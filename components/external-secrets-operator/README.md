# migrate

<https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/security_and_compliance/external-secrets-operator-for-red-hat-openshift#external-secrets-operator-migrate-downstream-upstream>

1. remove from gitops external-secrets-operator - delete app

2. cleanup

```sh
oc get operatorconfigs.operator.external-secrets.io -A
oc delete operatorconfig --all -n external-secrets-operator
oc get operatorconfigs.operator.external-secrets.io -A
oc get validatingwebhookconfigurations | grep external-secrets
oc get mutatingwebhookconfigurations | grep external-secrets

oc get subscription -n external-secrets-operator | grep external-secrets
oc delete subscription external-secrets-operator -n external-secrets-operator
oc get csv | grep external-secret
oc delete csv external-secrets-operator.v0.11.0
```

3. enable openshift-external-secrets-operator in gitops

