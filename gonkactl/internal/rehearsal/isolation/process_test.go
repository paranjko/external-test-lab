package isolation

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"
)

const helperMarker = "__gonka_isolation_test_helper__"

// TestProcessHelper is re-executed as a harmless child process by the runner tests.
func TestProcessHelper(t *testing.T) {
	marker := -1
	for i, arg := range os.Args {
		if arg == helperMarker {
			marker = i
			break
		}
	}
	if marker < 0 {
		return
	}
	if marker+1 >= len(os.Args) {
		os.Exit(90)
	}
	switch os.Args[marker+1] {
	case "echo":
		if marker+2 < len(os.Args) {
			fmt.Print(os.Args[marker+2])
		}
		fmt.Printf("\nsecret=%s\n", os.Getenv("ISOLATION_PARENT_SECRET"))
	case "flood":
		_, _ = os.Stdout.Write(bytes.Repeat([]byte("x"), 1<<20))
	case "flood-stderr":
		_, _ = os.Stderr.Write(bytes.Repeat([]byte("x"), 1<<20))
	case "sleep":
		time.Sleep(5 * time.Second)
	case "reply":
		if marker+2 < len(os.Args) {
			fmt.Print(os.Args[marker+2])
		}
	case "reply-exit":
		if marker+2 < len(os.Args) {
			fmt.Print(os.Args[marker+2])
		}
		code := 1
		if marker+3 < len(os.Args) {
			if parsed, err := strconv.Atoi(os.Args[marker+3]); err == nil {
				code = parsed
			}
		}
		os.Exit(code)
	case "fail":
		os.Exit(7)
	default:
		os.Exit(91)
	}
	os.Exit(0)
}

func helperRunner(t *testing.T, limit int) (*NativeRunner, string) {
	t.Helper()
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	runner, err := NewNativeRunner(ProcessPolicy{Executables: []string{exe}, Operations: []Operation{operationTestHelper}, Timeout: 3 * time.Second, MaxOutputBytes: limit})
	if err != nil {
		t.Fatal(err)
	}
	return runner, exe
}
func helperCommand(exe string, args ...string) Command {
	return newCommand(operationTestHelper, exe, append([]string{"-test.run=^TestProcessHelper$", helperMarker}, args...))
}

func TestNativeRunnerUsesArgvAndMinimalEnvironment(t *testing.T) {
	runner, exe := helperRunner(t, 4096)
	parentSecret := "ambient-secret-that-must-not-be-forwarded"
	previousSecret, hadSecret := os.LookupEnv("ISOLATION_PARENT_SECRET")
	if err := os.Setenv("ISOLATION_PARENT_SECRET", parentSecret); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if hadSecret {
			_ = os.Setenv("ISOLATION_PARENT_SECRET", previousSecret)
		} else {
			_ = os.Unsetenv("ISOLATION_PARENT_SECRET")
		}
	})
	sentinel := filepath.Join(t.TempDir(), "shell-was-not-used")
	arg := "literal ; touch " + sentinel + " $(echo injected)"
	stdout, _, code, err := runner.Run(context.Background(), helperCommand(exe, "echo", arg))
	if err != nil || code != 0 {
		t.Fatalf("run: code=%d err=%v", code, err)
	}
	if !bytes.Contains(stdout, []byte(arg+"\nsecret=\n")) {
		t.Fatalf("argv/environment not preserved as expected: %q", stdout)
	}
	if _, err := os.Stat(sentinel); !os.IsNotExist(err) {
		t.Fatalf("shell interpreted argv; sentinel stat err=%v", err)
	}
}

func TestNativeRunnerReturnsExactExitCode(t *testing.T) {
	runner, exe := helperRunner(t, 4096)
	_, _, code, err := runner.Run(context.Background(), helperCommand(exe, "fail"))
	if code != 7 || !errors.Is(err, ErrProcessExit) {
		t.Fatalf("want exit 7 with exit error, got code=%d err=%v", code, err)
	}
	var failure *ProcessFailure
	if !errors.As(err, &failure) || failure.ExitCode != 7 || failure.Operation != operationTestHelper || failure.CommandDigest == "" {
		t.Fatalf("missing exit provenance: %#v", failure)
	}
}

