package config

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"starwatch/internal/event"
	"starwatch/internal/history"
)

var ErrRestartManaged = errors.New("restart-managed field")
var ErrInvalidUpdate = errors.New("invalid config update")

type ManagerOptions struct {
	Now    func() time.Time
	Rand   io.Reader
	Events interface{ AddEvent(history.Event) }
	Live   event.Publisher
	Apply  func(*Config)
	Write  func(string, string) error
}

type Manager struct {
	mu           sync.RWMutex
	path, source string
	config       *Config
	options      ManagerOptions
}

type PublicConfig struct {
	Main    MainView    `json:"main"`
	History HistoryView `json:"history"`
	Alerts  AlertsView  `json:"alerts"`
	Battery BatteryView `json:"battery"`
}
type MainView struct {
	Listen          string   `json:"listen"`
	Port            int      `json:"port"`
	Token           string   `json:"token"`
	DishAddr        string   `json:"dish_addr"`
	PollStatus      int      `json:"poll_status"`
	PollMap         int      `json:"poll_map"`
	WANInterface    string   `json:"wan_iface"`
	ProbeHosts      []string `json:"probe_hosts"`
	ProbeInterval   int      `json:"probe_interval"`
	LocationEnabled bool     `json:"location_enabled"`
}
type HistoryView struct {
	RAMHours    int    `json:"ram_hours"`
	MinuteDays  int    `json:"minute_days"`
	QuarterDays int    `json:"quarter_days"`
	DBPath      string `json:"db_path"`
	FlushSecs   int    `json:"flush_secs"`
}
type AlertsView struct {
	WebhookURL string              `json:"webhook_url"`
	NtfyURL    string              `json:"ntfy_url"`
	Rules      map[string]RuleView `json:"rules"`
}
type RuleView struct {
	Enabled      bool    `json:"enabled"`
	Threshold    float64 `json:"threshold"`
	Threshold2   float64 `json:"threshold2"`
	HoldSeconds  int     `json:"hold_seconds"`
	ClearSeconds int     `json:"clear_seconds"`
}

type BatteryView struct {
	Enabled                     bool       `json:"enabled"`
	CapacityWh                  float64    `json:"capacity_wh"`
	StateOfChargePercent        float64    `json:"state_of_charge_percent"`
	ReservePercent              float64    `json:"reserve_percent"`
	ConversionEfficiencyPercent float64    `json:"conversion_efficiency_percent"`
	StateOfChargeUpdatedAt      *time.Time `json:"state_of_charge_updated_at,omitempty"`
}

type Update struct {
	Main    *MainUpdate    `json:"main,omitempty"`
	History *HistoryUpdate `json:"history,omitempty"`
	Alerts  *AlertsUpdate  `json:"alerts,omitempty"`
	Battery *BatteryUpdate `json:"battery,omitempty"`
}
type MainUpdate struct {
	Listen          *string   `json:"listen,omitempty"`
	Port            *int      `json:"port,omitempty"`
	Token           *string   `json:"token,omitempty"`
	DishAddr        *string   `json:"dish_addr,omitempty"`
	PollStatus      *int      `json:"poll_status,omitempty"`
	PollMap         *int      `json:"poll_map,omitempty"`
	WANInterface    *string   `json:"wan_iface,omitempty"`
	ProbeHosts      *[]string `json:"probe_hosts,omitempty"`
	ProbeInterval   *int      `json:"probe_interval,omitempty"`
	LocationEnabled *bool     `json:"location_enabled,omitempty"`
}
type HistoryUpdate struct {
	RAMHours    *int    `json:"ram_hours,omitempty"`
	MinuteDays  *int    `json:"minute_days,omitempty"`
	QuarterDays *int    `json:"quarter_days,omitempty"`
	DBPath      *string `json:"db_path,omitempty"`
	FlushSecs   *int    `json:"flush_secs,omitempty"`
}
type AlertsUpdate struct {
	WebhookURL *string               `json:"webhook_url,omitempty"`
	NtfyURL    *string               `json:"ntfy_url,omitempty"`
	Rules      map[string]RuleUpdate `json:"rules,omitempty"`
}
type RuleUpdate struct {
	Enabled      *bool    `json:"enabled,omitempty"`
	Threshold    *float64 `json:"threshold,omitempty"`
	Threshold2   *float64 `json:"threshold2,omitempty"`
	HoldSeconds  *int     `json:"hold_seconds,omitempty"`
	ClearSeconds *int     `json:"clear_seconds,omitempty"`
}

