"""Fixtures for the workflow registry tests.

Every test builds its own registry in a temporary directory, so nothing here
depends on the repository's own example folder except the tests that are
explicitly about the examples.
"""

from __future__ import annotations

import json
import textwrap
from pathlib import Path
from typing import Any, Dict, List, Optional

import pytest

from localcanvas_gateway.workflows import Registry, load_registry

#: The repository's public examples (`workflows/examples`).
REPO_ROOT = Path(__file__).resolve().parents[2]
EXAMPLES_ROOT = REPO_ROOT / "workflows" / "examples"

#: A small API-format graph carrying one literal input of every kind a field
#: can bind to, plus one input wired to another node's output.
DEFAULT_GRAPH: Dict[str, Any] = {
    "10": {
        "class_type": "ExampleLoader",
        "inputs": {"name": "PLACEHOLDER"},
    },
    "20": {
        "class_type": "ExampleTextEncoder",
        "inputs": {"text": "placeholder", "model": ["10", 0]},
    },
    "30": {
        "class_type": "ExampleSampler",
        "inputs": {
            "seed": 0,
            "steps": 20,
            "cfg": 6.0,
            "denoise": 1.0,
            "enabled": True,
            "mode": "fast",
            "conditioning": ["20", 0],
        },
    },
    "40": {
        "class_type": "ExampleMediaLoader",
        "inputs": {"image": "PLACEHOLDER.png", "video": "PLACEHOLDER.mp4"},
    },
}


def graph_copy() -> Dict[str, Any]:
    return json.loads(json.dumps(DEFAULT_GRAPH))


class RegistryBuilder:
    """Writes definitions into a registry root and loads it."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.root.mkdir(parents=True, exist_ok=True)

    def write(
        self,
        stem: str,
        yaml_text: str,
        *,
        graph: Optional[Dict[str, Any]] = None,
        json_name: Optional[str] = None,
        json_text: Optional[str] = None,
        subdir: Optional[str] = None,
        suffix: str = ".yaml",
        write_json: bool = True,
    ) -> Path:
        """Write one definition, and unless told otherwise the JSON it points at."""

        directory = self.root if subdir is None else self.root / subdir
        directory.mkdir(parents=True, exist_ok=True)

        yaml_path = directory / (stem + suffix)
        yaml_path.write_text(textwrap.dedent(yaml_text).lstrip(), encoding="utf-8")

        if json_name is None:
            json_name = stem + "_api.json"
        json_path = directory / json_name
        if write_json:
            json_path.parent.mkdir(parents=True, exist_ok=True)
        if not write_json:
            pass
        elif json_text is not None:
            json_path.write_text(json_text, encoding="utf-8")
        elif graph is not None:
            json_path.write_text(json.dumps(graph, indent=2), encoding="utf-8")
        return yaml_path

    def add(
        self,
        stem: str,
        fields: str,
        *,
        workflow_id: Optional[str] = None,
        name: str = "Test Workflow",
        presentation: str = "",
        graph: Optional[Dict[str, Any]] = None,
        json_name: Optional[str] = None,
        json_text: Optional[str] = None,
        subdir: Optional[str] = None,
        write_json: bool = True,
    ) -> Path:
        """Write a valid-by-default definition whose ``inputs:`` are ``fields``."""

        if workflow_id is None:
            workflow_id = stem
        if json_name is None:
            json_name = stem + "_api.json"
        body = "id: {}\nname: {}\nworkflow: {}\n".format(workflow_id, name, json_name)
        if presentation:
            body += "presentation:\n" + textwrap.indent(
                textwrap.dedent(presentation).strip("\n"), "  "
            )
            body += "\n"
        body += "inputs:\n" + textwrap.indent(textwrap.dedent(fields).strip("\n"), "  ") + "\n"
        return self.write(
            stem,
            body,
            graph=graph_copy() if graph is None else graph,
            json_name=json_name,
            json_text=json_text,
            subdir=subdir,
            write_json=write_json,
        )

    def load(self) -> Registry:
        return load_registry(self.root)


@pytest.fixture
def builder(tmp_path: Path) -> RegistryBuilder:
    return RegistryBuilder(tmp_path / "registry")


#: One valid field, used wherever the test is about something else.
PROMPT_FIELD = """
- id: prompt
  label: Prompt
  type: multiline
  required: true
  bind:
    node: "20"
    input: text
