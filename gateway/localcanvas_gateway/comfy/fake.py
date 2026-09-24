"""A protocol-faithful fake ComfyUI, speaking real HTTP on a real socket.

This is what makes the ComfyUI half of the gateway verifiable without hardware:
the client under test opens a socket, sends the same requests it sends to
ComfyUI, and parses the same response shapes.  Nothing is monkeypatched, and no
test asserts against a stub of the code it is testing.

It lives in the package rather than in ``tests/`` on purpose -- the runtime
scripts and later cards need something to point at that is not a real GPU.

**Fidelity is the whole point**, so the shapes below are ComfyUI's, not ones
that would be convenient here:

* ``POST /prompt`` answers ``{"prompt_id", "number", "node_errors"}``, and a
  refusal is **400** with ``{"error": {"type", "message", "details",
  "extra_info"}, "node_errors": {...}}``;
* ``GET /history/{id}`` is ``{}`` until the prompt finishes, then
  ``{id: {"prompt": [...], "outputs": {...}, "status": {...}}}``, where
  ``outputs`` is keyed by **node id** and each file is
  ``{"filename", "subfolder", "type"}``;
* ``GET /queue`` is ``{"queue_running": [...], "queue_pending": [...]}`` and
  each entry is the 5-element list ComfyUI uses, whose second element is the
  prompt id;
* ``GET /view`` takes ``filename``/``subfolder``/``type`` and returns bytes;
* ``POST /queue`` takes ``{"delete": [prompt_id]}`` and removes a prompt that
  has not started, answering 200 whether or not it was there;
* ``POST /interrupt`` stops whatever is executing and names no prompt.  What
  ComfyUI then records is the point of :attr:`FakeComfy.interrupt_outcome`: an
  interrupt is checked *between nodes*, so a prompt whose last node had already
  finished completes normally and is recorded as a **success**.  That race is
  the one `docs/recovery.md` says must never be reported as a cancellation, and
  this switch is how a test reaches it;
* ``GET /ws`` is a WebSocket, and it is where ComfyUI reports execution
  progress -- there is no HTTP endpoint for it.  Messages are JSON text frames
  ``{"type": ..., "data": {...}}``: ``execution_start``, ``executing``,
  ``progress`` (``{"value", "max", "prompt_id", "node"}``), ``executed``,
  ``execution_success``, ``execution_error`` and ``execution_interrupted``.
  Nothing is emitted on a timer: a test sends each message by hand;
* ``POST /upload/image`` is multipart with the file in the ``image`` field, and
  answers ``{"name", "subfolder", "type"}``.  **The name it answers with is not
  always the name it was sent**: ComfyUI keeps an existing file and stores the
  newcomer as ``picture (1).png``, which is why the gateway binds what came back
  rather than what it asked for.  The uploaded file becomes retrievable from
  ``/view`` with ``type=input``, exactly as it is on a real installation.

Where fidelity is uncertain it says so in a ``NOTE(fidelity)`` comment instead
of being quietly smoothed over.

Behaviour is **controlled, not timed**: a test moves a prompt from queued to
running to completed by calling :meth:`FakeComfy.start_running` and
:meth:`FakeComfy.complete`.  Nothing here sleeps, so nothing here is flaky.
"""

from __future__ import annotations

import base64
import hashlib
import json
import socket
import struct
import threading
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict, List, Mapping, Optional, Tuple
from urllib.parse import parse_qs, urlparse

#: A valid 1x1 PNG.  Real bytes, so a client that decodes the result is not
#: being lied to; small enough to embed.
ONE_PIXEL_PNG = base64.b64decode(
    b"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmM"
    b"IQAAAABJRU5ErkJggg=="
)

#: NOTE(fidelity): the real ``/object_info`` is one entry per installed node
#: class and is megabytes on a populated installation.  Only its *shape* matters
#: to the gateway -- a JSON object that exists once nodes are loaded -- and the
#: gateway never reads a class name out of it, so the fake returns a small one.
#: The class name below is invented for this fake and names no real node.
OBJECT_INFO = {
    "FakeNode": {
        "input": {"required": {"value": ["STRING", {"default": ""}]}},
        "output": ["IMAGE"],
        "name": "FakeNode",
        "category": "fake",
    }
}


@dataclass
class _Prompt:
    """One submitted prompt, as the fake tracks it."""

    prompt_id: str
    number: int
    graph: Dict[str, Any]
    client_id: Optional[str]
    place: str = "pending"  # "pending" | "running" | "done"
    outputs: Dict[str, Any] = field(default_factory=dict)
    status: Optional[Dict[str, Any]] = None


