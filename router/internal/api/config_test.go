package api

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"starwatch/internal/config"
	"starwatch/internal/history"
)

func TestConfigAPIUpdatesSafeFieldsRejectsRestartManagedAndRotatesToken(t *testing.T) {
	path := filepath.Join(t.TempDir(), "starwatch")
	source := "# preserved\nconfig starwatch 'main'\n\toption token 'old-secret'\n\toption probe_interval '2'\n\toption unknown 'keep'\nconfig history\n\toption minute_days '7'\n\toption quarter_days '30'\nconfig alerts\n"
	if err := os.WriteFile(path, []byte(source), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := config.Load(path)
	if err != nil {
		t.Fatal(err)
	}
	manager, err := config.NewManager(path, cfg, config.ManagerOptions{})
	if err != nil {
		t.Fatal(err)
	}
	handler := NewServer(Deps{TokenProvider: manager.Token, Settings: manager, Snapshot: snapshotStub{}, History: history.NewStore(1)})

	get := request(handler, http.MethodGet, "/api/config", "old-secret")
	if get.Code != http.StatusOK || strings.Contains(get.Body.String(), "old-secret") || !strings.Contains(get.Body.String(), "****cret") {
		t.Fatalf("GET code=%d body=%s", get.Code, get.Body.String())
	}
	put := requestBody(handler, http.MethodPut, "/api/config", "old-secret", `{"main":{"probe_interval":5,"probe_hosts":["9.9.9.9"],"location_enabled":true},"history":{"minute_days":8},"alerts":{"webhook_url":"https://example.test","rules":{"failover_event":{"enabled":false},"path_degraded":{"threshold":0.25,"threshold2":350}}}}`)
	if put.Code != http.StatusOK {
		t.Fatalf("PUT code=%d body=%s", put.Code, put.Body.String())
	}
	updated := manager.Snapshot()
	if updated.ProbeInterval.Seconds() != 5 || !updated.LocationEnabled || updated.History.MinuteDays != 8 || updated.Alerts.Rules["failover_event"].Enabled || updated.Alerts.Rules["path_degraded"].Threshold != .25 || updated.Alerts.Rules["path_degraded"].Threshold2 != 350 {
		t.Fatalf("updated=%+v", updated)
	}
	raw, _ := os.ReadFile(path)
	if !strings.Contains(string(raw), "# preserved") || !strings.Contains(string(raw), "option unknown 'keep'") {
		t.Fatalf("rewritten UCI:\n%s", raw)
	}

	for _, body := range []string{`{"main":{"listen":"127.0.0.1"}}`, `{"main":{"port":1234}}`, `{"main":{"token":"new"}}`, `{"main":{"dish_addr":"host:1"}}`, `{"history":{"db_path":"/tmp/x"}}`} {
		response := requestBody(handler, http.MethodPut, "/api/config", "old-secret", body)
		if response.Code != http.StatusBadRequest || !strings.Contains(response.Body.String(), "restart-managed field") {
			t.Fatalf("body=%s code=%d response=%s", body, response.Code, response.Body.String())
		}
	}
	rotated := request(handler, http.MethodPost, "/api/config/regenerate-token", "old-secret")
	if rotated.Code != http.StatusOK {
		t.Fatalf("rotate code=%d body=%s", rotated.Code, rotated.Body.String())
	}
	var tokenResponse struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(rotated.Body.Bytes(), &tokenResponse); err != nil || tokenResponse.Token == "" || tokenResponse.Token == "old-secret" {
		t.Fatalf("token=%q err=%v", tokenResponse.Token, err)
	}
	if response := request(handler, http.MethodGet, "/api/config", "old-secret"); response.Code != http.StatusUnauthorized {
		t.Fatalf("old token code=%d", response.Code)
	}
	if response := request(handler, http.MethodGet, "/api/config", tokenResponse.Token); response.Code != http.StatusOK {
		t.Fatalf("new token code=%d", response.Code)
	}
}

func TestConfigAPIBatteryPartialUpdateBoundsAndServerTimestamp(t *testing.T) {
	now := time.Date(2026, 7, 16, 20, 0, 0, 0, time.UTC)
	path := filepath.Join(t.TempDir(), "starwatch")
	source := "config starwatch 'main'\n\toption token 'secret'\nconfig battery\n\toption future 'keep'\nconfig vendor 'unknown'\n\toption opaque 'yes'\n"
	if err := os.WriteFile(path, []byte(source), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := config.Load(path)
	if err != nil {
		t.Fatal(err)
	}
	manager, err := config.NewManager(path, cfg, config.ManagerOptions{Now: func() time.Time { return now }})
	if err != nil {
		t.Fatal(err)
	}
	handler := NewServer(Deps{TokenProvider: manager.Token, Settings: manager, Snapshot: snapshotStub{}, History: history.NewStore(1)})

	get := request(handler, http.MethodGet, "/api/config", "secret")
	if get.Code != http.StatusOK || !strings.Contains(get.Body.String(), `"battery"`) || !strings.Contains(get.Body.String(), `"enabled":false`) {
		t.Fatalf("GET code=%d body=%s", get.Code, get.Body.String())
	}
	for _, body := range []string{
		`{"battery":{"capacity_wh":0}}`, `{"battery":{"capacity_wh":100001}}`,
		`{"battery":{"state_of_charge_percent":-1}}`, `{"battery":{"state_of_charge_percent":101}}`,
		`{"battery":{"reserve_percent":-1}}`, `{"battery":{"reserve_percent":96}}`,
		`{"battery":{"conversion_efficiency_percent":0}}`, `{"battery":{"conversion_efficiency_percent":101}}`,
		`{"battery":{"state_of_charge_updated_at":"2000-01-01T00:00:00Z"}}`,
	} {
		response := requestBody(handler, http.MethodPut, "/api/config", "secret", body)
		if response.Code != http.StatusBadRequest {
			t.Fatalf("body=%s code=%d response=%s", body, response.Code, response.Body.String())
		}
	}
	valid := requestBody(handler, http.MethodPut, "/api/config", "secret", `{"battery":{"enabled":true,"capacity_wh":1024,"state_of_charge_percent":76,"reserve_percent":10,"conversion_efficiency_percent":90}}`)
	if valid.Code != http.StatusOK {
		t.Fatalf("PUT code=%d body=%s", valid.Code, valid.Body.String())
	}
	var body config.PublicConfig
	if err := json.Unmarshal(valid.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if !body.Battery.Enabled || body.Battery.CapacityWh != 1024 || body.Battery.StateOfChargePercent != 76 ||
		body.Battery.StateOfChargeUpdatedAt == nil || !body.Battery.StateOfChargeUpdatedAt.Equal(now) {
		t.Fatalf("battery response=%+v", body.Battery)
	}
	partial := requestBody(handler, http.MethodPut, "/api/config", "secret", `{"battery":{"reserve_percent":15}}`)
	if partial.Code != http.StatusOK {
		t.Fatalf("partial PUT code=%d body=%s", partial.Code, partial.Body.String())
	}
	reloaded, err := config.Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if !reloaded.Battery.Enabled || reloaded.Battery.CapacityWh != 1024 || reloaded.Battery.StateOfChargePercent != 76 ||
		reloaded.Battery.ReservePercent != 15 || reloaded.Battery.ConversionEfficiencyPercent != 90 || !reloaded.Battery.StateOfChargeUpdatedAt.Equal(now) {
		t.Fatalf("reloaded partial battery=%+v", reloaded.Battery)
	}
	raw, _ := os.ReadFile(path)
	if !strings.Contains(string(raw), "option future 'keep'") || !strings.Contains(string(raw), "config vendor 'unknown'") || !strings.Contains(string(raw), "option opaque 'yes'") {
		t.Fatalf("rewritten UCI:\n%s", raw)
	}
}
