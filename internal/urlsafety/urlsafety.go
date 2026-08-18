// Package urlsafety is a 1:1 Go port of the URL/IP hardening in the mus.quran
// plugin's Model.js (isSafeIdentifier, isSafeServerPrefix, sanitizeServer,
// isBlockedHost, audioUrl) and download.sh (blocked_host/allowed_host).
//
// These functions are the SSRF gate for every outbound request the proxy makes:
// a catalog `server` value, or a final constructed URL, must be an https URL on
// an allowlisted audio CDN with a public host (no loopback/private/link-local/
// ULA/CGNAT/TEST-NET, no IPv4-mapped IPv6, no short/hex/octal IPv4 encodings,
// no userinfo/query/fragment, no encoded delimiters). Identifiers used as path
// segments are similarly restricted. Port deviations intentionally change
// behavior: an invalid input must never be "fixed" — it is rejected.
package urlsafety

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"sync"
)

const (
	// MaxSurahBytes is the per-surah cap (~300 MB), shared with Model.js and
	// download.sh. An origin lying about Content-Length cannot make the proxy
	// fallocate arbitrary amounts of disk.
	MaxSurahBytes = 314572800
	// CooldownMS is the per reciter:surah failure cooldown (Model.COOLDOWN_MS).
	CooldownMS = 10000
	// CDNBase is the default audio CDN base (Model.CDN_BASE).
	CDNBase = "https://cdn.islamic.app/quran/audio-surah"
)

var (
	allowedAudioHostSuffixes = []string{"mp3quran.net", "islamic.app"}

	safeIdentifierRe    = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*$`)
	controlCharRe       = regexp.MustCompile(`[\x00-\x20\x7f]`)
	encodedDelimiterRe  = regexp.MustCompile(`%(?:2e|2f|3f|23|40|5c)`)
	schemeAuthorityRe   = regexp.MustCompile(`^(https)://([^/?#]+)`)
	hexColonRe          = regexp.MustCompile(`^[0-9a-fA-F:]+$`)
	hostCharRe          = regexp.MustCompile(`^[A-Za-z0-9.:-]+$`)
	digitsRe            = regexp.MustCompile(`^[0-9]+$`)
	seekArgRe           = regexp.MustCompile(`^-?[0-9]+$`)
	ipv4LookalikePartRe = regexp.MustCompile(`^(0x[0-9a-fA-F]+|0[0-7]*|[0-9]+)$`)
	ipv4SuffixRe        = regexp.MustCompile(`:\d+\.\d+\.\d+\.\d+$`)
)

// Pad3 zero-pads n to three digits (Model.pad3).
func Pad3(n int) string {
	return fmt.Sprintf("%03d", n)
}

// IsValidSurahNumber reports whether n is an integer in 1..114.
func IsValidSurahNumber(n int) bool {
	return n >= 1 && n <= 114
}

// IsSafeIdentifier reports whether id is usable as a path segment: alnum
// first, letters/digits/dot/dash/underscore only, <= 64 chars, not "."/"..".
func IsSafeIdentifier(id string) bool {
	if len(id) == 0 || len(id) > 64 {
		return false
	}
	if !safeIdentifierRe.MatchString(id) {
		return false
	}
	if id == "." || id == ".." {
		return false
	}
	return true
}

// IsSafeReciterArg is the IPC/CLI form of IsSafeIdentifier.
func IsSafeReciterArg(id string) bool {
	return IsSafeIdentifier(id)
}

// ParseSurahArg parses a strict decimal 1..114 (no leading zeros, no junk).
func ParseSurahArg(str string) (int, bool) {
	if !digitsRe.MatchString(str) {
		return 0, false
	}
	if len(str) > 1 && str[0] == '0' {
		return 0, false
	}
	n, err := strconv.Atoi(str)
	if err != nil || n < 1 || n > 114 {
		return 0, false
	}
	return n, true
}

