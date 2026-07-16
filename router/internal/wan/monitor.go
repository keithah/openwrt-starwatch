// Package wan monitors the router-side Starlink WAN without changing routing.
package wan

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"starwatch/internal/dish"
	"starwatch/internal/history"
)

type Prober interface {
	Probe(ctx context.Context, interfaceName, host string) (time.Duration, error)
}

type Options struct {
	DishAddr          string
	Override          string
	Hosts             []string
	ProbeInterval     time.Duration
	CounterInterval   time.Duration
	DiscoveryInterval time.Duration
	SysfsRoot         string
	Now               func() time.Time
	Discoverer        Discoverer
	Prober            Prober
}

type probeSample struct {
	at      time.Time
	rtt     time.Duration
	success bool
}

type Monitor struct {
	options Options
	history history.Writer

	mu       sync.RWMutex
	snapshot dish.WANStatus
	probes   []probeSample
	lastRX   uint64
	lastTX   uint64
	lastAt   time.Time
}

func NewMonitor(options Options, writer history.Writer) *Monitor {
	if options.ProbeInterval <= 0 {
		options.ProbeInterval = 2 * time.Second
	}
	if options.CounterInterval <= 0 {
		options.CounterInterval = time.Second
	}
	if options.DiscoveryInterval <= 0 {
		options.DiscoveryInterval = time.Minute
	}
	if options.SysfsRoot == "" {
		options.SysfsRoot = "/sys/class/net"
	}
	if options.Now == nil {
		options.Now = time.Now
	}
	if options.Discoverer == nil {
		options.Discoverer = newSystemDiscoverer()
	}
	if options.Prober == nil {
		options.Prober = newSystemProber()
	}
	return &Monitor{options: options, history: writer}
}

func (m *Monitor) Run(ctx context.Context) {
	m.discover()
	m.sampleCounters()
	var workers sync.WaitGroup
	workers.Add(3)
	go func() {
		defer workers.Done()
		m.runDiscoveryLoop(ctx)
	}()
	go func() {
		defer workers.Done()
		m.runProbeLoop(ctx)
	}()
	go func() {
		defer workers.Done()
		m.runCounterLoop(ctx)
	}()
	<-ctx.Done()
	workers.Wait()
}

func (m *Monitor) runDiscoveryLoop(ctx context.Context) {
	ticker := time.NewTicker(m.options.DiscoveryInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			m.discover()
		}
	}
}

func (m *Monitor) runProbeLoop(ctx context.Context) {
	ticker := time.NewTicker(m.options.ProbeInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			m.probeOnce(ctx)
		}
	}
}

func (m *Monitor) runCounterLoop(ctx context.Context) {
	ticker := time.NewTicker(m.options.CounterInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			m.sampleCounters()
		}
	}
}

func (m *Monitor) Snapshot() dish.WANStatus {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.snapshot
}

func (m *Monitor) discover() {
	name, err := m.options.Discoverer.Discover(m.options.DishAddr, m.options.Override)
	m.mu.Lock()
	defer m.mu.Unlock()
	if err != nil || name == "" {
		m.snapshot.Available = false
		return
	}
	m.snapshot.Available = true
	m.snapshot.Interface = name
}

func (m *Monitor) interfaceName() string {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.snapshot.Interface
}

