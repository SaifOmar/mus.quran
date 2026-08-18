package fetch

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"quranproxyd/internal/dialer"
)

// origin builds a fake CDN: serves HEAD with a content type, honors Range GETs
// with 206, and counts requests. body writes are wrapped so a resume test can
// detect a Range request.
func origin(t *testing.T, body []byte, ct string, status int) (*httptest.Server, *atomic.Int32, *atomic.Bool) {
	t.Helper()
	var heads atomic.Int32
	var ranged atomic.Bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/redir" {
			w.Header().Set("Location", "/nowhere")
			w.WriteHeader(http.StatusFound)
			return
		}
		w.Header().Set("Content-Type", ct)
		if r.Method == http.MethodHead {
			heads.Add(1)
			w.Header().Set("Content-Length", fmt.Sprintf("%d", len(body)))
			w.WriteHeader(status)
			return
		}
		if rng := r.Header.Get("Range"); rng != "" {
			ranged.Store(true)
			var start int64
			if _, err := fmt.Sscanf(rng, "bytes=%d-", &start); err != nil {
				w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
				return
			}
			if start < 0 || start >= int64(len(body)) {
				w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
				return
			}
			w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, len(body)-1, len(body)))
			w.Header().Set("Content-Length", fmt.Sprintf("%d", len(body)-int(start)))
			w.WriteHeader(http.StatusPartialContent)
			w.Write(body[start:])
			return
		}
		w.Header().Set("Content-Length", fmt.Sprintf("%d", len(body)))
		w.WriteHeader(status)
		w.Write(body)
	}))
	return srv, &heads, &ranged
}

// setup wires a fetch Options against a fake origin with a plain client
// (dialer.NoRedirectClient, no pinning — the URL builder points straight at
// the httptest server).
func setup(t *testing.T, body []byte, ct string, status int) (Options, *httptest.Server, *atomic.Int32, *atomic.Bool) {
	t.Helper()
	srv, heads, ranged := origin(t, body, ct, status)
	opts := Options{
		Client:   dialer.NoRedirectClient(),
		DestRoot: t.TempDir(),
		Reciter:  "ar.alafasy",
		Surah:    1,
		URL: func(n int) (string, error) {
			return srv.URL + "/audio/" + fmt.Sprintf("%d", n) + ".mp3", nil
		},
	}
	return opts, srv, heads, ranged
}

func TestFetchFresh(t *testing.T) {
	body := []byte("0123456789abcdef")
	opts, srv, heads, _ := setup(t, body, "audio/mpeg", http.StatusOK)
	defer srv.Close()

	if err := Fetch(context.Background(), opts); err != nil {
		t.Fatalf("Fetch: %v", err)
	}
	got, err := os.ReadFile(filepath.Join(opts.DestRoot, "ar.alafasy", "1.mp3"))
	if err != nil {
		t.Fatalf("read target: %v", err)
	}
	if string(got) != string(body) {
		t.Fatalf("content = %q, want %q", got, body)
	}
	if heads.Load() != 1 {
		t.Fatalf("HEAD count = %d, want 1", heads.Load())
	}
	// No leftover staging files.
	matches, _ := filepath.Glob(filepath.Join(opts.DestRoot, "ar.alafasy", "1.mp3.part*"))
	if len(matches) != 0 {
		t.Fatalf("staging files left behind: %v", matches)
	}
}

func TestFetchCompleteSkipsNetwork(t *testing.T) {
	body := []byte("0123456789abcdef")
	opts, srv, heads, _ := setup(t, body, "audio/mpeg", http.StatusOK)
	defer srv.Close()
	target := filepath.Join(opts.DestRoot, "ar.alafasy", "1.mp3")
	if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, body, 0o600); err != nil {
		t.Fatal(err)
	}

	err := Fetch(context.Background(), opts)
	if !errors.Is(err, ErrComplete) {
		t.Fatalf("Fetch = %v, want ErrComplete", err)
	}
	if heads.Load() != 1 {
		t.Fatalf("HEAD count = %d, want 1 (probe still runs)", heads.Load())
	}
}

func TestFetchResume(t *testing.T) {
	body := []byte("0123456789abcdef")
	opts, srv, _, ranged := setup(t, body, "audio/mpeg", http.StatusOK)
	defer srv.Close()
	target := filepath.Join(opts.DestRoot, "ar.alafasy", "1.mp3")
	if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
		t.Fatal(err)
	}
	// A crash left a partial: 8 of 16 bytes, named like an old download.sh
	// .part would be.
	if err := os.WriteFile(filepath.Join(filepath.Dir(target), "1.mp3.part"), body[:8], 0o600); err != nil {
		t.Fatal(err)
	}

	if err := Fetch(context.Background(), opts); err != nil {
		t.Fatalf("Fetch: %v", err)
	}
	got, err := os.ReadFile(target)
	if err != nil {
		t.Fatalf("read target: %v", err)
	}
	if string(got) != string(body) {
		t.Fatalf("content = %q, want %q", got, body)
	}
	if !ranged.Load() {
		t.Fatal("expected a Range request for the resume")
	}
}

