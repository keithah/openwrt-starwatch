package diagnostics

import (
	"bytes"
	"encoding/json"
	"math"
	"testing"
	"time"

	"starwatch/internal/dish"
	"starwatch/internal/history"
	"starwatch/internal/outage"
)

func TestRawLatencyUsesNearestRankP95AndInclusiveBuckets(t *testing.T) {
	points := make([]history.Point, 0, 20)
	for value := 1; value <= 20; value++ {
		points = append(points, history.Point{Value: float32(value)})
	}
	percentile := Summarize(Input{Span: "15m", Latency: history.QueryResult{Tier: history.TierRAM, Points: points}}).Latency
	if percentile.Availability != nil || percentile.Approximate || percentile.P95MS == nil || *percentile.P95MS != 19 {
		t.Fatalf("latency=%+v", percentile)
	}

	boundaryPoints := []history.Point{
		history.Point{Value: 20}, history.Point{Value: 20.1}, history.Point{Value: 40},
		history.Point{Value: 500}, history.Point{Value: 500.1},
	}
	got := Summarize(Input{Span: "15m", Latency: history.QueryResult{Tier: history.TierRAM, Points: boundaryPoints}}).Latency
	want := []int64{1, 2, 0, 0, 0, 0, 0, 1, 1}
	if len(got.Distribution) != len(want) {
		t.Fatalf("distribution=%+v", got.Distribution)
	}
	for index, count := range want {
		if got.Distribution[index].Count != count {
			t.Fatalf("bucket %d count=%d want=%d", index, got.Distribution[index].Count, count)
		}
	}
	if got.Distribution[len(got.Distribution)-1].UpperBoundMS != nil {
		t.Fatalf("open bucket=%+v", got.Distribution[len(got.Distribution)-1])
	}
}

func TestAggregateLatencyIsWeightedAndApproximate(t *testing.T) {
	got := Summarize(Input{Span: "24h", Latency: history.QueryResult{Tier: history.TierMinute, Points: []history.Point{
		{Value: 10, Samples: 9}, {Value: 100, Samples: 1},
	}}}).Latency
	if !got.Approximate || got.MeanMS == nil || *got.MeanMS != 19 || got.P95MS == nil || *got.P95MS != 100 {
		t.Fatalf("latency=%+v", got)
	}
}

func TestPingSuccessClampsDishDropRate(t *testing.T) {
	for _, test := range []struct {
		name string
		drop float32
		want float32
	}{{"none", 0, 1}, {"all", 1, 0}, {"guard", 1.5, 0}, {"negative_guard", -0.5, 1}} {
		t.Run(test.name, func(t *testing.T) {
			got := Summarize(Input{Snapshot: dish.Snapshot{
				Dish:              &dish.Status{DropRate: test.drop},
				FieldAvailability: map[string]dish.Availability{dish.FieldStatus: {Available: true}},
			}}).Ping
			if got.DishSuccess == nil || *got.DishSuccess != test.want {
				t.Fatalf("drop=%v ping=%+v", test.drop, got)
			}
		})
	}
}

func TestPingDoesNotTreatUnsampledWANZerosAsSuccess(t *testing.T) {
	got := Summarize(Input{WAN: dish.WANStatus{Available: true}}).Ping
	if got.Availability == nil || got.Availability.Available || got.WANSuccess30s != nil || got.WANSuccess5m != nil {
		t.Fatalf("unsampled WAN ping=%+v", got)
	}
}

func TestPingKeepsRouterSourceAndLastSuccessDistinct(t *testing.T) {
	now := time.Date(2026, 7, 16, 12, 0, 30, 0, time.UTC)
	lastSuccess := now.Add(-12 * time.Second)
	drop, latency := float32(0.25), float32(3.5)
	got := Summarize(Input{Now: now, Snapshot: dish.Snapshot{StarlinkRouter: &dish.StarlinkRouter{
		Reachable: true, PingDropRate: &drop, PingLatencyMS: &latency, LastPingSuccess: &lastSuccess,
	}}})
	if got.Ping.RouterSuccess == nil || *got.Ping.RouterSuccess != 0.75 || got.Ping.SecondsSinceRouterSuccess == nil || *got.Ping.SecondsSinceRouterSuccess != 12 {
		t.Fatalf("router ping=%+v", got.Ping)
	}
}

func TestOutagesClipAndUnionOverlappingRepresentations(t *testing.T) {
	now := time.Date(2026, 7, 16, 12, 0, 0, 0, time.UTC)
	since := now.Add(-30 * time.Second)
	got := Summarize(Input{Now: now, Since: since, Outages: []outage.Entry{
		{Source: outage.SourceDish, Start: since.Add(-5 * time.Second), Duration: 15 * time.Second},
		{Source: outage.SourceUnreachable, Start: since.Add(5 * time.Second), Duration: 10 * time.Second},
		{Source: outage.SourcePath, Start: since.Add(20 * time.Second), Duration: 5 * time.Second},
	}}).Outages
	if got.Count == nil || *got.Count != 2 || got.DowntimeNS == nil || *got.DowntimeNS != int64(20*time.Second) || got.LongestNS == nil || *got.LongestNS != int64(15*time.Second) {
		t.Fatalf("outages=%+v", got)
	}
}

func TestPowerSummaryUsesKnownPositiveSeries(t *testing.T) {
	current := float32(55)
	got := Summarize(Input{
		Power: history.QueryResult{Tier: history.TierRAM, Points: []history.Point{{Value: 40}, {Value: 50}, {Value: 60}, {Value: -1}, {Value: float32(math.NaN())}}},
		Snapshot: dish.Snapshot{
			Dish:              &dish.Status{PowerW: &current, PowerSource: "status"},
			Config:            &dish.ConfigReadback{SnowMeltMode: "AUTO", PowerSaveMode: true},
			FieldAvailability: map[string]dish.Availability{dish.FieldPower: {Available: true}},
		},
	}).Power
	if got.CurrentW == nil || *got.CurrentW != 55 || got.MeanW == nil || *got.MeanW != 50 || got.MinW == nil || *got.MinW != 40 || got.MaxW == nil || *got.MaxW != 60 || got.KWhPerDay == nil || *got.KWhPerDay != 1.2 {
		t.Fatalf("power=%+v", got)
	}
	if got.Source != "status" || got.SnowMeltMode != "AUTO" || got.SleepEnabled == nil || !*got.SleepEnabled {
		t.Fatalf("power labels=%+v", got)
	}
}

func TestEmptyInputReturnsAvailabilityReasonsWithoutZeros(t *testing.T) {
	got := Summarize(Input{Span: "3h"})
	for name, availability := range map[string]*Availability{
		"latency": got.Latency.Availability,
		"ping":    got.Ping.Availability,
		"outages": got.Outages.Availability,
		"power":   got.Power.Availability,
	} {
		if availability == nil || availability.Available || availability.Reason == "" {
			t.Fatalf("%s availability=%+v", name, availability)
		}
	}
	encoded, err := json.Marshal(got)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{`"mean_ms":0`, `"count":0`, `"mean_w":0`} {
		if bytes.Contains(encoded, []byte(forbidden)) {
			t.Fatalf("fabricated zero in %s", encoded)
		}
	}
}
