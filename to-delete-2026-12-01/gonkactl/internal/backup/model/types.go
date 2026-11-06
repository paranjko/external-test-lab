package model

import "time"

type Member struct {
	Path string
	Data []byte
	Dir  bool
}

// Archive contains only validated in-memory members from the private snapshot.
// It has no extraction target and therefore cannot mutate a restore location.
type Archive struct {
	Members        []Member
	SnapshotSHA256 string
	ScannedAt      time.Time
}

// VerifiedArchive is the validated legacy archive identity handed to restore
// code. Decimal HRS values remain strings until exact comparison.
type VerifiedArchive struct {
	Archive       Archive
	NodeName      string
	ChainID       string
	GenesisSHA256 string
	SigningState  SigningState
}

type SigningState struct {
	Height  string
	Round   string
	Step    int8
	BlockID *BlockID
}

// BlockID is nil only when the legacy signing-state JSON used null.
type BlockID struct {
	Hash       string
	PartsTotal uint32
	PartsHash  string
}

func (a Archive) Member(path string) (Member, bool) {
	for _, member := range a.Members {
		if member.Path == path {
			return member, true
		}
	}
	return Member{}, false
}
