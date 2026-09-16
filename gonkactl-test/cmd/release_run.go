package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	reportpkg "github.com/paranjko/external-test-lab/gonkactl-test/report"
)

const releaseV5ArchiveSHA = "ae2d1f90374b54efd4290b4df8b8c0ae339deb0d3b6e5b10936ea9f73155f564"

var releaseFeatureHashes = map[string]string{
	"devshard_v5_height_sync.feature": "339245fc5ace4b807ce35951f9cd14eb10385fb41cf61b95842dd67224b2e3e6",
	"devshard_v5_residual.feature":    "eb93136c83a786b573ddb117ceba51aa239d612ea704c4487d35587254777a80",
}

// Only selectors whose test assertions cover the named scenario are connected.
// Remaining scenarios stay not_run, including those that need testenv-only
// fault injection which a production release binary intentionally lacks.
var releaseV5Bindings = map[string]string{
	"devshard_v5_height_sync.feature: A quiet escrow sends heartbeats after a floor is seeded":   "TestContainerE2E_HeightSync_QuietEscrowHeartbeat",
	"devshard_v5_height_sync.feature: A busy escrow discharges heartbeat work through inference": "TestContainerE2E_HeightSync_BusyEscrowDischarge",
	"devshard_v5_residual.feature: Solo boot serves before session recovery is complete":         "TestVersiondWarmCutoverBoot",
	"devshard_v5_residual.feature: Unused hosts are not pinged":                                  "TestHostPing/E1_unused_escrow_absent",
	"devshard_v5_residual.feature: A used host becomes visible in ping metrics":                  "TestHostPing/E2_metrics_after_chat",
	"devshard_v5_residual.feature: Disabling host ping does not disable chat":                    "TestHostPingKillSwitch",
}

type releaseOptions struct {
	Tag, SHA256, Features, DataRoot, Archive, Source string
}

type releaseReport struct {
	SchemaVersion       string            `json:"schema_version"`
	RunID               string            `json:"run_id"`
	StartedAt           string            `json:"started_at"`
	FinishedAt          string            `json:"finished_at,omitempty"`
	ReleaseTag          string            `json:"release_tag"`
	ReleaseSourceCommit string            `json:"release_source_commit"`
	Archive             string            `json:"archive,omitempty"`
	ArchiveSHA256       string            `json:"archive_sha256,omitempty"`
	BinarySHA256        string            `json:"binary_sha256,omitempty"`
	ImageConfigSHA256   string            `json:"image_config_sha256,omitempty"`
	ImageComposeSHA256  string            `json:"image_compose_sha256,omitempty"`
	RuntimeIdentities   []string          `json:"runtime_identities,omitempty"`
	Cases               []releaseScenario `json:"cases"`
	Outcome             string            `json:"outcome"`
	Error               string            `json:"error,omitempty"`
	Cleanup             releaseCleanup    `json:"cleanup"`
}

type releaseCleanup struct {
	Completed bool     `json:"completed"`
	Actions   []string `json:"actions,omitempty"`
	Remaining []string `json:"remaining,omitempty"`
	Errors    []string `json:"errors,omitempty"`
}