// ParseSeekArg parses a strict optional-sign decimal (Model.parseSeekArg).
func ParseSeekArg(str string) (int, bool) {
	if !seekArgRe.MatchString(str) {
		return 0, false
	}
	n, err := strconv.Atoi(str)
	if err != nil {
		return 0, false
	}
	return n, true
}

func stripTrailingDots(host string) string {
	for len(host) > 0 && host[len(host)-1] == '.' {
		host = host[:len(host)-1]
	}
	return host
}

// parseIPv4 parses a dotted decimal host into 4 octets. Hex/octal encodings,
// leading zeros, and short forms that would otherwise smuggle internal
// addresses are rejected (returns nil). Two- and three-part forms are padded
// the same way Model.js does (zeros inserted before the last part): a.b ->
// a.0.0.b, a.b.c -> a.b.0.c.
func parseIPv4(host string) []int {
	h := stripTrailingDots(host)
	parts := strings.Split(h, ".")
	if len(parts) < 2 || len(parts) > 4 {
		return nil
	}
	nums := make([]int, 0, 4)
	for _, p := range parts {
		if !digitsRe.MatchString(p) {
			return nil
		}
		if len(p) > 1 && p[0] == '0' {
			return nil
		}
		n, err := strconv.Atoi(p)
		if err != nil || n < 0 || n > 255 {
			return nil
		}
		nums = append(nums, n)
	}
	for len(nums) < 4 {
		last := nums[len(nums)-1]
		nums = append(nums[:len(nums)-1], 0, last)
	}
	return nums
}

// looksLikeIPv4 mirrors Model._looksLikeIpv4: dotted host whose parts are all
// numeric-looking (including hex/octal forms — those are blocked downstream).
func looksLikeIPv4(host string) bool {
	h := stripTrailingDots(host)
	parts := strings.Split(h, ".")
	if len(parts) < 2 || len(parts) > 4 {
		return false
	}
	for _, p := range parts {
		if !ipv4LookalikePartRe.MatchString(p) {
			return false
		}
	}
	return true
}

// isBlockedIPv4 mirrors Model._isBlockedIpv4.
func isBlockedIPv4(parts []int) bool {
	if len(parts) != 4 {
		return true
	}
	a, b, c := parts[0], parts[1], parts[2]
	if a == 0 || a == 10 || a == 127 {
		return true
	}
	if a == 169 && b == 254 {
		return true // link-local
	}
	if a == 172 && b >= 16 && b <= 31 {
		return true // private
	}
	if a == 192 && b == 168 {
		return true // private
	}
	if a == 100 && b >= 64 && b <= 127 {
		return true // CGNAT
	}
	if a >= 224 && a <= 255 {
		return true // multicast + reserved 240/4
	}
	if a == 192 && b == 0 && c == 0 {
		return true // 192.0.0.0/24
	}
	if a == 192 && b == 0 && c == 2 {
		return true // TEST-NET-1 (192.0.2.0/24)
	}
	if a == 198 && b == 51 && c == 100 {
		return true // TEST-NET-2 (198.51.100.0/24)
	}
	if a == 203 && b == 0 && c == 113 {
		return true // TEST-NET-3 (203.0.113.0/24)
	}
	return false
}

// IsAllowedAudioHost reports whether host (after stripping trailing dots,
// lowercasing) is exactly one of the allowlisted audio CDN suffixes or a
// subdomain of one.
func IsAllowedAudioHost(host string) bool {
	if host == "" {
		return false
	}
	h := strings.ToLower(stripTrailingDots(host))
	for _, s := range allowedAudioHostSuffixes {
		if h == s {
			return true
		}
		if len(h) > len(s)+1 && strings.HasSuffix(h, "."+s) {
			return true
		}
	}
	return false
}

