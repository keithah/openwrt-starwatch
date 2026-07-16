package dish

import (
	"bufio"
	"context"
	"encoding/binary"
	"fmt"
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
	GetDeviceInfo(context.Context) (*device.DeviceInfo, error)
	WifiGetClients(context.Context) (*device.WifiGetClientsResponse, error)
	WifiGetStatus(context.Context) (*device.WifiGetStatusResponse, error)
	Close() error
}

type routerTopology interface{ Snapshot() Snapshot }

type RouterPollerOptions struct {
	Topology       routerTopology
	ResolveGateway func(context.Context) (string, error)
	Dial           func(context.Context, string) (RouterAPI, error)
	Interval       time.Duration
	Timeout        time.Duration
}

type RouterPoller struct {
	options  RouterPollerOptions
	mu       sync.RWMutex
	snapshot *StarlinkRouter
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
	return &RouterPoller{options: options}
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
	info, err := client.GetDeviceInfo(ctx)
	if err != nil {
		p.failed()
		return
	}
	clients, err := client.WifiGetClients(ctx)
	if err != nil {
		p.failed()
		return
	}
	status, err := client.WifiGetStatus(ctx)
	if err != nil {
		p.failed()
		return
	}
	p.mu.Lock()
	p.snapshot = &StarlinkRouter{Reachable: true, HardwareVersion: info.GetHardwareVersion(), SoftwareVersion: info.GetSoftwareVersion(), ClientCount: len(clients.GetClients()), UptimeSeconds: status.GetDeviceState().GetUptimeS()}
	p.mu.Unlock()
}

func (p *RouterPoller) failed() {
	p.mu.Lock()
	if p.snapshot != nil {
		value := *p.snapshot
		value.Reachable = false
		p.snapshot = &value
	}
	p.mu.Unlock()
}

func (p *RouterPoller) Snapshot() *StarlinkRouter {
	p.mu.RLock()
	defer p.mu.RUnlock()
	if p.snapshot == nil {
		return nil
	}
	value := *p.snapshot
	return &value
}

type RouterClient struct {
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
	return &RouterClient{connection: connection, device: device.NewDeviceClient(connection)}, nil
}

func (c *RouterClient) Close() error { return c.connection.Close() }

func (c *RouterClient) GetDeviceInfo(ctx context.Context) (*device.DeviceInfo, error) {
	response, err := c.device.Handle(ctx, &device.Request{Request: &device.Request_GetDeviceInfo{GetDeviceInfo: &device.GetDeviceInfoRequest{}}})
	if err != nil {
		return nil, err
	}
	if info := response.GetGetDeviceInfo().GetDeviceInfo(); info != nil {
		return info, nil
	}
	return nil, fmt.Errorf("get_device_info: router response missing")
}

func (c *RouterClient) WifiGetClients(ctx context.Context) (*device.WifiGetClientsResponse, error) {
	response, err := c.device.Handle(ctx, &device.Request{Request: &device.Request_WifiGetClients{WifiGetClients: &device.WifiGetClientsRequest{}}})
	if err != nil {
		return nil, err
	}
	if clients := response.GetWifiGetClients(); clients != nil {
		return clients, nil
	}
	return nil, fmt.Errorf("wifi_get_clients: router response missing")
}

func (c *RouterClient) WifiGetStatus(ctx context.Context) (*device.WifiGetStatusResponse, error) {
	response, err := c.device.Handle(ctx, &device.Request{Request: &device.Request_GetStatus{GetStatus: &device.GetStatusRequest{}}})
	if err != nil {
		return nil, err
	}
	if status := response.GetWifiGetStatus(); status != nil {
		return status, nil
	}
	return nil, fmt.Errorf("wifi_get_status: router response missing")
}

func systemGateway(context.Context) (string, error) {
	file, err := os.Open("/proc/net/route")
	if err != nil {
		return "", err
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 4 || fields[1] != "00000000" {
			continue
		}
		flags, _ := strconv.ParseUint(fields[3], 16, 16)
		if flags&0x2 == 0 {
			continue
		}
		value, err := strconv.ParseUint(fields[2], 16, 32)
		if err != nil {
			continue
		}
		bytes := make([]byte, 4)
		binary.LittleEndian.PutUint32(bytes, uint32(value))
		return net.IP(bytes).String(), nil
	}
	if err := scanner.Err(); err != nil {
		return "", err
	}
	return "", fmt.Errorf("default gateway not found")
}
