package proxyhandler

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"quranproxyd/internal/catalog"
	"quranproxyd/internal/dialer"
	"quranproxyd/internal/rangecache"
	"quranproxyd/internal/session"
)

const testToken = "0123456789abcdef0123456789abcdef"

// fakeOrigin builds an httptest server mimicking the CDN: honors Range with
// 206, redirects to redirectTarget when path == /redir, otherwise serves the
// configured body/status.
func fakeOrigin(t *testing.T, body []byte, ct string, status int) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/redir" {
			w.Header().Set("Location", "/nowhere")
			w.WriteHeader(http.StatusFound)
			return
		}
		w.Header().Set("Content-Type", ct)
		w.Header().Set("Accept-Ranges", "bytes")
		if rng := r.Header.Get("Range"); rng != "" {
			start, end, ok := parseSimpleRange(rng, int64(len(body)))
			if !ok {
				w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
				return
			}
			w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, len(body)))
			w.Header().Set("Content-Length", fmt.Sprintf("%d", end-start+1))
			w.WriteHeader(http.StatusPartialContent)
			w.Write(body[start : end+1])
			return
		}
		w.Header().Set("Content-Length", fmt.Sprintf("%d", len(body)))
		w.WriteHeader(status)
		w.Write(body)
	}))
	return srv
}

// parseSimpleRange parses "bytes=a-b" (inclusive).
func parseSimpleRange(rng string, size int64) (int64, int64, bool) {
	if !strings.HasPrefix(rng, "bytes=") {
		return 0, 0, false
	}
	rs := strings.TrimPrefix(rng, "bytes=")
	var a, b int64
	if _, err := fmt.Sscanf(rs, "%d-%d", &a, &b); err != nil {
		return 0, 0, false
	}
	if a < 0 || b >= size || a > b {
		return 0, 0, false
	}
	return a, b, true
}

// newTestHandler wires a handler against an origin server. buildURL returns
// originURL/<reciter>/<n>.mp3. A fresh cache is created in a temp dir.
func newTestHandler(t *testing.T, origin *httptest.Server, withReciter bool) *Handler {
	t.Helper()
	store := catalog.NewStore(&catalog.State{
		Reciters: []catalog.Reciter{{Identifier: "ar.alafasy"}},
	})
	h := New(store, dialer.NoRedirectClient(), session.NewFromString(testToken),
		rangecache.New(t.TempDir(), 1<<30), 4, 314572800)
	h.SetBuildURL(func(id string, n int) string {
		return origin.URL + "/" + id + "/" + fmt.Sprintf("%d", n) + ".mp3"
	})
	if !withReciter {
		store.Set(&catalog.State{}) // drop reciters to exercise 404 path
	}
	return h
}

func get(t *testing.T, h *Handler, path string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, path, nil)
	rr := httptest.NewRecorder()
	h.Routes().ServeHTTP(rr, req)
	return rr
}

func TestHealthz(t *testing.T) {
	body := []byte("audio")
	origin := fakeOrigin(t, body, "audio/mpeg", http.StatusOK)
	defer origin.Close()
	h := newTestHandler(t, origin, true)

	rr := get(t, h, "/healthz")
	if rr.Code != http.StatusOK {
		t.Fatalf("healthz code = %d", rr.Code)
	}
}

func TestCacheClearAuthAndMethod(t *testing.T) {
	origin := fakeOrigin(t, []byte("audio"), "audio/mpeg", http.StatusOK)
	defer origin.Close()
	h := newTestHandler(t, origin, true)

	rr := get(t, h, "/api/cache/clear") // GET, no token -> method check first
	if rr.Code != http.StatusMethodNotAllowed {
		t.Fatalf("GET code = %d, want 405", rr.Code)
	}
	req := httptest.NewRequest(http.MethodPost, "/api/cache/clear", nil) // POST, no token
	rr2 := httptest.NewRecorder()
	h.Routes().ServeHTTP(rr2, req)
	if rr2.Code != http.StatusUnauthorized {
		t.Fatalf("no-token POST code = %d, want 401", rr2.Code)
	}
	req = httptest.NewRequest(http.MethodGet, "/api/cache/clear?tok="+testToken, nil)
	rr3 := httptest.NewRecorder()
	h.Routes().ServeHTTP(rr3, req)
	if rr3.Code != http.StatusMethodNotAllowed {
		t.Fatalf("GET-with-token code = %d, want 405", rr3.Code)
	}
	if u := h.cache.Usage(); u.Files != 0 {
		t.Fatalf("cache not empty after rejected clears: %+v", u)
	}
}

