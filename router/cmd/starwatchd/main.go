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

	"starwatch/internal/api"
	"starwatch/internal/config"
	"starwatch/internal/dish"
	"starwatch/internal/history"
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
	poller := dish.NewPoller(client, store, dish.PollerOptions{StatusInterval: cfg.PollStatus, Now: deps.now})
	pollerDone := make(chan struct{})
	go func() {
		poller.Run(runCtx)
		close(pollerDone)
	}()
	reader := history.SpanReader(store)
	persistent, recovered, sqliteErr := history.OpenSQLite(cfg.History.DBPath, history.SQLiteOptions{Now: deps.now})
	if sqliteErr != nil {
		log.Printf("starwatchd: sqlite unavailable; continuing with RAM history: %v", sqliteErr)
	} else {
		reader = history.NewTieredReader(store, persistent, time.Duration(cfg.History.RAMHours)*time.Hour)
		persistent.AddEvent(history.Event{At: deps.now(), Kind: "daemon_started"})
		if recovered {
			log.Printf("starwatchd: corrupt sqlite database moved aside and recreated")
			persistent.AddEvent(history.Event{At: deps.now(), Kind: "sqlite_recreated"})
		}
		go flushHistory(runCtx, persistent, store, cfg.History.FlushInterval, deps.now)
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
	wanMonitor := wan.NewMonitor(wan.Options{
		DishAddr: cfg.DishAddr, Override: cfg.WANInterface, Hosts: cfg.ProbeHosts,
		ProbeInterval: cfg.ProbeInterval, Now: deps.now,
	}, store)
	wanDone := make(chan struct{})
	go func() {
		wanMonitor.Run(runCtx)
		close(wanDone)
	}()
	defer func() {
		cancel()
		<-pollerDone
		<-wanDone
	}()

	warnEmptyToken(cfg.Token, log.Printf)
	server := newHTTPServer(bindAddr(cfg), api.NewServer(api.Deps{
		Token: cfg.Token, Snapshot: poller, History: reader, WAN: wanMonitor,
	}))
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
		return nil
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
