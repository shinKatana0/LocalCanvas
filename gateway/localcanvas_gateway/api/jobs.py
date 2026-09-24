"""Submission, the state snapshot, and the result bytes.

The order in :func:`submit_job` is the contract, not an implementation detail:
**validate, translate, bind, submit.**  A value the field schema rejects never
reaches ComfyUI, and the response names the field it came from so the app can
put the message under the input the user typed it into (`docs/api.md`).
Translation is one stage with one place in that order -- before binding, so the
graph carries the effective text, and after validation, so nothing is
translated that was going to be refused anyway.

What is deliberately not here: the event stream, which is its own module
(`events.py`) because it is the one route that is not a request and a response.

The result route **streams**.  A finished output is handed from ComfyUI to the
phone a chunk at a time and is never assembled in the gateway: that is the
difference between serving a picture and serving a video, and it is why
``comfy.open_view`` returns an open response rather than bytes.
"""

from __future__ import annotations

import logging
from typing import Any, FrozenSet, Mapping

from fastapi import APIRouter, Body, Request
from fastapi.responses import StreamingResponse

from ..comfy import ComfyError, ComfySubmitRejected
from ..errors import ApiError
from ..jobs import Job, JobState
from ..validation import validate_inputs
from ..workflows import BindingError, bind_values
from .state import gateway

log = logging.getLogger(__name__)

router = APIRouter()

#: The only word a submission may say about translation, and the whole of the
#: request-side vocabulary (`docs/api.md`).  There is deliberately no ``on``
#: and no ``auto``: the override can switch the stage **off** for one
#: submission and can never switch it on, which mirrors the rule the workflow
#: schema already carries -- a client cannot switch on a stage the machine has
#: not been configured for (`docs/workflow-schema.md`).
TRANSLATION_OFF = "off"


@router.post("/jobs", status_code=201)
def submit_job(request: Request, payload: Any = Body(default=None)) -> dict:
    """Validate, bind, submit.  Answers ``{job_id, state, created_at}``."""

    state = gateway(request)

    if not isinstance(payload, Mapping):
        raise ApiError(
            status_code=400,
            code="invalid_request",
            message="The request could not be understood. Expected JSON.",
        )

    workflow_id = payload.get("workflow_id")
    if not isinstance(workflow_id, str) or not workflow_id:
        raise ApiError(
            status_code=400,
            code="invalid_request",
            message="No workflow was chosen.",
            field="workflow_id",
        )

    workflow = state.registry.get(workflow_id)
    if workflow is None:
        raise ApiError(
            status_code=404,
            code="workflow_not_found",
            message="That workflow is no longer available.",
        )

    raw_inputs = payload.get("inputs", {})
    if raw_inputs is None:
        raw_inputs = {}
    if not isinstance(raw_inputs, Mapping):
        raise ApiError(
            status_code=400,
            code="invalid_request",
            message="The settings for this generation could not be read.",
            field="inputs",
        )

    # Read before validation so that a request whose translation block is
    # malformed is refused as one request rather than half-processed.
    translate = _translation_wanted(payload)

    # Raises ValidationFailure -- which is an ApiError carrying the field id --
    # before anything is bound and before ComfyUI is contacted at all.
    values = validate_inputs(workflow, raw_inputs)

    # Translation sits here, between validation and binding, and nowhere else
    # (`docs/api.md`): the graph is bound from the *effective* text, while the
    # original -- the canonical one, what the app shows and what Generate Again
    # resubmits -- is handed back in the answer and never persisted from here.
    # A translation that was asked for and could not run raises an ApiError
    # rather than quietly binding the untranslated text.
    #
    # ``translate`` is this submission's own override and is only ever able to
    # switch the stage off (`docs/api.md`).  It is passed *into* the stage
    # rather than branched on here, so there is still exactly one place that
    # decides whether a submission is translated.
    translation = state.translation.apply(workflow, values, translate=translate)

    try:
        # The media resolver is the seam `workflows/binding.py` left: it turns a
        # media_id into whatever value a ComfyUI loader input takes, and that
        # value never appears in a response.  A reference to media the gateway
        # no longer holds raises a field-attributed ValidationFailure from
        # inside here -- before ComfyUI is contacted, so an expired upload can
        # never become a generation from nothing.
        graph = bind_values(
            workflow, translation.values, media_resolver=state.media_resolver
        )
    except BindingError as exc:
        # Defensive, and currently unreachable: validate_inputs() has already
        # refused every value bind_values() would reject -- an unknown field and
        # a missing required one.  It stays because "unreachable" is a statement
        # about today's validation rules, and the alternative to catching it is
        # a traceback reaching the phone.
        log.error("workflow %s could not be bound: %s", workflow_id, exc)
        raise ApiError(
            status_code=500,
            code="workflow_unusable",
            message="This workflow could not be prepared for generation.",
        ) from exc
    except ComfyError as exc:
        # Binding media means handing the file to ComfyUI, so ComfyUI being
        # away is a way *binding* can fail now, not only submission.
        log.error("ComfyUI unreachable while binding workflow %s: %s", workflow_id, exc)
        raise ApiError(
            status_code=503,
            code="comfy_unavailable",
            message="ComfyUI is not running, so nothing can be generated right now.",
        ) from exc

    try:
        prompt_id = state.comfy.submit(graph)
    except ComfySubmitRejected as exc:
        log.error("ComfyUI rejected workflow %s: %s", workflow_id, exc)
        raise ApiError(
            status_code=502,
            code="comfy_rejected_workflow",
            message=(
                "ComfyUI could not run this workflow. Its definition may not match "
                "the ComfyUI on this PC."
            ),
        ) from exc
    except ComfyError as exc:
        log.error("ComfyUI unreachable while submitting workflow %s: %s", workflow_id, exc)
        raise ApiError(
            status_code=503,
            code="comfy_unavailable",
            message="ComfyUI is not running, so nothing can be generated right now.",
        ) from exc

    job = state.jobs.create(
        workflow_id=workflow_id,
        prompt_id=prompt_id,
        # Gateway-side, and never served: the job needs them to strip ComfyUI's
        # node vocabulary out of a failure message (`docs/api.md`).
        node_types=_node_types(graph),
    )
    log.info("job %s submitted workflow %s as prompt %s", job.job_id, workflow_id, prompt_id)
    view = job.submission_view()
    view["translation"] = translation.to_view()
    return view


