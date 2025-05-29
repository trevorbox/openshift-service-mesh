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

## istio-csr verify 

```sh
# this will just show the certificate presented by the gateway (ok, dotn worry) 
istioctl proxy-config secret -n istio-ingress $(oc get pods -n istio-ingress -o jsonpath='{.items..metadata.name}' --selector app=istio-ingressgateway) -o json | jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' | base64 --decode | openssl x509 -text -noout


# will show Issuer: O=cert-manager + O=cluster.local, CN=east-ca after restarting the pod (Issuer: O=cluster.local before if deployed previously before istio-csr)
istioctl proxy-config secret -n bookinfo $(oc get pods -n bookinfo -o jsonpath='{.items..metadata.name}' --selector app=productpage) -o json | jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' | base64 --decode | openssl x509 -text -noout
```