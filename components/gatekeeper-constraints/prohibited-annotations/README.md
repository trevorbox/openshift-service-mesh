# Testing gator unit tests

For some reason `gator test` works...

```sh
tbox@fedora:~/git/trevorbox/openshift-service-mesh/components/gatekeeper-constraints/prohibited-annotations$ gator test -f k8sprohibitedannotations-prohibit-gateway-injection.yaml -f constrainttemplate-k8sprohibitedannotations.yaml -f expansion.yaml -f deployment.yaml -f namespace.yaml
apps/v1/Deployment my-ns/nginx-deployment: ["prohibit-gateway-injection"] Message: "[Implied by expand-workloads] Annotation <inject.istio.io/templates: gateway> does not satisfy prohibited regex: ^gateway$"
tbox@fedora:~/git/trevorbox/openshift-service-mesh/components/gatekeeper-constraints/prohibited-annotations$ echo $?
1
tbox@fedora:~/git/trevorbox/openshift-service-mesh/components/gatekeeper-constraints/prohibited-annotations$ gator test -f k8sprohibitedannotations-prohibit-gateway-injection.yaml -f constrainttemplate-k8sprohibitedannotations.yaml -f expansion.yaml -f deployment.yaml -f namespace-allow.yaml
tbox@fedora:~/git/trevorbox/openshift-service-mesh/components/gatekeeper-constraints/prohibited-annotations$ echo $?
0
```

but this does not...

> TODO look into what I'm doing wong with the suite.yaml

```sh
tbox@fedora:~/git/trevorbox/openshift-service-mesh/components/gatekeeper-constraints/prohibited-annotation$ gator verify .
    --- FAIL: prohibited-annotation     (0.005s)
        unexpected number of violations: got 0 violations but want at least 1: got messages []
--- FAIL: prohibited-annotation (0.009s)
FAIL    .yaml   0.009s
FAIL

Error: FAIL
```


