# Investigate sourceIp behavior with Openshift for Ip whitelist in AuthorizationPolicy

https://istio.io/v1.20/docs/ops/configuration/traffic-management/network-topologies/#forwarding-external-client-attributes-ip-address-certificate-info-to-destination-workloads

```sh
tbox@fedora:~/git/trevorbox/openshift-service-mesh$ curl -k -s -H 'X-Forwarded-For: 56.5.6.7, 72.9.5.6, 98.1.2.3' "https://golang-ex-featurea-istio-ingress.apps-crc.testing/"
{
 "RequestHeaders": {
  "Accept": [
   "*/*"
  ],
  "Traceparent": [
   "00-c0102a3894effba89554f50121d6a246-3320aaab05594439-01"
  ],
  "Tracestate": [
   ""
  ],
  "User-Agent": [
   "curl/8.6.0"
  ],
  "X-Envoy-Attempt-Count": [
   "1"
  ],
  "X-Envoy-External-Address": [
   "10.217.0.2"
  ],
  "X-Forwarded-Client-Cert": [
   "By=spiffe://cluster.local/ns/golang-ex/sa/golang-ex;Hash=d87f7515af2bd04d5de6610eca07b9d949d52f216eb245099674044ae7b14314;Subject=\"\";URI=spiffe://cluster.local/ns/istio-ingress/sa/istio-ingressgateway"
  ],
  "X-Forwarded-For": [
   "56.5.6.7, 72.9.5.6, 98.1.2.3,10.217.0.2"
  ],
  "X-Forwarded-Proto": [
   "https"
  ],
  "X-Request-Id": [
   "908a5084-206a-9be4-9930-3e833b2a61e0"
  ]
 },
 "ResponseHeaders": {
  "ETag": [
   "W/\"0815\""
  ],
  "Set-Cookie": [
   "id=a3fWa; Max-Age=2592000",
   "id=b3fWa; Max-Age=3592000"
  ],
  "Test": [
   "test"
  ],
  "X-Content-Type-Options": [
   ""
  ],
  "X-Powered-By": [
   "Go"
  ],
  "X-XSS-Protection": [
   "0"
  ]
 },
 "Status": "Returned headers from the RESPONSE_HEADERS environment variable.",
 "Error": "",
 "Usage": "Usage: Set the RESPONSE_HEADERS environment variable to always return custom response headers for a GET request, else static default headers will be returned. Alternatively, send a POST or PUT request with the headers you want returned. Example: curl -i -X POST localhost:8080 -d '{\"k1\":[\"v1\"],\"k2\":[\"v3\",\"v4\"]}'"
}
```

What is 10.217.0.2?

on the crc node...
```sh
sh-4.4# ifconfig
...
ovn-k8s-mp0: flags=4163<UP,BROADCAST,RUNNING,MULTICAST>  mtu 1400
        inet 10.217.0.2  netmask 255.255.254.0  broadcast 10.217.1.255
        inet6 fe80::e830:c2ff:fefa:2066  prefixlen 64  scopeid 0x20<link>
        ether ea:30:c2:fa:20:66  txqueuelen 1000  (Ethernet)
        RX packets 29178708  bytes 30606250592 (28.5 GiB)
        RX errors 0  dropped 0  overruns 0  frame 0
        TX packets 30976609  bytes 111562538499 (103.9 GiB)
        TX errors 0  dropped 0 overruns 0  carrier 0  collisions 0
```

https://docs.redhat.com/en/documentation/red_hat_build_of_microshift/4.14/html/networking/microshift-cni#microshift-description-connections-network-topology_microshift-about-ovn-k-plugin
The north-south traffic between the pods and the external network is provided by the OVN cluster router ovn_cluster_router and the host network. This router is connected through the ovn-kubernetes management port ovn-k8s-mp0

Since this is a passthrough route, haproxy would not change any encrypted info in the packet.

Try Edge termination and replace the forwarded-headers maybe that will add the client source IP im looking for

https://docs.openshift.com/container-platform/4.16/networking/routes/route-configuration.html
haproxy.router.openshift.io/set-forwarded-headers: replace