func TestCacheClearRemovesFiles(t *testing.T) {
	body := []byte("0123456789")
	origin := fakeOrigin(t, body, "audio/mpeg", http.StatusOK)
	defer origin.Close()
	h := newTestHandler(t, origin, true)

	// Fill the cache by streaming a full surah.
	rr := get(t, h, "/stream?tok="+testToken+"&reciter=ar.alafasy&surah=1")
	if rr.Code != http.StatusOK {
		t.Fatalf("stream code = %d", rr.Code)
	}
	if u := h.cache.Usage(); u.Files != 1 || u.Bytes == 0 {
		t.Fatalf("pre-clear usage = %+v, want 1 file", u)
	}
	entry, err := h.cache.Entry("ar.alafasy", 1)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(entry.DataPath()); err != nil {
		t.Fatalf("dat missing before clear: %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, "/api/cache/clear?tok="+testToken, nil)
	rr2 := httptest.NewRecorder()
	h.Routes().ServeHTTP(rr2, req)
	if rr2.Code != http.StatusOK {
		t.Fatalf("clear code = %d, want 200", rr2.Code)
	}
	if u := h.cache.Usage(); u.Files != 0 || u.Bytes != 0 {
		t.Fatalf("post-clear usage = %+v, want empty", u)
	}
	if _, err := os.Stat(entry.DataPath()); !os.IsNotExist(err) {
		t.Error("dat still on disk after clear")
	}
}

func TestStreamAuth(t *testing.T) {
	origin := fakeOrigin(t, []byte("audio"), "audio/mpeg", http.StatusOK)
	defer origin.Close()
	h := newTestHandler(t, origin, true)

	cases := []struct {
		name string
		path string
		want int
	}{
		{"missing token", "/stream?reciter=ar.alafasy&surah=1", http.StatusUnauthorized},
		{"bad token", "/stream?tok=deadbeef&reciter=ar.alafasy&surah=1", http.StatusUnauthorized},
		{"short token", "/stream?tok=ab&reciter=ar.alafasy&surah=1", http.StatusUnauthorized},
	}
	for _, c := range cases {
		if rr := get(t, h, c.path); rr.Code != c.want {
			t.Errorf("%s: code = %d, want %d", c.name, rr.Code, c.want)
		}
	}
}

func TestStreamValidation(t *testing.T) {
	origin := fakeOrigin(t, []byte("audio"), "audio/mpeg", http.StatusOK)
	defer origin.Close()
	h := newTestHandler(t, origin, true)

	cases := []struct {
		name string
		path string
		want int
	}{
		{"invalid surah", "/stream?tok=" + testToken + "&reciter=ar.alafasy&surah=115", http.StatusBadRequest},
		{"junk surah", "/stream?tok=" + testToken + "&reciter=ar.alafasy&surah=1junk", http.StatusBadRequest},
		{"missing surah", "/stream?tok=" + testToken + "&reciter=ar.alafasy", http.StatusBadRequest},
		{"unsafe reciter id", "/stream?tok=" + testToken + "&reciter=../etc&surah=1", http.StatusBadRequest},
	}
	for _, c := range cases {
		if rr := get(t, h, c.path); rr.Code != c.want {
			t.Errorf("%s: code = %d, want %d", c.name, rr.Code, c.want)
		}
	}
}

func TestStreamUnknownReciter(t *testing.T) {
	origin := fakeOrigin(t, []byte("audio"), "audio/mpeg", http.StatusOK)
	defer origin.Close()
	h := newTestHandler(t, origin, false) // empty catalog
	rr := get(t, h, "/stream?tok="+testToken+"&reciter=ar.alafasy&surah=1")
	if rr.Code != http.StatusNotFound {
		t.Fatalf("code = %d, want 404", rr.Code)
	}
}

func TestStreamPassthrough(t *testing.T) {
	body := []byte("id3 fake mp3 bytes for full stream")
	origin := fakeOrigin(t, body, "audio/mpeg", http.StatusOK)
	defer origin.Close()
	h := newTestHandler(t, origin, true)

	rr := get(t, h, "/stream?tok="+testToken+"&reciter=ar.alafasy&surah=1")
	if rr.Code != http.StatusOK {
		t.Fatalf("code = %d, want 200 (body=%s)", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("Content-Type") != "audio/mpeg" {
		t.Errorf("content-type = %q", rr.Header().Get("Content-Type"))
	}
	if rr.Body.String() != string(body) {
		t.Errorf("body = %q, want %q", rr.Body.String(), body)
	}
}

func TestStreamRangeForwarded(t *testing.T) {
	body := []byte("0123456789abcdefghij") // 20 bytes
	origin := fakeOrigin(t, body, "audio/mpeg", http.StatusOK)
	defer origin.Close()
	h := newTestHandler(t, origin, true)

	req := httptest.NewRequest(http.MethodGet,
		"/stream?tok="+testToken+"&reciter=ar.alafasy&surah=1", nil)
	req.Header.Set("Range", "bytes=2-9")
	rr := httptest.NewRecorder()
	h.Routes().ServeHTTP(rr, req)

	if rr.Code != http.StatusPartialContent {
		t.Fatalf("code = %d, want 206", rr.Code)
	}
	if rr.Header().Get("Content-Range") != "bytes 2-9/20" {
		t.Errorf("content-range = %q", rr.Header().Get("Content-Range"))
	}
	if rr.Body.String() != "23456789" {
		t.Errorf("body = %q, want 23456789", rr.Body.String())
	}
}

func TestStreamRedirectNotFollowed(t *testing.T) {
	// origin serves 302 with a Location; the proxy must surface it as a failure
	// (502) rather than following to the target.
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Location", "https://evil.example.com/audio.mp3")
		w.WriteHeader(http.StatusFound)
	}))
	defer origin.Close()
	h := newTestHandler(t, origin, true)

	rr := get(t, h, "/stream?tok="+testToken+"&reciter=ar.alafasy&surah=1")
	if rr.Code != http.StatusBadGateway {
		t.Fatalf("code = %d, want 502", rr.Code)
	}
}

func TestStreamBadContentType(t *testing.T) {
	origin := fakeOrigin(t, []byte("nope"), "text/html", http.StatusOK)
	defer origin.Close()
	h := newTestHandler(t, origin, true)
	rr := get(t, h, "/stream?tok="+testToken+"&reciter=ar.alafasy&surah=1")
	if rr.Code != http.StatusBadGateway {
		t.Fatalf("code = %d, want 502", rr.Code)
	}
}

func TestStreamOversized(t *testing.T) {
	// content-length beyond maxSurahBytes must be refused.
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "audio/mpeg")
		w.Header().Set("Content-Length", "999999999999")
		w.WriteHeader(http.StatusOK)
	}))
	defer origin.Close()
	h := newTestHandler(t, origin, true)
	rr := get(t, h, "/stream?tok="+testToken+"&reciter=ar.alafasy&surah=1")
	if rr.Code != http.StatusBadGateway {
		t.Fatalf("code = %d, want 502", rr.Code)
	}
}

