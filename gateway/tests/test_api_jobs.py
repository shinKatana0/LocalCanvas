"""Submission, tracking and result serving.

The rule this file exists to hold in place: **a value the schema rejects never
reaches ComfyUI.**  Every validation test therefore asserts twice -- that the
response names the field, and that the fake backend received nothing.
"""

from __future__ import annotations

import asyncio
import threading
import time
from types import SimpleNamespace

import httpx
import pytest
from fastapi.responses import StreamingResponse

import media_fixtures
from conftest import IMPATIENT, served
from localcanvas_gateway.api.jobs import job_result
from localcanvas_gateway.api.media import _chunks
from localcanvas_gateway.media import CHUNK_BYTES
from localcanvas_gateway.comfy import RESULT_CHUNK_BYTES, OutputFile
from localcanvas_gateway.comfy.fake import ONE_PIXEL_PNG
from localcanvas_gateway.media import COMFY_INPUT_SUBFOLDER
from workflow_fixtures import EVERY_FIELD, IMAGE_FIELD


@pytest.fixture
def harness(gateway_factory, builder):
    builder.add("flow", EVERY_FIELD)
    return gateway_factory()


@pytest.fixture
def media_harness(gateway_factory, builder):
    builder.add("needs_image", IMAGE_FIELD)
    return gateway_factory()


def error_of(response):
    body = response.json()
    assert set(body) == {"error"}
    assert set(body["error"]) == {"code", "message", "field"}
    return body["error"]


# -- submission ------------------------------------------------------------


def test_a_valid_submission_is_accepted_and_queued(harness) -> None:
    response = harness.submit("flow", {"prompt": "a rainy alley at night"})

    assert response.status_code == 201
    body = response.json()
    # ``translation`` joined this answer with T-0040 and is always present:
    # what happened to the submitted text is part of the submission's own
    # answer, and "nothing" is a thing that happened (`docs/api.md`).
    assert set(body) == {"job_id", "state", "created_at", "translation"}
    assert body["translation"] == {"applied": False, "fields": {}}
    assert body["state"] == "queued"
    assert body["job_id"].startswith("j-")


def test_the_submitted_values_are_written_into_the_graph(harness) -> None:
    """The app sends fields; ComfyUI receives a graph.  This is that seam."""

    harness.submit("flow", {"prompt": "a rainy alley", "steps": 33, "mode": "slow"})

    graph = harness.fake.submissions[0]["prompt"]

    assert graph["20"]["inputs"]["text"] == "a rainy alley"
    assert graph["30"]["inputs"]["steps"] == 33
    assert graph["30"]["inputs"]["mode"] == "slow"


def test_a_field_left_out_keeps_the_curators_own_value(harness) -> None:
    harness.submit("flow", {"prompt": "a rainy alley"})

    graph = harness.fake.submissions[0]["prompt"]

    assert graph["30"]["inputs"]["steps"] == 20  # the value in the exported graph


def test_submitting_twice_does_not_leak_values_between_jobs(harness) -> None:
    harness.submit("flow", {"prompt": "first", "steps": 11})
    harness.submit("flow", {"prompt": "second"})

    first, second = (item["prompt"] for item in harness.fake.submissions)

    assert first["30"]["inputs"]["steps"] == 11
    assert second["30"]["inputs"]["steps"] == 20


# -- validation happens before ComfyUI -------------------------------------


def test_a_missing_required_field_is_attributed_and_never_submitted(harness) -> None:
    response = harness.submit("flow", {"steps": 20})

    assert response.status_code == 400
    error = error_of(response)
    assert error["field"] == "prompt"
    assert error["code"] == "missing_field"
    assert "Prompt" in error["message"]
    assert harness.fake.submissions == []


def test_an_empty_required_text_is_not_a_value(harness) -> None:
    response = harness.submit("flow", {"prompt": "   "})

    assert response.status_code == 400
    assert error_of(response)["field"] == "prompt"
    assert harness.fake.submissions == []


def test_a_value_below_the_minimum_names_the_field_and_the_bound(harness) -> None:
    response = harness.submit("flow", {"prompt": "x", "steps": 0})

    assert response.status_code == 400
    error = error_of(response)
    assert error["field"] == "steps"
    assert "at least 1" in error["message"]
    assert harness.fake.submissions == []


