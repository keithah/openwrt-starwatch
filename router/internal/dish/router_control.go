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
	ErrRouterRevisionStale                 = errors.New("router config revision is stale")
	ErrRouterNameUnsupported               = errors.New("client naming is not supported by this router firmware")
	ErrRouterBlockUnsupported              = errors.New("client blocking is not supported by this router firmware")
	ErrRouterUserManagedBlock              = errors.New("client has a user-managed block schedule")
	ErrRouterWifiUnsupported               = errors.New("Wi-Fi update is not supported by this router firmware")
	ErrRouterUnsafeChannel                 = errors.New("channel writes are withheld: router exposes no advertised allowed-channel set")
	ErrRouterNetworkCredentialsUnavailable = errors.New("router network credentials unavailable")
	ErrRouterWriteUnconfirmed              = errors.New("router write not confirmed by readback")
)

const starwatchBlockGroupID = "starwatch-block"

// RouterMutationClient is deliberately limited to the reads and targeted
// client-name RPC used by the first router write phase.
type RouterMutationClient interface {
	WifiGetConfig(context.Context) (*device.WifiGetConfigResponse, error)
	WifiGetClients(context.Context) (*device.WifiGetClientsResponse, error)
	WifiSetClientGivenName(context.Context, *device.WifiSetClientGivenNameRequest) error
	WifiSetConfig(context.Context, *device.WifiSetConfigRequest) error
	Close() error
}

type RouterWifiField string

const (
	RouterWifiBandEnabled RouterWifiField = "band_enabled"
	RouterWifiWidth       RouterWifiField = "channel_width"
	RouterWifiTxPower     RouterWifiField = "tx_power"
	RouterWifiChannel     RouterWifiField = "channel"
	RouterWifiSteering    RouterWifiField = "band_steering"
	RouterWifiOutdoor     RouterWifiField = "outdoor_mode"
	RouterWifiNameservers RouterWifiField = "nameservers"
	RouterWifiSecureDNS   RouterWifiField = "secure_dns"
)

// RouterWifiMutation represents exactly one scalar setting. Its request is
// always built from a fresh, minimal WifiConfig with incarnation plus one
// paired apply flag; it never carries any collection or unrelated apply flag.
type RouterWifiMutation struct {
	Field   RouterWifiField
	Band    string
	Bool    bool
	Uint    uint32
	Strings []string
}

