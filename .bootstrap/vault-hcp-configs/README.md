# https://developer.hashicorp.com/hcp/tutorials/get-started-hcp-vault-secrets/hcp-vault-secrets-kubernetes-vso
```sh
hcp auth login
hcp profile init --vault-secrets
hcp profile display
export HCP_ORG_ID=$(hcp profile display --format=json | jq -r .OrganizationID)
export HCP_PROJECT_ID=$(hcp profile display --format=json | jq -r .ProjectID)
export APP_NAME=$(hcp profile display --format=json | jq -r .VaultSecrets.AppName)

# https://developer.hashicorp.com/hcp/tutorials/get-started-hcp-vault-secrets/hcp-vault-secrets-kubernetes-vso#prerequisites
# export HCP_CLIENT_ID=
# export HCP_CLIENT_SECRET=


export OAUTH2_PROXY_NAMESPACE=oauth2-proxy
kubectl create secret generic vso-demo-sp \
    --namespace $OAUTH2_PROXY_NAMESPACE \
    --from-literal=clientID=$HCP_CLIENT_ID \
    --from-literal=clientSecret=$HCP_CLIENT_SECRET

export VSO_NAMESPACE=vault-secrets-operator

kubectl apply -f - <<EOF
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: HCPAuth
metadata:
  name: default
  namespace: $VSO_NAMESPACE
spec:
  allowedNamespaces:
    - $OAUTH2_PROXY_NAMESPACE
  organizationID: $HCP_ORG_ID
  projectID: $HCP_PROJECT_ID
  servicePrincipal:
    secretRef: vso-demo-sp
EOF
kubectl apply -f - <<EOF
apiVersion: secrets.hashicorp.com/v1beta1
kind: HCPVaultSecretsApp
metadata:
  name: $APP_NAME
  namespace: $OAUTH2_PROXY_NAMESPACE
spec:
  appName: $APP_NAME
  hcpAuthRef: $VSO_NAMESPACE/default
  refreshAfter: 1m
  destination:
    create: true
    labels:
      hvs: "true"
    name: $APP_NAME
    transformation:
      excludeRaw: true
      excludes:
       - .*
      templates:
        client-id:
          text: |
            {{-  get .Secrets "client_id" -}}
        client-secret:
          text: |
            {{-  get .Secrets "client_secret" -}}
        cookie-secret:
          text: |
            {{-  get .Secrets "cookie_secret" -}}
  refreshAfter: 1m
EOF
```
