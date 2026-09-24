"""ComfyUI's real HTTP protocol, and nothing invented on top of it.

The four calls the gateway makes, exactly as ComfyUI serves them:

``POST /prompt``
    Body ``{"prompt": <API-format graph>, "client_id": "<id>"}``.  On success
    ComfyUI answers ``{"prompt_id": ..., "number": ..., "node_errors": {}}``.
    On a graph it refuses it answers **400** with ``{"error": {...},
    "node_errors": {...}}``.

``GET /history/{prompt_id}``
    ``{}`` while the prompt has not finished, otherwise an object keyed by the
    prompt id holding ``prompt``, ``outputs`` and ``status``.

``GET /queue``
    ``{"queue_running": [...], "queue_pending": [...]}``, each entry a list
    whose second element is the prompt id.

``POST /queue``
    ``{"delete": ["<prompt_id>"]}`` removes a prompt that has **not started**.
    This is the only way to cancel a queued job: ``/interrupt`` stops the
    prompt that is executing and does nothing to one still waiting in line.

``POST /interrupt``
    Stops the prompt ComfyUI is executing **right now**.  It names no prompt,
    which is why this gateway sends it only after ``/queue`` has said that the
    running slot holds its own prompt -- otherwise the request would stop
    somebody else's generation.

    An interrupt is a *request*, not an outcome.  ComfyUI checks the flag
    between nodes, so a prompt that finished its last node first completes
    normally and is recorded as a success.  What actually happened is read back
    from ``/history`` afterwards, never assumed (`docs/recovery.md`).

``GET /view?filename=&subfolder=&type=``
    The output bytes.  This is the **only** way the gateway reads a ComfyUI
    output: it never goes to ComfyUI's filesystem itself
    (`docs/architecture.md`).  Read as a **stream**: see
    :meth:`ComfyClient.open_view`.

``POST /upload/image``
    Multipart, field ``image``, plus ``subfolder``, ``type`` and ``overwrite``.
    ComfyUI stores the file in its own input directory and answers
    ``{"name", "subfolder", "type"}`` -- the name it *actually* used, which is
    not necessarily the one that was sent, because ComfyUI renames rather than
    clobbers an existing file.  This is how an uploaded image or video gets to
    where a loader node can read it **without this gateway knowing where that
    is**: no input path is configured, composed or searched for
    (`docs/architecture.md`).

    NOTE(fidelity): the endpoint is named for images and is what ComfyUI's own
    web client uses for every uploaded input file, video included -- it stores
    what it is given and does not decode it.  The gateway sends video the same
    way for that reason.  Whether a given format can then be *loaded* is the
    workflow's business, and a node that cannot read it fails at submission
    with ComfyUI's own message rather than being second-guessed here.

Why results are streamed
------------------------
An output was once read whole into memory under the same ten-second read budget
as a metadata call.  That is comfortable for a PNG and wrong for a video twice
the size of the process: it holds the whole file in RAM to hand it straight back
out, and it gives a disk read sized for a few kilobytes the patience of one.
:meth:`open_view` keeps the response open and hands the caller an iterator, so
the bytes pass through the gateway a chunk at a time and never accumulate, and
:data:`RESULT_TIMEOUT` gives the read a budget a video-sized output can meet.

Why the readiness probe is ``/object_info``
-------------------------------------------
An open socket proves that *something* bound the port, which is not the
question.  ``/system_stats`` proves the process is alive, which is closer and
still not it.  ``/object_info`` can only answer once ComfyUI has imported every
node -- core and custom -- and built the object catalogue, and that catalogue is
precisely what ``POST /prompt`` validates a submitted graph against.  So
``/object_info`` answering ``200`` is the cheapest available proof that a prompt
submitted *now* would be understood, which is what "ready" has to mean if the
word is to be worth anything.

**That proof is not cheap, and pretending otherwise would be wrong.**  On a real
installation ComfyUI builds the ``/object_info`` answer on every request: it
walks every registered node class, calls each one's ``INPUT_TYPES()`` -- which
for loader nodes enumerates model directories on disk -- and serialises the
whole catalogue before the first byte leaves the server.  Aborting the read
saves this gateway the download; it saves ComfyUI nothing.  ``docs/api.md``
nevertheless calls ``GET /api/v1/info`` safe to poll, and ``docs/connection.md``
puts it at the end of every connection path, so the two are reconciled by
:data:`READY_TTL_SECONDS`: a **ready** answer is reused for a second or two
instead of being asked for again.

Only ``ready`` is cached.  ``starting`` and ``unavailable`` are answers the user
is waiting to see change, and caching those would put a delay exactly where
`docs/recovery.md` wants none.

Mapping ComfyUI's reality onto the three health values:

* nothing accepted the connection -> ``unavailable``.  Refused, unresolvable or
  a timeout while connecting: ComfyUI has not bound the port yet, or is not
  there at all.
* the connection was accepted but ``/object_info`` did not answer ``200`` (any
  other status, or a read timeout) -> ``starting``.  Something is on the port
  and is not usable yet.  A foreign service on the port lands here too, which
  is why the detail says what was actually seen rather than asserting a cause.

  NOTE(fidelity): real ComfyUI loads its nodes *before* binding the port, so a
  probe during its startup is usually refused outright and lands in
  ``unavailable`` above -- this branch is what catches a reverse proxy, a
  half-initialised build, or a stranger on the port, and it is proven against
  the fake rather than against an observed ComfyUI.  The mapping is still the
  right one: "answered, but not usably" is not "not there".
* ``200`` -> ``ready``.

Fidelity notes are marked ``NOTE(fidelity)`` where ComfyUI's behaviour is known
to vary between versions.  They are written down rather than smoothed over.
"""

