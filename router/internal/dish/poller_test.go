package dish

import (
	"bytes"
	"context"
	"encoding/json"
	"sync/atomic"
	"testing"
	"time"

	device "github.com/clarkzjw/starlink-grpc-golang/pkg/spacex.com/api/device"
	disablement "github.com/clarkzjw/starlink-grpc-golang/pkg/spacex.com/api/satellites/network/ut_disablement_codes"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"starwatch/internal/history"
)

func cannedResponse(request *device.Request) (*device.Response, error) {
	switch request.GetRequest().(type) {
	case *device.Request_GetStatus:
		return &device.Response{Response: &device.Response_DishGetStatus{DishGetStatus: &device.DishGetStatusResponse{
			DeviceState: &device.DeviceState{UptimeS: 99}, PopPingLatencyMs: 42,
			DownlinkThroughputBps: 1000, UplinkThroughputBps: 200,
			GpsStats: &device.DishGpsStats{
				GpsValid: true, GpsSats: 14, NoSatsAfterTtff: true, InhibitGps: false,
				PntFilterConvergenceState: device.AttitudeEstimationState_FILTER_CONVERGED,
			},
			SecondsToFirstNonemptySlot: 0.8,
			DisablementCode:            disablement.UtDisablementCode_OKAY,
			ObstructionStats:           &device.DishObstructionStats{FractionObstructed: 0.25},
			AlignmentStats:             &device.AlignmentStats{TiltAngleDeg: 12},
			UpsuStats:                  &device.DishUpsuStats{DishPower: 55},
		}}}, nil
	case *device.Request_GetDeviceInfo:
		return &device.Response{Response: &device.Response_GetDeviceInfo{GetDeviceInfo: &device.GetDeviceInfoResponse{DeviceInfo: &device.DeviceInfo{
			Id: "ut-test", HardwareVersion: "rev4", SoftwareVersion: "2026.1", CountryCode: "US",
		}}}}, nil
	case *device.Request_GetHistory:
		return &device.Response{Response: &device.Response_DishGetHistory{DishGetHistory: &device.DishGetHistoryResponse{
			Current: 3, PopPingLatencyMs: []float32{10, 20, 30}, PopPingDropRate: []float32{0, 0.1, 0.2},
			DownlinkThroughputBps: []float32{100, 200, 300}, UplinkThroughputBps: []float32{10, 20, 30}, PowerIn: []float32{40, 41, 42},
		}}}, nil
	case *device.Request_DishGetConfig:
		return &device.Response{Response: &device.Response_DishGetConfig{DishGetConfig: &device.DishGetConfigResponse{DishConfig: &device.DishConfig{
			SnowMeltMode: device.DishConfig_ALWAYS_OFF, PowerSaveMode: true, PowerSaveStartMinutes: 120, PowerSaveDurationMinutes: 60,
		}}}}, nil
	case *device.Request_GetLocation:
		return &device.Response{Response: &device.Response_GetLocation{GetLocation: &device.GetLocationResponse{Lla: &device.LLAPosition{Lat: 45, Lon: -122, Alt: 100}}}}, nil
	case *device.Request_DishGetObstructionMap:
		return &device.Response{Response: &device.Response_DishGetObstructionMap{DishGetObstructionMap: &device.DishGetObstructionMapResponse{
			NumRows: 1, NumCols: 2, Snr: []float32{0, 1}, MinElevationDeg: 25,
			MapReferenceFrame: device.ObstructionMapReferenceFrame_FRAME_EARTH,
		}}}, nil
	default:
		return &device.Response{}, nil
	}
}

