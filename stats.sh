#!/bin/bash

AFFECTED_POD="spring-boot-demo-5f445f5978-v4nw4"
AFFECTED_NAMESPACE="spring-boot-demo"
HEALTHY_POD="curl-88cc4ff69-whw4c"
HEALTHY_NAMESPACE="sample"

INTERVAL=1200  # seconds between samples (20 minutes)
SAMPLES=6    # number of samples (6 x 20min = 2 hours)
OUTPUT_DIR="stats_collection_$(date +%Y%m%d_%H%M%S)"

mkdir -p "$OUTPUT_DIR"
for i in $(seq 1 $SAMPLES); do
  FILE_TS=$(date -u +"%Y%m%d_%H%M%S")
  kubectl exec "$AFFECTED_POD" -n "$AFFECTED_NAMESPACE" -c istio-proxy -- \
    pilot-agent request GET stats > "$OUTPUT_DIR/${FILE_TS}.affected.stats.txt" 2>/dev/null
  kubectl exec "$AFFECTED_POD" -n "$AFFECTED_NAMESPACE" -c istio-proxy -- \
    pilot-agent request GET  memory > "$OUTPUT_DIR/${FILE_TS}.affected.memory.txt" 2>/dev/null
  kubectl exec "$HEALTHY_POD" -n "$HEALTHY_NAMESPACE" -c istio-proxy -- \
    pilot-agent request GET stats > "$OUTPUT_DIR/${FILE_TS}.healthy.stats.txt" 2>/dev/null
  kubectl exec "$HEALTHY_POD" -n "$HEALTHY_NAMESPACE" -c istio-proxy -- \
    pilot-agent request GET memory > "$OUTPUT_DIR/${FILE_TS}.healthy.memory.txt" 2>/dev/null
  if [ "$i" -lt "$SAMPLES" ]; then
    sleep "$INTERVAL"
  fi
done

echo "Collection complete. Output directory: $OUTPUT_DIR"
echo "Compressing..."
tar czf "${OUTPUT_DIR}.tar.gz" "$OUTPUT_DIR"
echo "Archive: ${OUTPUT_DIR}.tar.gz"
