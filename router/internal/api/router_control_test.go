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
		{"blocked deferred", renameMAC, `{"config_revision":"incarnation:7","confirmation":"RENAME CLIENT","given_name":"Work Mac","blocked":true}`, http.StatusUnprocessableEntity},
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

func renameRequest(handler http.Handler, mac, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPatch, "/api/router/clients/"+mac, strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer secret")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, req)
	return response
}

type renameRouterFake struct {
	device.UnimplementedDeviceServer
	mu                  sync.Mutex
	config              *device.WifiConfig
	clients             []*device.WifiClient
	writes              []*device.WifiSetClientGivenNameRequest
	writeErr            error
	confirm             bool
	createConfigOnWrite bool
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
			if f.createConfigOnWrite {
				f.config.ClientConfigs = append(f.config.ClientConfigs, &device.ClientConfig{MacAddress: typed.WifiSetClientGivenName.GetClientConfig().GetMacAddress(), GivenName: typed.WifiSetClientGivenName.GetClientConfig().GetGivenName()})
			}
			for _, config := range f.config.ClientConfigs {
				if config.GetMacAddress() == typed.WifiSetClientGivenName.GetClientConfig().GetMacAddress() {
					config.GivenName = typed.WifiSetClientGivenName.GetClientConfig().GetGivenName()
				}
			}
			for _, client := range f.clients {
				if client.GetMacAddress() == typed.WifiSetClientGivenName.GetClientConfig().GetMacAddress() {
					client.GivenName = typed.WifiSetClientGivenName.GetClientConfig().GetGivenName()
				}
			}
		}
		return &device.Response{}, nil
	default:
		return nil, status.Errorf(codes.Unimplemented, "unexpected request %T", request.GetRequest())
	}
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
