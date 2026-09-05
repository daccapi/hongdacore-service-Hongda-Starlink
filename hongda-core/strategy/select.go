package strategy

import (
	"context"

	"hongda.local/hongda-core/model"
)

// Select is a manual selector group.
type Select struct {
	*base
}

func NewSelect(id string, members map[string]model.Outbound, initial string) *Select {
	s := &Select{base: newBase(id, "select")}
	for _, name := range orderedNames(members) {
		s.addMember(name, members[name])
	}
	if initial != "" {
		s.mu.Lock()
		s.current = initial
		s.mu.Unlock()
	}
	return s
}

func (s *Select) SetCurrent(name string) bool {
	s.mu.RLock()
	_, ok := s.members[name]
	s.mu.RUnlock()
	if !ok {
		return false
	}
	s.mu.Lock()
	s.current = name
	s.mu.Unlock()
	return true
}

func (s *Select) Refresh(ctx context.Context) error { return nil }

var _ model.Group = (*Select)(nil)

func orderedNames(m map[string]model.Outbound) []string {
	names := make([]string, 0, len(m))
	for name := range m {
		names = append(names, name)
	}
	return names
}