class FakeComfy:
    """A local HTTP server that answers like ComfyUI.

    Use it as a context manager::

        with FakeComfy() as comfy:
            client = ComfyClient(comfy.base_url)

    Behaviour switches (all settable at any point, so one test can change its
    mind mid-run):

    ``ready``
        ``False`` makes ``/object_info`` answer 503 forever -- something is on
        the port and will never become usable.
    ``ready_after_probes``
        the number of ``/object_info`` probes that answer 503 before the rest
        answer 200: slow readiness, without a sleep.

        **NOTE(fidelity): the 503 is this fake's invention, not observed
        ComfyUI behaviour.**  Real ComfyUI imports its nodes *before* it binds
        the port, so a client that probes it during startup gets a refused
        connection, not an HTTP error -- which this gateway maps to
        ``unavailable``, not ``starting``.  The 503 exists here because
        ``starting`` is a documented state that needs *some* way to be reached
        in a test, and because a reverse proxy, a partially initialised build,
        or a foreign service on the port really can answer that way.  So
        ``starting`` is proven against this fake and not against ComfyUI: what
        is tested is that the client maps "answered, but not usably" to
        ``starting``, not that ComfyUI ever sends it.  ``client.py`` documents
        the same uncertainty from its side.
    ``reject_prompt``
        a message.  While set, ``POST /prompt`` answers 400 in ComfyUI's own
        error shape.
    ``malformed_history``
        while set, ``/history/{id}`` answers with a body that is well-formed
        JSON but not the documented shape.
    ``omit_history_status``
        while set, history entries carry no ``status`` block.  Older ComfyUI
        builds answer this way, and the client has a path for it; without this
        switch that path would never be exercised.
    ``reject_upload``
        an HTTP status.  While set, ``POST /upload/image`` answers with it
        instead of storing the file.
    ``upload_subfolder_override``
        a subfolder to store an upload in and report, whatever was asked for.
        ComfyUI decides where an input file goes; this is how a test says so --
        the gateway must bind what comes back, not what it sent.
    ``view_chunk_bytes``
        how much of a ``/view`` body is written per socket write.  A response
        split across writes is what lets a test see whether the gateway passes
        bytes through or waits for the last one.
    ``view_gate``
        a :class:`threading.Event`.  While set, ``/view`` writes the first
        chunk and then waits for the event before writing the rest -- a stalled
        backend, held still, with nothing timed.
    ``comfyui_version``
        what ``/system_stats`` reports for itself.
    ``installed_nodes``
        extra node class names to add to ``/object_info``, as an installation
        with different custom nodes would have.  Both exist because the workflow
        sync keys a cached conversion on **which ComfyUI produced it**
        (`workflows/sync/bridge.py`), and "a materially different ComfyUI" is
        otherwise not a situation a test can construct.
    ``node_inputs``
        the ``required`` input block one of those classes declares, in
        ``/object_info``'s own shape -- ``{"name": [["a", "b"], {}]}`` for an
        input offering a finite list of choices, ``{"name": ["INT", {}]}`` for
        one declared as a type.  It exists because "this runtime declares what
        that input accepts" is the whole of what the workflow sync's runtime
        contract reads (`workflows/sync/contract.py`), and it cannot be
        constructed by a test otherwise.

        **NOTE(fidelity): the shape is ComfyUI's public API format and the
        contents are invented for this fake.**  No installation was read to
        write it, and nothing here names a real node, a real model or a real
        setting.
    ``node_outputs``
        the ``output`` list one of those classes declares -- the type name of
        each socket, in socket order, ``["FLOAT", "INT"]`` -- beside
        ``node_inputs``.  A class with no entry declares ``[]``, exactly as
        every installed class did before this existed, so a test that sets
        nothing here is served the same document byte for byte.  It exists
        because what a class hands on is the evidence some of the workflow
        sync's judgements rest on (`workflows/sync/analysis.py`), and "every
        output of this node is a number" cannot be constructed by a test
        otherwise.  The same fidelity note applies: invented contents, public
        shape.
    """

    def __init__(
        self,
        *,
        host: str = "127.0.0.1",
        ready: bool = True,
        ready_after_probes: int = 0,
        reject_prompt: Optional[str] = None,
        malformed_history: bool = False,
        omit_history_status: bool = False,
        reject_upload: Optional[int] = None,
    ) -> None:
        self.ready = ready
        self.ready_after_probes = ready_after_probes
        self.reject_prompt = reject_prompt
        self.malformed_history = malformed_history
        self.omit_history_status = omit_history_status
        self.reject_upload = reject_upload
        self.comfyui_version = "fake"
        self.installed_nodes: Tuple[str, ...] = ()
        self.node_inputs: Dict[str, Mapping[str, Any]] = {}
        self.node_outputs: Dict[str, List[str]] = {}
        self.upload_subfolder_override: Optional[str] = None
        self.view_chunk_bytes: Optional[int] = None
        self.view_gate: Optional[threading.Event] = None
        #: What ``POST /interrupt`` does to the prompt that is executing:
        #: ``"interrupted"`` records ComfyUI's interrupted history,
        #: ``"completed"`` finishes it successfully -- the race in which the
        #: last node finished before the flag was read -- and ``"ignored"``
        #: leaves it running, which is what a real interrupt looks like in the
        #: moment before the executor notices it.
        self.interrupt_outcome = "interrupted"

        self.probe_count = 0
        #: Called with ``"METHOD /path"`` just before each request is served,
        #: which is the only place a test can make ComfyUI move *between* two
        #: of the gateway's calls.  Real timing, held still: the executor
        #: picking up a prompt at the instant a deletion arrives is a race, and
        #: a race asserted around is a race not tested.
        self.on_request: Optional[Any] = None
        #: Every request this fake received, as ``"METHOD /path"``, in order.
        #: What it is for: some properties are about *sequence*, not about the
        #: answer -- "a cancel reads before it acts" cannot be checked by
        #: looking at the outcome, because the outcome is the same either way
        #: right up until the one moment it is not.
        self.requests: List[str] = []
        self.submissions: List[Dict[str, Any]] = []
        self.view_requests: List[Dict[str, str]] = []
        self.uploads: List[Dict[str, Any]] = []
        #: Every ``POST /interrupt`` this fake received, in order.  A test that
        #: asserts a *completed* job was never interrupted reads this.
        self.interrupts: List[Optional[str]] = []
        #: Every prompt id named in a ``POST /queue`` deletion.
        self.queue_deletes: List[str] = []

        self._lock = threading.RLock()
        self._connections: "set" = set()
        self._prompts: Dict[str, _Prompt] = {}
        self._order: List[str] = []
        self._files: Dict[Tuple[str, str, str], Tuple[bytes, str]] = {}
        self._counter = 0
        self._sockets: List["_FakeWebSocket"] = []
        self._socket_opened = threading.Event()

        self._server = _Server((host, 0), _Handler)
        self._server.fake = self  # type: ignore[attr-defined]
        # A short poll interval keeps stop() prompt: socketserver only notices a
        # shutdown between polls, and a test suite pays that wait per server.
        self._thread = threading.Thread(
            target=self._server.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True
        )

    # -- lifecycle ---------------------------------------------------------

    def start(self) -> "FakeComfy":
        self._thread.start()
        return self

    def stop(self) -> None:
        """Stop serving, and mean it.

        Shutting the listening socket down is not enough: an HTTP/1.1 client
        holds a keep-alive connection whose handler thread would go on
        answering, so "ComfyUI went away" would not actually go away and a test
        that needs a dead backend would get a live one.  Every open connection
        is therefore closed as well.
        """

        self._server.shutdown()
        with self._lock:
            connections, self._connections = list(self._connections), set()
        for connection in connections:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        self._server.server_close()
        self._thread.join(timeout=5)

    def _track(self, connection: Any) -> None:
        with self._lock:
            self._connections.add(connection)

    def _untrack(self, connection: Any) -> None:
        with self._lock:
            self._connections.discard(connection)

    def __enter__(self) -> "FakeComfy":
        return self.start()

    def __exit__(self, *exc_info: Any) -> None:
        self.stop()

    @property
    def port(self) -> int:
        return int(self._server.server_address[1])

    @property
    def base_url(self) -> str:
        host, port = self._server.server_address[0], self._server.server_address[1]
        return "http://{}:{}".format(host, port)

    # -- control -----------------------------------------------------------

    def start_running(self, prompt_id: str) -> None:
        """Move a queued prompt to the running slot, as the executor would."""

        with self._lock:
            self._prompts[prompt_id].place = "running"

    def complete(
        self,
        prompt_id: str,
        *,
        node_id: str = "60",
        files: Optional[List[Mapping[str, str]]] = None,
        output_key: str = "images",
    ) -> List[Dict[str, str]]:
        """Finish a prompt successfully and register its output files.

        Returns the file descriptors it wrote into ``outputs``, each of which
        is retrievable from ``/view``.
        """

        if files is None:
            files = [{"filename": "{}_00001_.png".format(prompt_id), "subfolder": "", "type": "output"}]
        written: List[Dict[str, str]] = []
        with self._lock:
            prompt = self._prompts[prompt_id]
            for item in files:
                descriptor = {
                    "filename": item["filename"],
                    "subfolder": item.get("subfolder", ""),
                    "type": item.get("type", "output"),
                }
                written.append(descriptor)
                key = (descriptor["filename"], descriptor["subfolder"], descriptor["type"])
                self._files.setdefault(key, (ONE_PIXEL_PNG, "image/png"))
            prompt.outputs = {node_id: {output_key: written}}
            prompt.status = {
                "status_str": "success",
                "completed": True,
                "messages": [
                    ["execution_start", {"prompt_id": prompt_id}],
                    ["execution_success", {"prompt_id": prompt_id}],
                ],
            }
            prompt.place = "done"
        return written

    def leave_queue(self, prompt_id: str) -> None:
        """Take a prompt out of the queue without writing a history entry.

        NOTE(fidelity): this is the gap a real ComfyUI has between a prompt
        leaving the queue and its entry appearing in ``/history`` -- a real
        window, short and unavoidable, in which the two endpoints agree on
        nothing.  A client that guesses during it guesses wrong.
        """

        with self._lock:
            self._prompts[prompt_id].place = "gone"

    def interrupt_prompt(
        self,
        prompt_id: str,
        *,
        node_id: str = "60",
        partial_files: Optional[List[Mapping[str, str]]] = None,
    ) -> None:
        """Finish a prompt the way ComfyUI records one stopped by an interrupt.

        NOTE(fidelity): ``status_str`` really is ``"error"`` here.  ComfyUI
        raises ``InterruptProcessingException`` out of the executor and takes
        the same failure path it takes for a broken node, writing
        ``execution_interrupted`` instead of ``execution_error`` and **no**
        exception text.  A reader that only looks at ``status_str`` cannot tell
        a cancelled generation from a failed one, which is exactly why the
        client reads the messages.

        NOTE(fidelity): ``partial_files`` is the other half of the same record.
        ComfyUI keeps the ``outputs`` collected by nodes that finished before
        the interrupt, so a stopped run really can leave files in its history
        entry -- and a gateway that handed them over would be showing a result
        for a generation the user cancelled.  Empty by default, because most
        interrupts land inside the sampler; a test that wants the awkward case
        asks for it.
        """

        written: List[Dict[str, str]] = []
        with self._lock:
            for item in partial_files or ():
                descriptor = {
                    "filename": item["filename"],
                    "subfolder": item.get("subfolder", ""),
                    "type": item.get("type", "output"),
                }
                written.append(descriptor)
                key = (descriptor["filename"], descriptor["subfolder"], descriptor["type"])
                self._files.setdefault(key, (ONE_PIXEL_PNG, "image/png"))
            prompt = self._prompts[prompt_id]
            prompt.outputs = {node_id: {"images": written}} if written else {}
            prompt.status = {
                "status_str": "error",
                "completed": False,
                "messages": [
                    ["execution_start", {"prompt_id": prompt_id}],
                    [
                        "execution_interrupted",
                        {
                            "prompt_id": prompt_id,
                            "node_id": "40",
                            "node_type": "FakeNode",
                            "executed": [],
                        },
                    ],
                ],
            }
            prompt.place = "done"

    def fail(self, prompt_id: str, message: str = "Something went wrong in the graph") -> None:
        """Finish a prompt the way ComfyUI records an execution error."""

        with self._lock:
            prompt = self._prompts[prompt_id]
            prompt.outputs = {}
            prompt.status = {
                "status_str": "error",
                "completed": False,
                "messages": [
                    ["execution_start", {"prompt_id": prompt_id}],
                    [
                        "execution_error",
                        {
                            "prompt_id": prompt_id,
                            "node_id": "40",
                            "node_type": "FakeNode",
                            "exception_message": message,
                            "exception_type": "RuntimeError",
                            "traceback": ["fake traceback line"],
                        },
                    ],
                ],
            }
            prompt.place = "done"

    def put_file(
        self,
        filename: str,
        data: bytes,
        *,
        subfolder: str = "",
        type: str = "output",
        content_type: str = "image/png",
    ) -> None:
        """Register the bytes ``/view`` should serve for one output file."""

        with self._lock:
            self._files[(filename, subfolder, type)] = (data, content_type)

    @property
    def running_prompt_id(self) -> Optional[str]:
        with self._lock:
            for identifier in self._order:
                if self._prompts[identifier].place == "running":
                    return identifier
        return None

    # -- the event socket --------------------------------------------------

    @property
    def socket_count(self) -> int:
        """How many clients are attached to ``/ws`` right now."""

        with self._lock:
            return len(self._sockets)

    def wait_for_socket(self, timeout: float = 5.0) -> bool:
        """Block until something has connected to ``/ws`` at least once."""

        return self._socket_opened.wait(timeout)

    def emit(self, type_: str, data: Mapping[str, Any]) -> int:
        """Broadcast one ComfyUI event frame.  Returns how many sockets took it.

        ComfyUI addresses most execution messages at the submitting client's
        ``sid`` and broadcasts a few; this fake sends to everyone attached,
        because a gateway opens exactly one socket and the distinction has no
        observable consequence here.
        """

        payload = json.dumps({"type": type_, "data": dict(data)})
        with self._lock:
            sockets = list(self._sockets)
        delivered = 0
        for connection in sockets:
            if connection.send_text(payload):
                delivered += 1
            else:
                self._socket_closed(connection)
        return delivered

    def emit_progress(
        self, prompt_id: str, value: int, maximum: int, *, node: str = "30"
    ) -> int:
        """ComfyUI's per-step progress message, in its own shape."""

        return self.emit(
            "progress",
            {"value": value, "max": maximum, "prompt_id": prompt_id, "node": node},
        )

    def _socket_opened_now(self, connection: "_FakeWebSocket") -> None:
        with self._lock:
            self._sockets.append(connection)
        self._socket_opened.set()

    def _socket_closed(self, connection: "_FakeWebSocket") -> None:
        with self._lock:
            if connection in self._sockets:
                self._sockets.remove(connection)
        connection.close()

    # -- control -----------------------------------------------------------

    @property
    def prompt_ids(self) -> List[str]:
        with self._lock:
            return list(self._order)

    @property
    def input_files(self) -> List[str]:
        """The files in this ComfyUI's input directory, as a loader names them.

        ``subfolder/name`` when the file is in one, plain ``name`` when it is
        not -- the reference a loader input takes, so a test can compare what
        was bound against what is actually there.
        """

        with self._lock:
            return [
                "{}/{}".format(subfolder, filename) if subfolder else filename
                for (filename, subfolder, type_) in self._files
                if type_ == "input"
            ]

    # -- request handling, called from the server thread -------------------

    def _submit(self, body: Mapping[str, Any]) -> Tuple[int, Dict[str, Any]]:
        if self.reject_prompt is not None:
            # ComfyUI's own refusal shape.
            return 400, {
                "error": {
                    "type": "prompt_outputs_failed_validation",
                    "message": "Prompt outputs failed validation",
                    "details": self.reject_prompt,
                    "extra_info": {},
                },
                "node_errors": {
                    "40": {
                        "errors": [
                            {
                                "type": "value_not_in_list",
                                "message": "Value not in list",
                                "details": self.reject_prompt,
                                "extra_info": {},
                            }
                        ],
                        "dependent_outputs": [],
                        "class_type": "FakeNode",
                    }
                },
            }

        graph = body.get("prompt")
        if not isinstance(graph, Mapping) or not graph:
            return 400, {
                "error": {
                    "type": "no_prompt",
                    "message": "No prompt provided",
                    "details": "",
                    "extra_info": {},
                },
                "node_errors": {},
            }

        with self._lock:
            self._counter += 1
            prompt_id = "fake-prompt-{}".format(self._counter)
            self._prompts[prompt_id] = _Prompt(
                prompt_id=prompt_id,
                number=self._counter,
                graph=dict(graph),
                client_id=body.get("client_id"),
            )
            self._order.append(prompt_id)
            self.submissions.append(
                {"prompt_id": prompt_id, "prompt": dict(graph), "client_id": body.get("client_id")}
            )
            number = self._counter
        return 200, {"prompt_id": prompt_id, "number": number, "node_errors": {}}

    def _history(self, prompt_id: Optional[str]) -> Any:
        with self._lock:
            if self.malformed_history:
                # Valid JSON, wrong shape: the entry is a string, not an object.
                return {prompt_id or "": "in progress"}
            entries: Dict[str, Any] = {}
            for identifier in self._order:
                prompt = self._prompts[identifier]
                if prompt.place != "done":
                    continue
                if prompt_id is not None and identifier != prompt_id:
                    continue
                entry = {
                    # NOTE(fidelity): ComfyUI stores the submitted prompt as a
                    # positional list, not as the object that was posted.
                    "prompt": [prompt.number, identifier, prompt.graph, {}, []],
                    "outputs": prompt.outputs,
                    "status": prompt.status,
                }
                if self.omit_history_status:
                    entry.pop("status")
                entries[identifier] = entry
            return entries

    def _queue(self) -> Dict[str, Any]:
        with self._lock:
            running = [
                self._queue_entry(self._prompts[identifier])
                for identifier in self._order
                if self._prompts[identifier].place == "running"
            ]
            pending = [
                self._queue_entry(self._prompts[identifier])
                for identifier in self._order
                if self._prompts[identifier].place == "pending"
            ]
        return {"queue_running": running, "queue_pending": pending}

    @staticmethod
    def _queue_entry(prompt: _Prompt) -> List[Any]:
        # [number, prompt_id, prompt, extra_data, outputs_to_execute]
        return [prompt.number, prompt.prompt_id, prompt.graph, {}, []]

    def _object_info(self) -> Tuple[int, Any]:
        with self._lock:
            self.probe_count += 1
            probes = self.probe_count
        if not self.ready or probes <= self.ready_after_probes:
            return 503, {"error": "still loading nodes"}
        document = dict(OBJECT_INFO)
        for name in self.installed_nodes:
            document[name] = {
                "input": {"required": dict(self.node_inputs.get(name, {}))},
                "output": list(self.node_outputs.get(name, [])),
                "name": name,
                "category": "fake",
            }
        return 200, document

    def _upload_image(self, content_type_header: str, raw: bytes) -> Tuple[int, Any]:
        """``POST /upload/image``: store an input file, answer with its name.

        NOTE(fidelity): real ComfyUI does not decode what it is handed here --
        it writes the bytes into its input directory and answers.  That is why
        an uploaded video works through an endpoint named for images, and it is
        the behaviour reproduced below.
        """

        if self.reject_upload is not None:
            return self.reject_upload, {"error": "upload refused"}

        parts = _multipart(content_type_header, raw)
        image = parts.get("image")
        if image is None or not image["data"]:
            return 400, {"error": "no image uploaded"}

        requested_subfolder = _text_part(parts, "subfolder")
        subfolder = (
            requested_subfolder
            if self.upload_subfolder_override is None
            else self.upload_subfolder_override
        )
        type_ = _text_part(parts, "type") or "input"
        requested = image["filename"] or "upload"

        with self._lock:
            # ComfyUI keeps the file that is already there and suffixes the
            # newcomer -- an upload never destroys an existing input file.
            name = requested
            counter = 0
            while (name, subfolder, type_) in self._files:
                counter += 1
                stem, dot, extension = requested.rpartition(".")
                if not dot:
                    stem, extension = requested, ""
                name = "{} ({}){}{}".format(stem, counter, dot, extension)
            self._files[(name, subfolder, type_)] = (
                image["data"],
                image["content_type"] or "application/octet-stream",
            )
            self.uploads.append(
                {
                    "requested_filename": requested,
                    "requested_subfolder": requested_subfolder,
                    "name": name,
                    "subfolder": subfolder,
                    "type": type_,
                    "content_type": image["content_type"],
                    "bytes": len(image["data"]),
                }
            )
        return 200, {"name": name, "subfolder": subfolder, "type": type_}

    def _interrupt(self) -> Tuple[int, Any]:
        """``POST /interrupt``: stop what is executing, if anything is.

        Answers 200 either way, exactly as ComfyUI does -- the request carries
        no prompt id and reports no outcome, which is precisely why the gateway
        has to read ``/history`` afterwards to learn what happened.
        """

        with self._lock:
            running = None
            for identifier in self._order:
                if self._prompts[identifier].place == "running":
                    running = identifier
                    break
            self.interrupts.append(running)
            outcome = self.interrupt_outcome

        if running is not None:
            if outcome == "interrupted":
                self.interrupt_prompt(running)
            elif outcome == "completed":
                # The race `docs/recovery.md` names: the executor finished the
                # last node before it looked at the flag.
                self.complete(running)
            # "ignored": the flag is set and has not been read yet.
        return 200, {}

    def _queue_command(self, body: Mapping[str, Any]) -> Tuple[int, Any]:
        """``POST /queue``: ``{"delete": [...]}`` or ``{"clear": true}``.

        NOTE(fidelity): ComfyUI answers 200 for an id that is not in the queue,
        and for one that is already running -- deletion only ever removes
        *pending* entries.  Both are reproduced, because a gateway that read
        "200" as "cancelled" would be wrong in exactly those two cases.
        """

        with self._lock:
            if body.get("clear"):
                for identifier in self._order:
                    if self._prompts[identifier].place == "pending":
                        self._prompts[identifier].place = "deleted"
            for identifier in body.get("delete") or ():
                if not isinstance(identifier, str):
                    continue
                self.queue_deletes.append(identifier)
                prompt = self._prompts.get(identifier)
                if prompt is not None and prompt.place == "pending":
                    prompt.place = "deleted"
        return 200, {}

    def _view(self, query: Mapping[str, List[str]]) -> Tuple[int, bytes, str]:
        filename = (query.get("filename") or [""])[0]
        subfolder = (query.get("subfolder") or [""])[0]
        type_ = (query.get("type") or ["output"])[0]
        with self._lock:
            self.view_requests.append(
                {"filename": filename, "subfolder": subfolder, "type": type_}
            )
            found = self._files.get((filename, subfolder, type_))
        if found is None:
            return 404, b"", "text/plain"
        return 200, found[0], found[1]


