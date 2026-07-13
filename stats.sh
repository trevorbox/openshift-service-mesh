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

AFFECTED_POD="spring-boot-demo-5599c8d7d8-jm2g7"
AFFECTED_NAMESPACE="spring-boot-demo"
HEALTHY_POD="curl-88cc4ff69-tkjsz"
HEALTHY_NAMESPACE="sample"

INTERVAL=3600  # seconds between samples (1 hour)
SAMPLES=3    # number of samples (3 x 1 hour = 3 hours)
OUTPUT_DIR="$(pwd)/stats_collection_$(date +%Y%m%d_%H%M%S)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROF_ROOT="$OUTPUT_DIR/.pprof"
ENVOY_BIN="$PROF_ROOT/usr/local/bin/envoy"
REWRITE_TOOL="$SCRIPT_DIR/tools/rewrite_heap_profile_paths"

mkdir -p "$(dirname "$ENVOY_BIN")"
ocexec -n "$AFFECTED_NAMESPACE" "$AFFECTED_POD" -c istio-proxy -- cat /usr/local/bin/envoy > "$ENVOY_BIN"
chmod +x "$ENVOY_BIN"

# Shared libs referenced in heap profiles; mirror pod paths under .pprof for pprof -http.
copy_proxy_file() {
  local pod=$1 namespace=$2 remote=$3
  local local="$PROF_ROOT$remote"
  mkdir -p "$(dirname "$local")"
  kexec "$pod" -n "$namespace" -c istio-proxy -- base64 "$remote" 2>/dev/null | base64 -d > "$local" || rm -f "$local"
}
copy_proxy_file "$AFFECTED_POD" "$AFFECTED_NAMESPACE" /usr/lib64/libcrypto.so.3.5.1
copy_proxy_file "$AFFECTED_POD" "$AFFECTED_NAMESPACE" /usr/lib64/libssl.so.3.5.1

# Copy any other shared libs referenced in a rewritten profile (libc, libm, etc.).
sync_profile_binaries_from_pod() {
  local pod=$1 namespace=$2 prof=$3
  local root_abs=$4 remote local_path

  while read -r local_path; do
    [[ -z "$local_path" || "$local_path" != "$root_abs"* ]] && continue
    [[ -f "$local_path" ]] && continue
    remote="${local_path#$root_abs}"
    copy_proxy_file "$pod" "$namespace" "$remote"
  done < <(go tool pprof -raw "$prof" 2>/dev/null | awk '
    /^Mappings$/,/^Locations$/ {
      if ($0 ~ /^[0-9]+:/) {
        for (i = 3; i <= NF; i++) if ($i ~ /^\//) { print $i; break }
      }
    }' | sort -u)
}

# Heap profiles store absolute pod paths; rewrite them to the local .pprof mirror.
rewrite_heap_profile_paths() {
  local prof=$1
  local prof_abs root_abs
  prof_abs="$(cd "$(dirname "$prof")" && pwd)/$(basename "$prof")"
  root_abs="$(cd "$PROF_ROOT" && pwd)"
  (cd "$REWRITE_TOOL" && go run . -prof "$prof_abs" -root "$root_abs") || {
    echo "warning: failed to rewrite heap profile paths in $prof_abs" >&2
    return 1
  }
}

echo -e "# pprof commands\n" > "$OUTPUT_DIR/pprof_commands.md"
echo -e "Profiles are rewritten to use binaries under \`.pprof/\` (pod path mirror)." >> "$OUTPUT_DIR/pprof_commands.md"
echo -e "Heap dumps are tcmalloc **space** profiles (allocation sizes), not CPU stack traces." >> "$OUTPUT_DIR/pprof_commands.md"
echo -e "Use **Top** or **Flame Graph** in the web UI. Do **not** use Disassemble or Source —" >> "$OUTPUT_DIR/pprof_commands.md"
echo -e "those views treat sample addresses as code PCs and can panic \`go tool pprof\`.\n" >> "$OUTPUT_DIR/pprof_commands.md"
echo -e "CLI summary: \`go tool pprof -top ...\`   Web UI: open http://localhost:9999/ui/top after starting -http\n" >> "$OUTPUT_DIR/pprof_commands.md"
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

  rewrite_heap_profile_paths "$output_file"
  sync_profile_binaries_from_pod "$pod" "$namespace" "$output_file" "$(cd "$PROF_ROOT" && pwd)"
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
  echo "go tool pprof -top $ENVOY_BIN $OUTPUT_DIR/${FILE_TS}.affected.heap_dump.prof" >> "$OUTPUT_DIR/pprof_commands.md"
  echo "go tool pprof -http localhost:9999 -no_browser $ENVOY_BIN $OUTPUT_DIR/${FILE_TS}.affected.heap_dump.prof" >> "$OUTPUT_DIR/pprof_commands.md"

  kexec "$HEALTHY_POD" -n "$HEALTHY_NAMESPACE" -c istio-proxy -- \
    pilot-agent request GET stats > "$OUTPUT_DIR/${FILE_TS}.healthy.stats.txt" 2>/dev/null
  kexec "$HEALTHY_POD" -n "$HEALTHY_NAMESPACE" -c istio-proxy -- \
    pilot-agent request GET memory > "$OUTPUT_DIR/${FILE_TS}.healthy.memory.txt" 2>/dev/null
  kexec "$HEALTHY_POD" -n "$HEALTHY_NAMESPACE" -c istio-proxy -- \
    pilot-agent request GET server_info > "$OUTPUT_DIR/${FILE_TS}.healthy.server_info.json" 2>/dev/null
  kexec "$HEALTHY_POD" -n "$HEALTHY_NAMESPACE" -c istio-proxy -- \
    pilot-agent request GET config_dump > "$OUTPUT_DIR/${FILE_TS}.healthy.config_dump.json" 2>/dev/null
  heap_dump "$HEALTHY_POD" "$HEALTHY_NAMESPACE" "$OUTPUT_DIR/${FILE_TS}.healthy.heap_dump.prof"
  echo "go tool pprof -top $ENVOY_BIN $OUTPUT_DIR/${FILE_TS}.healthy.heap_dump.prof" >> "$OUTPUT_DIR/pprof_commands.md"
  echo "go tool pprof -http localhost:9999 -no_browser $ENVOY_BIN $OUTPUT_DIR/${FILE_TS}.healthy.heap_dump.prof" >> "$OUTPUT_DIR/pprof_commands.md"
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
