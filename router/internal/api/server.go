// Package api serves Starwatch's token-authenticated local HTTP API.
package api

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"starwatch/internal/alert"
	"starwatch/internal/config"
	"starwatch/internal/dish"
	"starwatch/internal/event"
	"starwatch/internal/history"
	"starwatch/internal/mwan"
	"starwatch/internal/outage"
	starwatchweb "starwatch/web"
)

type SnapshotProvider interface {
	Snapshot() dish.Snapshot
}

type WANProvider interface {
	Snapshot() dish.WANStatus
}

type OutageProvider interface {
	Query(since time.Time, limit int) ([]outage.Entry, error)
}

type EventProvider interface {
	QueryEvents(since time.Time, limit int) ([]history.Event, error)
}

type EventSubscriber interface {
	Subscribe(capacity int) (<-chan event.Message, func())
}

// EventWriter and EventPublisher are deliberately split from the read-only
// event interfaces above so mutation handlers can audit successful actions
// without broadening the dependencies used by GET endpoints.
type EventWriter interface {
	AddEvent(history.Event)
}

type EventPublisher interface {
	Publish(event.Message)
}

type ControlProvider interface {
	Execute(context.Context, dish.ControlParams) (dish.ControlResult, error)
}

type ObstructionProvider interface {
	Snapshot() dish.Snapshot
	RefreshObstructionMap(context.Context) (*dish.ObstructionMap, error)
}

type SpeedtestProvider interface {
	Start(context.Context) error
	Snapshot() dish.SpeedtestSnapshot
}

type FailoverAssistProvider interface {
	Assist(context.Context, string) mwan.AssistResult
	Apply(context.Context, string) error
}

type SettingsProvider interface {
	Token() string
	View() config.PublicConfig
	Update(config.Update) error
	RegenerateToken() (string, error)
}

type RouterMutationProvider interface {
	RenameClient(context.Context, string, string, string) (uint32, error)
	SetClientBlocked(context.Context, string, string, bool) (uint32, error)
	ApplyRouterWifi(context.Context, string, dish.RouterWifiMutation) error
	ApplyRouterNetwork(context.Context, string, dish.RouterNetworkMutation) error
}

type Deps struct {
	Token           string
	TokenProvider   func() string
	Snapshot        SnapshotProvider
	History         history.SpanReader
	WAN             WANProvider
	Outages         OutageProvider
	Events          EventProvider
	Live            EventSubscriber
	AuditEvents     EventWriter
	AuditLive       EventPublisher
	Controls        ControlProvider
	Obstruction     ObstructionProvider
	Speedtest       SpeedtestProvider
	MapInterval     time.Duration
	FailoverAssist  FailoverAssistProvider
	Settings        SettingsProvider
	AlertDelivery   alert.Delivery
	RouterMutations RouterMutationProvider
	Now             func() time.Time
	WSInterval      time.Duration
	WSBuffer        int
	WSWriteTimeout  time.Duration
	WSWrite         func(context.Context, *websocket.Conn, any) error
}

type server struct {
	deps   Deps
	mux    *http.ServeMux
	static http.Handler
	ctx    context.Context
	cancel context.CancelFunc
	wsMu   sync.Mutex
	closed bool
	wsDone sync.WaitGroup
}

