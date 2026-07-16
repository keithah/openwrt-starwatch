package history

import (
	"bytes"
	"context"
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"testing"
	"time"

	"starwatch/internal/outage"
)

func openTestSQLite(t *testing.T, now time.Time) (*SQLiteStore, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "history.db")
	store, recovered, err := OpenSQLite(path, SQLiteOptions{Now: func() time.Time { return now }})
	if err != nil {
		t.Fatal(err)
	}
	if recovered {
		t.Fatal("new database reported recovery")
	}
	t.Cleanup(func() { _ = store.Close() })
	return store, path
}

func TestSQLiteFlushAggregatesMinuteAndQuarter(t *testing.T) {
	now := time.Date(2026, 7, 15, 12, 16, 0, 0, time.UTC)
	ram := NewStore(100)
	for _, point := range []Point{
		{Time: time.Date(2026, 7, 15, 12, 1, 5, 0, time.UTC), Value: 1},
		{Time: time.Date(2026, 7, 15, 12, 1, 25, 0, time.UTC), Value: 3},
		{Time: time.Date(2026, 7, 15, 12, 1, 50, 0, time.UTC), Value: 5},
		{Time: time.Date(2026, 7, 15, 12, 2, 10, 0, time.UTC), Value: 9},
	} {
		if err := ram.Append(LatencyMS, point); err != nil {
			t.Fatal(err)
		}
	}
	store, _ := openTestSQLite(t, now)
	if err := store.Flush(context.Background(), ram, now); err != nil {
		t.Fatal(err)
	}
	minute, err := store.QueryTier(LatencyMS, TierMinute, now.Add(-time.Hour), 1000)
	if err != nil {
		t.Fatal(err)
	}
	if len(minute) != 2 || minute[0].Value != 3 || valueOf(minute[0].Min) != 1 || valueOf(minute[0].Max) != 5 || minute[0].Samples != 3 {
		t.Fatalf("minute: %#v", minute)
	}
	quarter, err := store.QueryTier(LatencyMS, TierQuarter, now.Add(-time.Hour), 1000)
	if err != nil {
		t.Fatal(err)
	}
	if len(quarter) != 1 || quarter[0].Value != 4.5 || valueOf(quarter[0].Min) != 1 || valueOf(quarter[0].Max) != 9 || quarter[0].Samples != 4 {
		t.Fatalf("quarter: %#v", quarter)
	}
	encoded, err := json.Marshal(minute[0])
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(encoded, []byte("samples")) {
		t.Fatalf("internal sample count leaked into history JSON: %s", encoded)
	}
}

func TestSQLiteUsesMemoryJournalAndCreatesAllTables(t *testing.T) {
	now := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	store, _ := openTestSQLite(t, now)
	var journal string
	if err := store.db.QueryRow("PRAGMA journal_mode").Scan(&journal); err != nil || journal != "memory" {
		t.Fatalf("journal=%q err=%v", journal, err)
	}
	for _, table := range []string{"minute", "quarter", "events", "outages", "speedtests"} {
		var count int
		if err := store.db.QueryRow("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?", table).Scan(&count); err != nil || count != 1 {
			t.Fatalf("table %s count=%d err=%v", table, count, err)
		}
	}
}

func TestSQLiteFlushPersistsSpeedtestResult(t *testing.T) {
	now := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	store, _ := openTestSQLite(t, now)
	store.AddSpeedtest(Speedtest{At: now, DownBPS: 100, UpBPS: 20, LatencyMS: 30})
	if err := store.Flush(context.Background(), NewStore(1), now); err != nil {
		t.Fatal(err)
	}
	var timestamp int64
	var down, up, latency float64
	if err := store.db.QueryRow("SELECT ts, down_bps, up_bps, latency_ms FROM speedtests").Scan(&timestamp, &down, &up, &latency); err != nil {
		t.Fatal(err)
	}
	if timestamp != now.Unix() || down != 100 || up != 20 || latency != 30 {
		t.Fatalf("speedtest row: ts=%d down=%v up=%v latency=%v", timestamp, down, up, latency)
	}
}