func TestStreamCacheHitServesFromDisk(t *testing.T) {
	// The first request fetches + caches; a second request for the same range
	// must be served from the .dat without another origin GET (and a HEAD is
	// not repeated either).
	var gets, heads int32
	body := []byte("0123456789abcdefghij") // 20 bytes
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodHead {
			atomic.AddInt32(&heads, 1)
			w.Header().Set("Content-Type", "audio/mpeg")
			w.Header().Set("Content-Length", fmt.Sprintf("%d", len(body)))
			w.WriteHeader(http.StatusOK)
			return
		}
		atomic.AddInt32(&gets, 1)
		if rng := r.Header.Get("Range"); rng != "" {
			start, end, ok := parseSimpleRange(rng, int64(len(body)))
			if !ok {
				w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
				return
			}
			w.Header().Set("Content-Type", "audio/mpeg")
			w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, len(body)))
			w.Header().Set("Content-Length", fmt.Sprintf("%d", end-start+1))
			w.WriteHeader(http.StatusPartialContent)
			w.Write(body[start : end+1])
			return
		}
		w.Header().Set("Content-Type", "audio/mpeg")
		w.WriteHeader(http.StatusOK)
		w.Write(body)
	}))
	defer origin.Close()
	h := newTestHandler(t, origin, true)

	rr1 := get(t, h, "/stream?tok="+testToken+"&reciter=ar.alafasy&surah=1")
	if rr1.Code != http.StatusOK || rr1.Body.String() != string(body) {
		t.Fatalf("first: code=%d body=%q", rr1.Code, rr1.Body.String())
	}
	rr2 := get(t, h, "/stream?tok="+testToken+"&reciter=ar.alafasy&surah=1")
	if rr2.Code != http.StatusOK || rr2.Body.String() != string(body) {
		t.Fatalf("second: code=%d body=%q", rr2.Code, rr2.Body.String())
	}
	if got := atomic.LoadInt32(&gets); got != 1 {
		t.Errorf("origin GETs = %d, want 1 (second request served from cache)", got)
	}
	if got := atomic.LoadInt32(&heads); got != 1 {
		t.Errorf("origin HEADs = %d, want 1", got)
	}
}

