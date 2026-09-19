package artifact

import (
	"context"
	"crypto/sha256"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"

	"github.com/paranjko/external-test-lab/gonkactl/internal/contracts"
)

type Cache struct{ client *http.Client }

func NewCache(client *http.Client) *Cache { return &Cache{client: client} }

func (c *Cache) Fetch(ctx context.Context, request contracts.ArtifactRequest) (contracts.ArtifactFile, error) {
	if request.SHA256 == "" || request.CacheRoot == "" || request.URL == "" {
		return contracts.ArtifactFile{}, fmt.Errorf("artifact request is incomplete")
	}
	if err := os.MkdirAll(request.CacheRoot, 0o700); err != nil {
		return contracts.ArtifactFile{}, err
	}
	path := filepath.Join(request.CacheRoot, request.SHA256)
	if info, err := os.Stat(path); err == nil {
		if info.Size() == request.SizeBytes {
			return contracts.ArtifactFile{Path: path, SHA256: request.SHA256, SizeBytes: info.Size()}, nil
		}
		return contracts.ArtifactFile{}, fmt.Errorf("cache collision for %s", request.SHA256)
	}
	client := c.client
	if client == nil {
		client = http.DefaultClient
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, request.URL, nil)
	if err != nil {
		return contracts.ArtifactFile{}, err
	}
	response, err := client.Do(req)
	if err != nil {
		return contracts.ArtifactFile{}, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return contracts.ArtifactFile{}, fmt.Errorf("artifact download status %d", response.StatusCode)
	}
	temp, err := os.CreateTemp(request.CacheRoot, ".artifact-")
	if err != nil {
		return contracts.ArtifactFile{}, err
	}
	defer os.Remove(temp.Name())
	hash := sha256.New()
	size, copyErr := io.Copy(io.MultiWriter(temp, hash), response.Body)
	if closeErr := temp.Close(); copyErr == nil {
		copyErr = closeErr
	}
	if copyErr != nil {
		return contracts.ArtifactFile{}, copyErr
	}
	if size != request.SizeBytes || fmt.Sprintf("%x", hash.Sum(nil)) != request.SHA256 {
		return contracts.ArtifactFile{}, fmt.Errorf("artifact digest or size mismatch")
	}
	if err := os.Rename(temp.Name(), path); err != nil {
		return contracts.ArtifactFile{}, err
	}
	return contracts.ArtifactFile{Path: path, SHA256: request.SHA256, SizeBytes: size}, nil
}
