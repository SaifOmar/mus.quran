# mus.quran — Quran Player (concise)

Lightweight Quran recitation player for the Omarchy bar. The service keeps
playback running when the popup closes and exposes a right-section bar widget.

Key features
- Reciter and Surah tabs with live, multilingual search (Arabic + 9 languages).
- Play/pause, prev/next, seek, four playback modes, and resume-from-last-position.
- Per-surah streaming with a background cache and optional per-surah/full-mushaf downloads.

Dependencies
- `mpv` (runtime) and `mpv-mpris` (recommended for system media control).

Install (developer)
```bash
# Copy the plugin folder to the omarchy plugins directory. The target
# directory name should match the plugin `id` in manifest.json (here: mus.quran).
cp -r mus.quran ~/.config/omarchy/plugins/mus.quran
omarchy plugin validate ~/.config/omarchy/plugins/mus.quran
omarchy plugin enable mus.quran --section right
```

Usage
- Left-click the bar icon to open the popup and select a surah to play.
- Right/middle-click toggles play/pause; scroll wheel = prev/next surah.
- j/k + Enter navigate lists; first reciter selection offers a full-mushaf download.

Layout (repo)
```
mus.quran/  # working plugin source directory
├── manifest.json
├── Service.qml
├── BarWidget.qml
├── Model.js
├── SurahNames.js
├── download.sh
├── preview.png
├── preview2.png
├── preview3.png
└── preview4.png
```

Notes
- This repo includes multiple preview images (`preview.png` plus three
  additional previews) for convenience; the store typically shows a single
  preview image but keeping extras is intentional.
- State is stored under `~/.local/state/omarchy/quran` and cache under
  `~/.cache/omarchy/quran`.

IPC
- `IpcHandler { target: "quran" }` exposes `status`, `playPause`, `next`,
  `previous`, `seek(ms)`, `playSurah(id,n)`, `setLanguage(code)`, `ping`.

Publishing
- `manifest.json` is prepared with `id: mus.quran` and `version: 0.5.0`.
- Include `preview.png` as the store preview; additional preview images are
  intentionally retained in the repo.
- Add or update `LICENSE` before publishing and run `omarchy plugin validate`.

Use `omarchy plugin validate` to verify the plugin before submission.
