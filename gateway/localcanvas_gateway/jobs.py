"""The job store: five states, one snapshot, nothing invented.

`docs/api.md` names exactly five server-side job states -- ``queued``,
``running``, ``completed``, ``failed``, ``cancelled`` -- and :class:`JobState`
contains those five and no others.  Connection-flavoured states belong to the
client and never appear here (`docs/recovery.md`).

Two rules do most of the work in this module:

**Never invent a state.**  A job's state changes only when ComfyUI's own
``/history`` or ``/queue`` says so.  When ComfyUI cannot be reached, or answers
something this gateway cannot parse, the job keeps the last state that was
actually observed and the reason is logged locally.  A guess would be
indistinguishable from knowledge to the app, and `docs/recovery.md` is built on
the snapshot being proof.

**Never fabricate progress.**  ``progress`` is ``null`` unless real numbers were
reported.  Over ComfyUI's *HTTP* surface no per-step progress exists at all --
ComfyUI reports it on its own WebSocket -- so the numbers arrive through
:meth:`JobStore.note_progress`, from `comfy/events.py`, and nowhere else.  When
that socket is absent the field stays ``null``, which is what the contract says
an absence of real progress looks like.  Nothing here derives a percentage from
elapsed time, from a queue position, or from a step count that was not
reported.

State is refreshed lazily, when a snapshot is asked for.  That keeps the gateway
free of background pollers, and it means the answer the app gets was true at the
moment it asked rather than at the last tick of a timer.  ComfyUI's event socket
adds a second, cheaper trigger for the same refresh -- :meth:`JobStore.note_change`
-- so a watcher learns of a finished generation as soon as ComfyUI says so
instead of at its next poll.  It is a trigger, not a source: what the app is
told still came from ``/history`` and ``/queue``.

**A watcher is served from the published view, never from a promise.**  Each
refresh publishes the snapshot it produced and bumps a version;
:meth:`JobStore.wait_for_change` is what the event-stream route waits on.  A
route that never woke, a socket that never opened and an event consumer that
never connected all leave the same thing behind: a job whose truth is one
``GET /api/v1/jobs/{id}`` away.

The store is in-process: a gateway restart loses it, and the honest signal for
that is the documented ``404`` on an unknown ``job_id``, which the app renders
as lost state rather than as a job still running.
"""

from __future__ import annotations

import logging
import re
import threading
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from enum import Enum
from typing import Any, Dict, FrozenSet, Iterable, List, Optional, Tuple

from .comfy import (
    ComfyClient,
    ComfyError,
    ExecutionError,
    HistoryEntry,
    OutputFile,
    QueuePlace,
)

log = logging.getLogger(__name__)


class JobState(str, Enum):
    """The only five states the gateway asserts (`docs/api.md`)."""

    QUEUED = "queued"
    RUNNING = "running"
    COMPLETED = "completed"
    FAILED = "failed"
    CANCELLED = "cancelled"


#: Once a job reaches one of these, ComfyUI is never asked about it again.
TERMINAL_STATES = frozenset({JobState.COMPLETED, JobState.FAILED, JobState.CANCELLED})

#: The two ways ``/queue`` can still be holding a prompt.  Either is proof that
#: ComfyUI has it, which is what makes them one case rather than two.
_IN_THE_QUEUE = frozenset({QueuePlace.RUNNING, QueuePlace.PENDING})

#: Result paths are built from this and the job id.  It is a **path**, never a
#: URL: the gateway does not name its own host in a payload
#: (`docs/transport-boundary.md` §3).
RESULT_PATH = "/api/v1/jobs/{job_id}/result/{index}"

#: ComfyUI's own failure text is genuine information, but it is not a UI, so
#: what reaches the app is one bounded line (`docs/api.md`, "What may cross
#: from ComfyUI").
_MAX_ERROR_DETAIL = 200

