package api

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	device "github.com/clarkzjw/starlink-grpc-golang/pkg/spacex.com/api/device"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"

	"starwatch/internal/dish"
	liveevent "starwatch/internal/event"
	"starwatch/internal/history"
)

const renameMAC = "aa:bb:cc:dd:ee:ff"

func TestWifiPatchAcceptsSSIDBandSelectorAndNewSSID(t *testing.T) {
	fake := newNetworkRouterFake()
	response := wifiRequest(networkHandler(t, fake), `{"config_revision":"incarnation:7","confirmation":"APPLY WIFI CHANGES","network":{"ssid":"Starlink Cabin","band":"RF_5GHZ","new_ssid":"Starlink Studio"}}`)
	if response.Code != http.StatusAccepted {
		t.Fatalf("code=%d body=%s", response.Code, response.Body.String())
	}
	if len(fake.wifiWrites) != 1 {
		t.Fatalf("writes=%d", len(fake.wifiWrites))
	}
	write := fake.wifiWrites[0].GetWifiConfig()
	if !write.GetApplyNetworks() || write.GetApplyDisable_2Ghz() || len(write.GetNetworks()) != 1 {
		t.Fatalf("write=%+v", write)
	}
	sets := write.GetNetworks()[0].GetBasicServiceSets()
	if sets[0].GetSsid() != "Starlink Guest" || sets[1].GetSsid() != "Starlink Studio" {
		t.Fatalf("sets=%+v", sets)
	}
	if sets[0].GetAuthWpa2().GetPassword() != "existing-sibling-password" || sets[1].GetAuthWpa2().GetPassword() != "existing-target-password" {
		t.Fatalf("passwords were not preserved")
	}
}

func TestWifiNetworkCredentialGuardWithholdsWrite(t *testing.T) {
	fake := newNetworkRouterFake()
	fake.config.Networks[0].BasicServiceSets[0].GetAuthWpa2().Password = ""
	response := wifiRequest(networkHandler(t, fake), `{"config_revision":"incarnation:7","confirmation":"APPLY WIFI CHANGES","network":{"ssid":"Starlink Cabin","band":"RF_5GHZ","hidden":true}}`)
	if response.Code != http.StatusUnprocessableEntity || !strings.Contains(response.Body.String(), "router network credentials unavailable") || len(fake.wifiWrites) != 0 {
		t.Fatalf("code=%d writes=%d body=%s", response.Code, len(fake.wifiWrites), response.Body.String())
	}
}

func TestWifiNetworkPassphraseIsWriteOnlyAndReadbackDoesNotCompareIt(t *testing.T) {
	fake := newNetworkRouterFake()
	fake.redactPasswordOnWrite = true
	audit := &renameAuditSink{}
	bus := liveevent.NewBus()
	live, unsubscribe := bus.Subscribe(1)
	defer unsubscribe()
	secret := "new-network-passphrase"
	response := wifiRequest(networkHandlerWithAudit(t, fake, audit, bus), `{"config_revision":"incarnation:7","confirmation":"APPLY WIFI CHANGES","network":{"ssid":"Starlink Cabin","band":"RF_5GHZ","passphrase":"`+secret+`"}}`)
	if response.Code != http.StatusAccepted || strings.Contains(response.Body.String(), secret) {
		t.Fatalf("code=%d body=%s", response.Code, response.Body.String())
	}
	if got := fake.wifiWrites[0].GetWifiConfig().GetNetworks()[0].GetBasicServiceSets()[1].GetAuthWpa2().GetPassword(); got != secret {
		t.Fatalf("write password=%q", got)
	}
	if len(audit.events) != 1 || strings.Contains(audit.events[0].Detail, secret) {
		t.Fatalf("audit=%+v", audit.events)
	}
	select {
	case message := <-live:
		encoded, _ := json.Marshal(message.Data)
		if strings.Contains(string(encoded), secret) {
			t.Fatalf("live payload exposes passphrase: %s", encoded)
		}
	case <-time.After(time.Second):
		t.Fatal("missing network audit publication")
	}
}

func TestWifiNetworkOpenRequiresStrongerConfirmation(t *testing.T) {
	fake := newNetworkRouterFake()
	response := wifiRequest(networkHandler(t, fake), `{"config_revision":"incarnation:7","confirmation":"APPLY WIFI CHANGES","network":{"ssid":"Starlink Cabin","band":"RF_5GHZ","security":"OPEN"}}`)
	if response.Code != http.StatusBadRequest || len(fake.wifiWrites) != 0 {
		t.Fatalf("code=%d writes=%d body=%s", response.Code, len(fake.wifiWrites), response.Body.String())
	}
	response = wifiRequest(networkHandler(t, fake), `{"config_revision":"incarnation:7","confirmation":"CREATE OPEN NETWORK","network":{"ssid":"Starlink Cabin","band":"RF_5GHZ","security":"OPEN"}}`)
	if response.Code != http.StatusAccepted || fake.config.Networks[0].BasicServiceSets[1].GetAuthOpen() == nil {
		t.Fatalf("code=%d body=%s", response.Code, response.Body.String())
	}
}

func TestWifiNetworkReadbackMismatchIsUnconfirmed(t *testing.T) {
	fake := newNetworkRouterFake()
	fake.confirm = false
	response := wifiRequest(networkHandler(t, fake), `{"config_revision":"incarnation:7","confirmation":"APPLY WIFI CHANGES","network":{"ssid":"Starlink Cabin","band":"RF_5GHZ","hidden":true}}`)
	if response.Code != http.StatusBadGateway || len(fake.wifiWrites) != 1 {
		t.Fatalf("code=%d writes=%d body=%s", response.Code, len(fake.wifiWrites), response.Body.String())
	}
}

