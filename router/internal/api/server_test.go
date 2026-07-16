package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"starwatch/internal/dish"
	liveevent "starwatch/internal/event"
	"starwatch/internal/history"
	"starwatch/internal/outage"
)

type snapshotStub struct{ snapshot dish.Snapshot }

func (s snapshotStub) Snapshot() dish.Snapshot { return s.snapshot }

type wanStub struct{ snapshot dish.WANStatus }

func (s wanStub) Snapshot() dish.WANStatus { return s.snapshot }

type spanStub struct{ result history.QueryResult }

func (s spanStub) QuerySpan(string, time.Time, time.Duration, int) (history.QueryResult, error) {
	return s.result, nil
}

type outageStub struct{ entries []outage.Entry }

func (s outageStub) Query(time.Time, int) ([]outage.Entry, error) { return s.entries, nil }

type eventStub struct{ events []history.Event }

func (s eventStub) QueryEvents(time.Time, int) ([]history.Event, error) { return s.events, nil }

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
		Tier   history.Tier    `json:"tier"`
		Points []history.Point `json:"points"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.Series != history.LatencyMS || body.Span != "3h" || body.Tier != history.TierRAM || len(body.Points) != 1000 {
		t.Fatalf("body: series=%q span=%q tier=%q points=%d", body.Series, body.Span, body.Tier, len(body.Points))
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

func TestWANEndpointAndStatusExposeWANSnapshot(t *testing.T) {
	store := history.NewStore(10)
	wan := wanStub{snapshot: dish.WANStatus{Available: true, Interface: "wan0", Up: true, RouterDownBPS: 123}}
	handler := NewServer(Deps{
		Token: "secret", Snapshot: snapshotStub{snapshot: dish.Snapshot{Topology: dish.TopologyWANOnly}},
		History: store, WAN: wan,
	})
	response := request(handler, http.MethodGet, "/api/wan", "secret")
	if response.Code != http.StatusOK {
		t.Fatalf("wan code=%d body=%s", response.Code, response.Body.String())
	}
	var got dish.WANStatus
	if err := json.Unmarshal(response.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if got.Interface != "wan0" || got.RouterDownBPS != 123 {
		t.Fatalf("wan: %+v", got)
	}
	response = request(handler, http.MethodGet, "/api/status", "secret")
	var status dish.Snapshot
	if err := json.Unmarshal(response.Body.Bytes(), &status); err != nil {
		t.Fatal(err)
	}
	if status.WAN.Interface != "wan0" {
		t.Fatalf("status wan: %+v", status.WAN)
	}
}

func TestHistoryReturnsSelectedPersistentTier(t *testing.T) {
	minimum, maximum := float32(1), float32(5)
	handler := NewServer(Deps{
		Token: "secret", Snapshot: snapshotStub{},
		History: spanStub{result: history.QueryResult{Tier: history.TierMinute, Points: []history.Point{{
			Time: time.Date(2026, 7, 15, 11, 0, 0, 0, time.UTC), Value: 3, Min: &minimum, Max: &maximum,
		}}}},
	})
	response := request(handler, http.MethodGet, "/api/history?series=latency_ms&span=24h", "secret")
	if response.Code != http.StatusOK {
		t.Fatalf("code=%d body=%s", response.Code, response.Body.String())
	}
	var body struct {
		Tier   history.Tier    `json:"tier"`
		Points []history.Point `json:"points"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.Tier != history.TierMinute || len(body.Points) != 1 || valueOf(body.Points[0].Min) != 1 || valueOf(body.Points[0].Max) != 5 {
		t.Fatalf("body: %+v", body)
	}
}

func TestOutagesAndEventsEndpointsApplySpan(t *testing.T) {
	now := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	handler := NewServer(Deps{
		Token: "secret", Snapshot: snapshotStub{}, History: history.NewStore(1), Now: func() time.Time { return now },
		Outages: outageStub{entries: []outage.Entry{{Source: outage.SourcePath, Cause: "probe_loss", Start: now.Add(-time.Minute), Duration: 30 * time.Second}}},
		Events:  eventStub{events: []history.Event{{At: now, Kind: "alert_fired", Detail: `{}`}}},
	})

	outageResponse := request(handler, http.MethodGet, "/api/outages?span=3h", "secret")
	if outageResponse.Code != http.StatusOK {
		t.Fatalf("outages code=%d body=%s", outageResponse.Code, outageResponse.Body.String())
	}
	var outages []outage.Entry
	if err := json.Unmarshal(outageResponse.Body.Bytes(), &outages); err != nil || len(outages) != 1 || outages[0].Source != outage.SourcePath {
		t.Fatalf("outages=%#v err=%v", outages, err)
	}
	eventResponse := request(handler, http.MethodGet, "/api/events?span=7d", "secret")
	if eventResponse.Code != http.StatusOK {
		t.Fatalf("events code=%d body=%s", eventResponse.Code, eventResponse.Body.String())
	}
	var events []history.Event
	if err := json.Unmarshal(eventResponse.Body.Bytes(), &events); err != nil || len(events) != 1 || events[0].Kind != "alert_fired" {
		t.Fatalf("events=%#v err=%v", events, err)
	}
}

