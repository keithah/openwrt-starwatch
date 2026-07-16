package api

import (
	"encoding/json"
	"errors"
	"net/http"

	"starwatch/internal/config"
)

func (s *server) configGet(w http.ResponseWriter, _ *http.Request) {
	if s.deps.Settings == nil {
		http.Error(w, "settings unavailable", http.StatusServiceUnavailable)
		return
	}
	writeJSON(w, http.StatusOK, s.deps.Settings.View())
}

func (s *server) configPut(w http.ResponseWriter, r *http.Request) {
	if s.deps.Settings == nil {
		http.Error(w, "settings unavailable", http.StatusServiceUnavailable)
		return
	}
	var update config.Update
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 128<<10))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&update); err != nil {
		http.Error(w, "invalid config update: "+err.Error(), http.StatusBadRequest)
		return
	}
	if err := s.deps.Settings.Update(update); err != nil {
		code := http.StatusBadRequest
		if !errors.Is(err, config.ErrRestartManaged) && !errors.Is(err, config.ErrInvalidUpdate) {
			code = http.StatusInternalServerError
		}
		http.Error(w, err.Error(), code)
		return
	}
	writeJSON(w, http.StatusOK, s.deps.Settings.View())
}

func (s *server) configRegenerateToken(w http.ResponseWriter, _ *http.Request) {
	if s.deps.Settings == nil {
		http.Error(w, "settings unavailable", http.StatusServiceUnavailable)
		return
	}
	token, err := s.deps.Settings.RegenerateToken()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, struct {
		Token string `json:"token"`
	}{Token: token})
}
