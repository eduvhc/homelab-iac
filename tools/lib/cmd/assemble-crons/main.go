// Command assemble-crons emits the assembled crontab to stdout for
// tools/apply.sh to install at /etc/cron.d/iac. All logic lives in
// internal/cron; this binary is a thin orchestrator.
//
// Usage:
//
//	go run ./cmd/assemble-crons [<repo-root>]
//	   (from tools/lib/ — sets module context)
package main

import (
	"fmt"
	"os"
	"path/filepath"

	"homelab-iac/tools/lib/internal/cron"
)

func main() {
	repo := "."
	if len(os.Args) > 1 {
		repo = os.Args[1]
	}
	root, err := filepath.Abs(repo)
	if err != nil {
		fatalf("resolve repo root: %v", err)
	}

	cronEntries, err := cron.LoadCronEntries(root)
	if err != nil {
		fatalf("%v", err)
	}
	backupEntries, err := cron.LoadBackupEntries(root)
	if err != nil {
		fatalf("%v", err)
	}
	out, err := cron.Emit(append(cronEntries, backupEntries...))
	if err != nil {
		fatalf("%v", err)
	}
	if _, err := os.Stdout.WriteString(out); err != nil {
		fatalf("write stdout: %v", err)
	}
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "assemble-crons: "+format+"\n", args...)
	os.Exit(1)
}
