#!/bin/bash

# Git Bash converts Unix paths in command lines (e.g. /var/lib/istio/... →
# C:/Program Files/Git/var/...) before kubectl/oc exec sends them to the pod.
if [[ -n "${MSYSTEM:-}" || "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == mingw* ]]; then
  export MSYS2_ARG_CONV_EXCL='*'
  export MSYS_NO_PATHCONV=1
fi

kexec() {
  MSYS2_ARG_CONV_EXCL='*' MSYS_NO_PATHCONV=1 kubectl exec "$@"
}

ocexec() {
  MSYS2_ARG_CONV_EXCL='*' MSYS_NO_PATHCONV=1 oc exec "$@"
}

AFFECTED_POD="spring-boot-demo-667fb74646-8ghfs"
AFFECTED_NAMESPACE="spring-boot-demo"
HEALTHY_POD="curl-74959cfb89-s24qq"
HEALTHY_NAMESPACE="sample"

INTERVAL=3600  # seconds between samples (1 hour)
SAMPLES=3    # number of samples (3 x 1 hour = 3 hours)
# Relative path so archives / pprof_commands.md work on any machine (not Git Bash /c/... paths).
OUTPUT_DIR="stats_collection_$(date +%Y%m%d_%H%M%S)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROF_ROOT="$OUTPUT_DIR/.pprof"
ENVOY_FILE="$PROF_ROOT/usr/local/bin/envoy"
# Paths written into pprof_commands.md assume you `cd` into OUTPUT_DIR first.
ENVOY_BIN=".pprof/usr/local/bin/envoy"
REWRITE_TOOL="$SCRIPT_DIR/tools/rewrite_heap_profile_paths"

# Convert Git Bash / MSYS paths (/c/Users/...) to Windows paths (C:\Users\...) for native .exe tools.
native_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s\n' "$1"
  fi
}

# Copy a file from the proxy container into the local .pprof mirror (pod path layout).
#
# Do NOT use `kubectl cp`: it needs `tar` on the client and in the container.
# istio-proxy has no tar, and Windows kubectl.exe often cannot see Git Bash's tar.
#
# Single-pipe base64 of ~800MB can truncate on Git Bash (~80MB). Copy in chunks instead.
copy_proxy_file() {
  local pod=$1 namespace=$2 remote=$3
  local local_file="$PROF_ROOT$remote"
  local remote_size local_size
  local chunk_mib=16
  local total_mib i count

  mkdir -p "$(dirname "$local_file")"
  remote_size=$(kexec "$pod" -n "$namespace" -c istio-proxy -- sh -c "wc -c < '$remote'" 2>/dev/null | tr -d ' \r')
  if [[ -z "$remote_size" || ! "$remote_size" =~ ^[0-9]+$ ]]; then
    echo "warning: could not read size of $remote in pod" >&2
    return 1
  fi

  rm -f "$local_file"
  : > "$local_file"
  total_mib=$(( (remote_size + 1048575) / 1048576 ))
  i=0
  while [[ "$i" -lt "$total_mib" ]]; do
    count=$chunk_mib
    if [[ $((i + count)) -gt "$total_mib" ]]; then
      count=$((total_mib - i))
    fi
    echo "  copying $remote: $((i * 1048576)) / ${remote_size} bytes ..." >&2
    if ! kexec "$pod" -n "$namespace" -c istio-proxy -- \
        sh -c "dd if='$remote' bs=1048576 skip=$i count=$count 2>/dev/null | base64" \
        | base64 -d >> "$local_file"; then
      rm -f "$local_file"
      return 1
    fi
    i=$((i + count))
  done

  local_size=$(wc -c < "$local_file" | tr -d ' ')
  if [[ -z "$local_size" || "$local_size" -eq 0 || "$local_size" != "$remote_size" ]]; then
    echo "warning: size mismatch copying $remote (remote=${remote_size} local=${local_size:-0})" >&2
    rm -f "$local_file"
    return 1
  fi
  return 0
}

mkdir -p "$(dirname "$ENVOY_FILE")"
echo "Pod envoy (verify this is the debug ~700M+ binary):" >&2
kexec "$AFFECTED_POD" -n "$AFFECTED_NAMESPACE" -c istio-proxy -- ls -lah /usr/local/bin/envoy >&2 || true
echo "Copying envoy binary from pod (chunked base64; debug builds ~800MB may take several minutes)..." >&2
if ! copy_proxy_file "$AFFECTED_POD" "$AFFECTED_NAMESPACE" /usr/local/bin/envoy; then
  echo "error: failed to copy /usr/local/bin/envoy from $AFFECTED_NAMESPACE/$AFFECTED_POD" >&2
  exit 1
fi
chmod +x "$ENVOY_FILE"
echo "envoy: $(wc -c < "$ENVOY_FILE" | tr -d ' ') bytes -> $ENVOY_FILE" >&2
if [[ "$(wc -c < "$ENVOY_FILE" | tr -d ' ')" -lt 200000000 ]]; then
  echo "warning: local envoy is < 200MB — this looks like a stripped binary, not a debug build." >&2
  echo "warning: check kube context and that the pod runs the debug image (ls -lah above should show ~775M)." >&2
fi

# Copy shared libraries that envoy links against (ldd is reliable; profile strings is not on Git Bash).
sync_envoy_libs_from_pod() {
  local pod=$1 namespace=$2
  local remote
  echo "Discovering shared libs via ldd ..." >&2
  while read -r remote; do
    [[ -z "$remote" || "$remote" != /* ]] && continue
    [[ -f "$PROF_ROOT$remote" ]] && continue
    echo "  copying $remote ..." >&2
    copy_proxy_file "$pod" "$namespace" "$remote" || echo "  warning: skip $remote" >&2
  done < <(
    kexec "$pod" -n "$namespace" -c istio-proxy -- ldd /usr/local/bin/envoy 2>/dev/null \
      | awk '/=>/ { print $3 }' | grep -E '^/' | sort -u
  )
}
sync_envoy_libs_from_pod "$AFFECTED_POD" "$AFFECTED_NAMESPACE"
echo "Local .pprof files:" >&2
find "$PROF_ROOT" -type f -printf '  %p (%s bytes)\n' 2>/dev/null \
  || find "$PROF_ROOT" -type f | while read -r f; do echo "  $f ($(wc -c < "$f" | tr -d ' ') bytes)"; done

# Extract absolute pod paths embedded in a gzip heap profile (no go/python needed).
# Protobuf packs filename next to build-id; `strings` glues them as
#   /usr/local/bin/envoy2(5ce103c...
# where ASCII '2' is the next field's tag. Strip that before using the path.
profile_pod_paths() {
  local prof=$1
  if command -v strings >/dev/null 2>&1; then
    gzip -dc "$prof" 2>/dev/null | strings
  else
    gzip -dc "$prof" 2>/dev/null | tr -cd '[:print:]\n'
  fi | grep -E '^/(usr|lib)' \
    | sed -E 's/2\([0-9a-fA-F].*//; s/[^A-Za-z0-9._+/-].*//' \
    | grep -E '^/(usr|lib)(/[A-Za-z0-9._+-]+)+$' \
    | sort -u
}

# Also copy any extra libs referenced only in the heap profile.
sync_profile_binaries_from_pod() {
  local pod=$1 namespace=$2 prof=$3
  local remote

  while read -r remote; do
    [[ -z "$remote" ]] && continue
    case "$remote" in
      *.cc|*.h|*.hh|*.hpp) continue ;;
      *linux-vdso*) continue ;;
      */envoy|*/envoy2) continue ;;
    esac
    [[ -f "$PROF_ROOT$remote" ]] && continue
    echo "  copying $remote ..." >&2
    copy_proxy_file "$pod" "$namespace" "$remote" || echo "  warning: skip $remote" >&2
  done < <(profile_pod_paths "$prof")
}

