package dish

import (
	"context"
	"sync/atomic"
	"testing"
	"time"

	device "github.com/clarkzjw/starlink-grpc-golang/pkg/spacex.com/api/device"
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
			ObstructionStats: &device.DishObstructionStats{FractionObstructed: 0.25},
			AlignmentStats:   &device.AlignmentStats{TiltAngleDeg: 12},
			UpsuStats:        &device.DishUpsuStats{DishPower: 55},
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
	default:
		return &device.Response{}, nil
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
		RetryInterval: 10 * time.Millisecond, RPCTimeout: time.Second,
		Now: func() time.Time { return time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC) },
	})
	return poller, store
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
		return poller.Snapshot().Topology == TopologyFull && requestCount(fake, "status") >= 2 && requestCount(fake, "config") >= 1
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
	if available, tracked := availability[FieldStatus]; !tracked || available {
		t.Fatalf("status must be marked unavailable after three failures: %#v", availability)
	}
	poller.pollStatus(context.Background())
	if available := poller.Snapshot().FieldAvailability[FieldStatus]; !available {
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