func executeRelease(ctx context.Context, o releaseOptions) (string, error) {
	if o.Tag != "devshard/v5.0.0" {
		return "", fmt.Errorf("no executable release binding for tag %q", o.Tag)
	}
	if !strings.EqualFold(o.SHA256, releaseV5ArchiveSHA) {
		return "", fmt.Errorf("declared SHA-256 does not match the pinned %s release asset", o.Tag)
	}
	if o.Features == "" {
		o.Features = "feature"
	}
	if o.DataRoot == "" {
		o.DataRoot = filepath.Join("build", "report")
	}
	cases, err := discoverReleaseScenarios(o.Features)
	if err != nil {
		return "", err
	}
	root, err := filepath.Abs(o.DataRoot)
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(root, 0o700); err != nil {
		return "", err
	}
	runDir, err := os.MkdirTemp(root, "release-v5-")
	if err != nil {
		return "", err
	}
	report := releaseReport{SchemaVersion: "1.0.0", RunID: filepath.Base(runDir), StartedAt: time.Now().UTC().Format(time.RFC3339Nano), ReleaseTag: o.Tag, ReleaseSourceCommit: releaseV5Commit, Cases: cases, Outcome: "incomplete"}
	fixtureStarted := false
	inputsValid := true
	for i := range report.Cases {
		item := &report.Cases[i]
		binding := releaseV5Bindings[filepath.Base(item.Feature)+": "+item.Name]
		if releaseFeatureHashes[filepath.Base(item.Feature)] != item.FeatureSHA {
			item.Reason = "feature bytes differ from the reviewed binding; revalidate before execution"
			inputsValid = false
		} else if binding == "" {
			item.Reason = "no release-safe executable binding for all scenario assertions"
		} else {
			item.Selector = binding
			item.Reason = "awaiting release fixture"
		}
	}
	finish := func(cause error) (string, error) {
		if identities, err := filepath.Glob(filepath.Join(runDir, "child-identity-*.txt")); err == nil {
			for _, path := range identities {
				report.RuntimeIdentities = append(report.RuntimeIdentities, filepath.Base(path))
			}
		}
		if fixtureStarted {
			report.Cleanup = cleanupReleaseFixture(context.Background(), report.RunID)
			if !report.Cleanup.Completed {
				cause = errors.Join(cause, errors.New("owned fixture cleanup is incomplete"))
			}
		} else {
			report.Cleanup.Completed = true
		}
		cleanupReleaseTemporaryData(runDir, &report.Cleanup)
		if !report.Cleanup.Completed {
			cause = errors.Join(cause, errors.New("owned temporary-data cleanup is incomplete"))
		}
		report.FinishedAt = time.Now().UTC().Format(time.RFC3339Nano)
		if cause != nil {
			report.Error = cause.Error()
		}
		complete := true
		for _, item := range report.Cases {
			if item.Status != "upstream_pass" {
				complete = false
			}
		}
		if !complete && cause == nil {
			cause = errors.New("release scenario coverage is incomplete; inspect report for not_run or failed cases")
			report.Error = cause.Error()
		}
		if cause == nil {
			report.Outcome = "scoped_upstream_pass"
		}
		if err := writeReleaseReport(runDir, report); err != nil {
			return runDir, fmt.Errorf("write release report: %w", err)
		}
		if err := writeReleaseAllureResults(runDir, report); err != nil {
			return runDir, fmt.Errorf("write release Allure results: %w", err)
		}
		if err := reportpkg.RenderAllure(ctx, filepath.Join(runDir, "allure-results"), filepath.Join(runDir, "allure-report")); err != nil {
			return runDir, err
		}
		return runDir, cause
	}
	if err := writeReleaseReport(runDir, report); err != nil {
		return runDir, err
	}
	if !inputsValid {
		return finish(errors.New("feature digest mismatch; no release fixture was created"))
	}
	archive, hash, err := obtainReleaseArchive(ctx, o.Tag, o.SHA256, o.Archive, runDir)
	report.Archive, report.ArchiveSHA256 = archive, hash
	if err != nil {
		return finish(err)
	}
	binary, binaryHash, err := extractReleaseBinary(archive, runDir)
	report.BinarySHA256 = binaryHash
	if err != nil {
		return finish(err)
	}
	source, err := cloneReleaseSource(ctx, o.Tag, o.Source, runDir)
	if err != nil {
		return finish(err)
	}
	if err := installReleaseBinary(binary, filepath.Join(source, "build", "devshardd")); err != nil {
		return finish(err)
	}
	overlay, err := prepareReleaseOverlay(source, runDir, report.RunID)
	if err != nil {
		return finish(err)
	}
	fixtureStarted = true
	if err := buildReleaseFixtureImages(ctx, source, report.RunID, runDir, &report); err != nil {
		return finish(err)
	}
	for i := range report.Cases {
		item := &report.Cases[i]
		if item.Selector == "" {
			continue
		}
		if ctx.Err() != nil {
			item.Reason = ctx.Err().Error()
			break
		}
		status, log, testErr := runReleaseSelector(ctx, source, overlay, runDir, report.RunID, binaryHash, item.Selector)
		item.Status, item.Log = status, filepath.Base(log)
		if log == "" {
			item.Log = ""
		}
		if testErr != nil {
			item.Reason = testErr.Error()
		} else {
			item.Reason = "upstream test passed; no Gherkin step-level evidence"
		}
		if err := writeReleaseReport(runDir, report); err != nil {
			return finish(err)
		}
	}
	if err := ctx.Err(); err != nil {
		return finish(err)
	}
	return finish(nil)
}

