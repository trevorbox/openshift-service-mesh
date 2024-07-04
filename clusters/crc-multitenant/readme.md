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