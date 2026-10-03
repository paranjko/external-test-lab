package main

import (
	"archive/zip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/cucumber/gherkin/go/v26"
	messages "github.com/cucumber/messages/go/v21"
)

const releaseV5Commit = "fae45d8c53180303b8345b56b2a9cc9dadcc0ffb"

type releaseScenario struct {
	Feature    string   `json:"feature"`
	FeatureSHA string   `json:"feature_sha256"`
	Name       string   `json:"name"`
	Tags       []string `json:"tags"`
	Steps      []string `json:"steps"`
	Status     string   `json:"status"`
	Reason     string   `json:"reason,omitempty"`
	Selector   string   `json:"upstream_selector,omitempty"`
	Log        string   `json:"log,omitempty"`
}

func discoverReleaseScenarios(path string) ([]releaseScenario, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, fmt.Errorf("feature path: %w", err)
	}
	var paths []string
	if info.IsDir() {
		entries, err := os.ReadDir(path)
		if err != nil {
			return nil, err
		}
		for _, entry := range entries {
			if !entry.IsDir() && strings.HasSuffix(entry.Name(), ".feature") {
				paths = append(paths, filepath.Join(path, entry.Name()))
			}
		}
	} else if strings.HasSuffix(path, ".feature") {
		paths = []string{path}
	}
	if len(paths) == 0 {
		return nil, fmt.Errorf("no .feature files in %s", path)
	}
	sort.Strings(paths)
	var result []releaseScenario
	seen := map[string]bool{}
	for _, file := range paths {
		contents, err := os.ReadFile(file)
		if err != nil {
			return nil, err
		}
		hash := sha256.Sum256(contents)
		ids := &messages.Incrementing{}
		doc, err := gherkin.ParseGherkinDocument(strings.NewReader(string(contents)), ids.NewId)
		if err != nil {
			return nil, fmt.Errorf("parse %s: %w", file, err)
		}
		if doc.Feature == nil {
			return nil, fmt.Errorf("%s has no feature", file)
		}
		for _, pickle := range gherkin.Pickles(*doc, file, ids.NewId) {
			key := filepath.Base(file) + ":" + pickle.Name
			if seen[key] {
				return nil, fmt.Errorf("duplicate scenario %q", key)
			}
			seen[key] = true
			item := releaseScenario{Feature: file, FeatureSHA: hex.EncodeToString(hash[:]), Name: pickle.Name, Status: "not_run"}
			for _, tag := range pickle.Tags {
				item.Tags = append(item.Tags, tag.Name)
			}
			for _, step := range pickle.Steps {
				item.Steps = append(item.Steps, step.Text)
			}
			result = append(result, item)
		}
	}
	if len(result) == 0 {
		return nil, errors.New("feature selection contains no executable scenarios")
	}
	return result, nil
}

func sha256File(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	h := sha256.New()
	if _, err := io.Copy(h, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func obtainReleaseArchive(ctx context.Context, tag, want, supplied, runDir string) (string, string, error) {
	if !regexp.MustCompile(`^[a-fA-F0-9]{64}$`).MatchString(want) {
		return "", "", errors.New("RELEASE_SHA256 must be a 64-character SHA-256 hex digest")
	}
	archive := supplied
	if archive == "" {
		archive = filepath.Join(runDir, "devshardd.zip")
		url := "https://github.com/gonka-ai/gonka/releases/download/" + tag + "/devshardd.zip"
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			return "", "", err
		}
		client := &http.Client{Timeout: 10 * time.Minute}
		response, err := client.Do(req)
		if err != nil {
			return "", "", fmt.Errorf("download release asset: %w", err)
		}
		defer response.Body.Close()
		if response.StatusCode != http.StatusOK {
			return "", "", fmt.Errorf("download release asset: HTTP %d", response.StatusCode)
		}
		file, err := os.OpenFile(archive, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
		if err != nil {
			return "", "", err
		}
		n, copyErr := io.Copy(file, io.LimitReader(response.Body, (512<<20)+1))
		closeErr := file.Close()
		if copyErr != nil {
			return "", "", copyErr
		}
		if closeErr != nil {
			return "", "", closeErr
		}
		if n > 512<<20 {
			return "", "", errors.New("release archive exceeds 512 MiB")
		}
	}
	actual, err := sha256File(archive)
	if err != nil {
		return "", "", err
	}
	if !strings.EqualFold(actual, want) {
		return archive, actual, fmt.Errorf("release asset SHA-256 mismatch: expected %s, got %s", want, actual)
	}
	return archive, actual, nil
}

func extractReleaseBinary(archive, runDir string) (string, string, error) {
	reader, err := zip.OpenReader(archive)
	if err != nil {
		return "", "", fmt.Errorf("open release archive: %w", err)
	}
	defer reader.Close()
	if len(reader.File) != 1 || reader.File[0].Name != "devshardd" || reader.File[0].UncompressedSize64 > 300<<20 {
		return "", "", errors.New("release archive must contain one bounded devshardd executable")
	}
	entry, err := reader.File[0].Open()
	if err != nil {
		return "", "", err
	}
	defer entry.Close()
	path := filepath.Join(runDir, "devshardd")
	out, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o700)
	if err != nil {
		return "", "", err
	}
	var header [4]byte
	if _, err := io.ReadFull(entry, header[:]); err != nil {
		out.Close()
		return "", "", err
	}
	if string(header[:]) != "\x7fELF" {
		out.Close()
		return "", "", errors.New("release executable is not ELF")
	}
	if _, err := out.Write(header[:]); err != nil {
		out.Close()
		return "", "", err
	}
	n, err := io.Copy(out, io.LimitReader(entry, (300<<20)+1))
	if err != nil {
		out.Close()
		return "", "", err
	}
	if n > 300<<20 {
		out.Close()
		return "", "", errors.New("release executable exceeds 300 MiB")
	}
	if err := out.Close(); err != nil {
		return "", "", err
	}
	hash, err := sha256File(path)
	return path, hash, err
}

func cloneReleaseSource(ctx context.Context, tag, supplied, runDir string) (string, error) {
	path := filepath.Join(runDir, "source")
	var args []string
	if supplied != "" {
		args = []string{"clone", "--no-hardlinks", "--local", supplied, path}
	} else {
		args = []string{"clone", "--depth=1", "--branch", tag, "https://github.com/gonka-ai/gonka.git", path}
	}
	cmd := exec.CommandContext(ctx, "git", args...)
	if output, err := cmd.CombinedOutput(); err != nil {
		return "", fmt.Errorf("clone release source: %w: %s", err, strings.TrimSpace(string(output)))
	}
	if supplied != "" {
		cmd = exec.CommandContext(ctx, "git", "-C", path, "checkout", "--detach", releaseV5Commit)
		if output, err := cmd.CombinedOutput(); err != nil {
			return "", fmt.Errorf("checkout release commit: %w: %s", err, strings.TrimSpace(string(output)))
		}
	}
	cmd = exec.CommandContext(ctx, "git", "-C", path, "rev-parse", "HEAD")
	output, err := cmd.Output()
	if err != nil {
		return "", err
	}
	if strings.TrimSpace(string(output)) != releaseV5Commit {
		return "", fmt.Errorf("release source mismatch: got %s", strings.TrimSpace(string(output)))
	}
	return path, nil
}