func installReleaseBinary(source, target string) error {
	if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
		return err
	}
	in, err := os.Open(source)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o700)
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(out, in)
	closeErr := out.Close()
	if copyErr != nil {
		return copyErr
	}
	return closeErr
}

func prepareReleaseOverlay(source, runDir, scope string) (string, error) {
	configPath := filepath.Join(source, "devshard", "testenv", "citest", "harness", "config.go")
	stackPath := filepath.Join(source, "devshard", "testenv", "citest", "harness", "stack.go")
	config, err := os.ReadFile(configPath)
	if err != nil {
		return "", err
	}
	from := "versiond:\n  mode: multi\n  version_name: v2\n  binary_version: 0.2.13-v2-r2"
	to := "versiond:\n  mode: multi\n  version_name: v5\n  binary_version: 5.0.0"
	if strings.Count(string(config), from) != 1 {
		return "", errors.New("upstream testenv config template changed; release overlay needs review")
	}
	patchedConfig := strings.Replace(string(config), from, to, 1)
	stack, err := os.ReadFile(stackPath)
	if err != nil {
		return "", err
	}
	stackText := string(stack)
	stackFrom := "workDir, err := os.MkdirTemp(testenvDir, prefix)"
	if strings.Count(stackText, stackFrom) != 1 {
		return "", errors.New("upstream testenv stack ownership hook changed; release overlay needs review")
	}
	stackText = strings.Replace(stackText, stackFrom, "prefix = os.Getenv(\"GONKACTL_TEST_PROJECT_PREFIX\") + prefix\n\t"+stackFrom, 1)
	pathsFrom := "fixComposePaths(t, s.ComposePath, s.TestenvDir)"
	if strings.Count(stackText, pathsFrom) != 1 {
		return "", errors.New("upstream testenv Compose render hook changed; release overlay needs review")
	}
	stackText = strings.Replace(stackText, pathsFrom, pathsFrom+"\n\tscopeReleaseComposeImages(t, s.ComposePath, os.Getenv(\"GONKACTL_TEST_IMAGE_SUFFIX\"), os.Getenv(\"GONKACTL_TEST_BINARY_SHA256\"))", 1)
	upFrom := "s.upAfterCatalog(t, false)"
	if strings.Count(stackText, upFrom) != 2 {
		return "", errors.New("upstream testenv stack launch hook changed; release identity capture needs review")
	}
	stackText = strings.Replace(stackText, upFrom, upFrom+"\n\tcaptureReleaseChildIdentity(t, s)", 1)
	stackText += `
func scopeReleaseComposeImages(t *testing.T, path, suffix, sha string) {
    t.Helper()
    require.NotEmpty(t, suffix)
    require.Len(t, sha, 64)
    b, err := os.ReadFile(path)
    require.NoError(t, err)
    text := string(b)
    for _, name := range []string{"mock-chain", "mock-dapi", "mock-openai", "versiond", "versiond-router", "runtime"} {
        text = strings.ReplaceAll(text, "image: devshard-"+name+":latest", "image: devshard-"+name+":"+suffix)
    }
    // Warm-cutover supplies its own version catalog fixture. The other
    // selected tests need the released v5 binary declared by mock-DAPI.
    if os.Getenv("GONKACTL_TEST_SELECTOR") != "TestVersiondWarmCutoverBoot" {
        const marker = "MOCK_DAPI_BINARY_DIR: /testenv-binaries"
        require.Equal(t, 1, strings.Count(text, marker))
        text = strings.Replace(text, marker, marker+"\n      MOCK_DAPI_VERSION_NAME: \"v5\"\n      MOCK_DAPI_VERSION_BINARY: \"file:///opt/devshard/devshardd\"\n      MOCK_DAPI_VERSION_SHA256: \""+sha+"\"", 1)
    }
    require.NoError(t, os.WriteFile(path, []byte(text), 0o600))
}

func captureReleaseChildIdentity(t *testing.T, s *Stack) {
    t.Helper()
    captureRoot := os.Getenv("GONKACTL_TEST_CAPTURE_ROOT")
    expected := os.Getenv("GONKACTL_TEST_BINARY_SHA256")
    require.NotEmpty(t, captureRoot)
    require.Len(t, expected, 64)
    ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
    defer cancel()
    args := append([]string{"compose"}, s.composeFileArgs()...)
    idCmd := exec.CommandContext(ctx, "docker", append(args, "ps", "-q", "versiond-0")...)
    idCmd.Dir, idCmd.Env = s.WorkDir, s.composeEnv()
    id, err := idCmd.CombinedOutput()
    require.NoError(t, err, "versiond container identity: %s", id)
    require.NotEmpty(t, strings.TrimSpace(string(id)), "versiond container ID")
    childCmd := exec.CommandContext(ctx, "docker", append(args, "exec", "-T", "versiond-0", "sh", "-ec", "set -- $(pidof devshardd); test \"$#\" -eq 1; printf 'pid=%s\\nexe=' \"$1\"; readlink /proc/$1/exe; sha256sum /proc/$1/exe")...)
    childCmd.Dir, childCmd.Env = s.WorkDir, s.composeEnv()
    child, err := childCmd.CombinedOutput()
    require.NoError(t, err, "running child identity: %s", child)
    fields := strings.Fields(string(child))
    require.GreaterOrEqual(t, len(fields), 3, "running child identity: %s", child)
    require.Equal(t, expected, fields[len(fields)-2], "running child executable SHA-256")
    config, err := os.ReadFile(s.ConfigPath)
    require.NoError(t, err)
    compose, err := os.ReadFile(s.ComposePath)
    require.NoError(t, err)
    receipt := fmt.Sprintf("container_id=%s\nchild=%s\nexpected_sha256=%s\n", strings.TrimSpace(string(id)), string(child), expected)
    require.NoError(t, os.WriteFile(filepath.Join(captureRoot, "child-identity-"+s.ComposeProject+".txt"), []byte(receipt), 0o600))
    require.NoError(t, os.WriteFile(filepath.Join(captureRoot, "config-"+s.ComposeProject+".yaml"), config, 0o600))
    require.NoError(t, os.WriteFile(filepath.Join(captureRoot, "compose-"+s.ComposeProject+".yaml"), compose, 0o600))
}
`
	configOverlay := filepath.Join(runDir, "overlay-config.go")
	stackOverlay := filepath.Join(runDir, "overlay-stack.go")
	if err := os.WriteFile(configOverlay, []byte(patchedConfig), 0o600); err != nil {
		return "", err
	}
	if err := os.WriteFile(stackOverlay, []byte(stackText), 0o600); err != nil {
		return "", err
	}
	overlay := filepath.Join(runDir, "overlay.json")
	b, err := json.Marshal(map[string]any{"Replace": map[string]string{configPath: configOverlay, stackPath: stackOverlay}})
	if err != nil {
		return "", err
	}
	return overlay, os.WriteFile(overlay, append(b, '\n'), 0o600)
}

