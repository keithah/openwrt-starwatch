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
	}
	return f.handle(ctx, request)
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