func TestStatusIncludesTypedGPSAndDiagnosticEnums(t *testing.T) {
	fake := &fakeDishServer{handle: func(_ context.Context, request *device.Request) (*device.Response, error) {
		return cannedResponse(request)
	}}
	poller, _ := testPoller(t, fake)
	poller.backfillDone = true
	poller.pollStatus(context.Background())

	snapshot := poller.Snapshot()
	got := snapshot.Dish
	if got == nil || got.GPS == nil {
		t.Fatalf("dish status GPS missing: %+v", got)
	}
	if !got.GPS.Valid || got.GPS.Satellites != 14 || !got.GPS.NoSatellitesAfterTTFF || got.GPS.Inhibited {
		t.Fatalf("GPS=%+v", got.GPS)
	}
	if got.GPS.PNTFilterState != "FILTER_CONVERGED" || got.DisablementCode != "OKAY" || got.SecondsToFirstNonemptySlot != 0.8 {
		t.Fatalf("diagnostic fields=%+v", got)
	}
	encoded, err := json.Marshal(got)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(encoded, []byte(`"pnt_filter_state":"FILTER_CONVERGED"`)) || bytes.Contains(encoded, []byte(`"convergence_state"`)) {
		t.Fatalf("status JSON=%s", encoded)
	}
	if available := snapshot.FieldAvailability[FieldGPS]; !available.Available {
		t.Fatalf("GPS availability=%+v", available)
	}
}

func TestStatusOmitsAbsentGPSAndMarksItUnavailableAfterThreePolls(t *testing.T) {
	fake := &fakeDishServer{handle: func(_ context.Context, request *device.Request) (*device.Response, error) {
		response, err := cannedResponse(request)
		if status := response.GetDishGetStatus(); status != nil {
			status.GpsStats = nil
		}
		return response, err
	}}
	poller, _ := testPoller(t, fake)
	poller.backfillDone = true
	for range 3 {
		poller.pollStatus(context.Background())
	}

	snapshot := poller.Snapshot()
	if snapshot.Dish == nil || snapshot.Dish.GPS != nil {
		t.Fatalf("absent GPS rendered: %+v", snapshot.Dish)
	}
	availability, ok := snapshot.FieldAvailability[FieldGPS]
	if !ok || availability.Available || availability.Reason == "" {
		t.Fatalf("GPS availability=%+v tracked=%v", availability, ok)
	}
	encoded, err := json.Marshal(snapshot.Dish)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(encoded, []byte(`"gps"`)) {
		t.Fatalf("absent GPS JSON=%s", encoded)
	}
}

func TestLocationPollingIsOptInAndSurfacesPermissionReason(t *testing.T) {
	denied := false
	fake := &fakeDishServer{handle: func(_ context.Context, request *device.Request) (*device.Response, error) {
		if _, ok := request.GetRequest().(*device.Request_GetLocation); ok && denied {
			return nil, status.Error(codes.PermissionDenied, "not authorized")
		}
		return cannedResponse(request)
	}}
	poller, _ := testPoller(t, fake)
	poller.pollLocation(context.Background())
	if got := requestCount(fake, "location"); got != 0 {
		t.Fatalf("disabled location calls=%d", got)
	}
	poller.SetLocationEnabled(true)
	poller.pollLocation(context.Background())
	if got := poller.Snapshot().Location; got == nil || got.Latitude != 45 || got.Longitude != -122 || got.Altitude != 100 {
		t.Fatalf("location=%+v", got)
	}
	denied = true
	poller.pollLocation(context.Background())
	availability := poller.Snapshot().FieldAvailability[FieldLocation]
	if availability.Available || availability.Reason != locationOptInReason {
		t.Fatalf("availability=%+v", availability)
	}
}

func testPoller(t *testing.T, fake *fakeDishServer) (*Poller, *history.Store) {
	t.Helper()
	client, err := Dial(context.Background(), startFakeDish(t, fake))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = client.Close() })
	store := history.NewStore(100)
	poller := NewPoller(client, store, PollerOptions{
		StatusInterval: 10 * time.Millisecond, MetadataInterval: 20 * time.Millisecond,
		HistoryInterval: 30 * time.Millisecond, RetryInterval: 10 * time.Millisecond, RPCTimeout: time.Second,
		Now: func() time.Time { return time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC) },
	})
	return poller, store
}

func TestPollerDefaultRPCTimeoutIsTwoSeconds(t *testing.T) {
	poller := NewPoller(nil, history.NewStore(1), PollerOptions{})
	if poller.options.RPCTimeout != 2*time.Second {
		t.Fatalf("timeout: got %v", poller.options.RPCTimeout)
	}
}

func waitFor(t *testing.T, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if condition() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("condition not reached")
}

