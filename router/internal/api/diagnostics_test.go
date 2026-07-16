package api

import (
	"encoding/json"
	"errors"
	"net/http"
	"testing"
	"time"

	"starwatch/internal/config"
	"starwatch/internal/dish"
	"starwatch/internal/history"
	"starwatch/internal/outage"
)

type diagnosticsHistoryStub struct {
	results map[string]history.QueryResult
	err     error
}

type diagnosticsSettingsStub struct{ view config.PublicConfig }

func (s diagnosticsSettingsStub) Token() string                    { return "secret" }
func (s diagnosticsSettingsStub) View() config.PublicConfig        { return s.view }
func (s diagnosticsSettingsStub) Update(config.Update) error       { return nil }
func (s diagnosticsSettingsStub) RegenerateToken() (string, error) { return "secret", nil }

type diagnosticsQuery struct {
	series string
	span   time.Duration
}

type diagnosticsRecordingHistory struct {
	queries      []diagnosticsQuery
	latency      history.QueryResult
	power        history.QueryResult
	batteryPower history.QueryResult
}

func (s *diagnosticsRecordingHistory) QuerySpan(series string, _ time.Time, span time.Duration, _ int) (history.QueryResult, error) {
	s.queries = append(s.queries, diagnosticsQuery{series: series, span: span})
	if series == history.LatencyMS {
		return s.latency, nil
	}
	if series == history.PowerW && span == 15*time.Minute {
		return s.batteryPower, nil
	}
	if series == history.PowerW {
		return s.power, nil
	}
	return history.QueryResult{}, history.ErrUnknownSeries
}

func (s diagnosticsHistoryStub) QuerySpan(series string, _ time.Time, _ time.Duration, _ int) (history.QueryResult, error) {
	if s.err != nil {
		return history.QueryResult{}, s.err
	}
	result, ok := s.results[series]
	if !ok {
		return history.QueryResult{}, history.ErrUnknownSeries
	}
	return result, nil
}

func TestDiagnosticsRequiresTokenAndReturnsDerivedAggregateSummary(t *testing.T) {
	now := time.Date(2026, 7, 16, 12, 0, 0, 0, time.UTC)
	power := float32(55)
	minimum, maximum := float32(40), float32(60)
	handler := NewServer(Deps{
		Token: "secret", Now: func() time.Time { return now },
		Snapshot: snapshotStub{snapshot: dish.Snapshot{
			Dish:   &dish.Status{LatencyMS: 25, DropRate: 0.1, PowerW: &power, PowerSource: "status"},
			Config: &dish.ConfigReadback{SnowMeltMode: "AUTO"},
			FieldAvailability: map[string]dish.Availability{
				dish.FieldStatus: {Available: true}, dish.FieldPower: {Available: true},
			},
		}},
		History: diagnosticsHistoryStub{results: map[string]history.QueryResult{
			history.LatencyMS: {Tier: history.TierMinute, Points: []history.Point{{Value: 20, Samples: 3}, {Value: 80, Samples: 1}}},
			history.PowerW:    {Tier: history.TierMinute, Points: []history.Point{{Value: 50, Min: &minimum, Max: &maximum, Samples: 4}}},
		}},
		WAN: wanStub{snapshot: dish.WANStatus{
			Available: true, Probe30sAvailable: true, Probe5mAvailable: true,
			ProbeLoss30s: 0.2, ProbeLoss5m: 0.25,
		}},
		Outages: outageStub{entries: []outage.Entry{{Source: outage.SourceDish, Start: now.Add(-time.Minute), Duration: 10 * time.Second}}},
	})

	if response := request(handler, http.MethodGet, "/api/diagnostics?span=24h", ""); response.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated code=%d body=%s", response.Code, response.Body.String())
	}
	response := request(handler, http.MethodGet, "/api/diagnostics?span=24h", "secret")
	if response.Code != http.StatusOK {
		t.Fatalf("code=%d body=%s", response.Code, response.Body.String())
	}
	var body map[string]any
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	latency := body["latency"].(map[string]any)
	ping := body["ping"].(map[string]any)
	powerBody := body["power"].(map[string]any)
	if body["span"] != "24h" || latency["approximate"] != true || latency["current_ms"] != float64(25) || ping["dish_success"] != 0.9 || ping["wan_success_30s"] != 0.8 {
		t.Fatalf("diagnostics=%s", response.Body.String())
	}
	if powerBody["mean_w"] != float64(50) || powerBody["min_w"] != float64(40) || powerBody["max_w"] != float64(60) {
		t.Fatalf("power=%+v", powerBody)
	}
	batteryBody := body["battery"].(map[string]any)
	if batteryBody["configured"] != false || batteryBody["derived"] != true {
		t.Fatalf("disabled battery=%+v", batteryBody)
	}
}