func TestStreamStraddledRange(t *testing.T) {
	// Prime the cache with [0,10), then request [0,20): the response must mix
	// a cached segment and one fresh origin fetch.
	body := []byte("0123456789abcdefghij") // 20 bytes
	origin := fakeOrigin(t, body, "audio/mpeg", http.StatusOK)
	defer origin.Close()
	h := newTestHandler(t, origin, true)

	req1 := httptest.NewRequest(http.MethodGet,
		"/stream?tok="+testToken+"&reciter=ar.alafasy&surah=1", nil)
	req1.Header.Set("Range", "bytes=0-9")
	rr1 := httptest.NewRecorder()
	h.Routes().ServeHTTP(rr1, req1)
	if rr1.Code != http.StatusPartialContent || rr1.Body.String() != "0123456789" {
		t.Fatalf("prime: code=%d body=%q", rr1.Code, rr1.Body.String())
	}

	req2 := httptest.NewRequest(http.MethodGet,
		"/stream?tok="+testToken+"&reciter=ar.alafasy&surah=1", nil)
	req2.Header.Set("Range", "bytes=0-19")
	rr2 := httptest.NewRecorder()
	h.Routes().ServeHTTP(rr2, req2)
	if rr2.Code != http.StatusPartialContent {
		t.Fatalf("straddle: code=%d", rr2.Code)
	}
	if rr2.Body.String() != string(body) {
		t.Errorf("straddle body = %q, want %q", rr2.Body.String(), body)
	}
}

func TestStreamUnsatisfiableRange(t *testing.T) {
	origin := fakeOrigin(t, []byte("0123456789"), "audio/mpeg", http.StatusOK)
	defer origin.Close()
	h := newTestHandler(t, origin, true)

	req := httptest.NewRequest(http.MethodGet,
		"/stream?tok="+testToken+"&reciter=ar.alafasy&surah=1", nil)
	req.Header.Set("Range", "bytes=999-")
	rr := httptest.NewRecorder()
	h.Routes().ServeHTTP(rr, req)
	if rr.Code != http.StatusRequestedRangeNotSatisfiable {
		t.Fatalf("code = %d, want 416", rr.Code)
	}
}

func TestStreamSharedFill(t *testing.T) {
	// Two concurrent requests for the same missing segment must trigger one
	// origin GET (inflight sharing).
	var gets int32
	body := []byte(strings.Repeat("z", 4096))
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodHead {
			w.Header().Set("Content-Type", "audio/mpeg")
			w.Header().Set("Content-Length", fmt.Sprintf("%d", len(body)))
			w.WriteHeader(http.StatusOK)
			return
		}
		atomic.AddInt32(&gets, 1)
		time.Sleep(50 * time.Millisecond) // widen the window for sharing
		if rng := r.Header.Get("Range"); rng != "" {
			start, end, ok := parseSimpleRange(rng, int64(len(body)))
			if !ok {
				w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
				return
			}
			w.Header().Set("Content-Type", "audio/mpeg")
			w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, len(body)))
			w.Header().Set("Content-Length", fmt.Sprintf("%d", end-start+1))
			w.WriteHeader(http.StatusPartialContent)
			w.Write(body[start : end+1])
			return
		}
		w.Header().Set("Content-Type", "audio/mpeg")
		w.WriteHeader(http.StatusOK)
		w.Write(body)
	}))
	defer origin.Close()
	h := newTestHandler(t, origin, true)

	var wg sync.WaitGroup
	res := make([]*httptest.ResponseRecorder, 2)
	for i := range res {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			res[i] = get(t, h, "/stream?tok="+testToken+"&reciter=ar.alafasy&surah=1")
		}(i)
	}
	wg.Wait()
	for i, rr := range res {
		if rr.Code != http.StatusOK || rr.Body.Len() != len(body) {
			t.Errorf("req %d: code=%d len=%d", i, rr.Code, rr.Body.Len())
		}
	}
	if got := atomic.LoadInt32(&gets); got != 1 {
		t.Errorf("origin GETs = %d, want 1 (shared fill)", got)
	}
}