func TestNativeRunnerBoundsOutputAndStopsChild(t *testing.T) {
	runner, exe := helperRunner(t, 256)
	stdout, _, code, err := runner.Run(context.Background(), helperCommand(exe, "flood"))
	if !errors.Is(err, ErrOutputLimit) {
		t.Fatalf("want output limit error, got code=%d err=%v", code, err)
	}
	if len(stdout) > 256 {
		t.Fatalf("captured %d bytes above cap", len(stdout))
	}
	_, stderr, _, err := runner.Run(context.Background(), helperCommand(exe, "flood-stderr"))
	if !errors.Is(err, ErrOutputLimit) || len(stderr) > 256 {
		t.Fatalf("stderr cap failed: bytes=%d err=%v", len(stderr), err)
	}
}

func TestNativeRunnerHonorsCancellationAndTimeout(t *testing.T) {
	runner, exe := helperRunner(t, 4096)
	ctx, cancel := context.WithCancel(context.Background())
	timer := time.AfterFunc(100*time.Millisecond, cancel)
	started := time.Now()
	_, _, _, err := runner.Run(ctx, helperCommand(exe, "sleep"))
	timer.Stop()
	if !errors.Is(err, context.Canceled) || time.Since(started) > time.Second {
		t.Fatalf("cancel was not preserved: %v", err)
	}

	ctx, stop := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer stop()
	started = time.Now()
	_, _, _, err = runner.Run(ctx, helperCommand(exe, "sleep"))
	if !errors.Is(err, ErrProcessTimeout) || time.Since(started) > time.Second {
		t.Fatalf("timeout was not enforced promptly: %v after %s", err, time.Since(started))
	}
}

func TestInspectCommandsAreTypedAndExact(t *testing.T) {
	image := "registry.invalid/node@sha256:" + strings.Repeat("a", 64)
	imageCommand, err := ImageInspectCommand("/usr/bin/docker", image)
	if err != nil {
		t.Fatal(err)
	}
	if imageCommand.Operation() != OperationInspectImage || !reflect.DeepEqual(imageCommand.Args(), []string{"image", "inspect", image}) {
		t.Fatalf("unexpected image inspect command: %+v", imageCommand)
	}
	resourceCommand, err := ResourcesInspectCommand("/usr/bin/docker", []string{"container-a", "0123456789ab"})
	if err != nil {
		t.Fatal(err)
	}
	if resourceCommand.Operation() != OperationInspectResources || !reflect.DeepEqual(resourceCommand.Args(), []string{"inspect", "--type", "container", "container-a", "0123456789ab"}) {
		t.Fatalf("unexpected resource inspect command: %+v", resourceCommand)
	}
}

func TestNativeRunnerRejectsInjectionAndUnapprovedExecutables(t *testing.T) {
	runner, exe := helperRunner(t, 4096)
	c := helperCommand(exe, "echo", "ok")
	c.args[2] = "fail"
	if _, _, _, err := runner.Run(context.Background(), c); !errors.Is(err, ErrCommandPolicy) {
		t.Fatalf("mutated argv accepted: %v", err)
	}
	c = helperCommand("/bin/sh", "-c", "touch /tmp/nope")
	if _, _, _, err := runner.Run(context.Background(), c); !errors.Is(err, ErrCommandPolicy) {
		t.Fatalf("unapproved executable accepted: %v", err)
	}
	if _, err := ImageInspectCommand(exe, "registry.invalid/node@sha256:x"); err == nil {
		t.Fatal("untyped mutable image inspect accepted")
	}
	if _, err := ResourcesInspectCommand(exe, []string{"container", "--all"}); err == nil {
		t.Fatal("option-like resource IDs accepted")
	}
}

func TestNativeRunnerPolicyIsCopiedAndBounded(t *testing.T) {
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	ops := []Operation{operationTestHelper}
	executables := []string{exe}
	runner, err := NewNativeRunner(ProcessPolicy{Executables: executables, Operations: ops, Timeout: 5 * time.Second, MaxOutputBytes: 32})
	if err != nil {
		t.Fatal(err)
	}
	ops[0] = OperationCreateContainer
	executables[0] = "/bin/sh"
	if _, _, _, err := runner.Run(context.Background(), helperCommand(exe, "echo", "ok")); err != nil {
		t.Fatalf("runner policy aliased caller slices: %v", err)
	}
	if _, err := NewNativeRunner(ProcessPolicy{Executables: []string{exe}, Operations: []Operation{OperationCreateContainer}, Timeout: 0, MaxOutputBytes: 32}); err == nil {
		t.Fatal("unbounded timeout accepted")
	}
	if strings.Contains(strings.Join(cleanEnvironment(), "\n"), "ISOLATION_PARENT_SECRET") {
		t.Fatal("minimal environment includes inherited secret")
	}
}
