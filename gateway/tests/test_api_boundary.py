"""The transport-independence boundary, checked against real response bodies.

`docs/transport-boundary.md` §3: *"A gateway that names its own host in a
payload breaks the moment it sits behind anything. This is the single most
common way this kind of boundary is lost."*  So this file does the crude thing
deliberately -- it exercises every endpoint, in success and in failure, and
looks for a scheme in what came back.

It also pins the surface itself.  `docs/api.md` lists nine endpoints; an
unauthenticated LAN-facing server should serve those and nothing else, so the
route table is asserted, not assumed.
"""

from __future__ import annotations

import re

import media_fixtures
from test_api_workflows import GRAPH_CLASS_TYPES
from workflow_fixtures import EVERY_FIELD, IMAGE_FIELD

#: The path shape `docs/api.md` names as the one to test against: rooted, with
#: spaces in the directories and in the filename.  The directory names are
#: distinctive so that finding one in a body cannot be a coincidence.
LEAKY_PATH = "C:\\Program Files\\SecretVendor\\hidden models\\sd xl.safetensors"

#: What may never appear in a body, from that path -- listed **one component at
#: a time**, because the way a keep-the-last-component rule fails is by leaving
#: a single directory word behind, and ``"Program Files"`` as one string would
#: not notice ``"Program"`` alone.
LEAKED_DIRECTORIES = ("C:", "Program", "Files", "SecretVendor", "hidden", "models")

#: What is *allowed* to appear -- the one actionable part.
CROSSING_FILENAME = "sd xl.safetensors"


def every_json_response(harness):
    """Every JSON body the gateway can produce, success and failure alike."""

    client = harness.client
    job_id = harness.submit("flow", {"prompt": "a rainy alley"}).json()["job_id"]
    prompt_id = harness.prompt_id

    yield client.get("/api/v1/info")
    yield client.get("/api/v1/workflows")
    yield client.get("/api/v1/workflows/flow")
    yield client.get("/api/v1/workflows/absent")
    yield client.get("/api/v1/jobs/{}".format(job_id))
    yield client.get("/api/v1/jobs/j-nosuchid")
    yield client.get("/api/v1/jobs/{}/result/0".format(job_id))
    yield harness.submit("flow", {})
    yield harness.submit("flow", {"prompt": "x", "steps": 900})

    # The media surface, in success and in every refusal it has.
    yield harness.upload()
    yield harness.upload(filename=r"..\..\windows\system32\evil.jpg")
    yield harness.upload(kind="drawing")
    # ``unsupported_media_type``.  The *body* has to be the wrong thing now
    # rather than the label: an upload is identified from its own first bytes,
    # so a JPEG mislabelled as an executable is accepted and this line would
    # quietly stop contributing a refusal to the corpus above.
    yield harness.upload(
        filename="setup.exe",
        content_type="application/x-msdownload",
        data=media_fixtures.NOT_MEDIA["windows executable"],
    )
    yield harness.submit("needs_image", {"source_image": {"media_id": "m-nosuch"}})
    yield harness.submit("needs_image", {"source_image": "not a reference"})
    yield harness.submit(
        "needs_image", {"source_image": {"media_id": harness.uploaded_id()}}
    )
    yield client.post("/api/v1/jobs", json={"workflow_id": "absent"})
    yield client.get("/api/v1/nothing-here")
    yield client.post("/api/v1/info")

    # A body FastAPI itself refuses, before any route runs.
    yield client.post(
        "/api/v1/jobs",
        content='{"workflow_id": "flow", "inputs": {',
        headers={"content-type": "application/json"},
    )

    harness.fake.start_running(prompt_id)
    yield client.get("/api/v1/jobs/{}".format(job_id))
    # ComfyUI's failure text at its worst: a node class from the submitted
    # graph, and the path shape docs/api.md names -- rooted, with spaces in the
    # directories *and* in the filename.
    harness.fake.fail(prompt_id, "ExampleSampler: " + LEAKY_PATH + " not found")
    yield client.get("/api/v1/jobs/{}".format(job_id))

    # ...and the same graph failing with a stack trace buried in the message.
    second = harness.submit("flow", {"prompt": "another"}).json()["job_id"]
    traced = harness.fake.prompt_ids[-1]
    harness.fake.fail(
        traced,
        "Traceback (most recent call last):\n"
        '  File "' + LEAKY_PATH + '", line 3, in load\n'
        "RuntimeError: boom",
    )
    yield client.get("/api/v1/jobs/{}".format(second))

    third = harness.submit("flow", {"prompt": "a third"}).json()["job_id"]
    harness.fake.complete(harness.fake.prompt_ids[-1])
    yield client.get("/api/v1/jobs/{}".format(third))

    harness.clock.advance(10)
    harness.fake.ready = False
    yield client.get("/api/v1/info")
    harness.fake.stop()
    harness.clock.advance(10)
    yield client.get("/api/v1/info")
    yield harness.submit("flow", {"prompt": "x"})

    # ...and a failure nobody planned for, which reaches the catch-all handler.
    healthy = harness.state.comfy.health

    def explode():
        raise ZeroDivisionError("C:/secret/path/inside.py exploded")

    harness.state.comfy.health = explode
    try:
        yield client.get("/api/v1/info")
    finally:
        harness.state.comfy.health = healthy


