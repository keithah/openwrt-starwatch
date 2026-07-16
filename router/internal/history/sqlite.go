package history

import (
	"context"
	"database/sql"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	_ "modernc.org/sqlite"

	"starwatch/internal/outage"
)

type SQLiteOptions struct {
	MinuteRetention  time.Duration
	QuarterRetention time.Duration
	Now              func() time.Time
}

type Event struct {
	At     time.Time `json:"at"`
	Kind   string    `json:"kind"`
	Detail string    `json:"detail"`
}

type SQLiteStore struct {
	db      *sql.DB
	path    string
	options SQLiteOptions

	mu             sync.Mutex
	pending        []Event
	pendingOutages []outage.Entry
	lastFlush      time.Time
}

const historySchema = `
CREATE TABLE IF NOT EXISTS minute (
  series TEXT NOT NULL, ts INTEGER NOT NULL, min REAL NOT NULL, avg REAL NOT NULL,
  max REAL NOT NULL, samples INTEGER NOT NULL, PRIMARY KEY(series, ts)
);
CREATE TABLE IF NOT EXISTS quarter (
  series TEXT NOT NULL, ts INTEGER NOT NULL, min REAL NOT NULL, avg REAL NOT NULL,
  max REAL NOT NULL, samples INTEGER NOT NULL, PRIMARY KEY(series, ts)
);
CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, kind TEXT NOT NULL, detail TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS outages (
  id INTEGER PRIMARY KEY AUTOINCREMENT, source TEXT NOT NULL, cause TEXT NOT NULL,
  start_ts INTEGER NOT NULL, duration_ns INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS speedtests (
  id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL,
  down_bps REAL NOT NULL DEFAULT 0, up_bps REAL NOT NULL DEFAULT 0, latency_ms REAL NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS minute_series_ts ON minute(series, ts);
CREATE INDEX IF NOT EXISTS quarter_series_ts ON quarter(series, ts);
`

func OpenSQLite(path string, options SQLiteOptions) (*SQLiteStore, bool, error) {
	if path == "" {
		return nil, false, fmt.Errorf("sqlite path is empty")
	}
	if options.MinuteRetention <= 0 {
		options.MinuteRetention = 7 * 24 * time.Hour
	}
	if options.QuarterRetention <= 0 {
		options.QuarterRetention = 30 * 24 * time.Hour
	}
	if options.Now == nil {
		options.Now = time.Now
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, false, err
	}
	_, statErr := os.Stat(path)
	existed := statErr == nil
	store, err := openSQLite(path, options)
	if err == nil {
		return store, false, nil
	}
	if !existed {
		return nil, false, err
	}
	backup := fmt.Sprintf("%s.corrupt-%d", path, options.Now().UnixNano())
	if renameErr := os.Rename(path, backup); renameErr != nil {
		return nil, false, fmt.Errorf("open sqlite: %v; move corrupt database: %w", err, renameErr)
	}
	store, recreateErr := openSQLite(path, options)
	if recreateErr != nil {
		return nil, false, fmt.Errorf("recreate sqlite after %v: %w", err, recreateErr)
	}
	return store, true, nil
}

func openSQLite(path string, options SQLiteOptions) (*SQLiteStore, error) {
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	fail := func(err error) (*SQLiteStore, error) {
		_ = db.Close()
		return nil, err
	}
	if _, err := db.Exec("PRAGMA journal_mode=MEMORY; PRAGMA synchronous=FULL;"); err != nil {
		return fail(err)
	}
	var check string
	if err := db.QueryRow("PRAGMA quick_check").Scan(&check); err != nil || check != "ok" {
		if err == nil {
			err = fmt.Errorf("sqlite quick_check: %s", check)
		}
		return fail(err)
	}
	if _, err := db.Exec(historySchema); err != nil {
		return fail(err)
	}
	store := &SQLiteStore{db: db, path: path, options: options}
	var latest int64
	if err := db.QueryRow("SELECT COALESCE(MAX(ts), 0) FROM minute").Scan(&latest); err != nil {
		return fail(err)
	}
	if latest > 0 {
		store.lastFlush = time.Unix(latest, 0).UTC()
	}
	return store, nil
}

func (s *SQLiteStore) Close() error { return s.db.Close() }

func (s *SQLiteStore) AddEvent(event Event) {
	s.mu.Lock()
	s.pending = append(s.pending, event)
	s.mu.Unlock()
}

func (s *SQLiteStore) SaveOutage(entry outage.Entry) error {
	if entry.Ongoing {
		return fmt.Errorf("cannot persist ongoing outage")
	}
	s.mu.Lock()
	s.pendingOutages = append(s.pendingOutages, entry)
	s.mu.Unlock()
	return nil
}

type aggregate struct {
	min, max float64
	sum      float64
	count    int64
}

