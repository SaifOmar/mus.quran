// Package rangecache manages the proxy's sparse .dat files and their
// .meta.json sidecars under ~/.cache/omarchy/quran/<reciter>/<surah>.dat.
//
// Ownership split (see PLAN.md): the PROXY owns eviction of these files —
// cache.sh keeps operating on legacy *.mp3 files. Eviction skips any entry
// with an in-flight request (active > 0) so a live file is never unlinked
// while the proxy holds an open write handle.
//
// Persistence invariant per fill: write data (WriteAt) -> fsync -> merge
// interval -> persist sidecar. On restart, a sidecar whose size disagrees with
// the .dat file is discarded (treat as empty, refetch).
package rangecache

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

// Cache is a concurrency-safe pool of Entrys rooted at a cache directory.
type Cache struct {
	root    string
	budget  int64
	mu      sync.Mutex
	entries map[string]*Entry
}

// New creates a cache rooted at root (created on first use).
func New(root string, budget int64) *Cache {
	return &Cache{
		root:    root,
		budget:  budget,
		entries: make(map[string]*Entry),
	}
}

// SetBudget updates the eviction target.
func (c *Cache) SetBudget(b int64) {
	c.mu.Lock()
	c.budget = b
	c.mu.Unlock()
}

// Budget returns the current eviction target.
func (c *Cache) Budget() int64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.budget
}

// Root returns the cache directory.
func (c *Cache) Root() string { return c.root }

func key(reciter string, surah int) string {
	return fmt.Sprintf("%s:%d", reciter, surah)
}

// Entry returns (creating on first use) the entry for reciter/surah. On first
// touch the sidecar is loaded; if the .dat size disagrees with the sidecar,
// the ranges are discarded and the file re-fetched.
func (c *Cache) Entry(reciter string, surah int) (*Entry, error) {
	k := key(reciter, surah)
	c.mu.Lock()
	e, ok := c.entries[k]
	if !ok {
		dir := filepath.Join(c.root, reciter)
		e = &Entry{
			reciter:  reciter,
			surah:    surah,
			dir:      dir,
			dataPath: filepath.Join(dir, fmt.Sprintf("%d.dat", surah)),
			metaPath: filepath.Join(dir, fmt.Sprintf("%d.meta.json", surah)),
			persist:  SaveMeta,
		}
		c.entries[k] = e
	}
	c.mu.Unlock()

	if !ok {
		if err := e.load(); err != nil {
			return nil, err
		}
	}
	return e, nil
}

// Size returns the total logical bytes the proxy pool accounts for (sum of
// entry data sizes). Used by /cache/usage and budget enforcement.
func (c *Cache) Size() int64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	var n int64
	for _, e := range c.entries {
		n += e.dataSize()
	}
	return n
}

// Usage returns the pool total plus the per-entry breakdown for /cache/usage.
type Usage struct {
	Bytes int64
	Files int
}

// Usage reports pool usage.
func (c *Cache) Usage() Usage {
	c.mu.Lock()
	defer c.mu.Unlock()
	var n int64
	for _, e := range c.entries {
		n += e.dataSize()
	}
	return Usage{Bytes: n, Files: len(c.entries)}
}

// EvictToBudget frees pool bytes above the budget, LRU by UpdatedAt, skipping
// entries with in-flight requests. Call after any persist; cheap when under
// budget.
func (c *Cache) EvictToBudget() error {
	c.mu.Lock()
	over := c.sizeLocked() - c.budget
	if over <= 0 {
		c.mu.Unlock()
		return nil
	}
	// Snapshot entries, sorted oldest-updated first (deterministic tiebreak on
	// the key so same-millisecond writes don't evict arbitrarily).
	es := make([]*Entry, 0, len(c.entries))
	for _, e := range c.entries {
		es = append(es, e)
	}
	sort.Slice(es, func(i, j int) bool {
		if es[i].updatedAt() != es[j].updatedAt() {
			return es[i].updatedAt() < es[j].updatedAt()
		}
		return key(es[i].reciter, es[i].surah) < key(es[j].reciter, es[j].surah)
	})
	c.mu.Unlock()

	for _, e := range es {
		if over <= 0 {
			break
		}
		if e.Active() {
			continue // never evict a file with an in-flight request
		}
		sz := e.dataSize()
		if err := e.Remove(); err != nil {
			return err
		}
		c.mu.Lock()
		delete(c.entries, key(e.reciter, e.surah))
		c.mu.Unlock()
		over -= sz
	}
	return nil
}

