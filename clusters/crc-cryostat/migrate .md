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
gnome-terminal -- bash -c "siege https://spring-boot-demo2-istio-ingress.apps-crc.testing/; exec bash"
gnome-terminal -- bash -c "siege https://spring-boot-demo2-istio-ingress3.apps-crc.testing/; exec bash"
```

## edit the route in components/spring-boot-2/istio-configs.yaml to deploy to istio-ingress3 instead of istio-ingress
```sh
vim components/spring-boot-demo2/istio-configs.yaml
```

## Make argocd sync.

If argo syncs and doesnt have autoprune the new route will have a host conflict and won't be admitted. As soon are the old resource is pruned, traffic is shifted to new ossm 3 gateway using the same dns.

## stop the siege window

use control-c and view the results (no outage).

```sh
HTTP/1.1 200     0.06 secs:      39 bytes ==> GET  /
HTTP/1.1 200     0.07 secs:      39 bytes ==> GET  /
HTTP/1.1 200     0.06 secs:      39 bytes ==> GET  /
HTTP/1.1 200     0.06 secs:      39 bytes ==> GET  /
HTTP/1.1 200     0.08 secs:      39 bytes ==> GET  /
HTTP/1.1 200     0.07 secs:      39 bytes ==> GET  /
^C
Lifting the server siege...
Transactions:		       49589 hits
Availability:		      100.00 %
Elapsed time:		      176.75 secs
Data transferred:	        1.84 MB
Response time:		        0.09 secs
Transaction rate:	      280.56 trans/sec
Throughput:		        0.01 MB/sec
Concurrency:		       24.90
Successful transactions:       49589
Failed transactions:	           0
Longest transaction:	        0.49
Shortest transaction:	        0.01
```
