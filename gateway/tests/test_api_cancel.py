"""``POST /api/v1/jobs/{id}/cancel`` -- a request, and the outcome it is not.

`docs/recovery.md`: **a cancel request is not a cancelled outcome**, and the API
must never assert one for the other.  Everything in this file exists to hold
that line, and the case it turns on is the race -- a generation that finished
before the interrupt landed is reported as **completed, with its result**.

Two ComfyUI mechanisms are involved and they are not interchangeable.
``/interrupt`` stops the prompt that is executing and does nothing to one still
waiting; a queued prompt is removed with ``POST /queue``.  Which one was used is
asserted, not assumed, because sending the wrong one would look like success and
leave the job running.
"""

from __future__ import annotations

import pytest

from conftest import served, watching
from localcanvas_gateway.comfy import QueuePlace
from workflow_fixtures import EVERY_FIELD


@pytest.fixture
def harness(gateway_factory, builder):
    builder.add("flow", EVERY_FIELD)
    return gateway_factory()


def submitted(harness):
    job_id = harness.submit("flow", {"prompt": "a rainy alley"}).json()["job_id"]
    return job_id, harness.prompt_id


def cancel(harness, job_id):
    return harness.client.post("/api/v1/jobs/{}/cancel".format(job_id))


def snapshot(harness, job_id):
    return harness.client.get("/api/v1/jobs/{}".format(job_id)).json()


# -- which mechanism ---------------------------------------------------------


def test_a_queued_job_is_cancelled_by_queue_deletion_not_by_interrupt(
    harness,
) -> None:
    """``/interrupt`` would do nothing here: the prompt has not started."""

    job_id, prompt_id = submitted(harness)

    body = cancel(harness, job_id).json()

    assert body["state"] == "cancelled"
    assert harness.fake.queue_deletes == [prompt_id]
    assert harness.fake.interrupts == []


def test_a_running_job_is_cancelled_by_interrupt_not_by_queue_deletion(
    harness,
) -> None:
    """Deleting from the queue would do nothing here: it is not in the queue."""

    job_id, prompt_id = submitted(harness)
    harness.fake.start_running(prompt_id)

    body = cancel(harness, job_id).json()

    assert body["state"] == "cancelled"
    assert harness.fake.interrupts == [prompt_id]
    assert harness.fake.queue_deletes == []


def test_an_interrupt_is_never_sent_for_somebody_elses_generation(harness) -> None:
    """``/interrupt`` names no prompt, so the caller must know it is theirs.

    Two jobs: the second is executing, the first is still waiting.  Cancelling
    the first must not reach for the one mechanism that would stop the second.
    """

    first = harness.submit("flow", {"prompt": "one"}).json()["job_id"]
    second = harness.submit("flow", {"prompt": "two"}).json()["job_id"]
    first_prompt, second_prompt = harness.fake.prompt_ids
    harness.fake.start_running(second_prompt)

    assert cancel(harness, first).json()["state"] == "cancelled"

    assert harness.fake.interrupts == []
    assert harness.fake.queue_deletes == [first_prompt]
    assert snapshot(harness, second)["state"] == "running"


def test_nothing_is_interrupted_while_comfyui_is_between_its_two_answers(
    harness,
) -> None:
    """The gap: the prompt has left the queue and has no history entry yet.

    ComfyUI has moved on to *something*, and an ``/interrupt`` sent blind would
    stop whatever that is.  So nothing is sent, and the job keeps the last
    state that was actually observed -- which is the honest answer to "we do
    not know yet".
    """

    job_id, prompt_id = submitted(harness)
    harness.fake.start_running(prompt_id)
    assert snapshot(harness, job_id)["state"] == "running"
    harness.fake.leave_queue(prompt_id)

    body = cancel(harness, job_id).json()

    assert harness.fake.interrupts == []
    assert harness.fake.queue_deletes == []
    assert body["state"] == "running"


# -- the race ----------------------------------------------------------------


def test_a_job_that_completed_before_the_request_is_completed_with_its_result(
    harness,
) -> None:
    """The first thing cancel does is read, and this is why.

    The generation was already over.  Nothing is sent to ComfyUI at all, and
    the answer carries the result the user is about to be shown.
    """

    job_id, prompt_id = submitted(harness)
    harness.fake.start_running(prompt_id)
    harness.fake.complete(prompt_id)

    body = cancel(harness, job_id).json()

    assert body["state"] == "completed"
    assert body["results"][0]["path"] == "/api/v1/jobs/{}/result/0".format(job_id)
    assert harness.fake.interrupts == []
    assert harness.fake.queue_deletes == []
    assert harness.client.get(body["results"][0]["path"]).status_code == 200


