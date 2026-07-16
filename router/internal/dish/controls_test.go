package dish

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	device "github.com/clarkzjw/starlink-grpc-golang/pkg/spacex.com/api/device"

	"starwatch/internal/event"
	"starwatch/internal/history"
)

type controlFake struct {
	configs []*device.DishConfig
	reboots int
	err     error
}

func (f *controlFake) Reboot(context.Context) error                  { f.reboots++; return f.err }
func (f *controlFake) DishStow(context.Context, bool) error          { return nil }
func (f *controlFake) DishInhibitGPS(context.Context, bool) error    { return nil }
func (f *controlFake) DishClearObstructionMap(context.Context) error { return nil }
func (f *controlFake) SoftwareUpdate(context.Context) error          { return nil }
func (f *controlFake) DishSetConfig(_ context.Context, config *device.DishConfig) error {
	f.configs = append(f.configs, config)
	return nil
}

func TestFailedControlIsAuditedWithError(t *testing.T) {
	events := &controlEvents{}
	controller := NewController(&controlFake{err: errors.New("rpc unavailable")}, &readbackFake{}, ControlOptions{Events: events})
	result, err := controller.Execute(context.Background(), ControlParams{Action: "reboot"})
	if err == nil || result.Accepted || len(events.events) != 1 || !strings.Contains(events.events[0].Detail, "rpc unavailable") {
		t.Fatalf("result=%+v err=%v events=%+v", result, err, events.events)
	}
}

func TestGPSControlRequiresExplicitEnabled(t *testing.T) {
	controller := NewController(&controlFake{}, &readbackFake{}, ControlOptions{})
	result, err := controller.Execute(context.Background(), ControlParams{Action: "gps"})
	if !errors.Is(err, ErrInvalidControl) || result.Accepted {
		t.Fatalf("result=%+v err=%v", result, err)
	}
}

type readbackFake struct{ calls int }

func (f *readbackFake) RefreshConfig(context.Context) (*ConfigReadback, error) {
	f.calls++
	return &ConfigReadback{SnowMeltMode: "ALWAYS_ON"}, nil
}
func (*readbackFake) InvalidateObstructionMap() {}

type controlEvents struct{ events []history.Event }

func (e *controlEvents) AddEvent(item history.Event) { e.events = append(e.events, item) }

func TestControllerSetsOnlyPairedApplyFlagsAndReadsBack(t *testing.T) {
	api := &controlFake{}
	readback := &readbackFake{}
	controller := NewController(api, readback, ControlOptions{})

	result, err := controller.Execute(context.Background(), ControlParams{Action: "snow-melt", SnowMeltMode: "ALWAYS_ON"})
	if err != nil {
		t.Fatal(err)
	}
	config := api.configs[0]
	if !config.ApplySnowMeltMode || config.SnowMeltMode != device.DishConfig_ALWAYS_ON ||
		config.ApplyPowerSaveMode || config.ApplyPowerSaveStartMinutes || config.ApplyPowerSaveDurationMinutes ||
		config.ApplyLocationRequestMode {
		t.Fatalf("snow config apply flags: %+v", config)
	}
	if readback.calls != 1 || result.Config == nil || result.Config.SnowMeltMode != "ALWAYS_ON" {
		t.Fatalf("readback calls=%d result=%+v", readback.calls, result)
	}

	enabled := true
	_, err = controller.Execute(context.Background(), ControlParams{Action: "sleep-schedule", Enabled: &enabled, StartMinutes: 60, DurationMinutes: 120})
	if err != nil {
		t.Fatal(err)
	}
	config = api.configs[1]
	if !config.ApplyPowerSaveMode || !config.ApplyPowerSaveStartMinutes || !config.ApplyPowerSaveDurationMinutes ||
		config.ApplySnowMeltMode || config.ApplyLocationRequestMode {
		t.Fatalf("sleep config apply flags: %+v", config)
	}
}

func TestSuccessfulRebootAuditsAndSetsExpectedOutageSuppression(t *testing.T) {
	now := time.Date(2026, 7, 16, 12, 0, 0, 0, time.UTC)
	api := &controlFake{}
	events := &controlEvents{}
	bus := event.NewBus()
	messages, cancel := bus.Subscribe(1)
	defer cancel()
	var alertUntil, outageUntil time.Time
	controller := NewController(api, &readbackFake{}, ControlOptions{
		Now: func() time.Time { return now }, Events: events, Live: bus,
		SuppressDishUnreachableUntil: func(until time.Time) { alertUntil = until },
		ExpectDishUnreachableUntil:   func(until time.Time) { outageUntil = until },
	})

	if _, err := controller.Execute(context.Background(), ControlParams{Action: "reboot"}); err != nil {
		t.Fatal(err)
	}
	want := now.Add(5 * time.Minute)
	if !alertUntil.Equal(want) || !outageUntil.Equal(want) || len(events.events) != 1 || events.events[0].Kind != "control" {
		t.Fatalf("alert=%v outage=%v events=%+v", alertUntil, outageUntil, events.events)
	}
	select {
	case message := <-messages:
		if message.Kind != "control" {
			t.Fatalf("live event: %+v", message)
		}
	default:
		t.Fatal("control action did not publish a live event")
	}
}
