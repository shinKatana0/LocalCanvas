"""``WS /api/v1/jobs/{id}/events`` -- and the product that survives without it.

The contract calls this socket "an optimization, never the source of truth",
which is a claim about what happens when it is *gone*.  So half of this file is
about the stream working and the other half is about it being unnecessary: a
generation followed with no socket at all, and one whose socket is torn down
mid-flight, both end with the app holding the same result.

Everything here runs against a real gateway on a loopback port, under uvicorn,
with a real WebSocket client -- ``TestClient`` speaks to the application object
and would say nothing about whether the server this project actually ships can
serve a socket at all.
"""

from __future__ import annotations

import time

import httpx
import pytest

from conftest import served, watching
from workflow_fixtures import EVERY_FIELD


@pytest.fixture
def harness(gateway_factory, builder):
    builder.add("flow", EVERY_FIELD)
    return gateway_factory()


def submitted(harness):
    """One queued job: its id, and the prompt id the fake gave it."""

    job_id = harness.submit("flow", {"prompt": "a rainy alley"}).json()["job_id"]
    return job_id, harness.prompt_id


def snapshot(base_url: str, job_id: str) -> dict:
    response = httpx.get("{}/api/v1/jobs/{}".format(base_url, job_id), timeout=10.0)
    assert response.status_code == 200, response.text
    return response.json()


def states(messages) -> list:
    return [message["state"] for message in messages if message["type"] == "state"]


# -- the stream ------------------------------------------------------------


def test_the_stream_opens_with_the_state_the_snapshot_would_have_given(
    harness,
) -> None:
    """A socket opened at any moment starts from the truth, not from silence."""

    job_id, _ = submitted(harness)

    with served(harness.app) as base_url:
        with watching(base_url, job_id) as stream:
            assert stream.next() == {"type": "state", "state": "queued"}


def test_a_state_change_arrives_as_a_delta(harness) -> None:
    job_id, prompt_id = submitted(harness)

    with served(harness.app) as base_url:
        with watching(base_url, job_id) as stream:
            assert stream.next() == {"type": "state", "state": "queued"}
            harness.fake.start_running(prompt_id)

            assert stream.until("state") == {"type": "state", "state": "running"}


def test_the_result_arrives_before_the_state_that_commits_it(harness) -> None:
    """A client acting on ``completed`` must already hold what completed.

    The order inside one batch is the reason this endpoint sends deltas rather
    than a snapshot per change: an app that had to re-fetch on ``completed``
    would gain nothing from the socket at all.
    """

    job_id, prompt_id = submitted(harness)

    with served(harness.app) as base_url:
        with watching(base_url, job_id) as stream:
            assert stream.next()["type"] == "state"
            harness.fake.complete(prompt_id)
            messages = stream.drain()

    types = [message["type"] for message in messages]
    assert "result" in types and "state" in types
    assert types.index("result") < types.index("state")
    result = messages[types.index("result")]
    assert result["results"][0]["path"] == "/api/v1/jobs/{}/result/0".format(job_id)
    assert states(messages)[-1] == "completed"


def test_the_stream_ends_when_the_generation_does(harness) -> None:
    """A finished job has nothing further to say, and the socket says so."""

    job_id, prompt_id = submitted(harness)

    with served(harness.app) as base_url:
        with watching(base_url, job_id) as stream:
            assert stream.next()["type"] == "state"
            harness.fake.complete(prompt_id)
            # drain() returns only when the gateway closed the socket; it
            # asserts otherwise.
            assert states(stream.drain())[-1] == "completed"


def test_a_socket_opened_late_is_told_the_snapshot_not_a_replay(harness) -> None:
    """Reconnect re-establishes truth from the snapshot (`docs/api.md`).

    The job passed through ``running`` before this socket existed.  A gateway
    that kept a per-job event log would replay that; this one does not have
    one, and the client is told where things stand instead of how they got
    there.
    """

    job_id, prompt_id = submitted(harness)
    harness.fake.start_running(prompt_id)
    harness.fake.complete(prompt_id)

    with served(harness.app) as base_url:
        with watching(base_url, job_id) as stream:
            messages = stream.drain()

    assert states(messages) == ["completed"]
    assert [message["type"] for message in messages] == ["result", "state"]


