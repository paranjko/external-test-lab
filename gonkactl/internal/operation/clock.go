package operation

import (
	"context"
	"sync"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

type RealClock struct{}

func (RealClock) Now() time.Time { return time.Now().UTC() }
func (RealClock) Wait(ctx context.Context, d time.Duration) error {
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

type FakeClock struct {
	mu  sync.Mutex
	now time.Time
}

func NewFakeClock(now time.Time) *FakeClock { return &FakeClock{now: now.UTC()} }
func (c *FakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}
func (c *FakeClock) Advance(d time.Duration) {
	c.mu.Lock()
	c.now = c.now.Add(d)
	c.mu.Unlock()
}
func (c *FakeClock) Wait(ctx context.Context, d time.Duration) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	c.Advance(d)
	return nil
}

var _ contracts.Clock = RealClock{}
var _ contracts.Clock = (*FakeClock)(nil)
