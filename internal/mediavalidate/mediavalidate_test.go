package mediavalidate

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeEnv points lookPath and runCommand at scripted commands.
func fakeEnv(t *testing.T, haveFile, haveFFprobe bool, fileOut, ffprobeOut string, fileErr, ffprobeErr error) {
	t.Helper()
	oldLook, oldRun := lookPath, runCommand
	lookPath = func(name string) (string, error) {
		switch name {
		case fileCmd:
			if haveFile {
				return "/usr/bin/file", nil
			}
			return "", os.ErrNotExist
		case ffprobeCmd:
			if haveFFprobe {
				return "/usr/bin/ffprobe", nil
			}
			return "", os.ErrNotExist
		}
		return "", os.ErrNotExist
	}
	runCommand = func(name string, args ...string) ([]byte, error) {
		switch name {
		case fileCmd:
			return []byte(fileOut), fileErr
		case ffprobeCmd:
			return []byte(ffprobeOut), ffprobeErr
		}
		return nil, os.ErrNotExist
	}
	t.Cleanup(func() { lookPath, runCommand = oldLook, oldRun })
}

func writeFile(t *testing.T, content []byte) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "audio.dat")
	if err := os.WriteFile(p, content, 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestValidatePass(t *testing.T) {
	fakeEnv(t, true, true, "audio/mpeg", "123.4\n", nil, nil)
	if err := Validate(writeFile(t, []byte("ID3\x04\x00"))); err != nil {
		t.Fatalf("Validate = %v, want nil", err)
	}
}

func TestValidateOctetStreamPass(t *testing.T) {
	fakeEnv(t, true, false, "application/octet-stream", "", nil, nil)
	if err := Validate(writeFile(t, []byte("MPEG"))); err != nil {
		t.Fatalf("Validate = %v, want nil", err)
	}
}

func TestValidateBadMime(t *testing.T) {
	fakeEnv(t, true, false, "text/html", "", nil, nil)
	if err := Validate(writeFile(t, []byte("<html>"))); err == nil {
		t.Fatal("Validate = nil, want error for text/html")
	}
}

func TestValidateFileMissingFailsClosed(t *testing.T) {
	fakeEnv(t, false, false, "", "", nil, nil)
	if err := Validate(writeFile(t, []byte("x"))); err == nil {
		t.Fatal("Validate = nil, want error when file(1) absent")
	}
}

func TestValidateFFprobeRejects(t *testing.T) {
	fakeEnv(t, true, true, "audio/mpeg", "", nil, errors.New("exit status 1"))
	if err := Validate(writeFile(t, []byte("ID3"))); err == nil {
		t.Fatal("Validate = nil, want error when ffprobe rejects")
	}
}

func TestValidateSymlink(t *testing.T) {
	fakeEnv(t, true, false, "audio/mpeg", "", nil, nil)
	dir := t.TempDir()
	src := filepath.Join(dir, "real.dat")
	if err := os.WriteFile(src, []byte("ID3"), 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "link.dat")
	if err := os.Symlink(src, link); err != nil {
		t.Fatal(err)
	}
	if err := Validate(link); err == nil || !strings.Contains(err.Error(), "symlink") {
		t.Fatalf("Validate(symlink) = %v, want symlink rejection", err)
	}
}

func TestValidateEmpty(t *testing.T) {
	fakeEnv(t, true, false, "audio/mpeg", "", nil, nil)
	if err := Validate(writeFile(t, nil)); err == nil {
		t.Fatal("Validate = nil, want error for empty file")
	}
}

func TestValidateMissingFile(t *testing.T) {
	fakeEnv(t, true, false, "audio/mpeg", "", nil, nil)
	if err := Validate(filepath.Join(t.TempDir(), "nope.dat")); err == nil {
		t.Fatal("Validate = nil, want error for missing file")
	}
}