def test_a_failure_crosses_the_socket_through_the_same_scrubber_as_http(
    harness,
) -> None:
    """`docs/api.md`, "What may cross from ComfyUI" -- over a socket this time.

    Not merely "the message is clean": it is asserted to be the *same string*
    the HTTP snapshot carries, because a second scrubber that agreed today
    would be a second thing to keep in agreement forever.
    """

    job_id, prompt_id = submitted(harness)

    with served(harness.app) as base_url:
        with watching(base_url, job_id) as stream:
            assert stream.next()["type"] == "state"
            harness.fake.fail(
                prompt_id,
                "ExampleSampler could not load "
                "C:\\Program Files\\ComfyUI\\models\\sd xl.safetensors",
            )
            messages = stream.drain()
        over_http = snapshot(base_url, job_id)["error"]["message"]

    error = next(message for message in messages if message["type"] == "error")
    assert error["message"] == over_http
    assert "ExampleSampler" not in error["message"]
    for directory in ("C:", "Program Files", "models"):
        assert directory not in error["message"]
    assert "sd xl.safetensors" in error["message"]
    assert states(messages)[-1] == "failed"


def test_the_error_arrives_before_the_state_that_commits_it(harness) -> None:
    job_id, prompt_id = submitted(harness)

    with served(harness.app) as base_url:
        with watching(base_url, job_id) as stream:
            assert stream.next()["type"] == "state"
            harness.fake.fail(prompt_id, "the model file is missing")
            messages = stream.drain()

    types = [message["type"] for message in messages]
    assert types.index("error") < types.index("state")


def test_a_failing_job_sends_exactly_these_messages_and_no_others(harness) -> None:
    """The whole batch, not a sample of it.

    Order and presence leave room for a message nobody asked for: a second
    ``error`` frame, a ``progress`` nobody reported, a state repeated.  This
    endpoint's whole claim is that it says the same thing the snapshot says and
    nothing more, so the set is pinned, not just its interesting members.
    """

    job_id, prompt_id = submitted(harness)

    with served(harness.app) as base_url:
        with watching(base_url, job_id) as stream:
            assert stream.next() == {"type": "state", "state": "queued"}
            harness.fake.start_running(prompt_id)
            assert stream.until("state") == {"type": "state", "state": "running"}
            harness.fake.fail(prompt_id, "the model file is missing")
            messages = stream.drain()
        over_http = snapshot(base_url, job_id)

    assert messages == [
        {"type": "error", "message": over_http["error"]["message"]},
        {"type": "state", "state": "failed"},
    ]


def test_a_completing_job_sends_exactly_these_messages_and_no_others(
    harness,
) -> None:
    job_id, prompt_id = submitted(harness)

    with served(harness.app) as base_url:
        with watching(base_url, job_id) as stream:
            assert stream.next() == {"type": "state", "state": "queued"}
            harness.fake.complete(prompt_id)
            messages = stream.drain()
        over_http = snapshot(base_url, job_id)

    assert messages == [
        {"type": "result", "results": over_http["results"]},
        {"type": "state", "state": "completed"},
    ]


def test_a_socket_for_a_job_this_gateway_never_had_is_refused(harness) -> None:
    """The 404 belongs to the snapshot; the socket just declines.

    `docs/recovery.md` makes ``GET /api/v1/jobs/{id}`` the place a lost job is
    stated, so the stream does not invent a second way to say it -- and in
    particular does not open and then send an ``error``, which is the shape
    reserved for a generation that failed.
    """

    submitted(harness)

    with served(harness.app) as base_url:
        with pytest.raises(Exception):
            with watching(base_url, "j-deadbeef", timeout=5.0):
                pass

        response = httpx.get(base_url + "/api/v1/jobs/j-deadbeef", timeout=10.0)

    assert response.status_code == 404
    assert response.json()["error"]["code"] == "job_not_found"


