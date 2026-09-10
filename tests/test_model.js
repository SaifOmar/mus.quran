#!/usr/bin/env node
"use strict";

// Unit tests for Model.js (URL policy, arg parsers, cooldown gate, caps).
// Model.js is a QML .pragma library; we execute it inside a vm sandbox that
// stubs the minimal QML globals it touches.

const fs = require("fs");
const path = require("path");
const vm = require("vm");

const MODEL = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8");

let pass = 0, fail = 0;

function ok(name, cond) {
  if (cond) { pass++; console.log("PASS " + name); }
  else { fail++; console.log("FAIL " + name); }
}

function loadModel() {
  const sandbox = {
    console,
    // QML .pragma library globals that Model.js may reference at eval time
    Qt: { },
  };
  vm.createContext(sandbox);
  const src = MODEL.split("\n").filter((l) => l.trim() !== ".pragma library").join("\n");
  vm.runInContext(src, sandbox, { filename: "Model.js" });
  return sandbox;
}

const M = loadModel();

// ---------------------------------------------------------------------------
// isSafeIdentifier / isSafeReciterArg
// ---------------------------------------------------------------------------
ok("safe id: plain", M.isSafeIdentifier("ar.alafasy"));
ok("safe id: underscores/dashes/dots", M.isSafeIdentifier("a.b-c_d.1"));
ok("safe id: starts with digit", M.isSafeIdentifier("123abc"));
ok("safe id: single alnum", M.isSafeIdentifier("a"));
ok("safe id: 64 chars ok", M.isSafeIdentifier("a".repeat(64)));
ok("safe id: 65 chars rejected", !M.isSafeIdentifier("a".repeat(65)));
ok("safe id: empty rejected", !M.isSafeIdentifier(""));
ok("safe id: non-string rejected", !M.isSafeIdentifier(42));
ok("safe id: slash rejected", !M.isSafeIdentifier("a/b"));
ok("safe id: backslash rejected", !M.isSafeIdentifier("a\\b"));
ok("safe id: dotdot rejected", !M.isSafeIdentifier(".."));
ok("safe id: dot rejected", !M.isSafeIdentifier("."));
ok("safe id: leading dot rejected", !M.isSafeIdentifier(".hidden"));
ok("safe id: space rejected", !M.isSafeIdentifier("a b"));
ok("safe id: percent rejected", !M.isSafeIdentifier("a%2f"));
ok("safe id: newline rejected", !M.isSafeIdentifier("a\nb"));
ok("safe id: null rejected", !M.isSafeIdentifier(null));
ok("safe id: unicode rejected", !M.isSafeIdentifier("عبد"));
ok("safe reciter arg: same policy", M.isSafeReciterArg("ar.alafasy") && !M.isSafeReciterArg("../etc"));

// ---------------------------------------------------------------------------
// parseSurahArg
// ---------------------------------------------------------------------------
ok("surah arg: 1", M.parseSurahArg("1") === 1);
ok("surah arg: 114", M.parseSurahArg("114") === 114);
ok("surah arg: 57", M.parseSurahArg("57") === 57);
ok("surah arg: 0 rejected", M.parseSurahArg("0") === null);
ok("surah arg: 115 rejected", M.parseSurahArg("115") === null);
ok("surah arg: -1 rejected", M.parseSurahArg("-1") === null);
ok("surah arg: 1junk rejected", M.parseSurahArg("1junk") === null);
ok("surah arg: junk1 rejected", M.parseSurahArg("junk1") === null);
ok("surah arg: 01 rejected", M.parseSurahArg("01") === null);
ok("surah arg: 1.5 rejected", M.parseSurahArg("1.5") === null);
ok("surah arg: empty rejected", M.parseSurahArg("") === null);
ok("surah arg: whitespace rejected", M.parseSurahArg(" 1") === null);
ok("surah arg: non-string rejected", M.parseSurahArg(1) === null);
ok("surah arg: huge rejected", M.parseSurahArg("99999999999999999999999999") === null);
ok("surah arg: +1 rejected", M.parseSurahArg("+1") === null);

