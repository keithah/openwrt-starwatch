package dish

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	device "github.com/clarkzjw/starlink-grpc-golang/pkg/spacex.com/api/device"
)

func TestRouterPollerMarksSubfieldUnavailableAfterThreeFailures(t *testing.T) {
	failRadio := false
	fake := &fakeDishServer{handle: func(_ context.Context, request *device.Request) (*device.Response, error) {
		switch request.GetRequest().(type) {
		case *device.Request_GetDeviceInfo:
			return &device.Response{Response: &device.Response_GetDeviceInfo{GetDeviceInfo: &device.GetDeviceInfoResponse{DeviceInfo: &device.DeviceInfo{}}}}, nil
		case *device.Request_WifiGetClients:
			return &device.Response{Response: &device.Response_WifiGetClients{WifiGetClients: &device.WifiGetClientsResponse{}}}, nil
		case *device.Request_GetStatus:
			return &device.Response{Response: &device.Response_WifiGetStatus{WifiGetStatus: &device.WifiGetStatusResponse{}}}, nil
		case *device.Request_GetHistory:
			return &device.Response{Response: &device.Response_WifiGetHistory{WifiGetHistory: &device.WifiGetHistoryResponse{}}}, nil
		case *device.Request_WifiGetConfig:
			return &device.Response{Response: &device.Response_WifiGetConfig{WifiGetConfig: &device.WifiGetConfigResponse{WifiConfig: &device.WifiConfig{}}}}, nil
		case *device.Request_GetRadioStats:
			if failRadio {
				return nil, errors.New("radio unavailable")
			}
			return &device.Response{Response: &device.Response_GetRadioStats{GetRadioStats: &device.GetRadioStatsResponse{RadioStats: []*device.RadioStats{{Band: device.WifiConfig_RF_2GHZ}}}}}, nil
		case *device.Request_GetDiagnostics:
			return &device.Response{Response: &device.Response_WifiGetDiagnostics{WifiGetDiagnostics: &device.WifiGetDiagnosticsResponse{}}}, nil
		case *device.Request_GetNetworkInterfaces:
			return &device.Response{Response: &device.Response_GetNetworkInterfaces{GetNetworkInterfaces: &device.GetNetworkInterfacesResponse{}}}, nil
		default:
			return nil, errors.New("unexpected write RPC")
		}
	}}
	address := startFakeDish(t, fake)
	poller := NewRouterPoller(RouterPollerOptions{Topology: snapshotStubForRouter{snapshot: Snapshot{Topology: TopologyFull}}, ResolveGateway: func(context.Context) (string, error) { return address, nil }})
	poller.Poll(context.Background())
	failRadio = true
	for i := 0; i < 2; i++ {
		poller.Poll(context.Background())
		if !poller.Snapshot().Availability.RadioStats.Available {
			t.Fatalf("unavailable after %d failures", i+1)
		}
	}
	poller.Poll(context.Background())
	got := poller.Snapshot()
	if got.Availability.RadioStats.Available || len(got.Radios) != 1 {
		t.Fatalf("snapshot=%+v", got)
	}
}

func TestGatewayForDestinationPrefersSpecificDishRouteOverMultiWANDefault(t *testing.T) {
	routes := `Iface Destination Gateway Flags RefCnt Use Metric Mask MTU Window IRTT
connectify0 00000000 00000000 0001 0 0 0 00000080 0 0 0
rmnet_mhi0 00000000 010000C0 0003 0 0 1 00000000 0 0 0
eth0 00000000 0101A8C0 0003 0 0 2 00000000 0 0 0
eth0 0164A8C0 0101A8C0 0007 0 0 2 FFFFFFFF 0 0 0
`

	got, err := gatewayForDestination(strings.NewReader(routes), "192.168.100.1")
	if err != nil {
		t.Fatal(err)
	}
	if got != "192.168.1.1" {
		t.Fatalf("gateway=%q, want Starlink WAN gateway", got)
	}
}

func TestRouterPollerUsesOnlyReadOnlyRPCsAndBuildsSnapshot(t *testing.T) {
	now := time.Date(2026, 7, 16, 12, 0, 0, 0, time.UTC)
	fake := &fakeDishServer{handle: func(_ context.Context, request *device.Request) (*device.Response, error) {
		switch request.GetRequest().(type) {
		case *device.Request_WifiGetClients:
			return &device.Response{Response: &device.Response_WifiGetClients{WifiGetClients: &device.WifiGetClientsResponse{Clients: []*device.WifiClient{{}, {}}}}}, nil
		case *device.Request_GetStatus:
			return &device.Response{Response: &device.Response_WifiGetStatus{WifiGetStatus: &device.WifiGetStatusResponse{
				DeviceInfo: &device.DeviceInfo{HardwareVersion: "router-v3", SoftwareVersion: "2026.7"}, DeviceState: &device.DeviceState{UptimeS: 99}, PingLatencyMs: 3.5, PingDropRate: 0.25,
			}}}, nil
		case *device.Request_GetHistory:
			return &device.Response{Response: &device.Response_WifiGetHistory{WifiGetHistory: &device.WifiGetHistoryResponse{Current: 1, PingLatencyMs: []float32{3.5}, PingDropRate: []float32{.25}}}}, nil
		case *device.Request_WifiGetConfig:
			return &device.Response{Response: &device.Response_WifiGetConfig{WifiGetConfig: &device.WifiGetConfigResponse{WifiConfig: &device.WifiConfig{}}}}, nil
		case *device.Request_GetRadioStats:
			return &device.Response{Response: &device.Response_GetRadioStats{GetRadioStats: &device.GetRadioStatsResponse{}}}, nil
		case *device.Request_GetDiagnostics:
			return &device.Response{Response: &device.Response_WifiGetDiagnostics{WifiGetDiagnostics: &device.WifiGetDiagnosticsResponse{}}}, nil
		case *device.Request_GetNetworkInterfaces:
			return &device.Response{Response: &device.Response_GetNetworkInterfaces{GetNetworkInterfaces: &device.GetNetworkInterfacesResponse{}}}, nil
		default:
			t.Fatalf("unexpected router request %T", request.GetRequest())
			return &device.Response{}, nil
		}
	}}
	address := startFakeDish(t, fake)
	topology := snapshotStubForRouter{snapshot: Snapshot{Topology: TopologyFull}}
	poller := NewRouterPoller(RouterPollerOptions{
		Topology: topology, ResolveGateway: func(context.Context) (string, error) { return address, nil },
		Interval: time.Hour, Now: func() time.Time { return now },
	})
	poller.Poll(context.Background())
	got := poller.Snapshot()
	if got == nil || !got.Reachable || got.HardwareVersion != "router-v3" || got.SoftwareVersion != "2026.7" || got.ClientCount != 2 || got.UptimeSeconds != 99 {
		t.Fatalf("snapshot=%+v", got)
	}
	if got.PingLatencyMS == nil || *got.PingLatencyMS != 3.5 || got.PingDropRate == nil || *got.PingDropRate != 0.25 || got.LastPingSuccess == nil || !got.LastPingSuccess.Equal(now) {
		t.Fatalf("router ping snapshot=%+v", got)
	}
	fake.mu.Lock()
	defer fake.mu.Unlock()
	if len(fake.requests) != 3 {
		t.Fatalf("requests=%#v", fake.requests)
	}
}

type snapshotStubForRouter struct{ snapshot Snapshot }

func (s snapshotStubForRouter) Snapshot() Snapshot { return s.snapshot }