func requestCount(fake *fakeDishServer, name string) int {
	fake.mu.Lock()
	defer fake.mu.Unlock()
	count := 0
	for _, request := range fake.requests {
		if request == name {
			count++
		}
	}
	return count
}

func TestPollerPollsAndBackfillsHistory(t *testing.T) {
	fake := &fakeDishServer{handle: func(_ context.Context, request *device.Request) (*device.Response, error) {
		return cannedResponse(request)
	}}
	poller, store := testPoller(t, fake)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { poller.Run(ctx); close(done) }()

	waitFor(t, func() bool {
		return poller.Snapshot().Topology == TopologyFull && requestCount(fake, "status") >= 2 && requestCount(fake, "config") >= 1 && requestCount(fake, "obstruction_map") >= 1
	})
	points, err := store.Query(history.LatencyMS, time.Time{}, 1000)
	if err != nil {
		t.Fatal(err)
	}
	if len(points) < 3 || points[0].Value != 10 || points[1].Value != 20 || points[2].Value != 30 {
		t.Fatalf("backfill: %#v", points)
	}
	snapshot := poller.Snapshot()
	if snapshot.Dish == nil || snapshot.Dish.LatencyMS != 42 || snapshot.DeviceInfo == nil || snapshot.Config == nil {
		t.Fatalf("snapshot: %+v", snapshot)
	}
	if snapshot.ObstructionMap == nil || snapshot.ObstructionMap.Rows != 1 || snapshot.ObstructionMap.ReferenceFrame != "FRAME_EARTH" {
		t.Fatalf("obstruction map: %+v", snapshot.ObstructionMap)
	}

	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("poller did not stop")
	}
}

func TestPollerMarksUnavailableAfterThreeFailuresAndClearsOnSuccess(t *testing.T) {
	var statusCalls atomic.Int32
	fake := &fakeDishServer{handle: func(_ context.Context, request *device.Request) (*device.Response, error) {
		if _, ok := request.GetRequest().(*device.Request_GetStatus); ok && statusCalls.Add(1) <= 3 {
			return nil, status.Error(codes.Unavailable, "dish rebooting")
		}
		return cannedResponse(request)
	}}
	poller, _ := testPoller(t, fake)
	for i := 0; i < 3; i++ {
		poller.pollStatus(context.Background())
	}
	availability := poller.Snapshot().FieldAvailability
	if available, tracked := availability[FieldStatus]; !tracked || available.Available {
		t.Fatalf("status must be marked unavailable after three failures: %#v", availability)
	}
	poller.pollStatus(context.Background())
	if available := poller.Snapshot().FieldAvailability[FieldStatus]; !available.Available {
		t.Fatalf("status must recover on first success: %#v", poller.Snapshot().FieldAvailability)
	}
}

func TestPollerWANOnlyRetriesDiscovery(t *testing.T) {
	var infoCalls atomic.Int32
	fake := &fakeDishServer{handle: func(_ context.Context, request *device.Request) (*device.Response, error) {
		if _, ok := request.GetRequest().(*device.Request_GetDeviceInfo); ok && infoCalls.Add(1) <= 2 {
			return nil, status.Error(codes.Unavailable, "no route")
		}
		return cannedResponse(request)
	}}
	poller, _ := testPoller(t, fake)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go poller.Run(ctx)

	waitFor(t, func() bool { return poller.Snapshot().Topology == TopologyWANOnly })
	waitFor(t, func() bool { return poller.Snapshot().Topology == TopologyFull })
	if infoCalls.Load() < 3 {
		t.Fatalf("discovery calls: %d", infoCalls.Load())
	}
}

type countingRouteEnsurer struct{ calls atomic.Int32 }

func (e *countingRouteEnsurer) Ensure(context.Context) error {
	e.calls.Add(1)
	return nil
}

func TestPollerEnsuresDishRouteAtStartup(t *testing.T) {
	fake := &fakeDishServer{handle: func(_ context.Context, request *device.Request) (*device.Response, error) {
		return cannedResponse(request)
	}}
	poller, _ := testPoller(t, fake)
	ensurer := &countingRouteEnsurer{}
	poller.options.RouteEnsurer = ensurer
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { poller.Run(ctx); close(done) }()
	waitFor(t, func() bool { return poller.Snapshot().Topology == TopologyFull })
	cancel()
	<-done
	if got := ensurer.calls.Load(); got != 1 {
		t.Fatalf("route ensure calls=%d want=1", got)
	}
}

