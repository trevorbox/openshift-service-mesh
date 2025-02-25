# oauth2-proxy in front of UI

![Kiali Auth Graph](./oauth2-proxy.png)



```yaml deployment
    annotations:
      sidecar.istio.io/inject: 'true'
      sidecar.istio.io/logLevel: 'rbac:debug,jwt:debug'
```