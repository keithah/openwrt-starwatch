package dish

import (
	"fmt"
	"math"
	"time"

	device "github.com/clarkzjw/starlink-grpc-golang/pkg/spacex.com/api/device"
)

type RouterDevice struct {
	ID              string `json:"id"`
	HardwareVersion string `json:"hardware_version"`
	SoftwareVersion string `json:"software_version"`
	UptimeSeconds   uint64 `json:"uptime_seconds"`
	WANIPv4         string `json:"wan_ipv4"`
	NoWANLink       bool   `json:"no_wan_link"`
}

type RouterPing struct {
	LatencyMeanMS           float64      `json:"latency_mean_ms"`
	LatencyStddevMS         float64      `json:"latency_stddev_ms"`
	LatencyMeanMS5m         *float64     `json:"latency_mean_ms_5m,omitempty"`
	LatencyMeanMS1h         *float64     `json:"latency_mean_ms_1h,omitempty"`
	DropRate                float64      `json:"drop_rate"`
	DropRate5m              float64      `json:"drop_rate_5m"`
	DropRate1h              *float64     `json:"drop_rate_1h,omitempty"`
	SecondsSinceLastSuccess uint64       `json:"seconds_since_last_success"`
	OneHourAvailability     Availability `json:"one_hour_availability"`
	Derived                 bool         `json:"derived"`
}

type RouterNetwork struct {
	Domain           string                  `json:"domain"`
	IPv4             string                  `json:"ipv4"`
	IPv6             []string                `json:"ipv6"`
	ClientsEthernet  uint32                  `json:"clients_ethernet"`
	Clients2GHz      uint32                  `json:"clients_2ghz"`
	Clients5GHz      uint32                  `json:"clients_5ghz"`
	BasicServiceSets []RouterBasicServiceSet `json:"basic_service_sets"`
}

type RouterBasicServiceSet struct {
	SSID          string `json:"ssid"`
	BSSID         string `json:"bssid"`
	Band          string `json:"band"`
	Interface     string `json:"interface"`
	Security      string `json:"security"`
	CredentialSet bool   `json:"credential_set"`
	Hidden        bool   `json:"hidden"`
	Disabled      bool   `json:"disabled"`
}

type RouterClientTraffic struct {
	RateMbps          uint32  `json:"rate_mbps"`
	ThroughputMbps15s float32 `json:"throughput_mbps_15s"`
	Bytes             uint64  `json:"bytes"`
}
type RouterClientPing struct {
	LatencyMS5m float32 `json:"latency_ms_5m"`
	DropRate5m  float32 `json:"drop_rate_5m"`
}
type RouterClient struct {
	MAC               string              `json:"mac"`
	Name              string              `json:"name"`
	GivenName         string              `json:"given_name"`
	IPv4              string              `json:"ipv4"`
	IPv6              []string            `json:"ipv6"`
	Active            bool                `json:"active"`
	Blocked           bool                `json:"blocked"`
	Interface         string              `json:"interface"`
	InterfaceName     string              `json:"interface_name"`
	SignalDBM         float32             `json:"signal_dbm"`
	SNRDB             float32             `json:"snr_db"`
	Mode              string              `json:"mode"`
	ChannelWidthMHz   uint32              `json:"channel_width_mhz"`
	AssociatedSeconds uint32              `json:"associated_seconds"`
	RX                RouterClientTraffic `json:"rx"`
	TX                RouterClientTraffic `json:"tx"`
	Ping              RouterClientPing    `json:"ping"`
}

type RouterRadio struct {
	Band             string  `json:"band"`
	Channel          uint32  `json:"channel"`
	ChannelWidthMHz  uint32  `json:"channel_width_mhz"`
	Disabled         bool    `json:"disabled"`
	TXPowerLevel     string  `json:"tx_power_level"`
	RXBytes          uint64  `json:"rx_bytes"`
	TXBytes          uint64  `json:"tx_bytes"`
	TemperatureC     float64 `json:"temperature_c"`
	ThermalThrottled bool    `json:"thermal_throttled"`
}

