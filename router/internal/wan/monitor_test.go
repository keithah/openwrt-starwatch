package wan

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"starwatch/internal/history"
)

func TestDiscoverInterfaceUsesExplicitOverrideBeforeAutodetection(t *testing.T) {
	dir := t.TempDir()
	routePath := filepath.Join(dir, "route")
	sysfs := filepath.Join(dir, "net")
	if err := os.MkdirAll(filepath.Join(sysfs, "wan"), 0o755); err != nil {
		t.Fatal(err)
	}
	route := "Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\n" +
		"starlink0\t0164A8C0\t00000000\t0001\t0\t0\t0\tFFFFFFFF\n"
	if err := os.WriteFile(routePath, []byte(route), 0o600); err != nil {
		t.Fatal(err)
	}
	options := DiscoveryOptions{DishAddr: "192.168.100.1:9200", Override: "wan2", RoutePath: routePath, SysfsRoot: sysfs}
	if got, err := DiscoverInterface(options); err != nil || got != "wan2" {
		t.Fatalf("override interface=%q err=%v", got, err)
	}
	options.Override = ""
	if err := os.WriteFile(routePath, []byte("Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got, err := DiscoverInterface(options); err != nil || got != "wan" {
		t.Fatalf("wan interface=%q err=%v", got, err)
	}
	if err := os.RemoveAll(filepath.Join(sysfs, "wan")); err != nil {
		t.Fatal(err)
	}
	if got, err := DiscoverInterface(options); err != nil || got != "" {
		t.Fatalf("empty fallback interface=%q err=%v", got, err)
	}
}

type fakeDiscoverer struct{ name string }

func (f fakeDiscoverer) Discover(string, string) (string, error) { return f.name, nil }

type changingDiscoverer struct {
	names []string
	calls int
}

func (f *changingDiscoverer) Discover(string, string) (string, error) {
	name := f.names[min(f.calls, len(f.names)-1)]
	f.calls++
	return name, nil
}

type probeResult struct {
	rtt time.Duration
	err error
}

type fakeProber struct {
	results []probeResult
	index   int
}

func (f *fakeProber) Probe(context.Context, string, string) (time.Duration, error) {
	result := f.results[f.index]
	f.index++
	return result.rtt, result.err
}

func writeCounter(t *testing.T, root, iface, name, value string) {
	t.Helper()
	path := filepath.Join(root, iface, "statistics")
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(path, name), []byte(value), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestMonitorTracksProbeWindowsAndRouterRates(t *testing.T) {
	now := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	sysfs := filepath.Join(t.TempDir(), "net")
	writeCounter(t, sysfs, "wan0", "rx_bytes", "1000\n")
	writeCounter(t, sysfs, "wan0", "tx_bytes", "2000\n")
	if err := os.WriteFile(filepath.Join(sysfs, "wan0", "operstate"), []byte("up\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	ram := history.NewStore(100)
	prober := &fakeProber{results: []probeResult{{rtt: 100 * time.Millisecond}, {err: errors.New("lost")}, {rtt: 200 * time.Millisecond}}}
	monitor := NewMonitor(Options{
		DishAddr: "192.168.100.1:9200", Hosts: []string{"1.1.1.1"}, SysfsRoot: sysfs,
		Now: func() time.Time { return now }, Discoverer: fakeDiscoverer{name: "wan0"}, Prober: prober,
	}, ram)
	monitor.discover()
	monitor.sampleCounters()
	writeCounter(t, sysfs, "wan0", "rx_bytes", "2000\n")
	writeCounter(t, sysfs, "wan0", "tx_bytes", "2500\n")
	now = now.Add(time.Second)
	monitor.sampleCounters()
	for range 3 {
		monitor.probeOnce(context.Background())
		now = now.Add(10 * time.Second)
	}

	snapshot := monitor.Snapshot()
	if snapshot.Interface != "wan0" || !snapshot.Up || snapshot.RouterDownBPS != 8000 || snapshot.RouterUpBPS != 4000 {
		t.Fatalf("snapshot counters: %+v", snapshot)
	}
	if snapshot.ProbeRTT30sMS != 150 || snapshot.ProbeLoss30s < 0.333 || snapshot.ProbeLoss30s > 0.334 {
		t.Fatalf("30s probe window: %+v", snapshot)
	}
	if snapshot.ProbeRTT5mMS != 150 || snapshot.ProbeLoss5m < 0.333 || snapshot.ProbeLoss5m > 0.334 {
		t.Fatalf("5m probe window: %+v", snapshot)
	}
	for _, series := range []string{history.WANProbeRTTMS, history.WANProbeLoss, history.RouterDownBPS, history.RouterUpBPS} {
		points, err := ram.Query(series, time.Time{}, 1000)
		if err != nil || len(points) == 0 {
			t.Fatalf("series %s points=%#v err=%v", series, points, err)
		}
	}
}

func TestMonitorPeriodicallyRediscoversInterface(t *testing.T) {
	discoverer := &changingDiscoverer{names: []string{"wan0", "wan1"}}
	monitor := NewMonitor(Options{
		Hosts: nil, Discoverer: discoverer, DiscoveryInterval: 10 * time.Millisecond,
		ProbeInterval: time.Hour, CounterInterval: time.Hour,
	}, history.NewStore(10))
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { monitor.Run(ctx); close(done) }()
	deadline := time.Now().Add(time.Second)
	for monitor.Snapshot().Interface != "wan1" && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	cancel()
	<-done
	if got := monitor.Snapshot().Interface; got != "wan1" {
		t.Fatalf("interface after rediscovery: %q", got)
	}
}

func TestMonitorExposesCurrentProbeRoundLossForOutageTiming(t *testing.T) {
	monitor := NewMonitor(Options{
		Hosts: []string{"1.1.1.1", "8.8.8.8"}, Now: func() time.Time { return time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC) },
		Discoverer: fakeDiscoverer{name: "wan0"}, Prober: &fakeProber{results: []probeResult{{err: errors.New("lost")}, {err: errors.New("lost")}}},
	}, history.NewStore(10))
	monitor.discover()
	monitor.probeOnce(context.Background())
	if got := monitor.Snapshot().ProbeLossNow; got != 1 {
		t.Fatalf("current probe loss: %v", got)
	}
}
