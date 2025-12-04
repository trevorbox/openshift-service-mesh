
# issue-ambient when crc start up

Previously deployed crc-ambient (synced via gitops in crc cluster) See https://github.com/trevorbox/openshift-service-mesh

```sh
tbox@fedora:~$ crc status
CRC VM:          Running
OpenShift:       Running (v4.20.1)
RAM Usage:       20.32GB of 41.12GB
Disk Usage:      64.98GB of 321.5GB (Inside the CRC VM)
Cache Usage:     94.58GB
Cache Directory: /home/tbox/.crc/cache
tbox@fedora:~$ oc version
Client Version: 4.19.13
Kustomize Version: v5.5.0
Server Version: 4.20.1
Kubernetes Version: v1.33.5
tbox@fedora:~$ oc get istio
NAME      NAMESPACE      PROFILE   REVISIONS   READY   IN USE   ACTIVE REVISION   STATUS    VERSION   AGE
default   istio-system   ambient   1           1       1        default-v1-27-3   Healthy   v1.27.3   8d
tbox@fedora:~$ istioctl -n ztunnel ztunnel-config workloads
NAMESPACE          POD NAME                                ADDRESS                                                  NODE WAYPOINT PROTOCOL
bookinfo           details-v1-6df5746fc9-vdmqd             10.217.0.147                                             crc  None     HBONE
bookinfo           productpage-v1-b58bcfb87-5s6d5          10.217.0.151                                             crc  None     HBONE
bookinfo           ratings-v1-fc68795ff-kq2td              10.217.0.149                                             crc  None     HBONE
bookinfo           reviews-v1-75d9c8ff69-f6fzl             10.217.0.150                                             crc  None     HBONE
bookinfo           reviews-v2-557b57b485-69bdw             10.217.0.148                                             crc  None     HBONE
bookinfo           reviews-v3-7cb45d5c45-9855z             10.217.0.152                                             crc  None     HBONE
golang-ex          golang-ex-featurea-54cb557c6d-p8cjk     10.217.0.146                                             crc  None     HBONE
golang-ex          golang-ex-high-586fb56f68-6lrth         10.217.0.144                                             crc  None     HBONE
golang-ex          golang-ex-stable-b64c9cc76-fvz7q        10.217.0.145                                             crc  None     HBONE
httpbin            httpbin-5c6c796d88-h92h5                10.217.0.173                                             crc  None     HBONE
httpbin            httpbin-gateway-istio-5fc77854fd-h7p62  10.217.0.175                                             crc  None     TCP
httpbin            httpbin-waypoint-6ff8c546b9-j9ck2       10.217.0.174                                             crc  None     TCP
istio-ingress      istio-ingressgateway-9f566cd95-hqwql    10.217.0.104                                             crc  None     TCP
istio-system       istiod-default-v1-27-3-784c4874f5-zbx44 10.217.0.181                                             crc  None     TCP
istio-system       kube-api                                kubernetes.default.svc.cluster.local                          None     TCP
istio-system       otel-collector                          otel-collector.opentelemetry-collector.svc.cluster.local      None     TCP
nginx-echo-headers nginx-echo-headers-6b6fb66f78-nh4kk     10.217.0.143                                             crc  None     HBONE
sample             curl-88cc4ff69-dsk2k                    10.217.0.142                                             crc  None     HBONE
sample             helloworld-v1-7985d797bd-q7qkm          10.217.0.141                                             crc  None     HBONE
ztunnel            ztunnel-cf8mb                           10.217.0.178                                             crc  None     TCP
tbox@fedora:~$ oc get routes -n istio-ingress
NAME                 HOST/PORT                                           PATH   SERVICES               PORT    TERMINATION            WILDCARD
bookinfo             bookinfo-istio-ingress.apps-crc.testing                    istio-ingressgateway   https   passthrough/Redirect   None
golang-ex-edge       golang-ex-edge-istio-ingress.apps-crc.testing              istio-ingressgateway   http2   edge/Redirect          None
golang-ex-featurea   golang-ex-featurea-istio-ingress.apps-crc.testing          istio-ingressgateway   https   passthrough/Redirect   None
golang-ex-high       golang-ex-high-istio-ingress.apps-crc.testing              istio-ingressgateway   https   passthrough/Redirect   None
golang-ex-stable     golang-ex-stable-istio-ingress.apps-crc.testing            istio-ingressgateway   https   passthrough/Redirect   None
nginx-echo-headers   nginx-echo-headers-istio-ingress.apps-crc.testing          istio-ingressgateway   https   passthrough/Redirect   None
tbox@fedora:~$ curl -k https://bookinfo-istio-ingress.apps-crc.testing/productpage
upstream connect error or disconnect/reset before headers. reset reason: connection terminationtbox@fedora:~$ 
tbox@fedora:~$ oc get service -n httpbin
NAME                    TYPE           CLUSTER-IP     EXTERNAL-IP       PORT(S)                        AGE
httpbin                 ClusterIP      10.217.4.54    <none>            8000/TCP                       8d
httpbin-gateway-istio   LoadBalancer   10.217.5.140   192.168.130.200   15021:30962/TCP,80:31754/TCP   8d
httpbin-waypoint        ClusterIP      10.217.4.179   <none>            15021/TCP,15008/TCP            8d
tbox@fedora:~$ curl -i -v -H Host:httpbin.example.com http://192.168.130.200:80/headers
*   Trying 192.168.130.200:80...
* Connected to 192.168.130.200 (192.168.130.200) port 80
* using HTTP/1.x
> GET /headers HTTP/1.1
> Host:httpbin.example.com
> User-Agent: curl/8.11.1
> Accept: */*
> 
* Request completely sent off
< HTTP/1.1 503 Service Unavailable
HTTP/1.1 503 Service Unavailable
< content-length: 95
content-length: 95
< content-type: text/plain
content-type: text/plain
< date: Thu, 04 Dec 2025 17:11:33 GMT
date: Thu, 04 Dec 2025 17:11:33 GMT
< server: istio-envoy
server: istio-envoy
< x-envoy-upstream-service-time: 10014
x-envoy-upstream-service-time: 10014
< 

* Connection #0 to host 192.168.130.200 left intact
upstream connect error or disconnect/reset before headers. reset reason: connection terminationtbox@fedora:~$ 
```