type BatteryUpdate struct {
	Enabled                     *bool    `json:"enabled,omitempty"`
	CapacityWh                  *float64 `json:"capacity_wh,omitempty"`
	StateOfChargePercent        *float64 `json:"state_of_charge_percent,omitempty"`
	ReservePercent              *float64 `json:"reserve_percent,omitempty"`
	ConversionEfficiencyPercent *float64 `json:"conversion_efficiency_percent,omitempty"`
}

func NewManager(path string, cfg *Config, options ManagerOptions) (*Manager, error) {
	source, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if options.Now == nil {
		options.Now = time.Now
	}
	if options.Rand == nil {
		options.Rand = rand.Reader
	}
	if options.Write == nil {
		options.Write = atomicWrite
	}
	return &Manager{path: path, source: string(source), config: cloneConfig(cfg), options: options}, nil
}

func (m *Manager) Token() string { m.mu.RLock(); defer m.mu.RUnlock(); return m.config.Token }
func (m *Manager) Snapshot() *Config {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return cloneConfig(m.config)
}
func (m *Manager) View() PublicConfig {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return publicConfig(m.config)
}

func (m *Manager) Update(update Update) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	candidate := cloneConfig(m.config)
	changes, err := applyUpdate(candidate, update, m.options.Now())
	if err != nil {
		return fmt.Errorf("%w: %w", ErrInvalidUpdate, err)
	}
	rewritten, err := RewriteUCI(m.source, changes)
	if err != nil {
		return err
	}
	if err := m.options.Write(m.path, rewritten); err != nil {
		return err
	}
	m.source, m.config = rewritten, candidate
	if m.options.Apply != nil {
		m.options.Apply(cloneConfig(candidate))
	}
	m.audit("update", update)
	return nil
}

func (m *Manager) RegenerateToken() (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	buffer := make([]byte, 32)
	if _, err := io.ReadFull(m.options.Rand, buffer); err != nil {
		return "", err
	}
	token := hex.EncodeToString(buffer)
	rewritten, err := RewriteUCI(m.source, []OptionValue{{SectionType: "starwatch", SectionName: "main", Option: "token", Value: token}})
	if err != nil {
		return "", err
	}
	if err := m.options.Write(m.path, rewritten); err != nil {
		return "", err
	}
	m.source, m.config.Token = rewritten, token
	m.audit("regenerate_token", map[string]any{})
	return token, nil
}

func (m *Manager) audit(action string, detail any) {
	payload, _ := json.Marshal(map[string]any{"action": action, "update": detail})
	at := m.options.Now()
	if m.options.Events != nil {
		m.options.Events.AddEvent(history.Event{At: at, Kind: "config", Detail: string(payload)})
	}
	if m.options.Live != nil {
		m.options.Live.Publish(event.Message{Kind: "config", At: at, Data: json.RawMessage(payload)})
	}
}

func publicConfig(cfg *Config) PublicConfig {
	rules := make(map[string]RuleView, len(cfg.Alerts.Rules))
	for name, rule := range cfg.Alerts.Rules {
		rules[name] = RuleView{Enabled: rule.Enabled, Threshold: rule.Threshold, Threshold2: rule.Threshold2, HoldSeconds: int(rule.Hold.Seconds()), ClearSeconds: int(rule.ClearHold.Seconds())}
	}
	var updatedAt *time.Time
	if !cfg.Battery.StateOfChargeUpdatedAt.IsZero() {
		value := cfg.Battery.StateOfChargeUpdatedAt
		updatedAt = &value
	}
	return PublicConfig{
		Main:    MainView{Listen: cfg.Listen, Port: cfg.Port, Token: maskToken(cfg.Token), DishAddr: cfg.DishAddr, PollStatus: int(cfg.PollStatus.Seconds()), PollMap: int(cfg.PollMap.Seconds()), WANInterface: cfg.WANInterface, ProbeHosts: append([]string(nil), cfg.ProbeHosts...), ProbeInterval: int(cfg.ProbeInterval.Seconds()), LocationEnabled: cfg.LocationEnabled},
		History: HistoryView{RAMHours: cfg.History.RAMHours, MinuteDays: cfg.History.MinuteDays, QuarterDays: cfg.History.QuarterDays, DBPath: cfg.History.DBPath, FlushSecs: int(cfg.History.FlushInterval.Seconds())},
		Alerts:  AlertsView{WebhookURL: cfg.Alerts.WebhookURL, NtfyURL: cfg.Alerts.NtfyURL, Rules: rules},
		Battery: BatteryView{Enabled: cfg.Battery.Enabled, CapacityWh: cfg.Battery.CapacityWh, StateOfChargePercent: cfg.Battery.StateOfChargePercent, ReservePercent: cfg.Battery.ReservePercent, ConversionEfficiencyPercent: cfg.Battery.ConversionEfficiencyPercent, StateOfChargeUpdatedAt: updatedAt},
	}
}

