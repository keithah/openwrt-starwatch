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

// routerWifiPatchRequest is intentionally an HTTP-only contract at this stage.
// The mutation controller is introduced separately, after its fake-router
// readback tests establish the safe write behavior for every field.
type routerWifiPatchRequest struct {
	ConfigRevision      string                  `json:"config_revision"`
	Confirmation        string                  `json:"confirmation"`
	Network             *routerWifiNetworkPatch `json:"network"`
	Radio               *routerWifiRadioPatch   `json:"radio"`
	BandSteeringEnabled *bool                   `json:"band_steering_enabled"`
	OutdoorMode         *bool                   `json:"outdoor_mode"`
	DNS                 *routerWifiDNSPatch     `json:"dns"`
}

type routerWifiNetworkPatch struct {
	SSID       string  `json:"ssid"`
	Band       string  `json:"band"`
	NewSSID    *string `json:"new_ssid"`
	Security   *string `json:"security"`
	Passphrase *string `json:"passphrase"`
	Hidden     *bool   `json:"hidden"`
	Disabled   *bool   `json:"disabled"`
}

type routerWifiRadioPatch struct {
	Band            string  `json:"band"`
	Enabled         *bool   `json:"enabled"`
	Channel         *uint32 `json:"channel"`
	ChannelWidthMHz *uint32 `json:"channel_width_mhz"`
	TxPowerLevel    *string `json:"tx_power_level"`
}

type routerWifiDNSPatch struct {
	Servers []string `json:"servers"`
	Secure  *bool    `json:"secure"`
}

