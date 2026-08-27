#!/usr/bin/env python3
"""Summarize Istio sidecar injection for a Pod JSON document on stdin."""
from __future__ import annotations

import json
import sys


def main() -> None:
    variant = sys.argv[1] if len(sys.argv) > 1 else "unknown"
    pod = json.load(sys.stdin)
    ann = pod["metadata"].get("annotations", {})
    status = ann.get("sidecar.istio.io/status", "")
    native_ann = ann.get("sidecar.istio.io/nativeSidecar", "<unset>")
    proxy_cfg_ann = ann.get("proxy.istio.io/config", "<unset>")

    inits = pod["spec"].get("initContainers") or []
    containers = pod["spec"].get("containers") or []
    proxy_init = next((c for c in inits if c["name"] == "istio-proxy"), None)
    proxy_ct = next((c for c in containers if c["name"] == "istio-proxy"), None)
    app = next((c for c in containers if c["name"] == "drain-app"), None)
    proxy = proxy_init or proxy_ct

    print(f"variant: {variant}")
    print(f"pod: {pod['metadata']['name']}")
    print(f"annotation sidecar.istio.io/nativeSidecar: {native_ann}")
    print("annotation proxy.istio.io/config:")
    for line in str(proxy_cfg_ann).splitlines():
        print(f"  {line}")
    print(f"sidecar.istio.io/status: {status}")
    print(
        "istio-proxy location: "
        + (
            "initContainers"
            if proxy_init
            else "containers"
            if proxy_ct
            else "MISSING"
        )
    )
    if proxy:
        print(f"istio-proxy.restartPolicy: {proxy.get('restartPolicy', '<unset>')}")
        print("istio-proxy.lifecycle:")
        print(json.dumps(proxy.get("lifecycle"), indent=2))
        print("istio-proxy.startupProbe:")
        print(json.dumps(proxy.get("startupProbe"), indent=2))
        env = {e["name"]: e.get("value", "") for e in proxy.get("env") or []}
        print("istio-proxy.PROXY_CONFIG:")
        print(env.get("PROXY_CONFIG", "<missing>"))
    if app:
        print("drain-app.lifecycle:")
        print(json.dumps(app.get("lifecycle"), indent=2))
        print(
            "terminationGracePeriodSeconds: "
            f"{pod['spec'].get('terminationGracePeriodSeconds')}"
        )

    native = proxy_init is not None and proxy_init.get("restartPolicy") == "Always"
    lifecycle = (proxy or {}).get("lifecycle") or {}
    post = ((lifecycle.get("postStart") or {}).get("exec") or {}).get("command") or []
    pre = ((lifecycle.get("preStop") or {}).get("exec") or {}).get("command") or []
    print(f"RESULT native_sidecar={str(native).lower()}")
    print(f"RESULT postStart_wait={str('wait' in post).lower()}")
    print(f"RESULT preStop_drain={str('drain' in pre).lower()}")


if __name__ == "__main__":
    main()
