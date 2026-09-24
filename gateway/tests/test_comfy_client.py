"""The ComfyUI client, against the fake ComfyUI over a real socket.

Nothing here is monkeypatched: the client opens a TCP connection, writes an HTTP
request and parses the bytes that come back, exactly as it does against the real
backend.  What is being verified is that the client understands **ComfyUI's**
shapes -- ``/prompt``'s ``prompt_id``, ``/history``'s status block and node-keyed
outputs, ``/queue``'s positional entries -- and not a shape invented here.
"""

from __future__ import annotations

import socket
from contextlib import contextmanager

import httpx
import pytest

from conftest import IMPATIENT, FakeClock
from localcanvas_gateway.comfy import (
    READY_TTL_SECONDS,
    ComfyClient,
    ComfyError,
    ComfyStatus,
    ComfySubmitRejected,
    OutputFile,
)
from localcanvas_gateway.comfy.fake import ONE_PIXEL_PNG, FakeComfy

GRAPH = {"20": {"class_type": "FakeNode", "inputs": {"text": "a prompt"}}}


@contextmanager
def nothing_serving():
    """An endpoint whose port is bound but never listening: connection refused.

    Holding the socket keeps the port from being handed to something else while
    the test runs, so what is measured is a refusal and not a race.
    """

    held = socket.socket()
    held.bind(("127.0.0.1", 0))
    try:
        yield "http://127.0.0.1:{}".format(held.getsockname()[1])
    finally:
        held.close()


@contextmanager
def unreachable_client():
    with nothing_serving() as base_url:
        with ComfyClient(base_url, timeout=IMPATIENT, probe_timeout=IMPATIENT) as comfy:
            yield comfy


@pytest.fixture
def client(fake_comfy: FakeComfy):
    with ComfyClient(fake_comfy.base_url) as comfy:
        yield comfy


# -- readiness -------------------------------------------------------------


def test_ready_when_object_info_answers(client: ComfyClient) -> None:
    health = client.health()

    assert health.status is ComfyStatus.READY
    assert health.detail is None


def test_unavailable_when_nothing_is_listening() -> None:
    with unreachable_client() as comfy:
        health = comfy.health()

    assert health.status is ComfyStatus.UNAVAILABLE
    assert health.detail == "ComfyUI is not running."


def test_starting_while_the_node_catalogue_is_not_built_yet(
    client: ComfyClient, fake_comfy: FakeComfy
) -> None:
    """The probe's whole justification, in one test.

    ``/system_stats`` answers -- the process is alive and serving HTTP -- while
    ``/object_info`` does not, because nodes are still loading.  A probe that
    took liveness for readiness would call this ``ready`` and a prompt
    submitted now would fail.
    """

    fake_comfy.ready = False

    assert httpx.get(fake_comfy.base_url + "/system_stats").status_code == 200
    assert client.health().status is ComfyStatus.STARTING


def test_slow_readiness_becomes_ready_without_a_sleep(
    client: ComfyClient, fake_comfy: FakeComfy
) -> None:
    fake_comfy.ready_after_probes = 2

    assert client.health().status is ComfyStatus.STARTING
    assert client.health().status is ComfyStatus.STARTING
    assert client.health().status is ComfyStatus.READY


def test_a_never_ready_backend_never_becomes_ready(
    client: ComfyClient, fake_comfy: FakeComfy
) -> None:
    fake_comfy.ready = False

    assert [client.health().status for _ in range(3)] == [ComfyStatus.STARTING] * 3


def test_the_probe_endpoint_is_object_info(
    client: ComfyClient, fake_comfy: FakeComfy
) -> None:
    before = fake_comfy.probe_count
    client.health()

    assert fake_comfy.probe_count == before + 1