func TestSQLiteFlushPrunesRetentionAndCapsEvents(t *testing.T) {
	now := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	store, _ := openTestSQLite(t, now)
	if _, err := store.db.Exec(`INSERT INTO minute(series, ts, min, avg, max, samples) VALUES(?, ?, 1, 1, 1, 1)`,
		LatencyMS, now.Add(-8*24*time.Hour).Unix()); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`INSERT INTO quarter(series, ts, min, avg, max, samples) VALUES(?, ?, 1, 1, 1, 1)`,
		LatencyMS, now.Add(-31*24*time.Hour).Unix()); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 10_005; i++ {
		store.AddEvent(Event{At: now.Add(time.Duration(i) * time.Second), Kind: "test"})
	}
	if err := store.Flush(context.Background(), NewStore(1), now); err != nil {
		t.Fatal(err)
	}
	for table, want := range map[string]int{"minute": 0, "quarter": 0, "events": 10_000} {
		var got int
		if err := store.db.QueryRow("SELECT COUNT(*) FROM " + table).Scan(&got); err != nil {
			t.Fatal(err)
		}
		if got != want {
			t.Fatalf("%s rows: got %d want %d", table, got, want)
		}
	}
}

func TestSQLiteDefersWritesWithInsaneClock(t *testing.T) {
	now := time.Date(2024, 1, 1, 0, 0, 0, 0, time.UTC)
	ram := NewStore(10)
	_ = ram.Append(LatencyMS, Point{Time: now, Value: 3})
	store, _ := openTestSQLite(t, now)
	store.AddEvent(Event{At: now, Kind: "daemon_started"})
	if err := store.Flush(context.Background(), ram, now); err != nil {
		t.Fatal(err)
	}
	for _, table := range []string{"minute", "events"} {
		var count int
		if err := store.db.QueryRow("SELECT COUNT(*) FROM " + table).Scan(&count); err != nil {
			t.Fatal(err)
		}
		if count != 0 {
			t.Fatalf("%s rows with insane clock: %d", table, count)
		}
	}
	sane := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	if err := store.Flush(context.Background(), ram, sane); err != nil {
		t.Fatal(err)
	}
	var minuteCount int
	if err := store.db.QueryRow("SELECT COUNT(*) FROM minute").Scan(&minuteCount); err != nil || minuteCount != 0 {
		t.Fatalf("insane RAM points persisted: count=%d err=%v", minuteCount, err)
	}
	var eventTimestamp int64
	if err := store.db.QueryRow("SELECT ts FROM events WHERE kind='daemon_started'").Scan(&eventTimestamp); err != nil || eventTimestamp != sane.Unix() {
		t.Fatalf("re-anchored event timestamp=%d err=%v", eventTimestamp, err)
	}
}

func TestSQLiteCorruptionMovesAsideAndRecreates(t *testing.T) {
	now := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	dir := t.TempDir()
	path := filepath.Join(dir, "history.db")
	if err := os.WriteFile(path, []byte("not a sqlite database"), 0o600); err != nil {
		t.Fatal(err)
	}
	store, recovered, err := OpenSQLite(path, SQLiteOptions{Now: func() time.Time { return now }})
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if !recovered {
		t.Fatal("corruption was not reported")
	}
	backups, err := filepath.Glob(path + ".corrupt-*")
	if err != nil || len(backups) != 1 {
		t.Fatalf("backups=%#v err=%v", backups, err)
	}
	store.AddEvent(Event{At: now, Kind: "sqlite_recreated"})
	if err := store.Flush(context.Background(), NewStore(1), now); err != nil {
		t.Fatal(err)
	}
	var count int
	if err := store.db.QueryRow("SELECT COUNT(*) FROM events WHERE kind='sqlite_recreated'").Scan(&count); err != nil || count != 1 {
		t.Fatalf("recovery event count=%d err=%v", count, err)
	}
}

func TestSQLitePersistsAndQueriesClosedOutages(t *testing.T) {
	now := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	store, _ := openTestSQLite(t, now)
	entry := outage.Entry{Source: outage.SourceDish, Cause: "OBSTRUCTED", Start: now.Add(-time.Minute), Duration: 30 * time.Second}
	if err := store.SaveOutage(entry); err != nil {
		t.Fatal(err)
	}
	pending, err := store.QueryOutages(now.Add(-time.Hour), 100)
	if err != nil || len(pending) != 1 || pending[0] != entry {
		t.Fatalf("pending outages=%#v err=%v", pending, err)
	}
	if err := store.Flush(context.Background(), NewStore(1), now); err != nil {
		t.Fatal(err)
	}
	// Re-saving a history-ring duplicate must not create another row.
	if err := store.SaveOutage(entry); err != nil {
		t.Fatal(err)
	}
	if err := store.Flush(context.Background(), NewStore(1), now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	entries, err := store.QueryOutages(now.Add(-time.Hour), 100)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0] != entry {
		t.Fatalf("outages: %#v", entries)
	}
}