func (m *Monitor) probeOnce(ctx context.Context) {
	name := m.interfaceName()
	if name == "" {
		m.discover()
		name = m.interfaceName()
	}
	if name == "" || len(m.options.Hosts) == 0 {
		return
	}
	now := m.options.Now()
	successes := 0
	var totalRTT time.Duration
	newSamples := make([]probeSample, 0, len(m.options.Hosts))
	for _, host := range m.options.Hosts {
		rtt, err := m.options.Prober.Probe(ctx, name, host)
		sample := probeSample{at: now, rtt: rtt, success: err == nil}
		newSamples = append(newSamples, sample)
		if err == nil {
			successes++
			totalRTT += rtt
		}
	}
	m.mu.Lock()
	m.probes = append(m.probes, newSamples...)
	m.snapshot.ProbeLossNow = float32(len(m.options.Hosts)-successes) / float32(len(m.options.Hosts))
	cutoff := now.Add(-5 * time.Minute)
	first := 0
	for first < len(m.probes) && m.probes[first].at.Before(cutoff) {
		first++
	}
	m.probes = append([]probeSample(nil), m.probes[first:]...)
	m.updateProbeWindows(now)
	m.mu.Unlock()
	if now.Year() >= 2025 {
		loss := float32(len(m.options.Hosts)-successes) / float32(len(m.options.Hosts))
		_ = m.history.Append(history.WANProbeLoss, history.Point{Time: now, Value: loss})
		if successes > 0 {
			averageMS := float32(totalRTT.Seconds()*1000) / float32(successes)
			_ = m.history.Append(history.WANProbeRTTMS, history.Point{Time: now, Value: averageMS})
		}
	}
}

func (m *Monitor) updateProbeWindows(now time.Time) {
	m.snapshot.ProbeRTT30sMS, m.snapshot.ProbeLoss30s = probeWindow(m.probes, now.Add(-30*time.Second))
	m.snapshot.ProbeRTT5mMS, m.snapshot.ProbeLoss5m = probeWindow(m.probes, now.Add(-5*time.Minute))
}

func probeWindow(samples []probeSample, since time.Time) (float32, float32) {
	count, successes := 0, 0
	var total time.Duration
	for _, sample := range samples {
		if sample.at.Before(since) {
			continue
		}
		count++
		if sample.success {
			successes++
			total += sample.rtt
		}
	}
	if count == 0 {
		return 0, 0
	}
	loss := float32(count-successes) / float32(count)
	if successes == 0 {
		return 0, loss
	}
	return float32(total.Seconds()*1000) / float32(successes), loss
}

func (m *Monitor) sampleCounters() {
	name := m.interfaceName()
	if name == "" {
		m.discover()
		name = m.interfaceName()
	}
	if name == "" {
		return
	}
	rx, rxErr := readUint(filepath.Join(m.options.SysfsRoot, name, "statistics", "rx_bytes"))
	tx, txErr := readUint(filepath.Join(m.options.SysfsRoot, name, "statistics", "tx_bytes"))
	up := strings.TrimSpace(readText(filepath.Join(m.options.SysfsRoot, name, "operstate"))) == "up"
	now := m.options.Now()
	m.mu.Lock()
	m.snapshot.Up = up
	previousAt, previousRX, previousTX := m.lastAt, m.lastRX, m.lastTX
	if rxErr == nil && txErr == nil {
		m.lastAt, m.lastRX, m.lastTX = now, rx, tx
	}
	m.mu.Unlock()
	if rxErr != nil || txErr != nil || previousAt.IsZero() || !now.After(previousAt) || rx < previousRX || tx < previousTX {
		return
	}
	seconds := now.Sub(previousAt).Seconds()
	downBPS := float32(float64(rx-previousRX) * 8 / seconds)
	upBPS := float32(float64(tx-previousTX) * 8 / seconds)
	m.mu.Lock()
	m.snapshot.RouterDownBPS, m.snapshot.RouterUpBPS = downBPS, upBPS
	m.mu.Unlock()
	if now.Year() >= 2025 {
		_ = m.history.Append(history.RouterDownBPS, history.Point{Time: now, Value: downBPS})
		_ = m.history.Append(history.RouterUpBPS, history.Point{Time: now, Value: upBPS})
	}
}

func readUint(path string) (uint64, error) {
	value, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}
	return strconv.ParseUint(strings.TrimSpace(string(value)), 10, 64)
}

func readText(path string) string {
	value, _ := os.ReadFile(path)
	return string(value)
}