from __future__ import annotations

import mimetypes
import threading
import time
import uuid
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Any, Callable, Iterable, Iterator, List, Mapping, Optional, Tuple

import httpx


class ComfyStatus(str, Enum):
    """The three values ``comfy.status`` may take (`docs/api.md`)."""

    READY = "ready"
    STARTING = "starting"
    UNAVAILABLE = "unavailable"


@dataclass(frozen=True)
class ComfyHealth:
    """What the readiness probe found.

    Two strings, and the split between them matters.  ``detail`` is the short
    human sentence `docs/api.md` puts in ``comfy.detail`` -- it names no URL,
    because ComfyUI's endpoint is a localhost address the phone cannot reach
    and has no business learning (`docs/architecture.md`).  ``log_detail``
    carries the endpoint and the underlying reason, and goes to the PC's log,
    where the person who can act on it is sitting.
    """

    status: ComfyStatus
    detail: Optional[str] = None
    log_detail: Optional[str] = None

    @property
    def is_ready(self) -> bool:
        return self.status is ComfyStatus.READY


class ComfyError(Exception):
    """ComfyUI could not be reached, or answered something unusable."""


class ComfySubmitRejected(ComfyError):
    """ComfyUI refused the submitted graph.

    Carries ComfyUI's own words for the log.  What reaches the app is a
    human sentence built by the caller, never this text.
    """

    def __init__(self, message: str, node_errors: Optional[Mapping[str, Any]] = None) -> None:
        super().__init__(message)
        self.node_errors = dict(node_errors or {})


class QueuePlace(str, Enum):
    """Where a prompt sits in ComfyUI's queue right now."""

    RUNNING = "running"
    PENDING = "pending"
    ABSENT = "absent"


@dataclass(frozen=True)
class OutputFile:
    """One file ComfyUI produced, as ``/history`` names it."""

    filename: str
    subfolder: str
    type: str
    kind: str  # "image" | "video"

    @property
    def media_type(self) -> str:
        guessed, _ = mimetypes.guess_type(self.filename)
        if guessed:
            return guessed
        return "image/png" if self.kind == "image" else "application/octet-stream"


@dataclass(frozen=True)
class ExecutionError:
    """What ComfyUI said went wrong, in its own words.

    **This is log material.**  Every field here is ComfyUI's vocabulary --
    exception text that routinely carries a model path, the class name of the
    node that raised, its id.  None of it is fit to cross to the phone as-is
    (`docs/api.md`, "What may cross from ComfyUI"), and turning it into
    something that is happens in :mod:`localcanvas_gateway.jobs`.

    The node type and id are kept precisely *because* they must not cross: they
    are what lets the gateway remove ComfyUI's node vocabulary from the message
    by name rather than by guesswork.
    """

    message: Optional[str] = None
    exception_type: Optional[str] = None
    node_id: Optional[str] = None
    node_type: Optional[str] = None

    def for_log(self) -> str:
        parts = [
            "{}={}".format(name, value)
            for name, value in (
                ("node", self.node_id),
                ("class", self.node_type),
                ("exception", self.exception_type),
                ("message", self.message),
            )
            if value
        ]
        return ", ".join(parts) or "no detail reported"


