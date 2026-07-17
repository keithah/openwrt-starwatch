package dish

import (
	"encoding/json"
	"math"
	"strings"
	"testing"
	"time"

	device "github.com/clarkzjw/starlink-grpc-golang/pkg/spacex.com/api/device"
)

func TestMapRouterResponsesMapsTypedReadModelWithoutSecrets(t *testing.T) {
	password := "never-return-this-passphrase"
	config := &device.WifiConfig{Incarnation: 42, Channel_2Ghz: 6, HtBandwidth_2Ghz: device.WifiConfig_HT_BANDWIDTH_20_OR_40_MHZ,
		TxPowerLevel_2Ghz: device.TxPowerLevel_TX_POWER_LEVEL_80, Networks: []*device.WifiConfig_Network{{Domain: "lan", Ipv4: "192.168.1.1/24", BasicServiceSets: []*device.WifiConfig_BasicServiceSet{
			{Ssid: "open", Band: device.WifiConfig_RF_2GHZ, Auth: &device.WifiConfig_BasicServiceSet_AuthOpen{AuthOpen: &device.AuthOpen{}}},
			{Ssid: "wpa2", Bssid: "00:11:22:33:44:55", Band: device.WifiConfig_RF_5GHZ, IfaceName: "wlan0", Auth: &device.WifiConfig_BasicServiceSet_AuthWpa2{AuthWpa2: &device.AuthWpa2{Password: password}}},
			{Ssid: "wpa3", Auth: &device.WifiConfig_BasicServiceSet_AuthWpa3{AuthWpa3: &device.AuthWpa3{Password: ""}}},
			{Ssid: "mixed", Auth: &device.WifiConfig_BasicServiceSet_AuthWpa2Wpa3{AuthWpa2Wpa3: &device.AuthWpa2Wpa3{Password: password}}},
		}}}}
	responses := routerResponses{
		status:      &device.WifiGetStatusResponse{DeviceInfo: &device.DeviceInfo{Id: "Router-1", HardwareVersion: "v4", SoftwareVersion: "2026.7"}, DeviceState: &device.DeviceState{UptimeS: 5400}, Ipv4WanAddress: "100.64.0.2", NoWanLink: true, PingLatencyMs: 3, PingDropRate: .25, PingDropRate_5M: .1},
		history:     &device.WifiGetHistoryResponse{Current: 4, PingLatencyMs: []float32{1, 2, 3, 4}, PingDropRate: []float32{1, 0, 1, 0}},
		clients:     &device.WifiGetClientsResponse{Clients: []*device.WifiClient{{MacAddress: "aa:bb:cc:dd:ee:ff", Name: "laptop", GivenName: "Work", IpAddress: "192.168.1.20", Ipv6Addresses: []string{"fd00::20"}, Active: true, Blocked: true, Iface: device.WifiClient_RF_5GHZ, IfaceName: "wlan0", SignalStrength: -52, Snr: 39, ModeStr: "11ax", ChannelWidth: 80, AssociatedTimeS: 1200, RxStats: &device.WifiClient_RxStats{RateMbps: 866, ThroughputMbpsLast_15SAvg: 12.4, Bytes: 1234}, TxStats: &device.WifiClient_TxStats{RateMbps: 720, ThroughputMbpsLast_15SAvg: 2.1, Bytes: 5678}, PingMetrics: &device.WifiClient_PingMetrics{Latency_5M: 4.2, DropRate_5M: .2}}}},
		config:      &device.WifiGetConfigResponse{WifiConfig: config},
		diagnostics: &device.WifiGetDiagnosticsResponse{Networks: []*device.WifiGetDiagnosticsResponse_Network{{Domain: "lan", Ipv4: "192.168.1.1/24", Ipv6: []string{"fd00::/64"}, ClientsEthernet: 1, Clients_2Ghz: 2, Clients_5Ghz: 3}}},
		radios:      &device.GetRadioStatsResponse{RadioStats: []*device.RadioStats{{Band: device.WifiConfig_RF_2GHZ, RxStats: &device.NetworkInterface_RxStats{Bytes: 111}, TxStats: &device.NetworkInterface_TxStats{Bytes: 222}, ThermalStatus: &device.RadioStats_ThermalStatus{Temp2: 51.2, PowerReduction: 1}}}},
		interfaces:  &device.GetNetworkInterfacesResponse{NetworkInterfaces: []*device.NetworkInterface{{Name: "eth0", Up: true, MacAddress: "00:aa", Ipv4Addresses: []string{"192.168.1.1/24"}, RxStats: &device.NetworkInterface_RxStats{Bytes: 10}, TxStats: &device.NetworkInterface_TxStats{Bytes: 20}, Interface: &device.NetworkInterface_Ethernet{Ethernet: &device.EthernetNetworkInterface{}}}}},
	}
	got := mapRouterResponses(responses, time.Unix(100, 0))
	if got.ConfigRevision != "incarnation:42" || got.Device.ID != "Router-1" || got.Device.WANIPv4 != "100.64.0.2" || !got.Device.NoWANLink {
		t.Fatalf("device/config=%+v", got)
	}
	if len(got.Networks) != 1 || got.Networks[0].Clients5GHz != 3 || len(got.Networks[0].BasicServiceSets) != 4 {
		t.Fatalf("networks=%+v", got.Networks)
	}
	wantSecurity := []string{"OPEN", "WPA2", "WPA3", "WPA2_WPA3"}
	for i, want := range wantSecurity {
		if got.Networks[0].BasicServiceSets[i].Security != want {
			t.Fatalf("security[%d]=%q", i, got.Networks[0].BasicServiceSets[i].Security)
		}
	}
	if !got.Networks[0].BasicServiceSets[1].CredentialSet || got.Networks[0].BasicServiceSets[2].CredentialSet {
		t.Fatalf("credentials=%+v", got.Networks[0].BasicServiceSets)
	}
	if len(got.Clients) != 1 || !got.Clients[0].Blocked || got.Clients[0].RX.Bytes != 1234 || got.Clients[0].Ping.LatencyMS5m != 4.2 {
		t.Fatalf("clients=%+v", got.Clients)
	}
	if len(got.Radios) != 1 || got.Radios[0].TXPowerLevel != "TX_POWER_LEVEL_80" || got.Radios[0].ChannelWidthMHz != 40 || !got.Radios[0].ThermalThrottled {
		t.Fatalf("radios=%+v", got.Radios)
	}
	if len(got.Interfaces) != 1 || got.Interfaces[0].Kind != "ethernet" || got.Interfaces[0].RXBytes != 10 {
		t.Fatalf("interfaces=%+v", got.Interfaces)
	}
	encoded, err := json.Marshal(got)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), password) || strings.Contains(string(encoded), `"id"`) && strings.Contains(string(encoded), "opaque") {
		t.Fatalf("secret/fake id leaked: %s", encoded)
	}
}

