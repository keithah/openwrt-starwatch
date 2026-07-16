package config

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

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

func TestManagerBatteryUpdateStampsSOCAndPreservesUnknownUCI(t *testing.T) {
	now := time.Date(2026, 7, 16, 20, 0, 0, 123, time.FixedZone("test", -7*60*60))
	path := filepath.Join(t.TempDir(), "starwatch")
	source := `# preserve me
config starwatch 'main'
	option token 'secret'

config battery
	option future_battery_option 'keep-me'

config plugin 'unknown'
	list mystery 'one'
`
	if err := os.WriteFile(path, []byte(source), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	events := &managerEvents{}
	applied := false
	manager, err := NewManager(path, cfg, ManagerOptions{Now: func() time.Time { return now }, Events: events, Apply: func(*Config) { applied = true }})
	if err != nil {
		t.Fatal(err)
	}
	enabled := true
	capacity, soc, reserve, efficiency := 1024.0, 76.0, 10.0, 90.0
	if err := manager.Update(Update{Battery: &BatteryUpdate{
		Enabled: &enabled, CapacityWh: &capacity, StateOfChargePercent: &soc,
		ReservePercent: &reserve, ConversionEfficiencyPercent: &efficiency,
	}}); err != nil {
		t.Fatal(err)
	}
	got := manager.Snapshot().Battery
	if !applied || !got.Enabled || got.CapacityWh != 1024 || got.StateOfChargePercent != 76 ||
		got.ReservePercent != 10 || got.ConversionEfficiencyPercent != 90 || !got.StateOfChargeUpdatedAt.Equal(now.UTC()) {
		t.Fatalf("battery=%+v applied=%v", got, applied)
	}
	view := manager.View().Battery
	if view.StateOfChargeUpdatedAt == nil || !view.StateOfChargeUpdatedAt.Equal(now.UTC()) {
		t.Fatalf("battery view=%+v", view)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for _, preserved := range []string{"# preserve me", "future_battery_option 'keep-me'", "config plugin 'unknown'", "list mystery 'one'"} {
		if !strings.Contains(string(raw), preserved) {
			t.Fatalf("missing %q in rewritten UCI:\n%s", preserved, raw)
		}
	}
	if !strings.Contains(string(raw), "option state_of_charge_updated_at '2026-07-17T03:00:00.000000123Z'") {
		t.Fatalf("server timestamp missing from UCI:\n%s", raw)
	}
	if len(events.items) != 1 || events.items[0].Kind != "config" || !strings.Contains(events.items[0].Detail, `"battery"`) {
		t.Fatalf("events=%+v", events.items)
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
