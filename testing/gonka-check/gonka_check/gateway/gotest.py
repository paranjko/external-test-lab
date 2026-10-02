"""Go test that gcheck writes into the gonka checkout: the upstream in-process session, measured per nonce."""

TEST_NAME = "TestGcheckGatewayLoad"
TEST_FILE = "devshard/user/gcheck_gateway_load_test.go"

GO_TEST = r'''//go:build stress

// Written by gonka-check (gcheck gateway-load stress); not part of the upstream tree.
// It reuses the stress fixtures of stress_test.go in this package.

package user

import (
    "context"
    "encoding/json"
    "fmt"
    "io"
    "os"
    "runtime"
    "strconv"
    "sync/atomic"
    "syscall"
    "testing"
    "time"

    "github.com/stretchr/testify/require"

    "devshard/host"
    "devshard/internal/testutil"
    "devshard/signing"
    "devshard/state"
    "devshard/stub"
    "devshard/types"
)

type gcheckTimedClient struct {
    inner *InProcessClient
    busy  *atomic.Int64
}

func (c *gcheckTimedClient) Send(ctx context.Context, req host.HostRequest, stream io.Writer,
    receiptHandler func(*host.HostResponse)) (*host.HostResponse, error) {
    type result struct {
        resp *host.HostResponse
        err  error
    }
    ch := make(chan result, 1)
    go func() {
        start := time.Now()
        resp, err := c.inner.Send(ctx, req, stream, receiptHandler)
        c.busy.Add(int64(time.Since(start)))
        ch <- result{resp, err}
    }()
    r := <-ch
    return r.resp, r.err
}

func gcheckEmit(kind string, fields map[string]any) {
    fields["kind"] = kind
    line, err := json.Marshal(fields)
    if err != nil {
        panic(err)
    }
    fmt.Fprintf(os.Stderr, "GCHECK %s\n", line)
}

func gcheckEnv(t *testing.T, name string) int {
    value, err := strconv.Atoi(os.Getenv(name))
    require.NoError(t, err, "%s must be a number", name)
    require.Positive(t, value, "%s must be positive", name)
    return value
}

func gcheckMsPer(d time.Duration, n int) float64 {
    return float64(d) / float64(time.Millisecond) / float64(n)
}

func gcheckSeconds(tv syscall.Timeval) float64 {
    return float64(tv.Sec) + float64(tv.Usec)/1e6
}

func TestGcheckGatewayLoad(t *testing.T) {
    numHosts := gcheckEnv(t, "GCHECK_HOSTS")
    nonces := gcheckEnv(t, "GCHECK_NONCES")
    every := gcheckEnv(t, "GCHECK_EVERY")
    runtime.GOMAXPROCS(runtime.NumCPU())

    grace := uint64(nonces + 100)
    balance := uint64(nonces)*actualCostPerInf + stressBalance

    hostSigners := make([]*signing.Secp256k1Signer, numHosts)
    for i := range hostSigners {
        hostSigners[i] = testutil.MustGenerateKey(t)
    }
    userKey := testutil.MustGenerateKey(t)
    group := testutil.MakeGroup(hostSigners)
    config := types.SessionConfig{
        RefusalTimeout:   60,
        ExecutionTimeout: 1200,
        TokenPrice:       1,
        VoteThreshold:    uint32(numHosts) / 2,
        ValidationRate:   1000,
        // A DevNet escrow ends before its records seal by the clock; a run of hours must not seal them either.
        InferenceSealGraceSeconds: 30 * 24 * 3600,
    }
    verifier := signing.NewSecp256k1Verifier()
    newSM := func() *state.StateMachine {
        store := testutil.MustMemoryStore(t, "escrow-gcheck", userKey.Address(), config, group, balance)
        sm, err := state.NewStateMachine("escrow-gcheck", config, group, balance, userKey.Address(), verifier, store)
        require.NoError(t, err)
        return sm
    }

    var hostBusy atomic.Int64
    clients := make([]HostClient, numHosts)
    for i := range hostSigners {
        h, err := host.NewHost(newSM(), hostSigners[i], stub.NewInferenceEngine(), "escrow-gcheck", group, nil,
            host.WithGrace(grace))
        require.NoError(t, err)
        clients[i] = &gcheckTimedClient{inner: &InProcessClient{Host: h}, busy: &hostBusy}
    }
    session, err := NewSession(newSM(), userKey, "escrow-gcheck", group, clients, verifier)
    require.NoError(t, err)

    // v5 hosts bind input_length to the prompt bytes and max_tokens to the body; the upstream fixture predates that.
    prompt := append([]byte(`{"max_tokens":100,`), stressPrompt[1:]...)
    ctx := context.Background()
    params := InferenceParams{
        Model:       stressModel,
        Prompt:      prompt,
        InputLength: uint64(len(prompt)),
        MaxTokens:   stressMaxTokens,
        StartedAt:   1000,
    }
    gcheckEmit("start", map[string]any{"hosts": numHosts, "nonces": nonces, "every": every,
        "cpus": runtime.NumCPU(), "go": runtime.Version(), "prompt_bytes": len(prompt)})

    var mem runtime.MemStats
    runStart := time.Now()
    bucketStart, bucketHost, bucketFrom := runStart, hostBusy.Load(), 0
    for i := 1; i <= nonces; i++ {
        _, err := session.SendInference(ctx, params)
        require.NoError(t, err, "inference %d failed", i)
        if i%every != 0 && i != nonces {
            continue
        }
        wall := time.Since(bucketStart)
        hostTime := time.Duration(hostBusy.Load() - bucketHost)
        n := i - bucketFrom
        runtime.ReadMemStats(&mem)
        live, _ := session.StateMachine().InferenceStatusCounts()
        gcheckEmit("checkpoint", map[string]any{"hosts": numHosts, "nonce": i,
            "gateway_ms": gcheckMsPer(wall-hostTime, n), "host_ms": gcheckMsPer(hostTime, n),
            "wall_ms": gcheckMsPer(wall, n), "heap_mb": float64(mem.HeapAlloc) / (1 << 20),
            "elapsed_s": time.Since(runStart).Seconds(), "live": live,
            "sealed": session.StateMachine().SealedNonceCount()})
        bucketStart, bucketHost, bucketFrom = time.Now(), hostBusy.Load(), i
    }
    loopWall := time.Since(runStart)
    loopHost := time.Duration(hostBusy.Load())

    peak := session.StateMachine().SnapshotState()
    rootStart := time.Now()
    _, err = state.ComputeStateRoot(peak.Balance, peak.HostStats, peak.Inferences, peak.Phase, peak.WarmKeys,
        peak.Fees, peak.StateRootAndProtocolVersion)
    require.NoError(t, err)
    rootTime := time.Since(rootStart)
    hostStatsMB, inferencesMB, stateMB := measureStateSize(peak)
    diffHistoryMB := measureDiffHistorySize(session.Diffs())

    finStart, finHost := time.Now(), hostBusy.Load()
    require.NoError(t, session.Finalize(ctx))
    finWall := time.Since(finStart)
    finHostTime := time.Duration(hostBusy.Load() - finHost)

    st := session.StateMachine().SnapshotState()
    finalNonce := session.Nonce()
    sigs, ok := session.Signatures()[finalNonce]
    require.True(t, ok, "no signatures at final nonce %d", finalNonce)
    settleStart := time.Now()
    payload, err := state.BuildSettlement("escrow-gcheck", st, sigs, finalNonce)
    require.NoError(t, err)
    settleTime := time.Since(settleStart)
    _, err = state.VerifySettlement(*payload, group, verifier, nil)
    require.NoError(t, err)
    require.Equal(t, balance-uint64(nonces)*actualCostPerInf, st.Balance, "balance after settlement")
    require.Equal(t, numHosts, len(sigs), "signatures at the final nonce")
    require.Equal(t, nonces+numHosts+1, len(session.Diffs()), "diffs")

    var ru syscall.Rusage
    require.NoError(t, syscall.Getrusage(syscall.RUSAGE_SELF, &ru))
    rssMB := float64(ru.Maxrss) / 1024
    if runtime.GOOS == "darwin" {
        rssMB /= 1024
    }
    gcheckEmit("summary", map[string]any{"hosts": numHosts, "nonces": nonces, "final_nonce": finalNonce,
        "diffs": len(session.Diffs()), "signatures": len(sigs),
        "loop_s": loopWall.Seconds(), "loop_host_s": loopHost.Seconds(),
        "loop_gateway_s": (loopWall - loopHost).Seconds(),
        "state_root_ms": float64(rootTime) / float64(time.Millisecond), "finalize_s": finWall.Seconds(),
        "finalize_host_s": finHostTime.Seconds(), "settlement_ms": float64(settleTime) / float64(time.Millisecond),
        "state_mb": stateMB, "inferences_mb": inferencesMB, "host_stats_kb": hostStatsMB * 1024,
        "diff_history_mb": diffHistoryMB, "user_cpu_s": gcheckSeconds(ru.Utime), "sys_cpu_s": gcheckSeconds(ru.Stime),
        "max_rss_mb": rssMB})
}
'''