func TestWifiPatchRejectsLegacyNetworkIDsAndExcludedFields(t *testing.T) {
	tests := []struct {
		name string
		body string
	}{
		{"legacy network id", `{"config_revision":"incarnation:7","confirmation":"APPLY WIFI CHANGES","network":{"id":"opaque-bss-id","ssid":"Starlink Cabin","band":"RF_5GHZ","new_ssid":"Starlink Studio"}}`},
		{"runtime bssid", `{"config_revision":"incarnation:7","confirmation":"APPLY WIFI CHANGES","network":{"ssid":"Starlink Cabin","band":"RF_5GHZ","bssid":"00:11:22:33:44:55","new_ssid":"Starlink Studio"}}`},
		{"firewall", `{"config_revision":"incarnation:7","confirmation":"APPLY WIFI CHANGES","firewall":{"enabled":false}}`},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			response := wifiRequest(NewServer(Deps{Token: "secret", History: history.NewStore(1)}), test.body)
			if response.Code != http.StatusUnprocessableEntity {
				t.Fatalf("code=%d body=%s", response.Code, response.Body.String())
			}
		})
	}
}

func TestWifiPatchRejectsAllKnownTopLevelExcludedFields(t *testing.T) {
	for _, field := range []string{
		"country_code", "regulatory", "pin", "mesh", "bypass", "ap", "repeater",
		"dhcp", "firewall", "static_routes", "http_server", "dynamic", "client_keys",
		"radius", "setup_complete", "sandbox", "disable_set_wifi_config_from_controller",
		"DisableSetWifiConfigFromController", "factory", "debug",
	} {
		t.Run(field, func(t *testing.T) {
			body := `{"config_revision":"incarnation:7","confirmation":"APPLY WIFI CHANGES","` + field + `":true}`
			response := wifiRequest(NewServer(Deps{Token: "secret", History: history.NewStore(1)}), body)
			if response.Code != http.StatusUnprocessableEntity {
				t.Fatalf("code=%d body=%s", response.Code, response.Body.String())
			}
		})
	}
}

func TestWifiPatchRejectsUnknownNestedNetworkField(t *testing.T) {
	response := wifiRequest(NewServer(Deps{Token: "secret", History: history.NewStore(1)}), `{"config_revision":"incarnation:7","confirmation":"APPLY WIFI CHANGES","network":{"ssid":"Starlink Cabin","band":"RF_5GHZ","new_ssid":"Starlink Studio","unexpected":true}}`)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("code=%d body=%s", response.Code, response.Body.String())
	}
}

func TestWifiPatchRejectsMultipleJSONDocuments(t *testing.T) {
	response := wifiRequest(NewServer(Deps{Token: "secret", History: history.NewStore(1)}), `{"config_revision":"incarnation:7","confirmation":"APPLY WIFI CHANGES","network":{"ssid":"Starlink Cabin","band":"RF_5GHZ","new_ssid":"Starlink Studio"}} {}`)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("code=%d body=%s", response.Code, response.Body.String())
	}
}

func TestWifiPatchRequiresExactConfirmation(t *testing.T) {
	for _, body := range []string{
		`{"config_revision":"incarnation:7","network":{"ssid":"Starlink Cabin","band":"RF_5GHZ","new_ssid":"Starlink Studio"}}`,
		`{"config_revision":"incarnation:7","confirmation":"RENAME WIFI","network":{"ssid":"Starlink Cabin","band":"RF_5GHZ","new_ssid":"Starlink Studio"}}`,
	} {
		response := wifiRequest(NewServer(Deps{Token: "secret", History: history.NewStore(1)}), body)
		if response.Code != http.StatusBadRequest {
			t.Fatalf("code=%d body=%s", response.Code, response.Body.String())
		}
	}
}

func TestWifiPatchRejectsOversizeBody(t *testing.T) {
	body := `{"config_revision":"incarnation:7","confirmation":"APPLY WIFI CHANGES","network":{"ssid":"Starlink Cabin","band":"RF_5GHZ","new_ssid":"` + strings.Repeat("a", 128<<10) + `"}}`
	response := wifiRequest(NewServer(Deps{Token: "secret", History: history.NewStore(1)}), body)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("code=%d body=%s", response.Code, response.Body.String())
	}
}

func TestWifiScalarWritesUseExactlyOneApplyFlag(t *testing.T) {
	tests := []struct{ name, body string }{
		{"band enable", `{"config_revision":"incarnation:7","confirmation":"APPLY WIFI CHANGES","radio":{"band":"RF_2GHZ","enabled":true}}`},
		{"width", `{"config_revision":"incarnation:7","confirmation":"APPLY WIFI CHANGES","radio":{"band":"RF_5GHZ","channel_width_mhz":80}}`},
		{"tx power", `{"config_revision":"incarnation:7","confirmation":"APPLY WIFI CHANGES","radio":{"band":"RF_5GHZ_HIGH","tx_power_level":"TX_POWER_LEVEL_50"}}`},
		{"steering", `{"config_revision":"incarnation:7","confirmation":"APPLY WIFI CHANGES","band_steering_enabled":true}`},
		{"outdoor", `{"config_revision":"incarnation:7","confirmation":"APPLY WIFI CHANGES","outdoor_mode":true}`},
		{"nameservers", `{"config_revision":"incarnation:7","confirmation":"APPLY WIFI CHANGES","dns":{"servers":["1.1.1.1"]}}`},
		{"secure dns", `{"config_revision":"incarnation:7","confirmation":"APPLY WIFI CHANGES","dns":{"secure":true}}`},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fake := newRenameRouterFake()
			response := wifiRequest(renameHandler(t, fake), test.body)
			if response.Code != http.StatusAccepted || len(fake.wifiWrites) != 1 {
				t.Fatalf("code=%d writes=%d body=%s", response.Code, len(fake.wifiWrites), response.Body.String())
			}
			config := fake.wifiWrites[0].GetWifiConfig()
			if config.GetIncarnation() != 7 || countApplyFlags(config) != 1 || config.GetApplyNetworks() || config.GetApplyClientConfigs() {
				t.Fatalf("unsafe config=%+v apply=%d", config, countApplyFlags(config))
			}
		})
	}
}