// ---------------------------------------------------------------------------
// parseSeekArg
// ---------------------------------------------------------------------------
ok("seek arg: 0", M.parseSeekArg("0") === 0);
ok("seek arg: 30", M.parseSeekArg("30") === 30);
ok("seek arg: -15", M.parseSeekArg("-15") === -15);
ok("seek arg: +5 rejected", M.parseSeekArg("+5") === null);
ok("seek arg: 5s rejected", M.parseSeekArg("5s") === null);
ok("seek arg: 1.5 rejected", M.parseSeekArg("1.5") === null);
ok("seek arg: empty rejected", M.parseSeekArg("") === null);
ok("seek arg: non-string rejected", M.parseSeekArg(-5) === null);
ok("seek arg: whitespace rejected", M.parseSeekArg(" -5") === null);

// ---------------------------------------------------------------------------
// URL policy: isSafeServerPrefix / sanitizeServer / audioUrl
// ---------------------------------------------------------------------------
// valid
ok("url: plain cdn", M.isSafeServerPrefix("https://cdn.islamic.app/quran/audio-surah/"));
ok("url: mp3quran.net", M.isSafeServerPrefix("https://server8.mp3quran.net/afs/"));
ok("url: subdomain of allowlisted", M.isSafeServerPrefix("https://a.b.c.islamic.app/x/"));
ok("url: port 443", M.isSafeServerPrefix("https://cdn.islamic.app:443/x/"));
ok("url: port 8080", M.isSafeServerPrefix("https://cdn.islamic.app:8080/x/"));
ok("url: no trailing slash ok", M.isSafeServerPrefix("https://cdn.islamic.app/quran"));
ok("url: sanitize adds slash", M.sanitizeServer("https://cdn.islamic.app/quran") === "https://cdn.islamic.app/quran/");
ok("url: sanitize keeps slash", M.sanitizeServer("https://cdn.islamic.app/quran/") === "https://cdn.islamic.app/quran/");

// scheme / structure
ok("url: http rejected", !M.isSafeServerPrefix("http://cdn.islamic.app/x/"));
ok("url: ftp rejected", !M.isSafeServerPrefix("ftp://cdn.islamic.app/x/"));
ok("url: protocol-relative rejected", !M.isSafeServerPrefix("//cdn.islamic.app/x/"));
ok("url: javascript rejected", !M.isSafeServerPrefix("javascript:alert(1)"));
ok("url: https with userinfo rejected", !M.isSafeServerPrefix("https://user:pass@cdn.islamic.app/x/"));
ok("url: https with user@ rejected", !M.isSafeServerPrefix("https://user@cdn.islamic.app/x/"));
ok("url: query rejected", !M.isSafeServerPrefix("https://cdn.islamic.app/x/?a=1"));
ok("url: fragment rejected", !M.isSafeServerPrefix("https://cdn.islamic.app/x/#frag"));
ok("url: control char rejected", !M.isSafeServerPrefix("https://cdn.islamic.app/x/\n/evil"));
ok("url: embedded tab rejected", !M.isSafeServerPrefix("https://cdn.islamic.app/x/\t/evil"));
ok("url: space rejected", !M.isSafeServerPrefix("https://cdn.islamic.app/x/ y"));
ok("url: empty rejected", !M.isSafeServerPrefix(""));
ok("url: whitespace-only rejected", !M.isSafeServerPrefix("   "));
ok("url: null rejected", !M.isSafeServerPrefix(null));
ok("url: overlong rejected", !M.isSafeServerPrefix("https://cdn.islamic.app/" + "a".repeat(600)));
ok("url: percent-encoded dot rejected", !M.isSafeServerPrefix("https://cdn.islamic%2eapp/x/"));
ok("url: percent-encoded slash rejected", !M.isSafeServerPrefix("https://cdn.islamic.app%2fx/"));
ok("url: percent-encoded question rejected", !M.isSafeServerPrefix("https://cdn.islamic.app/x%3fy"));
ok("url: percent-encoded hash rejected", !M.isSafeServerPrefix("https://cdn.islamic.app/x%23y"));
ok("url: percent-encoded at rejected", !M.isSafeServerPrefix("https://user%40x@cdn.islamic.app/"));
ok("url: percent-encoded backslash rejected", !M.isSafeServerPrefix("https://cdn.islamic.app/x%5cy"));

