package composition

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
)

type Descriptor struct {
	Core, DevShard, Governance, SHA256 string
	SelfContained                      bool
}

func Create(core, dev, gov string) Descriptor {
	d := Descriptor{Core: core, DevShard: dev, Governance: gov, SelfContained: true}
	b, _ := json.Marshal(d)
	d.SHA256 = fmt.Sprintf("%x", sha256.Sum256(b))
	return d
}