func TestWifiScalarChannelIsWithheldWithoutWrite(t *testing.T) {
	fake := newRenameRouterFake()
	response := wifiRequest(renameHandler(t, fake), `{"config_revision":"incarnation:7","confirmation":"APPLY WIFI CHANGES","radio":{"band":"RF_5GHZ","channel":149}}`)
	if response.Code != http.StatusUnprocessableEntity || len(fake.wifiWrites) != 0 {
		t.Fatalf("code=%d writes=%d body=%s", response.Code, len(fake.wifiWrites), response.Body.String())
	}
}

func TestWifiScalarReadbackAndUnsupportedFailures(t *testing.T) {
	fake := newRenameRouterFake()
	fake.confirm = false
	response := wifiRequest(renameHandler(t, fake), `{"config_revision":"incarnation:7","confirmation":"APPLY WIFI CHANGES","outdoor_mode":true}`)
	if response.Code != http.StatusBadGateway {
		t.Fatalf("code=%d body=%s", response.Code, response.Body.String())
	}
	fake = newRenameRouterFake()
	fake.wifiWriteErr = status.Error(codes.Unimplemented, "unsupported")
	response = wifiRequest(renameHandler(t, fake), `{"config_revision":"incarnation:7","confirmation":"APPLY WIFI CHANGES","outdoor_mode":true}`)
	if response.Code != http.StatusUnprocessableEntity {
		t.Fatalf("code=%d body=%s", response.Code, response.Body.String())
	}
}

func TestRenameClientAcceptsTargetedReadMergedRename(t *testing.T) {
	fake := newRenameRouterFake()
	audit := &renameAuditSink{}
	bus := liveevent.NewBus()
	live, unsubscribe := bus.Subscribe(1)
	defer unsubscribe()
	handler := renameHandlerWithAudit(t, fake, audit, bus)
	response := renameRequest(handler, renameMAC, `{"config_revision":"incarnation:7","confirmation":"RENAME CLIENT","given_name":"Work Mac"}`)
	if response.Code != http.StatusAccepted {
		t.Fatalf("code=%d body=%s", response.Code, response.Body.String())
	}
	if len(fake.writes) != 1 {
		t.Fatalf("writes=%d", len(fake.writes))
	}
	write := fake.writes[0]
	if write.GetClientName() != nil || write.GetClientConfig().GetGivenName() != "Work Mac" {
		t.Fatalf("targeted request=%+v", write)
	}
	if write.GetClientConfig().GetClientId() != 42 || write.GetClientConfig().GetGroupId() != "family" || len(write.GetClientConfig().GetWeeklyBlockSchedules()) != 1 {
		t.Fatalf("read-merge lost client config: %+v", write.GetClientConfig())
	}
	var body map[string]bool
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil || !body["accepted"] {
		t.Fatalf("body=%s err=%v", response.Body.String(), err)
	}
	if len(audit.events) != 1 || audit.events[0].Kind != "router_control" {
		t.Fatalf("audit events=%+v", audit.events)
	}
	var detail map[string]any
	if err := json.Unmarshal([]byte(audit.events[0].Detail), &detail); err != nil {
		t.Fatalf("audit detail: %v", err)
	}
	if detail["action"] != "rename_client" || detail["mac"] != renameMAC || detail["given_name"] != "Work Mac" || detail["result"] != "accepted" || detail["client_id"] != float64(42) {
		t.Fatalf("audit detail=%v", detail)
	}
	for _, value := range []string{"super-secret-passphrase", "weekly_block_schedules", "family"} {
		if strings.Contains(response.Body.String(), value) || strings.Contains(audit.events[0].Detail, value) {
			t.Fatalf("secret or surrounding config leaked %q: response=%s audit=%s", value, response.Body.String(), audit.events[0].Detail)
		}
	}
	select {
	case message := <-live:
		if message.Kind != "router_control" {
			t.Fatalf("live message=%+v", message)
		}
		published, err := json.Marshal(message.Data)
		if err != nil || strings.Contains(string(published), "super-secret-passphrase") {
			t.Fatalf("live detail leaked surrounding config: %s err=%v", published, err)
		}
		var liveDetail map[string]any
		if err := json.Unmarshal(published, &liveDetail); err != nil {
			t.Fatalf("decode live detail: %v", err)
		}
		if len(liveDetail) != 5 || liveDetail["action"] != "rename_client" || liveDetail["mac"] != renameMAC || liveDetail["given_name"] != "Work Mac" || liveDetail["result"] != "accepted" || liveDetail["client_id"] != float64(42) {
			t.Fatalf("live detail=%v", liveDetail)
		}
		select {
		case extra := <-live:
			t.Fatalf("unexpected second live event: %+v", extra)
		default:
		}
	case <-time.After(time.Second):
		t.Fatal("missing live router-control event")
	}
}

func TestRenameClientAuditsOnlyAfterReadbackConfirmation(t *testing.T) {
	fake := newRenameRouterFake()
	fake.confirm = false
	audit := &renameAuditSink{}
	bus := liveevent.NewBus()
	live, unsubscribe := bus.Subscribe(1)
	defer unsubscribe()
	response := renameRequest(renameHandlerWithAudit(t, fake, audit, bus), renameMAC, `{"config_revision":"incarnation:7","confirmation":"RENAME CLIENT","given_name":"Work Mac"}`)
	if response.Code != http.StatusBadGateway {
		t.Fatalf("code=%d body=%s", response.Code, response.Body.String())
	}
	if len(audit.events) != 0 {
		t.Fatalf("unconfirmed rename was audited: %+v", audit.events)
	}
	select {
	case message := <-live:
		t.Fatalf("unconfirmed rename was published: %+v", message)
	default:
	}
}

