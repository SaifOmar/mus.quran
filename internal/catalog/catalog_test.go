package catalog

import (
	"path/filepath"
	"testing"
)

const testState = "testdata/quran_state.json"

func TestLoadSanitize(t *testing.T) {
	s, err := Load(filepath.Join("..", "..", testState))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	// 6 entries in the fixture; hostile/traversal/overlong must be dropped.
	if len(s.Reciters) != 3 {
		t.Fatalf("len(Reciters) = %d, want 3 (hostile/traversal/overlong dropped)", len(s.Reciters))
	}
	seen := map[string]bool{}
	for _, r := range s.Reciters {
		seen[r.Identifier] = true
	}
	for _, id := range []string{"mp3quran_49", "ar.alafasy", "mp3quran_51"} {
		if !seen[id] {
			t.Errorf("reciter %q missing after sanitize", id)
		}
	}
	for _, id := range []string{"hostile", "../x", "toolong"} {
		if seen[id] {
			t.Errorf("reciter %q survived sanitize", id)
		}
	}
}

func TestReciterLookup(t *testing.T) {
	s, err := Load(filepath.Join("..", "..", testState))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if _, ok := s.Reciter("ar.alafasy"); !ok {
		t.Error("Reciter(ar.alafasy) not found")
	}
	if _, ok := s.Reciter("nope"); ok {
		t.Error("Reciter(nope) found")
	}
	if _, ok := s.Reciter("hostile"); ok {
		t.Error("Reciter(hostile) survived sanitize")
	}
}

func TestAudioURLShapes(t *testing.T) {
	s, err := Load(filepath.Join("..", "..", testState))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	// server-based reciter: padded NNN.mp3 on its own prefix
	if got := s.AudioURL("mp3quran_49", 1); got != "https://server6.mp3quran.net/thubti/001.mp3" {
		t.Errorf("AudioURL(server reciter, surah 1) = %q", got)
	}
	if got := s.AudioURL("mp3quran_49", 114); got != "https://server6.mp3quran.net/thubti/114.mp3" {
		t.Errorf("AudioURL(server reciter, surah 114) = %q", got)
	}
	// default-CDN reciter: unpadded N.mp3
	if got := s.AudioURL("ar.alafasy", 1); got != "https://cdn.islamic.app/quran/audio-surah/ar.alafasy/1.mp3" {
		t.Errorf("AudioURL(default reciter) = %q", got)
	}
	// unknown reciter falls back to default-CDN template with safe identifier
	if got := s.AudioURL("ar.ajamy", 1); got != "https://cdn.islamic.app/quran/audio-surah/ar.ahmedajamy/1.mp3" {
		t.Errorf("AudioURL(ajamy) = %q", got)
	}
	// invalid input rejected
	if s.AudioURL("ar.alafasy", 115) != "" {
		t.Error("AudioURL(surah 115) not rejected")
	}
	if s.AudioURL("a/b", 1) != "" {
		t.Error("AudioURL(unsafe id) not rejected")
	}
}

func TestBudgetBytes(t *testing.T) {
	s, err := Load(filepath.Join("..", "..", testState))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got := s.BudgetBytes(); got != 500*1024*1024 {
		t.Errorf("BudgetBytes = %d, want %d", got, 500*1024*1024)
	}
	s2 := &State{}
	if got := s2.BudgetBytes(); got != defaultBudgetBytes {
		t.Errorf("BudgetBytes(default) = %d, want %d", got, defaultBudgetBytes)
	}
}

func TestStoreSwap(t *testing.T) {
	st := NewStore(&State{CacheLimitMb: 100})
	if st.Get().CacheLimitMb != 100 {
		t.Error("initial store value wrong")
	}
	st.Set(&State{CacheLimitMb: 200})
	if st.Get().CacheLimitMb != 200 {
		t.Error("store swap did not take effect")
	}
}
