package rangecache

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func iset(intervals ...Interval) Intervals {
	return Intervals(intervals)
}

func TestIntervalsAdd(t *testing.T) {
	cases := []struct {
		name string
		init Intervals
		add  Interval
		want Intervals
	}{
		{"insert into empty", nil, Interval{0, 10}, iset(Interval{0, 10})},
		{"append after", iset(Interval{0, 10}), Interval{20, 30}, iset(Interval{0, 10}, Interval{20, 30})},
		{"prepend before", iset(Interval{20, 30}), Interval{0, 10}, iset(Interval{0, 10}, Interval{20, 30})},
		{"coalesce adjacent", iset(Interval{0, 10}), Interval{10, 20}, iset(Interval{0, 20})},
		{"coalesce overlap", iset(Interval{0, 10}), Interval{5, 15}, iset(Interval{0, 15})},
		{"coalesce contained", iset(Interval{0, 20}), Interval{5, 15}, iset(Interval{0, 20})},
		{"coalesce spanning", iset(Interval{0, 5}, Interval{10, 15}), Interval{3, 12}, iset(Interval{0, 15})},
		{"coalesce adjacent middle", iset(Interval{0, 10}, Interval{20, 30}), Interval{10, 20}, iset(Interval{0, 30})},
		{"merge overlapping non-adjacent", iset(Interval{0, 5}, Interval{10, 20}), Interval{15, 25}, iset(Interval{0, 5}, Interval{10, 25})},
		{"zero-length ignored", iset(Interval{0, 10}), Interval{5, 5}, iset(Interval{0, 10})},
		{"merge three", iset(Interval{0, 5}, Interval{5, 10}, Interval{10, 15}), Interval{2, 14}, iset(Interval{0, 15})},
	}
	for _, c := range cases {
		in := c.init
		in.Add(c.add.Start, c.add.End)
		if !reflect.DeepEqual(in, c.want) {
			t.Errorf("%s: Add(%v) = %v, want %v", c.name, c.add, in, c.want)
		}
	}
}

func TestIntervalsContains(t *testing.T) {
	in := Intervals{{0, 10}, {20, 30}}
	cases := []struct {
		s, e int64
		want bool
	}{
		{0, 10, true},
		{5, 9, true},
		{0, 11, false},
		{9, 10, true},
		{10, 11, false},
		{20, 30, true},
		{29, 30, true},
		{25, 35, false},
		{19, 20, false},
	}
	for _, c := range cases {
		if got := in.Contains(c.s, c.e); got != c.want {
			t.Errorf("Contains(%d,%d) = %v, want %v", c.s, c.e, got, c.want)
		}
	}
	empty := Intervals{}
	if !empty.Contains(3, 3) {
		t.Error("empty range always contained")
	}
	if !(Intervals{{0, 5}}).Contains(3, 3) {
		t.Error("empty range contained in non-empty set")
	}
}

func TestIntervalsFull(t *testing.T) {
	full := Intervals{{0, 100}}
	if !full.Full(100) {
		t.Error("single full interval not Full")
	}
	two := Intervals{{0, 50}, {50, 100}}
	if two.Full(100) {
		t.Error("two intervals should not be Full (not coalesced)")
	}
	shifted := Intervals{{1, 100}}
	if shifted.Full(100) {
		t.Error("non-zero start not Full")
	}
	short := Intervals{{0, 99}}
	if short.Full(100) {
		t.Error("short not Full")
	}
	empty := Intervals{}
	if empty.Full(100) {
		t.Error("empty not Full")
	}
}

func TestIntervalsBytes(t *testing.T) {
	in := Intervals{{0, 10}, {20, 30}}
	if got := in.Bytes(); got != 20 {
		t.Errorf("Bytes = %d, want 20", got)
	}
}

