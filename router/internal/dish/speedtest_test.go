package dish

import (
	"context"
	"errors"
	"testing"
	"time"

	device "github.com/clarkzjw/starlink-grpc-golang/pkg/spacex.com/api/device"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"starwatch/internal/event"
	"starwatch/internal/history"
)

type speedFake struct {
	statuses []*device.SpeedtestStatus
	err      error
	calls    int
	startErr error
	starts   int
}

func (f *speedFake) StartSpeedtest(context.Context) error {
	f.starts++
	return f.startErr
}
func (f *speedFake) GetSpeedtestStatus(context.Context) (*device.SpeedtestStatus, error) {
	f.calls++
	if f.err != nil {
		return nil, f.err
	}
	if len(f.statuses) == 0 {
		return &device.SpeedtestStatus{Running: true}, nil
	}
	result := f.statuses[0]
	f.statuses = f.statuses[1:]
	return result, nil
}

type speedSink struct{ results []history.Speedtest }

func (s *speedSink) AddSpeedtest(result history.Speedtest) { s.results = append(s.results, result) }

func TestSpeedtestManagerCompletesPersistsAndRejectsConcurrentStart(t *testing.T) {
	api := &speedFake{statuses: []*device.SpeedtestStatus{
		{Running: true},
		{Down: &device.SpeedtestStatus_Direction{ThroughputsMbps: []float32{10, 20}}, Up: &device.SpeedtestStatus_Direction{ThroughputsMbps: []float32{3, 4}}},
	}}
	sink := &speedSink{}
	bus := event.NewBus()
	messages, cancel := bus.Subscribe(1)
	defer cancel()
	manager := NewSpeedtestManager(api, SpeedtestOptions{PollInterval: time.Millisecond, Store: sink, Live: bus})
	if err := manager.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := manager.Start(context.Background()); !errors.Is(err, ErrSpeedtestRunning) {
		t.Fatalf("concurrent start error = %v", err)
	}
	deadline := time.Now().Add(time.Second)
	for manager.Snapshot().State == SpeedtestRunning && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	snapshot := manager.Snapshot()
	if snapshot.State != SpeedtestDone || snapshot.Latest == nil || snapshot.Latest.DownBPS != 20_000_000 || snapshot.Latest.UpBPS != 4_000_000 {
		t.Fatalf("snapshot: %+v", snapshot)
	}
	if len(sink.results) != 1 {
		t.Fatalf("persisted: %#v", sink.results)
	}
	select {
	case message := <-messages:
		if message.Kind != "speedtest_completed" {
			t.Fatalf("live event: %+v", message)
		}
	case <-time.After(time.Second):
		t.Fatal("completed speed test did not publish an event")
	}
}

func TestSpeedtestManagerReportsUnsupportedAfterThreeStatusFailures(t *testing.T) {
	api := &speedFake{err: status.Error(codes.Unimplemented, "not supported")}
	manager := NewSpeedtestManager(api, SpeedtestOptions{PollInterval: time.Millisecond})
	if err := manager.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(time.Second)
	for manager.Snapshot().State == SpeedtestRunning && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if got := manager.Snapshot().State; got != SpeedtestUnsupported || api.calls != 3 {
		t.Fatalf("state=%q calls=%d", got, api.calls)
	}
}

func TestSpeedtestManagerReportsUnsupportedAfterThreeStartFailures(t *testing.T) {
	api := &speedFake{startErr: status.Error(codes.Unavailable, "not supported")}
	manager := NewSpeedtestManager(api, SpeedtestOptions{PollInterval: time.Millisecond})
	if err := manager.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := manager.Snapshot().State; got != SpeedtestUnsupported || api.starts != 3 {
		t.Fatalf("state=%q starts=%d", got, api.starts)
	}
}
