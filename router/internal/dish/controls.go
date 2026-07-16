package dish

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	device "github.com/clarkzjw/starlink-grpc-golang/pkg/spacex.com/api/device"

	"starwatch/internal/event"
	"starwatch/internal/history"
)

var ErrInvalidControl = errors.New("invalid control request")

type ControlParams struct {
	Action          string `json:"action"`
	SnowMeltMode    string `json:"snow_melt_mode,omitempty"`
	Enabled         bool   `json:"enabled,omitempty"`
	StartMinutes    uint32 `json:"start_minutes,omitempty"`
	DurationMinutes uint32 `json:"duration_minutes,omitempty"`
}

type ControlResult struct {
	Accepted bool            `json:"accepted"`
	Config   *ConfigReadback `json:"config,omitempty"`
}

type controlAPI interface {
	Reboot(context.Context) error
	DishStow(context.Context, bool) error
	DishSetConfig(context.Context, *device.DishConfig) error
	DishInhibitGPS(context.Context, bool) error
	DishClearObstructionMap(context.Context) error
	SoftwareUpdate(context.Context) error
}

type controlReadback interface {
	RefreshConfig(context.Context) (*ConfigReadback, error)
	InvalidateObstructionMap()
}

type controlEventSink interface {
	AddEvent(history.Event)
}

type ControlOptions struct {
	Now                          func() time.Time
	Events                       controlEventSink
	Live                         event.Publisher
	SuppressDishUnreachableUntil func(time.Time)
	ExpectDishUnreachableUntil   func(time.Time)
}

type Controller struct {
	api      controlAPI
	readback controlReadback
	options  ControlOptions
}

func NewController(api controlAPI, readback controlReadback, options ControlOptions) *Controller {
	if options.Now == nil {
		options.Now = time.Now
	}
	return &Controller{api: api, readback: readback, options: options}
}

func (c *Controller) Execute(ctx context.Context, params ControlParams) (result ControlResult, err error) {
	defer func() { c.audit(params, result, err) }()
	result.Accepted = true
	switch params.Action {
	case "reboot":
		err = c.api.Reboot(ctx)
		if err == nil {
			until := c.options.Now().Add(5 * time.Minute)
			if c.options.SuppressDishUnreachableUntil != nil {
				c.options.SuppressDishUnreachableUntil(until)
			}
			if c.options.ExpectDishUnreachableUntil != nil {
				c.options.ExpectDishUnreachableUntil(until)
			}
		}
	case "stow":
		err = c.api.DishStow(ctx, false)
	case "unstow":
		err = c.api.DishStow(ctx, true)
	case "snow-melt", "snow-melt-mode":
		mode, ok := map[string]device.DishConfig_SnowMeltMode{
			"AUTO": device.DishConfig_AUTO, "ALWAYS_ON": device.DishConfig_ALWAYS_ON, "ALWAYS_OFF": device.DishConfig_ALWAYS_OFF,
		}[params.SnowMeltMode]
		if !ok {
			err = fmt.Errorf("%w: snow_melt_mode must be AUTO, ALWAYS_ON, or ALWAYS_OFF", ErrInvalidControl)
			break
		}
		result.Config, err = c.writeConfig(ctx, &device.DishConfig{SnowMeltMode: mode, ApplySnowMeltMode: true})
	case "sleep-schedule", "sleep":
		if params.StartMinutes >= 24*60 || params.DurationMinutes > 24*60 {
			err = fmt.Errorf("%w: sleep schedule minutes out of range", ErrInvalidControl)
			break
		}
		result.Config, err = c.writeConfig(ctx, &device.DishConfig{
			PowerSaveMode: params.Enabled, ApplyPowerSaveMode: true,
			PowerSaveStartMinutes: params.StartMinutes, ApplyPowerSaveStartMinutes: true,
			PowerSaveDurationMinutes: params.DurationMinutes, ApplyPowerSaveDurationMinutes: true,
		})
	case "gps":
		err = c.api.DishInhibitGPS(ctx, !params.Enabled)
	case "gps-enable":
		err = c.api.DishInhibitGPS(ctx, false)
	case "gps-disable":
		err = c.api.DishInhibitGPS(ctx, true)
	case "clear-obstruction-map":
		err = c.api.DishClearObstructionMap(ctx)
		if err == nil {
			c.readback.InvalidateObstructionMap()
		}
	case "firmware-update", "firmware-update-check", "firmware-update-apply", "software-update":
		err = c.api.SoftwareUpdate(ctx)
	default:
		err = fmt.Errorf("%w: unknown action %q", ErrInvalidControl, params.Action)
	}
	if err != nil {
		result.Accepted = false
	}
	return result, err
}

func (c *Controller) writeConfig(ctx context.Context, config *device.DishConfig) (*ConfigReadback, error) {
	if err := c.api.DishSetConfig(ctx, config); err != nil {
		return nil, err
	}
	return c.readback.RefreshConfig(ctx)
}

func (c *Controller) audit(params ControlParams, result ControlResult, actionErr error) {
	detail := struct {
		Action string        `json:"action"`
		Params ControlParams `json:"params"`
		Result ControlResult `json:"result"`
		Error  string        `json:"error,omitempty"`
	}{Action: params.Action, Params: params, Result: result}
	if actionErr != nil {
		detail.Error = actionErr.Error()
	}
	encoded, _ := json.Marshal(detail)
	at := c.options.Now()
	if c.options.Events != nil {
		c.options.Events.AddEvent(history.Event{At: at, Kind: "control", Detail: string(encoded)})
	}
	if c.options.Live != nil {
		c.options.Live.Publish(event.Message{Kind: "control", At: at, Data: detail})
	}
}
