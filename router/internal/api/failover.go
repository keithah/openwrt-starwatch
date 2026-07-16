package api

import (
	"errors"
	"net/http"

	"starwatch/internal/mwan"
)

func (s *server) failoverAssistGet(w http.ResponseWriter, r *http.Request) {
	if s.deps.FailoverAssist == nil {
		writeJSON(w, http.StatusOK, mwan.AssistResult{Reason: "mwan3 is not installed", Proposed: []mwan.Change{}})
		return
	}
	writeJSON(w, http.StatusOK, s.deps.FailoverAssist.Assist(r.Context(), s.primaryWAN()))
}

func (s *server) failoverAssistPost(w http.ResponseWriter, r *http.Request) {
	if s.deps.FailoverAssist == nil {
		writeJSON(w, http.StatusConflict, mwan.AssistResult{Reason: "mwan3 is not installed", Proposed: []mwan.Change{}})
		return
	}
	result := s.deps.FailoverAssist.Assist(r.Context(), s.primaryWAN())
	if !result.Available {
		writeJSON(w, http.StatusConflict, result)
		return
	}
	if err := s.deps.FailoverAssist.Apply(r.Context(), s.primaryWAN()); err != nil {
		if errors.Is(err, mwan.ErrAssistUnavailable) {
			writeJSON(w, http.StatusConflict, s.deps.FailoverAssist.Assist(r.Context(), s.primaryWAN()))
			return
		}
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	writeJSON(w, http.StatusOK, s.deps.FailoverAssist.Assist(r.Context(), s.primaryWAN()))
}

func (s *server) primaryWAN() string {
	if s.deps.WAN == nil {
		return ""
	}
	return s.deps.WAN.Snapshot().Interface
}
