package config

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"starwatch/internal/history"
)

type managerEvents struct{ items []history.Event }

func (e *managerEvents) AddEvent(item history.Event) { e.items = append(e.items, item) }

func TestManagerWriteFailureDoesNotPublishRuntimeCandidate(t *testing.T) {
	path := filepath.Join(t.TempDir(), "starwatch")
	if err := os.WriteFile(path, []byte("config starwatch 'main'\n option probe_interval '2'\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	applied := false
	manager, err := NewManager(path, cfg, ManagerOptions{Write: func(string, string) error { return errors.New("disk full") }, Apply: func(*Config) { applied = true }})
	if err != nil {
		t.Fatal(err)
	}
	interval := 5
	err = manager.Update(Update{Main: &MainUpdate{ProbeInterval: &interval}})
	if err == nil || applied || manager.Snapshot().ProbeInterval.Seconds() != 2 {
		t.Fatalf("err=%v applied=%v snapshot=%+v", err, applied, manager.Snapshot())
	}
}

func TestManagerAuditsUpdateAndTokenRegeneration(t *testing.T) {
	path := filepath.Join(t.TempDir(), "starwatch")
	if err := os.WriteFile(path, []byte("config starwatch 'main'\n option token 'secret'\n option probe_interval '2'\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	events := &managerEvents{}
	manager, err := NewManager(path, cfg, ManagerOptions{Events: events})
	if err != nil {
		t.Fatal(err)
	}
	interval := 3
	if err := manager.Update(Update{Main: &MainUpdate{ProbeInterval: &interval}}); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.RegenerateToken(); err != nil {
		t.Fatal(err)
	}
	if len(events.items) != 2 || events.items[0].Kind != "config" || events.items[1].Kind != "config" {
		t.Fatalf("events=%+v", events.items)
	}
}
