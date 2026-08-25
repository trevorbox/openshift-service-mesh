# MetalLB on OpenShift Local (CRC): L2 vs BGP

To decide **whether BGP is even an option** on an arbitrary OpenShift cluster (vSphere IPI, bare metal, cloud, CRC), run the checker first:

- [bgp-feasibility/README.md](bgp-feasibility/README.md)
- `./components/metallb/bgp-feasibility/check-bgp-feasibility.sh` (`--probe` to test TCP/179)

This document is the CRC lab that actually peers BGP with FRR on the host.

Keep the L2 advertisement for `192.168.130.200` (existing ingress). BGP uses a **separate off-subnet pool** so you can compare the two paths without breaking L2.

## Why CRC needs a different VIP range for BGP

CRC `network-mode: system` creates a libvirt network:

| Role | Address |
| --- | --- |
| Host `crc` bridge | `192.168.130.1/24` |
| CRC VM `br-ex` (host-facing) | `192.168.130.11/24` |
| OpenShift node InternalIP | `192.168.126.11/24` (not reachable from the host) |

The L2 pool `192.168.130.200-192.168.130.249` works because MetalLB answers ARP on `192.168.130.0/24`. The host already has that subnet as a connected route, so advertising those same addresses over BGP does not demonstrate routing.

The BGP pool `crc-bgp` is `192.168.200.200-192.168.200.249`. Those addresses are not on the CRC bridge. The host only reaches them after FRR installs `/32` routes whose next hop is `192.168.130.11`.

```text
 Fedora host
   crc 192.168.130.1   ASN 64501  (this FRR container)
           |
    192.168.130.0/24  (libvirt)
           |
 CRC VM br-ex 192.168.130.11   ASN 64500  (MetalLB FRR-K8s)
           |
    OVN-Kubernetes
           |
 LoadBalancer VIP 192.168.200.200  -> istio-ingress/ingress-gateway
```

MetalLB must source the BGP session from `192.168.130.11`, not from `192.168.126.11`. That is why `BGPPeer.spec.sourceAddress` is set.

## Cluster resources (BGP instead of L2)

| Kind | Name | Purpose |
| --- | --- | --- |
| `IPAddressPool` | `crc` | Existing L2 VIPs on `192.168.130.200-249` |
| `L2Advertisement` | `crc` | Existing ARP advertisement for pool `crc` |
| `IPAddressPool` | `crc-bgp` | BGP VIPs on `192.168.200.200-249` (`autoAssign: false`) |
| `BGPPeer` | `crc-host` | eBGP to the host FRR at `192.168.130.1` (ASN 64501) |
| `BGPAdvertisement` | `crc` | Advertise pool `crc-bgp` to peer `crc-host` |
| `Service` | `istio-ingress/ingress-gateway-istio-bgp` | Same ingress pods, VIP `192.168.200.200` |

Apply with GitOps (the `metallb` application) or:

```sh
oc apply -k components/metallb
```

A service that should take a BGP VIP must request that pool:

```yaml
metadata:
  annotations:
    metallb.io/address-pool: crc-bgp
spec:
  type: LoadBalancer
  loadBalancerIP: 192.168.200.200   # optional, pins the documented address
```

Without the annotation, MetalLB keeps using the L2 pool `crc` (`autoAssign: true`).

## Host BGP router

The CRC VM is the MetalLB speaker. The **host** must run a BGP daemon that:

1. Accepts TCP/179 from `192.168.130.11` (firewalld `libvirt` zone otherwise rejects guest-to-host traffic).
2. Peers eBGP ASN 64501 ↔ 64500.
3. Installs kernel routes for `192.168.200.0/24` via `192.168.130.11`.

Config lives in [`host-bgp-router/`](host-bgp-router/). From this repo:

```sh
sudo ./components/metallb/host-bgp-router/run-host-bgp-router.sh start
sudo ./components/metallb/host-bgp-router/run-host-bgp-router.sh status
```

