package ml

import "fmt"

type ModelDescriptor struct {
	ID, Image, Revision, SHA256 string
	VRAMMiB                     int
}

func Qwen3Descriptor() ModelDescriptor {
	return ModelDescriptor{ID: "qwen3-0.6b", Image: "ghcr.io/gonka/qwen3@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", Revision: "qwen3-0.6b", SHA256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", VRAMMiB: 2048}
}
func (d ModelDescriptor) Validate() error {
	if d.ID != "qwen3-0.6b" || d.VRAMMiB <= 0 || d.Image == "" || d.Revision == "" || len(d.SHA256) != 64 {
		return fmt.Errorf("invalid pinned model descriptor")
	}
	return nil
}
