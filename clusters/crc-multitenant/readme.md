```sh
[tbox@fedora openshift-service-mesh]$ istioctl ps -i istio-system
NAME                                                      CLUSTER        CDS        LDS        EDS        RDS        ECDS         ISTIOD                               VERSION
details-v1-54445495c5-stjc4.bookinfo                      Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-ossm-2-4-7fb98774d4-bzgn6     1.16.7
golang-ex-featurea-66456c7d9c-rvxwl.golang-ex             Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-ossm-2-4-7fb98774d4-bzgn6     1.16.7
golang-ex-high-59798d676c-m8prt.golang-ex                 Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-ossm-2-4-7fb98774d4-bzgn6     1.16.7
golang-ex-stable-588f78f6b5-svtvv.golang-ex               Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-ossm-2-4-7fb98774d4-bzgn6     1.16.7
istio-ingressgateway-5f5779b97f-w89wx.istio-ingress       Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-ossm-2-4-7fb98774d4-bzgn6     1.16.7
nginx-echo-headers-7bcf458fd-gtbnx.nginx-echo-headers     Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-ossm-2-4-7fb98774d4-bzgn6     1.16.7
productpage-v1-5f5cdbf975-7zsjn.bookinfo                  Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-ossm-2-4-7fb98774d4-bzgn6     1.16.7
ratings-v1-5d697c6fcf-qcbhp.bookinfo                      Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-ossm-2-4-7fb98774d4-bzgn6     1.16.7
reviews-v1-57ffbd4dd9-b9nz5.bookinfo                      Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-ossm-2-4-7fb98774d4-bzgn6     1.16.7
reviews-v2-6d755766c7-zhnfx.bookinfo                      Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-ossm-2-4-7fb98774d4-bzgn6     1.16.7
reviews-v3-5b74b7d897-m8tjj.bookinfo                      Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-ossm-2-4-7fb98774d4-bzgn6     1.16.7
[tbox@fedora openshift-service-mesh]$ istioctl ps -i istio-system-2-5
NAME     CLUSTER     CDS     LDS     EDS     RDS     ECDS     ISTIOD     VERSION
```

change the overlay path in values.yaml

```yaml
applications:
  istio-member-namespaces:
    annotations:
      argocd.argoproj.io/compare-options: IgnoreExtraneous
      argocd.argoproj.io/sync-wave: '1'
    destination:
      namespace: openshift-gitops
    source:
      # path: clusters/crc-multitenant/overlays/istio-member-namespaces
      path: clusters/crc-multitenant/overlays/istio-member-namespaces-2-5
```

```sh
oc rollout restart deployment -n istio-ingress
oc rollout restart deployment -n bookinfo
oc rollout restart deployment -n nginx-echo-headers
oc rollout restart deployment -n golang-ex
```

```sh
[tbox@fedora openshift-service-mesh]$ oc rollout restart deploy -n bookinfo
deployment.apps/details-v1 restarted
deployment.apps/productpage-v1 restarted
deployment.apps/ratings-v1 restarted
deployment.apps/reviews-v1 restarted
deployment.apps/reviews-v2 restarted
deployment.apps/reviews-v3 restarted
[tbox@fedora openshift-service-mesh]$ oc rollout restart deploy -n golang-ex
deployment.apps/golang-ex-featurea restarted
deployment.apps/golang-ex-high restarted
deployment.apps/golang-ex-stable restarted
[tbox@fedora openshift-service-mesh]$ istioctl ps -i istio-system
NAME                                                      CLUSTER        CDS        LDS        EDS        RDS        ECDS         ISTIOD                               VERSION
nginx-echo-headers-7bcf458fd-hxspt.nginx-echo-headers     Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-ossm-2-4-7fb98774d4-2ps92     1.16.7
[tbox@fedora openshift-service-mesh]$ istioctl ps -i istio-system-2-5
NAME                                                        CLUSTER        CDS        LDS        EDS        RDS        ECDS         ISTIOD                               VERSION
details-v1-74465cf9d7-kzs69.bookinfo                        Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-ossm-2-5-85b6d77d7c-r48mt     1.18.7
golang-ex-featurea-845c44d9bf-tjjpv.golang-ex               Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-ossm-2-5-85b6d77d7c-r48mt     1.18.7
golang-ex-high-5f45786ff5-6sk26.golang-ex                   Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-ossm-2-5-85b6d77d7c-r48mt     1.18.7
golang-ex-stable-54fbf5446f-jrmc4.golang-ex                 Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-ossm-2-5-85b6d77d7c-r48mt     1.18.7
istio-ingressgateway-5f5779b97f-z7llz.istio-ingress-2-5     Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-ossm-2-5-85b6d77d7c-r48mt     1.18.7
productpage-v1-695df497dc-fwzwh.bookinfo                    Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-ossm-2-5-85b6d77d7c-r48mt     1.18.7
ratings-v1-7d55f977c9-mqg2r.bookinfo                        Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-ossm-2-5-85b6d77d7c-r48mt     1.18.7
reviews-v1-64b7644685-7hgx6.bookinfo                        Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-ossm-2-5-85b6d77d7c-r48mt     1.18.7
reviews-v2-856cff8585-48dmn.bookinfo                        Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-ossm-2-5-85b6d77d7c-r48mt     1.18.7
reviews-v3-76bbdc8dcc-tzvmg.bookinfo                        Kubernetes     SYNCED     SYNCED     SYNCED     SYNCED     NOT SENT     istiod-ossm-2-5-85b6d77d7c-r48mt     1.18.7
[tbox@fedora openshift-service-mesh]$ istioctl ps -i istio-system
```