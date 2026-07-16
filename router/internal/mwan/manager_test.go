package mwan

import (
	"context"
	"errors"
	"strings"
	"testing"
)

type fakeRunner struct {
	outputs  map[string]string
	errors   map[string]error
	commands []string
	stdin    []string
}

func (r *fakeRunner) Run(_ context.Context, name string, args []string, stdin string) ([]byte, error) {
	key := name + " " + strings.Join(args, " ")
	r.commands = append(r.commands, key)
	r.stdin = append(r.stdin, stdin)
	return []byte(r.outputs[key]), r.errors[key]
}

func TestRefreshParsesUbusAndFallsBackToText(t *testing.T) {
	for name, runner := range map[string]*fakeRunner{
		"ubus": {outputs: map[string]string{"ubus call mwan3 status": `{"interfaces":{"wan":{"status":"online","tracking":"active"},"wwan":{"status":"offline","tracking":"down"}},"active_policy":"starwatch_failover","active_interfaces":["wan"],"last_switch":{"from":"wwan","to":"wan","at":123}}`}},
		"text": {outputs: map[string]string{"mwan3 interfaces": "Interface status:\n interface wan is online and tracking is active\n interface wwan is offline and tracking is down\n"}, errors: map[string]error{"ubus call mwan3 status": errors.New("no object")}},
	} {
		t.Run(name, func(t *testing.T) {
			manager := NewManager(Options{Runner: runner})
			status := manager.Refresh(context.Background())
			if status == nil || len(status.Interfaces) != 2 || status.Interfaces[0].Name != "wan" || !status.Interfaces[0].Online || status.Interfaces[1].Online {
				t.Fatalf("status=%+v", status)
			}
			if name == "ubus" && (status.ActivePolicy != "starwatch_failover" || status.LastSwitch == nil || status.LastSwitch.To != "wan") {
				t.Fatalf("ubus details=%+v", status)
			}
		})
	}
}

func TestRefreshOmitsMwanWhenAbsent(t *testing.T) {
	runner := &fakeRunner{errors: map[string]error{"ubus call mwan3 status": errors.New("missing"), "mwan3 interfaces": errors.New("missing")}}
	if status := NewManager(Options{Runner: runner}).Refresh(context.Background()); status != nil {
		t.Fatalf("status=%+v", status)
	}
}

func TestAssistAvailabilityMatrix(t *testing.T) {
	base := func() *fakeRunner {
		return &fakeRunner{outputs: map[string]string{"ubus call mwan3 status": `{"interfaces":{"wan":{"status":"online"},"wwan":{"status":"online"}}}`, "uci show mwan3": ""}, errors: map[string]error{}}
	}
	tests := []struct {
		name, reason string
		setup        func(*fakeRunner) Options
	}{
		{"absent", "mwan3 is not installed", func(r *fakeRunner) Options {
			r.errors["ubus call mwan3 status"] = errors.New("missing")
			r.errors["mwan3 interfaces"] = errors.New("missing")
			return Options{Runner: r, GLManaged: func(context.Context) bool { return false }}
		}},
		{"custom", "non-Starwatch mwan3 configuration exists", func(r *fakeRunner) Options {
			r.outputs["uci show mwan3"] = "mwan3.custom=member\n"
			return Options{Runner: r, Interfaces: func(context.Context) []string { return []string{"wan", "wwan"} }, GLManaged: func(context.Context) bool { return false }}
		}},
		{"one-interface", "at least two WAN interfaces are required", func(r *fakeRunner) Options {
			return Options{Runner: r, Interfaces: func(context.Context) []string { return []string{"wan"} }, GLManaged: func(context.Context) bool { return false }}
		}},
		{"gl", "GL.iNet multi-WAN is managing failover", func(r *fakeRunner) Options {
			return Options{Runner: r, Interfaces: func(context.Context) []string { return []string{"wan", "wwan"} }, GLManaged: func(context.Context) bool { return true }}
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			runner := base()
			manager := NewManager(test.setup(runner))
			result := manager.Assist(context.Background(), "wan")
			if result.Available || result.Reason != test.reason {
				t.Fatalf("result=%+v", result)
			}
		})
	}
}

func TestAssistAppliesExactlyProposedStarwatchChanges(t *testing.T) {
	runner := &fakeRunner{outputs: map[string]string{"ubus call mwan3 status": `{"interfaces":{"wan":{"status":"online"},"wwan":{"status":"online"}}}`, "uci show mwan3": ""}, errors: map[string]error{}}
	manager := NewManager(Options{Runner: runner, Interfaces: func(context.Context) []string { return []string{"wwan", "wan"} }, GLManaged: func(context.Context) bool { return false }})
	result := manager.Assist(context.Background(), "wan")
	if !result.Available || len(result.Proposed) == 0 {
		t.Fatalf("result=%+v", result)
	}
	for _, change := range result.Proposed {
		if change.Package != "mwan3" || !strings.HasPrefix(change.Section, "starwatch_") {
			t.Fatalf("unsafe change=%+v", change)
		}
	}
	if err := manager.Apply(context.Background(), "wan"); err != nil {
		t.Fatal(err)
	}
	batchIndex := -1
	for index, command := range runner.commands {
		if command == "uci batch" {
			batchIndex = index
		}
	}
	if batchIndex < 0 || batchIndex+1 >= len(runner.commands) || runner.commands[batchIndex+1] != "mwan3 restart" || !strings.Contains(runner.stdin[batchIndex], "starwatch_primary") {
		t.Fatalf("commands=%#v stdin=%#v", runner.commands, runner.stdin)
	}
}
