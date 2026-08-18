// Package proxyhandler implements the local HTTP API the plugin drives:
//
//	GET /healthz                     -> 200 "ok" (no token)
//	GET /cache/usage                 -> {"bytes": N, "files": M} (no token)
//	GET /stream?tok=..&reciter=..&surah=..
//	                                   -> cached/streamed surah audio
//
// M2 scope: the /stream endpoint serves byte ranges from a sparse local cache
// (.dat + .meta.json sidecar), fetching missing segments from the origin via a
// DNS-pinned, redirect-rejecting client. A single 206/200 response header pair
// is sent (Content-Range + Content-Length); segmentation is internal: the body
// alternates ReadAt on cached segments with origin streaming into both the
// client and the cache (write -> fsync -> merge -> persist per chunk).
//
// Shared fills: concurrent requests for the same reciter:surah segment share
// one origin fetch (inflight). A disconnect cancels the shared fetch only when
// the last waiter leaves; abandoned fills keep their flushed bytes.
package proxyhandler

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"quranproxyd/internal/catalog"
	"quranproxyd/internal/dialer"
	"quranproxyd/internal/inflight"
	"quranproxyd/internal/mediavalidate"
	"quranproxyd/internal/promote"
	"quranproxyd/internal/rangecache"
	"quranproxyd/internal/session"
	"quranproxyd/internal/urlsafety"
)

// ErrNotFound distinguishes catalog-miss (404) from other failures.
var ErrNotFound = errors.New("catalog miss")

// writeChunk is the bounded size for streaming a missing segment into the
// cache. Each chunk is one write->fsync->merge->persist cycle.
const writeChunk = 256 * 1024

// Handler serves the proxy HTTP API. buildURL and head are overridable for
// tests; now is overridable for cooldown tests.
type Handler struct {
	store         *catalog.Store
	client        *http.Client
	token         *session.Token
	sem           chan struct{}
	maxSurahBytes int64
	cooldown      *urlsafety.Cooldown
	cache         *rangecache.Cache
	flights       *inflight.Manager
	buildURL      func(identifier string, n int) string
	now           func() int64
	logger        *log.Logger
	// validateFile/promoteFile are the M3 promotion gate. Both nil => disabled
	// (default, and in unit tests). EnablePromotion wires the real ones.
	validateFile func(path string) error
	promoteFile  func(src, dstRoot string, reciter string, n int) error
	stateDir     string
	// stdout is where the `promoted <id> <n>` event is emitted (Service.qml
	// consumes the daemon's stdout).
	stdout io.Writer
}

// New wires a Handler. client is the pinned, redirect-rejecting client (see
// dialer.NewClient). cache owns the sparse .dat pool; maxConcurrent caps
// concurrent origin fetches.
func New(store *catalog.Store, client *http.Client, tok *session.Token,
	cache *rangecache.Cache, maxConcurrent int, maxSurahBytes int64) *Handler {
	if maxConcurrent < 1 {
		maxConcurrent = 1
	}
	return &Handler{
		store:         store,
		client:        client,
		token:         tok,
		sem:           make(chan struct{}, maxConcurrent),
		maxSurahBytes: maxSurahBytes,
		cooldown:      urlsafety.NewCooldown(),
		cache:         cache,
		flights:       inflight.NewManager(),
		buildURL: func(identifier string, n int) string {
			return store.Get().AudioURL(identifier, n)
		},
		now:    func() int64 { return time.Now().UnixMilli() },
		logger: log.New(io.Discard, "proxyhandler: ", 0),
		stdout: os.Stdout,
	}
}

// SetLogger enables logging (default: discarded).
func (h *Handler) SetLogger(l *log.Logger) {
	if l != nil {
		h.logger = l
	}
}

// SetBuildURL overrides origin URL construction (test hook).
func (h *Handler) SetBuildURL(f func(identifier string, n int) string) {
	h.buildURL = f
}

