"""The handlers that exist to stop a traceback reaching the phone.

`api/errors.py` claims that **no** failure escapes the documented envelope --
not a bug in this gateway, not a request FastAPI itself refuses.  A claim like
that is only worth what its tests are worth, and these are the paths that are
easy to leave untested precisely because nothing normal reaches them:

* the catch-all ``Exception`` handler, reached when the gateway's own code
  raises something nobody anticipated.  Without it FastAPI answers with its own
  500 and, in a development configuration, the traceback;
* the ``RequestValidationError`` handler, reached today by any malformed JSON
  body.  Without it FastAPI answers 422 with a list of pydantic error
  dictionaries -- valid JSON, wrong contract, and no ``error`` key for the app
  to read.

``raise_server_exceptions=False`` on the test client is what lets the first one
be observed here rather than escaping into pytest.
"""

from __future__ import annotations

import pytest

from workflow_fixtures import EVERY_FIELD

#: A body that is not JSON at all, and one that is truncated part-way.  Both
#: reach the gateway as a request FastAPI cannot parse.
MALFORMED_BODIES = (
    '{"workflow_id": "flow", "inputs": {"prompt": "a rainy alley"',  # truncated
    "not json at all",
    "",
)


@pytest.fixture
def harness(gateway_factory, builder):
    builder.add("flow", EVERY_FIELD)
    return gateway_factory()


def error_of(response):
    body = response.json()
    assert set(body) == {"error"}, body
    assert set(body["error"]) == {"code", "message", "field"}, body
    return body["error"]


def break_health(harness) -> None:
    """Make the readiness probe raise something nobody planned for.

    A ``ZeroDivisionError`` stands in for the class of bug this handler exists
    for: not a :class:`ComfyError`, not an :class:`ApiError`, nothing the route
    catches -- just a mistake, of the kind that is only ever found in
    production.
    """

    def explode():
        raise ZeroDivisionError("secret detail from inside the gateway")

    harness.state.comfy.health = explode


# -- the catch-all --------------------------------------------------------


def test_an_unexpected_failure_becomes_a_500_in_the_documented_shape(
    harness,
) -> None:
    break_health(harness)

    response = harness.client.get("/api/v1/info")

    assert response.status_code == 500
    error = error_of(response)
    assert error["code"] == "internal_error"
    assert error["field"] is None
    assert error["message"] == "Something went wrong on the LocalCanvas server."


def test_an_unexpected_failure_never_shows_the_user_a_traceback(harness) -> None:
    break_health(harness)

    body = harness.client.get("/api/v1/info").text

    assert "Traceback" not in body
    assert 'File "' not in body
    assert "ZeroDivisionError" not in body
    assert "secret detail from inside the gateway" not in body


def test_the_detail_of_an_unexpected_failure_reaches_the_pc_log(
    harness, caplog
) -> None:
    """It is not discarded -- it goes where the person who can act on it is."""

    break_health(harness)

    with caplog.at_level("ERROR", logger="localcanvas_gateway.api.errors"):
        harness.client.get("/api/v1/info")

    logged = caplog.text
    assert "ZeroDivisionError" in logged
    assert "secret detail from inside the gateway" in logged


# -- a request FastAPI itself refuses --------------------------------------


@pytest.mark.parametrize("body", MALFORMED_BODIES)
def test_a_malformed_json_body_is_answered_in_the_documented_envelope(
    harness, body: str
) -> None:
    """FastAPI's own 422 is a list of pydantic dictionaries; this contract is not."""

    response = harness.client.post(
        "/api/v1/jobs", content=body, headers={"content-type": "application/json"}
    )

    assert response.status_code == 400
    assert "detail" not in response.json()
    error = error_of(response)
    assert error["code"] == "invalid_request"
    assert error["field"] is None
    assert "Traceback" not in response.text


def test_a_malformed_body_never_reaches_comfyui(harness) -> None:
    harness.client.post(
        "/api/v1/jobs",
        content=MALFORMED_BODIES[0],
        headers={"content-type": "application/json"},
    )

    assert harness.fake.submissions == []


def test_a_malformed_body_message_is_written_for_a_person(harness) -> None:
    response = harness.client.post(
        "/api/v1/jobs",
        content=MALFORMED_BODIES[0],
        headers={"content-type": "application/json"},
    )

    message = error_of(response)["message"]
    assert message[0].isupper() and message.endswith(".")
    assert "pydantic" not in message.lower()
    assert "json_invalid" not in message.lower()
