"""A stand-in for the browser the conversion bridge launches.

The bridge (``bridge.py``) launches a browser, waits for the port file the
browser writes, asks it over HTTP which pages it has, opens a WebSocket to one
of them and speaks the Chrome DevTools Protocol.  None of that is testable
against a mock of the bridge's own code, and running a real Chrome in a suite is
not testable at all -- it needs a machine with Chrome, a ComfyUI and twenty
seconds of frontend start-up per run.

So this is the same answer ``comfy/fake.py`` gives for ComfyUI: **a real program
on a real socket, speaking the real protocol**.  It is launched by the bridge
exactly as a browser is, with the argument list the bridge really builds; it
writes a real ``DevToolsActivePort``; it serves real ``/json/list``; and it
answers real CDP frames over a real WebSocket.  Everything between
``ConversionBridge.convert`` and the wire is exercised.

What it does **not** do is run JavaScript.  Like ``fake.py``, behaviour is
**controlled, not computed**: a script file says what ComfyUI's frontend answers
for each workflow, and this program answers that.  It must not convert
anything -- a fake that inferred an API graph from a canvas would be the very
thing this whole capability exists to avoid, and a test asserting against it
would be asserting that two guesses agree.

Two things make it possible to prove the bridge's output really came through
here
==================================================================
* **the nonce.**  This process invents a random one at start-up, writes it to
  its evidence file and stamps it into every node it converts.  Neither the
  bridge nor the test knows it in advance, so a snapshot carrying it came
  through this socket -- and a bridge quietly replaced by a canned answer
  produces a snapshot without it.
* **the evidence file.**  Every argument this was launched with, the profile
  directory it was given, every expression it was asked to evaluate, every
  outbound request it attempted and what became of it, and anything it was
  scripted to queue.  A test reads facts out of it rather than asserting that
  something did not happen.

The resolver cage, and the honest limit of what this proves
==========================================================
This program **simulates** the loopback-only resolver rule: an outbound request
to a non-loopback host is recorded as ``ERR_NAME_NOT_RESOLVED`` and not made
when :data:`~localcanvas_gateway.workflows.sync.bridge.LOOPBACK_ONLY_RESOLVER_RULE`
is among its arguments, and is really made when it is not.  That is what makes
the guard fail when the rule is dropped.

It is a simulation, and the tests say so where they use it.  What it proves is
that **LocalCanvas asks for the cage** -- which is the part LocalCanvas is
responsible for and the part that can regress.  That a real Chrome honours the
rule was measured against a real ComfyUI and a real Chrome, and is recorded in
`docs/privacy-security.md`; no unit test can or should re-prove it.

    python -m localcanvas_gateway.workflows.sync.browser_fake <browser args...>

with two environment variables:

``LOCALCANVAS_FAKE_BROWSER_SCRIPT``
    path of the JSON script (below).  Absent means "convert nothing", which is
    itself a useful case.
``LOCALCANVAS_FAKE_BROWSER_EVIDENCE``
    path to write the evidence file to.  Absent means none is written.

The script::

    {
      "ready_after":  0,          // ready probes answered "not yet" first
      "refuse_after": 0,          // evaluations answered before it refuses
      "default":      {...},      // the answer for a workflow with no case
      "cases":        {"<graph id>": {...}},
      "outbound":     [{"host": "a-public-host", "url": "http://127.0.0.1:N/x"}],
      "queue":        "http://127.0.0.1:1234"         // POST /prompt there
    }

An answer is ``{"ok": true, "output": {...}}`` or
``{"ok": false, "name": "...", "message": "..."}`` -- the two shapes
``conversion_expression`` reads back.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import struct
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict, List, Optional

from .bridge import CONVERT_MARKER, LOOPBACK_ONLY_RESOLVER_RULE, NO_PROXY_FLAG

SCRIPT_VARIABLE = "LOCALCANVAS_FAKE_BROWSER_SCRIPT"
EVIDENCE_VARIABLE = "LOCALCANVAS_FAKE_BROWSER_EVIDENCE"

#: RFC 6455's magic string, as in ``comfy/fake.py``.
_WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

#: What a browser with the resolver rule reports for a name it may not resolve.
#: Chrome's own spelling, so a test asserts the string a person would see in
#: DevTools rather than one invented here.
NAME_NOT_RESOLVED = "net::ERR_NAME_NOT_RESOLVED"


class _State:
    """Everything this process knows, shared with the request handler."""

    def __init__(self, argv: List[str]) -> None:
        self.argv = list(argv)
        self.profile_dir = _flag_value(argv, "--user-data-dir=") or ""
        self.url = argv[-1] if argv and argv[-1].startswith("http") else ""
        self.caged = LOOPBACK_ONLY_RESOLVER_RULE in argv
        self.proxied = NO_PROXY_FLAG not in argv
        self.headless = any(item.startswith("--headless") for item in argv)
        #: Invented here and nowhere else.  See the module docstring.
        self.nonce = uuid.uuid4().hex
        self.script: Dict[str, Any] = _read_script()
        self.ready_probes = 0
        self.evaluations = 0
        self.expressions: List[str] = []
        self.outbound: List[Dict[str, str]] = []
        self.queued: List[str] = []
        self.lock = threading.Lock()

    def evidence(self) -> Dict[str, Any]:
        with self.lock:
            return {
                "argv": list(self.argv),
                "profile_dir": self.profile_dir,
                "url": self.url,
                "nonce": self.nonce,
                "caged": self.caged,
                "proxied": self.proxied,
                "headless": self.headless,
                "ready_probes": self.ready_probes,
                "evaluations": self.evaluations,
                "expressions": list(self.expressions),
                "outbound": list(self.outbound),
                "queued": list(self.queued),
            }


def _flag_value(argv: List[str], prefix: str) -> Optional[str]:
    for item in argv:
        if item.startswith(prefix):
            return item[len(prefix) :]
    return None


def _read_script() -> Dict[str, Any]:
    path = os.environ.get(SCRIPT_VARIABLE)
    if not path:
        return {}
    try:
        with open(path, "r", encoding="utf-8") as handle:
            document = json.load(handle)
    except (OSError, ValueError):
        return {}
    return document if isinstance(document, dict) else {}


# --------------------------------------------------------------------------
# What the "page" does on load
# --------------------------------------------------------------------------


def _attempt_outbound(state: _State) -> None:
    """Try what the script says the page tries, and record what happened.

    This is the whole point of the fake where privacy is concerned: with the
    resolver rule present a non-loopback host is not reached and is recorded
    as Chrome would record it; without it, the request is really made.  A test
    that drops the rule therefore sees a real request arrive somewhere, which
    is what makes the guard capable of failing.
    """

    for target in state.script.get("outbound") or []:
        # ``host`` is the name the page would have asked for -- a public one --
        # and ``url`` is where the attempt actually lands so a test can watch
        # it arrive.  Splitting them is what lets one test observe both halves:
        # a real request when the cage is missing, and no request at all when
        # it is there, without either needing a name that resolves off this
        # machine.
        host = str(target.get("host") or "")
        url = str(target.get("url") or "")
        if state.caged and not _is_loopback_host(host):
            with state.lock:
                state.outbound.append({"host": host, "outcome": NAME_NOT_RESOLVED})
            continue
        outcome = "RESPONSE"
        try:
            with urllib.request.urlopen(url, timeout=5) as response:  # noqa: S310
                response.read()
        except urllib.error.HTTPError:
            outcome = "RESPONSE"
        except Exception as exc:  # noqa: BLE001
            outcome = "ERROR:{}".format(exc)
        with state.lock:
            state.outbound.append({"host": host, "outcome": outcome})


def _is_loopback_host(host: str) -> bool:
    return host.lower() in ("127.0.0.1", "localhost", "::1", "[::1]")


def _attempt_queue(state: _State) -> None:
    """Submit a prompt, when a test asks for one.

    Nothing in the bridge does this and nothing ever should.  It exists so the
    assertion "no prompt was queued" can be shown to be an assertion about
    something: a test drives this once, watches the fake ComfyUI record a
    ``POST /prompt``, and only then is the same recorder's silence during a
    real conversion worth anything.
    """

    base = state.script.get("queue")
    if not base:
        return
    url = str(base).rstrip("/") + "/prompt"
    body = json.dumps({"prompt": {}, "client_id": "fake-browser"}).encode("utf-8")
    request = urllib.request.Request(  # noqa: S310
        url, data=body, headers={"Content-Type": "application/json"}, method="POST"
    )
    try:
        with urllib.request.urlopen(request, timeout=5) as response:  # noqa: S310
            response.read()
    except Exception:  # noqa: BLE001
        pass
    with state.lock:
        state.queued.append(url)


# --------------------------------------------------------------------------
# The DevTools conversation
# --------------------------------------------------------------------------


def _graph_from(expression: str) -> Optional[Dict[str, Any]]:
    """The workflow the bridge embedded, taken back out of its expression.

    Read with a real JSON decoder from the position after ``JSON.parse(``,
    which is where ``conversion_expression`` puts a JSON string literal.  A
    regular expression over that would be wrong for any workflow containing a
    quote, and workflows contain prompts.
    """

    marker = "JSON.parse("
    start = expression.find(marker)
    if start < 0:
        return None
    try:
        text, _end = json.JSONDecoder().raw_decode(expression, start + len(marker))
    except ValueError:
        return None
    if not isinstance(text, str):
        return None
    try:
        document = json.loads(text)
    except ValueError:
        return None
    return document if isinstance(document, dict) else None


def _answer(state: _State, expression: str) -> Any:
    """What the page returns for one evaluated expression."""

    if CONVERT_MARKER in expression:
        graph = _graph_from(expression)
        digest = hashlib.sha256(
            json.dumps(graph, sort_keys=True).encode("utf-8")
        ).hexdigest()[:12]
        with state.lock:
            state.expressions.append("convert:{}".format(digest))
        key = str(graph.get("id")) if isinstance(graph, dict) else ""
        cases = state.script.get("cases") or {}
        answer = cases.get(key, state.script.get("default"))
        if answer is None:
            return {
                "ok": False,
                "name": "TypeError",
                "message": "this fake browser was given no answer for {!r}".format(key),
            }
        return _stamped(state, answer)

    # The readiness probe.  Everything else the bridge might one day evaluate
    # falls here too and gets a null, which is what an unready page returns.
    with state.lock:
        state.ready_probes += 1
        state.expressions.append("ready")
        probes = state.ready_probes
    if probes <= int(state.script.get("ready_after") or 0):
        return None
    return {"node_types": int(state.script.get("node_types") or 1650)}


def _stamped(state: _State, answer: Any) -> Any:
    """Put this process's nonce on every node of a converted graph.

    So that a test can tell a graph that came through this socket from one that
    was made up somewhere between here and the snapshot on disk.
    """

    if not isinstance(answer, dict) or not answer.get("ok"):
        return answer
    output = answer.get("output")
    if not isinstance(output, dict):
        return answer
    stamped = {}
    for node_id, node in output.items():
        if isinstance(node, dict):
            node = dict(node)
            meta = dict(node.get("_meta") or {})
            meta["produced_by"] = state.nonce
            node["_meta"] = meta
        stamped[node_id] = node
    return {"ok": True, "output": stamped}


def _dispatch(state: _State, message: Dict[str, Any]) -> Dict[str, Any]:
    identifier = message.get("id")
    method = message.get("method")
    params = message.get("params") or {}
    if method in ("Runtime.enable", "Page.enable", "Network.enable"):
        return {"id": identifier, "result": {}}
    if method == "Runtime.evaluate":
        with state.lock:
            state.evaluations += 1
            evaluations = state.evaluations
        limit = int(state.script.get("refuse_after") or 0)
        if limit and evaluations > limit:
            # A browser that stops co-operating part-way through a run. The
            # DevTools error reply is how one really looks -- this is Chrome's
            # own message when a page navigates out from under an evaluation --
            # and it is the only way a test can reach the bridge's
            # transport-failure category.
            return {
                "id": identifier,
                "error": {
                    "code": -32000,
                    "message": "Execution context was destroyed.",
                },
            }
        value = _answer(state, str(params.get("expression") or ""))
        return {"id": identifier, "result": {"result": {"value": value}}}
    return {
        "id": identifier,
        "error": {"code": -32601, "message": "{} is not implemented".format(method)},
    }


# --------------------------------------------------------------------------
# The server
# --------------------------------------------------------------------------


class _Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    state: _State  # set on the server, read through self.server

    def log_message(self, fmt, *args):  # noqa: A002 - the base class's name
        pass

    @property
    def _state(self) -> _State:
        return self.server.state  # type: ignore[attr-defined]

    def _json(self, payload: Any) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler's spelling
        path = self.path.split("?", 1)[0]
        port = self.server.server_address[1]
        if path == "/json/version":
            self._json(
                {
                    "Browser": "LocalCanvasFakeBrowser/1.0",
                    "Protocol-Version": "1.3",
                    "webSocketDebuggerUrl": "ws://127.0.0.1:{}/devtools/browser".format(
                        port
                    ),
                }
            )
            return
        if path in ("/json", "/json/list"):
            self._json(
                [
                    {
                        "id": "page-1",
                        "type": "page",
                        "title": "ComfyUI",
                        "url": self._state.url,
                        "webSocketDebuggerUrl": (
                            "ws://127.0.0.1:{}/devtools/page/page-1".format(port)
                        ),
                    }
                ]
            )
            return
        if path.startswith("/devtools/page/"):
            self._websocket()
            return
        self.send_error(404)

    def _websocket(self) -> None:
        key = self.headers.get("sec-websocket-key")
        if not key:
            self.send_error(400, "not a websocket handshake")
            return
        accept = base64.b64encode(
            hashlib.sha1((key + _WS_GUID).encode("ascii")).digest()  # noqa: S324
        ).decode("ascii")
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        try:
            self.wfile.flush()
        except OSError:
            return
        # This connection stopped being HTTP at the 101 above, so the keep-alive
        # loop must not try to read another request from it. Without this the
        # socket stays open after the closing handshake and a well-behaved
        # client waits out its own close timeout -- ten seconds per browser,
        # which is most of a suite.
        self.close_connection = True
        self._serve_frames()

    def _serve_frames(self) -> None:
        while True:
            frame = self._read_frame()
            if frame is None:
                return
            try:
                message = json.loads(frame)
            except ValueError:
                continue
            if not isinstance(message, dict):
                continue
            reply = _dispatch(self._state, message)
            # Before the answer goes back, so that whatever this process was
            # asked is on disk by the time the caller has its reply. The bridge
            # terminates the browser the instant it is finished, and evidence
            # written on a timer would lose the last thing it did.
            _write_evidence(self._state)
            if not self._write_text(json.dumps(reply)):
                return

    # -- framing, as in comfy/fake.py, plus the client's mask ---------------

    def _read_frame(self) -> Optional[str]:
        head = self._read_exactly(2)
        if head is None:
            return None
        opcode = head[0] & 0x0F
        masked = bool(head[1] & 0x80)
        length = head[1] & 0x7F
        if length == 126:
            extended = self._read_exactly(2)
            if extended is None:
                return None
            length = struct.unpack("!H", extended)[0]
        elif length == 127:
            extended = self._read_exactly(8)
            if extended is None:
                return None
            length = struct.unpack("!Q", extended)[0]
        mask = self._read_exactly(4) if masked else b""
        if mask is None:
            return None
        payload = self._read_exactly(length) if length else b""
        if payload is None:
            return None
        if masked:
            payload = bytes(
                byte ^ mask[index % 4] for index, byte in enumerate(payload)
            )
        if opcode == 0x8:
            # Echo the close, so the client's closing handshake completes at
            # once. Without it a well-behaved client waits out its own close
            # timeout on every single conversion, which turns a fast suite into
            # a slow one and looks like a hang in the bridge.
            self._write_frame(0x8, payload)
            return None
        if opcode == 0x9:  # ping -> pong, so a real client stays connected
            self._write_frame(0xA, payload)
            return self._read_frame()
        if opcode not in (0x1, 0x0):
            return self._read_frame()
        return payload.decode("utf-8", "replace")

    def _write_text(self, payload: str) -> bool:
        return self._write_frame(0x1, payload.encode("utf-8"))

    def _write_frame(self, opcode: int, data: bytes) -> bool:
        header = bytearray([0x80 | opcode])
        length = len(data)
        if length < 126:
            header.append(length)
        elif length < 65536:
            header.append(126)
            header += struct.pack("!H", length)
        else:
            header.append(127)
            header += struct.pack("!Q", length)
        try:
            self.wfile.write(bytes(header) + data)
            self.wfile.flush()
        except OSError:
            return False
        return True

    def _read_exactly(self, count: int) -> Optional[bytes]:
        chunks = b""
        while len(chunks) < count:
            try:
                piece = self.rfile.read(count - len(chunks))
            except OSError:
                return None
            if not piece:
                return None
            chunks += piece
        return chunks


def main(argv: Optional[List[str]] = None) -> int:
    arguments = list(sys.argv[1:] if argv is None else argv)
    state = _State(arguments)

    server = ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
    server.daemon_threads = True
    server.state = state  # type: ignore[attr-defined]
    port = server.server_address[1]

    if state.profile_dir:
        try:
            os.makedirs(state.profile_dir, exist_ok=True)
            # A real browser writes the port and the browser-wide debugging
            # path on two lines, in that order, and the bridge reads the first.
            with open(
                os.path.join(state.profile_dir, "DevToolsActivePort"),
                "w",
                encoding="utf-8",
            ) as handle:
                handle.write("{}\n/devtools/browser/fake\n".format(port))
        except OSError:
            return 2

    _attempt_outbound(state)
    _attempt_queue(state)
    _write_evidence(state)

    thread = threading.Thread(
        target=server.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True
    )
    thread.start()
    try:
        while True:
            time.sleep(0.05)
            _write_evidence(state)
    except KeyboardInterrupt:  # pragma: no cover - terminate() is what happens
        pass
    return 0


def _write_evidence(state: _State) -> None:
    """Keep the evidence file current, because this process is *terminated*.

    The bridge stops the browser it started with ``terminate()``, so there is
    no orderly shutdown in which to write anything.  The file is therefore
    rewritten as the run goes on, atomically, and whatever it says when the
    process dies is the truth up to that moment.
    """

    path = os.environ.get(EVIDENCE_VARIABLE)
    if not path:
        return
    text = json.dumps(state.evidence(), indent=2)
    with _writing:
        if text == _written[0]:
            # Only when something actually changed. The file is read from
            # another process while this one keeps running, and every needless
            # rewrite is another window in which that read can collide with the
            # swap.
            return
        try:
            temporary = path + ".{}.tmp".format(os.getpid())
            with open(temporary, "w", encoding="utf-8") as handle:
                handle.write(text)
            os.replace(temporary, path)
        except OSError:
            return
        _written[0] = text


#: The last evidence written, so an unchanged record is not written again, and
#: the lock that keeps the request threads from swapping the file at once.
_written = [""]
_writing = threading.Lock()


if __name__ == "__main__":
    sys.exit(main())
