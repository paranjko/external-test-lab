package storage

// This lab fixture is overlaid on the frozen upstream test package. It never
// changes the reference checkout or connects to stand databases.
import (
	"context"
	"errors"
	"testing"
	"time"

	"devshard/storage/pgtest"
	"devshard/types"
	"github.com/stretchr/testify/require"
)

func labPostgres(t *testing.T) *Postgres {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
	defer cancel()
	container, err := pgtest.Run(ctx)
	require.NoError(t, err) // Docker unavailable is FAIL, never SKIP.
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		require.NoError(t, container.Terminate(ctx))
	})
	host, err := container.Host(ctx)
	require.NoError(t, err)
	port, err := container.MappedPort(ctx, "5432/tcp")
	require.NoError(t, err)
	t.Setenv("PGHOST", host)
	t.Setenv("PGPORT", port.Port())
	t.Setenv("PGDATABASE", "testdb")
	t.Setenv("PGUSER", "testuser")
	t.Setenv("PGPASSWORD", "testpass")
	pg, err := NewPostgres(ctx)
	require.NoError(t, err)
	t.Cleanup(func() { _ = pg.Close() })
	require.NoError(t, pg.WaitReady(ctx))
	return pg
}

func labSQLite(t *testing.T) *SQLite {
	t.Helper()
	src, err := NewSQLite(t.TempDir())
	require.NoError(t, err)
	t.Cleanup(func() { _ = src.Close() })
	require.NoError(t, src.CreateSession(paramsForEpoch("lab-migrate", 3)))
	for nonce := uint64(1); nonce <= 3; nonce++ {
		require.NoError(t, src.AppendDiff("lab-migrate", makeDiffRecord(nonce)))
	}
	require.NoError(t, src.MarkFinalized("lab-migrate", 3))
	require.NoError(t, src.SaveSnapshot("lab-migrate", 3, []byte("retained-snapshot")))
	return src
}

type interruptedLabDestination struct {
	Storage
	calls int
}

func (d *interruptedLabDestination) AppendDiffs(id string, diffs []types.DiffRecord) error {
	d.calls++
	if d.calls == 2 {
		return errors.New("lab injected interruption after first persisted chunk")
	}
	for _, diff := range diffs {
		if err := d.Storage.AppendDiff(id, diff); err != nil {
			return err
		}
	}
	return nil
}

func TestV6HAMigrationPostgresResumeAndSecondClient(t *testing.T) {
	pg := labPostgres(t)
	src := labSQLite(t)
	t.Setenv("DEVSHARD_MIGRATE_DIFF_CHUNK", "1")
	_, err := MigrateSQLiteSessions(src, &interruptedLabDestination{Storage: pg})
	require.ErrorContains(t, err, "lab injected interruption")
	meta, err := pg.GetSessionMeta("lab-migrate")
	require.NoError(t, err)
	require.Equal(t, uint64(1), meta.LatestNonce)
	for i := 0; i < 2; i++ {
		n, err := MigrateSQLiteSessions(src, pg)
		require.NoError(t, err)
		require.Equal(t, 1, n)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	second, err := NewPostgres(ctx)
	require.NoError(t, err)
	defer second.Close()
	require.NoError(t, second.WaitReady(ctx))
	want, err := src.GetDiffs("lab-migrate", 1, 3)
	require.NoError(t, err)
	got, err := second.GetDiffs("lab-migrate", 1, 3)
	require.NoError(t, err)
	require.Equal(t, want, got)
	nonce, data, err := second.LoadSnapshot("lab-migrate")
	require.NoError(t, err)
	require.Equal(t, uint64(3), nonce)
	require.Equal(t, []byte("retained-snapshot"), data)
	finalized, err := second.LastFinalized("lab-migrate")
	require.NoError(t, err)
	require.Equal(t, uint64(3), finalized)
}

func TestV6HAMigrationPostgresConflictPreservesSource(t *testing.T) {
	pg := labPostgres(t)
	src := labSQLite(t)
	require.NoError(t, pg.CreateSession(paramsForEpoch("lab-migrate", 4)))
	_, err := MigrateSQLiteSessions(src, pg)
	require.ErrorIs(t, err, ErrSessionEpochConflict)
	meta, err := src.GetSessionMeta("lab-migrate")
	require.NoError(t, err)
	require.Equal(t, uint64(3), meta.EpochID)
	require.Equal(t, uint64(3), meta.LatestNonce)
}

func TestV6HAMigrationPostgresClosedDestinationFails(t *testing.T) {
	pg := labPostgres(t)
	src := labSQLite(t)
	require.NoError(t, pg.Close())
	_, err := MigrateSQLiteSessions(src, pg)
	require.Error(t, err)
	_, err = src.GetSessionMeta("lab-migrate")
	require.NoError(t, err)
}
