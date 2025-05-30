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

# final steps establish trust

```sh
# log into east
export CTX_CLUSTER1=$(oc config current-context)
# log into west
export CTX_CLUSTER2=$(oc config current-context)

istioctl create-remote-secret \
    --context="${CTX_CLUSTER2}" \
    --name=cluster2 | \
    oc --context="${CTX_CLUSTER1}" apply -f -

istioctl create-remote-secret \
    --context="${CTX_CLUSTER1}" \
    --name=cluster1 | \
    oc --context="${CTX_CLUSTER2}" apply -f -
```