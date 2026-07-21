// Rewrite heap-profile mapping paths to portable relative paths under .pprof/.
//
// Usage: rewrite_heap_profile_paths -prof PROFILE -root PPROF_ROOT
//
// Writes paths like .pprof/usr/local/bin/envoy (forward slashes) so the same
// archive works on Windows and Linux when analyzed from the collection directory.
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

	profAbs, err := filepath.Abs(msysToWindows(*profPath))
	if err != nil {
		exitErr(err)
	}
	rootAbs, err := filepath.Abs(msysToWindows(*profRoot))
	if err != nil {
		exitErr(err)
	}
	profDir := filepath.Dir(profAbs)

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
		podRel, ok := mappingToPodPath(m.File)
		if !ok {
			continue
		}
		// rootAbs is .../.pprof ; podRel is /usr/local/bin/envoy
		localAbs := filepath.Join(rootAbs, filepath.FromSlash(podRel))
		rel, err := filepath.Rel(profDir, localAbs)
		if err != nil {
			exitErr(err)
		}
		// Always store forward slashes for cross-OS portability.
		newPath := filepath.ToSlash(rel)
		if m.File == newPath {
			continue
		}
		m.File = newPath
		changed++
	}

	tmp, err := os.CreateTemp(profDir, ".heap-*.prof")
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
	fmt.Fprintf(os.Stderr, "rewrote %d mapping path(s) to portable .pprof/... relative paths\n", changed)
}

// mappingToPodPath returns a pod-style path (/usr/..., /lib/...) from a mapping file.
// Accepts raw pod paths, prior absolute rewrites (any OS), or relative .pprof/... paths.
func mappingToPodPath(file string) (string, bool) {
	// Normalize separators manually — filepath.ToSlash does not convert '\' on Linux.
	f := strings.ReplaceAll(file, "\\", "/")

	// Already portable relative: .pprof/usr/local/bin/envoy
	if strings.HasPrefix(f, ".pprof/") {
		return "/" + strings.TrimPrefix(f, ".pprof/"), true
	}

	// Prior absolute rewrite containing .../.pprof/usr/... (Windows or Linux abs path)
	if i := strings.Index(strings.ToLower(f), "/.pprof/"); i >= 0 {
		return f[i+len("/.pprof"):], true
	}

	// Raw pod path from the cluster.
	if strings.HasPrefix(f, "/usr/") || strings.HasPrefix(f, "/lib/") {
		return f, true
	}

	return "", false
}

func exitErr(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}

// msysToWindows converts Git Bash paths (/c/Users/...) to Windows (C:\Users\...).
func msysToWindows(p string) string {
	if len(p) >= 3 && p[0] == '/' && p[2] == '/' {
		d := p[1]
		if (d >= 'a' && d <= 'z') || (d >= 'A' && d <= 'Z') {
			drive := string(d)
			if d >= 'a' && d <= 'z' {
				drive = string(d - 'a' + 'A')
			}
			return drive + ":" + filepath.FromSlash(p[2:])
		}
	}
	return p
}
