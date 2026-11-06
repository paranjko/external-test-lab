package backup

import (
	"archive/tar"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"sort"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/backup/model"
)

// Encode renders a stable USTAR stream. Archive content is supplied verbatim;
// no identity, mnemonic, or signer state is transformed during backup.
func Encode(members []model.Member) ([]byte, string, error) {
	ordered, err := Capture(members)
	if err != nil {
		return nil, "", err
	}
	sort.SliceStable(ordered, func(i, j int) bool { return ordered[i].Path < ordered[j].Path })
	var out bytes.Buffer
	w := tar.NewWriter(&out)
	for _, member := range ordered {
		h := &tar.Header{Name: member.Path, Mode: 0o600, Format: tar.FormatUSTAR, ModTime: time.Unix(0, 0).UTC()}
		if member.Dir {
			h.Typeflag, h.Mode = tar.TypeDir, 0o700
		} else {
			h.Typeflag, h.Size = tar.TypeReg, int64(len(member.Data))
		}
		if err := w.WriteHeader(h); err != nil {
			return nil, "", err
		}
		if !member.Dir {
			if _, err := w.Write(member.Data); err != nil {
				return nil, "", err
			}
		}
	}
	if err := w.Close(); err != nil {
		return nil, "", err
	}
	data := out.Bytes()
	sum := sha256.Sum256(data)
	return data, hex.EncodeToString(sum[:]), nil
}