func NewServer(deps Deps) *server {
	if deps.Now == nil {
		deps.Now = time.Now
	}
	if deps.WSInterval <= 0 {
		deps.WSInterval = time.Second
	}
	if deps.MapInterval <= 0 {
		deps.MapInterval = 15 * time.Minute
	}
	if deps.WSBuffer <= 0 {
		deps.WSBuffer = 16
	}
	if deps.WSWriteTimeout <= 0 {
		deps.WSWriteTimeout = 2 * time.Second
	}
	if deps.WSWrite == nil {
		deps.WSWrite = func(ctx context.Context, connection *websocket.Conn, value any) error {
			return wsjson.Write(ctx, connection, value)
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	s := &server{deps: deps, ctx: ctx, cancel: cancel}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/status", s.auth(s.status))
	mux.HandleFunc("GET /api/diagnostics", s.auth(s.diagnostics))
	mux.HandleFunc("GET /api/router", s.auth(s.router))
	mux.HandleFunc("PATCH /api/router/clients/{mac}", s.auth(s.routerClientPatch))
	mux.HandleFunc("PATCH /api/router/wifi", s.auth(s.routerWifiPatch))
	mux.HandleFunc("GET /api/history", s.auth(s.history))
	mux.HandleFunc("GET /api/wan", s.auth(s.wan))
	mux.HandleFunc("GET /api/outages", s.auth(s.outages))
	mux.HandleFunc("GET /api/events", s.auth(s.events))
	mux.HandleFunc("GET /api/ws", s.auth(s.websocket))
	mux.HandleFunc("POST /api/control/{action}", s.auth(s.control))
	mux.HandleFunc("GET /api/obstruction-map", s.auth(s.obstructionMap))
	mux.HandleFunc("GET /api/speedtest", s.auth(s.speedtestStatus))
	mux.HandleFunc("POST /api/speedtest", s.auth(s.speedtestStart))
	mux.HandleFunc("GET /api/wan/failover-assist", s.auth(s.failoverAssistGet))
	mux.HandleFunc("POST /api/wan/failover-assist", s.auth(s.failoverAssistPost))
	mux.HandleFunc("GET /api/config", s.auth(s.configGet))
	mux.HandleFunc("PUT /api/config", s.auth(s.configPut))
	mux.HandleFunc("POST /api/config/regenerate-token", s.auth(s.configRegenerateToken))
	mux.HandleFunc("POST /api/alerts/test", s.auth(s.alertTest))
	s.mux = mux
	s.static = http.FileServerFS(starwatchweb.FileSystem())
	return s
}

func (s *server) alertTest(w http.ResponseWriter, _ *http.Request) {
	if s.deps.AlertDelivery == nil {
		http.Error(w, "alert delivery unavailable", http.StatusServiceUnavailable)
		return
	}
	snapshot := s.deps.Snapshot.Snapshot()
	device := ""
	if snapshot.DeviceInfo != nil {
		device = snapshot.DeviceInfo.ID
	}
	s.deps.AlertDelivery.Enqueue(alert.Notification{
		Alert: "test", Severity: alert.SeverityInfo, State: alert.StateFiring,
		At: s.deps.Now().Unix(), Detail: map[string]any{"test": true}, Device: device,
	})
	writeJSON(w, http.StatusAccepted, struct {
		Accepted bool `json:"accepted"`
	}{Accepted: true})
}

func (s *server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if strings.HasPrefix(r.URL.Path, "/api/") {
		s.mux.ServeHTTP(w, r)
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	s.static.ServeHTTP(w, r)
}

func (s *server) Close() {
	s.wsMu.Lock()
	if s.closed {
		s.wsMu.Unlock()
		return
	}
	s.closed = true
	s.cancel()
	s.wsMu.Unlock()
	s.wsDone.Wait()
}

func (s *server) outages(w http.ResponseWriter, r *http.Request) {
	span, ok := s.requestSpan(w, r, "30d")
	if !ok {
		return
	}
	if s.deps.Outages == nil {
		writeJSON(w, http.StatusOK, []outage.Entry{})
		return
	}
	entries, err := s.deps.Outages.Query(s.deps.Now().Add(-span), 1000)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, entries)
}

func (s *server) events(w http.ResponseWriter, r *http.Request) {
	span, ok := s.requestSpan(w, r, "30d")
	if !ok {
		return
	}
	if s.deps.Events == nil {
		writeJSON(w, http.StatusOK, []history.Event{})
		return
	}
	events, err := s.deps.Events.QueryEvents(s.deps.Now().Add(-span), 1000)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, events)
}

func (s *server) requestSpan(w http.ResponseWriter, r *http.Request, fallback string) (time.Duration, bool) {
	value := r.URL.Query().Get("span")
	if value == "" {
		value = fallback
	}
	span, err := parseSpan(value)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return 0, false
	}
	return span, true
}

