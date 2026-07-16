package outage

import (
	"testing"
	"time"

	"starwatch/internal/event"
)

type memoryPersistence struct {
	entries []Entry
}

func (m *memoryPersistence) SaveOutage(entry Entry) error {
	for index, existing := range m.entries {
		if existing.Source == entry.Source && existing.Cause == entry.Cause && existing.Start.Equal(entry.Start) {
			if entry.Duration > existing.Duration {
				m.entries[index] = entry
			}
			return nil
		}
	}
	m.entries = append(m.entries, entry)
	return nil
}

func (m *memoryPersistence) QueryOutages(since time.Time, _ int) ([]Entry, error) {
	var result []Entry
	for _, entry := range m.entries {
		if !entry.Start.Before(since) {
			result = append(result, entry)
		}
	}
	return result, nil
}

func TestTimelineMergesAllSourcesAndDeduplicatesDishHistory(t *testing.T) {
	now := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	persistence := &memoryPersistence{}
	timeline := NewTimeline(Options{Now: func() time.Time { return now }, Persistence: persistence})
	dishStart := now.Add(-2 * time.Minute)
	report := DishReport{Cause: "OBSTRUCTED", Start: dishStart, Duration: time.Minute}

	timeline.IngestDish([]DishReport{report, report})
	timeline.ObserveDish(false, now.Add(-20*time.Second))
	for range 2 {
		timeline.ObservePath(true, true)
		now = now.Add(31 * time.Second)
	}

	entries, err := timeline.Query(now.Add(-time.Hour), 100)
	if err != nil {
		t.Fatal(err)
	}
	assertSources(t, entries, "dish", "dish_unreachable", "path")
	if len(persistence.entries) != 1 || persistence.entries[0].Source != "dish" {
		t.Fatalf("persisted dish entries: %#v", persistence.entries)
	}
}

func TestTimelineTransitionsOngoingEntriesToClosedOnce(t *testing.T) {
	now := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	persistence := &memoryPersistence{}
	bus := event.NewBus()
	messages, cancel := bus.Subscribe(10)
	defer cancel()
	timeline := NewTimeline(Options{Now: func() time.Time { return now }, Persistence: persistence, Events: bus})

	timeline.ObserveDish(false, now)
	now = now.Add(45 * time.Second)
	timeline.ObserveDish(true, time.Time{})
	timeline.ObserveDish(true, time.Time{})

	if len(persistence.entries) != 1 {
		t.Fatalf("closed entries: %#v", persistence.entries)
	}
	closed := persistence.entries[0]
	if closed.Ongoing || closed.Duration != 45*time.Second {
		t.Fatalf("closed outage: %+v", closed)
	}
	first, second := <-messages, <-messages
	if first.Kind != "outage_started" || second.Kind != "outage_ended" {
		t.Fatalf("events: %+v %+v", first, second)
	}
}

func TestTimelineDeduplicatesSuccessiveDishUpdatesAndClosesOngoing(t *testing.T) {
	now := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	persistence := &memoryPersistence{}
	timeline := NewTimeline(Options{Now: func() time.Time { return now }, Persistence: persistence})
	start := now.Add(-time.Minute)

	timeline.IngestDish([]DishReport{{Cause: "NO_DOWNLINK", Start: start}})
	timeline.IngestDish([]DishReport{{Cause: "NO_DOWNLINK", Start: start}})
	timeline.IngestDish([]DishReport{{Cause: "NO_DOWNLINK", Start: start, Duration: 90 * time.Second}})
	timeline.IngestDish([]DishReport{{Cause: "NO_DOWNLINK", Start: start, Duration: 90 * time.Second}})
	timeline.IngestDish([]DishReport{{Cause: "NO_DOWNLINK", Start: start, Duration: 2 * time.Minute}})

	if len(persistence.entries) != 1 || persistence.entries[0].Duration != 2*time.Minute {
		t.Fatalf("persisted: %#v", persistence.entries)
	}
	entries, err := timeline.Query(now.Add(-time.Hour), 100)
	if err != nil || len(entries) != 1 || entries[0].Ongoing {
		t.Fatalf("entries=%#v err=%v", entries, err)
	}
}

func TestPathOutageRequiresThirtySecondsOfTotalLossWhileDishConnected(t *testing.T) {
	now := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	timeline := NewTimeline(Options{Now: func() time.Time { return now }})
	timeline.ObservePath(true, true)
	now = now.Add(29 * time.Second)
	timeline.ObservePath(true, true)
	entries, _ := timeline.Query(time.Time{}, 100)
	if len(entries) != 0 {
		t.Fatalf("path outage started early: %#v", entries)
	}
	now = now.Add(time.Second)
	timeline.ObservePath(true, true)
	entries, _ = timeline.Query(time.Time{}, 100)
	if len(entries) != 1 || entries[0].Source != "path" || !entries[0].Ongoing {
		t.Fatalf("path outage: %#v", entries)
	}
	now = now.Add(5 * time.Second)
	timeline.ObservePath(false, true)
	entries, _ = timeline.Query(time.Time{}, 100)
	if len(entries) != 1 || entries[0].Ongoing || entries[0].Duration != 35*time.Second {
		t.Fatalf("closed path outage: %#v", entries)
	}
}

func TestQueryIncludesOutageOverlappingSpanBoundaryAndActiveReturnsOnlyOngoing(t *testing.T) {
	now := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	timeline := NewTimeline(Options{Now: func() time.Time { return now }})
	timeline.IngestDish([]DishReport{
		{Cause: "NO_PINGS", Start: now.Add(-2 * time.Hour), Duration: 90 * time.Minute},
		{Cause: "NO_DOWNLINK", Start: now.Add(-time.Minute)},
	})
	entries, err := timeline.Query(now.Add(-time.Hour), 100)
	if err != nil || len(entries) != 2 {
		t.Fatalf("overlapping query=%#v err=%v", entries, err)
	}
	active := timeline.Active()
	if len(active) != 1 || active[0].Cause != "NO_DOWNLINK" || active[0].Duration != time.Minute {
		t.Fatalf("active: %#v", active)
	}
}

func assertSources(t *testing.T, entries []Entry, want ...string) {
	t.Helper()
	found := make(map[string]bool)
	for _, entry := range entries {
		found[entry.Source] = true
	}
	for _, source := range want {
		if !found[source] {
			t.Fatalf("source %q missing from %#v", source, entries)
		}
	}
}
