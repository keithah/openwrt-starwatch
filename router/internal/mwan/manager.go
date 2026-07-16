// Package mwan provides optional, injectable mwan3 status and failover assistance.
package mwan

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"sort"
	"strings"
	"sync"
	"time"

	"starwatch/internal/dish"
)

type Runner interface {
	Run(context.Context, string, []string, string) ([]byte, error)
}

type Options struct {
	Runner     Runner
	Interval   time.Duration
	Interfaces func(context.Context) []string
	GLManaged  func(context.Context) bool
	Now        func() time.Time
}

type Change struct {
	Package string `json:"package"`
	Section string `json:"section"`
	Option  string `json:"option"`
	Value   string `json:"value"`
}

type AssistResult struct {
	Available bool     `json:"available"`
	Reason    string   `json:"reason,omitempty"`
	Proposed  []Change `json:"proposed"`
}

var ErrAssistUnavailable = errors.New("failover assist unavailable")

type Manager struct {
	options    Options
	mu         sync.RWMutex
	status     *dish.MWANStatus
	lastActive []string
	haveActive bool
}

func NewManager(options Options) *Manager {
	if options.Runner == nil {
		options.Runner = commandRunner{}
	}
	if options.Interval <= 0 {
		options.Interval = time.Minute
	}
	if options.Now == nil {
		options.Now = time.Now
	}
	if options.GLManaged == nil {
		// GL-X3000 firmware 4.8.3 was verified to use kmwan. Keep the legacy
		// mwan signals as well for older GL.iNet firmware.
		options.GLManaged = func(ctx context.Context) bool {
			return detectGLManaged(ctx, options.Runner, func(path string) bool {
				_, err := os.Stat(path)
				return err == nil
			})
		}
	}
	return &Manager{options: options}
}

func detectGLManaged(ctx context.Context, runner Runner, pathExists func(string) bool) bool {
	for _, path := range []string{"/etc/config/mwan", "/etc/config/kmwan"} {
		if pathExists(path) {
			return true
		}
	}
	for _, object := range []string{"mwan", "hotplug.kmwan"} {
		output, err := runner.Run(ctx, "ubus", []string{"list", object}, "")
		if err == nil && strings.TrimSpace(string(output)) != "" {
			return true
		}
	}
	return false
}

func (m *Manager) Run(ctx context.Context) {
	m.Refresh(ctx)
	ticker := time.NewTicker(m.options.Interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			m.Refresh(ctx)
		}
	}
}

func (m *Manager) Snapshot() *dish.MWANStatus {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return cloneStatus(m.status)
}

func (m *Manager) Refresh(ctx context.Context) *dish.MWANStatus {
	output, err := m.options.Runner.Run(ctx, "ubus", []string{"call", "mwan3", "status"}, "")
	var status *dish.MWANStatus
	if err == nil {
		status = parseUbusStatus(output)
	}
	if status == nil {
		output, err = m.options.Runner.Run(ctx, "mwan3", []string{"interfaces"}, "")
		if err == nil {
			status = parseTextStatus(string(output))
		}
	}
	m.mu.Lock()
	if status != nil {
		active := normalizedActive(status)
		if m.haveActive && strings.Join(active, "\x00") != strings.Join(m.lastActive, "\x00") && status.LastSwitch == nil {
			status.LastSwitch = &dish.MWANLastSwitch{From: strings.Join(m.lastActive, ","), To: strings.Join(active, ","), At: m.options.Now().Unix()}
		}
		m.lastActive, m.haveActive = active, true
	}
	m.status = cloneStatus(status)
	m.mu.Unlock()
	return cloneStatus(status)
}

