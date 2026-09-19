package legacyv1

import (
	"bytes"
	"encoding/json"
	"errors"
	"regexp"

	"github.com/paranjko/external-test-lab/gonkactl/internal/backup/model"
)

// Decode extracts the archive identity fields needed before restore. It never
// writes archive content and rejects a missing or malformed signing state.
func Decode(snapshot model.Archive) (model.VerifiedArchive, error) {
	manifest, ok := snapshot.Member("manifest.json")
	stateMember, okState := snapshot.Member("remote-state/tmkms/state/priv_validator_state.json")
	if !ok || !okState || manifest.Dir || stateMember.Dir {
		return model.VerifiedArchive{}, ErrInvalidArchive
	}
	var m struct {
		NodeName      string          `json:"node_name"`
		ChainID       string          `json:"chain_id"`
		GenesisSHA256 string          `json:"genesis_sha256"`
		MLHost        json.RawMessage `json:"ml_host"`
	}
	if err := strictJSON(manifest.Data, &m); err != nil || m.NodeName == "" || m.ChainID == "" || !lowerHex64(m.GenesisSHA256) || !validMLHost(m.MLHost) {
		return model.VerifiedArchive{}, ErrInvalidArchive
	}
	var raw struct {
		Height  string          `json:"height"`
		Round   string          `json:"round"`
		Step    int8            `json:"step"`
		BlockID json.RawMessage `json:"block_id"`
	}
	if err := strictJSON(stateMember.Data, &raw); err != nil {
		return model.VerifiedArchive{}, ErrInvalidArchive
	}
	state := model.SigningState{Height: raw.Height, Round: raw.Round, Step: raw.Step}
	if len(raw.BlockID) != 0 && !bytes.Equal(raw.BlockID, []byte("null")) {
		var block struct {
			Hash  string `json:"hash"`
			Parts struct {
				Total uint32 `json:"total"`
				Hash  string `json:"hash"`
			} `json:"parts"`
			PartSetHeader struct {
				Total uint32 `json:"total"`
				Hash  string `json:"hash"`
			} `json:"part_set_header"`
		}
		if err := strictJSON(raw.BlockID, &block); err != nil || !lowerHex64(block.Hash) {
			return model.VerifiedArchive{}, ErrInvalidArchive
		}
		if block.Parts.Hash == "" {
			block.Parts = block.PartSetHeader
		}
		if !lowerHex64(block.Parts.Hash) {
			return model.VerifiedArchive{}, ErrInvalidArchive
		}
		state.BlockID = &model.BlockID{Hash: block.Hash, PartsTotal: block.Parts.Total, PartsHash: block.Parts.Hash}
	}
	if _, err := CompareHRS(state, state); err != nil {
		return model.VerifiedArchive{}, err
	}
	return model.VerifiedArchive{Archive: snapshot, NodeName: m.NodeName, ChainID: m.ChainID, GenesisSHA256: m.GenesisSHA256, SigningState: state}, nil
}

var lowercaseHex64 = regexp.MustCompile(`^[a-f0-9]{64}$`)
var hostAlias = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*$`)

func lowerHex64(value string) bool { return lowercaseHex64.MatchString(value) }

// validMLHost accepts the historical schema-1 omission and null form, but
// keeps a supplied hint inert rather than treating it as a connection target.
func validMLHost(raw json.RawMessage) bool {
	if len(raw) == 0 || bytes.Equal(raw, []byte("null")) {
		return true
	}
	var value string
	return json.Unmarshal(raw, &value) == nil && hostAlias.MatchString(value)
}

func strictJSON(data []byte, value any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(value); err != nil {
		return err
	}
	if decoder.More() {
		return errors.New("trailing JSON")
	}
	var extra any
	if err := decoder.Decode(&extra); err == nil {
		return errors.New("trailing JSON")
	}
	return nil
}
