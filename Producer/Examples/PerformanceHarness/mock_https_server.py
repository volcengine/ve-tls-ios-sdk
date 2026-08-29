#!/usr/bin/env python3
"""Fixed-delay HTTPS fixture for the producer comparison harness.

The process never logs request headers, bodies, paths, or credentials. Its
only evidence is numeric request/body-byte counters split by SDK wire path.
"""

import argparse
import http.server
import json
import os
import signal
import ssl
import threading
import time


class Counters:
    def __init__(self):
        self.lock = threading.Lock()
        self.reset()

    def reset(self):
        with getattr(self, "lock", threading.Lock()):
            self.started_epoch_milliseconds = round(time.time() * 1000)
            self.last_data_epoch_milliseconds = None
            self.data_request_count = 0
            self.tls_request_count = 0
            self.sls_request_count = 0
            self.body_bytes = 0
            self.tls_body_bytes = 0
            self.sls_body_bytes = 0

    def record(self, sdk, body_bytes):
        with self.lock:
            self.data_request_count += 1
            self.body_bytes += body_bytes
            self.last_data_epoch_milliseconds = round(time.time() * 1000)
            if sdk == "tls":
                self.tls_request_count += 1
                self.tls_body_bytes += body_bytes
            else:
                self.sls_request_count += 1
                self.sls_body_bytes += body_bytes
            return self.data_request_count

    def snapshot(self):
        with self.lock:
            return {
                "schemaVersion": 1,
                "startedEpochMilliseconds": self.started_epoch_milliseconds,
                "lastDataEpochMilliseconds": self.last_data_epoch_milliseconds,
                "dataRequestCount": self.data_request_count,
                "tlsRequestCount": self.tls_request_count,
                "slsRequestCount": self.sls_request_count,
                "bodyBytes": self.body_bytes,
                "tlsBodyBytes": self.tls_body_bytes,
                "slsBodyBytes": self.sls_body_bytes,
            }


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, delay_seconds):
        super().__init__(address, Handler)
        self.delay_seconds = delay_seconds
        self.counters = Counters()

    def handle_error(self, request, client_address):
        return


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format_string, *args):
        return

    def _read_body(self):
        try:
            remaining = max(0, int(self.headers.get("Content-Length", "0")))
        except ValueError:
            remaining = 0
        total = 0
        while remaining:
            chunk = self.rfile.read(min(remaining, 64 * 1024))
            if not chunk:
                break
            total += len(chunk)
            remaining -= len(chunk)
        return total

    def _send(self, status, headers=None, body=b""):
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "keep-alive")
        if headers:
            for key, value in headers.items():
                self.send_header(key, value)
        self.end_headers()
        if body:
            self.wfile.write(body)
        self.wfile.flush()

    def do_GET(self):
        if self.path == "/__stats":
            body = json.dumps(
                self.server.counters.snapshot(),
                sort_keys=True,
                separators=(",", ":"),
            ).encode("ascii")
            self._send(200, {"Content-Type": "application/json"}, body)
            return
        if self.path == "/__reset":
            self.server.counters.reset()
            self._send(204)
            return
        if self.path == "/servertime":
            self._send(200, {"x-log-time": str(int(time.time()))})
            return
        self._send(404)

    def do_POST(self):
        if self.path.startswith("/PutLogs?") or self.path == "/PutLogs":
            sdk = "tls"
        elif self.path.startswith("/logstores/"):
            sdk = "sls"
        else:
            self._read_body()
            self._send(404)
            return

        body_bytes = self._read_body()
        request_number = self.server.counters.record(sdk, body_bytes)
        time.sleep(self.server.delay_seconds)
        request_id = "performance-%d" % request_number
        self._send(
            200,
            {
                "x-tls-requestid": request_id,
                "x-log-requestid": request_id,
                "x-log-time": str(int(time.time())),
            },
        )


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cert", required=True)
    parser.add_argument("--key", required=True)
    parser.add_argument("--ready-file", required=True)
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--delay-milliseconds", type=float, default=5.0)
    return parser.parse_args()


def main():
    args = parse_args()
    if args.delay_milliseconds < 0:
        raise SystemExit("delay must be non-negative")
    server = Server(("127.0.0.1", args.port), args.delay_milliseconds / 1000.0)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(args.cert, args.key)
    server.socket = context.wrap_socket(server.socket, server_side=True)

    ready = {
        "port": server.server_address[1],
        "delayMilliseconds": args.delay_milliseconds,
    }
    os.makedirs(os.path.dirname(os.path.abspath(args.ready_file)), exist_ok=True)
    temporary = args.ready_file + ".tmp"
    with open(temporary, "w", encoding="ascii") as output:
        json.dump(ready, output, sort_keys=True, separators=(",", ":"))
        output.write("\n")
    os.replace(temporary, args.ready_file)

    def stop(signum, frame):
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    print("READY", flush=True)
    try:
        server.serve_forever(poll_interval=0.1)
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