def _multipart(content_type_header: str, raw: bytes) -> Dict[str, Dict[str, Any]]:
    """Split a ``multipart/form-data`` body into its named parts.

    Written against the bytes rather than run through a text parser: the file
    part is a picture or a video, and a parser that decodes it is a parser that
    can corrupt it.  Segments are cut at ``CRLF--boundary``, which is exactly
    what the format defines, so nothing has to be stripped off the payload
    afterwards.
    """

    boundary = ""
    for piece in content_type_header.split(";")[1:]:
        key, _, value = piece.strip().partition("=")
        if key.strip().lower() == "boundary":
            boundary = value.strip().strip('"')
    if not boundary:
        return {}

    delimiter = b"\r\n--" + boundary.encode("ascii")
    parts: Dict[str, Dict[str, Any]] = {}
    for segment in (b"\r\n" + raw).split(delimiter)[1:]:
        if segment.startswith(b"--"):  # the closing boundary
            continue
        if segment.startswith(b"\r\n"):
            segment = segment[2:]
        head, separator, body = segment.partition(b"\r\n\r\n")
        if not separator:
            continue
        name = filename = None
        content_type = None
        for line in head.decode("utf-8", "replace").splitlines():
            field, _, value = line.partition(":")
            field = field.strip().lower()
            if field == "content-disposition":
                name = _parameter(value, "name")
                filename = _parameter(value, "filename")
            elif field == "content-type":
                content_type = value.strip()
        if name is None:
            continue
        parts[name] = {"filename": filename, "data": body, "content_type": content_type}
    return parts


