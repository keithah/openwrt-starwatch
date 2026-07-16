package history

import (
	"log"
	"sync"
	"time"
)

type Tier string

const (
	TierRAM     Tier = "ram"
	TierMinute  Tier = "minute"
	TierQuarter Tier = "quarter"
)

type QueryResult struct {
	Tier   Tier
	Points []Point
}

type SpanReader interface {
	QuerySpan(series string, since time.Time, span time.Duration, limit int) (QueryResult, error)
}

type TieredReader struct {
	ram        Reader
	persistent *SQLiteStore
	ramSpan    time.Duration
	logf       func(string, ...any)
	logOnce    sync.Once
}

func NewTieredReader(ram Reader, persistent *SQLiteStore, ramSpan time.Duration) *TieredReader {
	return NewTieredReaderWithLogger(ram, persistent, ramSpan, log.Printf)
}

func NewTieredReaderWithLogger(ram Reader, persistent *SQLiteStore, ramSpan time.Duration, logf func(string, ...any)) *TieredReader {
	return &TieredReader{ram: ram, persistent: persistent, ramSpan: ramSpan, logf: logf}
}

func (r *TieredReader) QuerySpan(series string, since time.Time, span time.Duration, limit int) (QueryResult, error) {
	tier := TierRAM
	if span > r.ramSpan && span <= 7*24*time.Hour {
		tier = TierMinute
	} else if span > 7*24*time.Hour {
		tier = TierQuarter
	}
	if tier != TierRAM && r.persistent != nil {
		points, err := r.persistent.QueryTier(series, tier, since, limit)
		if err == nil && len(points) > 0 {
			return QueryResult{Tier: tier, Points: points}, nil
		}
		if err != nil && r.logf != nil {
			r.logOnce.Do(func() { r.logf("starwatchd: persistent history query failed; falling back to RAM: %v", err) })
		}
	}
	points, err := r.ram.Query(series, since, limit)
	return QueryResult{Tier: TierRAM, Points: points}, err
}
