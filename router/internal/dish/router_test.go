package dish

import (
	"context"
	"testing"
	"time"

	device "github.com/clarkzjw/starlink-grpc-golang/pkg/spacex.com/api/device"
)

func TestRouterPollerUsesOnlyReadOnlyRPCsAndBuildsSnapshot(t *testing.T) {
	fake := &fakeDishServer{handle: func(_ context.Context, request *device.Request) (*device.Response, error) {
		switch request.GetRequest().(type) {
		case *device.Request_GetDeviceInfo:
			return &device.Response{Response: &device.Response_GetDeviceInfo{GetDeviceInfo: &device.GetDeviceInfoResponse{DeviceInfo: &device.DeviceInfo{HardwareVersion: "router-v3", SoftwareVersion: "2026.7"}}}}, nil
		case *device.Request_WifiGetClients:
			return &device.Response{Response: &device.Response_WifiGetClients{WifiGetClients: &device.WifiGetClientsResponse{Clients: []*device.WifiClient{{}, {}}}}}, nil
		case *device.Request_GetStatus:
			return &device.Response{Response: &device.Response_WifiGetStatus{WifiGetStatus: &device.WifiGetStatusResponse{DeviceState: &device.DeviceState{UptimeS: 99}}}}, nil
		default:
			t.Fatalf("unexpected router request %T", request.GetRequest())
			return &device.Response{}, nil
		}
	}}
	address := startFakeDish(t, fake)
	topology := snapshotStubForRouter{snapshot: Snapshot{Topology: TopologyFull}}
	poller := NewRouterPoller(RouterPollerOptions{
		Topology: topology, ResolveGateway: func(context.Context) (string, error) { return address, nil },
		Interval: time.Hour,
	})
	poller.Poll(context.Background())
	got := poller.Snapshot()
	if got == nil || !got.Reachable || got.HardwareVersion != "router-v3" || got.SoftwareVersion != "2026.7" || got.ClientCount != 2 || got.UptimeSeconds != 99 {
		t.Fatalf("snapshot=%+v", got)
	}
	fake.mu.Lock()
	defer fake.mu.Unlock()
	if len(fake.requests) != 3 {
		t.Fatalf("requests=%#v", fake.requests)
	}
}

type snapshotStubForRouter struct{ snapshot Snapshot }

func (s snapshotStubForRouter) Snapshot() Snapshot { return s.snapshot }
