# Local Range-Caching Media Proxy — Final Plan

A Go companion service for the `mus.quran` Quickshell plugin (Omarchy). It lets mpv
stream surah audio on demand over `http://127.0.0.1:PORT/stream?...` instead of
waiting on full-file `download.sh` fetches: byte-range seeks are served from a
sparse local cache, DNS-pinned and allowlist-checked origin requests, and fully
downloaded files are validated and promoted into the permanent download tree.

Reference implementation (source of truth for behavior to port):
`~/.config/omarchy/plugins/mus.quran/` — `Model.js`, `download.sh`, `cache.sh`,
`validate_media.sh`, `Service.qml`, and the `tests/` suite. Match these exactly;
do not re-derive "similar" policies.

## Decisions (confirmed)

1. **Module root** = `/home/saif/Dev/personal-projects/mus.quran` (already
   prepared empty). Single `go.mod`, layout below.
2. **Budget = one shared 500MB knob, split ownership.** User-visible behavior
   stays one pool (one slider, one "Cache:" readout, one clear button). But:
   - **The proxy owns eviction of its own files** (`.dat` + `.meta.json`). It is
     the only process that knows which files have open write handles or in-flight
     fills, so it can skip those — `cache.sh` evicting a file the proxy is
     mid-write to would silently destroy bytes the sidecar still claims.
   - **`cache.sh` is unchanged** for the legacy `*.mp3` streaming-cache path
     (scan/size/evict/clear keep operating on `*.mp3` only; `scan` must stay
     mp3-only so `cacheFiles` is not polluted by `.dat`).
   - **Combined number** comes from `cache.sh size` (legacy mp3s) **+** the
     proxy's `GET /cache/usage` response (its `.dat`/`.meta.json` bytes). The
     proxy enforces `--budget-bytes` against its own bytes only.
3. **Coexist for v1.** The proxy is a pure streaming/caching layer. It never
   writes `quran.json` — that file is owned by Service.qml (`FileView`,
   `atomicWrites`, `watchChanges`); two writers would be a corruption/lost-update
   bug. Promotion is signaled as a stdout event (`promoted <id> <n>`); Service.qml
   handles it through its existing `markSurahDownloaded()`. `download.sh`/`cache.sh`
   keep the explicit "download full mushaf" path.

## Verified facts (do not re-litigate)

- **Ranges work on both CDNs.** `cdn.islamic.app` HEAD returns `accept-ranges:
  bytes`; range GET returns `206` with `content-range: bytes 0-1023/1420155`.
  mp3quran.net servers (server6–16, the only ones in the catalog) return 206 too.
  Hard blocker cleared.
- **Origin URL shape is not uniform.** Catalog reciters carry per-reciter `server`
  prefixes (e.g. `https://server16.mp3quran.net/a_sheim/Rewayat-Warsh-A-n-Nafi/`).
  `download.sh:317-333` pads surahs to `001.mp3` for server-based URLs and uses
  **unpadded** `1.mp3` for the default CDN
  (`cdn.islamic.app/quran/audio-surah/<id>/<n>.mp3`), with `ar.ajamy →
  ar.ahmedajamy`. `internal/catalog` must mirror `audioUrl()` exactly, then run
  the final URL through the ported `isSafeRemoteUrl()`.
- **Catalog source of truth**: `~/.local/state/omarchy/settings/quran.json`
  (persisted `reciters[]` with `server`, `downloadedSurahs`, `cacheLimitMb`,
  `cacheLastPlayed`). Proxy reads it (with fsnotify reload), never writes it.
- **Runtime dir**: `$XDG_RUNTIME_DIR/mus-quran` (0700, created by Service.qml's
  `sockCleanProc`) is the home for the proxy token file `quranproxy.json`
  (0600): `{"port": ..., "token": ...}`. Fallback under the cache root when
  `XDG_RUNTIME_DIR` is unset, mirroring `mpvRuntimeDir`.
