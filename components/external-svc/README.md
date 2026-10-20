# External VM behind an in-cluster Service

Callers always use `myservice.myservice.svc.cluster.local`. Before the dependency is containerized, that Service has no selector and an EndpointSlice sends traffic to a VM address. After the app is running in namespace `myservice`, the same Service gains a pod selector and the VM slice is removed. The DNS name and ClusterIP stay.

A ServiceEntry for that same FQDN can serve the VM only until a Kubernetes Service owns the name. That path is below.

## CRC lab address

| Role | Address |
| --- | --- |
| Host `crc` bridge | `192.168.130.1/24` |
| CRC VM | `192.168.130.11` |
| MetalLB L2 pool | `192.168.130.200-249` |
| This app | `192.168.130.50/32` on the `crc` bridge |

`192.168.130.1` is the host, and the libvirt firewall rejects everything except ssh, dns, and dhcp. The app therefore listens on its own address. The `/32` is not kept across a host reboot.

## Start the VM stand-in

```sh
sudo components/external-svc/host-app/run-external-app.sh start
curl -sS http://192.168.130.50:8080/
```

The body is `external-myservice 192.168.130.50`. Stop with `sudo components/external-svc/host-app/run-external-app.sh stop`.

## Cluster objects

`crc-ossm3` syncs this directory. To apply it by hand:

```sh
oc apply -k components/external-svc
```

The namespace is labeled `istio.io/rev: default` so the mesh (REGISTRY_ONLY) discovers the Service. The DestinationRule turns off mTLS because the VM has no sidecar.

From a meshed pod:

```sh
curl -sS http://myservice.myservice.svc.cluster.local/
```

Service port 80 is forwarded to the VM's port 8080.

## Cut over to pods

Deploying pods does nothing while the Service has no selector. That is the hold.

1. Run the containerized app in `myservice` with a stable label, for example `app: myservice`.
2. Add `selector: {app: myservice}` to Service `myservice`. Update the Service in place so the ClusterIP does not change.
3. Wait until the controller's EndpointSlice shows the pod ready.
4. Delete EndpointSlice `myservice-external`. While it is still `ready: true`, clients are split between the VM and the pods. Set `ready: false` first if you want the VM to drain before the delete.
5. Delete DestinationRule `myservice` if those pods are in the mesh, so clients use mesh mTLS again.
6. `sudo components/external-svc/host-app/run-external-app.sh stop`

Keep the Service object during the handoff so the ClusterIP stays. Removing the Argo app prunes the Service.

This is the smoothest cutover for callers that stay on `myservice.myservice.svc.cluster.local`. The ClusterIP never changes, mesh and non-mesh clients share it, and the VM can drain with `ready: false` while pods are already serving.

## ServiceEntry on the same FQDN

A ServiceEntry can register the VM with the mesh under the internal hostname and omit the Kubernetes Service:

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: myservice
  namespace: myservice
spec:
  hosts:
    - myservice.myservice.svc.cluster.local
  location: MESH_EXTERNAL
  resolution: STATIC
  ports:
    - number: 80
      name: http
      protocol: HTTP
      targetPort: 8080
  endpoints:
    - address: 192.168.130.50
```

`crc-ossm3` turns on DNS capture and `PILOT_ENABLE_IP_AUTOALLOCATE`. A sidecar resolves the host to an Istio-assigned VIP and connects to `192.168.130.50:8080`. CoreDNS has no record until a Service exists. `location: MESH_EXTERNAL` leaves the VM on plaintext, which is what the DestinationRule does for the EndpointSlice.

### Cutover

Once a Kubernetes Service supplies that hostname, Istio keeps the Service's endpoints and treats the ServiceEntry as a decorator. The only ServiceEntry field istiod still applies is `subjectAltNames`. The VM address on the ServiceEntry is dropped. On `*.svc.cluster.local` the handoff is a switch.

1. Deploy the containerized app in `myservice` and wait until its pods are Ready. Leave Service `myservice` uncreated so the ServiceEntry still owns the host.
2. Create Service `myservice` with `selector: {app: myservice}` in the same change that deletes the ServiceEntry. The Service needs ready pod endpoints at that moment. Creating it while the pods are still starting removes the VM and leaves the ClusterIP empty.
3. Mesh clients move from the auto-allocated VIP to the ClusterIP on the next push. Connections still aimed at the old VIP close.
4. Stop the host app with `sudo components/external-svc/host-app/run-external-app.sh stop`.

`workloadSelector` is the blended migration, and it does not install anything on the VM. It matches labels on two kinds of Kubernetes objects in the ServiceEntry namespace: Pods, and `WorkloadEntry` records. You apply a `WorkloadEntry` whose `address` is the VM IP and whose labels match the selector. Mesh clients then send to that IP. Deleting the `WorkloadEntry` drops the VM; labeled pods stay. Callers keep the ServiceEntry host the whole time, so that host has to be a name you own, such as `myservice.example.com`. A Service of the same name takes over a `*.svc.cluster.local` host, and the selector stops supplying endpoints.

The Istio proxy (Envoy plus `istio-agent`, usually a systemd unit on the guest) is a separate step. Add it when the VM should be a mesh peer: inbound mTLS, calls from the VM into the mesh, and the health bit istiod writes after the proxy connects. `serviceAccount` on the `WorkloadEntry` means clients expect that proxy's identity. Leave `serviceAccount` unset, and keep the ServiceEntry `MESH_EXTERNAL` or a DestinationRule at `DISABLE`, to reach a VM that is only a listening process.

### Tradeoffs

| | EndpointSlice behind the Service | ServiceEntry for the internal FQDN |
| --- | --- | --- |
| Callers | Mesh sidecars and plain pods. CoreDNS returns the same ClusterIP the whole time. | Mesh sidecars with DNS capture. Other clients resolve the name only after the Service exists. |
| Destination | One ClusterIP before and after. | Auto-allocated VIP, then the ClusterIP. |
| Overlap | The VM slice and the pod slice can both be ready. Set the VM `ready: false` to drain, then delete the slice. | The VM leaves rotation when the Service is created. The ServiceEntry has no ready flag left to drain with. |
| Data plane | OVN and kube-proxy send the ClusterIP to `192.168.130.50`. | The VM exists only in the Istio registry. |
| mTLS | DestinationRule `DISABLE` until meshed pods own the Service. | `MESH_EXTERNAL` stays plaintext without that DestinationRule. |
| Ownership | The future app chart and this directory share Service `myservice`. Keep that object. | The app chart creates the Service at cutover. The ServiceEntry has to leave in that same change. |
