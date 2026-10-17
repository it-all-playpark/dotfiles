# lima-sandbox: VM の中からの外向き通信を、ホスト側の許可リスト付きプロキシ（vm-egress-proxy。
# home-manager/programs/vm-egress-proxy.nix）への 1 経路だけに絞る Lima（limactl）。
# docker を sandbox 内から使う VM の土台にする。インターネット・Mac 自身（localhost・Mac の IP）・LAN の
# どこにも VM から直接は届かない。
#
# 素の Lima（vz）の usernet は 3 か所で VM を外に通す。どれも設定項目が無いのでパッチで塞ぐ:
#   1. pkg/networks/usernet/gvproxy.go の NAT `gatewayIP: "127.0.0.1"`（ハードコード）で、
#      192.168.5.2 / host.lima.internal 宛てが Mac の 127.0.0.1 に届く → NAT の行を消す
#   2. vendor の gvisor-tap-vsock の TCP / UDP forwarder は、VM が指定した宛先に host のプロセスから
#      net.Dial する → deny.go で、TCP は 192.168.5.2:3128 だけを vm-egress-proxy の Unix ソケットに繋ぎ、
#      それ以外（UDP は全部）を拒否する。deny_test.go を checkPhase で走らせる
#   3. vendor の gvisor-tap-vsock の DNS（VM 標準の 192.168.5.2:53。netstack 内で答えるので forwarder を
#      通らない）は、Lima が足す zone 以外を host の resolver に問い合わせる → dns_deny.go で上流に出さない。
#      dns_deny_test.go を checkPhase で走らせる
#
# version・src は nixpkgs の lima に従う。パッチは --replace-fail の文字列置換で当て、上流の該当箇所が
# 変わったら build が落ちる（黙って素の動作に戻らない）。落ちたら上流の差分を見て置換を直す。
{ pkgs }:

pkgs.lima.overrideAttrs (old: {
  postPatch = (old.postPatch or "") + ''
    substituteInPlace pkg/networks/usernet/gvproxy.go \
      --replace-fail 'gatewayIP: "127.0.0.1",' ""
  '';

  # vendor は configurePhase が goModules から写すので、置くのはその後（読み取り専用で写るので u+w）
  postConfigure = (old.postConfigure or "") + ''
    svc=vendor/github.com/containers/gvisor-tap-vsock/pkg/services
    chmod -R u+w "$svc/forwarder" "$svc/dns"
    cp ${./deny.go} "$svc/forwarder/deny.go"
    cp ${./deny_test.go} "$svc/forwarder/deny_test.go"
    cp ${./dns_deny.go} "$svc/dns/dns_deny.go"
    cp ${./dns_deny_test.go} "$svc/dns/dns_deny_test.go"
    substituteInPlace "$svc/forwarder/tcp.go" \
      --replace-fail 'outbound, err := net.Dial("tcp",' 'outbound, err := dialTCP("tcp",'
    substituteInPlace "$svc/forwarder/udp.go" \
      --replace-fail 'natLock.Unlock()' 'natLock.Unlock()
    		if deniedUDP(net.JoinHostPort(localAddress.String(), strconv.Itoa(int(r.ID().LocalPort)))) {
    			return
    		}'
    substituteInPlace "$svc/dns/dns.go" \
      --replace-fail 'resolver := h.upstream' 'if h.refuseUpstream(m, q) {
    			return
    		}
    		resolver := h.upstream'
  '';

  # 既定の checkPhase は vendor を除くので、forwarder と DNS のテストは別に走らせる
  preCheck = (old.preCheck or "") + ''
    go test -count=1 -v \
      ./vendor/github.com/containers/gvisor-tap-vsock/pkg/services/forwarder/ \
      ./vendor/github.com/containers/gvisor-tap-vsock/pkg/services/dns/
  '';
})
