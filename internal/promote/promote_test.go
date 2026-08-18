package promote

import (
	"os"
	"path/filepath"
	"testing"
)

func TestPromote(t *testing.T) {
	src := filepath.Join(t.TempDir(), "1.dat")
	if err := os.WriteFile(src, []byte("hello-mp3-bytes"), 0o600); err != nil {
		t.Fatal(err)
	}
	dst := t.TempDir()
	if err := Promote(src, dst, "ar.alafasy", 7); err != nil {
		t.Fatalf("Promote = %v", err)
	}
	got, err := os.ReadFile(filepath.Join(dst, "ar.alafasy", "7.mp3"))
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "hello-mp3-bytes" {
		t.Fatalf("content = %q", got)
	}
	fi, err := os.Stat(filepath.Join(dst, "ar.alafasy", "7.mp3"))
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode()&0o777 != 0o600 {
		t.Errorf("target mode = %v, want 0600", fi.Mode())
	}
	if _, err := os.Stat(src); err != nil {
		t.Errorf("source must be preserved (caller deletes cache): %v", err)
	}
}

func TestPromoteOverwritesExisting(t *testing.T) {
	src := filepath.Join(t.TempDir(), "1.dat")
	if err := os.WriteFile(src, []byte("new"), 0o600); err != nil {
		t.Fatal(err)
	}
	dst := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dst, "ar.alafasy"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dst, "ar.alafasy", "7.mp3"), []byte("old"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := Promote(src, dst, "ar.alafasy", 7); err != nil {
		t.Fatalf("Promote = %v", err)
	}
	got, _ := os.ReadFile(filepath.Join(dst, "ar.alafasy", "7.mp3"))
	if string(got) != "new" {
		t.Fatalf("content = %q, want new", got)
	}
}

func TestPromoteRejectsBadReciter(t *testing.T) {
	src := filepath.Join(t.TempDir(), "1.dat")
	os.WriteFile(src, []byte("x"), 0o600)
	for _, rec := range []string{"..", ".", "a/b", "", "very-long-very-long-very-long-very-long-very-long-very-long-very-long-very-long-very-long-1"} {
		if err := Promote(src, t.TempDir(), rec, 1); err == nil {
			t.Errorf("Promote(reciter=%q) = nil, want error", rec)
		}
	}
}

func TestPromoteRejectsBadSurah(t *testing.T) {
	src := filepath.Join(t.TempDir(), "1.dat")
	os.WriteFile(src, []byte("x"), 0o600)
	for _, n := range []int{0, 115, 114} {
		err := Promote(src, t.TempDir(), "ar.alafasy", n)
		if n == 114 && err != nil {
			t.Errorf("Promote(surah 114) = %v, want nil", err)
		}
		if n != 114 && err == nil {
			t.Errorf("Promote(surah %d) = nil, want error", n)
		}
	}
}

func TestPromoteRejectsSymlinkSource(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "real.dat")
	os.WriteFile(src, []byte("x"), 0o600)
	link := filepath.Join(dir, "link.dat")
	if err := os.Symlink(src, link); err != nil {
		t.Fatal(err)
	}
	if err := Promote(link, t.TempDir(), "ar.alafasy", 1); err == nil {
		t.Fatal("Promote(symlink source) = nil, want error")
	}
}

func TestPromoteRejectsTraversalRoot(t *testing.T) {
	src := filepath.Join(t.TempDir(), "1.dat")
	os.WriteFile(src, []byte("x"), 0o600)
	if err := Promote(src, "/tmp/../etc", "ar.alafasy", 1); err == nil {
		t.Fatal("Promote(.. in root) = nil, want error")
	}
}

func TestPromoteCreatesMissingRoot(t *testing.T) {
	src := filepath.Join(t.TempDir(), "1.dat")
	os.WriteFile(src, []byte("x"), 0o600)
	dst := filepath.Join(t.TempDir(), "deep", "nested", "state")
	if err := Promote(src, dst, "ar.alafasy", 1); err != nil {
		t.Fatalf("Promote(missing root) = %v, want creation", err)
	}
	if _, err := os.Stat(filepath.Join(dst, "ar.alafasy", "1.mp3")); err != nil {
		t.Errorf("promoted file missing: %v", err)
	}
}

func TestPromoteRejectsSymlinkedReciterDir(t *testing.T) {
	src := filepath.Join(t.TempDir(), "1.dat")
	os.WriteFile(src, []byte("x"), 0o600)
	dst := t.TempDir()
	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(dst, "evil")); err != nil {
		t.Fatal(err)
	}
	if err := Promote(src, dst, "evil", 1); err == nil {
		t.Fatal("Promote(symlinked reciter dir) = nil, want escape rejection")
	}
}
