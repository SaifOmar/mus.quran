import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model
import "SurahNames.js" as SurahData

Item {
    id: root

    property var shell: null
    property var pluginRegistry: null

    readonly property string defaultDataDir: Quickshell.env("HOME") + "/.local/state/omarchy/quran"
    // User-configured download root (persisted; "" = default). Previous roots
    // are remembered in legacyRoots so already-downloaded files stay playable
    // without a migration — lookups check the current root first, then each
    // legacy root.
    property string downloadDir: ""
    property var legacyRoots: []
    property string dataDir: root.downloadDir !== "" ? root.downloadDir : root.defaultDataDir
    // Read-only local library: an existing folder of audio that is played
    // directly (never copied or promoted). Two layouts are supported:
    // <root>/<reciterId>/<n>.mp3, or flat <root>/<n>.mp3 attributed to the
    // configured libraryReciter. Persisted; "" = disabled.
    property string libraryDir: ""
    property string libraryReciter: ""    // reciter for flat (depth-1) library files
    property var libraryAvailable: ({})   // "<reciterId>:<n>" -> true, from the last scan
    property bool libraryScanning: false
    readonly property string statePath: Quickshell.env("HOME") + "/.local/state/omarchy/settings/quran.json"
    // mpv IPC socket lives in a private 0700 runtime dir (created on startup),
    // never /tmp. Falls back under the cache root when XDG_RUNTIME_DIR is unset.
    readonly property string mpvRuntimeDir: (function () {
            var rt = Quickshell.env("XDG_RUNTIME_DIR");
            if (rt && rt !== "")
                return rt + "/mus-quran";
            return Quickshell.env("HOME") + "/.cache/omarchy/quran/run";
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
    property var downloadFailedSurahs: [] // surah numbers that failed during the active run
    property var lastDownload: null       // { id, surah } for retry after failure
    // The audio engine is the Go quranproxyd daemon + quranctl CLI. Their paths
    // are resolved once at startup (onToolProbe): a committed prebuilt binary in
    // the plugin folder wins, then the user-installed ~/.local/bin copy. When
    // neither exists, setupRequired turns on and the engine actions fail with a
    // "run install.sh" hint instead of silently breaking.
    property string quranctlBinary: ""
    property bool setupRequired: false
    readonly property string cacheDir: Quickshell.env("HOME") + "/.cache/omarchy/quran"

    // --- local range-caching proxy (quranproxyd) ---
    // The daemon serves non-downloaded surahs at
    // http://127.0.0.1:<proxyPort>/stream?tok=..&reciter=..&surah=.., validates
    // and promotes fully-fetched files into dataDir, and reports progress as
    // `promoted <id> <n>` on stdout. proxyReady turns on only after a valid
    // handoff file (port + 32-hex token) has been read.
    property string proxyBinary: ""
    readonly property string proxyHandoffPath: root.mpvRuntimeDir + "/quranproxy.json"
    property string proxySocketPath: root.mpvRuntimeDir + "/quranproxy.sock"
    property int proxyPort: 0
    property string proxyToken: ""
    property bool proxyReady: false
    property int proxySizeBytes: 0      // proxy-owned cache bytes (combined readout)
    property int proxyFilesCount: 0     // proxy-owned cache files (cacheInfo)
    property int proxyRestartCount: 0
    property bool proxyManualRestart: false  // deliberate stop for a config change

    // --- proxy control plane (unix socket) ---
    // The daemon also listens on a unix socket in mpvRuntimeDir (announced as
    // "sock" in the handoff) and serves raw HTTP over it — the plugin reads
    // /cache/usage and POSTs /api/cache/clear through a QLocalSocket, the same
    // primitive mpv uses. No curl, no extra processes.

    property int cacheLimitMb: 500       // eviction budget (persisted; read by the daemon)

    // Per-reciter:surah fetch cooldown. After a failed fetch or a forced
    // playback error, re-fetches are refused for Model.COOLDOWN_MS so repeated
    // IPC/retries cannot become a download storm.
    property var fetchCooldowns: ({})    // "reciter:n" -> epoch ms when the window ends
    property var pendingPlayback: null   // { id, n, autoplay, positionMs } play after download completes
    property var mushafPending: null     // reciter id whose mushaf download was preempted by playback
    // Persisted across shell restarts: { id, surah, list, pb? } describing the
    // download that was in flight when the shell died, so the next instance
    // resumes it (quranctl re-validates/skips finished files and resumes
    // interrupted transfers). pb = playback request persisted while preempting a
    // mushaf. Cleared on completion; one-shot resumed on startup.
    property var downloadIntent: null
    property bool downloadResumeTried: false
    property string mpvMprisScript: ""  // resolved mpv-mpris plugin path ("" = not found)

    function _inCooldown(id, n) {
        return Model.cooldownActive(root.fetchCooldowns, id + ":" + n, Date.now());
    }

    function _markFetchAttempt(id, n) {
        Model.markCooldown(root.fetchCooldowns, id + ":" + n, Date.now());
    }

    function _clearCooldown(id, n) {
        Model.clearCooldown(root.fetchCooldowns, id + ":" + n);
    }

    // Cap any string arriving over IPC before it is parsed or stored, so a
    // hostile caller can't force unbounded memory/state growth.
    function _capString(s, max) {
        s = String(s || "");
        return s.length > max ? s.substring(0, max) : s;
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
            root.downloadSurah(id, n);
        }

        function downloadMushaf(id) {
            root.downloadMushaf(id);
        }

        readonly property int downloadDone: root.downloadDone
        readonly property int downloadTotal: root.downloadTotal
        readonly property bool downloading: root.downloading
    }

    function currentSurahFor(n) {
        if (!surahs || n < 1 || n > surahs.length)
            return null;
        return surahs[n - 1];
    }

    function reciterFor(id) {
        if (!reciters)
            return null;
        for (var i = 0; i < reciters.length; i++) {
            if (reciters[i].identifier === id)
                return reciters[i];
        }
        return null;
    }

    function surahLabel(n) {
        return Model.surahDisplayLabel(currentSurahFor(n), root.language);
    }

    function reciterLabel() {
        return Model.reciterDisplayLabel(currentReciter, root.language);
    }

    function downloadedCount(id) {
        return root.downloadedCounts[id] || 0;
    }

    function rebuildDownloadedCounts() {
        var counts = {};
        for (var key in root.downloadedSurahs) {
            if (root.downloadedSurahs[key] !== true)
                continue;
            var sep = key.lastIndexOf(":");
            if (sep <= 0)
                continue;
            var id = key.substring(0, sep);
            counts[id] = (counts[id] || 0) + 1;
        }
        root.downloadedCounts = counts;
    }

    // Completion is derived from the per-surah map. reciterStatus is persisted
    // history and may be stale if a file is removed or a prior batch was partial.
    function isMushafDownloaded(id) {
        return root.downloadedCount(id) === 114;
    }

    // Compatibility alias for callers that used the old coarse API.
    function isDownloaded(id) {
        return root.isMushafDownloaded(id);
    }

    function isSurahDownloaded(id, n) {
        return root.downloadedSurahs[id + ":" + n] === true;
    }

    function markSurahDownloaded(id, n) {
        var key = id + ":" + n;
        var next = Object.assign({}, root.downloadedSurahs);
        var wasDownloaded = next[key] === true;
        next[key] = true;
        root.downloadedSurahs = next;
        if (!wasDownloaded) {
            var counts = Object.assign({}, root.downloadedCounts);
            counts[id] = (counts[id] || 0) + 1;
            root.downloadedCounts = counts;
        }
        root.downloadRevision++;
        root.saveState();
    }

    function invalidateSurahDownload(id, n) {
        var key = id + ":" + n;
        if (root.downloadedSurahs[key] !== true)
            return;
        var next = Object.assign({}, root.downloadedSurahs);
        delete next[key];
        root.downloadedSurahs = next;
        var counts = Object.assign({}, root.downloadedCounts);
        counts[id] = Math.max(0, (counts[id] || 0) - 1);
        root.downloadedCounts = counts;
        root.downloadRevision++;
        root.saveState();
    }

    // true while a download is actively fetching this exact surah
    function isSurahDownloading(id, n) {
        return root.downloading && downloadProc.targetSurah === n && downloadProc.targetReciter === id;
    }

    // true while a download is actively fetching this reciter's mushaf
    function isReciterDownloading(id) {
        return root.downloading && downloadProc.targetSurah === 0 && downloadProc.targetReciter === id;
    }

    // First time a reciter is touched (no status recorded yet), the widget
    // should prompt the user about downloading the full mushaf. Also re-prompt
    // partially-downloaded reciters (even if previously declined) so the
    // remaining surahs can be fetched in one click. A decline with zero
    // downloads is respected.
    function shouldPrompt(id) {
        return !root.isMushafDownloaded(id) && root.reciterStatus[id] === undefined;
    }

    function hasAnyDownloaded(id) {
        for (var i = 1; i <= 114; i++) {
            if (root.downloadedSurahs[id + ":" + i])
                return true;
        }
        return false;
    }

    // Count of this reciter's surahs not yet available offline.
    function missingCount(id) {
        var count = 0;
        for (var i = 1; i <= 114; i++) {
            if (!root.isSurahDownloaded(id, i))
                count++;
        }
        return count;
    }

    function setReciterStatus(id, status) {
        root.reciterStatus[id] = status;
        root.saveState();
    }

    // --- mpv IPC --------------------------------------------------------------

    // Send one JSON command to mpv. Dropped silently if not connected (the
    // connect/recover machinery will re-issue playback state on connect).
    function _mpvCommand(cmd) {
        if (!root.mpvSock || !root.mpvSock.connected)
            return;
        root.mpvRequestId++;
        root.mpvSock.write(JSON.stringify({
            command: cmd,
            request_id: root.mpvRequestId
        }) + "\n");
        root.mpvSock.flush();
    }

    function _observeMpv() {
        root._mpvCommand(["observe_property", 1, "pause"]);
        root._mpvCommand(["observe_property", 2, "time-pos"]);
        root._mpvCommand(["observe_property", 3, "duration"]);
        root._mpvCommand(["observe_property", 4, "eof-reached"]);
        root._mpvCommand(["observe_property", 5, "seekable"]);
    }

    function onMpvLine(line) {
        var obj = null;
        try {
            obj = JSON.parse(line);
        } catch (e) {
            obj = null;
        }
        if (!obj)
            return;
        if (obj.event === "property-change")
            root.onMpvProperty(obj.name, obj.data);
        else if (obj.event === "start-file")
            root.onMpvStartFile();
        else if (obj.event === "file-loaded")
            root.onMpvFileLoaded();
        else if (obj.event === "end-file")
            root.onMpvEndFile(obj.reason);
    }

    function onMpvProperty(name, data) {
        var v = (data === undefined) ? null : data;
        if (name === "pause") {
            root.mpvPaused = (v === true);
        } else if (name === "time-pos") {
            if (typeof v === "number" && isFinite(v)) {
                root.mpvPositionMs = Math.round(v * 1000);
                // Persist only while media is loaded and not at EOF — never from the
                // idle/teardown nulls mpv sends after the file ends.
                if (root.hasMedia && !root.mpvEof)
                    root.savedPosition = root.mpvPositionMs;
            }
        } else if (name === "duration") {
            if (typeof v === "number" && isFinite(v) && v > 0)
                root.mpvDurationMs = Math.round(v * 1000);
        } else if (name === "eof-reached") {
            if (v === true)
                root.mpvEof = true;
            else if (v === false)
                root.mpvEof = false;
        } else if (name === "seekable") {
            root.mpvSeekable = (v === true);
        }
    }

    function onMpvStartFile() {
        root.mpvEof = false;
        root.endHandled = false;
        root.errorMessage = "";
    }

    function onMpvFileLoaded() {
        var t = root.resumeLoadTarget;
        if (t && t.positionMs > 0) {
            root.resumeLoadTarget = null;
            root._mpvCommand(["set_property", "time-pos", t.positionMs / 1000]);
        }
    }

    function onMpvEndFile(reason) {
        if (reason === "eof") {
            root.mpvEof = true;
            root._handleEndOfMedia();
        } else if (reason === "error") {
            // A failed load (404 / dead link) must not read as "playing": pin pause
            // so isPlaying goes false and the play button stops showing pause.
            root.mpvPaused = true;
            if (root.playbackSourceKind === "download" && root.playbackSourceTarget) {
                root.invalidateSurahDownload(root.playbackSourceTarget.id, root.playbackSourceTarget.n);
            } else if (root.playbackSourceKind === "stream" && root.playbackSourceTarget) {
                // A proxy stream failed (origin/CDN problem, oversized file, dead
                // link). The proxy arms its own 10 s cooldown (425) server-side;
                // mirror it here so an aggressive retry loop cannot re-enter playback
                // during the window.
                root._markFetchAttempt(root.playbackSourceTarget.id, root.playbackSourceTarget.n);
            }
            root.errorMessage = Model.tr(root.language, "playbackFailed");
        }
        // "stop" / "quit" / "redirect" / "unknown" (e.g. switching surahs) ignored.
    }

    // --- playback control -----------------------------------------------------

    function playSurah(reciterId_, surahNumber_) {
        if (!Model.isValidSurahNumber(surahNumber_)) {
            root.errorMessage = Model.tr(root.language, "invalidInput");
            return;
        }
        root.reciterId = reciterId_ || root.reciterId;
        root.surahNumber = surahNumber_;
        root.resumePosition = 0;
        root.savedPosition = 0;
        root.errorMessage = "";
        pendingTarget = {
            id: root.reciterId,
            n: root.surahNumber
        };
        surahDebounce.restart();
    }

    function localAudioPath(id, n) {
        return root.dataDir + "/" + id + "/" + n + ".mp3";
    }

    // Playback source resolution (download-only backend). A surah that is not
    // yet downloaded is streamed through the proxy (validating and promoting
    // into the state dir) or fetched into the permanent state dir first, then
    // played. mpv only ever receives local files or the proxy stream URL.
    function _playSurahOrDownload(id, n, autoplay, positionMs) {
        var shouldPlay = autoplay !== false;
        var resumeMs = positionMs || 0;
        if (root.isSurahDownloaded(id, n)) {
            root.requestLocalValidation(id, n, shouldPlay, resumeMs);
            return;
        }
        // A surah present in the configured local library plays straight from
        // disk (the scan already vetted the path shape); never copied or
        // re-fetched.
        if (root.libraryHas(id, n)) {
            root._playLibraryFile(id, n, shouldPlay, resumeMs);
            return;
        }
        // Stream through the local range-caching proxy; it validates and promotes
        // the surah to a permanent download on completion (no full-file download
        // needed before playback starts).
        if (root.proxyReady && root.proxyPort > 0) {
            root._playStream(id, n, shouldPlay, resumeMs);
            return;
        }
        // Everything else downloads to permanent storage, then plays. Playing a
        // surah never waits on a full-mushaf download: the mushaf is preempted
        // and resumes after the requested surah has played (see downloadProc).
        if (root._inCooldown(id, n)) {
            root.errorMessage = Model.tr(root.language, "playbackFailed");
            return;
        }
        root.pendingPlayback = {
            id: id,
            n: n,
            autoplay: shouldPlay,
            positionMs: resumeMs
        };
        if (root.downloading) {
            // A mushaf download (running, or still promoting cached files) is
            // preempted for playback; other single-surah downloads just queue
            // behind themselves.
            if (downloadProc.targetSurah === 0) {
                root.mushafPending = downloadProc.targetReciter;
                // Persist the playback request with the intent so a shell restart
                // mid-preempt resumes this surah's download (then the mushaf).
                if (root.downloadIntent) {
                    var intent = Object.assign({}, root.downloadIntent);
                    intent.pb = {
                        id: id,
                        n: n,
                        autoplay: shouldPlay,
                        positionMs: resumeMs
                    };
                    root.downloadIntent = intent;
                    root.saveState();
                }
                if (downloadProc.running)
                    downloadProc.running = false;
            }
            return;
        }
        root._markFetchAttempt(id, n);
        root.startExplicitDownload(id, n);
    }

    // Play directly from the configured local library. The path shape was
    // vetted by the scan (validated identifier + canonical surah number under
    // the configured root), so this is as safe as any downloaded file.
    function _playLibraryFile(id, n, autoplay, positionMs) {
        var path = root.libraryAudioPath(id, n);
        if (!Model.isSafeReciterArg(id) || !Model.isValidSurahNumber(n) || !root.libraryHas(id, n)) {
            root.errorMessage = Model.tr(root.language, "playbackFailed");
            return;
        }
        root.reciterId = id;
        root.surahNumber = n;
        root.playbackSourceKind = "library";
        root.playbackSourceTarget = {
            id: id,
            n: n
        };
        root._setMprisMetadata(id, n);
        root.resumePending = false;
        root._mpvLoad("file://" + path, autoplay, positionMs);
        root.saveState();
    }

    function _playNow(id, n) {
        if (root.reciters.length > 0 && !Model.reciterExists(root.reciters, id)) {
            root.errorMessage = Model.tr(root.language, "invalidInput");
            return;
        }
        root._playSurahOrDownload(id, n, true, 0);
    }

    // Play a non-downloaded surah through the local proxy. The source URL is
    // built only from already-validated inputs (see _proxyStreamUrl); mpv then
    // streams it while the proxy fills its cache and, on completion, promotes
    // the file to a permanent download (onProxyLine -> markSurahDownloaded).
    function _playStream(id, n, autoplay, positionMs) {
        var url = root._proxyStreamUrl(id, n);
        if (url === "") {
            root.errorMessage = Model.tr(root.language, "playbackFailed");
            return;
        }
        root.reciterId = id;
        root.surahNumber = n;
        root.playbackSourceKind = "stream";
        root.playbackSourceTarget = {
            id: id,
            n: n
        };
        root._setMprisMetadata(id, n);
        root.resumePending = false;
        root._mpvLoad(url, autoplay, positionMs);
        root.saveState();
    }

    function requestLocalValidation(id, n, autoplay, positionMs) {
        if (!root.quranctlBinary) {
            root.errorMessage = Model.tr(root.language, "setupRequired");
            return;
        }
        var target = {
            id: id,
            n: n,
            autoplay: autoplay !== false,
            positionMs: positionMs || 0
        };
        if (localValidationProc.running) {
            localValidationPlaybackTarget = target;
            return;
        }
        localValidationProc.mode = "playback";
        localValidationProc.target = target;
        // Deep media validation (size, MIME type, ffprobe) of the first root
        // that actually holds the file — see _audioResolveCommand. Exit 0 =
        // valid (resolvedPath holds the file), 1 = missing everywhere,
        // 3 = found but unusable media.
        localValidationProc.command = root._audioResolveCommand(id, n, true);
        localValidationProc.running = true;
    }

    function queueDownloadedFileValidation() {
        var queue = [];
        for (var key in root.downloadedSurahs) {
            if (root.downloadedSurahs[key] !== true)
                continue;
            var sep = key.lastIndexOf(":");
            if (sep <= 0)
                continue;
            queue.push({
                id: key.substring(0, sep),
                n: parseInt(key.substring(sep + 1))
            });
        }
        localValidationQueue = queue;
        pumpLocalValidation();
    }

    function pumpLocalValidation() {
        if (localValidationProc.running)
            return;
        var target = null;
        var mode = "";
        if (localValidationPlaybackTarget) {
            target = localValidationPlaybackTarget;
            localValidationPlaybackTarget = null;
            mode = "playback";
        } else if (localValidationQueue.length > 0) {
            target = localValidationQueue.shift();
            mode = "startup";
        } else {
            return;
        }
        localValidationProc.mode = mode;
        localValidationProc.target = target;
        // Shallow existence probe across the current + legacy roots so a
        // folder move doesn't invalidate flags for files left behind.
        localValidationProc.command = root._audioResolveCommand(target.id, target.n, false);
        localValidationProc.running = true;
    }

    function onLocalValidationExited(exitCode) {
        var target = localValidationProc.target;
        var mode = localValidationProc.mode;
        var resolved = localValidationProc.resolvedPath;
        localValidationProc.target = null;
        localValidationProc.mode = "";
        localValidationProc.resolvedPath = "";
        if (target && exitCode !== 0) {
            root.invalidateSurahDownload(target.id, target.n);
            if (mode === "playback") {
                // Corrupt downloaded file: delete it from disk (fail-closed whitelist
                // inside quranctl) and refuse re-fetches for the cooldown window so a
                // bad CDN file can't trigger a re-download loop. A retry after the
                // window re-fetches clean. The remove targets the root the bad file
                // was actually found in.
                localRemoveProc.command = [root.quranctlBinary, "remove", "--state-dir", root.audioRootOf(resolved, target.id, target.n), target.id, String(target.n)];
                localRemoveProc.running = true;
                root._markFetchAttempt(target.id, target.n);
                root.errorMessage = Model.tr(root.language, "playbackFailed");
            }
        } else if (target && mode === "playback") {
            root.playbackSourceKind = "download";
            root.playbackSourceTarget = target;
            root.reciterId = target.id;
            root.surahNumber = target.n;
            // resolved is the exact validated path from the resolver command.
            root._mpvLoad("file://" + resolved, target.autoplay, target.positionMs);
            root._setMprisMetadata(target.id, target.n);
            root.resumePending = false;
            root.saveState();
        }
        pumpLocalValidation();
    }

    // --- multi-root audio path resolution --------------------------------------

    // Single-quote a string for safe interpolation into a `bash -c` script.
    // Candidates are validated paths (no control chars, no ".."), but may
    // contain spaces or quotes of their own.
    function _shellQuote(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'";
    }

    // All roots that may hold downloaded files: the active download dir first,
    // then legacy roots (most recent first).
    function _audioRoots() {
        var roots = [root.dataDir];
        var legacy = Array.isArray(root.legacyRoots) ? root.legacyRoots : [];
        for (var i = legacy.length - 1; i >= 0; i--) {
            if (legacy[i] && roots.indexOf(legacy[i]) === -1)
                roots.push(legacy[i]);
        }
        return roots;
    }

    // Command that finds the first root holding <id>/<n>.mp3 and, in deep
    // mode, media-validates it with quranctl before reporting success.
    // Exit codes: 0 = found (stdout carries the absolute path), 1 = missing,
    // 3 = present but invalid media (deep mode only).
    function _audioResolveCommand(id, n, deep) {
        if (!Model.isSafeReciterArg(id) || !Model.isValidSurahNumber(n))
            return ["false"];
        var suffix = "/" + id + "/" + n + ".mp3";
        var quoted = [];
        var roots = root._audioRoots();
        for (var i = 0; i < roots.length; i++)
            quoted.push(root._shellQuote(roots[i] + suffix));
        var script = 'found=""; for p in ' + quoted.join(" ") + '; do if [ -s "$p" ]; then found="$p"; break; fi; done; [ -n "$found" ] || exit 1;';
        if (!deep)
            return ["bash", "-c", script + ' printf %s "$found"'];
        if (!root.quranctlBinary)
            return ["false"];
        return ["bash", "-c", script + " " + root._shellQuote(root.quranctlBinary) + " validate \"$found\" || exit 3; printf %s \"$found\""];
    }

    // Root directory of a resolved audio path (inverse of the candidate
    // construction above); falls back to the active dataDir when the shape
    // doesn't match.
    function audioRootOf(resolved, id, n) {
        var suffix = "/" + id + "/" + n + ".mp3";
        if (typeof resolved === "string" && resolved.length > suffix.length && resolved.substring(resolved.length - suffix.length) === suffix)
            return resolved.substring(0, resolved.length - suffix.length);
        return root.dataDir;
    }

    // Set mpv's force-media-title and artist so mpv-mpris surfaces surah/reciter
    // names instead of the raw CDN URL in playerctl metadata.
    function _setMprisMetadata(id, n) {
        var surah = root.currentSurahFor(n);
        var reciter = root.reciterFor(id);
        var title = surah ? Model.surahDisplayLabel(surah, root.language) : ("Surah " + n);
        var artist = reciter ? Model.reciterDisplayLabel(reciter, root.language) : id;
        root._mpvCommand(["set_property", "force-media-title", title]);
        root._mpvCommand(["set_property", "audio-display-metadata/by-key/artist", artist]);
    }

    // Load a source into mpv. `loadfile` replaces whatever is playing, then the
    // pause property pins the desired start state; resume positions are applied
    // on `file-loaded` (mpv can't set time-pos before the file exists).
    // SECURITY: mpv only ever receives local files OR this plugin's own
    // loopback proxy stream URL (http://127.0.0.1:<proxyPort>/stream?... — the
    // exact prefix + query we built in _proxyStreamUrl). Anything else — a
    // hostile catalog URL, a tampered state file, a stray IPC call — is refused
    // here; currentSource/lastSource are therefore always local or proxy, and
    // every replay path (playPause, seek, crash recovery) inherits this guard.
    function _mpvLoad(source, autoplay, positionMs) {
        var isLocal = (typeof source === "string" && source.indexOf("file://") === 0);
        var isProxyStream = (typeof source === "string" && root.proxyReady && root.proxyPort > 0 && source.indexOf("http://127.0.0.1:" + root.proxyPort + "/stream?") === 0);
        if (!isLocal && !isProxyStream) {
            root.errorMessage = Model.tr(root.language, "playbackFailed");
            return;
        }
        root.currentSource = source;
        root.lastSource = source;
        root.mpvEof = false;
        root.endHandled = false;
        root.errorMessage = "";
        root.mpvPaused = !autoplay;
        root.resumeLoadTarget = (positionMs > 0) ? {
            positionMs: positionMs
        } : null;
        root._mpvCommand(["loadfile", source]);
        root._mpvCommand(["set_property", "pause", !autoplay]);
    }

    function playPause() {
        if (!root.hasMedia) {
            if (root.resumePending && root.resumePosition > 0) {
                root._playNow(root.reciterId, root.surahNumber);
            } else {
                root.playSurah(root.reciterId, root.surahNumber);
            }
            return;
        }
        // A finished surah sits idle in mpv; toggling pause does nothing, so play
        // replays it from the start like the old backend did.
        if (root.mpvEof) {
            root._mpvLoad(root.currentSource, true, 0);
            root.saveState();
            return;
        }
        if (root.isPlaying)
            root._mpvCommand(["set_property", "pause", true]);
        else
            root._mpvCommand(["set_property", "pause", false]);
        root.saveState();
    }

    function stopPlayback() {
        root._mpvCommand(["stop"]);
        root.currentSource = "";
        root.lastSource = "";
        root.mpvEof = false;
        root.mpvPaused = true;
        root.mpvPositionMs = 0;
        root.mpvDurationMs = 0;
        root.endHandled = true;
        root.resumePosition = 0;
        root.savedPosition = 0;
        // An in-flight download keeps running (the file stays useful), but it
        // must not start playing on completion.
        root.pendingPlayback = null;
        root.saveState();
    }

    function next() {
        if (root.surahNumber < surahs.length)
            root._playNow(root.reciterId, root.surahNumber + 1);
    }

    function previous() {
        if (root.surahNumber > 1)
            root._playNow(root.reciterId, root.surahNumber - 1);
    }

    function seek(ms) {
        if (!root.hasMedia) {
            root.savedPosition = Math.max(0, Math.round(ms));
            root.saveState();
            return;
        }
        var target = Math.max(0, Math.round(ms));
        if (root.mpvEof) {
            root._mpvLoad(root.currentSource, false, target);
            root.saveState();
            return;
        }
        root._mpvCommand(["set_property", "time-pos", target / 1000]);
        root.savedPosition = target;
        root.saveState();
    }

    function cycleMode() {
        var i = Model.MODES.indexOf(root.playbackMode);
        root.playbackMode = Model.MODES[(i + 1) % Model.MODES.length];
        root.saveState();
    }

    function setLanguage(code) {
        root.language = Model.isValidLanguage(code) ? code : Model.DEFAULT_LANGUAGE;
        root.saveState();
    }

    function selectReciter(id) {
        root.reciterId = id;
        root.saveState();
    }

    // --- end of media (repeat-mode logic hooks here) ---

    function _handleEndOfMedia() {
        if (root.endHandled)
            return;
        root.endHandled = true;
        root.resumePosition = 0;
        root.savedPosition = 0;
        root.saveState();
        root._onEndOfMedia();
    }

    function _onEndOfMedia() {
        var n = root.surahNumber;
        var id = root.reciterId;
        switch (root.playbackMode) {
        case Model.MODE_REPEAT_ONE:
            root._playNow(id, n);
            break;
        case Model.MODE_CONTINUE:
            if (n < surahs.length)
                root._playNow(id, n + 1);
            break;
        case Model.MODE_REPEAT_ALL:
            root._playNow(id, (n % surahs.length) + 1);
            break;
        case Model.MODE_SINGLE:
        default:
            break;
        }
    }

    // --- resume-on-startup (load paused at the saved position) ---

    function _maybeResume() {
        if (!root.stateLoaded || !root.mpvReady)
            return;
        if (root.lastSource !== "")
            return;
        if (!root.resumePending || root.resumePosition <= 0)
            return;
        root.resumePending = false;
        root._playSurahOrDownload(root.reciterId, root.surahNumber, false, root.resumePosition);
    }

    // --- mpv lifecycle --------------------------------------------------------

    // (Re)create the socket. Each attempt uses a fresh Socket so a failed
    // connect is always retryable (QLocalSocket can't be re-targeted in place).
    // The unix connect can complete synchronously, firing onConnectionStateChanged
    // DURING createObject — before the assignment below runs. So connect is
    // triggered manually AFTER root.mpvSock is set, or onMpvConnected would see
    // a null socket and never issue the observe_property commands.
    function _mpvConnect() {
        if (root.shuttingDown || !mpvProc.running)
            return;
        if (root.mpvSock) {
            root.mpvSock.connected = false;
            root.mpvSock.destroy();
            root.mpvSock = null;
        }
        root.mpvSock = mpvSocketComponent.createObject(root);
        root.mpvSock.connected = true;
    }

    function _mpvRetryConnect() {
        if (root.shuttingDown || !mpvProc.running)
            return;
        root.mpvConnectAttempts++;
        if (root.mpvConnectAttempts > 30)
            return;
        root._mpvConnect();
    }

    function onMpvConnected() {
        if (root.shuttingDown)
            return;
        root.mpvConnectAttempts = 0;
        root.mpvRestartCount = 0;
        root.mpvReady = true;
        root._observeMpv();
        root._mpvRecoverLast();
        root._maybeResume();
    }

    // After mpv restarts, re-issue the last known playback state so a crash is
    // transparent apart from a brief playback gap. Routed through _mpvLoad so
    // the file://-only guard applies here too.
    function _mpvRecoverLast() {
        if (root.lastSource === "")
            return;
        var shouldPlay = root.isPlaying;
        var pos = root.mpvPositionMs > 0 ? root.mpvPositionMs : root.savedPosition;
        root._mpvLoad(root.lastSource, shouldPlay, pos);
    }

    function onMpvExited(exitCode) {
        root.mpvReady = false;
        mpvConnectTimer.stop();
        if (root.mpvSock) {
            root.mpvSock.connected = false;
            root.mpvSock.destroy();
            root.mpvSock = null;
        }
        if (root.shuttingDown)
            return;
        if (root.mpvRestartCount < 5) {
            root.mpvRestartCount++;
            mpvRestartTimer.restart();
        } else {
            root.errorMessage = Model.tr(root.language, "mpvMissing");
        }
    }

    // --- downloads (explicit, state dir) ---------------------------------------

    function downloadSurah(id, n) {
        if (root.downloading || !Model.isValidSurahNumber(n))
            return;
        // Cooldown gate: a still-flagged corrupt file can be re-downloaded, but
        // not more than once per reciter:surah inside the cooldown window — even
        // via repeated IPC/retry calls.
        if (root._inCooldown(id, n))
            return;
        root._markFetchAttempt(id, n);
        root.startExplicitDownload(id, n);
    }

    function startExplicitDownload(id, n) {
        if (!root.quranctlBinary) {
            root.errorMessage = Model.tr(root.language, "setupRequired");
            return;
        }
        root.downloading = true;
        root.downloadReciter = id;
        root.lastDownload = {
            id: id,
            surah: n
        };
        root.downloadDone = 0;
        root.downloadTotal = 1;
        root.errorMessage = "";
        root.downloadFailedSurahs = [];
        downloadProc.targetReciter = id;
        downloadProc.targetSurah = n;
        // Persist the active download so a shell restart resumes it.
        root.downloadIntent = {
            id: id,
            surah: n,
            list: [n]
        };
        root.saveState();
        var reciter = root.reciterFor(id);
        // quranctl shares the daemon's validation/fetch policy (same internal
        // packages); it validates the origin URL in-process and reports the
        // quranctl progress lines (download.sh-compatible) on stdout.
        var cmd = [root.quranctlBinary, "download", id, String(n)];
        if (reciter && reciter.server) {
            cmd.push("--server");
            cmd.push(reciter.server);
        }
        if (root.dataDir !== root.defaultDataDir) {
            cmd.push("--dest-root");
            cmd.push(root.dataDir);
        }
        downloadProc.command = cmd;
        downloadProc.running = true;
    }

    function downloadMushaf(id) {
        if (root.downloading)
            return;

        // Only fetch surahs not already present offline. If your download flow
        // still wants quranctl to re-validate/repair files that exist but are
        // corrupt, this needs a different check than isSurahDownloaded() — see
        // note below.
        var work = [];
        for (var i = 1; i <= 114; i++) {
            if (!root.isSurahDownloaded(id, i))
                work.push(i);
        }

        if (work.length === 0) {
            // Already fully downloaded — nothing to do.
            return;
        }

        root.downloading = true;
        root.downloadReciter = id;
        root.lastDownload = {
            id: id,
            surah: 0
        };

        downloadProc.targetReciter = id;
        downloadProc.targetSurah = 0;

        // Progress now reflects only the surahs actually being fetched.
        root.downloadDone = 0;
        root.downloadTotal = work.length;
        root.errorMessage = "";
        root.downloadFailedSurahs = [];
        root.startMushafDownload(id, work);
    }
    // function downloadMushaf(id) {
    //     if (root.downloading)
    //         return;
    //     // Always validate the complete reciter set. The persisted downloaded flag
    //     // is only a cache of prior work and cannot prove that files still exist or
    //     // are intact. quranctl's complete() check skips valid files and fetches
    //     // only missing/corrupt ones.
    //     var work = [];
    //     for (var i = 1; i <= 114; i++)
    //         work.push(i);
    //     root.downloading = true;
    //     root.downloadReciter = id;
    //     root.lastDownload = {
    //         id: id,
    //         surah: 0
    //     };
    //     // Mark the in-flight target up front so playback can preempt this mushaf
    //     // before the process has actually started.
    //     downloadProc.targetReciter = id;
    //     downloadProc.targetSurah = 0;
    //     // Progress reflects validation/download of all 114 surahs.
    //     root.downloadDone = 0;
    //     root.downloadTotal = 114;
    //     root.errorMessage = "";
    //     root.startMushafDownload(id, work);
    // }

    function startMushafDownload(id, list) {
        if (!root.quranctlBinary) {
            root.errorMessage = Model.tr(root.language, "setupRequired");
            return;
        }
        // Playback preempted this mushaf while its cached files were being
        // promoted (the process never started): don't launch it now — serve the
        // pending playback download first; downloadProc.onExited resumes the
        // mushaf once nothing else is queued.
        if (root.mushafPending === id) {
            var pb = root.pendingPlayback;
            if (pb) {
                root._markFetchAttempt(pb.id, pb.n);
                root.startExplicitDownload(pb.id, pb.n);
            }
            return;
        }
        // Announce the download up front (also on the resume path after playback
        // preempted the mushaf): the widget progress and the downloading guard
        // depend on this flag being true for the whole run.
        root.downloading = true;
        root.downloadReciter = id;
        root.lastDownload = {
            id: id,
            surah: 0
        };
        root.downloadFailedSurahs = [];
        downloadProc.targetReciter = id;
        downloadProc.targetSurah = 0;
        // Persist the active mushaf download (with the exact remaining list) so a
        // shell restart resumes it where it was interrupted.
        root.downloadIntent = {
            id: id,
            surah: 0,
            list: list
        };
        root.saveState();
        var reciter = root.reciterFor(id);
        var cmd = [root.quranctlBinary, "download", id, "--only", list.join(",")];
        if (reciter && reciter.server) {
            cmd.push("--server");
            cmd.push(reciter.server);
        }
        if (root.dataDir !== root.defaultDataDir) {
            cmd.push("--dest-root");
            cmd.push(root.dataDir);
        }
        downloadProc.command = cmd;
        downloadProc.running = true;
    }

    function finishMushafDownload(id) {
        root.downloading = false;
        root.downloadReciter = "";
        root.downloadDone = 114;
        root.downloadTotal = 114;
        downloadProc.targetReciter = null;
        downloadProc.targetSurah = 0;
        root.downloadIntent = null;
        root.setReciterStatus(id, "downloaded");
        var next = Object.assign({}, root.downloadedSurahs);
        for (var i = 1; i <= 114; i++)
            next[id + ":" + i] = true;
        root.downloadedSurahs = next;
        var counts = Object.assign({}, root.downloadedCounts);
        counts[id] = 114;
        root.downloadedCounts = counts;
        root.downloadRevision++;
        root.saveState();
    }

    function retryDownload() {
        if (!root.lastDownload || root.downloading)
            return;
        root.errorMessage = "";
        if (root.lastDownload.surah > 0)
            root.downloadSurah(root.lastDownload.id, root.lastDownload.surah);
        else
            root.downloadMushaf(root.lastDownload.id);
    }

    function applyDownloadProgress(line) {
        var bytes = String(line).match(/^progress_bytes\s+(\d+)\/(\d+)\s*$/);
        if (bytes && downloadProc.targetSurah > 0) {
            root.downloadDone = Math.min(100, parseInt(bytes[1]));
            root.downloadTotal = 100;
            return;
        }
        // Per-surah completion from the running quranctl: mark immediately so
        // the surah list flips icons live instead of only at process exit.
        // (Idempotent — onExited re-marks the single-surah case.)
        var done = String(line).match(/^surah_done\s+(\d+)\s*$/);
        if (done) {
            var dsn = parseInt(done[1], 10);
            if (downloadProc.targetReciter && Model.isValidSurahNumber(dsn))
                root.markSurahDownloaded(downloadProc.targetReciter, dsn);
            return;
        }
        var failed = String(line).match(/^surah_failed\s+(\d+)\s*$/);
        if (failed) {
            var fsn = parseInt(failed[1], 10);
            if (Model.isValidSurahNumber(fsn) && root.downloadFailedSurahs.indexOf(fsn) === -1)
                root.downloadFailedSurahs = root.downloadFailedSurahs.concat([fsn]);
            return;
        }
        var m = String(line).match(/^progress\s+(\d+)\/(\d+)\s*$/);
        if (!m)
            return;
        if (downloadProc.targetSurah === 0) {
            // The tally reflects what this run was launched with (only the
            // missing surahs) — never re-inflated to 114 mid-run.
            var total = parseInt(m[2], 10);
            if (total >= 1 && total <= 114) {
                root.downloadTotal = total;
                root.downloadDone = Math.min(total, parseInt(m[1]));
            }
        } else {
            root.downloadDone = parseInt(m[1]);
            root.downloadTotal = parseInt(m[2]);
        }
    }

    // --- proxy cache readout / clear ------------------------------------------

    // Best-effort refresh of the proxy-owned cache bytes for the "Cache:"
    // readout. On any failure (daemon down, socket busy) keep the last value.
    function refreshCacheSize() {
        if (!root.proxyReady || root.proxyPort === 0)
            return;
        root._proxyHttp("GET", "/cache/usage", function (data) {
            if (data && typeof data.bytes === "number" && isFinite(data.bytes)) {
                root.proxySizeBytes = Math.max(0, Math.round(data.bytes));
            }
            if (data && typeof data.files === "number" && isFinite(data.files)) {
                root.proxyFilesCount = Math.max(0, Math.round(data.files));
            }
        });
    }

    // Wipe the proxy-owned cache (token-authenticated POST on the control
    // socket). The files are .dat/.meta.json only — the legacy *.mp3 leftovers
    // in the cache dir are the user's to clean up manually.
    function clearCache() {
        if (!root.proxyReady || root.proxyPort === 0) {
            root.errorMessage = Model.tr(root.language, "cacheClearFailed");
            return;
        }
        root._proxyHttp("POST", "/api/cache/clear?tok=" + root.proxyToken, function (data) {
            if (data && data.cleared)
                root.refreshCacheSize();
        });
    }

    // --- storage roots ---------------------------------------------------------

    // Change the download folder. Files are never moved: the previous root is
    // remembered in legacyRoots so its downloads stay playable, new downloads
    // land in the new root, and the proxy daemon restarts so promotions follow.
    // Returns null on success or a user-facing error string.
    function setDownloadDir(raw) {
        var clean = Model.sanitizeDirPath(raw, Quickshell.env("HOME"));
        var hadInput = String(raw === undefined || raw === null ? "" : raw).trim() !== "";
        if (hadInput && clean === "")
            return root.trStr("invalidPath");
        if (clean === root.downloadDir)
            return null;
        var previous = root.dataDir;
        root.downloadDir = clean;
        if (previous !== root.dataDir)
            root.legacyRoots = Model.pushLegacyRoot(root.legacyRoots, previous, root.dataDir);
        root.saveState();
        root.downloadRevision++;
        root.restartProxyForConfig();
        return null;
    }

    function trStr(key) {
        return Model.tr(root.language, key);
    }

    // Settings-UI entry point: validate the shape synchronously (inline error),
    // then prove writability with a tiny probe process before committing.
    property string dirApplyTarget: ""

    function applyDownloadDir(raw) {
        var clean = Model.sanitizeDirPath(raw, Quickshell.env("HOME"));
        var hadInput = String(raw === undefined || raw === null ? "" : raw).trim() !== "";
        if (hadInput && clean === "")
            return root.trStr("invalidPath");
        if (clean === root.downloadDir)
            return "";
        dirApplyTarget = clean;
        if (clean === "") {
            // Reset to the default root — nothing to probe.
            var err = root.setDownloadDir("");
            return err || "";
        }
        var q = root._shellQuote(clean);
        dirProbeProc.command = ["bash", "-c", "mkdir -p -- " + q + " 2>/dev/null && [ -w " + q + " ] && touch " + q + "/.quran-probe 2>/dev/null && rm -f " + q + "/.quran-probe"];
        dirProbeProc.running = true;
        return "";
    }

    Process {
        id: dirProbeProc
        running: false
        onExited: function (exitCode) {
            if (!root.dirApplyTarget)
                return;
            var target = root.dirApplyTarget;
            root.dirApplyTarget = "";
            if (exitCode !== 0) {
                root.settingsError = root.trStr("pathNotWritable");
                return;
            }
            var err = root.setDownloadDir(target);
            if (err)
                root.settingsError = err;
        }
    }

    // Transient inline error for the settings panel (path validation etc.);
    // separate from playback errorMessage so it never masquerades as one.
    property string settingsError: ""

    // --- local library ----------------------------------------------------------

    function libraryHas(id, n) {
        return root.libraryDir !== "" && root.libraryAvailable[id + ":" + n] === true;
    }

    function libraryAudioPath(id, n) {
        return root.libraryDir + "/" + id + "/" + n + ".mp3";
    }

    function libraryCount(id) {
        var count = 0;
        for (var i = 1; i <= 114; i++) {
            if (root.libraryAvailable[id + ":" + i] === true)
                count++;
        }
        return count;
    }

    // One bounded scan of the library root. The result map only accepts
    // <safeId>/<canonical 1..114>.mp3 entries (plus flat <n>.mp3 bound to
    // libraryReciter), so a stray file can't inject a hostile path into
    // playback.
    function rescanLibrary() {
        if (root.shuttingDown || libraryScanProc.running)
            return;
        if (root.libraryDir === "") {
            root.libraryAvailable = {};
            return;
        }
        root.libraryScanning = true;
        libraryScanProc.command = ["bash", "-c", "find " + root._shellQuote(root.libraryDir) + " -mindepth 1 -maxdepth 2 -type f -name '*.mp3'"];
        libraryScanProc.running = true;
    }

    function onLibraryScanFinished(text, exitCode) {
        root.libraryScanning = false;
        if (exitCode !== 0) {
            root.settingsError = root.trStr("libraryUnreadable");
            return;
        }
        root.libraryAvailable = Model.parseLibraryEntries(String(text || "").split("\n"), root.libraryDir, root.libraryReciter);
        root.downloadRevision++;
    }

    // Bind flat (depth-1) library files to a reciter and rescan.
    function setLibraryReciter(id) {
        var clean = Model.isSafeReciterArg(String(id || "")) ? String(id) : "";
        if (clean === root.libraryReciter)
            return;
        root.libraryReciter = clean;
        root.saveState();
        root.rescanLibrary();
    }

    // Settings entry point for the library folder: validate shape inline, then
    // probe readability and scan in one process before committing.
    property string libraryApplyTarget: ""

    function applyLibraryDir(raw) {
        var clean = Model.sanitizeDirPath(raw, Quickshell.env("HOME"));
        var hadInput = String(raw === undefined || raw === null ? "" : raw).trim() !== "";
        if (hadInput && clean === "")
            return root.trStr("invalidPath");
        if (clean === root.libraryDir)
            return "";
        libraryApplyTarget = clean;
        if (clean === "") {
            root.libraryDir = "";
            root.libraryAvailable = {};
            root.saveState();
            root.downloadRevision++;
            return "";
        }
        var q = root._shellQuote(clean);
        libraryProbeProc.command = ["bash", "-c", "[ -d " + q + " ] && [ -r " + q + " ] && find " + q + " -mindepth 1 -maxdepth 2 -type f -name '*.mp3'"];
        libraryProbeProc.running = true;
        return "";
    }

    Process {
        id: libraryProbeProc
        running: false
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root._libraryProbeOutput = text
        }
        onExited: function (exitCode) {
            if (!root.libraryApplyTarget)
                return;
            var target = root.libraryApplyTarget;
            root.libraryApplyTarget = "";
            if (exitCode !== 0) {
                root.settingsError = root.trStr("libraryUnreadable");
                return;
            }
            root.libraryDir = target;
            root.saveState();
            root.onLibraryScanFinished(root._libraryProbeOutput, 0);
        }
    }
    property string _libraryProbeOutput: ""

    Process {
        id: libraryScanProc
        running: false
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root._libraryScanOutput = text
        }
        onExited: function (exitCode) {
            var text = root._libraryScanOutput;
            root._libraryScanOutput = "";
            root.onLibraryScanFinished(text, exitCode);
        }
    }
    property string _libraryScanOutput: ""

    // One-shot HTTP request over the daemon's control-plane unix socket. The
    // daemon's responses are single-line JSON, so the body is the last parsed
    // line of the response; headers are discarded. Failures are silent (the
    // readout keeps its last value).
    function _proxyHttp(method, path, onData) {
        if (!root.proxyReady || root.proxyPort === 0)
            return;
        proxyHttpSocket.pending = {
            method: method,
            path: path,
            onData: onData
        };
        proxyHttpSocket.path = root.proxySocketPath;
        proxyHttpSocket.connected = true;
    }

    // Restart the daemon because configuration changed (download folder). Any
    // in-flight stream dies — acceptable for a deliberate settings change.
    function restartProxyForConfig() {
        if (root.shuttingDown || !root.proxyBinary)
            return;
        root.proxyManualRestart = true;
        root.proxyRestartCount = 0;
        if (proxyProc.running)
            proxyProc.running = false;
        else
            proxyRestartTimer.restart();
    }

    // --- quranproxyd lifecycle + events ---------------------------------------

    // Locate the audio-engine binaries once, at startup. The probe prefers a
    // committed prebuilt binary inside the plugin folder (works straight after
    // `omarchy plugin add`), then a user-installed copy in ~/.local/bin (dev /
    // install.sh). Any binary not found flips setupRequired so engine actions
    // show a clear setup hint instead of failing silently.
    function onToolProbe(out) {
        var found = {};
        var lines = String(out || "").split("\n");
        for (var i = 0; i < lines.length; i++) {
            var parts = lines[i].split(" ");
            if (parts.length >= 2 && parts[0] && parts[1]) {
                found[parts[0]] = parts[1];
            }
        }
        if (found["quranproxyd"])
            root.proxyBinary = found["quranproxyd"];
        if (found["quranctl"])
            root.quranctlBinary = found["quranctl"];
        root.setupRequired = !found["quranproxyd"] || !found["quranctl"];
        if (root.setupRequired) {
            root.errorMessage = Model.tr(root.language, "setupRequired");
        } else {
            // Binaries are resolved now; start the streaming daemon. (Component
            // onCompleted must not call _startProxy before the probe lands.)
            root._startProxy();
        }
    }

    // Start the range-caching proxy. The Go daemon reads the catalog from
    // statePath (watched for changes), promotes into dataDir, and writes the
    // handoff file on startup.
    function _startProxy() {
        if (root.shuttingDown || proxyProc.running)
            return;
        if (root.proxyRestartCount >= 5)
            return;
        if (!root.proxyBinary) {
            root.errorMessage = Model.tr(root.language, "setupRequired");
            return;
        }
        proxyProc.command = [root.proxyBinary, "--state-file", root.statePath, "--state-dir", root.dataDir, "--cache-dir", root.cacheDir, "--token-file", root.proxyHandoffPath];
        proxyProc.running = true;
    }

    // mpv source builder for the proxy stream endpoint. id/n are already
    // validated by callers; the guard re-checks so a stray call cannot craft a
    // URL with a hostile reciter.
    function _proxyStreamUrl(id, n) {
        if (!Model.isSafeReciterArg(id) || !Model.isValidSurahNumber(n))
            return "";
        return "http://127.0.0.1:" + root.proxyPort + "/stream?tok=" + root.proxyToken + "&reciter=" + id + "&surah=" + n;
    }

    // Handle a line of proxy stdout: `promoted <id> <n>` means a surah was
    // fully fetched, media-validated and atomically moved into dataDir — record
    // it as a permanent download (the widget/download UI then treats it like any
    // other downloaded surah; subsequent plays use the local file).
    function onProxyLine(line) {
        var m = String(line).match(/^promoted (\S+) (\d+)$/);
        if (!m)
            return;
        if (!Model.isSafeIdentifier(m[1]))
            return;
        var n = parseInt(m[2], 10);
        if (!Model.isValidSurahNumber(n))
            return;
        root.markSurahDownloaded(m[1], n);
        root.refreshCacheSize();
    }

    // Parse the daemon's handoff file ({ port, token }). Only a valid port and
    // 32-hex token enable proxy playback; anything else leaves proxyReady false
    // and playback falls back to the download-then-play path.
    function onProxyHandoff(json) {
        var data = null;
        try {
            data = JSON.parse(String(json || ""));
        } catch (e) {
            data = null;
        }
        if (!data)
            return;
        var port = parseInt(data.port, 10);
        if (!isFinite(port) || port < 1 || port > 65535)
            return;
        var tok = String(data.token || "");
        if (!/^[0-9a-f]{32}$/.test(tok))
            return;
        // The control-plane socket path must be an absolute path under our own
        // runtime dir (which the daemon shares) — anything else is refused; the
        // default derivation stays.
        if (typeof data.sock === "string" && root._isSafeSocketPath(data.sock)) {
            root.proxySocketPath = data.sock;
        }
        root.proxyPort = port;
        root.proxyToken = tok;
        root.proxyReady = true;
    }

    // The socket path is trusted only when it is absolute and lives under
    // mpvRuntimeDir (no "..", no control characters). mpvRuntimeDir itself is
    // derived in this file, never from the handoff.
    function _isSafeSocketPath(p) {
        if (p.indexOf(root.mpvRuntimeDir + "/") !== 0)
            return false;
        if (p.indexOf("..") !== -1)
            return false;
        for (var i = 0; i < p.length; i++) {
            var c = p.charCodeAt(i);
            if (c < 32 || c === 127)
                return false;
        }
        return true;
    }

    // --- reciter catalog fetch (with cache) ---

    property string rawRecitersEng: ""
    property string rawRecitersAr: ""

    function fetchReciters() {
        if (recitersProc.running || recitersArProc.running)
            return;
        if (root.reciters.length > 0 && root.catalogFetchedAt > 0 && (Date.now() - root.catalogFetchedAt) < Model.CATALOG_TTL_MS) {
            return;
        }
        root.recitersLoading = true;
        root.rawRecitersEng = "";
        root.rawRecitersAr = "";
        // Catalog fetches are bounded: https-only, no redirects, strict timeouts,
        // and a hard 2 MB response cap so a hostile catalog can't exhaust memory.
        var catalogFlags = ["curl", "-fsSL", "--proto", "=https", "--proto-redir", "=https", "--max-redirs", "0", "--connect-timeout", "10", "--max-time", "20", "--max-filesize", "2097152"];
        recitersProc.command = catalogFlags.concat([Model.API_RECITERS_ENG]);
        recitersProc.running = true;
        recitersArProc.command = catalogFlags.concat([Model.API_RECITERS_AR]);
        recitersArProc.running = true;
    }

    function applyReciters(jsonEng, jsonAr) {
        var dataEng = null;
        var dataAr = null;
        try {
            dataEng = JSON.parse(jsonEng || "");
        } catch (e) {
            dataEng = null;
        }
        try {
            dataAr = JSON.parse(jsonAr || "");
        } catch (e) {
            dataAr = null;
        }
        var parsed = Model.parseReciters(dataEng, dataAr);
        if (parsed.length === 0) {
            // Never replace a known-good catalog with an empty one; only surface
            // the error when there is nothing to fall back on.
            root.recitersLoading = false;
            if (root.reciters.length === 0) {
                root.catalogError = true;
                root.errorMessage = Model.tr(root.language, "reciterLoadFailed");
            }
            return;
        }
        root.reciters = parsed;
        root.recitersLoading = false;
        root.catalogError = false;
        if (!root.currentReciter)
            root.reciterId = Model.DEFAULT_RECITER;
        root.catalogFetchedAt = Date.now();
        root.saveState();
    }

    // Retry the last failed action: a failed catalog fetch refetches the reciter
    // list; a playback failure re-attempts playback. (Retrying playback when the
    // catalog is empty is pointless because there is nothing to list/validate.)
    function retry() {
        root.errorMessage = "";
        if (root.catalogError || root.reciters.length === 0) {
            root.catalogError = false;
            root.fetchReciters();
            return;
        }
        root.playSurah(root.reciterId, root.surahNumber);
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
            reciters: root.reciters,
            catalogFetchedAt: root.catalogFetchedAt,
            reciterStatus: root.reciterStatus,
            downloadedSurahs: root.downloadedSurahs,
            downloadIntent: root.downloadIntent,
            downloadDir: root.downloadDir,
            legacyRoots: root.legacyRoots,
            libraryDir: root.libraryDir,
            libraryReciter: root.libraryReciter
        };
        stateFile.setText(JSON.stringify(state));
    }

    function loadState(json) {
        if (!json)
            return;
        var data = null;
        try {
            data = JSON.parse(json);
        } catch (e) {
            data = null;
        }
        if (!data)
            return;

        // --- sanitize every field (schema v2, tolerate legacy garbage) ---
        if (Model.isValidLanguage(data.language))
            root.language = data.language;
        else
            root.language = Model.DEFAULT_LANGUAGE;

        if (Model.MODES.indexOf(data.playbackMode) !== -1)
            root.playbackMode = data.playbackMode;
        else
            root.playbackMode = Model.MODE_SINGLE;

        if (typeof data.reciterId === "string" && Model.isSafeIdentifier(data.reciterId)) {
            root.reciterId = data.reciterId;
        }
        if (typeof data.surahNumber === "number" && data.surahNumber >= 1 && data.surahNumber <= 114)
            root.surahNumber = data.surahNumber;

        if (Array.isArray(data.reciters) && data.reciters.length > 0) {
            // Re-validate persisted catalog entries (a stale/tampered state file
            // must not reintroduce an unsafe `server` or identifier). Count cap so
            // a hostile state file can't blow up memory.
            var safeReciters = [];
            for (var ri = 0; ri < data.reciters.length && safeReciters.length < 1000; ri++) {
                if (Model.isSafeReciter(data.reciters[ri]))
                    safeReciters.push(data.reciters[ri]);
            }
            if (safeReciters.length > 0) {
                root.reciters = safeReciters;
                if (!root.currentReciter)
                    root.reciterId = Model.DEFAULT_RECITER;
            }
        }
        if (typeof data.catalogFetchedAt === "number" && isFinite(data.catalogFetchedAt) && data.catalogFetchedAt >= 0) {
            root.catalogFetchedAt = data.catalogFetchedAt;
        }
        // Configured download root + remembered previous roots. Each entry is
        // re-validated with the same rules quranctl applies to --dest-root; a
        // hostile state file falls back to the default root.
        if (typeof data.downloadDir === "string")
            root.downloadDir = data.downloadDir === "" ? "" : Model.sanitizeDirPath(data.downloadDir, Quickshell.env("HOME"));
        if (Array.isArray(data.legacyRoots))
            root.legacyRoots = Model.mergeLegacyRoots(data.legacyRoots, root.dataDir, Quickshell.env("HOME"));
        if (typeof data.libraryDir === "string") {
            var libClean = data.libraryDir === "" ? "" : Model.sanitizeDirPath(data.libraryDir, Quickshell.env("HOME"));
            if (libClean !== root.libraryDir) {
                root.libraryDir = libClean;
                root.rescanLibrary();
            }
        }
        if (typeof data.libraryReciter === "string") {
            var libRec = data.libraryReciter;
            if (libRec !== "" && !Model.isSafeReciterArg(libRec))
                libRec = "";
            if (libRec !== root.libraryReciter) {
                root.libraryReciter = libRec;
                // Flat files are attributed by this binding — rescan so the
                // map reflects it even when only the reciter changed.
                root.rescanLibrary();
            }
        }
        if (data.reciterStatus && typeof data.reciterStatus === "object") {
            // Keys must be valid identifiers, values from the known set; junk is
            // dropped individually (including legacy "null" keys written by an
            // old bug).
            var statusClean = {};
            for (var sk in data.reciterStatus) {
                if (!Model.isSafeIdentifier(sk) || sk === "null")
                    continue;
                var sv = data.reciterStatus[sk];
                if (sv === "downloaded" || sv === "declined" || sv === "failed")
                    statusClean[sk] = sv;
            }
            root.reciterStatus = statusClean;
        }
        if (data.downloadedSurahs && typeof data.downloadedSurahs === "object") {
            // Keys must match <validIdentifier>:<1..114> with a canonical number,
            // value === true; invalid keys are dropped individually (not a
            // wholesale reject) and the map is capped.
            var dlClean = {};
            var dlCount = 0;
            for (var dk in data.downloadedSurahs) {
                if (dlCount >= 5000)
                    break;
                if (data.downloadedSurahs[dk] !== true)
                    continue;
                var dsep = dk.lastIndexOf(":");
                if (dsep <= 0)
                    continue;
                var did = dk.substring(0, dsep);
                var dnumStr = dk.substring(dsep + 1);
                var dnum = parseInt(dnumStr, 10);
                if (!Model.isSafeIdentifier(did))
                    continue;
                if (!Model.isValidSurahNumber(dnum))
                    continue;
                if (String(dnum) !== dnumStr)
                    continue;
                dlClean[dk] = true;
                dlCount++;
            }
            root.downloadedSurahs = dlClean;
            root.rebuildDownloadedCounts();
            root.downloadRevision++;
            root.queueDownloadedFileValidation();
        }

        // A download interrupted by a shell restart: sanitize the persisted
        // intent (identifier, surah, bounded list, optional playback request)
        // so junk can't reintroduce unsafe values or unbounded state.
        if (data.downloadIntent && typeof data.downloadIntent === "object") {
            var di = data.downloadIntent;
            var diId = (typeof di.id === "string" && Model.isSafeIdentifier(di.id)) ? di.id : "";
            var diSurah = (typeof di.surah === "number" && di.surah >= 0 && di.surah <= 114) ? di.surah : 0;
            var diList = [];
            if (Array.isArray(di.list)) {
                for (var li = 0; li < di.list.length && diList.length < 114; li++) {
                    var ln = parseInt(di.list[li], 10);
                    if (Model.isValidSurahNumber(ln) && diList.indexOf(ln) === -1)
                        diList.push(ln);
                }
            }
            if (diId !== "" && diList.length > 0) {
                var cleanIntent = {
                    id: diId,
                    surah: diSurah,
                    list: diList
                };
                if (di.pb && typeof di.pb === "object" && Model.isSafeIdentifier(di.pb.id) && Model.isValidSurahNumber(di.pb.n)) {
                    cleanIntent.pb = {
                        id: di.pb.id,
                        n: di.pb.n,
                        autoplay: di.pb.autoplay !== false,
                        positionMs: (typeof di.pb.positionMs === "number" && isFinite(di.pb.positionMs) && di.pb.positionMs >= 0 && di.pb.positionMs <= 24 * 60 * 60 * 1000) ? di.pb.positionMs : 0
                    };
                }
                root.downloadIntent = cleanIntent;
            }
        }

        // Cache budget is user-tunable via quran.json (sanitized to a sane range).
        if (typeof data.cacheLimitMb === "number" && data.cacheLimitMb >= 100 && data.cacheLimitMb <= 10000) {
            root.cacheLimitMb = data.cacheLimitMb;
        } else {
            root.cacheLimitMb = 500;
        }

        // Resume: restore last surah but stay paused; seek after the media loads.
        if (typeof data.position === "number" && isFinite(data.position) && data.position > 0 && data.position <= 24 * 60 * 60 * 1000) {
            root.resumePosition = data.position;
            root.savedPosition = data.position;
            root.resumePending = true;
        } else {
            root.resumePosition = 0;
        }

        root.stateLoaded = true;
        root._resumeInterruptedDownload();
        root._maybeResume();
        if (data.version !== Model.STATE_VERSION)
            root.saveState();
    }

    // After a shell restart, resume the download that was in flight when the
    // previous instance died. Runs exactly once per service instance (the state
    // file is watched and reloaded on every save, which must not re-trigger it).
    // quranctl re-validates finished files and skips them, and resumes
    // interrupted transfers from their partial files. If a playback request was
    // persisted while preempting a mushaf, that surah downloads (and plays)
    // first — the mushaf then resumes through the same onExited chain.
    // _maybeResume may also preempt the mushaf with the user's last surah via
    // the normal play path.
    function _resumeInterruptedDownload() {
        if (root.downloadResumeTried)
            return;
        root.downloadResumeTried = true;
        if (root.shuttingDown || !root.downloadIntent)
            return;
        var intent = root.downloadIntent;
        if (!root.reciterFor(intent.id)) {
            // Unknown reciter (stale catalog or tampered state): nothing to fetch,
            // and a lingering intent must not wedge the service.
            root.downloadIntent = null;
            root.saveState();
            return;
        }
        if (intent.pb) {
            if (root.isSurahDownloaded(intent.pb.id, intent.pb.n)) {
                root.requestLocalValidation(intent.pb.id, intent.pb.n, intent.pb.autoplay, intent.pb.positionMs);
            } else {
                // Serve the preempted playback first; mushafPending chains the mushaf
                // resume in downloadProc.onExited.
                root.pendingPlayback = {
                    id: intent.pb.id,
                    n: intent.pb.n,
                    autoplay: intent.pb.autoplay,
                    positionMs: intent.pb.positionMs
                };
                root.mushafPending = intent.id;
                root.startExplicitDownload(intent.pb.id, intent.pb.n);
                return;
            }
        }
        if (intent.surah === 0) {
            if (root.isMushafDownloaded(intent.id)) {
                root.downloadIntent = null;
                root.saveState();
                return;
            }
            root.startMushafDownload(intent.id, intent.list);
        } else {
            if (root.isSurahDownloaded(intent.id, intent.surah)) {
                root.downloadIntent = null;
                root.saveState();
                return;
            }
            root.startExplicitDownload(intent.id, intent.surah);
        }
    }

    // --- init ---

    Component.onCompleted: {
        root.fetchReciters();
        sockCleanProc.running = true;
        mprisFindProc.running = true;
        // Resolve the audio-engine binaries first; _startProxy is a no-op until
        // they are found (or setupRequired is set).
        toolProbeProc.command = ["bash", "-c", 'arch=$(uname -m); case "$arch" in x86_64) arch=amd64;; aarch64|arm64) arch=arm64;; *) arch="";; esac;' + ' plugin="$HOME/.config/omarchy/plugins/mus.quran/prebuilt/linux-$arch";' + ' for b in quranproxyd quranctl; do c="";' + '   [ -n "$arch" ] && [ -x "$plugin/$b" ] && c="$plugin/$b";' + '   [ -z "$c" ] && [ -x "$HOME/.local/bin/$b" ] && c="$HOME/.local/bin/$b";' + '   [ -n "$c" ] && echo "$b $c"; done'];
        toolProbeProc.running = true;
    }

    Component.onDestruction: {
        root.shuttingDown = true;
        mpvConnectTimer.stop();
        proxyRestartTimer.stop();
        proxyProc.running = false;
        if (root.mpvSock) {
            root.mpvSock.connected = false;
            root.mpvSock.destroy();
            root.mpvSock = null;
        }
        mpvProc.running = false;
    }

    // --- mpv backend ----------------------------------------------------------
    // A single long-lived mpv owns playback; MPRIS is provided by the mpv-mpris
    // plugin loaded explicitly (--script=...), never via config autoload —
    // --no-config disables the default script-autoload dir, so relying on
    // autoload would silently drop MPRIS. No network flags: mpv only ever
    // receives local files (see _mpvLoad).

    // Full mpv command line, built once the mpris plugin path is known.
    function _mpvCommandLine() {
        var cmd = ["mpv", "--idle", "--no-video", "--no-terminal", "--no-config", "--no-input-default-bindings", "--no-osc", "--demuxer-max-bytes=2M", "--demuxer-max-back-bytes=1M", "--demuxer-readahead-secs=15", "--input-ipc-server=" + root.mpvSocketPath];
        if (root.mpvMprisScript !== "")
            cmd.push("--script=" + root.mpvMprisScript);
        return cmd;
    }

    // Start mpv once both the socket-cleanup and the mpris probe finished.
    function _maybeStartMpv() {
        if (root.shuttingDown || mpvProc.running)
            return;
        if (sockCleanProc.running || mprisFindProc.running)
            return;
        mpvProc.command = root._mpvCommandLine();
        mpvProc.running = true;
    }

    Process {
        id: localValidationProc
        property var target: null
        property string mode: ""
        property string resolvedPath: ""
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: localValidationProc.resolvedPath = text.trim()
        }
        onExited: function (exitCode) {
            root.onLocalValidationExited(exitCode);
        }
    }

    Process {
        id: mpvProc
        command: ["mpv", "--idle"]
        running: false
        onStarted: root._mpvConnect()
        onExited: function (exitCode) {
            root.onMpvExited(exitCode);
        }
    }

    // Locate the mpv-mpris C plugin in the standard install locations. When it
    // is missing, playback continues without system media control.
    Process {
        id: mprisFindProc
        command: ["bash", "-c", 'for p in /usr/lib/mpv/mpv-mpris/mpv_mpris.so /usr/lib64/mpv/mpv-mpris/mpv_mpris.so /usr/share/mpv/scripts/mpv-mpris/mpv_mpris.so /usr/lib/mpv-mpris/mpris.so /etc/mpv/scripts/mpris.so "$HOME/.config/mpv/scripts/mpv-mpris/mpv_mpris.so" "$HOME/.local/lib/mpv/mpv-mpris/mpv_mpris.so"; do [ -f "$p" ] && { echo "$p"; exit 0; }; done; exit 1']
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
                root._maybeStartMpv();
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
                onRead: function (line) {
                    root.onMpvLine(line);
                }
            }
            onError: function () {
                mpvConnectTimer.restart();
            }
            onConnectionStateChanged: {
                if (connected) {
                    mpvConnectTimer.stop();
                    root.onMpvConnected();
                } else if (!root.shuttingDown) {
                    mpvConnectTimer.restart();
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
            if (root.pendingTarget)
                root._playNow(root.pendingTarget.id, root.pendingTarget.n);
            root.pendingTarget = null;
        }
    }

    // Periodic position save while playing.
    Timer {
        id: positionSaveTimer
        interval: 5000
        running: root.isPlaying
        repeat: true
        onTriggered: {
            if (root.player.position > 0)
                root.savedPosition = root.player.position;
            root.saveState();
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
                root.rawRecitersEng = text;
                if (root.rawRecitersAr !== "")
                    root.applyReciters(root.rawRecitersEng, root.rawRecitersAr);
            }
        }
        onExited: function (exitCode) {
            if (exitCode !== 0) {
                root.recitersLoading = false;
                root.catalogError = true;
                root.errorMessage = Model.tr(root.language, "reciterLoadFailed");
            }
        }
    }

    Process {
        id: recitersArProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                root.rawRecitersAr = text;
                if (root.rawRecitersEng !== "")
                    root.applyReciters(root.rawRecitersEng, root.rawRecitersAr);
            }
        }
        onExited: function (exitCode) {
            if (exitCode !== 0 && root.rawRecitersEng !== "") {
                root.applyReciters(root.rawRecitersEng, "");
            }
        }
    }

    Process {
        id: downloadProc
        property var targetReciter: null
        property int targetSurah: 0
        stdout: SplitParser {
            onRead: function (line) {
                root.applyDownloadProgress(line);
            }
        }
        onExited: function (exitCode) {
            var id = downloadProc.targetReciter;
            var n = downloadProc.targetSurah;
            // A full-mushaf download deliberately cancelled because playback
            // preempted it: not a failure, and not a completion either — the mushaf
            // resumes below once no playback download is queued.
            var preempted = (n === 0 && root.mushafPending === id);
            root.downloading = false;
            if (exitCode === 0 && !preempted) {
                if (n > 0) {
                    root._clearCooldown(id, n);
                    root.markSurahDownloaded(id, n);
                    // A completed single-surah download clears its own persisted intent.
                    // (A mushaf intent is owned by startMushafDownload / the resume.)
                    if (root.downloadIntent && root.downloadIntent.surah === n && root.downloadIntent.id === id) {
                        root.downloadIntent = null;
                        root.saveState();
                    }
                } else {
                    root.finishMushafDownload(id);
                    id = null;
                    n = 0;
                }
            } else if (id && !preempted) {
                // A failed run must not replay on every shell restart: drop the
                // persisted intent (manual retry via the row icon still works).
                if (root.downloadIntent && root.downloadIntent.id === id
                    && root.downloadIntent.surah === n) {
                    root.downloadIntent = null;
                    root.saveState();
                }
                if (n > 0) {
                    // Single-surah failure: surface it through the existing inline
                    // error pattern; the icon reverts and a retry re-runs quranctl.
                    root.errorMessage = Model.tr(root.language, "downloadFailed");
                } else {
                    // Partial mushaf: keep what finished; a retry resumes (quranctl
                    // skips complete files and resumes partial ones).
                    // Always surface the failure, including a previously-declined
                    // reciter; the old branch made an instant script failure invisible.
                    root.errorMessage = Model.tr(root.language, "downloadFailed");
                    if (root.reciterStatus[id] !== "downloaded")
                        root.setReciterStatus(id, "failed");
                }
            }
            // Playback waiting on this exact download: validate and play it now.
            if (exitCode === 0 && n > 0 && root.pendingPlayback && root.pendingPlayback.id === id && root.pendingPlayback.n === n) {
                var pb = root.pendingPlayback;
                root.pendingPlayback = null;
                root.requestLocalValidation(id, n, pb.autoplay, pb.positionMs);
            }
            // A playback request queued behind this download: start it. (This also
            // serves a playback preempting a running mushaf — the mushaf's own exit
            // lands here and hands off to the requested surah's download.)
            if (root.pendingPlayback && !root.downloading) {
                var queued = root.pendingPlayback;
                root.pendingPlayback = null;
                if (queued && queued.id && queued.n) {
                    if (root.isSurahDownloaded(queued.id, queued.n)) {
                        root.requestLocalValidation(queued.id, queued.n, queued.autoplay, queued.positionMs);
                    } else if (!root._inCooldown(queued.id, queued.n)) {
                        root._markFetchAttempt(queued.id, queued.n);
                        root.startExplicitDownload(queued.id, queued.n);
                    } else {
                        root.errorMessage = Model.tr(root.language, "playbackFailed");
                    }
                }
            }
            // A preempted mushaf resumes once no playback download is pending.
            if (root.mushafPending && !root.downloading) {
                var mid = root.mushafPending;
                root.mushafPending = null;
                var work = [];
                for (var mi = 1; mi <= 114; mi++)
                    work.push(mi);
                root.startMushafDownload(mid, work);
            }
            downloadProc.targetReciter = null;
            downloadProc.targetSurah = 0;
            root.downloadReciter = "";
        }
    }

    Process {
        id: localRemoveProc
        running: false
    }

    // One-shot startup probe that locates the audio-engine binaries (see
    // Component.onCompleted). Its output is "name path" lines.
    Process {
        id: toolProbeProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.onToolProbe(text)
        }
    }

    // quranproxyd: range-caching stream proxy. Its stdout is the `promoted`
    // event channel consumed by onProxyLine; on an abnormal exit the proxy is
    // restarted (bounded) and proxyReady drops so playback falls back to the
    // download path until the handoff reappears.
    Process {
        id: proxyProc
        running: false
        stdout: SplitParser {
            onRead: function (line) {
                root.onProxyLine(line);
            }
        }
        onExited: function (exitCode) {
            root.proxyReady = false;
            root.proxyPort = 0;
            root.proxyToken = "";
            if (root.proxyManualRestart) {
                // Deliberate stop (config change): relaunch without burning
                // the crash-restart budget.
                root.proxyManualRestart = false;
                proxyRestartTimer.restart();
                return;
            }
            if (!root.shuttingDown && root.proxyRestartCount < 5) {
                root.proxyRestartCount++;
                proxyRestartTimer.restart();
            }
        }
    }

    Timer {
        id: proxyRestartTimer
        interval: 2000
        onTriggered: root._startProxy()
    }

    // Watches the daemon's handoff file ({ port, token }), written atomically
    // right after the proxy binds its listener.
    FileView {
        id: proxyHandoffFile
        path: root.proxyHandoffPath
        watchChanges: true
        printErrors: false
        onLoaded: root.onProxyHandoff(text())
        onFileChanged: reload()
    }

    // One-shot HTTP client on the daemon's control-plane unix socket (see
    // _proxyHttp). The daemon responds with single-line JSON bodies, so the
    // parser's last line before disconnect is the JSON; header lines are
    // ignored. `pending` holds the { method, path, onData } of the in-flight
    // request; the request is written when the socket connects, and the socket
    // is closed once a JSON line arrives.
    Socket {
        id: proxyHttpSocket
        property var pending: null
        parser: SplitParser {
            onRead: function (line) {
                var p = proxyHttpSocket.pending;
                if (!p || String(line).indexOf("{") !== 0)
                    return;
                proxyHttpSocket.pending = null;
                var data = null;
                try {
                    data = JSON.parse(String(line));
                } catch (e) {
                    data = null;
                }
                proxyHttpSocket.connected = false;
                if (data && p.onData)
                    p.onData(data);
            }
        }
        onConnectionStateChanged: {
            if (connected && proxyHttpSocket.pending) {
                var p = proxyHttpSocket.pending;
                proxyHttpSocket.write(p.method + " " + p.path + " HTTP/1.1\r\n" + "Host: localhost\r\nConnection: close\r\n\r\n");
                proxyHttpSocket.flush();
            } else if (!connected) {
                // Daemon closed the connection (or never accepted it): the in-flight
                // request is dead — drop it so the next poll starts fresh.
                proxyHttpSocket.pending = null;
            }
        }
        onError: function () {
            proxyHttpSocket.pending = null;
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
        command: ["bash", "-c", 'd="$1"; p="$2"; mkdir -p -m 700 -- "$d" || exit 1; [ -S "$p" ] || exit 0; [ "$(stat -c %u "$p")" = "$(id -u)" ] || exit 0; rm -f -- "$p"', "sockclean", root.mpvRuntimeDir, root.mpvSocketPath]
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
            });
        }

        function playPause(): string {
            root.playPause();
            return "ok";
        }

        function next(): string {
            root.next();
            return "ok";
        }

        function previous(): string {
            root.previous();
            return "ok";
        }

        function seek(ms: string): string {
            var v = Model.parseSeekArg(root._capString(ms, 32));
            if (v === null)
                return "error: invalid seek position";
            root.seek(v);
            return "ok";
        }

        function playSurah(reciterId: string, surahNumber: string): string {
            var id = root._capString(reciterId, 128);
            if (!id)
                id = root.reciterId;
            var n = Model.parseSurahArg(root._capString(surahNumber, 32));
            if (n === null)
                return "error: invalid surah to play";
            if (!Model.isSafeReciterArg(id))
                return "error: invalid reciter";
            if (root.reciters.length > 0 && !Model.reciterExists(root.reciters, id))
                return "error: unknown reciter";
            root.playSurah(id, n);
            return "ok";
        }

        function setLanguage(language: string): string {
            root.setLanguage(language);
            return "ok";
        }

        function setMode(mode: string): string {
            if (Model.MODES.indexOf(mode) !== -1) {
                root.playbackMode = mode;
                root.saveState();
            }
            return "ok";
        }

        function download(reciterId: string, n: string): string {
            var id = root._capString(reciterId, 128);
            if (!Model.isSafeReciterArg(id))
                return "error: invalid reciter";
            if (!Model.reciterExists(root.reciters, id))
                return "error: unknown reciter";
            var raw = root._capString(n, 32);
            var surah = 0;
            if (raw !== "" && raw !== "0") {
                surah = Model.parseSurahArg(raw);
                if (surah === null)
                    return "error: invalid surah";
            }
            if (surah === 0) {
                root.downloadMushaf(id);
            } else {
                if (root.downloading || root._inCooldown(id, surah))
                    return "error: retry in a moment";
                root.downloadSurah(id, surah);
            }
            return "ok";
        }
        // function download(reciterId: string, n: string): string {
        //     var id = root._capString(reciterId, 128);
        //     if (!Model.isSafeReciterArg(id))
        //         return "error: invalid reciter";
        //     if (!Model.reciterExists(root.reciters, id))
        //         return "error: unknown reciter";
        //     var raw = root._capString(n, 32);
        //     var surah = 0;
        //     if (raw !== "") {
        //         surah = Model.parseSurahArg(raw);
        //         if (surah === null)
        //             return "error: invalid surah";
        //     }
        //     if (surah === 0) {
        //         root.downloadMushaf(id);
        //     } else {
        //         // Cooldown gate alongside the existing refuse-while-downloading guard:
        //         // a caller cannot force more than one real fetch per reciter:surah
        //         // inside the window.
        //         if (root.downloading || root._inCooldown(id, surah))
        //             return "error: retry in a moment";
        //         root.downloadSurah(id, surah);
        //     }
        //     return "ok";
        // }

        function ping(): string {
            return "ok";
        }

        function clearCache(): string {
            root.clearCache();
            return "ok";
        }

        function cacheInfo(): string {
            return JSON.stringify({
                sizeBytes: root.proxySizeBytes,
                limitMb: root.cacheLimitMb,
                files: root.proxyFilesCount,
                inflight: 0
            });
        }
    }
}
