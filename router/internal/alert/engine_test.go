package alert

import (
	"encoding/json"
	"testing"
	"time"

	"starwatch/internal/dish"
	"starwatch/internal/history"
	"starwatch/internal/outage"
)

type notificationSink struct{ notifications []Notification }

func (s *notificationSink) Enqueue(notification Notification) {
	s.notifications = append(s.notifications, notification)
}

type eventSink struct{ events []history.Event }

func (s *eventSink) AddEvent(item history.Event) { s.events = append(s.events, item) }

type memoryStateStore struct {
	data  []byte
	saves int
}

func (s *memoryStateStore) LoadAlertState() ([]byte, error) {
	return append([]byte(nil), s.data...), nil
}

func (s *memoryStateStore) SaveAlertState(data []byte) error {
	s.data = append(s.data[:0], data...)
	s.saves++
	return nil
}

type countingSpanReader struct {
	calls int
	now   time.Time
}

func (r *countingSpanReader) QuerySpan(string, time.Time, time.Duration, int) (history.QueryResult, error) {
	r.calls++
	return history.QueryResult{Tier: history.TierRAM, Points: []history.Point{{Time: r.now, Value: .03}}}, nil
}

func testRules() map[string]Rule {
	rules := DefaultRules()
	rules["path_degraded"] = Rule{Enabled: true, Severity: SeverityWarning, Threshold: .2, Threshold2: 300, ClearHold: 5 * time.Minute}
	return rules
}

func TestCatalogContainsEverySupportedSpecAlertAndSeverities(t *testing.T) {
	rules := DefaultRules()
	want := map[string]Severity{
		"outage_started": SeverityCritical, "dish_unreachable": SeverityCritical,
		"path_degraded": SeverityWarning, "obstruction_high": SeverityWarning,
		"thermal_throttle": SeverityWarning, "thermal_shutdown": SeverityCritical,
		"motors_stuck": SeverityWarning, "water_detected": SeverityWarning,
		"mast_not_vertical": SeverityInfo, "slow_ethernet": SeverityInfo,
		"firmware_pending": SeverityInfo, "failover_event": SeverityWarning,
	}
	if len(rules) != len(want) {
		t.Fatalf("catalog length=%d want=%d: %#v", len(rules), len(want), rules)
	}
	for name, severity := range want {
		if rule, ok := rules[name]; !ok || !rule.Enabled || rule.Severity != severity {
			t.Fatalf("rule %q: %+v present=%v", name, rule, ok)
		}
	}
}

func TestFailoverEventBaselinesThenFiresOncePerActiveSetChangeWithoutClear(t *testing.T) {
	now := time.Date(2026, 7, 16, 12, 0, 0, 0, time.UTC)
	notifications := &notificationSink{}
	rules := map[string]Rule{"failover_event": DefaultRules()["failover_event"]}
	engine := NewEngine(Options{Now: func() time.Time { return now }, Rules: rules, Delivery: notifications})
	inputs := Inputs{WAN: dish.WANStatus{MWAN3: &dish.MWANStatus{ActiveInterfaces: []string{"wan"}}}}
	engine.Tick(inputs)
	engine.Tick(inputs)
	inputs.WAN.MWAN3.ActiveInterfaces = []string{"wwan"}
	engine.Tick(inputs)
	engine.Tick(inputs)
	inputs.WAN.MWAN3.Interfaces = []dish.MWANInterface{{Name: "wwan", Online: true}}
	engine.Tick(inputs)
	if len(notifications.notifications) != 2 || notifications.notifications[0].Alert != "failover_event" || notifications.notifications[0].State != StateFiring || notifications.notifications[1].State != StateFiring {
		t.Fatalf("notifications=%#v", notifications.notifications)
	}
}

func TestPathDegradedUsesStrictThresholdAndFiveMinuteClearHysteresis(t *testing.T) {
	now := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	notifications := &notificationSink{}
	engine := NewEngine(Options{Now: func() time.Time { return now }, Rules: testRules(), Delivery: notifications})
	inputs := Inputs{WAN: dish.WANStatus{Available: true, ProbeLoss5m: .2, ProbeRTT5mMS: 300}}

	engine.Tick(inputs)
	if len(notifications.notifications) != 0 {
		t.Fatal("equal-to thresholds must not fire")
	}
	inputs.WAN.ProbeLoss5m = .21
	engine.Tick(inputs)
	engine.Tick(inputs)
	if len(notifications.notifications) != 1 || notifications.notifications[0].State != StateFiring {
		t.Fatalf("fire notifications: %#v", notifications.notifications)
	}
	inputs.WAN.ProbeLoss5m = .2
	engine.Tick(inputs)
	now = now.Add(5*time.Minute - time.Second)
	engine.Tick(inputs)
	if len(notifications.notifications) != 1 {
		t.Fatal("path alert cleared before five minutes")
	}
	now = now.Add(time.Second)
	engine.Tick(inputs)
	engine.Tick(inputs)
	if len(notifications.notifications) != 2 || notifications.notifications[1].State != StateResolved {
		t.Fatalf("resolved notifications: %#v", notifications.notifications)
	}
}

