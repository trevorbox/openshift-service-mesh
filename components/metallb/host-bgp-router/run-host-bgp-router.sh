#!/usr/bin/env bash
# Run an FRR BGP speaker on the CRC host so MetalLB can advertise VIPs over BGP.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_NAME="${CONTAINER_NAME:-crc-metallb-bgp-peer}"
FRR_IMAGE="${FRR_IMAGE:-quay.io/frrouting/frr:10.3.1}"
PEER_PORT="${PEER_PORT:-179}"
CRC_HOST_IP="${CRC_HOST_IP:-192.168.130.1}"
CRC_VM_IP="${CRC_VM_IP:-$(crc ip 2>/dev/null || echo 192.168.130.11)}"
FIREWALL_ZONE="${FIREWALL_ZONE:-libvirt}"

usage() {
  cat <<EOF
Usage: sudo $0 [start|stop|status|logs]

Starts a privileged host-network FRR container that peers with MetalLB on CRC.

Environment:
  CONTAINER_NAME   podman name (default: ${CONTAINER_NAME})
  FRR_IMAGE        FRR image (default: ${FRR_IMAGE})
  PEER_PORT        BGP listen port (default: ${PEER_PORT})
  CRC_HOST_IP      host crc-bridge IP (default: ${CRC_HOST_IP})
  CRC_VM_IP        CRC VM br-ex IP (default: detected via 'crc ip')
  FIREWALL_ZONE    firewalld zone for the crc interface (default: ${FIREWALL_ZONE})
EOF
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This action needs root (firewalld, BGP port ${PEER_PORT}, kernel routes)." >&2
    echo "Re-run as: sudo $0 ${1:-start}" >&2
    exit 1
  fi
}

open_firewall() {
  if ! command -v firewall-cmd >/dev/null 2>&1; then
    echo "firewall-cmd not found; skipping firewalld configuration."
    return
  fi
  if ! firewall-cmd --state >/dev/null 2>&1; then
    echo "firewalld is not running; skipping firewalld configuration."
    return
  fi
  echo "Allowing TCP/${PEER_PORT} (BGP) in firewalld zone ${FIREWALL_ZONE}"
  firewall-cmd --zone="${FIREWALL_ZONE}" --add-port="${PEER_PORT}/tcp"
  firewall-cmd --zone="${FIREWALL_ZONE}" --add-port="${PEER_PORT}/tcp" --permanent
}

start() {
  need_root start
  if [[ ! -f "${SCRIPT_DIR}/frr.conf" || ! -f "${SCRIPT_DIR}/daemons" ]]; then
    echo "Missing ${SCRIPT_DIR}/frr.conf or daemons" >&2
    exit 1
  fi
  if [[ "${CRC_VM_IP}" != "192.168.130.11" ]]; then
    echo "WARNING: crc ip is ${CRC_VM_IP}, but frr.conf and BGPPeer sourceAddress use 192.168.130.11." >&2
    echo "Update both before expecting the session to establish." >&2
  fi
  open_firewall
  echo "Starting ${CONTAINER_NAME} (${FRR_IMAGE}), peering with ${CRC_VM_IP}"
  podman rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  podman run -d \
    --name "${CONTAINER_NAME}" \
    --replace \
    --network host \
    --privileged \
    --restart unless-stopped \
    -v "${SCRIPT_DIR}/frr.conf:/etc/frr/frr.conf:Z" \
    -v "${SCRIPT_DIR}/daemons:/etc/frr/daemons:Z" \
    "${FRR_IMAGE}"
  echo
  echo "Wait a few seconds, then:"
  echo "  sudo podman exec ${CONTAINER_NAME} vtysh -c 'show bgp summary'"
  echo "  ip route show | grep 192.168.200"
}

stop() {
  need_root stop
  podman rm -f "${CONTAINER_NAME}" >/dev/null
  echo "Stopped ${CONTAINER_NAME}."
  echo "Firewall port ${PEER_PORT}/tcp is still open in zone ${FIREWALL_ZONE}."
  echo "Remove it with:"
  echo "  sudo firewall-cmd --zone=${FIREWALL_ZONE} --remove-port=${PEER_PORT}/tcp"
  echo "  sudo firewall-cmd --zone=${FIREWALL_ZONE} --remove-port=${PEER_PORT}/tcp --permanent"
}

status() {
  podman ps -a --filter "name=${CONTAINER_NAME}"
  if podman inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    podman exec "${CONTAINER_NAME}" vtysh -c "show bgp summary" || true
    podman exec "${CONTAINER_NAME}" vtysh -c "show ip bgp" || true
  fi
  echo
  echo "Host routes for the BGP VIP range:"
  ip route show | grep 192.168.200 || echo "(none)"
}

logs() {
  podman logs --tail 100 "${CONTAINER_NAME}"
}

cmd="${1:-start}"
case "${cmd}" in
  start|stop|status|logs) "${cmd}" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 1 ;;
esac
