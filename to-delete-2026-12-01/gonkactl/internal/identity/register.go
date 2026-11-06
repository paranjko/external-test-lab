package identity

import "errors"

// RegisterFresh refuses overwrite: callers must read and compare an existing
// stable identity before a resume; incompatible state is never regenerated.
func RegisterFresh(existing *FreshStableKeys, next FreshStableKeys) (FreshStableKeys, error) {
	if err := ValidateFreshStableKeys(next); err != nil {
		return FreshStableKeys{}, err
	}
	if existing != nil {
		if err := ValidateFreshStableKeys(*existing); err != nil {
			return FreshStableKeys{}, err
		}
		if *existing != next {
			return FreshStableKeys{}, errors.New("stable identity already exists")
		}
		return *existing, nil
	}
	return next, nil
}
