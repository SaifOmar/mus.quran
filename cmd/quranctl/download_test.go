package main

import (
	"bytes"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"quranproxyd/internal/dialer"
	"quranproxyd/internal/urlsafety"
)

// fakeCDN serves HEAD with content type/length and body GETs, mirroring the
// real mp3quran servers.
func fakeCDN(t *testing.T, bodies map[int][]byte, ct string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var n int
		if _, err := fmt.Sscanf(r.URL.Path, "/audio/%d.mp3", &n); err != nil {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		body, ok := bodies[n]
		if !ok {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", ct)
		if r.Method == http.MethodHead {
			w.Header().Set("Content-Length", fmt.Sprintf("%d", len(body)))
			w.WriteHeader(http.StatusOK)
			return
		}
		w.Header().Set("Content-Length", fmt.Sprintf("%d", len(body)))
		w.Write(body)
	}))
	return srv
}

// withFakeOriginHome runs cmdDownloadIO with the URL builder and client
// pointed at the fake CDN, HOME set to home. Returns exit code, stdout,
// stderr, state root.
func withFakeOriginHome(t *testing.T, srv *httptest.Server, args []string, home string) (int, string, string, string) {
	t.Helper()
	old := buildOriginURL
	buildOriginURL = func(reciter string, server *string) func(n int) (string, error) {
		return func(n int) (string, error) {
			return srv.URL + "/audio/" + fmt.Sprintf("%d", n) + ".mp3", nil
		}
	}
	defer func() { buildOriginURL = old }()
	oldClient := newDownloadClient
	newDownloadClient = func() *http.Client { return dialer.NoRedirectClient() }
	defer func() { newDownloadClient = oldClient }()

	t.Setenv("HOME", home)
	var stdout, stderr bytes.Buffer
	code := cmdDownloadIO(args, &stdout, &stderr)
	stateRoot := filepath.Join(home, ".local", "state", "omarchy", "quran")
	return code, stdout.String(), stderr.String(), stateRoot
}

func withFakeOrigin(t *testing.T, srv *httptest.Server, args []string) (int, string, string, string) {
	t.Helper()
	return withFakeOriginHome(t, srv, args, t.TempDir())
}

func TestCmdDownloadSingle(t *testing.T) {
	body := []byte("0123456789abcdef")
	srv := fakeCDN(t, map[int][]byte{1: body}, "audio/mpeg")
	defer srv.Close()

	code, out, errOut, root := withFakeOrigin(t, srv, []string{"ar.alafasy", "1"})
	if code != 0 {
		t.Fatalf("exit = %d, stderr: %s", code, errOut)
	}
	got, err := os.ReadFile(filepath.Join(root, "ar.alafasy", "1.mp3"))
	if err != nil {
		t.Fatalf("target: %v", err)
	}
	if string(got) != string(body) {
		t.Fatalf("content = %q", got)
	}
	// Contract: progress_bytes during transfer, progress 1/1 after, complete line.
	if !strings.Contains(out, "progress_bytes") {
		t.Fatalf("stdout missing progress_bytes: %q", out)
	}
	if !strings.Contains(out, "progress 1/1") {
		t.Fatalf("stdout missing progress 1/1: %q", out)
	}
	if !strings.Contains(out, "complete 1 0") {
		t.Fatalf("stdout missing complete line: %q", out)
	}
}

func TestCmdDownloadBulk(t *testing.T) {
	bodies := map[int][]byte{
		1: []byte("aaa"), 2: []byte("bbbb"), 3: []byte("ccccc"),
	}
	srv := fakeCDN(t, bodies, "audio/mpeg")
	defer srv.Close()

	code, out, errOut, root := withFakeOrigin(t, srv, []string{"ar.alafasy", "--only", "1,2,3"})
	if code != 0 {
		t.Fatalf("exit = %d, stderr: %s", code, errOut)
	}
	for n := 1; n <= 3; n++ {
		if _, err := os.Stat(filepath.Join(root, "ar.alafasy", fmt.Sprintf("%d.mp3", n))); err != nil {
			t.Fatalf("surah %d missing: %v", n, err)
		}
	}
	if !strings.Contains(out, "progress 3/3") {
		t.Fatalf("stdout missing progress 3/3: %q", out)
	}
	if !strings.Contains(out, "complete 3 0") {
		t.Fatalf("stdout missing complete: %q", out)
	}
}

func TestCmdDownloadPartialFailure(t *testing.T) {
	bodies := map[int][]byte{1: []byte("aaa")} // surah 2,3 404 on origin
	srv := fakeCDN(t, bodies, "audio/mpeg")
	defer srv.Close()

	code, out, errOut, _ := withFakeOrigin(t, srv, []string{"ar.alafasy", "--only", "1,2,3"})
	if code != 1 {
		t.Fatalf("exit = %d, want 1", code)
	}
	if !strings.Contains(out, "complete 1 2") {
		t.Fatalf("stdout missing complete 1 2: %q", out)
	}
	if !strings.Contains(errOut, "failed 2") || !strings.Contains(errOut, "failed 3") {
		t.Fatalf("stderr missing failed lines: %q", errOut)
	}
}

