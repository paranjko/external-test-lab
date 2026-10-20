//go:build gnklab0002_live

package cli

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/paranjko/external-test-lab/gonkactl/internal/incidenthost"
	"github.com/spf13/cobra"
	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/knownhosts"
)

const incidentAgentPath = "/usr/local/libexec/gonkactl-incident"

// Incident operations are excluded from ordinary release builds. Remote hosts
// must have the digest-pinned native agent installed explicitly beforehand.
func registerIncidentRecovery(root *cobra.Command) {
	var apply bool
	var evidenceDir, node, keyFile, knownHosts, agentSHA string
	command := &cobra.Command{
		Use:   "incident-recovery <status|repair|launch|halt|resume|verify>",
		Short: "operate the pinned incident with a native Go host agent", Hidden: true,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			target, known := incidentRecoveryTargets[node]
			if !known {
				return errors.New("node is not in the inspected incident target set")
			}
			phase := args[0]
			if phase == "verify" {
				return verifyIncidentHPlusOne(cmd, node, evidenceDir)
			}
			if !incidentHostPhase(phase) {
				return errors.New("unknown incident recovery phase")
			}
			if phase != "status" && !apply {
				return errors.New("live mutation requires --apply")
			}
			if !filepath.IsAbs(evidenceDir) || !filepath.IsAbs(keyFile) || !filepath.IsAbs(knownHosts) || !incidentDigest(agentSHA) {
				return errors.New("absolute evidence, SSH identity and known-hosts paths and native agent SHA256 are required")
			}
			if err := os.MkdirAll(evidenceDir, 0700); err != nil {
				return err
			}
			path := filepath.Join(evidenceDir, time.Now().UTC().Format("20060102T150405.000000000")+"-"+node+"-"+phase+".json")
			file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
			if err != nil {
				return err
			}
			defer file.Close()
			encoder := json.NewEncoder(file)
			if err := encoder.Encode(map[string]any{"node": node, "phase": phase, "state": "intent", "target": target, "agent_sha256": agentSHA, "at": time.Now().UTC()}); err != nil {
				return err
			}
			if err := file.Sync(); err != nil {
				return err
			}
			dir, err := os.Open(evidenceDir)
			if err != nil {
				return err
			}
			err = errors.Join(dir.Sync(), dir.Close())
			if err != nil {
				return err
			}
			output, runErr := runIncidentAgent(cmd.Context(), node, phase, keyFile, knownHosts, agentSHA)
			if runErr == nil {
				var observed incidenthost.Result
				runErr = json.Unmarshal(output, &observed)
				if runErr == nil && (observed.Node != node || observed.Phase != phase ||
					observed.Original.ID != target.Original || observed.Original.Image != target.Image) {
					runErr = errors.New("native agent result differs from the requested node, phase or original identity")
				}
			}
			state := "succeeded"
			if runErr != nil {
				state = "unknown"
			}
			result := map[string]any{"node": node, "phase": phase, "state": state, "output": string(output), "at": time.Now().UTC()}
			if runErr != nil {
				result["error"] = runErr.Error()
			}
			if err := encoder.Encode(result); err != nil {
				return err
			}
			if err := file.Sync(); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "%s\nreceipt: %s\n", output, path)
			return runErr
		},
	}
	command.Flags().BoolVar(&apply, "apply", false, "authorize this live phase")
	command.Flags().StringVar(&node, "node", "node0", "inspected incident node")
	command.Flags().StringVar(&evidenceDir, "evidence-dir", "", "absolute local append-only receipt directory")
	command.Flags().StringVar(&keyFile, "ssh-identity", "", "absolute SSH private-key path, never copied to receipts")
	command.Flags().StringVar(&knownHosts, "ssh-known-hosts", "", "absolute trusted OpenSSH known_hosts file")
	command.Flags().StringVar(&agentSHA, "agent-sha256", "", "SHA256 of the installed native Linux incident agent")
	root.AddCommand(command, newIncidentHostCommand())
}

func incidentHostPhase(phase string) bool {
	switch phase {
	case "status", "repair", "launch", "halt", "resume":
		return true
	}
	return false
}

func incidentDigest(value string) bool {
	raw, err := hex.DecodeString(value)
	return err == nil && len(raw) == sha256.Size && hex.EncodeToString(raw) == value
}

