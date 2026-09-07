#!/usr/bin/env python3
"""Local HTTPS/HTTP redirect fixture for iOS Simulator integration tests.

The fixture starts four listeners:

* source HTTPS origin, where the Producer sends the initial PutLogs request;
* cross-host HTTPS target (127.0.0.1 instead of localhost);
* cross-scheme HTTP target;
* cross-port HTTPS target (same host, different port).

The redirect decision is selected by the TopicId query value. Every POST is
recorded in a role-specific JSONL file containing exactly one field:
``{"authorization_present": true|false}``. Request headers and bodies are
never written or logged. The response contains only a fixed, non-sensitive
request ID and no response body. The source HTTPS listener also exposes a
fixed ``/__evidence`` JSON response containing the in-memory boolean arrays;
that endpoint never records a request.
"""

import argparse
import http.server
import json
import os
import signal
import ssl
import sys
import threading
import time
import urllib.parse


class FixtureState:
    def __init__(self, record_dir, topics, recovery_release_file=None,
                 recovery_topic="recovery"):
        self.record_dir = os.path.abspath(record_dir)
        self.topics = topics
        self.recovery_release_file = (
            os.path.abspath(recovery_release_file)
            if recovery_release_file
            else None
        )
        self.recovery_topic = recovery_topic
        self.ports = {}
        self.redirects = {}
        self.final_paths = {
            "/same-origin-final",
            "/cross-host-final",
            "/cross-scheme-final",
            "/cross-port-final",
        }
        self.record_lock = threading.Lock()
        # XCTest runs inside the simulator and cannot read the host's record
        # directory. Keep the evidence in memory and expose only this
        # fixed-shape boolean snapshot through the source HTTPS listener.
        self.authorization = {
            "source": [],
            "cross_host": [],
            "cross_scheme": [],
            "cross_port": [],
        }

    def configure_redirects(self):
        self.redirects = {
            self.topics["same-origin"]: (
                "https://localhost:%d/same-origin-final" % self.ports["source"]
            ),
            self.topics["cross-host"]: (
                "https://127.0.0.1:%d/cross-host-final"
                % self.ports["cross-host"]
            ),
            self.topics["cross-scheme"]: (
                "http://localhost:%d/cross-scheme-final"
                % self.ports["cross-scheme"]
            ),
            self.topics["cross-port"]: (
                "https://localhost:%d/cross-port-final"
                % self.ports["cross-port"]
            ),
        }

    def record(self, role, authorization_present):
        os.makedirs(self.record_dir, mode=0o700, exist_ok=True)
        path = os.path.join(self.record_dir, "%s.jsonl" % role)
        role_key = role.replace("-", "_")
        present = bool(authorization_present)
        line = json.dumps(
            {"authorization_present": present},
            separators=(",", ":"),
        )
        with self.record_lock:
            self.authorization[role_key].append(present)
            with open(path, "a", encoding="ascii") as output:
                output.write(line)
                output.write("\n")
                output.flush()
                os.fsync(output.fileno())

    def evidence_snapshot(self):
        with self.record_lock:
            return {
                role: list(values)
                for role, values in self.authorization.items()
            }


class FixtureHTTPServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, role, state):
        self.role = role
        self.state = state
        super().__init__(address, FixtureRequestHandler)

    def handle_error(self, request, client_address):
        # Keep malformed-client tracebacks (which can include request
        # metadata) out of the fixture's output as well.
        return


class FixtureRequestHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format_string, *args):
        # BaseHTTPRequestHandler would otherwise print paths/statuses. Keep
        # the fixture output free of request metadata and header values.
        return

    def _consume_body(self):
        raw_length = self.headers.get("Content-Length")
        try:
            length = int(raw_length) if raw_length else 0
        except ValueError:
            length = 0
        remaining = max(0, length)
        while remaining:
            chunk = self.rfile.read(min(remaining, 64 * 1024))
            if not chunk:
                break
            remaining -= len(chunk)

    def _send(self, status, headers=None, body=b""):
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        if headers:
            for key, value in headers.items():
                self.send_header(key, value)
        self.end_headers()
        if body:
            self.wfile.write(body)
        self.close_connection = True

    def do_GET(self):
        # Only the source HTTPS listener exposes evidence. The path is fixed,
        # query strings are rejected, and GET never enters authorization
        # records. The response body contains only four boolean arrays.
        if self.server.role != "source" or self.path != "/__evidence":
            self._send(404)
            return
        body = json.dumps(
            self.server.state.evidence_snapshot(),
            sort_keys=True,
            separators=(",", ":"),
        ).encode("ascii")
        self._send(
            200,
            {"Content-Type": "application/json"},
            body,
        )

    def do_POST(self):
        state = self.server.state
        role = self.server.role
        # Header presence is the only request fact that crosses the fixture's
        # process boundary. The raw value is never read into a log or output.
        state.record(role, self.headers.get("Authorization") is not None)
        self._consume_body()

        parsed = urllib.parse.urlsplit(self.path)
        if parsed.path in state.final_paths:
            self._send(
                200,
                {"x-tls-request-id": "redirect-fixture-success"},
            )
            return

        if parsed.path != "/PutLogs":
            self._send(404)
            return

        query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
        topic_values = query.get("TopicId", [])
        topic = topic_values[0] if topic_values else ""

        if (
            topic == state.recovery_topic
            and state.recovery_release_file is not None
        ):
            # Do not return 503 while seeding: that would let the Core consume
            # its retry budget before the host observes the seed marker and
            # terminates the app. Keep this request without a terminal HTTP
            # response until the host creates the release gate. The 30-second
            # ceiling is longer than the harness's expected seed/terminate
            # interval but still bounds a misconfigured fixture.
            deadline = time.monotonic() + 30.0
            while (
                not os.path.isfile(state.recovery_release_file)
                and time.monotonic() < deadline
            ):
                time.sleep(0.05)
            if not os.path.isfile(state.recovery_release_file):
                self._send(503)
                return
            self._send(
                200,
                {"x-tls-request-id": "redirect-fixture-recovery"},
            )
            return

        location = state.redirects.get(topic)
        if location is None:
            self._send(404)
            return
        self._send(
            307,
            {
                "Location": location,
                "x-tls-request-id": "redirect-fixture-redirect",
            },
        )


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cert", required=True, help="server certificate PEM")
    parser.add_argument("--key", required=True, help="server private key PEM")
    parser.add_argument("--record-dir", required=True)
    parser.add_argument("--ready-file")
    parser.add_argument("--source-port", type=int, default=0)
    parser.add_argument("--cross-host-port", type=int, default=0)
    parser.add_argument("--cross-scheme-port", type=int, default=0)
    parser.add_argument("--cross-port", type=int, default=0)
    parser.add_argument("--same-origin-topic", default="same-origin")
    parser.add_argument("--cross-host-topic", default="cross-host")
    parser.add_argument("--cross-scheme-topic", default="cross-scheme")
    parser.add_argument("--cross-port-topic", default="cross-port")
    parser.add_argument(
        "--recovery-release-file",
        help="host-only release marker for the optional recovery gate",
    )
    parser.add_argument("--recovery-topic", default="recovery")
    return parser.parse_args(argv)


