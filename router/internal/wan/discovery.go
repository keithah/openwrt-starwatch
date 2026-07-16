package wan

import (
	"bufio"
	"encoding/binary"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

type DiscoveryOptions struct {
	DishAddr  string
	Override  string
	RoutePath string
	SysfsRoot string
}

type Discoverer interface {
	Discover(dishAddr, override string) (string, error)
}

func DiscoverInterface(options DiscoveryOptions) (string, error) {
	host, _, err := net.SplitHostPort(options.DishAddr)
	if err != nil {
		host = options.DishAddr
	}
	if ip := net.ParseIP(host).To4(); ip != nil {
		if name := routeInterface(options.RoutePath, binary.BigEndian.Uint32(ip)); name != "" {
			return name, nil
		}
	}
	if _, err := os.Stat(filepath.Join(options.SysfsRoot, "wan")); err == nil {
		return "wan", nil
	}
	return options.Override, nil
}

func routeInterface(path string, address uint32) string {
	file, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer file.Close()
	bestName, bestBits := "", -1
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 8 || fields[0] == "Iface" {
			continue
		}
		destination, okDestination := routeHex(fields[1])
		mask, okMask := routeHex(fields[7])
		if !okDestination || !okMask || address&mask != destination {
			continue
		}
		bits := 0
		for value := mask; value != 0; value &= value - 1 {
			bits++
		}
		if bits > bestBits {
			bestName, bestBits = fields[0], bits
		}
	}
	return bestName
}

func routeHex(value string) (uint32, bool) {
	parsed, err := strconv.ParseUint(value, 16, 32)
	if err != nil {
		return 0, false
	}
	number := uint32(parsed)
	return number>>24 | number>>8&0x0000ff00 | number<<8&0x00ff0000 | number<<24, true
}