func (s *server) routerWifiPatch(w http.ResponseWriter, r *http.Request) {
	payload, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 128<<10))
	if err != nil {
		http.Error(w, "invalid router Wi-Fi request", http.StatusBadRequest)
		return
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(payload, &raw); err != nil {
		http.Error(w, "invalid router Wi-Fi request", http.StatusBadRequest)
		return
	}
	if routerWifiRequestHasExcludedField(raw) {
		http.Error(w, "router write field is excluded", http.StatusUnprocessableEntity)
		return
	}
	var body routerWifiPatchRequest
	strict := json.NewDecoder(bytes.NewReader(payload))
	strict.DisallowUnknownFields()
	if err := strict.Decode(&body); err != nil {
		http.Error(w, "invalid router Wi-Fi request", http.StatusBadRequest)
		return
	}
	if err := strict.Decode(&struct{}{}); err != io.EOF {
		http.Error(w, "invalid router Wi-Fi request", http.StatusBadRequest)
		return
	}
	if strings.TrimSpace(body.ConfigRevision) == "" {
		http.Error(w, "config_revision is required", http.StatusBadRequest)
		return
	}
	openNetwork := body.Network != nil && body.Network.Security != nil && *body.Network.Security == "OPEN"
	if (!openNetwork && body.Confirmation != "APPLY WIFI CHANGES") || (openNetwork && body.Confirmation != "CREATE OPEN NETWORK") {
		http.Error(w, "APPLY WIFI CHANGES confirmation is required", http.StatusBadRequest)
		return
	}
	if !routerWifiPatchHasMutation(body) {
		http.Error(w, "at least one Wi-Fi mutation is required", http.StatusBadRequest)
		return
	}
	if body.Network != nil && (!routerWifiNetworkSelectorValid(*body.Network) || !routerWifiNetworkMutationValid(*body.Network)) {
		http.Error(w, "network requires non-empty ssid, band, and a mutation", http.StatusBadRequest)
		return
	}
	if body.Network != nil && body.Network.Passphrase != nil {
		// WPA/WPA2/WPA3 personal credentials are 8--63 bytes. Keep this
		// validation at the HTTP boundary so an invalid write never reaches the
		// router (and never appears in an upstream error or audit record).
		if size := len(*body.Network.Passphrase); size < 8 || size > 63 {
			http.Error(w, "passphrase must be 8 to 63 bytes", http.StatusBadRequest)
			return
		}
	}
	if s.deps.RouterMutations == nil {
		http.Error(w, "router mutations unavailable", http.StatusServiceUnavailable)
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
	if body.Network != nil {
		if body.Radio != nil || body.BandSteeringEnabled != nil || body.OutdoorMode != nil || body.DNS != nil {
			http.Error(w, "network edits cannot be combined with scalar Wi-Fi mutations", http.StatusUnprocessableEntity)
			return
		}
		mutation := dish.RouterNetworkMutation{SSID: body.Network.SSID, Band: body.Network.Band, NewSSID: body.Network.NewSSID, Security: body.Network.Security, Passphrase: body.Network.Passphrase, Hidden: body.Network.Hidden, Disabled: body.Network.Disabled}
		if err := s.deps.RouterMutations.ApplyRouterNetwork(r.Context(), body.ConfigRevision, mutation); err != nil {
			switch {
			case errors.Is(err, dish.ErrRouterRevisionStale):
				http.Error(w, "router config revision is stale", http.StatusConflict)
			case errors.Is(err, dish.ErrRouterNetworkCredentialsUnavailable):
				http.Error(w, err.Error(), http.StatusUnprocessableEntity)
			case errors.Is(err, dish.ErrRouterWifiUnsupported):
				http.Error(w, err.Error(), http.StatusUnprocessableEntity)
			case errors.Is(err, dish.ErrRouterWriteUnconfirmed):
				http.Error(w, "write not confirmed by readback", http.StatusBadGateway)
			default:
				http.Error(w, "router Wi-Fi upstream failure", http.StatusBadGateway)
			}
			return
		}
		s.auditRouterNetwork(mutation)
		writeJSON(w, http.StatusAccepted, struct {
			Accepted bool `json:"accepted"`
		}{Accepted: true})
		return
	}
	mutation, err := routerWifiScalarMutation(body)
	if err != nil {
		http.Error(w, err.Error(), http.StatusUnprocessableEntity)
		return
	}
	if err := s.deps.RouterMutations.ApplyRouterWifi(r.Context(), body.ConfigRevision, mutation); err != nil {
		switch {
		case errors.Is(err, dish.ErrRouterRevisionStale):
			http.Error(w, "router config revision is stale", http.StatusConflict)
		case errors.Is(err, dish.ErrRouterWifiUnsupported), errors.Is(err, dish.ErrRouterUnsafeChannel):
			http.Error(w, err.Error(), http.StatusUnprocessableEntity)
		case errors.Is(err, dish.ErrRouterWriteUnconfirmed):
			http.Error(w, "write not confirmed by readback", http.StatusBadGateway)
		default:
			http.Error(w, "router Wi-Fi upstream failure", http.StatusBadGateway)
		}
		return
	}
	s.auditRouterWifi(mutation)
	writeJSON(w, http.StatusAccepted, struct {
		Accepted bool `json:"accepted"`
	}{Accepted: true})
}

func routerWifiScalarMutation(body routerWifiPatchRequest) (dish.RouterWifiMutation, error) {
	// Network collection writes are Task 3. This task permits exactly one scalar
	// mutation so a request can never set multiple apply flags.
	if body.Network != nil {
		return dish.RouterWifiMutation{}, errors.New("network writes are not supported in this release")
	}
	var mutations []dish.RouterWifiMutation
	if body.Radio != nil {
		radio := body.Radio
		if strings.TrimSpace(radio.Band) == "" || !routerWifiRadioMutationValid(*radio) {
			return dish.RouterWifiMutation{}, errors.New("radio requires non-empty band and a mutation")
		}
		if radio.Enabled != nil {
			mutations = append(mutations, dish.RouterWifiMutation{Field: dish.RouterWifiBandEnabled, Band: radio.Band, Bool: *radio.Enabled})
		}
		if radio.Channel != nil {
			mutations = append(mutations, dish.RouterWifiMutation{Field: dish.RouterWifiChannel, Band: radio.Band, Uint: *radio.Channel})
		}
		if radio.ChannelWidthMHz != nil {
			mutations = append(mutations, dish.RouterWifiMutation{Field: dish.RouterWifiWidth, Band: radio.Band, Uint: *radio.ChannelWidthMHz})
		}
		if radio.TxPowerLevel != nil {
			level, ok := routerTxPowerLevel(*radio.TxPowerLevel)
			if !ok {
				return dish.RouterWifiMutation{}, errors.New("tx_power_level must be a real TX_POWER_LEVEL_* enum name")
			}
			mutations = append(mutations, dish.RouterWifiMutation{Field: dish.RouterWifiTxPower, Band: radio.Band, Uint: level})
		}
	}
	if body.BandSteeringEnabled != nil {
		mutations = append(mutations, dish.RouterWifiMutation{Field: dish.RouterWifiSteering, Bool: *body.BandSteeringEnabled})
	}
	if body.OutdoorMode != nil {
		mutations = append(mutations, dish.RouterWifiMutation{Field: dish.RouterWifiOutdoor, Bool: *body.OutdoorMode})
	}
	if body.DNS != nil {
		if len(body.DNS.Servers) > 0 {
			mutations = append(mutations, dish.RouterWifiMutation{Field: dish.RouterWifiNameservers, Strings: body.DNS.Servers})
		}
		if body.DNS.Secure != nil {
			mutations = append(mutations, dish.RouterWifiMutation{Field: dish.RouterWifiSecureDNS, Bool: *body.DNS.Secure})
		}
	}
	if len(mutations) != 1 {
		return dish.RouterWifiMutation{}, errors.New("exactly one scalar Wi-Fi mutation is required")
	}
	return mutations[0], nil
}

var routerWifiExcludedTopLevelFields = map[string]struct{}{
	"country_code":   {},
	"regulatory":     {},
	"pin":            {},
	"mesh":           {},
	"bypass":         {},
	"bypass_mode":    {},
	"ap":             {},
	"access_point":   {},
	"repeater":       {},
	"dhcp":           {},
	"firewall":       {},
	"route":          {},
	"routes":         {},
	"static_route":   {},
	"static_routes":  {},
	"http_server":    {},
	"dynamic":        {},
	"client_keys":    {},
	"client_key":     {},
	"client_configs": {},
	"client_names":   {},
	"radius":         {},
	"setup_complete": {},
	"sandbox":        {},
	"disable_set_wifi_config_from_controller": {},
	"disablesetwificonfigfromcontroller":      {},
	"factory":                                 {},
	"debug":                                   {},
}

func routerWifiRequestHasExcludedField(raw map[string]json.RawMessage) bool {
	for field, value := range raw {
		if _, excluded := routerWifiExcludedTopLevelFields[strings.ToLower(field)]; excluded {
			return true
		}
		switch field {
		case "clients", "dfs_enabled":
			return true
		case "network":
			var network map[string]json.RawMessage
			if json.Unmarshal(value, &network) == nil {
				if _, ok := network["id"]; ok {
					return true
				}
				if _, ok := network["bssid"]; ok {
					return true
				}
			}
		case "radio":
			var radio map[string]json.RawMessage
			if json.Unmarshal(value, &radio) == nil {
				if _, ok := radio["dfs_enabled"]; ok {
					return true
				}
			}
		}
	}
	return false
}

func routerWifiPatchHasMutation(body routerWifiPatchRequest) bool {
	return body.Network != nil || body.Radio != nil || body.BandSteeringEnabled != nil || body.OutdoorMode != nil || body.DNS != nil
}

func routerWifiNetworkSelectorValid(network routerWifiNetworkPatch) bool {
	return strings.TrimSpace(network.SSID) != "" && strings.TrimSpace(network.Band) != ""
}

func routerWifiNetworkMutationValid(network routerWifiNetworkPatch) bool {
	return (network.NewSSID != nil && strings.TrimSpace(*network.NewSSID) != "") || network.Security != nil || network.Passphrase != nil || network.Hidden != nil || network.Disabled != nil
}

func routerWifiRadioMutationValid(radio routerWifiRadioPatch) bool {
	return radio.Enabled != nil || radio.Channel != nil || radio.ChannelWidthMHz != nil || radio.TxPowerLevel != nil
}

func routerTxPowerLevel(value string) (uint32, bool) {
	switch value {
	case "TX_POWER_LEVEL_100":
		return 100, true
	case "TX_POWER_LEVEL_80":
		return 80, true
	case "TX_POWER_LEVEL_50":
		return 50, true
	case "TX_POWER_LEVEL_25":
		return 25, true
	case "TX_POWER_LEVEL_12":
		return 12, true
	case "TX_POWER_LEVEL_6":
		return 6, true
	default:
		return 0, false
	}
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

func (s *server) auditRouterWifi(mutation dish.RouterWifiMutation) {
	detail := struct {
		Action string `json:"action"`
		Field  string `json:"field"`
		Band   string `json:"band,omitempty"`
		Result string `json:"result"`
	}{Action: "update_wifi", Field: string(mutation.Field), Band: mutation.Band, Result: "accepted"}
	s.publishRouterControl(detail)
}

func (s *server) auditRouterNetwork(mutation dish.RouterNetworkMutation) {
	detail := struct {
		Action string `json:"action"`
		SSID   string `json:"ssid"`
		Band   string `json:"band"`
		Result string `json:"result"`
	}{Action: "update_wifi_network", SSID: mutation.SSID, Band: mutation.Band, Result: "accepted"}
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
