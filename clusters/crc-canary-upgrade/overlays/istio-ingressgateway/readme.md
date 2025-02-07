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

Since this is a passthrough route, haproxy would not change any encrypted info.


Try Edge and replace the forwarded-headers maybe that will add the source IP im looking for

https://docs.openshift.com/container-platform/4.16/networking/routes/route-configuration.html

haproxy.router.openshift.io/set-forwarded-headers: replace