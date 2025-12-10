# oidc

<https://azure.github.io/azure-workload-identity/docs/installation/self-managed-clusters/oidc-issuer/discovery-document.html>

1. Create an Azure Blob storage account

```sh
export RESOURCE_GROUP="oidc-issuer"
export LOCATION="westus2"
az group create --name "${RESOURCE_GROUP}" --location "${LOCATION}"

export AZURE_STORAGE_ACCOUNT="oidcissuer$(openssl rand -hex 4)"
# This $web container is a special container that serves static web content without requiring public access enablement.
# See https://learn.microsoft.com/en-us/azure/storage/blobs/storage-blob-static-website
AZURE_STORAGE_CONTAINER="\$web"

az storage account create \
    --name "${AZURE_STORAGE_ACCOUNT}" \
    --resource-group "${RESOURCE_GROUP}" \
    --kind StorageV2 \
    --location "westus2" \
    --allow-blob-public-access true

az storage container create \
    --name "${AZURE_STORAGE_CONTAINER}" \
    --public-access blob

```

2. Generate the discovery document

```sh
cat <<EOF > openid-configuration.json
{
  "issuer": "https://${AZURE_STORAGE_ACCOUNT}.blob.core.windows.net/${AZURE_STORAGE_CONTAINER}/",
  "jwks_uri": "https://${AZURE_STORAGE_ACCOUNT}.blob.core.windows.net/${AZURE_STORAGE_CONTAINER}/openid/v1/jwks",
  "response_types_supported": [
    "id_token"
  ],
  "subject_types_supported": [
    "public"
  ],
  "id_token_signing_alg_values_supported": [
    "RS256"
  ]
}
EOF
```

3. Upload the discovery document

```sh
az storage blob upload \
  --container-name "${AZURE_STORAGE_CONTAINER}" \
  --file openid-configuration.json \
  --name .well-known/openid-configuration
```

4. Verify that the discovery document is publicly accessible

```sh
curl -s "https://${AZURE_STORAGE_ACCOUNT}.blob.core.windows.net/${AZURE_STORAGE_CONTAINER}/.well-known/openid-configuration"
```

0. allow anonymous access to JWKS

```sh
oc create -f clusterrolebinding-anonymous-issuer-discovery.yaml
```

2. Get the JWKS document from kube api

```sh
curl -k https://api.crc.testing:6443/openid/v1/jwks | jq -r > jwks.json
```

3. Upload the JWKS document

```sh
az storage blob upload \
  --container-name "${AZURE_STORAGE_CONTAINER}" \
  --file jwks.json \
  --name openid/v1/jwks
```

4. Verify that the JWKS document is publicly accessible

```sh
curl -s "https://${AZURE_STORAGE_ACCOUNT}.blob.core.windows.net/${AZURE_STORAGE_CONTAINER}/openid/v1/jwks"
```
