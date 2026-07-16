// Command starwatchd monitors a Starlink dish from an OpenWrt router.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"starwatch/internal/alert"
	"starwatch/internal/api"
	"starwatch/internal/config"
	"starwatch/internal/dish"
	"starwatch/internal/event"
	"starwatch/internal/history"
	"starwatch/internal/outage"
	"starwatch/internal/wan"
)

type runtimeDeps struct {
	listen func(network, address string) (net.Listener, error)
	now    func() time.Time
}

func main() {
	configPath := flag.String("config", "/etc/config/starwatch", "UCI config path")
	flag.Parse()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, *configPath); err != nil {
		log.Fatalf("starwatchd: %v", err)
	}
}

func run(ctx context.Context, configPath string) error {
	cfg, err := config.Load(configPath)
	if err != nil {
		return err
	}
	return runConfig(ctx, cfg, runtimeDeps{})
}

func runConfig(ctx context.Context, cfg *config.Config, deps runtimeDeps) error {
	if deps.listen == nil {
		deps.listen = net.Listen
	}
	if deps.now == nil {
		deps.now = time.Now
	}
	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()

	client, err := dish.Dial(runCtx, cfg.DishAddr)
	if err != nil {
		return fmt.Errorf("dish client: %w", err)
	}
	defer client.Close()

	store := history.NewStore(cfg.History.RAMHours * 60 * 60)
	liveEvents := event.NewBus()
	poller := dish.NewPoller(client, store, dish.PollerOptions{StatusInterval: cfg.PollStatus, Now: deps.now})
	pollerDone := make(chan struct{})
	go func() {
		poller.Run(runCtx)
		close(pollerDone)
	}()
	reader := history.SpanReader(store)
	persistent, recovered, sqliteErr := history.OpenSQLite(cfg.History.DBPath, sqliteOptions(cfg, deps.now))
	var flushDone chan struct{}
	if sqliteErr != nil {
		log.Printf("starwatchd: sqlite unavailable; continuing with RAM history: %v", sqliteErr)
	} else {
		reader = history.NewTieredReader(store, persistent, time.Duration(cfg.History.RAMHours)*time.Hour)
		persistent.AddEvent(history.Event{At: deps.now(), Kind: "daemon_started"})
		if recovered {
			log.Printf("starwatchd: corrupt sqlite database moved aside and recreated")
			persistent.AddEvent(history.Event{At: deps.now(), Kind: "sqlite_recreated"})
		}
		flushDone = make(chan struct{})
		go func() {
			flushHistory(runCtx, persistent, store, cfg.History.FlushInterval, deps.now)
			close(flushDone)
		}()
		defer func() {
			persistent.AddEvent(history.Event{At: deps.now(), Kind: "daemon_stopped"})
			if err := persistent.Flush(context.Background(), store, deps.now()); err != nil {
				log.Printf("starwatchd: final history flush: %v", err)
			}
			if err := persistent.Close(); err != nil {
				log.Printf("starwatchd: close history database: %v", err)
			}
		}()
	}
	timeline := outage.NewTimeline(outage.Options{Now: deps.now, Persistence: persistent, Events: liveEvents})
	wanMonitor := wan.NewMonitor(wan.Options{
		DishAddr: cfg.DishAddr, Override: cfg.WANInterface, Hosts: cfg.ProbeHosts,
		ProbeInterval: cfg.ProbeInterval, Now: deps.now,
	}, store)
	wanDone := make(chan struct{})
	go func() {
		wanMonitor.Run(runCtx)
		close(wanDone)
	}()
	dispatcher := alert.NewDispatcher(alert.DeliveryOptions{
		WebhookURL: cfg.Alerts.WebhookURL, NtfyURL: cfg.Alerts.NtfyURL,
	})
	deliveryDone := make(chan struct{})
	go func() {
		dispatcher.Run(runCtx)
		close(deliveryDone)
	}()
	engineOptions := alert.Options{
		Now: deps.now, Rules: alertRules(cfg.Alerts), History: reader, Delivery: dispatcher, Live: liveEvents,
	}
	if persistent != nil {
		engineOptions.Events = persistent
	}
	alertEngine := alert.NewEngine(engineOptions)
	evaluationDone := make(chan struct{})
	go func() {
		runEvaluationLoop(runCtx, poller, wanMonitor, timeline, alertEngine, deps.now)
		close(evaluationDone)
	}()
	defer func() {
		cancel()
		<-pollerDone
		<-wanDone
		<-evaluationDone
		<-deliveryDone
		if flushDone != nil {
			<-flushDone
		}
	}()

	warnEmptyToken(cfg.Token, log.Printf)
	apiHandler := api.NewServer(api.Deps{
		Token: cfg.Token, Snapshot: poller, History: reader, WAN: wanMonitor,
		Outages: timeline, Events: persistent, Live: liveEvents, Now: deps.now,
	})
	defer apiHandler.Close()
	server := newHTTPServer(bindAddr(cfg), apiHandler)
	listener, err := deps.listen("tcp", server.Addr)
	if err != nil {
		return fmt.Errorf("listen %s: %w", server.Addr, err)
	}
	serveResult := make(chan error, 1)
	go func() {
		err := server.Serve(listener)
		if err == http.ErrServerClosed {
			err = nil
		}
		serveResult <- err
	}()
	log.Printf("starwatchd: API listening on %s", listener.Addr())

	select {
	case err := <-serveResult:
		cancel()
		apiHandler.Close()
		if err != nil {
			return fmt.Errorf("api server: %w", err)
		}
		return nil
	case <-ctx.Done():
		cancel()
		shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer shutdownCancel()
		if err := server.Shutdown(shutdownCtx); err != nil {
			return fmt.Errorf("api shutdown: %w", err)
		}
		apiHandler.Close()
		return nil
	}
}