func TestUnavailableInputsDoNotFalselyClearActiveAlerts(t *testing.T) {
	now := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	notifications := &notificationSink{}
	engine := NewEngine(Options{Now: func() time.Time { return now }, Rules: DefaultRules(), Delivery: notifications})
	inputs := Inputs{Dish: dish.Snapshot{Dish: &dish.Status{Alerts: map[string]bool{"thermal_throttle": true}}}}
	engine.Tick(inputs)
	inputs.Dish.Dish = nil
	engine.Tick(inputs)
	if len(notifications.notifications) != 1 || notifications.notifications[0].Alert != "thermal_throttle" {
		t.Fatalf("notifications after unavailable input: %#v", notifications.notifications)
	}
}

func TestDisablingActiveRuleEmitsResolve(t *testing.T) {
	now := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	notifications := &notificationSink{}
	rules := map[string]Rule{"thermal_throttle": DefaultRules()["thermal_throttle"]}
	engine := NewEngine(Options{Now: func() time.Time { return now }, Rules: rules, Delivery: notifications})
	inputs := Inputs{Dish: dish.Snapshot{Dish: &dish.Status{Alerts: map[string]bool{"thermal_throttle": true}}}}
	engine.Tick(inputs)
	rule := rules["thermal_throttle"]
	rule.Enabled = false
	rules["thermal_throttle"] = rule
	engine.SetRules(rules)
	now = now.Add(time.Minute)
	engine.Tick(inputs)
	if len(notifications.notifications) != 2 || notifications.notifications[0].State != StateFiring || notifications.notifications[1].State != StateResolved {
		t.Fatalf("notifications=%#v", notifications.notifications)
	}
}

func TestEngineRestoresActiveAlertWithoutRefiringAndLaterResolves(t *testing.T) {
	now := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	state := &memoryStateStore{}
	rules := map[string]Rule{"thermal_throttle": DefaultRules()["thermal_throttle"]}
	inputs := Inputs{Dish: dish.Snapshot{Dish: &dish.Status{Alerts: map[string]bool{"thermal_throttle": true}}}}
	firstNotifications := &notificationSink{}
	first := NewEngine(Options{Now: func() time.Time { return now }, Rules: rules, Delivery: firstNotifications, StateStore: state})
	first.Tick(inputs)
	if len(firstNotifications.notifications) != 1 || state.saves == 0 {
		t.Fatalf("first notifications=%#v saves=%d", firstNotifications.notifications, state.saves)
	}

	secondNotifications := &notificationSink{}
	second := NewEngine(Options{Now: func() time.Time { return now }, Rules: rules, Delivery: secondNotifications, StateStore: state})
	second.Tick(inputs)
	if len(secondNotifications.notifications) != 0 {
		t.Fatalf("restored active alert refired: %#v", secondNotifications.notifications)
	}
	inputs.Dish.Dish.Alerts["thermal_throttle"] = false
	now = now.Add(time.Minute)
	second.Tick(inputs)
	if len(secondNotifications.notifications) != 1 || secondNotifications.notifications[0].State != StateResolved {
		t.Fatalf("resolved notifications=%#v", secondNotifications.notifications)
	}
}

func TestEngineRestoresFailoverBaselineWithoutDuplicate(t *testing.T) {
	now := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	state := &memoryStateStore{}
	rules := map[string]Rule{"failover_event": DefaultRules()["failover_event"]}
	inputs := Inputs{WAN: dish.WANStatus{MWAN3: &dish.MWANStatus{ActiveInterfaces: []string{"wan"}}}}
	first := NewEngine(Options{Now: func() time.Time { return now }, Rules: rules, StateStore: state})
	first.Tick(inputs)

	notifications := &notificationSink{}
	second := NewEngine(Options{Now: func() time.Time { return now }, Rules: rules, Delivery: notifications, StateStore: state})
	second.Tick(inputs)
	if len(notifications.notifications) != 0 {
		t.Fatalf("restored failover baseline emitted duplicate: %#v", notifications.notifications)
	}
	inputs.WAN.MWAN3.ActiveInterfaces = []string{"wwan"}
	second.Tick(inputs)
	if len(notifications.notifications) != 1 || notifications.notifications[0].Alert != "failover_event" {
		t.Fatalf("failover notifications=%#v", notifications.notifications)
	}
}

