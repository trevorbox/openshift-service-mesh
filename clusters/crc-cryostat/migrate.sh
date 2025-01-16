#!/bin/bash

# experiment with restarting pods when switching form ossm2 to 3... There is an outage in this scenario before the new pods rollout.

set -x

echo "istio-system Before"... > migrate.log
istioctl -i istio-system ps >> migrate.log
echo "istio-system3 Before"... >> migrate.log
istioctl -i istio-system3 ps >> migrate.log

gnome-terminal -- bash -c "siege https://spring-boot-demo2-istio-ingress.apps-crc.testing/; exec bash"
gnome-terminal -- bash -c "siege https://spring-boot-demo2-istio-ingress3.apps-crc.testing/; exec bash"

# edit the route in components/spring-boot-2/istio-configs.yaml to deploy to istio-ingress3 instead of istio-ingress
# push it




oc label namespace $n istio.io/rev=default --overwrite

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
  name: istio-rev-default
spec:
  podSelector: {}
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              istio.io/rev: default
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