#: The rule, from `docs/api.md`: **no directory component ever crosses; a bare
#: filename may.**  ``D:/models/whatever.safetensors`` becomes
#: ``whatever.safetensors`` -- the filename is the part a user can act on (it
#: says *which* model is missing), and the layout of their disk is nobody's
#: business on a phone.
#:
#: Each pattern matches a path span and captures its final component, which is
#: what replaces the span.  Two are needed because *where a path begins* is only
#: knowable from an anchor:
#:
#: * **anchored** -- a drive letter, a UNC ``\\``, or a separator at a word
#:   boundary.  Past an anchor we are certainly inside a path, so a directory
#:   component is allowed to contain spaces, and
#:   ``C:\Program Files\ComfyUI\models\sd xl.safetensors`` loses every directory
#:   while the filename survives.  This is the shape the contract names,
#:   because it is the likely one on Windows;
#: * **relative** -- ``models/checkpoints/sd.ckpt``, with nothing to say where
#:   it starts.  Components must then be space-free, because extending leftwards
#:   across spaces with no anchor would eat ordinary words out of the sentence.
#:   The residue is stated rather than hidden: a *relative* path whose directory
#:   contains a space can leave that one word behind (``Program Files\x`` ->
#:   ``Program x``).  Closing it would mean deleting prose from every message
#:   containing a slash -- a worse trade for a shape ComfyUI does not produce,
#:   since the paths in its exceptions are absolute.
#:
#: Both are greedy, which is the safe direction: over-consuming drops a word,
#: under-consuming leaks a directory.
_PATH_SPANS = (
    re.compile(
        r"""(?:[A-Za-z]:[\\/]|\\\\|(?<![^\s'"(\[])[\\/])"""  # anchor
        r"""(?:[^\\/\n]*[\\/])*"""  # directories, spaces and all
        r"""(?P<name>[^\\/\s]*)"""  # the final component
    ),
    re.compile(r"""(?:[^\\/\s]+[\\/])+(?P<name>[^\\/\s]*)"""),
)

#: A custom node that re-raises with ``traceback.format_exc()`` puts a stack
#: trace inside ``exception_message``, where the ``traceback`` field never being
#: read does not help.  A trace is never the user-facing surface, and half a
#: trace with its paths stripped is not an improvement on a whole one -- so a
#: message carrying one contributes no reason at all.  Matched against the
#: **raw** text, before path scrubbing rewrites the very shape being looked for.
_TRACEBACK_MARKERS = (
    re.compile(r"traceback \(most recent call last\)", re.IGNORECASE),
    re.compile(r"""File ["'][^"']*["'], line \d+"""),
)


@dataclass(frozen=True)
class Progress:
    """Real, reported progress.  Constructed only from numbers ComfyUI gave."""

    step: int
    total: int

    def to_view(self) -> Dict[str, int]:
        return {"step": self.step, "total": self.total}


@dataclass(frozen=True)
class JobError:
    """Why a job failed, in the documented error object's shape."""

    code: str
    message: str
    field: Optional[str] = None

    def to_view(self) -> Dict[str, Any]:
        return {"code": self.code, "message": self.message, "field": self.field}


@dataclass(frozen=True)
class JobResult:
    """One output, as the app sees it -- plus the ComfyUI handle it came from.

    :attr:`output` stays gateway-side: it names a file inside ComfyUI's own
    output directory, and nothing in :meth:`to_view` exposes it.
    """

    index: int
    kind: str
    media_type: str
    output: OutputFile

    def to_view(self, job_id: str) -> Dict[str, Any]:
        return {
            "index": self.index,
            "kind": self.kind,
            "media_type": self.media_type,
            "path": RESULT_PATH.format(job_id=job_id, index=self.index),
        }


