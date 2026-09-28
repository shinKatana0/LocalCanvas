"""The job store: five states, refreshed from ComfyUI, never invented.

Every state change here is driven by the fake backend answering the way real
ComfyUI answers.  The two things the store must never do -- make up a state and
make up progress -- get a test each, because both are failures the app cannot
detect and would render as truth.
"""

from __future__ import annotations

import httpx
import pytest

from localcanvas_gateway.comfy import ComfyClient
from localcanvas_gateway.comfy.fake import FakeComfy
from localcanvas_gateway.jobs import JobState, JobStore

GRAPH = {"20": {"class_type": "FakeNode", "inputs": {"text": "a prompt"}}}

#: Short, so that the "backend went away" test does not wait out a real connect
#: timeout.  The code path is the same one a production timeout takes.
IMPATIENT = httpx.Timeout(connect=0.25, read=0.5, write=0.5, pool=0.5)


@pytest.fixture
def store(fake_comfy: FakeComfy):
    with ComfyClient(fake_comfy.base_url, timeout=IMPATIENT, probe_timeout=IMPATIENT) as comfy:
        yield JobStore(comfy), comfy


def submit(store_and_client, fake: FakeComfy):
    store, comfy = store_and_client
    prompt_id = comfy.submit(GRAPH)
    return store.create(workflow_id="w", prompt_id=prompt_id), prompt_id


def test_the_five_states_are_the_only_states() -> None:
    """`docs/api.md` names five.  A sixth would be a contract change."""

    assert [state.value for state in JobState] == [
        "queued",
        "running",
        "completed",
        "failed",
        "cancelled",
    ]


def test_a_new_job_is_queued_and_carries_an_id_and_a_timestamp(store, fake_comfy):
    job, _ = submit(store, fake_comfy)

    assert job.state is JobState.QUEUED
    assert job.job_id.startswith("j-")
    assert job.created_at.endswith("Z")


def test_two_jobs_do_not_share_an_id(store, fake_comfy):
    first, _ = submit(store, fake_comfy)
    second, _ = submit(store, fake_comfy)

    assert first.job_id != second.job_id


def test_the_lifecycle_follows_comfyui(store, fake_comfy):
    job_store, _ = store
    job, prompt_id = submit(store, fake_comfy)

    assert job_store.snapshot(job.job_id).state is JobState.QUEUED

    fake_comfy.start_running(prompt_id)
    assert job_store.snapshot(job.job_id).state is JobState.RUNNING

    fake_comfy.complete(prompt_id)
    assert job_store.snapshot(job.job_id).state is JobState.COMPLETED


def test_active_count_counts_queued_and_running_and_nothing_else(store, fake_comfy):
    """`api/info.py`'s ``jobs.active`` -- driven through real states, not a stub.

    Five jobs, one in each state: only the two that are not yet over should be
    counted, and each is put there the same way the lifecycle test above puts
    a job in it -- by moving the fake backend and letting the store refresh.
    """

    job_store, _ = store
    queued, _ = submit(store, fake_comfy)

    running, running_prompt = submit(store, fake_comfy)
    fake_comfy.start_running(running_prompt)
    assert job_store.snapshot(running.job_id).state is JobState.RUNNING

    completed, completed_prompt = submit(store, fake_comfy)
    fake_comfy.complete(completed_prompt)
    assert job_store.snapshot(completed.job_id).state is JobState.COMPLETED

    failed, failed_prompt = submit(store, fake_comfy)
    fake_comfy.fail(failed_prompt)
    assert job_store.snapshot(failed.job_id).state is JobState.FAILED

    cancelled, _ = submit(store, fake_comfy)
    assert job_store.cancel(cancelled.job_id).state is JobState.CANCELLED

    assert job_store.active_count() == 2