func TestCmdDownloadSkipsComplete(t *testing.T) {
	body := []byte("0123456789abcdef")
	srv := fakeCDN(t, map[int][]byte{1: body}, "audio/mpeg")
	defer srv.Close()
	home := t.TempDir()

	code, _, _, root := withFakeOriginHome(t, srv, []string{"ar.alafasy", "1"}, home)
	if code != 0 {
		t.Fatalf("exit = %d", code)
	}
	// Second run (same HOME): file already matches — exit 0, no transfer.
	code2, out2, _, _ := withFakeOriginHome(t, srv, []string{"ar.alafasy", "1"}, home)
	if code2 != 0 {
		t.Fatalf("second exit = %d", code2)
	}
	if strings.Contains(out2, "progress_bytes") {
		t.Fatalf("complete file must skip transfer: %q", out2)
	}
	if _, err := os.Stat(filepath.Join(root, "ar.alafasy", "1.mp3")); err != nil {
		t.Fatalf("target: %v", err)
	}
}

func TestCmdDownloadResumesPartial(t *testing.T) {
	body := []byte("0123456789abcdef")
	srv := fakeCDN(t, map[int][]byte{1: body}, "audio/mpeg")
	defer srv.Close()
	home := t.TempDir()

	code, _, _, root := withFakeOriginHome(t, srv, []string{"ar.alafasy", "1"}, home)
	if code != 0 {
		t.Fatalf("exit = %d", code)
	}
	// Simulate a crash: target gone, 8-byte partial remains.
	target := filepath.Join(root, "ar.alafasy", "1.mp3")
	if err := os.Remove(target); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target+".part.crash", body[:8], 0o600); err != nil {
		t.Fatal(err)
	}
	code2, _, errOut, _ := withFakeOriginHome(t, srv, []string{"ar.alafasy", "1"}, home)
	if code2 != 0 {
		t.Fatalf("resume exit = %d, stderr: %s", code2, errOut)
	}
	got, err := os.ReadFile(target)
	if err != nil {
		t.Fatalf("target: %v", err)
	}
	if string(got) != string(body) {
		t.Fatalf("resumed content = %q, want %q", got, body)
	}
}

// --- usage/validation gates (exit 2, before any network) ---

func TestCmdDownloadUsageErrors(t *testing.T) {
	srv := fakeCDN(t, map[int][]byte{1: []byte("aaa")}, "audio/mpeg")
	defer srv.Close()
	cases := [][]string{
		{},
		{"ar.alafasy"},
		{"../evil", "1"},
		{"..", "1"},
		{"ar.alafasy", "0"},
		{"ar.alafasy", "115"},
		{"ar.alafasy", "abc"},
		{"ar.alafasy", "--only", ""},
		{"ar.alafasy", "--only", "1,abc"},
		{"ar.alafasy", "--server", "http://127.0.0.1/", "1"},
	}
	for _, args := range cases {
		code, _, _, _ := withFakeOrigin(t, srv, args)
		if code != 2 {
			t.Fatalf("args %v: exit = %d, want 2", args, code)
		}
	}
}

// TestBuildOriginURLValidates — the REAL production builder must reject a
// hostile server or reciter before any request could be dialed.
func TestBuildOriginURLValidates(t *testing.T) {
	badServers := []string{
		"http://evil.example/",               // wrong scheme
		"https://127.0.0.1/",                 // loopback
		"https://192.168.1.5/",               // private
		"https://evil.com/",                  // not an allowlisted CDN
		"https://user@server6.mp3quran.net/", // userinfo rejected
	}
	for _, s := range badServers {
		b := buildOriginURL("ar.alafasy", &s)
		if u, err := b(1); err == nil && u != "" {
			t.Fatalf("server %q: builder returned %q, want rejection", s, u)
		}
	}
	// Valid allowlisted server prefix works.
	good := "https://server6.mp3quran.net/thubti/"
	if u, err := buildOriginURL("mp3quran_49", &good)(2); err != nil || u != good+"002.mp3" {
		t.Fatalf("good server: url = %q err = %v", u, err)
	}
	// Unsafe reciter with default CDN path (no server) is rejected.
	if u, err := buildOriginURL("../evil", nil)(1); err == nil && u != "" {
		t.Fatalf("unsafe reciter: url = %q, want rejection", u)
	}
	// Sanity: the safe default-CDN shape matches urlsafety's own builder.
	want := urlsafety.AudioURL("ar.alafasy", 3, nil)
	if u, err := buildOriginURL("ar.alafasy", nil)(3); err != nil || u != want {
		t.Fatalf("default CDN: url = %q err = %v, want %q", u, err, want)
	}
}
