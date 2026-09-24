"""A stand-in for ComfyUI's HTTP surface, for testing the runtime scripts.

It exists so that setup/start/stop/status can be tested without a real ComfyUI
anywhere near the machine. It speaks the one endpoint the runtime scripts
actually use as a health probe -- ``GET /system_stats`` -- and nothing else.

T-0003-01 owns the protocol-faithful fake (``gateway/localcanvas_gateway/
comfy/fake.py``) that the gateway's own tests drive. This stub is deliberately
smaller: the scripts only ever ask ComfyUI whether it is up.

    --port N            listen here
    --ready-after S     answer 503 for the first S seconds, then 200
    --never-ready       answer 503 forever
    --launch-marker P   write P as soon as this process starts
    --report-streams    print what this process's streams are encoded with
    --log-unencodable S write a line carrying U+25CB to out / err / both
    --exit-after-log    exit 1 straight after writing it
    --log-every S       print a numbered heartbeat every S seconds, forever

``--launch-marker`` is the tripwire the tests use to prove that start.ps1 did
*not* launch a second backend when a healthy one was already running.

``--log-unencodable`` is the T-0085 failure, reproduced: a real ComfyUI custom
node logs U+25CB while it loads, and on a machine whose ANSI code page has no
such character that write raises UnicodeEncodeError on a redirected stream and
ends the process. The write below is deliberately unguarded for that reason --
whether this stub survives is a fact about the encoding the launcher declared
for it, and must not be a fact about this file.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    ready_at = 0.0
    never_ready = False

    def _send(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler's spelling
        path = self.path.split("?", 1)[0]
        if path != "/system_stats":
            self._send(404, {"error": "not found"})
            return
        if Handler.never_ready or time.monotonic() < Handler.ready_at:
            self._send(503, {"error": "still loading"})
            return
        self._send(
            200,
            {
                "system": {"os": "test", "comfyui_version": "stub"},
                "devices": [],
            },
        )

    def log_message(self, fmt, *args):
        pass


# The character measured on the test workstation: a custom node logs it during
# ComfyUI's custom-node loading, and cp1251 has not got it. Written as a code
# point so that this file's own encoding cannot be what decides the test.
UNENCODABLE = chr(0x25CB)


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--ready-after", type=float, default=0.0)
    parser.add_argument("--never-ready", action="store_true")
    parser.add_argument("--launch-marker")
    parser.add_argument("--report-streams", action="store_true")
    parser.add_argument("--log-unencodable", choices=("out", "err", "both"))
    parser.add_argument("--exit-after-log", action="store_true")
    parser.add_argument("--log-every", type=float, default=0.0)
    args = parser.parse_args(argv)

    if args.launch_marker:
        # The PID goes in beside the timestamp so the harness can clean up
        # precisely: by process id, from a file this process wrote -- never
        # by name and never by port. Written first, so that a run which dies
        # on the line below is still a run the harness can account for.
        with open(args.launch_marker, "a", encoding="utf-8") as handle:
            handle.write(f"{time.time()} pid={os.getpid()}\n")

    if args.report_streams:
        # ASCII only, so this line reaches the log under any code page and the
        # test can say what the child was given rather than infer it.
        print(
            "streams stdout={} stderr={} PYTHONIOENCODING={!r} PYTHONUTF8={!r}".format(
                sys.stdout.encoding,
                sys.stderr.encoding,
                os.environ.get("PYTHONIOENCODING"),
                os.environ.get("PYTHONUTF8"),
            ),
            flush=True,
        )

    if args.log_unencodable in ("out", "both"):
        print("node loaded " + UNENCODABLE, flush=True)
    if args.log_unencodable in ("err", "both"):
        print("node warning " + UNENCODABLE, file=sys.stderr, flush=True)
    if args.exit_after_log:
        return 1

    if args.log_every > 0:
        # Keeps writing to the redirected stream for as long as it lives, so a
        # test can ask whether that stream still works once the process that
        # created it has gone. A pipe held open by the launcher would stop
        # here; a file handle of the child's own does not.
        def heartbeat():
            count = 0
            while True:
                count += 1
                print("heartbeat {}".format(count), flush=True)
                time.sleep(args.log_every)

        threading.Thread(target=heartbeat, daemon=True).start()

    Handler.ready_at = time.monotonic() + args.ready_after
    Handler.never_ready = args.never_ready

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"stub-comfy listening on {args.host}:{args.port}", flush=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