type RouterInterface struct {
	Name    string   `json:"name"`
	Up      bool     `json:"up"`
	MAC     string   `json:"mac"`
	IPv4    []string `json:"ipv4"`
	IPv6    []string `json:"ipv6"`
	RXBytes uint64   `json:"rx_bytes"`
	TXBytes uint64   `json:"tx_bytes"`
	Kind    string   `json:"kind"`
}
type RouterAvailability struct {
	RadioStats  Availability `json:"radio_stats"`
	Diagnostics Availability `json:"diagnostics"`
	WifiConfig  Availability `json:"wifi_config"`
}

type routerResponses struct {
	info        *device.DeviceInfo
	status      *device.WifiGetStatusResponse
	history     *device.WifiGetHistoryResponse
	clients     *device.WifiGetClientsResponse
	config      *device.WifiGetConfigResponse
	radios      *device.GetRadioStatsResponse
	diagnostics *device.WifiGetDiagnosticsResponse
	interfaces  *device.GetNetworkInterfacesResponse
}

func mapRouterResponses(r routerResponses, now time.Time) *StarlinkRouter {
	result := &StarlinkRouter{Reachable: true, UpdatedAt: now, Availability: RouterAvailability{RadioStats: available(), Diagnostics: available(), WifiConfig: available()}}
	if r.status != nil {
		if info := r.status.GetDeviceInfo(); info != nil {
			result.Device.ID = info.GetId()
			result.Device.HardwareVersion = info.GetHardwareVersion()
			result.Device.SoftwareVersion = info.GetSoftwareVersion()
		}
		result.Device.UptimeSeconds = r.status.GetDeviceState().GetUptimeS()
		result.Device.WANIPv4 = r.status.GetIpv4WanAddress()
		result.Device.NoWANLink = r.status.GetNoWanLink()
		result.Ping.DropRate = float64(r.status.GetPingDropRate())
		result.Ping.DropRate5m = float64(r.status.GetPingDropRate_5M())
		latency := r.status.GetPingLatencyMs()
		drop := r.status.GetPingDropRate()
		result.PingLatencyMS = &latency
		result.PingDropRate = &drop
	}
	result.HardwareVersion, result.SoftwareVersion, result.UptimeSeconds = result.Device.HardwareVersion, result.Device.SoftwareVersion, result.Device.UptimeSeconds
	result.Ping = mapRouterPing(r.status, r.history)
	if r.config != nil && r.config.GetWifiConfig() != nil {
		result.ConfigRevision = fmt.Sprintf("incarnation:%d", r.config.GetWifiConfig().GetIncarnation())
		result.Networks = mapNetworks(r.config.GetWifiConfig(), r.diagnostics)
		result.Radios = mapRadios(r.config.GetWifiConfig(), r.radios)
	}
	if r.clients != nil {
		result.ClientCount = len(r.clients.GetClients())
		result.Clients = mapClients(r.clients.GetClients())
	}
	if r.interfaces != nil {
		result.Interfaces = mapInterfaces(r.interfaces.GetNetworkInterfaces())
	}
	return result
}

func available() Availability { return Availability{Available: true} }

func mapRouterPing(status *device.WifiGetStatusResponse, history *device.WifiGetHistoryResponse) RouterPing {
	p := RouterPing{Derived: true, OneHourAvailability: Availability{Reason: "router history does not cover one hour"}}
	if status != nil {
		p.DropRate = float64(status.GetPingDropRate())
		p.DropRate5m = float64(status.GetPingDropRate_5M())
	}
	if history == nil {
		return p
	}
	latencyWindow := orderedHistory(history.GetPingLatencyMs(), history.GetCurrent())
	dropWindow := orderedHistory(history.GetPingDropRate(), history.GetCurrent())
	latencies := finiteValues(latencyWindow)
	p.LatencyMeanMS, p.LatencyStddevMS = meanStddev(latencies)
	if values := finiteValues(tail(latencyWindow, 300)); len(values) > 0 {
		value, _ := meanStddev(values)
		p.LatencyMeanMS5m = &value
	}
	for i := len(dropWindow) - 1; i >= 0; i-- {
		if finite32(dropWindow[i]) && dropWindow[i] < 1 {
			p.SecondsSinceLastSuccess = uint64(len(dropWindow) - 1 - i)
			break
		}
	}
	if len(latencyWindow) >= 3600 && len(dropWindow) >= 3600 {
		lat := finiteValues(tail(latencyWindow, 3600))
		drop := finiteValues(tail(dropWindow, 3600))
		if len(lat) > 0 && len(drop) > 0 {
			value, _ := meanStddev(lat)
			p.LatencyMeanMS1h = &value
			meanDrop, _ := meanStddev(drop)
			p.DropRate1h = &meanDrop
			p.OneHourAvailability = available()
		}
	}
	return p
}