func TestStreamCooldownAfterFailure(t *testing.T) {
	// A redirecting origin makes every fetch fail; after the first, the next
	// request inside the window must be refused with 425.
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Location", "/x")
		w.WriteHeader(http.StatusFound)
	}))
	defer origin.Close()
	h := newTestHandler(t, origin, true)

	rr1 := get(t, h, "/stream?tok="+testToken+"&reciter=ar.alafasy&surah=1")
	if rr1.Code != http.StatusBadGateway {
		t.Fatalf("first code = %d, want 502", rr1.Code)
	}
	if !h.Cooldown().Active("ar.alafasy:1", h.now()) {
		t.Fatal("cooldown not armed after failure")
	}
	rr2 := get(t, h, "/stream?tok="+testToken+"&reciter=ar.alafasy&surah=1")
	if rr2.Code != http.StatusTooEarly {
		t.Fatalf("second code = %d, want 425 (cooldown)", rr2.Code)
	}
}

func TestStreamBodyCopy(t *testing.T) {
	// HEAD advertises a small size; the GET streams chunked with no
	// Content-Length and more bytes than the cap. The handler must serve at
	// most the advertised length (curl --max-filesize analog).
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "audio/mpeg")
		if r.Method == http.MethodHead {
			w.Header().Set("Content-Length", "100")
			w.WriteHeader(http.StatusOK)
			return
		}
		w.WriteHeader(http.StatusOK)
		if f, ok := w.(http.Flusher); ok {
			f.Flush() // force chunked: no Content-Length on the GET
		}
		io.WriteString(w, strings.Repeat("x", 500))
	}))
	defer origin.Close()

	store := catalog.NewStore(&catalog.State{
		Reciters: []catalog.Reciter{{Identifier: "ar.alafasy"}},
	})
	h := New(store, dialer.NoRedirectClient(), session.NewFromString(testToken),
		rangecache.New(t.TempDir(), 1<<30), 4, 314572800)
	h.SetBuildURL(func(id string, n int) string {
		return origin.URL + "/" + id + ".mp3"
	})
	rr := get(t, h, "/stream?tok="+testToken+"&reciter=ar.alafasy&surah=1")
	if rr.Code != http.StatusOK {
		t.Fatalf("code = %d", rr.Code)
	}
	if got := rr.Body.Len(); got != 100 {
		t.Errorf("served %d bytes, want 100 (advertised length)", got)
	}
}

func TestPromotionEmitted(t *testing.T) {
	body := []byte(strings.Repeat("a", 4096))
	origin := fakeOrigin(t, body, "audio/mpeg", http.StatusOK)
	defer origin.Close()
	h := newTestHandler(t, origin, true)

	var stdout bytes.Buffer
	var promotedSrc, promotedRec string
	var promotedN int
	h.SetStdout(&stdout)
	h.validateFile = func(path string) error {
		if _, err := os.Stat(path); err != nil {
			t.Errorf("validate source missing: %v", err)
		}
		return nil
	}
	h.promoteFile = func(src, dstRoot, reciter string, n int) error {
		promotedSrc, promotedRec, promotedN = src, reciter, n
		return nil
	}
	h.stateDir = "/state"

	rr := get(t, h, "/stream?tok="+testToken+"&reciter=ar.alafasy&surah=1")
	if rr.Code != http.StatusOK || rr.Body.Len() != len(body) {
		t.Fatalf("code=%d len=%d", rr.Code, rr.Body.Len())
	}
	if got := stdout.String(); got != "promoted ar.alafasy 1\n" {
		t.Errorf("stdout = %q", got)
	}
	if promotedRec != "ar.alafasy" || promotedN != 1 || !strings.HasSuffix(promotedSrc, "/ar.alafasy/1.dat") {
		t.Errorf("promote args = (%q,%q,%d)", promotedSrc, promotedRec, promotedN)
	}
	if u := h.cache.Usage(); u.Bytes != 0 || u.Files != 0 {
		t.Errorf("cache after promote = %+v, want empty", u)
	}
}