func maskToken(token string) string {
	if len(token) <= 4 {
		return strings.Repeat("*", len(token))
	}
	return "****" + token[len(token)-4:]
}

func applyUpdate(cfg *Config, update Update, now time.Time) ([]OptionValue, error) {
	var changes []OptionValue
	add := func(typ, name, option, value string) {
		changes = append(changes, OptionValue{SectionType: typ, SectionName: name, Option: option, Value: value})
	}
	if main := update.Main; main != nil {
		if main.Listen != nil || main.Port != nil || main.Token != nil || main.DishAddr != nil || main.PollStatus != nil || main.WANInterface != nil {
			return nil, ErrRestartManaged
		}
		if main.PollMap != nil {
			if *main.PollMap <= 0 {
				return nil, fmt.Errorf("poll_map must be positive")
			}
			cfg.PollMap = time.Duration(*main.PollMap) * time.Second
			add("starwatch", "main", "poll_map", strconv.Itoa(*main.PollMap))
		}
		if main.ProbeInterval != nil {
			if *main.ProbeInterval <= 0 {
				return nil, fmt.Errorf("probe_interval must be positive")
			}
			cfg.ProbeInterval = time.Duration(*main.ProbeInterval) * time.Second
			add("starwatch", "main", "probe_interval", strconv.Itoa(*main.ProbeInterval))
		}
		if main.ProbeHosts != nil {
			if len(*main.ProbeHosts) == 0 {
				return nil, fmt.Errorf("probe_hosts must not be empty")
			}
			cfg.ProbeHosts = append([]string(nil), (*main.ProbeHosts)...)
			add("starwatch", "main", "probe_hosts", strings.Join(*main.ProbeHosts, " "))
		}
		if main.LocationEnabled != nil {
			cfg.LocationEnabled = *main.LocationEnabled
			add("starwatch", "main", "location_enabled", strconv.FormatBool(*main.LocationEnabled))
		}
	}
	if input := update.History; input != nil {
		if input.RAMHours != nil || input.DBPath != nil || input.FlushSecs != nil {
			return nil, ErrRestartManaged
		}
		if input.MinuteDays != nil {
			if *input.MinuteDays < 1 {
				return nil, fmt.Errorf("minute_days must be positive")
			}
			cfg.History.MinuteDays = *input.MinuteDays
			add("history", "", "minute_days", strconv.Itoa(*input.MinuteDays))
		}
		if input.QuarterDays != nil {
			if *input.QuarterDays < 1 {
				return nil, fmt.Errorf("quarter_days must be positive")
			}
			cfg.History.QuarterDays = *input.QuarterDays
			add("history", "", "quarter_days", strconv.Itoa(*input.QuarterDays))
		}
	}
	if input := update.Alerts; input != nil {
		if input.WebhookURL != nil {
			cfg.Alerts.WebhookURL = *input.WebhookURL
			add("alerts", "", "webhook_url", *input.WebhookURL)
		}
		if input.NtfyURL != nil {
			cfg.Alerts.NtfyURL = *input.NtfyURL
			add("alerts", "", "ntfy_url", *input.NtfyURL)
		}
		for name, patch := range input.Rules {
			rule, exists := cfg.Alerts.Rules[name]
			if !exists {
				return nil, fmt.Errorf("unknown alert rule %q", name)
			}
			if patch.Enabled != nil {
				rule.Enabled = *patch.Enabled
				add("alerts", "", name+"_enabled", strconv.FormatBool(*patch.Enabled))
			}
			if patch.Threshold != nil {
				if *patch.Threshold < 0 {
					return nil, fmt.Errorf("threshold must be nonnegative")
				}
				rule.Threshold = *patch.Threshold
				option, scale := thresholdOption(name, false)
				if option != "" {
					add("alerts", "", option, strconv.FormatFloat(*patch.Threshold*scale, 'f', -1, 64))
				}
			}
			if patch.Threshold2 != nil {
				if *patch.Threshold2 < 0 {
					return nil, fmt.Errorf("threshold2 must be nonnegative")
				}
				rule.Threshold2 = *patch.Threshold2
				option, scale := thresholdOption(name, true)
				if option != "" {
					add("alerts", "", option, strconv.FormatFloat(*patch.Threshold2*scale, 'f', -1, 64))
				}
			}
			if patch.HoldSeconds != nil {
				if *patch.HoldSeconds < 0 {
					return nil, fmt.Errorf("hold_seconds must be nonnegative")
				}
				rule.Hold = time.Duration(*patch.HoldSeconds) * time.Second
				if option := holdOption(name, false); option != "" {
					add("alerts", "", option, strconv.Itoa(*patch.HoldSeconds))
				}
			}
			if patch.ClearSeconds != nil {
				if *patch.ClearSeconds < 0 {
					return nil, fmt.Errorf("clear_seconds must be nonnegative")
				}
				rule.ClearHold = time.Duration(*patch.ClearSeconds) * time.Second
				if option := holdOption(name, true); option != "" {
					add("alerts", "", option, strconv.Itoa(*patch.ClearSeconds))
				}
			}
			cfg.Alerts.Rules[name] = rule
		}
	}
	if input := update.Battery; input != nil {
		if input.Enabled != nil {
			cfg.Battery.Enabled = *input.Enabled
			add("battery", "", "enabled", strconv.FormatBool(*input.Enabled))
		}
		if input.CapacityWh != nil {
			if !finiteNumber(*input.CapacityWh) || *input.CapacityWh <= 0 || *input.CapacityWh > 100_000 {
				return nil, fmt.Errorf("capacity_wh must be greater than 0 and at most 100000")
			}
			cfg.Battery.CapacityWh = *input.CapacityWh
			add("battery", "", "capacity_wh", formatNumber(*input.CapacityWh))
		}
		if input.StateOfChargePercent != nil {
			if !finiteNumber(*input.StateOfChargePercent) || *input.StateOfChargePercent < 0 || *input.StateOfChargePercent > 100 {
				return nil, fmt.Errorf("state_of_charge_percent must be between 0 and 100")
			}
			cfg.Battery.StateOfChargePercent = *input.StateOfChargePercent
			cfg.Battery.StateOfChargeUpdatedAt = now.UTC()
			add("battery", "", "state_of_charge_percent", formatNumber(*input.StateOfChargePercent))
			add("battery", "", "state_of_charge_updated_at", now.UTC().Format(time.RFC3339Nano))
		}
		if input.ReservePercent != nil {
			if !finiteNumber(*input.ReservePercent) || *input.ReservePercent < 0 || *input.ReservePercent > 95 {
				return nil, fmt.Errorf("reserve_percent must be between 0 and 95")
			}
			cfg.Battery.ReservePercent = *input.ReservePercent
			add("battery", "", "reserve_percent", formatNumber(*input.ReservePercent))
		}
		if input.ConversionEfficiencyPercent != nil {
			if !finiteNumber(*input.ConversionEfficiencyPercent) || *input.ConversionEfficiencyPercent < 1 || *input.ConversionEfficiencyPercent > 100 {
				return nil, fmt.Errorf("conversion_efficiency_percent must be between 1 and 100")
			}
			cfg.Battery.ConversionEfficiencyPercent = *input.ConversionEfficiencyPercent
			add("battery", "", "conversion_efficiency_percent", formatNumber(*input.ConversionEfficiencyPercent))
		}
	}
	return changes, nil
}

