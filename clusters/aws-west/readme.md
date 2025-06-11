# notes

in east we simulate an external issuer by create a root-ca and two intermediary CAs (east-ca, west-ca) from ../../components/multi-cluster-certificates/

## manual steps

We need to add the generic secret to cert-manager <https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.0/html/installing/ossm-cert-manager>

```sh
#log into east cluster
oc get -n istio-system secret west-ca -o jsonpath='{.data.tls\.crt}' | base64 -d > ca.pem

oc get -n istio-system secret west-ca -oyaml > west-ca.yaml

#log into west cluster
oc create secret generic -n cert-manager istio-root-ca --from-file=ca.pem=ca.pem
oc create -f west-ca.yaml -n istio-system
```

# final steps kube api secrets

```sh
# log into east
export CTX_CLUSTER1=$(oc config current-context)
# log into west
export CTX_CLUSTER2=$(oc config current-context)

oc --context="${CTX_CLUSTER1}" create serviceaccount istio-reader-service-account -n istio-system
oc --context="${CTX_CLUSTER2}" create serviceaccount istio-reader-service-account -n istio-system

oc --context="${CTX_CLUSTER1}" adm policy add-cluster-role-to-user cluster-reader -z istio-reader-service-account -n istio-system
oc --context="${CTX_CLUSTER2}" adm policy add-cluster-role-to-user cluster-reader -z istio-reader-service-account -n istio-system

istioctl create-remote-secret --create-service-account=false \
  --context="${CTX_CLUSTER2}" \
  --name=cluster2 | \
  oc --context="${CTX_CLUSTER1}" apply -f -

istioctl create-remote-secret --create-service-account=false \
  --context="${CTX_CLUSTER1}" \
  --name=cluster1 | \
  oc --context="${CTX_CLUSTER2}" apply -f -
```

## verify 

```sh
for i in {0..9}; do \
  oc --context="${CTX_CLUSTER1}" exec -n sample deploy/sleep -c sleep -- curl -sS helloworld.sample:5000/hello; \
done
for i in {0..9}; do \
  oc --context="${CTX_CLUSTER2}" exec -n sample deploy/sleep -c sleep -- curl -sS helloworld.sample:5000/hello; \
done
```

## verify endpoints

<https://istio.io/latest/docs/ops/diagnostic-tools/multicluster/#step-by-step-diagnosis>

```sh
tbox@fedora:~/git/trevorbox/openshift-service-mesh$ nslookup $(oc --context $CTX_CLUSTER2 get svc istio-eastwestgateway -n istio-system -o go-template="{{(index .status.loadBalancer.ingress 0).hostname }}")
Server:         127.0.0.53
Address:        127.0.0.53#53

Non-authoritative answer:
Name:   af486e1dbe4a44ac9994f8a98ce3376e-999950728.us-west-2.elb.amazonaws.com
Address: 52.25.251.159
Name:   af486e1dbe4a44ac9994f8a98ce3376e-999950728.us-west-2.elb.amazonaws.com
Address: 44.240.185.234
Name:   af486e1dbe4a44ac9994f8a98ce3376e-999950728.us-west-2.elb.amazonaws.com
Address: 44.226.201.253

tbox@fedora:~/git/trevorbox/openshift-service-mesh$ istioctl --context $CTX_CLUSTER1 proxy-config endpoint details-v1-547cc67476-qpvcj.bookinfo | grep productpage
10.129.2.48:9080                                        HEALTHY     OK                outbound|9080|v1|productpage.bookinfo.svc.cluster.local
10.129.2.48:9080                                        HEALTHY     OK                outbound|9080||productpage.bookinfo.svc.cluster.local
44.226.201.253:15443                                    HEALTHY     OK                outbound|9080|v1|productpage.bookinfo.svc.cluster.local
44.226.201.253:15443                                    HEALTHY     OK                outbound|9080||productpage.bookinfo.svc.cluster.local
44.240.185.234:15443                                    HEALTHY     OK                outbound|9080|v1|productpage.bookinfo.svc.cluster.local
44.240.185.234:15443                                    HEALTHY     OK                outbound|9080||productpage.bookinfo.svc.cluster.local
52.25.251.159:15443                                     HEALTHY     OK                outbound|9080|v1|productpage.bookinfo.svc.cluster.local
52.25.251.159:15443                                     HEALTHY     OK                outbound|9080||productpage.bookinfo.svc.cluster.local
```