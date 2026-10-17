# lima-sandbox: VM の中から Mac 自身（localhost・Mac の IP）と家の LAN に TCP / UDP で届かず、
# インターネットにだけ出られる Lima（limactl）。docker を sandbox 内から使う VM の土台にする。
#
# 素の Lima（vz）の usernet は 2 か所で VM を Mac・LAN に通す。どちらも設定項目が無いのでパッチで塞ぐ:
#   1. pkg/networks/usernet/gvproxy.go の NAT `gatewayIP: "127.0.0.1"`（ハードコード）で、
#      192.168.5.2 / host.lima.internal 宛てが Mac の 127.0.0.1 に届く → NAT の行を消す
#   2. vendor の gvisor-tap-vsock の TCP / UDP forwarder は、VM が指定した宛先に host のプロセスから
#      net.Dial する（除外は 169.254/16 だけ）→ NAT 変換の直後に deny.go の denied() で拒否する
#      （denylist ＋ IPv6 全拒否。インターネットは通す）。deny_test.go を checkPhase で走らせる
# VM 標準の DNS（192.168.5.2）は gvproxy の netstack 内で答えるので forwarder を通らず、影響しない。
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
    fw=vendor/github.com/containers/gvisor-tap-vsock/pkg/services/forwarder
    chmod -R u+w "$fw"
    cp ${./deny.go} "$fw/deny.go"
    cp ${./deny_test.go} "$fw/deny_test.go"
    substituteInPlace "$fw/tcp.go" \
      --replace-fail 'natLock.Unlock()' 'natLock.Unlock()
    		if denied(localAddress) {
    			r.Complete(true)
    			return
    		}'
    substituteInPlace "$fw/udp.go" \
      --replace-fail 'natLock.Unlock()' 'natLock.Unlock()
    		if denied(localAddress) {
    			return
    		}'
  '';

  # 既定の checkPhase は vendor を除くので、forwarder のテストは別に走らせる
  preCheck = (old.preCheck or "") + ''
    go test -count=1 -v ./vendor/github.com/containers/gvisor-tap-vsock/pkg/services/forwarder/
  '';
})