@dataclass(frozen=True)
class HistoryEntry:
    """One prompt's entry in ``/history``, normalized.

    ``found`` is false when ComfyUI returned ``{}`` -- the prompt has not
    finished, or ComfyUI has forgotten it.  Those two are indistinguishable over
    this endpoint, so this object does not pretend to tell them apart; the
    queue does that.
    """

    found: bool
    finished: bool = False
    failed: bool = False
    #: ComfyUI recorded this prompt as stopped by an interrupt.  It writes that
    #: as ``status_str == "error"`` with an ``execution_interrupted`` message
    #: and no ``execution_error`` one, so it looks like a failure over the wire
    #: and is not one: a cancelled generation is not a broken workflow, and the
    #: two must not reach the phone as the same thing (`docs/recovery.md`).
    interrupted: bool = False
    error: Optional[ExecutionError] = None
    outputs: Tuple[OutputFile, ...] = ()


#: How long a call is given before it is treated as a failure.  Generation can
#: take minutes; none of *these* calls does -- they are all metadata.
DEFAULT_TIMEOUT = httpx.Timeout(connect=2.0, read=10.0, write=10.0, pool=5.0)
#: The probe is polled, so it is given less patience than a real call.
PROBE_TIMEOUT = httpx.Timeout(connect=1.5, read=5.0, write=5.0, pool=5.0)

#: ``/view`` is not a metadata call.  The read budget applies to each chunk, and
#: the first one is the one that waits: ComfyUI has to open a file that may be
#: hundreds of megabytes, possibly still being flushed by the node that wrote
#: it.  A minute is patience for a video-sized output; ten seconds was patience
#: for a thumbnail.
RESULT_TIMEOUT = httpx.Timeout(connect=2.0, read=60.0, write=10.0, pool=5.0)

#: Sending a phone's video to ComfyUI is a local write of a large file, so the
#: write budget is the one that matters here.
UPLOAD_TIMEOUT = httpx.Timeout(connect=2.0, read=60.0, write=120.0, pool=5.0)

#: How much of a result is moved at a time.  Big enough that a large file is not
#: ten thousand iterations, small enough that it is never the file itself.
RESULT_CHUNK_BYTES = 64 * 1024

#: How long a ``ready`` answer stands before ComfyUI is asked again.  Short
#: enough that the app notices ComfyUI going away within a poll or two, long
#: enough that a burst of ``/info`` calls does not rebuild the node catalogue
#: once per call.  See the module docstring.
READY_TTL_SECONDS = 2.0

#: What ``/view`` is allowed to dictate.  ComfyUI is a local process the gateway
#: trusts to produce pictures, not to choose what the phone renders: a header it
#: sends is used only when it names a medium this API serves, and otherwise the
#: filename decides.  A Content-Type is an instruction to a browser, so it is
#: the one part of a ComfyUI response that is checked rather than echoed.
_SERVEABLE_MEDIA_PREFIXES = ("image/", "video/")

#: ``comfy.detail`` as the app shows it: one short sentence, no endpoint, no
#: exception text.  `docs/recovery.md` requires "ComfyUI is down" to read
#: differently from "the gateway is unreachable", and these are those words.
_UNAVAILABLE_DETAIL = "ComfyUI is not running."
_STARTING_DETAIL = "ComfyUI is still starting up."


