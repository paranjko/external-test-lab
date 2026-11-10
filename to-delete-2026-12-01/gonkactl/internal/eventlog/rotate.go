package eventlog

import (
	"fmt"
	"os"
)

const maxLogBytes = 20 << 20
const retainedLogs = 5

func rotate(path string) error {
	info, err := os.Stat(path)
	if os.IsNotExist(err) || (err == nil && info.Size() < maxLogBytes) {
		return nil
	}
	if err != nil {
		return err
	}
	for index := retainedLogs; index >= 1; index-- {
		from, to := fmt.Sprintf("%s.%d", path, index), fmt.Sprintf("%s.%d", path, index+1)
		if index == retainedLogs {
			_ = os.Remove(to)
		}
		if err := os.Rename(from, to); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	return os.Rename(path, path+".1")
}
