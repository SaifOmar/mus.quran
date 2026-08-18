package urlsafety

import (
	"strings"
	"testing"
)

func TestSafeIdentifier(t *testing.T) {
	cases := []struct {
		in   string
		want bool
	}{
		{"ar.alafasy", true},
		{"a.b-c_d.1", true},
		{"123abc", true},
		{"a", true},
		{strings.Repeat("a", 64), true},
		{strings.Repeat("a", 65), false},
		{"", false},
		{"a/b", false},
		{"a\\b", false},
		{"..", false},
		{".", false},
		{".hidden", false},
		{"a b", false},
		{"a%2f", false},
		{"a\nb", false},
		{"عبد", false},
	}
	for _, c := range cases {
		if got := IsSafeIdentifier(c.in); got != c.want {
			t.Errorf("IsSafeIdentifier(%q) = %v, want %v", c.in, got, c.want)
		}
	}
	if !IsSafeReciterArg("ar.alafasy") || IsSafeReciterArg("../etc") {
		t.Error("IsSafeReciterArg diverges from isSafeIdentifier")
	}
}

func TestParseSurahArg(t *testing.T) {
	cases := []struct {
		in   string
		want int
		ok   bool
	}{
		{"1", 1, true},
		{"114", 114, true},
		{"57", 57, true},
		{"0", 0, false},
		{"115", 0, false},
		{"-1", 0, false},
		{"1junk", 0, false},
		{"junk1", 0, false},
		{"01", 0, false},
		{"1.5", 0, false},
		{"", 0, false},
		{" 1", 0, false},
		{"99999999999999999999999999", 0, false},
		{"+1", 0, false},
	}
	for _, c := range cases {
		got, ok := ParseSurahArg(c.in)
		if got != c.want || ok != c.ok {
			t.Errorf("ParseSurahArg(%q) = (%d, %v), want (%d, %v)", c.in, got, ok, c.want, c.ok)
		}
	}
}

func TestParseSeekArg(t *testing.T) {
	cases := []struct {
		in   string
		want int
		ok   bool
	}{
		{"0", 0, true},
		{"30", 30, true},
		{"-15", -15, true},
		{"+5", 0, false},
		{"5s", 0, false},
		{"1.5", 0, false},
		{"", 0, false},
		{" -5", 0, false},
	}
	for _, c := range cases {
		got, ok := ParseSeekArg(c.in)
		if got != c.want || ok != c.ok {
			t.Errorf("ParseSeekArg(%q) = (%d, %v), want (%d, %v)", c.in, got, ok, c.want, c.ok)
		}
	}
}

