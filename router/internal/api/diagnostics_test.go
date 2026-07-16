package api

import (
	"encoding/json"
	"errors"
	"net/http"
	"testing"
	"time"

	"starwatch/internal/dish"
	"starwatch/internal/history"
	"starwatch/internal/outage"
)

type diagnosticsHistoryStub struct {
	results map[string]history.QueryResult
	err     error
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
	if _, hasBattery := body["battery"]; hasBattery {
		t.Fatalf("phase 1 emitted battery: %s", response.Body.String())
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
