package report

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"testing"
)

// The hosted runner uses UID 1001, which is absent from the image's passwd
// database. Its default Yarn/Corepack bootstrap tries to write under /.cache.
// Launch the image's declared Node server directly, without runtime downloads.
func TestStorageArbitraryUIDStartup(t *testing.T) {
	if os.Getenv(storageIntegrationEnv) != "1" {
		t.Skip("set GONKACTL_TEST_STORAGE_INTEGRATION=1 for the owned Storage fixture")
	}
	name := fmt.Sprintf("gonkactl-test-storage-uid-%d", os.Getpid())
	output, err := exec.Command("docker", "run", "--detach", "--name", name,
		"--label", "gonkactl-test.owner=qualification-storage-uid",
		"--user", "1001:1001", "--read-only",
		"--tmpfs", "/data:uid=1001,gid=1001,mode=700",
		"--env", "ACCESS_TOKEN=qualification-storage-bootstrap-only",
		"--env", "SECRET=qualification-storage-secret-only",
		"--env", "DATABASE_PATH=/data/reports.sqlite",
		"--env", "DATA_DIR=/data", "--env", "HOST=0.0.0.0", "--env", "PORT=3000",
		"--publish", "127.0.0.1::3000",
		"allure/allure-report-storage:v1.0.1", "node", "./dist/server.js",
	).CombinedOutput()
	if err != nil {
		t.Fatalf("start UID 1001 fixture: %v: %s", err, output)
	}
	t.Cleanup(func() {
		if t.Failed() {
			logs, _ := exec.Command("docker", "logs", name).CombinedOutput()
			t.Logf("UID 1001 container logs:\n%s", logs)
		}
		if output, err := exec.Command("docker", "rm", "--force", name).CombinedOutput(); err != nil {
			t.Errorf("remove UID 1001 fixture: %v: %s", err, output)
		}
	})
	port, err := exec.Command("docker", "port", name, "3000/tcp").Output()
	if err != nil {
		t.Fatal(err)
	}
	if err := waitForStorage("http://" + strings.TrimSpace(string(port)) + "/api/ping"); err != nil {
		t.Fatal(err)
	}
}