func (s *server) websocket(w http.ResponseWriter, r *http.Request) {
	s.wsMu.Lock()
	if s.closed {
		s.wsMu.Unlock()
		http.Error(w, "server shutting down", http.StatusServiceUnavailable)
		return
	}
	s.wsDone.Add(1)
	s.wsMu.Unlock()
	connection, err := websocket.Accept(w, r, nil)
	if err != nil {
		s.wsDone.Done()
		return
	}
	defer s.wsDone.Done()
	defer connection.CloseNow()
	connection.SetReadLimit(1024)
	connectionCtx := connection.CloseRead(s.ctx)

	var messages <-chan event.Message
	cancelSubscription := func() {}
	if s.deps.Live != nil {
		messages, cancelSubscription = s.deps.Live.Subscribe(s.deps.WSBuffer)
	}
	defer cancelSubscription()
	ticker := time.NewTicker(s.deps.WSInterval)
	defer ticker.Stop()
	for {
		select {
		case <-s.ctx.Done():
			_ = connection.Close(websocket.StatusGoingAway, "server shutdown")
			return
		case <-connectionCtx.Done():
			return
		case <-ticker.C:
			snapshot := s.deps.Snapshot.Snapshot()
			wan := snapshot.WAN
			if s.deps.WAN != nil {
				wan = s.deps.WAN.Snapshot()
			}
			// The poller deliberately retains the last dish snapshot so status and
			// history can explain a failure. A retained snapshot is not a live
			// sample, though: publishing it after reachability is lost would make a
			// non-Starlink WAN look like it is still producing dish telemetry.
			liveDish := snapshot.Dish
			if !snapshot.DishReachable {
				liveDish = nil
			}
			if !s.writeWS(connection, struct {
				T             int64          `json:"t"`
				Topology      dish.Topology  `json:"topology"`
				DishReachable bool           `json:"dish_reachable"`
				Dish          *dish.Status   `json:"dish"`
				WAN           dish.WANStatus `json:"wan"`
			}{
				T:             s.deps.Now().Unix(),
				Topology:      snapshot.Topology,
				DishReachable: snapshot.DishReachable,
				Dish:          liveDish,
				WAN:           wan,
			}) {
				return
			}
		case message, ok := <-messages:
			if !ok {
				_ = connection.Close(websocket.StatusPolicyViolation, "client too slow")
				return
			}
			if !s.writeWS(connection, struct {
				Event event.Message `json:"event"`
			}{Event: message}) {
				return
			}
		}
	}
}

func (s *server) writeWS(connection *websocket.Conn, value any) bool {
	ctx, cancel := context.WithTimeout(s.ctx, s.deps.WSWriteTimeout)
	defer cancel()
	return s.deps.WSWrite(ctx, connection, value) == nil
}

func (s *server) auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		configuredToken := s.deps.Token
		if s.deps.TokenProvider != nil {
			configuredToken = s.deps.TokenProvider()
		}
		if configuredToken == "" {
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
		if subtle.ConstantTimeCompare([]byte(token), []byte(configuredToken)) != 1 {
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
	snapshot := s.deps.Snapshot.Snapshot()
	if s.deps.WAN != nil {
		snapshot.WAN = s.deps.WAN.Snapshot()
	}
	writeJSON(w, http.StatusOK, snapshot)
}

func (s *server) wan(w http.ResponseWriter, _ *http.Request) {
	if s.deps.WAN == nil {
		writeJSON(w, http.StatusOK, dish.WANStatus{})
		return
	}
	writeJSON(w, http.StatusOK, s.deps.WAN.Snapshot())
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
	result, err := s.deps.History.QuerySpan(series, s.deps.Now().Add(-span), span, 1000)
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
		Tier   history.Tier    `json:"tier"`
		Points []history.Point `json:"points"`
	}{Series: series, Span: spanText, Tier: result.Tier, Points: result.Points})
}

func parseSpan(value string) (time.Duration, error) {
	spans := map[string]time.Duration{
		"15m": 15 * time.Minute,
		"3h":  3 * time.Hour,
		"24h": 24 * time.Hour,
		"7d":  7 * 24 * time.Hour,
		"30d": 30 * 24 * time.Hour,
	}
	duration, ok := spans[value]
	if !ok {
		return 0, fmt.Errorf("unsupported span %q", value)
	}
	return duration, nil
}
