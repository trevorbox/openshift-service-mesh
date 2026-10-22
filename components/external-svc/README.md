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

## run siege pod

```sh
oc rsh -n golang-ex deploy/siege-runner
siege myservice.myservice
```

## Process

1. Deploy ServiceEntry with DNS proxying enabled
2. Deploy the application like normal (k8s service with selector). The Endpoints for pods won't be available in client Envoy until ready.
3. Remove ServiceEntry

```sh
tbox@tbox-thinkpadp1gen7:~/git/trevorbox/openshift-service-mesh$ istio
ctl pc endpoints siege-runner-5d67568b86-cch6w.golang-ex | grep myservice
192.168.130.50:8080                                     HEALTHY     OK                outbound|80||myservice.myservice.svc.cluster.local
tbox@tbox-thinkpadp1gen7:~/git/trevorbox/openshift-service-mesh$ git commit -am "Deploy app"
tbox@tbox-thinkpadp1gen7:~/git/trevorbox/openshift-service-mesh$ git push
tbox@tbox-thinkpadp1gen7:~/git/trevorbox/openshift-service-mesh$ istioctl pc endpoints siege-runner-5d67568b86-cch6w.golang-ex | grep myservice
10.217.0.122:8080                                       HEALTHY     OK                outbound|80||myservice.myservice.svc.cluster.local
192.168.130.50:8080                                     HEALTHY     OK                outbound|80||myservice.myservice.svc.cluster.local
tbox@tbox-thinkpadp1gen7:~/git/trevorbox/openshift-service-mesh$ git commit -am "remove ServiceEntry"
tbox@tbox-thinkpadp1gen7:~/git/trevorbox/openshift-service-mesh$ git push
tbox@tbox-thinkpadp1gen7:~/git/trevorbox/openshift-service-mesh$ istioctl pc endpoints siege-runner-5d67568b86-cch6w.golang-ex | grep myservice
10.217.0.122:8080                                       HEALTHY     OK                outbound|80||myservice.myservice.svc.cluster.local
```

Siege results...

```text
Lifting the server siege...
Transactions:               25284    hits
Availability:                 100.00 %
Elapsed time:                 147.16 secs
Data transferred:              12.28 MB
Response time:                145.06 ms
Transaction rate:             171.81 trans/sec
Throughput:                     0.08 MB/sec
Concurrency:                   24.92
Successful transactions:    25284
Failed transactions:            0
Longest transaction:          500.00 ms
Shortest transaction:           0.00 ms
```
