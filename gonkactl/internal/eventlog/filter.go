package eventlog

import (
	"fmt"
	"strings"
)

var levelRank = map[string]int{
	"TRACE": 0,
	"DEBUG": 1,
	"INFO":  2,
	"WARN":  3,
	"ERROR": 4,
	"FATAL": 5,
}

type logFilter struct {
	minimum int
	only    map[string]struct{}
}

func newLogFilter(minimum string, only []string, failed bool) (logFilter, error) {
	if minimum == "" {
		minimum = "INFO"
	}
	minimum = strings.ToUpper(minimum)
	rank, ok := levelRank[minimum]
	if !ok {
		return logFilter{}, fmt.Errorf("invalid log level %q", minimum)
	}
	if failed && len(only) != 0 {
		return logFilter{}, fmt.Errorf("failed and only_level are mutually exclusive")
	}
	filter := logFilter{minimum: rank}
	if failed {
		filter.only = map[string]struct{}{"ERROR": {}, "FATAL": {}}
		return filter, nil
	}
	if len(only) != 0 {
		filter.only = make(map[string]struct{})
		for _, values := range only {
			for _, level := range strings.Split(values, ",") {
				level = strings.ToUpper(strings.TrimSpace(level))
				if _, ok := levelRank[level]; !ok {
					return logFilter{}, fmt.Errorf("invalid exact log level %q", level)
				}
				filter.only[level] = struct{}{}
			}
		}
	}
	return filter, nil
}

func (f logFilter) accepts(level string) bool {
	level = strings.ToUpper(level)
	rank, ok := levelRank[level]
	if !ok || rank < f.minimum {
		return false
	}
	if f.only == nil {
		return true
	}
	_, ok = f.only[level]
	return ok
}
