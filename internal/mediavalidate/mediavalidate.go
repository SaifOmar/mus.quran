// Package mediavalidate ports the plugin's validate_media.sh gate: a file is
// valid only if it is a regular non-symlink file, non-empty, file(1) reports an
// audio/* or application/octet-stream MIME type, and ffprobe (when installed)
// can parse its duration. Like the script it fails closed: missing file(1) or a
// rejecting ffprobe make Validate return an error.
package mediavalidate

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// fileCmd / ffprobeCmd are the consulted binaries. lookPath and runCommand are
// overridable for tests.
var (
	fileCmd    = "file"
	ffprobeCmd = "ffprobe"

	lookPath   = exec.LookPath
	runCommand = func(name string, args ...string) ([]byte, error) {
		return exec.Command(name, args...).Output()
	}
)

// Validate checks path against the media gate. A nil return means the file is
// safe to promote; any non-nil error describes the failing condition.
func Validate(path string) error {
	li, err := os.Lstat(path)
	if err != nil {
		return fmt.Errorf("mediavalidate: stat: %w", err)
	}
	if li.Mode()&os.ModeSymlink != 0 {
		return errors.New("mediavalidate: symlink rejected")
	}
	fi, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("mediavalidate: stat: %w", err)
	}
	if !fi.Mode().IsRegular() {
		return errors.New("mediavalidate: not a regular file")
	}
	if fi.Size() <= 0 {
		return errors.New("mediavalidate: empty file")
	}

	if _, err := lookPath(fileCmd); err != nil {
		return errors.New("mediavalidate: file(1) unavailable (failing closed)")
	}
	out, err := runCommand(fileCmd, "-b", "--mime-type", path)
	if err != nil {
		return fmt.Errorf("mediavalidate: file(1): %w", err)
	}
	mime := strings.ToLower(strings.TrimSpace(string(out)))
	if !strings.HasPrefix(mime, "audio/") && mime != "application/octet-stream" {
		return fmt.Errorf("mediavalidate: unexpected mime type %q", mime)
	}

	if _, err := lookPath(ffprobeCmd); err != nil {
		return nil // ffprobe absent: skip (matches validate_media.sh)
	}
	if _, err := runCommand(ffprobeCmd, "-v", "error", "-show_entries", "format=duration",
		"-of", "default=noprint_wrappers=1:nokey=1", path); err != nil {
		return fmt.Errorf("mediavalidate: ffprobe rejected the file: %w", err)
	}
	return nil
}
