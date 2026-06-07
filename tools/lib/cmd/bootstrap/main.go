// Command bootstrap emits an idempotent shell script for a single
// services/<svc>/bootstrap.yaml manifest. The caller (tools/apply.sh) is
// responsible for delivering it (typically: ssh-pipe into `sh -s` on the
// target LXC). All logic lives in internal/bootstrap.
//
// Usage:
//
//	go run ./cmd/bootstrap <services/<svc>/bootstrap.yaml>   # writes to stdout
//	   (from tools/lib/ — sets module context)
package main

import (
	"fmt"
	"os"
	"path/filepath"

	"homelab-iac/tools/lib/internal/bootstrap"
)

func main() {
	if len(os.Args) != 2 {
		fatalf("usage: bootstrap <services/<svc>/bootstrap.yaml>")
	}
	path := os.Args[1]
	m, err := bootstrap.Load(path)
	if err != nil {
		fatalf("%v", err)
	}
	script, err := bootstrap.Emit(m, filepath.Dir(path))
	if err != nil {
		fatalf("%v", err)
	}
	if _, err := os.Stdout.WriteString(script); err != nil {
		fatalf("write stdout: %v", err)
	}
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "bootstrap: "+format+"\n", args...)
	os.Exit(1)
}
