package api

import (
	"net/http"

	"starwatch/internal/dish"
)

func (s *server) router(w http.ResponseWriter, _ *http.Request) {
	snapshot := s.deps.Snapshot.Snapshot()
	if snapshot.Topology != dish.TopologyFull || snapshot.StarlinkRouter == nil || !snapshot.StarlinkRouter.Reachable {
		http.Error(w, "Starlink router unavailable outside topology B", http.StatusServiceUnavailable)
		return
	}
	writeJSON(w, http.StatusOK, snapshot.StarlinkRouter)
}
