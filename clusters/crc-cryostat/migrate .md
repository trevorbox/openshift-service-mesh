# Migrate gateways from ossm 2 to 3

```sh
echo "istio-system Before"... > migrate.log
istioctl -i istio-system ps >> migrate.log
echo "istio-system3 Before"... >> migrate.log
istioctl -i istio-system3 ps >> migrate.log
```

```sh
tbox@fedora:~/git/trevorbox/openshift-service-mesh$ cat migrate.log 
istio-system Before...
NAME                                                       CLUSTER        CDS        LDS        EDS        RDS        ECDS         ISTIOD                           VERSION
cryostat-788449649b-7vpqj.cryostat                         Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-ossm2-5d9df5dbc-w2gjv     1.20.8
istio-ingressgateway-565f945765-7x2nk.istio-ingress        Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-ossm2-5d9df5dbc-w2gjv     1.20.8
nginx-echo-headers-6db87c9dcb-vvgv5.nginx-echo-headers     Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-ossm2-5d9df5dbc-qqt26     1.20.8
spring-boot-demo-548b58675f-2kz8b.spring-boot-demo         Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-ossm2-5d9df5dbc-w2gjv     1.20.8
spring-boot-demo-548b58675f-69x9x.spring-boot-demo         Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-ossm2-5d9df5dbc-w2gjv     1.20.8
spring-boot-demo-548b58675f-rvp7f.spring-boot-demo         Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-ossm2-5d9df5dbc-qqt26     1.20.8
istio-system3 Before...
NAME                                                     CLUSTER        CDS        LDS        EDS        RDS        ECDS         ISTIOD                     VERSION
istio-ingressgateway-565f945765-w2x65.istio-ingress3     Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-5458cc5fd-bbnwg     1.23.0
```

## start siege
```sh
gnome-terminal -- bash -c "siege -q -j https://spring-boot-demo2-istio-ingress.apps-crc.testing/; exec bash"
gnome-terminal -- bash -c "oc logs -f deploy/istio-ingressgateway --tail=4 -n istio-ingress > istio-ingress.log; exec bash"
gnome-terminal -- bash -c "oc logs -f deploy/istio-ingressgateway --tail=4 -n istio-ingress3 > istio-ingress3.log; exec bash"
```

## edit the route in components/spring-boot-2/istio-configs.yaml to deploy to the istio-ingress3 namespace instead of istio-ingress

```sh
vim components/spring-boot-demo2/istio-configs.yaml
```

## Make argocd sync.

If argo syncs and doesnt have autoprune the new route will have a host conflict and won't be admitted. As soon are the old resource is pruned, traffic is shifted to new ossm 3 gateway using the same dns.

## stop the siege window

use control-c and view the results (no outage).

results from `siege -q -j https://spring-boot-demo2-istio-ingress.apps-crc.testing/`

```sh
{
	"transactions":			       35686,
	"availability":			      100.00,
	"elapsed_time":			       67.74,
	"data_transferred":		        1.33,
	"response_time":		        0.05,
	"transaction_rate":		      526.81,
	"throughput":			        0.02,
	"concurrency":			       24.91,
	"successful_transactions":	       35686,
	"failed_transactions":		           0,
	"longest_transaction":		        0.41,
	"shortest_transaction":		        0.00
}
```

gateway access logs (see timestamps)

