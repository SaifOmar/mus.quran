# mus.quran — Quran Player

![preview](preview.png)

A Quran recitation player for the Omarchy bar. Play any surah by any reciter,
stream it instantly, or download whole mushafs. The playback engine is a small
**Python service** (`quranproxyd.py`) with a CLI companion (`quranctl.py`) that
streams, caches, validates, and downloads audio over a hardened loopback
proxy — pure Python stdlib, no compiled binaries, no pip dependencies.

## Features

* Reciter and surah tabs with live, multilingual search (Arabic + 9 languages).
* Play/pause, prev/next, seek, four playback modes, resume-from-last-position.
* Instant streaming: byte-range playback starts immediately while the proxy
  caches in the background (mpv seeks without buffering).
* Background cache with eviction, a combined "Cache:" readout, and one-click
  clear.
* Explicit per-surah and full-mushaf downloads with live progress, resumable
  across shell restarts.
* Deep media validation on every fetch (size, MIME, ffprobe) before a file is
  trusted as a permanent download.

## Dependencies

* `mpv` (runtime; the player).
* `mpv-mpris` (recommended for system media control).
* `python3` (runtime; stdlib only — no pip packages).
* `file` (runtime, used by the media validator; falls back gracefully if
  missing).
* `ffprobe` (optional; deep validation when present).

## Install

```sh
omarchy plugin add https://github.com/saifomar/mus.quran.git --enable
```

The audio engine runs in place from the plugin folder — nothing to install.
Optionally, `make install` links the scripts into `~/.local/bin` (a fallback the
service probes after the plugin folder).

Then restart your Omarchy shell.

## Uninstall

Remove the plugin from Omarchy:

```sh
omarchy plugin remove mus.quran
```

That removes mus.quran's downloaded audio, cache, and settings (runtime state
under `~/.local/state/omarchy/quran` and `~/.cache/omarchy/quran`).

No administrator privileges are required.

After removing, restart your Omarchy shell or disable/remove the plugin
to unload the running engine.

## Develop

```sh
make test           # pytest suite (tests/ ported from the Go reference tests)
make lint           # ruff check
make install        # symlink scripts into ~/.local/bin
```

The Python engine is pure stdlib (no `requirements.txt`), so it runs offline.
A `.venv` with pytest + ruff is used for development only.

## Security

This plugin was written with the security model of the Omarchy shell in mind
(plugins run as unsandboxed code, so they are only as safe as their code):

* The proxy binds **127.0.0.1 only**, and every request requires a per-run
  32-hex token shared via a 0600 handoff file in a 0700 runtime dir.
* Origin URLs are built **only** from the validated reciter catalog and
  validated through a strict allowlist — no arbitrary URLs, no redirects
  followed, DNS is pinned to the allowlisted host.
* The daemon **never writes `quran.json`**; it reads the catalog and signals
  progress over stdout events. There is exactly one writer for your state file.
* Media is validated (size cap, MIME, ffprobe) before a file is accepted as a
  permanent download; downloads stage through unique temp files and atomic
  renames.
* **No prebuilt binaries.** The engine is pure Python stdlib — there are no
  committed executables anywhere; the scripts run in place from the plugin
  folder and `make install` optionally symlinks them into `~/.local/bin`.
* No administrator privileges, no install hooks, no writes outside your own
  state/cache/runtime dirs.

## Usage

* Left-click the bar icon to open the popup and select a surah to play.
* Right/middle-click toggles play/pause; scroll wheel moves prev/next surah.

### IPC

The service registers as the `quran` IPC target:

```sh
omarchy-shell quran status
omarchy-shell quran playSurah <reciter> <surah>
omarchy-shell quran download <reciter> [surah]
omarchy-shell quran cacheInfo
omarchy-shell quran clearCache
```

## Special Thanks

Special thanks to **AksharP5/omarchy-radio-atlas** for showing how to approach
Omarchy plugin integration and serving as a useful reference while building
mus.quran.

## License

MIT — see [LICENSE](LICENSE).

---

*This repo used to be a self-contained shell plugin; it is now a single
repository hosting both the plugin and its Python audio engine. See
[docs/PLAN.md](docs/PLAN.md) for the design history.*
