package forwarder

import (
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"gvisor.dev/gvisor/pkg/tcpip"
)

// lib/lima-sandbox/default.nix が build 中の vendor に deny.go と並べて置き、checkPhase で走らせる。
// 宛先は tcp.go / udp.go と同じ形（tcpip.Address の String と port の JoinHostPort）で組み立てる

func tcpAddress(a tcpip.Address, port uint16) string {
	return net.JoinHostPort(a.String(), fmt.Sprint(port))
}

func udpAddress(a tcpip.Address, port uint16) string {
	return net.JoinHostPort(a.String(), strconv.Itoa(int(port)))
}

func v4(s string) tcpip.Address { return tcpip.AddrFrom4Slice(net.ParseIP(s).To4()) }

func v6(s string) tcpip.Address { return tcpip.AddrFrom16Slice(net.ParseIP(s).To16()) }

// プロキシの代わりに一時ディレクトリの Unix ソケットで待ち受け、proxySocket をそこに向ける
func listenProxy(t *testing.T) net.Listener {
	t.Helper()
	dir, err := os.MkdirTemp("", "lsb")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	path := filepath.Join(dir, "proxy.sock")
	ln, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			c.Write([]byte("proxy"))
			c.Close()
		}
	}()
	orig := proxySocket
	proxySocket = func() (string, error) { return path, nil }
	t.Cleanup(func() { proxySocket = orig })
	return ln
}

func TestDialTCPReachesOnlyTheProxy(t *testing.T) {
	listenProxy(t)

	conn, err := dialTCP("tcp", tcpAddress(v4("192.168.5.2"), 3128))
	if err != nil {
		t.Fatalf("dialTCP(192.168.5.2:3128) = %v, want the proxy socket", err)
	}
	buf := make([]byte, 5)
	if _, err := conn.Read(buf); err != nil || string(buf) != "proxy" {
		t.Errorf("read from the proxy route = %q, %v", buf, err)
	}
	conn.Close()

	denied := []struct {
		what string
		addr string
	}{
		{"internet", tcpAddress(v4("93.184.215.14"), 443)},
		{"internet", tcpAddress(v4("1.1.1.1"), 80)},
		{"internet on the proxy port", tcpAddress(v4("1.1.1.1"), 3128)},
		{"Mac (loopback)", tcpAddress(v4("127.0.0.1"), 3128)},
		{"Mac (loopback)", tcpAddress(v4("127.0.0.1"), 22)},
		{"Mac (gateway, other port)", tcpAddress(v4("192.168.5.2"), 22)},
		{"Mac (gateway, other port)", tcpAddress(v4("192.168.5.2"), 3129)},
		{"Mac (gateway, other port)", tcpAddress(v4("192.168.5.2"), 80)},
		{"Mac (interface IP)", tcpAddress(v4("203.0.113.7"), 3128)},
		{"LAN", tcpAddress(v4("192.168.1.1"), 80)},
		{"LAN", tcpAddress(v4("10.0.0.1"), 443)},
		{"LAN", tcpAddress(v4("172.16.0.1"), 443)},
		{"CGNAT (Tailscale)", tcpAddress(v4("100.64.0.1"), 443)},
		{"link-local (metadata)", tcpAddress(v4("169.254.169.254"), 80)},
		{"OrbStack", tcpAddress(v4("198.18.0.1"), 443)},
		{"IPv6", tcpAddress(v6("2606:4700:4700::1111"), 443)},
		{"IPv6 loopback", tcpAddress(v6("::1"), 3128)},
		{"IPv6 link-local", tcpAddress(v6("fe80::1"), 3128)},
		{"IPv4-mapped proxy address", tcpAddress(v6("::ffff:192.168.5.2"), 3128)},
	}
	for _, c := range denied {
		conn, err := dialTCP("tcp", c.addr)
		if err == nil {
			conn.Close()
			t.Errorf("dialTCP(%s) [%s] succeeded, want denied", c.addr, c.what)
		} else if !errors.Is(err, errDenied) {
			t.Errorf("dialTCP(%s) [%s] = %v, want errDenied", c.addr, c.what, err)
		}
	}

	// tcp.go は "tcp" でしか呼ばないが、ほかの network ではプロキシの宛先でも通さない
	if conn, err := dialTCP("udp", tcpAddress(v4("192.168.5.2"), 3128)); err == nil {
		conn.Close()
		t.Errorf("dialTCP(udp, 192.168.5.2:3128) succeeded, want denied")
	}
}

func TestDialTCPFailsWhenTheProxyIsDown(t *testing.T) {
	ln := listenProxy(t)
	ln.Close()
	if conn, err := dialTCP("tcp", tcpAddress(v4("192.168.5.2"), 3128)); err == nil {
		conn.Close()
		t.Errorf("dialTCP to a closed proxy socket succeeded")
	}
}

func TestDeniedUDP(t *testing.T) {
	for _, addr := range []string{
		udpAddress(v4("1.1.1.1"), 53),
		udpAddress(v4("8.8.8.8"), 443),
		udpAddress(v4("192.168.5.2"), 3128),
		udpAddress(v4("192.168.5.2"), 53),
		udpAddress(v4("127.0.0.1"), 53),
		udpAddress(v4("192.168.1.1"), 123),
		udpAddress(v6("2606:4700:4700::1111"), 53),
	} {
		if !deniedUDP(addr) {
			t.Errorf("deniedUDP(%s) = false, want true", addr)
		}
	}
}
