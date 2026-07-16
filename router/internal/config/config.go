package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"starwatch/internal/alert"
)

type Config struct {
	Listen          string
	Port            int
	Token           string
	DishAddr        string
	PollStatus      time.Duration
	PollMap         time.Duration
	WANInterface    string
	ProbeHosts      []string
	ProbeInterval   time.Duration
	LocationEnabled bool
	History         HistoryConfig
	Alerts          AlertsConfig
}

type HistoryConfig struct {
	RAMHours      int
	MinuteDays    int
	QuarterDays   int
	DBPath        string
	FlushInterval time.Duration
}

type AlertsConfig struct {
	WebhookURL string
	NtfyURL    string
	Rules      map[string]AlertRuleConfig
}

type AlertRuleConfig struct {
	Enabled    bool
	Threshold  float64
	Threshold2 float64
	Hold       time.Duration
	ClearHold  time.Duration
}

func defaults() *Config {
	return &Config{
		Listen: "0.0.0.0", Port: 9633, DishAddr: "192.168.100.1:9200",
		PollStatus: time.Second, PollMap: 15 * time.Minute,
		ProbeHosts: []string{"1.1.1.1", "8.8.8.8"}, ProbeInterval: 2 * time.Second,
		History: HistoryConfig{RAMHours: 3, MinuteDays: 7, QuarterDays: 30,
			DBPath: "/etc/starwatch/history.db", FlushInterval: 5 * time.Minute},
		Alerts: defaultAlerts(),
	}
}

func defaultAlerts() AlertsConfig {
	defaults := alert.DefaultRules()
	rules := make(map[string]AlertRuleConfig, len(defaults))
	for name, rule := range defaults {
		rules[name] = AlertRuleConfig{
			Enabled: rule.Enabled, Threshold: rule.Threshold, Threshold2: rule.Threshold2,
			Hold: rule.Hold, ClearHold: rule.ClearHold,
		}
	}
	return AlertsConfig{Rules: rules}
}

