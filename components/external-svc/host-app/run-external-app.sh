#!/usr/bin/env bash
# Run myservice on its own address on the CRC libvirt bridge.
#
# CRC pods cannot use the bridge gateway (192.168.130.1) as an application
# address: that IP is the host itself, and the libvirt firewall only allows
# ssh, dns, and dhcp. This script adds 192.168.130.50/32 on the crc bridge
# and serves HTTP there. components/external-svc/endpointslice.yaml points
# Service/myservice at that address.
#
# The address is not kept across a host reboot. Run start again after reboot.
#
# Usage: sudo ./run-external-app.sh [start|stop|status|logs]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SLICE_FILE="${SCRIPT_DIR}/../endpointslice.yaml"
CONTAINER_NAME="${CONTAINER_NAME:-crc-external-myservice}"
IMAGE="${IMAGE:-quay.io/nginx/nginx-unprivileged:1.31-alpine}"
APP_IP="${APP_IP:-192.168.130.50}"
APP_PORT="${APP_PORT:-8080}"
CRC_HOST_IP="${CRC_HOST_IP:-192.168.130.1}"
CRC_VM_IP="${CRC_VM_IP:-$(crc ip 2>/dev/null || echo 192.168.130.11)}"
CONF_FILE="${CONF_FILE:-/var/tmp/${CONTAINER_NAME}.nginx.conf}"
BRIDGE=""
ZONE=""

usage() {
  cat <<EOF
Usage: sudo $0 [start|stop|status|logs]

Serves http://${APP_IP}:${APP_PORT}/ with the body "external-myservice ${APP_IP}".
The CRC EndpointSlice must list this address. Mesh clients call
http://myservice.myservice.svc.cluster.local/ (Service port 80).

Environment:
  CONTAINER_NAME   podman name (default: ${CONTAINER_NAME})
  IMAGE            nginx image (default: ${IMAGE})
  APP_IP           unique address on the CRC bridge (default: ${APP_IP})
  APP_PORT         port nginx binds (default: ${APP_PORT})
  CRC_HOST_IP      bridge address used to find the CRC interface (default: ${CRC_HOST_IP})
  CRC_VM_IP        CRC VM address that must not be reused (default: crc ip, else 192.168.130.11)
  CONF_FILE        generated nginx config (default: ${CONF_FILE})
EOF
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This action needs root (address on the crc bridge, firewalld, host network)." >&2
    echo "Re-run as: sudo $0 ${1:-start}" >&2
    exit 1
  fi
}

detect_bridge() {
  BRIDGE="$(ip -4 -o addr show | awk -v ip="${CRC_HOST_IP}/" '$4 ~ "^" ip { print $2; exit }')"
  if [[ -z "${BRIDGE}" ]]; then
    echo "No interface has ${CRC_HOST_IP}. Start CRC first." >&2
    exit 1
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    ZONE="$(firewall-cmd --get-zone-of-interface="${BRIDGE}" 2>/dev/null || true)"
  fi
  ZONE="${ZONE:-libvirt}"
}

reject_reserved_ip() {
  if [[ "${APP_IP}" == "${CRC_HOST_IP}" || "${APP_IP}" == "${CRC_VM_IP}" ]]; then
    echo "APP_IP ${APP_IP} is the bridge gateway or the CRC VM. Pick a different address." >&2
    exit 1
  fi
  local octet
  octet="${APP_IP##*.}"
  if [[ "${APP_IP%.*}" == "192.168.130" && "${octet}" -ge 200 && "${octet}" -le 249 ]]; then
    echo "WARNING: ${APP_IP} is inside the MetalLB L2 pool 192.168.130.200-249." >&2
  fi
  if [[ ! -f "${SLICE_FILE}" ]] || ! grep -q "${APP_IP}" "${SLICE_FILE}"; then
    echo "WARNING: ${APP_IP} is not listed in ${SLICE_FILE}." >&2
    echo "Mesh clients will not reach this process until the EndpointSlice matches." >&2
  fi
}

address_present() {
  ip -4 -o addr show dev "${BRIDGE}" | awk '{ print $4 }' | grep -qx "${APP_IP}/32"
}

ensure_address() {
  if address_present; then
    echo "Address ${APP_IP}/32 is already on ${BRIDGE}"
    return
  fi
  if command -v arping >/dev/null 2>&1; then
    if arping -c 2 -w 3 -I "${BRIDGE}" "${APP_IP}" >/dev/null 2>&1; then
      echo "ERROR: ${APP_IP} already answers ARP on ${BRIDGE}." >&2
      exit 1
    fi
  fi
  echo "Adding ${APP_IP}/32 on ${BRIDGE}"
  ip addr add "${APP_IP}/32" dev "${BRIDGE}"
}

