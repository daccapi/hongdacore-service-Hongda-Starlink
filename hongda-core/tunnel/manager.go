package tunnel

// Manager owns one operating-system TUN interface and every route/filter it
// installs. Close must be idempotent and restore networking even after a
// partially successful Start.
type Manager interface {
	Start() error
	Close() error
}