func TestIntervalsSegments(t *testing.T) {
	in := Intervals{{0, 10}, {20, 30}}
	cases := []struct {
		name string
		s, e int64
		want []Segment
	}{
		{"fully cached", 0, 10, []Segment{{0, 10, true}}},
		{"fully missing", 10, 20, []Segment{{10, 20, false}}},
		{"straddle both", 5, 25, []Segment{{5, 10, true}, {10, 20, false}, {20, 25, true}}},
		{"leading missing", 15, 22, []Segment{{15, 20, false}, {20, 22, true}}},
		{"trailing missing", 5, 12, []Segment{{5, 10, true}, {10, 12, false}}},
		{"empty", 5, 5, nil},
		{"cached then tail missing", 0, 40, []Segment{{0, 10, true}, {10, 20, false}, {20, 30, true}, {30, 40, false}}},
	}
	for _, c := range cases {
		got := in.Segments(c.s, c.e)
		if !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: Segments(%d,%d) = %v, want %v", c.name, c.s, c.e, got, c.want)
		}
	}
}

func TestEntryWriteRead(t *testing.T) {
	dir := t.TempDir()
	c, err := New(dir, 1<<30).Entry("ar.alafasy", 1)
	if err != nil {
		t.Fatal(err)
	}
	if err := c.EnsureSize(100, "audio/mpeg", "etag-1"); err != nil {
		t.Fatal(err)
	}
	if !c.SizeKnown() {
		t.Fatal("size not known after EnsureSize")
	}
	if err := c.WriteRange(0, []byte("hello world")); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 11)
	if _, err := c.ReadAt(buf, 0); err != nil {
		t.Fatal(err)
	}
	if string(buf) != "hello world" {
		t.Errorf("read = %q", buf)
	}
	if !c.Fetched().Contains(0, 11) {
		t.Errorf("fetched = %v, want [0,11)", c.Fetched())
	}
	// Adjacent fill coalesces.
	if err := c.WriteRange(11, []byte(" second")); err != nil {
		t.Fatal(err)
	}
	if !c.Fetched().Contains(0, 18) {
		t.Errorf("fetched after adjacent fill = %v", c.Fetched())
	}
	if c.Fetched().Full(100) {
		t.Error("should not be full yet")
	}
}

func TestSidecarPersistsAcrossReopen(t *testing.T) {
	dir := t.TempDir()
	c := &Cache{root: dir, entries: make(map[string]*Entry)}
	e, err := c.Entry("ar.alafasy", 2)
	if err != nil {
		t.Fatal(err)
	}
	if err := e.EnsureSize(1000, "audio/mpeg", ""); err != nil {
		t.Fatal(err)
	}
	if err := e.WriteRange(0, make([]byte, 500)); err != nil {
		t.Fatal(err)
	}

	// Re-open from disk (fresh cache over the same dir).
	c2 := &Cache{root: dir, entries: make(map[string]*Entry)}
	e2, err := c2.Entry("ar.alafasy", 2)
	if err != nil {
		t.Fatal(err)
	}
	if e2.Meta().Size != 1000 {
		t.Errorf("reopened size = %d", e2.Meta().Size)
	}
	if !e2.Fetched().Contains(0, 500) {
		t.Errorf("reopened fetched = %v", e2.Fetched())
	}
}

func TestSizeMismatchDiscardsRanges(t *testing.T) {
	dir := t.TempDir()
	c := &Cache{root: dir, entries: make(map[string]*Entry)}
	e, err := c.Entry("ar.alafasy", 3)
	if err != nil {
		t.Fatal(err)
	}
	if err := e.EnsureSize(1000, "audio/mpeg", ""); err != nil {
		t.Fatal(err)
	}
	if err := e.WriteRange(0, make([]byte, 300)); err != nil {
		t.Fatal(err)
	}
	// Truncate the .dat so it disagrees with the sidecar (simulates partial
	// data loss or a crash that lost writes).
	if err := os.Truncate(e.dataPath, 500); err != nil {
		t.Fatal(err)
	}
	c2 := &Cache{root: dir, entries: make(map[string]*Entry)}
	e2, err := c2.Entry("ar.alafasy", 3)
	if err != nil {
		t.Fatal(err)
	}
	if len(e2.Fetched()) != 0 {
		t.Errorf("fetched after mismatch = %v, want empty", e2.Fetched())
	}
}

