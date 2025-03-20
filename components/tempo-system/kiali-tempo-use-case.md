# use case


```yaml
apiVersion: kiali.io/v1alpha1
kind: Kiali
metadata:
  name: kiali-istio-system
  namespace: kiali
spec:
  auth:
    strategy: openshift
  deployment:
    cluster_wide_access: true
    discovery_selectors:
      default:
        - matchExpressions:
            - key: istio.io/rev
              operator: Exists
        - matchLabels:
            kubernetes.io/metadata.name: istio-system
        - matchLabels:
            kubernetes.io/metadata.name: grafana
    image_pull_policy: ''
    ingress:
      enabled: true
    instance_name: kiali
    logger:
      log_level: debug
    namespace: kiali
    pod_labels:
      maistra.io/expose-route: 'true'
      sidecar.istio.io/inject: 'false'
    replicas: 1
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
  external_services:
    custom_dashboards:
      namespace_label: kubernetes_namespace
    grafana:
      dashboards:
        - name: Istio Service Dashboard
          variables:
            namespace: var-namespace
            service: var-service
        - name: Istio Workload Dashboard
          variables:
            namespace: var-namespace
            workload: var-workload
        - name: Istio Mesh Dashboard
        - name: Istio Control Plane Dashboard
        - name: Istio Performance Dashboard
        - name: Istio Wasm Extension Dashboard
      enabled: true
      external_url: https://grafana-instance-route-grafana.apps-crc.testing
      internal_url: http://grafana-instance-service.grafana.svc:3000
    prometheus:
      url: http://prometheus-server.prometheus.svc.cluster.local
    tracing:
      enabled: true
      external_url: https://grafana-instance-route-grafana.apps-crc.testing
      # grpc_port: 9095
      health_check_url: http://tempo-minio-dev-query-frontend.tempo-system.svc.cluster.local:3200/ready
      internal_url: >-
        http://tempo-minio-dev-query-frontend.tempo-system.svc.cluster.local:3200/
      provider: tempo
      tempo_config:
        datasource_uid: 2aaa2e27-41bd-4e18-a253-2b328390e2bc
        org_id: '1'
        url_format: grafana
      use_grpc: false
  installation_tag: Kiali3
  istio_labels:
    app_label_name: app
    egress_gateway_label: istio=egressgateway
    ingress_gateway_label: istio=ingressgateway
    injection_label_name: istio-injection
    injection_label_rev: istio.io/rev
    version_label_name: version
  istio_namespace: istio-system
```

```yaml
apiVersion: tempo.grafana.com/v1alpha1
kind: TempoStack
metadata:
  name: minio-dev
spec:
  storageSize: 30Gi
  storage: 
    secret:
      name: minio-dev
      type: s3
  resources:
    total:
      limits:
        memory: 6Gi
        cpu: '4'
  template:
    queryFrontend:
      jaegerQuery: 
        enabled: true
```

Kiali pod debug logs

```log
2025-03-20T19:34:12Z DBG [HTTP Tempo] Prepared Tempo API query: http://tempo-minio-dev-query-frontend.tempo-system.svc.cluster.local:3200/api/search?end=1742499252&limit=100&q=%7B+.service.name+%3D+%22productpage.bookinfo%22++%26%26+.istio.cluster_id+%3D+%22Kubernetes%22+++%7D+%26%26+%7B++%7D+%7C+select%28status%2C+.service_name%2C+.node_id%2C+.component%2C+.upstream_cluster%2C+.http.method%2C+.response_flags%2C+resource.hostname%29&spss=10&start=1742498652
```

Logs from tempo-minio-dev-query-frontend-677f9f5554-xkcgm "tempo" container

