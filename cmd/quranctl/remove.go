package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"quranproxyd/internal/urlsafety"
)

// defaultStateDir mirrors the daemon's --state-dir default so the binary works
// standalone without flags.
func defaultStateDir() string {
	if h, err := os.UserHomeDir(); err == nil {
		return filepath.Join(h, ".local/state/omarchy/quran")
	}
	return ""
}

// cmdRemove deletes one downloaded surah file from the state dir. Used by the
// plugin after a failed validation: the corrupt file is removed so a retry
// re-fetches clean instead of looping on the same dead file. Fail-closed like
// download: the reciter/surah pair is validated against the same whitelist,
// and the resulting path is always "<stateDir>/<safeId>/<n>.mp3" — a hostile
// argument cannot name a file outside the state dir.
func cmdRemove(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("quranctl remove", flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.Usage = func() {
		fmt.Fprintf(stderr, "usage: quranctl remove [--state-dir <dir>] <reciter> <surah>\n")
	}
	stateDir := fs.String("state-dir", defaultStateDir(), "state dir containing the file")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() != 2 {
		fs.Usage()
		return 2
	}
	id := fs.Arg(0)
	n, ok := urlsafety.ParseSurahArg(fs.Arg(1))
	if !ok || !urlsafety.IsSafeIdentifier(id) {
		fmt.Fprintf(stderr, "remove: invalid reciter or surah\n")
		return 2
	}
	if *stateDir == "" {
		fmt.Fprintf(stderr, "remove: no state dir available\n")
		return 2
	}
	path := filepath.Join(*stateDir, id, fmt.Sprintf("%d.mp3", n))
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		fmt.Fprintf(stderr, "remove: %v\n", err)
		return 1
	}
	return 0
}
