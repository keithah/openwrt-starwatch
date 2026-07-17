package dish

import (
	"bufio"
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	device "github.com/clarkzjw/starlink-grpc-golang/pkg/spacex.com/api/device"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

type RouterAPI interface {
	WifiGetClients(context.Context) (*device.WifiGetClientsResponse, error)
	WifiGetStatus(context.Context) (*device.WifiGetStatusResponse, error)
	WifiGetHistory(context.Context) (*device.WifiGetHistoryResponse, error)
	WifiGetConfig(context.Context) (*device.WifiGetConfigResponse, error)
	GetRadioStats(context.Context) (*device.GetRadioStatsResponse, error)
	GetDiagnostics(context.Context) (*device.WifiGetDiagnosticsResponse, error)
	GetNetworkInterfaces(context.Context) (*device.GetNetworkInterfacesResponse, error)
	Close() error
}

type routerTopology interface{ Snapshot() Snapshot }

type RouterPollerOptions struct {
	Topology       routerTopology
	ResolveGateway func(context.Context) (string, error)
	Dial           func(context.Context, string) (RouterAPI, error)
	Interval       time.Duration
	Timeout        time.Duration
	Now            func() time.Time
}

type RouterPoller struct {
	options  RouterPollerOptions
	mu       sync.RWMutex
	snapshot *StarlinkRouter
	failures map[string]int
}

func NewRouterPoller(options RouterPollerOptions) *RouterPoller {
	if options.ResolveGateway == nil {
		options.ResolveGateway = systemGateway
	}
	if options.Dial == nil {
		options.Dial = DialRouter
	}
	if options.Interval <= 0 {
		options.Interval = time.Minute
	}
	if options.Timeout <= 0 {
		options.Timeout = 2 * time.Second
	}
	if options.Now == nil {
		options.Now = time.Now
	}
	return &RouterPoller{options: options, failures: make(map[string]int)}
}

func (p *RouterPoller) Run(ctx context.Context) {
	p.Poll(ctx)
	ticker := time.NewTicker(p.options.Interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			p.Poll(ctx)
		}
	}
}

func (p *RouterPoller) Poll(parent context.Context) {
	if p.options.Topology == nil || p.options.Topology.Snapshot().Topology != TopologyFull {
		return
	}
	ctx, cancel := context.WithTimeout(parent, p.options.Timeout)
	defer cancel()
	target, err := p.options.ResolveGateway(ctx)
	if err != nil || target == "" {
		p.failed()
		return
	}
	if _, _, splitErr := net.SplitHostPort(target); splitErr != nil {
		target = net.JoinHostPort(target, "9000")
	}
	client, err := p.options.Dial(ctx, target)
	if err != nil {
		p.failed()
		return
	}
	defer client.Close()
	clients, clientsErr := client.WifiGetClients(ctx)
	status, statusErr := client.WifiGetStatus(ctx)
	history, historyErr := client.WifiGetHistory(ctx)
	config, configErr := client.WifiGetConfig(ctx)
	radios, radiosErr := client.GetRadioStats(ctx)
	diagnostics, diagnosticsErr := client.GetDiagnostics(ctx)
	interfaces, interfacesErr := client.GetNetworkInterfaces(ctx)
	now := p.options.Now().UTC()
	mapped := mapRouterResponses(routerResponses{status: status, history: history, clients: clients, config: config, radios: radios, diagnostics: diagnostics, interfaces: interfaces}, now)
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.snapshot == nil {
		p.snapshot = &StarlinkRouter{}
	}
	current := cloneRouter(p.snapshot)
	if p.record("status", statusErr) {
		current.Reachable = false
	} else if statusErr == nil {
		current.Reachable = true
		current.UpdatedAt = now
		current.Device.UptimeSeconds = mapped.Device.UptimeSeconds
		current.Device.WANIPv4 = mapped.Device.WANIPv4
		current.Device.NoWANLink = mapped.Device.NoWANLink
		current.UptimeSeconds = mapped.UptimeSeconds
		current.PingLatencyMS = mapped.PingLatencyMS
		current.PingDropRate = mapped.PingDropRate
	}
	if statusErr == nil {
		current.Device.ID = mapped.Device.ID
		current.Device.HardwareVersion = mapped.Device.HardwareVersion
		current.Device.SoftwareVersion = mapped.Device.SoftwareVersion
		current.HardwareVersion = mapped.HardwareVersion
		current.SoftwareVersion = mapped.SoftwareVersion
	}
	if clientsErr == nil {
		p.record("clients", nil)
		current.Clients = mapped.Clients
		current.ClientCount = mapped.ClientCount
	} else {
		p.record("clients", clientsErr)
	}
	if historyErr == nil && statusErr == nil {
		p.record("history", nil)
		current.Ping = mapped.Ping
	} else if historyErr != nil {
		p.record("history", historyErr)
	}
	if configErr == nil {
		p.record("wifi_config", nil)
		current.ConfigRevision = mapped.ConfigRevision
		current.Networks = mapped.Networks
		current.Availability.WifiConfig = available()
	} else if p.record("wifi_config", configErr) {
		current.Availability.WifiConfig = Availability{Reason: "wifi config unavailable after three consecutive failures"}
	}
	if diagnosticsErr == nil {
		p.record("diagnostics", nil)
		if configErr == nil {
			current.Networks = mapped.Networks
		}
		current.Availability.Diagnostics = available()
	} else if p.record("diagnostics", diagnosticsErr) {
		current.Availability.Diagnostics = Availability{Reason: "router diagnostics unavailable after three consecutive failures"}
	}
	if radiosErr == nil {
		p.record("radio_stats", nil)
		if configErr == nil {
			current.Radios = mapped.Radios
		}
		current.Availability.RadioStats = available()
	} else if p.record("radio_stats", radiosErr) {
		current.Availability.RadioStats = Availability{Reason: "radio stats unavailable after three consecutive failures"}
	}
	if interfacesErr == nil {
		p.record("interfaces", nil)
		current.Interfaces = mapped.Interfaces
	} else {
		p.record("interfaces", interfacesErr)
	}
	if current.PingDropRate != nil && finite32(*current.PingDropRate) && *current.PingDropRate < 1 {
		value := now
		current.LastPingSuccess = &value
	}
	p.snapshot = current
}