func (m *Manager) Assist(ctx context.Context, primary string) AssistResult {
	status := m.Refresh(ctx)
	if status == nil {
		return AssistResult{Reason: "mwan3 is not installed", Proposed: []Change{}}
	}
	configOutput, _ := m.options.Runner.Run(ctx, "uci", []string{"show", "mwan3"}, "")
	if hasCustomConfig(string(configOutput)) {
		return AssistResult{Reason: "non-Starwatch mwan3 configuration exists", Proposed: []Change{}}
	}
	interfaces := []string{}
	if m.options.Interfaces != nil {
		interfaces = append(interfaces, m.options.Interfaces(ctx)...)
	} else {
		for _, item := range status.Interfaces {
			interfaces = append(interfaces, item.Name)
		}
	}
	interfaces = uniqueSorted(interfaces)
	if len(interfaces) < 2 {
		return AssistResult{Reason: "at least two WAN interfaces are required", Proposed: []Change{}}
	}
	if m.options.GLManaged(ctx) {
		return AssistResult{Reason: "GL.iNet multi-WAN is managing failover", Proposed: []Change{}}
	}
	backup := ""
	for _, name := range interfaces {
		if name != primary {
			backup = name
			break
		}
	}
	if primary == "" || backup == "" {
		return AssistResult{Reason: "at least two WAN interfaces are required", Proposed: []Change{}}
	}
	return AssistResult{Available: true, Proposed: proposedChanges(primary, backup, hasPristineDefaultRule(string(configOutput)))}
}

func (m *Manager) Apply(ctx context.Context, primary string) error {
	result := m.Assist(ctx, primary)
	if !result.Available {
		return fmt.Errorf("%w: %s", ErrAssistUnavailable, result.Reason)
	}
	batch := renderBatch(result.Proposed)
	if _, err := m.options.Runner.Run(ctx, "uci", []string{"batch"}, batch); err != nil {
		return err
	}
	if _, err := m.options.Runner.Run(ctx, "mwan3", []string{"restart"}, ""); err != nil {
		return err
	}
	m.Refresh(ctx)
	return nil
}

func proposedChanges(primary, backup string, replaceExampleRule bool) []Change {
	changes := []Change{
		{Package: "mwan3", Section: primary, Value: "interface"},
		{Package: "mwan3", Section: primary, Option: "enabled", Value: "1"},
		{Package: "mwan3", Section: primary, Option: "family", Value: "ipv4"},
		{Package: "mwan3", Section: primary, Option: "track_ip", Value: "1.1.1.1"},
		{Package: "mwan3", Section: primary, Option: "track_ip", Value: "8.8.8.8"},
		{Package: "mwan3", Section: primary, Option: "reliability", Value: "1"},
		{Package: "mwan3", Section: backup, Value: "interface"},
		{Package: "mwan3", Section: backup, Option: "enabled", Value: "1"},
		{Package: "mwan3", Section: backup, Option: "family", Value: "ipv4"},
		{Package: "mwan3", Section: backup, Option: "track_ip", Value: "1.1.1.1"},
		{Package: "mwan3", Section: backup, Option: "track_ip", Value: "8.8.8.8"},
		{Package: "mwan3", Section: backup, Option: "reliability", Value: "1"},
		{Package: "mwan3", Section: "starwatch_primary_m1", Value: "member"},
		{Package: "mwan3", Section: "starwatch_primary_m1", Option: "interface", Value: primary},
		{Package: "mwan3", Section: "starwatch_primary_m1", Option: "metric", Value: "1"},
		{Package: "mwan3", Section: "starwatch_primary_m1", Option: "weight", Value: "1"},
		{Package: "mwan3", Section: "starwatch_backup_m2", Value: "member"},
		{Package: "mwan3", Section: "starwatch_backup_m2", Option: "interface", Value: backup},
		{Package: "mwan3", Section: "starwatch_backup_m2", Option: "metric", Value: "2"},
		{Package: "mwan3", Section: "starwatch_backup_m2", Option: "weight", Value: "1"},
		{Package: "mwan3", Section: "starwatch_failover", Value: "policy"},
		{Package: "mwan3", Section: "starwatch_failover", Option: "use_member", Value: "starwatch_primary_m1"},
		{Package: "mwan3", Section: "starwatch_failover", Option: "use_member", Value: "starwatch_backup_m2"},
		{Package: "mwan3", Section: "starwatch_default", Value: "rule"},
		{Package: "mwan3", Section: "starwatch_default", Option: "dest_ip", Value: "0.0.0.0/0"},
		{Package: "mwan3", Section: "starwatch_default", Option: "use_policy", Value: "starwatch_failover"},
	}
	// The GL coexistence guard and this generated shape were verified on a
	// GL-X3000 running firmware 4.8.3; generic OpenWrt remains supported.
	if replaceExampleRule {
		changes = append(changes, Change{Package: "mwan3", Section: "default_rule_v4", Option: "enabled", Value: "0"})
	}
	return changes
}