func TestPollerReassertsDishRouteBeforeWANOnlyRetry(t *testing.T) {
	var infoCalls atomic.Int32
	fake := &fakeDishServer{handle: func(_ context.Context, request *device.Request) (*device.Response, error) {
		if _, ok := request.GetRequest().(*device.Request_GetDeviceInfo); ok && infoCalls.Add(1) <= 1 {
			return nil, status.Error(codes.Unavailable, "no route")
		}
		return cannedResponse(request)
	}}
	poller, _ := testPoller(t, fake)
	ensurer := &countingRouteEnsurer{}
	poller.options.RouteEnsurer = ensurer
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go poller.Run(ctx)
	waitFor(t, func() bool { return poller.Snapshot().Topology == TopologyFull })
	if got := ensurer.calls.Load(); got < 2 {
		t.Fatalf("route ensure calls=%d, want startup and retry", got)
	}
}

func TestRecoveryBackfillKeepsHistoryStrictlyIncreasing(t *testing.T) {
	now := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	statusFails := false
	fake := &fakeDishServer{handle: func(_ context.Context, request *device.Request) (*device.Response, error) {
		switch request.GetRequest().(type) {
		case *device.Request_GetStatus:
			if statusFails {
				return nil, status.Error(codes.Unavailable, "outage")
			}
			return cannedResponse(request)
		case *device.Request_GetHistory:
			return &device.Response{Response: &device.Response_DishGetHistory{DishGetHistory: &device.DishGetHistoryResponse{
				Current: 3, PopPingLatencyMs: []float32{42, 43, 44},
			}}}, nil
		default:
			return cannedResponse(request)
		}
	}}
	client, err := Dial(context.Background(), startFakeDish(t, fake))
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	store := history.NewStore(20)
	poller := NewPoller(client, store, PollerOptions{RPCTimeout: time.Second, Now: func() time.Time { return now }})
	poller.backfillDone = true

	poller.pollStatus(context.Background())
	statusFails = true
	for range 3 {
		poller.pollStatus(context.Background())
	}
	statusFails = false
	now = now.Add(2 * time.Second)
	if !poller.discover(context.Background()) {
		t.Fatal("discovery did not recover")
	}
	poller.backfill(context.Background())
	poller.pollStatus(context.Background())

	points, err := store.Query(history.LatencyMS, time.Time{}, 1000)
	if err != nil {
		t.Fatal(err)
	}
	if len(points) != 3 {
		t.Fatalf("points: %#v", points)
	}
	for i := 1; i < len(points); i++ {
		if !points[i].Time.After(points[i-1].Time) {
			t.Fatalf("timestamps not strictly increasing: %#v", points)
		}
	}
}

func TestBackfillDecodesWrappedHistoryRing(t *testing.T) {
	now := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	fake := &fakeDishServer{handle: func(_ context.Context, request *device.Request) (*device.Response, error) {
		if _, ok := request.GetRequest().(*device.Request_GetHistory); ok {
			return &device.Response{Response: &device.Response_DishGetHistory{DishGetHistory: &device.DishGetHistoryResponse{
				Current: 5, PopPingLatencyMs: []float32{30, 40, 20},
			}}}, nil
		}
		return cannedResponse(request)
	}}
	poller, store := testPoller(t, fake)
	poller.options.Now = func() time.Time { return now }
	poller.backfill(context.Background())
	points, err := store.Query(history.LatencyMS, time.Time{}, 1000)
	if err != nil {
		t.Fatal(err)
	}
	if len(points) != 3 || points[0].Value != 20 || points[1].Value != 30 || points[2].Value != 40 {
		t.Fatalf("wrapped points: %#v", points)
	}
}