func TestRenameClientFallbackConfigUsesLiveClientIDForConfirmedAudit(t *testing.T) {
	fake := newRenameRouterFake()
	fake.config.ClientConfigs = nil
	fake.clients[0].ClientId = 99
	fake.createConfigOnWrite = true
	audit := &renameAuditSink{}
	response := renameRequest(renameHandlerWithAudit(t, fake, audit, liveevent.NewBus()), renameMAC, `{"config_revision":"incarnation:7","confirmation":"RENAME CLIENT","given_name":"Work Mac"}`)
	if response.Code != http.StatusAccepted {
		t.Fatalf("code=%d body=%s", response.Code, response.Body.String())
	}
	if len(fake.writes) != 1 {
		t.Fatalf("writes=%d", len(fake.writes))
	}
	config := fake.writes[0].GetClientConfig()
	if config.GetMacAddress() != renameMAC || config.GetGivenName() != "Work Mac" || config.GetClientId() != 0 || config.GetGroupId() != "" || len(config.GetWeeklyBlockSchedules()) != 0 {
		t.Fatalf("fallback request was not minimal: %+v", config)
	}
	if len(audit.events) != 1 {
		t.Fatalf("audit events=%+v", audit.events)
	}
	if strings.Contains(audit.events[0].Detail, "super-secret-passphrase") {
		t.Fatalf("audit leaked password: %s", audit.events[0].Detail)
	}
	var detail map[string]any
	if err := json.Unmarshal([]byte(audit.events[0].Detail), &detail); err != nil || detail["client_id"] != float64(99) {
		t.Fatalf("audit detail=%s err=%v", audit.events[0].Detail, err)
	}
}

func TestRenameClientRejectsInvalidRequestsWithoutWrite(t *testing.T) {
	tests := []struct {
		name string
		path string
		body string
		code int
	}{
		{"missing confirmation", renameMAC, `{"config_revision":"incarnation:7","given_name":"Work Mac"}`, http.StatusBadRequest},
		{"wrong confirmation", renameMAC, `{"config_revision":"incarnation:7","confirmation":"BLOCK CLIENT","given_name":"Work Mac"}`, http.StatusBadRequest},
		{"empty name", renameMAC, `{"config_revision":"incarnation:7","confirmation":"RENAME CLIENT","given_name":""}`, http.StatusBadRequest},
		{"unknown field", renameMAC, `{"config_revision":"incarnation:7","confirmation":"RENAME CLIENT","given_name":"Work Mac","else":true}`, http.StatusBadRequest},
		{"rename and block together", renameMAC, `{"config_revision":"incarnation:7","confirmation":"RENAME CLIENT","given_name":"Work Mac","blocked":true}`, http.StatusBadRequest},
		{"wifi deferred", renameMAC, `{"config_revision":"incarnation:7","confirmation":"RENAME CLIENT","given_name":"Work Mac","ssid":"nope"}`, http.StatusUnprocessableEntity},
		{"radio deferred", renameMAC, `{"config_revision":"incarnation:7","confirmation":"RENAME CLIENT","given_name":"Work Mac","disabled":true}`, http.StatusUnprocessableEntity},
		{"unknown mac", "aa:bb:cc:dd:ee:00", `{"config_revision":"incarnation:7","confirmation":"RENAME CLIENT","given_name":"Work Mac"}`, http.StatusNotFound},
		{"stale revision", renameMAC, `{"config_revision":"incarnation:6","confirmation":"RENAME CLIENT","given_name":"Work Mac"}`, http.StatusConflict},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fake := newRenameRouterFake()
			response := renameRequest(renameHandler(t, fake), test.path, test.body)
			if response.Code != test.code {
				t.Fatalf("code=%d body=%s", response.Code, response.Body.String())
			}
			if len(fake.writes) != 0 {
				t.Fatalf("unexpected writes=%d", len(fake.writes))
			}
		})
	}
}

func TestBlockClientAddsOwnedAllWeekScheduleAndConfirms(t *testing.T) {
	fake := newRenameRouterFake()
	audit := &renameAuditSink{}
	bus := liveevent.NewBus()
	live, unsubscribe := bus.Subscribe(1)
	defer unsubscribe()
	fake.config.ClientConfigs[0].WeeklyBlockSchedules = []*device.WeeklyBlockSchedule{{GroupId: "family-rules", BlockRanges: []*device.WeeklyBlockSchedule_BlockRange{{StartMinutes: 120, EndMinutes: 180}}}}
	handler := renameHandlerWithAudit(t, fake, audit, bus)
	response := renameRequest(handler, renameMAC, `{"config_revision":"incarnation:7","confirmation":"BLOCK CLIENT","blocked":true}`)
	if response.Code != http.StatusAccepted {
		t.Fatalf("code=%d body=%s", response.Code, response.Body.String())
	}
	if len(fake.writes) != 1 {
		t.Fatalf("writes=%d", len(fake.writes))
	}
	config := fake.writes[0].GetClientConfig()
	if config.GetGivenName() != "Old Mac" || len(config.GetWeeklyBlockSchedules()) != 2 {
		t.Fatalf("write lost client config: %+v", config)
	}
	var owned *device.WeeklyBlockSchedule
	for _, schedule := range config.GetWeeklyBlockSchedules() {
		if schedule.GetGroupId() == "starwatch-block" {
			owned = schedule
		}
	}
	if owned == nil || len(owned.GetBlockRanges()) != 1 || owned.GetBlockRanges()[0].GetStartMinutes() != 0 || owned.GetBlockRanges()[0].GetEndMinutes() != 10080 {
		t.Fatalf("owned schedule=%+v", owned)
	}
	if !fake.clients[0].GetBlocked() {
		t.Fatal("live readback did not set Blocked")
	}
	if len(audit.events) != 1 || strings.Contains(audit.events[0].Detail, "super-secret-passphrase") || !strings.Contains(audit.events[0].Detail, `"action":"block_client"`) {
		t.Fatalf("audit=%+v", audit.events)
	}
	assertJSONKeys(t, audit.events[0].Detail, "action", "mac", "result", "client_id")
	select {
	case message := <-live:
		published, _ := json.Marshal(message.Data)
		if message.Kind != "router_control" || strings.Contains(string(published), "super-secret-passphrase") || !strings.Contains(string(published), `"action":"block_client"`) {
			t.Fatalf("live=%s", published)
		}
		assertJSONKeys(t, string(published), "action", "mac", "result", "client_id")
	case <-time.After(time.Second):
		t.Fatal("missing block audit publication")
	}
}

