package api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"starwatch/internal/alert"
	"starwatch/internal/dish"
	liveevent "starwatch/internal/event"
	"starwatch/internal/history"
	"starwatch/internal/mwan"
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

type alertDeliveryStub struct{ notifications []alert.Notification }

func (s *alertDeliveryStub) Enqueue(notification alert.Notification) {
	s.notifications = append(s.notifications, notification)
}

type controlStub struct {
	params dish.ControlParams
	err    error
}

func (s *controlStub) Execute(_ context.Context, params dish.ControlParams) (dish.ControlResult, error) {
	s.params = params
	return dish.ControlResult{Accepted: s.err == nil}, s.err
}

type obstructionStub struct {
	snapshot dish.Snapshot
	grid     *dish.ObstructionMap
	refresh  int
}

func (s *obstructionStub) Snapshot() dish.Snapshot { return s.snapshot }
func (s *obstructionStub) RefreshObstructionMap(context.Context) (*dish.ObstructionMap, error) {
	s.refresh++
	return s.grid, nil
}

type speedtestStub struct {
	state dish.SpeedtestSnapshot
	err   error
}

type failoverStub struct {
	result  mwan.AssistResult
	applied int
}

func (s *failoverStub) Assist(context.Context, string) mwan.AssistResult { return s.result }
func (s *failoverStub) Apply(context.Context, string) error              { s.applied++; return nil }

func (s *speedtestStub) Start(context.Context) error      { return s.err }
func (s *speedtestStub) Snapshot() dish.SpeedtestSnapshot { return s.state }

func testHandler(t *testing.T, token string, capacity int) (http.Handler, *history.Store) {
	t.Helper()
	store := history.NewStore(capacity)
	provider := snapshotStub{snapshot: dish.Snapshot{
		Topology:          dish.TopologyFull,
		Dish:              &dish.Status{LatencyMS: 42},
		FieldAvailability: map[string]dish.Availability{dish.FieldStatus: {Available: true}},
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

func requestBody(handler http.Handler, method, target, token, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, target, bytes.NewBufferString(body))
	req.Header.Set("Authorization", "Bearer "+token)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, req)
	return response
}

func TestStaticServingIsUnauthenticatedAndIframeSafe(t *testing.T) {
	t.Setenv("STARWATCH_WEB_DIR", "")
	handler, _ := testHandler(t, "secret", 10)

	index := request(handler, http.MethodGet, "/", "")
	if index.Code != http.StatusOK || !bytes.Contains(index.Body.Bytes(), []byte(`data-starwatch-app`)) {
		t.Fatalf("index code=%d body=%s", index.Code, index.Body.String())
	}
	app := request(handler, http.MethodGet, "/app.js", "")
	if app.Code != http.StatusOK || !bytes.Contains(app.Body.Bytes(), []byte("Customize dashboard")) || !bytes.Contains(app.Body.Bytes(), []byte("starwatch.dashboard.cards.v1")) {
		t.Fatalf("app code=%d missing dashboard drawer assets", app.Code)
	}
	logic := request(handler, http.MethodGet, "/logic.js", "")
	if logic.Code != http.StatusOK || !bytes.Contains(logic.Body.Bytes(), []byte("normalizeCardPreferences")) {
		t.Fatalf("logic code=%d missing card preference logic", logic.Code)
	}
	if got := index.Header().Get("X-Frame-Options"); got != "" {
		t.Fatalf("X-Frame-Options=%q", got)
	}
	asset := request(handler, http.MethodGet, "/vendor/preact.module.js", "")
	if asset.Code != http.StatusOK || !bytes.Contains(asset.Body.Bytes(), []byte("preact")) {
		t.Fatalf("asset code=%d body=%s", asset.Code, asset.Body.String())
	}
	harness := request(handler, http.MethodGet, "/test.html", "")
	if harness.Code != http.StatusOK || !bytes.Contains(harness.Body.Bytes(), []byte("Starwatch browser logic tests")) {
		t.Fatalf("harness code=%d body=%s", harness.Code, harness.Body.String())
	}
	if response := request(handler, http.MethodGet, "/api/status", ""); response.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated API code=%d", response.Code)
	}
}

