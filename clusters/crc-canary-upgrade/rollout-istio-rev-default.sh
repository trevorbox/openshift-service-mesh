#!/bin/bash

# rollout deployments in namespaces with the label "istio.io/rev: default"

set -x

start=`date +%s`
echo "Start: $(date -d @$start)"
istioctl -i istio-system tag list -o json | jq -r '.[]  | select(.tag == "default").namespaces.[]' | 
while IFS=$"\n" read -r namespace; do
	echo "------------------"
	echo "Namespace: $namespace"
	oc rollout restart deploy -n $namespace
	oc rollout status deploy -n $namespace --timeout 10m
	echo ".................."
done
end=`date +%s`
echo "End: $(date -d @$end)"
runtime=$((end-start))
echo "Runtime: $(date -d @$runtime -u +%H:%M:%S)"
