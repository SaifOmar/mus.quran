// download.go — `quranctl download`, the replacement for download.sh.
//
// Usage:
//
//	quranctl download <reciter> <n> [--server URL] [--dest-root DIR]
//	quranctl download <reciter> --only a,b,c [--server URL] [--dest-root DIR]
//
// The origin URL is built and validated in-process via urlsafety.AudioURL —
// the caller-supplied --server is convenience only and is NEVER trusted; an
// invalid URL fails the surah before any dial.
//
// Stdout contract (consumed by Service.qml):
// `progress_bytes P/100` during a transfer, `surah_done <n>` after each surah
// is present on disk (fresh fetch or already-complete skip), `surah_failed <n>`
// after each failed one, `progress DONE/TOTAL` as a running tally, and
// `complete DONE FAILED` at the end. `failed <n>: reason` detail goes to
// stderr. Exit 0 = all surahs present, 1 = at least one failed, 2 = usage,
// 130 = interrupted.
//
// Files land at <dest-root>/<reciter>/<n>.mp3 where <dest-root> is --dest-root
// when given, else ~/.local/state/omarchy/quran.
package main

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"

	"quranproxyd/internal/dialer"
	"quranproxyd/internal/fetch"
	"quranproxyd/internal/urlsafety"
)

func cmdDownload(args []string) int {
	return cmdDownloadIO(args, os.Stdout, os.Stderr)
}

// buildOriginURL is the production origin-URL builder: the final URL is
// constructed and validated by urlsafety.AudioURL (the daemon's exact
// function). A caller-supplied --server is convenience only — never trusted.
// Tests replace this to point at an httptest origin.
var buildOriginURL = func(reciter string, server *string) func(n int) (string, error) {
	return func(n int) (string, error) {
		u := urlsafety.AudioURL(reciter, n, server)
		if u == "" {
			return "", fmt.Errorf("invalid origin URL for %s:%d", reciter, n)
		}
		return u, nil
	}
}

// newDownloadClient is the production outbound client (DNS-pinned,
// redirect-rejecting). Tests replace it with a plain client for httptest
// origins.
var newDownloadClient = func() *http.Client {
	return dialer.NewClient(dialer.DefaultResolver)
}

func cmdDownloadIO(args []string, stdout, stderr io.Writer) int {
	reciter, surahs, server, destRoot, err := parseDownloadArgs(args, stderr)
	if err != nil {
		return 2
	}

	stateRoot := defaultStateDir()
	if destRoot != nil {
		clean, ok := safeDirPath(*destRoot)
		if !ok {
			fmt.Fprintf(stderr, "quranctl: invalid --dest-root path\n")
			return 2
		}
		stateRoot = clean
	}
	if stateRoot == "" {
		fmt.Fprintln(stderr, "quranctl: no destination root available (set HOME or --dest-root)")
		return 2
	}

	client := newDownloadClient()
	buildURL := buildOriginURL(reciter, server)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	done, failed := 0, 0
	total := len(surahs)
	for _, n := range surahs {
		if ctx.Err() != nil {
			return 130
		}
		onProgress := func(written, remote int64) {
			pct := int64(0)
			if remote > 0 {
				pct = written * 100 / remote
			}
			if pct > 100 {
				pct = 100
			}
			fmt.Fprintf(stdout, "progress_bytes %d/100\n", pct)
		}
		err := fetch.Fetch(ctx, fetch.Options{
			Client:     client,
			URL:        buildURL,
			DestRoot:   stateRoot,
			Reciter:    reciter,
			Surah:      n,
			OnProgress: onProgress,
		})
		if err == fetch.ErrComplete {
			done++
			fmt.Fprintf(stdout, "surah_done %d\n", n)
			fmt.Fprintf(stdout, "progress %d/%d\n", done, total)
			continue
		}
		if err != nil {
			if ctx.Err() != nil {
				// Interrupted (SIGINT/SIGTERM): match download.sh's exit 130
				// without a trailing complete line.
				return 130
			}
			failed++
			fmt.Fprintf(stdout, "surah_failed %d\n", n)
			fmt.Fprintf(stderr, "failed %d: %v\n", n, err)
			continue
		}
		done++
		fmt.Fprintf(stdout, "surah_done %d\n", n)
		fmt.Fprintf(stdout, "progress %d/%d\n", done, total)
	}

	fmt.Fprintf(stdout, "complete %d %d\n", done, failed)
	if failed == 0 {
		return 0
	}
	return 1
}

