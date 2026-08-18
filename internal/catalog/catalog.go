// Package catalog loads and validates the plugin's persisted state file
// (~/.local/state/omarchy/settings/quran.json), which doubles as the audio
// catalog for the proxy: reciters[] carries the per-reciter `server` prefixes
// that determine origin URLs. The proxy READS this file and never writes it
// (Service.qml owns it via FileView + atomic writes; two writers would race).
package catalog

import (
	"encoding/json"
	"os"
	"sync"

	"quranproxyd/internal/urlsafety"
)

const (
	// maxReciters caps the catalog size (Model.parseReciters cap).
	maxReciters = 1000
	// maxNameLen caps reciter display names (Model.parseReciters).
	maxNameLen = 200
	// defaultBudgetBytes is the fallback cache pool when cacheLimitMb is unset.
	defaultBudgetBytes int64 = 500 * 1024 * 1024
)

// Reciter is one entry of the persisted reciters[] array.
type Reciter struct {
	Identifier  string   `json:"identifier"`
	ID          string   `json:"id"`
	Name        string   `json:"name"`
	EnglishName string   `json:"englishName"`
	Server      *string  `json:"server"`
	Levels      []string `json:"audioLevels"`
}

// State mirrors the persisted quran.json structure. Only the fields the proxy
// consumes are modeled.
type State struct {
	Version         int              `json:"version"`
	Language        string           `json:"language"`
	ReciterID       string           `json:"reciterId"`
	SurahNumber     int              `json:"surahNumber"`
	PlaybackMode    string           `json:"playbackMode"`
	Position        int64            `json:"position"`
	WasPlaying      bool             `json:"wasPlaying"`
	CacheLimitMb    int              `json:"cacheLimitMb"`
	CacheLastPlayed map[string]int64 `json:"cacheLastPlayed"`
	Reciters        []Reciter        `json:"reciters"`
}

// Load reads and validates the state file. A malformed file is an error; a
// well-formed file with hostile entries keeps only the valid ones (see
// Sanitize).
func Load(path string) (*State, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var s State
	if err := json.Unmarshal(b, &s); err != nil {
		return nil, err
	}
	s.Sanitize()
	return &s, nil
}

// Sanitize filters reciters through the same policy Model.parseReciters uses:
// safe identifier, safe server prefix when present, name length <= 200, cap at
// 1000. Entries that fail are dropped so a hostile catalog can never point the
// proxy at a non-allowlisted origin.
func (s *State) Sanitize() {
	out := make([]Reciter, 0, len(s.Reciters))
	for _, r := range s.Reciters {
		if len(out) >= maxReciters {
			break
		}
		if len(r.Name) > maxNameLen || len(r.EnglishName) > maxNameLen {
			continue
		}
		if !urlsafety.IsSafeReciter(r.Identifier, r.Server) {
			continue
		}
		out = append(out, r)
	}
	s.Reciters = out
}

// Reciter returns the catalog entry for identifier, if present.
func (s *State) Reciter(id string) (*Reciter, bool) {
	for i := range s.Reciters {
		if s.Reciters[i].Identifier == id {
			return &s.Reciters[i], true
		}
	}
	return nil, false
}

// AudioURL builds the origin URL for identifier/surah, using the reciter's
// server prefix when present (padded NNN.mp3) and the default CDN template
// otherwise (unpadded N.mp3). The final URL is guarded by the ported URL
// policy (urlsafety.AudioURL).
func (s *State) AudioURL(identifier string, n int) string {
	var server *string
	if r, ok := s.Reciter(identifier); ok {
		server = r.Server
	}
	return urlsafety.AudioURL(identifier, n, server)
}

// BudgetBytes returns the shared cache pool size: cacheLimitMb from the state
// file when set, else the default (500 MB). The proxy enforces this against
// its own .dat/.meta.json bytes; legacy .mp3 bytes are accounted separately by
// cache.sh and combined in Service.qml.
func (s *State) BudgetBytes() int64 {
	if s.CacheLimitMb > 0 {
		return int64(s.CacheLimitMb) * 1024 * 1024
	}
	return defaultBudgetBytes
}

// Store is a concurrency-safe holder for a reloadable State. The proxy loads
// it at startup and swaps in a fresh State on fsnotify reload.
type Store struct {
	mu    sync.RWMutex
	state *State
}

// NewStore wraps an initial State.
func NewStore(s *State) *Store {
	return &Store{state: s}
}

// Get returns the current State.
func (st *Store) Get() *State {
	st.mu.RLock()
	defer st.mu.RUnlock()
	return st.state
}

// Set swaps in a new State.
func (st *Store) Set(s *State) {
	st.mu.Lock()
	defer st.mu.Unlock()
	st.state = s
}

// LoadStore loads a State from path and wraps it in a Store.
func LoadStore(path string) (*Store, error) {
	s, err := Load(path)
	if err != nil {
		return nil, err
	}
	return NewStore(s), nil
}