func TestHistoryReconciliationSuppliesPowerFallback(t *testing.T) {
	fake := &fakeDishServer{handle: func(_ context.Context, request *device.Request) (*device.Response, error) {
		response, err := cannedResponse(request)
		if statusResponse := response.GetDishGetStatus(); statusResponse != nil {
			statusResponse.UpsuStats = nil
		}
		return response, err
	}}
	poller, store := testPoller(t, fake)
	poller.options.HistoryInterval = 10 * time.Millisecond
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go poller.Run(ctx)
	waitFor(t, func() bool { return requestCount(fake, "history") >= 2 })
	snapshot := poller.Snapshot()
	if snapshot.Dish == nil || snapshot.Dish.PowerW == nil || *snapshot.Dish.PowerW != 42 {
		t.Fatalf("power fallback: %+v", snapshot.Dish)
	}
	points, err := store.Query(history.PowerW, time.Time{}, 1000)
	if err != nil || len(points) == 0 || points[len(points)-1].Value != 42 {
		t.Fatalf("power history: points=%#v err=%v", points, err)
	}
}

func TestMetadataRefreshUpdatesHistoryPowerSource(t *testing.T) {
	var historyCalls atomic.Int32
	fake := &fakeDishServer{handle: func(_ context.Context, request *device.Request) (*device.Response, error) {
		response, err := cannedResponse(request)
		if statusResponse := response.GetDishGetStatus(); statusResponse != nil {
			statusResponse.UpsuStats = nil
		}
		if historyResponse := response.GetDishGetHistory(); historyResponse != nil {
			call := historyCalls.Add(1)
			historyResponse.Current = 1
			historyResponse.PowerIn = []float32{40 + float32(call)}
		}
		return response, err
	}}
	poller, _ := testPoller(t, fake)
	poller.options.MetadataInterval = 10 * time.Millisecond
	poller.options.HistoryInterval = time.Hour
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go poller.Run(ctx)

	waitFor(t, func() bool {
		snapshot := poller.Snapshot()
		return historyCalls.Load() >= 2 && snapshot.Dish != nil && snapshot.Dish.PowerW != nil &&
			*snapshot.Dish.PowerW >= 42 && snapshot.Dish.PowerSource == "history"
	})
	snapshot := poller.Snapshot()
	if snapshot.Dish == nil || snapshot.Dish.PowerW == nil || *snapshot.Dish.PowerW < 42 || snapshot.Dish.PowerSource != "history" {
		t.Fatalf("metadata power fallback: %+v", snapshot.Dish)
	}
}

func TestStatusPowerIsLabeledAsStatusSource(t *testing.T) {
	fake := &fakeDishServer{handle: func(_ context.Context, request *device.Request) (*device.Response, error) {
		return cannedResponse(request)
	}}
	poller, _ := testPoller(t, fake)
	poller.pollStatus(context.Background())
	if got := poller.Snapshot().Dish; got == nil || got.PowerSource != "status" {
		t.Fatalf("status power source: %+v", got)
	}
}

func TestZeroStatusPowerUsesNonzeroHistoryFallback(t *testing.T) {
	fake := &fakeDishServer{handle: func(_ context.Context, request *device.Request) (*device.Response, error) {
		response, err := cannedResponse(request)
		if statusResponse := response.GetDishGetStatus(); statusResponse != nil {
			statusResponse.UpsuStats.DishPower = 0
		}
		return response, err
	}}
	poller, _ := testPoller(t, fake)
	poller.backfill(context.Background())
	poller.pollStatus(context.Background())
	got := poller.Snapshot().Dish
	if got == nil || got.PowerW == nil || *got.PowerW != 42 || got.PowerSource != "history" {
		t.Fatalf("zero status power fallback: %+v", got)
	}
	if poller.usesStatusPower() {
		t.Fatal("zero status power was treated as usable")
	}
}

func TestZeroStatusPowerWithoutFallbackIsUnavailable(t *testing.T) {
	fake := &fakeDishServer{handle: func(_ context.Context, request *device.Request) (*device.Response, error) {
		response, err := cannedResponse(request)
		if statusResponse := response.GetDishGetStatus(); statusResponse != nil {
			statusResponse.UpsuStats.DishPower = 0
		}
		return response, err
	}}
	poller, _ := testPoller(t, fake)
	poller.backfillDone = true
	poller.pollStatus(context.Background())
	got := poller.Snapshot().Dish
	if got == nil || got.PowerW != nil || got.PowerSource != "" {
		t.Fatalf("fake zero power rendered: %+v", got)
	}
}

