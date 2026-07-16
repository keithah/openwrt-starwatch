package config

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

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
}

func TestLoadRejectsInvalidNumbers(t *testing.T) {
	for name, body := range map[string]string{
		"port":        "config starwatch 'main'\n option port '70000'\n",
		"poll_status": "config starwatch 'main'\n option poll_status '0'\n",
		"ram_hours":   "config history\n option ram_hours '-1'\n",
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := Load(configFile(t, body)); err == nil {
				t.Fatal("expected validation error")
			}
		})
	}
}