func TestFetchStalePartDropped(t *testing.T) {
	body := []byte("0123456789abcdef")
	opts, srv, _, ranged := setup(t, body, "audio/mpeg", http.StatusOK)
	defer srv.Close()
	target := filepath.Join(opts.DestRoot, "ar.alafasy", "1.mp3")
	if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
		t.Fatal(err)
	}
	// A stale part larger than the remote (changed remote content): dropped.
	if err := os.WriteFile(filepath.Join(filepath.Dir(target), "1.mp3.part.999"), []byte("this is way too long a partial file for a 16-byte remote"), 0o600); err != nil {
		t.Fatal(err)
	}

	if err := Fetch(context.Background(), opts); err != nil {
		t.Fatalf("Fetch: %v", err)
	}
	got, err := os.ReadFile(target)
	if err != nil {
		t.Fatalf("read target: %v", err)
	}
	if string(got) != string(body) {
		t.Fatalf("content = %q, want %q", got, body)
	}
	if ranged.Load() {
		t.Fatal("stale part must not trigger a Range resume")
	}
	matches, _ := filepath.Glob(filepath.Join(opts.DestRoot, "ar.alafasy", "1.mp3.part*"))
	if len(matches) != 0 {
		t.Fatalf("stale part not cleaned up: %v", matches)
	}
}

func TestFetchRejectsWrongMime(t *testing.T) {
	body := []byte("<html>not audio</html>")
	opts, srv, _, _ := setup(t, body, "text/html", http.StatusOK)
	defer srv.Close()
	if err := Fetch(context.Background(), opts); err == nil || !strings.Contains(err.Error(), "content type") {
		t.Fatalf("Fetch = %v, want content-type rejection", err)
	}
	if _, err := os.Stat(filepath.Join(opts.DestRoot, "ar.alafasy", "1.mp3")); !os.IsNotExist(err) {
		t.Fatalf("target must not exist after rejection")
	}
}

func TestFetchRejectsRedirect(t *testing.T) {
	body := []byte("0123456789abcdef")
	opts, srv, _, _ := setup(t, body, "audio/mpeg", http.StatusFound)
	defer srv.Close()
	opts.URL = func(n int) (string, error) {
		return srv.URL + "/redir", nil
	}
	if err := Fetch(context.Background(), opts); err == nil || !strings.Contains(err.Error(), "status") {
		t.Fatalf("Fetch = %v, want redirect rejection", err)
	}
}

func TestFetchRejectsOversized(t *testing.T) {
	body := []byte("0123456789abcdef")
	opts, srv, _, _ := setup(t, body, "audio/mpeg", http.StatusOK)
	defer srv.Close()
	opts.MaxBytes = 10
	if err := Fetch(context.Background(), opts); err == nil || !strings.Contains(err.Error(), "exceeds cap") {
		t.Fatalf("Fetch = %v, want size cap rejection", err)
	}
}

func TestFetchRejectsBadURL(t *testing.T) {
	opts := Options{
		Client:   dialer.NoRedirectClient(),
		DestRoot: t.TempDir(),
		Reciter:  "ar.alafasy",
		Surah:    1,
		URL: func(n int) (string, error) {
			return "", nil
		},
	}
	if err := Fetch(context.Background(), opts); err == nil || !strings.Contains(err.Error(), "invalid origin URL") {
		t.Fatalf("Fetch = %v, want URL rejection", err)
	}
}

func TestFetchRejectsTraversal(t *testing.T) {
	body := []byte("0123456789abcdef")
	opts, srv, _, _ := setup(t, body, "audio/mpeg", http.StatusOK)
	defer srv.Close()
	opts.Reciter = "../escape"
	if err := Fetch(context.Background(), opts); err == nil {
		t.Fatal("Fetch must reject a traversal reciter")
	}
	opts.Reciter = ".."
	if err := Fetch(context.Background(), opts); err == nil {
		t.Fatal("Fetch must reject '..'")
	}
}

func TestFetchSymlinkedReciterDirRejected(t *testing.T) {
	body := []byte("0123456789abcdef")
	opts, srv, _, _ := setup(t, body, "audio/mpeg", http.StatusOK)
	defer srv.Close()
	outside := t.TempDir()
	// Plant a symlink where the reciter dir would be created.
	if err := os.MkdirAll(opts.DestRoot, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(opts.DestRoot, "ar.alafasy")); err != nil {
		t.Fatal(err)
	}
	if err := Fetch(context.Background(), opts); err == nil || !strings.Contains(err.Error(), "escapes") {
		t.Fatalf("Fetch = %v, want symlink-escape rejection", err)
	}
}

func TestFetchProgress(t *testing.T) {
	body := []byte("0123456789abcdef")
	opts, srv, _, _ := setup(t, body, "audio/mpeg", http.StatusOK)
	defer srv.Close()
	var lastWritten, lastTotal int64
	opts.OnProgress = func(w, tot int64) {
		lastWritten, lastTotal = w, tot
	}
	if err := Fetch(context.Background(), opts); err != nil {
		t.Fatalf("Fetch: %v", err)
	}
	if lastWritten != int64(len(body)) || lastTotal != int64(len(body)) {
		t.Fatalf("final progress = %d/%d, want %d/%d", lastWritten, lastTotal, len(body), len(body))
	}
}
