#!/usr/bin/env python3
"""Drain-aware HTTP server for Istio native-sidecar lifecycle tests.

Endpoints:
  GET /ready          503 if SIGTERM or /tmp/unhealthy exists (preStop), else 200
  GET /live           200 for the whole process lifetime
  GET /info           process state
  GET /sleep?seconds  hold the request, then 200 (in-flight drain demo)
"""
from __future__ import annotations

import os
import signal
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(os.environ.get("PORT", "8080"))
APP_DRAIN_SECONDS = float(os.environ.get("APP_DRAIN_SECONDS", "15"))
STARTUP_DELAY_SECONDS = float(os.environ.get("STARTUP_DELAY_SECONDS", "0"))
DRAIN_FLAG_FILE = os.environ.get("DRAIN_FLAG_FILE", "/tmp/unhealthy")
NAME = os.environ.get("HOSTNAME", "drain-app")

in_flight = 0
in_flight_lock = threading.Lock()
shutting_down = threading.Event()
started_at = time.time()


def not_ready() -> bool:
    return shutting_down.is_set() or os.path.exists(DRAIN_FLAG_FILE)


def log(msg: str) -> None:
    now = time.time()
    ms = int((now * 1000) % 1000)
    stamp = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(now))
    print(f"{stamp}.{ms:03d}Z [{NAME}] {msg}", flush=True)


def handle_term(signum: int, _frame: object) -> None:
    log(
        f"received signal {signum}; failing /ready and draining "
        f"in-flight requests for up to {APP_DRAIN_SECONDS}s"
    )
    shutting_down.set()

    def finish() -> None:
        deadline = time.time() + APP_DRAIN_SECONDS
        while time.time() < deadline:
            with in_flight_lock:
                n = in_flight
            remaining = deadline - time.time()
            log(f"drain in progress: in_flight={n} remaining={remaining:.1f}s")
            if n == 0:
                log("no in-flight requests; exiting")
                os._exit(0)
            time.sleep(min(1.0, max(0.1, remaining)))
        with in_flight_lock:
            n = in_flight
        log(f"drain timeout with in_flight={n}; exiting")
        os._exit(0)

    threading.Thread(target=finish, daemon=True).start()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args: object) -> None:
        log("http " + (fmt % args))

    def _send(self, code: int, body: str) -> None:
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:  # noqa: N802
        global in_flight
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)

        if parsed.path in ("/healthz", "/ready"):
            if not_ready():
                self._send(503, "shutting-down\n")
                return
            self._send(200, "ok\n")
            return

        if parsed.path == "/live":
            self._send(200, "ok\n")
            return

        if parsed.path == "/info":
            with in_flight_lock:
                n = in_flight
            uptime = time.time() - started_at
            self._send(
                200,
                (
                    f"name={NAME}\n"
                    f"uptime_seconds={uptime:.3f}\n"
                    f"shutting_down={shutting_down.is_set()}\n"
                    f"drain_flag={os.path.exists(DRAIN_FLAG_FILE)}\n"
                    f"in_flight={n}\n"
                    f"app_drain_seconds={APP_DRAIN_SECONDS}\n"
                ),
            )
            return

        if parsed.path == "/sleep":
            seconds = float(qs.get("seconds", ["5"])[0])
            if shutting_down.is_set():
                self._send(503, "shutting-down\n")
                return
            with in_flight_lock:
                in_flight += 1
            start = time.time()
            log(f"sleep start seconds={seconds} in_flight={in_flight}")
            try:
                time.sleep(seconds)
                elapsed = time.time() - start
                self._send(
                    200,
                    f"slept={elapsed:.3f}s shutting_down={shutting_down.is_set()}\n",
                )
                log(f"sleep done elapsed={elapsed:.3f}s")
            finally:
                with in_flight_lock:
                    in_flight -= 1
            return

        self._send(404, "not found\n")


if STARTUP_DELAY_SECONDS:
    log(f"startup delay {STARTUP_DELAY_SECONDS}s (not listening yet)")
    time.sleep(STARTUP_DELAY_SECONDS)

signal.signal(signal.SIGTERM, handle_term)
signal.signal(signal.SIGINT, handle_term)
log(f"listening on :{PORT} app_drain_seconds={APP_DRAIN_SECONDS}")
ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
