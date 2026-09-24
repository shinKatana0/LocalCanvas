"""Driving the conversion bridge against a real stand-in browser.

``localcanvas_gateway.workflows.sync.browser_fake`` is a program the bridge can
launch exactly as it launches Chrome: it writes a real ``DevToolsActivePort``,
serves real ``/json/list`` and answers real CDP frames over a real WebSocket.
This module is the scaffolding for pointing the bridge at it and reading back
what it saw.

Two details that are easy to get wrong and would quietly ruin every test here:

* the child process is a **new interpreter**, so it does not inherit the
  ``sys.path`` entry ``conftest.py`` inserts.  Without ``PYTHONPATH`` it would
  import whatever ``localcanvas_gateway`` is *installed*, which on a developer
  machine is an editable install pointing at a different checkout entirely --
  and the tests would then be exercising somebody else's code while passing;
* the browser is stopped with ``terminate()``, so the fake gets no orderly
  shutdown.  It rewrites its evidence file as it goes, and :meth:`Browser.saw`
  reads whatever it managed to write.
"""

from __future__ import annotations

import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

from localcanvas_gateway.workflows.sync import bridge as bridge_module
from localcanvas_gateway.workflows.sync.browser_fake import (
    EVIDENCE_VARIABLE,
    SCRIPT_VARIABLE,
)

#: The gateway source root, which is what the child interpreter has to import
#: from.  ``conftest.py`` put it at ``sys.path[0]`` for this process; the child
#: gets it through the environment.
GATEWAY_ROOT = str(Path(__file__).resolve().parent.parent)

FAKE_BROWSER_MODULE = "localcanvas_gateway.workflows.sync.browser_fake"


def ui_graph(identifier: str = "editor-1", *, seed: int = 0) -> Dict[str, Any]:
    """An editor-format workflow that carries an id the fake can key on."""

    return {
        "id": identifier,
        "last_node_id": 2,
        "last_link_id": 1,
        "nodes": [
            {"id": 1, "type": "ExampleLoader", "widgets_values": ["PLACEHOLDER"]},
            {"id": 2, "type": "ExampleSampler", "widgets_values": [seed]},
        ],
        "links": [[1, 1, 0, 2, 0, "MODEL"]],
        "version": 0.4,
    }


def converted_graph(seed: int = 0) -> Dict[str, Any]:
    """What the fake ComfyUI answers with: a plain API-format graph.

    Deliberately not derived from :func:`ui_graph`.  A fake that computed one
    from the other would be a converter, and this project's whole position is
    that writing one is the mistake -- a test asserting the bridge agreed with
    it would be asserting that two guesses match.
    """

    return {
        "10": {
            "class_type": "ExampleLoader",
            "inputs": {"name": "PLACEHOLDER.safetensors"},
        },
        "20": {
            "class_type": "ExampleSampler",
            "inputs": {"seed": seed, "model": ["10", 0]},
        },
    }


class Browser:
    """One scripted stand-in browser, and what it turned out to have done."""

    def __init__(
        self,
        tmp_path: Path,
        monkeypatch,
        *,
        default: Optional[Mapping[str, Any]] = None,
        cases: Optional[Mapping[str, Mapping[str, Any]]] = None,
        ready_after: int = 0,
        refuse_after: int = 0,
        outbound: Sequence[Mapping[str, str]] = (),
        queue: Optional[str] = None,
        node_types: int = 1650,
    ) -> None:
        self._folder = tmp_path / "fake browser"
        self._folder.mkdir(parents=True, exist_ok=True)
        self._script_path = self._folder / "script.json"
        self._evidence_path = self._folder / "evidence.json"
        script = {
            "ready_after": ready_after,
            "refuse_after": refuse_after,
            "node_types": node_types,
            "default": dict(default) if default is not None else None,
            "cases": {key: dict(value) for key, value in (cases or {}).items()},
            "outbound": [dict(item) for item in outbound],
            "queue": queue,
        }
        self._script_path.write_text(json.dumps(script, indent=2), encoding="utf-8")
        monkeypatch.setenv(SCRIPT_VARIABLE, str(self._script_path))
        monkeypatch.setenv(EVIDENCE_VARIABLE, str(self._evidence_path))
        monkeypatch.setenv("PYTHONPATH", GATEWAY_ROOT)

    @property
    def program(self) -> Tuple[str, ...]:
        return (sys.executable, "-m", FAKE_BROWSER_MODULE)

    def saw(self) -> Dict[str, Any]:
        """The evidence file, or an empty record when it was never launched.

        Retried, because the file is swapped into place by another process
        while this one may be reading it: on Windows a read that lands inside
        that swap fails outright, and a test that saw an empty record would
        report a fault in the bridge that is really a fault in this read. An
        absent file is answered at once -- "never launched" is a real answer
        and must not cost a second.
        """

        deadline = time.monotonic() + 2.0
        while True:
            if not self._evidence_path.exists():
                return {}
            try:
                return json.loads(self._evidence_path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.05)

    @property
    def launched(self) -> bool:
        return self._evidence_path.exists()


