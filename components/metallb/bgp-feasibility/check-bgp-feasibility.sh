#!/usr/bin/env bash
# Assess whether MetalLB BGP is a realistic option on the current OpenShift cluster.
set -euo pipefail

PEER_PORT="${PEER_PORT:-179}"
PROBE=0
PROBE_PEER="${PROBE_PEER:-}"
DEBUG_NODE="${DEBUG_NODE:-}"

usage() {
  cat <<EOF
Usage: $0 [--probe] [--peer <ip>] [--node <nodename>]

Read-only assessment of the logged-in OpenShift cluster. Prints a report and
suggested load-balancing options (platform LB, MetalLB L2, MetalLB BGP).

  --probe         From one node, ping and TCP-connect to the candidate ToR on
                  port ${PEER_PORT} (starts a debug pod; needs cluster-admin).
  --peer <ip>     Peer to probe (default: first unique node default gateway).
  --node <name>   Node for --probe (default: first Ready worker, else first node).

Environment: PEER_PORT (default 179), OC (default oc)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --probe) PROBE=1; shift ;;
    --peer) PROBE_PEER="${2:-}"; shift 2 ;;
    --node) DEBUG_NODE="${2:-}"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

OC="${OC:-oc}"

need_oc() {
  if ! command -v "${OC}" >/dev/null 2>&1; then
    echo "error: ${OC} not found" >&2
    exit 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "error: python3 is required" >&2
    exit 1
  fi
  if ! "${OC}" whoami >/dev/null 2>&1; then
    echo "error: not logged in to a cluster (oc whoami failed)" >&2
    exit 1
  fi
}

json_get() {
  python3 -c "import json,sys; d=json.load(sys.stdin)
${1}" 2>/dev/null || true
}

parse_ovn_gw() {
  python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    sys.exit(0)
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(0)
block = data.get("default") or (next(iter(data.values())) if data else {})
if not isinstance(block, dict):
    sys.exit(0)
nh = block.get("next-hop") or ""
if not nh:
    hops = block.get("next-hops") or []
    nh = hops[0] if hops else ""
ip = block.get("ip-address") or ""
mode = block.get("mode") or ""
print(f"{nh}\t{ip}\t{mode}")
'
}

section() {
  printf "\n== %s ==\n" "$1"
}

need_oc

WHOAMI="$("${OC}" whoami 2>/dev/null || true)"
SERVER="$("${OC}" whoami --show-server 2>/dev/null || true)"
INFRA_JSON="$("${OC}" get infrastructure cluster -o json 2>/dev/null || echo '{}')"
PLATFORM="$(printf '%s' "${INFRA_JSON}" | json_get 'print((d.get("status") or {}).get("platform") or (d.get("status") or {}).get("platformStatus",{}).get("type") or "unknown")')"
INFRA_NAME="$(printf '%s' "${INFRA_JSON}" | json_get 'print((d.get("status") or {}).get("infrastructureName") or "")')"
API_VIP="$(printf '%s' "${INFRA_JSON}" | json_get '
ps=(d.get("status") or {}).get("platformStatus") or {}
# nested apiServerInternalIP / apiServerInternalIPs vary by platform
for key in ("baremetal","vsphere","openstack","ovirt","nutanix","none"):
    block=ps.get(key) or {}
    v=block.get("apiServerInternalIP") or ""
    if v:
        print(v); break
')"
INGRESS_VIP="$(printf '%s' "${INFRA_JSON}" | json_get '
ps=(d.get("status") or {}).get("platformStatus") or {}
for key in ("baremetal","vsphere","openstack","ovirt","nutanix","none"):
    block=ps.get(key) or {}
    v=block.get("ingressIP") or ""
    if v:
        print(v); break
')"

NET_JSON="$("${OC}" get network.config.openshift.io cluster -o json 2>/dev/null || echo '{}')"
NET_TYPE="$(printf '%s' "${NET_JSON}" | json_get 'print((d.get("spec") or {}).get("networkType") or (d.get("status") or {}).get("networkType") or "unknown")')"
CLUSTER_CIDR="$(printf '%s' "${NET_JSON}" | json_get '
cidrs=[]
for n in (d.get("spec") or {}).get("clusterNetwork") or []:
    cidrs.append(n.get("cidr",""))
