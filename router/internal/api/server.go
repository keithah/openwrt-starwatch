// Package api serves Starwatch's token-authenticated local HTTP API.
package api

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"starwatch/internal/dish"
	"starwatch/internal/history"
)

type SnapshotProvider interface {
	Snapshot() dish.Snapshot
}

type Deps struct {
	Token    string
	Snapshot SnapshotProvider
	History  history.Reader
	Now      func() time.Time
}

type server struct {
	deps Deps
}

func NewServer(deps Deps) http.Handler {
	if deps.Now == nil {
		deps.Now = time.Now
	}
	s := &server{deps: deps}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/status", s.auth(s.status))
	mux.HandleFunc("GET /api/history", s.auth(s.history))
	return mux
}

func (s *server) auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if s.deps.Token == "" {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		token := ""
		authorization := r.Header.Get("Authorization")
		if strings.HasPrefix(authorization, "Bearer ") {
			token = strings.TrimPrefix(authorization, "Bearer ")
		}
		if token == "" {
			token = r.URL.Query().Get("token")
		}
		if subtle.ConstantTimeCompare([]byte(token), []byte(s.deps.Token)) != 1 {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func (s *server) status(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, s.deps.Snapshot.Snapshot())
}

func (s *server) history(w http.ResponseWriter, r *http.Request) {
	series := r.URL.Query().Get("series")
	if series == "" {
		http.Error(w, "series is required", http.StatusBadRequest)
		return
	}
	spanText := r.URL.Query().Get("span")
	if spanText == "" {
		spanText = "3h"
	}
	span, err := parseSpan(spanText)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	points, err := s.deps.History.Query(series, s.deps.Now().Add(-span), 1000)
	if errors.Is(err, history.ErrUnknownSeries) {
		http.Error(w, fmt.Sprintf("unknown series %q", series), http.StatusBadRequest)
		return
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, struct {
		Series string          `json:"series"`
		Span   string          `json:"span"`
		Points []history.Point `json:"points"`
	}{Series: series, Span: spanText, Points: points})
}

func parseSpan(value string) (time.Duration, error) {
	if strings.HasSuffix(value, "d") {
		days, err := strconv.Atoi(strings.TrimSuffix(value, "d"))
		if err != nil || days <= 0 {
			return 0, fmt.Errorf("invalid span %q", value)
		}
		return time.Duration(days) * 24 * time.Hour, nil
	}
	duration, err := time.ParseDuration(value)
	if err != nil || duration <= 0 {
		return 0, fmt.Errorf("invalid span %q", value)
	}
	return duration, nil
}