func TestSaneClockTriggersDeferredBackfill(t *testing.T) {
	now := time.Date(2024, 1, 1, 0, 0, 0, 0, time.UTC)
	fake := &fakeDishServer{handle: func(_ context.Context, request *device.Request) (*device.Response, error) {
		return cannedResponse(request)
	}}
	poller, store := testPoller(t, fake)
	poller.options.Now = func() time.Time { return now }
	if !poller.discover(context.Background()) {
		t.Fatal("discovery failed")
	}
	poller.backfill(context.Background())
	poller.pollStatus(context.Background())
	if got := requestCount(fake, "history"); got != 0 {
		t.Fatalf("history calls with bad clock: %d", got)
	}

	now = time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	poller.pollStatus(context.Background())
	if got := requestCount(fake, "history"); got != 1 {
		t.Fatalf("history calls after sane clock: %d", got)
	}
	points, err := store.Query(history.LatencyMS, time.Time{}, 1000)
	if err != nil || len(points) < 3 {
		t.Fatalf("deferred backfill: points=%#v err=%v", points, err)
	}
}

func TestSnapshotUsesStableStringEnumsAndNamedAlerts(t *testing.T) {
	fake := &fakeDishServer{handle: func(_ context.Context, request *device.Request) (*device.Response, error) {
		response, err := cannedResponse(request)
		if statusResponse := response.GetDishGetStatus(); statusResponse != nil {
			statusResponse.Outage = &device.DishOutage{Cause: device.DishOutage_OBSTRUCTED, DurationNs: uint64(time.Second)}
			statusResponse.Alerts = &device.DishAlerts{ThermalThrottle: true, DishWaterDetected: true}
		}
		return response, err
	}}
	poller, _ := testPoller(t, fake)
	poller.pollStatus(context.Background())
	got := poller.Snapshot().Dish
	if got.Outage == nil || got.Outage.Cause != "OBSTRUCTED" {
		t.Fatalf("outage: %+v", got.Outage)
	}
	if !got.Alerts["thermal_throttle"] || !got.Alerts["dish_water_detected"] {
		t.Fatalf("alerts: %#v", got.Alerts)
	}
}

func TestBackfillSurfacesDishReportedOutages(t *testing.T) {
	start := time.Date(2026, 7, 15, 11, 55, 0, 0, time.UTC)
	fake := &fakeDishServer{handle: func(_ context.Context, request *device.Request) (*device.Response, error) {
		response, err := cannedResponse(request)
		if historyResponse := response.GetDishGetHistory(); historyResponse != nil {
			historyResponse.Outages = []*device.DishOutage{{
				Cause: device.DishOutage_OBSTRUCTED, StartTimestampNs: start.UnixNano(), DurationNs: uint64(45 * time.Second),
			}}
		}
		return response, err
	}}
	poller, _ := testPoller(t, fake)
	poller.backfill(context.Background())

	got := poller.Snapshot().HistoryOutages
	if len(got) != 1 || got[0].Cause != "OBSTRUCTED" || !got[0].Start.Equal(start) || got[0].Duration != 45*time.Second {
		t.Fatalf("history outages: %#v", got)
	}
}

func TestSnapshotTracksDishFailureSpanAndRecovery(t *testing.T) {
	now := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	failing := true
	fake := &fakeDishServer{handle: func(_ context.Context, request *device.Request) (*device.Response, error) {
		if _, ok := request.GetRequest().(*device.Request_GetStatus); ok && failing {
			return nil, status.Error(codes.Unavailable, "offline")
		}
		return cannedResponse(request)
	}}
	poller, _ := testPoller(t, fake)
	poller.options.Now = func() time.Time { return now }
	poller.pollStatus(context.Background())
	snapshot := poller.Snapshot()
	if snapshot.DishReachable || snapshot.DishFailureSince == nil || !snapshot.DishFailureSince.Equal(now) {
		t.Fatalf("failure snapshot: %+v", snapshot)
	}
	now = now.Add(time.Minute)
	failing = false
	poller.pollStatus(context.Background())
	snapshot = poller.Snapshot()
	if !snapshot.DishReachable || snapshot.DishFailureSince != nil {
		t.Fatalf("recovery snapshot: %+v", snapshot)
	}
}