def test_a_completed_job_carries_its_results(store, fake_comfy):
    job_store, _ = store
    job, prompt_id = submit(store, fake_comfy)
    fake_comfy.complete(
        prompt_id,
        files=[
            {"filename": "a.png", "subfolder": "", "type": "output"},
            {"filename": "b.png", "subfolder": "", "type": "output"},
        ],
    )

    view = job_store.snapshot(job.job_id).to_view()

    assert [result["index"] for result in view["results"]] == [0, 1]
    assert view["results"][0]["kind"] == "image"
    assert view["results"][0]["media_type"] == "image/png"
    assert view["results"][0]["path"] == "/api/v1/jobs/{}/result/0".format(job.job_id)


def test_a_failed_job_carries_a_readable_error_and_no_traceback(store, fake_comfy):
    job_store, _ = store
    job, prompt_id = submit(store, fake_comfy)
    fake_comfy.fail(prompt_id, "the checkpoint could not be loaded")

    view = job_store.snapshot(job.job_id).to_view()

    assert view["state"] == "failed"
    assert view["error"]["message"].startswith("ComfyUI could not finish this generation.")
    assert "the checkpoint could not be loaded" in view["error"]["message"]
    assert "fake traceback line" not in view["error"]["message"]
    assert view["results"] == []


# -- what may cross from ComfyUI (`docs/api.md`) ---------------------------


def test_no_directory_crosses_but_the_filename_does(store, fake_comfy):
    """`docs/api.md`: no directory component ever crosses; a bare filename may.

    The filename is the part a user can act on -- it says *which* model is
    missing.  Where it sits on their disk is nobody's business on a phone.
    """

    job_store, _ = store
    job, prompt_id = submit(store, fake_comfy)
    fake_comfy.fail(
        prompt_id,
        "Value not in list: ckpt_name: 'D:/AI/models/checkpoints/sd_xl.safetensors' "
        "not in ['a.safetensors']",
    )

    message = job_store.snapshot(job.job_id).to_view()["error"]["message"]

    assert "sd_xl.safetensors" in message  # actionable: which file
    for directory in ("D:", "AI", "models", "checkpoints"):
        assert directory not in message
    assert ":/" not in message
    assert message.startswith("ComfyUI could not finish this generation.")


#: ``directories`` lists the components **one at a time**, never joined: a rule
#: that keeps only the last component fails by leaving *one* directory word
#: behind, and asserting the absence of ``"Program Files"`` would not notice
#: ``"Program"`` on its own.
@pytest.mark.parametrize(
    "raw, filename, directories",
    [
        (
            # The shape docs/api.md names, because it is the likely one on
            # Windows: a rooted path whose directories contain spaces, and
            # whose filename does too.
            "cannot open C:\\Program Files\\StableTools\\models\\sd xl.safetensors",
            "sd xl.safetensors",
            ("C:", "Program", "Files", "StableTools", "models"),
        ),
        ("cannot open D:\\models\\sd.safetensors", "sd.safetensors", ("D:", "models")),
        (
            "cannot open C:/Users/someone/models/sd.ckpt",
            "sd.ckpt",
            ("C:", "Users", "someone", "models"),
        ),
        (
            "cannot open /home/someone/models/sd.ckpt",
            "sd.ckpt",
            ("home", "someone", "models"),
        ),
        ("cannot open \\\\nas\\models\\sd.ckpt", "sd.ckpt", ("nas", "models")),
        (
            "cannot open models/checkpoints/sd.ckpt",
            "sd.ckpt",
            ("models", "checkpoints"),
        ),
        (
            # A space in a *directory* on a rooted POSIX path.
            "cannot open /srv/my models/checkpoints/sd.ckpt",
            "sd.ckpt",
            ("srv", "my", "models", "checkpoints"),
        ),
    ],
)
def test_no_shape_of_path_survives(store, fake_comfy, raw, filename, directories):
    job_store, _ = store
    job, prompt_id = submit(store, fake_comfy)
    fake_comfy.fail(prompt_id, raw)

    message = job_store.snapshot(job.job_id).to_view()["error"]["message"]

    assert "\\" not in message
    assert "/" not in message
    for directory in directories:
        assert directory not in message, message
    assert filename in message, message
    assert "cannot open" in message  # the readable part is kept