func newIncidentHostCommand() *cobra.Command {
	var node, phase, expectedSHA string
	var apply bool
	command := &cobra.Command{
		Use: "incident-recovery-local", Hidden: true, Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			target, known := incidentRecoveryTargets[node]
			if !known || !incidentHostPhase(phase) || !incidentDigest(expectedSHA) {
				return errors.New("invalid native incident agent request")
			}
			if phase != "status" && !apply {
				return errors.New("native host mutation requires --apply")
			}
			// Hash the running executable, not a replaceable installation path.
			file, err := os.Open("/proc/self/exe")
			if err != nil {
				return err
			}
			hash := sha256.New()
			_, copyErr := io.Copy(hash, file)
			closeErr := file.Close()
			if copyErr != nil || closeErr != nil {
				return errors.Join(copyErr, closeErr)
			}
			if hex.EncodeToString(hash.Sum(nil)) != expectedSHA {
				return errors.New("native agent identity differs from the controller pin")
			}
			result, err := incidenthost.Run(cmd.Context(), node, phase, incidenthost.Target{
				Original: target.Original, Image: target.Image, Entrypoint: target.Entrypoint, Consumers: target.Consumers,
			})
			if result != nil {
				if encodeErr := json.NewEncoder(cmd.OutOrStdout()).Encode(result); encodeErr != nil {
					return errors.Join(err, encodeErr)
				}
			}
			return err
		},
	}
	command.Flags().StringVar(&node, "node", "", "pinned incident node")
	command.Flags().StringVar(&phase, "phase", "", "pinned incident phase")
	command.Flags().StringVar(&expectedSHA, "self-sha256", "", "controller's immutable agent identity")
	command.Flags().BoolVar(&apply, "apply", false, "authorize this native host phase")
	return command
}

func runIncidentAgent(parent context.Context, node, phase, keyPath, hostsPath, digest string) ([]byte, error) {
	if _, ok := incidentRecoveryTargets[node]; !ok || !incidentHostPhase(phase) || !incidentDigest(digest) {
		return nil, errors.New("invalid native agent invocation")
	}
	key, err := os.ReadFile(keyPath)
	if err != nil {
		return nil, err
	}
	signer, err := ssh.ParsePrivateKey(key)
	clear(key)
	if err != nil {
		return nil, fmt.Errorf("parse SSH identity: %w", err)
	}
	hostKey, err := knownhosts.New(hostsPath)
	if err != nil {
		return nil, err
	}
	port := "22"
	if node == "node3" {
		port = "1098"
	} else if node == "node8" {
		port = "1099"
	}
	address := net.JoinHostPort(node+".gonka-dev.net", port)
	ctx, cancel := context.WithTimeout(parent, 3*time.Minute)
	defer cancel()
	conn, err := (&net.Dialer{Timeout: 10 * time.Second}).DialContext(ctx, "tcp", address)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()
	_ = conn.SetDeadline(time.Now().Add(3 * time.Minute))
	clientConn, channels, requests, err := ssh.NewClientConn(conn, address, &ssh.ClientConfig{
		User: "root", Auth: []ssh.AuthMethod{ssh.PublicKeys(signer)}, HostKeyCallback: hostKey,
	})
	if err != nil {
		return nil, err
	}
	client := ssh.NewClient(clientConn, channels, requests)
	defer client.Close()
	session, err := client.NewSession()
	if err != nil {
		return nil, err
	}
	defer session.Close()
	output := &incidentAgentOutput{limit: 4 << 20, cancel: cancel}
	session.Stdout, session.Stderr = output, output
	// SSH exec carries a fixed Go executable and allowlisted tokens only.
	// No shell source, interpolation, redirection or operator-supplied argv.
	invocation := incidentAgentPath + " incident-recovery-local --node " + node + " --phase " + phase + " --self-sha256 " + digest
	if phase != "status" {
		invocation += " --apply"
	}
	err = session.Run(invocation)
	if ctx.Err() != nil {
		err = ctx.Err()
	}
	return output.Bytes(), err
}

type incidentAgentOutput struct {
	mu     sync.Mutex
	buffer bytes.Buffer
	limit  int
	cancel context.CancelFunc
}

func (b *incidentAgentOutput) Write(data []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.buffer.Len()+len(data) > b.limit {
		b.cancel()
		return 0, errors.New("native agent output exceeds receipt limit")
	}
	return b.buffer.Write(data)
}

func (b *incidentAgentOutput) Bytes() []byte {
	b.mu.Lock()
	defer b.mu.Unlock()
	return append([]byte(nil), b.buffer.Bytes()...)
}
