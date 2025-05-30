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