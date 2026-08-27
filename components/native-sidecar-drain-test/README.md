# Native sidecar drain test

Demonstrates Kubernetes native sidecar lifecycle on OpenShift Service Mesh 3 / Istio 1.28, and what still has to be configured for a workload to drain in-flight requests on termination.

The [Istio discussion #53174](https://github.com/istio/istio/discussions/53174) asked whether `holdApplicationUntilProxyStarts` and `terminationDrainDuration` are still required after enabling native sidecars. Howard John's reply was:

> Neither is needed, and I think both are entirely ignored when this is set. Both of those variables were effectively workarounds for the lack of native sidecars in Istio.

That is **half right**. This component makes the distinction observable on a live cluster.

## What this cluster is actually running

On `crc-ossm3` (OpenShift 4.20.5 / Kubernetes **v1.33.5**, Istio **1.28.5**):

* `ENABLE_NATIVE_SIDECARS` is **not** set on istiod. Istio 1.27+ defaults to `auto`, which enables native sidecars when every node kubelet is >= 1.33. See the [1.27 upgrade notes](https://istio.io/latest/news/releases/1.27.x/announcing-1.27/upgrade-notes/) and [issue #57587](https://github.com/istio/istio/issues/57587).
* Injected workloads therefore get `istio-proxy` as an **initContainer** with `restartPolicy: Always` (KEP-753 native sidecar), not as a regular container.
* The proxy has a **startupProbe** on `/healthz/ready:15021` (kubelet will not start app containers until that succeeds) and a **preStop** hook `pilot-agent request --debug-port=15020 POST drain`.

Force or pin the mode per pod with `sidecar.istio.io/nativeSidecar: "true"|"false"`. Mesh-wide override remains `values.pilot.env.ENABLE_NATIVE_SIDECARS` (`true` / `false` / `auto`).

### Init containers that Istio injects

There are two init containers. Only the second is the native sidecar.

| Init container | `restartPolicy` | Role |
|---|---|---|
| `istio-validation` | unset (run-once) | `istio-iptables --run-validation --skip-rule-apply` because Istio CNI is enabled. Not a sidecar. |
| `istio-proxy` | `Always` | Native sidecar. `pilot-agent proxy sidecar`. Stays running for the pod lifetime. |

`istio-proxy` args and hooks observed on `native-default`:

```text
args: proxy sidecar --domain $(POD_NAMESPACE).svc.cluster.local
      --proxyLogLevel=info --proxyComponentLogLevel=misc:error
      --log_output_level=default:info
restartPolicy: Always
startupProbe:  HTTP GET :15021/healthz/ready  (period 1s, failureThreshold 600)
readinessProbe: HTTP GET :15021/healthz/ready (period 15s)
lifecycle.preStop: pilot-agent request --debug-port=15020 POST drain
```

Start order on a replacement `native-default` pod: `istio-validation` completes, `istio-proxy` becomes ready, then `drain-app` starts (`startedAt` was 4s later). That gap is kubelet waiting on the proxy startupProbe — this is what replaced `holdApplicationUntilProxyStarts`.

## Variants

| Deployment | Sidecar | Extra flags | Purpose |
|---|---|---|---|
| `native-default` | cluster auto (no pin) | app `preStop: sleep 5` | recommended native pattern |
| `native-legacy-flags` | `nativeSidecar: "true"` | `holdApplicationUntilProxyStarts: true` and `terminationDrainDuration: 45s` | prove those knobs do not change native hooks / do not stall exit |
| `classic-hold` | `nativeSidecar: "false"` | same two flags | contrast: `postStart: pilot-agent wait` is injected |
| `curl` | native (auto) | client | in-mesh caller for the drain test |

## Hold and drain: what is ignored, what is not

The 1.28 injection template (also on this cluster in `istio-sidecar-injector-default-v1-28-5`) is:

```yaml
{{- $holdProxy := and
    (or .ProxyConfig.HoldApplicationUntilProxyStarts.GetValue .Values.global.proxy.holdApplicationUntilProxyStarts)
    (not $nativeSidecar) }}
...
{{- if .Values.global.proxy.lifecycle }}
  lifecycle: {{ toYaml .Values.global.proxy.lifecycle }}
{{- else if $holdProxy }}
  lifecycle:
    postStart:
      exec:
        command: ["pilot-agent", "wait"]
{{- else if $nativeSidecar }}
  lifecycle:
    preStop:
      exec:
        command: ["pilot-agent", "request", "--debug-port=15020", "POST", "drain"]
{{- end }}
```

| Setting | Native sidecar | Classic sidecar |
|---|---|---|
| `holdApplicationUntilProxyStarts` | **Ignored.** `$holdProxy` is forced false. Kubelet + `startupProbe` replace `postStart wait`. | Honored: injects `postStart: pilot-agent wait`. |
| `terminationDrainDuration` | **Not ignored**, but it does not keep the proxy alive after the app exits. Drain starts at pod deletion via `preStop POST /drain`. After the app container exits, the proxy gets SIGTERM and typically logs `Agent already drained, exiting immediately`. Default is still **5s** if the proxy is not already drained. | Honored as the SIGTERM wait (default 5s). |
| `global.proxy.lifecycle` | **Replaces** the native `preStop` drain hook. Do not set this unless you intend to own shutdown. | Replaces `postStart wait`. |

Related knobs that still exist and are *not* native-sidecar workarounds:

* `sidecar.istio.io/nativeSidecar` — pin native vs classic.
* App `lifecycle.preStop` sleep (typically 5s) — wait for EndpointSlice propagation before SIGTERM. This is a Kubernetes practice, not an Istio flag.
* App SIGTERM handling — finish in-flight work, fail readiness, then exit. Native sidecars keep the proxy up until the **app** exits, so the app is what actually drains.
* `terminationGracePeriodSeconds` — must exceed app preStop + app drain. The proxy then exits immediately.
* `EXIT_ON_ZERO_ACTIVE_CONNECTIONS` / `MINIMUM_DRAIN_DURATION` — only matter once the proxy itself is in SIGTERM. With native sidecars that is after the app is already gone, so they are usually unnecessary.
* `global.proxy.startupProbe` — enabled by default (`failureThreshold: 600`). This is what makes native startup ordering wait for a **ready** Envoy, not merely a started process.

## Graceful termination lifecycle

Startup (for context): kubelet runs `istio-validation`, then starts `istio-proxy` (`restartPolicy: Always`). App containers start only after the proxy `startupProbe` (`GET :15021/healthz/ready`) succeeds. That replaces `holdApplicationUntilProxyStarts`.

Shutdown uses Kubernetes native-sidecar ordering ([KEP-753](https://istio.io/latest/blog/2023/native-sidecars/), [istio/istio#60649](https://github.com/istio/istio/issues/60649)). The proxy is **not** SIGTERM'd with the app. Clock starts at pod delete and ends at `terminationGracePeriodSeconds` (then SIGKILL).

1. **Pod delete** — `deletionTimestamp` is set. The EndpointSlice controller marks the endpoint terminating / not ready. Mesh clients keep sending until Istiod pushes EDS (eventually consistent; this is the race the app `preStop` sleep covers).
2. **`istio-proxy` `preStop`** — runs immediately: `pilot-agent request POST /drain`. Envoy starts draining now (`connection: close` / HTTP2 GOAWAY). In-flight streams still proxy to the app. Log: `handling /drain, starting drain`. This is **not** proxy SIGTERM.
3. **App `preStop`** (if set) — typically fail `/ready`, then `sleep 5–15s`, so EDS can catch up while the process is still serving. Without this, SIGTERM hits the app at the same moment as step 2.
4. **App SIGTERM** — kubelet signals regular containers only after their `preStop` finishes. The app must finish in-flight work, reject new requests, keep liveness passing, then exit. Envoy is still up and still draining.
5. **App exits** — native sidecar stays running until every regular container has exited.
6. **`istio-proxy` SIGTERM** — only now. `POST /drain` (step 2) calls `DrainNow()`, which starts Envoy drain and sets `skipDrain` **immediately** (not when connections hit zero). SIGTERM then always logs `Agent already drained, exiting immediately` and **aborts Envoy** — it does **not** wait `terminationDrainDuration`, even if Envoy is still draining. Istio’s own comment: native sidecar `/drain` runs at pod shutdown and drains forever; once the app exits, “we have no use to run anymore, so shutdown immediately.”
   A slow drain is therefore **not** a reason to raise `terminationDrainDuration` on an injected app. Keep the **app** alive until in-flight work is done (SIGTERM handler + grace). Envoy `--drain-time-s` (`drainDuration`, default 45s) only applies while the proxy process is still running (steps 2–5).
   `terminationDrainDuration` is used only when `skipDrain` is still false: no `POST /drain` (classic sidecar, gateway, `global.proxy.lifecycle` override, or preStop never hit the agent). Then the agent waits that duration (default 5s) and aborts.
7. **Grace period exceeded** — kubelet SIGKILLs whatever is left. In-flight requests die.

```
delete ─► EDS not-ready (async)
       ─► proxy preStop: POST /drain          Envoy draining, app still running
       ─► app preStop: fail ready + sleep     wait for client EDS
       ─► app SIGTERM → finish in-flight → exit
       ─► proxy SIGTERM → already drained → exit
```

Classic sidecars skip steps 5–6: proxy and app get SIGTERM together, so `terminationDrainDuration` was the workaround to keep Envoy alive during app shutdown. Native sidecars make that wait unnecessary for apps.

See also the [native sidecars blog](https://istio.io/latest/blog/2023/native-sidecars/).

## Recommendations (injected native sidecars)

Native sidecars keep Envoy up until the **app process exits**. Istio `POST /drain` only discourages new connections (GOAWAY / `connection: close`). It does not finish in-flight work after the app is gone, and it does not wait for Istiod EDS to drop the pod. Configure the **application pod**, not Istio lifecycle flags.

`preStop` is a **single** exec. `sleep` does not fail probes. Fail readiness **first**, then sleep, in one `sh -c`. `touch` only works if `/ready` (or an exec probe) checks that file. Use `readinessProbe.periodSeconds: 1` so kubelet notices during the sleep. Keep `/live` passing so kubelet does not SIGKILL mid-drain.

**Why fail readiness in `preStop` (not only sleep, not only SIGTERM):**

Pod delete starts two clocks at once: Istio’s proxy `preStop` sends Envoy GOAWAY / `connection: close` **immediately**, while Istiod EDS (and kube-proxy) still list this pod until EndpointSlice updates propagate (`PILOT_DEBOUNCE_MAX` is 10s). Clients that get GOAWAY open a new connection and can land on the **same** pod if it is still Ready and still in EDS.

- **Sleep alone** keeps `/ready` at 200 for the whole wait. Kubelet Ready stays true. You are only hoping EDS wins the race.
- **Fail `/ready` first, then sleep** so the next probe (1s) sets Ready=false **while the process is still up**. In-flight requests continue; new Service/EDS consumers should stop. The sleep is the cushion for Istiod to push that update.
- **Fail `/ready` only on SIGTERM** is too late: that is after `preStop` finished, so you never advertised not-ready during the wait.

Istiod also sees EndpointSlice `terminating` at delete, independent of probes. Failing Ready is still encouraged because terminating-but-Ready is a weaker “don’t send new traffic” signal than Ready=false, and anything watching the pod Ready condition (kubelet, some platform probes, non-mesh Services) will not wait for Istiod.

```yaml
spec:
  template:
    spec:
      terminationGracePeriodSeconds: 40   # > preStop + app drain
      containers:
      - name: app
        lifecycle:
          preStop:
            exec:
              command: ["/bin/sh", "-c", "touch /tmp/unhealthy; sleep 5"]
        readinessProbe:
          httpGet: { path: /ready, port: http }   # 503 when /tmp/unhealthy exists
          periodSeconds: 1
        livenessProbe:
          httpGet: { path: /live, port: http }    # still 200 while finishing in-flight
```

Istiod EDS mainly follows EndpointSlice **terminating** (set at delete). The fail-ready + sleep pattern is how the **app** participates in that race: not-ready for new traffic, still alive for in-flight, long enough for EDS. Equivalent to `touch`: `curl -sf http://127.0.0.1:8080/drain` if the app has a drain URL that makes `/ready` return 503 without exiting.

| Do | Why |
|---|---|
| Handle SIGTERM: finish in-flight, reject new requests, then exit | Proxy SIGTERM happens only after the app exits. This is the actual drain. |
| App `preStop`: fail readiness, then sleep ~5–15s (same `sh -c`) | Envoy GOAWAYs at delete while EDS is still catching up. Sleep alone leaves Ready=true so clients can reconnect here. Failing `/ready` first advertises not-ready during the wait; SIGTERM is too late (after `preStop`). |
| `terminationGracePeriodSeconds` > preStop + drain budget | Kubelet SIGKILLs when grace expires. Too short cuts in-flight requests. |
| Rolling update `maxUnavailable: 0` (or surge) | A Ready replacement must exist before the old pod is deleted. |
| Leave `holdApplicationUntilProxyStarts` unset | Ignored on native sidecars. Kubelet + proxy `startupProbe` already order startup. |
| Leave `terminationDrainDuration` at default (5s) on **apps** | Drain already started in proxy `preStop`. After app exit the agent exits immediately (`already drained`). Raising it does not keep serving. |
| Raise `terminationDrainDuration` on **gateways** (ingress, east-west, waypoint) | The gateway pod *is* Envoy; SIGTERM is stop-serving. Default 5s aborts in-flight work even when grace is 30s. [Details](#gateways-and-terminationdrainduration). |
| Do not set `global.proxy.lifecycle` | It replaces the injected `preStop POST /drain` hook. |
| Avoid `publishNotReadyAddresses: true` unless required | Keeps terminating/not-ready pods in the Service. |
| Pin `sidecar.istio.io/nativeSidecar: "true"` on Jobs and anything that must not flip | Cluster default is `auto` (on when every kubelet is ≥ 1.33). |

TCP and other non-HTTP protocols do not get GOAWAY; they depend on EDS removal plus the app closing connections. Headless / pod-IP callers never leave a Service endpoint set, so the sleep does not unregister them.

Do not confuse Envoy `--drain-time-s` (mesh `drainDuration`, default 45s, how long Envoy drains **after** `POST /drain` while the app is still up) with `terminationDrainDuration` (agent wait after **proxy** SIGTERM). Long requests need the app to stay up inside that Envoy window, not a larger agent wait.

## Gateways and `terminationDrainDuration`

Injected app pods have an application container. Native sidecars start drain in `preStop` and only SIGTERM the proxy **after the app exits**, so raising `terminationDrainDuration` does not keep serving.

A gateway pod **is** Envoy. On this cluster `istio-ingressgateway` is a single `istio-proxy` container (no native-sidecar init, `terminationGracePeriodSeconds: 30`). There is no app process to drain. SIGTERM *is* stop-serving.

What happens on gateway delete:

1. Endpoint / node-port / Route backend is marked terminating (async). External clients (browsers, `curl`, OpenShift HAProxy in front of the gateway) keep sending until that catch-up finishes.
2. Kubelet SIGTERMs `istio-proxy` (no “wait for another container”).
3. Pilot-agent starts Envoy drain and **sleeps `terminationDrainDuration`**, then aborts Envoy.
4. Default is **5s**. After that, in-flight requests get RST even if grace is 30s.

Configure it when gateway-held work can last longer than 5s: slow clients, large uploads, SSE/streaming, long HTTP/2, or a fronting load balancer that is slower than in-mesh EDS. Set:

```text
terminationDrainDuration  <  terminationGracePeriodSeconds
```

Example: 25s drain with 30s grace leaves 5s for SIGKILL. Leaving grace at 30s and drain at 5s wastes the grace window and drops requests that would have finished.

Same rule for east-west, egress, and waypoint gateways: each is a dedicated proxy Deployment, not a sidecar in front of an app.

## Deploy and test

Namespace must be labeled `istio.io/rev=default` (GitOps: add it to `clusters/crc-ossm3/overlays/istio-member-namespaces/values.yaml`).

```sh
# local apply (does not require a git push)
./components/native-sidecar-drain-test/test-drain.sh all
```

Subcommands: `apply`, `inspect`, `drain`.

`inspect` asserts:

* `native-default` and `native-legacy-flags`: `istio-proxy` is an init container with `restartPolicy: Always`, **no** `postStart wait`, **yes** `preStop drain` — even when `holdApplicationUntilProxyStarts: true`.
* `classic-hold`: `istio-proxy` is a regular container with `postStart: pilot-agent wait`.

`drain` starts `GET /sleep?seconds=8` from the in-mesh `curl` pod, deletes the target pod, and expects HTTP 200. For `native-legacy-flags` it also checks that the pod is gone in well under the configured 45s `terminationDrainDuration`.

## Observed on crc-ossm3

`inspect` matched the table above. `holdApplicationUntilProxyStarts: true` on `native-legacy-flags` was written into `PROXY_CONFIG` but did **not** inject `postStart: wait`. The same annotation on `classic-hold` did inject it.

`drain` against `native-legacy-flags` (`terminationDrainDuration: 45s`, no app preStop):

```text
23:03:11.427  app: sleep start seconds=8
23:03:13.375  app: SIGTERM (signal 15)
23:03:13.603  istio-proxy: handling /drain, starting drain     # preStop
23:03:19.427  app: sleep done (HTTP 200 to curl)
23:03:20.377  app: no in-flight requests; exiting
23:03:20.493  istio-proxy: Agent already drained, exiting immediately
pod deleted in 8s   # not 45s
```

`native-default` (app `preStop: sleep 5`) completed the same in-flight request; SIGTERM arrived ~5s after `POST /drain`, then the proxy again exited immediately after the app.

Do not confuse Envoy's `--drain-time-s 45` (mesh `drainDuration`, default 45s, always present in the Envoy command line) with `terminationDrainDuration` (pilot-agent wait after SIGTERM, default 5s). Native sidecar shutdown skipped the agent wait because drain had already been started by `preStop`.

## Images

The drain app uses the in-cluster Python imagestream (`openshift/python:3.12-ubi9`) so CRC does not have to pull from `registry.redhat.io`. The client reuses `curlimages/curl:latest` already present on this cluster.
