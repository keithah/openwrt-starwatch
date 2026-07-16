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
	HistoryInterval  time.Duration
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

	historyMu    sync.Mutex
	highWater    map[string]time.Time
	backfillDone bool
	historyPower *float32
	statusPower  bool
}

func NewPoller(api API, writer history.Writer, options PollerOptions) *Poller {
	if options.StatusInterval <= 0 {
		options.StatusInterval = time.Second
	}
	if options.MetadataInterval <= 0 {
		options.MetadataInterval = time.Minute
	}
	if options.HistoryInterval <= 0 {
		options.HistoryInterval = time.Hour
	}
	if options.RetryInterval <= 0 {
		options.RetryInterval = time.Minute
	}
	if options.RPCTimeout <= 0 {
		options.RPCTimeout = 2 * time.Second
	}
	if options.Now == nil {
		options.Now = time.Now
	}
	return &Poller{
		api: api, history: writer, options: options,
		snapshot: Snapshot{Topology: TopologyWANOnly, FieldAvailability: make(map[string]bool)},
		failures: make(map[string]int), highWater: make(map[string]time.Time),
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
	result.HistoryOutages = append([]HistoryOutage(nil), p.snapshot.HistoryOutages...)
	if p.snapshot.DishFailureSince != nil {
		failureSince := *p.snapshot.DishFailureSince
		result.DishFailureSince = &failureSince
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
	historyTicker := time.NewTicker(p.options.HistoryInterval)
	retryTicker := time.NewTicker(p.options.RetryInterval)
	defer statusTicker.Stop()
	defer metadataTicker.Stop()
	defer historyTicker.Stop()
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
				if !p.usesStatusPower() {
					p.refreshHistoryPower(ctx)
				}
			}
		case <-historyTicker.C:
			if p.topology() == TopologyFull {
				p.backfill(ctx)
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
		p.markDishFailure(p.options.Now())
		p.failed(FieldDeviceInfo)
		p.mu.Lock()
		if p.snapshot.DeviceInfo == nil || p.failures[FieldDeviceInfo] >= 3 {
			p.snapshot.Topology = TopologyWANOnly
		}
		p.mu.Unlock()
		return false
	}
	p.succeeded(FieldDeviceInfo)
	p.markDishReachable()
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
		p.markDishFailure(p.options.Now())
		p.failed(FieldStatus, FieldObstruction, FieldAlignment, FieldPower)
		p.mu.Lock()
		if p.failures[FieldStatus] >= 3 {
			p.snapshot.Topology = TopologyWANOnly
		}
		p.mu.Unlock()
		return
	}
	p.succeeded(FieldStatus)
	p.markDishReachable()
	now := p.options.Now()
	if now.Year() >= 2025 && p.initialBackfillPending() {
		p.backfill(parent)
	}
	dishStatus := &Status{
		UpdatedAt: now, UptimeSeconds: status.GetDeviceState().GetUptimeS(),
		LatencyMS: status.GetPopPingLatencyMs(), DropRate: status.GetPopPingDropRate(),
		DownlinkThroughputBPS: status.GetDownlinkThroughputBps(), UplinkThroughputBPS: status.GetUplinkThroughputBps(),
		Outage: outageSnapshot(status.GetOutage()), Alerts: alertSnapshot(status.GetAlerts()), MobilityClass: status.GetMobilityClass().String(),
		ClassOfService:      status.GetClassOfService().String(),
		SoftwareUpdateState: status.GetSoftwareUpdateState().String(),
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
		dishStatus.PowerSource = "status"
		p.mu.Lock()
		p.statusPower = true
		p.mu.Unlock()
	} else {
		p.mu.Lock()
		p.statusPower = false
		p.mu.Unlock()
		if fallback := p.powerFallback(); fallback != nil {
			p.succeeded(FieldPower)
			dishStatus.PowerW = fallback
			dishStatus.PowerSource = "history"
		} else {
			p.failed(FieldPower)
		}
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
	now := p.options.Now()
	if now.Year() < 2025 {
		return
	}
	ctx, cancel := p.callContext(parent)
	defer cancel()
	response, err := p.api.GetHistory(ctx)
	if err != nil || response == nil {
		p.failed(FieldHistory)
		return
	}
	p.succeeded(FieldHistory)
	p.setHistoryOutages(response.GetOutages())
	length := maxLength(response)
	valid := min(int(response.GetCurrent()), length)
	if valid > 0 && length > 0 {
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
	p.setBackfillDone()
	if power, ok := newestHistoryValue(response.GetPowerIn(), response.GetCurrent()); ok {
		p.setPowerFallback(power)
	}
}

func (p *Poller) setHistoryOutages(outages []*device.DishOutage) {
	result := make([]HistoryOutage, 0, len(outages))
	for _, item := range outages {
		if item == nil || item.GetStartTimestampNs() == 0 {
			continue
		}
		result = append(result, HistoryOutage{
			Cause: item.GetCause().String(), Start: time.Unix(0, item.GetStartTimestampNs()).UTC(),
			Duration: time.Duration(item.GetDurationNs()),
		})
	}
	p.mu.Lock()
	p.snapshot.HistoryOutages = result
	p.mu.Unlock()
}

func (p *Poller) refreshHistoryPower(parent context.Context) {
	ctx, cancel := p.callContext(parent)
	defer cancel()
	response, err := p.api.GetHistory(ctx)
	if err != nil || response == nil {
		p.failed(FieldHistory)
		return
	}
	p.succeeded(FieldHistory)
	if power, ok := newestHistoryValue(response.GetPowerIn(), response.GetCurrent()); ok {
		p.setPowerFallback(power)
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
	p.historyMu.Lock()
	defer p.historyMu.Unlock()
	if last, ok := p.highWater[series]; ok && !at.After(last) {
		return
	}
	if err := p.history.Append(series, history.Point{Time: at, Value: value}); err == nil {
		p.highWater[series] = at
	}
}

func (p *Poller) initialBackfillPending() bool {
	p.historyMu.Lock()
	defer p.historyMu.Unlock()
	return !p.backfillDone
}

func (p *Poller) setBackfillDone() {
	p.historyMu.Lock()
	p.backfillDone = true
	p.historyMu.Unlock()
}

func (p *Poller) powerFallback() *float32 {
	p.historyMu.Lock()
	defer p.historyMu.Unlock()
	if p.historyPower == nil {
		return nil
	}
	value := *p.historyPower
	return &value
}

func (p *Poller) setPowerFallback(value float32) {
	p.historyMu.Lock()
	p.historyPower = &value
	p.historyMu.Unlock()
	p.succeeded(FieldPower)
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.statusPower || p.snapshot.Dish == nil {
		return
	}
	dishStatus := *p.snapshot.Dish
	dishStatus.PowerW = &value
	dishStatus.PowerSource = "history"
	p.snapshot.Dish = &dishStatus
}

func (p *Poller) usesStatusPower() bool {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return p.statusPower
}

func newestHistoryValue(values []float32, current uint64) (float32, bool) {
	if len(values) == 0 || current == 0 {
		return 0, false
	}
	index := int(current-1) % len(values)
	return values[index], true
}

func outageSnapshot(outage *device.DishOutage) *Outage {
	if outage == nil {
		return nil
	}
	return &Outage{
		Cause: outage.GetCause().String(), StartTimestampNS: outage.GetStartTimestampNs(),
		DurationNS: outage.GetDurationNs(), DidSwitch: outage.GetDidSwitch(),
	}
}

func alertSnapshot(alerts *device.DishAlerts) map[string]bool {
	if alerts == nil {
		return nil
	}
	return map[string]bool{
		"motors_stuck": alerts.GetMotorsStuck(), "thermal_throttle": alerts.GetThermalThrottle(),
		"thermal_shutdown": alerts.GetThermalShutdown(), "mast_not_near_vertical": alerts.GetMastNotNearVertical(),
		"unexpected_location": alerts.GetUnexpectedLocation(), "slow_ethernet_speeds": alerts.GetSlowEthernetSpeeds(),
		"slow_ethernet_speeds_100": alerts.GetSlowEthernetSpeeds_100(), "roaming": alerts.GetRoaming(),
		"install_pending": alerts.GetInstallPending(), "is_heating": alerts.GetIsHeating(),
		"power_supply_thermal_throttle": alerts.GetPowerSupplyThermalThrottle(), "is_power_save_idle": alerts.GetIsPowerSaveIdle(),
		"dbf_telem_stale": alerts.GetDbfTelemStale(), "low_motor_current": alerts.GetLowMotorCurrent(),
		"lower_signal_than_predicted": alerts.GetLowerSignalThanPredicted(), "obstruction_map_reset": alerts.GetObstructionMapReset(),
		"dish_water_detected": alerts.GetDishWaterDetected(), "router_water_detected": alerts.GetRouterWaterDetected(),
		"upsu_router_port_slow": alerts.GetUpsuRouterPortSlow(), "no_ethernet_link": alerts.GetNoEthernetLink(),
	}
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

func (p *Poller) markDishFailure(at time.Time) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.snapshot.DishReachable = false
	if p.snapshot.DishFailureSince == nil {
		atCopy := at
		p.snapshot.DishFailureSince = &atCopy
	}
}

func (p *Poller) markDishReachable() {
	p.mu.Lock()
	p.snapshot.DishReachable = true
	p.snapshot.DishFailureSince = nil
	p.mu.Unlock()
}