print(",".join(cidrs))
')"
SERVICE_CIDR="$(printf '%s' "${NET_JSON}" | json_get '
print(",".join((d.get("spec") or {}).get("serviceNetwork") or []))
')"
MACHINE_CIDR=""
if "${OC}" get cm cluster-config-v1 -n kube-system >/dev/null 2>&1; then
  INSTALL_CONFIG="$("${OC}" get cm cluster-config-v1 -n kube-system -o jsonpath='{.data.install-config}' 2>/dev/null || true)"
  MACHINE_CIDR="$(printf '%s' "${INSTALL_CONFIG}" | python3 -c '
import sys
try:
    import yaml
except ImportError:
    text=sys.stdin.read()
    cidrs=[]
    take=False
    for line in text.splitlines():
        if "machineNetwork:" in line:
            take=True
            continue
        if take and "cidr:" in line:
            cidrs.append(line.split("cidr:",1)[1].strip().strip("\""))
        elif take and line.strip() and not line.strip().startswith("-") and not line.startswith(" "):
            break
        elif take and line.strip() and not line.startswith(" ") and not line.startswith("-"):
            break
    print(",".join(cidrs))
    sys.exit(0)
data=yaml.safe_load(sys.stdin) or {}
nets=(data.get("networking") or {}).get("machineNetwork") or []
print(",".join(n.get("cidr","") for n in nets if n.get("cidr")))
' 2>/dev/null || true)"
fi

IS_CRC=0
if [[ "${SERVER}" == *crc.testing* ]] || [[ "${INFRA_NAME}" == crc* ]] || [[ "${INFRA_NAME}" == *crc* ]]; then
  IS_CRC=1
fi

CLOUD_LB_PLATFORM=0
case "${PLATFORM}" in
  AWS|Azure|GCP|IBMCloud|AlibabaCloud) CLOUD_LB_PLATFORM=1 ;;
esac

printf "OpenShift BGP / MetalLB feasibility\n"
printf "Generated: %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
section "Cluster"
printf "User:              %s\n" "${WHOAMI}"
printf "API:               %s\n" "${SERVER}"
printf "Infrastructure:    %s\n" "${INFRA_NAME:-unknown}"
printf "Platform:          %s\n" "${PLATFORM}"
printf "Network plugin:    %s\n" "${NET_TYPE}"
printf "Cluster CIDR:      %s\n" "${CLUSTER_CIDR:-unknown}"
printf "Service CIDR:      %s\n" "${SERVICE_CIDR:-unknown}"
printf "Machine CIDR:      %s\n" "${MACHINE_CIDR:-not in cluster-config-v1}"
printf "API VIP:           %s\n" "${API_VIP:-n/a}"
printf "Ingress VIP:       %s\n" "${INGRESS_VIP:-n/a}"
if [[ "${IS_CRC}" -eq 1 ]]; then
  printf "Detected CRC:      yes (OpenShift Local)\n"
fi

section "Nodes and ToR candidates"
printf "%-40s %-18s %-18s %s\n" "NODE" "INTERNAL-IP" "DEFAULT-GW" "PRIMARY-IFADDR"
UNIQUE_GWS=""
NODE_COUNT=0
READY_WORKER=""
FIRST_NODE=""

while IFS=$'\t' read -r name ready roles internal ovn_ann primary; do
  [[ -z "${name}" ]] && continue
  NODE_COUNT=$((NODE_COUNT + 1))
  [[ -z "${FIRST_NODE}" ]] && FIRST_NODE="${name}"
  if [[ "${ready}" == "True" && "${roles}" != *control-plane* && "${roles}" != *master* ]]; then
    [[ -z "${READY_WORKER}" ]] && READY_WORKER="${name}"
  elif [[ "${ready}" == "True" && -z "${READY_WORKER}" ]]; then
    READY_WORKER="${name}"
  fi
  gw=""
  ifaddr=""
  if [[ -n "${ovn_ann}" ]]; then
    parsed="$(printf '%s' "${ovn_ann}" | parse_ovn_gw)"
    gw="$(printf '%s' "${parsed}" | cut -f1)"
    ifaddr="$(printf '%s' "${parsed}" | cut -f2)"
  fi
  if [[ -z "${ifaddr}" && -n "${primary}" ]]; then
    ifaddr="$(printf '%s' "${primary}" | python3 -c 'import json,sys
try:
    print(json.loads(sys.stdin.read()).get("ipv4",""))
except Exception:
    pass
' 2>/dev/null || true)"
  fi
  printf "%-40s %-18s %-18s %s\n" "${name}" "${internal:--}" "${gw:--}" "${ifaddr:--}"
  if [[ -n "${gw}" ]]; then
    case " ${UNIQUE_GWS} " in
      *" ${gw} "*) ;;
      *) UNIQUE_GWS="${UNIQUE_GWS} ${gw}" ;;
    esac
  fi
