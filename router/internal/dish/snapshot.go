package dish

import (
	"time"

	device "github.com/clarkzjw/starlink-grpc-golang/pkg/spacex.com/api/device"
)

type Topology string

const (
	TopologyFull    Topology = "full"
	TopologyWANOnly Topology = "wan-only"
)

const (
	FieldStatus      = "status"
	FieldObstruction = "obstruction_stats"
	FieldAlignment   = "alignment_stats"
	FieldPower       = "power_w"
	FieldDeviceInfo  = "device_info"
	FieldConfig      = "dish_config"
	FieldHistory     = "history"
)

type Snapshot struct {
	Topology          Topology        `json:"topology"`
	Dish              *Status         `json:"dish,omitempty"`
	DeviceInfo        *DeviceInfo     `json:"device_info,omitempty"`
	Config            *ConfigReadback `json:"config,omitempty"`
	FieldAvailability map[string]bool `json:"field_availability"`
	WAN               WANStatus       `json:"wan"`
}

type WANStatus struct {
	Available bool `json:"available"`
}

type Status struct {
	UpdatedAt             time.Time          `json:"updated_at"`
	UptimeSeconds         uint64             `json:"uptime_seconds"`
	LatencyMS             float32            `json:"latency_ms"`
	DropRate              float32            `json:"drop_rate"`
	DownlinkThroughputBPS float32            `json:"downlink_throughput_bps"`
	UplinkThroughputBPS   float32            `json:"uplink_throughput_bps"`
	PowerW                *float32           `json:"power_w,omitempty"`
	Obstruction           *Obstruction       `json:"obstruction,omitempty"`
	Alignment             *Alignment         `json:"alignment,omitempty"`
	Outage                *device.DishOutage `json:"outage,omitempty"`
	Alerts                *device.DishAlerts `json:"alerts,omitempty"`
	MobilityClass         string             `json:"mobility_class"`
	ClassOfService        string             `json:"class_of_service"`
}

type Obstruction struct {
	CurrentlyObstructed bool    `json:"currently_obstructed"`
	FractionObstructed  float32 `json:"fraction_obstructed"`
	TimeObstructed      float32 `json:"time_obstructed"`
	ValidSeconds        float32 `json:"valid_seconds"`
}

type Alignment struct {
	BoresightAzimuthDeg   float32 `json:"boresight_azimuth_deg"`
	BoresightElevationDeg float32 `json:"boresight_elevation_deg"`
	TiltAngleDeg          float32 `json:"tilt_angle_deg"`
}

type DeviceInfo struct {
	ID              string `json:"id"`
	HardwareVersion string `json:"hardware_version"`
	SoftwareVersion string `json:"software_version"`
	CountryCode     string `json:"country_code"`
}

type ConfigReadback struct {
	SnowMeltMode             string `json:"snow_melt_mode"`
	PowerSaveMode            bool   `json:"power_save_mode"`
	PowerSaveStartMinutes    uint32 `json:"power_save_start_minutes"`
	PowerSaveDurationMinutes uint32 `json:"power_save_duration_minutes"`
	LevelDishMode            string `json:"level_dish_mode"`
	LocationRequestMode      string `json:"location_request_mode"`
	SoftwareUpdateRebootHour uint32 `json:"software_update_reboot_hour"`
	ThreeDayDeferralEnabled  bool   `json:"three_day_deferral_enabled"`
}