- Go 1.26.6, mpv 0.41.0, `file(1)`/`ffprobe` available.
- `validate_media.sh` semantics: regular file (not symlink), non-empty, `file(1)`
  must exist and report `audio/*` or `application/octet-stream`; ffprobe
  fails-open if absent, fails-closed if present and rejects.

## Repo layout

```
mus.quran/
  cmd/quranproxyd/main.go     entry, flags/env, graceful shutdown
  internal/config/            flags+env: --listen (127.0.0.1:0), --state-file,
                              --cache-dir, --budget-bytes, --max-concurrent,
                              --token-file, --max-surah-bytes
  internal/urlsafety/         ported isSafeServerPrefix/isBlockedHost/isSafeIdentifier
                              + table tests (test_model.js cases verbatim)
  internal/catalog/           quran.json parse + validation; identifier→origin URL builder
  internal/dialer/            DNS-pinned transport (resolve→pin→dial; SNI/verify = hostname)
  internal/rangecache/        sparse .dat + coalesced interval sidecar; per-file RWMutex;
                              own-file eviction
  internal/proxyhandler/      Range parsing, segmented 206, origin fetch orchestration,
                              /healthz + /cache/usage
  internal/mediavalidate/     shells out to file(1)+ffprobe (validate_media.sh semantics)
  internal/promote/           atomic promote into state tree + guards
  internal/session/           per-process token generation/validation (constant-time)
  testdata/                   small mp3 fixtures; fake Range-capable origin (httptest)
  Makefile / go.mod / README.md / PLAN.md
```

## Cache format

`~/.cache/omarchy/quran/<reciter>/<surah>.dat` (fallocate sparse, `umask 077`) +
`<surah>.meta.json`:

```json
{
  "size": 4831201,
  "content_type": "audio/mpeg",
  "fetched_ranges": [[0, 65535], [1048576, 2097151]],
  "etag": "...",
  "updated_at": "..."
}
```

- `fetched_ranges` is a sorted, coalesced list of half-open intervals.
- **Write order invariant**: every fill is *write bytes → merge interval →
  persist sidecar*. A crash can never claim bytes that were not flushed.
- A `.dat` without a matching sidecar, or whose sidecar `size` disagrees with the
  file, is treated as empty and re-fetched.
- Proxy-owned eviction removes `.dat` + `.meta.json` together; it skips files
  with an open write handle or in-flight fill (see Concurrency).

## Request flow

1. Validate `tok` query param (constant-time compare), then `reciter`/`surah` as
   enums against the validated catalog. Nothing else proceeds on failure.
2. Build the origin URL from the catalog (`server` prefix or default CDN template,
   `pad3`/unpadded logic, `ar.ajamy` mapping) and run it through the ported
   `isSafeRemoteUrl()` as belt-and-suspenders.
3. Load sidecar. If size unknown: pinned **HEAD** to origin; require
   `content-type` `audio/*` or `application/octet-stream`, `content-length` ≤
   `--max-surah-bytes` (300MB default — closes the lying-Content-Length fallocate
   DoS), then `fallocate` the sparse `.dat`.
4. Diff requested range vs. cached intervals:
   - Fully cached → 206 served straight from `.dat` (`io.CopyN` at offset).
   - Partially/not cached → **one** 206 response with a single header pair
     `Content-Range: bytes a-b/size` and `Content-Length: b-a+1` (there is no
     "full" Content-Length variant — segmentation is purely internal). The body
     is emitted in byte order by alternating `ReadAt` on cached segments with
     streaming from origin fetches for missing segments; the same bytes streamed
     to the client are `WriteAt`-ed into `.dat`, and the sidecar is updated only
     after each segment flush. Client sees one ordinary 206.
   - No `Range` header → 200 with full `Content-Length`, same segmented path.
