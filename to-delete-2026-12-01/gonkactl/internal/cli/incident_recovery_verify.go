//go:build gnklab0002_live

package cli

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"

	cmtjson "github.com/cometbft/cometbft/libs/json"
	cmtproto "github.com/cometbft/cometbft/proto/tendermint/types"
	cmttypes "github.com/cometbft/cometbft/types"
	"github.com/cosmos/gogoproto/proto"
	"github.com/paranjko/external-test-lab/gonkactl/internal/rehearsal/coregate"
	"github.com/spf13/cobra"
)

type incidentHPlusOneRecord struct {
	Block      []byte                        `json:"block_proto"`
	Commit     []byte                        `json:"commit_proto"`
	Validators []byte                        `json:"validators_proto"`
	Verified   coregate.HPlusOneVerification `json:"verified"`
	Proof      coregate.QuorumProof          `json:"proof"`
}

func verifyIncidentHPlusOne(cmd *cobra.Command, node, dir string) error {
	if !filepath.IsAbs(dir) {
		return errors.New("absolute evidence directory required")
	}
	ctx, cancel := context.WithTimeout(cmd.Context(), time.Minute)
	defer cancel()
	get := func(method string, out interface{}) error {
		req, err := http.NewRequestWithContext(ctx, "GET", "https://"+node+".gonka-dev.net/chain-rpc/"+method, nil)
		if err != nil {
			return err
		}
		response, err := http.DefaultClient.Do(req)
		if err != nil {
			return err
		}
		defer response.Body.Close()
		raw, err := io.ReadAll(io.LimitReader(response.Body, 64<<20))
		if err != nil {
			return err
		}
		if response.StatusCode != http.StatusOK {
			return fmt.Errorf("RPC HTTP %d", response.StatusCode)
		}
		var envelope struct {
			Result json.RawMessage
			Error  json.RawMessage
		}
		if err := json.Unmarshal(raw, &envelope); err != nil {
			return err
		}
		if len(envelope.Error) > 0 && string(envelope.Error) != "null" {
			return fmt.Errorf("RPC: %s", envelope.Error)
		}
		return cmtjson.Unmarshal(envelope.Result, out)
	}
	var block struct {
		BlockID cmttypes.BlockID `json:"block_id"`
		Block   *cmttypes.Block  `json:"block"`
	}
	var commit struct {
		cmttypes.SignedHeader `json:"signed_header"`
	}
	var validators struct {
		BlockHeight int64                 `json:"block_height"`
		Total       int                   `json:"total"`
		Validators  []*cmttypes.Validator `json:"validators"`
	}
	if err := get("block?height=814731", &block); err != nil {
		return err
	}
	if err := get("commit?height=814731", &commit); err != nil {
		return err
	}
	if err := get("validators?height=814731&per_page=100", &validators); err != nil {
		return err
	}
	if block.Block == nil || commit.Commit == nil || commit.Header == nil ||
		validators.BlockHeight != 814731 || validators.Total != len(validators.Validators) ||
		len(validators.Validators) == 0 || !bytes.Equal(block.Block.Hash(), commit.Header.Hash()) {
		return errors.New("incomplete or inconsistent H+1 RPC evidence")
	}
	pb, err := block.Block.ToProto()
	if err != nil {
		return err
	}
	rawBlock, err := proto.Marshal(pb)
	if err != nil {
		return err
	}
	rawCommit, err := proto.Marshal(commit.Commit.ToProto())
	if err != nil {
		return err
	}
	set := cmttypes.NewValidatorSet(validators.Validators)
	setPB, err := set.ToProto()
	if err != nil {
		return err
	}
	rawValidators, err := proto.Marshal(setPB)
	if err != nil {
		return err
	}
	record := incidentHPlusOneRecord{Block: rawBlock, Commit: rawCommit, Validators: rawValidators}
	if err := checkIncidentHPlusOne(ctx, node, &record); err != nil {
		return err
	}
	if !bytes.Equal(block.BlockID.Hash, block.Block.Hash()) ||
		hex.EncodeToString(block.BlockID.PartSetHeader.Hash) != record.Verified.Block.PartSetHash ||
		block.BlockID.PartSetHeader.Total != record.Verified.Block.PartSetTotal {
		return errors.New("RPC BlockID differs from reconstructed canonical block")
	}
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	path := filepath.Join(dir, node+"-hplusone.json")
	encoded, err := json.MarshalIndent(record, "", "  ")
	if err != nil {
		return err
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if errors.Is(err, os.ErrExist) {
		stored, readErr := os.ReadFile(path)
		if readErr != nil {
			return readErr
		}
		var prior incidentHPlusOneRecord
		if err := json.Unmarshal(stored, &prior); err != nil {
			return err
		}
		pin := prior.Verified
		proofPin := prior.Proof
		if err := checkIncidentHPlusOne(ctx, node, &prior); err != nil {
			return err
		}
		if pin != prior.Verified || proofPin != prior.Proof || prior.Verified != record.Verified ||
			!bytes.Equal(prior.Block, record.Block) || !bytes.Equal(prior.Commit, record.Commit) ||
			!bytes.Equal(prior.Validators, record.Validators) {
			return errors.New("observed or stored H+1 evidence differs from durable pin")
		}
	} else {
		if err != nil {
			return err
		}
		_, writeErr := file.Write(encoded)
		syncErr := file.Sync()
		closeErr := file.Close()
		if err := errors.Join(writeErr, syncErr, closeErr); err != nil {
			return err
		}
		directory, err := os.Open(dir)
		if err != nil {
			return err
		}
		syncErr = directory.Sync()
		closeErr = directory.Close()
		if err := errors.Join(syncErr, closeErr); err != nil {
			return err
		}
	}
	fmt.Fprintf(cmd.OutOrStdout(), "verified H+1 %s, signed power %d/%d; pinned %s\n", record.Verified.Block.BlockID, record.Proof.SignedPower, record.Proof.TotalPower, path)
	return nil
}

func checkIncidentHPlusOne(ctx context.Context, node string, record *incidentHPlusOneRecord) error {
	want := coregate.HPlusOneExpectation{
		RunID: "GNK-LAB-2026-0002-live", NodeID: node, ChainID: "gonka-devnet-community", Height: 814730,
		PreviousBlockID:     "52b5413d4650c80126e6222ca4aa6868cc6fba278e97d1188d9d5eee3a2a0efc",
		PreviousPartSetHash: "31254953c98ef1f55862fb23d5ac21e94e036c397ac1f11bbfe6724fba4cfb98", PreviousPartSetTotal: 1,
		HeaderAppHash: "ed4e4a7e57c0e336d1b749a21c367f9a2775d42f9aaf151824fc7032f3f4f4f4",
	}
	verified, err := coregate.VerifyPostStandardHPlusOne(ctx, record.Block, coregate.CometBFT03821BlockDecoder{BlockPartSize: 65536}, want)
	if err != nil {
		return err
	}
	// Anchor the H+1 validator set to the known H header's NextValidatorsHash,
	// not to a self-asserted validator set from the responding endpoint.
	var commitPB cmtproto.Commit
	if err := proto.Unmarshal(record.Commit, &commitPB); err != nil {
		return err
	}
	commit, err := cmttypes.CommitFromProto(&commitPB)
	if err != nil {
		return err
	}
	proof, err := (coregate.CometCommitVerifier{}).VerifySeenCommit(ctx, want.ChainID,
		record.Commit, record.Validators, verified.Block.BlockID, verified.Block.PartSetHash,
		verified.Block.PartSetTotal, 814731, hex.EncodeToString(commit.Hash()),
		"a656a4cab2ce176ee67c9824d8981c2e54668356c6630737bcbee695205ea5c0")
	if err != nil {
		return err
	}
	record.Verified, record.Proof = verified, proof
	return nil
}
