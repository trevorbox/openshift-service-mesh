#!/usr/bin/env bash
# Assess whether MetalLB BGP is in use or readily available on the logged-in OpenShift cluster.
set -euo pipefail

PEER_PORT="${PEER_PORT:-179}"
PROBE=0
PROBE_PEER="${PROBE_PEER:-}"
DEBUG_NODE="${DEBUG_NODE:-}"

usage() {
  cat <<EOF
Usage: $0 [--probe] [--peer <ip>] [--node <nodename>]

Read-only. Prints inventory, then a check list (pass/fail/skip) of what this
run actually tested, then a cluster-specific BGP verdict.

Without --probe, TCP/${PEER_PORT} to the ToR is NOT tested; BGP availability
is then UNKNOWN even if MetalLB/FRR-K8s is installed.

  --probe         From one node: ping + nc to the candidate ToR on port ${PEER_PORT}
                  (oc debug pod; needs cluster-admin). This is the only check that
                  can confirm the gateway accepts BGP.
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
CHECK_FILE="$(mktemp)"
trap 'rm -f "${CHECK_FILE}"' EXIT

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

# status|title|how|result
add_check() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "${CHECK_FILE}"
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
print(f"{nh}\t{ip}")
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
for key in ("baremetal","vsphere","openstack","ovirt","nutanix","none"):
    block=ps.get(key) or {}
    v=block.get("apiServerInternalIP") or ""
    if not v:
        ips=block.get("apiServerInternalIPs") or []
        v=ips[0] if ips else ""
    if v:
        print(v); break
')"
INGRESS_VIP="$(printf '%s' "${INFRA_JSON}" | json_get '
ps=(d.get("status") or {}).get("platformStatus") or {}
for key in ("baremetal","vsphere","openstack","ovirt","nutanix","none"):
    block=ps.get(key) or {}
    v=block.get("ingressIP") or block.get("ingressIPs") or ""
    if isinstance(v, list):
        v=v[0] if v else ""
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
        elif take and line.strip() and not line.startswith(" ") and not line.strip().startswith("-"):
            break
    print(",".join(cidrs))
    sys.exit(0)
data=yaml.safe_load(sys.stdin) or {}
nets=(data.get("networking") or {}).get("machineNetwork") or []
print(",".join(n.get("cidr","") for n in nets if n.get("cidr")))
' 2>/dev/null || true)"
fi

IS_CRC=0
if [[ "${SERVER}" == *crc.testing* ]] || [[ "${INFRA_NAME}" == crc* ]]; then
  IS_CRC=1
fi

CLOUD_LB_PLATFORM=0
case "${PLATFORM}" in
  AWS|Azure|GCP|IBMCloud|AlibabaCloud) CLOUD_LB_PLATFORM=1 ;;
esac

printf "OpenShift BGP / MetalLB feasibility\n"
printf "Generated: %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf "Note: API reads only. TCP/%s is tested only with --probe.\n" "${PEER_PORT}"

section "Cluster"
printf "User:              %s\n" "${WHOAMI}"
printf "API:               %s\n" "${SERVER}"
printf "Infrastructure:    %s\n" "${INFRA_NAME:-unknown}"
printf "Platform:          %s\n" "${PLATFORM}"
printf "Network plugin:    %s\n" "${NET_TYPE}"
printf "Cluster CIDR:      %s\n" "${CLUSTER_CIDR:-unknown}"
printf "Service CIDR:      %s\n" "${SERVICE_CIDR:-unknown}"
printf "Machine CIDR:      %s  (install-config, may be stale)\n" "${MACHINE_CIDR:-not in cluster-config-v1}"
printf "API VIP:           %s\n" "${API_VIP:-n/a}"
printf "Ingress VIP:       %s\n" "${INGRESS_VIP:-n/a}"
if [[ "${IS_CRC}" -eq 1 ]]; then
  printf "Detected CRC:      yes (OpenShift Local)\n"
fi

add_check "INFO" "Read infrastructure/network CRs" \
  "oc get infrastructure cluster; oc get network.config cluster; oc get cm cluster-config-v1" \
  "platform=${PLATFORM} network=${NET_TYPE} machineNetwork=${MACHINE_CIDR:-unknown}"