func orderedHistory(values []float32, current uint64) []float32 {
	if len(values) == 0 || current == 0 {
		return nil
	}
	count := len(values)
	if current < uint64(count) {
		count = int(current)
	}
	start := 0
	if current >= uint64(len(values)) {
		start = int(current % uint64(len(values)))
	}
	result := make([]float32, 0, count)
	for i := 0; i < count; i++ {
		result = append(result, values[(start+i)%len(values)])
	}
	return result
}

func finiteValues(values []float32) []float32 {
	result := make([]float32, 0, len(values))
	for _, value := range values {
		if finite32(value) {
			result = append(result, value)
		}
	}
	return result
}

func tail(values []float32, n int) []float32 {
	if len(values) <= n {
		return values
	}
	return values[len(values)-n:]
}
func finite32(v float32) bool     { return !float32IsNaN(v) && !math.IsInf(float64(v), 0) }
func float32IsNaN(v float32) bool { return v != v }
func meanStddev(values []float32) (float64, float64) {
	if len(values) == 0 {
		return 0, 0
	}
	var sum float64
	for _, v := range values {
		sum += float64(v)
	}
	mean := sum / float64(len(values))
	var squares float64
	for _, v := range values {
		d := float64(v) - mean
		squares += d * d
	}
	return mean, math.Sqrt(squares / float64(len(values)))
}

func mapNetworks(config *device.WifiConfig, diagnostics *device.WifiGetDiagnosticsResponse) []RouterNetwork {
	byDomain := map[string]*device.WifiGetDiagnosticsResponse_Network{}
	if diagnostics != nil {
		for _, n := range diagnostics.GetNetworks() {
			byDomain[n.GetDomain()] = n
		}
	}
	result := make([]RouterNetwork, 0, len(config.GetNetworks()))
	for _, n := range config.GetNetworks() {
		out := RouterNetwork{Domain: n.GetDomain(), IPv4: n.GetIpv4(), IPv6: []string{}, BasicServiceSets: []RouterBasicServiceSet{}}
		if d := byDomain[n.GetDomain()]; d != nil {
			out.IPv4 = d.GetIpv4()
			out.IPv6 = append([]string(nil), d.GetIpv6()...)
			out.ClientsEthernet = d.GetClientsEthernet()
			out.Clients2GHz = d.GetClients_2Ghz()
			out.Clients5GHz = d.GetClients_5Ghz()
		}
		for _, b := range n.GetBasicServiceSets() {
			security, credential := bssSecurity(b)
			out.BasicServiceSets = append(out.BasicServiceSets, RouterBasicServiceSet{SSID: b.GetSsid(), BSSID: b.GetBssid(), Band: b.GetBand().String(), Interface: b.GetIfaceName(), Security: security, CredentialSet: credential, Hidden: b.GetHidden(), Disabled: b.GetDisable()})
		}
		result = append(result, out)
	}
	return result
}

