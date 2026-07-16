//go:build !linux

package wan

type systemDiscoverer struct{}

func (systemDiscoverer) Discover(_ string, override string) (string, error) { return override, nil }

func newSystemDiscoverer() Discoverer { return systemDiscoverer{} }
