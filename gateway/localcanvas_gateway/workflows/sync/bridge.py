"""Asking the user's own ComfyUI to convert an editor workflow into an API one.

A ComfyUI user has editor ("UI") workflows.  The API format that actually
executes is a separate, deliberate export almost nobody takes, so a sync that
can only read API exports can read almost nothing.  This module closes that gap
without LocalCanvas ever deciding what a canvas means.

**Nothing here converts anything.**  The conversion is
``app.graphToPrompt()`` -- ComfyUI's own function, in ComfyUI's own frontend,
running in a page the user's own ComfyUI served.  Only that build knows its
installed custom node definitions, its widget semantics, its virtual nodes and
its subgraph expansion; a translation written here would run and produce the
wrong result silently, which is worse than refusing.  So this module drives a
browser and reads an answer, and there is no code path in it that looks at a
node and decides what it means.

The measured consequence of loading that page, and why the browser is caged
=========================================================================
The frontend, every custom node's JavaScript and whatever a security product
injects all run when the page loads.  Measured while converting real workflows:
the page reached a vendor release endpoint, and one workflow made it request a
model URL on a public host **naming a model taken from inside that workflow**.
A user's workflow contents are the user's.

`docs/privacy-security.md`, "Converting a workflow through the user's own
ComfyUI", therefore makes five properties requirements rather than hardening
options, and they are what this module is shaped around:

1. the browser LocalCanvas launches resolves **nothing but loopback**
   (:data:`LOOPBACK_ONLY_RESOLVER_RULE`, plus :data:`NO_PROXY_FLAG` so a system
   proxy cannot resolve on its behalf);
2. the browser is one **already installed** -- :func:`find_browser` looks only
   at a fixed list of standard locations and nothing is ever downloaded;
3. the profile is **temporary and owned by the run**, and removed afterwards;
4. **nothing is queued**: the only frontend call made is ``graphToPrompt``,
   which asks what the graph *would* submit;
5. **sources are read-only**: bytes come in as an argument, and this module
   opens no file at all.

What a success is
=================
``graphToPrompt`` succeeding is **not** proof of a usable graph.  Measured: a
graph carrying a node type this ComfyUI does not have converts happily into a
node with no ``class_type`` at all --

    {"1": {"inputs": {"UNKNOWN": "x"}, "_meta": {}}}

-- and an empty canvas converts into ``{}``.  So every result is put back
through :func:`~localcanvas_gateway.workflows.sync.classify.classify`, the same
function that judges a file a user exported by hand, and anything it does not
call an importable API graph is a **failure with a category and no output**.
There is no path here that produces API JSON for a conversion that did not
work.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Any, Callable, Dict, Mapping, Optional, Sequence, Tuple

from .classify import classify
from .contract import ContractCache, RuntimeContract, read_object_info

# --------------------------------------------------------------------------
# The cage
# --------------------------------------------------------------------------

#: Every name except loopback fails to resolve in the browser this launches.
#:
#: Measured on a developer machine: without it the page received a real answer
#: from a vendor release endpoint and requested a model URL on a public host
#: with a model name taken out of the user's own workflow; with it both end
#: ``ERR_NAME_NOT_RESOLVED`` and the conversion is unchanged.  It is a
#: requirement of `docs/privacy-security.md`, not a hardening option, which is
#: why it is one named constant asserted verbatim by a test rather than a flag
#: buried in a list.
LOOPBACK_ONLY_RESOLVER_RULE = (
    "--host-resolver-rules=MAP * ~NOTFOUND , EXCLUDE localhost , "
    "EXCLUDE 127.0.0.1 , EXCLUDE ::1"
)

#: The rule above governs *name resolution*, and a browser told to use a proxy
#: does not resolve the name -- the proxy does, and the cage would have a hole
#: in exactly the configuration where a machine has an outbound path already
#: set up for it.  Direct connections only.
NO_PROXY_FLAG = "--no-proxy-server"

#: The rest: headless, its own throwaway profile, and every background service
#: a browser starts on its own turned off.  None of these is a privacy claim by
#: itself -- the two constants above are -- but each is one fewer thing running
#: in a page that is about to execute somebody else's JavaScript.
BROWSER_FLAGS: Tuple[str, ...] = (
    "--headless=new",
    "--disable-gpu",
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-default-apps",
    "--disable-extensions",
    "--disable-sync",
    "--disable-background-networking",
    "--disable-component-update",
    "--disable-client-side-phishing-detection",
    "--metrics-recording-only",
    "--no-service-autorun",
    "--password-store=basic",
    "--use-mock-keychain",
    "--mute-audio",
)

#: Where an installed Chrome or Edge is on Windows.  A fixed list, checked with
#: ``os.path.isfile`` -- nothing here searches the machine, reads the registry
#: or downloads anything, and a machine with neither browser gets a status
#: saying so rather than an install.
BROWSER_CANDIDATES: Tuple[str, ...] = (
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
)


def find_browser(
    candidates: Sequence[str] = BROWSER_CANDIDATES,
    *,
    exists: Callable[[str], bool] = os.path.isfile,
) -> Optional[Tuple[str, ...]]:
    """The first installed browser, as the program to run, or ``None``.

    A tuple rather than a string because that is what
    :func:`browser_command` puts at the front of its argument list, and a test
    substitutes a program of several words there without this module needing a
    branch for it.
    """

    for candidate in candidates:
        if exists(candidate):
            return (candidate,)
    return None


def browser_command(
    program: Sequence[str], *, profile_dir: str, url: str
) -> Tuple[str, ...]:
    """The exact command line the browser is launched with.

    A pure function so that the cage is checked by reading a list, not by
    watching a process.  ``--remote-debugging-port=0`` lets the operating
    system pick the port and the browser publish it in the profile directory,
    so two syncs never fight over one number.
    """

    return tuple(program) + BROWSER_FLAGS + (
        LOOPBACK_ONLY_RESOLVER_RULE,
        NO_PROXY_FLAG,
        "--remote-debugging-port=0",
        "--user-data-dir={}".format(profile_dir),
        url,
    )


# --------------------------------------------------------------------------
# What the frontend is asked
# --------------------------------------------------------------------------

#: Is the frontend far enough on to convert?
#:
#: ``app.nodeDefs`` is **empty** in frontend 1.49.6 and is not a readiness
#: signal, measured -- a bridge that waited for it would wait forever against a
#: perfectly ready page.  What does fill up is LiteGraph's registry of node
#: types, which is also exactly what a conversion needs.
READY_EXPRESSION = """
(() => {
  const app = window.app;
  if (!app || typeof app.graphToPrompt !== 'function'
      || typeof app.loadGraphData !== 'function' || !app.graph) return null;
  const types = window.LiteGraph && window.LiteGraph.registered_node_types;
  const count = types ? Object.keys(types).length : 0;
  if (count === 0) return null;
  return {node_types: count};
})()
"""

#: Marks the one expression that carries a user's workflow into the page, so
#: that everything else this module evaluates is obviously not that.
CONVERT_MARKER = "__localcanvas_convert__"


def conversion_expression(source_text: str) -> str:
    """The one thing LocalCanvas asks the frontend to do with a workflow.

    Two calls and no third: load the graph the way the editor loads it, then
    ask what it *would* submit.  ``graphToPrompt`` returns ``{workflow,
    output}`` and only ``output`` -- the API half -- is taken, which is
    precisely the half ComfyUI's own *Export (API)* menu item serialises.

    **The frontend call that submits a graph for execution is not named in this
    module, and a test enforces that** -- the whole module is read as source and
    the suite fails if it appears.  This sentence used to make the claim on its
    own; the design said a test must hold it, and now one does, so the claim is
    written here as a pointer to the test rather than as a substitute for it.
    """

    return (
        "(async () => {\n"
        "  /* " + CONVERT_MARKER + " */\n"
        "  const graph = JSON.parse(" + json.dumps(source_text) + ");\n"
        "  try {\n"
        "    await window.app.loadGraphData(graph, true, false, "
        "'localcanvas-conversion');\n"
        "    const prompt = await window.app.graphToPrompt();\n"
        "    return {ok: true, output: prompt.output};\n"
        "  } catch (error) {\n"
        "    return {ok: false, name: String(error && error.name || 'Error'),\n"
        "            message: String(error && error.message || error)};\n"
        "  }\n"
        "})()"
    )


# --------------------------------------------------------------------------
# Results
# --------------------------------------------------------------------------


class ConversionStatus(str, Enum):
    """What became of one workflow at the bridge."""

    #: ComfyUI converted it in this run.
    CONVERTED = "converted"
    #: A snapshot from an earlier run was still valid and was reused.
    REUSED = "reused"
    #: ComfyUI was asked and the answer was not a usable graph.
    FAILED = "failed"
    #: The bridge could not run at all -- so nothing was asked about this
    #: workflow, and that is a different thing from being refused.
    UNAVAILABLE = "unavailable"


#: The deterministic categories.  A category is a stable token a person can
#: search for and a test can assert verbatim; the sentence beside it is the
#: local detail, which may name a machine, a port or a JavaScript error.
CATEGORY_COMFY_UNREACHABLE = "COMFY_UNREACHABLE"
CATEGORY_COMFY_NOT_READY = "COMFY_NOT_READY"
CATEGORY_BROWSER_NOT_FOUND = "BROWSER_NOT_FOUND"
CATEGORY_BROWSER_NOT_STARTED = "BROWSER_NOT_STARTED"
CATEGORY_FRONTEND_NOT_READY = "FRONTEND_NOT_READY"
CATEGORY_CONVERSION_REJECTED = "CONVERSION_REJECTED"
CATEGORY_NOT_IMPORTABLE = "CONVERSION_NOT_IMPORTABLE"
CATEGORY_BRIDGE_ERROR = "BRIDGE_ERROR"


@dataclass(frozen=True)
class ComfyIdentity:
    """Which ComfyUI and which frontend produced a snapshot.

    ``digest`` is what a cached snapshot is keyed on beside its source, so that
    a materially different ComfyUI invalidates what an older one converted.  It
    is computed over the versions ComfyUI reports **and the sorted list of node
    types it has installed**, which is what actually moves when a custom node is
    installed, updated or removed -- the thing that changes what a conversion
    means.

    Both halves come from ComfyUI's own HTTP surface -- ``/system_stats`` and
    the keys of ``/object_info`` -- and **not** from the page.  That is what
    lets a run whose workflows are all unchanged answer "nothing to do" without
    launching a browser at all: the identity is knowable before the expensive
    part starts.

    Nothing machine-specific is kept.  ``/system_stats`` also carries
    ``system.argv``, which holds an absolute path on the user's machine;
    it is read for the two version fields and is never stored.
    """

    comfyui_version: str
    frontend_version: str
    node_type_count: int
    digest: str

    @classmethod
    def build(
        cls,
        *,
        comfyui_version: str,
        frontend_version: str,
        node_types: Sequence[str],
        packages: Optional[Mapping[str, str]] = None,
    ) -> "ComfyIdentity":
        document = json.dumps(
            {
                "comfyui_version": comfyui_version,
                "frontend_version": frontend_version,
                "packages": dict(sorted((packages or {}).items())),
                "node_types": sorted(node_types),
            },
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=True,
        )
        return cls(
            comfyui_version=comfyui_version,
            frontend_version=frontend_version,
            node_type_count=len(node_types),
            digest="sha256:" + hashlib.sha256(document.encode("ascii")).hexdigest(),
        )

    def to_document(self) -> Dict[str, Any]:
        return {
            "comfyui_version": self.comfyui_version,
            "frontend_version": self.frontend_version,
            "node_type_count": self.node_type_count,
            "digest": self.digest,
        }


@dataclass(frozen=True)
class Conversion:
    """What the bridge has to say about one workflow.

    ``document`` is filled **only** for a status of
    :attr:`ConversionStatus.CONVERTED` or :attr:`ConversionStatus.REUSED`.  A
    failure carries a category and a detail and no graph, and there is no
    constructor here that produces both a failure and a document.
    """

    status: ConversionStatus
    document: Optional[Mapping[str, Any]] = None
    category: Optional[str] = None
    detail: Optional[str] = None
    identity: Optional[ComfyIdentity] = None

    @property
    def succeeded(self) -> bool:
        return self.status in (ConversionStatus.CONVERTED, ConversionStatus.REUSED)

    @property
    def bytes(self) -> Optional[bytes]:
        return None if self.document is None else api_bytes(self.document)

    def to_document(self) -> Dict[str, Any]:
        return {
            "status": self.status.value,
            "category": self.category,
            "detail": self.detail,
            "comfy": self.identity.to_document() if self.identity is not None else None,
        }


def api_bytes(document: Mapping[str, Any]) -> bytes:
    """The exact bytes a converted graph is stored and hashed as.

    One definition, used by the snapshot on disk, by the cache and by the hash
    that names the file -- three copies of "how a graph is serialised" is how
    a cache comes to miss on content it already has.
    """

    return json.dumps(document, indent=2, ensure_ascii=False, sort_keys=False).encode(
        "utf-8"
    )


# --------------------------------------------------------------------------
# The sentence a user reads when the bridge cannot run
# --------------------------------------------------------------------------


def unreachable_reason(url: str, detail: str) -> str:
    """Why nothing was converted, and the one command that fixes it.

    Actionable is the requirement: it names what was probed, states plainly
    that nothing was converted and nothing written, and gives the command.  It
    must never read as though LocalCanvas might have another way of getting
    there -- it has not, and falling back to inferring an API graph from the
    canvas is the one thing this whole capability exists to avoid.
    """

    return (
        "ComfyUI is not reachable at {url}, so this workflow was not converted. "
        "Nothing was written for it and nothing was guessed: turning an editor "
        "workflow into an executable one needs the node definitions of the "
        "ComfyUI build that saved it, and LocalCanvas will not invent them. "
        "Start ComfyUI with scripts\\start.ps1, then run this sync again. "
        "({detail})".format(url=url, detail=detail)
    )


def not_ready_reason(url: str, detail: str) -> str:
    """ComfyUI answered, but is not far enough on to be asked anything.

    A different sentence from :func:`unreachable_reason` because it needs a
    different action: starting a second ComfyUI is exactly the wrong response
    to one that is still importing its custom nodes, which on a large
    installation takes minutes.

    **Narrower in practice than it sounds**, and worth knowing before relying
    on it: real ComfyUI binds its port *after* importing its nodes, so an
    instance that is genuinely mid-start-up usually refuses the connection
    outright and is reported by :func:`unreachable_reason` instead.  This one
    is reached when something answers ``/system_stats`` and cannot yet answer
    ``/object_info`` -- a partially initialised build, or a proxy in front of
    one.  The split is still worth having, because the two need opposite
    actions; it is simply not the common case.
    """

    return (
        "ComfyUI at {url} is running but has not finished loading its nodes, so "
        "this workflow was not converted and nothing was written for it. "
        "Converting needs the node definitions, and LocalCanvas will not guess "
        "them. Wait until ComfyUI has finished starting, then run this sync "
        "again. ({detail})".format(url=url, detail=detail)
    )


def no_browser_reason(candidates: Sequence[str]) -> str:
    return (
        "no installed browser was found, so this workflow was not converted and "
        "nothing was written for it. The conversion runs ComfyUI's own frontend "
        "in a browser already on this machine; LocalCanvas never downloads one. "
        "Install Google Chrome or Microsoft Edge and run this sync again. "
        "Looked for: {}.".format(", ".join(candidates))
    )


# --------------------------------------------------------------------------
# The Chrome DevTools Protocol, in the little of it this needs
# --------------------------------------------------------------------------


class BridgeError(Exception):
    """The bridge could not do its job.  Carries a deterministic category."""

    def __init__(self, category: str, detail: str) -> None:
        super().__init__(detail)
        self.category = category
        self.detail = detail


class CdpSession:
    """One DevTools connection to one page.

    Deliberately tiny: ``Runtime.enable`` and ``Runtime.evaluate`` are the whole
    of it.  ``send`` is separated from the socket so that the transport is the
    project's existing ``websockets`` dependency and nothing new.
    """

    def __init__(self, socket: Any, *, timeout: float = 180.0) -> None:
        self._socket = socket
        self._timeout = timeout
        self._counter = 0

    def call(
        self, method: str, params: Optional[Mapping[str, Any]] = None,
        *, timeout: Optional[float] = None,
    ) -> Mapping[str, Any]:
        self._counter += 1
        identifier = self._counter
        limit = self._timeout if timeout is None else timeout
        try:
            self._socket.send(
                json.dumps(
                    {"id": identifier, "method": method, "params": dict(params or {})}
                )
            )
        except Exception as exc:  # noqa: BLE001 - any transport failure is one thing
            raise BridgeError(
                CATEGORY_BRIDGE_ERROR,
                "the browser connection failed while sending {} ({}).".format(
                    method, exc
                ),
            ) from exc
        deadline = time.monotonic() + limit
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise BridgeError(
                    CATEGORY_BRIDGE_ERROR,
                    "the browser did not answer {} within {:g}s.".format(method, limit),
                )
            try:
                raw = self._socket.recv(timeout=remaining)
            except Exception as exc:  # noqa: BLE001
                raise BridgeError(
                    CATEGORY_BRIDGE_ERROR,
                    "the browser connection failed while waiting for {} ({}).".format(
                        method, exc
                    ),
                ) from exc
            try:
                message = json.loads(raw)
            except (TypeError, ValueError):
                continue
            if not isinstance(message, dict) or message.get("id") != identifier:
                continue
            if "error" in message:
                raise BridgeError(
                    CATEGORY_BRIDGE_ERROR,
                    "the browser refused {}: {}".format(method, message["error"]),
                )
            result = message.get("result")
            return result if isinstance(result, dict) else {}

    def evaluate(self, expression: str, *, timeout: Optional[float] = None) -> Any:
        """Run one expression in the page and return its value.

        ``awaitPromise`` because both expressions this module sends are async,
        and ``returnByValue`` because the answer has to cross the wire as data
        rather than as a handle to an object living in the page.
        """

        result = self.call(
            "Runtime.evaluate",
            {
                "expression": expression,
                "awaitPromise": True,
                "returnByValue": True,
            },
            timeout=timeout,
        )
        if result.get("exceptionDetails"):
            details = result["exceptionDetails"]
            exception = details.get("exception") or {}
            raise BridgeError(
                CATEGORY_BRIDGE_ERROR,
                "the page threw while converting: {}".format(
                    exception.get("description") or details.get("text") or "unknown"
                ),
            )
        value = result.get("result")
        return value.get("value") if isinstance(value, dict) else None


# --------------------------------------------------------------------------
# The browser process
# --------------------------------------------------------------------------


def _get_json(url: str, timeout: float) -> Any:
    with urllib.request.urlopen(url, timeout=timeout) as response:  # noqa: S310
        return json.loads(response.read().decode("utf-8"))


#: The name every profile this module creates begins with, and the only name it
#: will ever delete.
PROFILE_PREFIX = "localcanvas-conversion-"


def is_own_profile(path: str) -> bool:
    """Is ``path`` a profile directory *this module* made?

    Three conditions, all of them: it is a directory that exists, it sits
    **directly** in the system temporary directory, and its name begins with
    :data:`PROFILE_PREFIX`.  Links -- junctions as well as symbolic links --
    are resolved on both sides first, so one planted in the temporary directory
    cannot borrow the answer for somewhere else.

    Each of the four is held by a test that fails on its own
    (``test_only_a_profile_this_module_made_is_ever_deleted`` and
    ``test_a_link_planted_in_the_temp_directory_does_not_borrow_its_answer``).
    That is worth saying here because the first version of those tests refused
    every case on the *name*, so two of these conditions could be deleted with
    the suite still green -- which is the failure this whole card has been
    about, arriving in the guard added because of it.
    """

    if not path:
        return False
    try:
        resolved = Path(path).resolve()
        if not resolved.is_dir():
            return False
        if resolved.parent != Path(tempfile.gettempdir()).resolve():
            return False
    except OSError:
        return False
    return resolved.name.startswith(PROFILE_PREFIX)


def remove_own_profile(path: str) -> bool:
    """Delete a profile this module created, and refuse anything else.

    A recursive delete of an unvalidated string does not belong in a module
    whose whole purpose is not touching the user's things.  Nothing about the
    shipped code passes a path from outside -- the only value that reaches here
    is one :func:`tempfile.mkdtemp` returned moments earlier -- and that is
    exactly why this check is cheap: it costs one ``stat`` and it turns a class
    of edit that would be catastrophic into one that leaves a directory behind.

    The concrete shape of that edit is not hypothetical.  A test mutation
    asking "can the user's own browser profile be used?" once pointed
    ``--user-data-dir`` at a real Chrome profile, and the ``close()`` that
    followed deleted it.  A mutation is a loaded weapon; this is the safety
    catch on the weapon.

    Returns whether anything was removed, so a test can tell "refused" from
    "there was nothing there".
    """

    if not is_own_profile(path):
        return False
    shutil.rmtree(path, ignore_errors=True)
    return True


@dataclass
class BridgeTimeouts:
    """How long each step may take.  Constants, not configuration.

    Nothing here is a fixed sleep standing in for readiness: every one of these
    is the *limit* on a poll that stops as soon as the thing it waits for is
    true, which is the same rule `docs/runtime.md` puts on start-up probes.
    """

    comfy_probe: float = 5.0
    browser_start: float = 60.0
    page_target: float = 60.0
    frontend_ready: float = 240.0
    conversion: float = 300.0
    browser_stop: float = 20.0


class BrowserSession:
    """A launched browser, its temporary profile, and the page connection.

    The profile is created by this object and removed by it.  The user's own
    profile is never named, never opened and never passed on a command line;
    `docs/privacy-security.md` requires that and :func:`browser_command` is
    where it is visible.

    The process is stopped through the handle this object holds -- never by
    name, never by the port it has, which is the rule `docs/runtime.md` states
    for every process LocalCanvas starts.
    """

    def __init__(
        self,
        program: Sequence[str],
        *,
        url: str,
        timeouts: Optional[BridgeTimeouts] = None,
        popen: Callable[..., Any] = subprocess.Popen,
        connect: Optional[Callable[..., Any]] = None,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self._program = tuple(program)
        self._url = url
        self._timeouts = timeouts or BridgeTimeouts()
        self._popen = popen
        self._connect = connect
        self._sleep = sleep
        self._process: Any = None
        self._profile: Optional[str] = None
        self._socket: Any = None
        self.command: Tuple[str, ...] = ()
        self.session: Optional[CdpSession] = None

    # -- lifecycle ---------------------------------------------------------

    def __enter__(self) -> "BrowserSession":
        self.open()
        return self

    def __exit__(self, *exc_info: Any) -> None:
        self.close()

    def open(self) -> None:
        self._profile = tempfile.mkdtemp(prefix=PROFILE_PREFIX)
        self.command = browser_command(
            self._program, profile_dir=self._profile, url=self._url
        )
        try:
            self._process = self._popen(
                list(self.command),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except OSError as exc:
            raise BridgeError(
                CATEGORY_BROWSER_NOT_STARTED,
                "the browser could not be started ({}): {}".format(
                    exc.strerror or exc, self._program[0]
                ),
            ) from exc
        port = self._await_port()
        target = self._await_page(port)
        connect = self._connect
        if connect is None:
            from websockets.sync.client import connect as connect  # noqa: PLC0415

        try:
            self._socket = connect(
                target, max_size=_MAX_FRAME_BYTES, open_timeout=self._timeouts.browser_start
            )
        except Exception as exc:  # noqa: BLE001
            raise BridgeError(
                CATEGORY_BROWSER_NOT_STARTED,
                "the browser's debugging connection could not be opened ({}).".format(
                    exc
                ),
            ) from exc
        self.session = CdpSession(self._socket, timeout=self._timeouts.conversion)
        self.session.call("Runtime.enable")

    def close(self) -> None:
        """Close the connection, end the process, remove the profile.

        Every step runs even if an earlier one failed: a temporary profile left
        behind is a directory of somebody else's browser data on a machine
        LocalCanvas promised to leave alone.
        """

        socket, self._socket = self._socket, None
        if socket is not None:
            try:
                socket.close()
            except Exception:  # noqa: BLE001
                pass
        process, self._process = self._process, None
        if process is not None:
            try:
                process.terminate()
                process.wait(timeout=self._timeouts.browser_stop)
            except Exception:  # noqa: BLE001
                try:
                    process.kill()
                except Exception:  # noqa: BLE001
                    pass
        profile, self._profile = self._profile, None
        if profile is not None:
            remove_own_profile(profile)

    @property
    def profile_dir(self) -> Optional[str]:
        return self._profile

    # -- the two waits -----------------------------------------------------

    def _await_port(self) -> int:
        """The debugging port the browser chose, from the file it writes.

        Read from the profile rather than assumed, because the port was asked
        for as 0 -- so two syncs, or a sync beside anything else using a
        debugging port, cannot collide.
        """

        assert self._profile is not None
        marker = Path(self._profile) / "DevToolsActivePort"
        deadline = time.monotonic() + self._timeouts.browser_start
        while time.monotonic() < deadline:
            if self._exited():
                raise BridgeError(
                    CATEGORY_BROWSER_NOT_STARTED,
                    "the browser exited before it published a debugging port.",
                )
            try:
                lines = marker.read_text(encoding="utf-8").splitlines()
            except OSError:
                lines = []
            if lines and lines[0].strip().isdigit():
                return int(lines[0].strip())
            self._sleep(0.05)
        raise BridgeError(
            CATEGORY_BROWSER_NOT_STARTED,
            "the browser did not publish a debugging port within {:g}s.".format(
                self._timeouts.browser_start
            ),
        )

    def _await_page(self, port: int) -> str:
        """The debugging address of the page showing ComfyUI."""

        listing = "http://127.0.0.1:{}/json/list".format(port)
        deadline = time.monotonic() + self._timeouts.page_target
        last = "no page had opened yet"
        while time.monotonic() < deadline:
            try:
                targets = _get_json(listing, timeout=5.0)
            except (urllib.error.URLError, OSError, ValueError) as exc:
                last = str(exc)
                targets = []
            for target in targets if isinstance(targets, list) else []:
                if not isinstance(target, dict):
                    continue
                if target.get("type") != "page":
                    continue
                if not str(target.get("url", "")).startswith(self._url):
                    continue
                address = target.get("webSocketDebuggerUrl")
                if address:
                    return str(address)
            self._sleep(0.1)
        raise BridgeError(
            CATEGORY_BROWSER_NOT_STARTED,
            "the browser never opened a page on {} ({}).".format(self._url, last),
        )

    def _exited(self) -> bool:
        try:
            return self._process.poll() is not None
        except Exception:  # noqa: BLE001
            return False


#: CDP answers carry the whole converted graph in one frame, and a large
#: workflow expands into a large one.  The default cap is a megabyte, which a
#: real workflow passes today and would not always.
_MAX_FRAME_BYTES = 128 * 1024 * 1024


# --------------------------------------------------------------------------
# The bridge
# --------------------------------------------------------------------------


class ConversionBridge:
    """Converts editor workflows by asking the user's ComfyUI, once per run.

    One browser is launched for a whole run and every workflow goes through the
    same page: the frontend takes about twenty seconds to register its node
    types and a conversion then takes a fraction of a second, so a browser per
    workflow would be the whole cost of the feature.

    Failure is per workflow.  A graph the frontend refuses produces a category,
    a detail and **no output**, and the next workflow is converted regardless --
    the same isolation every other stage of this sync already has.  Only a
    failure that means the bridge itself cannot run (no ComfyUI, no browser, no
    frontend) stops the rest, and then every workflow is told the same
    actionable thing rather than being silently skipped.
    """

    def __init__(
        self,
        comfy_url: str,
        *,
        program: Optional[Sequence[str]] = None,
        candidates: Sequence[str] = BROWSER_CANDIDATES,
        timeouts: Optional[BridgeTimeouts] = None,
        popen: Callable[..., Any] = subprocess.Popen,
        connect: Optional[Callable[..., Any]] = None,
        get_json: Callable[[str, float], Any] = _get_json,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self.comfy_url = comfy_url.rstrip("/")
        self._program = tuple(program) if program is not None else None
        self._candidates = tuple(candidates)
        self._timeouts = timeouts or BridgeTimeouts()
        self._popen = popen
        self._connect = connect
        self._get_json = get_json
        self._sleep = sleep
        self._session: Optional[BrowserSession] = None
        self._identity: Optional[ComfyIdentity] = None
        self._blocked: Optional[BridgeError] = None
        #: What this ComfyUI declares its inputs accept, keyed on which
        #: ComfyUI said it.  Filled from the ``/object_info`` the identity
        #: probe already fetches, so it costs no second request.
        self._contracts = ContractCache()
        #: Every workflow converted in this run, keyed by source content hash,
        #: so two byte-identical sources cost one conversion and still get a
        #: record of their own.
        self._seen: Dict[str, Conversion] = {}

    # -- lifecycle ---------------------------------------------------------

    def __enter__(self) -> "ConversionBridge":
        return self

    def __exit__(self, *exc_info: Any) -> None:
        self.close()

    def close(self) -> None:
        session, self._session = self._session, None
        if session is not None:
            session.close()

    @property
    def identity(self) -> Optional[ComfyIdentity]:
        """What produced this run's conversions, once anything has been asked."""

        return self._identity

    def runtime_contract(self) -> Optional[RuntimeContract]:
        """What this run's ComfyUI declares its inputs accept, or ``None``.

        ``None`` until :meth:`ensure_identity` has succeeded.  Until then this
        run has not established *which* ComfyUI it is talking to, and a
        contract that cannot be attributed to one installation must not be
        used to describe a graph -- what an input accepts is exactly what moves
        when a custom node is installed, updated or removed.

        The lookup goes through the cache's key rather than round a check of
        its own, so there is one place where "the right ComfyUI" is decided.

        **Passing the digest here is defence in depth, and it is worth saying
        so.**  One bridge talks to one ComfyUI and therefore stores at most one
        contract, so today ``get(digest)`` and "hand back the only one there
        is" cannot be told apart by any test -- a mutation replacing the second
        line with the latter passes the whole suite.  The real provenance check
        is :meth:`ContractCache.get`, which a mutation *does* kill.

        It stays, rather than joining the two clauses deleted in the same round
        for exactly this reason, because deleting it is not what is on offer:
        the alternative is not "no check" but "take whatever is in the cache",
        which is a worse way of writing the same line and hides the fact that a
        contract belongs to an identity.  What is deleted here is the pretence
        that it is a guard -- it is the key, and the class's own one-ComfyUI
        invariant is what makes it look like more.

        The ``None`` above it is a different matter and is genuinely live:
        **delete** it and this asks the digest of an identity that does not
        exist yet, which turns three tests red, among them
        ``test_a_bridge_that_has_asked_nothing_has_no_contract_to_give``.
        (Measured, and stated as deletion on purpose: a *rewrite* that keeps
        the behaviour by other means -- reaching the digest defensively -- of
        course passes, and would not have been evidence about the guard.)
        """

        if self._identity is None:
            return None
        return self._contracts.get(self._identity.digest)

    @property
    def blocked(self) -> Optional[Conversion]:
        """The whole-run failure this bridge has already hit, if any.

        Read by nothing in the engine -- every workflow is told the same thing
        through :meth:`convert`, which is the shape that keeps failure per
        workflow -- and here so that a caller with a long list can stop asking.
        """

        if self._blocked is None:
            return None
        return _unavailable(self._blocked)

    # -- one workflow ------------------------------------------------------

    def convert(self, raw: bytes, *, content_hash: str) -> Conversion:
        """Convert one editor workflow.  Never raises.

        ``content_hash`` identifies the source, and is what makes two identical
        sources one conversion.  It is the caller's hash of the caller's bytes:
        this module does not open files.
        """

        remembered = self._seen.get(content_hash)
        if remembered is not None:
            return remembered
        result = self._convert(raw)
        self._seen[content_hash] = result
        return result

    def _convert(self, raw: bytes) -> Conversion:
        if self._blocked is not None:
            return _unavailable(self._blocked)
        try:
            session = self._ensure_session()
        except BridgeError as error:
            self._blocked = error
            return _unavailable(error)

        try:
            text = raw.decode("utf-8-sig")
        except UnicodeDecodeError as exc:
            return Conversion(
                status=ConversionStatus.FAILED,
                category=CATEGORY_CONVERSION_REJECTED,
                detail="this file is not UTF-8 text ({}), so it could not be "
                       "handed to ComfyUI.".format(exc.reason),
                identity=self._identity,
            )

        try:
            answer = session.evaluate(
                conversion_expression(text), timeout=self._timeouts.conversion
            )
        except BridgeError as error:
            # A transport failure is about the browser, not about this graph,
            # so it stops the run rather than being recorded as this
            # workflow's fault -- reporting sixty-six "bad workflow" lines for
            # one dead browser would send a user looking in the wrong place.
            self._blocked = error
            return _unavailable(error)

        return self._judge(answer)

    def _judge(self, answer: Any) -> Conversion:
        """Turn what the page said into a status -- and validate the graph.

        The validation is the point of this function.  ``graphToPrompt``
        succeeding does not mean the graph is usable: a node type this ComfyUI
        does not have converts into a node with no ``class_type``, and an empty
        canvas converts into ``{}``.  Both go through the *same*
        :func:`classify` a hand-made export is judged by, and anything it does
        not call an importable API graph is a failure with no output.
        """

        if not isinstance(answer, dict):
            return Conversion(
                status=ConversionStatus.FAILED,
                category=CATEGORY_BRIDGE_ERROR,
                detail=with_action(
                    CATEGORY_BRIDGE_ERROR,
                    "ComfyUI's frontend answered something this does not "
                    "understand ({}).".format(type(answer).__name__),
                ),
                identity=self._identity,
            )
        if not answer.get("ok"):
            return Conversion(
                status=ConversionStatus.FAILED,
                category=CATEGORY_CONVERSION_REJECTED,
                detail="ComfyUI's own frontend refused to convert this workflow: "
                       "{}: {}. Open it in ComfyUI and see what it says about "
                       "it.".format(
                           answer.get("name") or "Error",
                           answer.get("message") or "no message",
                       ),
                identity=self._identity,
            )
        document = answer.get("output")
        if not isinstance(document, dict):
            return Conversion(
                status=ConversionStatus.FAILED,
                category=CATEGORY_BRIDGE_ERROR,
                detail=with_action(
                    CATEGORY_BRIDGE_ERROR,
                    "ComfyUI's frontend reported success but produced no graph.",
                ),
                identity=self._identity,
            )

        verdict = classify(api_bytes(document))
        if not verdict.importable:
            return Conversion(
                status=ConversionStatus.FAILED,
                category=CATEGORY_NOT_IMPORTABLE,
                detail="ComfyUI converted this workflow, but what came back is "
                       "not a graph LocalCanvas can run: {} Nothing was written "
                       "for it. This usually means a node in it is not installed "
                       "in this ComfyUI.".format(
                           verdict.reason or "it is not an API-format graph."
                       ),
                identity=self._identity,
            )
        return Conversion(
            status=ConversionStatus.CONVERTED,
            document=document,
            identity=self._identity,
        )

    # -- getting there -----------------------------------------------------

    def ensure_identity(self) -> ComfyIdentity:
        """Which ComfyUI this run is talking to, without launching anything.

        Called before the cache is consulted, which is the whole reason it
        exists separately from :meth:`_ensure_session`: a run in which every
        workflow already has a valid snapshot must not pay for a browser, and
        it cannot know that until it knows the identity.
        """

        if self._identity is None:
            self._identity = self._probe_comfy()
        return self._identity

    def _ensure_session(self) -> CdpSession:
        if self._session is not None and self._session.session is not None:
            return self._session.session

        self.ensure_identity()
        program = self._program or find_browser(self._candidates)
        if program is None:
            raise BridgeError(
                CATEGORY_BROWSER_NOT_FOUND, no_browser_reason(self._candidates)
            )

        session = BrowserSession(
            program,
            url=self.comfy_url,
            timeouts=self._timeouts,
            popen=self._popen,
            connect=self._connect,
            sleep=self._sleep,
        )
        try:
            session.open()
            self._await_frontend(session)
        except BridgeError:
            session.close()
            raise
        except Exception as exc:  # noqa: BLE001
            session.close()
            raise BridgeError(
                CATEGORY_BROWSER_NOT_STARTED,
                "the conversion browser could not be prepared ({}).".format(exc),
            ) from exc

        self._session = session
        assert session.session is not None
        return session.session

    def _probe_comfy(self) -> ComfyIdentity:
        """Ask ComfyUI what it is, and fail actionably when it is not there.

        This runs before a browser is launched, deliberately: a user whose
        ComfyUI is not running should be told to start it, not watch a browser
        open on a refused connection.

        Two documents, because the identity needs both -- the versions from
        ``/system_stats`` and the installed node types, which are the keys of
        ``/object_info``.  Only the keys go into the **digest**; the values
        carry the user's own model file lists, which are none of a cache key's
        business and would invalidate every snapshot the moment a model was
        added.

        The values are read once, here, for something else entirely: what each
        class declares its inputs accept (`contract.py`).  That is stored
        against this identity's digest and never enters it, so adding a model
        still invalidates nothing -- and a run that talks to a different
        ComfyUI gets that ComfyUI's contract or none at all.
        """

        system = self._fetch("/system_stats", CATEGORY_COMFY_UNREACHABLE)
        if not isinstance(system, dict):
            raise BridgeError(
                CATEGORY_COMFY_UNREACHABLE,
                unreachable_reason(
                    self.comfy_url,
                    "something answered but it is not ComfyUI: {} is not a "
                    "system report".format(type(system).__name__),
                ),
            )
        stats = system.get("system")
        stats = stats if isinstance(stats, dict) else {}

        nodes = self._fetch("/object_info", CATEGORY_COMFY_NOT_READY)
        if not isinstance(nodes, dict) or not nodes:
            raise BridgeError(
                CATEGORY_COMFY_NOT_READY,
                not_ready_reason(
                    self.comfy_url, "it listed no installed nodes at /object_info"
                ),
            )
        identity = ComfyIdentity.build(
            comfyui_version=_text(stats, "comfyui_version"),
            frontend_version=_text(stats, "required_frontend_version"),
            node_types=[str(name) for name in nodes],
            packages=_packages(stats),
        )
        self._contracts.store(read_object_info(nodes, identity_digest=identity.digest))
        return identity

    def _fetch(self, path: str, category: str) -> Any:
        try:
            return self._get_json(self.comfy_url + path, self._timeouts.comfy_probe)
        except Exception as exc:  # noqa: BLE001 - every failure is "not there"
            if category == CATEGORY_COMFY_NOT_READY:
                raise BridgeError(
                    category, not_ready_reason(self.comfy_url, str(exc))
                ) from exc
            raise BridgeError(
                category, unreachable_reason(self.comfy_url, str(exc))
            ) from exc

    def _await_frontend(self, session: BrowserSession) -> None:
        """Poll until the frontend has registered its node types.

        A poll, not a sleep: it returns the instant the page is ready, and the
        timeout is only the limit.  The page is still navigating for the first
        moments, and an evaluation against a context that is being replaced
        fails -- so a refusal here is a retry, not an outcome.
        """

        assert session.session is not None
        deadline = time.monotonic() + self._timeouts.frontend_ready
        last = "the page never reported a ready frontend"
        while time.monotonic() < deadline:
            try:
                answer = session.session.evaluate(READY_EXPRESSION, timeout=20.0)
            except BridgeError as error:
                last = error.detail
                answer = None
            if isinstance(answer, dict) and answer.get("node_types"):
                return
            self._sleep(0.25)
        raise BridgeError(
            CATEGORY_FRONTEND_NOT_READY,
            "ComfyUI's frontend did not finish loading in the conversion browser "
            "within {:g}s. ({})".format(self._timeouts.frontend_ready, last),
        )


