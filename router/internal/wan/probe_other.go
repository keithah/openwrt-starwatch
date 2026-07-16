//go:build !linux

package wan

import (
	"context"
	"errors"
	"time"
)

var errProbingUnsupported = errors.New("interface-bound probing is unsupported on this platform")

type systemProber struct{}

func newSystemProber() Prober { return systemProber{} }

func (systemProber) Probe(context.Context, string, string) (time.Duration, error) {
	return 0, errProbingUnsupported
}