func (p *RouterPoller) record(field string, err error) bool {
	if err == nil {
		p.failures[field] = 0
		return false
	}
	p.failures[field]++
	return p.failures[field] >= 3
}

func (p *RouterPoller) failed() {
	p.mu.Lock()
	statusFailed := p.record("status", fmt.Errorf("router unavailable"))
	wifiConfigFailed := p.record("wifi_config", fmt.Errorf("router unavailable"))
	diagnosticsFailed := p.record("diagnostics", fmt.Errorf("router unavailable"))
	radioStatsFailed := p.record("radio_stats", fmt.Errorf("router unavailable"))
	p.record("clients", fmt.Errorf("router unavailable"))
	p.record("history", fmt.Errorf("router unavailable"))
	p.record("interfaces", fmt.Errorf("router unavailable"))
	if p.snapshot != nil {
		value := cloneRouter(p.snapshot)
		if statusFailed {
			value.Reachable = false
		}
		if wifiConfigFailed {
			value.Availability.WifiConfig = Availability{Reason: "wifi config unavailable after three consecutive failures"}
		}
		if diagnosticsFailed {
			value.Availability.Diagnostics = Availability{Reason: "router diagnostics unavailable after three consecutive failures"}
		}
		if radioStatsFailed {
			value.Availability.RadioStats = Availability{Reason: "radio stats unavailable after three consecutive failures"}
		}
		p.snapshot = value
	}
	p.mu.Unlock()
}

func (p *RouterPoller) Snapshot() *StarlinkRouter {
	p.mu.RLock()
	defer p.mu.RUnlock()
	if p.snapshot == nil {
		return nil
	}
	return cloneRouter(p.snapshot)
}

type routerGRPCClient struct {
	connection *grpc.ClientConn
	device     device.DeviceClient
}

func DialRouter(ctx context.Context, address string) (RouterAPI, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	connection, err := grpc.NewClient(address, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return nil, err
	}
	return &routerGRPCClient{connection: connection, device: device.NewDeviceClient(connection)}, nil
}

func (c *routerGRPCClient) Close() error { return c.connection.Close() }

func (c *routerGRPCClient) WifiGetClients(ctx context.Context) (*device.WifiGetClientsResponse, error) {
	response, err := c.device.Handle(ctx, &device.Request{Request: &device.Request_WifiGetClients{WifiGetClients: &device.WifiGetClientsRequest{}}})
	if err != nil {
		return nil, err
	}
	if clients := response.GetWifiGetClients(); clients != nil {
		return clients, nil
	}
	return nil, fmt.Errorf("wifi_get_clients: router response missing")
}

func (c *routerGRPCClient) WifiGetStatus(ctx context.Context) (*device.WifiGetStatusResponse, error) {
	response, err := c.device.Handle(ctx, &device.Request{Request: &device.Request_GetStatus{GetStatus: &device.GetStatusRequest{}}})
	if err != nil {
		return nil, err
	}
	if status := response.GetWifiGetStatus(); status != nil {
		return status, nil
	}
	return nil, fmt.Errorf("wifi_get_status: router response missing")
}