```log
level=info ts=2025-03-20T19:36:12.24905406Z caller=search_handlers.go:172 msg="search response" tenant=single-tenant query="{ .service.name = \"productpage.bookinfo\" && .istio.cluster_id = \"Kubernetes\" } && { } | select(status, .service_name, .node_id, .component, .upstream_cluster, .http.method, .response_flags, resource.hostname)" range_seconds=600 duration_seconds=0.01454256 request_throughput=5.073453367220077e+06 total_requests=3 total_blockBytes=0 total_blocks=0 completed_requests=3 inspected_bytes=73781 inspected_traces=0 inspected_spans=0 status_code=200 error=null
level=info ts=2025-03-20T19:36:12.249368288Z caller=handler.go:134 tenant=single-tenant method=GET traceID= url="/api/search?end=1742499372&limit=100&q=%7B+.service.name+%3D+%22productpage.bookinfo%22++%26%26+.istio.cluster_id+%3D+%22Kubernetes%22+++%7D+%26%26+%7B++%7D+%7C+select%28status%2C+.service_name%2C+.node_id%2C+.component%2C+.upstream_cluster%2C+.http.method%2C+.response_flags%2C+resource.hostname%29&spss=10&start=1742498772" duration=14.855209ms response_size=82 status=200
```

Curl from terminal in Kiali pod