@dataclass
class Job:
    """One submitted generation."""

    job_id: str
    workflow_id: str
    prompt_id: str
    created_at: str
    state: JobState = JobState.QUEUED
    results: Tuple[JobResult, ...] = ()
    error: Optional[JobError] = None
    progress: Optional[Progress] = None
    #: The node class names in the graph this job submitted.  Gateway-side, and
    #: kept for one purpose: removing ComfyUI's node vocabulary from a failure
    #: message by name.  "No node type in any response" is a rule this makes
    #: structural instead of trusting ComfyUI to have reported which node
    #: raised.
    node_types: FrozenSet[str] = frozenset()
    #: Set once ComfyUI has been asked to delete this prompt from its queue and
    #: has answered.  It changes what an *absence* means: normally a prompt that
    #: is in neither the queue nor the history is in the gap between the two and
    #: nothing is known, but a prompt deleted before it started never runs, so
    #: it will never have a history entry.  That is the one thing that lets the
    #: gateway say ``cancelled`` about a queued job and mean it.
    #:
    #: **It is a claim, not a fact, and one observation retires it.** ComfyUI
    #: answers ``POST /queue`` with 200 whether or not the id was there, and it
    #: only ever removes *pending* entries -- so a prompt the executor picked
    #: up between the read and the delete gets this flag while it is genuinely
    #: running.  :meth:`JobStore.refresh` therefore clears it the moment either
    #: queue names the prompt again; see the comment there.
    queue_deleted: bool = False

    def to_view(self) -> Dict[str, Any]:
        """The authoritative snapshot (`docs/api.md`)."""

        return {
            "job_id": self.job_id,
            "workflow_id": self.workflow_id,
            "state": self.state.value,
            "progress": self.progress.to_view() if self.progress else None,
            "results": [result.to_view(self.job_id) for result in self.results],
            "error": self.error.to_view() if self.error else None,
        }

    def submission_view(self) -> Dict[str, Any]:
        """What ``POST /api/v1/jobs`` answers."""

        return {"job_id": self.job_id, "state": self.state.value, "created_at": self.created_at}


