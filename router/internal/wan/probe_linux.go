//go:build linux

package wan

import (
	"context"
	"fmt"
	"net"
	"os"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"golang.org/x/net/icmp"
	"golang.org/x/net/ipv4"
)

type systemProber struct {
	sequence atomic.Uint32
	lookupIP func(context.Context, string, string) ([]net.IP, error)
}

func newSystemProber() Prober {
	return &systemProber{lookupIP: net.DefaultResolver.LookupIP}
}

func (p *systemProber) Probe(ctx context.Context, interfaceName, host string) (time.Duration, error) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	rtt, err, available := p.icmp(ctx, interfaceName, host)
	if available {
		return rtt, err
	}
	return p.udp(ctx, interfaceName, host)
}

func (p *systemProber) icmp(ctx context.Context, interfaceName, host string) (time.Duration, error, bool) {
	address, err := p.resolveIPv4(ctx, host)
	if err != nil {
		return 0, err, false
	}
	listen := net.ListenConfig{Control: bindControl(interfaceName)}
	connection, err := listen.ListenPacket(ctx, "ip4:icmp", "0.0.0.0")
	if err != nil {
		return 0, err, false
	}
	defer connection.Close()
	sequence := int(p.sequence.Add(1) & 0xffff)
	id := os.Getpid() & 0xffff
	payload, err := (&icmp.Message{Type: ipv4.ICMPTypeEcho, Code: 0, Body: &icmp.Echo{
		ID: id, Seq: sequence, Data: []byte("starwatch"),
	}}).Marshal(nil)
	if err != nil {
		return 0, err, true
	}
	deadline := time.Now().Add(2 * time.Second)
	if contextDeadline, ok := ctx.Deadline(); ok && contextDeadline.Before(deadline) {
		deadline = contextDeadline
	}
	_ = connection.SetDeadline(deadline)
	start := time.Now()
	if _, err := connection.WriteTo(payload, &net.IPAddr{IP: address}); err != nil {
		return 0, err, true
	}
	buffer := make([]byte, 1500)
	for {
		count, _, err := connection.ReadFrom(buffer)
		if err != nil {
			return 0, err, true
		}
		message, err := icmp.ParseMessage(1, buffer[:count])
		if err != nil || message.Type != ipv4.ICMPTypeEchoReply {
			continue
		}
		echo, ok := message.Body.(*icmp.Echo)
		if ok && echo.ID == id && echo.Seq == sequence {
			return time.Since(start), nil, true
		}
	}
}

func (p *systemProber) resolveIPv4(ctx context.Context, host string) (net.IP, error) {
	if address := net.ParseIP(host).To4(); address != nil {
		return address, nil
	}
	lookup := p.lookupIP
	if lookup == nil {
		lookup = net.DefaultResolver.LookupIP
	}
	addresses, err := lookup(ctx, "ip4", host)
	if err != nil {
		return nil, err
	}
	for _, address := range addresses {
		if ipv4 := address.To4(); ipv4 != nil {
			return ipv4, nil
		}
	}
	return nil, fmt.Errorf("resolve %s: no IPv4 address", host)
}

func (p *systemProber) udp(ctx context.Context, interfaceName, host string) (time.Duration, error) {
	dialer := net.Dialer{Control: bindControl(interfaceName)}
	connection, err := dialer.DialContext(ctx, "udp4", net.JoinHostPort(host, "33434"))
	if err != nil {
		return 0, err
	}
	defer connection.Close()
	deadline := time.Now().Add(2 * time.Second)
	if contextDeadline, ok := ctx.Deadline(); ok && contextDeadline.Before(deadline) {
		deadline = contextDeadline
	}
	_ = connection.SetDeadline(deadline)
	start := time.Now()
	if _, err := connection.Write([]byte{0}); err != nil {
		return 0, err
	}
	buffer := make([]byte, 1)
	_, err = connection.Read(buffer)
	if err == nil || strings.Contains(strings.ToLower(err.Error()), "connection refused") {
		return time.Since(start), nil
	}
	return 0, err
}

func bindControl(interfaceName string) func(string, string, syscall.RawConn) error {
	return func(_, _ string, raw syscall.RawConn) error {
		if interfaceName == "" {
			return nil
		}
		var controlErr error
		if err := raw.Control(func(fd uintptr) {
			controlErr = syscall.SetsockoptString(int(fd), syscall.SOL_SOCKET, syscall.SO_BINDTODEVICE, interfaceName)
		}); err != nil {
			return err
		}
		if controlErr != nil {
			return fmt.Errorf("bind to %s: %w", interfaceName, controlErr)
		}
		return nil
	}
}