def test_two_clients_watching_one_job_are_both_told(harness) -> None:
    """A phone and a fold, or a reconnect that overlapped its predecessor."""

    job_id, prompt_id = submitted(harness)

    with served(harness.app) as base_url:
        with watching(base_url, job_id) as first, watching(base_url, job_id) as second:
            assert first.next()["type"] == "state"
            assert second.next()["type"] == "state"
            harness.fake.complete(prompt_id)

            assert states(first.drain())[-1] == "completed"
            assert states(second.drain())[-1] == "completed"


# -- the product without the socket ----------------------------------------


def test_dropping_the_socket_mid_generation_loses_nothing(harness) -> None:
    """The claim the contract makes, tested by breaking the socket.

    The connection is torn down the way a phone leaving Wi-Fi tears one down --
    no close handshake -- while the job is still running.  Everything after
    that comes from ``GET /api/v1/jobs/{id}``: the state, the result list, and
    the bytes themselves.
    """

    job_id, prompt_id = submitted(harness)
    harness.fake.start_running(prompt_id)

    with served(harness.app) as base_url:
        with watching(base_url, job_id) as stream:
            assert stream.next()["type"] == "state"
            stream.abandon()

        harness.fake.complete(prompt_id)

        recovered = snapshot(base_url, job_id)
        assert recovered["state"] == "completed"
        assert recovered["results"], recovered
        bytes_response = httpx.get(
            base_url + recovered["results"][0]["path"], timeout=10.0
        )

    assert bytes_response.status_code == 200
    assert bytes_response.content


def test_a_generation_never_watched_is_fully_recoverable_from_the_snapshot(
    harness,
) -> None:
    """No socket is opened at any point.  Nothing about the outcome differs."""

    job_id, prompt_id = submitted(harness)

    with served(harness.app) as base_url:
        assert snapshot(base_url, job_id)["state"] == "queued"
        harness.fake.start_running(prompt_id)
        assert snapshot(base_url, job_id)["state"] == "running"
        harness.fake.complete(prompt_id)

        recovered = snapshot(base_url, job_id)
        assert recovered["state"] == "completed"
        assert httpx.get(
            base_url + recovered["results"][0]["path"], timeout=10.0
        ).status_code == 200


def test_the_socket_and_the_snapshot_never_disagree(harness) -> None:
    """Whatever the stream last said is what the snapshot says."""

    job_id, prompt_id = submitted(harness)

    with served(harness.app) as base_url:
        with watching(base_url, job_id) as stream:
            assert stream.next()["type"] == "state"
            harness.fake.start_running(prompt_id)
            assert stream.until("state")["state"] == "running"
            assert snapshot(base_url, job_id)["state"] == "running"

            harness.fake.complete(prompt_id)
            last = states(stream.drain())[-1]
            assert last == snapshot(base_url, job_id)["state"]


def test_the_stream_survives_comfyui_having_no_event_socket_at_all(
    gateway_factory, builder
) -> None:
    """The fallback path, isolated: a backend whose ``/ws`` refuses.

    The gateway is pointed at a port nothing listens on for its *event* socket
    by giving it a ComfyUI that never accepts one -- and every state still
    arrives, because the watcher polls the snapshot when nothing wakes it.
    Latency is what the socket buys; correctness is not.
    """

    builder.add("flow", EVERY_FIELD)
    harness = gateway_factory()
    # The fake serves /ws; refusing it here is what makes this the no-socket
    # case rather than a repeat of the tests above.
    harness.state.events.stop()

    job_id = harness.submit("flow", {"prompt": "x"}).json()["job_id"]
    prompt_id = harness.prompt_id

    with served(harness.app) as base_url:
        with watching(base_url, job_id) as stream:
            assert stream.next() == {"type": "state", "state": "queued"}
            harness.fake.start_running(prompt_id)
            assert stream.until("state")["state"] == "running"
            harness.fake.complete(prompt_id)
            assert states(stream.drain())[-1] == "completed"
        # Proof that this really was the no-socket case: had the consumer been
        # running, the fake would have an event connection to show for it.
        assert harness.fake.socket_count == 0


