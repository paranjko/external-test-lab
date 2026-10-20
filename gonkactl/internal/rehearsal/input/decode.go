package input

import "github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/contract"

func Decode(raw []byte, destination any) error {
	return contract.DecodeStrict(raw, destination)
}