class CountingPopen:
    """``subprocess.Popen``, counting how often the bridge launched anything.

    "No browser was launched" is a claim about a process that is not there, and
    the only honest way to check it is to hold the thing that would have
    launched one.
    """

    def __init__(self) -> None:
        self.calls: List[Sequence[str]] = []

    def __call__(self, argv, **kwargs):
        import subprocess  # noqa: PLC0415

        self.calls.append(list(argv))
        return subprocess.Popen(argv, **kwargs)

    @property
    def count(self) -> int:
        return len(self.calls)


class Beacon:
    """A local server standing in for a host on the Internet.

    It exists so a test can *watch a request arrive*.  Nothing here resolves a
    public name -- the stand-in browser is told which host the page would have
    asked for and where the attempt should land, and it applies the resolver
    rule to the former.  See ``browser_fake.py`` for why that split is what
    makes the guard able to fail.
    """

    def __init__(self) -> None:
        self.hits: List[str] = []
        beacon = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, fmt, *args):  # noqa: A002
                pass

            def do_GET(self) -> None:  # noqa: N802
                beacon.hits.append(self.path)
                self.send_response(200)
                self.send_header("Content-Length", "2")
                self.end_headers()
                self.wfile.write(b"ok")

        self._server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self._server.daemon_threads = True
        self._thread = threading.Thread(
            target=self._server.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True
        )

    def __enter__(self) -> "Beacon":
        self._thread.start()
        return self

    def __exit__(self, *exc_info: Any) -> None:
        self._server.shutdown()
        self._server.server_close()
        self._thread.join(timeout=5)

    @property
    def url(self) -> str:
        host, port = self._server.server_address[0], self._server.server_address[1]
        return "http://{}:{}/beacon".format(host, port)


def make_bridge(
    comfy_url: str,
    browser: Optional[Browser] = None,
    *,
    popen=None,
    program: Optional[Sequence[str]] = None,
    candidates: Sequence[str] = (),
    timeouts: Optional[bridge_module.BridgeTimeouts] = None,
) -> bridge_module.ConversionBridge:
    """A real :class:`ConversionBridge` pointed at a stand-in browser.

    Only two things are substituted: which program is launched, and -- when a
    test needs to count launches -- what does the launching.  Everything else
    is the production path: the temporary profile, the argument list, the port
    file, ``/json/list``, the WebSocket, and the CDP conversation.
    """

    kwargs: Dict[str, Any] = {
        "candidates": candidates,
        "timeouts": timeouts or _fast_timeouts(),
    }
    if program is not None:
        kwargs["program"] = tuple(program)
    elif browser is not None:
        kwargs["program"] = browser.program
    if popen is not None:
        kwargs["popen"] = popen
    return bridge_module.ConversionBridge(comfy_url, **kwargs)


def _fast_timeouts() -> bridge_module.BridgeTimeouts:
    """Short enough that a broken test fails rather than hangs.

    Not so short that a loaded machine fails a working one: starting a Python
    interpreter and binding a socket is the slowest thing here, and ten seconds
    is roughly a hundred times what it takes.
    """

    return bridge_module.BridgeTimeouts(
        comfy_probe=5.0,
        browser_start=30.0,
        page_target=30.0,
        frontend_ready=30.0,
        conversion=30.0,
        browser_stop=10.0,
    )


__all__ = [
    "Beacon",
    "Browser",
    "CountingPopen",
    "FAKE_BROWSER_MODULE",
    "GATEWAY_ROOT",
    "converted_graph",
    "make_bridge",
    "ui_graph",
]