func scopedReleaseImageNames(scope string) []string {
	return []string{"devshard-mock-chain:" + scope, "devshard-mock-dapi:" + scope, "devshard-mock-openai:" + scope, "devshard-versiond:" + scope, "devshard-versiond-router:" + scope, "devshard-runtime:" + scope}
}

func scopeImageNames(body []byte, scope string) []byte {
	text := string(body)
	for _, name := range []string{"mock-chain", "mock-dapi", "mock-openai", "versiond", "versiond-router", "runtime"} {
		text = strings.ReplaceAll(text, "image: devshard-"+name+":latest", "image: devshard-"+name+":"+scope)
	}
	return []byte(text)
}

func buildReleaseFixtureImages(ctx context.Context, source, scope, runDir string, report *releaseReport) error {
	testenv := filepath.Join(source, "devshard", "testenv")
	if err := runLoggedCommand(ctx, filepath.Join(runDir, "gencompose-default.log"), testenv, nil, "go", "run", "./cmd/gencompose", "-config", "config/config.yaml"); err != nil {
		return fmt.Errorf("generate base testenv config: %w", err)
	}
	baseConfig := filepath.Join(testenv, "config", "config.yaml")
	base, err := os.ReadFile(baseConfig)
	if err != nil {
		return err
	}
	baseText := string(base)
	for old, replacement := range map[string]string{"version_name: v2": "version_name: v5", "binary_version: 0.2.13-v2-r2": "binary_version: 5.0.0"} {
		if strings.Count(baseText, old) != 1 {
			return fmt.Errorf("base testenv config contract changed: expected one %q", old)
		}
		baseText = strings.Replace(baseText, old, replacement, 1)
	}
	if err := os.WriteFile(baseConfig, []byte(baseText), 0o600); err != nil {
		return err
	}
	if err := runLoggedCommand(ctx, filepath.Join(runDir, "gencompose-v5.log"), testenv, nil, "go", "run", "./cmd/gencompose", "-config", "config/config.yaml"); err != nil {
		return fmt.Errorf("generate v5 testenv config: %w", err)
	}
	if report.ImageConfigSHA256, err = sha256File(baseConfig); err != nil {
		return err
	}
	base, err = os.ReadFile(baseConfig)
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(runDir, "image-config.yaml"), base, 0o600); err != nil {
		return err
	}
	composePath := filepath.Join(testenv, "docker-compose.yml")
	contents, err := os.ReadFile(composePath)
	if err != nil {
		return err
	}
	if err := os.WriteFile(composePath, scopeImageNames(contents, scope), 0o600); err != nil {
		return err
	}
	if report.ImageComposeSHA256, err = sha256File(composePath); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(runDir, "image-compose.yaml"), scopeImageNames(contents, scope), 0o600); err != nil {
		return err
	}
	return runLoggedCommand(ctx, filepath.Join(runDir, "image-build.log"), testenv, nil, "docker", "compose", "-f", composePath, "build", "mock-chain", "mock-dapi", "mock-openai", "devshardctl", "versiond-router", "versiond-0")
}