func TestSafeServerPrefix(t *testing.T) {
	valid := []string{
		"https://cdn.islamic.app/quran/audio-surah/",
		"https://server8.mp3quran.net/afs/",
		"https://a.b.c.islamic.app/x/",
		"https://cdn.islamic.app:443/x/",
		"https://cdn.islamic.app:8080/x/",
		"https://cdn.islamic.app/quran",
		"https://islamic.app/x/",
		"https://cdn.islamic.app./x/",
	}
	for _, u := range valid {
		if !IsSafeServerPrefix(u) {
			t.Errorf("IsSafeServerPrefix(%q) = false, want true", u)
		}
	}

	invalid := []string{
		// scheme / structure
		"http://cdn.islamic.app/x/",
		"ftp://cdn.islamic.app/x/",
		"//cdn.islamic.app/x/",
		"javascript:alert(1)",
		"https://user:pass@cdn.islamic.app/x/",
		"https://user@cdn.islamic.app/x/",
		"https://cdn.islamic.app/x/?a=1",
		"https://cdn.islamic.app/x/#frag",
		"https://cdn.islamic.app/x/\n/evil",
		"https://cdn.islamic.app/x/\t/evil",
		"https://cdn.islamic.app/x/ y",
		"",
		"   ",
		"https://cdn.islamic.app/" + strings.Repeat("a", 600),
		// encoded delimiters
		"https://cdn.islamic%2eapp/x/",
		"https://cdn.islamic.app%2fx/",
		"https://cdn.islamic.app/x%3fy",
		"https://cdn.islamic.app/x%23y",
		"https://user%40x@cdn.islamic.app/",
		"https://cdn.islamic.app/x%5cy",
		// ports
		"https://cdn.islamic.app:0/x/",
		"https://cdn.islamic.app:65536/x/",
		"https://cdn.islamic.app:01/x/",
		"https://cdn.islamic.app:443a/x/",
		"https://cdn.islamic.app:/x/",
		"https://cdn.islamic.app:-1/x/",
		// host policy
		"https://93.184.216.34/x/",
		"https://evil.com/x/",
		"https://islamic.app.evil.com/x/",
		"https://islamicapp.com/x/",
		"https://localhost/x/",
		"https://foo.local/x/",
		"https://foo.internal/x/",
		"https://foo.localhost/x/",
		"https://intranet/x/",
		// ipv4 encodings
		"https://127.0.0.1/x/",
		"https://10.0.0.1/x/",
		"https://172.16.0.1/x/",
		"https://172.31.255.255/x/",
		"https://192.168.1.1/x/",
		"https://169.254.0.1/x/",
		"https://100.64.0.1/x/",
		"https://0.0.0.0/x/",
		"https://224.0.0.1/x/",
		"https://255.255.255.255/x/",
		"https://192.0.0.1/x/",
		"https://192.0.2.1/x/",
		"https://198.51.100.1/x/",
		"https://203.0.113.1/x/",
		"https://0177.0.0.1/x/",
		"https://0x7f.0.0.1/x/",
		"https://2130706433/x/",
		"https://127.0.0.01/x/",
		"https://8.8.8.8/x/",
		// ipv6
		"https://[::1]/x/",
		"https://[::]/x/",
		"https://[fe80::1]/x/",
		"https://[fc00::1]/x/",
		"https://[::ffff:127.0.0.1]/x/",
		"https://[::ffff:7f00:1]/x/",
		"https://[fe80::1%25eth0]/x/",
		"https://[g::1]/x/",
		"https://2001:db8::1/x/",
		"https://[2001:db8::1]:0/x/",
		"https://[2001:db8::1]:abc/x/",
	}
	for _, u := range invalid {
		if IsSafeServerPrefix(u) {
			t.Errorf("IsSafeServerPrefix(%q) = true, want false", u)
		}
	}
}

func TestSanitizeServer(t *testing.T) {
	if got := SanitizeServer("https://cdn.islamic.app/quran"); got != "https://cdn.islamic.app/quran/" {
		t.Errorf("SanitizeServer(no slash) = %q", got)
	}
	if got := SanitizeServer("https://cdn.islamic.app/quran/"); got != "https://cdn.islamic.app/quran/" {
		t.Errorf("SanitizeServer(slash) = %q", got)
	}
	if got := SanitizeServer("http://evil.com/"); got != "" {
		t.Errorf("SanitizeServer(hostile) = %q, want empty", got)
	}
}

func TestSafeRemoteURL(t *testing.T) {
	if !IsSafeRemoteURL("https://cdn.islamic.app/quran/audio-surah/ar.alafasy/1.mp3") {
		t.Error("IsSafeRemoteURL(final default-CDN url) = false, want true")
	}
	if IsSafeRemoteURL("http://cdn.islamic.app/quran/audio-surah/ar.alafasy/1.mp3") {
		t.Error("IsSafeRemoteURL(http) = true, want false")
	}
}

func TestAudioURL(t *testing.T) {
	// default CDN, unpadded
	if got := AudioURL("ar.alafasy", 1, nil); got != "https://cdn.islamic.app/quran/audio-surah/ar.alafasy/1.mp3" {
		t.Errorf("AudioURL(default) = %q", got)
	}
	// ar.ajamy -> ar.ahmedajamy
	if got := AudioURL("ar.ajamy", 1, nil); got != "https://cdn.islamic.app/quran/audio-surah/ar.ahmedajamy/1.mp3" {
		t.Errorf("AudioURL(ajamy) = %q", got)
	}
	// 114 ok, 115/0 rejected
	if AudioURL("ar.alafasy", 114, nil) == "" {
		t.Error("AudioURL(114) rejected")
	}
	if AudioURL("ar.alafasy", 115, nil) != "" {
		t.Error("AudioURL(115) not rejected")
	}
	if AudioURL("ar.alafasy", 0, nil) != "" {
		t.Error("AudioURL(0) not rejected")
	}
	// junk ids rejected
	if AudioURL("../etc", 1, nil) != "" {
		t.Error("AudioURL(traversal id) not rejected")
	}
	if AudioURL("a/b", 1, nil) != "" {
		t.Error("AudioURL(slash id) not rejected")
	}
	// server object used with padding
	server := "https://server8.mp3quran.net/afs/"
	if got := AudioURL("x", 1, &server); got != "https://server8.mp3quran.net/afs/001.mp3" {
		t.Errorf("AudioURL(server) = %q", got)
	}
	// hostile server rejected
	bad := "http://evil.com/"
	if AudioURL("x", 1, &bad) != "" {
		t.Error("AudioURL(hostile server) not rejected")
	}
}