func (c *Cache) sizeLocked() int64 {
	var n int64
	for _, e := range c.entries {
		n += e.dataSize()
	}
	return n
}

// Remove deletes an entry's files and forgets it. Used after promotion and on
// validation failure. A missing entry is not an error.
func (c *Cache) Remove(reciter string, surah int) error {
	k := key(reciter, surah)
	c.mu.Lock()
	e, ok := c.entries[k]
	if !ok {
		c.mu.Unlock()
		return nil
	}
	delete(c.entries, k)
	c.mu.Unlock()
	return e.Remove()
}

// Clear removes every cached entry without an in-flight request (the "clear
// cache" action). Entries currently being served are kept — they finish
// normally and are forgotten by their own completion path — so a clear never
// races a concurrent reader/writer.
func (c *Cache) Clear() error {
	c.mu.Lock()
	es := make([]*Entry, 0, len(c.entries))
	for _, e := range c.entries {
		es = append(es, e)
	}
	c.mu.Unlock()
	for _, e := range es {
		if e.Active() {
			continue
		}
		if err := e.Remove(); err != nil {
			return err
		}
		c.mu.Lock()
		delete(c.entries, key(e.reciter, e.surah))
		c.mu.Unlock()
	}
	return nil
}

// Entry is one surah: a sparse .dat plus its sidecar.
type Entry struct {
	reciter  string
	surah    int
	dir      string
	dataPath string
	metaPath string

	mu     sync.RWMutex
	meta   Meta
	file   *os.File
	active int
	// promoting guards the M3 validate+promote hook: only the sole active
	// request may claim it, so cache files are never deleted under a
	// concurrent reader.
	promoting bool
	// persist is overridable for tests (crash simulation).
	persist func(path string, m *Meta) error
}

// Reciter/Surah identify the entry.
func (e *Entry) Reciter() string { return e.reciter }
func (e *Entry) Surah() int      { return e.surah }

// DataPath returns the on-disk .dat path (promotion source).
func (e *Entry) DataPath() string { return e.dataPath }

// ClaimPromote marks the entry for promotion, succeeding only for the sole
// active request (active == 1). Returns false when another request is active
// (a concurrent reader would be racing the file deletion) or promotion was
// already claimed.
func (e *Entry) ClaimPromote() bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.promoting || e.active != 1 {
		return false
	}
	e.promoting = true
	return true
}

// load reads the sidecar and reconciles it with the on-disk .dat.
func (e *Entry) load() error {
	if err := os.MkdirAll(e.dir, 0o700); err != nil {
		return fmt.Errorf("rangecache: mkdir %s: %w", e.dir, err)
	}
	m, err := LoadMeta(e.metaPath)
	if err != nil {
		// Corrupt sidecar: discard and treat as empty.
		m = &Meta{}
	}
	e.mu.Lock()
	e.meta = *m
	// Reconcile: a .dat that disagrees with the sidecar cannot be trusted.
	if fi, err := os.Stat(e.dataPath); err == nil && fi.Size() == m.Size && m.Size > 0 {
		// ok: sidecar matches the file.
	} else if fi != nil && fi.Size() != m.Size {
		// size mismatch: reset claimed ranges (bytes are gone or suspect).
		e.meta.Fetched = nil
		e.meta.UpdatedAt = 0
	} else {
		e.meta.Fetched = nil
	}
	e.mu.Unlock()
	return nil
}

// Meta returns a copy of the sidecar.
func (e *Entry) Meta() Meta {
	e.mu.RLock()
	defer e.mu.RUnlock()
	return e.meta
}

// Fetched returns a copy of the fetched intervals.
func (e *Entry) Fetched() Intervals {
	e.mu.RLock()
	defer e.mu.RUnlock()
	out := make(Intervals, len(e.meta.Fetched))
	copy(out, e.meta.Fetched)
	return out
}

// SizeKnown reports whether the origin size has been discovered.
func (e *Entry) SizeKnown() bool {
	e.mu.RLock()
	defer e.mu.RUnlock()
	return e.meta.Size > 0
}