func runLoggedCommand(ctx context.Context, logPath, directory string, env []string, name string, args ...string) error {
	log, err := os.OpenFile(logPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer log.Close()
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = directory
	if env != nil {
		cmd.Env = append(os.Environ(), env...)
	}
	cmd.Stdout, cmd.Stderr = log, log
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%s: %w (log: %s)", name, err, logPath)
	}
	return log.Sync()
}

func runReleaseSelector(ctx context.Context, source, overlay, runDir, scope, binarySHA, selector string) (string, string, error) {
	parts := strings.Split(selector, "/")
	pattern := "^" + regexp.QuoteMeta(parts[0]) + "$"
	if len(parts) == 2 {
		pattern += "/^" + regexp.QuoteMeta(parts[1]) + "$"
	}
	logPath := filepath.Join(runDir, "test-"+strings.ReplaceAll(selector, "/", "-")+".jsonl")
	log, err := os.OpenFile(logPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return "not_run", "", err
	}
	defer log.Close()
	testCtx, cancel := context.WithTimeout(ctx, 25*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(testCtx, "go", "test", "-json", "-count=1", "-tags=testenvci", "-overlay", overlay, "-run", pattern, "-timeout=24m", "./citest")
	cmd.Dir = filepath.Join(source, "devshard", "testenv")
	cmd.Env = append(os.Environ(), "TESTENV_CITEST=1", "GONKACTL_TEST_PROJECT_PREFIX="+scope+"-", "GONKACTL_TEST_IMAGE_SUFFIX="+scope, "GONKACTL_TEST_BINARY_SHA256="+binarySHA, "GONKACTL_TEST_CAPTURE_ROOT="+runDir, "GONKACTL_TEST_SELECTOR="+selector, "GOTMPDIR="+filepath.Join(runDir, "go-tmp"))
	if err := os.MkdirAll(filepath.Join(runDir, "go-tmp"), 0o700); err != nil {
		return "not_run", logPath, err
	}
	cmd.Stdout, cmd.Stderr = log, log
	runErr := cmd.Run()
	if err := log.Sync(); err != nil {
		return "broken", logPath, err
	}
	file, err := os.Open(logPath)
	if err != nil {
		return "broken", logPath, err
	}
	defer file.Close()
	target := selector
	var observed string
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 65536), 8<<20)
	for scanner.Scan() {
		var event struct{ Action, Test string }
		if json.Unmarshal(scanner.Bytes(), &event) == nil && event.Test == target {
			if event.Action == "pass" || event.Action == "fail" || event.Action == "skip" {
				observed = event.Action
			}
		}
	}
	if err := scanner.Err(); err != nil {
		return "broken", logPath, err
	}
	if err := testCtx.Err(); err != nil {
		if ctx.Err() != nil {
			return "interrupted", logPath, ctx.Err()
		}
		return "timed_out", logPath, err
	}
	if runErr != nil || observed != "pass" {
		if runErr == nil {
			runErr = fmt.Errorf("selected upstream test ended %q", observed)
		}
		return "upstream_fail", logPath, runErr
	}
	return "upstream_pass", logPath, nil
}

