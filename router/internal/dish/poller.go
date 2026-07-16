package dish

import (
	"context"
	"sync"
	"time"

	device "github.com/clarkzjw/starlink-grpc-golang/pkg/spacex.com/api/device"

	"starwatch/internal/history"
)

type PollerOptions struct {
	StatusInterval   time.Duration
	MetadataInterval time.Duration
	RetryInterval    time.Duration
	RPCTimeout       time.Duration
	Now              func() time.Time
}

type Poller struct {
	api     API
	history history.Writer
	options PollerOptions

	mu       sync.RWMutex
	snapshot Snapshot
	failures map[string]int
}

func NewPoller(api API, writer history.Writer, options PollerOptions) *Poller {
	if options.StatusInterval <= 0 {
		options.StatusInterval = time.Second
	}
	if options.MetadataInterval <= 0 {
		options.MetadataInterval = time.Minute
	}
	if options.RetryInterval <= 0 {
		options.RetryInterval = time.Minute
	}
	if options.RPCTimeout <= 0 {
		options.RPCTimeout = 5 * time.Second
	}
	if options.Now == nil {
		options.Now = time.Now
	}
	return &Poller{
		api: api, history: writer, options: options,
		snapshot: Snapshot{Topology: TopologyWANOnly, FieldAvailability: make(map[string]bool)},
		failures: make(map[string]int),
	}
}

func (p *Poller) Snapshot() Snapshot {
	p.mu.RLock()
	defer p.mu.RUnlock()
	result := p.snapshot
	result.FieldAvailability = make(map[string]bool, len(p.snapshot.FieldAvailability))
	for field, available := range p.snapshot.FieldAvailability {
		result.FieldAvailability[field] = available
	}
	return result
}

func (p *Poller) Run(ctx context.Context) {
	if p.discover(ctx) {
		p.backfill(ctx)
		p.pollStatus(ctx)
		p.pollConfig(ctx)
	}
	statusTicker := time.NewTicker(p.options.StatusInterval)
	metadataTicker := time.NewTicker(p.options.MetadataInterval)
	retryTicker := time.NewTicker(p.options.RetryInterval)
	defer statusTicker.Stop()
	defer metadataTicker.Stop()
	defer retryTicker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-statusTicker.C:
			if p.topology() == TopologyFull {
				p.pollStatus(ctx)
			}
		case <-metadataTicker.C:
			if p.topology() == TopologyFull {
				p.discover(ctx)
				p.pollConfig(ctx)
			}
		case <-retryTicker.C:
			if p.topology() == TopologyWANOnly && p.discover(ctx) {
				p.backfill(ctx)
				p.pollStatus(ctx)
				p.pollConfig(ctx)
			}
		}
	}
}

func (p *Poller) topology() Topology {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return p.snapshot.Topology
}

func (p *Poller) callContext(parent context.Context) (context.Context, context.CancelFunc) {
	return context.WithTimeout(parent, p.options.RPCTimeout)
}

func (p *Poller) discover(parent context.Context) bool {
	ctx, cancel := p.callContext(parent)
	defer cancel()
	info, err := p.api.GetDeviceInfo(ctx)
	if err != nil || info == nil {
		p.failed(FieldDeviceInfo)
		p.mu.Lock()
		if p.snapshot.DeviceInfo == nil || p.failures[FieldDeviceInfo] >= 3 {
			p.snapshot.Topology = TopologyWANOnly
		}
		p.mu.Unlock()
		return false
	}
	p.succeeded(FieldDeviceInfo)
	p.mu.Lock()
	p.snapshot.Topology = TopologyFull
	p.snapshot.DeviceInfo = &DeviceInfo{
		ID: info.GetId(), HardwareVersion: info.GetHardwareVersion(),
		SoftwareVersion: info.GetSoftwareVersion(), CountryCode: info.GetCountryCode(),
	}
	p.mu.Unlock()
	return true
}

