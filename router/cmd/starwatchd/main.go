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
	"starwatch/internal/dishroute"
	"starwatch/internal/event"
	"starwatch/internal/history"
	"starwatch/internal/mwan"
	"starwatch/internal/outage"
	"starwatch/internal/wan"
)

type runtimeDeps struct {
	listen          func(network, address string) (net.Listener, error)
	now             func() time.Time
	configPath      string
	mwanRunner      mwan.Runner
	glManaged       func(context.Context) bool
	resolveGateway  func(context.Context) (string, error)
	wanDiscoverer   wan.Discoverer
	dishRouteRunner dishroute.Runner
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
	return runConfig(ctx, cfg, runtimeDeps{configPath: configPath})
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
	routeOptions := dishroute.Options{
		Enabled: cfg.ManageDishRoute, Runner: deps.dishRouteRunner, Now: deps.now, Live: liveEvents, Logf: log.Printf,
	}
	if persistent != nil {
		routeOptions.Events = persistent
	}
	routeManager := dishroute.NewManager(routeOptions)
	poller := dish.NewPoller(client, store, dish.PollerOptions{
		StatusInterval: cfg.PollStatus, MapInterval: cfg.PollMap, LocationEnabled: cfg.LocationEnabled, Now: deps.now,
		RouteEnsurer: routeManager, RouteError: func(err error) { log.Printf("starwatchd: ensure dish route: %v", err) },
	})
	pollerDone := make(chan struct{})
	go func() {
		poller.Run(runCtx)
		close(pollerDone)
	}()
	resolveGateway := deps.resolveGateway
	if resolveGateway == nil && deps.configPath == "" {
		resolveGateway = func(context.Context) (string, error) { return "", fmt.Errorf("router discovery disabled") }
	}
	routerPoller := dish.NewRouterPoller(dish.RouterPollerOptions{Topology: poller, ResolveGateway: resolveGateway, Now: deps.now})
	routerDone := make(chan struct{})
	go func() { routerPoller.Run(runCtx); close(routerDone) }()
	timeline := outage.NewTimeline(outage.Options{Now: deps.now, Persistence: persistent, Events: liveEvents})
	mwanOptions := mwan.Options{Runner: deps.mwanRunner, GLManaged: deps.glManaged}
	if mwanOptions.Runner == nil && deps.configPath == "" {
		mwanOptions.Runner = unavailableRunner{}
		mwanOptions.GLManaged = func(context.Context) bool { return false }
	}
	mwanManager := mwan.NewManager(mwanOptions)
	mwanDone := make(chan struct{})
	go func() { mwanManager.Run(runCtx); close(mwanDone) }()
	discoverer := deps.wanDiscoverer
	if discoverer == nil && deps.configPath == "" {
		discoverer = unavailableDiscoverer{}
	}
	wanMonitor := wan.NewMonitor(wan.Options{
		DishAddr: cfg.DishAddr, Override: cfg.WANInterface, Hosts: cfg.ProbeHosts,
		ProbeInterval: cfg.ProbeInterval, Now: deps.now, MWAN: mwanManager, Discoverer: discoverer,
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
	var settings *config.Manager
	if deps.configPath != "" {
		managerOptions := config.ManagerOptions{Now: deps.now, Live: liveEvents, Apply: func(updated *config.Config) {
			poller.SetLocationEnabled(updated.LocationEnabled)
			poller.SetMapInterval(updated.PollMap)
			wanMonitor.SetProbeConfig(updated.ProbeHosts, updated.ProbeInterval)
			alertEngine.SetRules(alertRules(updated.Alerts))
			dispatcher.SetEndpoints(updated.Alerts.WebhookURL, updated.Alerts.NtfyURL)
			if persistent != nil {
				persistent.SetRetention(time.Duration(updated.History.MinuteDays)*24*time.Hour, time.Duration(updated.History.QuarterDays)*24*time.Hour)
			}
		}}
		if persistent != nil {
			managerOptions.Events = persistent
		}
		settings, err = config.NewManager(deps.configPath, cfg, managerOptions)
		if err != nil {
			cancel()
			<-pollerDone
			<-routerDone
			<-wanDone
			<-mwanDone
			<-deliveryDone
			if flushDone != nil {
				<-flushDone
			}
			return fmt.Errorf("settings manager: %w", err)
		}
	}
	controllerOptions := dish.ControlOptions{
		Now: deps.now, Live: liveEvents, SuppressDishUnreachableUntil: alertEngine.SetDishUnreachableSuppressUntil,
		ExpectDishUnreachableUntil: timeline.ExpectDishUnreachableUntil,
	}
	if persistent != nil {
		controllerOptions.Events = persistent
	}
	controller := dish.NewController(client, poller, controllerOptions)
	speedOptions := dish.SpeedtestOptions{Context: runCtx, Now: deps.now, Live: liveEvents}
	if persistent != nil {
		speedOptions.Store = persistent
	}
	speedtests := dish.NewSpeedtestManager(client, speedOptions)
	evaluationDone := make(chan struct{})
	go func() {
		runEvaluationLoop(runCtx, poller, wanMonitor, timeline, alertEngine, deps.now)
		close(evaluationDone)
	}()
	defer func() {
		cancel()
		<-pollerDone
		<-routerDone
		<-wanDone
		<-mwanDone
		<-evaluationDone
		<-deliveryDone
		speedtests.Wait()
		if flushDone != nil {
			<-flushDone
		}
	}()

	warnEmptyToken(cfg.Token, log.Printf)
	apiDeps := api.Deps{
		Token: cfg.Token, Snapshot: combinedSnapshot{dish: poller, router: routerPoller}, History: reader, WAN: wanMonitor,
		Outages: timeline, Events: persistent, Live: liveEvents, AuditEvents: persistent, AuditLive: liveEvents, Now: deps.now,
		Controls: controller, Obstruction: poller, Speedtest: speedtests, MapInterval: cfg.PollMap,
		FailoverAssist: mwanManager, AlertDelivery: dispatcher,
		RouterMutations: dish.NewRouterMutationController(dish.RouterMutationOptions{ResolveGateway: resolveGateway}),
	}
	if settings != nil {
		apiDeps.Settings = settings
		apiDeps.TokenProvider = settings.Token
	}
	apiHandler := api.NewServer(apiDeps)
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

type unavailableRunner struct{}

func (unavailableRunner) Run(context.Context, string, []string, string) ([]byte, error) {
	return nil, fmt.Errorf("command unavailable")
}

type unavailableDiscoverer struct{}

func (unavailableDiscoverer) Discover(string, string) (string, error) {
	return "", fmt.Errorf("discovery unavailable")
}

type combinedSnapshot struct {
	dish   interface{ Snapshot() dish.Snapshot }
	router interface{ Snapshot() *dish.StarlinkRouter }
}

func (s combinedSnapshot) Snapshot() dish.Snapshot {
	result := s.dish.Snapshot()
	if s.router != nil {
		result.StarlinkRouter = s.router.Snapshot()
	}
	return result
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