# -- progress --------------------------------------------------------------


def test_progress_stays_null_while_comfyui_reports_none(harness) -> None:
    """The rule that has survived three reviews: nothing is invented.

    The job runs, time passes, the queue reports it as executing -- and none of
    that is a step count.  No ``progress`` message is sent and the snapshot's
    field stays ``null``.
    """

    job_id, prompt_id = submitted(harness)

    with served(harness.app) as base_url:
        with watching(base_url, job_id) as stream:
            assert stream.next()["type"] == "state"
            harness.fake.start_running(prompt_id)
            assert stream.until("state")["state"] == "running"
            assert snapshot(base_url, job_id)["progress"] is None

            harness.fake.complete(prompt_id)
            messages = stream.drain()

        assert snapshot(base_url, job_id)["progress"] is None

    assert [message for message in messages if message["type"] == "progress"] == []


def test_progress_comfyui_actually_reported_reaches_the_socket(harness) -> None:
    """The one source there is: ComfyUI's own event socket.

    The numbers asserted below are the ones the fake put on the wire, so the
    test cannot pass on a value this gateway made up.
    """

    job_id, prompt_id = submitted(harness)

    with served(harness.app) as base_url:
        assert harness.fake.wait_for_socket(10.0)
        harness.fake.start_running(prompt_id)
        with watching(base_url, job_id) as stream:
            assert stream.next()["type"] == "state"
            _emit_until_delivered(harness.fake, prompt_id, 7, 24)

            assert stream.until("progress") == {"type": "progress", "step": 7, "total": 24}
            assert snapshot(base_url, job_id)["progress"] == {"step": 7, "total": 24}


def test_progress_moves_as_comfyui_reports_it(harness) -> None:
    job_id, prompt_id = submitted(harness)

    with served(harness.app) as base_url:
        assert harness.fake.wait_for_socket(10.0)
        harness.fake.start_running(prompt_id)
        with watching(base_url, job_id) as stream:
            assert stream.next()["type"] == "state"
            _emit_until_delivered(harness.fake, prompt_id, 3, 24)
            assert stream.until("progress")["step"] == 3
            harness.fake.emit_progress(prompt_id, 11, 24)
            assert stream.until("progress")["step"] == 11


def test_a_finished_generation_reports_a_result_and_no_progress(harness) -> None:
    """A step count outlives its usefulness the moment the result exists."""

    job_id, prompt_id = submitted(harness)

    with served(harness.app) as base_url:
        assert harness.fake.wait_for_socket(10.0)
        harness.fake.start_running(prompt_id)
        _emit_until_delivered(harness.fake, prompt_id, 12, 24)
        with watching(base_url, job_id) as stream:
            assert stream.until("progress")["step"] == 12
            harness.fake.complete(prompt_id)
            assert states(stream.drain())[-1] == "completed"

        finished = snapshot(base_url, job_id)

    assert finished["progress"] is None
    assert finished["results"]


def _emit_until_delivered(fake, prompt_id: str, value: int, maximum: int) -> None:
    """Send a progress message once the gateway's consumer is actually there.

    ``wait_for_socket`` says a connection was accepted; this waits for the
    frame to have somewhere to go, so the test does not race the listener's
    first read.  Bounded, and it fails loudly rather than passing vacuously.
    """

    deadline = time.monotonic() + 10.0
    while time.monotonic() < deadline:
        if fake.emit_progress(prompt_id, value, maximum):
            return
        time.sleep(0.02)
    raise AssertionError("nothing was attached to ComfyUI's event socket")
