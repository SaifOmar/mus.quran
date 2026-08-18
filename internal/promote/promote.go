// Package promote moves a fully-fetched cache .dat into the explicit download
// tree as <dstRoot>/<reciter>/<n>.mp3, atomically (temp file in the target
// directory + fsync + rename), with the same path/symlink guards cache.sh
// promote uses. The source must be a regular non-symlink file. The caller
// deletes the cache entry after a successful promote.
package promote

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// reciterRE mirrors cache.sh check_reciter.
var reciterRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*$`)

const copyBuf = 256 * 1024

// Promote copies src into dstRoot/reciter/n.mp3. dstRoot must be an absolute,
// existing directory whose canonical path is itself (no ".." components); the
// reciter subdirectory is created and verified to resolve directly under
// dstRoot so a planted symlink cannot redirect the write outside the state
// tree.
func Promote(src, dstRoot string, reciter string, n int) error {
	if len(reciter) == 0 || len(reciter) > 64 || reciter == "." || reciter == ".." ||
		!reciterRE.MatchString(reciter) {
		return errors.New("promote: invalid reciter identifier")
	}
	if n < 1 || n > 114 {
		return errors.New("promote: surah out of range")
	}
	if !filepath.IsAbs(dstRoot) || strings.Contains(dstRoot, "..") {
		return errors.New("promote: invalid destination root")
	}
	// The state root is created on demand (fresh installs have none yet) and
	// canonicalized so all writes happen under the resolved root.
	if err := os.MkdirAll(dstRoot, 0o700); err != nil {
		return fmt.Errorf("promote: mkdir destination root: %w", err)
	}
	root, err := filepath.EvalSymlinks(dstRoot)
	if err != nil {
		return fmt.Errorf("promote: resolve destination root: %w", err)
	}
	fi, err := os.Stat(root)
	if err != nil {
		return fmt.Errorf("promote: destination root: %w", err)
	}
	if !fi.IsDir() {
		return errors.New("promote: destination root is not a directory")
	}

	// Source guards: only regular non-symlink files are promoted.
	li, err := os.Lstat(src)
	if err != nil {
		return fmt.Errorf("promote: source: %w", err)
	}
	if li.Mode()&os.ModeSymlink != 0 {
		return errors.New("promote: source is a symlink")
	}
	sf, err := os.Stat(src)
	if err != nil {
		return fmt.Errorf("promote: source: %w", err)
	}
	if !sf.Mode().IsRegular() {
		return errors.New("promote: source is not a regular file")
	}
	if sf.Size() <= 0 {
		return errors.New("promote: source is empty")
	}

	recDir := filepath.Join(root, reciter)
	if err := os.MkdirAll(recDir, 0o700); err != nil {
		return fmt.Errorf("promote: mkdir: %w", err)
	}
	// Verify the created directory resolves exactly under the canonical root
	// (rejects a symlinked reciter dir escaping the state tree).
	if real, err := filepath.EvalSymlinks(recDir); err != nil || real != filepath.Join(root, reciter) {
		return errors.New("promote: reciter directory escapes destination root")
	}

	target := filepath.Join(recDir, fmt.Sprintf("%d.mp3", n))
	in, err := os.Open(src)
	if err != nil {
		return fmt.Errorf("promote: open source: %w", err)
	}
	defer in.Close()

	tmp, err := os.CreateTemp(recDir, ".promote-*")
	if err != nil {
		return fmt.Errorf("promote: temp file: %w", err)
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName) // no-op after successful rename

	if _, err := io.CopyBuffer(tmp, in, make([]byte, copyBuf)); err != nil {
		tmp.Close()
		return fmt.Errorf("promote: copy: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return fmt.Errorf("promote: sync: %w", err)
	}
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return fmt.Errorf("promote: chmod: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("promote: close: %w", err)
	}
	if err := os.Rename(tmpName, target); err != nil {
		return fmt.Errorf("promote: rename: %w", err)
	}
	return nil
}