// IsBlockedHost mirrors Model.isBlockedHost: true for loopback/private/
// link-local/ULA/internal hostnames, IPv4-mapped IPv6, and short/hex/octal
// IPv4 encodings. Public IPv4 literals parse cleanly and return false here
// (they are rejected later by the audio-host allowlist).
func IsBlockedHost(host string) bool {
	if host == "" {
		return true
	}
	h := strings.ToLower(stripTrailingDots(host))
	if h == "" {
		return true
	}
	if h == "localhost" || h == "local" {
		return true
	}
	if strings.HasSuffix(h, ".localhost") {
		return true
	}
	if strings.Contains(h, ".local") || strings.Contains(h, ".internal") {
		return true
	}
	if strings.Contains(h, ":") {
		switch h {
		case "::", "::1", "0:0:0:0:0:0:0:1", "0:0:0:0:0:0:0:0":
			return true
		}
		// IPv4-mapped / IPv4-compatible (e.g. ::ffff:127.0.0.1, ::ffff:7f00:1)
		if strings.Contains(h, "ffff:") || strings.Contains(h, ":ffff") {
			return true
		}
		if ipv4SuffixRe.MatchString(h) {
			return true
		}
		if strings.HasPrefix(h, "fe8") || strings.HasPrefix(h, "fe9") ||
			strings.HasPrefix(h, "fea") || strings.HasPrefix(h, "feb") ||
			strings.HasPrefix(h, "fec") || strings.HasPrefix(h, "fc") ||
			strings.HasPrefix(h, "fd") {
			return true
		}
		return false
	}
	if !strings.Contains(h, ".") {
		return true
	}
	if looksLikeIPv4(h) {
		parts := parseIPv4(h)
		if parts == nil {
			return true
		}
		return isBlockedIPv4(parts)
	}
	return false
}

func isValidPort(p string) bool {
	if p == "" {
		return false
	}
	if !digitsRe.MatchString(p) {
		return false
	}
	if len(p) > 1 && p[0] == '0' {
		return false
	}
	n, err := strconv.Atoi(p)
	if err != nil || n < 1 || n > 65535 {
		return false
	}
	return true
}

// IsSafeServerPrefix mirrors Model.isSafeServerPrefix: true for an absolute
// https URL on an allowlisted audio CDN, no userinfo, no query, no fragment,
// no control chars, no encoded delimiters, valid port, safe (public,
// non-blocked) host.
func IsSafeServerPrefix(value string) bool {
	url := strings.TrimSpace(value)
	if len(url) == 0 || len(url) > 512 {
		return false
	}
	if controlCharRe.MatchString(url) {
		return false
	}
	// Encoded delimiters (%2e %2f %3f %23 %40 %5c) can smuggle structure past
	// naive URL checks.
	if encodedDelimiterRe.MatchString(url) {
		return false
	}
	m := schemeAuthorityRe.FindStringSubmatch(url)
	if m == nil {
		return false
	}
	if strings.Contains(url, "#") || strings.Contains(url, "?") {
		return false
	}
	authority := m[2]
	if strings.Contains(authority, "@") {
		return false
	}
	host := authority
	if strings.HasPrefix(host, "[") {
		// Bracketed IPv6: inner literal must be hex/colon-only, contain >= 1
		// colon, and carry no zone id. Anything after the bracket must be a port.
		closeIdx := strings.Index(authority, "]")
		if closeIdx == -1 {
			return false
		}
		inner := authority[1:closeIdx]
		if !hexColonRe.MatchString(inner) {
			return false
		}
		if !strings.Contains(inner, ":") {
			return false
		}
		if strings.Contains(inner, "%") {
			return false
		}
		host = inner
		after := authority[closeIdx+1:]
		if after != "" {
			if !strings.HasPrefix(after, ":") {
				return false
			}
			if !isValidPort(after[1:]) {
				return false
			}
		}
	} else {
		lastColon := strings.LastIndex(host, ":")
		if lastColon != -1 {
			if !isValidPort(host[lastColon+1:]) {
				return false
			}
			host = host[:lastColon]
		}
	}
	if !hostCharRe.MatchString(host) && !strings.Contains(host, ":") {
		return false
	}
	if IsBlockedHost(host) {
		return false
	}
	return IsAllowedAudioHost(host)
}