func TestPromotionValidationFailure(t *testing.T) {
	body := []byte(strings.Repeat("b", 4096))
	origin := fakeOrigin(t, body, "audio/mpeg", http.StatusOK)
	defer origin.Close()
	h := newTestHandler(t, origin, true)
	h.SetNow(func() int64 { return 1234 })
	h.validateFile = func(path string) error { return errors.New("bad mime") }
	h.promoteFile = func(src, dstRoot, reciter string, n int) error {
		t.Fatal("promote must not run on validation failure")
		return nil
	}

	rr := get(t, h, "/stream?tok="+testToken+"&reciter=ar.alafasy&surah=1")
	if rr.Code != http.StatusOK {
		t.Fatalf("first code=%d", rr.Code)
	}
	if u := h.cache.Usage(); u.Bytes != 0 {
		t.Errorf("cache after validation failure = %+v, want empty", u)
	}
	// Cooldown armed by the failed validation: next request refused.
	rr2 := get(t, h, "/stream?tok="+testToken+"&reciter=ar.alafasy&surah=1")
	if rr2.Code != http.StatusTooEarly {
		t.Errorf("second code = %d, want 425 (cooldown after validation failure)", rr2.Code)
	}
}

func TestPromotionFailureKeepsCache(t *testing.T) {
	body := []byte(strings.Repeat("c", 4096))
	origin := fakeOrigin(t, body, "audio/mpeg", http.StatusOK)
	defer origin.Close()
	h := newTestHandler(t, origin, true)
	h.validateFile = func(path string) error { return nil }
	h.promoteFile = func(src, dstRoot, reciter string, n int) error {
		return errors.New("disk full")
	}

	rr := get(t, h, "/stream?tok="+testToken+"&reciter=ar.alafasy&surah=1")
	if rr.Code != http.StatusOK {
		t.Fatalf("code=%d", rr.Code)
	}
	if u := h.cache.Usage(); u.Bytes != int64(len(body)) {
		t.Errorf("cache after promote failure = %+v, want entry kept", u)
	}
}

func TestPromotionDisabledByDefault(t *testing.T) {
	body := []byte(strings.Repeat("d", 4096))
	origin := fakeOrigin(t, body, "audio/mpeg", http.StatusOK)
	defer origin.Close()
	h := newTestHandler(t, origin, true)

	var stdout bytes.Buffer
	h.SetStdout(&stdout)

	rr := get(t, h, "/stream?tok="+testToken+"&reciter=ar.alafasy&surah=1")
	if rr.Code != http.StatusOK {
		t.Fatalf("code=%d", rr.Code)
	}
	if stdout.Len() != 0 {
		t.Errorf("stdout = %q, want no promoted event without EnablePromotion", stdout.String())
	}
	if u := h.cache.Usage(); u.Bytes != int64(len(body)) {
		t.Errorf("cache = %+v, want entry retained", u)
	}
}

func TestStreamNoAcceptRangesFallback(t *testing.T) {
	// Origin ignores Range entirely (no Accept-Ranges support) and always
	// returns 200 with the full body: the proxy must discard the lead-in and
	// serve the requested sub-range, caching only the segment bytes.
	body := []byte("0123456789abcdefghij") // 20 bytes
	var gets int32
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodHead {
			w.Header().Set("Content-Type", "audio/mpeg")
			w.Header().Set("Content-Length", fmt.Sprintf("%d", len(body)))
			w.WriteHeader(http.StatusOK)
			return
		}
		atomic.AddInt32(&gets, 1)
		w.Header().Set("Content-Type", "audio/mpeg")
		w.Header().Set("Content-Length", fmt.Sprintf("%d", len(body)))
		w.WriteHeader(http.StatusOK)
		w.Write(body)
	}))
	defer origin.Close()
	h := newTestHandler(t, origin, true)

	req := httptest.NewRequest(http.MethodGet,
		"/stream?tok="+testToken+"&reciter=ar.alafasy&surah=1", nil)
	req.Header.Set("Range", "bytes=5-14")
	rr := httptest.NewRecorder()
	h.Routes().ServeHTTP(rr, req)
	if rr.Code != http.StatusPartialContent {
		t.Fatalf("code=%d", rr.Code)
	}
	if got := rr.Body.String(); got != "56789abcde" {
		t.Errorf("body=%q, want bytes 5-14", got)
	}
	if got := atomic.LoadInt32(&gets); got != 1 {
		t.Errorf("origin GETs = %d, want 1", got)
	}
}