```sh
tbox@fedora:~/git/trevorbox/openshift-service-mesh$ tail -4 istio-ingress.log 
[2025-01-16T22:56:50.561Z] "GET / HTTP/1.1" 200 - via_upstream - "-" 0 39 13 12 "10.217.0.2" "Mozilla/5.0 (redhat-x86_64-linux-gnu) Siege/4.1.6" "7a346fc1-096a-9baf-8920-47ffa54371e3" "spring-boot-demo2-istio-ingress.apps-crc.testing" "10.217.0.180:8080" outbound|8080||spring-boot-demo2.spring-boot-demo2.svc.cluster.local 10.217.1.6:59658 10.217.1.6:8443 10.217.0.2:41594 spring-boot-demo2-istio-ingress.apps-crc.testing -
[2025-01-16T22:56:50.568Z] "GET / HTTP/1.1" 200 - via_upstream - "-" 0 39 19 19 "10.217.0.2" "Mozilla/5.0 (redhat-x86_64-linux-gnu) Siege/4.1.6" "41903d89-1b5a-9150-b978-c51c0322edae" "spring-boot-demo2-istio-ingress.apps-crc.testing" "10.217.0.180:8080" outbound|8080||spring-boot-demo2.spring-boot-demo2.svc.cluster.local 10.217.1.6:50920 10.217.1.6:8443 10.217.0.2:41602 spring-boot-demo2-istio-ingress.apps-crc.testing -
[2025-01-16T22:56:50.569Z] "GET / HTTP/1.1" 200 - via_upstream - "-" 0 39 18 18 "10.217.0.2" "Mozilla/5.0 (redhat-x86_64-linux-gnu) Siege/4.1.6" "f297ea09-95ff-9472-aa5e-137c763bc65a" "spring-boot-demo2-istio-ingress.apps-crc.testing" "10.217.0.180:8080" outbound|8080||spring-boot-demo2.spring-boot-demo2.svc.cluster.local 10.217.1.6:51006 10.217.1.6:8443 10.217.0.2:41604 spring-boot-demo2-istio-ingress.apps-crc.testing -
[2025-01-16T22:56:50.572Z] "GET / HTTP/1.1" 200 - via_upstream - "-" 0 39 15 15 "10.217.0.2" "Mozilla/5.0 (redhat-x86_64-linux-gnu) Siege/4.1.6" "b7944a17-a196-9a01-b3f1-be72c13f21c2" "spring-boot-demo2-istio-ingress.apps-crc.testing" "10.217.0.180:8080" outbound|8080||spring-boot-demo2.spring-boot-demo2.svc.cluster.local 10.217.1.6:50864 10.217.1.6:8443 10.217.0.2:41610 spring-boot-demo2-istio-ingress.apps-crc.testing -
tbox@fedora:~/git/trevorbox/openshift-service-mesh$ head -8 istio-ingress3.log 
2025-01-16T22:54:55.762454Z     info    cache   returned workload trust anchor from cache       ttl=23h59m59.237547964s
2025-01-16T22:54:55.762650Z     info    cache   returned workload trust anchor from cache       ttl=23h59m59.237351552s
2025-01-16T22:54:56.884798Z     info    Readiness succeeded in 1.562764415s
2025-01-16T22:54:56.885399Z     info    Envoy proxy is ready
[2025-01-16T22:56:50.544Z] "GET / HTTP/1.1" 200 - via_upstream - "-" 0 39 4 2 "10.217.0.2" "Mozilla/5.0 (redhat-x86_64-linux-gnu) Siege/4.1.6" "72cb36e3-b4d7-4e15-8e4c-a11b80d62b32" "spring-boot-demo2-istio-ingress.apps-crc.testing" "10.217.0.180:8080" outbound|8080||spring-boot-demo2.spring-boot-demo2.svc.cluster.local 10.217.1.5:51506 10.217.1.5:8443 10.217.0.2:40610 spring-boot-demo2-istio-ingress.apps-crc.testing -
[2025-01-16T22:56:50.547Z] "GET / HTTP/1.1" 200 - via_upstream - "-" 0 39 3 3 "10.217.0.2" "Mozilla/5.0 (redhat-x86_64-linux-gnu) Siege/4.1.6" "76633aa9-6a29-4a88-8c11-fab6d9f783c4" "spring-boot-demo2-istio-ingress.apps-crc.testing" "10.217.0.180:8080" outbound|8080||spring-boot-demo2.spring-boot-demo2.svc.cluster.local 10.217.1.5:51512 10.217.1.5:8443 10.217.0.2:40618 spring-boot-demo2-istio-ingress.apps-crc.testing -
[2025-01-16T22:56:50.563Z] "GET / HTTP/1.1" 200 - via_upstream - "-" 0 39 7 6 "10.217.0.2" "Mozilla/5.0 (redhat-x86_64-linux-gnu) Siege/4.1.6" "f7d04eae-1324-4067-b1a0-b352977d8ee8" "spring-boot-demo2-istio-ingress.apps-crc.testing" "10.217.0.180:8080" outbound|8080||spring-boot-demo2.spring-boot-demo2.svc.cluster.local 10.217.1.5:51516 10.217.1.5:8443 10.217.0.2:40640 spring-boot-demo2-istio-ingress.apps-crc.testing -
[2025-01-16T22:56:50.557Z] "GET / HTTP/1.1" 200 - via_upstream - "-" 0 39 15 15 "10.217.0.2" "Mozilla/5.0 (redhat-x86_64-linux-gnu) Siege/4.1.6" "f3b90ef8-4a22-4d1e-9ec5-daa0c4a55650" "spring-boot-demo2-istio-ingress.apps-crc.testing" "10.217.0.180:8080" outbound|8080||spring-boot-demo2.spring-boot-demo2.svc.cluster.local 10.217.1.5:51512 10.217.1.5:8443 10.217.0.2:40620 spring-boot-demo2-istio-ingress.apps-crc.testing -
```