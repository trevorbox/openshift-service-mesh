#!/usr/bin/env bash
# Test response headers after traffic flows through an Istio ingress gateway with:
#   - envoyfilter-owasp-gateway-filter.yaml
#   - envoyfilter-redact-server-response-headers.yaml
#
# The golang-ex backend echoes POST JSON as response headers:
#   {"Header-Name":["value"], ...}
# curl then reads those (post-filter) values with -w '%header{Name}' (7.84+).
#
# -----------------------------------------------------------------------------
# How to add a test case
# -----------------------------------------------------------------------------
# Three maps, key order does not matter:
#
#   POLICY        headers the filters control → expected value on a default
#                 response (POST {}). Empty string = header must be absent.
#   GIVEN_*       headers the backend should send (becomes the POST body).
#   EXPECT_*      only the keys that should differ from POLICY after the
#                 filter runs. Every other POLICY key is still asserted.
#
# 1) New header the filter always sets or strips
#      Add one line to POLICY, e.g. [X-New-Header]=required-value
#      or [X-Leak]=''  so it must be gone. All existing cases inherit it.
#
# 2) New scenario (backend sends X, gateway should return Y)
#      declare -A GIVEN_FOO=(
#        [Content-Type]=text/css
#      )
#      declare -A EXPECT_FOO=(
#        [Content-Type]=text/css
#        [Cache-Control]="$CACHE_CONTROL_STATIC"
#      )
#      run_case "Cache-Control for text/css" GIVEN_FOO EXPECT_FOO
#
#    Omit GIVEN / EXPECT to POST {} and assert POLICY as-is:
#      run_case defaults
#
# 3) Cache-Control vs Content-Type (Lua branches on the type)
#      run_cache_control_case text/css "$CACHE_CONTROL_STATIC"
#      run_cache_control_case text/html "$CACHE_CONTROL_DEFAULT"
#
# Each case prints its given POST headers and expect overrides. Set VERBOSE=1
# to also dump the JSON body and every actual response header curl collected.
#
# Usage:
#   ./test-envoyfilters.sh https://app.apps.example.com
#
# Optional environment:
#   HOST            Override Host header
#   CURL_INSECURE   Default 1; set 0 to verify TLS certificates
#   CURL_OPTS       Extra curl arguments (word-split)
#   VERBOSE         Set 1 to print POST JSON and all actual header values
set -euo pipefail

usage() {
  cat <<'EOF'
Test Istio ingress gateway response-header policy (OWASP + redact filters).

Usage:
  ./test-envoyfilters.sh https://app.apps.example.com
  VERBOSE=1 ./test-envoyfilters.sh https://app.apps.example.com

How a case is built
  POLICY     default expected headers (empty value = must be absent)
  GIVEN_*    backend response headers to send (POST JSON)
  EXPECT_*   sparse overrides of POLICY after the filter runs

Add a scenario (key order does not matter):

  declare -A GIVEN_FOO=( [Content-Type]=text/css )
  declare -A EXPECT_FOO=(
    [Content-Type]=text/css
    [Cache-Control]='no-cache="Set-Cookie,Authorization"'
  )
  run_case "Cache-Control for text/css" GIVEN_FOO EXPECT_FOO

Add a header every case must check: one line in POLICY.
Shortcut for Content-Type → Cache-Control: run_cache_control_case.

Requires curl 7.84+ for -w '%header{Name}'.
EOF
}

CSP="upgrade-insecure-requests; base-uri 'self'; frame-ancestors 'none'; script-src 'self'; form-action 'self'; frame-src 'none'; font-src 'none'; style-src 'self'; manifest-src 'none'; worker-src 'none'; media-src 'none'; object-src 'none';"
HSTS='max-age=63072000;includeSubDomains;preload'
PERMISSIONS='geolocation=(), camera=(), microphone=(), interest-cohort=()'
COOKIE='id=a3fWa; Max-Age=2592000'
CACHE_CONTROL_DEFAULT='no-store, no-cache'
CACHE_CONTROL_STATIC='no-cache="Set-Cookie,Authorization"'

