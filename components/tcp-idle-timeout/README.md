# TCP idle timeout

Deploys a TCP client, a silent echo server, and a DestinationRule that sets [`connectionPool.tcp.idleTimeout`](https://istio.io/v1.28/docs/reference/config/networking/destination-rule/#ConnectionPoolSettings-TCPSettings-idle_timeout) to **10s**.

The timeout is the period with no bytes in either direction on the proxied connection. Istio programs it on the **client sidecar outbound TCP proxy** for `tcp-idle-server:9000`. It is not the HTTP pool timer (`connectionPool.http.idleTimeout`), and it is not applied to the server's inbound listener (that listener keeps Envoy's default of 1 hour).

The service port is named `tcp`. A port named `http` would build an HTTP connection manager instead, and this DestinationRule field would not be the timer under test.

`idleTimeout: 0s` disables the timer. If the field is omitted, Istio uses 1 hour. With weighted destinations the value is a property of the outbound listener, so only the first weighted route's `idleTimeout` is installed.

The target namespace must already be in the mesh (`istio.io/rev` or `istio-injection=enabled`). The manifests do not set a namespace.

```bash
oc apply -k components/tcp-idle-timeout -n <namespace>
oc get pods -n <namespace> -l app.kubernetes.io/part-of=tcp-idle-timeout
```

Keep `DestinationRule` `idleTimeout` and the client env `IDLE_TIMEOUT_SECONDS` equal. Both are `10s` / `10` in this component.

## Idle connection

From the client pod, send nothing and block in `recv` until the sidecar closes the socket. `eof after` should be about 10 seconds, and the script prints `PASS`.

```bash
oc exec -n <namespace> deploy/tcp-idle-client -c client -- python3 /scripts/client.py
```

Send one byte after 7 seconds. The server echoes it, which resets the timer, so the close should be about 17 seconds after connect (`7 + 10`), not 10.

```bash
oc exec -n <namespace> deploy/tcp-idle-client -c client -- python3 /scripts/client.py --send-after 7
```

`nc` from an image that blocks on stdin (busybox) can stay running after Envoy has already closed the socket. Use this script, or any client that blocks in a socket read.

## Config dump

Short version:

```bash
istioctl pc listener deploy/tcp-idle-client -n <namespace> --type TCP --port 9000 -o yaml
```

Example output:

```text
- address:
    socketAddress:
      address: 10.217.4.96
      portValue: 9000
  bindToPort: false
  continueOnListenerFiltersTimeout: true
  filterChains:
  - filters:
    - name: istio.stats
      typedConfig:
        '@type': type.googleapis.com/stats.PluginConfig
    - name: envoy.filters.network.tcp_proxy
      typedConfig:
        '@type': type.googleapis.com/envoy.extensions.filters.network.tcp_proxy.v3.TcpProxy
        accessLog:
        - name: envoy.access_loggers.file
          typedConfig:
            '@type': type.googleapis.com/envoy.extensions.access_loggers.file.v3.FileAccessLog
            logFormat:
              textFormatSource:
                inlineString: |
                  [%START_TIME%] "%REQ(:METHOD)% %REQ(X-ENVOY-ORIGINAL-PATH?:PATH)% %PROTOCOL%" %RESPONSE_CODE% %RESPONSE_FLAGS% %RESPONSE_CODE_DETAILS% %CONNECTION_TERMINATION_DETAILS% "%UPSTREAM_TRANSPORT_FAILURE_REASON%" %BYTES_RECEIVED% %BYTES_SENT% %DURATION% %RESP(X-ENVOY-UPSTREAM-SERVICE-TIME)% "%REQ(X-FORWARDED-FOR)%" "%REQ(USER-AGENT)%" "%REQ(X-REQUEST-ID)%" "%REQ(:AUTHORITY)%" "%UPSTREAM_HOST%"%UPSTREAM_CLUSTER_RAW% %UPSTREAM_LOCAL_ADDRESS% %DOWNSTREAM_LOCAL_ADDRESS% %DOWNSTREAM_REMOTE_ADDRESS% %REQUESTED_SERVER_NAME% %ROUTE_NAME%
            path: /dev/stdout
        cluster: outbound|9000||tcp-idle-server.test.svc.cluster.local
        idleTimeout: 10s
        statPrefix: outbound|9000||tcp-idle-server.test.svc.cluster.local
    transportSocketConnectTimeout: 15s
  listenerFiltersTimeout: 0s
  name: 10.217.4.96_9000
  trafficDirection: OUTBOUND
```

