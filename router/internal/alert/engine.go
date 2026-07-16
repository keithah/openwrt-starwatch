// Package alert evaluates Starwatch's fixed alert catalog.
package alert

import (
	"encoding/json"
	"sync"
	"time"

	"starwatch/internal/dish"
	"starwatch/internal/event"
	"starwatch/internal/history"
	"starwatch/internal/outage"
)

type Severity string

const (
	SeverityCritical Severity = "critical"
	SeverityWarning  Severity = "warning"
	SeverityInfo     Severity = "info"
)

type State string

const (
	StateFiring   State = "firing"
	StateResolved State = "resolved"
)

type Rule struct {
	Enabled    bool
	Severity   Severity
	Threshold  float64
	Threshold2 float64
	Hold       time.Duration
	ClearHold  time.Duration
}

type Notification struct {
	Alert    string         `json:"alert"`
	Severity Severity       `json:"severity"`
	State    State          `json:"state"`
	At       int64          `json:"at"`
	Detail   map[string]any `json:"detail"`
	Device   string         `json:"device"`
}

type Inputs struct {
	Dish    dish.Snapshot
	WAN     dish.WANStatus
	Outages []outage.Entry
}

type Delivery interface {
	Enqueue(Notification)
}

type EventSink interface {
	AddEvent(history.Event)
}

type Options struct {
	Now      func() time.Time
	Rules    map[string]Rule
	History  history.SpanReader
	Delivery Delivery
	Events   EventSink
	Live     event.Publisher
}

type alertState struct {
	active       bool
	firedAt      time.Time
	subjectStart time.Time
	clearSince   time.Time
	detail       map[string]any
}

type Engine struct {
	now           func() time.Time
	rules         map[string]Rule
	history       history.SpanReader
	delivery      Delivery
	events        EventSink
	live          event.Publisher
	states        map[string]*alertState
	mu            sync.RWMutex
	suppressUntil time.Time
	obstruction   obstructionCache
}

type obstructionCache struct {
	at      time.Time
	average float64
	valid   bool
}

var catalogOrder = []string{
	"outage_started", "dish_unreachable", "path_degraded", "obstruction_high",
	"thermal_throttle", "thermal_shutdown", "motors_stuck", "water_detected",
	"mast_not_vertical", "slow_ethernet", "firmware_pending",
}

func DefaultRules() map[string]Rule {
	severity := map[string]Severity{
		"outage_started": SeverityCritical, "dish_unreachable": SeverityCritical,
		"path_degraded": SeverityWarning, "obstruction_high": SeverityWarning,
		"thermal_throttle": SeverityWarning, "thermal_shutdown": SeverityCritical,
		"motors_stuck": SeverityWarning, "water_detected": SeverityWarning,
		"mast_not_vertical": SeverityInfo, "slow_ethernet": SeverityInfo,
		"firmware_pending": SeverityInfo,
	}
	rules := make(map[string]Rule, len(catalogOrder))
	for _, name := range catalogOrder {
		rules[name] = Rule{Enabled: true, Severity: severity[name]}
	}
	setRule(rules, "outage_started", func(rule *Rule) { rule.Hold = 30 * time.Second })
	setRule(rules, "dish_unreachable", func(rule *Rule) { rule.Hold = time.Minute })
	setRule(rules, "path_degraded", func(rule *Rule) {
		rule.Threshold, rule.Threshold2, rule.ClearHold = .2, 300, 5*time.Minute
	})
	setRule(rules, "obstruction_high", func(rule *Rule) { rule.Threshold = .02 })
	return rules
}

func setRule(rules map[string]Rule, name string, update func(*Rule)) {
	rule := rules[name]
	update(&rule)
	rules[name] = rule
}

func NewEngine(options Options) *Engine {
	if options.Now == nil {
		options.Now = time.Now
	}
	if options.Rules == nil {
		options.Rules = DefaultRules()
	}
	return &Engine{
		now: options.Now, rules: options.Rules, history: options.History, delivery: options.Delivery,
		events: options.Events, live: options.Live, states: make(map[string]*alertState),
	}
}

func (e *Engine) SetDishUnreachableSuppressUntil(until time.Time) {
	e.mu.Lock()
	e.suppressUntil = until
	e.mu.Unlock()
}

func (e *Engine) Tick(inputs Inputs) {
	now := e.now()
	for _, name := range catalogOrder {
		rule, exists := e.rules[name]
		if !exists || !rule.Enabled {
			delete(e.states, name)
			continue
		}
		condition := e.evaluate(name, rule, inputs, now)
		if !condition.known {
			continue
		}
		state := e.states[name]
		if state == nil {
			state = &alertState{}
			e.states[name] = state
		}
		if condition.active {
			state.clearSince = time.Time{}
			if state.active {
				continue
			}
			state.active = true
			state.firedAt = now
			state.subjectStart = condition.started
			state.detail = condition.detail
			e.emit(name, rule.Severity, StateFiring, state, inputs, now)
			continue
		}
		if !state.active {
			continue
		}
		if rule.ClearHold > 0 {
			if state.clearSince.IsZero() {
				state.clearSince = now
				continue
			}
			if now.Sub(state.clearSince) < rule.ClearHold {
				continue
			}
		}
		e.emit(name, rule.Severity, StateResolved, state, inputs, now)
		*state = alertState{}
	}
}

