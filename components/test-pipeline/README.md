# notes

```sh
for n in $(oc get nodes -l node-role.kubernetes.io/worker-only='' --no-headers | awk '{print $1}'); do 
  echo -n "$n: "; 
  oc get pods -A --field-selector spec.nodeName=$n --no-headers | wc -l; 
done


nodes=$(oc get nodes -l node-role.kubernetes.io/worker-only='' --no-headers -o jsonpath='{.items[*].metadata.name}')

for node in $nodes; do
    count=$(oc get pods -A --field-selector spec.nodeName=$node -o json | \
    jq '[.items[] | select(.metadata.ownerReferences[]?.kind == "Job" and 
      (.status.phase == "Succeeded" or .status.phase == "Failed"))] | length')
    
    printf "%-40s %s\n" "$node" "Count: $count"
done

# Get all worker node names
nodes=$(oc get nodes -l node-role.kubernetes.io/worker='' --no-headers -o name | cut -d'/' -f2)

for node in $nodes; do
    
    total_count=$(oc get pods -A --field-selector spec.nodeName=$node \
      -o custom-columns="PHASE:.status.phase,OWNER:.metadata.ownerReferences[0].kind" \
      --no-headers | wc -l)

    j_count=$(oc get pods -A --field-selector spec.nodeName=$node \
      -o custom-columns="PHASE:.status.phase,OWNER:.metadata.ownerReferences[0].kind" \
      --no-headers | grep -E "Succeeded|Failed" | grep "Job" | wc -l)
    
    t_count=$(oc get pods -A --field-selector spec.nodeName=$node \
      -o custom-columns="PHASE:.status.phase,OWNER:.metadata.ownerReferences[0].kind" \
      --no-headers | grep -E "Succeeded|Failed" | grep "TaskRun" | wc -l)
    printf "%-40s Succeeded|Failed Job/TaskRun Pods: %s/%s Total Pods: %s\n" "$node" "$j_count" "$t_count" "$total_count"
done

oc get taskruns -A \
  -o custom-columns="NAMESPACE:.metadata.namespace,NAME:.metadata.name,DT:.metadata.deletionTimestamp,FINALIZERS:.metadata.finalizers[*]" \
  --no-headers | grep "results.tekton.dev/taskrun" | grep -v "<none>"


list=$(oc get servicemonitor -n openshift-pipelines -o name)

for p in $list; do
  echo "---" >> openshift-pipelines-servicemonitors.yaml 
  oc get $p -n openshift-pipelines -o yaml >> openshift-pipelines-servicemonitors.yaml 
done
```
