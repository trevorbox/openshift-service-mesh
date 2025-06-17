# multicluster configs east

![east-kiali](./.img/east-kiali.png "Kiali east")

# notes

in east we simulate an external issuer by create a root-ca and two intermediary CAs (east-ca, west-ca) 


```sh
rm -rf .certs
mkdir .certs
cd .certs
openssl genrsa -out root-key.pem 4096
cat >> root-ca.conf <<EOF
encrypt_key = no
prompt = no
utf8 = yes
default_md = sha256
default_bits = 4096
req_extensions = req_ext
x509_extensions = req_ext
distinguished_name = req_dn
[ req_ext ]
subjectKeyIdentifier = hash
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, nonRepudiation, keyEncipherment, keyCertSign
[ req_dn ]
O = Istio
CN = Root CA
EOF
openssl req -sha256 -new -key root-key.pem \
  -config root-ca.conf \
  -out root-cert.csr
openssl x509 -req -sha256 -days 3650 \
  -signkey root-key.pem \
  -extensions req_ext -extfile root-ca.conf \
  -in root-cert.csr \
  -out root-cert.pem
mkdir east
openssl genrsa -out east/ca-key.pem 4096

cat >> east/intermediate.conf <<EOF
[ req ]
encrypt_key = no
prompt = no
utf8 = yes
default_md = sha256
default_bits = 4096
req_extensions = req_ext
x509_extensions = req_ext
distinguished_name = req_dn
[ req_ext ]
subjectKeyIdentifier = hash
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, digitalSignature, nonRepudiation, keyEncipherment, keyCertSign
subjectAltName=@san
[ san ]
DNS.1 = istiod.istio-system.svc
[ req_dn ]
O = Istio
CN = Intermediate CA
L = east
EOF
openssl req -new -config east/intermediate.conf \
   -key east/ca-key.pem \
   -out east/cluster-ca.csr
openssl x509 -req -sha256 -days 3650 \
   -CA root-cert.pem \
   -CAkey root-key.pem -CAcreateserial \
   -extensions req_ext -extfile east/intermediate.conf \
   -in east/cluster-ca.csr \
   -out east/ca-cert.pem
cat east/ca-cert.pem root-cert.pem > east/cert-chain.pem && cp root-cert.pem east
mkdir west
openssl genrsa -out west/ca-key.pem 4096
cat >> west/intermediate.conf <<EOF
[ req ]
encrypt_key = no
prompt = no
utf8 = yes
default_md = sha256
default_bits = 4096
req_extensions = req_ext
x509_extensions = req_ext
distinguished_name = req_dn
[ req_ext ]
subjectKeyIdentifier = hash
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, digitalSignature, nonRepudiation, keyEncipherment, keyCertSign
subjectAltName=@san
[ san ]
DNS.1 = istiod.istio-system.svc
[ req_dn ]
O = Istio
CN = Intermediate CA
L = west
EOF
openssl req -new -config west/intermediate.conf \
   -key west/ca-key.pem \
   -out west/cluster-ca.csr
openssl x509 -req -sha256 -days 3650 \
   -CA root-cert.pem \
   -CAkey root-key.pem -CAcreateserial \
   -extensions req_ext -extfile west/intermediate.conf \
   -in west/cluster-ca.csr \
   -out west/ca-cert.pem
cat west/ca-cert.pem root-cert.pem > west/cert-chain.pem && cp root-cert.pem west
```

```sh
oc create secret generic cacerts -n istio-system --context "${CTX_CLUSTER1}" \
  --from-file=east/ca-cert.pem \
  --from-file=east/ca-key.pem \
  --from-file=east/root-cert.pem \
  --from-file=east/cert-chain.pem
oc create secret generic cacerts -n istio-system --context "${CTX_CLUSTER2}" \
  --from-file=west/ca-cert.pem \
  --from-file=west/ca-key.pem \
  --from-file=west/root-cert.pem \
  --from-file=west/cert-chain.pem
```

## (test) istio-csr verify 

> works but not working for multicluster

We need to add the generic secret to cert-manager <https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.0/html/installing/ossm-cert-manager>

```sh
oc get -n istio-system secret east-ca -o jsonpath='{.data.tls\.crt}' | base64 -d > ca.pem
oc create secret generic -n cert-manager istio-root-ca --from-file=ca.pem=ca.pem
```

```sh
# this will just show the certificate presented by the gateway (ok, dotn worry) 
istioctl proxy-config secret -n istio-ingress $(oc get pods -n istio-ingress -o jsonpath='{.items..metadata.name}' --selector app=istio-ingressgateway) -o json | jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' | base64 --decode | openssl x509 -text -noout

# will show Issuer: O=cert-manager + O=cluster.local, CN=east-ca after restarting the pod (Issuer: O=cluster.local before if deployed previously before istio-csr)
istioctl proxy-config secret -n bookinfo $(oc get pods -n bookinfo -o jsonpath='{.items..metadata.name}' --selector app=productpage) -o json | jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' | base64 --decode | openssl x509 -text -noout
```