```sh
tbox@fedora:~/git/trevorbox/openshift-service-mesh$ curl -k -s -H 'X-Forwarded-For: 56.5.6.7, 72.9.5.6, 98.1.2.3' "https://golang-ex-edge-istio-ingress.apps-crc.testing/"
{
 "RequestHeaders": {
  "Accept": [
   "*/*"
  ],
  "Forwarded": [
   "for=192.168.130.1;host=golang-ex-edge-istio-ingress.apps-crc.testing;proto=https"
  ],
  "Traceparent": [
   "00-7902062dbcb726642632182ce87601fe-a98ec5f2be06489d-01"
  ],
  "Tracestate": [
   ""
  ],
  "User-Agent": [
   "curl/8.6.0"
  ],
  "X-Envoy-Attempt-Count": [
   "1"
  ],
  "X-Envoy-External-Address": [
   "10.217.0.2"
  ],
  "X-Forwarded-Client-Cert": [
   "By=spiffe://cluster.local/ns/golang-ex/sa/golang-ex;Hash=d87f7515af2bd04d5de6610eca07b9d949d52f216eb245099674044ae7b14314;Subject=\"\";URI=spiffe://cluster.local/ns/istio-ingress/sa/istio-ingressgateway"
  ],
  "X-Forwarded-For": [
   "192.168.130.1,10.217.0.2"
  ],
  "X-Forwarded-Host": [
   "golang-ex-edge-istio-ingress.apps-crc.testing"
  ],
  "X-Forwarded-Port": [
   "443"
  ],
  "X-Forwarded-Proto": [
   "http"
  ],
  "X-Request-Id": [
   "e7bb3e0d-6f24-9cf3-ba81-55cf6aaa9b4d"
  ]
 },
 "ResponseHeaders": {
  "ETag": [
   "W/\"0815\""
  ],
  "Set-Cookie": [
   "id=a3fWa; Max-Age=2592000",
   "id=b3fWa; Max-Age=3592000"
  ],
  "Test": [
   "test"
  ],
  "X-Content-Type-Options": [
   ""
  ],
  "X-Powered-By": [
   "Go"
  ],
  "X-XSS-Protection": [
   "0"
  ]
 },
 "Status": "Returned headers from the RESPONSE_HEADERS environment variable.",
 "Error": "",
 "Usage": "Usage: Set the RESPONSE_HEADERS environment variable to always return custom response headers for a GET request, else static default headers will be returned. Alternatively, send a POST or PUT request with the headers you want returned. Example: curl -i -X POST localhost:8080 -d '{\"k1\":[\"v1\"],\"k2\":[\"v3\",\"v4\"]}'"
}
```

what is 192.168.130.1?

```sh
tbox@fedora:~/git/trevorbox/openshift-service-mesh$ ifconfig 
crc: flags=4163<UP,BROADCAST,RUNNING,MULTICAST>  mtu 1500
        inet 192.168.130.1  netmask 255.255.255.0  broadcast 192.168.130.255
        ether 52:54:00:fd:be:d0  txqueuelen 1000  (Ethernet)
        RX packets 363347  bytes 1472144724 (1.3 GiB)
        RX errors 0  dropped 0  overruns 0  frame 0
        TX packets 728895  bytes 1177032495 (1.0 GiB)
        TX errors 0  dropped 11 overruns 0  carrier 0  collisions 0
```

Note: Authorizationpolicy needs to use remoteIpBlocks per https://istio.io/v1.20/docs/tasks/security/authorization/authz-ingress/#ip-based-allow-list-and-deny-list

Yay it works

```sh
tbox@fedora:~/git/trevorbox/openshift-service-mesh$ curl -k -s -H 'X-Forwarded-For: 56.5.6.7, 72.9.5.6, 98.1.2.3' "https://golang-ex-edge-istio-ingress.apps-crc.testing/"
{
 "RequestHeaders": {
  "Accept": [
   "*/*"
  ],
  "Forwarded": [
   "for=192.168.130.1;host=golang-ex-edge-istio-ingress.apps-crc.testing;proto=https"
  ],
  "Traceparent": [
   "00-2975b5786fb9275ef200e1790bc86aa4-807fe77cb50e1226-01"
  ],
  "Tracestate": [
   ""
  ],
  "User-Agent": [
   "curl/8.6.0"
  ],
  "X-Envoy-Attempt-Count": [
   "1"
  ],
  "X-Envoy-External-Address": [
   "192.168.130.1"
  ],
  "X-Forwarded-Client-Cert": [
   "By=spiffe://cluster.local/ns/golang-ex/sa/golang-ex;Hash=9485cb2db91e3d97f0d5a4ad4893490fb3d97de7de91c4f9e8431ad70c1f3f9c;Subject=\"\";URI=spiffe://cluster.local/ns/istio-ingress/sa/istio-ingressgateway"
  ],
  "X-Forwarded-For": [
   "192.168.130.1,10.217.0.2"
  ],
  "X-Forwarded-Host": [
   "golang-ex-edge-istio-ingress.apps-crc.testing"
  ],
  "X-Forwarded-Port": [
   "443"
  ],
  "X-Forwarded-Proto": [
   "https"
  ],
  "X-Request-Id": [
   "6965ab38-54da-9c39-84ae-29464b4e6c47"
  ]
 },
 "ResponseHeaders": {
  "ETag": [
   "W/\"0815\""
  ],
  "Set-Cookie": [
   "id=a3fWa; Max-Age=2592000",
   "id=b3fWa; Max-Age=3592000"
  ],
  "Test": [
   "test"
  ],
  "X-Content-Type-Options": [
   ""
  ],
  "X-Powered-By": [
   "Go"
  ],
  "X-XSS-Protection": [
   "0"
  ]
 },
 "Status": "Returned headers from the RESPONSE_HEADERS environment variable.",
 "Error": "",
 "Usage": "Usage: Set the RESPONSE_HEADERS environment variable to always return custom response headers for a GET request, else static default headers will be returned. Alternatively, send a POST or PUT request with the headers you want returned. Example: curl -i -X POST localhost:8080 -d '{\"k1\":[\"v1\"],\"k2\":[\"v3\",\"v4\"]}'"
}
```

