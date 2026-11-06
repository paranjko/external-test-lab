package composition

import "encoding/json"

func Materialize(d Descriptor) json.RawMessage {
	b, _ := json.Marshal(struct{ Core, DevShard, Governance string }{d.Core, d.DevShard, d.Governance})
	return b
}
