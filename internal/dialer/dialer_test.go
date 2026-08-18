package dialer

import (
	"context"
	"errors"
	"net/http"
	"testing"
)

// fakeResolver returns fixed address lists; used to exercise pin() without
// touching the network.
func fakeResolver(addrs ...string) Resolver {
	return func(ctx context.Context, host string) ([]string, error) {
		return addrs, nil
	}
}

func TestPinValid(t *testing.T) {
	d := NewPinnedDialer(fakeResolver("93.184.216.34", "2a02:26f0:9000::1"))
	ip, err := d.pin(context.Background(), "cdn.islamic.app")
	if err != nil {
		t.Fatalf("pin: %v", err)
	}
	if ip != "93.184.216.34" {
		t.Errorf("pin = %q, want IPv4 first", ip)
	}
}

func TestPinIPv6Only(t *testing.T) {
	d := NewPinnedDialer(fakeResolver("2a02:26f0:9000::1"))
	ip, err := d.pin(context.Background(), "cdn.islamic.app")
	if err != nil {
		t.Fatalf("pin: %v", err)
	}
	if ip != "2a02:26f0:9000::1" {
		t.Errorf("pin = %q", ip)
	}
}

func TestPinFailsClosedOnPrivate(t *testing.T) {
	// ANY private address in the set must fail the whole dial.
	cases := [][]string{
		{"93.184.216.34", "10.0.0.1"},
		{"93.184.216.34", "192.168.1.1"},
		{"93.184.216.34", "127.0.0.1"},
		{"93.184.216.34", "169.254.1.1"},
		{"93.184.216.34", "100.64.1.1"},
		{"93.184.216.34", "fe80::1"},
		{"93.184.216.34", "::1"},
		{"93.184.216.34", "fc00::1"},
	}
	for _, addrs := range cases {
		d := NewPinnedDialer(fakeResolver(addrs...))
		if _, err := d.pin(context.Background(), "cdn.islamic.app"); err == nil {
			t.Errorf("pin(%v) did not fail closed", addrs)
		}
	}
}

func TestPinErrors(t *testing.T) {
	d := NewPinnedDialer(fakeResolver())
	if _, err := d.pin(context.Background(), "cdn.islamic.app"); err == nil {
		t.Error("pin(no addresses) did not error")
	}
	d2 := NewPinnedDialer(func(ctx context.Context, host string) ([]string, error) {
		return nil, errors.New("nxdomain")
	})
	if _, err := d2.pin(context.Background(), "cdn.islamic.app"); err == nil {
		t.Error("pin(resolve error) did not error")
	}
	d3 := &PinnedDialer{}
	if _, err := d3.pin(context.Background(), "cdn.islamic.app"); err == nil {
		t.Error("pin(nil resolver) did not error")
	}
}

func TestDialContextSplitsHostPort(t *testing.T) {
	d := NewPinnedDialer(fakeResolver("93.184.216.34"))
	// Dialing a loopback-ish host through a pinned public IP would attempt a
	// real connection; we only verify the pre-dial failure modes. SplitHostPort
	// on garbage must error cleanly.
	_, err := d.DialContext(context.Background(), "tcp", "bad-addr")
	if err == nil {
		t.Error("DialContext(bad addr) did not error")
	}
}

func TestNoRedirectClientRejectsRedirects(t *testing.T) {
	c := NoRedirectClient()
	if c.CheckRedirect == nil {
		t.Fatal("NoRedirectClient has no CheckRedirect policy")
	}
	if c.CheckRedirect(nil, nil) != http.ErrUseLastResponse {
		t.Error("CheckRedirect did not return http.ErrUseLastResponse")
	}
}
