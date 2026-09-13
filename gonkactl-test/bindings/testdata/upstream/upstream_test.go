package upstream

import (
	"testing"
	"time"
)

func TestPass(t *testing.T)      { t.Run("child", func(t *testing.T) {}) }
func TestFail(t *testing.T)      { t.Fatal("controlled failure") }
func TestInterrupt(t *testing.T) { time.Sleep(10 * time.Second) }