# Point profile mappings at local .pprof/... so pprof does not open /usr/local/bin/envoy.
# Uses prebuilt binaries in tools/rewrite_heap_profile_paths/bin/ (no Go required at runtime).
rewrite_bin_for_host() {
  local dir="$REWRITE_TOOL/bin"
  case "$(uname -s 2>/dev/null)" in
    Linux*)
      echo "$dir/rewrite_heap_profile_paths-linux-amd64"
      ;;
    MINGW*|MSYS*|CYGWIN*)
      echo "$dir/rewrite_heap_profile_paths-windows-amd64.exe"
      ;;
    *)
      # Git Bash often reports MINGW; also check MSYSTEM / OSTYPE.
      if [[ -n "${MSYSTEM:-}" || "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == mingw* ]]; then
        echo "$dir/rewrite_heap_profile_paths-windows-amd64.exe"
      else
        echo ""
      fi
      ;;
  esac
}

rewrite_heap_profile_paths() {
  local prof=$1
  local prof_abs root_abs bin prof_native root_native
  bin="$(rewrite_bin_for_host)"
  prof_abs="$(cd "$(dirname "$prof")" && pwd)/$(basename "$prof")"
  root_abs="$(cd "$PROF_ROOT" && pwd)"
  # Windows .exe cannot open Git Bash paths like /c/Users/... (becomes C:\c\Users\...).
  prof_native="$(native_path "$prof_abs")"
  root_native="$(native_path "$root_abs")"

  if [[ -z "$bin" || ! -f "$bin" ]]; then
    if command -v go >/dev/null 2>&1 && [[ -d "$REWRITE_TOOL" ]]; then
      (cd "$REWRITE_TOOL" && go run . -prof "$prof_native" -root "$root_native") || {
        echo "warning: failed to rewrite paths in $prof" >&2
        return 1
      }
      return 0
    fi
    echo "warning: no rewrite binary for this OS (expected under $REWRITE_TOOL/bin); profile keeps pod paths" >&2
    return 0
  fi
  "$bin" -prof "$prof_native" -root "$root_native" || {
    echo "warning: failed to rewrite paths in $prof_abs (native=$prof_native)" >&2
    return 1
  }
}

echo -e "# pprof commands\n" > "$OUTPUT_DIR/pprof_commands.md"
echo -e "Run all commands from **inside this directory** (\`cd\` here after extract)." >> "$OUTPUT_DIR/pprof_commands.md"
echo -e "Collection is bash-only (kubectl/oc). Analysis needs Go's \`go tool pprof\`." >> "$OUTPUT_DIR/pprof_commands.md"
echo -e "Debug envoy must be ~full size (often 700M+). If \`.pprof/.../envoy\` is ~80M, the copy was truncated — re-copy.\n" >> "$OUTPUT_DIR/pprof_commands.md"
echo -e "## Use these views" >> "$OUTPUT_DIR/pprof_commands.md"
echo -e "- **Top**: http://localhost:9999/ui/top  (named frames need the full debug binary)" >> "$OUTPUT_DIR/pprof_commands.md"
echo -e "- Compare growth: \`-base <earlier>.prof\` then open Top\n" >> "$OUTPUT_DIR/pprof_commands.md"
echo -e "## Do not use Disassemble / Source / Peek for heap dumps" >> "$OUTPUT_DIR/pprof_commands.md"
echo -e "Those views open the pod path (\`/usr/local/bin/envoy\`) and are not useful for tcmalloc space profiles.\n" >> "$OUTPUT_DIR/pprof_commands.md"
echo -e ">> example compare: \`go tool pprof -http localhost:9999 -no_browser -base <old>.prof $ENVOY_BIN <current>.prof\`\n" >> "$OUTPUT_DIR/pprof_commands.md"
echo "\`\`\`sh" >> "$OUTPUT_DIR/pprof_commands.md"

# Download an Envoy heap profile from an istio-proxy container.
#
# We cannot pipe `pilot-agent request GET heap_dump` straight to a local file:
# kubectl exec stdout corrupts binary gzip (often appends a trailing newline),
# which makes `go tool pprof` fail with "unexpected EOF".
#
# Instead: write the dump inside the pod, copy it out with base64, then fix up
# any trailing newline bytes that survive the transport.
heap_dump() {
  local pod=$1
  local namespace=$2
  local output_file=$3
  local container=istio-proxy
  local dump_id=$$
  local remote_file
  local size
  local last_byte_hex

  # /tmp is often read-only in istio-proxy; prefer /var/lib/istio/data.
  remote_file=$(kexec "$pod" -n "$namespace" -c "$container" -- sh -c "
    for dir in /var/lib/istio/data /tmp; do
      test_file=\"\$dir/.write-test-$dump_id\"
      if touch \"\$test_file\" 2>/dev/null; then
        rm -f \"\$test_file\"
        echo \"\$dir/heap_dump-$dump_id.prof\"
        exit 0
      fi
    done
    echo 'no writable directory in pod (/var/lib/istio/data or /tmp)' >&2
    exit 1
  ") || return 1

  kexec "$pod" -n "$namespace" -c "$container" -- \
    sh -c "pilot-agent request GET heap_dump > '$remote_file'" || return 1

  kexec "$pod" -n "$namespace" -c "$container" -- \
    base64 "$remote_file" | base64 -d > "$output_file" || return 1

  kexec "$pod" -n "$namespace" -c "$container" -- \
    rm -f "$remote_file"

  # Strip trailing newline bytes (0x0a / 0x0d) so gzip/pprof can read the file.
  size=$(wc -c < "$output_file" | tr -d ' ')
  while [ "$size" -gt 0 ]; do
    last_byte_hex=$(tail -c 1 "$output_file" | od -An -tx1 | tr -d ' \n')
    if [ "$last_byte_hex" = "0a" ] || [ "$last_byte_hex" = "0d" ]; then
      truncate -s $((size - 1)) "$output_file"
      size=$((size - 1))
    else
      break
    fi
  done

  sync_profile_binaries_from_pod "$pod" "$namespace" "$output_file"
  rewrite_heap_profile_paths "$output_file"
}

for i in $(seq 1 $SAMPLES); do
  FILE_TS=$(date -u +"%Y%m%d_%H%M%S")
  kexec "$AFFECTED_POD" -n "$AFFECTED_NAMESPACE" -c istio-proxy -- \
    pilot-agent request GET stats > "$OUTPUT_DIR/${FILE_TS}.affected.stats.txt" 2>/dev/null
  kexec "$AFFECTED_POD" -n "$AFFECTED_NAMESPACE" -c istio-proxy -- \
    pilot-agent request GET memory > "$OUTPUT_DIR/${FILE_TS}.affected.memory.txt" 2>/dev/null
  kexec "$AFFECTED_POD" -n "$AFFECTED_NAMESPACE" -c istio-proxy -- \
    pilot-agent request GET server_info > "$OUTPUT_DIR/${FILE_TS}.affected.server_info.json" 2>/dev/null
  kexec "$AFFECTED_POD" -n "$AFFECTED_NAMESPACE" -c istio-proxy -- \
    pilot-agent request GET config_dump > "$OUTPUT_DIR/${FILE_TS}.affected.config_dump.json" 2>/dev/null
  heap_dump "$AFFECTED_POD" "$AFFECTED_NAMESPACE" "$OUTPUT_DIR/${FILE_TS}.affected.heap_dump.prof"
  echo "go tool pprof -top $ENVOY_BIN ${FILE_TS}.affected.heap_dump.prof" >> "$OUTPUT_DIR/pprof_commands.md"
  echo "go tool pprof -http localhost:9999 -no_browser $ENVOY_BIN ${FILE_TS}.affected.heap_dump.prof" >> "$OUTPUT_DIR/pprof_commands.md"

  kexec "$HEALTHY_POD" -n "$HEALTHY_NAMESPACE" -c istio-proxy -- \
    pilot-agent request GET stats > "$OUTPUT_DIR/${FILE_TS}.healthy.stats.txt" 2>/dev/null
  kexec "$HEALTHY_POD" -n "$HEALTHY_NAMESPACE" -c istio-proxy -- \
    pilot-agent request GET memory > "$OUTPUT_DIR/${FILE_TS}.healthy.memory.txt" 2>/dev/null
  kexec "$HEALTHY_POD" -n "$HEALTHY_NAMESPACE" -c istio-proxy -- \
    pilot-agent request GET server_info > "$OUTPUT_DIR/${FILE_TS}.healthy.server_info.json" 2>/dev/null
  kexec "$HEALTHY_POD" -n "$HEALTHY_NAMESPACE" -c istio-proxy -- \
    pilot-agent request GET config_dump > "$OUTPUT_DIR/${FILE_TS}.healthy.config_dump.json" 2>/dev/null
  heap_dump "$HEALTHY_POD" "$HEALTHY_NAMESPACE" "$OUTPUT_DIR/${FILE_TS}.healthy.heap_dump.prof"
  echo "go tool pprof -top $ENVOY_BIN ${FILE_TS}.healthy.heap_dump.prof" >> "$OUTPUT_DIR/pprof_commands.md"
  echo "go tool pprof -http localhost:9999 -no_browser $ENVOY_BIN ${FILE_TS}.healthy.heap_dump.prof" >> "$OUTPUT_DIR/pprof_commands.md"
  if [ "$i" -lt "$SAMPLES" ]; then
    sleep "$INTERVAL"
  fi
done


echo "go tool pprof -http localhost:9999 -no_browser -base <old>.prof $ENVOY_BIN <current>.prof" >> "$OUTPUT_DIR/pprof_commands.md"
echo "\`\`\`" >> "$OUTPUT_DIR/pprof_commands.md"

echo "Collection complete. Output directory: $OUTPUT_DIR"
echo "Compressing..."
tar czf "${OUTPUT_DIR}.tar.gz" "$OUTPUT_DIR"
echo "Archive: ${OUTPUT_DIR}.tar.gz"
