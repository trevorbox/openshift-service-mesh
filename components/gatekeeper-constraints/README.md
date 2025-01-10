# Run all gator unit test suites

> Tested using [gator v3.18.1](https://github.com/open-policy-agent/gatekeeper/releases/tag/v3.18.1). Found example from <https://github.com/open-policy-agent/gatekeeper/tree/master/test/gator/test/fixtures/manifests/expansion>

```sh
gator verify ./...
```

You can also run `gator test` manually to see the messages...

```sh
gator test -f prohibit-injected-gateway-annotation/constraint.yaml -f template.yaml -f prohibit-injected-gateway-annotation/test/expansion.yaml -f prohibit-injected-gateway-annotation/test/deployment-my-ns.yaml -f prohibit-injected-gateway-annotation/test/namespace-my-ns.yaml
```