class JobStore:
    """Every job this gateway process knows about."""

    def __init__(self, comfy: ComfyClient) -> None:
        self._comfy = comfy
        self._lock = threading.RLock()
        # Watchers block here until a job's published view changes.  Built on
        # the same lock as the store, so a refresh and the wake-up it causes
        # cannot interleave.
        self._changed = threading.Condition(self._lock)
        self._jobs: Dict[str, Job] = {}
        #: ComfyUI talks in prompt ids; the app never sees one.  This is the
        #: only place the two vocabularies meet.
        self._by_prompt: Dict[str, str] = {}
        #: The last snapshot published for each job, and how many times it has
        #: changed.  A watcher compares versions rather than views, so an
        #: identical refresh wakes nobody.
        self._views: Dict[str, Dict[str, Any]] = {}
        self._versions: Dict[str, int] = {}

    def create(
        self,
        workflow_id: str,
        prompt_id: str,
        *,
        node_types: Iterable[str] = (),
    ) -> Job:
        """Record a prompt ComfyUI has accepted.  A new job starts ``queued``."""

        with self._lock:
            job_id = self._new_id()
            job = Job(
                job_id=job_id,
                workflow_id=workflow_id,
                prompt_id=prompt_id,
                created_at=_now(),
                node_types=frozenset(name for name in node_types if name),
            )
            self._jobs[job_id] = job
            self._by_prompt[prompt_id] = job_id
            self._publish(job)
            return job

    def get(self, job_id: str) -> Optional[Job]:
        """The job, or ``None`` -- which the API turns into the documented 404."""

        with self._lock:
            return self._jobs.get(job_id)

    def snapshot(self, job_id: str) -> Optional[Job]:
        """Refresh from ComfyUI and return the job, or ``None`` if unknown."""

        job = self.get(job_id)
        if job is None:
            return None
        self.refresh(job)
        return job

    def refresh(self, job: Job) -> Job:
        """Bring one job up to date with what ComfyUI actually reports."""

        if job.state in TERMINAL_STATES:
            return job

        try:
            entry = self._comfy.history(job.prompt_id)
        except ComfyError as exc:
            # Locally logged, not surfaced: the app is told the last state that
            # was really observed, not a state this gateway made up.
            log.warning("job %s: cannot read ComfyUI history: %s", job.job_id, exc)
            return job

        if entry.found:
            applied = self._apply_history(job, entry)
            with self._lock:
                self._publish(applied)
            return applied

        try:
            place = self._comfy.queue_place(job.prompt_id)
        except ComfyError as exc:
            log.warning("job %s: cannot read the ComfyUI queue: %s", job.job_id, exc)
            return job

        with self._lock:
            if place in _IN_THE_QUEUE:
                # ComfyUI still has this prompt, so any deletion asked for did
                # not land.  ``POST /queue`` answers 200 whether or not it
                # removed anything and only ever removes *pending* entries, so
                # ``queue_deleted`` is a claim until an observation supports
                # it -- and a sighting in either queue is the observation that
                # retires it.  Without this line a prompt the executor picked
                # up between the read and the delete keeps a flag saying it
                # never ran, and the next gap below turns a generation that is
                # about to succeed into a permanent ``cancelled``.
                job.queue_deleted = False
                job.state = (
                    JobState.RUNNING
                    if place is QueuePlace.RUNNING
                    else JobState.QUEUED
                )
            elif job.queue_deleted:
                # Not the gap this time.  ComfyUI took this prompt out of the
                # queue before it started, so it never ran and will never have
                # a history entry -- and it is not running, because it is not
                # in the running slot either.  Both halves are read from
                # ComfyUI; neither is assumed.
                job.state = JobState.CANCELLED
                job.progress = None
                job.results = ()
                job.error = None
            # ABSENT with no history entry is otherwise the gap between leaving
            # the queue and the entry appearing.  Nothing is known, so nothing
            # changes.
            self._publish(job)
        return job

    def _apply_history(self, job: Job, entry: HistoryEntry) -> Job:
        with self._lock:
            if entry.interrupted:
                # ComfyUI files an interrupt under the same status string as a
                # crash, and it is not one: it is what a cancel looks like once
                # it has actually landed (`docs/recovery.md`).  It reaches this
                # branch whoever asked for it -- this gateway, or somebody at
                # ComfyUI's own web UI.
                log.info("job %s was interrupted in ComfyUI", job.job_id)
                job.state = JobState.CANCELLED
                job.progress = None
                # A stopped run may have left a few files behind, but a
                # cancelled generation has no result to show and
                # ``/result/{index}`` serves a completed job only.  Reporting
                # half an outcome would be worse than reporting none.
                job.results = ()
                job.error = None
                return job
            if entry.failed:
                # The whole of ComfyUI's account goes here, where the person who
                # can act on it is sitting.  What crosses to the phone is built
                # separately, and deliberately carries less.
                log.warning(
                    "job %s failed in ComfyUI: %s",
                    job.job_id,
                    entry.error.for_log() if entry.error else "no detail reported",
                )
                job.state = JobState.FAILED
                job.error = _failure(entry.error, job.node_types)
                job.results = ()
                job.progress = None
                return job
            if entry.finished:
                job.state = JobState.COMPLETED
                job.results = _results(entry.outputs)
                job.error = None
                # A finished generation has a result, and a step count that
                # stopped being interesting the moment it did.
                job.progress = None
                return job
            # An entry exists but reports neither success nor failure.  That is
            # ComfyUI still working on it, not a fifth outcome.
            job.state = JobState.RUNNING
            return job

    # -- cancellation ------------------------------------------------------

    def cancel(self, job_id: str) -> Optional[Job]:
        """Ask ComfyUI to stop this job, then report what actually happened.

        Idempotent, and honest in both directions (`docs/recovery.md`):

        * the first thing it does is **read**.  A job that finished before the
          request arrived is answered with its real state and its results, and
          nothing is sent to ComfyUI at all -- a cancel request is not a
          cancelled outcome, and this is the case where the two differ;
        * a job still waiting in the queue is removed with ``POST /queue``,
          because ``/interrupt`` does nothing to a prompt that has not started;
        * a job that is executing is interrupted -- and only after ``/queue``
          has confirmed that the running slot holds *this* prompt, so a cancel
          never stops somebody else's generation;
        * afterwards the state is read back.  ComfyUI checks the interrupt flag
          between nodes, so a prompt whose last node had already finished
          completes normally, and completed is then what this reports.

        Returns ``None`` for an unknown id, which the route turns into the
        documented 404.
        """

        job = self.get(job_id)
        if job is None:
            return None

        self.refresh(job)
        if job.state in TERMINAL_STATES:
            # Already over.  Idempotent for a second cancel, and honest for a
            # generation that beat the request.
            return job

        try:
            place = self._comfy.queue_place(job.prompt_id)
            if place is QueuePlace.PENDING:
                self._comfy.delete_queued(job.prompt_id)
                with self._lock:
                    job.queue_deleted = True
            elif place is QueuePlace.RUNNING:
                self._comfy.interrupt()
            else:
                # Neither queued nor running: it is between the queue and its
                # history entry.  There is nothing to interrupt, and sending
                # /interrupt anyway would stop whatever ComfyUI has moved on
                # to.  The refresh below reads what it settled on.
                log.info(
                    "job %s: nothing to stop -- ComfyUI has it in neither queue",
                    job.job_id,
                )
        except ComfyError as exc:
            # The request did not get through.  The job keeps the state that
            # was really observed; the app sees no change and can ask again.
            log.warning("job %s: cancel could not be delivered: %s", job.job_id, exc)
            return job

        return self.refresh(job)

    # -- what ComfyUI's event socket contributes ---------------------------

    def note_progress(self, prompt_id: str, step: int, total: int) -> None:
        """Record real progress ComfyUI reported for one prompt.

        The only way ``progress`` ever becomes non-null.  Ignored for a job
        that is already over, and ignored for a prompt this gateway did not
        submit -- ComfyUI broadcasts some messages, and another client's
        generation is not this one's.
        """

        with self._lock:
            job = self._for_prompt(prompt_id)
            if job is None or job.state in TERMINAL_STATES:
                return
            reported = Progress(step=step, total=total)
            if job.progress == reported:
                return
            job.progress = reported
            self._publish(job)

    def note_change(self, prompt_id: str) -> None:
        """ComfyUI said this prompt moved; go and read what it moved to.

        A trigger, not a state.  What the app is told still comes from
        ``/history`` and ``/queue``, which is why this is a call to
        :meth:`refresh` and not an assignment.
        """

        with self._lock:
            job = self._for_prompt(prompt_id)
        if job is None:
            return
        self.refresh(job)

    def _for_prompt(self, prompt_id: str) -> Optional[Job]:
        job_id = self._by_prompt.get(prompt_id)
        return self._jobs.get(job_id) if job_id else None

    # -- watching ----------------------------------------------------------

    def published(self, job_id: str) -> Optional[Tuple[int, Dict[str, Any]]]:
        """The last published snapshot and its version, or ``None`` if unknown.

        Read without touching ComfyUI: this is what a watcher renders between
        refreshes, and it is the same object ``GET /api/v1/jobs/{id}`` would
        have answered at the moment it was published.
        """

        with self._lock:
            view = self._views.get(job_id)
            if view is None:
                return None
            return self._versions.get(job_id, 0), dict(view)

    def wait_for_change(self, job_id: str, since: int, timeout: float) -> int:
        """Block until this job's published version moves past ``since``.

        Returns the current version, which equals ``since`` when the wait timed
        out -- and a timeout is not an error: it is the watcher's cue to go and
        poll ComfyUI itself, which is what keeps the event stream working when
        ComfyUI's own socket is not there.
        """

        deadline = time.monotonic() + timeout
        with self._changed:
            while self._versions.get(job_id, 0) == since:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                self._changed.wait(remaining)
            return self._versions.get(job_id, 0)

    def _publish(self, job: Job) -> None:
        """Make this job's snapshot the published one, and wake its watchers.

        Called with the store's lock held.  An unchanged view publishes
        nothing: watchers are woken by a difference, never by activity.
        """

        view = job.to_view()
        if self._views.get(job.job_id) == view:
            return
        self._views[job.job_id] = view
        self._versions[job.job_id] = self._versions.get(job.job_id, 0) + 1
        self._changed.notify_all()

    def _new_id(self) -> str:
        while True:
            candidate = "j-{}".format(uuid.uuid4().hex[:8])
            if candidate not in self._jobs:
                return candidate


