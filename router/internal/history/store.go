// Package history provides Starwatch's bounded, second-resolution RAM tier.
package history

import (
	"errors"
	"sort"
	"sync"
	"time"
)

const (
	DishDownBPS         = "dish_down_bps"
	DishUpBPS           = "dish_up_bps"
	RouterDownBPS       = "router_down_bps"
	RouterUpBPS         = "router_up_bps"
	LatencyMS           = "latency_ms"
	DropRate            = "drop_rate"
	PowerW              = "power_w"
	ObstructionFraction = "obstruction_fraction"
	WANProbeRTTMS       = "wan_probe_rtt_ms"
	WANProbeLoss        = "wan_probe_loss"
)

var ErrUnknownSeries = errors.New("unknown history series")

type Point struct {
	Time  time.Time `json:"time"`
	Value float32   `json:"value"`
}

type Writer interface {
	Append(series string, point Point) error
}

type Reader interface {
	Query(series string, since time.Time, limit int) ([]Point, error)
	Series() []string
}

type Store struct {
	mu     sync.RWMutex
	series map[string]*ring
}

func NewStore(capacity int) *Store {
	store := &Store{series: make(map[string]*ring)}
	for _, name := range []string{
		DishDownBPS, DishUpBPS, RouterDownBPS, RouterUpBPS, LatencyMS,
		DropRate, PowerW, ObstructionFraction, WANProbeRTTMS, WANProbeLoss,
	} {
		store.series[name] = newRing(capacity)
	}
	return store
}

func (s *Store) Append(series string, point Point) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	r, ok := s.series[series]
	if !ok {
		return ErrUnknownSeries
	}
	r.append(point)
	return nil
}

func (s *Store) Query(series string, since time.Time, limit int) ([]Point, error) {
	s.mu.RLock()
	r, ok := s.series[series]
	if !ok {
		s.mu.RUnlock()
		return nil, ErrUnknownSeries
	}
	all := r.snapshot()
	s.mu.RUnlock()

	start := 0
	if !since.IsZero() {
		start = sort.Search(len(all), func(i int) bool { return !all[i].Time.Before(since) })
	}
	all = all[start:]
	if limit <= 0 || len(all) <= limit {
		return all, nil
	}
	if limit == 1 {
		return []Point{all[len(all)-1]}, nil
	}
	result := make([]Point, limit)
	for i := range result {
		index := i * (len(all) - 1) / (limit - 1)
		result[i] = all[index]
	}
	return result, nil
}

func (s *Store) Series() []string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	names := make([]string, 0, len(s.series))
	for name := range s.series {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}
