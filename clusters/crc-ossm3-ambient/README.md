# ambient mode

## prerequisites

* <https://istio.io/latest/docs/ambient/install/platform-prerequisites/#red-hat-openshift>
* <https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/ovn-kubernetes_network_plugin/configuring-gateway>
* <https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.1/html/installing/ossm-istio-ambient-mode#ossm-installing-istio-ambient-mode_ossm-istio-ambient-mode>

```sh
oc patch networks.operator.openshift.io cluster --type=merge -p '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost": true}}}}}'
```
