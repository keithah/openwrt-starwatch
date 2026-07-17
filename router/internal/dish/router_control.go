package dish

import (
	"context"
	"errors"
	"fmt"
	"net"
	"strings"
	"time"

	device "github.com/clarkzjw/starlink-grpc-golang/pkg/spacex.com/api/device"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

var (
	ErrRouterRevisionStale    = errors.New("router config revision is stale")
	ErrRouterNameUnsupported  = errors.New("client naming is not supported by this router firmware")
	ErrRouterWriteUnconfirmed = errors.New("router write not confirmed by readback")
)

// RouterMutationClient is deliberately limited to the reads and targeted
// client-name RPC used by the first router write phase.
type RouterMutationClient interface {
	WifiGetConfig(context.Context) (*device.WifiGetConfigResponse, error)
	WifiGetClients(context.Context) (*device.WifiGetClientsResponse, error)
	WifiSetClientGivenName(context.Context, *device.WifiSetClientGivenNameRequest) error
	Close() error
}

type RouterMutationDial func(context.Context, string) (RouterMutationClient, error)

type RouterMutationOptions struct {
	ResolveGateway func(context.Context) (string, error)
	Dial           RouterMutationDial
	Timeout        time.Duration
}

type RouterMutationController struct{ options RouterMutationOptions }

func NewRouterMutationController(options RouterMutationOptions) *RouterMutationController {
	if options.ResolveGateway == nil {
		options.ResolveGateway = systemGateway
	}
	if options.Dial == nil {
		options.Dial = DialRouterMutation
	}
	if options.Timeout <= 0 {
		options.Timeout = 2 * time.Second
	}
	return &RouterMutationController{options: options}
}

// RenameClient rechecks incarnation immediately before the write. The router
// RPC does not document server-side incarnation enforcement, so this remains
// a best-effort TOCTOU guard. The name is accepted only after both config and
// live-client readback agree.
func (c *RouterMutationController) RenameClient(parent context.Context, mac, revision, givenName string) (uint32, error) {
	ctx, cancel := context.WithTimeout(parent, c.options.Timeout)
	defer cancel()
	target, err := c.options.ResolveGateway(ctx)
	if err != nil || target == "" {
		if err == nil {
			err = errors.New("empty router gateway")
		}
		return 0, fmt.Errorf("resolve Starlink router: %w", err)
	}
	if _, _, splitErr := net.SplitHostPort(target); splitErr != nil {
		target = net.JoinHostPort(target, "9000")
	}
	client, err := c.options.Dial(ctx, target)
	if err != nil {
		return 0, fmt.Errorf("dial Starlink router: %w", err)
	}
	defer client.Close()

	config, err := client.WifiGetConfig(ctx)
	if err != nil {
		return 0, fmt.Errorf("read router config: %w", err)
	}
	wifiConfig := config.GetWifiConfig()
	if wifiConfig == nil || fmt.Sprintf("incarnation:%d", wifiConfig.GetIncarnation()) != revision {
		return 0, ErrRouterRevisionStale
	}

	requestConfig := &device.ClientConfig{MacAddress: mac, GivenName: givenName}
	for _, candidate := range wifiConfig.GetClientConfigs() {
		if normalizeRouterMAC(candidate.GetMacAddress()) == mac {
			requestConfig = proto.Clone(candidate).(*device.ClientConfig)
			requestConfig.GivenName = givenName
			break
		}
	}
	if err := client.WifiSetClientGivenName(ctx, &device.WifiSetClientGivenNameRequest{ClientConfig: requestConfig}); err != nil {
		if code := status.Code(err); code == codes.Unimplemented || code == codes.Unavailable {
			return requestConfig.GetClientId(), fmt.Errorf("%w: %v", ErrRouterNameUnsupported, err)
		}
		return requestConfig.GetClientId(), fmt.Errorf("set client given name: %w", err)
	}

	readConfig, err := client.WifiGetConfig(ctx)
	if err != nil {
		return requestConfig.GetClientId(), fmt.Errorf("read router config after rename: %w", err)
	}
	readClients, err := client.WifiGetClients(ctx)
	if err != nil {
		return requestConfig.GetClientId(), fmt.Errorf("read router clients after rename: %w", err)
	}
	clientID, clientMatches := clientNameMatches(readClients.GetClients(), mac, givenName)
	if !configNameMatches(readConfig.GetWifiConfig(), mac, givenName) || !clientMatches {
		return requestConfig.GetClientId(), ErrRouterWriteUnconfirmed
	}
	// A minimal fallback has no stored ClientConfig/client_id before the
	// targeted rename. The live readback is authoritative for the confirmed
	// audit identity, so return it rather than the fallback's zero value.
	return clientID, nil
}

func configNameMatches(config *device.WifiConfig, mac, givenName string) bool {
	for _, candidate := range config.GetClientConfigs() {
		if normalizeRouterMAC(candidate.GetMacAddress()) == mac && candidate.GetGivenName() == givenName {
			return true
		}
	}
	return false
}

func clientNameMatches(clients []*device.WifiClient, mac, givenName string) (uint32, bool) {
	for _, client := range clients {
		if normalizeRouterMAC(client.GetMacAddress()) == mac && client.GetGivenName() == givenName {
			return client.GetClientId(), true
		}
	}
	return 0, false
}

func NormalizeRouterMAC(value string) (string, bool) {
	parsed, err := net.ParseMAC(value)
	if err != nil || len(parsed) != 6 {
		return "", false
	}
	return strings.ToLower(parsed.String()), true
}

func normalizeRouterMAC(value string) string {
	normalized, ok := NormalizeRouterMAC(value)
	if !ok {
		return ""
	}
	return normalized
}

type routerMutationGRPCClient struct {
	connection *grpc.ClientConn
	device     device.DeviceClient
}

func DialRouterMutation(ctx context.Context, address string) (RouterMutationClient, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	connection, err := grpc.NewClient(address, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return nil, err
	}
	return &routerMutationGRPCClient{connection: connection, device: device.NewDeviceClient(connection)}, nil
}

func (c *routerMutationGRPCClient) Close() error { return c.connection.Close() }

func (c *routerMutationGRPCClient) WifiGetConfig(ctx context.Context) (*device.WifiGetConfigResponse, error) {
	response, err := c.device.Handle(ctx, &device.Request{Request: &device.Request_WifiGetConfig{WifiGetConfig: &device.WifiGetConfigRequest{}}})
	if err != nil {
		return nil, err
	}
	if config := response.GetWifiGetConfig(); config != nil {
		return config, nil
	}
	return nil, errors.New("wifi_get_config: router response missing")
}

func (c *routerMutationGRPCClient) WifiGetClients(ctx context.Context) (*device.WifiGetClientsResponse, error) {
	response, err := c.device.Handle(ctx, &device.Request{Request: &device.Request_WifiGetClients{WifiGetClients: &device.WifiGetClientsRequest{}}})
	if err != nil {
		return nil, err
	}
	if clients := response.GetWifiGetClients(); clients != nil {
		return clients, nil
	}
	return nil, errors.New("wifi_get_clients: router response missing")
}

func (c *routerMutationGRPCClient) WifiSetClientGivenName(ctx context.Context, config *device.WifiSetClientGivenNameRequest) error {
	_, err := c.device.Handle(ctx, &device.Request{Request: &device.Request_WifiSetClientGivenName{WifiSetClientGivenName: config}})
	return err
}
