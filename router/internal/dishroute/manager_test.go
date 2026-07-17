package dishroute

import (
	"context"
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"testing"
	"time"

	"starwatch/internal/event"
	"starwatch/internal/history"
)

type command struct {
	name  string
	args  []string
	stdin string
}

type fakeRunner struct {
	status       string
	routeGet     string
	currentRoute string
	commands     []command
}

func (r *fakeRunner) Run(_ context.Context, name string, args []string, stdin string) ([]byte, error) {
	r.commands = append(r.commands, command{name: name, args: append([]string(nil), args...), stdin: stdin})
	switch {
	case name == "ubus":
		return []byte(r.status), nil
	case name == "ip" && reflect.DeepEqual(args, []string{"-4", "route", "get", starlinkRouterIP}):
		return []byte(r.routeGet), nil
	case name == "ip" && reflect.DeepEqual(args, []string{"-4", "route", "show", dishRoute}):
		return []byte(r.currentRoute), nil
	case name == "ip" && reflect.DeepEqual(args, []string{"-4", "route", "flush", dishRoute}):
		return nil, nil
	case name == "ip" && len(args) >= 4 && args[2] == "replace":
		return nil, nil
	default:
		return nil, fmt.Errorf("unexpected command: %s %v", name, args)
	}
}

func wanStatusJSON(device, address string, mask int, gateways ...string) string {
	routes := make([]map[string]any, 0, len(gateways))
	for _, gateway := range gateways {
		routes = append(routes, map[string]any{"target": "0.0.0.0", "mask": 0, "nexthop": gateway})
	}
	encoded, _ := json.Marshal(map[string]any{
		"device": device, "l3_device": device,
		"ipv4-address": []map[string]any{{"address": address, "mask": mask}},
		"route":        routes,
	})
	return string(encoded)
}

func replaceCommands(runner *fakeRunner) []command {
	var result []command
	for _, item := range runner.commands {
		if item.name == "ip" && len(item.args) >= 4 && item.args[2] == "replace" {
			result = append(result, item)
		}
	}
	return result
}

func TestEnsureRejectsSpeedifyGatewayAndUsesOnLinkStarlinkRouter(t *testing.T) {
	runner := &fakeRunner{
		status:   wanStatusJSON("eth0", "192.168.1.49", 24, "192.0.0.1"),
		routeGet: "192.168.1.1 dev eth0 src 192.168.1.49 uid 0\n",
	}
	manager := NewManager(Options{Enabled: true, Runner: runner})
	if err := manager.Ensure(context.Background()); err != nil {
		t.Fatal(err)
	}
	want := []string{"-4", "route", "replace", dishRoute, "via", starlinkRouterIP, "dev", "eth0"}
	if got := replaceCommands(runner); len(got) != 1 || !reflect.DeepEqual(got[0].args, want) {
		t.Fatalf("replace commands=%v want=%v", got, want)
	}
}

func TestEnsurePrefersConfiguredGatewayWhenItIsOnLink(t *testing.T) {
	runner := &fakeRunner{status: wanStatusJSON("eth0", "192.168.1.49", 24, "192.168.1.254")}
	manager := NewManager(Options{Enabled: true, Runner: runner})
	if err := manager.Ensure(context.Background()); err != nil {
		t.Fatal(err)
	}
	want := []string{"-4", "route", "replace", dishRoute, "via", "192.168.1.254", "dev", "eth0"}
	if got := replaceCommands(runner); len(got) != 1 || !reflect.DeepEqual(got[0].args, want) {
		t.Fatalf("replace commands=%v", got)
	}
}

func TestEnsureUsesLinkScopeOnlyWhenWANHasNoGateway(t *testing.T) {
	runner := &fakeRunner{status: wanStatusJSON("eth0", "100.64.1.2", 24), routeGet: "192.168.1.1 via 100.64.1.1 dev eth0\n"}
	manager := NewManager(Options{Enabled: true, Runner: runner})
	if err := manager.Ensure(context.Background()); err != nil {
		t.Fatal(err)
	}
	want := []string{"-4", "route", "replace", dishRoute, "dev", "eth0", "scope", "link"}
	if got := replaceCommands(runner); len(got) != 1 || !reflect.DeepEqual(got[0].args, want) {
		t.Fatalf("replace commands=%v", got)
	}
}

