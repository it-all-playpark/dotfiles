package dns

import (
	"context"
	"errors"
	"net"
	"testing"

	"github.com/containers/gvisor-tap-vsock/pkg/types"
	"github.com/miekg/dns"
)

// lib/lima-sandbox/default.nix が build 中の vendor に dns_deny.go と並べて置き、checkPhase で走らせる。
// 上流の resolver を、呼ばれたら記録するだけの偽物に差し替えて addAnswers を呼ぶ

type recordingResolver struct{ calls []string }

func (r *recordingResolver) record(name string) error {
	r.calls = append(r.calls, name)
	return errors.New("the upstream resolver must not be called")
}

func (r *recordingResolver) LookupIPAddr(_ context.Context, host string) ([]net.IPAddr, error) {
	return nil, r.record(host)
}

func (r *recordingResolver) LookupCNAME(_ context.Context, host string) (string, error) {
	return "", r.record(host)
}

func (r *recordingResolver) LookupMX(_ context.Context, name string) ([]*net.MX, error) {
	return nil, r.record(name)
}

func (r *recordingResolver) LookupNS(_ context.Context, name string) ([]*net.NS, error) {
	return nil, r.record(name)
}

func (r *recordingResolver) LookupSRV(_ context.Context, _, _, name string) (string, []*net.SRV, error) {
	return "", nil, r.record(name)
}

func (r *recordingResolver) LookupTXT(_ context.Context, name string) ([]string, error) {
	return nil, r.record(name)
}

func TestOnlyInternalNamesAreAnswered(t *testing.T) {
	// Lima（pkg/networks/usernet/client.go の AddDNSHosts）が足すのと同じ zone
	zones := []types.Zone{{
		Name: "internal.",
		Records: []types.Record{
			{Name: "host.lima", IP: net.ParseIP("192.168.5.2")},
			{Name: "lima-sandbox-docker", IP: net.ParseIP("192.168.5.15")},
		},
	}}

	cases := []struct {
		name   string
		qtype  uint16
		rcode  int
		answer string
	}{
		{"host.lima.internal.", dns.TypeA, dns.RcodeSuccess, "192.168.5.2"},
		{"lima-sandbox-docker.internal.", dns.TypeA, dns.RcodeSuccess, "192.168.5.15"},
		// zone 内の名前でも A 以外（TXT 等）は、素の dns.go では上流に回る。答えなし（NOERROR）にする
		{"host.lima.internal.", dns.TypeAAAA, dns.RcodeSuccess, ""},
		{"host.lima.internal.", dns.TypeTXT, dns.RcodeSuccess, ""},
		{"c2VjcmV0.lima.internal.", dns.TypeTXT, dns.RcodeSuccess, ""},
		{"unknown.internal.", dns.TypeA, dns.RcodeNameError, ""},
		{"example.com.", dns.TypeA, dns.RcodeNameError, ""},
		{"example.com.", dns.TypeAAAA, dns.RcodeNameError, ""},
		{"registry.npmjs.org.", dns.TypeA, dns.RcodeNameError, ""},
		{"c2VjcmV0.attacker.example.", dns.TypeTXT, dns.RcodeNameError, ""},
		{"attacker.example.", dns.TypeMX, dns.RcodeNameError, ""},
		{"attacker.example.", dns.TypeNS, dns.RcodeNameError, ""},
		{"attacker.example.", dns.TypeCNAME, dns.RcodeNameError, ""},
		{"_x._tcp.attacker.example.", dns.TypeSRV, dns.RcodeNameError, ""},
	}
	for _, c := range cases {
		upstream := &recordingResolver{}
		h := &dnsHandler{zones: zones, upstream: upstream}
		m := new(dns.Msg)
		m.SetQuestion(c.name, c.qtype)
		h.addAnswers(m)

		if len(upstream.calls) != 0 {
			t.Errorf("%s %s: upstream resolver was called with %v", c.name, dns.TypeToString[c.qtype], upstream.calls)
		}
		if m.Rcode != c.rcode {
			t.Errorf("%s %s: rcode = %s, want %s", c.name, dns.TypeToString[c.qtype], dns.RcodeToString[m.Rcode], dns.RcodeToString[c.rcode])
		}
		got := ""
		if len(m.Answer) == 1 {
			if a, ok := m.Answer[0].(*dns.A); ok {
				got = a.A.String()
			}
		}
		if got != c.answer || len(m.Answer) > 1 {
			t.Errorf("%s %s: answer = %v, want %q", c.name, dns.TypeToString[c.qtype], m.Answer, c.answer)
		}
	}
}