## kiali multi-cluster

In west and east cluster, create the following for test purposes

```yaml
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: kiali-remote-access-create-oauthclient
subjects:
  - kind: ServiceAccount
    name: kiali-remote-access
    namespace: kiali
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kiali-remote-access-create-oauthclient
---
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: kiali-remote-access-create-oauthclient
rules:
  - verbs:
      - get
      - create
      - watch
      - delete
    apiGroups:
      - oauth.openshift.io
    resources:
      - oauthclients
```

```sh
# log into east
export CTX_CLUSTER1=$(oc config current-context)
# log into west
export CTX_CLUSTER2=$(oc config current-context)
```

```sh
# log into east
export CLIENT_EXE=oc
export PROCESS_KIALI_SECRET=true
export PROCESS_REMOTE_RESOURCES=true
export DELETE=false
export DRY_RUN=false
export HELM=helm
export KIALI_CLUSTER_CONTEXT=$CTX_CLUSTER1
export KIALI_CLUSTER_NAMESPACE=kiali
export KIALI_RESOURCE_NAME=kiali-remote-access
export KIALI_VERSION="2.11.0"
export REMOTE_CLUSTER_CONTEXT=$CTX_CLUSTER2
export REMOTE_CLUSTER_NAME=cluster2
export REMOTE_CLUSTER_NAMESPACE=kiali
export REMOTE_CLUSTER_URL=https://api.west.sandbox1.opentlc.com:6443
export VIEW_ONLY=false
export EXEC_AUTH_JSON=
./kiali-prepare-remote-cluster.sh
```

```sh
# log into west
export CLIENT_EXE=oc
export PROCESS_KIALI_SECRET=true
export PROCESS_REMOTE_RESOURCES=true
export DELETE=false
export DRY_RUN=false
export HELM=helm
export KIALI_CLUSTER_CONTEXT=$CTX_CLUSTER2
export KIALI_CLUSTER_NAMESPACE=kiali
export KIALI_RESOURCE_NAME=kiali-remote-access
export KIALI_VERSION="2.11.0"
export REMOTE_CLUSTER_CONTEXT=$CTX_CLUSTER1
export REMOTE_CLUSTER_NAME=cluster1
export REMOTE_CLUSTER_NAMESPACE=kiali
export REMOTE_CLUSTER_URL=https://api.east.sandbox2729.opentlc.com:6443
export VIEW_ONLY=false
export EXEC_AUTH_JSON=
./kiali-prepare-remote-cluster.sh
```


# Verify the secret kiali-remote-cluster-secret-cluster2 should work

Grab the ca info in the k8s secret created in the east cluster in the kiali namespace, decode it and make sure the pem is correct

```sh
curl --cacert out.pem https://api.west.sandbox1.opentlc.com:6443
oc login --token='MY_TOKEN' https://api.west.sandbox1.opentlc.com:6443

tbox@fedora:~/git/trevorbox/openshift-service-mesh/clusters/aws-east$ for i in VirtualService DestinationRule Pods ConfigMap Deployment Service ReplicaSet StatefulSet DaemonSet Endpoints; do echo -n "GET [$i] (COUNT): "; oc get $i -o name --all-namespaces | wc -l; echo -n "CAN-I WATCH [$i]? "; oc auth can-i watch $i; done
GET [VirtualService] (COUNT): 1
CAN-I WATCH [VirtualService]? yes
GET [DestinationRule] (COUNT): 6
CAN-I WATCH [DestinationRule]? yes
GET [Pods] (COUNT): 329
CAN-I WATCH [Pods]? yes
GET [ConfigMap] (COUNT): 646
CAN-I WATCH [ConfigMap]? yes
GET [Deployment] (COUNT): 107
CAN-I WATCH [Deployment]? yes
GET [Service] (COUNT): 148
CAN-I WATCH [Service]? yes
GET [ReplicaSet] (COUNT): 152
CAN-I WATCH [ReplicaSet]? yes
GET [StatefulSet] (COUNT): 7
CAN-I WATCH [StatefulSet]? yes
GET [DaemonSet] (COUNT): 18
CAN-I WATCH [DaemonSet]? yes
GET [Endpoints] (COUNT): 147
CAN-I WATCH [Endpoints]? yes
```

Currently getting the error

```sh
2025-06-11T05:40:11Z ERR K8s Client [cluster2] is not found or is not accessible for Kiali
```