section "Nodes and ToR candidates"
printf "%-42s %-16s %-16s %s\n" "NODE" "INTERNAL-IP" "DEFAULT-GW" "PRIMARY-IFADDR"
UNIQUE_GWS=""
NODE_COUNT=0
READY_WORKER=""
FIRST_NODE=""
NODE_IFADDRS=""

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
  printf "%-42s %-16s %-16s %s\n" "${name}" "${internal:--}" "${gw:--}" "${ifaddr:--}"
  if [[ -n "${gw}" ]]; then
    case " ${UNIQUE_GWS} " in
      *" ${gw} "*) ;;
      *) UNIQUE_GWS="${UNIQUE_GWS} ${gw}" ;;
    esac
  fi
  if [[ -n "${ifaddr}" ]]; then
    NODE_IFADDRS="${NODE_IFADDRS} ${ifaddr}"
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

NODE_PREFIXES="$(NODE_IFADDRS="${NODE_IFADDRS}" python3 -c '
import ipaddress, os
seen=[]
for tok in os.environ.get("NODE_IFADDRS","").split():
    try:
        net=str(ipaddress.ip_interface(tok).network)
    except ValueError:
        continue
    if net not in seen:
        seen.append(net)
print(",".join(seen))
')"

printf "\nNodes: %s\n" "${NODE_COUNT}"
printf "Observed node prefixes (from OVN primary-ifaddr, not install-config): %s\n" "${NODE_PREFIXES:-none}"
printf "Unique default gateways: %s\n" "${GW_COUNT}"
if [[ "${GW_COUNT}" -gt 0 ]]; then
  printf "Candidate BGP peer IPs (OVN l3-gateway-config next-hop = node default gateway):\n"
  for gw in ${UNIQUE_GWS}; do
    printf "  - %s\n" "${gw}"
  done
  add_check "PASS" "Discovered ToR/gateway candidate(s)" \
    "oc get nodes -o json -> annotation k8s.ovn.org/l3-gateway-config next-hop" \
    "${GW_COUNT} unique gateway(s):${UNIQUE_GWS}  (typical ToR SVI on vSphere IPI; not proof it speaks BGP)"
else
  add_check "FAIL" "Discovered ToR/gateway candidate(s)" \
    "oc get nodes -o json -> k8s.ovn.org/l3-gateway-config" \
    "No next-hop found. Run: oc debug node/<node> -- chroot /host ip -4 route show default"
fi

if [[ -n "${NODE_PREFIXES}" && -n "${MACHINE_CIDR}" ]]; then
  PREFIX_VS_MACHINE="$(MACHINE_CIDR="${MACHINE_CIDR}" NODE_PREFIXES="${NODE_PREFIXES}" python3 -c '
import ipaddress, os
machines=[]
for tok in os.environ.get("MACHINE_CIDR","").split(","):
    tok=tok.strip()
    if tok:
        machines.append(ipaddress.ip_network(tok, strict=False))
nodes=[]
for tok in os.environ.get("NODE_PREFIXES","").split(","):
    tok=tok.strip()
    if tok:
        nodes.append(ipaddress.ip_network(tok, strict=False))
covered=all(any(n.subnet_of(m) or n==m for m in machines) for n in nodes)
print("yes" if covered else "no")
' 2>/dev/null || echo unknown)"
  if [[ "${PREFIX_VS_MACHINE}" == "no" ]]; then
    add_check "INFO" "install-config machineNetwork vs live node prefixes" \
      "compare cluster-config-v1 networking.machineNetwork to node primary-ifaddr" \
      "machineNetwork=${MACHINE_CIDR} does not contain observed ${NODE_PREFIXES}. Use the observed prefix for on-link VIP checks."
  else
    add_check "PASS" "install-config machineNetwork vs live node prefixes" \
      "compare cluster-config-v1 networking.machineNetwork to node primary-ifaddr" \
      "observed ${NODE_PREFIXES} is inside machineNetwork=${MACHINE_CIDR}"
  fi
fi

