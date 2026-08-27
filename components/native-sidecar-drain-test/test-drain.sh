#!/usr/bin/env bash
# Inspect native-sidecar injection and prove in-flight requests drain on pod delete.
set -euo pipefail

NS="${NS:-native-sidecar-drain}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SLEEP_SECONDS="${SLEEP_SECONDS:-8}"
VARIANTS=(native-default native-legacy-flags classic-hold)

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
fail() { log "FAIL: $*"; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

wait_ready() {
  local deploy="$1"
  log "waiting for deployment/${deploy} in ${NS}"
  oc -n "${NS}" rollout status "deploy/${deploy}" --timeout=180s >/dev/null
}

pod_for() {
  oc -n "${NS}" get pod -l "app=${1}" -o jsonpath='{.items[0].metadata.name}'
}

inspect_variant() {
  local variant="$1"
  local pod
  pod="$(pod_for "${variant}")"
  [[ -n "${pod}" ]] || fail "no pod for ${variant}"
  log "=== inspect ${variant} pod/${pod} ==="
  oc -n "${NS}" get pod "${pod}" -o json | python3 "${ROOT}/components/native-sidecar-drain-test/inspect-injection.py" "${variant}"
}

assert_inspect() {
  local variant="$1"
  local expect_native="$2"
  local expect_poststart="$3"
  local expect_prestop="$4"
  local out
  out="$(inspect_variant "${variant}")"
  printf '%s\n' "${out}"
  echo "${out}" | grep -q "RESULT native_sidecar=${expect_native}" || fail "${variant}: native_sidecar expected ${expect_native}"
  echo "${out}" | grep -q "RESULT postStart_wait=${expect_poststart}" || fail "${variant}: postStart_wait expected ${expect_poststart}"
  echo "${out}" | grep -q "RESULT preStop_drain=${expect_prestop}" || fail "${variant}: preStop_drain expected ${expect_prestop}"
  log "PASS inspect ${variant}"
}

drain_variant() {
  local variant="$1"
  local svc="${variant}.${NS}.svc.cluster.local:8080"
  local pod curl_pod
  pod="$(pod_for "${variant}")"
  curl_pod="$(pod_for curl)"
  [[ -n "${pod}" && -n "${curl_pod}" ]] || fail "missing pods"

  local workdir
  workdir="$(mktemp -d)"
  local app_log="${workdir}/app.log"
  local proxy_log="${workdir}/proxy.log"
  local curl_out="${workdir}/curl.out"

  log "=== drain ${variant} pod/${pod} in-flight sleep=${SLEEP_SECONDS}s ==="
  oc -n "${NS}" logs "${pod}" -c drain-app --follow >"${app_log}" 2>&1 &
  local app_pid=$!
  oc -n "${NS}" logs "${pod}" -c istio-proxy --follow >"${proxy_log}" 2>&1 &
  local proxy_pid=$!

  oc -n "${NS}" exec "${curl_pod}" -c curl -- \
    curl -sS -m 40 "http://${svc}/sleep?seconds=${SLEEP_SECONDS}" >"${curl_out}" 2>&1 &
  local curl_pid=$!

  # Let the request land before deleting the target pod.
  sleep 2
  local t0
  t0="$(date +%s)"
  log "deleting pod/${pod}"
  oc -n "${NS}" delete pod "${pod}" --wait=true --timeout=90s >/dev/null
  local t1
  t1="$(date +%s)"
  local elapsed=$((t1 - t0))

  local curl_rc=0
  wait "${curl_pid}" || curl_rc=$?
  wait "${app_pid}" 2>/dev/null || true
  wait "${proxy_pid}" 2>/dev/null || true

  log "pod gone after ${elapsed}s; curl_rc=${curl_rc}"
  log "curl response: $(tr '\n' ' ' <"${curl_out}")"
  log "--- drain-app lifecycle logs ---"
  grep -E 'listening |sleep |received signal|drain in progress|exiting' "${app_log}" || true
  log "--- istio-proxy drain-related logs ---"
  grep -E 'handling /drain|Agent |Aborting proxy|drainDuration|drain-time-s' "${proxy_log}" || true

  [[ "${curl_rc}" -eq 0 ]] || fail "${variant}: in-flight curl failed (rc=${curl_rc})"
  grep -q '^slept=' "${curl_out}" || fail "${variant}: curl did not get a completed /sleep response"
  grep -q 'received signal' "${app_log}" || fail "${variant}: app did not log SIGTERM"
  grep -q 'handling /drain, starting drain' "${proxy_log}" || log "WARN ${variant}: no preStop /drain log (classic sidecars drain on SIGTERM instead)"

  if [[ "${variant}" == "native-legacy-flags" ]]; then
    if grep -q 'already drained, exiting immediately' "${proxy_log}"; then
      log "PASS proxy exited immediately after app (terminationDrainDuration=45s was not waited)"
    else
      log "WARN did not see 'already drained, exiting immediately'; inspect timestamps above"
    fi
    if [[ "${elapsed}" -ge 40 ]]; then
      fail "${variant}: pod delete took ${elapsed}s; 45s terminationDrainDuration may have been honored"
    fi
    log "PASS ${variant} pod terminated in ${elapsed}s (well under 45s drain duration)"
  fi

  log "PASS drain ${variant} in-flight request completed; pod deleted in ${elapsed}s"
  rm -rf "${workdir}"

  log "waiting for replacement pod"
  wait_ready "${variant}"
}

cmd_apply() {
  log "ensuring namespace ${NS}"
  oc create namespace "${NS}" --dry-run=client -o yaml | oc apply -f -
  oc label namespace "${NS}" istio.io/rev=default --overwrite
  log "applying ${ROOT}/components/native-sidecar-drain-test"
  oc apply -k "${ROOT}/components/native-sidecar-drain-test"
  for v in "${VARIANTS[@]}" curl; do
    wait_ready "${v}"
  done
}

cmd_inspect() {
  assert_inspect native-default true false true
  assert_inspect native-legacy-flags true false true
  assert_inspect classic-hold false true false
}

cmd_drain() {
  drain_variant native-legacy-flags
  drain_variant native-default
}

cmd_all() {
  cmd_apply
  cmd_inspect
  cmd_drain
  log "ALL CHECKS PASSED"
}

usage() {
  cat <<EOF
Usage: $0 <apply|inspect|drain|all>

  apply    Create the namespace, label it for injection, apply the kustomize component
  inspect  Prove native vs classic injection and which lifecycle hooks were rendered
  drain    Send an in-flight /sleep request and delete the pod; expect HTTP 200
  all      apply + inspect + drain

Environment:
  NS              namespace (default: native-sidecar-drain)
  SLEEP_SECONDS   in-flight request length (default: 8)
EOF
}

need oc
need python3

case "${1:-}" in
  apply) cmd_apply ;;
  inspect) cmd_inspect ;;
  drain) cmd_drain ;;
  all) cmd_all ;;
  *) usage; exit 1 ;;
esac