func TestUnblockClientRemovesOnlyOwnedScheduleAndConfirms(t *testing.T) {
	fake := newRenameRouterFake()
	audit := &renameAuditSink{}
	bus := liveevent.NewBus()
	live, unsubscribe := bus.Subscribe(1)
	defer unsubscribe()
	fake.config.ClientConfigs[0].WeeklyBlockSchedules = []*device.WeeklyBlockSchedule{
		{GroupId: "starwatch-block", BlockRanges: []*device.WeeklyBlockSchedule_BlockRange{{StartMinutes: 0, EndMinutes: 10080}}},
		{GroupId: "family-rules", BlockRanges: []*device.WeeklyBlockSchedule_BlockRange{{StartMinutes: 120, EndMinutes: 180}}},
	}
	// The user schedule is not currently active, so the live signal is false.
	fake.clients[0].Blocked = false
	response := renameRequest(renameHandlerWithAudit(t, fake, audit, bus), renameMAC, `{"config_revision":"incarnation:7","confirmation":"UNBLOCK CLIENT","blocked":false}`)
	if response.Code != http.StatusAccepted {
		t.Fatalf("code=%d body=%s", response.Code, response.Body.String())
	}
	if len(fake.writes) != 1 || len(fake.writes[0].GetClientConfig().GetWeeklyBlockSchedules()) != 1 || fake.writes[0].GetClientConfig().GetWeeklyBlockSchedules()[0].GetGroupId() != "family-rules" {
		t.Fatalf("write=%+v", fake.writes)
	}
	if fake.clients[0].GetBlocked() {
		t.Fatal("live readback still blocked")
	}
	if len(audit.events) != 1 {
		t.Fatalf("audit=%+v", audit.events)
	}
	assertJSONKeys(t, audit.events[0].Detail, "action", "mac", "result", "client_id")
	select {
	case message := <-live:
		published, _ := json.Marshal(message.Data)
		assertJSONKeys(t, string(published), "action", "mac", "result", "client_id")
	case <-time.After(time.Second):
		t.Fatal("missing unblock audit publication")
	}
}

func TestUnblockClientMissingConfigReadbackIsUnconfirmedWithoutAudit(t *testing.T) {
	fake := newRenameRouterFake()
	fake.config.ClientConfigs[0].WeeklyBlockSchedules = []*device.WeeklyBlockSchedule{{GroupId: "starwatch-block", BlockRanges: []*device.WeeklyBlockSchedule_BlockRange{{StartMinutes: 0, EndMinutes: 10080}}}}
	fake.clients[0].Blocked = true
	fake.dropConfigOnWrite = true
	audit := &renameAuditSink{}
	response := renameRequest(renameHandlerWithAudit(t, fake, audit, liveevent.NewBus()), renameMAC, `{"config_revision":"incarnation:7","confirmation":"UNBLOCK CLIENT","blocked":false}`)
	if response.Code != http.StatusBadGateway || len(audit.events) != 0 {
		t.Fatalf("code=%d audit=%+v body=%s", response.Code, audit.events, response.Body.String())
	}
}

func TestUnblockClientRefusesUserManagedScheduleWithoutWrite(t *testing.T) {
	fake := newRenameRouterFake()
	fake.config.ClientConfigs[0].WeeklyBlockSchedules = []*device.WeeklyBlockSchedule{
		{GroupId: "starwatch-block", BlockRanges: []*device.WeeklyBlockSchedule_BlockRange{{StartMinutes: 0, EndMinutes: 10080}}},
		{GroupId: "family-rules", BlockRanges: []*device.WeeklyBlockSchedule_BlockRange{{StartMinutes: 0, EndMinutes: 10080}}},
	}
	fake.clients[0].Blocked = true
	response := renameRequest(renameHandler(t, fake), renameMAC, `{"config_revision":"incarnation:7","confirmation":"UNBLOCK CLIENT","blocked":false}`)
	if response.Code != http.StatusConflict || len(fake.writes) != 0 {
		t.Fatalf("code=%d writes=%d body=%s", response.Code, len(fake.writes), response.Body.String())
	}
}