func TestDiagnosticsBatteryUsesSeparateRolling15MinutePower(t *testing.T) {
	now := time.Date(2026, 7, 16, 20, 0, 0, 0, time.UTC)
	updatedAt := now.Add(-time.Hour)
	historyReader := &diagnosticsRecordingHistory{
		latency: history.QueryResult{Tier: history.TierMinute, Points: []history.Point{{Time: now.Add(-time.Hour), Value: 25}}},
		power:   history.QueryResult{Tier: history.TierMinute, Points: []history.Point{{Time: now.Add(-time.Hour), Value: 70}}},
		batteryPower: history.QueryResult{Tier: history.TierRAM, Points: []history.Point{
			{Time: now.Add(-10 * time.Minute), Value: 40}, {Time: now.Add(-5 * time.Minute), Value: 50},
		}},
	}
	handler := NewServer(Deps{
		Token: "secret", Now: func() time.Time { return now }, Snapshot: snapshotStub{}, History: historyReader,
		Settings: diagnosticsSettingsStub{view: config.PublicConfig{Battery: config.BatteryView{
			Enabled: true, CapacityWh: 1024, StateOfChargePercent: 76, ReservePercent: 10,
			ConversionEfficiencyPercent: 90, StateOfChargeUpdatedAt: &updatedAt,
		}}},
	})
	response := request(handler, http.MethodGet, "/api/diagnostics?span=24h", "secret")
	if response.Code != http.StatusOK {
		t.Fatalf("code=%d body=%s", response.Code, response.Body.String())
	}
	var body map[string]any
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	battery := body["battery"].(map[string]any)
	if battery["configured"] != true || battery["derived"] != true || battery["load_window"] != "15m" || battery["load_w"] != float64(45) {
		t.Fatalf("battery=%+v body=%s", battery, response.Body.String())
	}
	if battery["full_charge_runtime_hours"] == nil || battery["remaining_runtime_hours"] == nil || battery["state_of_charge_stale"] != false {
		t.Fatalf("runtime battery=%+v", battery)
	}
	foundBatteryQuery := false
	for _, query := range historyReader.queries {
		if query.series == history.PowerW && query.span == 15*time.Minute {
			foundBatteryQuery = true
		}
	}
	if !foundBatteryQuery {
		t.Fatalf("queries=%+v", historyReader.queries)
	}
	if _, exists := body["router"]; exists {
		t.Fatalf("Phase 2 emitted Phase 3 router object: %s", response.Body.String())
	}
}

func TestDiagnosticsEmptySpanReturnsAvailabilityReasons(t *testing.T) {
	handler := NewServer(Deps{
		Token: "secret", Snapshot: snapshotStub{}, Outages: outageStub{},
		History: diagnosticsHistoryStub{results: map[string]history.QueryResult{
			history.LatencyMS: {Tier: history.TierRAM}, history.PowerW: {Tier: history.TierRAM},
		}},
		Now: func() time.Time { return time.Date(2026, 7, 16, 12, 0, 0, 0, time.UTC) },
	})
	response := request(handler, http.MethodGet, "/api/diagnostics?span=3h", "secret")
	if response.Code != http.StatusOK {
		t.Fatalf("code=%d body=%s", response.Code, response.Body.String())
	}
	var body map[string]any
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"latency", "ping", "outages", "power"} {
		summary := body[name].(map[string]any)
		if summary["available"] != false || summary["reason"] == "" {
			t.Fatalf("%s=%+v body=%s", name, summary, response.Body.String())
		}
	}
}

func TestDiagnosticsAndHistoryRejectUnsupportedSpan(t *testing.T) {
	handler := NewServer(Deps{Token: "secret", Snapshot: snapshotStub{}, History: history.NewStore(1)})
	for _, target := range []string{
		"/api/diagnostics?span=1h",
		"/api/history?series=latency_ms&span=1h",
	} {
		response := request(handler, http.MethodGet, target, "secret")
		if response.Code != http.StatusBadRequest {
			t.Fatalf("%s code=%d body=%s", target, response.Code, response.Body.String())
		}
	}
}

func TestDiagnosticsHistoryFailureReturnsServerError(t *testing.T) {
	handler := NewServer(Deps{
		Token: "secret", Snapshot: snapshotStub{}, History: diagnosticsHistoryStub{err: errors.New("history unavailable")},
	})
	response := request(handler, http.MethodGet, "/api/diagnostics?span=3h", "secret")
	if response.Code != http.StatusInternalServerError {
		t.Fatalf("code=%d body=%s", response.Code, response.Body.String())
	}
}