"""


def only(items, message: str = ""):
    """Assert exactly one item and return it -- a count mismatch fails loudly."""

    items = list(items)
    assert len(items) == 1, "{}expected exactly one, got {}: {}".format(
        message + ": " if message else "", len(items), [str(item) for item in items]
    )
    return items[0]


# ==========================================================================
# Gateway fixtures: a real fake ComfyUI on a real socket, and an app wired to
# it.  Nothing here monkeypatches the code under test -- the client opens a
# socket and parses the answers that come back.
# ==========================================================================

import importlib  # noqa: E402
import socket  # noqa: E402
import sys  # noqa: E402
import threading  # noqa: E402
import time  # noqa: E402
from contextlib import contextmanager  # noqa: E402
from dataclasses import dataclass  # noqa: E402
from typing import Callable, Iterator  # noqa: E402

import httpx  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from localcanvas_gateway.api import build_gateway, create_app  # noqa: E402
from localcanvas_gateway.comfy import ComfyClient  # noqa: E402
from localcanvas_gateway.comfy.fake import FakeComfy  # noqa: E402
from localcanvas_gateway.config import (  # noqa: E402
    ComfyConfig,
    GatewayConfig,
    IdentityConfig,
    PromptTranslationConfig,
    RuntimeConfig,
)
from localcanvas_gateway.media import MediaStore  # noqa: E402
from localcanvas_gateway.translation import Translator  # noqa: E402

#: The display name the harness advertises, distinctive so that a test can
#: tell it apart from a value that leaked in from somewhere else.
TEST_DISPLAY_NAME = "Test Generation PC"

#: Timeouts for the harness's ComfyUI client.  Short, so that a test which
#: takes the backend away does not wait out a production connect timeout; the
#: code path taken is the same one.
IMPATIENT = httpx.Timeout(connect=0.4, read=1.0, write=1.0, pool=1.0)


#: Where the media clock starts.  A real epoch, so that an ``expires_at`` in a
#: response is a plausible timestamp rather than 1970 -- a test that reads one
#: should be looking at the shape it will really see.
MEDIA_EPOCH = 1_767_225_600.0  # 2026-01-01T00:00:00Z

#: What an upload sends when the test is about something other than the bytes.
#: A JPEG's opening marker and the APP0 that follows it, then filler.
#:
#: The head is load-bearing now: the gateway reads it to decide what the file is
#: (`media.py`, :func:`sniff_image_type`), so an upload of filler alone would be
#: refused before reaching whatever the test was about.  It is still only a
#: head -- the gateway does not decode a picture, and nothing here claims a
#: check nothing performs.  Tests that are about the bytes themselves use the
#: real containers in ``media_fixtures.py``.
UPLOAD_BYTES = bytes.fromhex("ffd8ffe0") + b"pretend jpeg payload" * 4


class FakeClock:
    """A monotonic clock a test moves by hand.

    The readiness probe caches a ``ready`` answer for a couple of seconds
    (`comfy/client.py`).  Waiting that out would put real sleeps in the suite
    and make it slow and flaky; moving the clock instead tests the same code
    with none of that.
    """

    def __init__(self, now: float = 1000.0) -> None:
        self.now = now

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


@pytest.fixture
def importable_backend(tmp_path, monkeypatch):
    """A stub ``argostranslate`` an import would really find (T-0043).

    The two "this does not import the extra" guards are worth nothing on a
    machine where the extra cannot be imported at all: every implementation
    passes them, including one that imports on every handshake.  This puts a
    package on ``sys.path`` that satisfies exactly what
    ``ArgosTranslator._import`` asks for, so the *absence* of
    ``argostranslate`` from ``sys.modules`` afterwards is evidence rather than
    an accident of this PC.

    It answers "no model for that pair", which is the cheapest complete walk:
    what is under test is whether anything imported, not what it found.  The
    modules are removed again on the way out, because a leaked one would
    silently change what every later test in the session measures.
    """

    root = tmp_path / "stub-site-packages"
    package = root / "argostranslate"
    package.mkdir(parents=True)
    (package / "__init__.py").write_text("", encoding="utf-8")
    (package / "settings.py").write_text(
        "class _Provider:\n"
        "    name = 'OPENNMT'\n"
        "\n"
        "model_provider = _Provider()\n",
        encoding="utf-8",
    )
    (package / "translate.py").write_text(
        "class _Language:\n"
        "    def get_translation(self, other):\n"
        "        return None\n"
        "\n"
        "def get_language_from_code(code):\n"
        "    return _Language()\n",
        encoding="utf-8",
    )
    monkeypatch.syspath_prepend(str(root))
    importlib.invalidate_caches()
    try:
        yield root
    finally:
        for name in [
            name
            for name in sys.modules
            if name == "argostranslate" or name.startswith("argostranslate.")
        ]:
            del sys.modules[name]


@pytest.fixture
def fake_comfy():
    """A protocol-faithful ComfyUI listening on a loopback port."""

    fake = FakeComfy()
    fake.start()
    try:
        yield fake
    finally:
        fake.stop()


def config_for(
    comfy_host: str,
    comfy_port: int,
    registry_root: Path,
    *,
    display_name: str = TEST_DISPLAY_NAME,
    prompt_translation: Optional[PromptTranslationConfig] = None,
) -> RuntimeConfig:
    """A RuntimeConfig built in memory.

    Config *loading* has its own tests; these fixtures are about everything
    downstream of it, so they skip the file.
    """

    return RuntimeConfig(
        source=Path("runtime.yaml"),
        repo_root=registry_root.parent,
        manage_comfy=False,
        comfy=ComfyConfig(host=comfy_host, port=comfy_port),
        workflows_registry=registry_root,
        gateway=GatewayConfig(host="127.0.0.1", port=7801),
        identity=IdentityConfig(display_name=display_name),
        # Off unless a test asks for it, which is also the shipped default:
        # translation is an optional install (`docs/api.md`).
        prompt_translation=(
            PromptTranslationConfig() if prompt_translation is None else prompt_translation
        ),
    )


#: "This request did not carry the key at all", which is a different request
#: from one that carried it as ``null``.
ABSENT = object()


@dataclass
class Harness:
    """One gateway, its fake backend, and a client that talks to it."""

    client: TestClient
    app: Any
    fake: FakeComfy
    state: Any
    config: RuntimeConfig
    clock: FakeClock
    media_clock: FakeClock

    def upload(
        self,
        *,
        kind: str = "image",
        filename: str = "IMG_0142.jpg",
        content_type: str = "image/jpeg",
        data: bytes = UPLOAD_BYTES,
    ):
        """POST one file to /api/v1/media, the way a phone does."""

        return self.client.post(
            "/api/v1/media",
            files={"file": (filename, data, content_type)},
            data={"kind": kind},
        )

    def uploaded_id(self, **kwargs) -> str:
        """Upload and return the media_id, failing loudly if it was refused."""

        response = self.upload(**kwargs)
        assert response.status_code == 201, response.text
        return response.json()["media_id"]

    def submit(
        self,
        workflow_id: str,
        inputs: Dict[str, Any],
        *,
        translation: Any = ABSENT,
    ):
        """POST one submission.  ``translation`` is sent only when given.

        The default is what every client that has never heard of the
        per-submission override sends -- no key at all -- so a test that says
        nothing about translation exercises exactly that request.
        """

        payload: Dict[str, Any] = {"workflow_id": workflow_id, "inputs": inputs}
        if translation is not ABSENT:
            payload["translation"] = translation
        return self.client.post("/api/v1/jobs", json=payload)

    @property
    def prompt_id(self) -> str:
        """The prompt id of the single submission the fake received."""

        return only(self.fake.submissions, "submissions")["prompt_id"]


# ==========================================================================
# A real server on a real port.
#
# ``TestClient`` cannot answer one question this project has to answer:
# Starlette's test transport runs the app to completion and hands back a body
# that is already in memory, so a streamed response and a buffered one are
# byte-for-byte identical through it.  Streaming is the whole point of the
# result route -- a gateway that buffers a video is a gateway that dies on a
# large one -- so it is tested where the difference exists, over a socket,
# against uvicorn, which is already a dependency because it is what actually
# serves this app in production.
# ==========================================================================


@contextmanager
def served(app) -> "Iterator[str]":
    """Run ``app`` under uvicorn on a loopback port; yield its base URL.

    The socket is bound here rather than by uvicorn so the port is known before
    the server starts: asking for port 0 and then reading it back off the
    server is a race this does not need.
    """

    import uvicorn

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(16)
    port = listener.getsockname()[1]

    server = uvicorn.Server(
        uvicorn.Config(app, log_level="warning", access_log=False, lifespan="on")
    )
    thread = threading.Thread(
        target=server.run, kwargs={"sockets": [listener]}, daemon=True
    )
    thread.start()
    try:
        deadline = time.monotonic() + 10
        while not server.started:
            if time.monotonic() > deadline:  # pragma: no cover - a wedged server
                raise RuntimeError("uvicorn did not start")
            time.sleep(0.01)
        yield "http://127.0.0.1:{}".format(port)
    finally:
        server.should_exit = True
        thread.join(timeout=10)
        listener.close()


class EventStream:
    """One open ``/events`` socket, read message by message.

    Every read has a deadline, so a test that expects a message the gateway
    never sends fails with what it was waiting for instead of hanging the
    suite.
    """

    def __init__(self, socket: Any) -> None:
        self._socket = socket

    def next(self, timeout: float = 10.0) -> Dict[str, Any]:
        return json.loads(self._socket.recv(timeout=timeout))

    def until(self, type_: str, *, timeout: float = 10.0) -> Dict[str, Any]:
        """Read past everything else and return the first message of a type."""

        deadline = time.monotonic() + timeout
        seen: List[Dict[str, Any]] = []
        while True:
            remaining = deadline - time.monotonic()
            assert remaining > 0, "no {!r} message arrived; saw {}".format(type_, seen)
            message = self.next(timeout=remaining)
            if message.get("type") == type_:
                return message
            seen.append(message)

    def drain(self, timeout: float = 10.0) -> List[Dict[str, Any]]:
        """Everything up to the gateway closing the socket."""

        from websockets.exceptions import ConnectionClosed

        deadline = time.monotonic() + timeout
        messages: List[Dict[str, Any]] = []
        while True:
            remaining = deadline - time.monotonic()
            assert remaining > 0, "the stream did not end; saw {}".format(messages)
            try:
                messages.append(self.next(timeout=remaining))
            except ConnectionClosed:
                return messages

    def abandon(self) -> None:
        """Drop the connection the way a phone leaving Wi-Fi does.

        Not a close handshake: the socket is torn down under the gateway, which
        is the case `docs/recovery.md` is written for.
        """

        self._socket.socket.close()


@contextmanager
def watching(base_url: str, job_id: str, *, timeout: float = 10.0):
    """Open ``WS /api/v1/jobs/{job_id}/events`` against a served gateway."""

    from websockets.sync.client import connect

    url = "{}/api/v1/jobs/{}/events".format(
        base_url.replace("http://", "ws://", 1), job_id
    )
    with connect(url, open_timeout=timeout) as socket:
        yield EventStream(socket)


@pytest.fixture
def gateway_factory(builder, fake_comfy, tmp_path) -> Callable[..., Harness]:
    """Build a gateway around whatever the registry builder has written.

    A factory rather than a plain fixture, because the registry has to be
    populated by the test before it is loaded.
    """

    opened = []
    stores = []
    # The store root sits *inside* a directory of its own, so a test can assert
    # that nothing was ever written beside it.
    media_root = tmp_path / "media"
    media_root.mkdir(parents=True, exist_ok=True)

    def _build(
        *,
        display_name: str = TEST_DISPLAY_NAME,
        comfy_port: Optional[int] = None,
        media_ttl_seconds: float = 3600.0,
        max_upload_bytes: Optional[Dict[str, int]] = None,
        max_store_bytes: Optional[int] = None,
        prompt_translation: Optional[PromptTranslationConfig] = None,
        translator: Optional[Translator] = None,
    ) -> Harness:
        registry = builder.load()
        config = config_for(
            "127.0.0.1",
            fake_comfy.port if comfy_port is None else comfy_port,
            builder.root,
            display_name=display_name,
            prompt_translation=prompt_translation,
        )
        clock = FakeClock()
        comfy = ComfyClient(
            config.comfy.base_url,
            timeout=IMPATIENT,
            probe_timeout=IMPATIENT,
            clock=clock,
        )
        opened.append(comfy)
        media_clock = FakeClock(MEDIA_EPOCH)
        store = MediaStore(
            media_root / "store-{}".format(len(opened)),
            ttl_seconds=media_ttl_seconds,
            clock=media_clock,
            **(
                {"max_upload_bytes": max_upload_bytes}
                if max_upload_bytes is not None
                else {}
            ),
            **({"max_store_bytes": max_store_bytes} if max_store_bytes is not None else {}),
        )
        stores.append(store)
        state = build_gateway(
            config,
            comfy=comfy,
            registry=registry,
            media_store=store,
            translator=translator,
        )
        app = create_app(state)
        # raise_server_exceptions=False so that the catch-all 500 handler is
        # what a test sees, rather than the exception escaping into pytest.
        client = TestClient(app, raise_server_exceptions=False)
        return Harness(
            client=client,
            app=app,
            fake=fake_comfy,
            state=state,
            config=config,
            clock=clock,
            media_clock=media_clock,
        )

    try:
        yield _build
    finally:
        for comfy in opened:
            comfy.close()
        for store in stores:
            store.close()


# ==========================================================================
# Two classes of test, and the ports the ordinary class may never reach.
#
# *Deterministic* is the default and what public CI runs: no real ComfyUI, no
# developer network, no verdict that depends on another process's state, no
# multi-minute live wait.  *Integration* is opt-in: a test marked
# ``@pytest.mark.integration`` runs only when LOCALCANVAS_INTEGRATION=1 is set,
# and is otherwise skipped with the reason printed (``-rs`` in pyproject.toml).
#
# 8188 and 7801 are the ports a real ComfyUI and a real gateway listen on by
# default, on a developer's machine and on the LAN alike.  A deterministic test
# that connects to either is talking to somebody's live stack, so the attempt
# is refused *before* the socket connects -- through the interpreter's own
# ``socket.connect`` audit event, which ``connect`` and ``connect_ex`` both
# raise whatever library called them -- and the test that made it fails.  This
# covers the pytest process; a child process a test starts is not covered here.
# ==========================================================================

import os  # noqa: E402

#: The variable that opts a run into the integration class.
INTEGRATION_VARIABLE = "LOCALCANVAS_INTEGRATION"

#: Default ports of a live ComfyUI and a live gateway (`docs/runtime.md`).
LIVE_PORTS = frozenset({8188, 7801})

INTEGRATION_SKIP_REASON = (
    "integration test: needs a real ComfyUI, a real browser or machine state "
    "outside the test's control; set {}=1 to run it".format(INTEGRATION_VARIABLE)
)


def integration_enabled() -> bool:
    return os.environ.get(INTEGRATION_VARIABLE) == "1"


class LivePortRefused(RuntimeError):
    """A deterministic test tried to connect to a live ComfyUI or gateway port.

    Deliberately not an ``OSError``: the client code under test turns an
    ``OSError`` into "unreachable", which would let the attempt pass silently.
    """


class _LivePortGuard:
    def __init__(self) -> None:
        self.allowed = False
        self.attempts: List[Any] = []

    def __call__(self, event: str, args: Any) -> None:
        if event != "socket.connect" or self.allowed:
            return
        address = args[1] if len(args) > 1 else None
        if (
            isinstance(address, tuple)
            and len(address) >= 2
            and isinstance(address[1], int)
            and address[1] in LIVE_PORTS
        ):
            self.attempts.append(address)
            raise LivePortRefused(
                "a deterministic test tried to connect to {!r}, a live "
                "ComfyUI/gateway port; the connection was not made".format(address)
            )


LIVE_PORT_GUARD = _LivePortGuard()
# An audit hook cannot be removed again, which is the property wanted here: no
# test can take the guard away for the tests after it.
sys.addaudithook(LIVE_PORT_GUARD)


def pytest_report_header(config) -> List[str]:
    return [
        "integration tests ({}): {}".format(
            INTEGRATION_VARIABLE,
            "ENABLED" if integration_enabled() else "skipped (set {}=1)".format(INTEGRATION_VARIABLE),
        ),
        "live ports refused to deterministic tests: {}".format(sorted(LIVE_PORTS)),
    ]


def pytest_collection_modifyitems(config, items) -> None:
    if integration_enabled():
        return
    skip = pytest.mark.skip(reason=INTEGRATION_SKIP_REASON)
    for item in items:
        if item.get_closest_marker("integration") is not None:
            item.add_marker(skip)


@pytest.fixture(autouse=True)
def _no_live_port_contact(request):
    """Fail any deterministic test that tried to reach 8188 or 7801."""

    integration = request.node.get_closest_marker("integration") is not None
    before = len(LIVE_PORT_GUARD.attempts)
    LIVE_PORT_GUARD.allowed = integration and integration_enabled()
    try:
        yield
    finally:
        LIVE_PORT_GUARD.allowed = False
    attempts = LIVE_PORT_GUARD.attempts[before:]
    assert not attempts, "this deterministic test tried to reach live ports: {}".format(
        attempts
    )


def pytest_sessionfinish(session, exitstatus) -> None:
    if LIVE_PORT_GUARD.attempts:
        print(
            "\nLIVE PORT CONTACT ATTEMPTS REFUSED: {}".format(LIVE_PORT_GUARD.attempts),
            file=sys.stderr,
        )
        session.exitstatus = 1
    else:
        print(
            "\nlive ports {}: no connection attempted by this pytest process".format(
                sorted(LIVE_PORTS)
            ),
            file=sys.stderr,
        )