type condition struct {
	active  bool
	known   bool
	started time.Time
	detail  map[string]any
}

func (e *Engine) evaluate(name string, rule Rule, inputs Inputs, now time.Time) condition {
	result := condition{known: true, started: now, detail: make(map[string]any)}
	switch name {
	case "outage_started", "dish_unreachable":
		for _, entry := range inputs.Outages {
			if entry.Cause == "expected_reboot" {
				continue
			}
			if !entry.Ongoing || (name == "dish_unreachable" && entry.Source != outage.SourceUnreachable) {
				continue
			}
			duration := entry.Duration
			if elapsed := now.Sub(entry.Start); elapsed > duration {
				duration = elapsed
			}
			if duration < rule.Hold {
				continue
			}
			if name == "dish_unreachable" && now.Before(e.dishUnreachableSuppressUntil()) {
				continue
			}
			result.active, result.started = true, entry.Start
			result.detail = map[string]any{"source": entry.Source, "cause": entry.Cause}
			return result
		}
	case "path_degraded":
		if !inputs.WAN.Available {
			result.known = false
			return result
		}
		result.active = inputs.WAN.ProbeLoss5m > float32(rule.Threshold) || inputs.WAN.ProbeRTT5mMS > float32(rule.Threshold2)
		result.detail = map[string]any{"loss_5m": inputs.WAN.ProbeLoss5m, "rtt_5m_ms": inputs.WAN.ProbeRTT5mMS}
	case "obstruction_high":
		average, ok := e.obstructionAverage(now)
		if !ok {
			result.known = false
			return result
		}
		result.active = average > rule.Threshold
		result.detail = map[string]any{"fraction_24h": average}
	case "thermal_throttle":
		result.active, result.known = dishAlert(inputs, "thermal_throttle")
	case "thermal_shutdown":
		result.active, result.known = dishAlert(inputs, "thermal_shutdown")
	case "motors_stuck":
		result.active, result.known = dishAlert(inputs, "motors_stuck")
	case "water_detected":
		result.active, result.known = dishAlert(inputs, "dish_water_detected")
	case "mast_not_vertical":
		result.active, result.known = dishAlert(inputs, "mast_not_near_vertical")
	case "slow_ethernet":
		result.active, result.known = dishAlert(inputs, "slow_ethernet_speeds")
	case "firmware_pending":
		if inputs.Dish.Dish == nil {
			result.known = false
			return result
		}
		result.active = inputs.Dish.Dish.SoftwareUpdateState == "REBOOT_REQUIRED" || inputs.Dish.Dish.Alerts["install_pending"]
	}
	return result
}

func (e *Engine) obstructionAverage(now time.Time) (float64, bool) {
	if e.history == nil {
		return 0, false
	}
	e.mu.RLock()
	cached := e.obstruction
	e.mu.RUnlock()
	if cached.valid && now.Sub(cached.at) >= 0 && now.Sub(cached.at) < time.Minute {
		return cached.average, true
	}
	query, err := e.history.QuerySpan(history.ObstructionFraction, now.Add(-24*time.Hour), 24*time.Hour, 0)
	if err != nil || len(query.Points) == 0 {
		return 0, false
	}
	var total float64
	for _, point := range query.Points {
		total += float64(point.Value)
	}
	average := total / float64(len(query.Points))
	e.mu.Lock()
	e.obstruction = obstructionCache{at: now, average: average, valid: true}
	e.mu.Unlock()
	return average, true
}

func (e *Engine) dishUnreachableSuppressUntil() time.Time {
	e.mu.RLock()
	defer e.mu.RUnlock()
	return e.suppressUntil
}

func dishAlert(inputs Inputs, name string) (bool, bool) {
	if inputs.Dish.Dish == nil {
		return false, false
	}
	return inputs.Dish.Dish.Alerts[name], true
}

func (e *Engine) emit(name string, severity Severity, state State, current *alertState, inputs Inputs, now time.Time) {
	detail := make(map[string]any, len(current.detail)+1)
	for key, value := range current.detail {
		detail[key] = value
	}
	if state == StateResolved {
		started := current.subjectStart
		if started.IsZero() {
			started = current.firedAt
		}
		detail["duration_seconds"] = nonnegative(now.Sub(started)).Seconds()
	}
	device := ""
	if inputs.Dish.DeviceInfo != nil {
		device = inputs.Dish.DeviceInfo.ID
	}
	notification := Notification{Alert: name, Severity: severity, State: state, At: now.Unix(), Detail: detail, Device: device}
	if e.delivery != nil {
		e.delivery.Enqueue(notification)
	}
	kind := "alert_fired"
	if state == StateResolved {
		kind = "alert_cleared"
	}
	if e.events != nil {
		encoded, _ := json.Marshal(notification)
		e.events.AddEvent(history.Event{At: now, Kind: kind, Detail: string(encoded)})
	}
	if e.live != nil {
		e.live.Publish(event.Message{Kind: kind, At: now, Data: notification})
	}
}

func nonnegative(duration time.Duration) time.Duration {
	if duration < 0 {
		return 0
	}
	return duration
}
