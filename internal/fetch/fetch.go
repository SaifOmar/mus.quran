// Package fetch implements download.sh's single-surah fetch for quranctl:
// HEAD size probe with content-type gate, complete() skip, stale-part drop,
// conditional Range resume, and an atomic .part.<pid> -> .mp3 rename. It is
// compiled into the short-lived quranctl binary so the fallback download path
// uses the exact same URL policy (urlsafety) and transport (dialer) as the
// daemon — one implementation, two binaries.
package fetch

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"quranproxyd/internal/dialer"
	"quranproxyd/internal/urlsafety"
)

// ErrComplete reports that the local file already exists and matches the
// remote size (download.sh complete()); the caller counts it as success.
var ErrComplete = errors.New("fetch: already complete")

// reciterRE mirrors cache.sh check_reciter / promote.
var reciterRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*$`)

const writeBuf = 256 * 1024

// Options configures one surah fetch.
type Options struct {
	// Client is the outbound client (dialer.NewClient in production).
	Client *http.Client
	// URL builds the origin URL for a surah. Production callers wrap
	// urlsafety.AudioURL so the final URL is validated before any dial.
	URL func(n int) (string, error)
	// DestRoot is the permanent download root (state dir).
	DestRoot string
	Reciter  string
	Surah    int
	// MaxBytes caps the accepted remote size; 0 = urlsafety.MaxSurahBytes.
	MaxBytes int64
	// OnProgress reports cumulative bytes written vs the remote size.
	OnProgress func(written, total int64)
}

// Fetch downloads one surah into DestRoot/<reciter>/<n>.mp3.
//
//   - HEAD probes the remote (audio/* or application/octet-stream only,
//     0 < size <= MaxBytes); a local file of the exact remote size is
//     ErrComplete.
//   - An existing `<n>.mp3.part*` file smaller than the remote is resumed via
//     a conditional Range GET; a stale part (>= remote) is dropped.
//   - Staging uses a unique per-invocation temp name and an atomic rename, so
//     concurrent writers (e.g. the daemon's promote) can never interleave.
//   - On context cancellation the temp file is removed (download.sh parity).
func Fetch(ctx context.Context, o Options) error {
	if len(o.Reciter) == 0 || len(o.Reciter) > 64 || o.Reciter == "." || o.Reciter == ".." ||
		!reciterRE.MatchString(o.Reciter) {
		return errors.New("fetch: invalid reciter identifier")
	}
	if o.Surah < 1 || o.Surah > 114 {
		return errors.New("fetch: surah out of range")
	}
	max := o.MaxBytes
	if max <= 0 {
		max = urlsafety.MaxSurahBytes
	}
	if o.URL == nil {
		return errors.New("fetch: nil URL builder")
	}

	recDir, err := resolveReciterDir(o.DestRoot, o.Reciter)
	if err != nil {
		return err
	}

	target := filepath.Join(recDir, fmt.Sprintf("%d.mp3", o.Surah))

	remote, u, err := probe(o.Client, o.URL, o.Surah, max, ctx)
	if err != nil {
		return err
	}

	// complete(): the local file already matches the remote size.
	if fi, err := os.Lstat(target); err == nil && fi.Mode()&os.ModeSymlink == 0 {
		if fi.Mode().IsRegular() && fi.Size() == remote {
			return ErrComplete
		}
	}

	// Partial files: any `<n>.mp3.part*`; pick the newest.
	part := ""
	var partSize int64 = 0
	if matches, _ := filepath.Glob(filepath.Join(recDir, fmt.Sprintf("%d.mp3.part*", o.Surah))); len(matches) > 0 {
		var newest string
		var newestMod time.Time
		for _, m := range matches {
			if fi, err := os.Lstat(m); err == nil && fi.Mode()&os.ModeSymlink == 0 && fi.ModTime().After(newestMod) {
				newest, newestMod = m, fi.ModTime()
			}
		}
		if newest != "" {
			if fi, err := os.Lstat(newest); err == nil && fi.Size() < remote {
				part, partSize = newest, fi.Size()
			} else {
				// Stale (>= remote): drop it and start fresh.
				os.Remove(newest)
			}
		}
	}

	getCtx, cancel := context.WithTimeout(ctx, dialer.OverallTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(getCtx, http.MethodGet, u, nil)
	if err != nil {
		return fmt.Errorf("fetch: build request: %w", err)
	}
	req.Header.Set("Accept-Encoding", "identity")
	if part != "" {
		req.Header.Set("Range", fmt.Sprintf("bytes=%d-", partSize))
	}

	resp, err := o.Client.Do(req)
	if err != nil {
		return fmt.Errorf("fetch: get: %w", err)
	}
	defer resp.Body.Close()

	// 200 on a resume means the server ignored Range (restart from 0); 206
	// continues from the partial; anything else is a failure.
	start := int64(0)
	switch resp.StatusCode {
	case http.StatusOK:
		partSize = 0
	case http.StatusPartialContent:
		start = partSize
	default:
		io.Copy(io.Discard, resp.Body)
		return fmt.Errorf("fetch: origin returned status %d", resp.StatusCode)
	}

	tmp, err := os.CreateTemp(recDir, fmt.Sprintf("%d.mp3.part.", o.Surah))
	if err != nil {
		return fmt.Errorf("fetch: temp file: %w", err)
	}
	tmpName := tmp.Name()
	cleanup := func() {
		tmp.Close()
		os.Remove(tmpName)
	}
	defer func() {
		if tmpName != "" {
			cleanup()
		}
	}()

	if start > 0 {
		// Seed the fresh staging file with the partial's bytes so the
		// append below produces the full file.
		pf, err := os.Open(part)
		if err != nil {
			return fmt.Errorf("fetch: open partial: %w", err)
		}
		if _, err := io.Copy(tmp, pf); err != nil {
			pf.Close()
			return fmt.Errorf("fetch: seed partial: %w", err)
		}
		pf.Close()
	}

	buf := make([]byte, writeBuf)
	var written int64 = start
	lastEmit := time.Now()
	if o.OnProgress != nil {
		o.OnProgress(start, remote)
	}
	for {
		nr, rerr := resp.Body.Read(buf)
		if nr > 0 {
			if _, werr := tmp.Write(buf[:nr]); werr != nil {
				return fmt.Errorf("fetch: write: %w", werr)
			}
			written += int64(nr)
			if o.OnProgress != nil && (time.Since(lastEmit) > 200*time.Millisecond || rerr != nil) {
				o.OnProgress(written, remote)
				lastEmit = time.Now()
			}
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			return fmt.Errorf("fetch: read: %w", rerr)
		}
	}
	if written != remote {
		return fmt.Errorf("fetch: size mismatch (got %d, want %d)", written, remote)
	}
	if err := tmp.Sync(); err != nil {
		return fmt.Errorf("fetch: sync: %w", err)
	}
	if err := tmp.Chmod(0o600); err != nil {
		return fmt.Errorf("fetch: chmod: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("fetch: close: %w", err)
	}
	tmpName = "" // keep the temp; it becomes the target
	if err := os.Rename(tmp.Name(), target); err != nil {
		os.Remove(tmp.Name())
		return fmt.Errorf("fetch: rename: %w", err)
	}
	if o.OnProgress != nil {
		o.OnProgress(remote, remote)
	}
	return nil
}

// probe performs the HEAD size/content-type gate. Returns the remote size and
// the validated origin URL (reused verbatim for the GET).
func probe(cl *http.Client, buildURL func(n int) (string, error), n int, max int64, ctx context.Context) (int64, string, error) {
	u, err := buildURL(n)
	if err != nil {
		return 0, "", err
	}
	if u == "" {
		return 0, "", errors.New("fetch: invalid origin URL")
	}
	headCtx, cancel := context.WithTimeout(ctx, dialer.HeadTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(headCtx, http.MethodHead, u, nil)
	if err != nil {
		return 0, "", fmt.Errorf("fetch: head request: %w", err)
	}
	resp, err := cl.Do(req)
	if err != nil {
		return 0, "", fmt.Errorf("fetch: head: %w", err)
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 0, "", fmt.Errorf("fetch: origin head status %d", resp.StatusCode)
	}
	ct := strings.ToLower(resp.Header.Get("Content-Type"))
	if !strings.HasPrefix(ct, "audio/") && ct != "application/octet-stream" {
		return 0, "", fmt.Errorf("fetch: origin content type %q rejected", ct)
	}
	size := resp.ContentLength
	if size <= 0 {
		return 0, "", errors.New("fetch: origin missing content-length")
	}
	if size > max {
		return 0, "", fmt.Errorf("fetch: origin size %d exceeds cap %d", size, max)
	}
	return size, u, nil
}

// resolveReciterDir creates DestRoot (0700) and DestRoot/<reciter>, verifying
// after resolution that the reciter directory sits directly under the
// canonical root (rejects symlink escapes, mirroring promote).
func resolveReciterDir(destRoot, reciter string) (string, error) {
	if !filepath.IsAbs(destRoot) || strings.Contains(destRoot, "..") {
		return "", errors.New("fetch: invalid destination root")
	}
	if err := os.MkdirAll(destRoot, 0o700); err != nil {
		return "", fmt.Errorf("fetch: mkdir destination root: %w", err)
	}
	root, err := filepath.EvalSymlinks(destRoot)
	if err != nil {
		return "", fmt.Errorf("fetch: resolve destination root: %w", err)
	}
	recDir := filepath.Join(root, reciter)
	if err := os.MkdirAll(recDir, 0o700); err != nil {
		return "", fmt.Errorf("fetch: mkdir reciter dir: %w", err)
	}
	if real, err := filepath.EvalSymlinks(recDir); err != nil || real != filepath.Join(root, reciter) {
		return "", errors.New("fetch: reciter directory escapes destination root")
	}
	return recDir, nil
}
