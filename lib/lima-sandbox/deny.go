package forwarder

import (
	"net"

	"gvisor.dev/gvisor/pkg/tcpip"
)

// VM から host のプロセス経由で出ていく接続（tcp.go / udp.go の net.Dial）のうち、
// Mac 自身と LAN に向かうものを拒否する。インターネットだけを通す。
// lib/lima-sandbox/default.nix が build 中の vendor にこのファイルを置き、NAT 変換の直後で呼ぶ。
var deniedNets = func() []*net.IPNet {
	var nets []*net.IPNet
	for _, c := range []string{
		"0.0.0.0/8",      // this network
		"10.0.0.0/8",     // RFC1918
		"100.64.0.0/10",  // CGNAT（Tailscale 等）
		"127.0.0.0/8",    // loopback
		"169.254.0.0/16", // link-local
		"172.16.0.0/12",  // RFC1918
		"192.0.0.0/24",   // IETF protocol assignments
		"192.168.0.0/16", // RFC1918
		"198.18.0.0/15",  // benchmarking（OrbStack の VM ネットワーク）
		"224.0.0.0/4",    // multicast
		"240.0.0.0/4",    // reserved + broadcast
	} {
		_, n, err := net.ParseCIDR(c)
		if err != nil {
			panic(err)
		}
		nets = append(nets, n)
	}
	return nets
}()

// host のインターフェースの IP（グローバル IP を直に持つ回線でも Mac 自身に届かせない）。
// DHCP で変わるので接続のたびに読む。テストは差し替える
var interfaceAddrs = net.InterfaceAddrs

func denied(a tcpip.Address) bool {
	// IPv6（IPv4-mapped を含む 16 byte のアドレス）は全部拒否する
	if a.Len() != 4 {
		return true
	}
	ip := net.IP(a.AsSlice())
	for _, n := range deniedNets {
		if n.Contains(ip) {
			return true
		}
	}
	addrs, err := interfaceAddrs()
	if err != nil {
		return true
	}
	for _, addr := range addrs {
		if n, ok := addr.(*net.IPNet); ok && n.IP.Equal(ip) {
			return true
		}
	}
	return false
}