func bssSecurity(b *device.WifiConfig_BasicServiceSet) (string, bool) {
	switch auth := b.GetAuth().(type) {
	case *device.WifiConfig_BasicServiceSet_AuthOpen:
		return "OPEN", false
	case *device.WifiConfig_BasicServiceSet_AuthWpa2:
		return "WPA2", auth.AuthWpa2.GetPassword() != ""
	case *device.WifiConfig_BasicServiceSet_AuthWpa3:
		return "WPA3", auth.AuthWpa3.GetPassword() != ""
	case *device.WifiConfig_BasicServiceSet_AuthWpa2Wpa3:
		return "WPA2_WPA3", auth.AuthWpa2Wpa3.GetPassword() != ""
	case *device.WifiConfig_BasicServiceSet_AuthRadius:
		return "RADIUS", auth.AuthRadius.GetPassword() != ""
	case *device.WifiConfig_BasicServiceSet_AuthOpenEncrypted:
		return "OPEN_ENCRYPTED", false
	case *device.WifiConfig_BasicServiceSet_AuthOnboardRadius:
		return "ONBOARD_RADIUS", false
	default:
		return "", false
	}
}

func mapClients(clients []*device.WifiClient) []RouterClient {
	result := make([]RouterClient, 0, len(clients))
	for _, c := range clients {
		out := RouterClient{MAC: c.GetMacAddress(), Name: c.GetName(), GivenName: c.GetGivenName(), IPv4: c.GetIpAddress(), IPv6: append([]string(nil), c.GetIpv6Addresses()...), Active: c.GetActive(), Blocked: c.GetBlocked(), Interface: c.GetIface().String(), InterfaceName: c.GetIfaceName(), SignalDBM: c.GetSignalStrength(), SNRDB: c.GetSnr(), Mode: c.GetModeStr(), ChannelWidthMHz: c.GetChannelWidth(), AssociatedSeconds: c.GetAssociatedTimeS()}
		if rx := c.GetRxStats(); rx != nil {
			out.RX = RouterClientTraffic{RateMbps: rx.GetRateMbps(), ThroughputMbps15s: rx.GetThroughputMbpsLast_15SAvg(), Bytes: rx.GetBytes()}
		}
		if tx := c.GetTxStats(); tx != nil {
			out.TX = RouterClientTraffic{RateMbps: tx.GetRateMbps(), ThroughputMbps15s: tx.GetThroughputMbpsLast_15SAvg(), Bytes: tx.GetBytes()}
		}
		if ping := c.GetPingMetrics(); ping != nil {
			out.Ping = RouterClientPing{LatencyMS5m: ping.GetLatency_5M(), DropRate5m: ping.GetDropRate_5M()}
		}
		result = append(result, out)
	}
	return result
}