func TestBlockClientValidationAndFailures(t *testing.T) {
	tests := []struct {
		name, body string
		err        error
		confirm    bool
		code       int
	}{
		{"missing confirmation", `{"config_revision":"incarnation:7","blocked":true}`, nil, true, http.StatusBadRequest},
		{"missing revision", `{"confirmation":"BLOCK CLIENT","blocked":true}`, nil, true, http.StatusBadRequest},
		{"wrong confirmation", `{"config_revision":"incarnation:7","confirmation":"UNBLOCK CLIENT","blocked":true}`, nil, true, http.StatusBadRequest},
		{"unsupported", `{"config_revision":"incarnation:7","confirmation":"BLOCK CLIENT","blocked":true}`, status.Error(codes.Unimplemented, "no"), true, http.StatusUnprocessableEntity},
		{"unavailable", `{"config_revision":"incarnation:7","confirmation":"BLOCK CLIENT","blocked":true}`, status.Error(codes.Unavailable, "no"), true, http.StatusUnprocessableEntity},
		{"unconfirmed", `{"config_revision":"incarnation:7","confirmation":"BLOCK CLIENT","blocked":true}`, nil, false, http.StatusBadGateway},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fake := newRenameRouterFake()
			fake.writeErr, fake.confirm = test.err, test.confirm
			response := renameRequest(renameHandler(t, fake), renameMAC, test.body)
			if response.Code != test.code {
				t.Fatalf("code=%d body=%s", response.Code, response.Body.String())
			}
			if test.code == http.StatusBadRequest && len(fake.writes) != 0 {
				t.Fatalf("unexpected writes=%d", len(fake.writes))
			}
		})
	}
}

func TestBlockClientRejectsStaleRevisionWithoutWrite(t *testing.T) {
	fake := newRenameRouterFake()
	fake.config.Incarnation = 8
	response := renameRequest(renameHandler(t, fake), renameMAC, `{"config_revision":"incarnation:7","confirmation":"BLOCK CLIENT","blocked":true}`)
	if response.Code != http.StatusConflict || len(fake.writes) != 0 {
		t.Fatalf("code=%d writes=%d body=%s", response.Code, len(fake.writes), response.Body.String())
	}
}

func TestRenameClientMapsRouterFailuresAndReadbackMismatch(t *testing.T) {
	tests := []struct {
		name    string
		err     error
		confirm bool
		code    int
	}{
		{"unsupported", status.Error(codes.Unimplemented, "not implemented"), true, http.StatusUnprocessableEntity},
		{"unavailable", status.Error(codes.Unavailable, "unavailable"), true, http.StatusUnprocessableEntity},
		{"upstream failure", errors.New("router failed: super-secret-passphrase"), true, http.StatusBadGateway},
		{"readback mismatch", nil, false, http.StatusBadGateway},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fake := newRenameRouterFake()
			fake.writeErr, fake.confirm = test.err, test.confirm
			response := renameRequest(renameHandler(t, fake), renameMAC, `{"config_revision":"incarnation:7","confirmation":"RENAME CLIENT","given_name":"Work Mac"}`)
			if response.Code != test.code {
				t.Fatalf("code=%d body=%s", response.Code, response.Body.String())
			}
			if strings.Contains(response.Body.String(), "super-secret-passphrase") {
				t.Fatalf("upstream error leaked: %s", response.Body.String())
			}
		})
	}
}

func TestRenameClientNormalizesHyphenatedMixedCaseMAC(t *testing.T) {
	fake := newRenameRouterFake()
	response := renameRequest(renameHandler(t, fake), "AA-Bb-cC-Dd-eE-Ff", `{"config_revision":"incarnation:7","confirmation":"RENAME CLIENT","given_name":"Work Mac"}`)
	if response.Code != http.StatusAccepted || len(fake.writes) != 1 || fake.writes[0].GetClientConfig().GetMacAddress() != renameMAC {
		t.Fatalf("code=%d writes=%+v", response.Code, fake.writes)
	}
}

func TestRenameClientRequiresReachableTopologyB(t *testing.T) {
	for _, snapshot := range []dish.Snapshot{
		{Topology: dish.TopologyWANOnly},
		{Topology: dish.TopologyFull},
		{Topology: dish.TopologyFull, StarlinkRouter: &dish.StarlinkRouter{Reachable: false}},
	} {
		fake := newRenameRouterFake()
		response := renameRequest(renameHandlerWithSnapshot(t, fake, snapshot), renameMAC, `{"config_revision":"incarnation:7","confirmation":"RENAME CLIENT","given_name":"Work Mac"}`)
		if response.Code != http.StatusServiceUnavailable || len(fake.writes) != 0 {
			t.Fatalf("snapshot=%+v code=%d writes=%d", snapshot, response.Code, len(fake.writes))
		}
	}
}

func TestRenameClientRereadDetectsRevisionChangeWithoutWrite(t *testing.T) {
	fake := newRenameRouterFake()
	fake.config.Incarnation = 8
	response := renameRequest(renameHandler(t, fake), renameMAC, `{"config_revision":"incarnation:7","confirmation":"RENAME CLIENT","given_name":"Work Mac"}`)
	if response.Code != http.StatusConflict || len(fake.writes) != 0 {
		t.Fatalf("code=%d writes=%d body=%s", response.Code, len(fake.writes), response.Body.String())
	}
}

func renameHandler(t *testing.T, fake *renameRouterFake) http.Handler {
	t.Helper()
	return renameHandlerWithSnapshot(t, fake, dish.Snapshot{Topology: dish.TopologyFull, StarlinkRouter: &dish.StarlinkRouter{
		Reachable: true, ConfigRevision: "incarnation:7", Clients: []dish.RouterClient{{MAC: renameMAC, GivenName: "Old Mac"}},
	}})
}

func renameHandlerWithAudit(t *testing.T, fake *renameRouterFake, audit *renameAuditSink, bus *liveevent.Bus) http.Handler {
	t.Helper()
	address := startRenameRouter(t, fake)
	controller := dish.NewRouterMutationController(dish.RouterMutationOptions{
		ResolveGateway: func(context.Context) (string, error) { return address, nil },
		Dial:           dish.DialRouterMutation,
	})
	return NewServer(Deps{
		Token: "secret", Snapshot: snapshotStub{snapshot: dish.Snapshot{Topology: dish.TopologyFull, StarlinkRouter: &dish.StarlinkRouter{
			Reachable: true, ConfigRevision: "incarnation:7", Clients: []dish.RouterClient{{MAC: renameMAC, GivenName: "Old Mac"}},
		}}}, History: history.NewStore(1), RouterMutations: controller, AuditEvents: audit, AuditLive: bus,
	})
}

