// Command sync reads a services/<svc>/sync.yaml manifest and converges a
// target LXC to its declared file/restart state. Replaces the per-service
// sync.sh scripts (which were ~95% boilerplate around envsubst + scp +
// systemctl).
//
// Pipeline:
//
//	1. Load + validate the manifest.
//	2. Render each `files[]` entry through envsubst with its declared
//	   whitelist of vars (read from this process's environment).
//	3. Run validate_local (locally on the rendered file) if specified.
//	4. One ssh round-trip to fetch sha256 of every dest path on the target.
//	5. For each file whose local sha256 differs from remote: scp (or
//	   atomic_push for files marked atomic), apply owner/mode, then run
//	   validate_remote on the target if specified.
//	6. Collect+dedupe on_change actions from the set of files that changed.
//	   Apply in one ssh round-trip: daemon-reload (if any), reloads (with
//	   restart fallback), restarts, escape-hatch commands.
//	7. Optionally check `verify_active` for the listed unit(s).
//
// Pre-reqs in environment:
//
//	$REPO_ROOT     repo root (set by caller, e.g. sourced from common.sh)
//	IP_<HOST>      target IP (e.g. IP_NAVIDROME), populated by
//	               tools/lib/infra/tofu.sh — caller sources it.
//	Any vars referenced by files[].envsubst must also be in env.
//
// Usage:
//
//	go run ./tools/lib/sync <services/<svc>/sync.yaml>
//
// Run from the repo root or from anywhere with REPO_ROOT exported.
package main

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

type Config struct {
	Host          string   `yaml:"host"`
	Files         []File   `yaml:"files"`
	VerifyActive  StrOrList `yaml:"verify_active,omitempty"`
}

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