def test_a_stack_trace_inside_the_exception_message_contributes_nothing(
    store, fake_comfy
):
    """A custom node re-raising with ``format_exc()`` puts the trace here.

    The ``traceback`` field being ignored does not help, and half a trace with
    its paths stripped is no improvement on a whole one.
    """

    job_store, _ = store
    job, prompt_id = submit(store, fake_comfy)
    fake_comfy.fail(
        prompt_id,
        'Traceback (most recent call last):\n'
        '  File "C:\\Program Files\\ComfyUI\\custom_nodes\\thing.py", line 3, in load\n'
        "    raise RuntimeError('boom')\n"
        "RuntimeError: boom",
    )

    message = job_store.snapshot(job.job_id).to_view()["error"]["message"]

    assert message == "ComfyUI could not finish this generation."
    assert "Traceback" not in message
    assert "File" not in message
    assert "line 3" not in message


def test_a_trace_that_lost_its_header_is_still_a_trace(store, fake_comfy):
    job_store, _ = store
    job, prompt_id = submit(store, fake_comfy)
    fake_comfy.fail(prompt_id, 'boom in File "nodes.py", line 71, in execute')

    message = job_store.snapshot(job.job_id).to_view()["error"]["message"]

    assert message == "ComfyUI could not finish this generation."


def test_a_header_less_frame_carrying_a_full_path_is_still_a_trace(
    store, fake_comfy
):
    """A frame whose path is scrubbed away is still a frame, not a reason.

    The guard reads the **raw** message rather than the scrubbed one. On
    today's inputs the two agree -- scrubbing replaces the path *inside* the
    quotes and leaves the ``File "..." , line N`` shape intact -- so this test
    does not prove the ordering, and no test here claims to. Reading the raw
    text is the safer of two equal options: it cannot be defeated by a later
    change to the scrubber.
    """

    job_store, _ = store
    job, prompt_id = submit(store, fake_comfy)
    fake_comfy.fail(
        prompt_id, 'boom in File "C:\\Program Files\\StableTools\\nodes.py", line 71'
    )

    message = job_store.snapshot(job.job_id).to_view()["error"]["message"]

    assert message == "ComfyUI could not finish this generation."
    assert "File" not in message
    assert "line 71" not in message


def test_a_node_class_is_stripped_whatever_its_case(store, fake_comfy):
    """ComfyUI writes ``KSampler``; a custom node's message may write ``ksampler``."""

    job_store, _ = store
    prompt_id = store[1].submit(GRAPH)
    job = job_store.create(workflow_id="w", prompt_id=prompt_id, node_types={"KSampler"})
    fake_comfy.fail(prompt_id, "ksampler received an empty latent")

    message = job_store.snapshot(job.job_id).to_view()["error"]["message"]

    assert "ksampler" not in message.lower()
    assert "received an empty latent" in message


def test_a_node_type_never_crosses_even_when_comfyui_names_it(store, fake_comfy):
    """"No node type in any response" is a rule, and an error body is a response."""

    job_store, _ = store
    prompt_id = store[1].submit(GRAPH)
    job = job_store.create(
        workflow_id="w", prompt_id=prompt_id, node_types={"FakeNode", "ExampleSampler"}
    )
    fake_comfy.fail(prompt_id, "ExampleSampler expected a latent, FakeNode gave nothing")

    message = job_store.snapshot(job.job_id).to_view()["error"]["message"]

    assert "FakeNode" not in message
    assert "ExampleSampler" not in message
    assert "expected a latent" in message


def test_a_message_that_was_only_a_directory_leaves_no_dangling_punctuation(
    store, fake_comfy
):
    """Nothing readable survives, so nothing is appended -- not an empty clause."""

    job_store, _ = store
    job, prompt_id = submit(store, fake_comfy)
    fake_comfy.fail(prompt_id, "D:/AI/models/checkpoints/")

    message = job_store.snapshot(job.job_id).to_view()["error"]["message"]

    assert message == "ComfyUI could not finish this generation."


