package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	Listen        string
	Port          int
	Token         string
	DishAddr      string
	PollStatus    time.Duration
	PollMap       time.Duration
	WANInterface  string
	ProbeHosts    []string
	ProbeInterval time.Duration
	History       HistoryConfig
	Alerts        AlertsConfig
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
}

func defaults() *Config {
	return &Config{
		Listen: "0.0.0.0", Port: 9633, DishAddr: "192.168.100.1:9200",
		PollStatus: time.Second, PollMap: 15 * time.Minute,
		ProbeHosts: []string{"1.1.1.1", "8.8.8.8"}, ProbeInterval: 2 * time.Second,
		History: HistoryConfig{RAMHours: 3, MinuteDays: 7, QuarterDays: 30,
			DBPath: "/etc/starwatch/history.db", FlushInterval: 5 * time.Minute},
	}
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
	}
	return cfg, nil
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