func mapRadios(config *device.WifiConfig, stats *device.GetRadioStatsResponse) []RouterRadio {
	if stats == nil {
		return nil
	}
	result := make([]RouterRadio, 0, len(stats.GetRadioStats()))
	for _, s := range stats.GetRadioStats() {
		out := RouterRadio{Band: s.GetBand().String()}
		switch s.GetBand() {
		case device.WifiConfig_RF_2GHZ:
			out.Channel = config.GetChannel_2Ghz()
			out.ChannelWidthMHz = htWidth(config.GetHtBandwidth_2Ghz())
			out.Disabled = config.GetDisable_2Ghz()
			out.TXPowerLevel = config.GetTxPowerLevel_2Ghz().String()
		case device.WifiConfig_RF_5GHZ:
			out.Channel = config.GetChannel_5Ghz()
			out.ChannelWidthMHz = vhtWidth(config.GetVhtBandwidth())
			if out.ChannelWidthMHz == 0 {
				out.ChannelWidthMHz = htWidth(config.GetHtBandwidth_5Ghz())
			}
			out.Disabled = config.GetDisable_5Ghz()
			out.TXPowerLevel = config.GetTxPowerLevel_5Ghz().String()
		case device.WifiConfig_RF_5GHZ_HIGH:
			out.Channel = config.GetChannel_5GhzHigh()
			out.ChannelWidthMHz = vhtWidth(config.GetVhtBandwidth_5GhzHigh())
			if out.ChannelWidthMHz == 0 {
				out.ChannelWidthMHz = htWidth(config.GetHtBandwidth_5GhzHigh())
			}
			out.Disabled = config.GetDisable_5GhzHigh()
			out.TXPowerLevel = config.GetTxPowerLevel_5GhzHigh().String()
		}
		out.RXBytes = s.GetRxStats().GetBytes()
		out.TXBytes = s.GetTxStats().GetBytes()
		if thermal := s.GetThermalStatus(); thermal != nil {
			out.TemperatureC = thermal.GetTemp2()
			out.ThermalThrottled = thermal.GetLevel() > 0 || thermal.GetPowerReduction() > 0
		}
		result = append(result, out)
	}
	return result
}
func htWidth(v device.WifiConfig_HTBandwidth) uint32 {
	if v == device.WifiConfig_HT_BANDWIDTH_20_OR_40_MHZ {
		return 40
	}
	if v == device.WifiConfig_HT_BANDWIDTH_20_MHZ {
		return 20
	}
	return 0
}
func vhtWidth(v device.WifiConfig_VHTBandwidth) uint32 {
	switch v {
	case device.WifiConfig_VHT_BANDWIDTH_80_MHZ, device.WifiConfig_VHT_BANDWIDTH_80_PLUS_80_MHZ:
		return 80
	case device.WifiConfig_VHT_BANDWIDTH_160_MHZ:
		return 160
	}
	return 0
}
func mapInterfaces(items []*device.NetworkInterface) []RouterInterface {
	result := make([]RouterInterface, 0, len(items))
	for _, i := range items {
		kind := "unknown"
		switch i.GetInterface().(type) {
		case *device.NetworkInterface_Ethernet:
			kind = "ethernet"
		case *device.NetworkInterface_Wifi:
			kind = "wifi"
		case *device.NetworkInterface_Bridge:
			kind = "bridge"
		}
		result = append(result, RouterInterface{Name: i.GetName(), Up: i.GetUp(), MAC: i.GetMacAddress(), IPv4: append([]string(nil), i.GetIpv4Addresses()...), IPv6: append([]string(nil), i.GetIpv6Addresses()...), RXBytes: i.GetRxStats().GetBytes(), TXBytes: i.GetTxStats().GetBytes(), Kind: kind})
	}
	return result
}

func cloneRouter(source *StarlinkRouter) *StarlinkRouter {
	if source == nil {
		return nil
	}
	clone := *source
	clone.Networks = append([]RouterNetwork(nil), source.Networks...)
	for i := range clone.Networks {
		clone.Networks[i].IPv6 = append([]string(nil), source.Networks[i].IPv6...)
		clone.Networks[i].BasicServiceSets = append([]RouterBasicServiceSet(nil), source.Networks[i].BasicServiceSets...)
	}
	clone.Clients = append([]RouterClient(nil), source.Clients...)
	for i := range clone.Clients {
		clone.Clients[i].IPv6 = append([]string(nil), source.Clients[i].IPv6...)
	}
	clone.Radios = append([]RouterRadio(nil), source.Radios...)
	clone.Interfaces = append([]RouterInterface(nil), source.Interfaces...)
	for i := range clone.Interfaces {
		clone.Interfaces[i].IPv4 = append([]string(nil), source.Interfaces[i].IPv4...)
		clone.Interfaces[i].IPv6 = append([]string(nil), source.Interfaces[i].IPv6...)
	}
	if source.PingLatencyMS != nil {
		value := *source.PingLatencyMS
		clone.PingLatencyMS = &value
	}
	if source.PingDropRate != nil {
		value := *source.PingDropRate
		clone.PingDropRate = &value
	}
	if source.LastPingSuccess != nil {
		value := *source.LastPingSuccess
		clone.LastPingSuccess = &value
	}
	if source.Ping.LatencyMeanMS5m != nil {
		value := *source.Ping.LatencyMeanMS5m
		clone.Ping.LatencyMeanMS5m = &value
	}
	if source.Ping.LatencyMeanMS1h != nil {
		value := *source.Ping.LatencyMeanMS1h
		clone.Ping.LatencyMeanMS1h = &value
	}
	if source.Ping.DropRate1h != nil {
		value := *source.Ping.DropRate1h
		clone.Ping.DropRate1h = &value
	}
	return &clone
}