def test_a_value_above_the_maximum_names_the_field_and_the_bound(harness) -> None:
    response = harness.submit("flow", {"prompt": "x", "steps": 500})

    error = error_of(response)
    assert error["field"] == "steps"
    assert "at most 50" in error["message"]
    assert harness.fake.submissions == []


def test_a_wrong_type_names_the_field(harness) -> None:
    response = harness.submit("flow", {"prompt": "x", "steps": "twenty"})

    assert error_of(response)["field"] == "steps"
    assert harness.fake.submissions == []


def test_true_is_not_a_number(harness) -> None:
    response = harness.submit("flow", {"prompt": "x", "steps": True})

    assert error_of(response)["field"] == "steps"
    assert harness.fake.submissions == []


def test_a_value_outside_the_options_names_the_choices(harness) -> None:
    response = harness.submit("flow", {"prompt": "x", "mode": "sideways"})

    error = error_of(response)
    assert error["field"] == "mode"
    assert "Fast" in error["message"] and "Slow" in error["message"]
    assert harness.fake.submissions == []


def test_a_boolean_field_refuses_a_string(harness) -> None:
    response = harness.submit("flow", {"prompt": "x", "enabled": "yes"})

    assert error_of(response)["field"] == "enabled"
    assert harness.fake.submissions == []


def test_a_field_the_workflow_does_not_have_is_refused(harness) -> None:
    response = harness.submit("flow", {"prompt": "x", "sampler": "euler"})

    error = error_of(response)
    assert error["field"] == "sampler"
    assert error["code"] == "unknown_field"
    assert harness.fake.submissions == []


def test_an_integer_field_accepts_an_integer_valued_float(harness) -> None:
    """JSON has one number type; ``24.0`` from a phone is the integer 24."""

    harness.submit("flow", {"prompt": "x", "steps": 24.0})

    assert harness.fake.submissions[0]["prompt"]["30"]["inputs"]["steps"] == 24


def test_a_float_field_accepts_an_integer(harness) -> None:
    harness.submit("flow", {"prompt": "x", "guidance": 7})

    assert harness.fake.submissions[0]["prompt"]["30"]["inputs"]["cfg"] == 7.0


def test_a_media_field_binds_an_uploaded_file(media_harness) -> None:
    """The whole point of the seam, seen from both sides at once.

    The graph that reached ComfyUI carries a value at the loader's input; the
    response the phone got carries no value at all.
    """

    media_id = media_harness.uploaded_id()

    response = media_harness.submit("needs_image", {"source_image": {"media_id": media_id}})

    assert response.status_code == 201
    bound = media_harness.fake.submissions[0]["prompt"]["40"]["inputs"]["image"]
    assert bound != "PLACEHOLDER.png"
    assert bound in media_harness.fake.input_files


def test_an_uploaded_file_is_asked_into_one_clearable_subfolder(
    media_harness,
) -> None:
    """`docs/privacy-security.md`: the residue is one folder, not a scattering.

    LocalCanvas cannot reap what it puts in ComfyUI's input directory, so the
    one thing it can do for the user is keep it all in a single place they can
    empty in one action.
    """

    for name, content_type in (("a.jpg", "image/jpeg"), ("b.png", "image/png")):
        media_id = media_harness.uploaded_id(filename=name, content_type=content_type)
        media_harness.submit("needs_image", {"source_image": {"media_id": media_id}})

    assert len(media_harness.fake.input_files) == 2
    for reference in media_harness.fake.input_files:
        assert reference.startswith(COMFY_INPUT_SUBFOLDER + "/")
    for submission in media_harness.fake.submissions:
        bound = submission["prompt"]["40"]["inputs"]["image"]
        assert bound.startswith(COMFY_INPUT_SUBFOLDER + "/")
        assert bound in media_harness.fake.input_files


def test_the_subfolder_is_asked_for_never_composed_by_the_gateway(
    media_harness,
) -> None:
    """A subfolder ComfyUI reports is bound; one it does not is not invented.

    Nothing in the gateway prefixes the reference itself -- proven by taking the
    subfolder away in ComfyUI's *answer* and watching the bound value lose it
    too, rather than keeping a prefix the gateway had put there.
    """

    media_harness.fake.upload_subfolder_override = ""
    media_id = media_harness.uploaded_id()

    media_harness.submit("needs_image", {"source_image": {"media_id": media_id}})

    bound = media_harness.fake.submissions[0]["prompt"]["40"]["inputs"]["image"]
    assert "/" not in bound
    assert bound in media_harness.fake.input_files