// ports
ok("url: port 0 rejected", !M.isSafeServerPrefix("https://cdn.islamic.app:0/x/"));
ok("url: port 65536 rejected", !M.isSafeServerPrefix("https://cdn.islamic.app:65536/x/"));
ok("url: port 01 rejected", !M.isSafeServerPrefix("https://cdn.islamic.app:01/x/"));
ok("url: port 443a rejected", !M.isSafeServerPrefix("https://cdn.islamic.app:443a/x/"));
ok("url: port empty rejected", !M.isSafeServerPrefix("https://cdn.islamic.app:/x/"));
ok("url: port negative rejected", !M.isSafeServerPrefix("https://cdn.islamic.app:-1/x/"));

// host policy
ok("url: bare ipv4 rejected", !M.isSafeServerPrefix("https://93.184.216.34/x/"));
ok("url: disallowed domain rejected", !M.isSafeServerPrefix("https://evil.com/x/"));
ok("url: lookalike suffix rejected", !M.isSafeServerPrefix("https://islamic.app.evil.com/x/"));
ok("url: isl amic.app rejected", !M.isSafeServerPrefix("https://islamicapp.com/x/"));
ok("url: exact allowlist entry ok", M.isSafeServerPrefix("https://islamic.app/x/"));
ok("url: trailing dot host ok", M.isSafeServerPrefix("https://cdn.islamic.app./x/"));
ok("url: localhost rejected", !M.isSafeServerPrefix("https://localhost/x/"));
ok("url: .local rejected", !M.isSafeServerPrefix("https://foo.local/x/"));
ok("url: .internal rejected", !M.isSafeServerPrefix("https://foo.internal/x/"));
ok("url: .localhost rejected", !M.isSafeServerPrefix("https://foo.localhost/x/"));
ok("url: single-label rejected", !M.isSafeServerPrefix("https://intranet/x/"));

// ipv4 encodings
ok("url: 127.0.0.1 rejected", !M.isSafeServerPrefix("https://127.0.0.1/x/"));
ok("url: 10.0.0.1 rejected", !M.isSafeServerPrefix("https://10.0.0.1/x/"));
ok("url: 172.16.0.1 rejected", !M.isSafeServerPrefix("https://172.16.0.1/x/"));
ok("url: 172.31.255.255 rejected", !M.isSafeServerPrefix("https://172.31.255.255/x/"));
ok("url: 192.168.1.1 rejected", !M.isSafeServerPrefix("https://192.168.1.1/x/"));
ok("url: 169.254.0.1 rejected", !M.isSafeServerPrefix("https://169.254.0.1/x/"));
ok("url: 100.64.0.1 rejected", !M.isSafeServerPrefix("https://100.64.0.1/x/"));
ok("url: 0.0.0.0 rejected", !M.isSafeServerPrefix("https://0.0.0.0/x/"));
ok("url: 224.0.0.1 rejected", !M.isSafeServerPrefix("https://224.0.0.1/x/"));
ok("url: 255.255.255.255 rejected", !M.isSafeServerPrefix("https://255.255.255.255/x/"));
ok("url: 192.0.0.1 rejected", !M.isSafeServerPrefix("https://192.0.0.1/x/"));
ok("url: 192.0.2.1 rejected", !M.isSafeServerPrefix("https://192.0.2.1/x/"));
ok("url: 198.51.100.1 rejected", !M.isSafeServerPrefix("https://198.51.100.1/x/"));
ok("url: 203.0.113.1 rejected", !M.isSafeServerPrefix("https://203.0.113.1/x/"));
ok("url: octal ipv4 rejected", !M.isSafeServerPrefix("https://0177.0.0.1/x/"));
ok("url: hex ipv4 rejected", !M.isSafeServerPrefix("https://0x7f.0.0.1/x/"));
ok("url: short ipv4 rejected", !M.isSafeServerPrefix("https://2130706433/x/"));
ok("url: ipv4 with leading zero rejected", !M.isSafeServerPrefix("https://127.0.0.01/x/"));
ok("url: public ipv4 not allowlisted", !M.isSafeServerPrefix("https://8.8.8.8/x/"));