def test_a_ready_answer_stands_for_the_ttl_even_if_comfyui_goes(
    fake_comfy: FakeComfy,
) -> None:
    """The cost of caching, stated plainly rather than left as a surprise.

    Producing ``/object_info`` is expensive for ComfyUI, so a ``ready`` answer
    is reused for :data:`READY_TTL_SECONDS`.  Inside that window the gateway
    reports what it last saw -- which is the bound on how quickly ComfyUI
    disappearing is noticed.
    """

    clock = FakeClock()
    with ComfyClient(
        fake_comfy.base_url, timeout=IMPATIENT, probe_timeout=IMPATIENT, clock=clock
    ) as comfy:
        assert comfy.health().status is ComfyStatus.READY
        fake_comfy.stop()

        assert comfy.health().status is ComfyStatus.READY  # still inside the TTL

        clock.advance(READY_TTL_SECONDS + 0.1)
        assert comfy.health().status is ComfyStatus.UNAVAILABLE


def test_health_never_names_the_backend_endpoint_to_the_caller(
    fake_comfy: FakeComfy,
) -> None:
    """``comfy.detail`` reaches the phone; ComfyUI's localhost URL must not."""

    with unreachable_client() as comfy:
        health = comfy.health()

    assert "http" not in (health.detail or "")
    assert "http" in (health.log_detail or "")


# -- submission ------------------------------------------------------------


def test_submit_sends_the_graph_and_the_client_id(
    client: ComfyClient, fake_comfy: FakeComfy
) -> None:
    prompt_id = client.submit(GRAPH)

    submission = fake_comfy.submissions[0]
    assert submission["prompt_id"] == prompt_id
    assert submission["prompt"] == GRAPH
    assert submission["client_id"] == client.client_id


def test_a_rejected_prompt_raises_with_comfyui_own_words(
    client: ComfyClient, fake_comfy: FakeComfy
) -> None:
    fake_comfy.reject_prompt = "Value not in list: ckpt_name"

    with pytest.raises(ComfySubmitRejected) as raised:
        client.submit(GRAPH)

    assert "Value not in list: ckpt_name" in str(raised.value)
    assert raised.value.node_errors  # ComfyUI attributes it to a node


def test_an_unreachable_backend_raises_rather_than_returning_a_fake_id() -> None:
    with unreachable_client() as comfy:
        with pytest.raises(ComfyError):
            comfy.submit(GRAPH)


# -- tracking --------------------------------------------------------------


def test_history_is_absent_until_the_prompt_finishes(
    client: ComfyClient, fake_comfy: FakeComfy
) -> None:
    prompt_id = client.submit(GRAPH)

    assert client.history(prompt_id).found is False

    fake_comfy.complete(prompt_id)
    assert client.history(prompt_id).found is True


def test_a_completed_history_entry_carries_the_output_files(
    client: ComfyClient, fake_comfy: FakeComfy
) -> None:
    prompt_id = client.submit(GRAPH)
    fake_comfy.complete(
        prompt_id,
        files=[{"filename": "out_00001_.png", "subfolder": "runs", "type": "output"}],
    )

    entry = client.history(prompt_id)

    assert entry.finished is True
    assert entry.failed is False
    assert entry.outputs == (
        OutputFile(filename="out_00001_.png", subfolder="runs", type="output", kind="image"),
    )


def test_a_failed_history_entry_carries_what_comfyui_said(
    client: ComfyClient, fake_comfy: FakeComfy
) -> None:
    """Raw, and with the node it came from -- this is log material, not a message."""

    prompt_id = client.submit(GRAPH)
    fake_comfy.fail(prompt_id, "CheckpointLoaderSimple: file not found")

    entry = client.history(prompt_id)

    assert entry.failed is True
    assert entry.finished is False
    assert entry.error.message == "CheckpointLoaderSimple: file not found"
    assert entry.error.exception_type == "RuntimeError"
    assert entry.error.node_id == "40"
    assert entry.error.node_type == "FakeNode"