def test_a_media_reference_the_gateway_no_longer_holds_generates_nothing(
    media_harness,
) -> None:
    """`docs/api.md`: `media_expired`, attributed to the field.

    The attribution is the point: it is what lets the app clear that one field
    and ask for the picture again, instead of reporting a generation failure
    the user cannot place.
    """

    media_id = media_harness.uploaded_id()
    media_harness.media_clock.advance(3600 + 1)

    response = media_harness.submit("needs_image", {"source_image": {"media_id": media_id}})

    error = error_of(response)
    assert response.status_code == 400
    assert error["field"] == "source_image"
    assert error["code"] == "media_expired"
    assert media_harness.fake.submissions == []


def test_a_well_formed_id_the_store_never_held_expires_the_same_way(
    media_harness,
) -> None:
    """Reaped and never-issued are indistinguishable, and are not distinguished."""

    response = media_harness.submit(
        "needs_image", {"source_image": {"media_id": "m-000000"}}
    )

    error = error_of(response)
    assert error["field"] == "source_image"
    assert error["code"] == "media_expired"
    assert media_harness.fake.submissions == []


def test_a_reference_this_gateway_could_not_have_issued_is_not_found(
    media_harness,
) -> None:
    """The one media miss the gateway can speak about with certainty.

    ``m-3f9c1a`` is the shape it issues; ``../../etc/passwd`` is not a media id
    that ever existed here, and saying `media_not_found` rather than
    "expired" is the difference between a fact and a polite guess.
    """

    response = media_harness.submit(
        "needs_image", {"source_image": {"media_id": "../../etc/passwd"}}
    )

    error = error_of(response)
    assert error["field"] == "source_image"
    assert error["code"] == "media_not_found"
    assert media_harness.fake.submissions == []
    assert media_harness.fake.uploads == []


def test_a_media_field_sent_as_a_bare_string_is_refused(media_harness) -> None:
    """A phone that sends the id, not the reference, is a client bug.

    The id is a real one, uploaded a line earlier: a gateway that shrugged and
    accepted the bare string would generate happily, so nothing but the shape
    check stands between this request and a submission.
    """

    media_id = media_harness.uploaded_id()

    response = media_harness.submit("needs_image", {"source_image": media_id})

    error = error_of(response)
    assert response.status_code == 400
    assert error["field"] == "source_image"
    assert error["code"] == "invalid_input"
    assert media_harness.fake.submissions == []


def test_a_video_cannot_be_bound_to_an_image_field(media_harness) -> None:
    """The body is a real MP4, because the gateway reads it now (T-0129).

    The upload has to be accepted on its own bytes before this test can say
    anything about binding it; filler under a ``video/mp4`` label is refused at
    the endpoint, and the mismatch below would never be reached.
    """

    media_id = media_harness.uploaded_id(
        kind="video",
        filename="clip.mp4",
        content_type="video/mp4",
        data=media_fixtures.MP4,
    )

    response = media_harness.submit("needs_image", {"source_image": {"media_id": media_id}})

    error = error_of(response)
    assert error["field"] == "source_image"
    assert error["code"] == "media_kind_mismatch"
    assert media_harness.fake.submissions == []


def test_a_retried_submission_does_not_upload_the_file_again(media_harness) -> None:
    """`docs/api.md`: media outlives one submission.

    The phone uploaded once; two generations from that picture must cost
    ComfyUI one transfer, not two.
    """

    media_id = media_harness.uploaded_id()

    media_harness.submit("needs_image", {"source_image": {"media_id": media_id}})
    media_harness.submit("needs_image", {"source_image": {"media_id": media_id}})

    assert len(media_harness.fake.uploads) == 1
    first, second = media_harness.fake.submissions
    assert first["prompt"]["40"]["inputs"]["image"] == second["prompt"]["40"]["inputs"]["image"]


