package dns

import (
	"fmt"
	"strings"

	"github.com/miekg/dns"
)

// VM の DNS（gvproxy の内蔵 DNS。192.168.5.2:53）が、VM 内部用の名前（Lima が足す zone。
// host.lima.internal・lima-<instance>.internal 等）以外を host の resolver に問い合わせないようにする。
// 問い合わせ自体が持ち出しの経路になる（<data>.attacker.example の TXT 等）ので、上流には一切出さない。
// VM からの外向きの HTTP(S) は許可リスト付きプロキシが名前を解決するので、VM 側で外の名前は要らない。
// lib/lima-sandbox/default.nix が build 中の vendor にこのファイルを置き、dns.go の addAnswers で
// zone の A レコードで答えられなかった問い合わせを upstream に渡す手前で呼ぶ。常に true（upstream に渡さない）。
//
// zone の外の名前は、dns.go が上流の lookup に失敗したときと同じ NXDOMAIN（VM 側では名前の解決の失敗として
// 見える）。zone の中の名前の A 以外（AAAA 等）は、素の dns.go の AAAA と同じく答えなし（NOERROR）にする。
// （NXDOMAIN は「その名前にはどの型のレコードも無い」の意味なので、A のある名前には返さない）
func (h *dnsHandler) refuseUpstream(m *dns.Msg, q dns.Question) bool {
	h.zonesLock.RLock()
	defer h.zonesLock.RUnlock()
	for _, zone := range h.zones {
		if strings.HasSuffix(q.Name, fmt.Sprintf(".%s", zone.Name)) {
			return true
		}
	}
	m.Rcode = dns.RcodeNameError
	return true
}