def _parameter(header_value: str, name: str) -> Optional[str]:
    for piece in header_value.split(";")[1:]:
        key, _, value = piece.strip().partition("=")
        if key.strip().lower() == name:
            return value.strip().strip('"')
    return None


def _text_part(parts: Mapping[str, Dict[str, Any]], name: str) -> str:
    part = parts.get(name)
    if part is None:
        return ""
    return part["data"].decode("utf-8", "replace")


#: RFC 6455's magic string.  The handshake is four lines of arithmetic, and
#: doing it here keeps the fake a single self-contained server on one port --
#: which is what ComfyUI is, and the shape the gateway has to work against.
_WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class _FakeWebSocket:
    """One accepted ``/ws`` connection, written to from any thread.

    Only what this fake needs is implemented: unmasked server-to-client text
    frames out, and enough frame parsing to notice the client hanging up.  A
    server frame is never masked and never fragmented here, both of which the
    protocol allows and a real client accepts.
    """

    def __init__(self, connection: Any) -> None:
        self._connection = connection
        self._send_lock = threading.Lock()
        self._closed = False

    def send_text(self, payload: str) -> bool:
        """Write one text frame.  ``False`` means the peer has gone."""

        data = payload.encode("utf-8")
        header = bytearray([0x81])  # FIN + opcode 1 (text)
        length = len(data)
        if length < 126:
            header.append(length)
        elif length < 65536:
            header.append(126)
            header += struct.pack("!H", length)
        else:  # pragma: no cover - no fixture is this large
            header.append(127)
            header += struct.pack("!Q", length)
        with self._send_lock:
            if self._closed:
                return False
            try:
                self._connection.sendall(bytes(header) + data)
            except OSError:
                self._closed = True
                return False
        return True

    def close(self) -> None:
        with self._send_lock:
            self._closed = True

    def serve_until_closed(self) -> None:
        """Read and discard client frames until the peer closes or vanishes.

        The handler thread has to stay in here for the connection to stay open,
        and a real client sends pings and a close frame that would otherwise
        pile up in the receive buffer.
        """

        while not self._closed:
            try:
                if not self._read_frame():
                    return
            except OSError:
                return

    def _read_frame(self) -> bool:
        head = self._read_exactly(2)
        if head is None:
            return False
        opcode = head[0] & 0x0F
        masked = bool(head[1] & 0x80)
        length = head[1] & 0x7F
        if length == 126:
            extended = self._read_exactly(2)
            if extended is None:
                return False
            length = struct.unpack("!H", extended)[0]
        elif length == 127:
            extended = self._read_exactly(8)
            if extended is None:
                return False
            length = struct.unpack("!Q", extended)[0]
        if masked and self._read_exactly(4) is None:
            return False
        if length and self._read_exactly(length) is None:
            return False
        return opcode != 0x8  # 0x8 is close

    def _read_exactly(self, count: int) -> Optional[bytes]:
        chunks = b""
        while len(chunks) < count:
            piece = self._connection.recv(count - len(chunks))
            if not piece:
                return None
            chunks += piece
        return chunks


