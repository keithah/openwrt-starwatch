package main

import (
	"bytes"
	"context"
	"database/sql"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"

	"starwatch/internal/config"
	"starwatch/internal/history"
)

func TestBindAddr(t *testing.T) {
	cfg := &config.Config{Listen: "0.0.0.0", Port: 9633}
	if got := bindAddr(cfg); got != "0.0.0.0:9633" {
		t.Fatalf("got %q", got)
	}
	cfg.Listen = "::1"
	if got := bindAddr(cfg); got != "[::1]:9633" {
		t.Fatalf("IPv6 got %q", got)
	}
}

func TestNewHTTPServerSetsReadHeaderTimeout(t *testing.T) {
	server := newHTTPServer("127.0.0.1:9633", http.NewServeMux())
	if server.ReadHeaderTimeout != 5*time.Second {
		t.Fatalf("timeout: %v", server.ReadHeaderTimeout)
	}
}

func TestWarnEmptyToken(t *testing.T) {
	var output bytes.Buffer
	logger := log.New(&output, "", 0)
	warnEmptyToken("", logger.Printf)
	if !bytes.Contains(output.Bytes(), []byte("token is empty")) {
		t.Fatalf("warning: %q", output.String())
	}
	output.Reset()
	warnEmptyToken("secret", logger.Printf)
	if output.Len() != 0 {
		t.Fatalf("unexpected warning: %q", output.String())
	}
}

func TestSQLiteOptionsMapConfiguredRetention(t *testing.T) {
	now := func() time.Time { return time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC) }
	cfg := &config.Config{History: config.HistoryConfig{MinuteDays: 11, QuarterDays: 47}}

	options := sqliteOptions(cfg, now)

	if options.MinuteRetention != 11*24*time.Hour || options.QuarterRetention != 47*24*time.Hour {
		t.Fatalf("sqlite options: %+v", options)
	}
	if options.Now == nil || !options.Now().Equal(now()) {
		t.Fatal("sqlite options did not retain the daemon clock")
	}
	var _ history.SQLiteOptions = options
}

func TestRunConfigServesAndStopsOnCancellation(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	cfg := &config.Config{
		Listen: "127.0.0.1", Port: 9633, Token: "secret", DishAddr: "127.0.0.1:1",
		PollStatus: time.Second, History: config.HistoryConfig{
			RAMHours: 1, DBPath: filepath.Join(t.TempDir(), "history.db"), FlushInterval: time.Hour,
		},
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- runConfig(ctx, cfg, runtimeDeps{listen: func(_, _ string) (net.Listener, error) {
			return listener, nil
		}})
	}()

	client := &http.Client{Timeout: time.Second}
	waitUntil := time.Now().Add(2 * time.Second)
	for {
		req, _ := http.NewRequest(http.MethodGet, "http://"+listener.Addr().String()+"/api/status", nil)
		req.Header.Set("Authorization", "Bearer secret")
		response, requestErr := client.Do(req)
		if requestErr == nil {
			_ = response.Body.Close()
			if response.StatusCode != http.StatusOK {
				t.Fatalf("status code: %d", response.StatusCode)
			}
			break
		}
		if time.Now().After(waitUntil) {
			t.Fatalf("server did not start: %v", requestErr)
		}
		time.Sleep(10 * time.Millisecond)
	}

	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("daemon did not stop cleanly")
	}
	db, err := sql.Open("sqlite", cfg.History.DBPath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	for _, kind := range []string{"daemon_started", "daemon_stopped"} {
		var count int
		if err := db.QueryRow("SELECT COUNT(*) FROM events WHERE kind=?", kind).Scan(&count); err != nil || count != 1 {
			t.Fatalf("event %s count=%d err=%v", kind, count, err)
		}
	}
}

func TestRunConfigContinuesWhenSQLiteIsUnavailable(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	blocker := filepath.Join(t.TempDir(), "not-a-directory")
	if err := os.WriteFile(blocker, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg := &config.Config{
		Listen: "127.0.0.1", Port: 9633, Token: "secret", DishAddr: "127.0.0.1:1",
		PollStatus: time.Second, History: config.HistoryConfig{RAMHours: 1, DBPath: filepath.Join(blocker, "history.db")},
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- runConfig(ctx, cfg, runtimeDeps{listen: func(_, _ string) (net.Listener, error) { return listener, nil }})
	}()
	client := &http.Client{Timeout: time.Second}
	deadline := time.Now().Add(2 * time.Second)
	for {
		req, _ := http.NewRequest(http.MethodGet, "http://"+listener.Addr().String()+"/api/status", nil)
		req.Header.Set("Authorization", "Bearer secret")
		response, requestErr := client.Do(req)
		if requestErr == nil {
			_ = response.Body.Close()
			if response.StatusCode != http.StatusOK {
				t.Fatalf("status code: %d", response.StatusCode)
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("server did not start without sqlite: %v", requestErr)
		}
		time.Sleep(10 * time.Millisecond)
	}
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("daemon did not stop")
	}
}
