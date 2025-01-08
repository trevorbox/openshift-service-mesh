# Testing gator unit tests

> Tested using [gator v3.18.1](https://github.com/open-policy-agent/gatekeeper/releases/tag/v3.18.1). Found example from <https://github.com/open-policy-agent/gatekeeper/tree/master/test/gator/test/fixtures/manifests/expansion>

Run the test suite..

```sh
gator verify prohibit-injected-gateway-annotation/test/suite.yaml
```

You can also run `gator test` manually to see the messages...

```sh
gator test -f prohibit-injected-gateway-annotation/constraint.yaml -f template.yaml -f prohibit-injected-gateway-annotation/test/expansion.yaml -f prohibit-injected-gateway-annotation/test/deployment-my-ns.yaml -f prohibit-injected-gateway-annotation/test/namespace-my-ns.yaml
```

Example...

```sh
tbox@fedora:~/git/trevorbox/openshift-service-mesh/components/gatekeeper-constraints/prohibited-annotations$ gator verify prohibit-injected-gateway-annotation/test/suite.yaml
ok      prohibit-injected-gateway-annotation/test/suite.yaml    0.018s
PASS

tbox@fedora:~/git/trevorbox/openshift-service-mesh/components/gatekeeper-constraints/prohibited-annotations$ gator test -f prohibit-injected-gateway-annotation/constraint.yaml -f template.yaml -f prohibit-injected-gateway-annotation/test/expansion.yaml -f prohibit-injected-gateway-annotation/test/deployment-my-ns.yaml -f prohibit-injected-gateway-annotation/test/namespace-my-ns.yaml
apps/v1/Deployment my-ns/nginx-deployment: ["prohibit-gateway-injection"] Message: "[Implied by expand-workloads] Annotation <inject.istio.io/templates: gateway> does not satisfy prohibited regex: ^gateway$"
```
