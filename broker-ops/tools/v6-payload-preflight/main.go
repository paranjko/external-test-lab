// Read-only payload compatibility check against the frozen v6 storage format.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"common/storage/payloads"
	"github.com/jackc/pgx/v5"
)

type report struct {
	Checked   int `json:"checked"`
	Absent    int `json:"absent"`
	Identical int `json:"identical"`
}

func canonicalNumber(s string) (uint64, error) {
	n, err := strconv.ParseUint(s, 10, 63)
	if err != nil || strconv.FormatUint(n, 10) != s {
		return 0, errors.New("noncanonical numeric path")
	}
	return n, nil
}

// A read-only repeatable snapshot prevents accidental DDL and destination writes.
// Writers must still be stopped before using this result for a migration decision.
func check(ctx context.Context, dir string, conn *pgx.Conn) (report, error) {
	var result report
	info, err := os.Lstat(dir)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return result, errors.New("source directory missing or unsafe")
	}
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return result, errors.New("cannot open read-only destination snapshot")
	}
	defer tx.Rollback(context.Background())
	var tableExists bool
	if err := tx.QueryRow(ctx, "SELECT to_regclass('public.payload_storage') IS NOT NULL").Scan(&tableExists); err != nil || !tableExists {
		return result, errors.New("destination payload schema unavailable")
	}
	source := payloads.NewFileStorage(dir)
	seen := map[string]bool{}
	err = filepath.WalkDir(dir, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return errors.New("cannot enumerate source")
		}
		if path == dir {
			return nil
		}
		if entry.Type()&os.ModeSymlink != 0 {
			return errors.New("source symlink refused")
		}
		rel, err := filepath.Rel(dir, path)
		if err != nil {
			return errors.New("invalid source path")
		}
		parts := strings.Split(rel, string(filepath.Separator))
		if len(parts) > 3 {
			return errors.New("unexpected source depth")
		}
		epoch, err := canonicalNumber(parts[0])
		if err != nil {
			return err
		}
		if len(parts) < 3 {
			if !entry.IsDir() {
				return errors.New("unexpected source file")
			}
			if len(parts) == 2 && (strings.Contains(parts[1], "..") || strings.Contains(parts[1], "\\") || strings.TrimSpace(parts[1]) != parts[1]) {
				return errors.New("unsafe escrow directory")
			}
			return nil
		}
		if !entry.Type().IsRegular() {
			return errors.New("nonregular payload refused")
		}
		name := parts[2]
		if strings.HasSuffix(name, ".json.zst") {
			name = strings.TrimSuffix(name, ".json.zst")
		} else if strings.HasSuffix(name, ".json") {
			name = strings.TrimSuffix(name, ".json")
		} else {
			return errors.New("unexpected payload suffix")
		}
		id, err := canonicalNumber(name)
		if err != nil || id > 2147483647 {
			return errors.New("payload ID outside destination integer range")
		}
		key := parts[0] + "/" + parts[1] + "/" + name
		if seen[key] {
			return errors.New("ambiguous duplicate payload formats")
		}
		seen[key] = true
		prompt, response, err := source.Retrieve(ctx, parts[1], id, epoch)
		if err != nil {
			return errors.New("source payload unreadable")
		}
		var pgPrompt, pgResponse []byte
		err = tx.QueryRow(ctx, "SELECT prompt_payload,response_payload FROM public.payload_storage WHERE escrow_id=$1 AND inference_id=$2 AND epoch_id=$3", parts[1], int64(id), int64(epoch)).Scan(&pgPrompt, &pgResponse)
		if errors.Is(err, pgx.ErrNoRows) {
			result.Absent++
		} else if err != nil {
			return errors.New("destination payload read failed")
		} else if !bytes.Equal(prompt, pgPrompt) || !bytes.Equal(response, pgResponse) {
			return errors.New("payload conflict: destination differs from source")
		} else {
			result.Identical++
		}
		result.Checked++
		return nil
	})
	return result, err
}

func main() {
	dir := flag.String("source", "", "offline payload directory; never modified")
	flag.Parse()
	if *dir == "" || flag.NArg() != 0 {
		fmt.Fprintln(os.Stderr, "required: -source PATH; PostgreSQL credentials via PG environment")
		os.Exit(2)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	conn, err := pgx.Connect(ctx, "")
	if err != nil {
		fmt.Fprintln(os.Stderr, "destination connection failed")
		os.Exit(1)
	}
	defer conn.Close(context.Background())
	result, err := check(ctx, filepath.Clean(*dir), conn)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	_ = json.NewEncoder(os.Stdout).Encode(result)
}
