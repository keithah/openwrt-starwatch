// Package outage merges dish, gRPC reachability, and WAN path outages.
package outage

import (
	"sort"
	"sync"
	"time"

	"starwatch/internal/event"
)

const (
	SourceDish        = "dish"
	SourceUnreachable = "dish_unreachable"
	SourcePath        = "path"
)

type Entry struct {
	Source   string        `json:"source"`
	Cause    string        `json:"cause"`
	Start    time.Time     `json:"start"`
	Duration time.Duration `json:"duration"`
	Ongoing  bool          `json:"ongoing"`
}

type DishReport struct {
	Cause    string
	Start    time.Time
	Duration time.Duration
}

type Persistence interface {
	SaveOutage(Entry) error
	QueryOutages(since time.Time, limit int) ([]Entry, error)
}

type Options struct {
	Now         func() time.Time
	Persistence Persistence
	Events      event.Publisher
}

type Timeline struct {
	mu            sync.RWMutex
	now           func() time.Time
	persistence   Persistence
	events        event.Publisher
	entries       map[string]Entry
	seen          map[string]seenEntry
	pathPending   time.Time
	expectedUntil time.Time
}

func (t *Timeline) ExpectDishUnreachableUntil(until time.Time) {
	t.mu.Lock()
	if until.After(t.expectedUntil) {
		t.expectedUntil = until
	}
	t.mu.Unlock()
}

type seenEntry struct {
	duration time.Duration
	end      time.Time
}

func NewTimeline(options Options) *Timeline {
	if options.Now == nil {
		options.Now = time.Now
	}
	return &Timeline{
		now: options.Now, persistence: options.Persistence, events: options.Events,
		entries: make(map[string]Entry), seen: make(map[string]seenEntry),
	}
}

func (t *Timeline) IngestDish(reports []DishReport) {
	t.pruneSeenDish()
	for _, report := range reports {
		if report.Start.IsZero() {
			continue
		}
		key := entryKey(SourceDish, report.Cause, report.Start)
		t.mu.Lock()
		current, exists := t.entries[key]
		closed, alreadyClosed := t.seen[key]
		incoming := Entry{Source: SourceDish, Cause: report.Cause, Start: report.Start, Duration: report.Duration, Ongoing: report.Duration <= 0}
		if (alreadyClosed && (incoming.Ongoing || incoming.Duration <= closed.duration)) || (exists && incoming.Ongoing) {
			t.mu.Unlock()
			continue
		}
		if incoming.Ongoing {
			t.entries[key] = incoming
		} else {
			delete(t.entries, key)
			t.seen[key] = seenEntry{duration: incoming.Duration, end: incoming.Start.Add(incoming.Duration)}
			if t.persistence == nil {
				t.entries[key] = incoming
			}
		}
		t.mu.Unlock()
		if incoming.Ongoing && !exists {
			t.publish("outage_started", incoming)
		} else if !incoming.Ongoing {
			t.persist(incoming)
			if exists && current.Ongoing {
				t.publish("outage_ended", incoming)
			}
		}
	}
}

func (t *Timeline) pruneSeenDish() {
	cutoff := t.now().Add(-time.Hour)
	t.mu.Lock()
	defer t.mu.Unlock()
	for key, closed := range t.seen {
		if !closed.end.IsZero() && closed.end.Before(cutoff) {
			delete(t.seen, key)
		}
	}
}

func (t *Timeline) ObserveDish(reachable bool, failureSince time.Time) {
	now := t.now()
	key := activeKey(SourceUnreachable)
	t.mu.Lock()
	current, exists := t.entries[key]
	if !reachable {
		if exists {
			t.mu.Unlock()
			return
		}
		if failureSince.IsZero() {
			failureSince = now
		}
		cause := "grpc_unreachable"
		if now.Before(t.expectedUntil) {
			cause = "expected_reboot"
		}
		entry := Entry{Source: SourceUnreachable, Cause: cause, Start: failureSince, Ongoing: true}
		t.entries[key] = entry
		t.mu.Unlock()
		t.publish("outage_started", entry)
		return
	}
	if !exists {
		t.mu.Unlock()
		return
	}
	delete(t.entries, key)
	current.Duration = nonnegativeDuration(now.Sub(current.Start))
	current.Ongoing = false
	closedKey := entryKey(current.Source, current.Cause, current.Start)
	t.seen[closedKey] = seenEntry{duration: current.Duration, end: current.Start.Add(current.Duration)}
	if t.persistence == nil {
		t.entries[closedKey] = current
	}
	t.mu.Unlock()
	t.persist(current)
	t.publish("outage_ended", current)
}

