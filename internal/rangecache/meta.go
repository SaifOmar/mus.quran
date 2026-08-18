package rangecache

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// Meta is the sidecar persisted next to each <surah>.dat. fetched_ranges is a
// sorted, coalesced list of half-open intervals. Invariant: the sidecar never
// claims bytes that were not fsynced to the .dat file (WriteRange flushes data
// before persisting the merged intervals).
type Meta struct {
	Size        int64     `json:"size"`
	ContentType string    `json:"content_type"`
	ETag        string    `json:"etag,omitempty"`
	UpdatedAt   int64     `json:"updated_at"`
	Fetched     Intervals `json:"fetched_ranges"`
}

// LoadMeta reads the sidecar at path. A missing file returns an empty Meta
// (nil error). A corrupt file is an error so the caller can decide (the entry
// is treated as empty).
func LoadMeta(path string) (*Meta, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return &Meta{}, nil
		}
		return nil, err
	}
	var m Meta
	if err := json.Unmarshal(b, &m); err != nil {
		return nil, fmt.Errorf("rangecache: corrupt sidecar %s: %w", path, err)
	}
	return &m, nil
}

// SaveMeta atomically persists the sidecar (temp + rename) so a crash never
// leaves a truncated sidecar that would claim bogus ranges.
func SaveMeta(path string, m *Meta) error {
	dir := filepath.Dir(path)
	b, err := json.Marshal(m)
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".meta-*.tmp")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if _, err := tmp.Write(b); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, path)
}
