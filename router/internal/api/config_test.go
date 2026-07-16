package api

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

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