section "LoadBalancer services"
LB_JSON="$("${OC}" get svc -A --field-selector spec.type=LoadBalancer -o json 2>/dev/null || echo '{"items":[]}')"
LB_IPS="$(printf '%s' "${LB_JSON}" | python3 -c '
import json,sys
items=json.load(sys.stdin).get("items") or []
ips=[]
print("Count: %s" % len(items))
if items:
    print("%-28s %-36s %s" % ("NAMESPACE", "NAME", "EXTERNAL-IP"))
for s in items:
    md=s.get("metadata") or {}
    ings=(((s.get("status") or {}).get("loadBalancer") or {}).get("ingress")) or []
    ext=",".join(i.get("ip") or i.get("hostname") or "" for i in ings) or "<pending>"
    print("%-28s %-36s %s" % (md.get("namespace",""), md.get("name",""), ext))
    for i in ings:
        if i.get("ip"):
            ips.append(i["ip"])
print("IPS=%s" % ",".join(ips))
print("ASSIGNED=%s" % len(ips))
')"
LB_ASSIGNED="$(printf '%s\n' "${LB_IPS}" | sed -n 's/^ASSIGNED=//p' | tail -1)"
LB_IP_LIST="$(printf '%s\n' "${LB_IPS}" | sed -n 's/^IPS=//p' | tail -1)"
LB_ASSIGNED="${LB_ASSIGNED:-0}"
printf '%s\n' "${LB_IPS}" | grep -v '^IPS=' | grep -v '^ASSIGNED='

ONLINK_REPORT="$(NODE_PREFIXES="${NODE_PREFIXES}" LB_IPS="${LB_IP_LIST}" API_VIP="${API_VIP}" INGRESS_VIP="${INGRESS_VIP}" python3 -c '
import ipaddress, os, sys
def nets():
    out=[]
    for tok in os.environ.get("NODE_PREFIXES","").split(","):
        tok=tok.strip()
        if tok:
            out.append(ipaddress.ip_network(tok, strict=False))
    return out
def classify(ip):
    if not ip:
        return "n/a"
    try:
        addr=ipaddress.ip_address(ip.split("/")[0])
    except ValueError:
        return "not-an-ip"
    for n in nets():
        if addr in n:
            return "on-link (%s)" % n
    return "off-link (routed VIP if advertised via BGP)"
ns=nets()
print("node_prefixes=%s" % (",".join(str(n) for n in ns) or "none"))
onlink=[]
offlink=[]
for ip in [p for p in os.environ.get("LB_IPS","").split(",") if p]:
    c=classify(ip)
    print("lb %s -> %s" % (ip, c))
    if c.startswith("on-link"):
        onlink.append(ip)
    elif c.startswith("off-link"):
        offlink.append(ip)
for label, ip in (("apiVIP", os.environ.get("API_VIP","")), ("ingressVIP", os.environ.get("INGRESS_VIP",""))):
    if ip:
        print("%s %s -> %s" % (label, ip, classify(ip)))
print("ONLINK_IPS=%s" % ",".join(onlink))
print("OFFLINK_IPS=%s" % ",".join(offlink))
' 2>/dev/null || true)"
ONLINK_IPS="$(printf '%s\n' "${ONLINK_REPORT}" | sed -n 's/^ONLINK_IPS=//p' | tail -1)"
OFFLINK_IPS="$(printf '%s\n' "${ONLINK_REPORT}" | sed -n 's/^OFFLINK_IPS=//p' | tail -1)"
if [[ -n "${ONLINK_REPORT}" ]]; then
  printf "\nOn-link vs routed (VIP in a node prefix = L2/ARP, not BGP):\n"
  printf '%s\n' "${ONLINK_REPORT}" | grep -v '^ONLINK_IPS=' | grep -v '^OFFLINK_IPS=' | sed 's/^/  /'
fi

section "MetalLB and FRR-K8s"
METALLB_NS=""
if "${OC}" get ns metallb-system >/dev/null 2>&1; then
  METALLB_NS="metallb-system"
