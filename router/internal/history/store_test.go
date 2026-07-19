package history

import (
	"errors"
	"testing"
	"time"
)

func TestStoreHasSpecSeries(t *testing.T) {
	store := NewStore(10)
	want := map[string]bool{
		DishDownBPS: true, DishUpBPS: true, RouterDownBPS: true, RouterUpBPS: true,
		LatencyMS: true, DropRate: true, PowerW: true, ObstructionFraction: true,
		WANProbeRTTMS: true, WANProbeLoss: true,
	}
	for _, name := range store.Series() {
		delete(want, name)
	}
	if len(want) != 0 {
		t.Fatalf("missing series: %#v", want)
	}
}

func TestStoreRingOverwritesOldestInOrder(t *testing.T) {
	store := NewStore(3)
	start := time.Unix(1_700_000_000, 0)
	for i := 0; i < 5; i++ {
		if err := store.Append(LatencyMS, Point{Time: start.Add(time.Duration(i) * time.Second), Value: float32(i)}); err != nil {
			t.Fatal(err)
		}
	}
	points, err := store.Query(LatencyMS, time.Time{}, 1000)
	if err != nil {
		t.Fatal(err)
	}
	if len(points) != 3 || points[0].Value != 2 || points[2].Value != 4 {
		t.Fatalf("points: %#v", points)
	}
}

func TestStoreQueryFiltersAndDownsamples(t *testing.T) {
	store := NewStore(2005)
	start := time.Unix(1_700_000_000, 0)
	for i := 0; i < 2005; i++ {
		if err := store.Append(DishDownBPS, Point{Time: start.Add(time.Duration(i) * time.Second), Value: float32(i)}); err != nil {
			t.Fatal(err)
		}
	}
	points, err := store.Query(DishDownBPS, start.Add(5*time.Second), 1000)
	if err != nil {
		t.Fatal(err)
	}
	if len(points) > 1000 {
		t.Fatalf("got %d points", len(points))
	}
	if points[0].Time.Before(start.Add(5*time.Second)) || points[len(points)-1].Value != 2004 {
		t.Fatalf("range endpoints: %#v ... %#v", points[0], points[len(points)-1])
	}
}

func TestStoreQuerySortsOutOfOrderPointsAndDropsZeroTimes(t *testing.T) {
	store := NewStore(10)
	start := time.Unix(1_700_000_000, 0).UTC()
	for _, point := range []Point{
		{Time: start.Add(2 * time.Second), Value: 2},
		{Time: time.Time{}, Value: 99},
		{Time: start, Value: 0},
		{Time: start.Add(time.Second), Value: 1},
	} {
		if err := store.Append(LatencyMS, point); err != nil {
			t.Fatal(err)
		}
	}

	points, err := store.Query(LatencyMS, start.Add(time.Second), 1000)
	if err != nil {
		t.Fatal(err)
	}
	if len(points) != 2 || points[0].Value != 1 || points[1].Value != 2 {
		t.Fatalf("points=%#v", points)
	}
}

func TestStoreRejectsUnknownSeries(t *testing.T) {
	store := NewStore(10)
	if err := store.Append("unknown", Point{}); !errors.Is(err, ErrUnknownSeries) {
		t.Fatalf("append error: %v", err)
	}
	if _, err := store.Query("unknown", time.Time{}, 10); !errors.Is(err, ErrUnknownSeries) {
		t.Fatalf("query error: %v", err)
	}
}
