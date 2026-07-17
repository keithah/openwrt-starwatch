// Package dishroute maintains the one host route Starwatch is permitted to
// change: the local Starlink dish management address.
package dishroute

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os/exec"
	"strings"
	"time"

	"starwatch/internal/event"
	"starwatch/internal/history"
)

const (
	dishRoute        = "192.168.100.1/32"
	starlinkRouterIP = "192.168.1.1"
)

type Runner interface {
	Run(context.Context, string, []string, string) ([]byte, error)
}

type EventWriter interface {
	AddEvent(history.Event)
}

type Options struct {
	Enabled bool
	Runner  Runner
	Now     func() time.Time
	Events  EventWriter
	Live    event.Publisher
	Logf    func(string, ...any)
}

type Manager struct{ options Options }

func NewManager(options Options) *Manager {
	if options.Runner == nil {
		options.Runner = commandRunner{}
	}
	if options.Now == nil {
		options.Now = time.Now
	}
	if options.Logf == nil {
		options.Logf = func(string, ...any) {}
	}
	return &Manager{options: options}
}

type wanStatus struct {
	Device    string        `json:"device"`
	L3Device  string        `json:"l3_device"`
	Addresses []wanAddress  `json:"ipv4-address"`
	Routes    []statusRoute `json:"route"`
}

type wanAddress struct {
	Address string `json:"address"`
	Mask    int    `json:"mask"`
}

type statusRoute struct {
	Target  string `json:"target"`
	Mask    int    `json:"mask"`
	Nexthop string `json:"nexthop"`
}

type desiredRoute struct {
	Device  string `json:"device"`
	Gateway string `json:"gateway,omitempty"`
}

func (m *Manager) Ensure(ctx context.Context) error {
	if !m.options.Enabled {
		return nil
	}
	desired, err := m.derive(ctx)
	if err != nil {
		return err
	}
	current, _ := m.options.Runner.Run(ctx, "ip", []string{"-4", "route", "show", dishRoute}, "")
	if routeMatches(string(current), desired) {
		return nil
	}
	// A replace updates one matching route, but a VPN can leave additional
	// metric/table variants for this destination. Flush only this exact host
	// prefix before replacing so Starwatch maintains precisely one dish /32.
	if strings.TrimSpace(string(current)) != "" {
		if _, err := m.options.Runner.Run(ctx, "ip", []string{"-4", "route", "flush", dishRoute}, ""); err != nil {
			return fmt.Errorf("flush stale dish host routes: %w", err)
		}
	}
	args := []string{"-4", "route", "replace", dishRoute}
	if desired.Gateway != "" {
		args = append(args, "via", desired.Gateway)
	}
	args = append(args, "dev", desired.Device)
	if desired.Gateway == "" {
		args = append(args, "scope", "link")
	}
	if _, err := m.options.Runner.Run(ctx, "ip", args, ""); err != nil {
		return fmt.Errorf("replace dish host route: %w", err)
	}
	m.recordChange(desired)
	return nil
}

func (m *Manager) derive(ctx context.Context) (desiredRoute, error) {
	output, err := m.options.Runner.Run(ctx, "ubus", []string{"call", "network.interface.wan", "status"}, "")
	if err != nil {
		return desiredRoute{}, fmt.Errorf("read WAN status: %w", err)
	}
	var status wanStatus
	if err := json.Unmarshal(output, &status); err != nil {
		return desiredRoute{}, fmt.Errorf("decode WAN status: %w", err)
	}
	device := status.Device
	if device == "" {
		device = status.L3Device
	}
	if device == "" {
		return desiredRoute{}, fmt.Errorf("WAN status has no device")
	}
	subnets := connectedSubnets(status.Addresses)
	if len(subnets) == 0 {
		return desiredRoute{}, fmt.Errorf("WAN device %s has no IPv4 connected subnet", device)
	}
	hadGateway := false
	for _, route := range status.Routes {
		if route.Nexthop == "" || route.Target != "0.0.0.0" || route.Mask != 0 {
			continue
		}
		hadGateway = true
		if inAnySubnet(net.ParseIP(route.Nexthop), subnets) {
			return desiredRoute{Device: device, Gateway: route.Nexthop}, nil
		}
	}
	if onLinkStarlinkRouter(ctx, m.options.Runner, device) {
		return desiredRoute{Device: device, Gateway: starlinkRouterIP}, nil
	}
	if !hadGateway {
		return desiredRoute{Device: device}, nil
	}
	return desiredRoute{}, fmt.Errorf("WAN gateway is not on-link on %s", device)
}

func connectedSubnets(addresses []wanAddress) []*net.IPNet {
	result := make([]*net.IPNet, 0, len(addresses))
	for _, item := range addresses {
		ip := net.ParseIP(item.Address).To4()
		if ip == nil || item.Mask < 0 || item.Mask > 32 {
			continue
		}
		mask := net.CIDRMask(item.Mask, 32)
		result = append(result, &net.IPNet{IP: ip.Mask(mask), Mask: mask})
	}
	return result
}

func inAnySubnet(ip net.IP, subnets []*net.IPNet) bool {
	if ip == nil {
		return false
	}
	for _, subnet := range subnets {
		if subnet.Contains(ip) {
			return true
		}
	}
	return false
}

func onLinkStarlinkRouter(ctx context.Context, runner Runner, device string) bool {
	output, err := runner.Run(ctx, "ip", []string{"-4", "route", "get", starlinkRouterIP}, "")
	if err != nil {
		return false
	}
	fields := strings.Fields(string(output))
	hasDevice := false
	for index, field := range fields {
		if field == "via" {
			return false
		}
		if field == "dev" && index+1 < len(fields) && fields[index+1] == device {
			hasDevice = true
		}
	}
	return hasDevice
}

func routeMatches(output string, desired desiredRoute) bool {
	lines := strings.Split(strings.TrimSpace(output), "\n")
	if len(lines) != 1 || strings.TrimSpace(lines[0]) == "" {
		return false
	}
	fields := strings.Fields(lines[0])
	if len(fields) == 0 || fields[0] != dishRoute && fields[0] != "192.168.100.1" {
		return false
	}
	device, gateway := "", ""
	for index, field := range fields {
		if index+1 >= len(fields) {
			continue
		}
		switch field {
		case "dev":
			device = fields[index+1]
		case "via":
			gateway = fields[index+1]
		}
	}
	return device == desired.Device && gateway == desired.Gateway
}

func (m *Manager) recordChange(route desiredRoute) {
	at := m.options.Now()
	detail, _ := json.Marshal(struct {
		Route   string `json:"route"`
		Device  string `json:"device"`
		Gateway string `json:"gateway,omitempty"`
	}{Route: dishRoute, Device: route.Device, Gateway: route.Gateway})
	m.options.Logf("starwatchd: replaced dish route %s via %s dev %s", dishRoute, routeGatewayLabel(route.Gateway), route.Device)
	if m.options.Events != nil {
		m.options.Events.AddEvent(history.Event{At: at, Kind: "dish_route", Detail: string(detail)})
	}
	if m.options.Live != nil {
		m.options.Live.Publish(event.Message{Kind: "dish_route", At: at, Data: route})
	}
}

func routeGatewayLabel(gateway string) string {
	if gateway == "" {
		return "link-scope"
	}
	return gateway
}

type commandRunner struct{}

func (commandRunner) Run(ctx context.Context, name string, args []string, stdin string) ([]byte, error) {
	command := exec.CommandContext(ctx, name, args...)
	if stdin != "" {
		command.Stdin = strings.NewReader(stdin)
	}
	return command.Output()
}
