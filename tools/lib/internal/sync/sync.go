// Package sync runs the declarative sync engine: it reads a
// services/<svc>/sync.yaml manifest and converges a target LXC to its
// declared file/restart state.
//
// Pipeline (one call to Run):
//
//	1. Render each files[] entry through envsubst with its whitelist of
//	   vars (read from this process's environment).
//	2. validate_local on each rendered file (optional).
//	3. One ssh round-trip to fetch sha256 of every dest path.
//	4. For each file with a sha256 mismatch: scp (atomic_push if marked),
//	   apply owner/mode, then validate_remote (optional).
//	5. Dedupe on_change actions from the set of files that changed; apply
//	   in one ssh round-trip in order:
//	       daemon-reload → reloads (w/ restart fallback) → restarts → commands.
//	6. systemctl is-active on verify_active units (if specified).
package sync

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// Config is the schema for services/<svc>/sync.yaml.
type Config struct {
	Host         string    `yaml:"host"`
	PreRun       []Hook    `yaml:"pre_run,omitempty"`
	Files        []File    `yaml:"files"`
	VerifyActive StrOrList `yaml:"verify_active,omitempty"`
}

// File describes one rendered+pushed artifact.
type File struct {
	Src            string   `yaml:"src"`
	Dest           string   `yaml:"dest"`
	Envsubst       []string `yaml:"envsubst,omitempty"`
	Owner          string   `yaml:"owner,omitempty"`
	Mode           string   `yaml:"mode,omitempty"`
	Atomic         bool     `yaml:"atomic,omitempty"`
	ValidateLocal  string   `yaml:"validate_local,omitempty"`
	ValidateRemote string   `yaml:"validate_remote,omitempty"`
	OnChange       []Action `yaml:"on_change,omitempty"`
}

// Action is one element of on_change. At most one of {DaemonReload, Restart,
// Reload, Command} should be set per element; the engine dedupes across
// the manifest before applying.
type Action struct {
	DaemonReload bool   `yaml:"daemon_reload,omitempty"`
	Restart      string `yaml:"restart,omitempty"`
	Reload       string `yaml:"reload,omitempty"`
	Command      string `yaml:"command,omitempty"`
}

// StrOrList lets verify_active be either a scalar string or a list — common
// YAML ergonomics ("one unit" vs "multiple units").
type StrOrList []string

func (s *StrOrList) UnmarshalYAML(node *yaml.Node) error {
	switch node.Kind {
	case yaml.ScalarNode:
		*s = []string{node.Value}
		return nil
	case yaml.SequenceNode:
		var arr []string
		if err := node.Decode(&arr); err != nil {
			return err
		}
		*s = arr
		return nil
	}
	return fmt.Errorf("verify_active must be string or list, got kind %d", node.Kind)
}

// LoadManifest reads + validates a sync.yaml.
func LoadManifest(path string) (Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, fmt.Errorf("read %s: %w", path, err)
	}
	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return Config{}, fmt.Errorf("parse %s: %w", path, err)
	}
	if cfg.Host == "" {
		return Config{}, fmt.Errorf("%s: 'host' is required", path)
	}
	if len(cfg.Files) == 0 {
		return Config{}, fmt.Errorf("%s: at least one entry in 'files' is required", path)
	}
	for i, f := range cfg.Files {
		if f.Src == "" || f.Dest == "" {
			return Config{}, fmt.Errorf("%s: files[%d]: src and dest are required", path, i)
		}
	}
	return cfg, nil
}