def _results(outputs: Tuple[OutputFile, ...]) -> Tuple[JobResult, ...]:
    """Number the outputs once, so ``/result/{index}`` stays stable afterwards.

    ``width`` / ``height`` are deliberately absent.  ComfyUI's ``/history`` does
    not report them, and the only way to learn them would be to download and
    decode every output before answering a snapshot -- a real cost for a field
    `docs/api.md` describes as "optional and normally absent", includable only by
    a gateway that knows a dimension for free.  The app sizes an image from the
    image.
    """

    results: List[JobResult] = []
    for index, output in enumerate(outputs):
        results.append(
            JobResult(
                index=index,
                kind=output.kind,
                media_type=output.media_type,
                output=output,
            )
        )
    return tuple(results)


def _failure(error: Optional[ExecutionError], node_types: FrozenSet[str]) -> JobError:
    """A failure a person can read -- and nothing they cannot act on.

    `docs/api.md`: a backend failure reaches the phone as a human sentence plus,
    at most, a short bounded reason.  No directory component crosses, node
    internals do not cross, and neither does a stack trace.
    """

    message = "ComfyUI could not finish this generation."
    reason = _reason(error, node_types) if error is not None else None
    if reason:
        message = "{} It reported: {}".format(message, reason)
    return JobError(code="generation_failed", message=message)


