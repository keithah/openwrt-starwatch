// Package dish talks to the Starlink user terminal's local gRPC API.
package dish

import (
	"context"
	"fmt"

	device "github.com/clarkzjw/starlink-grpc-golang/pkg/spacex.com/api/device"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

type API interface {
	GetStatus(context.Context) (*device.DishGetStatusResponse, error)
	GetDeviceInfo(context.Context) (*device.DeviceInfo, error)
	GetHistory(context.Context) (*device.DishGetHistoryResponse, error)
	DishGetConfig(context.Context) (*device.DishConfig, error)
	GetLocation(context.Context) (*device.GetLocationResponse, error)
	DishGetObstructionMap(context.Context) (*device.DishGetObstructionMapResponse, error)
	Reboot(context.Context) error
	DishStow(context.Context, bool) error
	DishSetConfig(context.Context, *device.DishConfig) error
	DishInhibitGPS(context.Context, bool) error
	DishClearObstructionMap(context.Context) error
	SoftwareUpdate(context.Context) error
	StartSpeedtest(context.Context) error
	GetSpeedtestStatus(context.Context) (*device.SpeedtestStatus, error)
}

func (c *Client) GetLocation(ctx context.Context) (*device.GetLocationResponse, error) {
	response, err := c.device.Handle(ctx, &device.Request{Request: &device.Request_GetLocation{GetLocation: &device.GetLocationRequest{}}})
	if err != nil {
		return nil, err
	}
	if location := response.GetGetLocation(); location != nil && location.GetLla() != nil {
		return location, nil
	}
	return nil, fmt.Errorf("get_location: dish response missing")
}

func (c *Client) DishGetObstructionMap(ctx context.Context) (*device.DishGetObstructionMapResponse, error) {
	response, err := c.device.Handle(ctx, &device.Request{Request: &device.Request_DishGetObstructionMap{DishGetObstructionMap: &device.DishGetObstructionMapRequest{}}})
	if err != nil {
		return nil, err
	}
	if obstructionMap := response.GetDishGetObstructionMap(); obstructionMap != nil {
		return obstructionMap, nil
	}
	return nil, fmt.Errorf("dish_get_obstruction_map: dish response missing")
}

func (c *Client) Reboot(ctx context.Context) error {
	response, err := c.device.Handle(ctx, &device.Request{Request: &device.Request_Reboot{Reboot: &device.RebootRequest{}}})
	if err != nil {
		return err
	}
	if response.GetReboot() == nil {
		return fmt.Errorf("reboot: dish response missing")
	}
	return nil
}

func (c *Client) DishStow(ctx context.Context, unstow bool) error {
	response, err := c.device.Handle(ctx, &device.Request{Request: &device.Request_DishStow{DishStow: &device.DishStowRequest{Unstow: unstow}}})
	if err != nil {
		return err
	}
	if response.GetDishStow() == nil {
		return fmt.Errorf("dish_stow: dish response missing")
	}
	return nil
}

func (c *Client) DishSetConfig(ctx context.Context, config *device.DishConfig) error {
	response, err := c.device.Handle(ctx, &device.Request{Request: &device.Request_DishSetConfig{DishSetConfig: &device.DishSetConfigRequest{DishConfig: config}}})
	if err != nil {
		return err
	}
	if response.GetDishSetConfig() == nil {
		return fmt.Errorf("dish_set_config: dish response missing")
	}
	return nil
}

func (c *Client) DishInhibitGPS(ctx context.Context, inhibit bool) error {
	response, err := c.device.Handle(ctx, &device.Request{Request: &device.Request_DishInhibitGps{DishInhibitGps: &device.DishInhibitGpsRequest{InhibitGps: inhibit}}})
	if err != nil {
		return err
	}
	if response.GetDishInhibitGps() == nil {
		return fmt.Errorf("dish_inhibit_gps: dish response missing")
	}
	return nil
}

func (c *Client) DishClearObstructionMap(ctx context.Context) error {
	response, err := c.device.Handle(ctx, &device.Request{Request: &device.Request_DishClearObstructionMap{DishClearObstructionMap: &device.DishClearObstructionMapRequest{}}})
	if err != nil {
		return err
	}
	if response.GetDishClearObstructionMap() == nil {
		return fmt.Errorf("dish_clear_obstruction_map: dish response missing")
	}
	return nil
}

func (c *Client) SoftwareUpdate(ctx context.Context) error {
	response, err := c.device.Handle(ctx, &device.Request{Request: &device.Request_SoftwareUpdate{SoftwareUpdate: &device.SoftwareUpdateRequest{}}})
	if err != nil {
		return err
	}
	if response.GetSoftwareUpdate() == nil {
		return fmt.Errorf("software_update: dish response missing")
	}
	return nil
}

func (c *Client) StartSpeedtest(ctx context.Context) error {
	response, err := c.device.Handle(ctx, &device.Request{Request: &device.Request_StartSpeedtest{StartSpeedtest: &device.StartSpeedtestRequest{DurationS: 15}}})
	if err != nil {
		return err
	}
	if response.GetStartSpeedtest() == nil {
		return fmt.Errorf("start_speedtest: dish response missing")
	}
	return nil
}

func (c *Client) GetSpeedtestStatus(ctx context.Context) (*device.SpeedtestStatus, error) {
	response, err := c.device.Handle(ctx, &device.Request{Request: &device.Request_GetSpeedtestStatus{GetSpeedtestStatus: &device.GetSpeedtestStatusRequest{}}})
	if err != nil {
		return nil, err
	}
	if status := response.GetGetSpeedtestStatus().GetStatus(); status != nil {
		return status, nil
	}
	return nil, fmt.Errorf("get_speedtest_status: dish response missing")
}

type Client struct {
	connection *grpc.ClientConn
	device     device.DeviceClient
}

func Dial(ctx context.Context, address string) (*Client, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	connection, err := grpc.NewClient(address, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return nil, err
	}
	return &Client{connection: connection, device: device.NewDeviceClient(connection)}, nil
}

func (c *Client) Close() error {
	return c.connection.Close()
}

func (c *Client) GetStatus(ctx context.Context) (*device.DishGetStatusResponse, error) {
	response, err := c.device.Handle(ctx, &device.Request{Request: &device.Request_GetStatus{GetStatus: &device.GetStatusRequest{}}})
	if err != nil {
		return nil, err
	}
	if status := response.GetDishGetStatus(); status != nil {
		return status, nil
	}
	return nil, fmt.Errorf("get_status: dish response missing")
}

func (c *Client) GetDeviceInfo(ctx context.Context) (*device.DeviceInfo, error) {
	response, err := c.device.Handle(ctx, &device.Request{Request: &device.Request_GetDeviceInfo{GetDeviceInfo: &device.GetDeviceInfoRequest{}}})
	if err != nil {
		return nil, err
	}
	if info := response.GetGetDeviceInfo().GetDeviceInfo(); info != nil {
		return info, nil
	}
	return nil, fmt.Errorf("get_device_info: dish response missing")
}

func (c *Client) GetHistory(ctx context.Context) (*device.DishGetHistoryResponse, error) {
	response, err := c.device.Handle(ctx, &device.Request{Request: &device.Request_GetHistory{GetHistory: &device.GetHistoryRequest{}}})
	if err != nil {
		return nil, err
	}
	if history := response.GetDishGetHistory(); history != nil {
		return history, nil
	}
	return nil, fmt.Errorf("get_history: dish response missing")
}

func (c *Client) DishGetConfig(ctx context.Context) (*device.DishConfig, error) {
	response, err := c.device.Handle(ctx, &device.Request{Request: &device.Request_DishGetConfig{DishGetConfig: &device.DishGetConfigRequest{}}})
	if err != nil {
		return nil, err
	}
	if config := response.GetDishGetConfig().GetDishConfig(); config != nil {
		return config, nil
	}
	return nil, fmt.Errorf("dish_get_config: dish response missing")
}