def test_the_reason_is_bounded(store, fake_comfy):
    job_store, _ = store
    job, prompt_id = submit(store, fake_comfy)
    fake_comfy.fail(prompt_id, "overflowing " * 200)

    message = job_store.snapshot(job.job_id).to_view()["error"]["message"]

    assert len(message) < 300
    assert message.endswith("…")


def test_comfyuis_whole_account_goes_to_the_pc_log(store, fake_comfy, caplog):
    """Nothing is discarded -- it goes where someone can act on it."""

    job_store, _ = store
    job, prompt_id = submit(store, fake_comfy)
    fake_comfy.fail(prompt_id, "D:/AI/models/sd_xl.safetensors not found")

    with caplog.at_level("WARNING", logger="localcanvas_gateway.jobs"):
        job_store.snapshot(job.job_id)

    assert "D:/AI/models/sd_xl.safetensors" in caplog.text
    assert "FakeNode" in caplog.text


def test_a_terminal_job_is_never_reopened(store, fake_comfy):
    """Completed is a decision, not a poll result that can flip back."""

    job_store, _ = store
    job, prompt_id = submit(store, fake_comfy)
    fake_comfy.complete(prompt_id)
    assert job_store.snapshot(job.job_id).state is JobState.COMPLETED

    fake_comfy.fail(prompt_id, "later trouble")

    assert job_store.snapshot(job.job_id).state is JobState.COMPLETED


def test_progress_is_null_because_none_is_reported(store, fake_comfy):
    """ComfyUI reports progress on its WebSocket, not over HTTP.

    Nothing over this gateway's HTTP path to ComfyUI carries a step count, so
    the honest answer here is ``null`` -- and nothing derives a percentage from
    elapsed time or from a queue position.
    """

    job_store, _ = store
    job, prompt_id = submit(store, fake_comfy)
    fake_comfy.start_running(prompt_id)

    view = job_store.snapshot(job.job_id).to_view()

    assert view["state"] == "running"
    assert "progress" in view
    assert view["progress"] is None


def test_progress_reported_for_this_prompt_is_recorded_as_reported(
    store, fake_comfy
):
    """The one door progress comes through, and it takes what it was given."""

    job_store, _ = store
    job, prompt_id = submit(store, fake_comfy)
    fake_comfy.start_running(prompt_id)

    job_store.note_progress(prompt_id, 7, 24)

    assert job_store.snapshot(job.job_id).to_view()["progress"] == {
        "step": 7,
        "total": 24,
    }


def test_progress_for_a_prompt_this_gateway_did_not_submit_is_ignored(
    store, fake_comfy
):
    """ComfyUI broadcasts some of its messages.

    Another client's generation is not this one's, and attaching its step count
    to a job here would be a number about the wrong work.
    """

    job_store, _ = store
    job, prompt_id = submit(store, fake_comfy)
    fake_comfy.start_running(prompt_id)

    job_store.note_progress("some-other-clients-prompt", 7, 24)

    assert job_store.snapshot(job.job_id).to_view()["progress"] is None


def test_a_finished_job_does_not_go_on_reporting_progress(store, fake_comfy):
    """A step count of a generation that is over is not a fact about anything.

    It also cannot be a *late* fact: once ``/history`` has spoken the job is
    terminal, and a message that arrives afterwards changes nothing.
    """

    job_store, _ = store
    job, prompt_id = submit(store, fake_comfy)
    fake_comfy.start_running(prompt_id)
    job_store.note_progress(prompt_id, 7, 24)
    fake_comfy.complete(prompt_id)
    assert job_store.snapshot(job.job_id).state is JobState.COMPLETED

    job_store.note_progress(prompt_id, 23, 24)

    view = job_store.snapshot(job.job_id).to_view()
    assert view["progress"] is None
    assert view["results"]


