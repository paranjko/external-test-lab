package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"common/storage/payloads"
	"devshard/storage/pgtest"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/stretchr/testify/require"
)

func TestReadOnlyPayloadPreflight(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
	defer cancel()
	container, err := pgtest.Run(ctx)
	require.NoError(t, err)
	defer func() { require.NoError(t, container.Terminate(context.Background())) }()
	host, err := container.Host(ctx)
	require.NoError(t, err)
	port, err := container.MappedPort(ctx, "5432/tcp")
	require.NoError(t, err)
	for key, value := range map[string]string{"PGHOST": host, "PGPORT": port.Port(), "PGDATABASE": "testdb", "PGUSER": "testuser", "PGPASSWORD": "testpass"} {
		t.Setenv(key, value)
	}
	conn, err := pgx.Connect(ctx, "")
	require.NoError(t, err)
	defer conn.Close(ctx)
	_, err = check(ctx, t.TempDir(), conn)
	require.ErrorContains(t, err, "schema unavailable")
	pool, err := pgxpool.New(ctx, "")
	require.NoError(t, err)
	defer pool.Close()
	dest, err := payloads.New(ctx, pool)
	require.NoError(t, err)
	for _, compressed := range []bool{false, true} {
		name := "plain"
		if compressed {
			name = "compressed"
		}
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			source := payloads.NewFileStorage(dir)
			if compressed {
				source = payloads.NewCompressingFileStorage(dir)
			}
			require.NoError(t, source.Store(ctx, name, 1, 3, []byte("prompt"), []byte("response")))
			got, err := check(ctx, dir, conn)
			require.NoError(t, err)
			require.Equal(t, report{Checked: 1, Absent: 1}, got)
			var count int
			require.NoError(t, conn.QueryRow(ctx, "SELECT count(*) FROM public.payload_storage WHERE escrow_id=$1", name).Scan(&count))
			require.Zero(t, count)
			require.NoError(t, dest.Store(ctx, name, 1, 3, []byte("prompt"), []byte("response")))
			got, err = check(ctx, dir, conn)
			require.NoError(t, err)
			require.Equal(t, report{Checked: 1, Identical: 1}, got)
			_, err = conn.Exec(ctx, "UPDATE public.payload_storage SET response_payload=$1 WHERE escrow_id=$2", []byte("different"), name)
			require.NoError(t, err)
			_, err = check(ctx, dir, conn)
			require.ErrorContains(t, err, "payload conflict")
			prompt, response, err := source.Retrieve(ctx, name, 1, 3)
			require.NoError(t, err)
			require.Equal(t, []byte("prompt"), prompt)
			require.Equal(t, []byte("response"), response)
			_, response, err = dest.Retrieve(ctx, name, 1, 3)
			require.NoError(t, err)
			require.Equal(t, []byte("different"), response)
			require.DirExists(t, filepath.Join(dir, "3"))
		})
	}
	t.Run("unsafe-source", func(t *testing.T) {
		dir := t.TempDir()
		require.NoError(t, os.Symlink(t.TempDir(), filepath.Join(dir, "3")))
		_, err := check(ctx, dir, conn)
		require.ErrorContains(t, err, "symlink")
	})
	t.Run("duplicate-formats", func(t *testing.T) {
		dir := t.TempDir()
		require.NoError(t, payloads.NewFileStorage(dir).Store(ctx, "duplicate", 1, 3, []byte("a"), nil))
		other := t.TempDir()
		require.NoError(t, payloads.NewCompressingFileStorage(other).Store(ctx, "duplicate", 1, 3, []byte("b"), nil))
		compressed, err := os.ReadFile(filepath.Join(other, "3", "duplicate", "1.json.zst"))
		require.NoError(t, err)
		require.NoError(t, os.WriteFile(filepath.Join(dir, "3", "duplicate", "1.json.zst"), compressed, 0600))
		_, err = check(ctx, dir, conn)
		require.ErrorContains(t, err, "duplicate")
	})
	t.Run("invalid-source", func(t *testing.T) {
		_, err := check(ctx, filepath.Join(t.TempDir(), "missing"), conn)
		require.ErrorContains(t, err, "missing or unsafe")
	})
}