# -----------------------------------------------------------------------------
# POLICY — catalog of headers the EnvoyFilters control
# -----------------------------------------------------------------------------
# setHeaderIfNotEquals → a required value (wrong backend values are replaced).
# setHeaderIfUnset     → Content-Type default when the backend omits it.
# removeHeader         → empty string; the header must not appear.
#
# Every run_case asserts this whole map, then applies that case's EXPECT_*
# overrides. Add/remove a line here when the Lua filter gains or drops a header.
declare -A POLICY=(
  [X-Frame-Options]=DENY
  [X-XSS-Protection]='1; mode=block'
  [X-Content-Type-Options]=nosniff
  [Referrer-Policy]=strict-origin-when-cross-origin
  [Strict-Transport-Security]="$HSTS"
  [Content-Security-Policy]="$CSP"
  [Cross-Origin-Opener-Policy]=same-origin
  [Cross-Origin-Embedder-Policy]=require-corp
  [Cross-Origin-Resource-Policy]=same-site
  [Permissions-Policy]="$PERMISSIONS"
  [X-DNS-Prefetch-Control]=off
  [Content-Type]='text/plain; charset=utf-8'
  [Cache-Control]="$CACHE_CONTROL_DEFAULT"
  [Set-Cookie]=''
  [Access-Control-Allow-Origin]=''
  [X-Powered-By]=''
  [Server]=''
  [X-AspNet-Version]=''
  [X-AspNetMvc-Version]=''
  [Expect-CT]=''
  [Public-Key-Pins]=''
  [ETag]=''
  [x-envoy-upstream-service-time]=''
)

# -----------------------------------------------------------------------------
# Scenario maps — GIVEN is what the backend emits; EXPECT is POLICY overlays
# -----------------------------------------------------------------------------
# GIVEN_* becomes POST {"Name":["value"],...}. The gateway filter then mutates
# those headers. EXPECT_* lists only keys whose final value is not POLICY.
#
# set-if-not-set: wrong OWASP values must be replaced, Content-Type kept,
# cookies hardened, leak headers and Access-Control-Allow-Origin: * stripped.
declare -A GIVEN_WRONG=(
  [X-Frame-Options]=WRONG
  [X-XSS-Protection]=WRONG
  [X-Content-Type-Options]=WRONG
  [Referrer-Policy]=WRONG
  [Strict-Transport-Security]=WRONG
  [Content-Security-Policy]=WRONG
  [Cross-Origin-Opener-Policy]=WRONG
  [Cross-Origin-Embedder-Policy]=WRONG
  [Cross-Origin-Resource-Policy]=WRONG
  [Permissions-Policy]=WRONG
  [X-DNS-Prefetch-Control]=WRONG
  [Content-Type]=application/json
  [Cache-Control]='public, max-age=31536000'
  [Set-Cookie]="$COOKIE"
  [Access-Control-Allow-Origin]='*'
  [X-Powered-By]=express
  [Server]=nginx
  [X-AspNet-Version]=1.0
  [X-AspNetMvc-Version]=1.0
  [Expect-CT]='max-age=86400'
  [Public-Key-Pins]='pin-sha256=abc'
  [ETag]=leak-ETag
  [x-envoy-upstream-service-time]=4
)

# Final values that are not the POLICY defaults for GIVEN_WRONG.
declare -A EXPECT_WRONG=(
  [Content-Type]=application/json
  [Set-Cookie]="${COOKIE}; HTTPOnly; Secure;"
)

VERBOSE="${VERBOSE:-0}"
PASSES=0
FAILS=0
HTTP_CODE=""
declare -A ACTUAL=()
CURL_ARGS=()
URL=""

json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

# Associative map → {"Name":["value"],...} for the golang-ex POST body.
json_body() {
  local -n _hdrs=$1
  local k sep=""
  printf '{'
  for k in "${!_hdrs[@]}"; do
    printf '%s"%s":["%s"]' "$sep" "$(json_escape "$k")" "$(json_escape "${_hdrs[$k]}")"
    sep=','
  done
  printf '}'
}

