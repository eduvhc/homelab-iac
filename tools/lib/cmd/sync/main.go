// Command sync invokes the declarative sync engine against a single
// services/<svc>/sync.yaml manifest. All logic lives in internal/sync.
//
// Usage:
//
//	go run ./cmd/sync <services/<svc>/sync.yaml>
//	   (from tools/lib/ — sets module context)
package main

import (
	"fmt"
	"os"
	"path/filepath"

	"homelab-iac/tools/lib/internal/sync"
)

func main() {
	if len(os.Args) != 2 {
		fatalf("usage: sync <services/<svc>/sync.yaml>")
	}
	manifestPath := os.Args[1]
	cfg, err := sync.LoadManifest(manifestPath)
	if err != nil {
		fatalf("%v", err)
	}
	svcDir := filepath.Dir(manifestPath)
	svcName := filepath.Base(svcDir)
	if err := sync.Run(cfg, svcDir, svcName); err != nil {
		fatalf("%v", err)
	}
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "sync: "+format+"\n", args...)
	os.Exit(1)
}