// EnsureSize records the origin size, allocates the sparse .dat, and persists
// an empty sidecar. Called after the pinned HEAD. size must be > 0.
func (e *Entry) EnsureSize(size int64, contentType, etag string) error {
	e.mu.Lock()
	if e.meta.Size != size {
		f, err := os.OpenFile(e.dataPath, os.O_CREATE|os.O_RDWR, 0o600)
		if err != nil {
			e.mu.Unlock()
			return err
		}
		if err := f.Truncate(size); err != nil { // sparse allocation
			f.Close()
			e.mu.Unlock()
			return err
		}
		if e.file != nil {
			e.file.Close()
		}
		e.file = f
		e.meta.Size = size
		e.meta.ContentType = contentType
		e.meta.ETag = etag
		e.meta.Fetched = nil
		e.meta.UpdatedAt = 0
	}
	m := e.meta
	e.mu.Unlock()
	return e.persist(e.metaPath, &m)
}

// WriteRange writes b at offset, flushes it, merges [offset, offset+len(b))
// into the sidecar, and persists. This is the invariant-preserving fill step:
// a crash before the sidecar persist leaves the sidecar under-claiming (safe),
// never over-claiming.
func (e *Entry) WriteRange(offset int64, b []byte) error {
	if len(b) == 0 {
		return nil
	}
	f, err := e.openFile()
	if err != nil {
		return err
	}
	if _, err := f.WriteAt(b, offset); err != nil {
		return fmt.Errorf("rangecache: write at %d: %w", offset, err)
	}
	// Data must be durable before the sidecar can claim it.
	if err := f.Sync(); err != nil {
		return fmt.Errorf("rangecache: sync: %w", err)
	}

	e.mu.Lock()
	e.meta.Fetched.Add(offset, offset+int64(len(b)))
	if offset < e.meta.UpdatedAt || e.meta.UpdatedAt == 0 {
		e.meta.UpdatedAt = nowMillis()
	}
	m := e.meta
	e.mu.Unlock()
	return e.persist(e.metaPath, &m)
}

// ReadAt reads len(b) bytes at off from the .dat. Callers must only read
// within claimed intervals (see Fetched).
func (e *Entry) ReadAt(b []byte, off int64) (int, error) {
	f, err := e.openFile()
	if err != nil {
		return 0, err
	}
	return f.ReadAt(b, off)
}

// Active increments/decrements the in-flight counter (guards eviction).
func (e *Entry) Active() bool {
	e.mu.RLock()
	defer e.mu.RUnlock()
	return e.active > 0
}

// Begin marks an in-flight request; returns a release func.
func (e *Entry) Begin() func() {
	e.mu.Lock()
	e.active++
	e.mu.Unlock()
	return func() {
		e.mu.Lock()
		e.active--
		e.mu.Unlock()
	}
}

// Remove closes the file handle and deletes the .dat + sidecar (and the now
// empty reciter dir if unused).
func (e *Entry) Remove() error {
	e.mu.Lock()
	if e.file != nil {
		e.file.Close()
		e.file = nil
	}
	e.mu.Unlock()
	err1 := os.Remove(e.dataPath)
	err2 := os.Remove(e.metaPath)
	if os.IsNotExist(err1) {
		err1 = nil
	}
	if os.IsNotExist(err2) {
		err2 = nil
	}
	if err1 != nil {
		return err1
	}
	if err2 != nil {
		return err2
	}
	os.Remove(e.dir) // best-effort
	return nil
}

// Close releases the file handle.
func (e *Entry) Close() error {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.file != nil {
		err := e.file.Close()
		e.file = nil
		return err
	}
	return nil
}

func (e *Entry) openFile() (*os.File, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.file == nil {
		f, err := os.OpenFile(e.dataPath, os.O_CREATE|os.O_RDWR, 0o600)
		if err != nil {
			return nil, err
		}
		e.file = f
	}
	return e.file, nil
}

func (e *Entry) dataSize() int64 {
	e.mu.RLock()
	defer e.mu.RUnlock()
	return e.meta.Size
}

func (e *Entry) updatedAt() int64 {
	e.mu.RLock()
	defer e.mu.RUnlock()
	return e.meta.UpdatedAt
}

// nowMillis is overridable for tests.
var nowMillis = func() int64 { return time.Now().UnixMilli() }