def test_the_bound_value_is_the_name_comfyui_chose_not_the_one_asked_for(
    media_harness,
) -> None:
    """ComfyUI renames rather than clobbering, and the gateway binds its answer.

    A gateway that bound the name it *sent* would silently generate from
    whatever file was already sitting in the input directory under that name.
    """

    media_id = media_harness.uploaded_id()
    # Something is already there under the name this upload will ask for.
    taken = media_harness.state.media.get(media_id).comfy_upload_name
    media_harness.fake.put_file(
        taken,
        b"someone else's picture",
        subfolder=COMFY_INPUT_SUBFOLDER,
        type="input",
    )

    media_harness.submit("needs_image", {"source_image": {"media_id": media_id}})

    bound = media_harness.fake.submissions[0]["prompt"]["40"]["inputs"]["image"]
    assert bound != "{}/{}".format(COMFY_INPUT_SUBFOLDER, taken)
    assert media_harness.fake.uploads[-1]["requested_filename"] == taken
    assert bound.endswith(media_harness.fake.uploads[-1]["name"])


def test_no_media_value_or_path_appears_in_the_submission_response(
    media_harness,
) -> None:
    """The app never learns what a media field binds to (`docs/api.md`)."""

    media_id = media_harness.uploaded_id()

    response = media_harness.submit("needs_image", {"source_image": {"media_id": media_id}})
    bound = media_harness.fake.submissions[0]["prompt"]["40"]["inputs"]["image"]
    job_id = response.json()["job_id"]
    snapshot = media_harness.client.get("/api/v1/jobs/{}".format(job_id))

    for body in (response.text, snapshot.text):
        assert bound not in body
        assert str(media_harness.state.media.root) not in body


def test_an_unknown_workflow_is_a_404_and_reaches_no_backend(harness) -> None:
    response = harness.client.post(
        "/api/v1/jobs", json={"workflow_id": "nope", "inputs": {}}
    )

    assert response.status_code == 404
    assert error_of(response)["code"] == "workflow_not_found"
    assert harness.fake.submissions == []


def test_a_body_that_is_not_an_object_is_refused(harness) -> None:
    response = harness.client.post("/api/v1/jobs", json=["not", "an", "object"])

    assert response.status_code == 400
    assert error_of(response)["code"] == "invalid_request"
    assert harness.fake.submissions == []


def test_a_body_with_no_workflow_names_the_field(harness) -> None:
    response = harness.client.post("/api/v1/jobs", json={"inputs": {}})

    assert response.status_code == 400
    assert error_of(response)["field"] == "workflow_id"


def test_inputs_that_are_not_an_object_are_refused(harness) -> None:
    response = harness.client.post(
        "/api/v1/jobs", json={"workflow_id": "flow", "inputs": []}
    )

    assert response.status_code == 400
    assert error_of(response)["field"] == "inputs"
    assert harness.fake.submissions == []


# -- the backend refusing or being absent ----------------------------------


def test_a_backend_refusal_is_reported_without_comfyui_vocabulary(harness) -> None:
    harness.fake.reject_prompt = "Value not in list: ckpt_name"

    response = harness.submit("flow", {"prompt": "x"})

    assert response.status_code == 502
    error = error_of(response)
    assert error["code"] == "comfy_rejected_workflow"
    assert "ckpt_name" not in error["message"]
    assert "Traceback" not in response.text


def test_a_backend_that_is_down_is_distinguishable_from_a_bad_workflow(
    harness,
) -> None:
    """`docs/recovery.md`: those two failures have different fixes."""

    harness.fake.stop()

    response = harness.submit("flow", {"prompt": "x"})

    assert response.status_code == 503
    assert error_of(response)["code"] == "comfy_unavailable"


# -- the snapshot ----------------------------------------------------------


def test_the_snapshot_follows_the_job_through_its_states(harness) -> None:
    job_id = harness.submit("flow", {"prompt": "x"}).json()["job_id"]
    prompt_id = harness.prompt_id

    def state():
        return harness.client.get("/api/v1/jobs/{}".format(job_id)).json()["state"]

    assert state() == "queued"
    harness.fake.start_running(prompt_id)
    assert state() == "running"
    harness.fake.complete(prompt_id)
    assert state() == "completed"


def test_a_failed_generation_is_reported_as_failed(harness) -> None:
    job_id = harness.submit("flow", {"prompt": "x"}).json()["job_id"]
    harness.fake.fail(harness.prompt_id, "the model file is missing")

    body = harness.client.get("/api/v1/jobs/{}".format(job_id)).json()

    assert body["state"] == "failed"
    assert "the model file is missing" in body["error"]["message"]
    assert body["results"] == []


