// Package session handles the per-process authentication token and the
// runtime handoff file. The token is a random 32-hex value generated at
// startup and written (0600) to a private runtime dir as quranproxy.json:
//
//	{"port": 49152, "token": "<32 hex>"}
//
// Service.qml reads this file via a FileView to build the mpv URL
// (http://127.0.0.1:<port>/stream?tok=<token>&reciter=...&surah=...). The
// file is created 0600 so only the owner can read it; the proxy binds loopback
// only, so the token is defense-in-depth against local CSRF from other apps.
package session

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// Token is an immutable random secret. Validate uses a constant-time compare.
type Token struct {
	value string
}

// New generates a fresh token (32 hex chars = 128 bits).
func New() (*Token, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return nil, fmt.Errorf("session: generating token: %w", err)
	}
	return &Token{value: hex.EncodeToString(b)}, nil
}

// NewFromString restores a token from its hex form (used in tests).
func NewFromString(v string) *Token {
	return &Token{value: v}
}

// Value returns the token string.
func (t *Token) Value() string {
	return t.value
}

// Validate reports whether given equals the token. Constant-time on equal
// length; length mismatch is rejected outright (both are fixed 32 chars).
func (t *Token) Validate(given string) bool {
	if t == nil || len(given) != len(t.value) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(t.value), []byte(given)) == 1
}

// Handoff is the runtime handoff file payload.
type Handoff struct {
	Port  int    `json:"port"`
	Token string `json:"token"`
	// Sock is the daemon's unix-socket path (control-plane HTTP for the
	// plugin's cache readout/clear). Empty when the socket failed to bind.
	Sock string `json:"sock,omitempty"`
}

// WriteHandoff atomically writes the handoff file (0600) into path, creating
// parent directories with 0700. The rename makes a crash never leave a
// truncated file that Service.qml would misread.
func WriteHandoff(path string, h Handoff) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("session: mkdir %s: %w", dir, err)
	}
	b, err := json.Marshal(h)
	if err != nil {
		return fmt.Errorf("session: marshal handoff: %w", err)
	}
	tmp, err := os.CreateTemp(dir, ".quranproxy-*.tmp")
	if err != nil {
		return fmt.Errorf("session: temp file: %w", err)
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return fmt.Errorf("session: chmod temp: %w", err)
	}
	if _, err := tmp.Write(b); err != nil {
		tmp.Close()
		return fmt.Errorf("session: write handoff: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("session: close handoff: %w", err)
	}
	if err := os.Rename(tmpName, path); err != nil {
		return fmt.Errorf("session: rename handoff: %w", err)
	}
	return nil
}

// ReadHandoff parses a handoff file. A missing file is an error.
func ReadHandoff(path string) (*Handoff, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var h Handoff
	if err := json.Unmarshal(b, &h); err != nil {
		return nil, err
	}
	if h.Port <= 0 || h.Port > 65535 || len(h.Token) != 32 {
		return nil, errors.New("session: malformed handoff")
	}
	return &h, nil
}