func TestStaticServingUsesWebDirectoryOverride(t *testing.T) {
	directory := t.TempDir()
	if err := os.WriteFile(filepath.Join(directory, "index.html"), []byte("override shell"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("STARWATCH_WEB_DIR", directory)
	handler, _ := testHandler(t, "secret", 10)

	response := request(handler, http.MethodGet, "/", "")
	if response.Code != http.StatusOK || response.Body.String() != "override shell" {
		t.Fatalf("code=%d body=%q", response.Code, response.Body.String())
	}
}

func TestAlertTestEnqueuesNormalNotification(t *testing.T) {
	delivery := &alertDeliveryStub{}
	handler := NewServer(Deps{
		Token: "secret", Snapshot: snapshotStub{}, History: history.NewStore(1), AlertDelivery: delivery,
		Now: func() time.Time { return time.Unix(123, 0) },
	})

	if response := request(handler, http.MethodPost, "/api/alerts/test", ""); response.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated POST code=%d", response.Code)
	}
	if response := request(handler, http.MethodGet, "/api/alerts/test", "secret"); response.Code != http.StatusMethodNotAllowed {
		t.Fatalf("GET code=%d", response.Code)
	}
	response := request(handler, http.MethodPost, "/api/alerts/test", "secret")
	if response.Code != http.StatusAccepted || len(delivery.notifications) != 1 {
		t.Fatalf("POST code=%d notifications=%+v body=%s", response.Code, delivery.notifications, response.Body.String())
	}
	got := delivery.notifications[0]
	if got.Alert != "test" || got.Severity != alert.SeverityInfo || got.State != alert.StateFiring || got.At != 123 || got.Detail["test"] != true {
		t.Fatalf("notification=%+v", got)
	}
}

func TestControlEndpointAcceptsPostAndRejectsOtherMethods(t *testing.T) {
	controls := &controlStub{}
	handler := NewServer(Deps{Token: "secret", Snapshot: snapshotStub{}, History: history.NewStore(1), Controls: controls})
	response := requestBody(handler, http.MethodPost, "/api/control/snow-melt", "secret", `{"snow_melt_mode":"ALWAYS_ON"}`)
	if response.Code != http.StatusAccepted || controls.params.Action != "snow-melt" || controls.params.SnowMeltMode != "ALWAYS_ON" {
		t.Fatalf("code=%d params=%+v body=%s", response.Code, controls.params, response.Body.String())
	}
	if response := request(handler, http.MethodGet, "/api/control/reboot", "secret"); response.Code != http.StatusMethodNotAllowed {
		t.Fatalf("GET control code=%d", response.Code)
	}
}

func TestObstructionMapRefreshesStaleGridAndReturnsJSON(t *testing.T) {
	now := time.Date(2026, 7, 16, 12, 0, 0, 0, time.UTC)
	grid := &dish.ObstructionMap{Rows: 1, Cols: 2, SNR: []float32{0, 1}, FetchedAt: now}
	provider := &obstructionStub{snapshot: dish.Snapshot{Topology: dish.TopologyFull, DishReachable: true}, grid: grid}
	handler := NewServer(Deps{Token: "secret", Snapshot: provider, History: history.NewStore(1), Obstruction: provider, Now: func() time.Time { return now }})
	response := request(handler, http.MethodGet, "/api/obstruction-map", "secret")
	if response.Code != http.StatusOK || provider.refresh != 1 {
		t.Fatalf("code=%d refresh=%d body=%s", response.Code, provider.refresh, response.Body.String())
	}
	var decoded dish.ObstructionMap
	if err := json.Unmarshal(response.Body.Bytes(), &decoded); err != nil || decoded.Rows != 1 || len(decoded.SNR) != 2 {
		t.Fatalf("decoded=%+v err=%v", decoded, err)
	}
	provider.snapshot.DishReachable = false
	if response := request(handler, http.MethodGet, "/api/obstruction-map", "secret"); response.Code != http.StatusServiceUnavailable {
		t.Fatalf("unreachable code=%d", response.Code)
	}
}

func TestSpeedtestEndpointReportsConflictAndState(t *testing.T) {
	speedtests := &speedtestStub{state: dish.SpeedtestSnapshot{State: dish.SpeedtestRunning}, err: dish.ErrSpeedtestRunning}
	handler := NewServer(Deps{Token: "secret", Snapshot: snapshotStub{}, History: history.NewStore(1), Speedtest: speedtests})
	if response := request(handler, http.MethodPost, "/api/speedtest", "secret"); response.Code != http.StatusConflict {
		t.Fatalf("POST code=%d body=%s", response.Code, response.Body.String())
	}
	response := request(handler, http.MethodGet, "/api/speedtest", "secret")
	if response.Code != http.StatusOK || !bytes.Contains(response.Body.Bytes(), []byte(`"state":"running"`)) {
		t.Fatalf("GET code=%d body=%s", response.Code, response.Body.String())
	}
}

func TestFailoverAssistGETAndConflictPOST(t *testing.T) {
	provider := &failoverStub{result: mwan.AssistResult{Reason: "mwan3 is not installed", Proposed: []mwan.Change{}}}
	handler := NewServer(Deps{Token: "secret", Snapshot: snapshotStub{}, History: history.NewStore(1), WAN: wanStub{snapshot: dish.WANStatus{Interface: "wan"}}, FailoverAssist: provider})
	if response := request(handler, http.MethodGet, "/api/wan/failover-assist", "secret"); response.Code != http.StatusOK {
		t.Fatalf("GET code=%d", response.Code)
	}
	if response := request(handler, http.MethodPost, "/api/wan/failover-assist", "secret"); response.Code != http.StatusConflict || provider.applied != 0 {
		t.Fatalf("POST code=%d applied=%d", response.Code, provider.applied)
	}
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
	if snapshot.Topology != dish.TopologyFull || snapshot.Dish == nil || snapshot.Dish.LatencyMS != 42 || !snapshot.FieldAvailability[dish.FieldStatus].Available {
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