// SetNow overrides the clock (test hook).
func (h *Handler) SetNow(f func() int64) {
	h.now = f
}

// SetStdout redirects the `promoted` event writer (test hook).
func (h *Handler) SetStdout(w io.Writer) {
	if w != nil {
		h.stdout = w
	}
}

// EnablePromotion arms the M3 validate+promote hook: fully-fetched surahs are
// media-validated and promoted into the explicit download tree, with a
// `promoted <id> <n>` event on stdout. Promotion needs stateDir as its target.
func (h *Handler) EnablePromotion(stateDir string) {
	h.validateFile = mediavalidate.Validate
	h.promoteFile = promote.Promote
	h.stateDir = stateDir
}

// Routes returns the HTTP mux.
func (h *Handler) Routes() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", h.healthz)
	mux.HandleFunc("/cache/usage", h.cacheUsage)
	mux.HandleFunc("/api/cache/clear", h.cacheClear)
	mux.HandleFunc("/stream", h.stream)
	return mux
}

func (h *Handler) healthz(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain")
	w.WriteHeader(http.StatusOK)
	io.WriteString(w, "ok")
}

// cacheUsage reports the proxy-owned pool size (no token: it is folded into
// the plugin's "Cache:" readout). Single-line JSON (trailing newline: the
// plugin parses it with a newline-delimited SplitParser).
func (h *Handler) cacheUsage(w http.ResponseWriter, r *http.Request) {
	u := h.cache.Usage()
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	fmt.Fprintf(w, "{\"bytes\":%d,\"files\":%d}\n", u.Bytes, u.Files)
}

