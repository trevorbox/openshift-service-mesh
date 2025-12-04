# ambient mode

## prerequisites

* <https://istio.io/latest/docs/ambient/install/platform-prerequisites/#red-hat-openshift>
* <https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/ovn-kubernetes_network_plugin/configuring-gateway>
* <https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.1/html/installing/ossm-istio-ambient-mode#ossm-installing-istio-ambient-mode_ossm-istio-ambient-mode>

```sh
oc patch networks.operator.openshift.io cluster --type=merge -p '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost": true}}}}}'
```

## Notes

Had to delete PeerAuthentication with STRICT mtls mode to remove these errors in ztunnel for liveness/readiness probes to start working

```log
2025-10-30T22:23:01.119792Z error access connection complete src.addr=10.217.0.2:44480 dst.addr=10.217.0.248:8080 dst.workload="golang-ex-6d957754b-nfbfv" dst.namespace="test" direction="inbound" bytes_sent=0 bytes_recv=0 duration="0ms" error="connection closed due to policy rejection: explicitly denied by: istio-system/istio_converted_static_strict"
2025-10-30T22:23:01.120766Z error access connection complete src.addr=10.217.0.2:44486 dst.addr=10.217.0.248:8080 dst.workload="golang-ex-6d957754b-nfbfv" dst.namespace="test" direction="inbound" bytes_sent=0 bytes_recv=0 duration="0ms" error="connection closed due to policy rejection: explicitly denied by: istio-system/istio_converted_static_strict"
2025-10-30T22:23:01.719707Z error access connection complete src.addr=10.217.0.2:36610 dst.addr=10.217.0.249:8080 dst.workload="golang-ex-featurea-54cb557c6d-7vq4r" dst.namespace="golang-ex" direction="inbound" bytes_sent=0 bytes_recv=0 duration="0ms" error="connection closed due to policy rejection: explicitly denied by: istio-system/istio_converted_static_strict"
2025-10-30T22:23:02.728466Z error access connection complete src.addr=10.217.0.2:44494 dst.addr=10.217.0.248:8080 dst.workload="golang-ex-6d957754b-nfbfv" dst.namespace="test" direction="inbound" bytes_sent=0 bytes_recv=0 duration="0ms" error="connection closed due to policy rejection: explicitly denied by: istio-system/istio_converted_static_strict"
2025-10-30T22:23:02.728568Z error access connection complete src.addr=10.217.0.2:36624 dst.addr=10.217.0.249:8080 dst.workload="golang-ex-featurea-54cb557c6d-7vq4r" dst.namespace="golang-ex" direction="inbound" bytes_sent=0 bytes_recv=0 duration="0ms" error="connection closed due to policy rejection: explicitly denied by: istio-system/istio_converted_static_strict"
2025-10-30T22:23:03.379016Z error access connection complete src.addr=10.217.0.2:48912 dst.addr=10.217.0.250:8080 dst.workload="golang-ex-stable-b64c9cc76-66h87" dst.namespace="golang-ex" direction="inbound" bytes_sent=0 bytes_recv=0 duration="0ms" error="connection closed due to policy rejection: explicitly denied by: istio-system/istio_converted_static_strict"
2025-10-30T22:23:03.380038Z error access connection complete src.addr=10.217.0.2:48928 dst.addr=10.217.0.250:8080 dst.workload="golang-ex-stable-b64c9cc76-66h87" dst.namespace="golang-ex" direction="inbound" bytes_sent=0 bytes_recv=0 duration="0ms" error="connection closed due to policy rejection: explicitly denied by: istio-system/istio_converted_static_strict"
2025-10-30T22:23:03.734386Z error access connection complete src.addr=10.217.0.2:44510 dst.addr=10.217.0.248:8080 dst.workload="golang-ex-6d957754b-nfbfv" dst.namespace="test" direction="inbound" bytes_sent=0 bytes_recv=0 duration="0ms" error="connection closed due to policy rejection: explicitly denied by: istio-system/istio_converted_static_strict"
```

Show Ip addresses in subnet

```sh

tbox@fedora:~/git/trevorbox/openshift-service-mesh$ sudo virsh list
 Id   Name   State
----------------------
 1    crc    running

tbox@fedora:~/git/trevorbox/openshift-service-mesh$ sudo virsh net-dhcp-leases crc
 Expiry Time           MAC address         Protocol   IP address          Hostname   Client ID or DUID
-----------------------------------------------------------------------------------------------------------
 2025-11-25 18:08:59   52:fd:fc:07:21:82   ipv4       192.168.130.11/24   crc        01:52:fd:fc:07:21:82

tbox@fedora:~/git/trevorbox/openshift-service-mesh$ sudo virsh net-list
 Name      State    Autostart   Persistent
--------------------------------------------
 crc       active   yes         yes
 default   active   yes         yes

tbox@fedora:~/git/trevorbox/openshift-service-mesh$ crc ip
192.168.130.11
tbox@fedora:~/git/trevorbox/openshift-service-mesh$ crc config view
- consent-telemetry                     : no
- cpus                                  : 14
- disk-size                             : 300
- enable-cluster-monitoring             : true
- memory                                : 40060
- network-mode                          : system
- pull-secret-file                      : /home/tbox/pull-secret.txt
```

```sh
curl -i -v -H Host:httpbin.example.com http://192.168.130.200:80/headers
```

I have experienced this issue <https://github.com/istio/istio/issues/56729>

And then I had to remove and re-add the `istio.io/dataplane-mode=ambient` labels to fix the ztunnel "connection failed: deadline has elapsed" problem.

```sh
oc get namespace -l istio.io/dataplane-mode=ambient -o name | 
while IFS=$"\n" read -r namespace; do
  echo "------------------"
  echo "Namespace: $namespace"
  oc label $namespace istio.io/dataplane-mode-
  echo ".................."
done
oc get namespace -l istio.io/dataplane-mode=ambient
```

## testing

```sh
curl -i -v -H Host:httpbin.example.com http://192.168.130.200:80/headers
curl -k https://bookinfo-istio-ingress.apps-crc.testing/productpage
```