def make_server(port, role, state, secure, certificate):
    server = FixtureHTTPServer(("127.0.0.1", port), role, state)
    if secure:
        cert, key = certificate
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(certfile=cert, keyfile=key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
    return server


def write_ready_file(path, state):
    metadata = {
        "endpoint": "https://localhost:%d" % state.ports["source"],
        "evidence_url": "https://localhost:%d/__evidence" % state.ports["source"],
        # Do not put host paths (including a recovery marker) in metadata
        # consumed by the simulator. The host launcher already owns them.
        "recovery_supported": state.recovery_release_file is not None,
    }
    if path:
        parent = os.path.dirname(os.path.abspath(path))
        if parent:
            os.makedirs(parent, exist_ok=True)
        temporary = path + ".tmp"
        with open(temporary, "w", encoding="utf-8") as output:
            json.dump(metadata, output, sort_keys=True, separators=(",", ":"))
            output.write("\n")
        os.replace(temporary, path)

    print("READY")
    print("TLS_REDIRECT_ENDPOINT=%s" % metadata["endpoint"])
    print("TLS_REDIRECT_EVIDENCE_URL=%s" % metadata["evidence_url"])
    print(
        "TLS_REDIRECT_RECOVERY_SUPPORTED=%s"
        % ("1" if metadata["recovery_supported"] else "0")
    )
    sys.stdout.flush()


def run(args):
    if not os.path.isfile(args.cert) or not os.path.isfile(args.key):
        raise RuntimeError("server certificate/key not found")
    os.makedirs(args.record_dir, mode=0o700, exist_ok=True)
    for role in ("source", "cross-host", "cross-scheme", "cross-port"):
        # Create empty role files up front so a zero target count is
        # distinguishable from an incorrectly configured record directory.
        record_path = os.path.join(
            os.path.abspath(args.record_dir), "%s.jsonl" % role
        )
        with open(record_path, "a", encoding="ascii"):
            pass
    state = FixtureState(
        args.record_dir,
        {
            "same-origin": args.same_origin_topic,
            "cross-host": args.cross_host_topic,
            "cross-scheme": args.cross_scheme_topic,
            "cross-port": args.cross_port_topic,
        },
        recovery_release_file=args.recovery_release_file,
        recovery_topic=args.recovery_topic,
    )

    servers = []
    certificate = (args.cert, args.key)
    try:
        servers.append(
            make_server(
                args.source_port,
                "source",
                state,
                True,
                certificate,
            )
        )
        servers.append(
            make_server(
                args.cross_host_port,
                "cross-host",
                state,
                True,
                certificate,
            )
        )
        servers.append(
            make_server(
                args.cross_scheme_port,
                "cross-scheme",
                state,
                False,
                None,
            )
        )
        servers.append(
            make_server(
                args.cross_port,
                "cross-port",
                state,
                True,
                certificate,
            )
        )
        state.ports = {
            "source": servers[0].server_address[1],
            "cross-host": servers[1].server_address[1],
            "cross-scheme": servers[2].server_address[1],
            "cross-port": servers[3].server_address[1],
        }
        state.configure_redirects()

        threads = []
        for server in servers:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            threads.append(thread)

        # The ready marker is written only after every listener has a serving
        # thread, so clients may use its presence as the startup barrier.
        write_ready_file(args.ready_file, state)

        stop = threading.Event()

        def handle_signal(signum, frame):
            stop.set()

        signal.signal(signal.SIGINT, handle_signal)
        signal.signal(signal.SIGTERM, handle_signal)
        while not stop.wait(0.25):
            pass
    finally:
        for server in servers:
            server.shutdown()
        for server in servers:
            server.server_close()
    return 0


def main(argv=None):
    try:
        return run(parse_args(argv or sys.argv[1:]))
    except (OSError, RuntimeError, ssl.SSLError) as error:
        # Do not dump a traceback containing command-line paths or request
        # metadata; the caller only needs an actionable fixture error.
        print("fixture startup failed: %s" % error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
