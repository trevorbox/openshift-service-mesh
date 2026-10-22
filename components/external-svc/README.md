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

## Process

1. Deploy ServiceEntry with DNS proxying enabled
2. Deploy the application like normal (k8s service with selector). The Endpoints for pods won't be available in client Envoy until ready.
3. Remove ServiceEntry

```sh

```

```text

```