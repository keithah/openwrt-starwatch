package api

import (
	"errors"
	"net/http"

	"starwatch/internal/dish"
)

func (s *server) speedtestStatus(w http.ResponseWriter, _ *http.Request) {
	if s.deps.Speedtest == nil {
		writeJSON(w, http.StatusOK, dish.SpeedtestSnapshot{State: dish.SpeedtestUnsupported})
		return
	}
	writeJSON(w, http.StatusOK, s.deps.Speedtest.Snapshot())
}

func (s *server) speedtestStart(w http.ResponseWriter, r *http.Request) {
	if s.deps.Speedtest == nil {
		http.Error(w, "speed test unavailable", http.StatusServiceUnavailable)
		return
	}
	if err := s.deps.Speedtest.Start(r.Context()); err != nil {
		if errors.Is(err, dish.ErrSpeedtestRunning) {
			http.Error(w, err.Error(), http.StatusConflict)
			return
		}
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	writeJSON(w, http.StatusAccepted, s.deps.Speedtest.Snapshot())
}
