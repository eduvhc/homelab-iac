// Package bootstrap is the declarative one-shot installer engine. It reads
// a services/<svc>/bootstrap.yaml manifest and emits an idempotent shell
// script (run on the target LXC via ssh stdin). Same execution model as
// the per-service bootstrap.sh scripts it replaces — what changes is that
// each directive's idempotency lives in one Go function instead of being
// reinvented in every script.
//
// Run pipeline:
//
//	1. Load + validate manifest.
//	2. Emit one shell script combining all directives in a deterministic
//	   order:  apt → binaries → users → dirs → files → random_secrets
//	          → commands → systemd
//	3. The caller (cmd/bootstrap) is responsible for delivering the script
//	   to the target (apply.sh ssh-pipes it into `sh -s` on the LXC).
//
// Directives intentionally have narrow scopes — when something doesn't fit
// (e.g. Authelia's argon2id RSA generation), use the `commands:` escape
// hatch rather than inventing a new directive.
package bootstrap

import (
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

// Manifest is the schema for services/<svc>/bootstrap.yaml.
type Manifest struct {
	Host    string         `yaml:"host"`
	APT     APT            `yaml:"apt,omitempty"`
	Binary  []Binary       `yaml:"binaries,omitempty"`
	Users   []User         `yaml:"users,omitempty"`
	Dirs    []Dir          `yaml:"dirs,omitempty"`
	Files   []FileWrite    `yaml:"files,omitempty"`
	Secrets []SecretsFile  `yaml:"random_secrets,omitempty"`
	Cmds    []Command      `yaml:"commands,omitempty"`
	Systemd SystemdActions `yaml:"systemd,omitempty"`
}

// APT installs Debian repos + packages. Both fields are optional; the
// engine runs `apt-get update -qq` once before any install.
type APT struct {
	Repos    []APTRepo `yaml:"repos,omitempty"`
	Packages []string  `yaml:"packages,omitempty"`
}

// APTRepo adds a signed Debian repo. KeyringURL is downloaded and dearmored
// to KeyringDest (idempotent — re-download only if file missing/empty).
// DebLine is written to /etc/apt/sources.list.d/<name>.list.
type APTRepo struct {
	Name         string `yaml:"name"`
	KeyringURL   string `yaml:"keyring_url"`
	KeyringDest  string `yaml:"keyring_dest"`
	DebLine      string `yaml:"deb_line"`
}

// Binary downloads + installs a binary from a GitHub release. AssetTemplate
// is the asset filename pattern; {tag} and {tag_num} are substituted with
// the latest release tag and its numeric form (v0.60.3 → 0.60.3). If
// Extract is set, the binary is extracted from a tar.gz with that member
// name; otherwise AssetTemplate is treated as the raw binary.
type Binary struct {
	Name           string `yaml:"name"`
	GithubRepo     string `yaml:"github_repo"`
	AssetTemplate  string `yaml:"asset_template"`
	Extract        string `yaml:"extract,omitempty"`
	Dest           string `yaml:"dest"`
	Mode           string `yaml:"mode,omitempty"`
}

// User creates a system user (useradd) if absent.
type User struct {
	Name         string `yaml:"name"`
	System       bool   `yaml:"system,omitempty"`
	NoCreateHome bool   `yaml:"no_create_home,omitempty"`
	Shell        string `yaml:"shell,omitempty"`
	Home         string `yaml:"home,omitempty"`
}

// Dir is a mkdir+chown+chmod (uses `install -d`).
type Dir struct {
	Path  string `yaml:"path"`
	Owner string `yaml:"owner,omitempty"`
	Mode  string `yaml:"mode,omitempty"`
}

// FileWrite writes a literal file from one of three sources:
//
//	Content          inline literal string (multi-line OK)
//	ContentFromEnv   value of named env var (e.g. TUNNEL_TOKEN)
//	Src              relative path under the service's target/ dir; the
//	                 engine reads the file at emit time and inlines via
//	                 base64+decode so the generated script is self-contained.
//
// RestartOnChange optionally restarts a systemd unit if this file's content
// changed (and only then) — useful for token files or unit files where the
// daemon must reload to pick up the new state.
type FileWrite struct {
	Dest            string `yaml:"dest"`
	Content         string `yaml:"content,omitempty"`
	ContentFromEnv  string `yaml:"content_from_env,omitempty"`
	Src             string `yaml:"src,omitempty"`
	Owner           string `yaml:"owner,omitempty"`
	Mode            string `yaml:"mode,omitempty"`
	RestartOnChange string `yaml:"restart_on_change,omitempty"`
}

// SecretsFile generates a key=value env file if missing. Each entry's value
// is a random alphanumeric string of the requested length.
type SecretsFile struct {
	Dest      string         `yaml:"dest"`
	Owner     string         `yaml:"owner,omitempty"`
	Mode      string         `yaml:"mode,omitempty"`
	IfMissing bool           `yaml:"if_missing,omitempty"`
	Entries   []SecretsEntry `yaml:"entries"`
}

type SecretsEntry struct {
	Key    string `yaml:"key"`
	Length int    `yaml:"length"`
}

// Command is the escape hatch. Runs Shell verbatim, optionally guarded by
// IfMissingFile or IfMissingCmd. Use sparingly — prefer a typed directive.
type Command struct {
	Shell         string `yaml:"shell"`
	IfMissingFile string `yaml:"if_missing_file,omitempty"`
	IfMissingCmd  string `yaml:"if_missing_cmd,omitempty"`
}

// SystemdActions runs as the last phase. DaemonReload is implicit when any
// new .service file was placed (FileWrite into /etc/systemd/system); the
// flag is for the rare case you want to force one without a file change.
type SystemdActions struct {
	DaemonReload bool     `yaml:"daemon_reload,omitempty"`
	Enable       []string `yaml:"enable,omitempty"`
	Start        []string `yaml:"start,omitempty"`
}

// Load reads + validates a manifest.
func Load(path string) (Manifest, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Manifest{}, fmt.Errorf("read %s: %w", path, err)
	}
	var m Manifest
	if err := yaml.Unmarshal(data, &m); err != nil {
		return Manifest{}, fmt.Errorf("parse %s: %w", path, err)
	}
	if err := m.Validate(); err != nil {
		return Manifest{}, fmt.Errorf("%s: %w", path, err)
	}
	return m, nil
}

