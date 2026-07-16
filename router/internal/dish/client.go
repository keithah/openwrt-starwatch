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
