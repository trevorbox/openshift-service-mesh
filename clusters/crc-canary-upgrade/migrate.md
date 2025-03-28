# Migrate gateways from ossm 2 to 3

This process describes using ossm2 for just managing gateway pods (NO sidecars in applications), deploying new ossm3 gateways, changing the OCP routes to point to the new ossm3 gateway pods.
With this approach the pods can be restarted to get the ossm3 sidecar injected into application pods without outage. 
After all gateways are migrated, ocp routes are switched and applications have been restarted with the sidecars inject, mtls can be required.

> Note that if two control planes can discover the same namespace they will both update the istio-ca-root-cert configmap. We could maintain a serviceentry instead for ossm2 and keep namespace discovery separate. It should be possible for two control planes to discover the same namespace so long as no injection is allowed (meaning we need to keep istio-injection: disabled on the namespace). Both control planes need to use the same istio-ca-secret, otherwise they will both constanly update it in discovered namespaces. We may want this so that both control planes can discover Istio objects in tenant namespaces. Only when ossm2 is uninstalled do we enable injection (so that there aren't multiple mutating webhooks for the same namespace for injection).

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
gnome-terminal -- bash -c "siege -q -j https://spring-boot-demo2-istio-ingress3.apps-crc.testing/; exec bash"
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

## Verify the sidecar can be autoinjected (from ossm3) if the pod restarted without outage. 

since mtls is not enforced there is no outage. ossm2 gateway can still talk to pod with ossm3 sidecar

```sh
tbox@fedora:~/git/trevorbox/openshift-service-mesh$ oc get pods -n spring-boot-demo2
NAME                                 READY   STATUS    RESTARTS   AGE
spring-boot-demo2-664c6cc5d6-4lsq7   1/1     Running   0          8m19s
```

rollout the application and it will get the new sidecar from ossm3 control plane

```sh
tbox@fedora:~/git/trevorbox/openshift-service-mesh$ oc rollout restart deploy -n spring-boot-demo2
deployment.apps/spring-boot-demo2 restarted
tbox@fedora:~/git/trevorbox/openshift-service-mesh$ oc get pods -n spring-boot-demo2
NAME                                 READY   STATUS        RESTARTS   AGE
spring-boot-demo2-5c5bdc68f4-pk9dn   2/2     Running       0          25s
spring-boot-demo2-664c6cc5d6-4lsq7   1/1     Terminating   0          9m38s
```

Siege is still running so no outage...

When all the gateways are migrated, we can require mtls mesh-wide by simply changing the peerauthnetication and default destination rule in istio-system.

Final step is delete the istio-ingress, istio-system, and remove the service mesh oprator.




# try canary upgrades in same namespaces

> 01/22/25

Deploy the ossm3 control plane in same namespace as ossm2 (istio-system) and then rollout pods in istio-ingress and application namespace after changing the istio.io/rev namespace label. What is good about this is mTLS is also working.

> TODO Kiali v1.73 with clusterwide access show the below logs (has some config behavior errors during testing)

kiali logs...
```log
2025-01-22T11:30:54Z DBG Found controlplane [istiod/istio-system] on cluster [Kubernetes].
2025-01-22T11:30:54Z DBG Found controlplane [istiod-ossm2/istio-system] on cluster [Kubernetes].
```

Notes...
- For ossm3, the name of the istio CR (in my case "default") is what informs the mutatingwebhookconfiguration label matching logic.
- For ossm2, the ServiceMeshMemberRoll is what informs the mutatingwebhookconfiguration label matching logic.
- Both ossm2 and ossm3 can discover the same namespace (I match discovery on the Existance of a label key `istio.io/rev`)
- If two control planes can discover the same namespace, they will both update the istio-ca-root-cert configmap, which means they both should use the same rootca secret (we accomplish this by deploying both control planes in the same namespace, istio-system). I assume an intermediary ca that shares the same root ca could be used, but not necessary in my case.
- We need to maintain our own networkpolicies to permit ingress, since ossm2 will create these (and thus restrict things). I used `allow-any-istio-rev` and `allow-istio-system`. These networkpolicies are placed in ingress, and app namespaces. and the istio-system namespace needs the `allow-any-istio-rev` networkpolicy.
- We need to be able to upgrade the gateways separately form the dataplane and vice-versa.

```sh
tbox@fedora:~/git/trevorbox/openshift-service-mesh$ istioctl ps
NAME                                                       CLUSTER        CDS        LDS        EDS        RDS        ECDS         ISTIOD                           VERSION
cryostat-788449649b-mscfc.cryostat                         Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-ossm2-5d9df5dbc-59cpg     1.20.8
istio-ingressgateway-565f945765-qlpxj.istio-ingress        Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-ossm2-5d9df5dbc-59cpg     1.20.8
nginx-echo-headers-6db87c9dcb-lxbqb.nginx-echo-headers     Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-546bfdb64c-pgx84          1.23.0
spring-boot-demo-548b58675f-rnvq7.spring-boot-demo         Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-546bfdb64c-pgx84          1.23.0
spring-boot-demo-548b58675f-sfc6l.spring-boot-demo         Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-546bfdb64c-pgx84          1.23.0
spring-boot-demo-548b58675f-tgmrb.spring-boot-demo         Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-546bfdb64c-pgx84          1.23.0
spring-boot-demo2-664c6cc5d6-5pzxj.spring-boot-demo2       Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-ossm2-5d9df5dbc-7v5cz     1.20.8
```

start siege

```sh
gnome-terminal -- bash -c "siege -q -j https://spring-boot-demo2-istio-ingress.apps-crc.testing/; exec bash"
```

change the label in components/istio-member-namepsaces/values.yaml from istio.io/rev: ossm2 to istio.io/rev: default

```yaml
members:
  - istio-ingress
  - golang-ex
  - bookinfo
  - nginx-echo-headers
  - spring-boot-demo
  - spring-boot-demo2
labels:
  # istio.io/rev: ossm2
  istio.io/rev: default
  argocd.argoproj.io/managed-by: openshift-gitops
annotations:
  argocd.argoproj.io/sync-options: Delete=false 
smcp:
  name: ossm2
  namespace: istio-system

```

```sh
tbox@fedora:~/git/trevorbox/openshift-service-mesh$ git commit -am "flip to new istio revision default"
[main e305bdb] flip to new istio revision default
 2 files changed, 47 insertions(+), 2 deletions(-)
tbox@fedora:~/git/trevorbox/openshift-service-mesh$ git push
```

```sh
oc rollout restart deploy -n istio-ingress
tbox@fedora:~/git/trevorbox/openshift-service-mesh$ istioctl ps
NAME                                                       CLUSTER        CDS        LDS        EDS        RDS        ECDS         ISTIOD                           VERSION
cryostat-788449649b-mscfc.cryostat                         Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-ossm2-5d9df5dbc-59cpg     1.20.8
istio-ingressgateway-75f668975-sz67g.istio-ingress         Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-546bfdb64c-pgx84          1.23.0
nginx-echo-headers-6db87c9dcb-lxbqb.nginx-echo-headers     Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-546bfdb64c-pgx84          1.23.0
spring-boot-demo-548b58675f-rnvq7.spring-boot-demo         Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-546bfdb64c-pgx84          1.23.0
spring-boot-demo-548b58675f-sfc6l.spring-boot-demo         Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-546bfdb64c-pgx84          1.23.0
spring-boot-demo-548b58675f-tgmrb.spring-boot-demo         Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-546bfdb64c-pgx84          1.23.0
spring-boot-demo2-664c6cc5d6-5pzxj.spring-boot-demo2       Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-ossm2-5d9df5dbc-7v5cz     1.20.8
```

```sh
tbox@fedora:~/git/trevorbox/openshift-service-mesh$ oc rollout restart deploy -n spring-boot-demo2
deployment.apps/spring-boot-demo2 restarted
tbox@fedora:~/git/trevorbox/openshift-service-mesh$ istioctl ps
NAME                                                       CLUSTER        CDS        LDS        EDS        RDS        ECDS         ISTIOD                           VERSION
cryostat-788449649b-mscfc.cryostat                         Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-ossm2-5d9df5dbc-59cpg     1.20.8
istio-ingressgateway-78cdb4984c-xpc57.istio-ingress        Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-546bfdb64c-pgx84          1.23.0
nginx-echo-headers-6db87c9dcb-lxbqb.nginx-echo-headers     Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-546bfdb64c-pgx84          1.23.0
spring-boot-demo-548b58675f-rnvq7.spring-boot-demo         Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-546bfdb64c-pgx84          1.23.0
spring-boot-demo-548b58675f-sfc6l.spring-boot-demo         Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-546bfdb64c-pgx84          1.23.0
spring-boot-demo-548b58675f-tgmrb.spring-boot-demo         Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-546bfdb64c-pgx84          1.23.0
spring-boot-demo2-7ff46bf96-qgk8c.spring-boot-demo2        Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-546bfdb64c-pgx84          1.23.0
```

stop siege, show results

```sh
{
	"transactions":			      222968,
	"availability":			      100.00,
	"elapsed_time":			      453.21,
	"data_transferred":		        8.29,
	"response_time":		        0.05,
	"transaction_rate":		      491.98,
	"throughput":			        0.02,
	"concurrency":			       24.93,
	"successful_transactions":	      222968,
	"failed_transactions":		           0,
	"longest_transaction":		        0.61,
	"shortest_transaction":		        0.00
}
```


## final steps

<https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.0/html/migrating_from_service_mesh_2_to_service_mesh_3/completing-the-migration#ossm-migrating-complete-remove-2-6-operator-crds_ossm-migrating-complete>

```sh
oc get smcp,smm,smmr -A # Expect No resources found
# cleanly delete the service-mesh-operator app from argo
oc get crds -o name | grep ".*\.maistra\.io" | xargs -r -n 1 oc delete
```

results:

```sh
tbox@fedora:~/.local/bin$ siege -q -j https://spring-boot-demo-istio-ingress.apps-crc.testing/
^C
{
	"transactions":			      348411,
	"availability":			       99.94,
	"elapsed_time":			     1041.44,
	"data_transferred":		       12.99,
	"response_time":		        0.07,
	"transaction_rate":		      334.55,
	"throughput":			        0.01,
	"concurrency":			       24.94,
	"successful_transactions":	      348411,
	"failed_transactions":		         195,
	"longest_transaction":		        2.87,
	"shortest_transaction":		        0.00
}
```

```sh
oc rollout restart deploy -n oauth2-proxy
oc rollout restart deploy -n spring-boot-demo
oc rollout restart deploy -n bookinfo
oc rollout restart deploy -n istio-ingress
```