def test_a_failure_message_crosses_stripped_of_paths_and_node_names(harness) -> None:
    """`docs/api.md`, "What may cross from ComfyUI" -- end to end, over HTTP.

    ``ExampleSampler`` is a class in the submitted graph, and the fake reports
    a *different* node as the one that raised.  So only the graph's own class
    names can remove it, which is the wiring this pins: the route hands them to
    the job store at submission time.
    """

    job_id = harness.submit("flow", {"prompt": "x"}).json()["job_id"]
    harness.fake.fail(
        harness.prompt_id,
        "ExampleSampler could not load "
        "C:\\Program Files\\ComfyUI\\models\\sd xl.safetensors",
    )

    body = harness.client.get("/api/v1/jobs/{}".format(job_id)).json()

    assert body["state"] == "failed"
    message = body["error"]["message"]
    assert "ExampleSampler" not in message
    for directory in ("C:", "Program Files", "models"):
        assert directory not in message
    # ...while the one actionable part survives: which file was missing.
    assert "sd xl.safetensors" in message
    assert "could not load" in message


def test_an_unknown_job_id_is_404(harness) -> None:
    """Recovery depends on this: a lost job says so instead of pretending."""

    response = harness.client.get("/api/v1/jobs/j-deadbeef")

    assert response.status_code == 404
    assert error_of(response)["code"] == "job_not_found"


def test_progress_is_null_while_nothing_reports_it(harness) -> None:
    job_id = harness.submit("flow", {"prompt": "x"}).json()["job_id"]
    harness.fake.start_running(harness.prompt_id)

    body = harness.client.get("/api/v1/jobs/{}".format(job_id)).json()

    assert body["progress"] is None


# -- results ---------------------------------------------------------------


def test_a_result_is_served_by_the_path_the_snapshot_gave(harness) -> None:
    job_id = harness.submit("flow", {"prompt": "x"}).json()["job_id"]
    harness.fake.complete(harness.prompt_id)

    snapshot = harness.client.get("/api/v1/jobs/{}".format(job_id)).json()
    result = snapshot["results"][0]
    response = harness.client.get(result["path"])

    assert response.status_code == 200
    assert response.content == ONE_PIXEL_PNG
    assert response.headers["content-type"].startswith("image/png")


def test_a_result_path_is_relative_to_the_base_endpoint(harness) -> None:
    job_id = harness.submit("flow", {"prompt": "x"}).json()["job_id"]
    harness.fake.complete(harness.prompt_id)

    path = harness.client.get("/api/v1/jobs/{}".format(job_id)).json()["results"][0]["path"]

    assert path == "/api/v1/jobs/{}/result/0".format(job_id)


def test_a_result_of_a_job_that_has_not_finished_is_not_available(harness) -> None:
    job_id = harness.submit("flow", {"prompt": "x"}).json()["job_id"]

    response = harness.client.get("/api/v1/jobs/{}/result/0".format(job_id))

    assert response.status_code == 404
    assert error_of(response)["code"] == "result_not_found"


def test_a_result_index_that_does_not_exist_is_404(harness) -> None:
    job_id = harness.submit("flow", {"prompt": "x"}).json()["job_id"]
    harness.fake.complete(harness.prompt_id)

    assert harness.client.get("/api/v1/jobs/{}/result/7".format(job_id)).status_code == 404
    assert harness.client.get("/api/v1/jobs/{}/result/x".format(job_id)).status_code == 404


def test_a_result_of_an_unknown_job_is_404(harness) -> None:
    response = harness.client.get("/api/v1/jobs/j-deadbeef/result/0")

    assert response.status_code == 404
    assert error_of(response)["code"] == "job_not_found"


def test_a_video_result_is_served_with_its_own_media_type(harness) -> None:
    job_id = harness.submit("flow", {"prompt": "x"}).json()["job_id"]
    harness.fake.complete(
        harness.prompt_id,
        output_key="gifs",
        files=[{"filename": "clip.mp4", "subfolder": "", "type": "output"}],
    )
    harness.fake.put_file("clip.mp4", b"not really a video", content_type="video/mp4")

    snapshot = harness.client.get("/api/v1/jobs/{}".format(job_id)).json()
    assert snapshot["results"][0]["kind"] == "video"
    assert snapshot["results"][0]["media_type"] == "video/mp4"

    response = harness.client.get(snapshot["results"][0]["path"])
    assert response.headers["content-type"].startswith("video/mp4")