def test_the_log_line_carries_everything_comfyui_reported(
    client: ComfyClient, fake_comfy: FakeComfy
) -> None:
    """The PC log is where the detail belongs, so nothing is dropped on the way."""

    prompt_id = client.submit(GRAPH)
    fake_comfy.fail(prompt_id, "D:/models/sd.safetensors not found")

    line = client.history(prompt_id).error.for_log()

    assert "D:/models/sd.safetensors" in line
    assert "FakeNode" in line
    assert "40" in line


def test_a_video_output_is_recognized_as_a_video(
    client: ComfyClient, fake_comfy: FakeComfy
) -> None:
    prompt_id = client.submit(GRAPH)
    fake_comfy.complete(
        prompt_id,
        output_key="gifs",
        files=[{"filename": "clip_00001_.mp4", "subfolder": "", "type": "output"}],
    )

    output = client.history(prompt_id).outputs[0]

    assert output.kind == "video"
    assert output.media_type == "video/mp4"


def test_an_older_history_entry_without_a_status_block_still_reads(
    client: ComfyClient, fake_comfy: FakeComfy
) -> None:
    """Older ComfyUI writes no ``status``; the outputs are then the evidence.

    ComfyUI only writes a history entry with outputs for a prompt that ran, so
    treating that as success is reading the backend rather than guessing.
    """

    fake_comfy.omit_history_status = True
    prompt_id = client.submit(GRAPH)
    fake_comfy.complete(prompt_id)

    entry = client.history(prompt_id)

    assert entry.found is True
    assert entry.finished is True
    assert entry.failed is False
    assert len(entry.outputs) == 1


def test_a_malformed_history_body_is_an_error_not_a_guess(
    client: ComfyClient, fake_comfy: FakeComfy
) -> None:
    prompt_id = client.submit(GRAPH)
    fake_comfy.malformed_history = True

    with pytest.raises(ComfyError):
        client.history(prompt_id)


def test_queue_place_follows_the_prompt(
    client: ComfyClient, fake_comfy: FakeComfy
) -> None:
    from localcanvas_gateway.comfy import QueuePlace

    prompt_id = client.submit(GRAPH)
    assert client.queue_place(prompt_id) is QueuePlace.PENDING

    fake_comfy.start_running(prompt_id)
    assert client.queue_place(prompt_id) is QueuePlace.RUNNING

    fake_comfy.complete(prompt_id)
    assert client.queue_place(prompt_id) is QueuePlace.ABSENT


def test_an_unknown_prompt_is_absent_from_the_queue(client: ComfyClient) -> None:
    from localcanvas_gateway.comfy import QueuePlace

    assert client.queue_place("never-submitted") is QueuePlace.ABSENT


# -- results ---------------------------------------------------------------


def test_view_returns_the_bytes_and_a_media_type(
    client: ComfyClient, fake_comfy: FakeComfy
) -> None:
    prompt_id = client.submit(GRAPH)
    fake_comfy.complete(prompt_id)
    output = client.history(prompt_id).outputs[0]

    with client.open_view(output) as stream:
        data = b"".join(stream.chunks())

    assert data == ONE_PIXEL_PNG
    assert stream.media_type == "image/png"


def test_view_asks_for_the_file_comfyui_named(
    client: ComfyClient, fake_comfy: FakeComfy
) -> None:
    prompt_id = client.submit(GRAPH)
    fake_comfy.complete(
        prompt_id,
        files=[{"filename": "picture.png", "subfolder": "day one", "type": "temp"}],
    )
    client.open_view(client.history(prompt_id).outputs[0]).close()

    assert fake_comfy.view_requests[-1] == {
        "filename": "picture.png",
        "subfolder": "day one",
        "type": "temp",
    }


def test_a_missing_output_file_is_an_error(client: ComfyClient) -> None:
    with pytest.raises(ComfyError):
        client.open_view(OutputFile("gone.png", "", "output", "image"))