@dataclass(frozen=True)
class UploadedInput:
    """Where ComfyUI put a file the gateway handed it.

    Every field is ComfyUI's own answer.  Nothing here is composed by the
    gateway, which is the point: the input directory's location is unknown to
    this process and stays that way.
    """

    name: str
    subfolder: str = ""
    type: str = "input"

    @property
    def reference(self) -> str:
        """What a loader input takes to mean this file.

        ComfyUI addresses an input file by name, prefixed with its subfolder
        when it is in one -- the same string its own web client puts in a
        ``LoadImage`` widget.  It is a reference on ComfyUI's HTTP surface, not
        a filesystem path: **both halves came back from ``/upload/image``**,
        and no root is supplied here.  The ``/`` is this method's, and it is
        ComfyUI's own convention for joining the two, not a path separator
        chosen by the gateway -- it stays ``/`` on Windows for exactly that
        reason.
        """

        if self.subfolder:
            return "{}/{}".format(self.subfolder, self.name)
        return self.name


class ResultStream:
    """One open ``/view`` response, read a chunk at a time.

    The response stays open until :meth:`chunks` is exhausted or :meth:`close`
    is called, so the caller decides when the transfer ends.  It is never read
    whole: that is what this class exists to prevent.
    """

    def __init__(
        self,
        response: httpx.Response,
        media_type: str,
        content_length: Optional[int],
    ) -> None:
        self.media_type = media_type
        self.content_length = content_length
        self._response = response

    def chunks(self, size: int = RESULT_CHUNK_BYTES) -> Iterator[bytes]:
        try:
            for chunk in self._response.iter_bytes(size):
                yield chunk
        finally:
            self._response.close()

    def close(self) -> None:
        self._response.close()

    def __enter__(self) -> "ResultStream":
        return self

    def __exit__(self, *exc_info: Any) -> None:
        self.close()