def test_a_result_that_comfyui_can_no_longer_produce_is_an_error_not_bytes(
    harness,
) -> None:
    job_id = harness.submit("flow", {"prompt": "x"}).json()["job_id"]
    harness.fake.complete(harness.prompt_id)
    harness.client.get("/api/v1/jobs/{}".format(job_id))
    harness.fake.stop()

    response = harness.client.get("/api/v1/jobs/{}/result/0".format(job_id))

    assert response.status_code == 502
    assert error_of(response)["code"] == "result_unavailable"


# -- result streaming ------------------------------------------------------
#
# `docs/api.md` says nothing about how a result is moved, and it does not have
# to: the difference between streaming and buffering is invisible in a body and
# decisive in a gateway serving a video.  These tests are what makes it
# visible -- the bytes are right, they are more than one chunk, and the first
# of them reaches the phone before ComfyUI has sent the last.


#: Four chunks' worth, so "larger than one chunk" is a fact rather than a hope.
LARGE_RESULT = bytes(
    (index * 7 + 11) % 251 for index in range(4 * RESULT_CHUNK_BYTES + 137)
)


def completed_video(harness, payload: bytes = LARGE_RESULT) -> str:
    """A finished job whose single output is ``payload``.  Returns its path."""

    job_id = harness.submit("flow", {"prompt": "x"}).json()["job_id"]
    written = harness.fake.complete(
        harness.prompt_id,
        files=[{"filename": "clip.mp4", "subfolder": "", "type": "output"}],
        output_key="gifs",
    )
    harness.fake.put_file(written[0]["filename"], payload, content_type="video/mp4")
    snapshot = harness.client.get("/api/v1/jobs/{}".format(job_id)).json()
    return snapshot["results"][0]["path"]


def test_a_result_larger_than_one_chunk_arrives_byte_for_byte(harness) -> None:
    """Chunking must not lose, duplicate or reorder anything."""

    harness.fake.view_chunk_bytes = 8 * 1024
    path = completed_video(harness)

    response = harness.client.get(path)

    assert response.status_code == 200
    assert len(LARGE_RESULT) > RESULT_CHUNK_BYTES
    assert response.content == LARGE_RESULT
    assert response.headers["content-length"] == str(len(LARGE_RESULT))


def test_result_bytes_arrive_before_comfyui_has_sent_them_all(harness) -> None:
    """The property that distinguishes streaming from buffering.

    ComfyUI is held after its first chunk and released on a timer.  Reading
    incrementally, the first bytes are here at once; a client that buffered
    would have nothing until the release, and the elapsed assertion is what
    says which happened.  The gate opens either way, so a regression fails the
    assertion rather than hanging the suite.

    Driven through the gateway's own ComfyUI client rather than over
    ``TestClient``: the ASGI test transport collects a response before handing
    it back, so at that level a streamed body and a buffered one look the same.
    The route's half of the same property is the test below.
    """

    gate = threading.Event()
    harness.fake.view_chunk_bytes = 8 * 1024
    harness.fake.view_gate = gate
    completed_video(harness)
    output = OutputFile("clip.mp4", "", "output", "video")

    release_after = 3.0
    releaser = threading.Timer(release_after, gate.set)
    releaser.start()
    started = time.monotonic()
    try:
        stream = harness.state.comfy.open_view(output)
        assert stream.media_type == "video/mp4"
        assert stream.content_length == len(LARGE_RESULT)

        arriving = stream.chunks(8 * 1024)
        first = next(arriving)
        waited = time.monotonic() - started
        gate.set()
        rest = b"".join(arriving)
    finally:
        releaser.cancel()
        gate.set()

    assert waited < release_after / 2, waited
    assert first
    assert first + rest == LARGE_RESULT


def test_the_comfyui_read_outlasts_a_pause_a_large_output_can_cause(harness) -> None:
    """The other half of the T-0003 finding: the budget, not just the buffering.

    The harness's client is deliberately impatient -- a one-second read budget,
    fine for the metadata calls it was sized for.  ``/view`` is given its own,
    sized for an output ComfyUI has to pull off a disk, and this holds the
    backend still for twice the impatient budget to say so.  Without the
    override the read gives up and never sees the rest of the video.
    """

    gate = threading.Event()
    harness.fake.view_chunk_bytes = 8 * 1024
    harness.fake.view_gate = gate
    completed_video(harness)
    output = OutputFile("clip.mp4", "", "output", "video")

    stalled_for = 2.0
    assert stalled_for > IMPATIENT.read
    releaser = threading.Timer(stalled_for, gate.set)
    releaser.start()
    try:
        with harness.state.comfy.open_view(output) as stream:
            received = b"".join(stream.chunks(8 * 1024))
    finally:
        releaser.cancel()
        gate.set()

    assert received == LARGE_RESULT


