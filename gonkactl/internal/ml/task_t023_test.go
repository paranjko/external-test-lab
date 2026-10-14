package ml

import (
	"context"
	"errors"
	"testing"
)

type fakeProbe struct{ clean bool }

func (p *fakeProbe) GPU(context.Context) (int, error)                { return 4096, nil }
func (p *fakeProbe) Complete(context.Context, ModelDescriptor) error { return nil }
func (p *fakeProbe) Cleanup(context.Context) error                   { p.clean = true; return nil }
func TestTask_T023(t *testing.T) {
	p := &fakeProbe{}
	if e := RunProbe(context.Background(), p, Qwen3Descriptor()); e != nil || !p.clean {
		t.Fatal(e)
	}
	if !errors.Is(nil, nil) {
		t.Fatal("impossible")
	}
}