rich_rule() {
  echo "rule family=ipv4 destination address=${APP_IP} port port=${APP_PORT} protocol=tcp accept"
}

add_rich_rule() {
  local rule="$1"
  shift
  if firewall-cmd --zone="${ZONE}" "$@" --query-rich-rule="${rule}" >/dev/null; then
    return
  fi
  firewall-cmd --zone="${ZONE}" "$@" --add-rich-rule="${rule}" >/dev/null
}

open_firewall() {
  if ! command -v firewall-cmd >/dev/null 2>&1 || ! firewall-cmd --state >/dev/null 2>&1; then
    echo "firewalld is not running; not opening ${APP_PORT}/tcp."
    return
  fi
  local rule
  rule="$(rich_rule)"
  echo "Allowing TCP/${APP_PORT} to ${APP_IP} in firewalld zone ${ZONE}"
  add_rich_rule "${rule}"
  add_rich_rule "${rule}" --permanent
}

close_firewall() {
  if ! command -v firewall-cmd >/dev/null 2>&1 || ! firewall-cmd --state >/dev/null 2>&1; then
    return
  fi
  local rule
  rule="$(rich_rule)"
  firewall-cmd --zone="${ZONE}" --remove-rich-rule="${rule}" >/dev/null 2>&1 || true
  firewall-cmd --zone="${ZONE}" --remove-rich-rule="${rule}" --permanent >/dev/null 2>&1 || true
}

write_config() {
  cat > "${CONF_FILE}" <<EOF
worker_processes 1;
error_log /dev/stderr notice;
pid /tmp/nginx.pid;
events {
    worker_connections 64;
}
http {
    client_body_temp_path /tmp/client_temp;
    proxy_temp_path /tmp/proxy_temp;
    fastcgi_temp_path /tmp/fastcgi_temp;
    uwsgi_temp_path /tmp/uwsgi_temp;
    scgi_temp_path /tmp/scgi_temp;
    access_log off;
    server {
        listen ${APP_IP}:${APP_PORT};
        location / {
            default_type text/plain;
            return 200 'external-myservice ${APP_IP}\n';
        }
    }
}
EOF
  # The image runs as uid 101 and must be able to read this file.
  chmod 644 "${CONF_FILE}"
}

start() {
  need_root start
  detect_bridge
  reject_reserved_ip
  ensure_address
  open_firewall
  write_config
  echo "Starting ${CONTAINER_NAME} (${IMAGE}) on ${APP_IP}:${APP_PORT}"
  podman rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  podman run -d \
    --name "${CONTAINER_NAME}" \
    --replace \
    --network host \
    --pull missing \
    --entrypoint nginx \
    -v "${CONF_FILE}:/etc/nginx/nginx.conf:ro,Z" \
    "${IMAGE}" \
    -g 'daemon off;' >/dev/null

  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fsS --max-time 1 "http://${APP_IP}:${APP_PORT}/"; then
      echo
      echo "From a meshed pod:"
      echo "  curl -sS http://myservice.myservice.svc.cluster.local/"
      return
    fi
    sleep 0.5
  done
  echo "nginx did not answer on ${APP_IP}:${APP_PORT}" >&2
  podman logs "${CONTAINER_NAME}" >&2 || true
  exit 1
}

stop() {
  need_root stop
  detect_bridge
  podman rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  if address_present; then
    ip addr del "${APP_IP}/32" dev "${BRIDGE}"
    echo "Removed ${APP_IP}/32 from ${BRIDGE}"
  fi
  close_firewall
  rm -f "${CONF_FILE}"
  echo "Stopped ${CONTAINER_NAME}."
}

status() {
  need_root status
  detect_bridge
  echo "Bridge ${BRIDGE} zone ${ZONE}"
  if address_present; then
    echo "Address ${APP_IP}/32 is on ${BRIDGE}"
  else
    echo "Address ${APP_IP}/32 is not configured"
  fi
  podman ps -a --filter "name=^${CONTAINER_NAME}$"
  curl -fsS --max-time 2 "http://${APP_IP}:${APP_PORT}/" || echo "(no HTTP response)"
}

logs() {
  need_root logs
  podman logs --tail 100 "${CONTAINER_NAME}"
}

cmd="${1:-start}"
case "${cmd}" in
  start|stop|status|logs) "${cmd}" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 1 ;;
esac
