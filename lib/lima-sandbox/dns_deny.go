package dns

import (
	"github.com/miekg/dns"
)

// VM の DNS（gvproxy の内蔵 DNS。192.168.5.2:53）が、VM 内部用の名前（Lima が足す zone。
// host.lima.internal・lima-<instance>.internal 等）以外を host の resolver に問い合わせないようにする。
// 問い合わせ自体が持ち出しの経路になる（<data>.attacker.example の TXT 等）ので、上流には一切出さない。
// VM からの外向きの HTTP(S) は許可リスト付きプロキシが名前を解決するので、VM 側で外の名前は要らない。
// lib/lima-sandbox/default.nix が build 中の vendor にこのファイルを置き、dns.go の addAnswers で
// upstream に渡す手前で呼ぶ。常に true（upstream に渡さない）。
//
// zone の中の名前は手前の addLocalAnswers が答え切る（無い名前は NXDOMAIN、A 以外は答えなし）ので、
// ここに来るのは zone の外の名前だけ。dns.go が上流の lookup に失敗したときと同じ NXDOMAIN を返す
// （VM 側では名前の解決の失敗として見える）
func (h *dnsHandler) refuseUpstream(m *dns.Msg, _ dns.Question) bool {
	m.Rcode = dns.RcodeNameError
	return true
}