def build(gateway_factory, builder):
    builder.add("flow", EVERY_FIELD)
    builder.add("needs_image", IMAGE_FIELD)
    return gateway_factory()


def test_no_response_body_ever_names_a_host(gateway_factory, builder) -> None:
    harness = build(gateway_factory, builder)

    for response in every_json_response(harness):
        body = response.text
        assert "http://" not in body, (response.request.url, body)
        assert "https://" not in body, (response.request.url, body)
        assert "://" not in body, (response.request.url, body)


def test_no_response_body_ever_names_a_directory_on_this_pc(
    gateway_factory, builder
) -> None:
    """`docs/api.md`: no directory component ever crosses.

    ComfyUI's exception text is the usual way one would, so the sweep above
    drives a failure whose message carries the path shape the contract names.
    """

    harness = build(gateway_factory, builder)

    for response in every_json_response(harness):
        body = response.text
        assert not re.search(r"[A-Za-z]:[\\/]", body), (response.request.url, body)
        assert "\\\\" not in body, (response.request.url, body)
        for directory in LEAKED_DIRECTORIES:
            assert directory not in body, (response.request.url, directory)


def test_the_filename_is_allowed_to_cross(gateway_factory, builder) -> None:
    """The other half of the same rule, and the reason the sweep above bites.

    A gateway that answered by deleting every message would pass the sweep and
    tell the user nothing.  The filename is what says *which* model is missing,
    so its absence would be a defect too.
    """

    harness = build(gateway_factory, builder)
    bodies = [response.text for response in every_json_response(harness)]

    assert any(CROSSING_FILENAME in body for body in bodies)


def test_no_response_body_ever_names_a_node_class(gateway_factory, builder) -> None:
    """Not in a workflow view, and not in a failure message either.

    The sweep drives a job that fails with ComfyUI naming a class from the very
    graph that was submitted -- the one place a node type could still get out
    after T-0002 made the two views structurally separate.
    """

    harness = build(gateway_factory, builder)

    for response in every_json_response(harness):
        for class_type in GRAPH_CLASS_TYPES:
            assert class_type not in response.text, (response.request.url, class_type)


def test_no_response_body_ever_carries_a_traceback(gateway_factory, builder) -> None:
    harness = build(gateway_factory, builder)

    for response in every_json_response(harness):
        assert "Traceback" not in response.text
        assert "File \"" not in response.text
        assert "ZeroDivisionError" not in response.text