```sh
sh-5.1$ curl http://tempo-minio-dev-query-frontend.tempo-system.svc.cluster.local:3200/api/search?end=1742499252&limit=100&q=%7B+.service.name+%3D+%22productpage.bookinfo%22++%26%26+.istio.cluster_id+%3D+%22Kubernetes%22+++%7D+%26%26+%7B++%7D+%7C+select%28status%2C+.service_name%2C+.node_id%2C+.component%2C+.upstream_cluster%2C+.http.method%2C+.response_flags%2C+resource.hostname%29&spss=10&start=1742498652
[1] 63
[2] 64
[3] 65
[4] 66
sh-5.1$ {"traces":[{"traceID":"f17dfd37bc48c7722ae2dc97c8024d3","rootServiceName":"istio-ingressgateway.istio-ingress","rootTraceName":"egress oauth-bookinfo-istio-ingress.apps-crc.testing","startTimeUnixNano":"1742498813145670567","durationMs":29},{"traceID":"72f827d2b2d0af68705e105afcb91a5","rootServiceName":"istio-ingressgateway.istio-ingress","rootTraceName":"egress oauth-bookinfo-istio-ingress.apps-crc.testing","startTimeUnixNano":"1742498813143348843","durationMs":15},{"traceID":"f5de2aa74833648da77258b0822cd13","rootServiceName":"istio-ingressgateway.istio-ingress","rootTraceName":"egress oauth-bookinfo-istio-ingress.apps-crc.testing","startTimeUnixNano":"1742498813086959166","durationMs":64},{"traceID":"853c2925ad7a5cf501f9e6a11436658","rootServiceName":"istio-ingressgateway.istio-ingress","rootTraceName":"egress oauth-bookinfo-istio-ingress.apps-crc.testing","startTimeUnixNano":"1742498812397493179","durationMs":19},{"traceID":"10e8dd3c9d30ee43ead3c0dcca041372","rootServiceName":"istio-ingressgateway.istio-ingress","rootTraceName":"egress oauth-bookinfo-istio-ingress.apps-crc.testing","startTimeUnixNano":"1742498811523279429","durationMs":52},{"traceID":"119f1d66804cd6a06a92dfccfb9e20c7","rootServiceName":"istio-ingressgateway.istio-ingress","rootTraceName":"egress oauth-bookinfo-istio-ingress.apps-crc.testing","startTimeUnixNano":"1742498809891745131","durationMs":16},{"traceID":"317e1904be99ad4ce72859e70b27331","rootServiceName":"istio-ingressgateway.istio-ingress","rootTraceName":"egress oauth-bookinfo-istio-ingress.apps-crc.testing","startTimeUnixNano":"1742498809757056196","durationMs":68},{"traceID":"77ab4bcdc3ed1f0761e2b4c7a8041f4","rootServiceName":"istio-ingressgateway.istio-ingress","rootTraceName":"egress oauth-bookinfo-istio-ingress.apps-crc.testing","startTimeUnixNano":"1742498809518750262","durationMs":90},{"traceID":"e494291061dacbf71a1f425ccceb3fb","rootServiceName":"istio-ingressgateway.istio-ingress","rootTraceName":"egress oauth-bookinfo-istio-ingress.apps-crc.testing","startTimeUnixNano":"1742498809518543303","durationMs":83},{"traceID":"81a165f87800810108a61b1bbfc3c10","rootServiceName":"istio-ingressgateway.istio-ingress","rootTraceName":"egress oauth-bookinfo-istio-ingress.apps-crc.testing","startTimeUnixNano":"1742498808834913503","durationMs":60},{"traceID":"65de96ba2e62d447b6e0301421255d3","rootServiceName":"istio-ingressgateway.istio-ingress","rootTraceName":"egress oauth-bookinfo-istio-ingress.apps-crc.testing","startTimeUnixNano":"1742498808580296088","durationMs":35},{"traceID":"47013b8c902833ba7c994e77e9378cd","rootServiceName":"istio-ingressgateway.istio-ingress","rootTraceName":"egress oauth-bookinfo-istio-ingress.apps-crc.testing","startTimeUnixNano":"1742498805921078298","durationMs":48},{"traceID":"4d79a372708ad6a738c8cca03209424","rootServiceName":"istio-ingressgateway.istio-ingress","rootTraceName":"egress oauth-bookinfo-istio-ingress.apps-crc.testing","startTimeUnixNano":"1742498805138830917","durationMs":79},{"traceID":"350683b2ee66c2ddfc22636bda3ebd86","rootServiceName":"istio-ingressgateway.istio-ingress","rootTraceName":"egress oauth-bookinfo-istio-ingress.apps-crc.testing","startTimeUnixNano":"1742498803522185489","durationMs":16},{"traceID":"b7bd2f5c673ccf42c1574705acf944d3","rootServiceName":"istio-ingressgateway.istio-ingress","rootTraceName":"egress oauth-bookinfo-istio-ingress.apps-crc.testing","startTimeUnixNano":"1742498803520985810","durationMs":12},{"traceID":"ff9e6cb01e009460bff987c6d1a46dbc","rootServiceName":"istio-ingressgateway.istio-ingress","rootTraceName":"egress oauth-bookinfo-istio-ingress.apps-crc.testing","startTimeUnixNano":"1742498803449819493","durationMs":38},{"traceID":"517ec11036936583de7832ea845c8ed4","rootServiceName":"istio-ingressgateway.istio-ingress","rootTraceName":"egress oauth-bookinfo-istio-ingress.apps-crc.testing","startTimeUnixNano":"1742498803449282059","durationMs":17},{"traceID":"502da575b303ee41f72b4464e4852ba8","rootServiceName":"istio-ingressgateway.istio-ingress","rootTraceName":"egress oauth-bookinfo-istio-ingress.apps-crc.testing","startTimeUnixNano":"1742498803448450122","durationMs":26},{"traceID":"9a82e196afab6332361c5b9c0fdb08f4","rootServiceName":"istio-ingressgateway.istio-ingress","rootTraceName":"egress oauth-bookinfo-istio-ingress.apps-crc.testing","startTimeUnixNano":"1742498803435112870","durationMs":15},{"traceID":"f42f26ac445ed241463911826a899142","rootServiceName":"istio-ingressgateway.istio-ingress","rootTraceName":"egress oauth-bookinfo-istio-ingress.apps-crc.testing","startTimeUnixNano":"1742498803356256336","durationMs":53}],"metrics":{"inspectedTraces":197,"inspectedBytes":"44463","completedJobs":1,"totalJobs":1}}
```

not working in kiali though.