#: What to do about the three categories whose detail is a description of what
#: broke rather than an instruction.
#:
#: The other categories compose whole sentences of their own
#: (:func:`unreachable_reason` and its neighbours) because there is one useful
#: thing to say about each.  These three cannot: the informative part is
#: whatever the browser or the connection actually did, which varies.  So the
#: detail carries that and the action is added here -- once, in one table, so
#: that **every** state in which the bridge cannot run tells a user what to do,
#: which is what the design asks for and what a category alone does not give
#: them.
ACTIONS: Dict[str, str] = {
    CATEGORY_BROWSER_NOT_STARTED: (
        "Nothing was converted and nothing was written. LocalCanvas runs "
        "ComfyUI's own frontend in a browser already installed on this machine, "
        "in a temporary profile of its own; check that Chrome or Edge starts "
        "normally here, then run this sync again. To carry on without "
        "conversion, run it with -NoConvert and export from ComfyUI by hand."
    ),
    CATEGORY_FRONTEND_NOT_READY: (
        "Nothing was converted and nothing was written. A ComfyUI with many "
        "custom nodes can take longer than that to register them all: open "
        "ComfyUI in a browser yourself and see whether its editor finishes "
        "loading, then run this sync again. To carry on without conversion, "
        "run it with -NoConvert and export from ComfyUI by hand."
    ),
    CATEGORY_BRIDGE_ERROR: (
        "Nothing was written for it. The browser and its temporary profile are "
        "removed either way, so nothing is left running: run this sync again. "
        "To carry on without conversion, run it with -NoConvert and export "
        "from ComfyUI by hand."
    ),
}


