//go:build linux

package wan

import (
	"context"
	"errors"
	"net"
	"testing"
)

func TestSystemProberResolvesHostnameToIPv4(t *testing.T) {
	prober := &systemProber{lookupIP: func(_ context.Context, network, host string) ([]net.IP, error) {
		if network != "ip4" || host != "probe.example" {
			t.Fatalf("lookup network=%q host=%q", network, host)
		}
		return []net.IP{net.ParseIP("192.0.2.10")}, nil
	}}
	address, err := prober.resolveIPv4(context.Background(), "probe.example")
	if err != nil || !address.Equal(net.ParseIP("192.0.2.10")) {
		t.Fatalf("address=%v err=%v", address, err)
	}
}

func TestSystemProberResolverFailureMakesICMPUnavailable(t *testing.T) {
	prober := &systemProber{lookupIP: func(context.Context, string, string) ([]net.IP, error) {
		return nil, errors.New("temporary DNS failure")
	}}
	_, err, available := prober.icmp(context.Background(), "", "probe.example")
	if err == nil || available {
		t.Fatalf("err=%v available=%v", err, available)
	}
}