func TestMapRouterPingWindowsAndOneHourAvailability(t *testing.T) {
	latency := make([]float32, 3600)
	drops := make([]float32, 3600)
	for i := range latency {
		latency[i] = float32(i % 10)
		drops[i] = 1
	}
	drops[3599] = 0
	got := mapRouterResponses(routerResponses{status: &device.WifiGetStatusResponse{PingLatencyMs: 4, PingDropRate: 0}, history: &device.WifiGetHistoryResponse{Current: 3600, PingLatencyMs: latency, PingDropRate: drops}}, time.Unix(100, 0))
	if got.Ping.LatencyMeanMS1h == nil || got.Ping.DropRate1h == nil || got.Ping.SecondsSinceLastSuccess != 0 || !got.Ping.Derived {
		t.Fatalf("ping=%+v", got.Ping)
	}
	if math.Abs(*got.Ping.LatencyMeanMS1h-4.5) > .001 {
		t.Fatalf("mean=%v", *got.Ping.LatencyMeanMS1h)
	}
	short := mapRouterResponses(routerResponses{status: &device.WifiGetStatusResponse{}, history: &device.WifiGetHistoryResponse{Current: 3, PingLatencyMs: []float32{1, 2, 3}, PingDropRate: []float32{0, 1, 1}}}, time.Unix(100, 0))
	if short.Ping.LatencyMeanMS1h != nil || short.Ping.DropRate1h != nil || short.Ping.OneHourAvailability.Available {
		t.Fatalf("short ping=%+v", short.Ping)
	}
	if short.Ping.SecondsSinceLastSuccess != 2 {
		t.Fatalf("seconds=%v", short.Ping.SecondsSinceLastSuccess)
	}
}
