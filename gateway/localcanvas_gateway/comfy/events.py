"""ComfyUI's event socket, consumed for the one thing only it can say.

`docs/api.md` allows ``progress`` in a snapshot **only when ComfyUI reports
real progress**, and ComfyUI reports it on its own WebSocket -- there is no
HTTP endpoint carrying it.  T-0003 therefore left the field honestly ``null``.
This module is what fills it, and it takes from that socket exactly two things:

* the ``value``/``max`` pair of a ``progress`` message, which is a real step
  count produced by the node that is sampling.  Nothing here derives a
  percentage from elapsed time, from a queue position, or from anything else:
  a number that was not reported is not reported on;
* a **nudge** -- "this prompt just changed" -- which makes the job store go and
  re-read ``/history`` and ``/queue``.  The state that reaches the app is still
  the one those two HTTP endpoints stated, exactly as it was before this
  module existed.

That split is deliberate.  ComfyUI's ``execution_error`` message carries the
same exception text as ``/history``, and building a second failure path out of
it would mean a second place where a model path could cross to the phone.
There is one scrubber (`jobs.py`), on one path, and this module does not become
a way around it.

**Nothing here is required for correctness.**  The socket may be absent, refuse
connections, or drop mid-generation; a gateway that never connects still serves
every documented endpoint, still reports every state transition, and reports
``progress`` as ``null`` -- which is what the contract says an absence of real
progress looks like.  The failures are logged locally and reconnection is a
plain, bounded retry loop.
"""

from __future__ import annotations

import json
import logging
import threading
from typing import Any, Callable, Mapping, Optional, Protocol

log = logging.getLogger(__name__)

#: How long to wait before reconnecting after the socket closed or refused.
#: ComfyUI is a local process that is restarted by hand; a couple of seconds is
#: responsive without turning an absent backend into a busy loop.
RECONNECT_SECONDS = 2.0

#: How long a connection attempt is given.  ComfyUI is on localhost, so a
#: connect that has not happened by now is not going to.
OPEN_TIMEOUT_SECONDS = 3.0

#: Messages that mean "this prompt reached a point where its HTTP-visible state
#: may have changed".  Each one causes a re-read of ``/history`` and ``/queue``;
#: none of them is itself treated as a state.
_LIFECYCLE = frozenset(
    {
        "execution_start",
        "execution_cached",
        "execution_success",
        "execution_error",
        "execution_interrupted",
    }
)


class JobSink(Protocol):
    """What this consumer needs from the job store, and nothing more."""

    def note_progress(self, prompt_id: str, step: int, total: int) -> None:
        ...

    def note_change(self, prompt_id: str) -> None:
        ...


