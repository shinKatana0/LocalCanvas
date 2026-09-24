"""``WS /api/v1/jobs/{job_id}/events`` -- the stream, and its own irrelevance.

`docs/api.md` is unusually blunt about this endpoint: **the WebSocket is an
optimization, never the source of truth.**  So the thing to check about the
code below is not what it sends but what happens without it, and the answer is
"everything still works": every message here is a field of the snapshot that
``GET /api/v1/jobs/{job_id}`` already answers, carried earlier and nothing
more.  A client that never opens this socket, or loses it and does not come
back, polls that endpoint and misses nothing.  Nothing is queued for a socket
that is not there, no event is replayed on reconnect, and a reconnecting client
re-establishes truth from the snapshot rather than from a backlog.

What it sends is a delta against the last snapshot it sent::

    {"type": "progress", "step": 7, "total": 24}
    {"type": "result",   "results": [...]}
    {"type": "error",    "message": "..."}
    {"type": "state",    "state": "running"}

**In that order within one batch**, which is the one design decision here worth
naming: the payload goes before the state that commits it, so a client acting on
``completed`` already holds the results, and one acting on ``failed`` already
holds the message.  The reverse order would make every client re-fetch.

The error message is the one the job store built, scrubbed of paths, node
vocabulary and tracebacks by ``jobs.py`` (`docs/api.md`, "What may cross from
ComfyUI").  There is no second scrubber, and no second path from ComfyUI's words
to the phone -- what crosses a socket crosses the same boundary as what crosses
HTTP, because it is literally the same string.

**How it learns.**  It waits on the job store's published version.  ComfyUI's
event socket (`comfy/events.py`) bumps that version as soon as ComfyUI says
anything, so a finished generation is delivered immediately.  When that socket
is absent the wait times out and the watcher polls the snapshot itself, once
per :data:`POLL_SECONDS`, for as long as somebody is actually watching.  Both
paths end in the same call and produce the same messages: the difference between
having ComfyUI's socket and not having it is latency, never correctness.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Any, Dict, List, Mapping

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from ..jobs import TERMINAL_STATES, JobStore

log = logging.getLogger(__name__)

router = APIRouter()

#: How long a watcher waits for the store to change before going and asking
#: ComfyUI itself.  This is the fallback that makes the stream correct without
#: ComfyUI's event socket, so it is short enough to feel live and long enough
#: that one phone watching one generation is not a poller in disguise.
POLL_SECONDS = 0.5

#: Application close codes.  1000 is a normal, expected end -- the generation is
#: over and there is nothing further to say, which is a completed conversation
#: and not a dropped connection.
_CLOSED_NORMALLY = 1000
#: 1008 refuses the handshake for a job this gateway does not know.  The client
#: is told *what* by ``GET /api/v1/jobs/{id}``, which answers the documented
#: 404; a socket is the wrong place to state a fact the snapshot owns.
_UNKNOWN_JOB = 1008


@router.websocket("/jobs/{job_id}/events")
async def job_events(websocket: WebSocket, job_id: str) -> None:
    """Stream one job's state deltas until it ends or the client goes away."""

    store: JobStore = websocket.app.state.gateway.jobs
    if store.get(job_id) is None:
        await websocket.close(code=_UNKNOWN_JOB)
        return

    await websocket.accept()
    gone = asyncio.Event()
    # A client that walks away sends nothing, so the only way to notice is to
    # be reading.  Without this the gateway would hold a socket open for the
    # length of a generation nobody is watching.
    watcher = asyncio.create_task(_watch_for_disconnect(websocket, gone))
    sent: Dict[str, Any] = {}

    try:
        await asyncio.to_thread(store.snapshot, job_id)
        published = store.published(job_id)
        if published is None:  # pragma: no cover - the job was there a line ago
            return
        version, view = published
        await _send(websocket, sent, view)
        sent = view

        while view["state"] not in _TERMINAL_NAMES and not gone.is_set():
            changed = await asyncio.to_thread(
                store.wait_for_change, job_id, version, POLL_SECONDS
            )
            if gone.is_set():
                break
            if changed == version:
                # Nothing told us anything.  Ask ComfyUI ourselves -- this is
                # the branch that makes the stream work on a gateway whose
                # ComfyUI event socket never connected.
                await asyncio.to_thread(store.snapshot, job_id)
            published = store.published(job_id)
            if published is None:  # pragma: no cover - jobs are never dropped
                break
            version, view = published
            await _send(websocket, sent, view)
            sent = view
    except WebSocketDisconnect:
        pass
    except Exception:  # pragma: no cover - a stream failure is never fatal
        log.exception("job %s: the event stream ended unexpectedly", job_id)
    finally:
        watcher.cancel()
        try:
            await websocket.close(code=_CLOSED_NORMALLY)
        except Exception:
            pass


#: The five job states as they appear in a snapshot.
_TERMINAL_NAMES = frozenset(state.value for state in TERMINAL_STATES)


async def _watch_for_disconnect(websocket: WebSocket, gone: asyncio.Event) -> None:
    """Read from the socket only to learn when there is nobody on it.

    The contract defines no client-to-server message, so anything that arrives
    is discarded rather than interpreted -- a socket the app can send commands
    down is a second API, and there is one.
    """

    try:
        while True:
            message = await websocket.receive()
            if message.get("type") == "websocket.disconnect":
                return
    except Exception:
        return
    finally:
        gone.set()


async def _send(
    websocket: WebSocket, previous: Mapping[str, Any], current: Mapping[str, Any]
) -> None:
    for message in _deltas(previous, current):
        await websocket.send_json(message)


def _deltas(
    previous: Mapping[str, Any], current: Mapping[str, Any]
) -> List[Dict[str, Any]]:
    """What changed between two snapshots, in the shapes `docs/api.md` names.

    ``previous`` is empty for the first batch, which is why a client that opens
    the socket late is told the state, the progress and the result it missed --
    from the snapshot, not from a replay log.
    """

    messages: List[Dict[str, Any]] = []

    progress = current.get("progress")
    if progress is not None and progress != previous.get("progress"):
        messages.append(
            {"type": "progress", "step": progress["step"], "total": progress["total"]}
        )

    results = current.get("results") or []
    if results and results != (previous.get("results") or []):
        messages.append({"type": "result", "results": results})

    error = current.get("error")
    if error is not None and error != previous.get("error"):
        # The message the job store already built.  `jobs.py` is the only place
        # ComfyUI's words are turned into something fit to cross, and this
        # carries its output rather than repeating its work.
        messages.append({"type": "error", "message": error["message"]})

    if current.get("state") != previous.get("state"):
        messages.append({"type": "state", "state": current["state"]})

    return messages


__all__ = ["POLL_SECONDS", "router"]
