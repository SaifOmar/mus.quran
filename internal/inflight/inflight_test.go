package inflight

import (
	"sync"
	"testing"
	"time"
)

func TestJoinCreatesAndShares(t *testing.T) {
	m := NewManager()
	ctx, done, release, created := m.Join("k")
	if !created {
		t.Fatal("first Join should create the flight")
	}
	if ctx == nil {
		t.Fatal("nil ctx")
	}
	ctx2, done2, release2, created2 := m.Join("k")
	if created2 {
		t.Fatal("second Join should share, not create")
	}
	if ctx != ctx2 {
		t.Error("shared ctx differs")
	}
	if done != done2 {
		t.Error("shared done differs")
	}
	release()
	release2()
}

func TestLastWaiterCancels(t *testing.T) {
	m := NewManager()
	ctx, _, r1, created := m.Join("k")
	if !created {
		t.Fatal("expected created")
	}
	_, _, r2, _ := m.Join("k")

	r1() // one waiter leaves: ctx must stay alive
	select {
	case <-ctx.Done():
		t.Fatal("ctx cancelled after first waiter left")
	default:
	}
	r2() // last waiter leaves: cancel
	select {
	case <-ctx.Done():
	case <-time.After(time.Second):
		t.Fatal("ctx not cancelled after last waiter left")
	}
}

func TestFinishClosesDoneAndRemoves(t *testing.T) {
	m := NewManager()
	_, done, _, created := m.Join("k")
	if !created {
		t.Fatal("expected created")
	}
	m.Finish("k")
	select {
	case <-done:
	default:
		t.Fatal("done not closed by Finish")
	}
	// second Join creates a fresh flight (old one removed)
	ctx2, done2, release2, created2 := m.Join("k")
	if !created2 {
		t.Fatal("Join after Finish should create a new flight")
	}
	select {
	case <-ctx2.Done():
		t.Fatal("new flight already cancelled")
	default:
	}
	m.Finish("k")
	<-done2
	release2()
	// Finish is idempotent (no panic on second call / missing key)
	m.Finish("k")
}

func TestFinishAfterCancelStillClosesDone(t *testing.T) {
	m := NewManager()
	_, done, release, created := m.Join("k")
	if !created {
		t.Fatal("expected created")
	}
	// Simulate the operation being torn down: last waiter releases -> cancel,
	// then the owner calls Finish.
	release()
	m.Finish("k")
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("done not closed after Finish")
	}
}

func TestConcurrentJoinRelease(t *testing.T) {
	m := NewManager()
	const n = 64
	// One owner that finishes after a tick; it must join first to create.
	_, _, release, created := m.Join("k")
	if !created {
		t.Fatal("expected created")
	}
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, done, release, _ := m.Join("k")
			// Waiters wake when the operation finishes (done closed).
			<-done
			release()
		}()
	}
	<-time.After(10 * time.Millisecond)
	m.Finish("k")
	release()
	wgDone := make(chan struct{})
	go func() { wg.Wait(); close(wgDone) }()
	select {
	case <-wgDone:
	case <-time.After(2 * time.Second):
		t.Fatal("waiters did not finish")
	}
}

func TestContextCancellationLeak(t *testing.T) {
	// After Finish, the flight is removed; a Join creates a new context that is
	// not derived from the old one (no leak of cancellation).
	m := NewManager()
	_, _, release, _ := m.Join("k")
	release() // cancels nothing yet (no Finish); but release is a waiter
	m.Finish("k")
	_, _, release2, created := m.Join("k")
	if !created {
		t.Fatal("expected new flight")
	}
	release2()
	m.Finish("k")
}
