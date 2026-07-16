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
)

type runtimeDeps struct {
	listen func(network, address string) (net.Listener, error)
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
	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()

	client, err := dish.Dial(runCtx, cfg.DishAddr)
	if err != nil {
		return fmt.Errorf("dish client: %w", err)
	}
	defer client.Close()

	store := history.NewStore(cfg.History.RAMHours * 60 * 60)
	poller := dish.NewPoller(client, store, dish.PollerOptions{StatusInterval: cfg.PollStatus})
	go poller.Run(runCtx)

	warnEmptyToken(cfg.Token, log.Printf)
	server := newHTTPServer(bindAddr(cfg), api.NewServer(api.Deps{Token: cfg.Token, Snapshot: poller, History: store}))
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