5. When intervals become `[0, size)`: run the `file(1)`+`ffprobe` gate; on pass,
   atomically promote to `<state>/quran/<reciter>/<n>.mp3` (temp + rename, with
   the realpath/symlink guards `cache.sh promote` uses), delete the cache entry,
   emit `promoted <id> <n>` on stdout. On validation failure, delete the cache
   entry and arm the 10s cooldown.

## Concurrency

- **singleflight** keyed `reciter:surah` for origin fills. The fetch goroutine
  owns its context; a caller disconnect only aborts the shared fetch when it is
  the **last waiter** (`singleflight.DoChan` + waiter refcount). Abandoned fills
  keep already-flushed bytes (partial credit), and the sidecar invariant holds.
- Per-file RWMutex guards sidecar read/modify/write only. Data is written via
  `os.File.WriteAt`, so concurrent non-overlapping fills never serialize on file
  I/O — only on interval-list bookkeeping.
- Global semaphore (default 4) caps concurrent origin fetches.
- 10s failure cooldown per `reciter:surah` inside the proxy (mirrors
  `Model.cooldownActive`/`markCooldown`).
- Requests respect context cancellation: if mpv aborts (user seeks again), the
  client response is abandoned but the fill continues while other waiters or an
  open handle justify it, and flushed bytes are never discarded.

## Security checklist

- Port `urlsafety` 1:1 from `Model.js`:
  - https-only; host suffix allowlist `mp3quran.net` / `islamic.app` (dot-boundary,
    lowercase, trailing-dot stripped).
  - Reject userinfo, query, fragment, control chars, encoded delimiters
    (`%2e %2f %3f %23 %40 %5c`), length > 512, bad ports, bracket-IPv6 without
    zone ids, unbracketed IPv6.
  - Reject IPv4 edge forms: hex, octal, short, leading zeros, integer forms.
  - Blocked ranges: `0/8`, `10/8`, `127/8`, `169.254/16`, `172.16/12`,
    `192.168/16`, `100.64/10` (CGNAT), `192.0.0.0/24`, `192.0.2.0/24`
    (TEST-NET-1), `198.51.100.0/24` (TEST-NET-2), `203.0.113.0/24` (TEST-NET-3),
    multicast/240/4; IPv6 `::`, `::1`, `fe80::/10`, `fc00::/7`, IPv4-mapped and
    IPv4-compatible forms.
  - Identifiers: `^[A-Za-z0-9][A-Za-z0-9._-]*$`, ≤64 chars, not `.`/`..` —
    blocks traversal and template injection.
- **DNS pinning**: resolve the allowlisted hostname once per fetch (IPv4-preferred
  like `pin_host`); fail closed if **any** returned address is private/internal
  (this is what stops DNS rebinding). Dial the pinned IP; keep the original
  hostname in TLS SNI and verify the certificate against it.
- **Redirects are an SSRF path**: Go's `http.Client` follows redirects by default.
  Set `CheckRedirect: return http.ErrUseLastResponse` (and treat 3xx as error) on
  **every** outbound request — the size-probing HEAD included, not just the range
  GET. Matches `download.sh`'s `--max-redirs 0`.
- Session token: random 32-hex at startup, constant-time compare, 0600 file in
  the private runtime dir. Listener binds `127.0.0.1` only. `/healthz` (read-only)
  and `/cache/usage` need no token; `/stream` requires it.
- Timeouts mirror curl: connect 10s, overall 300s, no-data abort (`--speed-limit
  1024 --speed-time 30`); streamed bytes capped at `--max-surah-bytes`.
- Media integrity gate before promotion (file(1)+ffprobe); only promoted files
  are ever offered for `file://` playback.

## Eviction & budget (ownership split)

- **Proxy owns eviction of its own cache dir.** It maintains the LRU order from
  `cacheLastPlayed` in quran.json plus file mtimes, and never evicts a file with
  an open fd or an in-flight fill. Evicts `.dat`+`.meta.json` pairs atomically to
  stay under `--budget-bytes` (500MB default, driven by the same `cacheLimitMb`
  value Service.qml persists).
