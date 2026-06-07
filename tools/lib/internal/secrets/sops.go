// Package secrets is a thin Go wrapper around the `sops` CLI for the
// read+write of single keys inside iac/secrets.sops.yaml.
//
// Mirrors the behavior of tools/lib/secrets/sops.sh::sops_get / sops_set —
// kept independent so the Go engines don't depend on shell helpers being
// sourced in the environment.
package secrets

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// File returns the path of the sops file: $SOPS_FILE if set, else
// $REPO_ROOT/iac/secrets.sops.yaml.
func File() (string, error) {
	if p := os.Getenv("SOPS_FILE"); p != "" {
		return p, nil
	}
	if root := os.Getenv("REPO_ROOT"); root != "" {
		return root + "/iac/secrets.sops.yaml", nil
	}
	return "", fmt.Errorf("neither $SOPS_FILE nor $REPO_ROOT is set")
}

// Get returns the value of key (empty string if absent). Decrypts the
// whole file into dotenv form, then matches line-by-line — same model as
// the shell helper, simple and correct.
func Get(file, key string) (string, error) {
	out, err := exec.Command("sops", "-d", "--output-type", "dotenv", file).Output()
	if err != nil {
		return "", fmt.Errorf("sops decrypt %s: %w", file, err)
	}
	prefix := key + "="
	for _, line := range strings.Split(string(out), "\n") {
		if strings.HasPrefix(line, prefix) {
			return strings.TrimPrefix(line, prefix), nil
		}
	}
	return "", nil
}

// Set upserts key=value in the sops file via `sops set` (in-place
// encrypted write). Caller is responsible for committing + pushing the
// changed file — this function does not touch git.
func Set(file, key, value string) error {
	// The value arg to `sops set` is JSON-encoded — Marshal a string gives
	// us "\"escaped\"".
	jsonVal, err := json.Marshal(value)
	if err != nil {
		return err
	}
	cmd := exec.Command("sops", "set", file, fmt.Sprintf(`["%s"]`, key), string(jsonVal))
	cmd.Stderr = os.Stderr
	return cmd.Run()
}
