# pipelines

## notes

get number of pods on nodes

```sh
for n in $(oc get nodes -l node-role.kubernetes.io/worker-only='' --no-headers | awk '{print $1}'); do 
  echo -n "$n: "; 
  oc get pods -A --field-selector spec.nodeName=$n --no-headers | wc -l; 
done
```
