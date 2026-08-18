package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestCmdRemove(t *testing.T) {
	dir := t.TempDir()
	sub := filepath.Join(dir, "ar.alafasy")
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(sub, "7.mp3")
	if err := os.WriteFile(path, []byte("junk"), 0o644); err != nil {
		t.Fatal(err)
	}

	var out, errOut bytes.Buffer
	code := cmdRemove([]string{"--state-dir", dir, "ar.alafasy", "7"}, &out, &errOut)
	if code != 0 {
		t.Fatalf("code = %d, want 0 (stderr: %s)", code, errOut.String())
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Error("file still on disk after remove")
	}
}

func TestCmdRemoveMissingFileIsOk(t *testing.T) {
	dir := t.TempDir()
	var out, errOut bytes.Buffer
	code := cmdRemove([]string{"--state-dir", dir, "ar.alafasy", "7"}, &out, &errOut)
	if code != 0 {
		t.Fatalf("code = %d, want 0 (stderr: %s)", code, errOut.String())
	}
}

func TestCmdRemoveUsageErrors(t *testing.T) {
	dir := t.TempDir()
	var out, errOut bytes.Buffer
	for _, args := range [][]string{
		{},
		{"--state-dir", dir, "ar.alafasy"},        // missing surah
		{"--state-dir", dir, "../evil", "1"},      // traversal reciter
		{"--state-dir", dir, "ar.alafasy", "0"},   // surah out of range
		{"--state-dir", dir, "ar.alafasy", "115"}, // surah out of range
		{"--state-dir", dir, "ar.alafasy", "http://evil.com"}, // junk surah
	} {
		code := cmdRemove(args, &out, &errOut)
		if code != 2 {
			t.Errorf("args %v: code = %d, want 2", args, code)
		}
	}
}
