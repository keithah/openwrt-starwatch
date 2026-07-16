package mwan

import (
	"context"
	"errors"
	"strings"
	"testing"
)

const pristineOpenWrtMwan3 = `mwan3.globals=globals
mwan3.globals.mmx_mask='0x3F00'
mwan3.wan=interface
mwan3.wan.enabled='1'
mwan3.wan.track_ip='1.0.0.1' '1.1.1.1' '208.67.222.222' '208.67.220.220'
mwan3.wan.family='ipv4'
mwan3.wan.reliability='2'
mwan3.wan6=interface
mwan3.wan6.enabled='0'
mwan3.wan6.track_ip='2606:4700:4700::1001' '2606:4700:4700::1111' '2620:0:ccd::2' '2620:0:ccc::2'
mwan3.wan6.family='ipv6'
mwan3.wan6.reliability='2'
mwan3.wanb=interface
mwan3.wanb.enabled='0'
mwan3.wanb.track_ip='1.0.0.1' '1.1.1.1' '208.67.222.222' '208.67.220.220'
mwan3.wanb.family='ipv4'
mwan3.wanb.reliability='1'
mwan3.wanb6=interface
mwan3.wanb6.enabled='0'
mwan3.wanb6.track_ip='2606:4700:4700::1001' '2606:4700:4700::1111' '2620:0:ccd::2' '2620:0:ccc::2'
mwan3.wanb6.family='ipv6'
mwan3.wanb6.reliability='1'
mwan3.wan_m1_w3=member
mwan3.wan_m1_w3.interface='wan'
mwan3.wan_m1_w3.metric='1'
mwan3.wan_m1_w3.weight='3'
mwan3.wan_m2_w3=member
mwan3.wan_m2_w3.interface='wan'
mwan3.wan_m2_w3.metric='2'
mwan3.wan_m2_w3.weight='3'
mwan3.wanb_m1_w2=member
mwan3.wanb_m1_w2.interface='wanb'
mwan3.wanb_m1_w2.metric='1'
mwan3.wanb_m1_w2.weight='2'
mwan3.wanb_m1_w3=member
mwan3.wanb_m1_w3.interface='wanb'
mwan3.wanb_m1_w3.metric='1'
mwan3.wanb_m1_w3.weight='3'
mwan3.wanb_m2_w2=member
mwan3.wanb_m2_w2.interface='wanb'
mwan3.wanb_m2_w2.metric='2'
mwan3.wanb_m2_w2.weight='2'
mwan3.wan6_m1_w3=member
mwan3.wan6_m1_w3.interface='wan6'
mwan3.wan6_m1_w3.metric='1'
mwan3.wan6_m1_w3.weight='3'
mwan3.wan6_m2_w3=member
mwan3.wan6_m2_w3.interface='wan6'
mwan3.wan6_m2_w3.metric='2'
mwan3.wan6_m2_w3.weight='3'
mwan3.wanb6_m1_w2=member
mwan3.wanb6_m1_w2.interface='wanb6'
mwan3.wanb6_m1_w2.metric='1'
mwan3.wanb6_m1_w2.weight='2'
mwan3.wanb6_m1_w3=member
mwan3.wanb6_m1_w3.interface='wanb6'
mwan3.wanb6_m1_w3.metric='1'
mwan3.wanb6_m1_w3.weight='3'
mwan3.wanb6_m2_w2=member
mwan3.wanb6_m2_w2.interface='wanb6'
mwan3.wanb6_m2_w2.metric='2'
mwan3.wanb6_m2_w2.weight='2'
mwan3.wan_only=policy
mwan3.wan_only.use_member='wan_m1_w3' 'wan6_m1_w3'
mwan3.wanb_only=policy
mwan3.wanb_only.use_member='wanb_m1_w2' 'wanb6_m1_w2'
mwan3.balanced=policy
mwan3.balanced.use_member='wan_m1_w3' 'wanb_m1_w3' 'wan6_m1_w3' 'wanb6_m1_w3'
mwan3.wan_wanb=policy
mwan3.wan_wanb.use_member='wan_m1_w3' 'wanb_m2_w2' 'wan6_m1_w3' 'wanb6_m2_w2'
mwan3.wanb_wan=policy
mwan3.wanb_wan.use_member='wan_m2_w3' 'wanb_m1_w2' 'wan6_m2_w3' 'wanb6_m1_w2'
mwan3.https=rule
mwan3.https.sticky='1'
mwan3.https.dest_port='443'
mwan3.https.proto='tcp'
mwan3.https.use_policy='balanced'
mwan3.default_rule_v4=rule
mwan3.default_rule_v4.dest_ip='0.0.0.0/0'
mwan3.default_rule_v4.use_policy='balanced'
mwan3.default_rule_v4.family='ipv4'
mwan3.default_rule_v6=rule
mwan3.default_rule_v6.dest_ip='::/0'
mwan3.default_rule_v6.use_policy='balanced'
mwan3.default_rule_v6.family='ipv6'
`

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

