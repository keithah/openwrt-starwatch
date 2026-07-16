package api

import (
	"encoding/json"
	"errors"
	"net/http"

	"starwatch/internal/dish"
)

func (s *server) control(w http.ResponseWriter, r *http.Request) {
	if s.deps.Controls == nil {
		http.Error(w, "dish controls unavailable", http.StatusServiceUnavailable)
		return
	}
	params := dish.ControlParams{Action: r.PathValue("action")}
	if r.ContentLength != 0 {
		decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10))
		if err := decoder.Decode(&params); err != nil {
			http.Error(w, "invalid JSON request", http.StatusBadRequest)
			return
		}
		params.Action = r.PathValue("action")
	}
	result, err := s.deps.Controls.Execute(r.Context(), params)
	if err != nil {
		statusCode := http.StatusBadGateway
		if errors.Is(err, dish.ErrInvalidControl) {
			statusCode = http.StatusBadRequest
		}
		http.Error(w, err.Error(), statusCode)
		return
	}
	writeJSON(w, http.StatusAccepted, result)
}