class ComfyClient:
    """A thin, synchronous client for one ComfyUI instance."""

    def __init__(
        self,
        base_url: str,
        *,
        client_id: Optional[str] = None,
        timeout: httpx.Timeout = DEFAULT_TIMEOUT,
        probe_timeout: httpx.Timeout = PROBE_TIMEOUT,
        ready_ttl_seconds: float = READY_TTL_SECONDS,
        clock: Callable[[], float] = time.monotonic,
        client: Optional[httpx.Client] = None,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        # ComfyUI uses client_id to address WebSocket messages back at the
        # submitter.  One per gateway process is what a single consumer is.
        self.client_id = client_id or uuid.uuid4().hex
        self._probe_timeout = probe_timeout
        self._ready_ttl = ready_ttl_seconds
        # Monotonic, not wall-clock: a clock the user adjusts must not make a
        # cached "ready" outlive its welcome, or expire it early.
        self._clock = clock
        # One client is shared by every request, and FastAPI runs the sync
        # routes on a threadpool, so this is shared mutable state read and
        # written from several threads at once -- guarded like the job store
        # next door rather than left to chance.
        self._ready_lock = threading.Lock()
        self._ready_until: Optional[float] = None
        self._owns_client = client is None
        self._client = client or httpx.Client(base_url=self.base_url, timeout=timeout)

    def close(self) -> None:
        if self._owns_client:
            self._client.close()

    def __enter__(self) -> "ComfyClient":
        return self

    def __exit__(self, *exc_info: Any) -> None:
        self.close()

    # -- readiness ---------------------------------------------------------

    def health(self) -> ComfyHealth:
        """Probe ``/object_info``, reusing a recent ``ready`` answer.

        Producing that answer costs ComfyUI real work (see the module
        docstring), so a ``ready`` result stands for
        :data:`READY_TTL_SECONDS`.  Nothing else is cached.
        """

        with self._ready_lock:
            if self._ready_until is not None and self._clock() < self._ready_until:
                return ComfyHealth(ComfyStatus.READY, None, None)

        # Probed outside the lock: holding it across a network call would queue
        # every /info behind one slow probe, which is the opposite of the point.
        # Two threads arriving together may both probe once; that costs one
        # extra request and cannot produce a wrong answer.
        health = self._probe()

        with self._ready_lock:
            self._ready_until = (
                self._clock() + self._ready_ttl if health.is_ready else None
            )
        return health

    def _probe(self) -> ComfyHealth:
        try:
            with self._client.stream(
                "GET", "/object_info", timeout=self._probe_timeout
            ) as response:
                status = response.status_code
        except httpx.ConnectError as exc:
            return ComfyHealth(
                ComfyStatus.UNAVAILABLE,
                _UNAVAILABLE_DETAIL,
                "nothing is listening at {} ({})".format(self.base_url, _reason(exc)),
            )
        except httpx.ConnectTimeout:
            return ComfyHealth(
                ComfyStatus.UNAVAILABLE,
                _UNAVAILABLE_DETAIL,
                "{} did not accept a connection in time".format(self.base_url),
            )
        except httpx.TimeoutException:
            # The connection was accepted; the answer did not come.  Something
            # is on the port and busy -- which is what "starting" describes.
            return ComfyHealth(
                ComfyStatus.STARTING,
                _STARTING_DETAIL,
                "{} accepted the connection but did not answer /object_info in time".format(
                    self.base_url
                ),
            )
        except httpx.HTTPError as exc:
            return ComfyHealth(
                ComfyStatus.UNAVAILABLE,
                _UNAVAILABLE_DETAIL,
                "{} could not be reached ({})".format(self.base_url, _reason(exc)),
            )

        if status == 200:
            return ComfyHealth(ComfyStatus.READY, None, None)
        return ComfyHealth(
            ComfyStatus.STARTING,
            _STARTING_DETAIL,
            "{} answered /object_info with HTTP {}; it is still loading, or another "
            "service holds this port".format(self.base_url, status),
        )

    # -- submission --------------------------------------------------------

    def submit(self, prompt: Mapping[str, Any]) -> str:
        """``POST /prompt``.  Returns ComfyUI's ``prompt_id``."""

        try:
            response = self._client.post(
                "/prompt", json={"prompt": prompt, "client_id": self.client_id}
            )
        except httpx.HTTPError as exc:
            raise ComfyError(
                "ComfyUI could not be reached at {} ({}).".format(self.base_url, _reason(exc))
            ) from exc

        if response.status_code >= 400:
            raise ComfySubmitRejected(*_rejection(response))

        payload = _json(response, "/prompt")
        prompt_id = payload.get("prompt_id")
        if not isinstance(prompt_id, str) or not prompt_id:
            raise ComfyError(
                "ComfyUI accepted the prompt but returned no prompt_id: {!r}".format(payload)
            )
        return prompt_id

    # -- tracking ----------------------------------------------------------

    def history(self, prompt_id: str) -> HistoryEntry:
        """``GET /history/{prompt_id}``, normalized into :class:`HistoryEntry`."""

        try:
            response = self._client.get("/history/{}".format(prompt_id))
        except httpx.HTTPError as exc:
            raise ComfyError(
                "ComfyUI could not be reached at {} ({}).".format(self.base_url, _reason(exc))
            ) from exc
        if response.status_code >= 400:
            raise ComfyError(
                "ComfyUI answered HTTP {} for the history of prompt {}.".format(
                    response.status_code, prompt_id
                )
            )

        payload = _json(response, "/history")
        entry = payload.get(prompt_id)
        if entry is None:
            return HistoryEntry(found=False)
        if not isinstance(entry, Mapping):
            raise ComfyError(
                "ComfyUI returned a history entry that is not an object for prompt {}.".format(
                    prompt_id
                )
            )
        return _history_entry(entry)

    def queue_place(self, prompt_id: str) -> QueuePlace:
        """Where ``prompt_id`` sits in ``GET /queue`` right now."""

        try:
            response = self._client.get("/queue")
        except httpx.HTTPError as exc:
            raise ComfyError(
                "ComfyUI could not be reached at {} ({}).".format(self.base_url, _reason(exc))
            ) from exc
        if response.status_code >= 400:
            raise ComfyError("ComfyUI answered HTTP {} for /queue.".format(response.status_code))

        payload = _json(response, "/queue")
        if _in_queue(payload.get("queue_running"), prompt_id):
            return QueuePlace.RUNNING
        if _in_queue(payload.get("queue_pending"), prompt_id):
            return QueuePlace.PENDING
        return QueuePlace.ABSENT

    # -- stopping ----------------------------------------------------------

    def delete_queued(self, prompt_id: str) -> None:
        """``POST /queue`` with ``{"delete": [prompt_id]}``.

        The only way to stop a prompt that has not started: ``/interrupt``
        stops what is executing and a waiting prompt is not.  ComfyUI answers
        200 whether or not the id was there, so a caller learns what happened
        by reading ``/queue`` again -- which is what this gateway does rather
        than treat "the request succeeded" as "the job is cancelled".
        """

        self._post_nothing("/queue", {"delete": [prompt_id]})

    def interrupt(self) -> None:
        """``POST /interrupt``: stop the prompt ComfyUI is executing.

        It takes no prompt id, so it stops **whatever is running**.  The caller
        is responsible for having established that the running prompt is its
        own; this client does not check, because the check needs ``/queue`` and
        the decision belongs with the job (`jobs.py`).
        """

        self._post_nothing("/interrupt", {})

    def _post_nothing(self, path: str, body: Mapping[str, Any]) -> None:
        try:
            response = self._client.post(path, json=dict(body))
        except httpx.HTTPError as exc:
            raise ComfyError(
                "ComfyUI could not be reached at {} ({}).".format(self.base_url, _reason(exc))
            ) from exc
        if response.status_code >= 400:
            raise ComfyError(
                "ComfyUI answered HTTP {} for {}.".format(response.status_code, path)
            )

    # -- events ------------------------------------------------------------

    @property
    def events_url(self) -> str:
        """ComfyUI's own event socket, addressed to this gateway's client id.

        ComfyUI serves it beside its HTTP API and delivers each prompt's
        execution messages to the ``clientId`` that submitted it -- the same id
        :meth:`submit` sends.  Derived from ``base_url`` by scheme, never
        hardcoded to ``ws://``: `docs/transport-boundary.md` §2 is a rule about
        the app's endpoint and the same reasoning holds here, one layer down.
        """

        scheme, separator, rest = self.base_url.partition("://")
        if not separator:  # pragma: no cover - base_url always carries one
            return "ws://{}/ws?clientId={}".format(self.base_url, self.client_id)
        return "{}://{}/ws?clientId={}".format(
            "wss" if scheme.lower() == "https" else "ws", rest, self.client_id
        )

    # -- results -----------------------------------------------------------

    def open_view(self, output: OutputFile) -> ResultStream:
        """``GET /view``, opened but not read.

        Returns as soon as the headers are in, with the body still on the wire.
        The caller pulls it through :meth:`ResultStream.chunks`, so a result of
        any size crosses the gateway without ever being held in it -- which is
        the difference between serving a picture and serving a video.
        """

        params = {
            "filename": output.filename,
            "subfolder": output.subfolder,
            "type": output.type,
        }
        request = self._client.build_request(
            "GET", "/view", params=params, timeout=RESULT_TIMEOUT
        )
        try:
            response = self._client.send(request, stream=True)
        except httpx.HTTPError as exc:
            raise ComfyError(
                "ComfyUI could not be reached at {} ({}).".format(self.base_url, _reason(exc))
            ) from exc

        if response.status_code >= 400:
            response.close()
            raise ComfyError(
                "ComfyUI answered HTTP {} for output file {!r}.".format(
                    response.status_code, output.filename
                )
            )

        # NOTE(fidelity): ComfyUI sets a Content-Type on /view, but has served
        # a generic one for formats it does not recognize.  Rather than echo
        # whatever arrives, the header is accepted only when it names a medium
        # this API serves; anything else -- octet-stream, text/html, a type a
        # custom node invented -- falls back to what the filename says.
        header = (response.headers.get("content-type") or "").split(";")[0].strip().lower()
        if not header.startswith(_SERVEABLE_MEDIA_PREFIXES):
            header = output.media_type
        return ResultStream(response, header, _content_length(response))

    # -- input files -------------------------------------------------------

    def upload_input(
        self, *, path: Path, filename: str, content_type: str, subfolder: str = ""
    ) -> UploadedInput:
        """``POST /upload/image``.  Returns where ComfyUI put the file.

        The file is streamed from disk by ``httpx``: a phone's video is never
        loaded into this process to be sent on.

        ``subfolder`` is a **request**, not a location.  It is a bare name
        handed to ComfyUI, which decides where its input directory is and
        answers with the subfolder it actually used; this client composes no
        path and knows no root.  Who asks for which name, and why, is the media
        store's business (`media.py`, ``COMFY_INPUT_SUBFOLDER``).

        ``overwrite`` is deliberately not sent.  ComfyUI's default is to keep
        an existing file and store the new one under a suffixed name, and the
        answer says which -- so an upload can never destroy a file already in
        the user's input directory, and the gateway learns the real name rather
        than assuming the one it asked for.
        """

        try:
            with open(path, "rb") as handle:
                response = self._client.post(
                    "/upload/image",
                    files={"image": (filename, handle, content_type)},
                    data={"type": "input", "subfolder": subfolder},
                    timeout=UPLOAD_TIMEOUT,
                )
        except OSError as exc:
            raise ComfyError(
                "the uploaded file could not be read back ({}).".format(_reason(exc))
            ) from exc
        except httpx.HTTPError as exc:
            raise ComfyError(
                "ComfyUI could not be reached at {} ({}).".format(self.base_url, _reason(exc))
            ) from exc

        if response.status_code >= 400:
            raise ComfyError(
                "ComfyUI answered HTTP {} to an input upload: {}".format(
                    response.status_code, response.text[:500] or "no detail"
                )
            )

        payload = _json(response, "/upload/image")
        name = payload.get("name")
        if not isinstance(name, str) or not name:
            raise ComfyError(
                "ComfyUI accepted an input upload but named no file: {!r}".format(payload)
            )
        return UploadedInput(
            name=name,
            subfolder=str(payload.get("subfolder") or ""),
            type=str(payload.get("type") or "input"),
        )


# --------------------------------------------------------------------------
# Response shaping
# --------------------------------------------------------------------------


def _json(response: httpx.Response, what: str) -> Mapping[str, Any]:
    try:
        payload = response.json()
    except ValueError as exc:
        raise ComfyError("ComfyUI returned a non-JSON body from {}.".format(what)) from exc
    if not isinstance(payload, Mapping):
        raise ComfyError(
            "ComfyUI returned {} from {}, expected an object.".format(
                type(payload).__name__, what
            )
        )
    return payload


def _rejection(response: httpx.Response) -> Tuple[str, Mapping[str, Any]]:
    """ComfyUI's own words for why it refused a prompt, for the local log."""

    try:
        payload = response.json()
    except ValueError:
        payload = None
    if isinstance(payload, Mapping):
        error = payload.get("error")
        node_errors = payload.get("node_errors")
        message = None
        if isinstance(error, Mapping):
            parts = [
                str(error[key])
                for key in ("message", "details")
                if error.get(key) not in (None, "")
            ]
            message = ": ".join(parts) if parts else None
        elif isinstance(error, str):
            message = error
        if message:
            return (
                "ComfyUI rejected the prompt (HTTP {}): {}".format(
                    response.status_code, message
                ),
                node_errors if isinstance(node_errors, Mapping) else {},
            )
    return (
        "ComfyUI rejected the prompt (HTTP {}): {}".format(
            response.status_code, response.text[:500] or "no detail"
        ),
        {},
    )


def _in_queue(entries: Any, prompt_id: str) -> bool:
    """``/queue`` entries are lists whose second element is the prompt id."""

    if not isinstance(entries, Iterable) or isinstance(entries, (str, bytes, Mapping)):
        return False
    for entry in entries:
        if isinstance(entry, (list, tuple)) and len(entry) >= 2 and entry[1] == prompt_id:
            return True
    return False


#: ``outputs`` groups files by the key the producing node used.  ``images`` is
#: core ComfyUI.
#: NOTE(fidelity): ``gifs`` is what several widely used video/animation nodes
#: emit (the key predates video support and is used for mp4 and webm too), and
#: ``videos`` appears in newer ones.  Both are accepted; a key not in this map
#: is ignored rather than guessed at, so an unrecognized output shows up as
#: "no results" instead of as a broken download.
_OUTPUT_KINDS = {"images": "image", "gifs": "video", "videos": "video"}


def _history_entry(entry: Mapping[str, Any]) -> HistoryEntry:
    status = entry.get("status")
    finished = False
    failed = False
    error: Optional[ExecutionError] = None

    # NOTE(fidelity): the ``status`` block is present in current ComfyUI and
    # absent in older builds.  When it is missing, the presence of ``outputs``
    # is the only evidence there is, and it is treated as success -- ComfyUI
    # only writes a history entry with outputs for a prompt that ran.
    interrupted = False
    if isinstance(status, Mapping):
        status_str = status.get("status_str")
        messages = status.get("messages")
        # ComfyUI records an interrupt as an *error* -- ``status_str`` is
        # ``"error"`` and the only thing telling the two apart is which message
        # it wrote.  Read that first, because everything below branches on
        # ``failed`` and an interrupted prompt is not a failed one.
        interrupted = status_str == "error" and _has_message(
            messages, "execution_interrupted"
        )
        failed = status_str == "error" and not interrupted
        finished = not failed and not interrupted and (
            bool(status.get("completed")) or status_str == "success"
        )
        if failed:
            error = _execution_error(messages)
    else:
        finished = "outputs" in entry

    outputs = _outputs(entry.get("outputs"))
    return HistoryEntry(
        found=True,
        finished=finished,
        failed=failed,
        interrupted=interrupted,
        error=error,
        outputs=outputs,
    )


def _has_message(messages: Any, name: str) -> bool:
    """Is ``name`` one of the ``[event, payload]`` pairs in ``status.messages``?"""

    if not isinstance(messages, list):
        return False
    return any(
        isinstance(message, (list, tuple)) and message and message[0] == name
        for message in messages
    )


def _execution_error(messages: Any) -> Optional[ExecutionError]:
    """``status.messages`` is a list of ``[event_name, payload]`` pairs.

    The ``execution_error`` payload carries the node's id and class alongside
    the exception.  Both are kept: they are what lets the message be stripped
    of ComfyUI's node vocabulary by name, downstream.  ``traceback`` is
    deliberately not read -- there is nowhere it belongs.
    """

    if not isinstance(messages, list):
        return None
    for message in messages:
        if not (isinstance(message, (list, tuple)) and len(message) >= 2):
            continue
        name, payload = message[0], message[1]
        if name != "execution_error" or not isinstance(payload, Mapping):
            continue
        return ExecutionError(
            message=_text_or_none(payload.get("exception_message")),
            exception_type=_text_or_none(payload.get("exception_type")),
            node_id=_text_or_none(payload.get("node_id")),
            node_type=_text_or_none(payload.get("node_type")),
        )
    return None


def _text_or_none(value: Any) -> Optional[str]:
    if isinstance(value, str) and value.strip():
        return value
    if isinstance(value, int) and not isinstance(value, bool):
        return str(value)  # ComfyUI has written node_id as a number
    return None


def _outputs(raw: Any) -> Tuple[OutputFile, ...]:
    if not isinstance(raw, Mapping):
        return ()
    files: List[OutputFile] = []
    # Node keys are ComfyUI node ids.  They are read here and go no further:
    # nothing downstream of this function ever sees one (`docs/api.md`).
    for node_output in raw.values():
        if not isinstance(node_output, Mapping):
            continue
        for key, kind in _OUTPUT_KINDS.items():
            for item in node_output.get(key) or ():
                if not isinstance(item, Mapping):
                    continue
                filename = item.get("filename")
                if not isinstance(filename, str) or not filename:
                    continue
                files.append(
                    OutputFile(
                        filename=filename,
                        subfolder=str(item.get("subfolder") or ""),
                        type=str(item.get("type") or "output"),
                        kind=kind,
                    )
                )
    return tuple(files)


def _content_length(response: httpx.Response) -> Optional[int]:
    """ComfyUI's own ``Content-Length``, when it sent a usable one.

    Passed on so the app can show a real download progress bar for a large
    result.  It is not invented: no header, or one that is not a number, means
    the app is told nothing rather than told a guess.
    """

    raw = response.headers.get("content-length")
    if raw is None:
        return None
    try:
        value = int(raw)
    except ValueError:
        return None
    return value if value >= 0 else None


def _reason(exc: Exception) -> str:
    text = str(exc).strip()
    return text or type(exc).__name__


__all__ = [
    "ComfyClient",
    "ComfyError",
    "ComfyHealth",
    "ComfyStatus",
    "ComfySubmitRejected",
    "DEFAULT_TIMEOUT",
    "ExecutionError",
    "HistoryEntry",
    "OutputFile",
    "PROBE_TIMEOUT",
    "READY_TTL_SECONDS",
    "RESULT_CHUNK_BYTES",
    "RESULT_TIMEOUT",
    "QueuePlace",
    "ResultStream",
    "UPLOAD_TIMEOUT",
    "UploadedInput",
]
