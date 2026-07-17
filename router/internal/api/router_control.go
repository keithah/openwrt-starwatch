package api

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"

	"starwatch/internal/dish"
	"starwatch/internal/event"
	"starwatch/internal/history"
)

type routerClientPatchRequest struct {
	ConfigRevision string  `json:"config_revision"`
	Confirmation   string  `json:"confirmation"`
	GivenName      *string `json:"given_name"`
	Blocked        *bool   `json:"blocked"`
}

func (s *server) routerClientPatch(w http.ResponseWriter, r *http.Request) {
	if s.deps.RouterMutations == nil {
		http.Error(w, "router mutations unavailable", http.StatusServiceUnavailable)
		return
	}
	payload, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 128<<10))
	if err != nil {
		http.Error(w, "invalid router rename request", http.StatusBadRequest)
		return
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(payload, &raw); err != nil {
		http.Error(w, "invalid router rename request", http.StatusBadRequest)
		return
	}
	for field := range raw {
		if deferredRouterWriteField(field) {
			http.Error(w, field+" is not supported in this release", http.StatusUnprocessableEntity)
			return
		}
	}
	var body routerClientPatchRequest
	strict := json.NewDecoder(bytes.NewReader(payload))
	strict.DisallowUnknownFields()
	if err := strict.Decode(&body); err != nil {
		http.Error(w, "invalid router rename request", http.StatusBadRequest)
		return
	}
	if err := strict.Decode(&struct{}{}); err != io.EOF {
		http.Error(w, "invalid router rename request", http.StatusBadRequest)
		return
	}
	if strings.TrimSpace(body.ConfigRevision) == "" {
		http.Error(w, "config_revision is required", http.StatusBadRequest)
		return
	}
	if (body.GivenName == nil && body.Blocked == nil) || (body.GivenName != nil && body.Blocked != nil) {
		http.Error(w, "exactly one of given_name or blocked is required", http.StatusBadRequest)
		return
	}
	if body.GivenName != nil && (body.Confirmation != "RENAME CLIENT" || strings.TrimSpace(*body.GivenName) == "") {
		http.Error(w, "RENAME CLIENT confirmation and non-empty given_name are required", http.StatusBadRequest)
		return
	}
	if body.Blocked != nil {
		expected := "UNBLOCK CLIENT"
		if *body.Blocked {
			expected = "BLOCK CLIENT"
		}
		if body.Confirmation != expected {
			http.Error(w, "confirmation does not match blocked value", http.StatusBadRequest)
			return
		}
	}

	mac, ok := dish.NormalizeRouterMAC(r.PathValue("mac"))
	if !ok {
		http.Error(w, "client not found", http.StatusNotFound)
		return
	}
	snapshot := s.deps.Snapshot.Snapshot()
	if snapshot.Topology != dish.TopologyFull || snapshot.StarlinkRouter == nil || !snapshot.StarlinkRouter.Reachable {
		http.Error(w, "Starlink router unavailable", http.StatusServiceUnavailable)
		return
	}
	if body.ConfigRevision != snapshot.StarlinkRouter.ConfigRevision {
		http.Error(w, "router config revision is stale", http.StatusConflict)
		return
	}
	if !snapshotHasRouterClient(snapshot.StarlinkRouter.Clients, mac) {
		http.Error(w, "client not found", http.StatusNotFound)
		return
	}
	if body.GivenName != nil {
		s.routerClientRename(w, r, mac, body)
		return
	}
	s.routerClientBlock(w, r, mac, body)
}

func (s *server) routerClientRename(w http.ResponseWriter, r *http.Request, mac string, body routerClientPatchRequest) {
	clientID, err := s.deps.RouterMutations.RenameClient(r.Context(), mac, body.ConfigRevision, *body.GivenName)
	if err != nil {
		switch {
		case errors.Is(err, dish.ErrRouterRevisionStale):
			http.Error(w, "router config revision is stale", http.StatusConflict)
		case errors.Is(err, dish.ErrRouterNameUnsupported):
			http.Error(w, "client naming is not supported by this router firmware", http.StatusUnprocessableEntity)
		case errors.Is(err, dish.ErrRouterWriteUnconfirmed):
			http.Error(w, "write not confirmed by readback", http.StatusBadGateway)
		default:
			http.Error(w, "router rename upstream failure", http.StatusBadGateway)
		}
		return
	}
	s.auditRouterRename(mac, *body.GivenName, clientID)
	writeJSON(w, http.StatusAccepted, struct {
		Accepted bool `json:"accepted"`
	}{Accepted: true})
}

