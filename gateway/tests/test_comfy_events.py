"""Reading ComfyUI's event socket -- and refusing to read more than it says.

This consumer exists for one number that no HTTP endpoint carries: the step
count in a ``progress`` message.  So the tests that matter most here are the
ones about what it declines to do with everything else -- it never turns a
message into a state, never builds a failure message out of ``execution_error``,
and never lets an unusable pair of numbers become progress.

The consumer is driven two ways.  Message handling is exercised directly
against :meth:`ComfyEvents.handle`, which is what a frame becomes; connection
behaviour is exercised against the in-package fake's real WebSocket, over a
real socket.
"""

from __future__ import annotations

import json
import threading
import time
from typing import Any, List, Tuple

import pytest

from localcanvas_gateway.comfy import ComfyClient, ComfyEvents


class RecordingSink:
    """A job store's two event-facing methods, and nothing else."""

    def __init__(self) -> None:
        self.progress: List[Tuple[str, int, int]] = []
        self.changes: List[str] = []
        self.arrived = threading.Event()

    def note_progress(self, prompt_id: str, step: int, total: int) -> None:
        self.progress.append((prompt_id, step, total))
        self.arrived.set()

    def note_change(self, prompt_id: str) -> None:
        self.changes.append(prompt_id)
        self.arrived.set()


def frame(type_: str, **data: Any) -> str:
    return json.dumps({"type": type_, "data": data})


@pytest.fixture
def consumer():
    sink = RecordingSink()
    return ComfyEvents("ws://unused/ws", sink), sink


# -- what it takes -----------------------------------------------------------


def test_a_reported_step_count_is_passed_on_as_reported(consumer) -> None:
    events, sink = consumer

    events.handle(frame("progress", value=7, max=24, prompt_id="p-1", node="30"))

    assert sink.progress == [("p-1", 7, 24)]


def test_progress_with_no_prompt_id_belongs_to_the_prompt_comfyui_named(
    consumer,
) -> None:
    """Older builds omit ``prompt_id``, and ComfyUI runs one prompt at a time.

    The attribution is read out of ComfyUI's own ``executing`` message rather
    than guessed at, and with no such message there is nothing to attribute to
    and the numbers are dropped.
    """

    events, sink = consumer

    events.handle(frame("progress", value=1, max=10))
    assert sink.progress == []

    events.handle(frame("executing", prompt_id="p-1", node="30"))
    events.handle(frame("progress", value=1, max=10))

    assert sink.progress == [("p-1", 1, 10)]


@pytest.mark.parametrize(
    "data",
    [
        {"value": 7},  # no total
        {"max": 24},  # no step
        {"value": 7, "max": 0},  # nothing to be seven of
        {"value": 7, "max": -1},
        {"value": 30, "max": 24},  # past the end
        {"value": -1, "max": 24},
        {"value": "7", "max": "24"},  # not numbers
        {"value": True, "max": 24},  # a bool is not a step count
    ],
)
def test_numbers_that_do_not_describe_a_position_are_not_progress(
    consumer, data
) -> None:
    """`docs/api.md`: no fabricated progress -- including no repaired progress.

    A message this gateway cannot read is not turned into a plausible-looking
    one.  ``null`` is the documented answer for "no real progress", and it is
    also the honest answer for "ComfyUI said something unusable".
    """

    events, sink = consumer

    events.handle(frame("progress", prompt_id="p-1", **data))

    assert sink.progress == []


def test_the_end_of_execution_triggers_a_re_read_and_asserts_no_state(
    consumer,
) -> None:
    """Every lifecycle message is a nudge, never an outcome.

    ``execution_success`` is ComfyUI stating the result, and this consumer
    still does not record one: it says "go and look", and ``/history`` is what
    answers.  That is what keeps a single path from ComfyUI's words to the
    phone.
    """

    events, sink = consumer

    events.handle(frame("execution_success", prompt_id="p-1"))

    assert sink.changes == ["p-1"]
    assert sink.progress == []


def test_a_failure_message_is_a_nudge_and_never_a_message_to_the_user(
    consumer,
) -> None:
    """``execution_error`` carries the same exception text ``/history`` does.

    If this consumer passed that text on, there would be a second route from a
    model path on someone's PC to a phone, and only one of the two would go
    through the scrubber in ``jobs.py``.  So it carries nothing but the fact
    that something happened.
    """

    events, sink = consumer

    events.handle(
        frame(
            "execution_error",
            prompt_id="p-1",
            node_id="40",
            node_type="ExampleSampler",
            exception_message="could not load D:/models/secret.safetensors",
        )
    )

    assert sink.changes == ["p-1"]


def test_the_last_node_of_a_prompt_triggers_a_re_read(consumer) -> None:
    """``executing`` with a null node is ComfyUI running out of work."""

    events, sink = consumer

    events.handle(frame("executing", prompt_id="p-1", node="30"))
    assert sink.changes == []

    events.handle(frame("executing", prompt_id="p-1", node=None))
    assert sink.changes == ["p-1"]


# -- what it ignores ---------------------------------------------------------


def test_a_binary_preview_frame_is_dropped(consumer) -> None:
    """ComfyUI sends partially denoised images down this socket.

    `docs/api.md` has no preview surface, and half-supporting one would mean
    deciding what a phone does with an image that is not a result.
    """

    events, sink = consumer

    events.handle(b"\x00\x01\x02not json at all")

    assert sink.progress == [] and sink.changes == []