done < <("${OC}" get nodes -o json | python3 -c '
import json,sys
data=json.load(sys.stdin)
for n in data.get("items") or []:
    md=n.get("metadata") or {}
    st=n.get("status") or {}
    name=md.get("name","")
    anns=md.get("annotations") or {}
    labels=md.get("labels") or {}
    roles=[]
    for k,v in labels.items():
        if k.startswith("node-role.kubernetes.io/"):
            roles.append(k.split("/",1)[1])
    ready="False"
    for c in st.get("conditions") or []:
        if c.get("type")=="Ready":
            ready=c.get("status","")
    internal=""
    for a in st.get("addresses") or []:
        if a.get("type")=="InternalIP":
            internal=a.get("address","")
            break
    ovn=anns.get("k8s.ovn.org/l3-gateway-config","")
    primary=anns.get("k8s.ovn.org/node-primary-ifaddr","")
    print("\t".join([name, ready, ",".join(roles), internal, ovn, primary]))
')

GW_COUNT=0
for _ in ${UNIQUE_GWS}; do
  GW_COUNT=$((GW_COUNT + 1))
done
printf "\nUnique default gateways: %s\n" "${GW_COUNT}"
if [[ "${GW_COUNT}" -gt 0 ]]; then
  printf "Candidate BGP peer IPs (node default gateway / ToR SVI):\n"
  for gw in ${UNIQUE_GWS}; do
    printf "  - %s\n" "${gw}"
  done
  printf "On a single-VLAN IPI cluster this is usually the ToR/router. Confirm with the network team.\n"
elif [[ "${NODE_COUNT}" -eq 0 ]]; then
  printf "No nodes listed (RBAC?).\n"
else
  printf "No OVN gateway annotation found. Inspect routes on a node:\n"
  printf "  oc debug node/<node> -- chroot /host ip -4 route show default\n"
fi

section "LoadBalancer services"
LB_JSON="$("${OC}" get svc -A --field-selector spec.type=LoadBalancer -o json 2>/dev/null || echo '{"items":[]}')"
LB_ASSIGNED=0
printf '%s' "${LB_JSON}" | python3 -c '
import json,sys
items=json.load(sys.stdin).get("items") or []
print("Count: %s" % len(items))
if not items:
    sys.exit(0)
print("%-28s %-36s %s" % ("NAMESPACE", "NAME", "EXTERNAL-IP"))
assigned=0
for s in items:
    md=s.get("metadata") or {}
    st=s.get("status") or {}
    ings=((st.get("loadBalancer") or {}).get("ingress")) or []
    ext=",".join(i.get("ip") or i.get("hostname") or "" for i in ings) or "<pending>"
    if ext != "<pending>":
        assigned += 1
    print("%-28s %-36s %s" % (md.get("namespace",""), md.get("name",""), ext))
print("Assigned: %s" % assigned)
' 
LB_ASSIGNED="$(printf '%s' "${LB_JSON}" | python3 -c '
import json,sys
items=json.load(sys.stdin).get("items") or []
n=0
for s in items:
    ings=(((s.get("status") or {}).get("loadBalancer") or {}).get("ingress")) or []
    if any(i.get("ip") or i.get("hostname") for i in ings):
        n+=1
print(n)
')"

section "MetalLB and FRR-K8s"
METALLB_NS=""
if "${OC}" get ns metallb-system >/dev/null 2>&1; then
  METALLB_NS="metallb-system"
fi
if [[ -n "${METALLB_NS}" ]]; then
  printf "Namespace:         %s\n" "${METALLB_NS}"
  "${OC}" get metallb,ipaddresspool,l2advertisement,bgppeer,bgpadvertisement,bfdprofile -n "${METALLB_NS}" 2>/dev/null \
    || printf "(MetalLB CRs not readable or operator not fully installed)\n"
else
  printf "metallb-system namespace: not found (MetalLB Operator likely not installed)\n"
fi

if "${OC}" get ns openshift-frr-k8s >/dev/null 2>&1; then
  printf "\nFRR-K8s namespace: openshift-frr-k8s\n"
  "${OC}" get ds,deploy -n openshift-frr-k8s 2>/dev/null | sed -n '1,20p' || true
  "${OC}" get frrconfigurations.frrk8s.metallb.io -A 2>/dev/null || true
  "${OC}" get bgpsessionstates.frrk8s.metallb.io -A -o wide 2>/dev/null || true
else
  printf "\nFRR-K8s namespace: not found (appears after MetalLB is deployed on recent OCP)\n"
fi

HAS_L2=0
HAS_BGP_PEER=0
HAS_BGP_ADV=0
if [[ -n "${METALLB_NS}" ]]; then
  [[ -n "$("${OC}" get l2advertisement -n "${METALLB_NS}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)" ]] && HAS_L2=1
  [[ -n "$("${OC}" get bgppeer -n "${METALLB_NS}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)" ]] && HAS_BGP_PEER=1
  [[ -n "$("${OC}" get bgpadvertisement -n "${METALLB_NS}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)" ]] && HAS_BGP_ADV=1
fi

PROBE_RESULT=""
if [[ "${PROBE}" -eq 1 ]]; then
  section "Probe TCP/${PEER_PORT}"
  TARGET_NODE="${DEBUG_NODE:-${READY_WORKER:-${FIRST_NODE}}}"
  TARGET_PEER="${PROBE_PEER}"
  if [[ -z "${TARGET_PEER}" ]]; then
    for gw in ${UNIQUE_GWS}; do
      TARGET_PEER="${gw}"
      break
    done
  fi
  if [[ -z "${TARGET_NODE}" || -z "${TARGET_PEER}" ]]; then
    printf "Skip probe: need a node and a peer IP (pass --peer and --node).\n"
  else
    printf "Node: %s\nPeer: %s port %s\n" "${TARGET_NODE}" "${TARGET_PEER}" "${PEER_PORT}"
    printf "(oc debug can take a minute)\n"
    set +e
    PROBE_OUT="$("${OC}" debug "node/${TARGET_NODE}" --quiet -- chroot /host bash -c \
      "ping -c 2 -W 2 ${TARGET_PEER}; echo ---; nc -vz -w 5 ${TARGET_PEER} ${PEER_PORT} 2>&1" 2>&1)"
    PROBE_RC=$?
    set -e
    printf "%s\n" "${PROBE_OUT}"
    if printf '%s' "${PROBE_OUT}" | grep -qiE 'Connected to|succeeded|open'; then
      PROBE_RESULT="tcp_open"
    elif printf '%s' "${PROBE_OUT}" | grep -qiE 'Connection refused|Ncat:.*refused'; then
      PROBE_RESULT="tcp_refused"
    elif printf '%s' "${PROBE_OUT}" | grep -qiE 'timed out|timeout|No route'; then
      PROBE_RESULT="tcp_timeout"
    else
      PROBE_RESULT="unknown_rc_${PROBE_RC}"
    fi
    printf "Probe result: %s\n" "${PROBE_RESULT}"
  fi
fi

section "Verdict and options"
printf "How to read this:\n"
printf "  L2 MetalLB  = ARP/NDP on the machine VLAN. VIPs must be in the node subnet.\n"
printf "  BGP MetalLB = eBGP/iBGP to a router. VIPs must be a *routed* CIDR outside the machine network.\n"
printf "  ToR         = top-of-rack switch/router; usually the node default gateway.\n"
printf "\n"

if [[ "${CLOUD_LB_PLATFORM}" -eq 1 ]] || { [[ "${LB_ASSIGNED}" -gt 0 ]] && [[ -z "${METALLB_NS}" ]]; }; then
  if [[ "${CLOUD_LB_PLATFORM}" -eq 1 ]]; then
    printf "Suggested primary option: platform LoadBalancer (%s).\n" "${PLATFORM}"
  else
    printf "Suggested primary option: keep the existing platform/external LoadBalancer.\n"
    printf "LoadBalancer services already have EXTERNAL-IPs and MetalLB is not installed.\n"
  fi
  printf "  Services of type LoadBalancer are implemented outside MetalLB (cloud NLB, Octavia, etc).\n"
  printf "  MetalLB BGP is usually unnecessary unless you have an extra BYO network\n"
  printf "  or a disconnected range the platform LB cannot advertise.\n"
  printf "\nOther options:\n"
  printf "  - OpenShift Routes / Ingress for HTTP(S)\n"
  printf "  - MetalLB L2 or BGP only on a secondary NIC/VLAN that the platform LB does not cover\n"
elif [[ "${IS_CRC}" -eq 1 ]]; then
  printf "Suggested primary option: MetalLB L2 on 192.168.130.0/24 (CRC libvirt).\n"
  printf "BGP is possible only if you run a BGP speaker on the *CRC host* (ASN + TCP/179),\n"
  printf "and you use an off-subnet VIP pool. This repo has that lab:\n"
  printf "  ./components/metallb/README.md\n"
  printf "  sudo ./components/metallb/host-bgp-router/run-host-bgp-router.sh start\n"
  if [[ "${PROBE_RESULT}" == "tcp_refused" ]]; then
    printf "\nProbe: gateway reachable, port %s refused — expected until host FRR + firewalld allow BGP.\n" "${PEER_PORT}"
  elif [[ "${PROBE_RESULT}" == "tcp_open" ]]; then
    printf "\nProbe: TCP/%s is open on the host — complete MetalLB BGPPeer + BGPAdvertisement and check sessions.\n" "${PEER_PORT}"
  fi
else
  printf "Suggested primary option: MetalLB (this platform has no cloud LoadBalancer).\n"
  printf "\n"
  printf "Choose advertisement mode:\n"
  printf "  MetalLB L2 when:\n"
  printf "    - Clients share the node/machine VLAN, or\n"
  printf "    - The ToR does not speak BGP *and* you will not add another BGP speaker, or\n"
  printf "    - TCP/%s to a peer is filtered and the network team will not open it.\n" "${PEER_PORT}"
  printf "    vSphere: the port group often needs forged transmits / MAC changes (or MAC learning).\n"
  printf "\n"
  printf "  MetalLB BGP when you have *a* BGP speaker nodes can reach (not necessarily the ToR):\n"
  printf "    - Typical: the ToR/edge SVI listed above already runs BGP.\n"
  printf "    - Otherwise: spine/core, firewall, NSX T0, or a Linux VM with FRR/BIRD on the VLAN\n"
  printf "      (CRC-style). Use ebgpMultiHop if that peer is not on-link.\n"
  printf "    - TCP/%s (and optionally BFD UDP 3784/3785) must be allowed node ↔ that peer,\n" "${PEER_PORT}"
  printf "    - You have a reserved VIP CIDR *outside* the machine network,\n"
  printf "    - That speaker installs the prefixes (next-hop = node IP) and advertises them upstream.\n"
  printf "    BGP is only impossible if there is no speaker you can peer with and you will not add one.\n"
  if [[ "${GW_COUNT}" -gt 1 ]]; then
    printf "\n  Multiple default gateways: likely one ToR per rack. Use one BGPPeer per gateway\n"
    printf "  with spec.nodeSelectors so each node peers only with its own ToR.\n"
  elif [[ "${GW_COUNT}" -eq 1 ]]; then
    printf "\n  Single gateway %s: typical IPI VLAN. Ask the network team if that SVI speaks BGP.\n" "${UNIQUE_GWS// /}"
  fi
  case "${PROBE_RESULT}" in
    tcp_open)
      printf "\n  Probe: TCP/%s is open. BGP is plausible; confirm ASN and prefix-list with the network team.\n" "${PEER_PORT}"
      ;;
    tcp_refused)
      printf "\n  Probe: ICMP ok, TCP/%s refused. Packets reach the gateway but nothing accepts BGP\n" "${PEER_PORT}"
      printf "  (or a firewall RSTs). BGP is not live until the router/firewall allows it.\n"
      ;;
    tcp_timeout)
      printf "\n  Probe: TCP/%s timed out. Filtered path — BGP is not an option until the firewall is opened.\n" "${PEER_PORT}"
      ;;
  esac
  printf "\nOther options (no MetalLB):\n"
  printf "  - OpenShift Routes (HAProxy Ingress) using the platform ingress VIP\n"
  printf "  - spec.externalIPs on Services (manual, not highly available)\n"
  printf "  - NodePort / hostNetwork plus an external load balancer you already own\n"
fi

if [[ "${HAS_BGP_PEER}" -eq 1 || "${HAS_BGP_ADV}" -eq 1 ]]; then
  printf "\nThis cluster already has MetalLB BGP CRs. Check sessions:\n"
  printf "  oc get bgpsessionstates.frrk8s.metallb.io -A -o wide\n"
  printf "  oc exec -n openshift-frr-k8s ds/frr-k8s -c frr -- vtysh -c 'show bgp summary'\n"
fi
if [[ "${HAS_L2}" -eq 1 ]]; then
  printf "\nMetalLB L2Advertisement is already present — L2 is in use for at least one pool.\n"
fi

printf "\nAsk the network team (copy/paste):\n"
printf "  Can the ToR/router at the node default gateway(s) above peer BGP with node IPs?\n"
printf "  Cluster ASN, peer ASN, allowed VIP CIDR (must not overlap machine network),\n"
printf "  TCP/%s (and BFD if required), and whether next-hop is the node address.\n" "${PEER_PORT}"
printf "\nDone.\n"
