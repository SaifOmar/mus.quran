# mus.quran — Quran Player

![preview](preview.png)

A lightweight Quran recitation player for the Omarchy bar. The service keeps
playback running when the popup closes and exposes a right-section bar widget.

## Features

- Reciter and Surah tabs with live, multilingual search (Arabic + 9 languages).
- Play/pause, prev/next, seek, four playback modes, and resume-from-last-position.
- Per-surah streaming with a background cache and optional per-surah/full-mushaf downloads.

## Dependencies

- `mpv` (runtime).
- `mpv-mpris` (recommended for system media control).

## Install

```sh
omarchy plugin add https://github.com/SaifOmar/mus.quran.git --enable
```

## Usage

- Left-click the bar icon to open the popup and select a surah to play.
- Right/middle-click toggles play/pause; scroll wheel moves prev/next surah.
- `j`/`k` + `Enter` navigate the lists; the first reciter selection offers a
  full-mushaf download.

## Configure

```sh
omarchy bar move mus.quran --section right
```

## IPC

The service exposes an `IpcHandler` targeting `quran` with `status`,
`playPause`, `next`, `previous`, `seek(ms)`, `playSurah(id,n)`,
`download(id[,n])`, `setMode(mode)`, `setLanguage(code)`, `clearCache`,
`cacheInfo`, and `ping`.

## State

- Reciter/playback state: `~/.local/state/omarchy/settings/quran.json`
- Explicit downloads: `~/.local/state/omarchy/quran/<reciter>/`
- Cache: `~/.cache/omarchy/quran`

## Remove

```sh
omarchy plugin remove mus.quran
```

## License

MIT