func TestOutageAndDishUnreachableHoldDedupAndSuppression(t *testing.T) {
	now := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	notifications := &notificationSink{}
	rules := DefaultRules()
	engine := NewEngine(Options{Now: func() time.Time { return now }, Rules: rules, Delivery: notifications})
	engine.SetDishUnreachableSuppressUntil(now.Add(2 * time.Minute))
	inputs := Inputs{Outages: []outage.Entry{
		{Source: outage.SourceDish, Cause: "NO_DOWNLINK", Start: now.Add(-30 * time.Second), Duration: 30 * time.Second, Ongoing: true},
		{Source: outage.SourceUnreachable, Cause: "grpc_unreachable", Start: now.Add(-time.Minute), Duration: time.Minute, Ongoing: true},
	}}

	engine.Tick(inputs)
	if len(notifications.notifications) != 1 || notifications.notifications[0].Alert != "outage_started" {
		t.Fatalf("suppressed fire set: %#v", notifications.notifications)
	}
	now = now.Add(2 * time.Minute)
	inputs.Outages[0].Duration += 2 * time.Minute
	inputs.Outages[1].Duration += 2 * time.Minute
	engine.Tick(inputs)
	engine.Tick(inputs)
	if len(notifications.notifications) != 2 || notifications.notifications[1].Alert != "dish_unreachable" {
		t.Fatalf("unreachable notifications: %#v", notifications.notifications)
	}
	inputs.Outages = nil
	engine.Tick(inputs)
	if len(notifications.notifications) != 4 || notifications.notifications[2].State != StateResolved || notifications.notifications[3].State != StateResolved {
		t.Fatalf("clear notifications: %#v", notifications.notifications)
	}
}

func TestExpectedRebootOutageDoesNotFireAlerts(t *testing.T) {
	now := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	notifications := &notificationSink{}
	engine := NewEngine(Options{Now: func() time.Time { return now }, Rules: DefaultRules(), Delivery: notifications})
	engine.Tick(Inputs{Outages: []outage.Entry{{
		Source: outage.SourceUnreachable, Cause: "expected_reboot", Start: now.Add(-2 * time.Minute),
		Duration: 2 * time.Minute, Ongoing: true,
	}}})
	if len(notifications.notifications) != 0 {
		t.Fatalf("expected reboot notifications: %#v", notifications.notifications)
	}
}

func TestDishFlagsFirmwareAndObstructionFireAndPersistExactEvents(t *testing.T) {
	now := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	ram := history.NewStore(10)
	_ = ram.Append(history.ObstructionFraction, history.Point{Time: now.Add(-time.Hour), Value: .03})
	notifications := &notificationSink{}
	events := &eventSink{}
	engine := NewEngine(Options{Now: func() time.Time { return now }, Rules: DefaultRules(), History: ram, Delivery: notifications, Events: events})
	inputs := Inputs{Dish: dish.Snapshot{DeviceInfo: &dish.DeviceInfo{ID: "ut-1"}, Dish: &dish.Status{
		Alerts: map[string]bool{
			"thermal_throttle": true, "thermal_shutdown": true, "motors_stuck": true,
			"dish_water_detected": true, "mast_not_near_vertical": true, "slow_ethernet_speeds": true,
		},
		SoftwareUpdateState: "REBOOT_REQUIRED",
	}}}

	engine.Tick(inputs)
	wantAlerts := map[string]bool{"obstruction_high": true, "thermal_throttle": true, "thermal_shutdown": true, "motors_stuck": true, "water_detected": true, "mast_not_vertical": true, "slow_ethernet": true, "firmware_pending": true}
	if len(notifications.notifications) != len(wantAlerts) || len(events.events) != len(wantAlerts) {
		t.Fatalf("notifications=%#v events=%#v", notifications.notifications, events.events)
	}
	for i, notification := range notifications.notifications {
		if !wantAlerts[notification.Alert] || notification.Device != "ut-1" || notification.State != StateFiring {
			t.Fatalf("notification: %+v", notification)
		}
		if events.events[i].Kind != "alert_fired" {
			t.Fatalf("event: %+v", events.events[i])
		}
		var decoded Notification
		if err := json.Unmarshal([]byte(events.events[i].Detail), &decoded); err != nil || decoded.Alert != notification.Alert {
			t.Fatalf("event detail=%q decoded=%+v err=%v", events.events[i].Detail, decoded, err)
		}
	}
}

func TestObstructionAverageIsCachedForSixtySeconds(t *testing.T) {
	now := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	reader := &countingSpanReader{now: now}
	rules := map[string]Rule{"obstruction_high": DefaultRules()["obstruction_high"]}
	engine := NewEngine(Options{Now: func() time.Time { return now }, Rules: rules, History: reader})

	engine.Tick(Inputs{})
	now = now.Add(time.Second)
	engine.Tick(Inputs{})
	if reader.calls != 1 {
		t.Fatalf("24-hour history query calls = %d, want 1", reader.calls)
	}
	now = now.Add(59 * time.Second)
	engine.Tick(Inputs{})
	if reader.calls != 2 {
		t.Fatalf("24-hour history query calls after cache expiry = %d, want 2", reader.calls)
	}
}