fi
HAS_L2=0
HAS_BGP_PEER=0
HAS_BGP_ADV=0
POOL_ADDRS=""
if [[ -n "${METALLB_NS}" ]]; then
  printf "Namespace:         %s\n" "${METALLB_NS}"
  "${OC}" get metallb,ipaddresspool,l2advertisement,bgppeer,bgpadvertisement,bfdprofile -n "${METALLB_NS}" 2>/dev/null \
    || printf "(MetalLB CRs not readable or operator not fully installed)\n"
  [[ -n "$("${OC}" get l2advertisement -n "${METALLB_NS}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)" ]] && HAS_L2=1
  [[ -n "$("${OC}" get bgppeer -n "${METALLB_NS}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)" ]] && HAS_BGP_PEER=1
  [[ -n "$("${OC}" get bgpadvertisement -n "${METALLB_NS}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)" ]] && HAS_BGP_ADV=1
  POOL_ADDRS="$("${OC}" get ipaddresspool -n "${METALLB_NS}" -o json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
parts=[]
for p in d.get("items") or []:
    name=p.get("metadata",{}).get("name","")
    addrs=",".join((p.get("spec") or {}).get("addresses") or [])
    parts.append("%s[%s]" % (name, addrs))
print("; ".join(parts))
' 2>/dev/null || true)"
  add_check "PASS" "MetalLB is installed" \
    "oc get ns metallb-system; oc get metallb,ipaddresspool,l2advertisement,bgppeer,bgpadvertisement -n metallb-system" \
    "pools=${POOL_ADDRS:-none} L2Advertisement=$([[ ${HAS_L2} -eq 1 ]] && echo yes || echo no) BGPPeer=$([[ ${HAS_BGP_PEER} -eq 1 ]] && echo yes || echo no) BGPAdvertisement=$([[ ${HAS_BGP_ADV} -eq 1 ]] && echo yes || echo no)"
else
  add_check "INFO" "MetalLB is installed" \
    "oc get ns metallb-system" \
    "namespace not found — MetalLB Operator not installed (or different namespace)"
fi

FRR_NS=0
FRR_READY=""
FRR_CFG_COUNT=0
BGP_SESS_EST=0
BGP_SESS_TOTAL=0
if "${OC}" get ns openshift-frr-k8s >/dev/null 2>&1; then
  FRR_NS=1
  printf "\nFRR-K8s namespace: openshift-frr-k8s\n"
  "${OC}" get ds,deploy -n openshift-frr-k8s 2>/dev/null | sed -n '1,20p' || true
  FRR_READY="$("${OC}" get ds frr-k8s -n openshift-frr-k8s -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}' 2>/dev/null || true)"
  printf "\nFRRConfiguration objects (created by the MetalLB speaker when BGPPeer exists):\n"
  "${OC}" get frrconfigurations.frrk8s.metallb.io -A 2>/dev/null || printf "(none or CRD missing)\n"
  FRR_CFG_COUNT="$("${OC}" get frrconfigurations.frrk8s.metallb.io -A -o json 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("items") or []))' 2>/dev/null || echo 0)"
  printf "\nBGPSessionState (Established = live BGP; empty = no sessions):\n"
  "${OC}" get bgpsessionstates.frrk8s.metallb.io -A -o wide 2>/dev/null || printf "(none or CRD missing)\n"
  BGP_SESS_TOTAL="$("${OC}" get bgpsessionstates.frrk8s.metallb.io -A -o json 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("items") or []))' 2>/dev/null || echo 0)"
  BGP_SESS_EST="$("${OC}" get bgpsessionstates.frrk8s.metallb.io -A -o json 2>/dev/null | python3 -c '
import json,sys
n=0
for i in json.load(sys.stdin).get("items") or []:
    st=((i.get("status") or {}).get("bgpStatus") or (i.get("status") or {}).get("bgp") or "")
    # CRD column may be .status.bgpStatus
    if not st:
        st=i.get("bgpStatus") or ""
    if str(st).lower()=="established":
        n+=1
print(n)
' 2>/dev/null || echo 0)"
  add_check "INFO" "FRR-K8s DaemonSet is running" \
    "oc get ds frr-k8s -n openshift-frr-k8s" \
    "ready=${FRR_READY:-unknown}. This is the BGP *backend* shipped with MetalLB; it does not mean a ToR session exists."
  FRR_CFG_COUNT="${FRR_CFG_COUNT:-0}"
BGP_SESS_TOTAL="${BGP_SESS_TOTAL:-0}"
BGP_SESS_EST="${BGP_SESS_EST:-0}"
if [[ "${FRR_CFG_COUNT}" -gt 0 ]]; then
    add_check "PASS" "Speaker generated FRRConfiguration" \
      "oc get frrconfigurations.frrk8s.metallb.io -A" \
      "${FRR_CFG_COUNT} object(s) — MetalLB has translated a BGPPeer into FRR config"
  else
    add_check "FAIL" "Speaker generated FRRConfiguration" \
      "oc get frrconfigurations.frrk8s.metallb.io -A" \
      "none — no BGPPeer (or speaker has not rendered one). BGP is not configured on this cluster."
  fi
  if [[ "${BGP_SESS_EST}" -gt 0 ]]; then
    add_check "PASS" "Live BGP session (BGPSessionState)" \
      "oc get bgpsessionstates.frrk8s.metallb.io -A -o wide" \
      "${BGP_SESS_EST}/${BGP_SESS_TOTAL} Established"
  elif [[ "${BGP_SESS_TOTAL}" -gt 0 ]]; then
    add_check "FAIL" "Live BGP session (BGPSessionState)" \
      "oc get bgpsessionstates.frrk8s.metallb.io -A -o wide" \
      "0/${BGP_SESS_TOTAL} Established — peer configured but session is down"
  else
    add_check "FAIL" "Live BGP session (BGPSessionState)" \
      "oc get bgpsessionstates.frrk8s.metallb.io -A" \
      "no session objects — BGP is not in use"
  fi
else
  add_check "INFO" "FRR-K8s DaemonSet is running" \
    "oc get ns openshift-frr-k8s" \
    "namespace not found (expected after MetalLB on recent OCP)"
fi

if [[ "${HAS_L2}" -eq 1 && -n "${ONLINK_IPS}" ]]; then
  add_check "PASS" "MetalLB L2 is serving traffic" \
    "oc get l2advertisement -n metallb-system; compare EXTERNAL-IP to node prefixes" \
    "L2Advertisement present; on-link VIP(s) ${ONLINK_IPS} on ${NODE_PREFIXES}. L2/ARP dataplane is working for those addresses."
elif [[ "${HAS_L2}" -eq 1 ]]; then
  add_check "INFO" "MetalLB L2Advertisement present" \
    "oc get l2advertisement -n metallb-system" \
    "L2 is configured; no on-link LoadBalancer IPs seen"
fi

if [[ -n "${ONLINK_IPS}" ]]; then
  add_check "INFO" "On-link LoadBalancer VIP(s)" \
    "compare LoadBalancer EXTERNAL-IP to observed node prefixes ${NODE_PREFIXES}" \
    "${ONLINK_IPS} is on the node VLAN (L2/ARP). Do not reuse this range as a BGP pool."
fi
if [[ -n "${OFFLINK_IPS}" ]]; then
  add_check "INFO" "Off-link LoadBalancer VIP(s)" \
    "compare LoadBalancer EXTERNAL-IP to observed node prefixes ${NODE_PREFIXES}" \
    "${OFFLINK_IPS} is outside ${NODE_PREFIXES}. That is the shape of a BGP VIP; it is only reachable after a BGP session (or a static route) exists."
fi

PROBE_RESULT=""
TARGET_NODE="${DEBUG_NODE:-${READY_WORKER:-${FIRST_NODE}}}"
TARGET_PEER="${PROBE_PEER}"
if [[ -z "${TARGET_PEER}" ]]; then
  for gw in ${UNIQUE_GWS}; do
    TARGET_PEER="${gw}"
    break
  done
fi

if [[ "${PROBE}" -eq 1 ]]; then
  section "Probe TCP/${PEER_PORT} (from a node)"
  if [[ -z "${TARGET_NODE}" || -z "${TARGET_PEER}" ]]; then
    add_check "SKIP" "TCP/${PEER_PORT} from a node to the gateway" \
      "oc debug node/<node> -- chroot /host; ping; nc -vz <peer> ${PEER_PORT}" \
      "not run: need --node and --peer"
  else
    printf "Command: oc debug node/%s -- chroot /host bash -c 'ping -c 2 -W 2 %s; nc -vz -w 5 %s %s'\n" \
      "${TARGET_NODE}" "${TARGET_PEER}" "${TARGET_PEER}" "${PEER_PORT}"
    printf "(debug pod can take a minute)\n"
    set +e
    PROBE_OUT="$("${OC}" debug "node/${TARGET_NODE}" --quiet -- chroot /host bash -c \
      "ping -c 2 -W 2 ${TARGET_PEER}; echo ---; nc -vz -w 5 ${TARGET_PEER} ${PEER_PORT} 2>&1" 2>&1)"
    PROBE_RC=$?
    set -e
    printf "%s\n" "${PROBE_OUT}"
    if printf '%s' "${PROBE_OUT}" | grep -qiE 'Connected to|succeeded|Ncat:.*open'; then
      PROBE_RESULT="tcp_open"
      add_check "PASS" "TCP/${PEER_PORT} from a node to the gateway" \
        "oc debug node/${TARGET_NODE}; ping ${TARGET_PEER}; nc -vz ${TARGET_PEER} ${PEER_PORT}" \
        "TCP connected — a process on ${TARGET_PEER} accepts BGP. Still need ASN + a routed VIP CIDR from the network team."
    elif printf '%s' "${PROBE_OUT}" | grep -qiE 'Connection refused|Ncat:.*refused'; then
      PROBE_RESULT="tcp_refused"
      add_check "FAIL" "TCP/${PEER_PORT} from a node to the gateway" \
        "oc debug node/${TARGET_NODE}; ping ${TARGET_PEER}; nc -vz ${TARGET_PEER} ${PEER_PORT}" \
        "ICMP ok, TCP refused. Packets reach ${TARGET_PEER} but nothing accepts BGP (or firewall RST). BGP is not readily available on this gateway."
    elif printf '%s' "${PROBE_OUT}" | grep -qiE 'timed out|timeout|No route'; then
      PROBE_RESULT="tcp_timeout"
      add_check "FAIL" "TCP/${PEER_PORT} from a node to the gateway" \
        "oc debug node/${TARGET_NODE}; ping ${TARGET_PEER}; nc -vz ${TARGET_PEER} ${PEER_PORT}" \
        "timeout/no route to ${TARGET_PEER}:${PEER_PORT}. Filtered or wrong peer. BGP is not readily available."
    else
      PROBE_RESULT="unknown_rc_${PROBE_RC}"
      add_check "FAIL" "TCP/${PEER_PORT} from a node to the gateway" \
        "oc debug node/${TARGET_NODE}; ping ${TARGET_PEER}; nc -vz ${TARGET_PEER} ${PEER_PORT}" \
        "could not classify output (rc=${PROBE_RC}). See probe log above."
    fi
  fi
else
  add_check "SKIP" "TCP/${PEER_PORT} from a node to the gateway" \
    "not run. Re-run: $0 --probe --peer ${TARGET_PEER:-<gw>} --node ${TARGET_NODE:-<node>}" \
    "This is the test that confirms or denies whether ${TARGET_PEER:-the ToR} already speaks BGP. Until it runs, BGP readiness is UNKNOWN."
fi

if [[ "${CLOUD_LB_PLATFORM}" -eq 1 ]]; then
  add_check "INFO" "Platform provides a cloud LoadBalancer" \
    "infrastructure.status.platform=${PLATFORM}" \
    "MetalLB BGP is usually unnecessary on ${PLATFORM}"
fi

section "Checks this run (what was actually tested)"
printf "%-6s  %s\n" "STATUS" "CHECK"
printf "%-6s  %s\n" "------" "-----"
while IFS=$'\t' read -r st title how result; do
  printf "%-6s  %s\n" "${st}" "${title}"
  printf "        how:    %s\n" "${how}"
  printf "        result: %s\n" "${result}"
done < "${CHECK_FILE}"
printf "\nSTATUS means: PASS=evidence found, FAIL=evidence against, SKIP=not executed this run, INFO=context only.\n"

section "Verdict for this cluster"
# Compute a one-line BGP status
BGP_IN_USE="no"
if [[ "${BGP_SESS_EST}" -gt 0 ]]; then
  BGP_IN_USE="yes"
elif [[ "${HAS_BGP_PEER}" -eq 1 || "${FRR_CFG_COUNT}" -gt 0 ]]; then
  BGP_IN_USE="configured-but-down"
fi

BGP_READY="UNKNOWN"
BGP_READY_WHY="TCP/${PEER_PORT} to the gateway was not probed (--probe not passed)."
case "${PROBE_RESULT}" in
  tcp_open)
    BGP_READY="PLAUSIBLE"
    BGP_READY_WHY="${TARGET_PEER} accepts TCP/${PEER_PORT}. Confirm ASN and an off-subnet VIP CIDR with the network team, then add BGPPeer + BGPAdvertisement."
    ;;
  tcp_refused)
    BGP_READY="NO"
    BGP_READY_WHY="${TARGET_PEER} is reachable but does not accept BGP. L2 (already in use if listed above) is the working option unless you add another BGP speaker."
    ;;
  tcp_timeout)
    BGP_READY="NO"
    BGP_READY_WHY="TCP/${PEER_PORT} to ${TARGET_PEER} did not complete. BGP is not readily available on that path."
    ;;