func (t *Timeline) ObservePath(dishConnected, allProbesLost bool) {
	now := t.now()
	condition := dishConnected && allProbesLost
	key := activeKey(SourcePath)
	t.mu.Lock()
	current, active := t.entries[key]
	if condition {
		if active {
			t.mu.Unlock()
			return
		}
		if t.pathPending.IsZero() {
			t.pathPending = now
			t.mu.Unlock()
			return
		}
		if now.Sub(t.pathPending) < 30*time.Second {
			t.mu.Unlock()
			return
		}
		entry := Entry{Source: SourcePath, Cause: "probe_loss", Start: t.pathPending, Ongoing: true}
		t.entries[key] = entry
		t.mu.Unlock()
		t.publish("outage_started", entry)
		return
	}
	t.pathPending = time.Time{}
	if !active {
		t.mu.Unlock()
		return
	}
	delete(t.entries, key)
	current.Duration = nonnegativeDuration(now.Sub(current.Start))
	current.Ongoing = false
	closedKey := entryKey(current.Source, current.Cause, current.Start)
	t.seen[closedKey] = seenEntry{duration: current.Duration, end: current.Start.Add(current.Duration)}
	if t.persistence == nil {
		t.entries[closedKey] = current
	}
	t.mu.Unlock()
	t.persist(current)
	t.publish("outage_ended", current)
}

func (t *Timeline) Query(since time.Time, limit int) ([]Entry, error) {
	t.mu.RLock()
	combined := make(map[string]Entry, len(t.entries))
	for key, entry := range t.entries {
		if entry.Ongoing {
			entry.Duration = nonnegativeDuration(t.now().Sub(entry.Start))
		}
		if overlapsSince(entry, since) {
			combined[canonicalKey(key, entry)] = entry
		}
	}
	t.mu.RUnlock()
	if t.persistence != nil {
		persisted, err := t.persistence.QueryOutages(since, limit)
		if err != nil {
			return nil, err
		}
		for _, entry := range persisted {
			combined[entryKey(entry.Source, entry.Cause, entry.Start)] = entry
		}
	}
	result := make([]Entry, 0, len(combined))
	for _, entry := range combined {
		result = append(result, entry)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Start.Before(result[j].Start) })
	if limit > 0 && len(result) > limit {
		result = result[len(result)-limit:]
	}
	return result, nil
}

func (t *Timeline) Active() []Entry {
	now := t.now()
	t.mu.RLock()
	defer t.mu.RUnlock()
	var entries []Entry
	for _, entry := range t.entries {
		if !entry.Ongoing {
			continue
		}
		entry.Duration = nonnegativeDuration(now.Sub(entry.Start))
		entries = append(entries, entry)
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Start.Before(entries[j].Start) })
	return entries
}

func (t *Timeline) persist(entry Entry) {
	if t.persistence != nil {
		_ = t.persistence.SaveOutage(entry)
	}
}

func (t *Timeline) publish(kind string, entry Entry) {
	if t.events != nil {
		t.events.Publish(event.Message{Kind: kind, At: t.now(), Data: entry})
	}
}

func entryKey(source, cause string, start time.Time) string {
	return source + "\x00" + cause + "\x00" + start.UTC().Format(time.RFC3339Nano)
}

func activeKey(source string) string { return "active\x00" + source }

func canonicalKey(key string, entry Entry) string {
	if entry.Ongoing {
		return key
	}
	return entryKey(entry.Source, entry.Cause, entry.Start)
}

func nonnegativeDuration(duration time.Duration) time.Duration {
	if duration < 0 {
		return 0
	}
	return duration
}

func overlapsSince(entry Entry, since time.Time) bool {
	return entry.Ongoing || !entry.Start.Add(entry.Duration).Before(since)
}
