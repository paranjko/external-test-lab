//go:build !linux

package incidenthost

import (
	"context"
	"errors"
)

func runLinux(context.Context, string, string, Target) (any, error) {
	return nil, errors.New("incidenthost is supported only on Linux")
}
