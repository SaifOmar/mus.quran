// quranproxyd is a local HTTP proxy that lets the mus.quran plugin stream
// surah audio through a validated, DNS-pinned, range-caching pipeline instead
// of direct CDN access.
//
// M1: passthrough — validate the request against the catalog, build a safe
// origin URL, fetch it via a DNS-pinned redirect-rejecting client, and stream
// the body through (no caching). Writes the runtime handoff file
// (quranproxy.json) with the port and session token so Service.qml can target
// mpv at http://127.0.0.1:<port>/stream?tok=...
package main

import (
	"context"
	"flag"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"quranproxyd/internal/catalog"
	"quranproxyd/internal/config"
	"quranproxyd/internal/dialer"
	"quranproxyd/internal/proxyhandler"
	"quranproxyd/internal/rangecache"
	"quranproxyd/internal/session"
)

func main() {
	cfg, err := config.Parse(os.Args[1:])
	if err != nil {
		if err == flag.ErrHelp {
			os.Exit(0)
		}
		log.Fatalf("config: %v", err)
	}

	logger := log.New(os.Stderr, "quranproxyd: ", log.LstdFlags)

	store, err := catalog.LoadStore(cfg.StateFile)
	if err != nil {
		if os.IsNotExist(err) {
			// First run: the plugin has not written quran.json yet. Serve with
			// an empty catalog; watchStateFile picks the real one up the moment
			// it appears.
			logger.Printf("catalog: %v (starting empty; waiting for the plugin state file)", err)
			store = catalog.NewStore(&catalog.State{})
		} else {
			logger.Fatalf("catalog: %v", err)
		}
	}
	state := store.Get()

	budget := cfg.BudgetBytes
	if budget == 0 {
		budget = state.BudgetBytes()
	}

	tok, err := session.New()
	if err != nil {
		logger.Fatalf("session: %v", err)
	}

	client := dialer.NewClient(dialer.DefaultResolver)
	cache := rangecache.New(cfg.CacheDir, budget)
	h := proxyhandler.New(store, client, tok, cache, cfg.MaxConcurrent, cfg.MaxSurahBytes)
	h.SetLogger(logger)
	h.EnablePromotion(cfg.StateDir)

	// The plugin owns quran.json (FileView + atomic writes) and may fetch a
	// fresh reciter catalog after we start. Poll for changes and swap in the
	// new State + budget so a first-run daemon catches up without a restart.
	watchStateFile(store, cache, cfg.StateFile, cfg.BudgetBytes, logger)

	ln, err := net.Listen("tcp", cfg.Listen)
	if err != nil {
		logger.Fatalf("listen %s: %v", cfg.Listen, err)
	}
	// Bind is loopback-only by default; refuse otherwise.
	addr := ln.Addr().(*net.TCPAddr)
	if !addr.IP.IsLoopback() && !addr.IP.IsUnspecified() {
		ln.Close()
		logger.Fatalf("refusing non-loopback listen address %s", cfg.Listen)
	}

	port := addr.Port
	if err := session.WriteHandoff(cfg.TokenFile, session.Handoff{Port: port, Token: tok.Value(), Sock: cfg.SocketPath}); err != nil {
		ln.Close()
		logger.Fatalf("handoff: %v", err)
	}
	defer os.Remove(cfg.TokenFile)

	srv := &http.Server{Handler: h.Routes()}
	sockSrv := &http.Server{Handler: h.Routes()}

	// Control-plane unix socket: the plugin speaks raw HTTP over QLocalSocket
	// (the mpv pattern) for /cache/usage and /api/cache/clear — no curl, no
	// new external processes. The socket sits in the 0700 runtime dir, so
	// only this user can reach it.
	var sockLn net.Listener
	if cfg.SocketPath != "" {
		if err := os.MkdirAll(filepath.Dir(cfg.SocketPath), 0o700); err != nil {
			logger.Fatalf("socket dir: %v", err)
		}
		os.Remove(cfg.SocketPath) // stale socket from a crashed daemon
		sockLn, err = net.Listen("unix", cfg.SocketPath)
		if err != nil {
			logger.Fatalf("listen %s: %v", cfg.SocketPath, err)
		}
		if err := os.Chmod(cfg.SocketPath, 0o600); err != nil {
			sockLn.Close()
			logger.Fatalf("socket chmod: %v", err)
		}
		defer os.Remove(cfg.SocketPath)
	}

	// Graceful shutdown: stop accepting, cancel in-flight requests, then exit.
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		<-stop
		logger.Printf("shutting down")
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		srv.Shutdown(ctx)
		if sockLn != nil {
			sockSrv.Shutdown(ctx)
		}
	}()

	logger.Printf("listening on 127.0.0.1:%d (budget=%d bytes, %d reciters, max-concurrent=%d)",
		port, budget, len(state.Reciters), cfg.MaxConcurrent)

	// A socket serve error is non-fatal: the plugin's cache readout/clear
	// simply falls back to keeping its last value. Never block main's exit on
	// it — shutdown is driven by srv.Shutdown above.
	if sockLn != nil {
		go func() {
			if err := sockSrv.Serve(sockLn); err != nil && err != http.ErrServerClosed {
				logger.Printf("socket serve: %v", err)
			}
		}()
	}

	if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
		logger.Fatalf("serve: %v", err)
	}
}

// watchStateFile polls path for changes and swaps the catalog State (and cache
// budget when it is derived from the state file) on every modification. A
// malformed or missing file is logged and ignored (the last good State stays).
func watchStateFile(store *catalog.Store, cache *rangecache.Cache, path string, explicitBudget int64, logger *log.Logger) {
	var lastMod, lastSize int64
	go func() {
		var lastReciters int
		t := time.NewTicker(2 * time.Second)
		defer t.Stop()
		for range t.C {
			fi, err := os.Stat(path)
			if err != nil {
				continue
			}
			if fi.ModTime().UnixNano() == lastMod && fi.Size() == lastSize {
				continue
			}
			lastMod, lastSize = fi.ModTime().UnixNano(), fi.Size()
			s, err := catalog.Load(path)
			if err != nil {
				if !os.IsNotExist(err) {
					logger.Printf("catalog reload: %v", err)
				}
				continue
			}
			if explicitBudget == 0 {
				if b := s.BudgetBytes(); b != cache.Budget() {
					cache.SetBudget(b)
					logger.Printf("budget updated to %d bytes", b)
				}
			}
			store.Set(s)
			// The plugin rewrites the state file on every saveState; only log
			// when the catalog itself actually changed.
			if n := len(s.Reciters); n != lastReciters {
				lastReciters = n
				logger.Printf("catalog updated: %d reciters", n)
			}
		}
	}()
}
