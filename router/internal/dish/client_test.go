package dish

import (
	"context"
	"net"
	"sync"
	"testing"
	"time"

	device "github.com/clarkzjw/starlink-grpc-golang/pkg/spacex.com/api/device"
	"google.golang.org/grpc"
)

type fakeDishServer struct {
	device.UnimplementedDeviceServer
	mu       sync.Mutex
	requests []string
	handle   func(context.Context, *device.Request) (*device.Response, error)
}

func (f *fakeDishServer) Handle(ctx context.Context, request *device.Request) (*device.Response, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	switch request.GetRequest().(type) {
	case *device.Request_GetStatus:
		f.requests = append(f.requests, "status")
	case *device.Request_GetDeviceInfo:
		f.requests = append(f.requests, "device_info")
	case *device.Request_GetHistory:
		f.requests = append(f.requests, "history")
	case *device.Request_DishGetConfig:
		f.requests = append(f.requests, "config")
	case *device.Request_GetLocation:
		f.requests = append(f.requests, "location")
	case *device.Request_WifiGetClients:
		f.requests = append(f.requests, "wifi_clients")
	case *device.Request_DishGetObstructionMap:
		f.requests = append(f.requests, "obstruction_map")
	case *device.Request_Reboot:
		f.requests = append(f.requests, "reboot")
	case *device.Request_DishStow:
		f.requests = append(f.requests, "stow")
	case *device.Request_DishSetConfig:
		f.requests = append(f.requests, "set_config")
	case *device.Request_DishInhibitGps:
		f.requests = append(f.requests, "gps")
	case *device.Request_DishClearObstructionMap:
		f.requests = append(f.requests, "clear_map")
	case *device.Request_SoftwareUpdate:
		f.requests = append(f.requests, "software_update")
	case *device.Request_StartSpeedtest:
		f.requests = append(f.requests, "start_speedtest")
	case *device.Request_GetSpeedtestStatus:
		f.requests = append(f.requests, "speedtest_status")
	}
	return f.handle(ctx, request)
}

func TestClientGetLocationWrapper(t *testing.T) {
	fake := &fakeDishServer{handle: func(_ context.Context, request *device.Request) (*device.Response, error) {
		if _, ok := request.GetRequest().(*device.Request_GetLocation); ok {
			return &device.Response{Response: &device.Response_GetLocation{GetLocation: &device.GetLocationResponse{Lla: &device.LLAPosition{Lat: 1, Lon: 2, Alt: 3}}}}, nil
		}
		return &device.Response{}, nil
	}}
	client, err := Dial(context.Background(), startFakeDish(t, fake))
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	location, err := client.GetLocation(context.Background())
	if err != nil || location.GetLla().GetLat() != 1 {
		t.Fatalf("location=%+v err=%v", location, err)
	}
}