func TestCorruptSidecarTreatedEmpty(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "ar.alafasy"), 0o700)
	if err := os.WriteFile(filepath.Join(dir, "ar.alafasy", "4.meta.json"), []byte("{corrupt"), 0o600); err != nil {
		t.Fatal(err)
	}
	c := &Cache{root: dir, entries: make(map[string]*Entry)}
	e, err := c.Entry("ar.alafasy", 4)
	if err != nil {
		t.Fatalf("corrupt sidecar should not hard-fail: %v", err)
	}
	if len(e.Fetched()) != 0 {
		t.Errorf("fetched = %v, want empty", e.Fetched())
	}
}

// crashPersist simulates a crash: data writes succeeded but the sidecar was
// never persisted.
func crashPersist(path string, m *Meta) error { return nil }

func TestCrashNeverClaimsUnflushed(t *testing.T) {
	dir := t.TempDir()
	c := &Cache{root: dir, entries: make(map[string]*Entry)}
	e, err := c.Entry("ar.alafasy", 5)
	if err != nil {
		t.Fatal(err)
	}
	// Size sidecar persists normally.
	if err := e.EnsureSize(1000, "audio/mpeg", ""); err != nil {
		t.Fatal(err)
	}
	// From here on the sidecar persist is dropped (crash after data write).
	e.persist = crashPersist
	if err := e.WriteRange(0, make([]byte, 200)); err != nil {
		t.Fatal(err)
	}
	// On-disk sidecar must still claim nothing beyond the size.
	c2 := &Cache{root: dir, entries: make(map[string]*Entry)}
	e2, err := c2.Entry("ar.alafasy", 5)
	if err != nil {
		t.Fatal(err)
	}
	if e2.Meta().Size != 1000 {
		t.Errorf("reopened size = %d, want 1000", e2.Meta().Size)
	}
	if len(e2.Fetched()) != 0 {
		t.Fatalf("sidecar claims ranges a crash never persisted: %v", e2.Fetched())
	}
}

