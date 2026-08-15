import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model
import "SurahNames.js" as SurahData

Item {
  id: root

  property var shell: null
  property var pluginRegistry: null

  readonly property string dataDir: Quickshell.env("HOME") + "/.local/state/omarchy/quran"
  readonly property string statePath: Quickshell.env("HOME") + "/.local/state/omarchy/settings/quran.json"
  // mpv IPC socket lives in a private 0700 runtime dir (created on startup),
  // never /tmp. Falls back under the cache root when XDG_RUNTIME_DIR is unset.
  readonly property string mpvRuntimeDir: (function() {
    var rt = Quickshell.env("XDG_RUNTIME_DIR")
    if (rt && rt !== "") return rt + "/mus-quran"
    return Quickshell.env("HOME") + "/.cache/omarchy/quran/run"
  })()
  readonly property string mpvSocketPath: root.mpvRuntimeDir + "/mpv.sock"

  // --- playback state (read by the bar widget + IPC) ---
  readonly property var player: playerFacade
  property string reciterId: Model.DEFAULT_RECITER
  property int surahNumber: 1
  property string playbackMode: Model.MODE_SINGLE
  property int resumePosition: 0
  // Last meaningful playback position. Only updated while media is loaded and
  // not at EOF (Playing/Paused equivalents, explicit seeks, periodic saves) so
  // a teardown/crash "stopped" state never persists 0 and wipes the resume
  // point on shell restart.
  property int savedPosition: 0
  readonly property bool isPlaying: root.hasMedia && !root.mpvPaused && !root.mpvEof
  readonly property bool isPaused: root.hasMedia && root.mpvPaused && !root.mpvEof
  readonly property bool hasMedia: root.currentSource !== ""

  // --- mpv engine state (mirrored from observed properties) ---
  property string currentSource: ""       // source the user asked to play
  property string playbackSourceKind: ""  // download | cache | stream
  property var playbackSourceTarget: null // { id, n } for local validation failures
  property var localValidationQueue: []
  property var localValidationPlaybackTarget: null
  property bool mpvPaused: true           // observed `pause`
  property bool mpvEof: false             // true after end-file reason "eof"
  property double mpvPositionMs: 0        // observed `time-pos` in ms
  property double mpvDurationMs: 0        // observed `duration` in ms
  property bool mpvSeekable: false        // observed `seekable`
  property bool mpvReady: false           // socket connected + observes sent
  property bool shuttingDown: false
  property int mpvRestartCount: 0         // mpv relaunch attempts (crash recovery)
  property int mpvConnectAttempts: 0      // socket connect attempts
  property var mpvSock: null              // live Socket instance
  property var resumeLoadTarget: null     // { positionMs } seek on file-loaded
  property bool endHandled: true          // EndOfMedia dedupe guard
  property int mpvRequestId: 0
  property string lastSource: ""          // crash recovery: source to reload
  property bool stateLoaded: false
  property bool resumePending: false

  // --- data ---
  readonly property var surahs: SurahData.SURAHS
  property var reciters: []
  property string language: Model.DEFAULT_LANGUAGE
  property var reciterStatus: ({}) // id -> prompt/failure history; not completion truth
  property var downloadedSurahs: ({}) // "reciterId:n" -> true
  property var downloadedCounts: ({}) // reciterId -> count derived from downloadedSurahs
  property double catalogFetchedAt: 0

  // --- errors / status ---
  property string errorMessage: ""
  property bool recitersLoading: false
  property bool catalogError: false      // last failure was the reciter fetch, not playback

  // --- download state (shared between widget + IPC) ---
  property bool downloading: false
  property int downloadDone: 0
  property int downloadTotal: 114
  property int downloadRevision: 0
  property string downloadReciter: ""   // reciter currently being downloaded
  property var lastDownload: null       // { id, surah } for retry after failure
  readonly property string downloadScript: Quickshell.env("HOME") + "/.config/omarchy/plugins/mus.quran/download.sh"
  readonly property string cacheScript: Quickshell.env("HOME") + "/.config/omarchy/plugins/mus.quran/cache.sh"
  readonly property string validateScript: Quickshell.env("HOME") + "/.config/omarchy/plugins/mus.quran/validate_media.sh"
  readonly property string cacheDir: Quickshell.env("HOME") + "/.cache/omarchy/quran"

  // --- streaming cache (invisible to the user; never changes download icons) ---
  property var cacheFiles: ({})        // "reciter:n" -> true (complete files)
  property var cacheLastPlayed: ({})   // "reciter:n" -> ms (LRU source, persisted)
  property var cacheInFlight: ({})     // "reciter:n" -> true (fill queued/running)
  property var fillQueue: []           // serialized background cache fills
  property var promotePending: ({})    // explicit download waiting on an in-flight fill
  property int cacheLimitMb: 500       // eviction budget (persisted)
  property double cacheSizeBytes: 0    // live cache dir size (for the UI)
  property var cacheQueue: []          // serialized cache.sh ops (scan/size/promote/evict/clear)
  property var mushafPlan: null        // { id, allMissing } during full-reciter download
  property int downloadBaseline: 0     // promoted count framing the mushaf progress bar

  // Per-reciter:surah fetch cooldown. After a failed fetch or a forced
  // playback error on a cached file, re-fetches are refused for
  // Model.COOLDOWN_MS so repeated IPC/retries cannot become a download storm.
  property var fetchCooldowns: ({})    // "reciter:n" -> epoch ms when the window ends
  property var foregroundFillTarget: null // { key, id, n, autoplay, positionMs } playing after fill
  property var promoteSingleTarget: null  // { id, n } awaited by promote-single completion
  property string mpvMprisScript: ""  // resolved mpv-mpris plugin path ("" = not found)

  function _inCooldown(id, n) {
    return Model.cooldownActive(root.fetchCooldowns, id + ":" + n, Date.now())
  }

  function _markFetchAttempt(id, n) {
    Model.markCooldown(root.fetchCooldowns, id + ":" + n, Date.now())
  }

  function _clearCooldown(id, n) {
    Model.clearCooldown(root.fetchCooldowns, id + ":" + n)
  }

  // Cap any string arriving over IPC before it is parsed or stored, so a
  // hostile caller can't force unbounded memory/state growth.
  function _capString(s, max) {
    s = String(s || "")
    return s.length > max ? s.substring(0, max) : s
  }

  // current surah/reciter convenience lookups
  readonly property var currentSurah: currentSurahFor(surahNumber)
  readonly property var currentReciter: reciterFor(reciterId)

  // `player` facade mirrors the old MediaPlayer surface (ms units) so the
  // bar widget and IPC see identical values; only the backend changed.
  QtObject {
    id: playerFacade
    readonly property int position: Math.round(root.mpvPositionMs)
    readonly property int duration: Math.round(root.mpvDurationMs)
    readonly property bool seekable: root.mpvSeekable && root.hasMedia

    function downloadSurah(id, n) {
      root.downloadSurah(id, n)
    }

    function downloadMushaf(id) {
      root.downloadMushaf(id)
    }

    readonly property int downloadDone: root.downloadDone
    readonly property int downloadTotal: root.downloadTotal
    readonly property bool downloading: root.downloading
  }

  function currentSurahFor(n) {
    if (!surahs || n < 1 || n > surahs.length) return null
    return surahs[n - 1]
  }

  function reciterFor(id) {
    if (!reciters) return null
    for (var i = 0; i < reciters.length; i++) {
      if (reciters[i].identifier === id) return reciters[i]
    }
    return null
  }

  function surahLabel(n) {
    return Model.surahDisplayLabel(currentSurahFor(n), root.language)
  }

  function reciterLabel() {
    return Model.reciterDisplayLabel(currentReciter, root.language)
  }

  function downloadedCount(id) {
    return root.downloadedCounts[id] || 0
  }

  function rebuildDownloadedCounts() {
    var counts = {}
    for (var key in root.downloadedSurahs) {
      if (root.downloadedSurahs[key] !== true) continue
      var sep = key.lastIndexOf(":")
      if (sep <= 0) continue
      var id = key.substring(0, sep)
      counts[id] = (counts[id] || 0) + 1
    }
    root.downloadedCounts = counts
  }

  // Completion is derived from the per-surah map. reciterStatus is persisted
  // history and may be stale if a file is removed or a prior batch was partial.
  function isMushafDownloaded(id) {
    return root.downloadedCount(id) === 114
  }

  // Compatibility alias for callers that used the old coarse API.
  function isDownloaded(id) {
    return root.isMushafDownloaded(id)
  }

  function isSurahDownloaded(id, n) {
    return root.downloadedSurahs[id + ":" + n] === true
  }

  function markSurahDownloaded(id, n) {
    var key = id + ":" + n
    var next = Object.assign({}, root.downloadedSurahs)
    var wasDownloaded = next[key] === true
    next[key] = true
    root.downloadedSurahs = next
    if (!wasDownloaded) {
      var counts = Object.assign({}, root.downloadedCounts)
      counts[id] = (counts[id] || 0) + 1
      root.downloadedCounts = counts
    }
    root.downloadRevision++
    root.saveState()
  }

  function invalidateSurahDownload(id, n) {
    var key = id + ":" + n
    if (root.downloadedSurahs[key] !== true) return
    var next = Object.assign({}, root.downloadedSurahs)
    delete next[key]
    root.downloadedSurahs = next
    var counts = Object.assign({}, root.downloadedCounts)
    counts[id] = Math.max(0, (counts[id] || 0) - 1)
    root.downloadedCounts = counts
    root.downloadRevision++
    root.saveState()
  }

  // true while a download is actively fetching this exact surah
  function isSurahDownloading(id, n) {
    return root.downloading
      && downloadProc.targetSurah === n
      && downloadProc.targetReciter === id
  }

  // true while a download is actively fetching this reciter's mushaf
  function isReciterDownloading(id) {
    return root.downloading
      && downloadProc.targetSurah === 0
      && downloadProc.targetReciter === id
  }

  // First time a reciter is touched (no status recorded yet), the widget
  // should prompt the user about downloading the full mushaf. Also re-prompt
  // partially-downloaded reciters (even if previously declined) so the
  // remaining surahs can be fetched in one click. A decline with zero
  // downloads is respected.
  function shouldPrompt(id) {
    return !root.isMushafDownloaded(id) && root.reciterStatus[id] === undefined
  }

  function hasAnyDownloaded(id) {
    for (var i = 1; i <= 114; i++) {
      if (root.downloadedSurahs[id + ":" + i]) return true
    }
    return false
  }

  // Count of this reciter's surahs not yet available offline.
  function missingCount(id) {
    var count = 0
    for (var i = 1; i <= 114; i++) {
      if (!root.isSurahDownloaded(id, i)) count++
    }
    return count
  }

  function setReciterStatus(id, status) {
    root.reciterStatus[id] = status
    root.saveState()
  }

  // --- mpv IPC --------------------------------------------------------------

  // Send one JSON command to mpv. Dropped silently if not connected (the
  // connect/recover machinery will re-issue playback state on connect).
  function _mpvCommand(cmd) {
    if (!root.mpvSock || !root.mpvSock.connected) return
    root.mpvRequestId++
    root.mpvSock.write(JSON.stringify({ command: cmd, request_id: root.mpvRequestId }) + "\n")
    root.mpvSock.flush()
  }

  function _observeMpv() {
    root._mpvCommand(["observe_property", 1, "pause"])
    root._mpvCommand(["observe_property", 2, "time-pos"])
    root._mpvCommand(["observe_property", 3, "duration"])
    root._mpvCommand(["observe_property", 4, "eof-reached"])
    root._mpvCommand(["observe_property", 5, "seekable"])
  }

  function onMpvLine(line) {
    var obj = null
    try { obj = JSON.parse(line) } catch (e) { obj = null }
    if (!obj) return
    if (obj.event === "property-change") root.onMpvProperty(obj.name, obj.data)
    else if (obj.event === "start-file") root.onMpvStartFile()
    else if (obj.event === "file-loaded") root.onMpvFileLoaded()
    else if (obj.event === "end-file") root.onMpvEndFile(obj.reason)
  }

  function onMpvProperty(name, data) {
    var v = (data === undefined) ? null : data
    if (name === "pause") {
      root.mpvPaused = (v === true)
    } else if (name === "time-pos") {
      if (typeof v === "number" && isFinite(v)) {
        root.mpvPositionMs = Math.round(v * 1000)
        // Persist only while media is loaded and not at EOF — never from the
        // idle/teardown nulls mpv sends after the file ends.
        if (root.hasMedia && !root.mpvEof) root.savedPosition = root.mpvPositionMs
      }
    } else if (name === "duration") {
      if (typeof v === "number" && isFinite(v) && v > 0) root.mpvDurationMs = Math.round(v * 1000)
    } else if (name === "eof-reached") {
      if (v === true) root.mpvEof = true
      else if (v === false) root.mpvEof = false
    } else if (name === "seekable") {
      root.mpvSeekable = (v === true)
    }
  }

  function onMpvStartFile() {
    root.mpvEof = false
    root.endHandled = false
    root.errorMessage = ""
  }

  function onMpvFileLoaded() {
    var t = root.resumeLoadTarget
    if (t && t.positionMs > 0) {
      root.resumeLoadTarget = null
      root._mpvCommand(["set_property", "time-pos", t.positionMs / 1000])
    }
  }

  function onMpvEndFile(reason) {
    if (reason === "eof") {
      root.mpvEof = true
      root._handleEndOfMedia()
    } else if (reason === "error") {
      // A failed load (404 / dead link) must not read as "playing": pin pause
      // so isPlaying goes false and the play button stops showing pause.
      root.mpvPaused = true
      if (root.playbackSourceKind === "download" && root.playbackSourceTarget) {
        root.invalidateSurahDownload(root.playbackSourceTarget.id, root.playbackSourceTarget.n)
      } else if (root.playbackSourceKind === "cache" && root.playbackSourceTarget) {
        // A corrupt cached file: drop it from the cache maps and delete it so
        // the next fill re-downloads clean instead of looping the same dead
        // file forever. The cooldown keeps a forced-error loop from becoming
        // a download storm — the next retry within 10 s is refused, and any
        // later retry re-fetches from the CDN.
        var cid = root.playbackSourceTarget.id
        var cn = root.playbackSourceTarget.n
        var ckey = cid + ":" + cn
        delete root.cacheFiles[ckey]
        delete root.cacheLastPlayed[ckey]
        root._markFetchAttempt(cid, cn)
        root.saveState()
        root.cacheOp({ mode: "remove-file",
          command: ["bash", root.cacheScript, "remove", root.cacheDir, cid, String(cn)] })
      }
      root.errorMessage = Model.tr(root.language, "playbackFailed")
    }
    // "stop" / "quit" / "redirect" / "unknown" (e.g. switching surahs) ignored.
  }

  // --- playback control -----------------------------------------------------

  function playSurah(reciterId_, surahNumber_) {
    if (!Model.isValidSurahNumber(surahNumber_)) {
      root.errorMessage = Model.tr(root.language, "invalidInput")
      return
    }
    root.reciterId = reciterId_ || root.reciterId
    root.surahNumber = surahNumber_
    root.resumePosition = 0
    root.savedPosition = 0
    root.errorMessage = ""
    pendingTarget = { id: root.reciterId, n: root.surahNumber }
    surahDebounce.restart()
  }

  function localAudioPath(id, n) {
    return root.dataDir + "/" + id + "/" + n + ".mp3"
  }

  // Playback source resolution (mpv backend), after permanent-file validation:
  //   1. explicitly downloaded (validated state dir) -> local file
  //   2. cached (cache dir, complete)                  -> local file
  //   3. else                                          -> foreground cache fill,
  //      then play the local file. mpv never receives a remote URL.
  function _playFallback(id, n, autoplay, positionMs) {
    var shouldPlay = autoplay !== false
    var resumeMs = positionMs || 0
    var key = id + ":" + n
    if (root.cacheFiles[key]) {
      root.touchCache(id, n)
      root.playbackSourceKind = "cache"
      root.playbackSourceTarget = { id: id, n: n }
      root._mpvLoad(Model.localAudioUrl(root.cacheDir, id, n), shouldPlay, resumeMs)
      root._setMprisMetadata(id, n)
      root.resumePending = false
      root.saveState()
      return
    }
    // Not cached: fetch into the cache (foreground), then play the local
    // file. A cooldown-blocked or budget-blocked fill fails playback rather
    // than streaming an unvalidated URL into mpv.
    root.playbackSourceKind = "cache"
    root.playbackSourceTarget = { id: id, n: n }
    if (!root.fillCache(id, n)) {
      root.errorMessage = Model.tr(root.language, "playbackFailed")
      return
    }
    root.foregroundFillTarget = { key: key, id: id, n: n, autoplay: shouldPlay, positionMs: resumeMs }
    foregroundFillTimer.restart()
  }

  // Called from fillProc.onExited when the awaited foreground fill finishes.
  function _onForegroundFillFinished(key, exitCode) {
    var t = root.foregroundFillTarget
    if (!t || t.key !== key) return
    root.foregroundFillTarget = null
    foregroundFillTimer.stop()
    if (exitCode === 0 && root.cacheFiles[key]) {
      root.touchCache(t.id, t.n)
      root.playbackSourceKind = "cache"
      root.playbackSourceTarget = { id: t.id, n: t.n }
      root._mpvLoad(Model.localAudioUrl(root.cacheDir, t.id, t.n), t.autoplay, t.positionMs)
      root._setMprisMetadata(t.id, t.n)
      root.resumePending = false
      root.saveState()
    } else {
      root.errorMessage = Model.tr(root.language, "playbackFailed")
    }
  }

  function _playNow(id, n) {
    if (root.reciters.length > 0 && !Model.reciterExists(root.reciters, id)) {
      root.errorMessage = Model.tr(root.language, "invalidInput")
      return
    }
    if (root.isSurahDownloaded(id, n)) {
      root.requestLocalValidation(id, n, true, 0)
      return
    }
    root._playFallback(id, n, true, 0)
  }

  function requestLocalValidation(id, n, autoplay, positionMs) {
    var target = { id: id, n: n, autoplay: autoplay !== false, positionMs: positionMs || 0 }
    if (localValidationProc.running) {
      localValidationPlaybackTarget = target
      return
    }
    localValidationProc.mode = "playback"
    localValidationProc.target = target
    // Deep media validation (size, MIME type, ffprobe) — fails closed when
    // file(1) is missing. A non-zero exit means the local file is unusable.
    localValidationProc.command = ["bash", root.validateScript, root.localAudioPath(id, n)]
    localValidationProc.running = true
  }

  function queueDownloadedFileValidation() {
    var queue = []
    for (var key in root.downloadedSurahs) {
      if (root.downloadedSurahs[key] !== true) continue
      var sep = key.lastIndexOf(":")
      if (sep <= 0) continue
      queue.push({ id: key.substring(0, sep), n: parseInt(key.substring(sep + 1)) })
    }
    localValidationQueue = queue
    pumpLocalValidation()
  }

  function pumpLocalValidation() {
    if (localValidationProc.running) return
    var target = null
    var mode = ""
    if (localValidationPlaybackTarget) {
      target = localValidationPlaybackTarget
      localValidationPlaybackTarget = null
      mode = "playback"
    } else if (localValidationQueue.length > 0) {
      target = localValidationQueue.shift()
      mode = "startup"
    } else {
      return
    }
    localValidationProc.mode = mode
    localValidationProc.target = target
    localValidationProc.command = ["test", "-s", root.localAudioPath(target.id, target.n)]
    localValidationProc.running = true
  }

  function onLocalValidationExited(exitCode) {
    var target = localValidationProc.target
    var mode = localValidationProc.mode
    localValidationProc.target = null
    localValidationProc.mode = ""
    if (target && exitCode !== 0) {
      root.invalidateSurahDownload(target.id, target.n)
      if (mode === "playback") root._playFallback(target.id, target.n, target.autoplay, target.positionMs)
    } else if (target && mode === "playback") {
      root.playbackSourceKind = "download"
      root.playbackSourceTarget = target
      root.reciterId = target.id
      root.surahNumber = target.n
      root._mpvLoad(Model.localAudioUrl(root.dataDir, target.id, target.n), target.autoplay, target.positionMs)
      root._setMprisMetadata(target.id, target.n)
      root.resumePending = false
      root.saveState()
    }
    pumpLocalValidation()
  }

  // Set mpv's force-media-title and artist so mpv-mpris surfaces surah/reciter
  // names instead of the raw CDN URL in playerctl metadata.
  function _setMprisMetadata(id, n) {
    var surah = root.currentSurahFor(n)
    var reciter = root.reciterFor(id)
    var title = surah ? Model.surahDisplayLabel(surah, root.language) : ("Surah " + n)
    var artist = reciter ? Model.reciterDisplayLabel(reciter, root.language) : id
    root._mpvCommand(["set_property", "force-media-title", title])
    root._mpvCommand(["set_property", "audio-display-metadata/by-key/artist", artist])
  }

  // Load a source into mpv. `loadfile` replaces whatever is playing, then the
  // pause property pins the desired start state; resume positions are applied
  // on `file-loaded` (mpv can't set time-pos before the file exists).
  // SECURITY: mpv only ever receives local files. Anything that is not a
  // file:// URL (a hostile catalog URL, a tampered state file, a stray IPC
  // call) is refused here — currentSource/lastSource are therefore always
  // local, and every replay path (playPause, seek, crash recovery) inherits
  // this guard.
  function _mpvLoad(source, autoplay, positionMs) {
    if (typeof source !== "string" || source.indexOf("file://") !== 0) {
      root.errorMessage = Model.tr(root.language, "playbackFailed")
      return
    }
    root.currentSource = source
    root.lastSource = source
    root.mpvEof = false
    root.endHandled = false
    root.errorMessage = ""
    root.mpvPaused = !autoplay
    root.resumeLoadTarget = (positionMs > 0) ? { positionMs: positionMs } : null
    root._mpvCommand(["loadfile", source])
    root._mpvCommand(["set_property", "pause", !autoplay])
  }

  function playPause() {
    if (!root.hasMedia) {
      if (root.resumePending && root.resumePosition > 0) {
        root._playNow(root.reciterId, root.surahNumber)
      } else {
        root.playSurah(root.reciterId, root.surahNumber)
      }
      return
    }
    // A finished surah sits idle in mpv; toggling pause does nothing, so play
    // replays it from the start like the old backend did.
    if (root.mpvEof) {
      root._mpvLoad(root.currentSource, true, 0)
      root.saveState()
      return
    }
    if (root.isPlaying) root._mpvCommand(["set_property", "pause", true])
    else root._mpvCommand(["set_property", "pause", false])
    root.saveState()
  }

  function stopPlayback() {
    root._mpvCommand(["stop"])
    root.currentSource = ""
    root.lastSource = ""
    root.mpvEof = false
    root.mpvPaused = true
    root.mpvPositionMs = 0
    root.mpvDurationMs = 0
    root.endHandled = true
    root.resumePosition = 0
    root.savedPosition = 0
    root.saveState()
  }

  function next() {
    if (root.surahNumber < surahs.length) root._playNow(root.reciterId, root.surahNumber + 1)
  }

  function previous() {
    if (root.surahNumber > 1) root._playNow(root.reciterId, root.surahNumber - 1)
  }

  function seek(ms) {
    if (!root.hasMedia) {
      root.savedPosition = Math.max(0, Math.round(ms))
      root.saveState()
      return
    }
    var target = Math.max(0, Math.round(ms))
    if (root.mpvEof) {
      root._mpvLoad(root.currentSource, false, target)
      root.saveState()
      return
    }
    root._mpvCommand(["set_property", "time-pos", target / 1000])
    root.savedPosition = target
    root.saveState()
  }

  function cycleMode() {
    var i = Model.MODES.indexOf(root.playbackMode)
    root.playbackMode = Model.MODES[(i + 1) % Model.MODES.length]
    root.saveState()
  }

  function setLanguage(code) {
    root.language = Model.isValidLanguage(code) ? code : Model.DEFAULT_LANGUAGE
    root.saveState()
  }

  function selectReciter(id) {
    root.reciterId = id
    root.saveState()
  }

  // --- end of media (repeat-mode logic hooks here) ---

  function _handleEndOfMedia() {
    if (root.endHandled) return
    root.endHandled = true
    root.resumePosition = 0
    root.savedPosition = 0
    root.saveState()
    root._onEndOfMedia()
  }

  function _onEndOfMedia() {
    var n = root.surahNumber
    var id = root.reciterId
    switch (root.playbackMode) {
      case Model.MODE_REPEAT_ONE:
        root._playNow(id, n)
        break
      case Model.MODE_CONTINUE:
        if (n < surahs.length) root._playNow(id, n + 1)
        break
      case Model.MODE_REPEAT_ALL:
        root._playNow(id, (n % surahs.length) + 1)
        break
      case Model.MODE_SINGLE:
      default:
        break
    }
  }

  // --- resume-on-startup (load paused at the saved position) ---

  function _maybeResume() {
    if (!root.stateLoaded || !root.mpvReady) return
    if (root.lastSource !== "") return
    if (!root.resumePending || root.resumePosition <= 0) return
    root.resumePending = false
    if (root.isSurahDownloaded(root.reciterId, root.surahNumber))
      root.requestLocalValidation(root.reciterId, root.surahNumber, false, root.resumePosition)
    else
      root._playFallback(root.reciterId, root.surahNumber, false, root.resumePosition)
  }

  // --- mpv lifecycle --------------------------------------------------------

  // (Re)create the socket. Each attempt uses a fresh Socket so a failed
  // connect is always retryable (QLocalSocket can't be re-targeted in place).
  // The unix connect can complete synchronously, firing onConnectionStateChanged
  // DURING createObject — before the assignment below runs. So connect is
  // triggered manually AFTER root.mpvSock is set, or onMpvConnected would see
  // a null socket and never issue the observe_property commands.
  function _mpvConnect() {
    if (root.shuttingDown || !mpvProc.running) return
    if (root.mpvSock) {
      root.mpvSock.connected = false
      root.mpvSock.destroy()
      root.mpvSock = null
    }
    root.mpvSock = mpvSocketComponent.createObject(root)
    root.mpvSock.connected = true
  }

  function _mpvRetryConnect() {
    if (root.shuttingDown || !mpvProc.running) return
    root.mpvConnectAttempts++
    if (root.mpvConnectAttempts > 30) return
    root._mpvConnect()
  }

  function onMpvConnected() {
    if (root.shuttingDown) return
    root.mpvConnectAttempts = 0
    root.mpvRestartCount = 0
    root.mpvReady = true
    root._observeMpv()
    root._mpvRecoverLast()
    root._maybeResume()
  }

  // After mpv restarts, re-issue the last known playback state so a crash is
  // transparent apart from a brief playback gap. Routed through _mpvLoad so
  // the file://-only guard applies here too.
  function _mpvRecoverLast() {
    if (root.lastSource === "") return
    var shouldPlay = root.isPlaying
    var pos = root.mpvPositionMs > 0 ? root.mpvPositionMs : root.savedPosition
    root._mpvLoad(root.lastSource, shouldPlay, pos)
  }

  function onMpvExited(exitCode) {
    root.mpvReady = false
    mpvConnectTimer.stop()
    if (root.mpvSock) {
      root.mpvSock.connected = false
      root.mpvSock.destroy()
      root.mpvSock = null
    }
    if (root.shuttingDown) return
    if (root.mpvRestartCount < 5) {
      root.mpvRestartCount++
      mpvRestartTimer.restart()
    } else {
      root.errorMessage = Model.tr(root.language, "mpvMissing")
    }
  }

  // --- downloads (explicit, state dir) ---------------------------------------

  function downloadSurah(id, n) {
    if (root.downloading || !Model.isValidSurahNumber(n)) return
    // Cooldown gate: a still-flagged corrupt file can be re-downloaded, but
    // not more than once per reciter:surah inside the cooldown window — even
    // via repeated IPC/retry calls.
    if (root._inCooldown(id, n)) return
    var key = id + ":" + n
    // Already fully cached? Promote straight to a permanent download (no network).
    if (root.cacheFiles[key]) {
      root.promoteSingleTarget = { id: id, n: n }
      root.promoteFromCache(id, n)
      return
    }
    // An explicit download takes priority over a background cache fill for
    // the same surah. Waiting here made the button appear inert after Retry
    // had started streaming the surah into the cache.
    if (root.cacheInFlight[key]) {
      root.cancelCacheFill(key)
    }
    root._markFetchAttempt(id, n)
    root.startExplicitDownload(id, n)
  }

  function startExplicitDownload(id, n) {
    root.downloading = true
    root.downloadReciter = id
    root.lastDownload = { id: id, surah: n }
    root.downloadDone = 0
    root.downloadTotal = 1
    root.errorMessage = ""
    downloadProc.targetReciter = id
    downloadProc.targetSurah = n
    var reciter = root.reciterFor(id)
    // stdbuf -oL: download.sh echo progress lines must arrive line-buffered
    // (piped stdout would otherwise only flush at process exit, freezing the
    // progress UI at 0% for the whole download).
    var cmd = ["stdbuf", "-oL", "bash", root.downloadScript, id, String(n)]
    if (reciter && reciter.server) {
      cmd.push("--server")
      cmd.push(reciter.server)
    }
    downloadProc.command = cmd
    downloadProc.running = true
  }

  function cancelCacheFill(key) {
    var remaining = []
    for (var i = 0; i < root.fillQueue.length; i++) {
      if (root.fillQueue[i] !== key) remaining.push(root.fillQueue[i])
    }
    root.fillQueue = remaining
    delete root.cacheInFlight[key]
    delete root.promotePending[key]
    // If this key is currently being fetched, stopping the process prevents
    // the background cache job from competing with the explicit action.
    // Its onExited handler will clean up the target and pump the next item.
    if (fillProc.target === key && fillProc.running)
      fillProc.running = false
  }

  function downloadMushaf(id) {
    if (root.downloading) return
    // Always validate the complete reciter set. The persisted downloaded flag
    // is only a cache of prior work and cannot prove that files still exist or
    // are intact. download.sh's complete() check skips valid files and fetches
    // only missing/corrupt ones.
    var work = []
    for (var i = 1; i <= 114; i++) work.push(i)
    var promoteList = []
    for (var j = 0; j < work.length; j++) {
      if (root.cacheFiles[id + ":" + work[j]]) promoteList.push(work[j])
    }
    var remaining = []
    for (var k = 0; k < work.length; k++) {
      if (promoteList.indexOf(work[k]) === -1) remaining.push(work[k])
    }
    root.downloading = true
    root.downloadReciter = id
    root.lastDownload = { id: id, surah: 0 }
    // Progress reflects validation/download of all 114 surahs. Cached files
    // promoted before the process starts form the initial baseline.
    var baseline = promoteList.length
    root.downloadDone = baseline
    root.downloadTotal = 114
    root.downloadBaseline = baseline
    root.errorMessage = ""
    root.mushafPlan = { id: id, allMissing: work }
    if (promoteList.length > 0) root.promoteRun(id, promoteList)
    else root.startMushafDownload(id, remaining)
  }

  // Move complete cached files into the state dir (permanent). `list` is a
  // subset of the mushaf's missing set; completion is handled in the cache-op
  // pump, which then launches `download.sh --only <remaining>` for the rest.
  function promoteRun(id, list) {
    root.cacheOp({ mode: "promote",
      command: ["bash", root.cacheScript, "promote", root.cacheDir, root.dataDir, id, list.join(",")] })
  }

  function promoteFromCache(id, n) {
    root.cacheOp({ mode: "promote-single",
      command: ["bash", root.cacheScript, "promote", root.cacheDir, root.dataDir, id, String(n)] })
  }

  function startMushafDownload(id, list) {
    downloadProc.targetReciter = id
    downloadProc.targetSurah = 0
    var reciter = root.reciterFor(id)
    var cmd = ["stdbuf", "-oL", "bash", root.downloadScript, id, "--only", list.join(",")]
    if (reciter && reciter.server) {
      cmd.push("--server")
      cmd.push(reciter.server)
    }
    downloadProc.command = cmd
    downloadProc.running = true
  }

  function finishMushafDownload(id) {
    root.downloading = false
    root.downloadReciter = ""
    root.downloadDone = 114
    root.downloadTotal = 114
    downloadProc.targetReciter = null
    downloadProc.targetSurah = 0
    root.setReciterStatus(id, "downloaded")
    var next = Object.assign({}, root.downloadedSurahs)
    for (var i = 1; i <= 114; i++) next[id + ":" + i] = true
    root.downloadedSurahs = next
    var counts = Object.assign({}, root.downloadedCounts)
    counts[id] = 114
    root.downloadedCounts = counts
    root.downloadRevision++
    root.saveState()
  }

  function retryDownload() {
    if (!root.lastDownload || root.downloading) return
    root.errorMessage = ""
    if (root.lastDownload.surah > 0)
      root.downloadSurah(root.lastDownload.id, root.lastDownload.surah)
    else
      root.downloadMushaf(root.lastDownload.id)
  }

  function applyDownloadProgress(line) {
    var bytes = String(line).match(/^progress_bytes\s+(\d+)\/(\d+)\s*$/)
    if (bytes && downloadProc.targetSurah > 0) {
      root.downloadDone = Math.min(100, parseInt(bytes[1]))
      root.downloadTotal = 100
      return
    }
    var m = String(line).match(/^progress\s+(\d+)\/(\d+)\s*$/)
    if (!m) return
    if (downloadProc.targetSurah === 0) {
      root.downloadDone = Math.min(114, root.downloadBaseline + parseInt(m[1]))
      root.downloadTotal = 114
    } else {
      root.downloadDone = parseInt(m[1])
      root.downloadTotal = parseInt(m[2])
    }
  }

  // --- streaming cache fills (background, serialized, invisible) -------------

  function touchCache(id, n) {
    root.cacheLastPlayed[id + ":" + n] = Date.now()
  }

  function fillCache(id, n) {
    var key = id + ":" + n
    if (root.cacheFiles[key]) return true
    if (root.cacheInFlight[key]) return true
    // Cooldown gate: failed/forced-error surahs are not re-fetched inside the
    // window, no matter how often playback or IPC retries them.
    if (root._inCooldown(id, n)) return false
    // Budget gate: never fill beyond the cache budget. Eviction stays
    // post-hoc LRU; this check only prevents the cache from growing while an
    // eviction is pending or the budget was lowered.
    if (root.cacheSizeBytes + Model.MAX_SURAH_BYTES > root.cacheLimitMb * 1048576) {
      root.runEviction()
      return false
    }
    root.cacheInFlight[key] = true
    root.fillQueue.push(key)
    root.pumpFillQueue()
    return true
  }

  function pumpFillQueue() {
    if (fillProc.running) return
    if (root.fillQueue.length === 0) return
    var key = root.fillQueue.shift()
    var parts = root.splitKey(key)
    // Re-validate at dequeue time: state may have changed since enqueue.
    if (root.cacheFiles[key] || root._inCooldown(parts[0], parts[1])) {
      delete root.cacheInFlight[key]
      root.pumpFillQueue()
      return
    }
    if (root.cacheSizeBytes + Model.MAX_SURAH_BYTES > root.cacheLimitMb * 1048576) {
      delete root.cacheInFlight[key]
      root.pumpFillQueue()
      return
    }
    var reciter = root.reciterFor(parts[0])
    fillProc.target = key
    // download.sh enforces the same budget on its side (defense in depth).
    var cmd = ["bash", root.downloadScript, parts[0], parts[1], "--dest", root.cacheDir,
      "--budget-bytes", String(root.cacheLimitMb * 1048576)]
    if (reciter && reciter.server) {
      cmd.push("--server")
      cmd.push(reciter.server)
    }
    fillProc.command = cmd
    fillProc.running = true
  }

  function splitKey(key) {
    var sep = key.lastIndexOf(":")
    return [key.substring(0, sep), key.substring(sep + 1)]
  }

  // --- cache.sh ops (scan/size/promote/evict/clear), serialized --------------

  function cacheOp(op) {
    root.cacheQueue.push(op)
    root.pumpCacheOps()
  }

  function pumpCacheOps() {
    if (cacheProc.running) return
    if (root.cacheQueue.length === 0) return
    var op = root.cacheQueue.shift()
    cacheProc.mode = op.mode
    cacheProc.collected = ""
    cacheProc.command = op.command
    cacheProc.running = true
  }

  function runEviction() {
    var args = root.lastPlayedArgs()
    var cmd = ["bash", root.cacheScript, "evict", root.cacheDir, String(root.cacheLimitMb)]
    for (var i = 0; i < args.length; i++) cmd.push(args[i])
    root.cacheOp({ mode: "evict", command: cmd })
  }

  function refreshCacheSize() {
    root.cacheOp({ mode: "size", command: ["bash", root.cacheScript, "size", root.cacheDir] })
  }

  function clearCache() {
    var keep = []
    for (var key in root.cacheInFlight) {
      keep.push(root.cacheDir + "/" + root.cacheRelPath(key) + ".mp3.part")
    }
    var cmd = ["bash", root.cacheScript, "clear", root.cacheDir]
    for (var i = 0; i < keep.length; i++) cmd.push(keep[i])
    root.cacheOp({ mode: "clear", command: cmd })
  }

  function cacheRelPath(key) {
    var parts = root.splitKey(key)
    return parts[0] + "/" + parts[1]
  }

  // Only pass LRU timestamps for files still present in the cache.
  function lastPlayedArgs() {
    var args = []
    for (var k in root.cacheLastPlayed) {
      if (root.cacheFiles[k]) args.push(k + "=" + root.cacheLastPlayed[k])
    }
    if (args.length === 0) return []
    var out = ["--last-played"]
    for (var i = 0; i < args.length; i++) out.push(args[i])
    return out
  }

  function onCacheOpDone(mode, exitCode, out) {
    var lines = out.split("\n")
    var i, m, key, parts
    if (mode === "scan") {
      // Rebuild the map from scratch rather than merging: purges ghost
      // entries (including any pre-existing flat <cacheDir>/<n>.mp3 from
      // older builds, which never match "<reciter>/<n>.mp3"). Entries are
      // routed through the same whitelist loadState uses — don't blindly
      // trust scan output even though cache.sh constrains it.
      var rebuilt = {}
      for (i = 0; i < lines.length; i++) {
        m = lines[i].match(/^(\S+)\/(\d+)\.mp3$/)
        if (!m) continue
        var rid = m[1]
        var rnum = parseInt(m[2], 10)
        if (!Model.isSafeIdentifier(rid)) continue
        if (!Model.isValidSurahNumber(rnum)) continue
        rebuilt[rid + ":" + rnum] = true
      }
      root.cacheFiles = rebuilt
    } else if (mode === "size") {
      root.cacheSizeBytes = parseInt(out) || 0
    } else if (mode === "promote" || mode === "promote-single") {
      // "moved reciter/n" lines: those files left the cache for the state dir.
      var moved = []
      for (i = 0; i < lines.length; i++) {
        m = lines[i].match(/^moved (\S+)\/(\d+)$/)
        if (!m) continue
        key = m[1] + ":" + m[2]
        delete root.cacheFiles[key]
        delete root.cacheLastPlayed[key]
        root.markSurahDownloaded(m[1], parseInt(m[2]))
        moved.push(m[2])
      }
      if (mode === "promote-single") {
        if (moved.length === 0 && root.promoteSingleTarget) {
          // The cached file is actually missing (or the move failed): fall
          // back to a real download instead of silently no-op'ing.
          var ps = root.promoteSingleTarget
          root.promoteSingleTarget = null
          if (!root._inCooldown(ps.id, ps.n)) {
            root._markFetchAttempt(ps.id, ps.n)
            root.startExplicitDownload(ps.id, ps.n)
          } else {
            root.downloading = false
            root.errorMessage = Model.tr(root.language, "downloadFailed")
          }
        } else {
          root.promoteSingleTarget = null
          root.downloading = false
        }
      } else if (root.mushafPlan) {
        var plan = root.mushafPlan
        root.mushafPlan = null
        var remaining = []
        for (i = 0; i < plan.allMissing.length; i++) {
          var n = plan.allMissing[i]
          if (moved.indexOf(String(n)) === -1) remaining.push(n)
        }
        // downloadBaseline/downloadDone were set in downloadMushaf and already
        // include the promoted files — keep them, download.sh adds on top.
        if (remaining.length > 0) root.startMushafDownload(plan.id, remaining)
        else root.finishMushafDownload(plan.id)
      }
      root.refreshCacheSize()
    } else if (mode === "evict") {
      for (i = 0; i < lines.length; i++) {
        m = lines[i].match(/^deleted (\S+)\/(\d+)\.mp3$/)
        if (!m) continue
        key = m[1] + ":" + m[2]
        delete root.cacheFiles[key]
        delete root.cacheLastPlayed[key]
      }
      root.refreshCacheSize()
    } else if (mode === "clear") {
      var drop = []
      for (var k in root.cacheFiles) if (!root.cacheInFlight[k]) drop.push(k)
      for (i = 0; i < drop.length; i++) delete root.cacheFiles[drop[i]]
      drop = []
      for (var k2 in root.cacheLastPlayed) if (!root.cacheInFlight[k2]) drop.push(k2)
      for (i = 0; i < drop.length; i++) delete root.cacheLastPlayed[drop[i]]
      root.saveState()
      root.refreshCacheSize()
    }
  }

  // --- reciter catalog fetch (with cache) ---

  property string rawRecitersEng: ""
  property string rawRecitersAr: ""

  function fetchReciters() {
    if (recitersProc.running || recitersArProc.running) return
    if (root.reciters.length > 0
        && root.catalogFetchedAt > 0
        && (Date.now() - root.catalogFetchedAt) < Model.CATALOG_TTL_MS) {
      return
    }
    root.recitersLoading = true
    root.rawRecitersEng = ""
    root.rawRecitersAr = ""
    // Catalog fetches are bounded: https-only, no redirects, strict timeouts,
    // and a hard 2 MB response cap so a hostile catalog can't exhaust memory.
    var catalogFlags = ["curl", "-fsSL", "--proto", "=https", "--proto-redir", "=https",
      "--max-redirs", "0", "--connect-timeout", "10", "--max-time", "20",
      "--max-filesize", "2097152"]
    recitersProc.command = catalogFlags.concat([Model.API_RECITERS_ENG])
    recitersProc.running = true
    recitersArProc.command = catalogFlags.concat([Model.API_RECITERS_AR])
    recitersArProc.running = true
  }

  function applyReciters(jsonEng, jsonAr) {
    var dataEng = null
    var dataAr = null
    try { dataEng = JSON.parse(jsonEng || "") } catch (e) { dataEng = null }
    try { dataAr = JSON.parse(jsonAr || "") } catch (e) { dataAr = null }
    var parsed = Model.parseReciters(dataEng, dataAr)
    if (parsed.length === 0) {
      // Never replace a known-good catalog with an empty one; only surface
      // the error when there is nothing to fall back on.
      root.recitersLoading = false
      if (root.reciters.length === 0) {
        root.catalogError = true
        root.errorMessage = Model.tr(root.language, "reciterLoadFailed")
      }
      return
    }
    root.reciters = parsed
    root.recitersLoading = false
    root.catalogError = false
    if (!root.currentReciter) root.reciterId = Model.DEFAULT_RECITER
    root.catalogFetchedAt = Date.now()
    root.saveState()
  }

  // Retry the last failed action: a failed catalog fetch refetches the reciter
  // list; a playback failure re-attempts playback. (Retrying playback when the
  // catalog is empty is pointless because there is nothing to list/validate.)
  function retry() {
    root.errorMessage = ""
    if (root.catalogError || root.reciters.length === 0) {
      root.catalogError = false
      root.fetchReciters()
      return
    }
    root.playSurah(root.reciterId, root.surahNumber)
  }

  // --- state persistence ----------------------------------------------------

  function saveState() {
    var state = {
      version: Model.STATE_VERSION,
      language: root.language,
      reciterId: root.reciterId,
      surahNumber: root.surahNumber,
      playbackMode: root.playbackMode,
      position: root.savedPosition,
      wasPlaying: root.isPlaying,
      cacheLimitMb: root.cacheLimitMb,
      cacheLastPlayed: root.cacheLastPlayed,
      reciters: root.reciters,
      catalogFetchedAt: root.catalogFetchedAt,
      reciterStatus: root.reciterStatus,
      downloadedSurahs: root.downloadedSurahs
    }
    stateFile.setText(JSON.stringify(state))
  }

  function loadState(json) {
    if (!json) return
    var data = null
    try { data = JSON.parse(json) } catch (e) { data = null }
    if (!data) return

    // --- sanitize every field (schema v2, tolerate legacy garbage) ---
    if (Model.isValidLanguage(data.language)) root.language = data.language
    else root.language = Model.DEFAULT_LANGUAGE

    if (Model.MODES.indexOf(data.playbackMode) !== -1) root.playbackMode = data.playbackMode
    else root.playbackMode = Model.MODE_SINGLE

    if (typeof data.reciterId === "string" && Model.isSafeIdentifier(data.reciterId)) {
      root.reciterId = data.reciterId
    }
    if (typeof data.surahNumber === "number"
        && data.surahNumber >= 1 && data.surahNumber <= 114) root.surahNumber = data.surahNumber

    if (Array.isArray(data.reciters) && data.reciters.length > 0) {
      // Re-validate persisted catalog entries (a stale/tampered state file
      // must not reintroduce an unsafe `server` or identifier). Count cap so
      // a hostile state file can't blow up memory.
      var safeReciters = []
      for (var ri = 0; ri < data.reciters.length && safeReciters.length < 1000; ri++) {
        if (Model.isSafeReciter(data.reciters[ri])) safeReciters.push(data.reciters[ri])
      }
      if (safeReciters.length > 0) {
        root.reciters = safeReciters
        if (!root.currentReciter) root.reciterId = Model.DEFAULT_RECITER
      }
    }
    if (typeof data.catalogFetchedAt === "number" && isFinite(data.catalogFetchedAt) && data.catalogFetchedAt >= 0) {
      root.catalogFetchedAt = data.catalogFetchedAt
    }
    if (data.reciterStatus && typeof data.reciterStatus === "object") {
      // Keys must be valid identifiers, values from the known set; junk is
      // dropped individually.
      var statusClean = {}
      for (var sk in data.reciterStatus) {
        if (!Model.isSafeIdentifier(sk)) continue
        var sv = data.reciterStatus[sk]
        if (sv === "downloaded" || sv === "declined" || sv === "failed") statusClean[sk] = sv
      }
      root.reciterStatus = statusClean
    }
    if (data.downloadedSurahs && typeof data.downloadedSurahs === "object") {
      // Keys must match <validIdentifier>:<1..114> with a canonical number,
      // value === true; invalid keys are dropped individually (not a
      // wholesale reject) and the map is capped.
      var dlClean = {}
      var dlCount = 0
      for (var dk in data.downloadedSurahs) {
        if (dlCount >= 5000) break
        if (data.downloadedSurahs[dk] !== true) continue
        var dsep = dk.lastIndexOf(":")
        if (dsep <= 0) continue
        var did = dk.substring(0, dsep)
        var dnumStr = dk.substring(dsep + 1)
        var dnum = parseInt(dnumStr, 10)
        if (!Model.isSafeIdentifier(did)) continue
        if (!Model.isValidSurahNumber(dnum)) continue
        if (String(dnum) !== dnumStr) continue
        dlClean[dk] = true
        dlCount++
      }
      root.downloadedSurahs = dlClean
      root.rebuildDownloadedCounts()
      root.downloadRevision++
      root.queueDownloadedFileValidation()
    }

    // Cache budget is user-tunable via quran.json (sanitized to a sane range).
    if (typeof data.cacheLimitMb === "number" && data.cacheLimitMb >= 100 && data.cacheLimitMb <= 10000) {
      root.cacheLimitMb = data.cacheLimitMb
    } else {
      root.cacheLimitMb = 500
    }
    if (data.cacheLastPlayed && typeof data.cacheLastPlayed === "object") {
      // Same key whitelist as downloadedSurahs; values must be finite ms
      // timestamps within safe-integer range.
      var clpClean = {}
      for (var ck in data.cacheLastPlayed) {
        var csep = ck.lastIndexOf(":")
        if (csep <= 0) continue
        var cid = ck.substring(0, csep)
        var cnumStr = ck.substring(csep + 1)
        var cnum = parseInt(cnumStr, 10)
        if (!Model.isSafeIdentifier(cid)) continue
        if (!Model.isValidSurahNumber(cnum)) continue
        if (String(cnum) !== cnumStr) continue
        var cv = data.cacheLastPlayed[ck]
        if (typeof cv !== "number" || !isFinite(cv) || cv < 0 || cv > Number.MAX_SAFE_INTEGER) continue
        clpClean[ck] = cv
      }
      root.cacheLastPlayed = clpClean
    } else {
      root.cacheLastPlayed = {}
    }

    // Resume: restore last surah but stay paused; seek after the media loads.
    if (typeof data.position === "number" && isFinite(data.position)
        && data.position > 0 && data.position <= 24 * 60 * 60 * 1000) {
      root.resumePosition = data.position
      root.savedPosition = data.position
      root.resumePending = true
    } else {
      root.resumePosition = 0
    }

    root.stateLoaded = true
    root._maybeResume()
    if (data.version !== Model.STATE_VERSION) root.saveState()
  }

  // --- init ---

  Component.onCompleted: {
    root.fetchReciters()
    root.cacheOp({ mode: "scan", command: ["bash", root.cacheScript, "scan", root.cacheDir] })
    root.cacheOp({ mode: "size", command: ["bash", root.cacheScript, "size", root.cacheDir] })
    sockCleanProc.running = true
    mprisFindProc.running = true
  }

  Component.onDestruction: {
    root.shuttingDown = true
    mpvConnectTimer.stop()
    if (root.mpvSock) {
      root.mpvSock.connected = false
      root.mpvSock.destroy()
      root.mpvSock = null
    }
    mpvProc.running = false
  }

  // --- mpv backend ----------------------------------------------------------
  // A single long-lived mpv owns playback; MPRIS is provided by the mpv-mpris
  // plugin loaded explicitly (--script=...), never via config autoload —
  // --no-config disables the default script-autoload dir, so relying on
  // autoload would silently drop MPRIS. No network flags: mpv only ever
  // receives local files (see _mpvLoad).

  // Full mpv command line, built once the mpris plugin path is known.
  function _mpvCommandLine() {
    var cmd = ["mpv", "--idle", "--no-video", "--no-terminal",
      "--no-config", "--no-input-default-bindings", "--no-osc",
      "--demuxer-max-bytes=2M", "--demuxer-max-back-bytes=1M", "--demuxer-readahead-secs=15",
      "--input-ipc-server=" + root.mpvSocketPath]
    if (root.mpvMprisScript !== "") cmd.push("--script=" + root.mpvMprisScript)
    return cmd
  }

  // Start mpv once both the socket-cleanup and the mpris probe finished.
  function _maybeStartMpv() {
    if (root.shuttingDown || mpvProc.running) return
    if (sockCleanProc.running || mprisFindProc.running) return
    mpvProc.command = root._mpvCommandLine()
    mpvProc.running = true
  }

  Process {
    id: localValidationProc
    property var target: null
    property string mode: ""
    onExited: function(exitCode) { root.onLocalValidationExited(exitCode) }
  }

  Process {
    id: mpvProc
    command: ["mpv", "--idle"]
    running: false
    onStarted: root._mpvConnect()
    onExited: function(exitCode) { root.onMpvExited(exitCode) }
  }

  // Locate the mpv-mpris C plugin in the standard install locations. When it
  // is missing, playback continues without system media control.
  Process {
    id: mprisFindProc
    command: ["bash", "-c",
      'for p in /usr/lib/mpv/mpv-mpris/mpv_mpris.so /usr/lib64/mpv/mpv-mpris/mpv_mpris.so /usr/share/mpv/scripts/mpv-mpris/mpv_mpris.so "$HOME/.config/mpv/scripts/mpv-mpris/mpv_mpris.so" "$HOME/.local/lib/mpv/mpv-mpris/mpv_mpris.so"; do [ -f "$p" ] && { echo "$p"; exit 0; }; done; exit 1']
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.mpvMprisScript = text.trim()
    }
    running: false
    onExited: root._maybeStartMpv()
  }

  Timer {
    id: mpvRestartTimer
    interval: 1000
    onTriggered: {
      if (!root.shuttingDown && !mpvProc.running && root.mpvRestartCount < 5) {
        root._maybeStartMpv()
      }
    }
  }

  Timer {
    id: mpvConnectTimer
    interval: 350
    onTriggered: root._mpvRetryConnect()
  }

  // Instantiated fresh on every connect attempt so a failed connect never
  // leaves the wrapper stuck on a dead QLocalSocket. `connected` is left off
  // here; _mpvConnect triggers it manually after assigning root.mpvSock.
  Component {
    id: mpvSocketComponent
    Socket {
      path: root.mpvSocketPath
      parser: SplitParser {
        onRead: function(line) { root.onMpvLine(line) }
      }
      onError: function() { mpvConnectTimer.restart() }
      onConnectionStateChanged: {
        if (connected) {
          mpvConnectTimer.stop()
          root.onMpvConnected()
        } else if (!root.shuttingDown) {
          mpvConnectTimer.restart()
        }
      }
    }
  }

  // Debounce rapid surah switching so only the last requested target loads.
  property var pendingTarget: null
  Timer {
    id: surahDebounce
    interval: 300
    onTriggered: {
      if (root.pendingTarget) root._playNow(root.pendingTarget.id, root.pendingTarget.n)
      root.pendingTarget = null
    }
  }

  // Bound on a foreground cache fill: if the fill hasn't completed within 120
  // seconds the playback attempt fails and the surah is left for a (cooldown-
  // gated) background retry.
  Timer {
    id: foregroundFillTimer
    interval: 120000
    repeat: false
    onTriggered: {
      root.foregroundFillTarget = null
      root.errorMessage = Model.tr(root.language, "playbackFailed")
    }
  }

  // Periodic position save while playing.
  Timer {
    id: positionSaveTimer
    interval: 5000
    running: root.isPlaying
    repeat: true
    onTriggered: {
      if (root.player.position > 0) root.savedPosition = root.player.position
      root.saveState()
    }
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadState(text())
    onFileChanged: reload()
  }

  Process {
    id: recitersProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.rawRecitersEng = text
        if (root.rawRecitersAr !== "") root.applyReciters(root.rawRecitersEng, root.rawRecitersAr)
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.recitersLoading = false
        root.catalogError = true
        root.errorMessage = Model.tr(root.language, "reciterLoadFailed")
      }
    }
  }

  Process {
    id: recitersArProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.rawRecitersAr = text
        if (root.rawRecitersEng !== "") root.applyReciters(root.rawRecitersEng, root.rawRecitersAr)
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.rawRecitersEng !== "") {
        root.applyReciters(root.rawRecitersEng, "")
      }
    }
  }

  Process {
    id: downloadProc
    property var targetReciter: null
    property int targetSurah: 0
    stdout: SplitParser { onRead: function(line) { root.applyDownloadProgress(line) } }
    onExited: function(exitCode) {
      var id = downloadProc.targetReciter
      var n = downloadProc.targetSurah
      root.downloading = false
      if (exitCode === 0) {
        if (n > 0) {
          root._clearCooldown(id, n)
          root.markSurahDownloaded(id, n)
        } else {
          root.finishMushafDownload(id)
          id = null
          n = 0
        }
        } else if (id) {
        if (n > 0) {
          // Single-surah failure: surface it through the existing inline
          // error pattern; the icon reverts and a retry re-runs download.sh.
          root.errorMessage = Model.tr(root.language, "downloadFailed")
        } else {
          // Partial mushaf: keep what finished; a retry resumes (curl -C -).
          // Always surface the failure, including a previously-declined
          // reciter; the old branch made an instant script failure invisible.
          root.errorMessage = Model.tr(root.language, "downloadFailed")
          if (root.reciterStatus[id] !== "downloaded")
            root.setReciterStatus(id, "failed")
        }
      }
      downloadProc.targetReciter = null
      downloadProc.targetSurah = 0
      root.downloadReciter = ""
    }
  }

  Process {
    id: fillProc
    property string target: ""
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      var key = fillProc.target
      fillProc.target = ""
      delete root.cacheInFlight[key]
      var parts = root.splitKey(key)
      if (exitCode === 0) {
        root.cacheFiles[key] = true
        root.touchCache(parts[0], parts[1])
        root._clearCooldown(parts[0], parts[1])
        root.saveState()
        root.runEviction()
        root.refreshCacheSize()
      }
      if (root.promotePending[key]) {
        delete root.promotePending[key]
        if (exitCode === 0) root.promoteFromCache(parts[0], parts[1])
      }
      root._onForegroundFillFinished(key, exitCode)
      root.pumpFillQueue()
    }
  }

  Process {
    id: cacheProc
    property string mode: ""
    property string collected: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: cacheProc.collected = text
    }
    onExited: function(exitCode) {
      var mode = cacheProc.mode
      var out = cacheProc.collected || ""
      cacheProc.mode = ""
      cacheProc.collected = ""
      root.onCacheOpDone(mode, exitCode, out)
      root.pumpCacheOps()
    }
  }

  // Prepare the mpv runtime dir (0700) and remove any stale IPC socket before