def with_action(category: Optional[str], detail: str) -> str:
    """``detail``, and what to do about it when the category needs saying."""

    action = ACTIONS.get(category or "")
    return detail if action is None else "{} {}".format(detail, action)


def _unavailable(error: BridgeError) -> Conversion:
    return Conversion(
        status=ConversionStatus.UNAVAILABLE,
        category=error.category,
        detail=with_action(error.category, error.detail),
    )


def _text(mapping: Mapping[str, Any], key: str) -> str:
    value = mapping.get(key)
    return str(value) if isinstance(value, (str, int, float)) else "unknown"


def _packages(stats: Mapping[str, Any]) -> Dict[str, str]:
    """The installed versions ComfyUI reports for its own packages.

    Part of the identity because a frontend package update changes what a
    conversion produces, and it is the one thing that moves when ComfyUI itself
    does not.  Read defensively: this is another build's document, and an older
    or newer one need not carry the key at all.
    """

    raw = stats.get("comfy_package_versions")
    packages: Dict[str, str] = {}
    if isinstance(raw, list):
        for entry in raw:
            if isinstance(entry, dict) and entry.get("name"):
                packages[str(entry["name"])] = str(entry.get("installed", ""))
    return packages


__all__ = [
    "ACTIONS",
    "BROWSER_CANDIDATES",
    "BROWSER_FLAGS",
    "CATEGORY_BRIDGE_ERROR",
    "CATEGORY_BROWSER_NOT_FOUND",
    "CATEGORY_BROWSER_NOT_STARTED",
    "CATEGORY_COMFY_NOT_READY",
    "CATEGORY_COMFY_UNREACHABLE",
    "CATEGORY_CONVERSION_REJECTED",
    "CATEGORY_FRONTEND_NOT_READY",
    "CATEGORY_NOT_IMPORTABLE",
    "CONVERT_MARKER",
    "LOOPBACK_ONLY_RESOLVER_RULE",
    "NO_PROXY_FLAG",
    "PROFILE_PREFIX",
    "READY_EXPRESSION",
    "BridgeError",
    "BridgeTimeouts",
    "BrowserSession",
    "CdpSession",
    "ComfyIdentity",
    "Conversion",
    "ConversionBridge",
    "ConversionStatus",
    "api_bytes",
    "browser_command",
    "conversion_expression",
    "find_browser",
    "is_own_profile",
    "no_browser_reason",
    "not_ready_reason",
    "remove_own_profile",
    "unreachable_reason",
    "with_action",
]
