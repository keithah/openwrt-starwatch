//go:build linux

package wan

import (
	"encoding/json"
	"os/exec"
)

type systemDiscoverer struct{}

func (systemDiscoverer) Discover(dishAddr, override string) (string, error) {
	if override != "" {
		return override, nil
	}
	name, err := DiscoverInterface(DiscoveryOptions{
		DishAddr:  dishAddr,
		RoutePath: "/proc/net/route", SysfsRoot: "/sys/class/net",
	})
	if err != nil || name != "" {
		return name, err
	}
	output, err := exec.Command("ubus", "call", "network.interface.wan", "status").Output()
	if err == nil {
		var status struct {
			L3Device string `json:"l3_device"`
			Device   string `json:"device"`
		}
		if json.Unmarshal(output, &status) == nil {
			if status.L3Device != "" {
				return status.L3Device, nil
			}
			if status.Device != "" {
				return status.Device, nil
			}
		}
	}
	return "", nil
}

func newSystemDiscoverer() Discoverer { return systemDiscoverer{} }
