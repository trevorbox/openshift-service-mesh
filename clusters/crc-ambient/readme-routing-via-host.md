# routingViaHost, probes, and STRICT mTLS

Ambient on OpenShift needs OVN-Kubernetes local gateway mode so kubelet probes succeed. The same exception applies to every socket in the node's network namespace, so any hostNetwork workload on that node can reach a colocated ambient pod without entering ztunnel.

Keep this set:

```sh
oc patch networks.operator.openshift.io cluster --type=merge -p '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost": true}}}}}'
```

`routingViaHost: true` is local gateway mode. `false` is shared gateway mode. Istio documents the requirement for workloads that use liveness or readiness probes: [platform prerequisites](https://istio.io/latest/docs/ambient/install/platform-prerequisites/#red-hat-openshift). OpenShift describes the gateway modes in [Configuring a gateway](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/ovn-kubernetes_network_plugin/configuring-gateway).

## Enabling this on a cluster that is already running

The field is cluster-wide. Setting it moves every pod from shared gateway mode to local gateway mode, including workloads that will never join the mesh. The patch does not enroll any namespace in ambient.

On a production cluster, set local gateway mode on a new cluster and migrate the applications onto it. The OpenShift 4.22 Cluster Network Operator reference says this on the `gatewayConfig` field:

> While migrating egress traffic, you can expect some disruption to workloads and service traffic until the Cluster Network Operator (CNO) successfully rolls out the changes.

Source: [Cluster Network Operator in OpenShift Container Platform](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/networking_operators/cluster-network-operator). The same disruption happens if you set the field back to `false`. That rollout reprograms the node datapath. Long-running TCP connections, such as database sessions, gRPC streams, and message-bus consumers, can stall or reset when their node's gateway changes. OpenShift does not drain those sockets first. An in-place change belongs in a maintenance window only when dropped connections are acceptable and the host firewall and routes below have been reviewed.

In shared gateway mode, OVN-Kubernetes sends pod ingress and egress through Open vSwitch (OVS) and out the node interface. Host routes and host iptables or nftables do not see those packets, and hardware offload can apply. In local gateway mode, the same packets are delivered to the host networking stack. The kernel routing table, host firewall rules, and host connection tracking then apply to every pod, and the offload benefit on that path goes away. The node does more forwarding work for traffic that never enters the mesh.

A host rule or static route that was written for node processes starts matching application flows. That can drop, reject, or rewrite traffic that previously left through OVN-Kubernetes untouched.

## How probes skip ztunnel

Kubelet has no mesh identity. Ambient exempts it with a host SNAT plus an in-pod accept. `istio-cni` puts every ambient pod IP on the node into the `istio-inpod-probes-v4` ipset (`hash:ip`, every port, not only probe ports).

On the node, with the default probe address (`HOST_PROBE_SNAT_IP`, IPv6 default `HOST_PROBE_SNAT_IPV6`):

```text
ISTIO_POSTRT  SNAT  owner socket-exists  match-set istio-inpod-probes-v4 dst  to:169.254.7.127
```

Any TCP socket opened in the host network namespace and aimed at an ambient pod IP on that node is rewritten to that source. Inside the pod:

```text
ISTIO_PRERT  ACCEPT    tcp  source 169.254.7.127
ISTIO_PRERT  REDIRECT  tcp  dport != 15008  to :15006
```

Traffic from `169.254.7.127` is delivered to the application. Everything else on a workload port is redirected to ztunnel (`15006` plaintext, `15008` HBONE). A mesh-wide `PeerAuthentication` `STRICT` becomes `istio_converted_static_strict` on the workload and denies connections that arrive at ztunnel with no peer identity.

Local gateway mode is what makes the probe handshake finish. The SYN-ACK has to come back through the host routing table so host conntrack can reverse the SNAT and hand the response to kubelet. With `routingViaHost: false`, OVN's shared gateway does not return `169.254.7.127` to that conntrack entry. The application socket stays in `SYN-RECV` and the probe times out. ztunnel never sees the packet, so deleting the `PeerAuthentication` does not help.

If the host SNAT rule is missing, probes arrive as the node IP, hit ztunnel, and `STRICT` resets them.

## Pod-to-pod traffic stays encrypted

The exemption is only for sockets in the host network namespace. A normal pod socket is in its own network namespace, so ztunnel redirects it and sends HBONE, including when both pods are on the same node.

```text
Pod A application
  |  redirect inside pod A to ztunnel :15001
  v
ztunnel
  |  HBONE mTLS to pod B :15008
  v
ztunnel
  |  plaintext inside pod B
  v
Pod B application
```

An ingress gateway is a mesh client, so its hop to the application is the same HBONE path. The router in front of it is still hostNetwork. Its listen socket takes the client connection, and a second socket connects to the gateway in plaintext. When that gateway pod is ambient and on the same node, the probe rule SNATs that outbound socket to `169.254.7.127`. HBONE starts at the gateway.

```text
Client
  |  HTTPS, inbound. Probe rule does not match.
  v
Router listen socket :443
  node network namespace
  |  second socket, plaintext to the gateway
  v
Ingress gateway
  |  HBONE mTLS :15008
  v
ztunnel
  |  plaintext inside the pod
  v
Application
```

## Any hostNetwork workload can bypass STRICT mTLS

A pod with `hostNetwork: true` shares the node's network namespace. Ingress and egress are different sockets in that namespace. The probe rule matches the outbound socket when its destination is an ambient pod IP on the same node. The listening socket is inbound to the host, so the rule does not apply to it.

```text
Client
  |  inbound to the listen socket. Probe rule does not match.
  v
Listen socket :443
  node network namespace
  |  process opens a second socket
  v
Outbound socket to the ambient pod IP
  |  host POSTROUTING SNAT source 169.254.7.127
  v
Pod ACCEPT
  ztunnel is not on this path
  v
Application
```

ztunnel is not on that path. Mesh-wide `STRICT` mTLS and L4 `AuthorizationPolicy` do not apply to the outbound hop. Kubelet probes are the same kind of outbound socket.

This is not limited to ingress. Any hostNetwork Service or pod can do it: a metrics scraper, a daemon, an operator, or a platform ingress controller. The OpenShift router is the case on CRC because that cluster has one node, so the hostNetwork ingress pod is always colocated with the backend and every Route to an ambient workload takes this path. On a multi-node cluster the same thing happens only for backends scheduled on a node that runs the hostNetwork pod. A hostNetwork client on another node is not a local socket for that destination; ztunnel sees plaintext and `STRICT` resets it.

A normal pod cannot use this path. Its socket lives in its own network namespace, so ztunnel sends HBONE even when the peer is on the same node.

Be careful with hostNetwork. On OpenShift the restricted SCC and Pod Security admission are what keep ordinary workloads out of the host network namespace. Grant it only to platform components that must have it. Root on the node is a broader break: Istio's [security model](https://istio.io/latest/docs/ops/deployment/security-model/) treats node compromise as full control of every workload on that node, including ztunnel, and the blast radius stays on that node. The mesh is not the control that protects pods from someone who already has the node.

Do not treat a hostNetwork ingress path as mesh ingress. North-south traffic that should carry a mesh identity has to enter through a gateway pod. The hostNetwork client can still reach that gateway in plaintext when they share a node. The gateway-to-application hop is HBONE. A `NetworkPolicy` cannot separate kubelet from other host sockets after the SNAT; ambient expects the probe address to be allowed so probes keep working.
