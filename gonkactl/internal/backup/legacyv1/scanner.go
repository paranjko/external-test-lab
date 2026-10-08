// Package legacyv1 reads the narrow v1 USTAR producer format without generic
// extraction. PAX/GNU extensions are rejected at raw-header level.
package legacyv1

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/backup/model"
	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

var ErrInvalidArchive = errors.New("invalid legacy v1 archive")

func Scan(r io.Reader) (model.Archive, error) {
	data, err := io.ReadAll(io.LimitReader(r, MaxArchiveBytes+1))
	if err != nil {
		return model.Archive{}, err
	}
	if len(data) < MinArchiveBytes || len(data) > MaxArchiveBytes || len(data)%BlockSize != 0 {
		return model.Archive{}, ErrInvalidArchive
	}
	archive := model.Archive{ScannedAt: time.Now().UTC()}
	seen := map[string]bool{}
	dirs := map[string]bool{}
	total := 0
	offset := 0
	for offset < len(data) {
		header := data[offset : offset+BlockSize]
		if zeroBlock(header) {
			trailing := len(data) - offset
			if trailing < MinArchiveBytes || trailing > MaxTrailingBytes || !allZero(data[offset:]) {
				return model.Archive{}, ErrInvalidArchive
			}
			return archive, nil
		}
		if err := validChecksum(header); err != nil || string(header[257:262]) != "ustar" {
			return model.Archive{}, ErrInvalidArchive
		}
		name, err := headerPath(header)
		if err != nil {
			return model.Archive{}, err
		}
		typeFlag := header[156]
		if typeFlag != 0 && typeFlag != '0' && typeFlag != '5' {
			return model.Archive{}, ErrInvalidArchive
		}
		size, err := octal(header[124:136])
		if err != nil || size > MaxMemberBytes {
			return model.Archive{}, ErrInvalidArchive
		}
		if typeFlag == '5' && size != 0 {
			return model.Archive{}, ErrInvalidArchive
		}
		if seen[name] || !parentBeforeChild(name, dirs) || !allowed(name, typeFlag == '5') {
			return model.Archive{}, ErrInvalidArchive
		}
		seen[name] = true
		if typeFlag == '5' {
			dirs[name] = true
		}
		total += size
		if len(seen) > MaxMembers || total > MaxTotalMemberBytes {
			return model.Archive{}, ErrInvalidArchive
		}
		bodyStart := offset + BlockSize
		blocks := (size + BlockSize - 1) / BlockSize
		bodyEnd := bodyStart + size
		if bodyEnd < bodyStart || bodyStart+blocks*BlockSize > len(data) {
			return model.Archive{}, ErrInvalidArchive
		}
		member := model.Member{Path: name, Dir: typeFlag == '5'}
		if !member.Dir {
			member.Data = append([]byte(nil), data[bodyStart:bodyEnd]...)
		}
		archive.Members = append(archive.Members, member)
		offset = bodyStart + blocks*BlockSize
	}
	return model.Archive{}, ErrInvalidArchive
}

func ScanSnapshot(ctx context.Context, snapshot contracts.Snapshot, request contracts.SnapshotRequest) (model.Archive, error) {
	if snapshot == nil {
		return model.Archive{}, errors.New("snapshot is required")
	}
	file, err := snapshot.Copy(ctx, request)
	if err != nil {
		return model.Archive{}, err
	}
	defer file.Close()
	reader, err := file.Open()
	if err != nil {
		return model.Archive{}, err
	}
	defer reader.Close()
	archive, err := Scan(reader)
	if err != nil {
		return model.Archive{}, err
	}
	archive.SnapshotSHA256 = file.SHA256()
	return archive, nil
}

func validChecksum(header []byte) error {
	stored, err := octal(header[148:156])
	if err != nil {
		return err
	}
	actual := 0
	for i, value := range header {
		if i >= 148 && i < 156 {
			actual += 32
		} else {
			actual += int(value)
		}
	}
	if actual != stored {
		return ErrInvalidArchive
	}
	return nil
}

func headerPath(header []byte) (string, error) {
	name := trimNUL(header[:100])
	prefix := trimNUL(header[345:500])
	path := name
	if prefix != "" {
		path = prefix + "/" + name
	}
	path = strings.TrimSuffix(path, "/")
	if path == "" || strings.HasPrefix(path, "/") || strings.Contains(path, `\\`) || strings.Contains(path, `//`) {
		return "", ErrInvalidArchive
	}
	for _, part := range strings.Split(path, "/") {
		if part == "" || part == "." || part == ".." {
			return "", ErrInvalidArchive
		}
		for _, char := range part {
			if !((char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z') || (char >= '0' && char <= '9') || strings.ContainsRune("._-", char)) {
				return "", ErrInvalidArchive
			}
		}
	}
	return path, nil
}

func parentBeforeChild(path string, dirs map[string]bool) bool {
	parent := path[:strings.LastIndex(path, "/")+1]
	parent = strings.TrimSuffix(parent, "/")
	return parent == "" || dirs[parent]
}

func allowed(path string, dir bool) bool {
	if path == "mnemonics" || path == "remote-state" || path == "remote-state/tmkms" || path == "remote-state/tmkms/secrets" || path == "remote-state/tmkms/state" || path == "remote-state/inference" || path == "remote-state/inference/config" {
		return dir
	}
	if path == "manifest.json" || path == "manifest.sha256" || path == "identity.json" || path == "remote-state/inference/config/node_key.json" || strings.HasPrefix(path, "mnemonics/") {
		return !dir
	}
	return strings.HasPrefix(path, "remote-state/tmkms/")
}

func octal(field []byte) (int, error) {
	text := strings.Trim(string(field), " \x00")
	if text == "" {
		return 0, nil
	}
	value := 0
	for _, char := range text {
		if char < '0' || char > '7' {
			return 0, ErrInvalidArchive
		}
		if value > (int(^uint(0)>>1)-int(char-'0'))/8 {
			return 0, ErrInvalidArchive
		}
		value = value*8 + int(char-'0')
	}
	return value, nil
}
func trimNUL(value []byte) string {
	if index := strings.IndexByte(string(value), 0); index >= 0 {
		value = value[:index]
	}
	return string(value)
}
func zeroBlock(value []byte) bool {
	for _, char := range value {
		if char != 0 {
			return false
		}
	}
	return true
}
func allZero(value []byte) bool {
	for _, char := range value {
		if char != 0 {
			return false
		}
	}
	return true
}
func Digest(data []byte) string { sum := sha256.Sum256(data); return hex.EncodeToString(sum[:]) }

var _ = fmt.Sprintf