type evaluationPoller interface {
	Snapshot() dish.Snapshot
}

type evaluationWAN interface {
	Snapshot() dish.WANStatus
}

func runEvaluationLoop(ctx context.Context, poller evaluationPoller, wanProvider evaluationWAN, timeline *outage.Timeline, engine *alert.Engine, now func() time.Time) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			at := now()
			if at.Year() < 2025 {
				continue
			}
			snapshot := poller.Snapshot()
			reports := make([]outage.DishReport, 0, len(snapshot.HistoryOutages))
			for _, reported := range snapshot.HistoryOutages {
				reports = append(reports, outage.DishReport{Cause: reported.Cause, Start: reported.Start, Duration: reported.Duration})
			}
			timeline.IngestDish(reports)
			failureSince := time.Time{}
			if snapshot.DishFailureSince != nil {
				failureSince = *snapshot.DishFailureSince
			}
			if snapshot.DishReachable || snapshot.DishFailureSince != nil {
				timeline.ObserveDish(snapshot.DishReachable, failureSince)
			}
			wanSnapshot := wanProvider.Snapshot()
			dishConnected := snapshot.DishReachable && snapshot.Dish != nil && snapshot.Dish.Outage == nil
			timeline.ObservePath(dishConnected, wanSnapshot.ProbeLossNow >= 1)
			engine.Tick(alert.Inputs{Dish: snapshot, WAN: wanSnapshot, Outages: timeline.Active()})
		}
	}
}

func alertRules(configured config.AlertsConfig) map[string]alert.Rule {
	rules := alert.DefaultRules()
	for name, input := range configured.Rules {
		rule, exists := rules[name]
		if !exists {
			continue
		}
		rule.Enabled = input.Enabled
		rule.Threshold = input.Threshold
		rule.Threshold2 = input.Threshold2
		rule.Hold = input.Hold
		rule.ClearHold = input.ClearHold
		rules[name] = rule
	}
	return rules
}

func sqliteOptions(cfg *config.Config, now func() time.Time) history.SQLiteOptions {
	return history.SQLiteOptions{
		MinuteRetention:  time.Duration(cfg.History.MinuteDays) * 24 * time.Hour,
		QuarterRetention: time.Duration(cfg.History.QuarterDays) * 24 * time.Hour,
		Now:              now,
	}
}

func flushHistory(ctx context.Context, persistent *history.SQLiteStore, ram history.Reader, interval time.Duration, now func() time.Time) {
	if interval <= 0 {
		interval = 5 * time.Minute
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := persistent.Flush(ctx, ram, now()); err != nil {
				log.Printf("starwatchd: history flush: %v", err)
			}
		}
	}
}

func newHTTPServer(address string, handler http.Handler) *http.Server {
	return &http.Server{Addr: address, Handler: handler, ReadHeaderTimeout: 5 * time.Second}
}

func warnEmptyToken(token string, logf func(string, ...any)) {
	if token == "" {
		logf("starwatchd: warning: API token is empty; all API requests will be denied")
	}
}

func bindAddr(cfg *config.Config) string {
	return net.JoinHostPort(cfg.Listen, strconv.Itoa(cfg.Port))
}