func TestWebSocketAuthCadenceAndAsyncEvents(t *testing.T) {
	now := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	bus := liveevent.NewBus()
	handler := NewServer(Deps{
		Token: "secret", Snapshot: snapshotStub{snapshot: dish.Snapshot{Dish: &dish.Status{LatencyMS: 42}}},
		History: history.NewStore(1), WAN: wanStub{snapshot: dish.WANStatus{Interface: "wan0"}}, Live: bus,
		Now: func() time.Time { return now }, WSInterval: 10 * time.Millisecond,
	})
	defer handler.Close()
	server := httptest.NewServer(handler)
	defer server.Close()
	wsURL := "ws" + server.URL[len("http"):] + "/api/ws"
	if connection, response, err := websocket.Dial(context.Background(), wsURL, nil); err == nil || response == nil || response.StatusCode != http.StatusUnauthorized {
		if connection != nil {
			connection.CloseNow()
		}
		t.Fatalf("unauthorized dial connection=%v response=%v err=%v", connection, response, err)
	}
	connection, _, err := websocket.Dial(context.Background(), wsURL+"?token=secret", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.CloseNow()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	var frame struct {
		T    int64          `json:"t"`
		Dish *dish.Status   `json:"dish"`
		WAN  dish.WANStatus `json:"wan"`
	}
	if err := wsjson.Read(ctx, connection, &frame); err != nil {
		t.Fatal(err)
	}
	if frame.T != now.Unix() || frame.Dish == nil || frame.Dish.LatencyMS != 42 || frame.WAN.Interface != "wan0" {
		t.Fatalf("frame: %+v", frame)
	}
	bus.Publish(liveevent.Message{Kind: "alert_fired", At: now, Data: map[string]any{"alert": "path_degraded"}})
	var async struct {
		Event liveevent.Message `json:"event"`
	}
	if err := wsjson.Read(ctx, connection, &async); err != nil {
		t.Fatal(err)
	}
	if async.Event.Kind != "alert_fired" {
		t.Fatalf("async event: %+v", async)
	}
}

func TestWebSocketDisconnectsWhenBoundedEventBufferOverflows(t *testing.T) {
	bus := liveevent.NewBus()
	writeStarted := make(chan struct{}, 1)
	unblock := make(chan struct{})
	handler := NewServer(Deps{
		Token: "secret", Snapshot: snapshotStub{}, History: history.NewStore(1), Live: bus,
		WSInterval: time.Hour, WSBuffer: 1, WSWriteTimeout: time.Second,
		WSWrite: func(ctx context.Context, _ *websocket.Conn, _ any) error {
			select {
			case writeStarted <- struct{}{}:
			default:
			}
			select {
			case <-unblock:
				return nil
			case <-ctx.Done():
				return ctx.Err()
			}
		},
	})
	server := httptest.NewServer(handler)
	connection, _, err := websocket.Dial(context.Background(), "ws"+server.URL[len("http"):]+"/api/ws?token=secret", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.CloseNow()
	bus.Publish(liveevent.Message{Kind: "one"})
	select {
	case <-writeStarted:
	case <-time.After(time.Second):
		t.Fatal("websocket did not begin event write")
	}
	bus.Publish(liveevent.Message{Kind: "two"})
	bus.Publish(liveevent.Message{Kind: "three"})
	close(unblock)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	var value any
	if err := wsjson.Read(ctx, connection, &value); err == nil || websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
		t.Fatalf("slow client read err=%v value=%#v", err, value)
	}
	handler.Close()
	server.Close()
}

func valueOf(value *float32) float32 {
	if value == nil {
		return 0
	}
	return *value
}