func main() {
	if len(os.Args) != 2 {
		fatalf("usage: sync <services/<svc>/sync.yaml>")
	}
	manifestPath := os.Args[1]
	svcDir := filepath.Dir(manifestPath)
	svcName := filepath.Base(svcDir)

	repoRoot := os.Getenv("REPO_ROOT")
	if repoRoot == "" {
		fatalf("REPO_ROOT not exported (source tools/lib/core/common.sh first)")
	}

	data, err := os.ReadFile(manifestPath)
	if err != nil {
		fatalf("read %s: %v", manifestPath, err)
	}
	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		fatalf("parse %s: %v", manifestPath, err)
	}
	if cfg.Host == "" {
		fatalf("%s: 'host' is required", manifestPath)
	}
	if len(cfg.Files) == 0 {
		fatalf("%s: at least one entry in 'files' is required", manifestPath)
	}

	// Resolve target host. IP_<HOST> must be in env (populated by
	// tools/lib/infra/tofu.sh before invoking this engine).
	envVar := "IP_" + strings.ToUpper(strings.ReplaceAll(cfg.Host, "-", "_"))
	ip := os.Getenv(envVar)
	if ip == "" {
		fatalf("$%s not set — source tools/lib/infra/tofu.sh first", envVar)
	}
	target := "root@" + ip

	// ── Render + validate locally ─────────────────────────────────────────
	tmpDir, err := os.MkdirTemp("", "sync-"+svcName+"-")
	if err != nil {
		fatalf("mktemp: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	// Map local-rendered path per file index.
	rendered := make([]string, len(cfg.Files))

	for i, f := range cfg.Files {
		if f.Src == "" || f.Dest == "" {
			fatalf("%s: files[%d]: src and dest are required", manifestPath, i)
		}
		srcPath := filepath.Join(svcDir, f.Src)
		dstName := filepath.Base(f.Dest)
		renderedPath := filepath.Join(tmpDir, dstName)

		if err := renderFile(srcPath, renderedPath, f.Envsubst); err != nil {
			fatalf("render %s: %v", f.Src, err)
		}
		rendered[i] = renderedPath

		if f.ValidateLocal != "" {
			expanded := strings.ReplaceAll(f.ValidateLocal, "$f", renderedPath)
			if err := runShell(expanded); err != nil {
				fatalf("validate_local for %s failed: %v", f.Src, err)
			}
		}
	}

	// ── One ssh round-trip to fetch remote sha256s ────────────────────────
	dests := make([]string, len(cfg.Files))
	for i, f := range cfg.Files {
		dests[i] = f.Dest
	}
	remoteSums, err := fetchRemoteSums(target, dests)
	if err != nil {
		fatalf("fetch remote sha256: %v", err)
	}

	// ── Push files whose hashes differ ────────────────────────────────────
	var changed []int
	for i, f := range cfg.Files {
		localSum, err := sha256file(rendered[i])
		if err != nil {
			fatalf("sha256 %s: %v", rendered[i], err)
		}
		if localSum == remoteSums[f.Dest] {
			continue
		}
		if err := pushFile(rendered[i], target, f.Dest, f.Atomic); err != nil {
			fatalf("push %s: %v", f.Dest, err)
		}
		if err := applyAttrs(target, f.Dest, f.Owner, f.Mode); err != nil {
			fatalf("chown/chmod %s: %v", f.Dest, err)
		}
		if f.ValidateRemote != "" {
			expanded := strings.ReplaceAll(f.ValidateRemote, "$f", f.Dest)
			if err := runRemote(target, expanded); err != nil {
				fatalf("validate_remote for %s failed: %v", f.Dest, err)
			}
		}
		changed = append(changed, i)
	}

	if len(changed) == 0 {
		fmt.Printf("%s: no changes\n", svcName)
		return
	}

	// ── Collect+dedupe on_change actions ──────────────────────────────────
	var (
		needsDaemonReload bool
		restarts          []string
		reloads           []string
		commands          []string
	)
	for _, i := range changed {
		for _, a := range cfg.Files[i].OnChange {
			if a.DaemonReload {
				needsDaemonReload = true
			}
			if a.Restart != "" {
				restarts = appendUnique(restarts, a.Restart)
			}
			if a.Reload != "" {
				reloads = appendUnique(reloads, a.Reload)
			}
			if a.Command != "" {
				commands = appendUnique(commands, a.Command)
			}
		}
	}
	sort.Strings(restarts)
	sort.Strings(reloads)
	sort.Strings(commands)

	// ── Apply in one ssh round-trip ───────────────────────────────────────
	var cmds []string
	if needsDaemonReload {
		cmds = append(cmds, "systemctl daemon-reload")
	}
	// Reloads first (cheaper than restarts), with restart fallback for
	// units that don't support reload — matches what services/gateway/caddy
	// historically did manually.
	for _, u := range reloads {
		cmds = append(cmds, fmt.Sprintf("(systemctl reload %s 2>/dev/null || systemctl restart %s)", u, u))
	}
	for _, u := range restarts {
		cmds = append(cmds, "systemctl restart "+u)
	}
	cmds = append(cmds, commands...)
	if len(cfg.VerifyActive) > 0 {
		cmds = append(cmds, "sleep 2", "systemctl is-active "+strings.Join([]string(cfg.VerifyActive), " "))
	}

	if err := runRemote(target, strings.Join(cmds, " && ")); err != nil {
		fatalf("apply actions: %v", err)
	}
	fmt.Printf("%s: %d file(s) changed → applied\n", svcName, len(changed))
}

// renderFile pipes src through `envsubst '$V1 $V2 ...'` into dst. If
// allowedVars is empty, envsubst substitutes nothing (we never want
// uncontrolled $-expansion in config files).
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
		quoted := make([]string, len(allowedVars))
		for i, v := range allowedVars {
			quoted[i] = "$" + v
		}
		args = strings.Join(quoted, " ")
	}
	cmd := exec.Command("envsubst", args)
	cmd.Stdin = in
	cmd.Stdout = out
	cmd.Stderr = os.Stderr
	cmd.Env = os.Environ()
	return cmd.Run()
}

// fetchRemoteSums runs a single `sha256sum f1 f2 ... 2>/dev/null` on the
// target and parses the result back into a {dest: sha256-hex} map. Missing
// files just don't appear in the map (so the caller treats them as "differs",
// triggering a push).
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

// pushFile scp's local→target:dest. Atomic mode uses scp .tmp + mv so a
// file watcher on the dest never sees a truncated mid-write state.
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

// applyAttrs sets owner and/or mode on the just-pushed file. Skips a chown
// or chmod if the corresponding field is empty (preserves existing).
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

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "sync: "+format+"\n", args...)
	os.Exit(1)
}