func renameHandlerWithSnapshot(t *testing.T, fake *renameRouterFake, snapshot dish.Snapshot) http.Handler {
	t.Helper()
	address := startRenameRouter(t, fake)
	controller := dish.NewRouterMutationController(dish.RouterMutationOptions{
		ResolveGateway: func(context.Context) (string, error) { return address, nil },
		Dial:           dish.DialRouterMutation,
	})
	return NewServer(Deps{Token: "secret", Snapshot: snapshotStub{snapshot: snapshot}, History: history.NewStore(1), RouterMutations: controller})
}

func networkHandler(t *testing.T, fake *renameRouterFake) http.Handler {
	t.Helper()
	return networkHandlerWithAudit(t, fake, nil, nil)
}

func networkHandlerWithAudit(t *testing.T, fake *renameRouterFake, audit *renameAuditSink, bus *liveevent.Bus) http.Handler {
	t.Helper()
	address := startRenameRouter(t, fake)
	controller := dish.NewRouterMutationController(dish.RouterMutationOptions{
		ResolveGateway: func(context.Context) (string, error) { return address, nil },
		Dial:           dish.DialRouterMutation,
	})
	deps := Deps{Token: "secret", Snapshot: snapshotStub{snapshot: dish.Snapshot{Topology: dish.TopologyFull, StarlinkRouter: &dish.StarlinkRouter{Reachable: true, ConfigRevision: "incarnation:7"}}}, History: history.NewStore(1), RouterMutations: controller}
	if audit != nil {
		deps.AuditEvents = audit
	}
	if bus != nil {
		deps.AuditLive = bus
	}
	return NewServer(deps)
}

func renameRequest(handler http.Handler, mac, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPatch, "/api/router/clients/"+mac, strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer secret")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, req)
	return response
}

func wifiRequest(handler http.Handler, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPatch, "/api/router/wifi", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer secret")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, req)
	return response
}

type renameRouterFake struct {
	device.UnimplementedDeviceServer
	mu                    sync.Mutex
	config                *device.WifiConfig
	clients               []*device.WifiClient
	writes                []*device.WifiSetClientGivenNameRequest
	wifiWrites            []*device.WifiSetConfigRequest
	writeErr              error
	wifiWriteErr          error
	confirm               bool
	redactPasswordOnWrite bool
	createConfigOnWrite   bool
	dropConfigOnWrite     bool
}

func newRenameRouterFake() *renameRouterFake {
	return &renameRouterFake{
		config: &device.WifiConfig{
			Incarnation:   7,
			ClientConfigs: []*device.ClientConfig{{ClientId: 42, MacAddress: renameMAC, GivenName: "Old Mac", GroupId: "family", WeeklyBlockSchedules: []*device.WeeklyBlockSchedule{{}}}},
			Networks: []*device.WifiConfig_Network{{BasicServiceSets: []*device.WifiConfig_BasicServiceSet{{
				Auth: &device.WifiConfig_BasicServiceSet_AuthWpa2{AuthWpa2: &device.AuthWpa2{Password: "super-secret-passphrase"}},
			}}}},
		},
		clients: []*device.WifiClient{{MacAddress: renameMAC, GivenName: "Old Mac", ClientId: 42}},
		confirm: true,
	}
}

func newNetworkRouterFake() *renameRouterFake {
	fake := newRenameRouterFake()
	fake.config.Networks = []*device.WifiConfig_Network{{BasicServiceSets: []*device.WifiConfig_BasicServiceSet{
		{Ssid: "Starlink Guest", Band: device.WifiConfig_RF_2GHZ, Auth: &device.WifiConfig_BasicServiceSet_AuthWpa2{AuthWpa2: &device.AuthWpa2{Password: "existing-sibling-password"}}},
		{Ssid: "Starlink Cabin", Band: device.WifiConfig_RF_5GHZ, Auth: &device.WifiConfig_BasicServiceSet_AuthWpa2{AuthWpa2: &device.AuthWpa2{Password: "existing-target-password"}}},
	}}}
	return fake
}

type renameAuditSink struct{ events []history.Event }

func (s *renameAuditSink) AddEvent(item history.Event) { s.events = append(s.events, item) }

