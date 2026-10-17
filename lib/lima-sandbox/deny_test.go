package forwarder

import (
	"net"
	"testing"

	"gvisor.dev/gvisor/pkg/tcpip"
)

// lib/lima-sandbox/default.nix が build 中の vendor に deny.go と並べて置き、checkPhase で走らせる。
// 各 CIDR の代表アドレスと、境界のすぐ外側の値を並べる
func TestDenied(t *testing.T) {
	// host のインターフェースの IP は表の外の値（TEST-NET-3）に固定する
	interfaceAddrs = func() ([]net.Addr, error) {
		return []net.Addr{&net.IPNet{IP: net.ParseIP("203.0.113.7"), Mask: net.CIDRMask(24, 32)}}, nil
	}
	defer func() { interfaceAddrs = net.InterfaceAddrs }()

	cases := []struct {
		addr string
		want bool
	}{
		{"0.0.0.0", true},
		{"0.255.255.255", true},
		{"1.0.0.0", false},
		{"10.0.0.1", true},
		{"10.255.255.255", true},
		{"9.255.255.255", false},
		{"11.0.0.0", false},
		{"100.64.0.1", true},
		{"100.127.255.255", true},
		{"100.63.255.255", false},
		{"100.128.0.0", false},
		{"127.0.0.1", true},
		{"127.255.255.255", true},
		{"126.255.255.255", false},
		{"128.0.0.0", false},
		{"169.254.169.254", true},
		{"169.253.255.255", false},
		{"169.255.0.0", false},
		{"172.16.0.1", true},
		{"172.31.255.255", true},
		{"172.15.255.255", false},
		{"172.32.0.0", false},
		{"192.0.0.1", true},
		{"192.0.0.255", true},
		{"191.255.255.255", false},
		{"192.0.1.0", false},
		{"192.168.5.2", true},
		{"192.168.255.255", true},
		{"192.167.255.255", false},
		{"192.169.0.0", false},
		{"198.18.0.1", true},
		{"198.19.255.255", true},
		{"198.17.255.255", false},
		{"198.20.0.0", false},
		{"224.0.0.1", true},
		{"239.255.255.255", true},
		{"223.255.255.255", false},
		{"240.0.0.1", true},
		{"255.255.255.255", true},
		{"203.0.113.7", true},
		{"203.0.113.8", false},
		{"1.1.1.1", false},
		{"93.184.215.14", false},
	}
	for _, c := range cases {
		ip := net.ParseIP(c.addr).To4()
		if got := denied(tcpip.AddrFrom4Slice(ip)); got != c.want {
			t.Errorf("denied(%s) = %v, want %v", c.addr, got, c.want)
		}
	}

	for _, addr := range []string{"2606:4700:4700::1111", "::1", "fe80::1", "::ffff:1.1.1.1"} {
		if !denied(tcpip.AddrFrom16Slice(net.ParseIP(addr).To16())) {
			t.Errorf("denied(%s) = false, want true (IPv6 is always denied)", addr)
		}
	}
}
