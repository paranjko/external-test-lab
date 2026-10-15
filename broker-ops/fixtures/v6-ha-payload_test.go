package storage

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"common/storage/payloads"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/stretchr/testify/require"
)

func TestV6HAMigrationPostgresPayloadRoundTrip(t *testing.T) {
	_ = labPostgres(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, "")
	require.NoError(t, err)
	defer pool.Close()
	dest, err := payloads.New(ctx, pool)
	require.NoError(t, err)
	for _, compressed := range []bool{false, true} {
		dir := t.TempDir()
		src := payloads.NewFileStorage(dir)
		escrow := "plain"
		if compressed {
			src = payloads.NewCompressingFileStorage(dir)
			escrow = "compressed"
		}
		require.NoError(t, src.Store(ctx, escrow, 1, 3, []byte("prompt"), []byte("response")))
		n, err := payloads.MigrateFilePayloadsToPostgres(ctx, dir, dest)
		require.NoError(t, err)
		require.Equal(t, 1, n)
		prompt, response, err := dest.Retrieve(ctx, escrow, 1, 3)
		require.NoError(t, err)
		require.Equal(t, []byte("prompt"), prompt)
		require.Equal(t, []byte("response"), response)
		require.NoDirExists(t, filepath.Join(dir, "3"))
		n, err = payloads.MigrateFilePayloadsToPostgres(ctx, dir, dest)
		require.NoError(t, err)
		require.Zero(t, n)
	}
}

// This characterizes a known unsafe input, not a passing HA activation gate.
// Live activation must refuse differing destination payloads before migration.
func TestV6HAMigrationPostgresPayloadConflictRequiresPreflight(t *testing.T) {
	_ = labPostgres(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, "")
	require.NoError(t, err)
	defer pool.Close()
	dest, err := payloads.New(ctx, pool)
	require.NoError(t, err)
	dir := t.TempDir()
	src := payloads.NewFileStorage(dir)
	require.NoError(t, src.Store(ctx, "conflict", 1, 3, []byte("source"), []byte("source-response")))
	require.NoError(t, dest.Store(ctx, "conflict", 1, 3, []byte("other"), []byte("other-response")))
	n, err := payloads.MigrateFilePayloadsToPostgres(ctx, dir, dest)
	require.NoError(t, err)
	require.Equal(t, 1, n)
	prompt, response, err := dest.Retrieve(ctx, "conflict", 1, 3)
	require.NoError(t, err)
	require.Equal(t, []byte("other"), prompt)
	require.Equal(t, []byte("other-response"), response)
	require.NoDirExists(t, filepath.Join(dir, "3"))
	t.Log("UNSAFE INPUT confirmed: importer quarantines source despite different destination payload; live preflight required")
}
