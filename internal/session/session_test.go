package session

import (
	"os"
	"path/filepath"
	"testing"
)

func TestTokenGenerateValidate(t *testing.T) {
	tok, err := New()
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if len(tok.Value()) != 32 {
		t.Fatalf("token length = %d, want 32", len(tok.Value()))
	}
	if !tok.Validate(tok.Value()) {
		t.Error("Validate(own value) = false")
	}
	if tok.Validate("") {
		t.Error("Validate(empty) = true")
	}
	if tok.Validate("x") {
		t.Error("Validate(short) = true")
	}
	if tok.Validate("ffffffffffffffffffffffffffffffff") {
		t.Error("Validate(different token) = true")
	}
	var nilTok *Token
	if nilTok.Validate("anything") {
		t.Error("Validate(nil receiver) = true")
	}
}

func TestTokenUniqueness(t *testing.T) {
	a, _ := New()
	b, _ := New()
	if a.Value() == b.Value() {
		t.Error("two tokens identical")
	}
}

func TestHandoffRoundTrip(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "run", "quranproxy.json")
	h := Handoff{Port: 49152, Token: "0123456789abcdef0123456789abcdef"}
	if err := WriteHandoff(path, h); err != nil {
		t.Fatalf("WriteHandoff: %v", err)
	}
	got, err := ReadHandoff(path)
	if err != nil {
		t.Fatalf("ReadHandoff: %v", err)
	}
	if got.Port != h.Port || got.Token != h.Token {
		t.Errorf("roundtrip = %+v, want %+v", got, h)
	}
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0o600 {
		t.Errorf("handoff mode = %o, want 600", fi.Mode().Perm())
	}
}

func TestReadHandoffMalformed(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "quranproxy.json")
	if _, err := ReadHandoff(path); err == nil {
		t.Error("ReadHandoff(missing) did not error")
	}
	if err := os.WriteFile(path, []byte(`{"port":0,"token":"xx"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadHandoff(path); err == nil {
		t.Error("ReadHandoff(malformed) did not error")
	}
}