// cacheClear wipes the proxy-owned cache (the plugin's "Clear cache" action).
// Token-authenticated: unlike /cache/usage this mutates state.
func (h *Handler) cacheClear(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !h.token.Validate(r.URL.Query().Get("tok")) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	if err := h.cache.Clear(); err != nil {
		http.Error(w, "clear failed", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, "{\"cleared\":true}\n")
}

// stream is the caching audio endpoint. Auth token first; then the reciter
// must exist in the validated catalog and surah must be 1..114 (enums against
// the catalog — no arbitrary URLs).
func (h *Handler) stream(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	q := r.URL.Query()
	if !h.token.Validate(q.Get("tok")) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	reciter := q.Get("reciter")
	if !urlsafety.IsSafeReciterArg(reciter) {
		http.Error(w, "invalid reciter", http.StatusBadRequest)
		return
	}
	n, ok := urlsafety.ParseSurahArg(q.Get("surah"))
	if !ok {
		http.Error(w, "invalid surah", http.StatusBadRequest)
		return
	}
	state := h.store.Get()
	if _, found := state.Reciter(reciter); !found {
		http.Error(w, "unknown reciter", http.StatusNotFound)
		return
	}
	target := h.buildURL(reciter, n)
	if target == "" {
		http.Error(w, "unsafe reciter", http.StatusBadRequest)
		return
	}

	key := reciter + ":" + strconv.Itoa(n)
	if h.cooldown.Active(key, h.now()) {
		http.Error(w, "playback failed, retry later", http.StatusTooEarly)
		return
	}

	select {
	case h.sem <- struct{}{}:
		defer func() { <-h.sem }()
	default:
		http.Error(w, "busy", http.StatusServiceUnavailable)
		return
	}

	entry, err := h.cache.Entry(reciter, n)
	if err != nil {
		h.logger.Printf("stream %s entry: %v", key, err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	release := entry.Begin()
	defer release()
	// Budget enforcement is best-effort: free room before the fill and reclaim
	// on return. The active entry is never evicted (Begin() guards it), so a
	// huge live file legitimately overrides a small budget until it completes.
	defer func() {
		if err := h.cache.EvictToBudget(); err != nil {
			h.logger.Printf("stream %s evict: %v", key, err)
		}
	}()
	if err := h.cache.EvictToBudget(); err != nil {
		h.logger.Printf("stream %s evict: %v", key, err)
	}

	// Discover origin size once (pinned HEAD) and allocate the sparse file.
	if !entry.SizeKnown() {
		size, ct, err := h.headOrigin(r.Context(), key, target)
		if err != nil {
			h.logger.Printf("stream %s head: %v", key, err)
			h.cooldown.Mark(key, h.now())
			http.Error(w, "playback failed", http.StatusBadGateway)
			return
		}
		if size > h.maxSurahBytes {
			h.logger.Printf("stream %s oversized %d > %d", key, size, h.maxSurahBytes)
			h.cooldown.Mark(key, h.now())
			http.Error(w, "playback failed", http.StatusBadGateway)
			return
		}
		if err := entry.EnsureSize(size, ct, ""); err != nil {
			h.logger.Printf("stream %s alloc: %v", key, err)
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}
	}
	size := entry.Meta().Size

	// Parse the requested byte range. Default: the whole file (200).
	start, end, partial := parseRange(r.Header.Get("Range"), size)
	if partial && (start >= end || start < 0 || end > size) {
		http.Error(w, "range not satisfiable", http.StatusRequestedRangeNotSatisfiable)
		return
	}

	// Segment the requested range into cached/missing pieces.
	segments := entry.Fetched().Segments(start, end)

	// One header pair for the whole response (the plan's "one Content-Range +
	// one Content-Length"); segmentation is purely internal to the body.
	hdr := w.Header()
	meta := entry.Meta()
	hdr.Set("Content-Type", meta.ContentType)
	if hdr.Get("Content-Type") == "" {
		hdr.Set("Content-Type", "audio/mpeg")
	}
	hdr.Set("Content-Length", strconv.FormatInt(end-start, 10))
	if partial {
		hdr.Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end-1, size))
		hdr.Set("Accept-Ranges", "bytes")
		w.WriteHeader(http.StatusPartialContent)
	} else {
		w.WriteHeader(http.StatusOK)
	}

	var failed bool
	for _, seg := range segments {
		if r.Context().Err() != nil {
			return // client gave up; partial credit already flushed
		}
		if seg.Cached {
			if err := serveCached(w, entry, seg); err != nil {
				h.logger.Printf("stream %s read cached %v: %v", key, seg, err)
				failed = true
				return
			}
			continue
		}
		if err := h.fetchAndServe(r.Context(), key, target, seg, w, entry); err != nil {
			h.logger.Printf("stream %s fetch %v: %v", key, seg, err)
			failed = true
			return
		}
	}
	if !failed && entry.Fetched().Full(size) {
		h.maybePromote(entry, reciter, n, key)
	}
}

// maybePromote runs the M3 hook for a fully-fetched surah: media validation,
// atomic promotion into the state tree, `promoted <id> <n>` on stdout, then
// cache-entry cleanup. A validation failure deletes the cache entry and arms
// the per-surah cooldown (a corrupted file should not be re-served). A
// promotion (filesystem) failure keeps the valid cache and is only logged.
func (h *Handler) maybePromote(entry *rangecache.Entry, reciter string, n int, key string) {
	if h.validateFile == nil || h.promoteFile == nil || !entry.ClaimPromote() {
		return
	}
	p := entry.DataPath()
	if err := h.validateFile(p); err != nil {
		h.logger.Printf("promote %s invalid: %v", key, err)
		h.cooldown.Mark(key, h.now())
		if rerr := h.cache.Remove(reciter, n); rerr != nil {
			h.logger.Printf("promote %s cleanup: %v", key, rerr)
		}
		return
	}
	if err := h.promoteFile(p, h.stateDir, reciter, n); err != nil {
		h.logger.Printf("promote %s: %v", key, err)
		return
	}
	h.logger.Printf("promoted %s", key)
	fmt.Fprintf(h.stdout, "promoted %s %d\n", reciter, n)
	if rerr := h.cache.Remove(reciter, n); rerr != nil {
		h.logger.Printf("promote %s cleanup: %v", key, rerr)
	}
}

// serveCached streams a cached segment from the .dat file.
func serveCached(w http.ResponseWriter, entry *rangecache.Entry, seg rangecache.Segment) error {
	buf := make([]byte, 64*1024)
	off := seg.Start
	for off < seg.End {
		want := seg.End - off
		if int64(len(buf)) > want {
			buf = buf[:want]
		}
		n, err := entry.ReadAt(buf, off)
		if n > 0 {
			if _, werr := w.Write(buf[:n]); werr != nil {
				return werr
			}
			off += int64(n)
		}
		if err != nil {
			if err == io.EOF && off == seg.End {
				return nil
			}
			return err
		}
		if n == 0 {
			return io.ErrUnexpectedEOF
		}
	}
	return nil
}

// fetchAndServe fetches a missing segment from the origin, streaming it to the
// client and into the cache. Concurrent requests for the same segment share
// the origin fetch (inflight, keyed reciter:surah:start-end); a disconnect
// only aborts the fetch when the last waiter leaves.
func (h *Handler) fetchAndServe(ctx context.Context, key, target string, seg rangecache.Segment, w http.ResponseWriter, entry *rangecache.Entry) error {
	segKey := fmt.Sprintf("%s:%d-%d", key, seg.Start, seg.End)

	// Write-only waiters detect a disconnect via ctx and join a shared fetch.
	sharedCtx, done, release, created := h.flights.Join(segKey)
	defer release()

	if !created {
		// Another request is already fetching this segment. Wait for it, then
		// serve whatever is now cached and fetch what the (possibly aborted)
		// owner did not complete.
		select {
		case <-done:
		case <-ctx.Done():
			return ctx.Err()
		}
		remaining := entry.Fetched().Segments(seg.Start, seg.End)
		for _, sub := range remaining {
			if sub.Cached {
				if err := serveCached(w, entry, sub); err != nil {
					return err
				}
				continue
			}
			if err := h.fetchAndServe(ctx, key, target, sub, w, entry); err != nil {
				return err
			}
		}
		return nil
	}

	// We own the shared fetch: run it on sharedCtx, keep flushing to the cache
	// even after the client disconnects (partial credit) until the shared ctx
	// is cancelled (last waiter gone) or the segment is done.
	fetchErr := h.doOriginFetch(sharedCtx, target, seg, w, entry)
	h.flights.Finish(segKey)
	return fetchErr
}

// doOriginFetch issues one pinned GET for [seg.Start, seg.End), streaming each
// chunk to the client and into the cache. A 200 response (origin ignores
// ranges) is handled by discarding the lead-in bytes.
func (h *Handler) doOriginFetch(ctx context.Context, target string, seg rangecache.Segment, w http.ResponseWriter, entry *rangecache.Entry) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", seg.Start, seg.End-1))

	resp, err := h.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 300 && resp.StatusCode < 400 {
		return fmt.Errorf("origin redirect %d (not followed)", resp.StatusCode)
	}
	switch resp.StatusCode {
	case http.StatusPartialContent:
		// Body is exactly the requested range.
	case http.StatusOK:
		// Origin ignored the Range header: body is the whole file. Discard the
		// lead-in so the segment bytes line up with seg.Start.
		if seg.Start > 0 {
			if _, err := io.CopyN(io.Discard, resp.Body, seg.Start); err != nil {
				return fmt.Errorf("discard lead-in: %w", err)
			}
		}
	default:
		return fmt.Errorf("origin status %d", resp.StatusCode)
	}
	if !isAudioType(resp.Header.Get("Content-Type")) {
		return fmt.Errorf("origin content-type %q", resp.Header.Get("Content-Type"))
	}

	buf := make([]byte, writeChunk)
	var flushed int64
	length := seg.End - seg.Start
	for {
		if ctx.Err() != nil {
			return ctx.Err() // shared fetch aborted by last waiter
		}
		if flushed >= length {
			break
		}
		if int64(len(buf)) > length-flushed {
			buf = buf[:length-flushed]
		}
		nr, rerr := resp.Body.Read(buf)
		if nr > 0 {
			chunk := buf[:nr]
			// Write to cache first (the invariant: data durable before the
			// sidecar claims it). Writing to the (possibly gone) client is
			// best-effort.
			off := seg.Start + flushed
			if err := entry.WriteRange(off, chunk); err != nil {
				return err
			}
			if w != nil {
				if _, werr := w.Write(chunk); werr != nil {
					h.logger.Printf("client write aborted (partial credit retained)")
				}
			}
			flushed += int64(nr)
		}
		if rerr != nil {
			if rerr == io.EOF {
				break
			}
			return rerr
		}
	}
	return nil
}