func (s *server) routerClientBlock(w http.ResponseWriter, r *http.Request, mac string, body routerClientPatchRequest) {
	clientID, err := s.deps.RouterMutations.SetClientBlocked(r.Context(), mac, body.ConfigRevision, *body.Blocked)
	if err != nil {
		switch {
		case errors.Is(err, dish.ErrRouterRevisionStale):
			http.Error(w, "router config revision is stale", http.StatusConflict)
		case errors.Is(err, dish.ErrRouterUserManagedBlock):
			http.Error(w, "client has a user-managed block schedule", http.StatusConflict)
		case errors.Is(err, dish.ErrRouterBlockUnsupported):
			http.Error(w, "client blocking is not supported by this router firmware", http.StatusUnprocessableEntity)
		case errors.Is(err, dish.ErrRouterWriteUnconfirmed):
			http.Error(w, "write not confirmed by readback", http.StatusBadGateway)
		default:
			http.Error(w, "router block upstream failure", http.StatusBadGateway)
		}
		return
	}
	action := "unblock_client"
	if *body.Blocked {
		action = "block_client"
	}
	s.auditRouterBlock(action, mac, clientID)
	writeJSON(w, http.StatusAccepted, struct {
		Accepted bool `json:"accepted"`
	}{Accepted: true})
}

// auditRouterRename is intentionally called only after the targeted RPC has
// completed config and live-client readback confirmation. It records only the
// requested name and identity, never surrounding router configuration.
func (s *server) auditRouterRename(mac, givenName string, clientID uint32) {
	detail := struct {
		Action    string `json:"action"`
		MAC       string `json:"mac"`
		GivenName string `json:"given_name"`
		Result    string `json:"result"`
		ClientID  uint32 `json:"client_id"`
	}{
		Action: "rename_client", MAC: mac, GivenName: givenName, Result: "accepted", ClientID: clientID,
	}
	s.publishRouterControl(detail)
}

// auditRouterBlock deliberately has no given_name member: a block operation
// must not imply it changed or observed the client's display name.
func (s *server) auditRouterBlock(action, mac string, clientID uint32) {
	detail := struct {
		Action   string `json:"action"`
		MAC      string `json:"mac"`
		Result   string `json:"result"`
		ClientID uint32 `json:"client_id"`
	}{Action: action, MAC: mac, Result: "accepted", ClientID: clientID}
	s.publishRouterControl(detail)
}

func (s *server) publishRouterControl(detail any) {
	encoded, err := json.Marshal(detail)
	if err != nil {
		return
	}
	at := s.deps.Now()
	if s.deps.AuditEvents != nil {
		s.deps.AuditEvents.AddEvent(history.Event{At: at, Kind: "router_control", Detail: string(encoded)})
	}
	if s.deps.AuditLive != nil {
		s.deps.AuditLive.Publish(event.Message{Kind: "router_control", At: at, Data: detail})
	}
}

func snapshotHasRouterClient(clients []dish.RouterClient, mac string) bool {
	for _, client := range clients {
		if normalized, ok := dish.NormalizeRouterMAC(client.MAC); ok && normalized == mac {
			return true
		}
	}
	return false
}

func deferredRouterWriteField(field string) bool {
	field = strings.ToLower(field)
	for _, token := range []string{
		"wifi", "radio", "ssid", "bssid", "pass", "psk", "security", "channel", "tx_power", "band", "network", "auth",
		"interface", "credential", "hidden", "disabled", "domain", "ipv4", "ipv6", "basic_service_set",
	} {
		if strings.Contains(field, token) {
			return true
		}
	}
	return false
}