def test_the_result_route_streams_over_a_real_socket(harness) -> None:
    """The property this card exists for, tested where it is observable.

    ``TestClient`` drains a response before returning it, so the assertion
    below is impossible through it and the type assertion underneath is not a
    substitute: wrapping a fully-read body in a one-chunk ``StreamingResponse``
    satisfies ``isinstance`` and buffers a whole video. So the app is served by
    uvicorn on a loopback port -- the server that runs it in production -- with
    ComfyUI held mid-body, and the question asked directly: did the first bytes
    reach the client before the backend had sent the last?

    The fake's chunk must be **larger** than ``RESULT_CHUNK_BYTES``, or the
    gateway's own ``iter_bytes(65536)`` sits waiting for a full 64 KB and the
    signal disappears into the buffer.
    """

    gate = threading.Event()
    harness.fake.view_chunk_bytes = 4 * RESULT_CHUNK_BYTES
    harness.fake.view_gate = gate
    path = completed_video(harness)

    release_after = 3.0
    releaser = threading.Timer(release_after, gate.set)
    releaser.start()
    try:
        with served(harness.app) as base_url:
            started = time.monotonic()
            with httpx.stream("GET", base_url + path, timeout=30.0) as response:
                assert response.status_code == 200
                arriving = response.iter_bytes()
                first = next(arriving)
                waited = time.monotonic() - started
                gate.set()
                rest = b"".join(arriving)
    finally:
        releaser.cancel()
        gate.set()

    assert waited < release_after / 2, waited
    assert first
    assert first + rest == LARGE_RESULT


def test_the_upload_route_reads_the_body_in_pieces(harness) -> None:
    """The same property on the way in: a phone's video is never one read.

    ``_chunks`` is what stands between an upload and the gateway's memory.
    ``yield file.file.read()`` -- one unbounded read -- is a one-word change
    that passes every other test in this suite and puts a whole video in RAM,
    so what is asserted is the shape of the reads themselves: each one bounded,
    and more than one of them.
    """

    payload = b"v" * (3 * CHUNK_BYTES + 7)
    handle = CountingFile(payload)

    pieces = list(_chunks(SimpleNamespace(file=handle)))

    assert b"".join(pieces) == payload
    assert len(pieces) > 1
    assert max(len(piece) for piece in pieces) <= CHUNK_BYTES
    # Every read was bounded.  An unbounded one -- read(), read(-1), read(None)
    # -- is the mutation this exists to kill.
    assert handle.calls
    for size in handle.calls:
        assert isinstance(size, int) and 0 < size <= CHUNK_BYTES, handle.calls


class CountingFile:
    """A file object that remembers how it was asked for its contents."""

    def __init__(self, data: bytes) -> None:
        self.data = data
        self.offset = 0
        self.calls: list = []

    def read(self, size: int = -1) -> bytes:
        self.calls.append(size)
        if size is None or size < 0:
            chunk = self.data[self.offset :]
        else:
            chunk = self.data[self.offset : self.offset + size]
        self.offset += len(chunk)
        return chunk


def test_the_result_route_hands_back_a_stream_not_a_body(harness) -> None:
    """The route's half: it must not quietly become a buffer again.

    Asserted on the response object, for the reason given above -- over the
    test transport the two are indistinguishable, and this is exactly the
    distinction the card is about.
    """

    harness.fake.view_chunk_bytes = 8 * 1024
    path = completed_video(harness)
    pieces = path.split("/")
    request = SimpleNamespace(
        app=SimpleNamespace(state=SimpleNamespace(gateway=harness.state))
    )

    response = job_result(pieces[-3], pieces[-1], request)

    assert isinstance(response, StreamingResponse)
    assert asyncio.run(_collect(response.body_iterator)) == LARGE_RESULT


async def _collect(body_iterator) -> bytes:
    return b"".join([chunk async for chunk in body_iterator])