// (re)starting mpv. The socket is only unlinked when it exists, is a socket,
// and is owned by the current euid — a foreign file (or a symlink) at that
// path is never deleted. Unlinking only drops the directory entry: a live
// orphaned mpv keeps its bound inode (unreachable) while a fresh mpv can bind
// the path again — safe for our private socket.
  Process {
    id: sockCleanProc
    command: ["bash", "-c",
      'd="$1"; p="$2"; mkdir -p -m 700 -- "$d" || exit 1; [ -S "$p" ] || exit 0; [ "$(stat -c %u "$p")" = "$(id -u)" ] || exit 0; rm -f -- "$p"',
      "sockclean", root.mpvRuntimeDir, root.mpvSocketPath]
    running: false
    onExited: root._maybeStartMpv()
  }

  IpcHandler {
    target: "quran"

    function status(): string {
      return JSON.stringify({
        reciterId: root.reciterId,
        reciterLabel: root.reciterLabel(),
        surahNumber: root.surahNumber,
        surahLabel: root.surahLabel(root.surahNumber),
        mode: root.playbackMode,
        playing: root.isPlaying,
        paused: root.isPaused,
        position: player.position,
        duration: player.duration,
        seekable: player.seekable,
        hasMedia: root.hasMedia,
        downloading: root.downloading,
        downloadDone: root.downloadDone,
        downloadTotal: root.downloadTotal
      })
    }

    function playPause(): string {
      root.playPause()
      return "ok"
    }

    function next(): string {
      root.next()
      return "ok"
    }

    function previous(): string {
      root.previous()
      return "ok"
    }

    function seek(ms: string): string {
      var v = Model.parseSeekArg(root._capString(ms, 32))
      if (v === null) return "error: invalid seek position"
      root.seek(v)
      return "ok"
    }

    function playSurah(reciterId: string, surahNumber: string): string {
      var id = root._capString(reciterId, 128)
      if (!id) id = root.reciterId
      var n = Model.parseSurahArg(root._capString(surahNumber, 32))
      if (n === null) return "error: invalid surah"
      if (!Model.isSafeReciterArg(id)) return "error: invalid reciter"
      if (root.reciters.length > 0 && !Model.reciterExists(root.reciters, id)) return "error: unknown reciter"
      root.playSurah(id, n)
      return "ok"
    }

    function setLanguage(language: string): string {
      root.setLanguage(language)
      return "ok"
    }

    function setMode(mode: string): string {
      if (Model.MODES.indexOf(mode) !== -1) {
        root.playbackMode = mode
        root.saveState()
      }
      return "ok"
    }

    function download(reciterId: string, n: string): string {
      var id = root._capString(reciterId, 128)
      if (!Model.isSafeReciterArg(id)) return "error: invalid reciter"
      if (!Model.reciterExists(root.reciters, id)) return "error: unknown reciter"
      var raw = root._capString(n, 32)
      var surah = 0
      if (raw !== "") {
        surah = Model.parseSurahArg(raw)
        if (surah === null) return "error: invalid surah"
      }
      if (surah === 0) {
        root.downloadMushaf(id)
      } else {
        // Cooldown gate alongside the existing refuse-while-downloading guard:
        // a caller cannot force more than one real fetch per reciter:surah
        // inside the window.
        if (root.downloading || root._inCooldown(id, surah)) return "error: retry in a moment"
        root.downloadSurah(id, surah)
      }
      return "ok"
    }

    function ping(): string {
      return "ok"
    }

    function clearCache(): string {
      root.clearCache()
      return "ok"
    }

    function cacheInfo(): string {
      return JSON.stringify({
        sizeBytes: root.cacheSizeBytes,
        limitMb: root.cacheLimitMb,
        files: Object.keys(root.cacheFiles).length,
        inflight: Object.keys(root.cacheInFlight).length
      })
    }
  }
}
