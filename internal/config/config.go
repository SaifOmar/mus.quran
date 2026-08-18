// Package config parses command-line flags and environment defaults for the
// quranproxyd daemon. Path defaults mirror the mus.quran plugin's conventions
// (Service.qml dataDir/statePath/cacheDir/mpvRuntimeDir).
package config

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
)

const (
	// DefaultMaxSurahBytes is the per-surah cap shared with Model.js/download.sh.
	DefaultMaxSurahBytes int64 = 314572800
	// DefaultBudgetBytes is the fallback cache pool when the state file carries
	// no cacheLimitMb.
	DefaultBudgetBytes int64 = 500 * 1024 * 1024
	// DefaultMaxConcurrent caps simultaneous origin fetches.
	DefaultMaxConcurrent = 4
)

// Config holds all runtime options. Every value is overridable via a
// QURANPROXY_* environment variable, with a command-line flag taking
// precedence over the environment.
type Config struct {
	Listen        string
	SocketPath    string
	StateFile     string
	StateDir      string
	CacheDir      string
	BudgetBytes   int64 // 0 = derive from state file, then DefaultBudgetBytes
	MaxConcurrent int
	TokenFile     string
	MaxSurahBytes int64
}

func envOr(name, def string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return def
}

func homeDir() string {
	if h := os.Getenv("HOME"); h != "" {
		return h
	}
	if h, err := os.UserHomeDir(); err == nil {
		return h
	}
	return ""
}

// runtimeDir mirrors Service.qml's mpvRuntimeDir: $XDG_RUNTIME_DIR/mus-quran
// when the runtime dir is set, else $HOME/.cache/omarchy/quran/run.
func runtimeDir() string {
	if rt := os.Getenv("XDG_RUNTIME_DIR"); rt != "" {
		return filepath.Join(rt, "mus-quran")
	}
	return filepath.Join(homeDir(), ".cache/omarchy/quran", "run")
}

// Parse builds a Config from the given argument slice (os.Args[1:]).
func Parse(args []string) (*Config, error) {
	home := homeDir()

	cfg := &Config{}
	fs := flag.NewFlagSet("quranproxyd", flag.ContinueOnError)
	fs.StringVar(&cfg.Listen, "listen",
		envOr("QURANPROXY_LISTEN", "127.0.0.1:0"),
		"listen address (loopback only)")
	fs.StringVar(&cfg.StateFile, "state-file",
		envOr("QURANPROXY_STATE_FILE", filepath.Join(home, ".local/state/omarchy/settings/quran.json")),
		"quran.json state file (catalog source; read-only)")
	fs.StringVar(&cfg.StateDir, "state-dir",
		envOr("QURANPROXY_STATE_DIR", filepath.Join(home, ".local/state/omarchy/quran")),
		"explicit download dir (promotion target)")
	fs.StringVar(&cfg.CacheDir, "cache-dir",
		envOr("QURANPROXY_CACHE_DIR", filepath.Join(home, ".cache/omarchy/quran")),
		"streaming cache dir (proxy-owned .dat/.meta.json)")
	fs.Int64Var(&cfg.BudgetBytes, "budget-bytes", 0,
		"cache budget in bytes for proxy-owned files (0 = state file cacheLimitMb, else default)")
	fs.IntVar(&cfg.MaxConcurrent, "max-concurrent", DefaultMaxConcurrent,
		"max concurrent origin fetches")
	fs.StringVar(&cfg.TokenFile, "token-file",
		envOr("QURANPROXY_TOKEN_FILE", filepath.Join(runtimeDir(), "quranproxy.json")),
		"token handoff file written on startup")
	fs.StringVar(&cfg.SocketPath, "socket-path",
		envOr("QURANPROXY_SOCKET_PATH", filepath.Join(runtimeDir(), "quranproxy.sock")),
		"unix socket path for the plugin control-plane (cache readout/clear)")
	fs.Int64Var(&cfg.MaxSurahBytes, "max-surah-bytes", DefaultMaxSurahBytes,
		"per-surah byte cap (0 = default)")
	if err := fs.Parse(args); err != nil {
		return nil, err
	}
	if fs.NArg() > 0 {
		return nil, fmt.Errorf("unexpected positional arguments: %v", fs.Args())
	}

	if cfg.MaxConcurrent < 1 {
		return nil, fmt.Errorf("max-concurrent must be >= 1")
	}
	if cfg.MaxSurahBytes < 1 {
		cfg.MaxSurahBytes = DefaultMaxSurahBytes
	}
	if cfg.BudgetBytes < 0 {
		return nil, fmt.Errorf("budget-bytes must be >= 0")
	}
	return cfg, nil
}