func cleanupReleaseFixture(ctx context.Context, scope string) releaseCleanup {
	cleanupCtx, cancel := context.WithTimeout(ctx, 3*time.Minute)
	defer cancel()
	result := releaseCleanup{}
	// The testenv helper has its own Compose down cleanup. Verify its result.
	// All generated project names are prefixed with this unique run ID.
	for _, kind := range []struct{ command, list, field string }{{"ps", "-a", "ID"}, {"network", "ls", "ID"}, {"volume", "ls", "Name"}} {
		args := []string{kind.command, kind.list, "--format", "{{." + kind.field + "}} {{.Label \"com.docker.compose.project\"}}"}
		output, err := exec.CommandContext(cleanupCtx, "docker", args...).CombinedOutput()
		if err != nil {
			result.Errors = append(result.Errors, fmt.Sprintf("inspect %s: %v: %s", kind.command, err, strings.TrimSpace(string(output))))
			continue
		}
		for _, line := range strings.Split(strings.TrimSpace(string(output)), "\n") {
			fields := strings.Fields(line)
			if len(fields) != 2 || !strings.HasPrefix(fields[1], scope+"-") {
				continue
			}
			remove := map[string][]string{"ps": {"rm", "-f"}, "network": {"network", "rm"}, "volume": {"volume", "rm"}}[kind.command]
			if output, err := exec.CommandContext(cleanupCtx, "docker", append(remove, fields[0])...).CombinedOutput(); err != nil {
				result.Errors = append(result.Errors, fmt.Sprintf("remove owned %s %s: %v: %s", kind.command, fields[0], err, strings.TrimSpace(string(output))))
			} else {
				result.Actions = append(result.Actions, "removed owned "+kind.command+" "+fields[0])
			}
		}
	}
	for _, name := range scopedReleaseImageNames(scope) {
		if output, err := exec.CommandContext(cleanupCtx, "docker", "image", "rm", name).CombinedOutput(); err != nil && !strings.Contains(string(output), "No such image") {
			result.Errors = append(result.Errors, fmt.Sprintf("remove owned image %s: %v: %s", name, err, strings.TrimSpace(string(output))))
		} else if err == nil {
			result.Actions = append(result.Actions, "removed owned image "+name)
		}
	}
	for _, kind := range []struct{ command, list, field string }{{"ps", "-a", "ID"}, {"network", "ls", "ID"}, {"volume", "ls", "Name"}} {
		output, err := exec.CommandContext(cleanupCtx, "docker", kind.command, kind.list, "--format", "{{."+kind.field+"}} {{.Label \"com.docker.compose.project\"}}").CombinedOutput()
		if err != nil {
			result.Errors = append(result.Errors, fmt.Sprintf("verify %s: %v: %s", kind.command, err, strings.TrimSpace(string(output))))
			continue
		}
		for _, line := range strings.Split(strings.TrimSpace(string(output)), "\n") {
			fields := strings.Fields(line)
			if len(fields) == 2 && strings.HasPrefix(fields[1], scope+"-") {
				result.Remaining = append(result.Remaining, kind.command+" "+line)
			}
		}
	}
	for _, name := range scopedReleaseImageNames(scope) {
		if err := exec.CommandContext(cleanupCtx, "docker", "image", "inspect", name).Run(); err == nil {
			result.Remaining = append(result.Remaining, "image "+name)
		}
	}
	result.Completed = len(result.Errors) == 0 && len(result.Remaining) == 0
	return result
}