func Load(path string) (*Config, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	doc, err := ParseUCI(string(raw))
	if err != nil {
		return nil, err
	}
	cfg := defaults()
	if section := doc.Find("starwatch", "main"); section != nil {
		if value := section.Options["listen"]; value != "" {
			cfg.Listen = value
		}
		if value := section.Options["token"]; value != "" {
			cfg.Token = value
		}
		if value := section.Options["dish_addr"]; value != "" {
			cfg.DishAddr = value
		}
		cfg.WANInterface = section.Options["wan_iface"]
		if value := section.Options["probe_hosts"]; value != "" {
			cfg.ProbeHosts = strings.Fields(value)
		}
		if err := parseInt(section, "port", 1, 65535, &cfg.Port); err != nil {
			return nil, err
		}
		if err := parseSeconds(section, "poll_status", &cfg.PollStatus); err != nil {
			return nil, err
		}
		if err := parseSeconds(section, "poll_map", &cfg.PollMap); err != nil {
			return nil, err
		}
		if err := parseSeconds(section, "probe_interval", &cfg.ProbeInterval); err != nil {
			return nil, err
		}
		if err := parseBool(section, "location_enabled", &cfg.LocationEnabled); err != nil {
			return nil, err
		}
	}
	if section := doc.Find("history", ""); section != nil {
		if err := parseInt(section, "ram_hours", 1, 24*365, &cfg.History.RAMHours); err != nil {
			return nil, err
		}
		if err := parseInt(section, "minute_days", 1, 3650, &cfg.History.MinuteDays); err != nil {
			return nil, err
		}
		if err := parseInt(section, "quarter_days", 1, 3650, &cfg.History.QuarterDays); err != nil {
			return nil, err
		}
		if value := section.Options["db_path"]; value != "" {
			cfg.History.DBPath = value
		}
		if err := parseSeconds(section, "flush_secs", &cfg.History.FlushInterval); err != nil {
			return nil, err
		}
	}
	if section := doc.Find("alerts", ""); section != nil {
		cfg.Alerts.WebhookURL = section.Options["webhook_url"]
		cfg.Alerts.NtfyURL = section.Options["ntfy_url"]
		for option, name := range map[string]string{
			"outage_started_enabled": "outage_started", "dish_unreachable_enabled": "dish_unreachable",
			"path_degraded_enabled": "path_degraded", "obstruction_high_enabled": "obstruction_high",
			"thermal_throttle_enabled": "thermal_throttle", "thermal_shutdown_enabled": "thermal_shutdown",
			"motors_stuck_enabled": "motors_stuck", "water_detected_enabled": "water_detected",
			"mast_not_vertical_enabled": "mast_not_vertical", "slow_ethernet_enabled": "slow_ethernet",
			"firmware_pending_enabled": "firmware_pending",
			"failover_event_enabled":   "failover_event",
		} {
			rule := cfg.Alerts.Rules[name]
			if err := parseBool(section, option, &rule.Enabled); err != nil {
				return nil, err
			}
			cfg.Alerts.Rules[name] = rule
		}
		if err := parseAlertSeconds(section, "outage_started_secs", cfg.Alerts.Rules, "outage_started", false); err != nil {
			return nil, err
		}
		if err := parseAlertSeconds(section, "dish_unreachable_secs", cfg.Alerts.Rules, "dish_unreachable", false); err != nil {
			return nil, err
		}
		if err := parseAlertSeconds(section, "path_clear_secs", cfg.Alerts.Rules, "path_degraded", true); err != nil {
			return nil, err
		}
		path := cfg.Alerts.Rules["path_degraded"]
		if err := parseFloat(section, "path_loss_percent", 0, 100, &path.Threshold, .01); err != nil {
			return nil, err
		}
		if err := parseFloat(section, "path_rtt_ms", 0, 60_000, &path.Threshold2, 1); err != nil {
			return nil, err
		}
		cfg.Alerts.Rules["path_degraded"] = path
		obstruction := cfg.Alerts.Rules["obstruction_high"]
		if err := parseFloat(section, "obstruction_percent", 0, 100, &obstruction.Threshold, .01); err != nil {
			return nil, err
		}
		cfg.Alerts.Rules["obstruction_high"] = obstruction
	}
	return cfg, nil
}

func parseBool(section *UCISection, option string, destination *bool) error {
	value := section.Options[option]
	if value == "" {
		return nil
	}
	parsed, err := strconv.ParseBool(value)
	if err != nil {
		return fmt.Errorf("%s.%s must be boolean", section.Type, option)
	}
	*destination = parsed
	return nil
}

func parseFloat(section *UCISection, option string, min, max float64, destination *float64, scale float64) error {
	value := section.Options[option]
	if value == "" {
		return nil
	}
	parsed, err := strconv.ParseFloat(value, 64)
	if err != nil || parsed < min || parsed > max {
		return fmt.Errorf("%s.%s must be between %g and %g", section.Type, option, min, max)
	}
	*destination = parsed * scale
	return nil
}

func parseAlertSeconds(section *UCISection, option string, rules map[string]AlertRuleConfig, name string, clear bool) error {
	rule := rules[name]
	destination := &rule.Hold
	if clear {
		destination = &rule.ClearHold
	}
	if err := parseSeconds(section, option, destination); err != nil {
		return err
	}
	rules[name] = rule
	return nil
}

func parseInt(section *UCISection, option string, min, max int, destination *int) error {
	value := section.Options[option]
	if value == "" {
		return nil
	}
	number, err := strconv.Atoi(value)
	if err != nil || number < min || number > max {
		return fmt.Errorf("%s.%s must be between %d and %d", section.Type, option, min, max)
	}
	*destination = number
	return nil
}

func parseSeconds(section *UCISection, option string, destination *time.Duration) error {
	seconds := int(destination.Seconds())
	if err := parseInt(section, option, 1, 365*24*60*60, &seconds); err != nil {
		return err
	}
	*destination = time.Duration(seconds) * time.Second
	return nil
}
