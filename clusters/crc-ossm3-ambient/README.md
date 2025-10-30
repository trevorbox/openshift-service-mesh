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