esac
if [[ "${BGP_IN_USE}" == "yes" ]]; then
  BGP_READY="YES"
  BGP_READY_WHY="At least one BGPSessionState is Established."
fi

printf "Platform:                 %s\n" "${PLATFORM}"
printf "MetalLB L2 in use:        %s\n" "$([[ ${HAS_L2} -eq 1 ]] && echo yes || echo no)"
printf "MetalLB BGP in use:       %s\n" "${BGP_IN_USE}"
printf "BGP readily available:    %s\n" "${BGP_READY}"
printf "Why:                      %s\n" "${BGP_READY_WHY}"
printf "\n"

if [[ "${IS_CRC}" -eq 1 ]]; then
  printf "CRC: L2 on the libvirt network is the default. BGP only if FRR runs on the CRC host\n"
  printf "(see components/metallb/README.md). Existing L2 VIPs on 192.168.130.0/24 are not a BGP pool.\n"
elif [[ "${CLOUD_LB_PLATFORM}" -eq 1 ]]; then
  printf "Use the ${PLATFORM} LoadBalancer. MetalLB BGP is a special case (extra NIC/BYO network).\n"
elif [[ "${HAS_L2}" -eq 1 ]]; then
  printf "This looks like vSphere/bare-metal IPI with MetalLB L2 already serving LoadBalancer IPs\n"
  printf "on the node VLAN (gateway %s, node prefix %s).\n" "${UNIQUE_GWS:-unknown}" "${NODE_PREFIXES:-unknown}"
  printf "API/ingress keepalived VIPs on that same VLAN are unrelated to MetalLB BGP.\n"
  printf "\nTo move to BGP you still need all of:\n"
  printf "  1. A BGP speaker (often %s) — prove with: %s --probe\n" "${TARGET_PEER:-<gateway>}" "$0"
  printf "  2. A routed VIP CIDR *outside* %s (do not reuse the current L2 /32s)\n" "${NODE_PREFIXES:-the node subnet}"
  printf "  3. Network-team ASN, prefix-list, and upstream advertisement of that CIDR\n"
  printf "If (1) fails, BGP is not readily available; keep L2 or add a different speaker (spine, NSX T0, FRR VM).\n"
else
  printf "MetalLB is the usual LB on this platform. Prefer L2 if clients are on the node VLAN.\n"
  printf "Prefer BGP only after --probe shows TCP/%s open and you have an off-subnet VIP CIDR.\n" "${PEER_PORT}"
fi

printf "\nAsk the network team:\n"
printf "  Peer IP we would use: %s (node default gateway from OVN).\n" "${TARGET_PEER:-unknown}"
printf "  Does that SVI (or another speaker we can reach) peer BGP with node IPs on %s?\n" "${NODE_PREFIXES:-the node subnet}"
printf "  Cluster ASN, peer ASN, TCP/%s, optional BFD, and a VIP CIDR that does not overlap %s.\n" "${PEER_PORT}" "${NODE_PREFIXES:-the node subnet}"
printf "\nDone.\n"