func (f *renameRouterFake) Handle(_ context.Context, request *device.Request) (*device.Response, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	switch typed := request.GetRequest().(type) {
	case *device.Request_WifiGetConfig:
		return &device.Response{Response: &device.Response_WifiGetConfig{WifiGetConfig: &device.WifiGetConfigResponse{WifiConfig: proto.Clone(f.config).(*device.WifiConfig)}}}, nil
	case *device.Request_WifiGetClients:
		return &device.Response{Response: &device.Response_WifiGetClients{WifiGetClients: &device.WifiGetClientsResponse{Clients: proto.Clone(&device.WifiGetClientsResponse{Clients: f.clients}).(*device.WifiGetClientsResponse).Clients}}}, nil
	case *device.Request_WifiSetClientGivenName:
		f.writes = append(f.writes, proto.Clone(typed.WifiSetClientGivenName).(*device.WifiSetClientGivenNameRequest))
		if f.writeErr != nil {
			return nil, f.writeErr
		}
		if f.confirm {
			requestConfig := typed.WifiSetClientGivenName.GetClientConfig()
			if f.createConfigOnWrite {
				f.config.ClientConfigs = append(f.config.ClientConfigs, proto.Clone(requestConfig).(*device.ClientConfig))
			}
			for _, config := range f.config.ClientConfigs {
				if config.GetMacAddress() == requestConfig.GetMacAddress() {
					config.GivenName = requestConfig.GetGivenName()
					config.WeeklyBlockSchedules = proto.Clone(requestConfig).(*device.ClientConfig).GetWeeklyBlockSchedules()
				}
			}
			for _, client := range f.clients {
				if client.GetMacAddress() == requestConfig.GetMacAddress() {
					client.GivenName = requestConfig.GetGivenName()
					client.Blocked = hasStarwatchBlock(requestConfig.GetWeeklyBlockSchedules())
				}
			}
			if f.dropConfigOnWrite {
				f.config.ClientConfigs = nil
			}
		}
		return &device.Response{}, nil
	case *device.Request_WifiSetConfig:
		f.wifiWrites = append(f.wifiWrites, proto.Clone(typed.WifiSetConfig).(*device.WifiSetConfigRequest))
		if f.wifiWriteErr != nil {
			return nil, f.wifiWriteErr
		}
		if f.confirm {
			applyFakeWifiConfig(f.config, typed.WifiSetConfig.GetWifiConfig())
			if f.redactPasswordOnWrite {
				for _, network := range f.config.GetNetworks() {
					for _, bss := range network.GetBasicServiceSets() {
						if auth := bss.GetAuthWpa2(); auth != nil {
							auth.Password = ""
						}
					}
				}
			}
		}
		return &device.Response{Response: &device.Response_WifiSetConfig{WifiSetConfig: &device.WifiSetConfigResponse{UpdatedWifiConfig: proto.Clone(f.config).(*device.WifiConfig)}}}, nil
	default:
		return nil, status.Errorf(codes.Unimplemented, "unexpected request %T", request.GetRequest())
	}
}

func applyFakeWifiConfig(target, write *device.WifiConfig) {
	if write.GetApplyDisable_2Ghz() {
		target.Disable_2Ghz = write.GetDisable_2Ghz()
	}
	if write.GetApplyDisable_5Ghz() {
		target.Disable_5Ghz = write.GetDisable_5Ghz()
	}
	if write.GetApplyDisable_5GhzHigh() {
		target.Disable_5GhzHigh = write.GetDisable_5GhzHigh()
	}
	if write.GetApplyHtBandwidth_2Ghz() {
		target.HtBandwidth_2Ghz = write.GetHtBandwidth_2Ghz()
	}
	if write.GetApplyHtBandwidth_5Ghz() {
		target.HtBandwidth_5Ghz = write.GetHtBandwidth_5Ghz()
	}
	if write.GetApplyHtBandwidth_5GhzHigh() {
		target.HtBandwidth_5GhzHigh = write.GetHtBandwidth_5GhzHigh()
	}
	if write.GetApplyVhtBandwidth() {
		target.VhtBandwidth = write.GetVhtBandwidth()
	}
	if write.GetApplyVhtBandwidth_5GhzHigh() {
		target.VhtBandwidth_5GhzHigh = write.GetVhtBandwidth_5GhzHigh()
	}
	if write.GetApplyTxPowerLevel_2Ghz() {
		target.TxPowerLevel_2Ghz = write.GetTxPowerLevel_2Ghz()
	}
	if write.GetApplyTxPowerLevel_5Ghz() {
		target.TxPowerLevel_5Ghz = write.GetTxPowerLevel_5Ghz()
	}
	if write.GetApplyTxPowerLevel_5GhzHigh() {
		target.TxPowerLevel_5GhzHigh = write.GetTxPowerLevel_5GhzHigh()
	}
	if write.GetApplyDisableBandSteering() {
		target.DisableBandSteering = write.GetDisableBandSteering()
	}
	if write.GetApplyOutdoorMode() {
		target.OutdoorMode = write.GetOutdoorMode()
	}
	if write.GetApplyNameservers() {
		target.Nameservers = append([]string(nil), write.GetNameservers()...)
	}
	if write.GetApplySecureDns() {
		target.SecureDns = write.GetSecureDns()
	}
	if write.GetApplyNetworks() {
		target.Networks = proto.Clone(&device.WifiConfig{Networks: write.GetNetworks()}).(*device.WifiConfig).GetNetworks()
	}
}

func countApplyFlags(config *device.WifiConfig) int {
	count := 0
	fields := config.ProtoReflect().Descriptor().Fields()
	for i := 0; i < fields.Len(); i++ {
		field := fields.Get(i)
		if strings.HasPrefix(string(field.Name()), "apply_") && config.ProtoReflect().Get(field).Bool() {
			count++
		}
	}
	return count
}

func assertJSONKeys(t *testing.T, encoded string, want ...string) {
	t.Helper()
	var value map[string]json.RawMessage
	if err := json.Unmarshal([]byte(encoded), &value); err != nil {
		t.Fatalf("decode JSON %q: %v", encoded, err)
	}
	if len(value) != len(want) {
		t.Fatalf("keys=%v want=%v", value, want)
	}
	for _, key := range want {
		if _, ok := value[key]; !ok {
			t.Fatalf("keys=%v missing %q", value, key)
		}
	}
}

func hasStarwatchBlock(schedules []*device.WeeklyBlockSchedule) bool {
	for _, schedule := range schedules {
		if schedule.GetGroupId() == "starwatch-block" {
			return true
		}
	}
	return false
}

func startRenameRouter(t *testing.T, fake *renameRouterFake) string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	grpcServer := grpc.NewServer()
	device.RegisterDeviceServer(grpcServer, fake)
	go func() { _ = grpcServer.Serve(listener) }()
	t.Cleanup(func() { grpcServer.Stop(); _ = listener.Close() })
	return listener.Addr().String()
}