// Run executes the pipeline against cfg. svcDir is the directory containing
// the manifest (used to resolve File.Src relative paths). svcName is shown
// in the human-readable status line.
func Run(cfg Config, svcDir, svcName string) error {
	target, err := resolveTarget(cfg.Host)
	if err != nil {
		return err
	}

	// ── pre_run hooks (e.g. argon2id_hash) — may mutate sops + export env
	// vars consumed by files[].envsubst below.
	for i, h := range cfg.PreRun {
		if err := runHook(h, target); err != nil {
			return fmt.Errorf("pre_run[%d] (type=%s): %w", i, h.Type, err)
		}
	}

	tmpDir, err := os.MkdirTemp("", "sync-"+svcName+"-")
	if err != nil {
		return fmt.Errorf("mktemp: %w", err)
	}
	defer os.RemoveAll(tmpDir)

	// ── Render + validate locally ────────────────────────────────────────
	rendered := make([]string, len(cfg.Files))
	for i, f := range cfg.Files {
		srcPath := filepath.Join(svcDir, f.Src)
		renderedPath := filepath.Join(tmpDir, filepath.Base(f.Dest))
		if err := renderFile(srcPath, renderedPath, f.Envsubst); err != nil {
			return fmt.Errorf("render %s: %w", f.Src, err)
		}
		rendered[i] = renderedPath

		if f.ValidateLocal != "" {
			expanded := strings.ReplaceAll(f.ValidateLocal, "$f", renderedPath)
			if err := runShell(expanded); err != nil {
				return fmt.Errorf("validate_local for %s failed: %w", f.Src, err)
			}
		}
	}

	// ── One ssh round-trip to fetch remote sha256s ───────────────────────
	dests := make([]string, len(cfg.Files))
	for i, f := range cfg.Files {
		dests[i] = f.Dest
	}
	remoteSums, err := fetchRemoteSums(target, dests)
	if err != nil {
		return fmt.Errorf("fetch remote sha256: %w", err)
	}

	// ── Push files whose hashes differ ───────────────────────────────────
	var changed []int
	for i, f := range cfg.Files {
		localSum, err := sha256file(rendered[i])
		if err != nil {
			return fmt.Errorf("sha256 %s: %w", rendered[i], err)
		}
		if localSum == remoteSums[f.Dest] {
			continue
		}
		if err := pushFile(rendered[i], target, f.Dest, f.Atomic); err != nil {
			return fmt.Errorf("push %s: %w", f.Dest, err)
		}
		if err := applyAttrs(target, f.Dest, f.Owner, f.Mode); err != nil {
			return fmt.Errorf("chown/chmod %s: %w", f.Dest, err)
		}
		if f.ValidateRemote != "" {
			expanded := strings.ReplaceAll(f.ValidateRemote, "$f", f.Dest)
			if err := runRemote(target, expanded); err != nil {
				return fmt.Errorf("validate_remote for %s failed: %w", f.Dest, err)
			}
		}
		changed = append(changed, i)
	}

	if len(changed) == 0 {
		fmt.Printf("%s: no changes\n", svcName)
		return nil
	}

	// ── Collect+dedupe on_change actions ─────────────────────────────────
	plan := collectActions(cfg, changed)
	if err := runRemote(target, plan.shellLine(cfg.VerifyActive)); err != nil {
		return fmt.Errorf("apply actions: %w", err)
	}
	fmt.Printf("%s: %d file(s) changed → applied\n", svcName, len(changed))
	return nil
}

type actionPlan struct {
	needsDaemonReload bool
	restarts          []string
	reloads           []string
	commands          []string
}

func collectActions(cfg Config, changed []int) actionPlan {
	var p actionPlan
	for _, i := range changed {
		for _, a := range cfg.Files[i].OnChange {
			if a.DaemonReload {
				p.needsDaemonReload = true
			}
			if a.Restart != "" {
				p.restarts = appendUnique(p.restarts, a.Restart)
			}
			if a.Reload != "" {
				p.reloads = appendUnique(p.reloads, a.Reload)
			}
			if a.Command != "" {
				p.commands = appendUnique(p.commands, a.Command)
			}
		}
	}
	sort.Strings(p.restarts)
	sort.Strings(p.reloads)
	sort.Strings(p.commands)
	return p
}