@router.get("/jobs/{job_id}")
def job_snapshot(job_id: str, request: Request) -> dict:
    """The authoritative state.  An unknown id is a 404, and that is the point.

    `docs/recovery.md` is built on this answer being honest: a gateway that
    restarted has genuinely lost the job, and saying ``404`` is what lets the
    app tell the user so instead of showing a generation that will never finish.
    """

    job = gateway(request).jobs.snapshot(job_id)
    if job is None:
        raise ApiError(
            status_code=404,
            code="job_not_found",
            message="That generation is no longer known to this server.",
        )
    return job.to_view()


@router.post("/jobs/{job_id}/cancel")
def cancel_job(job_id: str, request: Request) -> dict:
    """Ask ComfyUI to stop, then answer with what actually happened.

    Idempotent, and it answers the **whole snapshot** rather than a bare state:
    the case that matters most is the one where the generation finished before
    the request landed, and the app needs the result it just discovered it has
    (`docs/recovery.md`).  A second cancel on a job that is already over gets
    the same answer as the first.

    The reasoning about which ComfyUI mechanism applies -- interrupt for a
    running prompt, queue deletion for a waiting one -- lives in the job store,
    with the state it is reasoning about.
    """

    job = gateway(request).jobs.cancel(job_id)
    if job is None:
        raise ApiError(
            status_code=404,
            code="job_not_found",
            message="That generation is no longer known to this server.",
        )
    return job.to_view()


@router.get("/jobs/{job_id}/result/{index}")
def job_result(job_id: str, index: str, request: Request) -> StreamingResponse:
    """The output bytes, streamed, with the media type to render them as.

    The bytes are pulled from ComfyUI only as fast as the phone takes them and
    are never accumulated here.  A video is therefore served by a gateway whose
    memory use does not depend on how long the video is -- and the read is given
    a budget sized for one (`comfy/client.py`, ``RESULT_TIMEOUT``).

    ``Content-Length`` is passed through when ComfyUI sent one, so the app can
    show a real download progress bar.  When it did not, no length is invented.
    """

    state = gateway(request)
    job = state.jobs.snapshot(job_id)
    if job is None:
        raise ApiError(
            status_code=404,
            code="job_not_found",
            message="That generation is no longer known to this server.",
        )

    result = _result(job, index)
    try:
        stream = state.comfy.open_view(result.output)
    except ComfyError as exc:
        log.error("job %s: result %s could not be read: %s", job_id, index, exc)
        raise ApiError(
            status_code=502,
            code="result_unavailable",
            message="This result could not be read back from ComfyUI.",
        ) from exc

    headers = (
        {"content-length": str(stream.content_length)}
        if stream.content_length is not None
        else None
    )
    return StreamingResponse(
        stream.chunks(), media_type=stream.media_type, headers=headers
    )


def _translation_wanted(payload: Mapping[str, Any]) -> bool:
    """``False`` when this submission asked for its text to be left alone.

    Absent means "whatever this PC and this workflow already decided", which is
    what every client that has never heard of the override sends.  The only
    accepted body is ``{"mode": "off"}``: anything else -- ``on``, ``auto``, a
    stray key, a bare string -- is refused rather than quietly ignored, because
    a client that thinks it switched translation *on* and was silently ignored
    would be told a confident lie by the very block that exists to prevent one.
    """

    raw = payload.get("translation")
    if raw is None:
        return True
    if (
        not isinstance(raw, Mapping)
        or set(raw) != {"mode"}
        or raw.get("mode") != TRANSLATION_OFF
    ):
        raise ApiError(
            status_code=400,
            code="invalid_request",
            message=(
                "Translation can only be switched off for a generation, never on."
            ),
            field="translation",
        )
    return False


def _node_types(graph: Mapping[str, Any]) -> FrozenSet[str]:
    """Every ``class_type`` in the submitted graph."""

    return frozenset(
        str(node["class_type"])
        for node in graph.values()
        if isinstance(node, Mapping) and node.get("class_type")
    )


def _result(job: Job, index: str):
    missing = ApiError(
        status_code=404,
        code="result_not_found",
        message="That result is not available.",
    )
    try:
        position = int(index)
    except ValueError:
        raise missing from None
    if job.state is not JobState.COMPLETED or not 0 <= position < len(job.results):
        raise missing
    return job.results[position]


__all__ = ["TRANSLATION_OFF", "router"]