func cleanupReleaseTemporaryData(runDir string, result *releaseCleanup) {
	for _, name := range []string{"source", "devshardd", "go-tmp"} {
		path := filepath.Join(runDir, name)
		if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) {
			continue
		} else if err != nil {
			result.Errors = append(result.Errors, fmt.Sprintf("inspect owned temporary data %s: %v", path, err))
			continue
		}
		if err := os.RemoveAll(path); err != nil {
			if name != "source" || !errors.Is(err, os.ErrPermission) {
				result.Errors = append(result.Errors, fmt.Sprintf("remove owned temporary data %s: %v", path, err))
				continue
			}
			if fallbackErr := removeRootOwnedReleaseSource(path); fallbackErr != nil {
				result.Errors = append(result.Errors, fmt.Sprintf("remove owned temporary data %s: %v; root-owned fallback: %v", path, err, fallbackErr))
			} else {
				result.Actions = append(result.Actions, "removed root-owned temporary source via scoped container")
			}
		} else {
			result.Actions = append(result.Actions, "removed temporary "+name)
		}
	}
	result.Completed = result.Completed && len(result.Errors) == 0
}

func removeRootOwnedReleaseSource(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || filepath.Base(path) != "source" || !strings.HasPrefix(filepath.Base(filepath.Dir(path)), "release-v5-") {
		return errors.New("refusing root-owned cleanup outside an owned release source directory")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, "docker", "run", "--rm", "--pull=never", "--user", "0:0", "--mount", "type=bind,source="+path+",target=/owned", "--entrypoint", "/bin/sh", "alpine:3.20", "-ec", "find /owned -mindepth 1 -delete")
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("scoped container cleanup: %w: %s", err, strings.TrimSpace(string(output)))
	}
	if err := os.RemoveAll(path); err != nil {
		return err
	}
	if _, err := os.Lstat(path); !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("source still present after cleanup: %v", err)
	}
	return nil
}