def test_every_error_body_has_the_documented_shape(gateway_factory, builder) -> None:
    harness = build(gateway_factory, builder)

    for response in every_json_response(harness):
        if response.status_code < 400:
            continue
        body = response.json()
        assert set(body) == {"error"}, response.request.url
        assert set(body["error"]) == {"code", "message", "field"}, response.request.url
        assert isinstance(body["error"]["message"], str) and body["error"]["message"]
        assert body["error"]["message"][0].isupper()


def test_every_documented_endpoint_is_actually_served(gateway_factory, builder) -> None:
    harness = build(gateway_factory, builder)
    job_id = harness.submit("flow", {"prompt": "x"}).json()["job_id"]
    harness.fake.complete(harness.prompt_id)

    for path in (
        "/api/v1/info",
        "/api/v1/workflows",
        "/api/v1/workflows/flow",
        "/api/v1/jobs/{}".format(job_id),
        "/api/v1/jobs/{}/result/0".format(job_id),
    ):
        assert harness.client.get(path).status_code == 200, path

    assert harness.submit("flow", {"prompt": "x"}).status_code == 201
    assert harness.upload().status_code == 201
    assert (
        harness.client.post("/api/v1/jobs/{}/cancel".format(job_id)).status_code == 200
    )
    with harness.client.websocket_connect(
        "/api/v1/jobs/{}/events".format(job_id)
    ) as socket:
        assert socket.receive_json()["type"]


def test_nothing_beyond_the_documented_endpoints_is_served(
    gateway_factory, builder
) -> None:
    """A media *library* belongs to nobody, and neither does a job registry.

    Probed by asking, rather than by reading FastAPI's route table, because
    what matters is what answers on the wire.

    ``/events`` appears here as a plain **GET**, which is not a duplicate of
    the endpoint next door: the event stream is a WebSocket, and the same path
    is deliberately not an HTTP resource that could be polled for a body the
    contract never defined.
    """

    harness = build(gateway_factory, builder)
    job_id = harness.submit("flow", {"prompt": "x"}).json()["job_id"]

    absent = [
        ("GET", "/api/v1/jobs/{}/events".format(job_id)),  # a socket, not a GET
        # POST /api/v1/media exists now; what stays absent is everything that
        # would make the store a library (`docs/api.md`).
        ("GET", "/api/v1/media"),
        ("GET", "/api/v1/media/m-1"),
        ("DELETE", "/api/v1/media/m-1"),
        ("DELETE", "/api/v1/jobs/{}".format(job_id)),
        ("GET", "/api/v1/queue"),
        ("GET", "/api/v1/comfy"),
        ("GET", "/api/v1"),
        ("GET", "/"),
    ]
    for method, path in absent:
        status = harness.client.request(method, path).status_code
        assert status in (404, 405), "{} {} answered {}".format(method, path, status)


def test_the_gateway_publishes_no_schema_or_documentation_surface(
    gateway_factory, builder
) -> None:
    """An unauthenticated LAN service exposes what it must and nothing more."""

    harness = build(gateway_factory, builder)

    for path in ("/openapi.json", "/docs", "/redoc"):
        assert harness.client.get(path).status_code == 404


def test_an_unknown_path_answers_in_the_documented_shape(
    gateway_factory, builder
) -> None:
    harness = build(gateway_factory, builder)

    response = harness.client.get("/api/v2/info")

    assert response.status_code == 404
    assert set(response.json()["error"]) == {"code", "message", "field"}


def test_a_result_is_the_only_response_that_is_not_json(
    gateway_factory, builder
) -> None:
    harness = build(gateway_factory, builder)
    job_id = harness.submit("flow", {"prompt": "x"}).json()["job_id"]
    harness.fake.complete(harness.prompt_id)

    response = harness.client.get("/api/v1/jobs/{}/result/0".format(job_id))

    assert response.headers["content-type"].startswith("image/")
    assert b"http" not in response.content
