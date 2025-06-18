# testing Cert manager istio intermediaries

Manually copy over the certificate secrets created by cert-manager to both istio-systems...

The Cert manager certificate secret `type: kubernetes.io/tls` work fine for the `cacerts` secret; does not have to be generic type of secret

```sh
oc get secret istio-intermediate-ca-east -n my-pki -oyaml > intermediate-east.yaml

# rename the secret to cacerts, and namespace to istio-system
oc apply -f intermediate-east.yaml -n istio-system
```

## notes

Istio will produce a warning in the logs if the ROOT-CA is changes and won't inject new sidecars (new pods) with the new root ca until you also restart Istiod. 
After resting the istiod instances, however, it will start configuring new sidecars (new pods) with the new root ca.

Rotating the intermediaries among different clusters works seamlessly, so long as the root is the same.