func TestAssistAcceptsPristineOpenWrtExample(t *testing.T) {
	runner := &fakeRunner{outputs: map[string]string{
		"ubus call mwan3 status": `{"interfaces":{"wan":{"status":"online"},"wanb":{"status":"online"}}}`,
		"uci show mwan3":         pristineOpenWrtMwan3,
	}, errors: map[string]error{}}
	manager := NewManager(Options{
		Runner: runner,
		Interfaces: func(context.Context) []string {
			return []string{"wan", "wanb"}
		},
		GLManaged: func(context.Context) bool { return false },
	})

	result := manager.Assist(context.Background(), "wan")
	if !result.Available || result.Reason != "" {
		t.Fatalf("Assist()=%+v", result)
	}
	assertProposedChange(t, result.Proposed, Change{Package: "mwan3", Section: "default_rule_v4", Option: "enabled", Value: "0"})
	for _, section := range []string{"wan", "wanb"} {
		assertProposedChange(t, result.Proposed, Change{Package: "mwan3", Section: section, Value: "interface"})
		assertProposedChange(t, result.Proposed, Change{Package: "mwan3", Section: section, Option: "enabled", Value: "1"})
		assertProposedChange(t, result.Proposed, Change{Package: "mwan3", Section: section, Option: "family", Value: "ipv4"})
		assertProposedChange(t, result.Proposed, Change{Package: "mwan3", Section: section, Option: "reliability", Value: "1"})
		if got := proposedValues(result.Proposed, section, "track_ip"); strings.Join(got, ",") != "1.1.1.1,8.8.8.8" {
			t.Fatalf("%s track_ip=%v", section, got)
		}
	}
}

func TestAssistRefusesCustomizedOpenWrtExample(t *testing.T) {
	customized := strings.Replace(pristineOpenWrtMwan3, "mwan3.wan_m1_w3.weight='3'", "mwan3.wan_m1_w3.weight='9'", 1)
	runner := &fakeRunner{outputs: map[string]string{
		"ubus call mwan3 status": `{"interfaces":{"wan":{"status":"online"},"wanb":{"status":"online"}}}`,
		"uci show mwan3":         customized,
	}, errors: map[string]error{}}
	manager := NewManager(Options{
		Runner:     runner,
		Interfaces: func(context.Context) []string { return []string{"wan", "wanb"} },
		GLManaged:  func(context.Context) bool { return false },
	})

	result := manager.Assist(context.Background(), "wan")
	if result.Available || result.Reason != "non-Starwatch mwan3 configuration exists" {
		t.Fatalf("Assist()=%+v", result)
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
		allowedInterface := change.Section == "wan" || change.Section == "wwan"
		if change.Package != "mwan3" || (!strings.HasPrefix(change.Section, "starwatch_") && !allowedInterface) {
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
	batch := runner.stdin[batchIndex]
	if !strings.Contains(batch, "set mwan3.wan.track_ip='1.1.1.1'") || !strings.Contains(batch, "add_list mwan3.wan.track_ip='8.8.8.8'") {
		t.Fatalf("track_ip list is not replaced deterministically:\n%s", batch)
	}
}

func assertProposedChange(t *testing.T, changes []Change, want Change) {
	t.Helper()
	for _, change := range changes {
		if change == want {
			return
		}
	}
	t.Fatalf("missing proposed change %+v in %+v", want, changes)
}

func proposedValues(changes []Change, section, option string) []string {
	var values []string
	for _, change := range changes {
		if change.Section == section && change.Option == option {
			values = append(values, change.Value)
		}
	}
	return values
}
