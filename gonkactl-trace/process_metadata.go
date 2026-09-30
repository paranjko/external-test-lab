package main

import (
	"context"
	"encoding/json"
	"os/exec"
	"regexp"
	"strings"
	"time"
)

// Only non-secret Docker fields are requested; never collect full inspect output.
type ProcessMetadata struct {
	ID           string `json:"id"`
	Created      string `json:"created"`
	StartedAt    string `json:"started_at"`
	RestartCount int    `json:"restart_count"`
}

var containerIDRE = regexp.MustCompile(`^[a-f0-9]{64}$`)

func inspectProcess(host, container string, timeout int) *ProcessMetadata {
	if !safeID.MatchString(host) || !safeID.MatchString(container) {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeout)*time.Second)
	defer cancel()
	format := `{"id":{{json .Id}},"created":{{json .Created}},"started_at":{{json .State.StartedAt}},"restart_count":{{json .RestartCount}}}`
	cmd := exec.CommandContext(ctx, "ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=8", host, "docker inspect --format "+quote(format)+" "+quote(container))
	b, err := cmd.Output()
	var p ProcessMetadata
	if err != nil || json.Unmarshal(b, &p) != nil || !containerIDRE.MatchString(p.ID) || timestamp(p.Created).IsZero() {
		return nil
	}
	return &p
}

func annotateProcess(e *Event, r Receipt) {
	if e.Attr == nil {
		e.Attr = map[string]string{}
	}
	e.Attr["process.source"] = r.Source
	e.Attr["process.generation_basis"] = "unverified source stream; no container metadata"
	if r.Process == nil || !containerIDRE.MatchString(r.Process.ID) || e.Time.IsZero() {
		return
	}
	created := timestamp(r.Process.Created)
	if created.IsZero() || e.Time.Before(created) {
		return
	}
	e.Attr["process.generation"] = "container-" + r.Process.ID
	e.Attr["process.generation_basis"] = "Docker container ID and Created; not a proven process restart history"
	e.Attr["process.created"] = r.Process.Created
	e.Attr["process.metadata_collected_at"] = iso(r.Collected)
}

func processActor(o ConsensusObservation, kind string) (string, string, string) {
	if generation := o.Attributes["process.generation"]; strings.HasPrefix(generation, "container-") && containerIDRE.MatchString(strings.TrimPrefix(generation, "container-")) {
		return kind + "@" + o.Observer + "/" + generation,
			kind + "@" + o.Observer + " / container " + strings.TrimPrefix(generation, "container-")[:12], o.Attributes["process.generation_basis"]
	}
	return kind + "@" + o.Observer + "/source-" + pfID(strings.Split(o.Source, "#")[0]),
		kind + "@" + o.Observer + " / generation unverified", "Source stream only; deployment and process generation unverified"
}
