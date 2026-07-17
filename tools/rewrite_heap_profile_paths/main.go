// Rewrite absolute pod paths in a heap profile to local paths under a .pprof tree.
//
// Usage: go run . -prof PROFILE -root PPROF_ROOT
//
// Optional (for analysis machines with Go). Collection via stats.sh still works
// without Go; rewriting is skipped if go is unavailable.
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/google/pprof/profile"
)

func main() {
	profPath := flag.String("prof", "", "heap profile to rewrite in place")
	profRoot := flag.String("root", "", "local .pprof directory mirroring pod paths")
	flag.Parse()

	if *profPath == "" || *profRoot == "" {
		fmt.Fprintf(os.Stderr, "usage: %s -prof PROFILE -root PPROF_ROOT\n", filepath.Base(os.Args[0]))
		os.Exit(2)
	}

	profAbs, err := filepath.Abs(*profPath)
	if err != nil {
		exitErr(err)
	}
	rootAbs, err := filepath.Abs(*profRoot)
	if err != nil {
		exitErr(err)
	}

	f, err := os.Open(profAbs)
	if err != nil {
		exitErr(err)
	}
	p, err := profile.Parse(f)
	f.Close()
	if err != nil {
		exitErr(err)
	}

	changed := 0
	for _, m := range p.Mapping {
		if !strings.HasPrefix(m.File, "/") {
			continue
		}
		// Already rewritten into this tree.
		if strings.HasPrefix(m.File, rootAbs) {
			continue
		}
		m.File = filepath.Join(rootAbs, m.File)
		changed++
	}

	tmp, err := os.CreateTemp(filepath.Dir(profAbs), ".heap-*.prof")
	if err != nil {
		exitErr(err)
	}
	tmpPath := tmp.Name()
	if err := p.Write(tmp); err != nil {
		tmp.Close()
		os.Remove(tmpPath)
		exitErr(err)
	}
	tmp.Close()
	if err := os.Rename(tmpPath, profAbs); err != nil {
		os.Remove(tmpPath)
		exitErr(err)
	}
	fmt.Fprintf(os.Stderr, "rewrote %d mapping path(s) under %s\n", changed, rootAbs)
}

func exitErr(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
