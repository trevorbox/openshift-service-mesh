#!/bin/bash

# experiment with restarting pods when switching form ossm2 to 3... There is an outage in this scenario before the new pods rollout.

set -x

echo "istio-system Before"... > migrate.log
istioctl -i istio-system ps >> migrate.log
echo "istio-system3 Before"... >> migrate.log
istioctl -i istio-system3 ps >> migrate.log

RESOURCES=$(oc get namespace -l istio.io/rev=ossm2 -o custom-columns=":metadata.name")
for n in $RESOURCES
do
  oc label namespace $n istio.io/rev=default --overwrite
  oc label namespace $n istio-injection=enabled --overwrite


# mistra netowwork policies will be removed. but others remain, so ensure communication can happen to the new control plane
oc apply -n $n -f - <<EOF
kind: NetworkPolicy
apiVersion: networking.k8s.io/v1
metadata:
  name: istio-injection-enabled
spec:
  podSelector: {}
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              istio-injection: enabled
  policyTypes:
    - Ingress
EOF


  oc rollout restart deploy -n $n

done

# kiali operator won't update on namespace label changes apparently
oc rollout restart deploy -n kiali-operator

echo "istio-system After"... >> migrate.log
istioctl -i istio-system ps >> migrate.log
echo "istio-system3 After"... >> migrate.log
istioctl -i istio-system3 ps >> migrate.log