The script starts `quay.io/frrouting/frr:10.3.1` with `--network host --privileged` so zebra can program the host routing table.

### Dataplane check without BGP

If you want to confirm OVN/MetalLB will accept the VIP before FRR is up:

```sh
sudo ip route add 192.168.200.200/32 via 192.168.130.11
curl -ivk --resolve "httpbin.example.com:443:192.168.200.200" https://httpbin.example.com:443/headers
sudo ip route del 192.168.200.200/32
```

If that curl works, the remaining work is only the BGP session and FRR route install.

## Verify

```sh
# Cluster: MetalLB assigned the BGP VIP
oc get svc ingress-gateway-istio-bgp -n istio-ingress
oc get ipaddresspool,bgppeer,bgpadvertisement -n metallb-system

# Cluster: FRR-K8s session toward the host
FRR=$(oc get pod -n openshift-frr-k8s -l app=frr-k8s -o jsonpath='{.items[0].metadata.name}')
oc exec -n openshift-frr-k8s "${FRR}" -c frr -- vtysh -c "show bgp summary"
oc exec -n openshift-frr-k8s "${FRR}" -c frr -- vtysh -c "show ip bgp"

# Host: session Established and /32 installed
sudo podman exec crc-metallb-bgp-peer vtysh -c "show bgp summary"
sudo podman exec crc-metallb-bgp-peer vtysh -c "show ip bgp"
ip route show | grep 192.168.200

# Same app as L2, different advertisement
curl -ivk --resolve "httpbin.example.com:443:192.168.130.200" https://httpbin.example.com:443/headers
curl -ivk --resolve "httpbin.example.com:443:192.168.200.200" https://httpbin.example.com:443/headers
```

Expected host route:

```text
192.168.200.200 nhid ... via 192.168.130.11 dev crc proto bgp metric 20
```

`show bgp summary` should show `Established` for neighbor `192.168.130.11` (on the host) and `192.168.130.1` (in FRR-K8s).

## Switch a service from L2 to BGP

1. Keep `IPAddressPool/crc` or move the service onto `crc-bgp`.
2. Annotate the Service with `metallb.io/address-pool: crc-bgp` (and optionally `loadBalancerIP`).
3. Leave `L2Advertisement` in place for other services, or delete it if every VIP should be BGP-only.
4. Point `BGPAdvertisement.spec.ipAddressPools` at the pool you want advertised.
5. Run the host FRR peer so those prefixes are installed on the CRC host.

Do **not** advertise `192.168.130.200-249` as the only BGP demo on CRC: the host already owns `192.168.130.0/24`. Use `crc-bgp` for a realistic “ToR learns a VIP prefix” setup.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| BGP stays Idle/Active | `crc ip` is still `192.168.130.11`; firewalld `libvirt` zone allows TCP/179; FRR container is running |
| Session up, no host routes | `show ip bgp` on the host; prefix-list `METALLB-VIPS` must permit `192.168.200.0/24 le 32` |
| Session up, routes present, curl fails | static `/32` test above; NetworkPolicy; gateway listener/hostname |
| Next-hop `192.168.126.11` | `BGPPeer.spec.sourceAddress` must be `192.168.130.11` |
| `crc ip` is not `192.168.130.11` | update `bgppeer-crc-host.yaml` and `host-bgp-router/frr.conf` |

## Cleanup

```sh
sudo ./components/metallb/host-bgp-router/run-host-bgp-router.sh stop
sudo firewall-cmd --zone=libvirt --remove-port=179/tcp
sudo firewall-cmd --zone=libvirt --remove-port=179/tcp --permanent
```

Remove the BGP CRs and example Service from GitOps, or:

```sh
oc delete svc ingress-gateway-istio-bgp -n istio-ingress
oc delete bgpadvertisement crc bgppeer crc-host ipaddresspool crc-bgp -n metallb-system
```