func TestEvictSkipsActive(t *testing.T) {
	dir := t.TempDir()
	c := New(dir, 1000)
	e1, err := c.Entry("a", 1)
	if err != nil {
		t.Fatal(err)
	}
	e2, err := c.Entry("a", 2)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range []*Entry{e1, e2} {
		if err := e.EnsureSize(1000, "audio/mpeg", ""); err != nil {
			t.Fatal(err)
		}
	}
	release := e1.Begin() // e1 is in-flight; must survive eviction
	defer release()

	if err := c.EvictToBudget(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(e1.dataPath); err != nil {
		t.Error("in-flight entry was evicted")
	}
	if _, err := os.Stat(e2.dataPath); !os.IsNotExist(err) {
		t.Error("idle entry was not evicted")
	}
}

func TestClearSkipsActive(t *testing.T) {
	dir := t.TempDir()
	c := New(dir, 1<<30)
	e1, err := c.Entry("a", 1)
	if err != nil {
		t.Fatal(err)
	}
	e2, err := c.Entry("a", 2)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range []*Entry{e1, e2} {
		if err := e.EnsureSize(1000, "audio/mpeg", ""); err != nil {
			t.Fatal(err)
		}
	}
	release := e1.Begin() // e1 is in-flight; must survive clear
	defer release()

	if err := c.Clear(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(e1.dataPath); err != nil {
		t.Error("in-flight entry was cleared")
	}
	if _, err := os.Stat(e2.dataPath); !os.IsNotExist(err) {
		t.Error("idle entry was not cleared")
	}
	u := c.Usage()
	if u.Files != 1 {
		t.Errorf("Usage.Files = %d, want 1", u.Files)
	}
}

func TestClearIdempotent(t *testing.T) {
	dir := t.TempDir()
	c := New(dir, 1<<30)
	if err := c.Clear(); err != nil {
		t.Fatal(err)
	}
}

func TestEvictUnderBudgetNoop(t *testing.T) {
	dir := t.TempDir()
	c := New(dir, 1<<30)
	e, err := c.Entry("a", 1)
	if err != nil {
		t.Fatal(err)
	}
	if err := e.EnsureSize(5000, "audio/mpeg", ""); err != nil {
		t.Fatal(err)
	}
	if err := c.EvictToBudget(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(e.dataPath); err != nil {
		t.Error("entry evicted while under budget")
	}
}

func TestEvictLRUOrder(t *testing.T) {
	dir := t.TempDir()
	c := New(dir, 1000)
	var es []*Entry
	for i := 1; i <= 3; i++ {
		e, err := c.Entry("a", i)
		if err != nil {
			t.Fatal(err)
		}
		if err := e.EnsureSize(800, "audio/mpeg", ""); err != nil {
			t.Fatal(err)
		}
		if err := e.WriteRange(0, []byte("x")); err != nil { // bump UpdatedAt
			t.Fatal(err)
		}
		es = append(es, e)
	}
	// Touch e3 last so it is newest; budget 1000 keeps only the newest 800B.
	if err := es[2].WriteRange(1, []byte("y")); err != nil {
		t.Fatal(err)
	}
	if err := c.EvictToBudget(); err != nil {
		t.Fatal(err)
	}
	for i, e := range es {
		_, err := os.Stat(e.dataPath)
		if i == 2 && err != nil {
			t.Errorf("newest entry evicted: %v", err)
		}
		if i < 2 && err == nil {
			t.Errorf("entry %d (older) survived eviction", i)
		}
	}
}

func TestUsage(t *testing.T) {
	dir := t.TempDir()
	c := New(dir, 1<<30)
	e, err := c.Entry("a", 1)
	if err != nil {
		t.Fatal(err)
	}
	if err := e.EnsureSize(700, "audio/mpeg", ""); err != nil {
		t.Fatal(err)
	}
	u := c.Usage()
	if u.Bytes != 700 || u.Files != 1 {
		t.Errorf("usage = %+v, want {700 1}", u)
	}
}

func TestClaimPromote(t *testing.T) {
	c := New(t.TempDir(), 1<<30)
	e, err := c.Entry("ar.alafasy", 1)
	if err != nil {
		t.Fatal(err)
	}
	if err := e.EnsureSize(100, "audio/mpeg", ""); err != nil {
		t.Fatal(err)
	}
	if e.ClaimPromote() {
		t.Error("ClaimPromote = true with no active request, want false")
	}
	release := e.Begin()
	defer release()
	if !e.ClaimPromote() {
		t.Error("ClaimPromote = false for sole active request, want true")
	}
	if e.ClaimPromote() {
		t.Error("ClaimPromote = true after already claimed, want false")
	}
}

func TestClaimPromoteSkipsConcurrent(t *testing.T) {
	c := New(t.TempDir(), 1<<30)
	e, err := c.Entry("ar.alafasy", 1)
	if err != nil {
		t.Fatal(err)
	}
	r1 := e.Begin()
	defer r1()
	r2 := e.Begin()
	defer r2()
	if e.ClaimPromote() {
		t.Error("ClaimPromote = true with two active requests, want false")
	}
}

func TestCacheRemove(t *testing.T) {
	root := t.TempDir()
	c := New(root, 1<<30)
	e, err := c.Entry("ar.alafasy", 3)
	if err != nil {
		t.Fatal(err)
	}
	if err := e.EnsureSize(64, "audio/mpeg", ""); err != nil {
		t.Fatal(err)
	}
	if err := c.Remove("ar.alafasy", 3); err != nil {
		t.Fatal(err)
	}
	if u := c.Usage(); u.Files != 0 {
		t.Errorf("usage after Remove = %+v", u)
	}
	if _, err := os.Stat(filepath.Join(root, "ar.alafasy", "3.dat")); !os.IsNotExist(err) {
		t.Errorf("3.dat still present after Remove: %v", err)
	}
	if err := c.Remove("ar.alafasy", 3); err != nil {
		t.Errorf("Remove of missing entry = %v, want nil", err)
	}
}