func writeReleaseReport(runDir string, r releaseReport) error {
	jsonPath := filepath.Join(runDir, "report.json")
	b, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(jsonPath, append(b, '\n'), 0o600); err != nil {
		return err
	}
	const page = `<!doctype html><html lang="en"><meta charset="utf-8"><title>DevShard release test</title>
<h1>DevShard release test</h1><p>Release: {{.ReleaseTag}}</p><p>Source: {{.ReleaseSourceCommit}}</p>
<p>Archive SHA-256: {{.ArchiveSHA256}}</p><p>Binary SHA-256: {{.BinarySHA256}}</p>
<p>Outcome: {{.Outcome}}</p><p>{{.Error}}</p>
<p>Running child identities: {{range .RuntimeIdentities}}<a href="{{.}}">{{.}}</a> {{end}}</p>
<table border="1"><tr><th>Feature</th><th>Scenario and steps</th><th>Upstream test</th><th>Status</th><th>Reason</th><th>Log</th></tr>
{{range .Cases}}<tr><td>{{.Feature}}</td><td>{{.Name}}<details><summary>Steps</summary><ol>{{range .Steps}}<li>{{.}}</li>{{end}}</ol></details></td><td>{{.Selector}}</td><td>{{.Status}}</td><td>{{.Reason}}</td><td>{{if .Log}}<a href="{{.Log}}">test log</a>{{end}}</td></tr>{{end}}</table>
<p>Upstream test PASS is scoped evidence, not Gherkin step-level acceptance. See <a href="report.json">report.json</a> and retained test logs.</p></html>`
	file, err := os.OpenFile(filepath.Join(runDir, "index.html"), os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	err = template.Must(template.New("report").Parse(page)).Execute(file, r)
	closeErr := file.Close()
	if err != nil {
		return err
	}
	return closeErr
}

// writeReleaseAllureResults records only what the release run proves. A
// selector PASS is one upstream-test step, not a fabricated Gherkin trace;
// unbound scenarios remain skipped and visible in the generated Allure v3 UI.
func writeReleaseAllureResults(runDir string, r releaseReport) error {
	results := filepath.Join(runDir, "allure-results")
	if err := os.MkdirAll(results, 0o700); err != nil {
		return err
	}
	start, err := time.Parse(time.RFC3339Nano, r.StartedAt)
	if err != nil {
		return fmt.Errorf("parse report start: %w", err)
	}
	stop := time.Now().UTC()
	if r.FinishedAt != "" {
		if parsed, err := time.Parse(time.RFC3339Nano, r.FinishedAt); err == nil {
			stop = parsed
		}
	}
	if !stop.After(start) {
		stop = start.Add(time.Millisecond)
	}
	for index, item := range r.Cases {
		status := "skipped"
		message := item.Reason
		steps := []map[string]any{}
		switch item.Status {
		case "upstream_pass":
			status = "passed"
			steps = append(steps, map[string]any{"name": "Mapped upstream selector: " + item.Selector, "status": "passed", "stage": "finished", "start": start.UnixMilli(), "stop": stop.UnixMilli()})
		case "failed":
			status = "failed"
		}
		labels := []map[string]string{{"name": "epic", "value": "Release qualification"}, {"name": "feature", "value": filepath.Base(item.Feature)}, {"name": "story", "value": item.Name}, {"name": "evidence_class", "value": "release-selector"}}
		attachments := []map[string]string{}
		if item.Log != "" {
			logBody, err := os.ReadFile(filepath.Join(runDir, item.Log))
			if err != nil {
				return fmt.Errorf("read retained upstream log %q: %w", item.Log, err)
			}
			attachmentName := fmt.Sprintf("%03d-%s", index+1, filepath.Base(item.Log))
			if err := os.WriteFile(filepath.Join(results, attachmentName), logBody, 0o600); err != nil {
				return fmt.Errorf("copy retained upstream log %q: %w", item.Log, err)
			}
			attachments = append(attachments, map[string]string{"name": "upstream test log", "source": attachmentName, "type": "text/plain"})
		}
		payload := map[string]any{"uuid": fmt.Sprintf("%s-%03d", r.RunID, index+1), "historyId": fmt.Sprintf("release-%s-%03d", r.RunID, index+1), "name": item.Name, "fullName": filepath.Base(item.Feature) + ":" + item.Name, "status": status, "stage": "finished", "statusDetails": map[string]string{"message": message}, "labels": labels, "links": []any{}, "steps": steps, "attachments": attachments, "start": start.UnixMilli(), "stop": stop.UnixMilli()}
		body, err := json.MarshalIndent(payload, "", "  ")
		if err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(results, fmt.Sprintf("%03d-result.json", index+1)), append(body, '\n'), 0o600); err != nil {
			return err
		}
	}
	return nil
}
