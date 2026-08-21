// paths.go — shared destination-path handling for quranctl commands that
// touch the download root.
package main

import (
	"os"
	"path/filepath"
	"strings"
)

// safeDirPath validates a caller-supplied directory (the plugin's configured
// download root): expands a leading "~/", requires an absolute result, and
// rejects traversal components and control characters anywhere in the input.
// The cleaned path is returned; ok is false when any rule fails.
func safeDirPath(p string) (string, bool) {
	if strings.HasPrefix(p, "~/") {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", false
		}
		p = filepath.Join(home, p[2:])
	}
	if p == "" || !filepath.IsAbs(p) {
		return "", false
	}
	for i := 0; i < len(p); i++ {
		c := p[i]
		if c < 32 || c == 127 {
			return "", false
		}
	}
	for _, part := range strings.Split(p, "/") {
		if part == ".." {
			return "", false
		}
	}
	return filepath.Clean(p), true
}
