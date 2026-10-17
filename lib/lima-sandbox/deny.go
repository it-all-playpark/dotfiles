package forwarder

import (
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"

	log "github.com/sirupsen/logrus"
)

// VM から host のプロセス経由で出ていく接続（tcp.go / udp.go の net.Dial）を、ホスト側の許可リスト付き
// プロキシ（home-manager/programs/vm-egress-proxy.nix）への経路を除いてすべて拒否する。
// インターネット・Mac 自身（localhost・Mac の IP）・LAN・IPv6 のどれにも host から net.Dial しない。
// lib/lima-sandbox/default.nix が build 中の vendor にこのファイルを置き、tcp.go の net.Dial を
// dialTCP に差し替え、udp.go の NAT 変換の直後で deniedUDP を呼ぶ。

// VM から見たプロキシの宛先。usernet のゲートウェイ（192.168.5.2。NAT の行を消したので host には
// 届かない）の 3128 番だけを、host の Unix ソケットに繋ぐ。
// home-manager/home/file/sandbox-docker/lima.yaml の param.egressProxy と揃える
const proxyAddress = "192.168.5.2:3128"

// プロキシが待ち受ける Unix ソケット。vm-egress-proxy.nix の socket と揃える。
// sandbox の allowUnixSockets に無いので、Claude Code の sandbox からは直接繋がらない。テストは差し替える
var proxySocket = func() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".local/state/vm-egress-proxy/proxy.sock"), nil
}

var errDenied = errors.New("lima-sandbox: only the egress proxy is reachable from the VM")

// tcp.go の net.Dial("tcp", address) の代わり。address は tcp.go が組み立てる host:port
// （IPv6 は IPv4-mapped も含めて [addr]:port）で、プロキシの宛先と文字列で完全に一致するものだけ通す。
// 拒否すると tcp.go が RST を返すので、VM 側では接続の拒否として見える
func dialTCP(network, address string) (net.Conn, error) {
	if network != "tcp" || address != proxyAddress {
		log.Warnf("lima-sandbox: denied %s to %s (only tcp %s is reachable)", network, address, proxyAddress)
		return nil, fmt.Errorf("%w: %s %s", errDenied, network, address)
	}
	path, err := proxySocket()
	if err != nil {
		return nil, err
	}
	conn, err := net.Dial("unix", path)
	if err != nil {
		log.Warnf("lima-sandbox: egress proxy %s is unreachable: %v", path, err)
	}
	return conn, err
}

// udp.go から呼ぶ。UDP はプロキシを通らないので全部拒否する（VM の DNS は gvproxy の netstack 内で
// 答えるので forwarder を通らない）
func deniedUDP(address string) bool {
	log.Warnf("lima-sandbox: denied udp to %s", address)
	return true
}