@pytest.mark.parametrize(
    "served, expected",
    [
        ("image/webp", "image/webp"),  # a medium this API serves: honoured
        ("video/webm", "video/webm"),
        ("application/octet-stream", "image/png"),  # generic: the filename wins
        ("text/html", "image/png"),  # never handed to a phone as markup
        ("", "image/png"),
    ],
)
def test_view_only_honours_a_content_type_it_would_serve(
    client: ComfyClient, fake_comfy: FakeComfy, served: str, expected: str
) -> None:
    """ComfyUI names the medium; it does not get to choose what a phone renders."""

    fake_comfy.put_file("picture.png", b"bytes", content_type=served)

    with client.open_view(OutputFile("picture.png", "", "output", "image")) as stream:
        media_type = stream.media_type

    assert media_type == expected


# -- input files -----------------------------------------------------------
#
# The gateway gets an uploaded picture to where a loader node can read it by
# handing it to ComfyUI over HTTP.  It never writes into ComfyUI's input
# directory, because it does not know where that is and must not learn
# (`docs/architecture.md`).


def test_an_input_upload_reaches_comfyui_with_its_bytes(
    client: ComfyClient, fake_comfy: FakeComfy, tmp_path
) -> None:
    source = tmp_path / "m-3f9c1a.png"
    source.write_bytes(ONE_PIXEL_PNG)

    uploaded = client.upload_input(
        path=source, filename="localcanvas_m-3f9c1a.png", content_type="image/png"
    )

    assert uploaded.name == "localcanvas_m-3f9c1a.png"
    assert uploaded.type == "input"
    assert fake_comfy.uploads[-1]["bytes"] == len(ONE_PIXEL_PNG)
    assert fake_comfy.uploads[-1]["content_type"] == "image/png"
    # And it is readable back from ComfyUI as an input file, which is what a
    # loader node will do with it.
    with client.open_view(
        OutputFile(uploaded.name, "", "input", "image")
    ) as stream:
        assert b"".join(stream.chunks()) == ONE_PIXEL_PNG


def test_the_uploaded_file_is_addressed_by_the_name_comfyui_answered_with(
    client: ComfyClient, fake_comfy: FakeComfy, tmp_path
) -> None:
    """ComfyUI renames rather than clobbering, and the client believes it.

    A client that assumed the name it sent would address whatever file was
    already sitting there under it.
    """

    fake_comfy.put_file("picture.png", b"someone else's picture", type="input")
    source = tmp_path / "upload.png"
    source.write_bytes(ONE_PIXEL_PNG)

    uploaded = client.upload_input(
        path=source, filename="picture.png", content_type="image/png"
    )

    assert uploaded.name != "picture.png"
    assert uploaded.reference == uploaded.name


def test_a_reference_carries_the_subfolder_comfyui_reported(
    client: ComfyClient, fake_comfy: FakeComfy, tmp_path
) -> None:
    """The only composition the gateway does, and both halves are ComfyUI's."""

    from localcanvas_gateway.comfy import UploadedInput

    assert UploadedInput("clip.mp4", "", "input").reference == "clip.mp4"
    assert UploadedInput("clip.mp4", "sub", "input").reference == "sub/clip.mp4"


def test_an_upload_comfyui_refuses_is_an_error_not_a_silent_success(
    client: ComfyClient, fake_comfy: FakeComfy, tmp_path
) -> None:
    fake_comfy.reject_upload = 500
    source = tmp_path / "upload.png"
    source.write_bytes(ONE_PIXEL_PNG)

    with pytest.raises(ComfyError) as error:
        client.upload_input(
            path=source, filename="picture.png", content_type="image/png"
        )

    # The log gets what ComfyUI actually answered; a client that read the body
    # of a refusal as if it were an answer would report something else.
    assert "500" in str(error.value)


def test_an_upload_of_a_file_that_is_gone_is_an_error(
    client: ComfyClient, tmp_path
) -> None:
    """A reaped media file must not become a traceback out of httpx."""

    with pytest.raises(ComfyError):
        client.upload_input(
            path=tmp_path / "never-written.png",
            filename="picture.png",
            content_type="image/png",
        )