// headOrigin probes origin size + content type (mirrors download.sh remote_size).
func (h *Handler) headOrigin(ctx context.Context, key, target string) (int64, string, error) {
	ctx, cancel := context.WithTimeout(ctx, dialer.HeadTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodHead, target, nil)
	if err != nil {
		return 0, "", err
	}
	resp, err := h.client.Do(req)
	if err != nil {
		return 0, "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 && resp.StatusCode < 400 {
		return 0, "", fmt.Errorf("head redirect %d", resp.StatusCode)
	}
	if resp.StatusCode != http.StatusOK {
		return 0, "", fmt.Errorf("head status %d", resp.StatusCode)
	}
	ct := resp.Header.Get("Content-Type")
	if !isAudioType(ct) {
		return 0, "", fmt.Errorf("head content-type %q", ct)
	}
	cl := resp.ContentLength
	if cl <= 0 {
		return 0, "", errors.New("head missing content-length")
	}
	return cl, ct, nil
}

// parseRange parses a single-range "bytes=a-b" / "bytes=a-" / "bytes=-suffix"
// header. size <= 0 means unknown (no range allowed). Returns start, end
// (half-open) and whether the request was a partial request.
func parseRange(header string, size int64) (int64, int64, bool) {
	if header == "" || size <= 0 {
		return 0, size, false
	}
	if !strings.HasPrefix(header, "bytes=") {
		return 0, 0, true // malformed; caller rejects
	}
	spec := strings.TrimPrefix(header, "bytes=")
	if strings.Contains(spec, ",") {
		return 0, 0, true // multi-range not supported
	}
	dash := strings.IndexByte(spec, '-')
	if dash < 0 {
		return 0, 0, true
	}
	startStr, endStr := spec[:dash], spec[dash+1:]
	var start, end int64
	if startStr == "" {
		// suffix range: last N bytes
		suffix, err := strconv.ParseInt(endStr, 10, 64)
		if err != nil || suffix <= 0 {
			return 0, 0, true
		}
		if suffix > size {
			suffix = size
		}
		return size - suffix, size, true
	}
	var err error
	start, err = strconv.ParseInt(startStr, 10, 64)
	if err != nil || start < 0 {
		return 0, 0, true
	}
	if start >= size {
		return start, start, true // unsatisfiable; caller returns 416
	}
	if endStr == "" {
		return start, size, true
	}
	end, err = strconv.ParseInt(endStr, 10, 64)
	if err != nil || end < start {
		return 0, 0, true
	}
	if end+1 > size {
		end = size - 1
	}
	return start, end + 1, true
}

func isAudioType(ct string) bool {
	switch {
	case ct == "":
		return false
	case len(ct) >= 6 && ct[:6] == "audio/":
		return true
	case ct == "application/octet-stream":
		return true
	}
	return false
}

// Cooldown exposes the gate for tests.
func (h *Handler) Cooldown() *urlsafety.Cooldown { return h.cooldown }
