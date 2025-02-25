# oauth2-proxy in front of UI

![Kiali Auth Graph](./oauth2-proxy.png)


enable debiggin
```yaml deployment
    annotations:
      sidecar.istio.io/inject: 'true'
      sidecar.istio.io/logLevel: 'rbac:debug,jwt:debug'
```

```sh
auth0 login

#create the app
auth0 apps create --name myapp --description myapp --type regular --callbacks https://oauth-bookinfo-istio-ingress.apps-crc.testing/oauth2/callback

# get the client id from the list for myapp
auth0 apps list
export client_id=

#create the api
auth0 apis create --name myapi --identifier http://my-api

# authorize the app to the api
auth0 login --scopes create:client_grants
auth0 api post client-grants --data "{\"audience\":\"http://my-api\",\"client_id\":\"${client_id}\",\"scope\":[]}"

# get the client secret
auth0 apps show --reveal-secrets
```

put the client id and secret in the oauth2-proxy secret.