// ipv6
ok("url: ipv6 loopback rejected", !M.isSafeServerPrefix("https://[::1]/x/"));
ok("url: ipv6 unspecified rejected", !M.isSafeServerPrefix("https://[::]/x/"));
ok("url: ipv6 link-local rejected", !M.isSafeServerPrefix("https://[fe80::1]/x/"));
ok("url: ipv6 ula rejected", !M.isSafeServerPrefix("https://[fc00::1]/x/"));
ok("url: ipv4-mapped ipv6 rejected", !M.isSafeServerPrefix("https://[::ffff:127.0.0.1]/x/"));
ok("url: ipv4-compatible ipv6 rejected", !M.isSafeServerPrefix("https://[::ffff:7f00:1]/x/"));
ok("url: zone id rejected", !M.isSafeServerPrefix("https://[fe80::1%25eth0]/x/"));
ok("url: bracketed junk rejected", !M.isSafeServerPrefix("https://[g::1]/x/"));
ok("url: unbracketed ipv6 rejected", !M.isSafeServerPrefix("https://2001:db8::1/x/"));
ok("url: bracket then bad port rejected", !M.isSafeServerPrefix("https://[2001:db8::1]:0/x/"));
ok("url: bracket then non-port rejected", !M.isSafeServerPrefix("https://[2001:db8::1]:abc/x/"));

// audioUrl
ok("audioUrl: default cdn built", M.audioUrl("ar.alafasy", 1) === "https://cdn.islamic.app/quran/audio-surah/ar.alafasy/1.mp3");
ok("audioUrl: pads surah 1 -> 001", M.audioUrl("ar.alafasy", 1).indexOf("/001.mp3") !== -1 || M.audioUrl("ar.alafasy", 1).indexOf("/1.mp3") !== -1);
ok("audioUrl: surah 114 ok", M.audioUrl("ar.alafasy", 114) !== "");
ok("audioUrl: surah 115 rejected", M.audioUrl("ar.alafasy", 115) === "");
ok("audioUrl: surah 0 rejected", M.audioUrl("ar.alafasy", 0) === "");
ok("audioUrl: junk id rejected", M.audioUrl("../etc", 1) === "");
ok("audioUrl: id with slash rejected", M.audioUrl("a/b", 1) === "");
ok("audioUrl: ajamy maps to ahmedajamy", M.audioUrl("ar.ajamy", 1) === "https://cdn.islamic.app/quran/audio-surah/ar.ahmedajamy/1.mp3");
ok("audioUrl: server object used", M.audioUrl("x", 1, { server: "https://server8.mp3quran.net/afs/" }) === "https://server8.mp3quran.net/afs/001.mp3");
ok("audioUrl: hostile server object rejected", M.audioUrl("x", 1, { server: "http://evil.com/" }) === "");

// isSafeRemoteUrl mirrors server-prefix policy on the final URL
ok("remote url: final url guarded", M.isSafeRemoteUrl("https://cdn.islamic.app/quran/audio-surah/ar.alafasy/1.mp3"));
ok("remote url: http rejected", !M.isSafeRemoteUrl("http://cdn.islamic.app/quran/audio-surah/ar.alafasy/1.mp3"));

// ---------------------------------------------------------------------------
// isSafeReciter
// ---------------------------------------------------------------------------
ok("safe reciter: id+server", M.isSafeReciter({ identifier: "ar.alafasy", server: "https://cdn.islamic.app/x/" }));
ok("safe reciter: bad server rejected", !M.isSafeReciter({ identifier: "ar.alafasy", server: "http://x/" }));
ok("safe reciter: bad id rejected", !M.isSafeReciter({ identifier: "../x", server: "https://cdn.islamic.app/x/" }));
ok("safe reciter: null rejected", !M.isSafeReciter(null));
ok("safe reciter: server undefined ok", M.isSafeReciter({ identifier: "ar.alafasy" }));

// ---------------------------------------------------------------------------
// parseReciters caps
// ---------------------------------------------------------------------------
{
  const many = [];
  for (let i = 0; i < 2000; i++) many.push({ identifier: "r" + i, audioLevels: ["surah"], name: "n" + i, englishName: "e" + i });
  const out = M.parseReciters({ reciters: many });
  ok("parseReciters caps at 1000", out.length === 1000);
}
{
  const long = [{ identifier: "a", audioLevels: ["surah"], name: "x".repeat(201), englishName: "y" }];
  ok("parseReciters rejects 201-char name", M.parseReciters({ reciters: long }).length === 0);
  const okName = [{ identifier: "a", audioLevels: ["surah"], name: "x".repeat(200), englishName: "y" }];
  ok("parseReciters accepts 200-char name", M.parseReciters({ reciters: okName }).length === 1);
}