// Validate enforces per-directive required fields.
func (m Manifest) Validate() error {
	for i, r := range m.APT.Repos {
		if r.Name == "" || r.KeyringURL == "" || r.KeyringDest == "" || r.DebLine == "" {
			return fmt.Errorf("apt.repos[%d]: name, keyring_url, keyring_dest, deb_line all required", i)
		}
	}
	for i, b := range m.Binary {
		if b.Name == "" || b.GithubRepo == "" || b.AssetTemplate == "" || b.Dest == "" {
			return fmt.Errorf("binaries[%d]: name, github_repo, asset_template, dest all required", i)
		}
	}
	for i, u := range m.Users {
		if u.Name == "" {
			return fmt.Errorf("users[%d]: name required", i)
		}
	}
	for i, d := range m.Dirs {
		if d.Path == "" {
			return fmt.Errorf("dirs[%d]: path required", i)
		}
	}
	for i, f := range m.Files {
		if f.Dest == "" {
			return fmt.Errorf("files[%d]: dest required", i)
		}
		sources := 0
		if f.Content != "" {
			sources++
		}
		if f.ContentFromEnv != "" {
			sources++
		}
		if f.Src != "" {
			sources++
		}
		if sources != 1 {
			return fmt.Errorf("files[%d] (%s): exactly one of content / content_from_env / src required", i, f.Dest)
		}
	}
	for i, s := range m.Secrets {
		if s.Dest == "" || len(s.Entries) == 0 {
			return fmt.Errorf("random_secrets[%d]: dest + non-empty entries required", i)
		}
		for j, e := range s.Entries {
			if e.Key == "" || e.Length <= 0 {
				return fmt.Errorf("random_secrets[%d].entries[%d]: key + length>0 required", i, j)
			}
		}
	}
	for i, c := range m.Cmds {
		if c.Shell == "" {
			return fmt.Errorf("commands[%d]: shell required", i)
		}
	}
	return nil
}