func TestClientTypedControlMapAndSpeedtestWrappers(t *testing.T) {
	var unstow, inhibitGPS bool
	var setConfig *device.DishConfig
	var speedtestDuration int32
	fake := &fakeDishServer{handle: func(_ context.Context, request *device.Request) (*device.Response, error) {
		switch typed := request.GetRequest().(type) {
		case *device.Request_DishGetObstructionMap:
			return &device.Response{Response: &device.Response_DishGetObstructionMap{DishGetObstructionMap: &device.DishGetObstructionMapResponse{NumRows: 1, NumCols: 2, Snr: []float32{0, 1}}}}, nil
		case *device.Request_Reboot:
			return &device.Response{Response: &device.Response_Reboot{Reboot: &device.RebootResponse{}}}, nil
		case *device.Request_DishStow:
			unstow = typed.DishStow.GetUnstow()
			return &device.Response{Response: &device.Response_DishStow{DishStow: &device.DishStowResponse{}}}, nil
		case *device.Request_DishSetConfig:
			setConfig = typed.DishSetConfig.GetDishConfig()
			return &device.Response{Response: &device.Response_DishSetConfig{DishSetConfig: &device.DishSetConfigResponse{}}}, nil
		case *device.Request_DishInhibitGps:
			inhibitGPS = typed.DishInhibitGps.GetInhibitGps()
			return &device.Response{Response: &device.Response_DishInhibitGps{DishInhibitGps: &device.DishInhibitGpsResponse{}}}, nil
		case *device.Request_DishClearObstructionMap:
			return &device.Response{Response: &device.Response_DishClearObstructionMap{DishClearObstructionMap: &device.DishClearObstructionMapResponse{}}}, nil
		case *device.Request_SoftwareUpdate:
			return &device.Response{Response: &device.Response_SoftwareUpdate{SoftwareUpdate: &device.SoftwareUpdateResponse{}}}, nil
		case *device.Request_StartSpeedtest:
			speedtestDuration = typed.StartSpeedtest.GetDurationS()
			return &device.Response{Response: &device.Response_StartSpeedtest{StartSpeedtest: &device.StartSpeedtestResponse{}}}, nil
		case *device.Request_GetSpeedtestStatus:
			return &device.Response{Response: &device.Response_GetSpeedtestStatus{GetSpeedtestStatus: &device.GetSpeedtestStatusResponse{Status: &device.SpeedtestStatus{Running: true}}}}, nil
		default:
			return &device.Response{}, nil
		}
	}}
	client, err := Dial(context.Background(), startFakeDish(t, fake))
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	ctx := context.Background()
	grid, err := client.DishGetObstructionMap(ctx)
	if err != nil || grid.GetNumCols() != 2 {
		t.Fatalf("map=%+v err=%v", grid, err)
	}
	for _, call := range []func() error{
		func() error { return client.Reboot(ctx) },
		func() error { return client.DishStow(ctx, true) },
		func() error { return client.DishSetConfig(ctx, &device.DishConfig{ApplySnowMeltMode: true}) },
		func() error { return client.DishInhibitGPS(ctx, true) },
		func() error { return client.DishClearObstructionMap(ctx) },
		func() error { return client.SoftwareUpdate(ctx) },
		func() error { return client.StartSpeedtest(ctx) },
	} {
		if err := call(); err != nil {
			t.Fatal(err)
		}
	}
	status, err := client.GetSpeedtestStatus(ctx)
	if err != nil || !status.GetRunning() {
		t.Fatalf("status=%+v err=%v", status, err)
	}
	if !unstow || !inhibitGPS || setConfig == nil || !setConfig.GetApplySnowMeltMode() || speedtestDuration <= 0 {
		t.Fatalf("request payloads: unstow=%v inhibit=%v config=%+v duration=%d", unstow, inhibitGPS, setConfig, speedtestDuration)
	}
}

func startFakeDish(t *testing.T, fake *fakeDishServer) string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := grpc.NewServer()
	device.RegisterDeviceServer(server, fake)
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(func() {
		server.Stop()
		_ = listener.Close()
	})
	return listener.Addr().String()
}

func TestClientTypedReadWrappers(t *testing.T) {
	fake := &fakeDishServer{handle: func(_ context.Context, request *device.Request) (*device.Response, error) {
		switch request.GetRequest().(type) {
		case *device.Request_GetStatus:
			return &device.Response{Response: &device.Response_DishGetStatus{DishGetStatus: &device.DishGetStatusResponse{PopPingLatencyMs: 42}}}, nil
		case *device.Request_GetDeviceInfo:
			return &device.Response{Response: &device.Response_GetDeviceInfo{GetDeviceInfo: &device.GetDeviceInfoResponse{DeviceInfo: &device.DeviceInfo{Id: "ut-test"}}}}, nil
		case *device.Request_GetHistory:
			return &device.Response{Response: &device.Response_DishGetHistory{DishGetHistory: &device.DishGetHistoryResponse{Current: 2, PopPingLatencyMs: []float32{1, 2}}}}, nil
		case *device.Request_DishGetConfig:
			return &device.Response{Response: &device.Response_DishGetConfig{DishGetConfig: &device.DishGetConfigResponse{DishConfig: &device.DishConfig{}}}}, nil
		default:
			return &device.Response{}, nil
		}
	}}
	client, err := Dial(context.Background(), startFakeDish(t, fake))
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	status, err := client.GetStatus(ctx)
	if err != nil || status.GetPopPingLatencyMs() != 42 {
		t.Fatalf("status=%+v err=%v", status, err)
	}
	info, err := client.GetDeviceInfo(ctx)
	if err != nil || info.GetId() != "ut-test" {
		t.Fatalf("info=%+v err=%v", info, err)
	}
	history, err := client.GetHistory(ctx)
	if err != nil || history.GetCurrent() != 2 {
		t.Fatalf("history=%+v err=%v", history, err)
	}
	config, err := client.DishGetConfig(ctx)
	if err != nil || config == nil {
		t.Fatalf("config=%+v err=%v", config, err)
	}

	fake.mu.Lock()
	defer fake.mu.Unlock()
	want := []string{"status", "device_info", "history", "config"}
	if len(fake.requests) != len(want) {
		t.Fatalf("requests: %#v", fake.requests)
	}
	for i := range want {
		if fake.requests[i] != want[i] {
			t.Fatalf("requests: %#v", fake.requests)
		}
	}
}
