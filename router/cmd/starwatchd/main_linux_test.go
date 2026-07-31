//go:build linux

package main

import (
	"net"
	"testing"

	"golang.org/x/sys/unix"
)

func TestListenTCPDisablesMultipathTCP(t *testing.T) {
	listener, err := listenTCP("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()

	tcpListener, ok := listener.(*net.TCPListener)
	if !ok {
		t.Fatalf("listener type = %T, want *net.TCPListener", listener)
	}
	raw, err := tcpListener.SyscallConn()
	if err != nil {
		t.Fatal(err)
	}
	protocol := -1
	var socketErr error
	if err := raw.Control(func(fd uintptr) {
		protocol, socketErr = unix.GetsockoptInt(int(fd), unix.SOL_SOCKET, unix.SO_PROTOCOL)
	}); err != nil {
		t.Fatal(err)
	}
	if socketErr != nil {
		t.Fatal(socketErr)
	}
	if protocol != unix.IPPROTO_TCP {
		t.Fatalf("socket protocol = %d, want ordinary TCP (%d)", protocol, unix.IPPROTO_TCP)
	}
}