class _Server(ThreadingHTTPServer):
    """A server that does not shout when a client hangs up.

    The readiness probe deliberately closes ``/object_info`` after reading the
    status line, so an aborted connection is normal traffic here, not an
    incident.  Real ComfyUI logs the same event at debug level.
    """

    daemon_threads = True

    def handle_error(self, request: Any, client_address: Any) -> None:
        import sys

        exc = sys.exc_info()[1]
        if isinstance(exc, (ConnectionError, BrokenPipeError)):
            return
        super().handle_error(request, client_address)


class _Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    @property
    def fake(self) -> FakeComfy:
        return self.server.fake  # type: ignore[attr-defined]

    def log_message(self, *args: Any) -> None:  # noqa: D401 - silence the server
        """A test suite's output is not a web server log."""

    def setup(self) -> None:
        super().setup()
        self.fake._track(self.connection)

    def finish(self) -> None:
        self.fake._untrack(self.connection)
        super().finish()

    def _record(self, method: str, path: str) -> None:
        entry = "{} {}".format(method, path)
        with self.fake._lock:
            self.fake.requests.append(entry)
            hook = self.fake.on_request
        if hook is not None:
            # Outside the lock, and *before* the request is served: this is
            # where a test puts ComfyUI's executor moving while a call is in
            # flight.  A race is only reproducible if something can happen
            # between two of the caller's requests, and this is that something.
            hook(entry)

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler's name
        parsed = urlparse(self.path)
        path = parsed.path
        self._record("GET", path)

        if path == "/ws":
            self._websocket()
        elif path == "/object_info":
            status, payload = self.fake._object_info()
            self._json(status, payload)
        elif path.startswith("/object_info/"):
            status, payload = self.fake._object_info()
            self._json(status, payload)
        elif path == "/queue":
            self._json(200, self.fake._queue())
        elif path == "/history":
            self._json(200, self.fake._history(None))
        elif path.startswith("/history/"):
            self._json(200, self.fake._history(path[len("/history/") :]))
        elif path == "/view":
            status, body, content_type = self.fake._view(parse_qs(parsed.query))
            self._send_view(status, body, content_type)
        elif path == "/system_stats":
            # Present so that a probe *could* have chosen it -- and so a test can
            # show that it answers while /object_info does not (see client.py).
            self._json(
                200,
                {
                    "system": {
                        "os": "fake",
                        "python_version": "fake",
                        "comfyui_version": self.fake.comfyui_version,
                        "required_frontend_version": "fake-frontend",
                    },
                    "devices": [],
                },
            )
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler's name
        parsed = urlparse(self.path)
        self._record("POST", parsed.path)
        length = int(self.headers.get("content-length") or 0)
        raw = self.rfile.read(length) if length else b""
        if parsed.path == "/interrupt":
            status, payload = self.fake._interrupt()
            self._json(status, payload)
            return
        if parsed.path == "/queue":
            try:
                body = json.loads(raw.decode("utf-8")) if raw else {}
            except ValueError:
                body = {}
            status, payload = self.fake._queue_command(
                body if isinstance(body, dict) else {}
            )
            self._json(status, payload)
            return
        if parsed.path == "/upload/image":
            status, payload = self.fake._upload_image(
                self.headers.get("content-type") or "", raw
            )
            self._json(status, payload)
            return
        if parsed.path != "/prompt":
            self._json(404, {"error": "not found"})
            return
        try:
            body = json.loads(raw.decode("utf-8")) if raw else {}
        except ValueError:
            self._json(400, {"error": {"type": "invalid_json", "message": "Bad JSON"}})
            return
        if not isinstance(body, dict):
            self._json(400, {"error": {"type": "invalid_json", "message": "Bad JSON"}})
            return
        status, payload = self.fake._submit(body)
        self._json(status, payload)

    def _websocket(self) -> None:
        """Complete RFC 6455's handshake and hold the connection open."""

        key = self.headers.get("sec-websocket-key")
        if not key:
            self._json(400, {"error": "not a websocket handshake"})
            return
        accept = base64.b64encode(
            hashlib.sha1((key + _WS_GUID).encode("ascii")).digest()
        ).decode("ascii")
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()

        connection = _FakeWebSocket(self.connection)
        self.fake._socket_opened_now(connection)
        # NOTE(fidelity): ComfyUI's first frame is a status message carrying the
        # session id it assigned.  The gateway ignores it; it is here so that a
        # client which does read it is not surprised by its absence.
        connection.send_text(
            json.dumps(
                {
                    "type": "status",
                    "data": {
                        "status": {"exec_info": {"queue_remaining": 0}},
                        "sid": "fake-session",
                    },
                }
            )
        )
        try:
            connection.serve_until_closed()
        finally:
            self.fake._socket_closed(connection)
        self.close_connection = True

    # -- writing -----------------------------------------------------------

    def _json(self, status: int, payload: Any) -> None:
        self._send(status, json.dumps(payload).encode("utf-8"), "application/json")

    def _send_view(self, status: int, body: bytes, content_type: str) -> None:
        """``/view``, optionally written in more than one piece.

        A real backend sends a large file across many writes, and a gateway
        that buffers cannot be told from one that streams while the whole body
        arrives in a single packet.  ``view_chunk_bytes`` makes the response
        arrive in pieces, and ``view_gate`` holds it between the first and the
        rest -- so a test can ask whether the first bytes reached the client
        before the backend had sent the last, which is the whole question.
        """

        chunk = self.fake.view_chunk_bytes
        gate = self.fake.view_gate
        if status != 200 or not chunk or not body:
            self._send(status, body, content_type)
            return

        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        for start in range(0, len(body), chunk):
            if start and gate is not None:
                # Waited for once, not before every chunk: the point is to hold
                # the tail back, and a bounded wait keeps a forgotten gate from
                # wedging the suite.
                gate.wait(timeout=30)
                gate = None
            self.wfile.write(body[start : start + chunk])
            self.wfile.flush()

    def _send(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)


__all__ = ["FakeComfy", "ONE_PIXEL_PNG", "OBJECT_INFO"]