func (c *routerGRPCClient) WifiGetHistory(ctx context.Context) (*device.WifiGetHistoryResponse, error) {
	response, err := c.device.Handle(ctx, &device.Request{Request: &device.Request_GetHistory{GetHistory: &device.GetHistoryRequest{}}})
	if err != nil {
		return nil, err
	}
	if history := response.GetWifiGetHistory(); history != nil {
		return history, nil
	}
	return nil, fmt.Errorf("wifi_get_history: router response missing")
}

func (c *routerGRPCClient) WifiGetConfig(ctx context.Context) (*device.WifiGetConfigResponse, error) {
	response, err := c.device.Handle(ctx, &device.Request{Request: &device.Request_WifiGetConfig{WifiGetConfig: &device.WifiGetConfigRequest{}}})
	if err != nil {
		return nil, err
	}
	if config := response.GetWifiGetConfig(); config != nil {
		return config, nil
	}
	return nil, fmt.Errorf("wifi_get_config: router response missing")
}

func (c *routerGRPCClient) GetRadioStats(ctx context.Context) (*device.GetRadioStatsResponse, error) {
	response, err := c.device.Handle(ctx, &device.Request{Request: &device.Request_GetRadioStats{GetRadioStats: &device.GetRadioStatsRequest{}}})
	if err != nil {
		return nil, err
	}
	if stats := response.GetGetRadioStats(); stats != nil {
		return stats, nil
	}
	return nil, fmt.Errorf("get_radio_stats: router response missing")
}

func (c *routerGRPCClient) GetDiagnostics(ctx context.Context) (*device.WifiGetDiagnosticsResponse, error) {
	response, err := c.device.Handle(ctx, &device.Request{Request: &device.Request_GetDiagnostics{GetDiagnostics: &device.GetDiagnosticsRequest{}}})
	if err != nil {
		return nil, err
	}
	if diagnostics := response.GetWifiGetDiagnostics(); diagnostics != nil {
		return diagnostics, nil
	}
	return nil, fmt.Errorf("get_diagnostics: router response missing")
}

func (c *routerGRPCClient) GetNetworkInterfaces(ctx context.Context) (*device.GetNetworkInterfacesResponse, error) {
	response, err := c.device.Handle(ctx, &device.Request{Request: &device.Request_GetNetworkInterfaces{GetNetworkInterfaces: &device.GetNetworkInterfacesRequest{}}})
	if err != nil {
		return nil, err
	}
	if interfaces := response.GetGetNetworkInterfaces(); interfaces != nil {
		return interfaces, nil
	}
	return nil, fmt.Errorf("get_network_interfaces: router response missing")
}

func systemGateway(context.Context) (string, error) {
	file, err := os.Open("/proc/net/route")
	if err != nil {
		return "", err
	}
	defer file.Close()
	return gatewayForDestination(file, "192.168.100.1")
}

func gatewayForDestination(routes io.Reader, destination string) (string, error) {
	targetIP := net.ParseIP(destination).To4()
	if targetIP == nil {
		return "", fmt.Errorf("invalid IPv4 destination %q", destination)
	}
	target := binary.LittleEndian.Uint32(targetIP)
	var bestGateway uint32
	var bestMask uint32
	var bestMetric uint64 = ^uint64(0)
	found := false
	scanner := bufio.NewScanner(routes)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 8 {
			continue
		}
		flags, _ := strconv.ParseUint(fields[3], 16, 16)
		if flags&0x2 == 0 {
			continue
		}
		route, routeErr := strconv.ParseUint(fields[1], 16, 32)
		gateway, gatewayErr := strconv.ParseUint(fields[2], 16, 32)
		metric, metricErr := strconv.ParseUint(fields[6], 10, 32)
		mask, maskErr := strconv.ParseUint(fields[7], 16, 32)
		if routeErr != nil || gatewayErr != nil || metricErr != nil || maskErr != nil || gateway == 0 {
			continue
		}
		route32, gateway32, mask32 := uint32(route), uint32(gateway), uint32(mask)
		if target&mask32 != route32&mask32 {
			continue
		}
		if found && (mask32 < bestMask || mask32 == bestMask && metric >= bestMetric) {
			continue
		}
		found, bestGateway, bestMask, bestMetric = true, gateway32, mask32, metric
	}
	if err := scanner.Err(); err != nil {
		return "", err
	}
	if found {
		bytes := make([]byte, 4)
		binary.LittleEndian.PutUint32(bytes, bestGateway)
		return net.IP(bytes).String(), nil
	}
	return "", fmt.Errorf("gateway for %s not found", destination)
}
