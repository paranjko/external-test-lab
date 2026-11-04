package session

import (
	"context"
	"maps"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"devshard/bridge"
	"devshard/host"
	"devshard/internal/testutil"
	"devshard/observability"
	"devshard/signing"
	"devshard/storage"
	"devshard/stub"
	"devshard/types"
)

const (
	restartEscrowID  = "1"
	restartGroupSize = 16
)

// Slots of the validator under test, in the nonce order of their first inference.
var restartOwnSlots = []uint32{8, 9, 13, 0}

// restartWarmBridge grants one warm key to one validator, like the chain authz
// grant a real host signs under.
type restartWarmBridge struct {
	mockBridge
	warm, cold string
}

func (b *restartWarmBridge) VerifyWarmKey(warm, cold string) (bool, error) {
	return warm == b.warm && cold == b.cold, nil
}

// restartClient plays the gateway: it signs diffs and carries host mempool txs.
type restartClient struct {
	t     *testing.T
	user  *signing.Secp256k1Signer
	nonce uint64
}

// runInference advances to the next nonce executed by slot and sends it to h.
func (c *restartClient) runInference(h *host.Host, slot uint32) *host.HostResponse {
	c.t.Helper()
	target := c.nonce + 1
	for target%restartGroupSize != uint64(slot) {
		target++
	}
	var diffs []types.Diff
	pending := orderedMempool(h)
	for n := c.nonce + 1; n <= target; n++ {
		var txs []*types.DevshardTx
		if n == c.nonce+1 {
			txs = append(txs, pending...)
		}
		if n == target {
			txs = append(txs, testutil.StartTx(n))
		}
		diffs = append(diffs, testutil.SignDiff(c.t, c.user, restartEscrowID, n, txs))
	}
	c.nonce = target
	resp, err := h.HandleRequest(context.Background(), host.HostRequest{
		Diffs: diffs,
		Nonce: target,
		Payload: &host.InferencePayload{
			Prompt:      testutil.TestPrompt,
			Model:       "llama",
			InputLength: 100,
			MaxTokens:   testutil.TestMaxTokens,
			StartedAt:   1000,
		},
	})
	require.NoError(c.t, err)
	if resp.ExecutionJob != nil {
		_, err := h.RunExecution(context.Background(), resp.ExecutionJob)
		require.NoError(c.t, err)
	}
	return resp
}

// orderedMempool puts ConfirmStart before FinishInference, as the user session does:
// the state machine rejects a finish for an inference that has not started.
func orderedMempool(h *host.Host) []*types.DevshardTx {
	txs := h.MempoolTxs()
	rank := func(tx *types.DevshardTx) int {
		switch {
		case tx.GetConfirmStart() != nil:
			return 0
		case tx.GetFinishInference() != nil:
			return 1
		default:
			return 2
		}
	}
	slices.SortStableFunc(txs, func(a, b *types.DevshardTx) int { return rank(a) - rank(b) })
	return txs
}

// commitNext sends one more diff carrying whatever the host has in its mempool.
func (c *restartClient) commitNext(h *host.Host) {
	c.t.Helper()
	c.nonce++
	diff := testutil.SignDiff(c.t, c.user, restartEscrowID, c.nonce, orderedMempool(h))
	_, err := h.HandleRequest(context.Background(), host.HostRequest{Diffs: []types.Diff{diff}, Nonce: c.nonce})
	require.NoError(c.t, err)
}

func restartSessionHost(t *testing.T, mgr *HostManager) *host.Host {
	t.Helper()
	mgr.sessionsMutex.RLock()
	defer mgr.sessionsMutex.RUnlock()
	srv, ok := mgr.sessions[restartEscrowID]
	require.True(t, ok, "session must exist after recovery")
	return srv.Host()
}

