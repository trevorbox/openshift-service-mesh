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

AFFECTED_POD="spring-boot-demo-858859456c-lvgjg"
AFFECTED_NAMESPACE="spring-boot-demo"
HEALTHY_POD="curl-74959cfb89-s24qq"
HEALTHY_NAMESPACE="sample"

INTERVAL=3600  # seconds between samples (1 hour)
SAMPLES=3    # number of samples (3 x 1 hour = 3 hours)
OUTPUT_DIR="$(pwd)/stats_collection_$(date +%Y%m%d_%H%M%S)"
PROF_ROOT="$OUTPUT_DIR/.pprof"
ENVOY_BIN="$PROF_ROOT/usr/local/bin/envoy"

mkdir -p "$(dirname "$ENVOY_BIN")"
ocexec -n "$AFFECTED_NAMESPACE" "$AFFECTED_POD" -c istio-proxy -- cat /usr/local/bin/envoy > "$ENVOY_BIN"
chmod +x "$ENVOY_BIN"

# Copy a file from the proxy container into the local .pprof mirror (pod path layout).
copy_proxy_file() {
  local pod=$1 namespace=$2 remote=$3
  local local_file="$PROF_ROOT$remote"
  mkdir -p "$(dirname "$local_file")"
  kexec "$pod" -n "$namespace" -c istio-proxy -- base64 "$remote" 2>/dev/null | base64 -d > "$local_file" || rm -f "$local_file"
}

# Extract absolute pod paths embedded in a gzip heap profile (no go/python needed).
profile_pod_paths() {
  local prof=$1
  # Prefer strings(1); fall back to tr for Git Bash / minimal environments.
  if command -v strings >/dev/null 2>&1; then
    gzip -dc "$prof" 2>/dev/null | strings
  else
    gzip -dc "$prof" 2>/dev/null | tr -cd '[:print:]\n'
  fi | grep -E '^/(usr|lib)' | sort -u
}

# Copy shared libs / binaries referenced by the heap profile into .pprof/.
sync_profile_binaries_from_pod() {
  local pod=$1 namespace=$2 prof=$3
  local remote

  while read -r remote; do
    [[ -z "$remote" ]] && continue
    # Skip non-files (source paths, vdso names, etc.)
    case "$remote" in
      *.cc|*.h|*.hh|*.hpp) continue ;;
      *linux-vdso*) continue ;;
    esac
    [[ -f "$PROF_ROOT$remote" ]] && continue
    copy_proxy_file "$pod" "$namespace" "$remote"
  done < <(profile_pod_paths "$prof")
}

echo -e "# pprof commands\n" > "$OUTPUT_DIR/pprof_commands.md"
echo -e "Collection is bash-only (kubectl/oc). Analysis needs Go's \`go tool pprof\`." >> "$OUTPUT_DIR/pprof_commands.md"
echo -e "Profiles keep pod paths; use \`-symbolize=none\` so pprof does not look up /usr/... locally." >> "$OUTPUT_DIR/pprof_commands.md"
echo -e "Binaries under \`.pprof/\` are a convenience mirror for compare / optional symbolization." >> "$OUTPUT_DIR/pprof_commands.md"
echo -e "Heap dumps are tcmalloc **space** profiles. Use **Top** or **Flame Graph** — not Disassemble/Source/Peek.\n" >> "$OUTPUT_DIR/pprof_commands.md"
echo -e ">> example compare: \`go tool pprof -symbolize=none -http localhost:9999 -no_browser -base <old>.prof $ENVOY_BIN <current>.prof\`\n" >> "$OUTPUT_DIR/pprof_commands.md"
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
  echo "go tool pprof -symbolize=none -top $ENVOY_BIN $OUTPUT_DIR/${FILE_TS}.affected.heap_dump.prof" >> "$OUTPUT_DIR/pprof_commands.md"
  echo "go tool pprof -symbolize=none -http localhost:9999 -no_browser $ENVOY_BIN $OUTPUT_DIR/${FILE_TS}.affected.heap_dump.prof" >> "$OUTPUT_DIR/pprof_commands.md"

  kexec "$HEALTHY_POD" -n "$HEALTHY_NAMESPACE" -c istio-proxy -- \
    pilot-agent request GET stats > "$OUTPUT_DIR/${FILE_TS}.healthy.stats.txt" 2>/dev/null
  kexec "$HEALTHY_POD" -n "$HEALTHY_NAMESPACE" -c istio-proxy -- \
    pilot-agent request GET memory > "$OUTPUT_DIR/${FILE_TS}.healthy.memory.txt" 2>/dev/null
  kexec "$HEALTHY_POD" -n "$HEALTHY_NAMESPACE" -c istio-proxy -- \
    pilot-agent request GET server_info > "$OUTPUT_DIR/${FILE_TS}.healthy.server_info.json" 2>/dev/null
  kexec "$HEALTHY_POD" -n "$HEALTHY_NAMESPACE" -c istio-proxy -- \
    pilot-agent request GET config_dump > "$OUTPUT_DIR/${FILE_TS}.healthy.config_dump.json" 2>/dev/null
  heap_dump "$HEALTHY_POD" "$HEALTHY_NAMESPACE" "$OUTPUT_DIR/${FILE_TS}.healthy.heap_dump.prof"
  echo "go tool pprof -symbolize=none -top $ENVOY_BIN $OUTPUT_DIR/${FILE_TS}.healthy.heap_dump.prof" >> "$OUTPUT_DIR/pprof_commands.md"
  echo "go tool pprof -symbolize=none -http localhost:9999 -no_browser $ENVOY_BIN $OUTPUT_DIR/${FILE_TS}.healthy.heap_dump.prof" >> "$OUTPUT_DIR/pprof_commands.md"
  if [ "$i" -lt "$SAMPLES" ]; then
    sleep "$INTERVAL"
  fi
done


echo "go tool pprof -symbolize=none -http localhost:9999 -no_browser -base <old>.prof $ENVOY_BIN <current>.prof" >> "$OUTPUT_DIR/pprof_commands.md"
echo "\`\`\`" >> "$OUTPUT_DIR/pprof_commands.md"

echo "Collection complete. Output directory: $OUTPUT_DIR"
echo "Compressing..."
tar czf "${OUTPUT_DIR}.tar.gz" "$OUTPUT_DIR"
echo "Archive: ${OUTPUT_DIR}.tar.gz"
