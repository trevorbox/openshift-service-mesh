#!/bin/bash

AFFECTED_POD="spring-boot-demo-c56c55b7-lstdm"
AFFECTED_NAMESPACE="spring-boot-demo"
HEALTHY_POD="curl-88cc4ff69-tkjsz"
HEALTHY_NAMESPACE="sample"

INTERVAL=3600  # seconds between samples (1 hour)
SAMPLES=3    # number of samples (3 x 1 hour = 3 hours)
OUTPUT_DIR="stats_collection_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$OUTPUT_DIR"
oc exec -n "$AFFECTED_NAMESPACE" "$AFFECTED_POD" -c istio-proxy -- cat /usr/local/bin/envoy > "$OUTPUT_DIR/envoy"
chmod +x "$OUTPUT_DIR/envoy"

echo -e "# pprof commands\n" > "$OUTPUT_DIR/pprof_commands.md"
echo -e ">> example compare: \`go tool pprof -http localhost:9999 -base <old>.prof "./$OUTPUT_DIR/envoy" <current>.prof\`\n" >> "$OUTPUT_DIR/pprof_commands.md"
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
  remote_file=$(kubectl exec "$pod" -n "$namespace" -c "$container" -- sh -c "
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

  kubectl exec "$pod" -n "$namespace" -c "$container" -- \
    sh -c "pilot-agent request GET heap_dump > '$remote_file'" || return 1

  kubectl exec "$pod" -n "$namespace" -c "$container" -- \
    base64 "$remote_file" | base64 -d > "$output_file" || return 1

  kubectl exec "$pod" -n "$namespace" -c "$container" -- \
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
}

for i in $(seq 1 $SAMPLES); do
  FILE_TS=$(date -u +"%Y%m%d_%H%M%S")
  kubectl exec "$AFFECTED_POD" -n "$AFFECTED_NAMESPACE" -c istio-proxy -- \
    pilot-agent request GET stats > "$OUTPUT_DIR/${FILE_TS}.affected.stats.txt" 2>/dev/null
  kubectl exec "$AFFECTED_POD" -n "$AFFECTED_NAMESPACE" -c istio-proxy -- \
    pilot-agent request GET memory > "$OUTPUT_DIR/${FILE_TS}.affected.memory.txt" 2>/dev/null
  kubectl exec "$AFFECTED_POD" -n "$AFFECTED_NAMESPACE" -c istio-proxy -- \
    pilot-agent request GET server_info > "$OUTPUT_DIR/${FILE_TS}.affected.server_info.json" 2>/dev/null
  kubectl exec "$AFFECTED_POD" -n "$AFFECTED_NAMESPACE" -c istio-proxy -- \
    pilot-agent request GET config_dump > "$OUTPUT_DIR/${FILE_TS}.affected.config_dump.json" 2>/dev/null
  heap_dump "$AFFECTED_POD" "$AFFECTED_NAMESPACE" "$OUTPUT_DIR/${FILE_TS}.affected.heap_dump.prof"
  echo "go tool pprof -top "./$OUTPUT_DIR/envoy" "./$OUTPUT_DIR/${FILE_TS}.affected.heap_dump.prof"" >> "$OUTPUT_DIR/pprof_commands.md"
  echo "go tool pprof -http localhost:9999 "./$OUTPUT_DIR/envoy" "./$OUTPUT_DIR/${FILE_TS}.affected.heap_dump.prof"" >> "$OUTPUT_DIR/pprof_commands.md"

  kubectl exec "$HEALTHY_POD" -n "$HEALTHY_NAMESPACE" -c istio-proxy -- \
    pilot-agent request GET stats > "$OUTPUT_DIR/${FILE_TS}.healthy.stats.txt" 2>/dev/null
  kubectl exec "$HEALTHY_POD" -n "$HEALTHY_NAMESPACE" -c istio-proxy -- \
    pilot-agent request GET memory > "$OUTPUT_DIR/${FILE_TS}.healthy.memory.txt" 2>/dev/null
  kubectl exec "$HEALTHY_POD" -n "$HEALTHY_NAMESPACE" -c istio-proxy -- \
    pilot-agent request GET server_info > "$OUTPUT_DIR/${FILE_TS}.healthy.server_info.json" 2>/dev/null
  kubectl exec "$HEALTHY_POD" -n "$HEALTHY_NAMESPACE" -c istio-proxy -- \
    pilot-agent request GET config_dump > "$OUTPUT_DIR/${FILE_TS}.healthy.config_dump.json" 2>/dev/null
  heap_dump "$HEALTHY_POD" "$HEALTHY_NAMESPACE" "$OUTPUT_DIR/${FILE_TS}.healthy.heap_dump.prof"
  echo "go tool pprof -top "./$OUTPUT_DIR/envoy" "./$OUTPUT_DIR/${FILE_TS}.healthy.heap_dump.prof"" >> "$OUTPUT_DIR/pprof_commands.md"
  echo "go tool pprof -http localhost:9999 "./$OUTPUT_DIR/envoy" "./$OUTPUT_DIR/${FILE_TS}.healthy.heap_dump.prof"" >> "$OUTPUT_DIR/pprof_commands.md"
  if [ "$i" -lt "$SAMPLES" ]; then
    sleep "$INTERVAL"
  fi
done


echo "go tool pprof -http localhost:9999 -base <old>.prof "./$OUTPUT_DIR/envoy" <current>.prof" >> "$OUTPUT_DIR/pprof_commands.md"
echo "\`\`\`" >> "$OUTPUT_DIR/pprof_commands.md"

echo "Collection complete. Output directory: $OUTPUT_DIR"
echo "Compressing..."
tar czf "${OUTPUT_DIR}.tar.gz" "$OUTPUT_DIR"
echo "Archive: ${OUTPUT_DIR}.tar.gz"