So the route does not work and the httpbin gateway does not work. 

After we relabel the namespaces then they start to work.

```sh
tbox@fedora:~$ oc label namespace httpbin istio.io/dataplane-mode-
namespace/httpbin unlabeled
tbox@fedora:~$ oc label namespace httpbin istio.io/dataplane-mode=ambient
namespace/httpbin labeled
tbox@fedora:~$ istioctl -n ztunnel ztunnel-config workloads
NAMESPACE          POD NAME                                ADDRESS                                                  NODE WAYPOINT PROTOCOL
bookinfo           details-v1-6df5746fc9-vdmqd             10.217.0.147                                             crc  None     HBONE
bookinfo           productpage-v1-b58bcfb87-5s6d5          10.217.0.151                                             crc  None     HBONE
bookinfo           ratings-v1-fc68795ff-kq2td              10.217.0.149                                             crc  None     HBONE
bookinfo           reviews-v1-75d9c8ff69-f6fzl             10.217.0.150                                             crc  None     HBONE
bookinfo           reviews-v2-557b57b485-69bdw             10.217.0.148                                             crc  None     HBONE
bookinfo           reviews-v3-7cb45d5c45-9855z             10.217.0.152                                             crc  None     HBONE
golang-ex          golang-ex-featurea-54cb557c6d-p8cjk     10.217.0.146                                             crc  None     HBONE
golang-ex          golang-ex-high-586fb56f68-6lrth         10.217.0.144                                             crc  None     HBONE
golang-ex          golang-ex-stable-b64c9cc76-fvz7q        10.217.0.145                                             crc  None     HBONE
httpbin            httpbin-5c6c796d88-h92h5                10.217.0.173                                             crc  None     HBONE
httpbin            httpbin-gateway-istio-5fc77854fd-h7p62  10.217.0.175                                             crc  None     TCP
httpbin            httpbin-waypoint-6ff8c546b9-j9ck2       10.217.0.174                                             crc  None     TCP
istio-ingress      istio-ingressgateway-9f566cd95-hqwql    10.217.0.104                                             crc  None     TCP
istio-system       istiod-default-v1-27-3-784c4874f5-zbx44 10.217.0.181                                             crc  None     TCP
istio-system       kube-api                                kubernetes.default.svc.cluster.local                          None     TCP
istio-system       otel-collector                          otel-collector.opentelemetry-collector.svc.cluster.local      None     TCP
nginx-echo-headers nginx-echo-headers-6b6fb66f78-nh4kk     10.217.0.143                                             crc  None     HBONE
sample             curl-88cc4ff69-dsk2k                    10.217.0.142                                             crc  None     HBONE
sample             helloworld-v1-7985d797bd-q7qkm          10.217.0.141                                             crc  None     HBONE
ztunnel            ztunnel-cf8mb                           10.217.0.178                                             crc  None     TCP
tbox@fedora:~$ curl -i -v -H Host:httpbin.example.com http://192.168.130.200:80/headers
*   Trying 192.168.130.200:80...
* Connected to 192.168.130.200 (192.168.130.200) port 80
* using HTTP/1.x
> GET /headers HTTP/1.1
> Host:httpbin.example.com
> User-Agent: curl/8.11.1
> Accept: */*
> 
* Request completely sent off
< HTTP/1.1 200 OK
HTTP/1.1 200 OK
< access-control-allow-credentials: true
access-control-allow-credentials: true
< access-control-allow-origin: *
access-control-allow-origin: *
< content-type: application/json; charset=utf-8
content-type: application/json; charset=utf-8
< date: Thu, 04 Dec 2025 17:13:39 GMT
date: Thu, 04 Dec 2025 17:13:39 GMT
< content-length: 561
content-length: 561
< x-envoy-upstream-service-time: 6
x-envoy-upstream-service-time: 6
< server: istio-envoy
server: istio-envoy
< 

{
  "headers": {
    "Accept": [
      "*/*"
    ],
    "Host": [
      "httpbin.example.com"
    ],
    "Traceparent": [
      "00-538371b4358bf1efa8b2567ed2e82e6d-739baa4edb00b9c6-01"
    ],
    "Tracestate": [
      ""
    ],
    "User-Agent": [
      "curl/8.11.1"
    ],
    "X-Envoy-Attempt-Count": [
      "1"
    ],
    "X-Envoy-External-Address": [
      "100.64.0.2"
    ],
    "X-Forwarded-For": [
      "100.64.0.2"
    ],
    "X-Forwarded-Proto": [
      "http"
    ],
    "X-Request-Id": [
      "ad45f2bf-387d-94a3-bda6-d96511c5e0df"
    ]
  }
}
* Connection #0 to host 192.168.130.200 left intact
tbox@fedora:~$ oc label namespace bookinfo istio.io/dataplane-mode-
namespace/bookinfo unlabeled
tbox@fedora:~$ oc label namespace bookinfo istio.io/dataplane-mode=ambient
namespace/bookinfo not labeled
tbox@fedora:~$ curl -k https://bookinfo-istio-ingress.apps-crc.testing/productpage
<!DOCTYPE html>
<html>
  <head>
    <title>Simple Bookstore App</title>
<meta charset="utf-8">
<meta http-equiv="X-UA-Compatible" content="IE=edge">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
...
```
