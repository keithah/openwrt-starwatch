// Package diagnostics derives read-only summaries from local Starwatch data.
package diagnostics

import (
	"math"
	"sort"
	"time"

	"starwatch/internal/dish"
	"starwatch/internal/history"
	"starwatch/internal/outage"
)

var distributionEdges = [...]float64{20, 40, 60, 80, 100, 150, 200, 500}

type Availability struct {
	Available bool   `json:"available"`
	Reason    string `json:"reason"`
}

type Input struct {
	Span     string
	Now      time.Time
	Since    time.Time
	Latency  history.QueryResult
	Power    history.QueryResult
	Snapshot dish.Snapshot
	WAN      dish.WANStatus
	Outages  []outage.Entry
}

type Response struct {
	Span    string         `json:"span"`
	Latency LatencySummary `json:"latency"`
	Ping    PingSummary    `json:"ping"`
	Outages OutageSummary  `json:"outages"`
	Power   PowerSummary   `json:"power"`
}

type LatencySummary struct {
	*Availability
	Approximate        bool          `json:"approximate,omitempty"`
	CurrentMS          *float64      `json:"current_ms,omitempty"`
	MeanMS             *float64      `json:"mean_ms,omitempty"`
	P95MS              *float64      `json:"p95_ms,omitempty"`
	MaxMS              *float64      `json:"max_ms,omitempty"`
	RouterMS           *float64      `json:"router_ms,omitempty"`
	RouterAvailability *Availability `json:"router_ms_availability,omitempty"`
	Distribution       []Bucket      `json:"distribution,omitempty"`
}

type Bucket struct {
	UpperBoundMS *float64 `json:"upper_bound_ms"`
	Count        int64    `json:"count"`
}

type PingSummary struct {
	*Availability
	DishSuccess               *float32 `json:"dish_success,omitempty"`
	RouterSuccess             *float32 `json:"router_success,omitempty"`
	WANSuccess30s             *float32 `json:"wan_success_30s,omitempty"`
	WANSuccess5m              *float32 `json:"wan_success_5m,omitempty"`
	SecondsSinceRouterSuccess *float64 `json:"seconds_since_router_success,omitempty"`
}

type OutageSummary struct {
	*Availability
	Count      *int   `json:"count,omitempty"`
	DowntimeNS *int64 `json:"downtime_ns,omitempty"`
	LongestNS  *int64 `json:"longest_ns,omitempty"`
}

type PowerSummary struct {
	*Availability
	CurrentW     *float64 `json:"current_w,omitempty"`
	MeanW        *float64 `json:"mean_w,omitempty"`
	MinW         *float64 `json:"min_w,omitempty"`
	MaxW         *float64 `json:"max_w,omitempty"`
	KWhPerDay    *float64 `json:"kwh_per_day,omitempty"`
	Source       string   `json:"source,omitempty"`
	SnowMeltMode string   `json:"snow_melt_mode,omitempty"`
	SleepEnabled *bool    `json:"sleep_enabled,omitempty"`
}

func Summarize(input Input) Response {
	return Response{
		Span: input.Span, Latency: summarizeLatency(input), Ping: summarizePing(input),
		Outages: summarizeOutages(input), Power: summarizePower(input),
	}
}

type weightedValue struct {
	value  float64
	weight int64
}

func summarizeLatency(input Input) LatencySummary {
	values := validWeightedValues(input.Latency.Points, false)
	if len(values) == 0 {
		return LatencySummary{Availability: unavailable("no valid latency samples in span")}
	}
	mean, maximum := weightedMean(values), values[0].value
	for _, point := range input.Latency.Points {
		candidate := float64(point.Value)
		if input.Latency.Tier != history.TierRAM && point.Max != nil {
			candidate = float64(*point.Max)
		}
		if validNonnegative(candidate) && candidate > maximum {
			maximum = candidate
		}
	}
	p95 := weightedPercentile(values, 0.95)
	result := LatencySummary{
		Approximate: input.Latency.Tier != history.TierRAM,
		MeanMS:      &mean, P95MS: &p95, MaxMS: &maximum, Distribution: distribution(values),
	}
	if input.Snapshot.Dish != nil && fieldAvailable(input.Snapshot, dish.FieldStatus) {
		current := float64(input.Snapshot.Dish.LatencyMS)
		if validNonnegative(current) {
			result.CurrentMS = &current
		}
	}
	if router := input.Snapshot.StarlinkRouter; router != nil && router.Reachable && router.PingLatencyMS != nil {
		value := float64(*router.PingLatencyMS)
		if validNonnegative(value) {
			result.RouterMS = &value
		}
	}
	if result.RouterMS == nil {
		result.RouterAvailability = unavailable("Starlink router ping latency unavailable")
	}
	return result
}

func summarizePing(input Input) PingSummary {
	var result PingSummary
	if input.Snapshot.Dish != nil && fieldAvailable(input.Snapshot, dish.FieldStatus) {
		if drop := float64(input.Snapshot.Dish.DropRate); finite(drop) {
			value := success(drop)
			result.DishSuccess = &value
		}
	}
	if router := input.Snapshot.StarlinkRouter; router != nil && router.Reachable {
		if router.PingDropRate != nil && finite(float64(*router.PingDropRate)) {
			value := success(float64(*router.PingDropRate))
			result.RouterSuccess = &value
		}
		if router.LastPingSuccess != nil && !input.Now.IsZero() && !router.LastPingSuccess.After(input.Now) {
			seconds := input.Now.Sub(*router.LastPingSuccess).Seconds()
			result.SecondsSinceRouterSuccess = &seconds
		}
	}
	if input.WAN.Available {
		if loss := float64(input.WAN.ProbeLoss30s); input.WAN.Probe30sAvailable && finite(loss) {
			value := success(loss)
			result.WANSuccess30s = &value
		}
		if loss := float64(input.WAN.ProbeLoss5m); input.WAN.Probe5mAvailable && finite(loss) {
			value := success(loss)
			result.WANSuccess5m = &value
		}
	}
	if result.DishSuccess == nil && result.RouterSuccess == nil && result.WANSuccess30s == nil && result.WANSuccess5m == nil {
		result.Availability = unavailable("no valid ping samples available")
	}
	return result
}