// parseDownloadArgs validates the command line and returns the reciter, the
// ordered surah work set, the optional --server prefix, and the optional
// --dest-root override. Usage errors are printed to stderr and returned as err.
func parseDownloadArgs(args []string, stderr io.Writer) (string, []int, *string, *string, error) {
	var positionals []string
	var only string
	var server *string
	var destRoot *string
	i := 0
	for i < len(args) {
		switch args[i] {
		case "--only":
			if i+1 >= len(args) {
				fmt.Fprintln(stderr, "usage: quranctl download <reciter> <n>|--only a,b,c [--server URL] [--dest-root DIR]")
				return "", nil, nil, nil, fmt.Errorf("missing --only value")
			}
			only = args[i+1]
			i += 2
		case "--server":
			if i+1 >= len(args) {
				fmt.Fprintln(stderr, "usage: quranctl download <reciter> <n>|--only a,b,c [--server URL] [--dest-root DIR]")
				return "", nil, nil, nil, fmt.Errorf("missing --server value")
			}
			v := args[i+1]
			server = &v
			i += 2
		case "--dest-root":
			if i+1 >= len(args) {
				fmt.Fprintln(stderr, "usage: quranctl download <reciter> <n>|--only a,b,c [--server URL] [--dest-root DIR]")
				return "", nil, nil, nil, fmt.Errorf("missing --dest-root value")
			}
			v := args[i+1]
			destRoot = &v
			i += 2
		default:
			positionals = append(positionals, args[i])
			i++
		}
	}
	if len(positionals) == 0 {
		fmt.Fprintln(stderr, "usage: quranctl download <reciter> <n>|--only a,b,c [--server URL] [--dest-root DIR]")
		return "", nil, nil, nil, fmt.Errorf("missing reciter")
	}
	reciter := positionals[0]
	if !urlsafety.IsSafeIdentifier(reciter) {
		fmt.Fprintln(stderr, "quranctl: invalid reciter identifier")
		return "", nil, nil, nil, fmt.Errorf("invalid reciter")
	}
	if server != nil && urlsafety.SanitizeServer(*server) == "" {
		fmt.Fprintln(stderr, "quranctl: invalid --server URL")
		return "", nil, nil, nil, fmt.Errorf("invalid server")
	}

	var surahs []int
	if only != "" {
		// --only wins over a positional n (download.sh precedence).
		for _, raw := range strings.Split(only, ",") {
			raw = strings.TrimSpace(raw)
			if raw == "" {
				continue
			}
			n, err := strconv.Atoi(raw)
			if err != nil || n < 1 || n > 114 {
				fmt.Fprintln(stderr, "quranctl: invalid surah number:", raw)
				return "", nil, nil, nil, fmt.Errorf("invalid surah")
			}
			surahs = append(surahs, n)
		}
		if len(surahs) == 0 {
			fmt.Fprintln(stderr, "usage: quranctl download <reciter> <n>|--only a,b,c [--server URL] [--dest-root DIR]")
			return "", nil, nil, nil, fmt.Errorf("empty only list")
		}
	} else if len(positionals) >= 2 {
		n, err := strconv.Atoi(positionals[1])
		if err != nil || n < 1 || n > 114 {
			fmt.Fprintln(stderr, "quranctl: invalid surah number:", positionals[1])
			return "", nil, nil, nil, fmt.Errorf("invalid surah")
		}
		surahs = []int{n}
	} else {
		fmt.Fprintln(stderr, "usage: quranctl download <reciter> <n>|--only a,b,c [--server URL] [--dest-root DIR]")
		return "", nil, nil, nil, fmt.Errorf("missing surah")
	}
	return reciter, surahs, server, destRoot, nil
}