type aggregateKey struct {
	series string
	at     time.Time
}

func (a *aggregate) add(value float64, samples int64) {
	if a.count == 0 {
		a.min, a.max = value, value
	} else {
		a.min = math.Min(a.min, value)
		a.max = math.Max(a.max, value)
	}
	a.sum += value * float64(samples)
	a.count += samples
}

func (a *aggregate) addRange(minimum, average, maximum float64, samples int64) {
	if a.count == 0 {
		a.min, a.max = minimum, maximum
	} else {
		a.min = math.Min(a.min, minimum)
		a.max = math.Max(a.max, maximum)
	}
	a.sum += average * float64(samples)
	a.count += samples
}

func (s *SQLiteStore) Flush(ctx context.Context, ram Reader, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if now.Year() < 2025 {
		return nil
	}
	since := time.Time{}
	if !s.lastFlush.IsZero() {
		since = s.lastFlush.Add(-time.Minute)
	}
	minutes := make(map[aggregateKey]*aggregate)
	for _, series := range ram.Series() {
		points, err := ram.Query(series, since, 0)
		if err != nil {
			return err
		}
		for _, point := range points {
			if point.Time.Year() < 2025 {
				continue
			}
			key := aggregateKey{series: series, at: point.Time.UTC().Truncate(time.Minute)}
			if minutes[key] == nil {
				minutes[key] = &aggregate{}
			}
			minutes[key].add(float64(point.Value), 1)
		}
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	rollback := func(err error) error { _ = tx.Rollback(); return err }
	minuteStatement, err := tx.PrepareContext(ctx, `INSERT INTO minute(series, ts, min, avg, max, samples)
		VALUES(?, ?, ?, ?, ?, ?) ON CONFLICT(series, ts) DO UPDATE SET
		min=excluded.min, avg=excluded.avg, max=excluded.max, samples=excluded.samples`)
	if err != nil {
		return rollback(err)
	}
	var earliest time.Time
	for key, values := range minutes {
		if _, err := minuteStatement.ExecContext(ctx, key.series, key.at.Unix(), values.min,
			values.sum/float64(values.count), values.max, values.count); err != nil {
			_ = minuteStatement.Close()
			return rollback(err)
		}
		if earliest.IsZero() || key.at.Before(earliest) {
			earliest = key.at
		}
	}
	_ = minuteStatement.Close()

	if !earliest.IsZero() {
		if err := rebuildQuarters(ctx, tx, earliest.Truncate(15*time.Minute)); err != nil {
			return rollback(err)
		}
	}
	if _, err := tx.ExecContext(ctx, "DELETE FROM minute WHERE ts < ?", now.Add(-s.options.MinuteRetention).Unix()); err != nil {
		return rollback(err)
	}
	if _, err := tx.ExecContext(ctx, "DELETE FROM quarter WHERE ts < ?", now.Add(-s.options.QuarterRetention).Unix()); err != nil {
		return rollback(err)
	}
	for _, event := range s.pending {
		eventTime := event.At
		if eventTime.Year() < 2025 {
			eventTime = now
		}
		if _, err := tx.ExecContext(ctx, "INSERT INTO events(ts, kind, detail) VALUES(?, ?, ?)", eventTime.Unix(), event.Kind, event.Detail); err != nil {
			return rollback(err)
		}
	}
	for _, entry := range s.pendingOutages {
		result, err := tx.ExecContext(ctx, `UPDATE outages SET duration_ns=MAX(duration_ns, ?)
			WHERE source=? AND cause=? AND start_ts=?`, int64(entry.Duration), entry.Source, entry.Cause, entry.Start.UnixNano())
		if err != nil {
			return rollback(err)
		}
		updated, err := result.RowsAffected()
		if err != nil {
			return rollback(err)
		}
		if updated == 0 {
			if _, err := tx.ExecContext(ctx, `INSERT INTO outages(source, cause, start_ts, duration_ns) VALUES(?, ?, ?, ?)`,
				entry.Source, entry.Cause, entry.Start.UnixNano(), int64(entry.Duration)); err != nil {
				return rollback(err)
			}
		}
	}
	for table, limit := range map[string]int{"events": 10_000, "outages": 10_000, "speedtests": 500} {
		query := fmt.Sprintf("DELETE FROM %s WHERE id NOT IN (SELECT id FROM %s ORDER BY id DESC LIMIT %d)", table, table, limit)
		if _, err := tx.ExecContext(ctx, query); err != nil {
			return rollback(err)
		}
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	s.pending = nil
	s.pendingOutages = nil
	s.lastFlush = now
	return nil
}

func (s *SQLiteStore) QueryOutages(since time.Time, limit int) ([]outage.Entry, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rows, err := s.db.Query(`SELECT source, cause, start_ts, duration_ns FROM outages
		WHERE start_ts+duration_ns>=? ORDER BY start_ts`, since.UnixNano())
	if err != nil {
		return nil, err
	}
	type key struct {
		source, cause string
		start         int64
	}
	combined := make(map[key]outage.Entry)
	for rows.Next() {
		var entry outage.Entry
		var startNS, durationNS int64
		if err := rows.Scan(&entry.Source, &entry.Cause, &startNS, &durationNS); err != nil {
			_ = rows.Close()
			return nil, err
		}
		entry.Start = time.Unix(0, startNS).UTC()
		entry.Duration = time.Duration(durationNS)
		combined[key{entry.Source, entry.Cause, startNS}] = entry
	}
	if err := rows.Close(); err != nil {
		return nil, err
	}
	for _, entry := range s.pendingOutages {
		if entry.Start.Add(entry.Duration).Before(since) {
			continue
		}
		combined[key{entry.Source, entry.Cause, entry.Start.UnixNano()}] = entry
	}
	entries := make([]outage.Entry, 0, len(combined))
	for _, entry := range combined {
		entries = append(entries, entry)
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Start.Before(entries[j].Start) })
	if limit > 0 && len(entries) > limit {
		entries = entries[len(entries)-limit:]
	}
	return entries, nil
}

func (s *SQLiteStore) QueryEvents(since time.Time, limit int) ([]Event, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rows, err := s.db.Query("SELECT ts, kind, detail FROM events WHERE ts>=? ORDER BY ts", since.Unix())
	if err != nil {
		return nil, err
	}
	var events []Event
	for rows.Next() {
		var timestamp int64
		var item Event
		if err := rows.Scan(&timestamp, &item.Kind, &item.Detail); err != nil {
			_ = rows.Close()
			return nil, err
		}
		item.At = time.Unix(timestamp, 0).UTC()
		events = append(events, item)
	}
	if err := rows.Close(); err != nil {
		return nil, err
	}
	for _, item := range s.pending {
		if !item.At.Before(since) {
			events = append(events, item)
		}
	}
	sort.SliceStable(events, func(i, j int) bool { return events[i].At.Before(events[j].At) })
	if limit > 0 && len(events) > limit {
		events = events[len(events)-limit:]
	}
	return events, nil
}

func rebuildQuarters(ctx context.Context, tx *sql.Tx, since time.Time) error {
	rows, err := tx.QueryContext(ctx, "SELECT series, ts, min, avg, max, samples FROM minute WHERE ts >= ? ORDER BY ts", since.Unix())
	if err != nil {
		return err
	}
	quarters := make(map[aggregateKey]*aggregate)
	for rows.Next() {
		var series string
		var timestamp int64
		var minimum, average, maximum float64
		var samples int64
		if err := rows.Scan(&series, &timestamp, &minimum, &average, &maximum, &samples); err != nil {
			_ = rows.Close()
			return err
		}
		at := time.Unix(timestamp, 0).UTC().Truncate(15 * time.Minute)
		key := aggregateKey{series: series, at: at}
		if quarters[key] == nil {
			quarters[key] = &aggregate{}
		}
		quarters[key].addRange(minimum, average, maximum, samples)
	}
	if err := rows.Close(); err != nil {
		return err
	}
	for key, values := range quarters {
		if _, err := tx.ExecContext(ctx, `INSERT INTO quarter(series, ts, min, avg, max, samples)
			VALUES(?, ?, ?, ?, ?, ?) ON CONFLICT(series, ts) DO UPDATE SET
			min=excluded.min, avg=excluded.avg, max=excluded.max, samples=excluded.samples`,
			key.series, key.at.Unix(), values.min, values.sum/float64(values.count), values.max, values.count); err != nil {
			return err
		}
	}
	return nil
}

func (s *SQLiteStore) QueryTier(series string, tier Tier, since time.Time, limit int) ([]Point, error) {
	if !knownSeries(series) {
		return nil, ErrUnknownSeries
	}
	if tier != TierMinute && tier != TierQuarter {
		return nil, fmt.Errorf("unsupported sqlite tier %q", tier)
	}
	rows, err := s.db.Query(fmt.Sprintf("SELECT ts, min, avg, max FROM %s WHERE series=? AND ts>=? ORDER BY ts", tier), series, since.Unix())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var points []Point
	for rows.Next() {
		var timestamp int64
		var minimum, average, maximum float64
		if err := rows.Scan(&timestamp, &minimum, &average, &maximum); err != nil {
			return nil, err
		}
		minValue, maxValue := float32(minimum), float32(maximum)
		points = append(points, Point{Time: time.Unix(timestamp, 0).UTC(), Value: float32(average), Min: &minValue, Max: &maxValue})
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return downsample(points, limit), nil
}
