package dish

import (
	"context"
	"errors"
	"math"
	"sync"
	"time"

	device "github.com/clarkzjw/starlink-grpc-golang/pkg/spacex.com/api/device"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"starwatch/internal/event"
	"starwatch/internal/history"
)

type SpeedtestState string

const (
	SpeedtestIdle        SpeedtestState = "idle"
	SpeedtestRunning     SpeedtestState = "running"
	SpeedtestDone        SpeedtestState = "done"
	SpeedtestUnsupported SpeedtestState = "unsupported"
	SpeedtestError       SpeedtestState = "error"
)

var ErrSpeedtestRunning = errors.New("speed test already running")

type SpeedtestSnapshot struct {
	State  SpeedtestState     `json:"state"`
	Latest *history.Speedtest `json:"latest,omitempty"`
	Error  string             `json:"error,omitempty"`
}

type speedtestAPI interface {
	StartSpeedtest(context.Context) error
	GetSpeedtestStatus(context.Context) (*device.SpeedtestStatus, error)
}

type speedtestSink interface {
	AddSpeedtest(history.Speedtest)
}

type SpeedtestOptions struct {
	Context      context.Context
	PollInterval time.Duration
	Now          func() time.Time
	Store        speedtestSink
	Live         event.Publisher
}

type SpeedtestManager struct {
	api     speedtestAPI
	options SpeedtestOptions
	mu      sync.RWMutex
	state   SpeedtestSnapshot
	done    sync.WaitGroup
}

func NewSpeedtestManager(api speedtestAPI, options SpeedtestOptions) *SpeedtestManager {
	if options.Context == nil {
		options.Context = context.Background()
	}
	if options.PollInterval <= 0 {
		options.PollInterval = time.Second
	}
	if options.Now == nil {
		options.Now = time.Now
	}
	return &SpeedtestManager{api: api, options: options, state: SpeedtestSnapshot{State: SpeedtestIdle}}
}

func (m *SpeedtestManager) Snapshot() SpeedtestSnapshot {
	m.mu.RLock()
	defer m.mu.RUnlock()
	result := m.state
	if result.Latest != nil {
		latest := *result.Latest
		result.Latest = &latest
	}
	return result
}

func (m *SpeedtestManager) Start(ctx context.Context) error {
	m.mu.Lock()
	if m.state.State == SpeedtestRunning {
		m.mu.Unlock()
		return ErrSpeedtestRunning
	}
	m.state.State, m.state.Error = SpeedtestRunning, ""
	m.mu.Unlock()

	for attempt := 0; attempt < 3; attempt++ {
		err := m.api.StartSpeedtest(ctx)
		if err == nil {
			m.done.Add(1)
			go func() {
				defer m.done.Done()
				m.poll()
			}()
			return nil
		}
		if !unsupportedRPC(err) {
			m.fail(err)
			return err
		}
		if attempt < 2 && !waitContext(ctx, m.options.PollInterval) {
			m.fail(ctx.Err())
			return ctx.Err()
		}
	}
	m.setState(SpeedtestUnsupported, "")
	return nil
}

func (m *SpeedtestManager) Wait() { m.done.Wait() }

func (m *SpeedtestManager) poll() {
	ticker := time.NewTicker(m.options.PollInterval)
	defer ticker.Stop()
	unsupportedFailures := 0
	for {
		select {
		case <-m.options.Context.Done():
			m.fail(m.options.Context.Err())
			return
		case <-ticker.C:
			statusResponse, err := m.api.GetSpeedtestStatus(m.options.Context)
			if err != nil {
				if unsupportedRPC(err) {
					unsupportedFailures++
					if unsupportedFailures >= 3 {
						m.setState(SpeedtestUnsupported, "")
						return
					}
					continue
				}
				m.fail(err)
				return
			}
			unsupportedFailures = 0
			if statusResponse == nil || statusResponse.GetRunning() {
				continue
			}
			if directionErr := speedtestDirectionError(statusResponse); directionErr != "" {
				m.setState(SpeedtestError, directionErr)
				return
			}
			result := history.Speedtest{
				At: m.options.Now(), DownBPS: maxThroughput(statusResponse.GetDown().GetThroughputsMbps()) * 1_000_000,
				UpBPS: maxThroughput(statusResponse.GetUp().GetThroughputsMbps()) * 1_000_000,
			}
			if m.options.Store != nil {
				m.options.Store.AddSpeedtest(result)
			}
			m.mu.Lock()
			m.state = SpeedtestSnapshot{State: SpeedtestDone, Latest: &result}
			m.mu.Unlock()
			if m.options.Live != nil {
				m.options.Live.Publish(event.Message{Kind: "speedtest_completed", At: result.At, Data: result})
			}
			return
		}
	}
}

func (m *SpeedtestManager) fail(err error) {
	message := "speed test failed"
	if err != nil {
		message = err.Error()
	}
	m.setState(SpeedtestError, message)
}

func (m *SpeedtestManager) setState(state SpeedtestState, message string) {
	m.mu.Lock()
	m.state.State, m.state.Error = state, message
	m.mu.Unlock()
}

func unsupportedRPC(err error) bool {
	code := status.Code(err)
	return code == codes.Unimplemented || code == codes.Unavailable
}

func waitContext(ctx context.Context, delay time.Duration) bool {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

func maxThroughput(values []float32) float64 {
	result := float64(0)
	for _, value := range values {
		result = math.Max(result, float64(value))
	}
	return result
}

func speedtestDirectionError(response *device.SpeedtestStatus) string {
	for _, direction := range []*device.SpeedtestStatus_Direction{response.GetDown(), response.GetUp()} {
		if direction != nil && direction.GetErr() != device.SpeedtestError_SPEEDTEST_ERROR_NONE {
			return direction.GetErr().String()
		}
	}
	return ""
}