func renderBatch(changes []Change) string {
	counts := make(map[string]int)
	for _, change := range changes {
		if change.Option != "" {
			counts[change.Section+"\x00"+change.Option]++
		}
	}
	var result strings.Builder
	seen := make(map[string]int)
	for _, change := range changes {
		path := change.Package + "." + change.Section
		verb := "set"
		if change.Option != "" {
			path += "." + change.Option
			key := change.Section + "\x00" + change.Option
			if counts[key] > 1 && seen[key] > 0 {
				verb = "add_list"
			}
			seen[key]++
		}
		fmt.Fprintf(&result, "%s %s='%s'\n", verb, path, strings.ReplaceAll(change.Value, "'", "'\\''"))
	}
	result.WriteString("commit mwan3\n")
	return result.String()
}

func hasCustomConfig(output string) bool {
	for _, line := range strings.Split(output, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "mwan3.") || !strings.Contains(line, "=") {
			continue
		}
		path, rawValue, _ := strings.Cut(strings.TrimPrefix(line, "mwan3."), "=")
		section, option, _ := strings.Cut(path, ".")
		if section == "globals" || strings.HasPrefix(section, "starwatch_") {
			continue
		}
		options, ok := pristineOpenWrtExample[section]
		if !ok || options[option] != canonicalUCIValue(rawValue) {
			return true
		}
	}
	return false
}

func hasPristineDefaultRule(output string) bool {
	for _, line := range strings.Split(output, "\n") {
		if strings.TrimSpace(line) == "mwan3.default_rule_v4=rule" {
			return true
		}
	}
	return false
}

func canonicalUCIValue(raw string) string {
	fields := strings.Fields(raw)
	for index := range fields {
		fields[index] = strings.Trim(fields[index], "'\"")
	}
	return strings.Join(fields, " ")
}

var pristineOpenWrtExample = map[string]map[string]string{
	"wan": {
		"": "interface", "enabled": "1", "family": "ipv4", "reliability": "2", "track_ip": "1.0.0.1 1.1.1.1 208.67.222.222 208.67.220.220",
	},
	"wan6": {
		"": "interface", "enabled": "0", "family": "ipv6", "reliability": "2", "track_ip": "2606:4700:4700::1001 2606:4700:4700::1111 2620:0:ccd::2 2620:0:ccc::2",
	},
	"wanb": {
		"": "interface", "enabled": "0", "family": "ipv4", "reliability": "1", "track_ip": "1.0.0.1 1.1.1.1 208.67.222.222 208.67.220.220",
	},
	"wanb6": {
		"": "interface", "enabled": "0", "family": "ipv6", "reliability": "1", "track_ip": "2606:4700:4700::1001 2606:4700:4700::1111 2620:0:ccd::2 2620:0:ccc::2",
	},
	"wan_m1_w3": {
		"": "member", "interface": "wan", "metric": "1", "weight": "3",
	},
	"wan_m2_w3": {
		"": "member", "interface": "wan", "metric": "2", "weight": "3",
	},
	"wanb_m1_w2": {
		"": "member", "interface": "wanb", "metric": "1", "weight": "2",
	},
	"wanb_m1_w3": {
		"": "member", "interface": "wanb", "metric": "1", "weight": "3",
	},
	"wanb_m2_w2": {
		"": "member", "interface": "wanb", "metric": "2", "weight": "2",
	},
	"wan6_m1_w3": {
		"": "member", "interface": "wan6", "metric": "1", "weight": "3",
	},
	"wan6_m2_w3": {
		"": "member", "interface": "wan6", "metric": "2", "weight": "3",
	},
	"wanb6_m1_w2": {
		"": "member", "interface": "wanb6", "metric": "1", "weight": "2",
	},
	"wanb6_m1_w3": {
		"": "member", "interface": "wanb6", "metric": "1", "weight": "3",
	},
	"wanb6_m2_w2": {
		"": "member", "interface": "wanb6", "metric": "2", "weight": "2",
	},
	"wan_only": {
		"": "policy", "use_member": "wan_m1_w3 wan6_m1_w3",
	},
	"wanb_only": {
		"": "policy", "use_member": "wanb_m1_w2 wanb6_m1_w2",
	},
	"balanced": {
		"": "policy", "use_member": "wan_m1_w3 wanb_m1_w3 wan6_m1_w3 wanb6_m1_w3",
	},
	"wan_wanb": {
		"": "policy", "use_member": "wan_m1_w3 wanb_m2_w2 wan6_m1_w3 wanb6_m2_w2",
	},
	"wanb_wan": {
		"": "policy", "use_member": "wan_m2_w3 wanb_m1_w2 wan6_m2_w3 wanb6_m1_w2",
	},
	"https": {
		"": "rule", "sticky": "1", "dest_port": "443", "proto": "tcp", "use_policy": "balanced",
	},
	"default_rule_v4": {
		"": "rule", "dest_ip": "0.0.0.0/0", "use_policy": "balanced", "family": "ipv4",
	},
	"default_rule_v6": {
		"": "rule", "dest_ip": "::/0", "use_policy": "balanced", "family": "ipv6",
	},
}