func formatNumber(value float64) string {
	return strconv.FormatFloat(value, 'f', -1, 64)
}

func finiteNumber(value float64) bool {
	return !math.IsNaN(value) && !math.IsInf(value, 0)
}

func thresholdOption(name string, second bool) (string, float64) {
	if name == "path_degraded" {
		if second {
			return "path_rtt_ms", 1
		}
		return "path_loss_percent", 100
	}
	if name == "obstruction_high" && !second {
		return "obstruction_percent", 100
	}
	return "", 1
}
func holdOption(name string, clear bool) string {
	if clear && name == "path_degraded" {
		return "path_clear_secs"
	}
	if !clear && name == "outage_started" {
		return "outage_started_secs"
	}
	if !clear && name == "dish_unreachable" {
		return "dish_unreachable_secs"
	}
	return ""
}

func cloneConfig(cfg *Config) *Config {
	if cfg == nil {
		return nil
	}
	result := *cfg
	result.ProbeHosts = append([]string(nil), cfg.ProbeHosts...)
	result.Alerts.Rules = make(map[string]AlertRuleConfig, len(cfg.Alerts.Rules))
	for name, rule := range cfg.Alerts.Rules {
		result.Alerts.Rules[name] = rule
	}
	return &result
}

func atomicWrite(path, source string) error {
	dir := filepath.Dir(path)
	file, err := os.CreateTemp(dir, ".starwatch-*")
	if err != nil {
		return err
	}
	name := file.Name()
	defer os.Remove(name)
	if err = file.Chmod(0o600); err == nil {
		_, err = file.WriteString(source)
	}
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	return os.Rename(name, path)
}