`idleTimeout` shows up as `idle_timeout` on the outbound listener whose address is the Service ClusterIP and port 9000. Confirm that before trusting a connection test.

```bash
NS=<namespace>
POD=$(oc get pod -n "$NS" -l app=tcp-idle-client -o jsonpath='{.items[0].metadata.name}')
CLUSTER_IP=$(oc get svc -n "$NS" tcp-idle-server -o jsonpath='{.spec.clusterIP}')

oc exec -n "$NS" "$POD" -c istio-proxy -- pilot-agent request GET config_dump \
  | CLUSTER_IP="$CLUSTER_IP" python3 -c '
import json, os, sys
ip = os.environ["CLUSTER_IP"]
dump = json.load(sys.stdin)
for cfg in dump["configs"]:
    if not cfg.get("@type", "").endswith("ListenersConfigDump"):
        continue
    for lst in cfg.get("dynamic_listeners", []):
        listener = lst.get("active_state", {}).get("listener", {})
        addr = listener.get("address", {}).get("socket_address", {})
        if addr.get("address") != ip or addr.get("port_value") != 9000:
            continue
        for chain in listener.get("filter_chains", []):
            for flt in chain.get("filters", []):
                typed = flt.get("typed_config", {})
                if typed.get("@type", "").endswith("TcpProxy"):
                    print("listener", lst.get("name"))
                    print("stat_prefix", typed.get("stat_prefix"))
                    print("cluster", typed.get("cluster"))
                    print("idle_timeout", typed.get("idle_timeout"))
'
```

Expect `idle_timeout` of `10s` and a `stat_prefix` of `outbound|9000||tcp-idle-server.<namespace>.svc.cluster.local`.

On the server sidecar, the `virtualInbound` filter chain for `inbound|9000||` has no `idle_timeout`. This DestinationRule does not set the inbound timer. A close at 10 seconds is the outbound proxy on the source workload.

`istioctl proxy-config listeners "$POD" -n "$NS" --port 9000 -o json` shows the same listener if `istioctl` is installed.

## Metrics

The client proxy config includes `proxyStatsMatcher.inclusionPrefixes: ["tcp."]`. Without that, Envoy does not publish the TCP proxy counters on the admin port.

The counter that increments when the idle timer fires is the outbound TCP proxy stat. The admin output keeps the Istio stat prefix as-is, including `|` and `.`:

```text
tcp.outbound|9000||tcp-idle-server.<namespace>.svc.cluster.local.idle_timeout
```

```bash
oc exec -n <namespace> deploy/tcp-idle-client -c istio-proxy -- \
  pilot-agent request GET 'stats?filter=idle_timeout'
```

After one idle `client.py` run the `tcp-idle-server` line is `1`. Each idle close increments it once. The same query lists `tcp.*.idle_timeout` for every outbound TCP listener on this sidecar; the others stay at 0 for this test.

The mesh `PodMonitor` `istio-proxies-monitor` already scrapes `istio-proxy` port `15020` at `/stats/prometheus`. No extra scrape config is required once `proxyStatsMatcher` includes `tcp.`. Envoy publishes the same counter as:

```text
envoy_tcp_idle_timeout{tcp_prefix="outbound|9000||tcp-idle-server.<namespace>.svc.cluster.local"}
```

```promql
envoy_tcp_idle_timeout{tcp_prefix=~"outbound\\|9000\\|\\|tcp-idle-server\\..+"}
```

