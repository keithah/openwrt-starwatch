package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"starwatch/internal/dish"
	"starwatch/internal/history"
)

func TestRouterEndpointRequiresTopologyBAndReachability(t *testing.T) {
	for _, snapshot := range []dish.Snapshot{
		{Topology: dish.TopologyWANOnly},
		{Topology: dish.TopologyFull, StarlinkRouter: &dish.StarlinkRouter{Reachable: false}},
	} {
		handler := NewServer(Deps{Token: "secret", Snapshot: snapshotStub{snapshot: snapshot}, History: history.NewStore(1)})
		if got := request(handler, http.MethodGet, "/api/router", "secret"); got.Code != http.StatusServiceUnavailable {
			t.Fatalf("snapshot=%+v code=%d body=%s", snapshot, got.Code, got.Body.String())
		}
	}
}

func TestRouterEndpointReturnsTypedReadOnlySnapshot(t *testing.T) {
	router := &dish.StarlinkRouter{Reachable: true, ConfigRevision: "incarnation:42", Device: dish.RouterDevice{ID: "Router-1"}, Networks: []dish.RouterNetwork{{Domain: "lan", BasicServiceSets: []dish.RouterBasicServiceSet{{SSID: "Starlink", BSSID: "", Security: "WPA2", CredentialSet: true}}}}, Radios: []dish.RouterRadio{{TXPowerLevel: "TX_POWER_LEVEL_80"}}}
	handler := NewServer(Deps{Token: "secret", Snapshot: snapshotStub{snapshot: dish.Snapshot{Topology: dish.TopologyFull, StarlinkRouter: router}}, History: history.NewStore(1)})
	if got := request(handler, http.MethodGet, "/api/router", ""); got.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated code=%d", got.Code)
	}
	response := request(handler, http.MethodGet, "/api/router", "secret")
	if response.Code != http.StatusOK {
		t.Fatalf("code=%d body=%s", response.Code, response.Body.String())
	}
	var body map[string]any
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	encoded := response.Body.String()
	if body["config_revision"] != "incarnation:42" || !strings.Contains(encoded, "TX_POWER_LEVEL_80") || strings.Contains(encoded, "password") || strings.Contains(encoded, `"id":"opaque`) {
		t.Fatalf("body=%s", encoded)
	}
}
