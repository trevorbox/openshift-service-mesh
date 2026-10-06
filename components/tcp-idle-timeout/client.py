#!/usr/bin/env python3
"""Open one TCP connection and report when the peer closes it.

Default mode sends nothing. The sidecar should close the connection after
IDLE_TIMEOUT_SECONDS (the DestinationRule tcp idleTimeout).

--send-after N sends one byte after N seconds. The echo resets the idle
timer, so the close should be about N + IDLE_TIMEOUT_SECONDS after connect.
"""

import argparse
import os
import socket
import sys
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--host",
        default=os.environ.get("TCP_IDLE_HOST", "tcp-idle-server"),
    )
    parser.add_argument(
        "--port",
        type=int,
        default=int(os.environ.get("TCP_IDLE_PORT", "9000")),
    )
    parser.add_argument(
        "--send-after",
        type=float,
        default=None,
        help="send one byte after this many seconds, then wait for close",
    )
    parser.add_argument(
        "--expect",
        type=float,
        default=float(os.environ.get("IDLE_TIMEOUT_SECONDS", "10")),
        help="configured tcp idleTimeout, in seconds",
    )
    parser.add_argument(
        "--tolerance",
        type=float,
        default=2.0,
        help="allowed error, in seconds, between expected and actual close",
    )
    args = parser.parse_args()

    sock = socket.create_connection((args.host, args.port), timeout=10)
    start = time.monotonic()
    print(f"connected to {args.host}:{args.port}", flush=True)

    expected = args.expect
    if args.send_after is not None:
        time.sleep(args.send_after)
        sock.sendall(b"x")
        sent_at = time.monotonic() - start
        print(f"sent 1 byte at {sent_at:.3f}s", flush=True)
        expected = args.send_after + args.expect

    sock.settimeout(expected + 15)
    try:
        while True:
            data = sock.recv(16)
            elapsed = time.monotonic() - start
            if data == b"":
                print(f"eof after {elapsed:.3f}s (expect {expected:.1f}s)", flush=True)
                if abs(elapsed - expected) <= args.tolerance:
                    print("PASS", flush=True)
                    return 0
                print("FAIL", flush=True)
                return 1
            print(f"data {data!r} at {elapsed:.3f}s", flush=True)
    except socket.timeout:
        elapsed = time.monotonic() - start
        print(f"still open after {elapsed:.3f}s (expect close near {expected:.1f}s)", flush=True)
        print("FAIL", flush=True)
        return 1
    finally:
        sock.close()


if __name__ == "__main__":
    sys.exit(main())