func parseUbusStatus(data []byte) *dish.MWANStatus {
	var raw struct {
		Interfaces map[string]struct {
			Status   string `json:"status"`
			Tracking string `json:"tracking"`
		} `json:"interfaces"`
		ActivePolicy     string               `json:"active_policy"`
		ActiveInterfaces []string             `json:"active_interfaces"`
		LastSwitch       *dish.MWANLastSwitch `json:"last_switch"`
	}
	if json.Unmarshal(data, &raw) != nil || len(raw.Interfaces) == 0 {
		return nil
	}
	result := &dish.MWANStatus{ActivePolicy: raw.ActivePolicy, ActiveInterfaces: raw.ActiveInterfaces, LastSwitch: raw.LastSwitch}
	for name, item := range raw.Interfaces {
		result.Interfaces = append(result.Interfaces, dish.MWANInterface{Name: name, State: item.Status, Tracking: item.Tracking, Online: strings.EqualFold(item.Status, "online")})
	}
	sort.Slice(result.Interfaces, func(i, j int) bool { return result.Interfaces[i].Name < result.Interfaces[j].Name })
	return result
}

func parseTextStatus(output string) *dish.MWANStatus {
	result := &dish.MWANStatus{}
	for _, line := range strings.Split(output, "\n") {
		fields := strings.Fields(strings.TrimSpace(line))
		if len(fields) < 4 || fields[0] != "interface" || fields[2] != "is" {
			continue
		}
		item := dish.MWANInterface{Name: fields[1], State: fields[3], Online: fields[3] == "online"}
		if len(fields) >= 8 && fields[5] == "tracking" && fields[6] == "is" {
			item.Tracking = fields[7]
		}
		result.Interfaces = append(result.Interfaces, item)
		if item.Online {
			result.ActiveInterfaces = append(result.ActiveInterfaces, item.Name)
		}
	}
	if len(result.Interfaces) == 0 {
		return nil
	}
	sort.Slice(result.Interfaces, func(i, j int) bool { return result.Interfaces[i].Name < result.Interfaces[j].Name })
	return result
}

func cloneStatus(input *dish.MWANStatus) *dish.MWANStatus {
	if input == nil {
		return nil
	}
	result := *input
	result.Interfaces = append([]dish.MWANInterface(nil), input.Interfaces...)
	result.ActiveInterfaces = append([]string(nil), input.ActiveInterfaces...)
	if input.LastSwitch != nil {
		value := *input.LastSwitch
		result.LastSwitch = &value
	}
	return &result
}

func uniqueSorted(values []string) []string {
	seen := make(map[string]bool)
	var result []string
	for _, value := range values {
		if value != "" && !seen[value] {
			seen[value] = true
			result = append(result, value)
		}
	}
	sort.Strings(result)
	return result
}

func normalizedActive(status *dish.MWANStatus) []string {
	values := append([]string(nil), status.ActiveInterfaces...)
	if len(values) == 0 {
		for _, item := range status.Interfaces {
			if item.Online {
				values = append(values, item.Name)
			}
		}
	}
	return uniqueSorted(values)
}

type commandRunner struct{}

func (commandRunner) Run(ctx context.Context, name string, args []string, stdin string) ([]byte, error) {
	command := exec.CommandContext(ctx, name, args...)
	command.Stdin = bytes.NewBufferString(stdin)
	return command.Output()
}