func TestSQLiteQueriesPersistedAndPendingEvents(t *testing.T) {
	now := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	store, _ := openTestSQLite(t, now)
	store.AddEvent(Event{At: now.Add(-time.Minute), Kind: "alert_fired", Detail: `{"alert":"path_degraded"}`})
	if err := store.Flush(context.Background(), NewStore(1), now); err != nil {
		t.Fatal(err)
	}
	store.AddEvent(Event{At: now, Kind: "alert_cleared", Detail: `{"alert":"path_degraded"}`})

	events, err := store.QueryEvents(now.Add(-time.Hour), 100)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 2 || events[0].Kind != "alert_fired" || events[1].Kind != "alert_cleared" {
		t.Fatalf("events: %#v", events)
	}
}

func TestTieredReaderSelectsTierBySpan(t *testing.T) {
	now := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	ram := NewStore(10)
	_ = ram.Append(LatencyMS, Point{Time: now, Value: 1})
	persistent, _ := openTestSQLite(t, now)
	if _, err := persistent.db.Exec(`INSERT INTO minute(series, ts, min, avg, max, samples) VALUES(?, ?, 2, 3, 4, 1)`,
		LatencyMS, now.Add(-4*time.Hour).Unix()); err != nil {
		t.Fatal(err)
	}
	if _, err := persistent.db.Exec(`INSERT INTO quarter(series, ts, min, avg, max, samples) VALUES(?, ?, 5, 6, 7, 1)`,
		LatencyMS, now.Add(-8*24*time.Hour).Unix()); err != nil {
		t.Fatal(err)
	}
	reader := NewTieredReader(ram, persistent, 3*time.Hour)
	for _, test := range []struct {
		span time.Duration
		tier Tier
	}{
		{3 * time.Hour, TierRAM}, {7 * 24 * time.Hour, TierMinute}, {30 * 24 * time.Hour, TierQuarter},
	} {
		result, err := reader.QuerySpan(LatencyMS, now.Add(-test.span), test.span, 1000)
		if err != nil {
			t.Fatal(err)
		}
		if result.Tier != test.tier {
			t.Fatalf("span %v tier=%q want %q", test.span, result.Tier, test.tier)
		}
	}
}

func TestTieredReaderFallsBackToRAMWhenPersistentTierIsEmpty(t *testing.T) {
	now := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	ram := NewStore(10)
	if err := ram.Append(LatencyMS, Point{Time: now.Add(-time.Hour), Value: 42}); err != nil {
		t.Fatal(err)
	}
	persistent, _ := openTestSQLite(t, now)
	reader := NewTieredReader(ram, persistent, 3*time.Hour)

	result, err := reader.QuerySpan(LatencyMS, now.Add(-24*time.Hour), 24*time.Hour, 1000)
	if err != nil {
		t.Fatal(err)
	}
	if result.Tier != TierRAM || len(result.Points) != 1 || result.Points[0].Value != 42 {
		t.Fatalf("fallback result: %#v", result)
	}
}

func TestTieredReaderLogsPersistentErrorOnceAndFallsBack(t *testing.T) {
	now := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	ram := NewStore(10)
	_ = ram.Append(LatencyMS, Point{Time: now, Value: 7})
	persistent, _ := openTestSQLite(t, now)
	if err := persistent.Close(); err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	reader := NewTieredReaderWithLogger(ram, persistent, 3*time.Hour, log.New(&output, "", 0).Printf)

	for range 2 {
		result, err := reader.QuerySpan(LatencyMS, now.Add(-24*time.Hour), 24*time.Hour, 1000)
		if err != nil || result.Tier != TierRAM || len(result.Points) != 1 {
			t.Fatalf("fallback result=%#v err=%v", result, err)
		}
	}
	if got := bytes.Count(output.Bytes(), []byte("persistent history query")); got != 1 {
		t.Fatalf("log count=%d output=%q", got, output.String())
	}
}

func valueOf(value *float32) float32 {
	if value == nil {
		return 0
	}
	return *value
}