// shellLine builds the single ssh command line: daemon-reload first, then
// reloads (with restart fallback), then restarts, then commands, then
// optional verify_active check.
func (p actionPlan) shellLine(verifyActive StrOrList) string {
	var cmds []string
	if p.needsDaemonReload {
		cmds = append(cmds, "systemctl daemon-reload")
	}
	for _, u := range p.reloads {
		cmds = append(cmds, fmt.Sprintf("(systemctl reload %s 2>/dev/null || systemctl restart %s)", u, u))
	}
	for _, u := range p.restarts {
		cmds = append(cmds, "systemctl restart "+u)
	}
	cmds = append(cmds, p.commands...)
	if len(verifyActive) > 0 {
		cmds = append(cmds, "sleep 2", "systemctl is-active "+strings.Join([]string(verifyActive), " "))
	}
	return strings.Join(cmds, " && ")
}

// resolveTarget reads IP_<HOST> from env (populated by tools/lib/infra/tofu.sh)
// and returns the ssh target "root@<ip>".
func resolveTarget(host string) (string, error) {
	envVar := "IP_" + strings.ToUpper(strings.ReplaceAll(host, "-", "_"))
	ip := os.Getenv(envVar)
	if ip == "" {
		return "", fmt.Errorf("$%s not set — source tools/lib/infra/tofu.sh first", envVar)
	}
	return "root@" + ip, nil
}

// renderFile pipes src through `envsubst '$V1 $V2 ...'` into dst.
func renderFile(src, dst string, allowedVars []string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()

	args := ""
	if len(allowedVars) > 0 {
		parts := make([]string, len(allowedVars))
		for i, v := range allowedVars {
			parts[i] = "$" + v
		}
		args = strings.Join(parts, " ")
	}
	cmd := exec.Command("envsubst", args)
	cmd.Stdin = in
	cmd.Stdout = out
	cmd.Stderr = os.Stderr
	cmd.Env = os.Environ()
	return cmd.Run()
}

func fetchRemoteSums(target string, dests []string) (map[string]string, error) {
	if len(dests) == 0 {
		return nil, nil
	}
	quoted := make([]string, len(dests))
	for i, d := range dests {
		quoted[i] = "'" + strings.ReplaceAll(d, "'", `'\''`) + "'"
	}
	out, err := exec.Command("ssh", target, "sha256sum "+strings.Join(quoted, " ")+" 2>/dev/null || true").Output()
	if err != nil {
		return nil, err
	}
	sums := map[string]string{}
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 2 {
			sums[fields[1]] = fields[0]
		}
	}
	return sums, nil
}

func sha256file(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func pushFile(localPath, target, destPath string, atomic bool) error {
	remotePath := destPath
	if atomic {
		remotePath = destPath + ".tmp"
	}
	if err := exec.Command("scp", "-q", localPath, target+":"+remotePath).Run(); err != nil {
		return fmt.Errorf("scp: %w", err)
	}
	if atomic {
		if err := runRemote(target, fmt.Sprintf("mv '%s' '%s'", destPath+".tmp", destPath)); err != nil {
			return fmt.Errorf("atomic mv: %w", err)
		}
	}
	return nil
}

func applyAttrs(target, dest, owner, mode string) error {
	var parts []string
	if owner != "" {
		parts = append(parts, fmt.Sprintf("chown '%s' '%s'", owner, dest))
	}
	if mode != "" {
		parts = append(parts, fmt.Sprintf("chmod %s '%s'", mode, dest))
	}
	if len(parts) == 0 {
		return nil
	}
	return runRemote(target, strings.Join(parts, " && "))
}

func runRemote(target, cmd string) error {
	c := exec.Command("ssh", target, cmd)
	c.Stdout = os.Stdout
	c.Stderr = os.Stderr
	return c.Run()
}

func runShell(cmd string) error {
	c := exec.Command("sh", "-c", cmd)
	c.Stdout = os.Stdout
	c.Stderr = os.Stderr
	return c.Run()
}

func appendUnique(s []string, v string) []string {
	for _, x := range s {
		if x == v {
			return s
		}
	}
	return append(s, v)
}
