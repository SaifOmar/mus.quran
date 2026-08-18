// Package inflight implements a singleflight manager whose shared fetch is
// owned by the fetch goroutine, not the callers: joining callers share the
// fetch's context, and only the LAST waiter tearing down cancels it. This lets
// an abandoned fill keep its already-flushed bytes while a disconnect from one
// client never kills the fetch other clients still depend on.
package inflight

import (
	"context"
	"sync"
)

// Flight is one in-flight shared operation for a key.
type Flight struct {
	ctx     context.Context
	cancel  context.CancelFunc
	done    chan struct{} // closed by Finish when the operation terminates
	waiters int
}

// Manager tracks flights by key.
type Manager struct {
	mu      sync.Mutex
	flights map[string]*Flight
}

// NewManager returns an empty Manager.
func NewManager() *Manager {
	return &Manager{flights: make(map[string]*Flight)}
}

// Join registers a caller for key.
//
// If a flight already exists the caller shares it: created is false and the
// returned ctx is the flight's shared context (the operation is already being
// performed by whoever created it; the caller should wait on Done).
//
// If none exists a flight is created and the caller owns it: created is true
// and the caller must run the operation using ctx, then call Finish and
// release (in that order) exactly once each.
//
// release must always be called exactly once per Join. Releasing the last
// waiter cancels the shared context, which aborts a still-running operation.
func (m *Manager) Join(key string) (ctx context.Context, done <-chan struct{}, release func(), created bool) {
	m.mu.Lock()
	f, ok := m.flights[key]
	if !ok {
		ctx, cancel := context.WithCancel(context.Background())
		f = &Flight{ctx: ctx, cancel: cancel, done: make(chan struct{})}
		m.flights[key] = f
	}
	f.waiters++
	m.mu.Unlock()

	var once sync.Once
	release = func() {
		once.Do(func() {
			m.mu.Lock()
			f.waiters--
			last := f.waiters == 0
			m.mu.Unlock()
			if last {
				f.cancel()
			}
		})
	}
	return f.ctx, f.done, release, !ok
}

// Finish closes the flight's done channel and removes it from the manager so a
// subsequent Join starts a fresh operation. The operation owner MUST call
// Finish on every termination path (success, error, or cancellation) or future
// joins would wait forever on a dead flight. Safe to call once; later calls
// are no-ops.
func (m *Manager) Finish(key string) {
	m.mu.Lock()
	f, ok := m.flights[key]
	if ok {
		delete(m.flights, key)
	}
	m.mu.Unlock()
	if ok {
		close(f.done)
	}
}