- `cache.sh` stays as-is for the legacy `*.mp3` path (`scan`/`size`/`evict`/
  `clear`).
- Combined UI number = `cache.sh size <dir>` (mp3s) + `GET /cache/usage`
  (`{"bytes": N}` for `.dat`+`.meta.json`). Service.qml adds them for the
  "Cache: X" readout; the clear button clears both (existing `cache.sh clear` +
  a proxy `DELETE /cache` or equivalent internal call).
- `download.sh`'s existing budget pre-check (`existing + want > BUDGET_BYTES`)
  keeps its current semantics for the state dir; proxy bytes are accounted
  separately via `/cache/usage`, so no double counting.

## M4 — Service.qml integration

- `proxyProc` Process spawning the binary; restart-on-crash ≤5 (same pattern as
  `mpvProc`). Runtime-file handoff via a FileView on `quranproxy.json`
  (captures `{port, token}`), `/healthz` polled before first use and before
  crash-recovery reloads.
- `_mpvLoad` guard (Service.qml:548) extended from `file://`-only to also accept
  exactly `http://127.0.0.1:<port>/stream?...` sourced from proxy state —
  everything else still refused. `lastSource`/`_mpvRecoverLast` then replay http
  URLs unchanged.
- Keep mpv's network cache (`--cache` default `yes`); consider bumping
  `--demuxer-readahead-secs` / `--demuxer-max-bytes` for smoother seeks.
- `playSurah` routing: already downloaded → `file://` (unchanged); else → proxy
  URL with **no foreground cache fill**. `promoted <id> <n>` stdout lines →
  `markSurahDownloaded()`; proxy fetch failures → cooldown + existing error
  strings (`playbackFailed`). `/healthz` failure → restart proxy, keep token file
  re-read on reconnect.

## Milestones

- **M0** — skeleton repo, config, ported `urlsafety` + `catalog` with table
  tests (no network).
- **M1** — passthrough: validate → pinned fetch → stream through; no caching.
  Proves range forwarding against the real CDN with real mpv.
- **M2** — `rangecache`: sparse file, sidecar, cache hits, segmented fills,
  singleflight last-waiter cancellation, crash-sim tests.
- **M3** — mediavalidate + promote + stdout events + failure cooldown.
- **M4** — Service.qml lifecycle, token handoff, routing, health checks,
  combined-budget readout.
- **M5** — security pass: token auth, budget/cooldown enforcement, proxy-owned
  eviction, adversarial fake origin, Range-parser fuzzing.

## Test plan

- `urlsafety`: port every `test_model.js` case verbatim (the hardened oracle).
- `rangecache`: interval merge/coalesce (adjacent, overlapping, disjoint,
  out-of-order inserts); crash-sim via injected persist failure verifying the
  sidecar never claims unflushed bytes; `.dat`/sidecar size-mismatch recovery;
  eviction skipping open/in-flight files.
- `proxyhandler`: httptest fake origin — range-capable, no-Accept-Ranges (200
  fallback), stall + context cancel (singleflight last-waiter semantics), 416,
  3xx (assert **no** redirect follow on HEAD and GET), non-audio MIME, oversized
  Content-Length.
- `catalog`: parse a sample quran.json; assert exact origin URL shapes
  (server-prefix padded vs default-CDN unpadded, `ar.ajamy` mapping, hostile
  server rejected).
- End-to-end: real mpv → proxy → real CDN; seek mid-file and assert a single
  small origin request via the fake-origin request log.

## Non-goals (v1)

No adaptive bitrate/transcoding. No multi-host CDN failover (single allowlisted
origin per file). No general-purpose proxy. No subsumption of `download.sh` /
`cache.sh` (explicit download path stays; promotion links them via events).