package config

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"starwatch/internal/alert"
)

func TestAlertDefaultsMatchEngineCatalog(t *testing.T) {
	cfg := defaults()
	want := alert.DefaultRules()
	if len(cfg.Alerts.Rules) != len(want) {
		t.Fatalf("config rules=%d engine rules=%d", len(cfg.Alerts.Rules), len(want))
	}
	for name, rule := range want {
		got, ok := cfg.Alerts.Rules[name]
		if !ok || got.Enabled != rule.Enabled || got.Threshold != rule.Threshold ||
			got.Threshold2 != rule.Threshold2 || got.Hold != rule.Hold || got.ClearHold != rule.ClearHold {
			t.Fatalf("rule %q: config=%+v present=%v engine=%+v", name, got, ok, rule)
		}
	}
}

func configFile(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "starwatch")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestLoadDefaults(t *testing.T) {
	cfg, err := Load(configFile(t, "config starwatch 'main'\n"))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Listen != "0.0.0.0" || cfg.Port != 9633 || cfg.DishAddr != "192.168.100.1:9200" {
		t.Fatalf("main defaults: %+v", cfg)
	}
	if cfg.PollStatus != time.Second || cfg.PollMap != 15*time.Minute || cfg.ProbeInterval != 2*time.Second {
		t.Fatalf("interval defaults: %+v", cfg)
	}
	if !reflect.DeepEqual(cfg.ProbeHosts, []string{"1.1.1.1", "8.8.8.8"}) {
		t.Fatalf("probe hosts: %#v", cfg.ProbeHosts)
	}
	if cfg.History.RAMHours != 3 || cfg.History.MinuteDays != 7 || cfg.History.QuarterDays != 30 ||
		cfg.History.DBPath != "/etc/starwatch/history.db" || cfg.History.FlushInterval != 5*time.Minute {
		t.Fatalf("history defaults: %+v", cfg.History)
	}
	for _, name := range []string{"outage_started", "dish_unreachable", "path_degraded", "obstruction_high", "thermal_throttle", "thermal_shutdown", "motors_stuck", "water_detected", "mast_not_vertical", "slow_ethernet", "firmware_pending"} {
		if !cfg.Alerts.Rules[name].Enabled {
			t.Fatalf("default alert %q is disabled: %#v", name, cfg.Alerts.Rules[name])
		}
	}
	if cfg.Alerts.Rules["outage_started"].Hold != 30*time.Second || cfg.Alerts.Rules["dish_unreachable"].Hold != time.Minute ||
		cfg.Alerts.Rules["path_degraded"].Threshold != .2 || cfg.Alerts.Rules["path_degraded"].Threshold2 != 300 ||
		cfg.Alerts.Rules["path_degraded"].ClearHold != 5*time.Minute || cfg.Alerts.Rules["obstruction_high"].Threshold != .02 {
		t.Fatalf("alert defaults: %#v", cfg.Alerts.Rules)
	}
}

func TestLoadAllSpecOptions(t *testing.T) {
	cfg, err := Load(configFile(t, `
config starwatch 'main'
	option listen '127.0.0.1'
	option port '1234'
	option token 'secret'
	option dish_addr 'localhost:9200'
	option poll_status '3'
	option poll_map '120'
	option wan_iface 'wan2'
	option probe_hosts '9.9.9.9 149.112.112.112'
	option probe_interval '7'

config history
	option ram_hours '6'
	option minute_days '8'
	option quarter_days '31'
	option db_path '/tmp/history.db'
	option flush_secs '42'

config alerts
	option webhook_url 'https://example.test/hook'
	option ntfy_url 'https://ntfy.test/topic'
	option outage_started_enabled '0'
	option outage_started_secs '45'
	option dish_unreachable_enabled '1'
	option dish_unreachable_secs '75'
	option path_degraded_enabled '1'
	option path_loss_percent '25'
	option path_rtt_ms '350'
	option path_clear_secs '240'
	option obstruction_high_enabled '1'
	option obstruction_percent '3.5'
	option thermal_throttle_enabled '0'
	option thermal_shutdown_enabled '1'
	option motors_stuck_enabled '1'
	option water_detected_enabled '1'
	option mast_not_vertical_enabled '1'
	option slow_ethernet_enabled '1'
	option firmware_pending_enabled '0'
`))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Listen != "127.0.0.1" || cfg.Port != 1234 || cfg.Token != "secret" ||
		cfg.DishAddr != "localhost:9200" || cfg.PollStatus != 3*time.Second ||
		cfg.PollMap != 2*time.Minute || cfg.WANInterface != "wan2" || cfg.ProbeInterval != 7*time.Second {
		t.Fatalf("main: %+v", cfg)
	}
	if !reflect.DeepEqual(cfg.ProbeHosts, []string{"9.9.9.9", "149.112.112.112"}) {
		t.Fatalf("probe hosts: %#v", cfg.ProbeHosts)
	}
	if cfg.History.RAMHours != 6 || cfg.History.MinuteDays != 8 || cfg.History.QuarterDays != 31 ||
		cfg.History.DBPath != "/tmp/history.db" || cfg.History.FlushInterval != 42*time.Second {
		t.Fatalf("history: %+v", cfg.History)
	}
	if cfg.Alerts.WebhookURL != "https://example.test/hook" || cfg.Alerts.NtfyURL != "https://ntfy.test/topic" {
		t.Fatalf("alerts: %+v", cfg.Alerts)
	}
	if cfg.Alerts.Rules["outage_started"].Enabled || cfg.Alerts.Rules["outage_started"].Hold != 45*time.Second ||
		cfg.Alerts.Rules["dish_unreachable"].Hold != 75*time.Second || cfg.Alerts.Rules["path_degraded"].Threshold != .25 ||
		cfg.Alerts.Rules["path_degraded"].Threshold2 != 350 || cfg.Alerts.Rules["path_degraded"].ClearHold != 4*time.Minute ||
		cfg.Alerts.Rules["obstruction_high"].Threshold != .035 || cfg.Alerts.Rules["thermal_throttle"].Enabled ||
		cfg.Alerts.Rules["firmware_pending"].Enabled {
		t.Fatalf("alert options: %#v", cfg.Alerts.Rules)
	}
}

func TestLoadRejectsInvalidNumbers(t *testing.T) {
	for name, body := range map[string]string{
		"port":        "config starwatch 'main'\n option port '70000'\n",
		"poll_status": "config starwatch 'main'\n option poll_status '0'\n",
		"ram_hours":   "config history\n option ram_hours '-1'\n",
		"alert_bool":  "config alerts\n option motors_stuck_enabled 'maybe'\n",
		"alert_value": "config alerts\n option path_loss_percent '101'\n",
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := Load(configFile(t, body)); err == nil {
				t.Fatal("expected validation error")
			}
		})
	}
}