clone_map() {
  local -n _from=$1 _to=$2
  local k
  _to=()
  for k in "${!_from[@]}"; do
    _to["$k"]="${_from[$k]}"
  done
}

# Sorted keys of the associative array named $1. Pass the real variable name,
# not another nameref — bash warns on circular namerefs if the names match.
sorted_keys() {
  eval 'printf "%s\n" "${!'"$1"'[@]}"' | sort
}

# Print a map as aligned "Name  value" lines (empty value shown as <absent>).
print_map_lines() {
  local label="$1"
  local map_name="$2"
  local -n _map=$map_name
  local k
  printf '  %s\n' "$label"
  if [[ ${#_map[@]} -eq 0 ]]; then
    printf '    (none)\n'
    return
  fi
  while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    printf '    %-32s %s\n' "$k" "${_map[$k]:-<absent>}"
  done < <(sorted_keys "$map_name")
}

# POST body; fetch every key in the expected map via %header{Name}.
# Fills HTTP_CODE and ACTUAL (name → value). Trailing | in -w keeps empty
# fields (stripped headers) so the split lines up with keys.
post_headers() {
  local body="$1"
  local want_name="$2"
  local k fmt="" raw header_line curl_ec=0
  local -a keys=() vals=()

  HTTP_CODE=""
  ACTUAL=()

  while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    keys+=("$k")
    fmt+="%header{${k}}|"
  done < <(sorted_keys "$want_name")

  set +e
  raw="$(curl "${CURL_ARGS[@]}" \
    -o /dev/null \
    -w '%{http_code}\n'"$fmt" \
    -X POST \
    -H 'Content-Type: application/json' \
    --data-binary "$body" \
    "$URL")"
  curl_ec=$?
  set -e

  if [[ $curl_ec -ne 0 ]]; then
    printf 'curl exited %s talking to %s\n' "$curl_ec" "$URL" >&2
    return 1
  fi

  HTTP_CODE="${raw%%$'\n'*}"
  if [[ "$raw" == *$'\n'* ]]; then
    header_line="${raw#*$'\n'}"
  else
    header_line=""
  fi

  IFS='|' read -ra vals <<< "$header_line"
  local i
  for i in "${!keys[@]}"; do
    ACTUAL["${keys[$i]}"]="${vals[$i]:-}"
  done
}

pass() {
  PASSES=$((PASSES + 1))
  printf '  PASS  %s\n' "$*"
}

fail() {
  FAILS=$((FAILS + 1))
  printf '  FAIL  %s\n' "$*"
}

# run_case NAME [GIVEN_MAP] [EXPECT_MAP]
#   NAME         shown in PASS/FAIL output
#   GIVEN_MAP    name of an associative array → POST body (omit → {})
#   EXPECT_MAP   name of an associative array → overrides cloned from POLICY
#                (omit → assert POLICY only)
#
# Always prints the given headers and expect overlays for the scenario.
# VERBOSE=1 also prints the JSON body, HTTP status, and every actual header.
run_case() {
  local name="$1"
  local given_ref="${2:-}"
  local expect_ref="${3:-}"
  local body='{}'
  local -A expected=()
  local k want got mismatch=0

  clone_map POLICY expected

  if [[ -n "$given_ref" ]]; then
    body="$(json_body "$given_ref")"
  fi
  if [[ -n "$expect_ref" ]]; then
    local -n _expect=$expect_ref
    for k in "${!_expect[@]}"; do
      expected["$k"]="${_expect[$k]}"
    done
  fi

  printf '\n==> %s\n' "$name"
  if [[ -n "$given_ref" ]]; then
    print_map_lines "given (backend response headers):" "$given_ref"
  else
    printf '  given:    POST {} (no custom backend headers)\n'
  fi
  if [[ -n "$expect_ref" ]]; then
    print_map_lines "expect (POLICY with these overrides):" "$expect_ref"
  else
    printf '  expect:   POLICY defaults\n'
  fi

  if [[ "$VERBOSE" == "1" ]]; then
    printf '  request: %s\n' "$body"
  fi

  post_headers "$body" expected || {
    fail "${name}: POST failed"
    return 0
  }

  if [[ "$VERBOSE" == "1" ]]; then
    printf '  actual (HTTP %s):\n' "$HTTP_CODE"
    while IFS= read -r k; do
      [[ -z "$k" ]] && continue
      printf '    %-32s %s\n' "$k" "${ACTUAL[$k]:-<absent>}"
    done < <(sorted_keys expected)
  fi

  if [[ ! "$HTTP_CODE" =~ ^2[0-9][0-9]$ ]]; then
    fail "${name}: HTTP ${HTTP_CODE}"
    return 0
  fi

  while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    want="${expected[$k]}"
    got="${ACTUAL[$k]:-}"
    if [[ "$got" != "$want" ]]; then
      printf '  mismatch  %s\n            expected %s\n            actual   %s\n' \
        "$k" "${want:-<absent>}" "${got:-<absent>}"
      mismatch=1
    fi
  done < <(sorted_keys expected)

  if [[ $mismatch -eq 0 ]]; then
    pass "$name"
  else
    fail "${name}: response headers != expected"
  fi
}

# Thin wrapper: backend sends Content-Type, expect that type plus Cache-Control.
# Lua uses no-cache="Set-Cookie,Authorization" for JS/CSS/font/image, else
# no-store, no-cache.
run_cache_control_case() {
  local ctype="$1"
  local cc="$2"
  local -A given_cc=([Content-Type]="$ctype")
  local -A expect_cc=(
    [Content-Type]="$ctype"
    [Cache-Control]="$cc"
  )
  run_case "Cache-Control for ${ctype}" given_cc expect_cc
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

URL="${1:-${INGRESS_URL:-}}"
if [[ -z "$URL" ]]; then
  usage >&2
  echo "error: URL is required" >&2
  exit 2
fi

command -v curl >/dev/null 2>&1 || { echo "error: curl is required" >&2; exit 2; }

CURL_INSECURE="${CURL_INSECURE:-1}"
CURL_ARGS=(-sS --http1.1 --connect-timeout 10 --max-time 30)
if [[ "$CURL_INSECURE" == "1" || "$CURL_INSECURE" == "true" ]]; then
  CURL_ARGS+=(-k)
fi
if [[ -n "${HOST:-}" ]]; then
  CURL_ARGS+=(-H "Host: ${HOST}")
fi
if [[ -n "${CURL_OPTS:-}" ]]; then
  # shellcheck disable=SC2206
  CURL_ARGS+=(${CURL_OPTS})
fi

# -----------------------------------------------------------------------------
# Cases — add new scenarios below (see the header comment for recipes)
# -----------------------------------------------------------------------------
# defaults: empty POST, filter fills OWASP headers, leak headers stay absent.
run_case defaults

# Backend sends wrong/leak values; filter replaces OWASP, keeps Content-Type,
# hardens Set-Cookie, strips * CORS and leak headers.
run_case set-if-not-set GIVEN_WRONG EXPECT_WRONG

# Cache-Control depends on Content-Type (see envoyfilter-owasp-gateway-filter).
run_cache_control_case application/ecmascript "$CACHE_CONTROL_STATIC"
run_cache_control_case application/javascript "$CACHE_CONTROL_STATIC"
run_cache_control_case text/css "$CACHE_CONTROL_STATIC"
run_cache_control_case font/woff2 "$CACHE_CONTROL_STATIC"
run_cache_control_case image/png "$CACHE_CONTROL_STATIC"
run_cache_control_case text/html "$CACHE_CONTROL_DEFAULT"
run_cache_control_case application/json "$CACHE_CONTROL_DEFAULT"

printf '\n%s\n' "----------------------------------------"
printf 'Passed: %s  Failed: %s\n' "$PASSES" "$FAILS"
if [[ "$FAILS" -ne 0 ]]; then
  exit 1
fi
exit 0