def test_an_interrupted_prompt_is_cancelled_and_not_failed(store, fake_comfy):
    """ComfyUI files both under ``status_str == "error"``; they are not one.

    A cancelled generation reaches the phone as cancelled, with no error
    message invented for it (`docs/recovery.md`).
    """

    job_store, _ = store
    job, prompt_id = submit(store, fake_comfy)
    fake_comfy.start_running(prompt_id)
    fake_comfy.interrupt_prompt(prompt_id)

    view = job_store.snapshot(job.job_id).to_view()

    assert view["state"] == "cancelled"
    assert view["error"] is None
    assert view["results"] == []


def test_a_watcher_is_woken_by_a_change_and_not_by_activity(store, fake_comfy):
    """The event stream waits on this, so an unchanged refresh must not wake it.

    A version that moved on every poll would turn every watcher into a busy
    loop resending what it already sent.
    """

    job_store, _ = store
    job, prompt_id = submit(store, fake_comfy)
    version, view = job_store.published(job.job_id)
    assert view["state"] == "queued"

    job_store.snapshot(job.job_id)
    assert job_store.published(job.job_id)[0] == version

    fake_comfy.start_running(prompt_id)
    job_store.snapshot(job.job_id)
    moved, view = job_store.published(job.job_id)

    assert moved > version
    assert view["state"] == "running"


def test_waiting_for_a_change_that_does_not_come_times_out_and_says_so(
    store, fake_comfy
):
    """A timeout is the watcher's cue to poll, so it must be distinguishable."""

    job_store, _ = store
    job, _ = submit(store, fake_comfy)
    version, _ = job_store.published(job.job_id)

    assert job_store.wait_for_change(job.job_id, version, 0.05) == version


def test_an_unknown_job_id_is_not_a_job(store, fake_comfy):
    job_store, _ = store

    assert job_store.snapshot("j-nosuchid") is None
    assert job_store.get("j-nosuchid") is None


def test_a_backend_that_stopped_answering_leaves_the_state_alone(store, fake_comfy):
    """No state is invented from silence.

    The last state that was actually observed is what the app is told; the
    reason it could not be refreshed is logged on the PC.
    """

    job_store, _ = store
    job, prompt_id = submit(store, fake_comfy)
    fake_comfy.start_running(prompt_id)
    assert job_store.snapshot(job.job_id).state is JobState.RUNNING

    fake_comfy.stop()

    refreshed = job_store.snapshot(job.job_id)
    assert refreshed.state is JobState.RUNNING
    assert refreshed.error is None


def test_a_malformed_history_does_not_move_the_job(store, fake_comfy):
    job_store, _ = store
    job, prompt_id = submit(store, fake_comfy)
    fake_comfy.start_running(prompt_id)
    job_store.snapshot(job.job_id)

    fake_comfy.malformed_history = True

    assert job_store.snapshot(job.job_id).state is JobState.RUNNING


def test_the_snapshot_has_exactly_the_documented_keys(store, fake_comfy):
    job_store, _ = store
    job, _ = submit(store, fake_comfy)

    assert set(job_store.snapshot(job.job_id).to_view()) == {
        "job_id",
        "workflow_id",
        "state",
        "progress",
        "results",
        "error",
    }


def test_a_result_path_is_relative_and_names_no_host(store, fake_comfy):
    job_store, _ = store
    job, prompt_id = submit(store, fake_comfy)
    fake_comfy.complete(prompt_id)

    path = job_store.snapshot(job.job_id).to_view()["results"][0]["path"]

    assert path.startswith("/api/v1/")
    assert "://" not in path


def test_a_result_view_never_names_a_comfyui_file(store, fake_comfy):
    """The output filename is ComfyUI's business and stops at the gateway."""

    job_store, _ = store
    job, prompt_id = submit(store, fake_comfy)
    fake_comfy.complete(
        prompt_id,
        files=[
            {"filename": "secret_name.png", "subfolder": "private_folder", "type": "output"}
        ],
    )

    view = job_store.snapshot(job.job_id).to_view()

    assert "secret_name" not in repr(view)
    assert "private_folder" not in repr(view)
    # ...while the gateway still knows it, or it could not fetch the bytes.
    assert job_store.get(job.job_id).results[0].output.filename == "secret_name.png"
