# Is MetalLB BGP possible on this OpenShift cluster?

Use this against **any** logged-in OpenShift cluster (vSphere IPI, bare metal, CRC, cloud, and so on). It does not change the cluster.

**ToR** (top-of-rack) is the switch or router that is the first hop for the nodes. On a typical IPI VLAN that is the node default gateway.

## Quick start

```sh
# Logged in as a user who can get nodes, network, and (for --probe) oc debug
./components/metallb/bgp-feasibility/check-bgp-feasibility.sh

# Also ping + TCP/179 from a node to the discovered gateway
./components/metallb/bgp-feasibility/check-bgp-feasibility.sh --probe
./components/metallb/bgp-feasibility/check-bgp-feasibility.sh --probe --peer 10.0.0.1 --node worker-0
```

Requires `oc` and `python3`. `--probe` starts a debug pod and needs `cluster-admin` (or equivalent).

The default run **does not** open TCP/179. It only reads the API. The report has a **Checks this run** section (PASS / FAIL / SKIP / INFO) so you can see what was actually tested. `BGP readily available: UNKNOWN` means the gateway BGP port was not probed.

Example: vSphere IPI with MetalLB L2 already assigning an IP on the node `/25` is **L2 working**, not BGP. Re-run with `--probe` to test `nc -vz <gateway> 179` from a node.

## What “BGP is possible” means

MetalLB BGP is an option only if all of these are true:

1. You **need** MetalLB at all (no usable platform LoadBalancer).
2. A BGP-capable router exists that nodes can reach (usually the ToR SVI / default gateway).
3. **TCP 179** is allowed node → router (UDP 3784/3785 as well if you want BFD).
4. You have a **VIP CIDR outside the machine network**. BGP advertises routed prefixes; do not reuse the node subnet.
5. The router will install those prefixes with **next-hop = node IP** (ECMP if you want traffic spread across nodes).

Without `--probe` the script only proves (1) and discovers a candidate IP for (2). Item (3) is SKIP until `--probe`. Items (4)–(5) stay with the network team.

## How the script finds the ToR IP

It reads each node’s `k8s.ovn.org/l3-gateway-config` annotation (`next-hop` / `next-hops`). That is the OVN copy of the host default gateway.

If that annotation is missing:

```sh
oc debug node/<node> -- chroot /host ip -4 route show default
```

`--probe` then `ping`s that IP and runs `nc -vz <ip> 179` from the node.

| Probe result | Meaning |
| --- | --- |
| TCP connected / succeeded | Something is listening on BGP; continue with ASN and prefix-list |
| Connection refused | Packet reached the IP; no BGP daemon, or a firewall RST. Not live yet |
| Timeout / no route | Filtered or wrong peer. BGP is not an option until the path is opened |

## Options the script will suggest

| Situation | Use this |
| --- | --- |
| AWS, Azure, GCP, IBM Cloud, Alibaba (or LoadBalancer IPs already assigned without MetalLB) | **Platform LoadBalancer**. MetalLB BGP is rarely needed |
| vSphere / bare metal / Nutanix / OpenStack without a working cloud LB; ToR does not speak BGP | **MetalLB L2** is the default. BGP is still possible if you add another speaker (see below). vSphere port groups often need forged transmits / MAC changes (or MAC learning) for L2 |
| Same platforms; ToR speaks BGP; TCP/179 open; routed VIP CIDR available | **MetalLB BGP** to that ToR. `BGPPeer` + `BGPAdvertisement` + off-subnet `IPAddressPool` |
| Several different default gateways | One `BGPPeer` per ToR with `spec.nodeSelectors` (rack-aware) |
| OpenShift Local (CRC) | **L2** on `192.168.130.0/24`. BGP only if you run FRR on the CRC **host** — see [../README.md](../README.md) |
| HTTP(S) only, no Service LoadBalancer | **OpenShift Routes** on the platform ingress VIP |
| You already own an F5/Netscaler/etc. | NodePort or hostNetwork behind that appliance |

L2 and BGP can coexist (different pools). Do not treat an L2 VIP range as a BGP demo: the subnet is already on-link.

## “No BGP on the ToR” does not mean BGP is impossible

MetalLB must peer with **some** BGP speaker. The ToR is only the usual one because it is already the default gateway and already forwards client traffic.

If the ToR is a plain L2/L3 VLAN gateway (no BGP), you still have:

1. **MetalLB L2** — no extra router. This is the normal choice on vSphere IPI and many bare-metal labs.
2. **MetalLB BGP to a different device** — any reachable speaker: spine/core, firewall, NSX T0/edge, or a Linux VM running FRR/BIRD (same pattern as the CRC host lab). Nodes need TCP/179 to that IP (`ebgpMultiHop: true` if it is not on-link). That device must then announce the VIP CIDR **upstream** (or you add static routes toward it).
3. **Something that is not MetalLB** — OpenShift Routes, an existing hardware LB, `spec.externalIPs`.

BGP is only off the table if you cannot (or will not) place *any* BGP speaker in the path and you will not open TCP/179. Then use L2 or an external LB.

## After you choose BGP

You do **not** write `FRRConfiguration` by hand for the MetalLB session. Install MetalLB, apply `BGPPeer` / `IPAddressPool` / `BGPAdvertisement`. The speaker creates `FRRConfiguration/metallb-<node>` in `openshift-frr-k8s`.

```sh
oc get bgpsessionstates.frrk8s.metallb.io -A -o wide
oc exec -n openshift-frr-k8s ds/frr-k8s -c frr -- vtysh -c "show bgp summary"
```

Ask the network team for: cluster ASN, peer ASN, peer IP (confirm it matches the script’s gateway list), VIP CIDR, prefix-list, and whether eBGP multihop is required (only if the peer is not on-link).

## CRC lab

This check will detect `api.crc.testing`. L2 is the default. To simulate BGP on the same laptop, use [../README.md](../README.md) and [../host-bgp-router/](../host-bgp-router/).