def test_a_cancel_reads_before_it_acts(harness) -> None:
    """The order is the guarantee, and the outcome cannot show it.

    A cancel that acts first and reads afterwards produces the same answer as
    this one almost every time -- right up until the run it stops was already
    over, which is the one case `docs/recovery.md` writes a rule about.  So the
    sequence of requests is asserted rather than the answer: nothing that
    *changes* ComfyUI is sent before ComfyUI has been asked what the state is.
    """

    job_id, prompt_id = submitted(harness)
    harness.fake.start_running(prompt_id)
    del harness.fake.requests[:]

    assert cancel(harness, job_id).json()["state"] == "cancelled"

    during = harness.fake.requests
    reads = [
        index
        for index, request in enumerate(during)
        if request.startswith("GET /history/")
    ]
    writes = [
        index
        for index, request in enumerate(during)
        if request in ("POST /interrupt", "POST /queue")
    ]
    assert reads and writes, during
    assert reads[0] < writes[0], during


def test_a_job_that_completed_before_the_interrupt_landed_is_completed_not_cancelled(
    harness,
) -> None:
    """The narrow race, and the single most likely thing to get wrong here.

    ComfyUI was executing this prompt when the cancel arrived, so ``/interrupt``
    really was sent -- and ComfyUI checks that flag *between nodes*, so the last
    node finished first and the prompt completed normally.  What is reported is
    what happened: completed, with the result, and never cancelled.
    """

    job_id, prompt_id = submitted(harness)
    harness.fake.start_running(prompt_id)
    harness.fake.interrupt_outcome = "completed"

    body = cancel(harness, job_id).json()

    assert harness.fake.interrupts == [prompt_id], "the interrupt was not even sent"
    assert body["state"] == "completed"
    assert body["results"], body
    assert harness.client.get(body["results"][0]["path"]).status_code == 200
    assert snapshot(harness, job_id)["state"] == "completed"


def test_an_interrupt_comfyui_has_not_acted_on_yet_asserts_nothing(harness) -> None:
    """The flag is set and unread.  Nothing is known, so nothing is claimed."""

    job_id, prompt_id = submitted(harness)
    harness.fake.start_running(prompt_id)
    harness.fake.interrupt_outcome = "ignored"

    body = cancel(harness, job_id).json()

    assert harness.fake.interrupts == [prompt_id]
    assert body["state"] == "running"

    # ...and when ComfyUI does act on it, the state follows.
    harness.fake.interrupt_prompt(prompt_id)
    assert snapshot(harness, job_id)["state"] == "cancelled"


# -- idempotence and honesty -------------------------------------------------


def test_cancel_is_idempotent(harness) -> None:
    job_id, prompt_id = submitted(harness)

    first = cancel(harness, job_id).json()
    second = cancel(harness, job_id).json()

    assert first["state"] == second["state"] == "cancelled"
    # The second call had nothing left to ask ComfyUI for.
    assert harness.fake.queue_deletes == [prompt_id]


def test_cancelling_a_finished_job_does_not_rewrite_it(harness) -> None:
    job_id, prompt_id = submitted(harness)
    harness.fake.fail(prompt_id, "the model file is missing")
    assert snapshot(harness, job_id)["state"] == "failed"

    body = cancel(harness, job_id).json()

    assert body["state"] == "failed"
    assert "the model file is missing" in body["error"]["message"]


def test_cancel_of_a_job_this_gateway_never_had_is_404(harness) -> None:
    response = cancel(harness, "j-deadbeef")

    assert response.status_code == 404
    assert response.json()["error"]["code"] == "job_not_found"


def test_a_cancel_that_never_reached_comfyui_claims_nothing(harness) -> None:
    """A gateway that cannot reach ComfyUI does not get to say "cancelled"."""

    job_id, _ = submitted(harness)
    harness.fake.stop()

    body = cancel(harness, job_id).json()

    assert body["state"] == "queued"


def test_a_cancelled_job_has_no_result_to_serve(harness) -> None:
    job_id, prompt_id = submitted(harness)
    harness.fake.start_running(prompt_id)

    body = cancel(harness, job_id).json()

    assert body["state"] == "cancelled"
    assert body["results"] == []
    assert body["error"] is None
    assert harness.client.get("/api/v1/jobs/{}/result/0".format(job_id)).status_code == 404