@pytest.mark.parametrize(
    "message",
    ["not json", "[]", '"a string"', "null", '{"type": "status", "data": {}}'],
)
def test_a_frame_this_gateway_cannot_read_changes_nothing(consumer, message) -> None:
    events, sink = consumer

    events.handle(message)

    assert sink.progress == [] and sink.changes == []


def test_a_lifecycle_message_with_no_prompt_id_names_nothing(consumer) -> None:
    events, sink = consumer

    events.handle(frame("execution_success"))

    assert sink.changes == []


# -- the connection ----------------------------------------------------------


def test_the_consumer_reads_a_real_socket_from_a_real_comfyui(fake_comfy) -> None:
    """End to end over the fake's own WebSocket, no stubbing anywhere."""

    sink = RecordingSink()
    client = ComfyClient(fake_comfy.base_url)
    events = ComfyEvents(client.events_url, sink).start()
    try:
        assert events.wait_until_connected(10.0)
        assert fake_comfy.wait_for_socket(10.0)
        _emit_until_delivered(fake_comfy, "p-1", 5, 20)
        assert sink.arrived.wait(10.0)
    finally:
        events.stop()
        client.close()

    assert ("p-1", 5, 20) in sink.progress


def test_the_consumer_gives_up_the_socket_when_it_is_stopped(fake_comfy) -> None:
    sink = RecordingSink()
    client = ComfyClient(fake_comfy.base_url)
    events = ComfyEvents(client.events_url, sink).start()
    try:
        assert events.wait_until_connected(10.0)
        assert fake_comfy.wait_for_socket(10.0)
    finally:
        events.stop()
        client.close()

    deadline = time.monotonic() + 5.0
    while fake_comfy.socket_count and time.monotonic() < deadline:
        time.sleep(0.02)
    assert fake_comfy.socket_count == 0
    assert not events.connected


def test_a_backend_with_no_event_socket_is_a_local_matter(fake_comfy) -> None:
    """Nothing fails, nothing raises, and no job is affected.

    ComfyUI not being there is the normal case at startup, and a gateway whose
    progress optimization cannot connect is a gateway that reports ``progress``
    as null -- which is a documented answer, not an error.
    """

    fake_comfy.stop()
    sink = RecordingSink()
    events = ComfyEvents(
        "ws://127.0.0.1:{}/ws".format(fake_comfy.port),
        sink,
        reconnect_seconds=0.05,
        open_timeout=0.5,
    ).start()
    try:
        assert not events.wait_until_connected(1.0)
    finally:
        events.stop()

    assert sink.progress == [] and sink.changes == []


def test_the_consumer_keeps_trying_after_a_refused_connection() -> None:
    """A ComfyUI that is restarted comes back without restarting the gateway."""

    attempts: List[int] = []
    delivered = threading.Event()

    class OneMessageSocket:
        def __enter__(self):
            return self

        def __exit__(self, *exc_info):
            return False

        def __iter__(self):
            yield frame("progress", value=2, max=8, prompt_id="p-1")
            delivered.set()
            # Then the backend goes away again, as a restart looks from here.

        def close(self):
            pass

    def connect(url, **kwargs):
        attempts.append(1)
        if len(attempts) == 1:
            raise OSError("connection refused")
        return OneMessageSocket()

    sink = RecordingSink()
    events = ComfyEvents(
        "ws://unused/ws", sink, reconnect_seconds=0.01, connect=connect
    ).start()
    try:
        assert delivered.wait(10.0), attempts
        assert sink.arrived.wait(10.0)
    finally:
        events.stop()

    assert len(attempts) >= 2
    assert ("p-1", 2, 8) in sink.progress


# -- the address it connects to ----------------------------------------------


def test_the_event_socket_is_derived_from_the_scheme_never_hardcoded() -> None:
    """`docs/transport-boundary.md` §2, one layer down from the app's endpoint."""

    plain = ComfyClient("http://127.0.0.1:8188", client_id="abc")
    secured = ComfyClient("https://comfy.example:8443", client_id="abc")
    try:
        assert plain.events_url == "ws://127.0.0.1:8188/ws?clientId=abc"
        assert secured.events_url == "wss://comfy.example:8443/ws?clientId=abc"
    finally:
        plain.close()
        secured.close()


def test_the_socket_carries_the_client_id_that_submitted_the_prompts(
    fake_comfy,
) -> None:
    """ComfyUI addresses a prompt's messages at the client that submitted it.

    A socket opened under a different id would be connected, silent, and
    indistinguishable from a working one -- so the id in the URL is asserted to
    be the same one ``POST /prompt`` sent.
    """

    client = ComfyClient(fake_comfy.base_url)
    try:
        client.submit({"1": {"class_type": "FakeNode", "inputs": {}}})
        submitted_id = fake_comfy.submissions[0]["client_id"]

        assert submitted_id
        assert client.events_url.endswith("clientId={}".format(submitted_id))
    finally:
        client.close()


def _emit_until_delivered(fake, prompt_id: str, value: int, maximum: int) -> None:
    deadline = time.monotonic() + 10.0
    while time.monotonic() < deadline:
        if fake.emit_progress(prompt_id, value, maximum):
            return
        time.sleep(0.02)
    raise AssertionError("nothing was attached to ComfyUI's event socket")