type interval struct{ start, end time.Time }

func summarizeOutages(input Input) OutageSummary {
	intervals := make([]interval, 0, len(input.Outages))
	for _, entry := range input.Outages {
		start := entry.Start
		end := entry.Start.Add(entry.Duration)
		if entry.Ongoing && !input.Now.IsZero() {
			end = input.Now
		}
		if start.Before(input.Since) {
			start = input.Since
		}
		if !input.Now.IsZero() && end.After(input.Now) {
			end = input.Now
		}
		if end.After(start) {
			intervals = append(intervals, interval{start: start, end: end})
		}
	}
	if len(intervals) == 0 {
		return OutageSummary{Availability: unavailable("no valid outage intervals in span")}
	}
	sort.Slice(intervals, func(i, j int) bool { return intervals[i].start.Before(intervals[j].start) })
	merged := intervals[:1]
	for _, next := range intervals[1:] {
		last := &merged[len(merged)-1]
		if next.start.Before(last.end) {
			if next.end.After(last.end) {
				last.end = next.end
			}
			continue
		}
		merged = append(merged, next)
	}
	count := len(merged)
	var downtime, longest time.Duration
	for _, item := range merged {
		duration := item.end.Sub(item.start)
		downtime += duration
		if duration > longest {
			longest = duration
		}
	}
	downtimeNS, longestNS := int64(downtime), int64(longest)
	return OutageSummary{Count: &count, DowntimeNS: &downtimeNS, LongestNS: &longestNS}
}

func summarizePower(input Input) PowerSummary {
	values := validWeightedValues(input.Power.Points, true)
	if len(values) == 0 {
		return PowerSummary{Availability: unavailable("no valid power samples in span")}
	}
	mean := weightedMean(values)
	minimum, maximum := values[0].value, values[0].value
	for _, point := range input.Power.Points {
		low, high := float64(point.Value), float64(point.Value)
		if input.Power.Tier != history.TierRAM {
			if point.Min != nil {
				low = float64(*point.Min)
			}
			if point.Max != nil {
				high = float64(*point.Max)
			}
		}
		if validPositive(low) && low < minimum {
			minimum = low
		}
		if validPositive(high) && high > maximum {
			maximum = high
		}
	}
	kwh := mean * 24 / 1000
	result := PowerSummary{MeanW: &mean, MinW: &minimum, MaxW: &maximum, KWhPerDay: &kwh}
	if input.Snapshot.Dish != nil && fieldAvailable(input.Snapshot, dish.FieldPower) && input.Snapshot.Dish.PowerW != nil {
		current := float64(*input.Snapshot.Dish.PowerW)
		if validPositive(current) {
			result.CurrentW = &current
			result.Source = input.Snapshot.Dish.PowerSource
		}
	}
	if input.Snapshot.Config != nil {
		result.SnowMeltMode = input.Snapshot.Config.SnowMeltMode
		sleep := input.Snapshot.Config.PowerSaveMode
		result.SleepEnabled = &sleep
	}
	return result
}

func validWeightedValues(points []history.Point, positive bool) []weightedValue {
	values := make([]weightedValue, 0, len(points))
	for _, point := range points {
		value := float64(point.Value)
		if positive && !validPositive(value) || !positive && !validNonnegative(value) {
			continue
		}
		weight := point.Samples
		if weight <= 0 {
			weight = 1
		}
		values = append(values, weightedValue{value: value, weight: weight})
	}
	return values
}

func weightedMean(values []weightedValue) float64 {
	var sum float64
	var count int64
	for _, value := range values {
		sum += value.value * float64(value.weight)
		count += value.weight
	}
	return sum / float64(count)
}

func weightedPercentile(values []weightedValue, percentile float64) float64 {
	sorted := append([]weightedValue(nil), values...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].value < sorted[j].value })
	var total int64
	for _, value := range sorted {
		total += value.weight
	}
	target := int64(math.Ceil(percentile * float64(total)))
	var cumulative int64
	for _, value := range sorted {
		cumulative += value.weight
		if cumulative >= target {
			return value.value
		}
	}
	return sorted[len(sorted)-1].value
}

func distribution(values []weightedValue) []Bucket {
	result := make([]Bucket, len(distributionEdges)+1)
	for index, edge := range distributionEdges {
		value := edge
		result[index].UpperBoundMS = &value
	}
	for _, value := range values {
		index := sort.Search(len(distributionEdges), func(index int) bool { return value.value <= distributionEdges[index] })
		result[index].Count += value.weight
	}
	return result
}

func success(dropRate float64) float32    { return float32(math.Min(1, math.Max(0, 1-dropRate))) }
func finite(value float64) bool           { return !math.IsNaN(value) && !math.IsInf(value, 0) }
func validNonnegative(value float64) bool { return finite(value) && value >= 0 }
func validPositive(value float64) bool    { return finite(value) && value > 0 }

func fieldAvailable(snapshot dish.Snapshot, field string) bool {
	availability, tracked := snapshot.FieldAvailability[field]
	return !tracked || availability.Available
}

func unavailable(reason string) *Availability {
	return &Availability{Available: false, Reason: reason}
}
