// Package dialer builds the outbound http.Transport the proxy uses for every
// origin request. It mirrors download.sh's pin_host + curl hardening:
//
//   - The URL host is resolved once per dial; fail closed if ANY returned
//     address is private/internal/loopback/ULA (this is what stops DNS
//     rebinding). The first IPv4 is pinned, else the first IPv6.
//   - The dial goes to the pinned IP, but the request keeps the original
//     hostname, so TLS SNI and certificate verification still run against the
//     allowlisted hostname (not the raw IP).
//   - Redirects are never followed (CheckRedirect returns http.ErrUseLastResponse
//     on the client); a 3xx surfaces to the handler as an error.
package dialer

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"time"

	"quranproxyd/internal/urlsafety"
)

const (
	// ConnectTimeout mirrors curl --connect-timeout 10.
	ConnectTimeout = 10 * time.Second
	// OverallTimeout mirrors curl --max-time 300.
	OverallTimeout = 300 * time.Second
	// HeadTimeout mirrors curl --max-time 30 for the size-probing HEAD.
	HeadTimeout = 30 * time.Second
	// KeepAlive is the idle keepalive on origin connections.
	KeepAlive = 30 * time.Second
)

// Resolver maps a hostname to a set of addresses. DefaultResolver uses the
// system resolver.
type Resolver func(ctx context.Context, host string) ([]string, error)

// DefaultResolver is the production resolver.
func DefaultResolver(ctx context.Context, host string) ([]string, error) {
	return net.DefaultResolver.LookupHost(ctx, host)
}

// PinnedDialer dials pinned IPs for allowlisted hostnames.
type PinnedDialer struct {
	netDialer *net.Dialer
	resolve   Resolver
}

// NewPinnedDialer builds a dialer that resolves via resolve and pins the
// chosen address per dial.
func NewPinnedDialer(resolve Resolver) *PinnedDialer {
	return &PinnedDialer{
		netDialer: &net.Dialer{Timeout: ConnectTimeout, KeepAlive: KeepAlive},
		resolve:   resolve,
	}
}

// DialContext resolves addr's host, pins it, and dials the pinned IP. The
// caller (http.Transport) still presents the original hostname to TLS.
func (d *PinnedDialer) DialContext(ctx context.Context, network, addr string) (net.Conn, error) {
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return nil, fmt.Errorf("dialer: split %q: %w", addr, err)
	}
	if port == "" {
		port = "443"
	}
	ip, err := d.pin(ctx, host)
	if err != nil {
		return nil, err
	}
	return d.netDialer.DialContext(ctx, network, net.JoinHostPort(ip, port))
}

// pin resolves host and returns the pinned IP. Fails closed if resolution
// fails, yields no usable address, or if ANY address is blocked.
func (d *PinnedDialer) pin(ctx context.Context, host string) (string, error) {
	if d.resolve == nil {
		return "", errors.New("dialer: nil resolver")
	}
	addrs, err := d.resolve(ctx, host)
	if err != nil {
		return "", fmt.Errorf("dialer: resolve %q: %w", host, err)
	}
	var v4, v6 string
	for _, a := range addrs {
		ip := net.ParseIP(a)
		if ip == nil {
			continue
		}
		// Fail closed on ANY internal/private address — DNS rebinding defense.
		if urlsafety.IsBlockedHost(ip.String()) {
			return "", fmt.Errorf("dialer: blocked resolved address %q for %q", ip, host)
		}
		if ip4 := ip.To4(); ip4 != nil {
			if v4 == "" {
				v4 = ip4.String()
			}
		} else if v6 == "" {
			v6 = ip.String()
		}
	}
	chosen := v4
	if chosen == "" {
		chosen = v6
	}
	if chosen == "" {
		return "", fmt.Errorf("dialer: no usable address for %q", host)
	}
	return chosen, nil
}

// NewTransport returns an http.Transport that pins DNS and never follows
// redirects. DisableCompression keeps the proxy byte-exact.
func NewTransport(resolve Resolver) *http.Transport {
	return &http.Transport{
		DialContext:           NewPinnedDialer(resolve).DialContext,
		ForceAttemptHTTP2:     true,
		MaxIdleConns:          8,
		MaxIdleConnsPerHost:   4,
		IdleConnTimeout:       KeepAlive * 2,
		TLSHandshakeTimeout:   ConnectTimeout,
		ExpectContinueTimeout: time.Second,
		DisableCompression:    true,
	}
}

// NewClient returns an http.Client with the pinned transport and redirects
// disabled. Timeout covers the whole request (mirrors curl --max-time 300);
// handlers set tighter per-request contexts where needed (e.g. HEAD).
func NewClient(resolve Resolver) *http.Client {
	return &http.Client{
		Transport: NewTransport(resolve),
		Timeout:   OverallTimeout,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			// 3xx is an error path: following a redirect would let an
			// allowlisted host bounce the proxy at an arbitrary destination.
			return http.ErrUseLastResponse
		},
	}
}

// NoRedirectClient is a plain client (used in tests against httptest origins)
// with the same redirect rejection but no DNS pinning.
func NoRedirectClient() *http.Client {
	return &http.Client{
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
		Timeout: OverallTimeout,
	}
}