func TestStreamAdversarialGETRedirect(t *testing.T) {
	// HEAD succeeds (size + audio MIME) but GET redirects: the proxy must NOT
	// follow it and must abort the stream (headers already committed).
	body := []byte(strings.Repeat("r", 4096))
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodHead {
			w.Header().Set("Content-Type", "audio/mpeg")
			w.Header().Set("Content-Length", fmt.Sprintf("%d", len(body)))
			w.WriteHeader(http.StatusOK)
			return
		}
		w.Header().Set("Location", "http://evil.example/x.mp3")
		w.WriteHeader(http.StatusFound)
	}))
	defer origin.Close()
	h := newTestHandler(t, origin, true)

	rr := get(t, h, "/stream?tok="+testToken+"&reciter=ar.alafasy&surah=1")
	// The GET redirect was not followed; headers were already committed, so
	// the client sees a truncated stream and zero bytes from the redirecting
	// origin.
	if rr.Body.Len() != 0 {
		t.Errorf("served %d bytes from a redirecting origin, want 0", rr.Body.Len())
	}
}

func TestStreamAdversarialGETWrongMime(t *testing.T) {
	// HEAD claims audio, GET returns an HTML error page: mid-fetch MIME gate.
	body := []byte("<html>not audio</html>")
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodHead {
			w.Header().Set("Content-Type", "audio/mpeg")
			w.Header().Set("Content-Length", fmt.Sprintf("%d", len(body)))
			w.WriteHeader(http.StatusOK)
			return
		}
		w.Header().Set("Content-Type", "text/html")
		w.WriteHeader(http.StatusOK)
		w.Write(body)
	}))
	defer origin.Close()
	h := newTestHandler(t, origin, true)

	rr := get(t, h, "/stream?tok="+testToken+"&reciter=ar.alafasy&surah=1")
	// Headers were already committed as 200/206 before the mid-fetch MIME gate
	// fired, so the client sees a truncated stream — the crucial property is
	// that the HTML body was NEVER forwarded.
	if rr.Body.Len() != 0 {
		t.Errorf("served %d bytes of a non-audio origin body, want 0", rr.Body.Len())
	}
	if strings.Contains(rr.Body.String(), "<html>") {
		t.Error("origin HTML leaked into the stream")
	}
}

func FuzzParseRange(f *testing.F) {
	seeds := []string{
		"", "bytes=0-10", "bytes=10-", "bytes=-5", "bytes=0-0",
		"bytes=999-", "bytes=-999", "bytes=1-0", "bytes=1,2-3",
		"bytes=0-", "bytes=abc-def", "bytes=-0", "items=0-2",
		"bytes=0-18446744073709551616", "bytes=-18446744073709551616",
		"bytes= 0-5", "bytes=0 -5", "bytes=0-5 ", "bytes=%00",
	}
	for _, s := range seeds {
		f.Add(s, int64(100))
	}
	f.Add("bytes=0-1023", int64(705309))
	f.Add("bytes=-suffix", int64(10))
	f.Fuzz(func(t *testing.T, header string, size int64) {
		if size < 0 {
			return
		}
		start, end, partial := parseRange(header, size)
		if !partial {
			return
		}
		// start==end>=size is the unsatisfiable marker the caller turns into
		// 416; every other accepted range must be well-formed and satisfiable.
		if start == end && start >= size {
			return
		}
		if start < 0 || end < start || (size > 0 && end > size) {
			t.Fatalf("invalid range bounds %d-%d for %q size %d", start, end, header, size)
		}
	})
}
