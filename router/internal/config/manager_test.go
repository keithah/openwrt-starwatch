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

type atomicTestFile struct {
	name    string
	label   string
	calls   *[]string
	syncErr error
}

func (f *atomicTestFile) Name() string { return f.name }
func (f *atomicTestFile) Chmod(os.FileMode) error {
	*f.calls = append(*f.calls, f.label+"-chmod")
	return nil
}
func (f *atomicTestFile) WriteString(source string) (int, error) {
	*f.calls = append(*f.calls, f.label+"-write")
	return len(source), nil
}
func (f *atomicTestFile) Sync() error {
	*f.calls = append(*f.calls, f.label+"-sync")
	return f.syncErr
}
func (f *atomicTestFile) Close() error {
	*f.calls = append(*f.calls, f.label+"-close")
	return nil
}

func TestAtomicWriteSyncsFileAndParentDirectory(t *testing.T) {
	var calls []string
	temporary := &atomicTestFile{name: "/etc/config/.starwatch-test", label: "file", calls: &calls}
	directory := &atomicTestFile{name: "/etc/config", label: "dir", calls: &calls}
	operations := atomicWriteOperations{
		createTemp: func(directory, pattern string) (atomicSyncFile, error) {
			calls = append(calls, "create:"+directory+":"+pattern)
			return temporary, nil
		},
		remove: func(path string) error {
			calls = append(calls, "remove:"+path)
			return nil
		},
		rename: func(oldPath, newPath string) error {
			calls = append(calls, "rename:"+oldPath+":"+newPath)
			return nil
		},
		openDirectory: func(path string) (atomicSyncFile, error) {
			calls = append(calls, "open-dir:"+path)
			return directory, nil
		},
	}
	if err := atomicWriteWithOperations("/etc/config/starwatch", "config starwatch\n", operations); err != nil {
		t.Fatal(err)
	}
	want := []string{
		"create:/etc/config:.starwatch-*", "file-chmod", "file-write", "file-sync", "file-close",
		"rename:/etc/config/.starwatch-test:/etc/config/starwatch", "open-dir:/etc/config", "dir-sync", "dir-close",
		"remove:/etc/config/.starwatch-test",
	}
	if strings.Join(calls, "|") != strings.Join(want, "|") {
		t.Fatalf("calls=%v want=%v", calls, want)
	}
}

func TestAtomicWriteDoesNotRenameAfterFileSyncFailure(t *testing.T) {
	var calls []string
	temporary := &atomicTestFile{name: "/etc/config/.starwatch-test", label: "file", calls: &calls, syncErr: errors.New("sync failed")}
	operations := atomicWriteOperations{
		createTemp: func(string, string) (atomicSyncFile, error) { return temporary, nil },
		remove:     func(string) error { calls = append(calls, "remove"); return nil },
		rename:     func(string, string) error { calls = append(calls, "rename"); return nil },
		openDirectory: func(string) (atomicSyncFile, error) {
			calls = append(calls, "open-dir")
			return nil, nil
		},
	}
	if err := atomicWriteWithOperations("/etc/config/starwatch", "source", operations); err == nil || !strings.Contains(err.Error(), "sync failed") {
		t.Fatalf("err=%v", err)
	}
	if strings.Contains(strings.Join(calls, "|"), "rename") || strings.Contains(strings.Join(calls, "|"), "open-dir") {
		t.Fatalf("calls after sync failure=%v", calls)
	}
}

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

func TestManagerRejectsNewlinesInDeliveryEndpoints(t *testing.T) {
	for name, update := range map[string]Update{
		"webhook": {Alerts: &AlertsUpdate{WebhookURL: stringPointer("https://example.test/hook\noption token 'injected'")}},
		"ntfy":    {Alerts: &AlertsUpdate{NtfyURL: stringPointer("https://ntfy.test/topic\r\nconfig injected")}},
	} {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "starwatch")
			if err := os.WriteFile(path, []byte("config alerts\n"), 0o600); err != nil {
				t.Fatal(err)
			}
			cfg, err := Load(path)
			if err != nil {
				t.Fatal(err)
			}
			writes := 0
			manager, err := NewManager(path, cfg, ManagerOptions{Write: func(string, string) error { writes++; return nil }})
			if err != nil {
				t.Fatal(err)
			}
			if err := manager.Update(update); !errors.Is(err, ErrInvalidUpdate) {
				t.Fatalf("err=%v", err)
			}
			if writes != 0 {
				t.Fatalf("writes=%d", writes)
			}
		})
	}
}

func TestManagerRejectsRuleFieldsWithoutPersistedOptions(t *testing.T) {
	path := filepath.Join(t.TempDir(), "starwatch")
	if err := os.WriteFile(path, []byte("config alerts\n\toption thermal_throttle_enabled '1'\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	original := cfg.Alerts.Rules["thermal_throttle"]
	writes := 0
	manager, err := NewManager(path, cfg, ManagerOptions{Write: func(string, string) error { writes++; return nil }})
	if err != nil {
		t.Fatal(err)
	}
	threshold := 12.0
	err = manager.Update(Update{Alerts: &AlertsUpdate{Rules: map[string]RuleUpdate{
		"thermal_throttle": {Threshold: &threshold},
	}}})
	if !errors.Is(err, ErrInvalidUpdate) {
		t.Fatalf("err=%v", err)
	}
	if writes != 0 || manager.Snapshot().Alerts.Rules["thermal_throttle"] != original {
		t.Fatalf("writes=%d rule=%+v original=%+v", writes, manager.Snapshot().Alerts.Rules["thermal_throttle"], original)
	}
}

func TestManagerInvokesApplyAfterReleasingLock(t *testing.T) {
	path := filepath.Join(t.TempDir(), "starwatch")
	if err := os.WriteFile(path, []byte("config starwatch 'main'\n\toption probe_interval '2'\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	var manager *Manager
	applied := make(chan struct{})
	manager, err = NewManager(path, cfg, ManagerOptions{Apply: func(*Config) {
		_ = manager.View()
		close(applied)
	}})
	if err != nil {
		t.Fatal(err)
	}
	interval := 3
	done := make(chan error, 1)
	go func() { done <- manager.Update(Update{Main: &MainUpdate{ProbeInterval: &interval}}) }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("Update deadlocked while Apply re-entered the manager")
	}
	select {
	case <-applied:
	default:
		t.Fatal("Apply was not invoked")
	}
}

func stringPointer(value string) *string { return &value }