```logs
[2025-02-08T00:14:22.582Z] "GET / HTTP/1.1" 200 - via_upstream - "-" 0 1651 3 3 "192.168.130.1,10.217.0.2" "curl/8.6.0" "6965ab38-54da-9c39-84ae-29464b4e6c47" "golang-ex-edge-istio-ingress.apps-crc.testing" "10.217.0.203:8080" outbound|8080||golang-ex-featurea.golang-ex.svc.cluster.local 10.217.1.78:50610 10.217.1.78:8080 192.168.130.1:0 - -
2025-02-08T00:15:19.831579Z debug envoy rbac external/envoy/source/extensions/filters/http/rbac/rbac_filter.cc:114 checking request: requestedServerName: , sourceIP: 10.217.0.2:48052, directRemoteIP: 10.217.0.2:48052, remoteIP: 192.168.130.1:0,localAddress: 10.217.1.78:8080, ssl: none, headers: ':authority', 'golang-ex-edge-istio-ingress.apps-crc.testing'
':path', '/'
':method', 'GET'
':scheme', 'https'
'user-agent', 'curl/8.6.0'
'accept', '*/*'
'x-forwarded-for', '192.168.130.1,10.217.0.2'
'x-forwarded-host', 'golang-ex-edge-istio-ingress.apps-crc.testing'
'x-forwarded-port', '443'
'x-forwarded-proto', 'https'
'forwarded', 'for=192.168.130.1;host=golang-ex-edge-istio-ingress.apps-crc.testing;proto=https'
'x-envoy-external-address', '192.168.130.1'
'x-request-id', '8cfe2b8f-794c-9423-99c9-65a75c407b2b'
'x-envoy-decorator-operation', 'golang-ex-featurea.golang-ex.svc.cluster.local:8080/*'
'x-envoy-peer-metadata-id', 'router~10.217.1.78~istio-ingressgateway-6c8698fd8c-qhltc.istio-ingress~istio-ingress.svc.cluster.local'
'x-envoy-peer-metadata', 'ChQKDkFQUF9DT05UQUlORVJTEgIaAAoaCgpDTFVTVEVSX0lEEgwaCkt1YmVybmV0ZXMKHQoMSU5TVEFOQ0VfSVBTEg0aCzEwLjIxNy4xLjc4ChkKDUlTVElPX1ZFUlNJT04SCBoGMS4yMC44CpYCCgZMQUJFTFMSiwIqiAIKHQoDYXBwEhYaFGlzdGlvLWluZ3Jlc3NnYXRld2F5ChkKBWlzdGlvEhAaDmluZ3Jlc3NnYXRld2F5ChoKD21haXN0cmEtdmVyc2lvbhIHGgUyLjYuNQohChdtYWlzdHJhLmlvL2V4cG9zZS1yb3V0ZRIGGgR0cnVlCjkKH3NlcnZpY2UuaXN0aW8uaW8vY2Fub25pY2FsLW5hbWUSFhoUaXN0aW8taW5ncmVzc2dhdGV3YXkKLwojc2VydmljZS5pc3Rpby5pby9jYW5vbmljYWwtcmV2aXNpb24SCBoGbGF0ZXN0CiEKF3NpZGVjYXIuaXN0aW8uaW8vaW5qZWN0EgYaBHRydWUKGgoHTUVTSF9JRBIPGg1jbHVzdGVyLmxvY2FsCi8KBE5BTUUSJxolaXN0aW8taW5ncmVzc2dhdGV3YXktNmM4Njk4ZmQ4Yy1xaGx0YwocCglOQU1FU1BBQ0USDxoNaXN0aW8taW5ncmVzcwpeCgVPV05FUhJVGlNrdWJlcm5ldGVzOi8vYXBpcy9hcHBzL3YxL25hbWVzcGFjZXMvaXN0aW8taW5ncmVzcy9kZXBsb3ltZW50cy9pc3Rpby1pbmdyZXNzZ2F0ZXdheQonCg1XT1JLTE9BRF9OQU1FEhYaFGlzdGlvLWluZ3Jlc3NnYXRld2F5'
, dynamicMetadata: thread=21
2025-02-08T00:15:19.831860Z debug envoy rbac external/envoy/source/extensions/filters/http/rbac/rbac_filter.cc:154 enforced allowed, matched policy ns[istio-ingress]-policy[allowed-ips]-rule[0] thread=21
```