def _reason(error: ExecutionError, node_types: FrozenSet[str]) -> Optional[str]:
    """ComfyUI's exception text with everything that must not cross removed.

    Returns ``None`` when nothing readable survives -- which is the honest
    outcome for a message that was *only* a directory and a node name, and is
    better than padding the sentence with punctuation.
    """

    if not error.message:
        return None

    raw = str(error.message)
    if any(marker.search(raw) for marker in _TRACEBACK_MARKERS):
        # A stack trace is never the user-facing surface, and a scrubbed one is
        # no better.  It is already on its way to the log in full.
        return None

    text = " ".join(raw.split())
    for pattern in _PATH_SPANS:
        text = pattern.sub(lambda match: match.group("name"), text)

    # Longest first, so a class name that contains another is removed whole.
    # Case-insensitively: ComfyUI's own messages say "KSampler" and a custom
    # node's say "ksampler", and both name the node.
    names = set(node_types)
    if error.node_type:
        names.add(error.node_type)
    for name in sorted(names, key=len, reverse=True):
        text = re.sub(re.escape(name), " ", text, flags=re.IGNORECASE)

    if error.node_id:
        text = re.sub(
            r"\bnode\s*#?\s*{}\b".format(re.escape(error.node_id)),
            " ",
            text,
            flags=re.IGNORECASE,
        )

    text = " ".join(text.split()).strip(" .,:;-'\"()[]<>")
    if not text or not any(character.isalpha() for character in text):
        return None
    if len(text) > _MAX_ERROR_DETAIL:
        text = text[: _MAX_ERROR_DETAIL - 1].rstrip() + "…"
    return text if text.endswith("…") else text + "."


def _now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


__all__ = [
    "Job",
    "JobError",
    "JobResult",
    "JobState",
    "JobStore",
    "Progress",
    "RESULT_PATH",
    "TERMINAL_STATES",
]
