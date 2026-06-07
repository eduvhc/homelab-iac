package sync

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strings"

	"homelab-iac/tools/lib/internal/secrets"
)

// Hook is a typed pre-sync step. The engine dispatches by Type into a
// per-type runner. Each runner is responsible for its own validation —
// the YAML schema here is a flat superset so all Hook variants share one
// struct without an inline tagged union.
type Hook struct {
	Type string `yaml:"type"`

	// argon2id_hash: regenerate a non-deterministic password hash on a
	// remote host only when the source password changed (tracked via a
	// sha256 marker stored alongside the hash in sops).
	SourceEnv     string `yaml:"source_env,omitempty"`
	TargetSopsKey string `yaml:"target_sops_key,omitempty"`
	MarkerSopsKey string `yaml:"marker_sops_key,omitempty"`
	RemoteCommand string `yaml:"remote_command,omitempty"`
	OutputMatch   string `yaml:"output_match,omitempty"`
}

// runHook dispatches by Type. target is the ssh "root@<ip>" pre-resolved
// from cfg.Host so all hooks share the same remote (matching the sync
// engine's whole-manifest-runs-against-one-host model).
func runHook(h Hook, target string) error {
	switch h.Type {
	case "argon2id_hash":
		return runArgon2idHash(h, target)
	default:
		return fmt.Errorf("unknown hook type %q (supported: argon2id_hash)", h.Type)
	}
}

// runArgon2idHash regenerates an argon2id digest on the remote host only
// when the source password changed (compared via a sha256 marker stored
// alongside in sops). The new digest + marker are written back to sops;
// the digest is also exported into the current process's env under
// $<TargetSopsKey> so downstream files[].envsubst entries can reference
// it. Idempotent: a no-op when marker matches.
func runArgon2idHash(h Hook, target string) error {
	for f, v := range map[string]string{
		"source_env":      h.SourceEnv,
		"target_sops_key": h.TargetSopsKey,
		"marker_sops_key": h.MarkerSopsKey,
		"remote_command":  h.RemoteCommand,
		"output_match":    h.OutputMatch,
	} {
		if v == "" {
			return fmt.Errorf("argon2id_hash hook: %q is required", f)
		}
	}

	sourceVal := os.Getenv(h.SourceEnv)
	if sourceVal == "" {
		return fmt.Errorf("argon2id_hash hook: $%s not set", h.SourceEnv)
	}

	sum := sha256.Sum256([]byte(sourceVal))
	pwSha := hex.EncodeToString(sum[:])

	sopsFile, err := secrets.File()
	if err != nil {
		return err
	}
	storedSha, err := secrets.Get(sopsFile, h.MarkerSopsKey)
	if err != nil {
		return err
	}
	storedHash, err := secrets.Get(sopsFile, h.TargetSopsKey)
	if err != nil {
		return err
	}

	if storedHash != "" && storedSha == pwSha {
		// Hash matches the current password — reuse without remote call.
		return os.Setenv(h.TargetSopsKey, storedHash)
	}

	fmt.Printf("argon2id_hash: regenerating %s on %s\n", h.TargetSopsKey, target)

	// Escape password for the single-quoted shell context in remote_command's
	// {password} placeholder. Argv is briefly visible on the remote — same
	// trade-off as the original shell script (binary doesn't accept stdin).
	escaped := strings.ReplaceAll(sourceVal, "'", `'\''`)
	cmd := strings.ReplaceAll(h.RemoteCommand, "{password}", escaped)

	out, err := exec.Command("ssh", target, cmd).Output()
	if err != nil {
		return fmt.Errorf("remote command failed: %w", err)
	}

	re, err := regexp.Compile("(?m)" + h.OutputMatch)
	if err != nil {
		return fmt.Errorf("invalid output_match regex: %w", err)
	}
	m := re.FindStringSubmatch(string(out))
	if len(m) < 2 {
		return fmt.Errorf("output_match did not capture group 1 in remote output:\n%s", string(out))
	}
	newHash := m[1]

	if err := secrets.Set(sopsFile, h.TargetSopsKey, newHash); err != nil {
		return fmt.Errorf("sops set %s: %w", h.TargetSopsKey, err)
	}
	if err := secrets.Set(sopsFile, h.MarkerSopsKey, pwSha); err != nil {
		return fmt.Errorf("sops set %s: %w", h.MarkerSopsKey, err)
	}

	fmt.Printf("argon2id_hash: refreshed → commit + push iac/secrets.sops.yaml\n")
	return os.Setenv(h.TargetSopsKey, newHash)
}