`cluster.*.upstream_cx_idle_timeout` is the HTTP connection-pool idle counter. It stays 0 for this TCP test. Istio's `istio_tcp_connections_closed_total` series also does not record this event as response flag `SI`. Envoy 1.36 closes the session without setting that flag.

On a sidecar that does not already include `tcp.` in the stats matcher, add this annotation and restart the pod:

```yaml
proxy.istio.io/config: |
  proxyStatsMatcher:
    inclusionPrefixes:
    - "tcp."
```

The prometheus `envoy_tcp_idle_timeout` metric will now be able to be scraped automatically by prometheus pod-monitor.

The prometheus `istio_tcp_connections_closed_total` metric will also increment per source/destination combination.

## Logs

The client pod sets `sidecar.istio.io/componentLogLevel: misc:error,filter:debug`. The TCP proxy logs the idle close at debug on the `filter` logger. After an idle run:

```bash
oc logs -n <namespace> deploy/tcp-idle-client -c istio-proxy --since=1m | grep "Session timed out"
```

The line from Envoy 1.36 (Istio 1.28) looks like:

```text
debug envoy filter external/envoy/source/common/tcp_proxy/tcp_proxy.cc:1180 [Tags: "ConnectionId":"6"] Session timed out thread=16
```

Full request logs:

```test
2026-10-06T23:29:50.667849Z info Envoy proxy is ready
2026-10-06T23:29:57.452539Z debug envoy filter external/envoy/source/extensions/filters/listener/original_dst/original_dst.cc:69 original_dst: set destination to 10.217.4.96:9000 thread=16
2026-10-06T23:29:57.452650Z debug envoy filter external/envoy/source/common/tcp_proxy/tcp_proxy.cc:389 [Tags: "ConnectionId":"6"] new tcp proxy session thread=16
2026-10-06T23:29:57.452675Z debug envoy filter external/envoy/source/common/tcp_proxy/tcp_proxy.cc:602 [Tags: "ConnectionId":"6"] Creating connection to cluster outbound|9000||tcp-idle-server.test.svc.cluster.local thread=16
2026-10-06T23:29:57.457065Z debug envoy filter external/envoy/source/common/tcp_proxy/tcp_proxy.cc:1156 [Tags: "ConnectionId":"6"] TCP:onUpstreamEvent(), requestedServerName: thread=16
2026-10-06T23:30:14.453014Z debug envoy filter external/envoy/source/common/tcp_proxy/tcp_proxy.cc:1180 [Tags: "ConnectionId":"6"] Session timed out thread=16
[2026-10-06T23:29:57.452Z] "- - -" 0 - - - "-" 1 1 17000 - "-" "-" "-" "-" "10.217.0.185:9000" outbound|9000||tcp-idle-server.test.svc.cluster.local 10.217.0.250:48758 10.217.4.96:9000 10.217.0.250:44296 - -
```

Match `Session timed out` and `tcp_proxy.cc`. The line number can change across Envoy builds. This line is on the **source** sidecar. The server sidecar does not emit it for this 10s timeout, because its inbound TCP proxy is still on the 1 hour default. The client proxy closes both sides, so the server access log ends at the same moment.

To enable the same log on some other sidecar without restarting:

```bash
oc exec -n <namespace> <pod> -c istio-proxy -- \
  pilot-agent request POST 'logging?filter=debug'
```

`filter` here is the logger name, not a search string. Set it back with `logging?filter=info`. The equivalent annotation is `sidecar.istio.io/componentLogLevel: "misc:error,filter:debug"`.

The standard access log is supporting evidence only. A fully idle close looks like this (duration in milliseconds, both byte counts 0):

```text
"- - -" 0 - - - "-" 0 0 10005 ... outbound|9000||tcp-idle-server.<namespace>.svc.cluster.local
```

`%RESPONSE_FLAGS%` stays `-`. There is no `SI` flag for this timeout on Envoy 1.36.