def test_the_files_a_stopped_run_left_behind_are_not_offered_as_a_result(
    harness,
) -> None:
    """ComfyUI keeps the outputs of nodes that finished before the interrupt.

    They are real files, and they are not the generation the user asked for.
    ``/result/{index}`` serves a completed job only, so handing them over would
    produce a result list whose entries 404 -- half an outcome, which is worse
    than none.
    """

    job_id, prompt_id = submitted(harness)
    harness.fake.start_running(prompt_id)
    harness.fake.interrupt_prompt(
        prompt_id,
        partial_files=[{"filename": "half_done_00001_.png", "subfolder": "", "type": "output"}],
    )

    body = snapshot(harness, job_id)

    assert body["state"] == "cancelled"
    assert body["results"] == []
    assert harness.client.get("/api/v1/jobs/{}/result/0".format(job_id)).status_code == 404


def test_an_interrupt_from_comfyuis_own_screen_is_cancelled_not_failed(
    harness,
) -> None:
    """ComfyUI files an interrupt under the same status string as a crash.

    Nobody asked this gateway for a cancel -- somebody pressed the button on
    the PC.  A cancelled generation and a broken workflow must still not reach
    the phone as the same thing (`docs/recovery.md`).
    """

    job_id, prompt_id = submitted(harness)
    harness.fake.start_running(prompt_id)
    harness.fake.interrupt_prompt(prompt_id)

    body = snapshot(harness, job_id)

    assert body["state"] == "cancelled"
    assert body["error"] is None
    assert body["results"] == []


def test_a_queued_job_deleted_from_the_queue_is_never_left_stuck(harness) -> None:
    """A deleted prompt never runs, so it never gets a history entry.

    Without knowing the deletion happened, "in neither the queue nor the
    history" is the gap and nothing changes -- and the job would sit at
    ``queued`` for ever.  This is the one absence the gateway is entitled to
    read as an outcome.
    """

    job_id, prompt_id = submitted(harness)

    assert cancel(harness, job_id).json()["state"] == "cancelled"

    # Read back through ComfyUI's own /queue, not through the fake's bookkeeping.
    assert harness.state.comfy.queue_place(prompt_id) is QueuePlace.ABSENT
    assert snapshot(harness, job_id)["state"] == "cancelled"


def test_a_deletion_the_executor_beat_does_not_cancel_the_run_it_missed(
    harness,
) -> None:
    """The other side of "a cancel request is not a cancelled outcome".

    ComfyUI answers ``POST /queue`` with 200 whether or not it removed
    anything, and it only ever removes *pending* entries.  So if the executor
    picks the prompt up between the gateway's ``/queue`` read and its delete --
    a user changing their mind at the instant generation starts, which is not
    an exotic timing -- the request lands on a prompt that is running and will
    run to completion.

    The race is reproduced, not asserted around: ComfyUI's executor moves
    *while the delete is in flight*.  What must not happen is the gateway
    remembering a deletion that never took: the next time the prompt is in
    neither queue and its history entry has not appeared -- the module's own
    documented gap, which a watcher samples twice a second -- a stale flag
    would read that absence as proof and write ``cancelled``, which is
    terminal.  The generation then succeeds and its result is never reported.
    """

    job_id, prompt_id = submitted(harness)

    def executor(request: str) -> None:
        if request == "POST /queue":
            harness.fake.on_request = None
            harness.fake.start_running(prompt_id)

    harness.fake.on_request = executor

    # The delete really was sent, and ComfyUI really did answer it.
    assert cancel(harness, job_id).json()["state"] == "running"
    assert harness.fake.queue_deletes == [prompt_id]

    # The gap: out of the queue, no history entry yet.  Nothing is known, so
    # nothing may be claimed -- least of all a terminal state.
    harness.fake.leave_queue(prompt_id)
    assert snapshot(harness, job_id)["state"] == "running"

    # And the generation the deletion missed finishes, with its result.
    harness.fake.complete(prompt_id)
    finished = snapshot(harness, job_id)
    assert finished["state"] == "completed"
    assert finished["results"], finished
    assert harness.client.get(finished["results"][0]["path"]).status_code == 200


# -- and it reaches a watcher ------------------------------------------------


def test_the_cancelled_state_reaches_a_watching_socket(harness) -> None:
    job_id, prompt_id = submitted(harness)
    harness.fake.start_running(prompt_id)

    with served(harness.app) as base_url:
        with watching(base_url, job_id) as stream:
            assert stream.next()["type"] == "state"
            assert cancel(harness, job_id).json()["state"] == "cancelled"

            messages = stream.drain()

    assert [message["state"] for message in messages if message["type"] == "state"][
        -1
    ] == "cancelled"