class ComfyEvents:
    """A background subscription to one ComfyUI's event socket.

    Started once at gateway startup and stopped at shutdown.  It is a
    subscription, not a poller: it makes no request of its own and wakes only
    when ComfyUI says something.
    """

    def __init__(
        self,
        url: str,
        sink: JobSink,
        *,
        reconnect_seconds: float = RECONNECT_SECONDS,
        open_timeout: float = OPEN_TIMEOUT_SECONDS,
        connect: Optional[Callable[..., Any]] = None,
    ) -> None:
        self._url = url
        self._sink = sink
        self._reconnect_seconds = reconnect_seconds
        self._open_timeout = open_timeout
        self._connect = connect
        self._stopping = threading.Event()
        self._connected = threading.Event()
        self._lock = threading.Lock()
        self._socket: Any = None
        self._thread: Optional[threading.Thread] = None
        #: Which prompt ComfyUI last said it was executing.  Older builds omit
        #: ``prompt_id`` from a ``progress`` message, and ComfyUI executes one
        #: prompt at a time, so this is the only thing the numbers can belong
        #: to.  It is read from ComfyUI's own messages, not assumed.
        self._executing: Optional[str] = None

    # -- lifecycle ---------------------------------------------------------

    def start(self) -> "ComfyEvents":
        if self._thread is not None:  # pragma: no cover - started once
            return self
        self._thread = threading.Thread(
            target=self._run, name="comfy-events", daemon=True
        )
        self._thread.start()
        return self

    def stop(self) -> None:
        """Stop listening.  Safe to call whether or not :meth:`start` ran."""

        self._stopping.set()
        with self._lock:
            socket = self._socket
        if socket is not None:
            # Closing from this thread is what breaks the blocking read the
            # listener is sitting in; the library documents close() as safe to
            # call from another thread.
            try:
                socket.close()
            except Exception:  # pragma: no cover - a socket already torn down
                pass
        thread, self._thread = self._thread, None
        if thread is not None:
            thread.join(timeout=5)

    @property
    def connected(self) -> bool:
        return self._connected.is_set()

    def wait_until_connected(self, timeout: float) -> bool:
        """Used by tests; the gateway never waits for this socket."""

        return self._connected.wait(timeout)

    # -- the listener ------------------------------------------------------

    def _run(self) -> None:
        while not self._stopping.is_set():
            try:
                self._listen()
            except Exception as exc:
                # Every failure here is local: ComfyUI is not running, it
                # restarted, it closed the socket.  None of it is the app's
                # business, and none of it changes a job's state.
                log.debug("ComfyUI event socket: %s", exc)
            finally:
                self._connected.clear()
                with self._lock:
                    self._socket = None
                self._executing = None
            if self._stopping.is_set():
                return
            self._stopping.wait(self._reconnect_seconds)

    def _listen(self) -> None:
        connect = self._connect
        if connect is None:
            from websockets.sync.client import connect as connect  # noqa: PLC0415

        with connect(self._url, open_timeout=self._open_timeout) as socket:
            with self._lock:
                if self._stopping.is_set():
                    socket.close()
                    return
                self._socket = socket
            self._connected.set()
            log.info("listening to ComfyUI's event socket")
            for message in socket:
                if self._stopping.is_set():
                    return
                self.handle(message)

    # -- one message -------------------------------------------------------

    def handle(self, message: Any) -> None:
        """Act on one frame.  Public so a test can drive it without a socket."""

        if isinstance(message, (bytes, bytearray)):
            # Binary frames are node previews -- a partially denoised image.
            # `docs/api.md` has no preview surface, so they are dropped here
            # rather than half-supported.
            return
        try:
            payload = json.loads(message)
        except (TypeError, ValueError):
            return
        if not isinstance(payload, Mapping):
            return

        kind = payload.get("type")
        data = payload.get("data")
        if not isinstance(data, Mapping):
            data = {}

        if kind == "progress":
            self._progress(data)
            return

        prompt_id = _identifier(data.get("prompt_id"))
        if kind == "executing":
            if prompt_id:
                self._executing = prompt_id
            # ``node: null`` is ComfyUI saying it has run out of nodes for this
            # prompt.  Every other ``executing`` is one node of many, and
            # re-reading /history once per node would be chatter.
            if prompt_id and data.get("node") is None:
                self._sink.note_change(prompt_id)
            return

        if kind in _LIFECYCLE:
            if not prompt_id:
                return
            if kind == "execution_start":
                self._executing = prompt_id
            elif self._executing == prompt_id:
                self._executing = None
            self._sink.note_change(prompt_id)

    def _progress(self, data: Mapping[str, Any]) -> None:
        prompt_id = _identifier(data.get("prompt_id")) or self._executing
        if not prompt_id:
            return
        step = _count(data.get("value"))
        total = _count(data.get("max"))
        # Only a pair that describes a real position is passed on.  A missing
        # number, a zero total or a step past the end is a message this gateway
        # cannot read, and the honest response to that is no progress at all.
        if step is None or total is None or total <= 0 or not 0 <= step <= total:
            return
        self._sink.note_progress(prompt_id, step, total)


def _identifier(value: Any) -> Optional[str]:
    return value if isinstance(value, str) and value else None


def _count(value: Any) -> Optional[int]:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, float) and value.is_integer():
        return int(value)
    return None


__all__ = ["ComfyEvents", "JobSink", "OPEN_TIMEOUT_SECONDS", "RECONNECT_SECONDS"]