func TestSafeReciter(t *testing.T) {
	server := "https://cdn.islamic.app/x/"
	if !IsSafeReciter("ar.alafasy", &server) {
		t.Error("IsSafeReciter(valid id+server) = false")
	}
	bad := "http://x/"
	if IsSafeReciter("ar.alafasy", &bad) {
		t.Error("IsSafeReciter(bad server) = true")
	}
	if IsSafeReciter("../x", &server) {
		t.Error("IsSafeReciter(bad id) = true")
	}
	if IsSafeReciter("ar.alafasy", nil) {
		// nil server (default CDN) is acceptable
	} else {
		t.Error("IsSafeReciter(nil server) = false")
	}
	empty := ""
	if IsSafeReciter("ar.alafasy", &empty) {
		t.Error("IsSafeReciter(empty server) = true, want false (present but invalid)")
	}
}

func TestLocalAudioURL(t *testing.T) {
	if got := LocalAudioURL("/data/state/omarchy/quran", "ar.alafasy", 1); got != "file:///data/state/omarchy/quran/ar.alafasy/1.mp3" {
		t.Errorf("LocalAudioURL = %q", got)
	}
	if LocalAudioURL("/data/../etc", "ar.alafasy", 1) != "" {
		t.Error("LocalAudioURL(traversal) not rejected")
	}
	if LocalAudioURL("/data", "../etc", 1) != "" {
		t.Error("LocalAudioURL(bad reciter) not rejected")
	}
	if LocalAudioURL("/data", "ar.alafasy", 115) != "" {
		t.Error("LocalAudioURL(bad surah) not rejected")
	}
}

func TestConstants(t *testing.T) {
	if MaxSurahBytes != 314572800 {
		t.Errorf("MaxSurahBytes = %d", MaxSurahBytes)
	}
	if CooldownMS != 10000 {
		t.Errorf("CooldownMS = %d", CooldownMS)
	}
}

func TestCooldown(t *testing.T) {
	cd := NewCooldown()
	const t0 = 1000000
	if cd.Active("ar.alafasy:1", t0) {
		t.Error("cooldown active on fresh map")
	}
	cd.Mark("ar.alafasy:1", t0)
	if !cd.Active("ar.alafasy:1", t0+5000) {
		t.Error("cooldown not active inside window")
	}
	if cd.Active("ar.alafasy:1", t0+CooldownMS+1) {
		t.Error("cooldown still active after window")
	}
	if cd.Active("ar.alafasy:2", t0+5000) {
		t.Error("cooldown leaked to other key")
	}
	cd.Clear("ar.alafasy:1")
	if cd.Active("ar.alafasy:1", t0+5000) {
		t.Error("cooldown not cleared")
	}
	if !cd.Active("", t0) {
		t.Error("cooldown: empty key should be active (defensive)")
	}

	// Gate-flow simulation: one fetch per window per key.
	cd2 := NewCooldown()
	fetches := 0
	tryFetch := func(key string, now int64) bool {
		if cd2.Active(key, now) {
			return false
		}
		fetches++
		cd2.Mark(key, now)
		return true
	}
	key := "ar.alafasy:7"
	res := []bool{tryFetch(key, t0+1), tryFetch(key, t0+2), tryFetch(key, t0+3)}
	if fetches != 1 || !res[0] || res[1] || res[2] {
		t.Errorf("gate: fetches=%d res=%v, want 1 [true,false,false]", fetches, res)
	}
	if !tryFetch(key, t0+CooldownMS+100) {
		t.Error("gate: window expiry did not allow refetch")
	}
	if fetches != 2 {
		t.Errorf("gate: fetches=%d after two windows, want 2", fetches)
	}
}

func TestIsValidSurahNumber(t *testing.T) {
	ok := []int{1, 114}
	bad := []int{0, 115, 1 << 30}
	for _, n := range ok {
		if !IsValidSurahNumber(n) {
			t.Errorf("IsValidSurahNumber(%d) = false", n)
		}
	}
	for _, n := range bad {
		if IsValidSurahNumber(n) {
			t.Errorf("IsValidSurahNumber(%d) = true", n)
		}
	}
}