// A host process restart must not change which slots of an open escrow the host
// serves. Each case runs a session through the production create and
// RecoverSessions paths on a SQLite file reopened from disk.
func TestHostRestartKeepsAllSlots(t *testing.T) {
	cases := []struct {
		name             string
		warmKey          bool
		runBeforeRestart bool
		snapshot         bool
		abruptStop       bool
	}{
		{name: "cold-key-journal-replay", runBeforeRestart: true},
		{name: "warm-key-no-inference-before-restart", warmKey: true},
		{name: "warm-key-journal-replay", warmKey: true, runBeforeRestart: true},
		{name: "warm-key-snapshot-and-tail", warmKey: true, runBeforeRestart: true, snapshot: true},
		{name: "warm-key-without-graceful-close", warmKey: true, runBeforeRestart: true, abruptStop: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cold := mustGenerateKey(t)
			warm := mustGenerateKey(t)
			user := mustGenerateKey(t)
			others := []*signing.Secp256k1Signer{mustGenerateKey(t), mustGenerateKey(t), mustGenerateKey(t)}

			addresses := make([]string, restartGroupSize)
			for i := range addresses {
				addresses[i] = others[i%len(others)].Address()
			}
			wantSlots := make(map[uint32]bool, len(restartOwnSlots))
			for _, slot := range restartOwnSlots {
				addresses[slot] = cold.Address()
				wantSlots[slot] = true
			}

			br := &restartWarmBridge{cold: cold.Address()}
			br.escrow = &bridge.EscrowInfo{
				EscrowID:       restartEscrowID,
				Amount:         1_000_000_000,
				CreatorAddress: user.Address(),
				Slots:          addresses,
				EpochID:        7,
			}
			signer := cold
			if tc.warmKey {
				signer = warm
				br.warm = warm.Address()
			}

			dbPath := filepath.Join(t.TempDir(), "devshard.db")
			store, err := storage.NewSQLite(dbPath)
			require.NoError(t, err)
			newManager := func(s storage.Storage) *HostManager {
				return NewHostManager(s, signer, stub.NewInferenceEngine(), stub.NewValidationEngine(), nil, testutil.RuntimeTestVersion, br, nil, nil)
			}

			mgr := newManager(store)
			srv, err := mgr.SessionServer(restartEscrowID)
			require.NoError(t, err)
			live := srv.Host()
			require.Equal(t, wantSlots, live.SlotIDs(), "fresh host must own all its slots")

			client := &restartClient{t: t, user: user}
			if tc.runBeforeRestart {
				for _, slot := range restartOwnSlots {
					resp := client.runInference(live, slot)
					require.Equal(t, observability.ReasonOK, resp.ReceiptReason, "live slot %d", slot)
					require.True(t, resp.ExecutionExpected, "live slot %d", slot)
				}
				client.commitNext(live)
			}
			if tc.snapshot {
				for client.nonce < host.SnapshotInterval+5 {
					client.commitNext(live)
				}
				snapNonce, _, err := store.LoadSnapshot(restartEscrowID)
				require.NoError(t, err)
				require.EqualValues(t, host.SnapshotInterval, snapNonce)
			}
			bindings := live.SnapshotState().WarmKeys
			t.Logf("before restart: slots=%v warm-key bindings=%d %v", slices.Sorted(maps.Keys(live.SlotIDs())), len(bindings), slices.Sorted(maps.Keys(bindings)))

			if tc.abruptStop {
				t.Cleanup(func() { _ = mgr.Close() })
			} else {
				require.NoError(t, mgr.Close())
			}

			// The closing WAL can hold the file for a moment.
			var reopened *storage.SQLite
			require.Eventually(t, func() bool {
				var err error
				reopened, err = storage.NewSQLite(dbPath)
				return err == nil
			}, 5*time.Second, 50*time.Millisecond, "reopen store")
			restarted := waitRecoveryRepairsOnCleanup(t, newManager(reopened))
			t.Cleanup(func() { _ = restarted.Close() })
			require.NoError(t, restarted.RecoverSessions())

			recovered := restartSessionHost(t, restarted)
			require.Equal(t, client.nonce, recovered.LatestNonce(), "recovery must keep committed state")
			t.Logf("after restart: slots=%v", slices.Sorted(maps.Keys(recovered.SlotIDs())))
			assert.Equal(t, wantSlots, recovered.SlotIDs(), "restart must not change the slots of an open escrow")

			for _, slot := range restartOwnSlots {
				resp := client.runInference(recovered, slot)
				t.Logf("after restart: slot %d receipt reason=%s", slot, resp.ReceiptReason)
				assert.Equal(t, observability.ReasonOK, resp.ReceiptReason, "slot %d after restart", slot)
				assert.True(t, resp.ExecutionExpected, "slot %d after restart", slot)
			}
		})
	}
}
