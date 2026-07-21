# rewrite_heap_profile_paths

Writes paths like `.pprof/usr/local/bin/envoy` (forward slashes, relative to the
profile directory) so the same archive works on Windows and Linux when you
`cd` into the collection directory before running pprof.

## Prebuilt binaries (no Go needed at runtime)

| Host | Binary |
|------|--------|
| Linux amd64 | `bin/rewrite_heap_profile_paths-linux-amd64` |
| Windows amd64 (Git Bash) | `bin/rewrite_heap_profile_paths-windows-amd64.exe` |

`stats.sh` picks the right one automatically.

## Rebuild (developers with Go)

```sh
cd tools/rewrite_heap_profile_paths
go mod tidy
mkdir -p bin
GOOS=linux   GOARCH=amd64 go build -o bin/rewrite_heap_profile_paths-linux-amd64 .
GOOS=windows GOARCH=amd64 go build -o bin/rewrite_heap_profile_paths-windows-amd64.exe .
```

## Manual use

```sh
./bin/rewrite_heap_profile_paths-linux-amd64 \
  -prof /path/to/heap.prof \
  -root /path/to/collection/.pprof
```