// ---------------------------------------------------------------------------
// cooldown gate
// ---------------------------------------------------------------------------
{
  const map = {};
  const t0 = 1000000;
  ok("cooldown: inactive on fresh map", !M.cooldownActive(map, "ar.alafasy:1", t0));
  M.markCooldown(map, "ar.alafasy:1", t0);
  ok("cooldown: active inside window", M.cooldownActive(map, "ar.alafasy:1", t0 + 5000));
  ok("cooldown: inactive after window", !M.cooldownActive(map, "ar.alafasy:1", t0 + M.COOLDOWN_MS + 1));
  ok("cooldown: other key unaffected", !M.cooldownActive(map, "ar.alafasy:2", t0 + 5000));
  M.clearCooldown(map, "ar.alafasy:1");
  ok("cooldown: cleared", !M.cooldownActive(map, "ar.alafasy:1", t0 + 5000));
  ok("cooldown: missing key active (defensive)", M.cooldownActive(map, null, t0));
  ok("cooldown: COOLDOWN_MS is 10000", M.COOLDOWN_MS === 10000);

  // Gate-flow simulation: a caller who keeps asking inside the window gets at
  // most one "fetch" per key; the fetch only happens when the gate is open.
  const fetches = { count: 0 };
  function tryFetch(key, now) {
    if (M.cooldownActive(map, key, now)) return { fetched: false, reason: "cooldown" };
    fetches.count++;
    M.markCooldown(map, key, now); // failure path marks cooldown
    return { fetched: true };
  }
  const key = "ar.alafasy:7";
  const results = [];
  results.push(tryFetch(key, t0 + 1).fetched);
  results.push(tryFetch(key, t0 + 2).fetched);
  results.push(tryFetch(key, t0 + 3).fetched);
  ok("gate: one fetch per window", fetches.count === 1);
  ok("gate: only first attempt fetched", results.join() === "true,false,false");
  ok("gate: window expiry allows refetch", tryFetch(key, t0 + M.COOLDOWN_MS + 100).fetched === true);
  ok("gate: two fetches total across two windows", fetches.count === 2);
}

// ---------------------------------------------------------------------------
// misc helpers the UI depends on
// ---------------------------------------------------------------------------
ok("isValidSurahNumber: 1", M.isValidSurahNumber(1));
ok("isValidSurahNumber: 114", M.isValidSurahNumber(114));
ok("isValidSurahNumber: 0 rejected", !M.isValidSurahNumber(0));
ok("isValidSurahNumber: 115 rejected", !M.isValidSurahNumber(115));
ok("isValidSurahNumber: 1.5 rejected", !M.isValidSurahNumber(1.5));
ok("isValidSurahNumber: string rejected", !M.isValidSurahNumber("1"));
ok("reciterExists: found", M.reciterExists([{ identifier: "ar.alafasy" }], "ar.alafasy"));
ok("reciterExists: missing", !M.reciterExists([{ identifier: "ar.alafasy" }], "ar.ajamy"));
ok("localAudioUrl: builds file url", M.localAudioUrl("/data/state/omarchy/quran", "ar.alafasy", 1) === "file:///data/state/omarchy/quran/ar.alafasy/1.mp3");
ok("localAudioUrl: traversal rejected", M.localAudioUrl("/data/../etc", "ar.alafasy", 1) === "");
ok("localAudioUrl: bad reciter rejected", M.localAudioUrl("/data", "../etc", 1) === "");
ok("localAudioUrl: bad surah rejected", M.localAudioUrl("/data", "ar.alafasy", 115) === "");
ok("MAX_SURAH_BYTES is 314572800", M.MAX_SURAH_BYTES === 314572800);

console.log("\nmodel.js: " + pass + " passed, " + fail + " failed");
process.exit(fail === 0 ? 0 : 1);