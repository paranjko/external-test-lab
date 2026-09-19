package ml

import (
	"context"
	"fmt"
)

type Probe interface {
	GPU(context.Context) (int, error)
	Complete(context.Context, ModelDescriptor) error
	Cleanup(context.Context) error
}

func RunProbe(ctx context.Context, p Probe, d ModelDescriptor) error {
	if d.Validate() != nil {
		return d.Validate()
	}
	vram, e := p.GPU(ctx)
	if e != nil || vram < d.VRAMMiB {
		return fmt.Errorf("gpu unsupported")
	}
	defer p.Cleanup(context.Background())
	return p.Complete(ctx, d)
}
