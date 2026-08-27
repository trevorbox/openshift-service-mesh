# OLMV1

<https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html-single/extensions/index>

## Install (disabled in openshift-local)

[Have a config option to enable OLMv1 operator #4689](https://github.com/crc-org/crc/issues/4689)

```sh
curl -L -s https://github.com/operator-framework/operator-controller/releases/latest/download/install.sh | bash -s
```

## Auth for registry.redhat.io catalogs

Upstream OLMv1 (`olmv1-system`) does not use the cluster pull secret by default.
Without this, `ClusterCatalog` sources on `registry.redhat.io` fail with
`invalid username/password` / `Please login to the Red Hat Registry`.

Allow catalogd and operator-controller to read `openshift-config/pull-secret`, then
point both deployments at it:

```sh
oc apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: olmv1-pull-secret-reader
  namespace: openshift-config
rules:
  # list/watch cannot be scoped with resourceNames for controller-runtime caches
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: catalogd-pull-secret-reader
  namespace: openshift-config
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: olmv1-pull-secret-reader
subjects:
- kind: ServiceAccount
  name: catalogd-controller-manager
  namespace: olmv1-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: operator-controller-pull-secret-reader
  namespace: openshift-config
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: olmv1-pull-secret-reader
subjects:
- kind: ServiceAccount
  name: operator-controller-controller-manager
  namespace: olmv1-system
EOF

oc -n olmv1-system patch deploy catalogd-controller-manager --type=json -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--global-pull-secret=openshift-config/pull-secret"}
]'

oc -n olmv1-system patch deploy operator-controller-controller-manager --type=json -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--global-pull-secret=openshift-config/pull-secret"}
]'
```

Then apply catalogs:

```sh
oc apply -f .olmv1/clustercatalogs.yaml
oc get clustercatalog
```

## List Packages
opm render registry.redhat.io/redhat/redhat-operator-index:v4.20 | jq -cs '[.[] | select(.schema == "olm.bundle" and (.properties[] | select(.type == "olm.csv.metadata").value.installModes[] | select(.type == "AllNamespaces" and .supported == true)) and .spec.webhookdefinitions == null) | .package] | unique[]'
opm render registry.redhat.io/redhat/redhat-operator-index:v4.20 | jq -s '.[] | select( .schema == "olm.package") | .name'

## Channels in a package
opm render registry.redhat.io/redhat/redhat-operator-index:v4.20 | jq -s '.[] | select( .schema == "olm.channel" ) | select( .package == "servicemeshoperator3") | .name'

## Versions in a channel
opm render registry.redhat.io/redhat/redhat-operator-index:v4.20 | jq -s '.[] | select( .package == "servicemeshoperator3" ) | select( .schema == "olm.channel" ) | select( .name == "stable" ) .entries | .[] | .name'

## Latest version in a channel
opm render registry.redhat.io/redhat/redhat-operator-index:v4.20 | jq -s '.[] | select( .schema == "olm.channel" ) | select ( .name == "stable") | select( .package == "servicemeshoperator3")'

## get images
opm render registry.redhat.io/redhat/redhat-operator-index:v4.20 | jq -cs '.[] | select( .schema == "olm.bundle" ) | select( .package == "servicemeshoperator3") | {"name":.name, "image":.image}'

## extract
oc image extract registry.redhat.io/openshift-service-mesh/istio-sail-operator-bundle@sha256:aa2f99fc2cc6fc519042718ef2934376beca0138cd594cb793d3bbd3af399da9



## notes
opm render registry.redhat.io/redhat/redhat-operator-index:v4.18 | jq -cs '.[] | select( .schema == "olm.bundle" ) | select( .package == "openshift-pipelines-operator-rh") | {"name":.name, "image":.image}'
oc image extract registry.redhat.io/openshift-pipelines/pipelines-operator-bundle@sha256:a7aae937d0ffb78ef948f6c24281ae175d7bf64ba5b0079785e73f4248ac1f9f
