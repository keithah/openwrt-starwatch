package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"starwatch/internal/dish"
	"starwatch/internal/history"
)

type snapshotStub struct{ snapshot dish.Snapshot }

func (s snapshotStub) Snapshot() dish.Snapshot { return s.snapshot }

func testHandler(t *testing.T, token string, capacity int) (http.Handler, *history.Store) {
	t.Helper()
	store := history.NewStore(capacity)
	provider := snapshotStub{snapshot: dish.Snapshot{
		Topology:          dish.TopologyFull,
		Dish:              &dish.Status{LatencyMS: 42},
		FieldAvailability: map[string]bool{dish.FieldStatus: true},
	}}
	return NewServer(Deps{Token: token, Snapshot: provider, History: store, Now: func() time.Time {
		return time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	}}), store
}

func request(handler http.Handler, method, target, token string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, target, nil)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, req)
	return response
}

func TestAuthAcceptsBearerAndQueryToken(t *testing.T) {
	handler, _ := testHandler(t, "secret", 10)
	for name, response := range map[string]*httptest.ResponseRecorder{
		"missing": request(handler, http.MethodGet, "/api/status", ""),
		"wrong":   request(handler, http.MethodGet, "/api/status", "wrong"),
	} {
		if response.Code != http.StatusUnauthorized {
			t.Fatalf("%s: got %d", name, response.Code)
		}
	}
	if response := request(handler, http.MethodGet, "/api/status", "secret"); response.Code != http.StatusOK {
		t.Fatalf("bearer: %d", response.Code)
	}
	if response := request(handler, http.MethodGet, "/api/status?token=secret", ""); response.Code != http.StatusOK {
		t.Fatalf("query: %d", response.Code)
	}
}

func TestAuthEmptyConfiguredTokenAlwaysDenies(t *testing.T) {
	handler, _ := testHandler(t, "", 10)
	if response := request(handler, http.MethodGet, "/api/status?token=anything", "anything"); response.Code != http.StatusUnauthorized {
		t.Fatalf("got %d", response.Code)
	}
}

func TestStatusReturnsSnapshot(t *testing.T) {
	handler, _ := testHandler(t, "secret", 10)
	response := request(handler, http.MethodGet, "/api/status", "secret")
	var snapshot dish.Snapshot
	if err := json.Unmarshal(response.Body.Bytes(), &snapshot); err != nil {
		t.Fatal(err)
	}
	if snapshot.Topology != dish.TopologyFull || snapshot.Dish == nil || snapshot.Dish.LatencyMS != 42 || !snapshot.FieldAvailability[dish.FieldStatus] {
		t.Fatalf("snapshot: %+v", snapshot)
	}
}

func TestHistoryReturnsAtMostThousandRAMPoints(t *testing.T) {
	handler, store := testHandler(t, "secret", 1500)
	start := time.Date(2026, 7, 15, 11, 30, 0, 0, time.UTC)
	for i := 0; i < 1500; i++ {
		if err := store.Append(history.LatencyMS, history.Point{Time: start.Add(time.Duration(i) * time.Second), Value: float32(i)}); err != nil {
			t.Fatal(err)
		}
	}
	response := request(handler, http.MethodGet, "/api/history?series=latency_ms&span=3h", "secret")
	if response.Code != http.StatusOK {
		t.Fatalf("code=%d body=%s", response.Code, response.Body.String())
	}
	var body struct {
		Series string          `json:"series"`
		Span   string          `json:"span"`
		Points []history.Point `json:"points"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.Series != history.LatencyMS || body.Span != "3h" || len(body.Points) != 1000 {
		t.Fatalf("body: series=%q span=%q points=%d", body.Series, body.Span, len(body.Points))
	}
}

func TestHistoryValidatesSeriesAndSpan(t *testing.T) {
	handler, _ := testHandler(t, "secret", 10)
	for _, target := range []string{
		"/api/history?span=3h",
		"/api/history?series=nope&span=3h",
		"/api/history?series=latency_ms&span=banana",
	} {
		if response := request(handler, http.MethodGet, target, "secret"); response.Code != http.StatusBadRequest {
			t.Fatalf("%s: code=%d body=%s", target, response.Code, response.Body.String())
		}
	}
}
