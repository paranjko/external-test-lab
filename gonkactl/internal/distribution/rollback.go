package distribution

import "fmt"

func RollbackTarget(current, prior string, verified map[string]bool) (string, error) {
	if prior == "" || !verified[prior] {
		return "", fmt.Errorf("prior release is not retained and verified")
	}
	if current == prior {
		return "", fmt.Errorf("already current")
	}
	return prior, nil
}