// RouterNetworkMutation addresses one BSS by its currently reported SSID and band.
// Passphrase is intentionally write-only: callers must not report or audit it.
type RouterNetworkMutation struct {
	SSID       string
	Band       string
	NewSSID    *string
	Security   *string
	Passphrase *string
	Hidden     *bool
	Disabled   *bool
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

// SetClientBlocked changes only Starwatch's schedule in the addressed client's
// ClientConfig. WeeklyBlockSchedule has no day field, so its single all-week
// range uses minutes-of-week [0, 10080). As with RenameClient, incarnation is
// checked immediately before this targeted RPC, but is only a best-effort
// TOCTOU guard because the router does not document server-side enforcement.
func (c *RouterMutationController) SetClientBlocked(parent context.Context, mac, revision string, blocked bool) (uint32, error) {
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

	requestConfig := &device.ClientConfig{MacAddress: mac}
	found := false
	for _, candidate := range wifiConfig.GetClientConfigs() {
		if normalizeRouterMAC(candidate.GetMacAddress()) == mac {
			requestConfig, found = proto.Clone(candidate).(*device.ClientConfig), true
			break
		}
	}
	if !found && !blocked {
		// No stored schedule means the requested unblock is already reflected in
		// config; live readback below still prevents a false accepted response.
		requestConfig = &device.ClientConfig{MacAddress: mac}
	}
	if blocked {
		// Replace only our own marker so an older/duplicated Starwatch entry is
		// canonicalized without touching any user-created schedule.
		requestConfig.WeeklyBlockSchedules = append(removeStarwatchSchedules(requestConfig.GetWeeklyBlockSchedules()), starwatchAllWeekSchedule())
	} else {
		// A non-Starwatch schedule combined with the live Blocked signal means
		// we cannot attribute the block to our schedule. Leave that user-owned
		// policy intact instead of reporting a misleading unblock success.
		currentClients, clientsErr := client.WifiGetClients(ctx)
		if clientsErr != nil {
			return requestConfig.GetClientId(), fmt.Errorf("read router clients before unblock: %w", clientsErr)
		}
		_, liveBlocked := clientBlockedMatches(currentClients.GetClients(), mac, true)
		if liveBlocked && hasNonStarwatchSchedule(requestConfig.GetWeeklyBlockSchedules()) {
			return requestConfig.GetClientId(), ErrRouterUserManagedBlock
		}
		requestConfig.WeeklyBlockSchedules = removeStarwatchSchedules(requestConfig.GetWeeklyBlockSchedules())
	}
	if err := client.WifiSetClientGivenName(ctx, &device.WifiSetClientGivenNameRequest{ClientConfig: requestConfig}); err != nil {
		if code := status.Code(err); code == codes.Unimplemented || code == codes.Unavailable {
			return requestConfig.GetClientId(), fmt.Errorf("%w: %v", ErrRouterBlockUnsupported, err)
		}
		return requestConfig.GetClientId(), fmt.Errorf("set client block schedule: %w", err)
	}

	readConfig, err := client.WifiGetConfig(ctx)
	if err != nil {
		return requestConfig.GetClientId(), fmt.Errorf("read router config after block change: %w", err)
	}
	readClients, err := client.WifiGetClients(ctx)
	if err != nil {
		return requestConfig.GetClientId(), fmt.Errorf("read router clients after block change: %w", err)
	}
	clientID, liveMatches := clientBlockedMatches(readClients.GetClients(), mac, blocked)
	if !configBlockMatches(readConfig.GetWifiConfig(), mac, blocked) || !liveMatches {
		return requestConfig.GetClientId(), ErrRouterWriteUnconfirmed
	}
	return clientID, nil
}

// ApplyRouterWifi applies one safe scalar and rereads config to confirm it.
// Channel writes are deliberately rejected: these protobufs expose a current
// channel but no advertised non-DFS allowed-channel set, so accepting a value
// would invent a safety predicate the router has not provided.
func (c *RouterMutationController) ApplyRouterWifi(parent context.Context, revision string, mutation RouterWifiMutation) error {
	if mutation.Field == RouterWifiChannel {
		return ErrRouterUnsafeChannel
	}
	ctx, cancel := context.WithTimeout(parent, c.options.Timeout)
	defer cancel()
	target, err := c.options.ResolveGateway(ctx)
	if err != nil || target == "" {
		if err == nil {
			err = errors.New("empty router gateway")
		}
		return fmt.Errorf("resolve Starlink router: %w", err)
	}
	if _, _, splitErr := net.SplitHostPort(target); splitErr != nil {
		target = net.JoinHostPort(target, "9000")
	}
	client, err := c.options.Dial(ctx, target)
	if err != nil {
		return fmt.Errorf("dial Starlink router: %w", err)
	}
	defer client.Close()
	current, err := client.WifiGetConfig(ctx)
	if err != nil {
		return fmt.Errorf("read router config: %w", err)
	}
	if current.GetWifiConfig() == nil || fmt.Sprintf("incarnation:%d", current.GetWifiConfig().GetIncarnation()) != revision {
		return ErrRouterRevisionStale
	}
	request, err := buildRouterWifiSetConfig(current.GetWifiConfig().GetIncarnation(), mutation)
	if err != nil {
		return err
	}
	if err := client.WifiSetConfig(ctx, request); err != nil {
		if code := status.Code(err); code == codes.Unimplemented || code == codes.Unavailable {
			return fmt.Errorf("%w: %v", ErrRouterWifiUnsupported, err)
		}
		return fmt.Errorf("set router Wi-Fi config: %w", err)
	}
	readback, err := client.WifiGetConfig(ctx)
	if err != nil {
		return fmt.Errorf("read router config after Wi-Fi update: %w", err)
	}
	if !routerWifiMatches(readback.GetWifiConfig(), mutation) {
		return ErrRouterWriteUnconfirmed
	}
	return nil
}

func (c *RouterMutationController) ApplyRouterNetwork(parent context.Context, revision string, mutation RouterNetworkMutation) error {
	ctx, cancel := context.WithTimeout(parent, c.options.Timeout)
	defer cancel()
	target, err := c.options.ResolveGateway(ctx)
	if err != nil || target == "" {
		if err == nil {
			err = errors.New("empty router gateway")
		}
		return fmt.Errorf("resolve Starlink router: %w", err)
	}
	if _, _, err := net.SplitHostPort(target); err != nil {
		target = net.JoinHostPort(target, "9000")
	}
	client, err := c.options.Dial(ctx, target)
	if err != nil {
		return fmt.Errorf("dial Starlink router: %w", err)
	}
	defer client.Close()
	current, err := client.WifiGetConfig(ctx)
	if err != nil {
		return fmt.Errorf("read router config: %w", err)
	}
	config := current.GetWifiConfig()
	if config == nil || fmt.Sprintf("incarnation:%d", config.GetIncarnation()) != revision {
		return ErrRouterRevisionStale
	}
	request, err := buildRouterNetworkSetConfig(config, mutation)
	if err != nil {
		return err
	}
	if err := client.WifiSetConfig(ctx, request); err != nil {
		if code := status.Code(err); code == codes.Unimplemented || code == codes.Unavailable {
			return fmt.Errorf("%w: %v", ErrRouterWifiUnsupported, err)
		}
		return fmt.Errorf("set router Wi-Fi config: %w", err)
	}
	readback, err := client.WifiGetConfig(ctx)
	if err != nil {
		return fmt.Errorf("read router config after network update: %w", err)
	}
	if !routerNetworkMatches(readback.GetWifiConfig(), mutation) {
		return ErrRouterWriteUnconfirmed
	}
	return nil
}

func buildRouterNetworkSetConfig(current *device.WifiConfig, mutation RouterNetworkMutation) (*device.WifiSetConfigRequest, error) {
	clone := proto.Clone(current).(*device.WifiConfig)
	var target *device.WifiConfig_BasicServiceSet
	count := 0
	for _, network := range clone.GetNetworks() {
		for _, bss := range network.GetBasicServiceSets() {
			if bss.GetSsid() == mutation.SSID && bss.GetBand().String() == mutation.Band {
				target, count = bss, count+1
			}
		}
	}
	if count != 1 {
		return nil, ErrRouterWifiUnsupported
	}
	if mutation.NewSSID != nil {
		for _, network := range clone.GetNetworks() {
			for _, bss := range network.GetBasicServiceSets() {
				if bss != target && bss.GetBand().String() == mutation.Band && bss.GetSsid() == *mutation.NewSSID {
					return nil, ErrRouterWifiUnsupported
				}
			}
		}
	}
	for _, network := range clone.GetNetworks() {
		for _, bss := range network.GetBasicServiceSets() {
			if bss != target && bssPSKPassword(bss) == "" && bssIsPSK(bss) {
				return nil, ErrRouterNetworkCredentialsUnavailable
			}
		}
	}
	if mutation.NewSSID != nil {
		target.Ssid = *mutation.NewSSID
	}
	if mutation.Hidden != nil {
		target.Hidden = *mutation.Hidden
	}
	if mutation.Disabled != nil {
		target.Disable = *mutation.Disabled
	}
	if mutation.Security != nil {
		password := bssPSKPassword(target)
		if mutation.Passphrase != nil {
			password = *mutation.Passphrase
		}
		if *mutation.Security != "OPEN" && password == "" {
			// The target's credential is just as important as a sibling's: a
			// security-mode update without a returned or replacement password
			// would serialize an empty PSK into ApplyNetworks.
			return nil, ErrRouterNetworkCredentialsUnavailable
		}
		switch *mutation.Security {
		case "OPEN":
			target.Auth = &device.WifiConfig_BasicServiceSet_AuthOpen{AuthOpen: &device.AuthOpen{}}
		case "WPA2":
			target.Auth = &device.WifiConfig_BasicServiceSet_AuthWpa2{AuthWpa2: &device.AuthWpa2{Password: password}}
		case "WPA3":
			target.Auth = &device.WifiConfig_BasicServiceSet_AuthWpa3{AuthWpa3: &device.AuthWpa3{Password: password}}
		case "WPA2_WPA3":
			target.Auth = &device.WifiConfig_BasicServiceSet_AuthWpa2Wpa3{AuthWpa2Wpa3: &device.AuthWpa2Wpa3{Password: password}}
		default:
			return nil, ErrRouterWifiUnsupported
		}
	} else if mutation.Passphrase != nil {
		if !bssIsPSK(target) {
			return nil, ErrRouterWifiUnsupported
		}
		setBSSPSKPassword(target, *mutation.Passphrase)
	}
	return &device.WifiSetConfigRequest{WifiConfig: &device.WifiConfig{Incarnation: clone.GetIncarnation(), Networks: clone.GetNetworks(), ApplyNetworks: true}}, nil
}

func bssIsPSK(bss *device.WifiConfig_BasicServiceSet) bool {
	return bss.GetAuthWpa2() != nil || bss.GetAuthWpa3() != nil || bss.GetAuthWpa2Wpa3() != nil
}
func bssPSKPassword(bss *device.WifiConfig_BasicServiceSet) string {
	if x := bss.GetAuthWpa2(); x != nil {
		return x.GetPassword()
	}
	if x := bss.GetAuthWpa3(); x != nil {
		return x.GetPassword()
	}
	if x := bss.GetAuthWpa2Wpa3(); x != nil {
		return x.GetPassword()
	}
	return ""
}
func setBSSPSKPassword(bss *device.WifiConfig_BasicServiceSet, password string) {
	if x := bss.GetAuthWpa2(); x != nil {
		x.Password = password
	}
	if x := bss.GetAuthWpa3(); x != nil {
		x.Password = password
	}
	if x := bss.GetAuthWpa2Wpa3(); x != nil {
		x.Password = password
	}
}
func routerNetworkMatches(config *device.WifiConfig, mutation RouterNetworkMutation) bool {
	if config == nil {
		return false
	}
	for _, n := range config.GetNetworks() {
		for _, b := range n.GetBasicServiceSets() {
			if b.GetSsid() != mutation.SSID && (mutation.NewSSID == nil || b.GetSsid() != *mutation.NewSSID) {
				continue
			}
			if b.GetBand().String() != mutation.Band {
				continue
			}
			if mutation.NewSSID != nil && b.GetSsid() != *mutation.NewSSID {
				return false
			}
			if mutation.Hidden != nil && b.GetHidden() != *mutation.Hidden {
				return false
			}
			if mutation.Disabled != nil && b.GetDisable() != *mutation.Disabled {
				return false
			}
			if mutation.Security != nil {
				sec, _ := bssSecurityForMutation(b)
				if sec != *mutation.Security {
					return false
				}
			}
			return true
		}
	}
	return false
}
func bssSecurityForMutation(b *device.WifiConfig_BasicServiceSet) (string, bool) {
	if b.GetAuthOpen() != nil {
		return "OPEN", true
	}
	if b.GetAuthWpa2() != nil {
		return "WPA2", true
	}
	if b.GetAuthWpa3() != nil {
		return "WPA3", true
	}
	if b.GetAuthWpa2Wpa3() != nil {
		return "WPA2_WPA3", true
	}
	return "", false
}

func buildRouterWifiSetConfig(incarnation uint64, mutation RouterWifiMutation) (*device.WifiSetConfigRequest, error) {
	config := &device.WifiConfig{Incarnation: incarnation}
	switch mutation.Field {
	case RouterWifiBandEnabled:
		switch mutation.Band {
		case "RF_2GHZ":
			config.Disable_2Ghz, config.ApplyDisable_2Ghz = !mutation.Bool, true
		case "RF_5GHZ":
			config.Disable_5Ghz, config.ApplyDisable_5Ghz = !mutation.Bool, true
		case "RF_5GHZ_HIGH":
			config.Disable_5GhzHigh, config.ApplyDisable_5GhzHigh = !mutation.Bool, true
		default:
			return nil, ErrRouterWifiUnsupported
		}
	case RouterWifiWidth:
		if err := setRouterWifiWidth(config, mutation.Band, mutation.Uint); err != nil {
			return nil, err
		}
	case RouterWifiTxPower:
		level, ok := routerTxPowerLevel(mutation.Uint)
		if !ok {
			return nil, ErrRouterWifiUnsupported
		}
		switch mutation.Band {
		case "RF_2GHZ":
			config.TxPowerLevel_2Ghz, config.ApplyTxPowerLevel_2Ghz = level, true
		case "RF_5GHZ":
			config.TxPowerLevel_5Ghz, config.ApplyTxPowerLevel_5Ghz = level, true
		case "RF_5GHZ_HIGH":
			config.TxPowerLevel_5GhzHigh, config.ApplyTxPowerLevel_5GhzHigh = level, true
		default:
			return nil, ErrRouterWifiUnsupported
		}
	case RouterWifiSteering:
		config.DisableBandSteering, config.ApplyDisableBandSteering = !mutation.Bool, true
	case RouterWifiOutdoor:
		config.OutdoorMode, config.ApplyOutdoorMode = mutation.Bool, true
	case RouterWifiNameservers:
		if len(mutation.Strings) == 0 {
			return nil, ErrRouterWifiUnsupported
		}
		config.Nameservers, config.ApplyNameservers = append([]string(nil), mutation.Strings...), true
	case RouterWifiSecureDNS:
		config.SecureDns, config.ApplySecureDns = mutation.Bool, true
	default:
		return nil, ErrRouterWifiUnsupported
	}
	return &device.WifiSetConfigRequest{WifiConfig: config}, nil
}

func setRouterWifiWidth(config *device.WifiConfig, band string, width uint32) error {
	switch band {
	case "RF_2GHZ":
		switch width {
		case 20:
			config.HtBandwidth_2Ghz, config.ApplyHtBandwidth_2Ghz = device.WifiConfig_HT_BANDWIDTH_20_MHZ, true
		case 40:
			config.HtBandwidth_2Ghz, config.ApplyHtBandwidth_2Ghz = device.WifiConfig_HT_BANDWIDTH_20_OR_40_MHZ, true
		default:
			return ErrRouterWifiUnsupported
		}
	case "RF_5GHZ":
		switch width {
		case 20:
			config.HtBandwidth_5Ghz, config.ApplyHtBandwidth_5Ghz = device.WifiConfig_HT_BANDWIDTH_20_MHZ, true
		case 40:
			config.HtBandwidth_5Ghz, config.ApplyHtBandwidth_5Ghz = device.WifiConfig_HT_BANDWIDTH_20_OR_40_MHZ, true
		case 80:
			config.VhtBandwidth, config.ApplyVhtBandwidth = device.WifiConfig_VHT_BANDWIDTH_80_MHZ, true
		case 160:
			config.VhtBandwidth, config.ApplyVhtBandwidth = device.WifiConfig_VHT_BANDWIDTH_160_MHZ, true
		default:
			return ErrRouterWifiUnsupported
		}
	case "RF_5GHZ_HIGH":
		switch width {
		case 20:
			config.HtBandwidth_5GhzHigh, config.ApplyHtBandwidth_5GhzHigh = device.WifiConfig_HT_BANDWIDTH_20_MHZ, true
		case 40:
			config.HtBandwidth_5GhzHigh, config.ApplyHtBandwidth_5GhzHigh = device.WifiConfig_HT_BANDWIDTH_20_OR_40_MHZ, true
		case 80:
			config.VhtBandwidth_5GhzHigh, config.ApplyVhtBandwidth_5GhzHigh = device.WifiConfig_VHT_BANDWIDTH_80_MHZ, true
		case 160:
			config.VhtBandwidth_5GhzHigh, config.ApplyVhtBandwidth_5GhzHigh = device.WifiConfig_VHT_BANDWIDTH_160_MHZ, true
		default:
			return ErrRouterWifiUnsupported
		}
	default:
		return ErrRouterWifiUnsupported
	}
	return nil
}

func routerTxPowerLevel(percent uint32) (device.TxPowerLevel, bool) {
	switch percent {
	case 100:
		return device.TxPowerLevel_TX_POWER_LEVEL_100, true
	case 80:
		return device.TxPowerLevel_TX_POWER_LEVEL_80, true
	case 50:
		return device.TxPowerLevel_TX_POWER_LEVEL_50, true
	case 25:
		return device.TxPowerLevel_TX_POWER_LEVEL_25, true
	case 12:
		return device.TxPowerLevel_TX_POWER_LEVEL_12, true
	case 6:
		return device.TxPowerLevel_TX_POWER_LEVEL_6, true
	}
	return 0, false
}

func routerWifiMatches(config *device.WifiConfig, mutation RouterWifiMutation) bool {
	if config == nil {
		return false
	}
	switch mutation.Field {
	case RouterWifiBandEnabled:
		switch mutation.Band {
		case "RF_2GHZ":
			return config.GetDisable_2Ghz() == !mutation.Bool
		case "RF_5GHZ":
			return config.GetDisable_5Ghz() == !mutation.Bool
		case "RF_5GHZ_HIGH":
			return config.GetDisable_5GhzHigh() == !mutation.Bool
		}
	case RouterWifiWidth: // Compare the one mapped enum rather than any apply flag returned by readback.
		expected, err := buildRouterWifiSetConfig(config.GetIncarnation(), mutation)
		if err != nil {
			return false
		}
		e := expected.GetWifiConfig()
		switch mutation.Band {
		case "RF_2GHZ":
			return config.GetHtBandwidth_2Ghz() == e.GetHtBandwidth_2Ghz()
		case "RF_5GHZ":
			if mutation.Uint <= 40 {
				return config.GetHtBandwidth_5Ghz() == e.GetHtBandwidth_5Ghz()
			}
			return config.GetVhtBandwidth() == e.GetVhtBandwidth()
		case "RF_5GHZ_HIGH":
			if mutation.Uint <= 40 {
				return config.GetHtBandwidth_5GhzHigh() == e.GetHtBandwidth_5GhzHigh()
			}
			return config.GetVhtBandwidth_5GhzHigh() == e.GetVhtBandwidth_5GhzHigh()
		}
	case RouterWifiTxPower:
		expected, ok := routerTxPowerLevel(mutation.Uint)
		if !ok {
			return false
		}
		switch mutation.Band {
		case "RF_2GHZ":
			return config.GetTxPowerLevel_2Ghz() == expected
		case "RF_5GHZ":
			return config.GetTxPowerLevel_5Ghz() == expected
		case "RF_5GHZ_HIGH":
			return config.GetTxPowerLevel_5GhzHigh() == expected
		}
	case RouterWifiSteering:
		return config.GetDisableBandSteering() == !mutation.Bool
	case RouterWifiOutdoor:
		return config.GetOutdoorMode() == mutation.Bool
	case RouterWifiNameservers:
		return strings.Join(config.GetNameservers(), "\x00") == strings.Join(mutation.Strings, "\x00")
	case RouterWifiSecureDNS:
		return config.GetSecureDns() == mutation.Bool
	}
	return false
}

func starwatchAllWeekSchedule() *device.WeeklyBlockSchedule {
	return &device.WeeklyBlockSchedule{GroupId: starwatchBlockGroupID, BlockRanges: []*device.WeeklyBlockSchedule_BlockRange{{StartMinutes: 0, EndMinutes: 10080}}}
}

func hasNonStarwatchSchedule(schedules []*device.WeeklyBlockSchedule) bool {
	for _, schedule := range schedules {
		if schedule.GetGroupId() != starwatchBlockGroupID {
			return true
		}
	}
	return false
}

func removeStarwatchSchedules(schedules []*device.WeeklyBlockSchedule) []*device.WeeklyBlockSchedule {
	kept := make([]*device.WeeklyBlockSchedule, 0, len(schedules))
	for _, schedule := range schedules {
		if schedule.GetGroupId() != starwatchBlockGroupID {
			kept = append(kept, schedule)
		}
	}
	return kept
}

func configBlockMatches(config *device.WifiConfig, mac string, blocked bool) bool {
	for _, candidate := range config.GetClientConfigs() {
		if normalizeRouterMAC(candidate.GetMacAddress()) == mac {
			starwatchSchedules := 0
			for _, schedule := range candidate.GetWeeklyBlockSchedules() {
				if schedule.GetGroupId() == starwatchBlockGroupID {
					starwatchSchedules++
					if len(schedule.GetBlockRanges()) != 1 || schedule.GetBlockRanges()[0].GetStartMinutes() != 0 || schedule.GetBlockRanges()[0].GetEndMinutes() != 10080 {
						return false
					}
				}
			}
			if blocked {
				return starwatchSchedules == 1
			}
			return starwatchSchedules == 0
		}
	}
	// A targeted write is not confirmed if the addressed ClientConfig vanished
	// from readback, even for an unblock where no Starwatch schedule remains.
	return false
}

func clientBlockedMatches(clients []*device.WifiClient, mac string, blocked bool) (uint32, bool) {
	for _, client := range clients {
		if normalizeRouterMAC(client.GetMacAddress()) == mac {
			return client.GetClientId(), client.GetBlocked() == blocked
		}
	}
	return 0, false
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

func (c *routerMutationGRPCClient) WifiSetConfig(ctx context.Context, config *device.WifiSetConfigRequest) error {
	response, err := c.device.Handle(ctx, &device.Request{Request: &device.Request_WifiSetConfig{WifiSetConfig: config}})
	if err != nil {
		return err
	}
	if response.GetWifiSetConfig() == nil {
		return errors.New("wifi_set_config: router response missing")
	}
	return nil
}