// SanitizeServer returns the validated server prefix with a trailing slash,
// or "" if unsafe (Model.sanitizeServer).
func SanitizeServer(value string) string {
	if !IsSafeServerPrefix(value) {
		return ""
	}
	url := strings.TrimSpace(value)
	if !strings.HasSuffix(url, "/") {
		url += "/"
	}
	return url
}

// IsSafeRemoteURL is the final-url guard applied after URL construction
// (Model.isSafeRemoteUrl).
func IsSafeRemoteURL(url string) bool {
	return IsSafeServerPrefix(url)
}

// IsSafeReciter validates an identifier plus an optional server prefix
// (Model.isSafeReciter). A nil server means the default CDN is used; an empty
// non-nil server is present and therefore must validate (and fails).
func IsSafeReciter(identifier string, server *string) bool {
	if !IsSafeIdentifier(identifier) {
		return false
	}
	if server != nil && SanitizeServer(*server) == "" {
		return false
	}
	return true
}

// AudioURL mirrors Model.audioUrl. With a non-nil server, the padded
// (NNN.mp3) URL is built on that prefix and re-checked. Otherwise the default
// CDN template is used (unpadded N.mp3, with ar.ajamy mapped to
// ar.ahmedajamy). The final URL is always passed through IsSafeRemoteURL.
func AudioURL(reciterID string, surahNumber int, server *string) string {
	n := surahNumber
	if !IsValidSurahNumber(n) {
		return ""
	}
	if server != nil {
		url := SanitizeServer(*server)
		if url == "" {
			return ""
		}
		url += Pad3(n) + ".mp3"
		if IsSafeRemoteURL(url) {
			return url
		}
		return ""
	}
	providerID := reciterID
	if providerID == "ar.ajamy" {
		providerID = "ar.ahmedajamy"
	}
	if !IsSafeIdentifier(providerID) {
		return ""
	}
	url := CDNBase + "/" + providerID + "/" + strconv.Itoa(n) + ".mp3"
	if IsSafeRemoteURL(url) {
		return url
	}
	return ""
}

// LocalAudioURL mirrors Model.localAudioUrl: builds a file:// URL for an
// explicit download, rejecting traversal and invalid ids/numbers.
func LocalAudioURL(dataDir, reciterID string, surahNumber int) string {
	if strings.Contains(dataDir, "..") {
		return ""
	}
	if !IsSafeIdentifier(reciterID) || !IsValidSurahNumber(surahNumber) {
		return ""
	}
	return "file://" + dataDir + "/" + reciterID + "/" + strconv.Itoa(surahNumber) + ".mp3"
}

// Cooldown is a per-key failure gate mirroring Model's cooldown map
// (cooldownActive/markCooldown/clearCooldown, COOLDOWN_MS). Keys are
// "reciter:surah". Thread-safe.
type Cooldown struct {
	mu     sync.Mutex
	until  map[string]int64
	window int64
}

// NewCooldown returns a Cooldown with the default window (CooldownMS).
func NewCooldown() *Cooldown {
	return &Cooldown{until: make(map[string]int64), window: CooldownMS}
}

// Active reports whether key is inside its cooldown window. A missing or empty
// key is treated as active (defensive, mirrors Model.cooldownActive).
func (c *Cooldown) Active(key string, now int64) bool {
	if key == "" {
		return true
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	u, ok := c.until[key]
	return ok && now < u
}

// Mark arms the cooldown for key starting at now.
func (c *Cooldown) Mark(key string, now int64) {
	if key == "" {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.until[key] = now + c.window
}

// Clear removes any cooldown for key.
func (c *Cooldown) Clear(key string) {
	if key == "" {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	delete(c.until, key)
}