func (p *Poller) pollStatus(parent context.Context) {
	ctx, cancel := p.callContext(parent)
	defer cancel()
	status, err := p.api.GetStatus(ctx)
	if err != nil || status == nil {
		p.failed(FieldStatus, FieldObstruction, FieldAlignment, FieldPower)
		p.mu.Lock()
		if p.failures[FieldStatus] >= 3 {
			p.snapshot.Topology = TopologyWANOnly
		}
		p.mu.Unlock()
		return
	}
	p.succeeded(FieldStatus)
	now := p.options.Now()
	dishStatus := &Status{
		UpdatedAt: now, UptimeSeconds: status.GetDeviceState().GetUptimeS(),
		LatencyMS: status.GetPopPingLatencyMs(), DropRate: status.GetPopPingDropRate(),
		DownlinkThroughputBPS: status.GetDownlinkThroughputBps(), UplinkThroughputBPS: status.GetUplinkThroughputBps(),
		Outage: status.GetOutage(), Alerts: status.GetAlerts(), MobilityClass: status.GetMobilityClass().String(),
		ClassOfService: status.GetClassOfService().String(),
	}
	if obstruction := status.GetObstructionStats(); obstruction != nil {
		p.succeeded(FieldObstruction)
		dishStatus.Obstruction = &Obstruction{
			CurrentlyObstructed: obstruction.GetCurrentlyObstructed(), FractionObstructed: obstruction.GetFractionObstructed(),
			TimeObstructed: obstruction.GetTimeObstructed(), ValidSeconds: obstruction.GetValidS(),
		}
	} else {
		p.failed(FieldObstruction)
	}
	if alignment := status.GetAlignmentStats(); alignment != nil {
		p.succeeded(FieldAlignment)
		dishStatus.Alignment = &Alignment{
			BoresightAzimuthDeg: status.GetBoresightAzimuthDeg(), BoresightElevationDeg: status.GetBoresightElevationDeg(),
			TiltAngleDeg: alignment.GetTiltAngleDeg(),
		}
	} else {
		p.failed(FieldAlignment)
	}
	if power := status.GetUpsuStats(); power != nil {
		p.succeeded(FieldPower)
		value := power.GetDishPower()
		dishStatus.PowerW = &value
	} else {
		p.failed(FieldPower)
	}
	p.mu.Lock()
	p.snapshot.Dish = dishStatus
	p.snapshot.Topology = TopologyFull
	p.mu.Unlock()

	if now.Year() >= 2025 {
		p.append(history.LatencyMS, now, status.GetPopPingLatencyMs())
		p.append(history.DropRate, now, status.GetPopPingDropRate())
		p.append(history.DishDownBPS, now, status.GetDownlinkThroughputBps())
		p.append(history.DishUpBPS, now, status.GetUplinkThroughputBps())
		if dishStatus.Obstruction != nil {
			p.append(history.ObstructionFraction, now, dishStatus.Obstruction.FractionObstructed)
		}
		if dishStatus.PowerW != nil {
			p.append(history.PowerW, now, *dishStatus.PowerW)
		}
	}
}

func (p *Poller) pollConfig(parent context.Context) {
	ctx, cancel := p.callContext(parent)
	defer cancel()
	config, err := p.api.DishGetConfig(ctx)
	if err != nil || config == nil {
		p.failed(FieldConfig)
		return
	}
	p.succeeded(FieldConfig)
	p.mu.Lock()
	p.snapshot.Config = &ConfigReadback{
		SnowMeltMode: config.GetSnowMeltMode().String(), PowerSaveMode: config.GetPowerSaveMode(),
		PowerSaveStartMinutes: config.GetPowerSaveStartMinutes(), PowerSaveDurationMinutes: config.GetPowerSaveDurationMinutes(),
		LevelDishMode: config.GetLevelDishMode().String(), LocationRequestMode: config.GetLocationRequestMode().String(),
		SoftwareUpdateRebootHour: config.GetSwupdateRebootHour(), ThreeDayDeferralEnabled: config.GetSwupdateThreeDayDeferralEnabled(),
	}
	p.mu.Unlock()
}

func (p *Poller) backfill(parent context.Context) {
	ctx, cancel := p.callContext(parent)
	defer cancel()
	response, err := p.api.GetHistory(ctx)
	if err != nil || response == nil {
		p.failed(FieldHistory)
		return
	}
	p.succeeded(FieldHistory)
	now := p.options.Now()
	if now.Year() < 2025 {
		return
	}
	length := maxLength(response)
	valid := min(int(response.GetCurrent()), length)
	if valid == 0 || length == 0 {
		return
	}
	start := 0
	if response.GetCurrent() >= uint64(length) {
		start = int(response.GetCurrent() % uint64(length))
	}
	for offset := 0; offset < valid; offset++ {
		index := (start + offset) % length
		at := now.Add(-time.Duration(valid-1-offset) * time.Second)
		p.appendIndex(history.LatencyMS, at, response.GetPopPingLatencyMs(), index)
		p.appendIndex(history.DropRate, at, response.GetPopPingDropRate(), index)
		p.appendIndex(history.DishDownBPS, at, response.GetDownlinkThroughputBps(), index)
		p.appendIndex(history.DishUpBPS, at, response.GetUplinkThroughputBps(), index)
		p.appendIndex(history.PowerW, at, response.GetPowerIn(), index)
	}
}

func maxLength(response *device.DishGetHistoryResponse) int {
	result := 0
	for _, length := range []int{
		len(response.GetPopPingLatencyMs()), len(response.GetPopPingDropRate()),
		len(response.GetDownlinkThroughputBps()), len(response.GetUplinkThroughputBps()), len(response.GetPowerIn()),
	} {
		if length > result {
			result = length
		}
	}
	return result
}

func (p *Poller) appendIndex(series string, at time.Time, values []float32, index int) {
	if index < len(values) {
		p.append(series, at, values[index])
	}
}

func (p *Poller) append(series string, at time.Time, value float32) {
	_ = p.history.Append(series, history.Point{Time: at, Value: value})
}

func (p *Poller) succeeded(fields ...string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, field := range fields {
		p.failures[field] = 0
		p.snapshot.FieldAvailability[field] = true
	}
}

func (p *Poller) failed(fields ...string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, field := range fields {
		p.failures[field]++
		if p.failures[field] >= 3 {
			p.snapshot.FieldAvailability[field] = false
		}
	}
}