func TestEnsureDoesNotWriteWhenDisabled(t *testing.T) {
	runner := &fakeRunner{status: wanStatusJSON("eth0", "192.168.1.49", 24, "192.168.1.1")}
	manager := NewManager(Options{Enabled: false, Runner: runner})
	if err := manager.Ensure(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(runner.commands) != 0 {
		t.Fatalf("disabled commands=%v", runner.commands)
	}
}

func TestEnsureIsIdempotentWhenExactRouteMatches(t *testing.T) {
	runner := &fakeRunner{status: wanStatusJSON("eth0", "192.168.1.49", 24, "192.168.1.1"), currentRoute: "192.168.100.1 via 192.168.1.1 dev eth0\n"}
	manager := NewManager(Options{Enabled: true, Runner: runner})
	if err := manager.Ensure(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := replaceCommands(runner); len(got) != 0 {
		t.Fatalf("unexpected replace=%v", got)
	}
}

func TestEnsureFlushesDuplicateDishRoutesBeforeReplacing(t *testing.T) {
	runner := &fakeRunner{
		status: wanStatusJSON("eth0", "192.168.1.49", 24, "192.168.1.1"),
		currentRoute: "192.168.100.1 via 192.168.1.1 dev eth0 metric 10\n" +
			"192.168.100.1 via 192.0.0.1 dev connectify0 metric 20\n",
	}
	manager := NewManager(Options{Enabled: true, Runner: runner})
	if err := manager.Ensure(context.Background()); err != nil {
		t.Fatal(err)
	}
	var flushed bool
	for _, item := range runner.commands {
		if item.name == "ip" && reflect.DeepEqual(item.args, []string{"-4", "route", "flush", dishRoute}) {
			flushed = true
		}
	}
	if !flushed || len(replaceCommands(runner)) != 1 {
		t.Fatalf("commands=%v", runner.commands)
	}
}

type eventSink struct{ items []history.Event }

func (s *eventSink) AddEvent(item history.Event) { s.items = append(s.items, item) }

func TestEnsureLogsAndEmitsDishRouteEventOnlyOnChange(t *testing.T) {
	now := time.Date(2026, 7, 17, 12, 0, 0, 0, time.UTC)
	runner := &fakeRunner{status: wanStatusJSON("eth0", "192.168.1.49", 24, "192.168.1.1")}
	sink := &eventSink{}
	bus := event.NewBus()
	subscription, unsubscribe := bus.Subscribe(1)
	defer unsubscribe()
	var logs []string
	manager := NewManager(Options{Enabled: true, Runner: runner, Now: func() time.Time { return now }, Events: sink, Live: bus, Logf: func(format string, args ...any) { logs = append(logs, fmt.Sprintf(format, args...)) }})
	if err := manager.Ensure(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(logs) != 1 || !strings.Contains(logs[0], dishRoute) || !strings.Contains(logs[0], "192.168.1.1") {
		t.Fatalf("logs=%v", logs)
	}
	if len(sink.items) != 1 || sink.items[0].Kind != "dish_route" || sink.items[0].At != now || !strings.Contains(sink.items[0].Detail, dishRoute) {
		t.Fatalf("events=%+v", sink.items)
	}
	select {
	case message := <-subscription:
		if message.Kind != "dish_route" || message.At != now {
			t.Fatalf("live event=%+v", message)
		}
	default:
		t.Fatal("missing live event")
	}
	for _, item := range replaceCommands(runner) {
		if !containsExactRoute(item.args) {
			t.Fatalf("route write escaped exact host route: %v", item.args)
		}
	}
}

func containsExactRoute(args []string) bool {
	for _, arg := range args {
		if arg == dishRoute {
			return true
		}
	}
	return false
}
