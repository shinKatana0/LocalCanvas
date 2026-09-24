"""``duration: {fps: N}`` -- a frame count a renderer may also show as a time.

Two rules are what this file exists to hold in place (`docs/workflow-schema.md`):

* **declared, never inferred** -- no field id, no label, no value range and
  nothing in the graph switches the hint on;
* **the wire value never changes** -- what ComfyUI receives is the frame count
  it always received, with no duration key and no rounded frame count anywhere
  near it.
"""

from __future__ import annotations

import pytest

from conftest import only
from localcanvas_gateway.workflows import DurationHint, bind_values

#: The design's own example: a step that does not divide the range evenly, so a
#: naive ``seconds * fps`` lands off the grid.
LENGTH_FIELD = """
- id: length
  label: Length
  type: integer
  default: 25
  min: 25
  max: 121
  step: 4
  duration:
    fps: 24
  bind: {node: "30", input: steps}
"""

#: The same field with the hint taken away, and nothing else changed.
PLAIN_LENGTH_FIELD = """
- id: length
  label: Length
  type: integer
  default: 25
  min: 25
  max: 121
  step: 4
  bind: {node: "30", input: steps}
"""


def reject(builder, fields):
    """Write one definition, load, and assert it did not make it in."""

    builder.add("bad", fields)
    registry = builder.load()
    assert registry.workflows == (), "the definition should have been rejected"
    assert registry.diagnostics, "a rejected definition must say why"
    return registry.diagnostics


def load_field(builder, fields, field_id="length"):
    builder.add("timed", fields)
    registry = builder.load()
    assert [str(item) for item in registry.diagnostics] == []
    return registry.get("timed").field(field_id)


# -- what a declared hint carries ------------------------------------------


def test_a_declared_duration_is_carried_onto_the_field(builder) -> None:
    field = load_field(builder, LENGTH_FIELD)

    assert field.duration == DurationHint(fps=24)
    # The bounds are untouched: they still bind the frame count.
    assert (field.min, field.max, field.step, field.default) == (25, 121, 4, 25)


def test_the_frame_rate_is_carried_as_the_curator_wrote_it(builder) -> None:
    field = load_field(
        builder,
        """
        - id: length
          label: Length
          type: integer
          duration: {fps: 23.976}
          bind: {node: "30", input: steps}
        """,
    )

    assert field.duration.fps == pytest.approx(23.976)


def test_the_hint_reaches_the_app_in_the_field_schema(builder) -> None:
    field = load_field(builder, LENGTH_FIELD)

    view = field.to_view()

    assert view["duration"] == {"fps": 24}
    # And the value keys it lives beside are unchanged.
    assert (view["min"], view["max"], view["step"]) == (25, 121, 4)


def test_a_field_that_declares_nothing_carries_nothing(builder) -> None:
    field = load_field(builder, PLAIN_LENGTH_FIELD)

    assert field.duration is None
    assert "duration" not in field.to_view()
    # Byte for byte the view this field had before the hint existed.
    assert field.to_view() == {
        "id": "length",
        "label": "Length",
        "type": "integer",
        "required": False,
        "section": "main",
        "default": 25,
        "min": 25,
        "max": 121,
        "step": 4,
    }


def test_the_detail_endpoint_serves_the_hint_and_omits_it_where_absent(
    gateway_factory, builder
) -> None:
    builder.add(
        "timed",
        LENGTH_FIELD
        + PLAIN_LENGTH_FIELD.replace("id: length", "id: other").replace(
            'input: steps', 'input: seed'
        ),
    )
    harness = gateway_factory()

    inputs = harness.client.get("/api/v1/workflows/timed").json()["inputs"]
    by_id = {field["id"]: field for field in inputs}

    assert by_id["length"]["duration"] == {"fps": 24}
    assert "duration" not in by_id["other"]


# -- declared, never inferred ----------------------------------------------


@pytest.mark.parametrize(
    "field_id", ["frames", "length", "video_length", "num_frames", "fps", "duration"]
)
def test_no_field_name_switches_the_hint_on(builder, field_id) -> None:
    """The names a curator plausibly writes are still just names."""

    field = load_field(
        builder,
        """
        - id: {}
          label: Length
          type: integer
          default: 25
          min: 25
          max: 121
          step: 4
          bind: {{node: "30", input: steps}}
        """.format(field_id),
        field_id=field_id,
    )

    assert field.duration is None


def test_no_frame_rate_is_read_out_of_the_graph(builder) -> None:
    """A graph that states its own frame rate does not fill `fps` in."""

    builder.add(
        "timed",
        PLAIN_LENGTH_FIELD,
        graph={
            "30": {
                "class_type": "ExampleSampler",
                "inputs": {"steps": 20, "fps": 24, "frame_rate": 24, "video_length": 121},
            }
        },
    )
    registry = builder.load()

    assert [str(item) for item in registry.diagnostics] == []
    assert registry.get("timed").field("length").duration is None


# -- what a bad declaration says -------------------------------------------


@pytest.mark.parametrize("field_type", ["float", "string", "multiline", "boolean"])
def test_duration_is_refused_off_an_integer(builder, field_type) -> None:
    diagnostics = reject(
        builder,
        """
        - id: length
          label: Length
          type: {}
          duration: {{fps: 24}}
          bind: {{node: "10", input: name}}
        """.format(field_type),
    )

    message = only(diagnostics).message
    assert "'duration' is not valid for a field of type '{}'".format(field_type) in message
    assert "length" in str(only(diagnostics))


def test_a_duration_with_no_fps_is_refused(builder) -> None:
    diagnostics = reject(
        builder,
        """
        - id: length
          label: Length
          type: integer
          duration: {}
          bind: {node: "30", input: steps}
        """,
    )

    diagnostic = only(diagnostics)
    assert "'duration' requires an 'fps'" in diagnostic.message
    assert "declared, never inferred" in diagnostic.message
    assert diagnostic.field_id == "length"


@pytest.mark.parametrize("fps", ["0", "-24", "-0.5"])
def test_a_frame_rate_that_is_not_positive_is_refused(builder, fps) -> None:
    diagnostics = reject(
        builder,
        """
        - id: length
          label: Length
          type: integer
          duration: {{fps: {}}}
          bind: {{node: "30", input: steps}}
        """.format(fps),
    )

    diagnostic = only(diagnostics)
    assert "'duration.fps' must be greater than 0" in diagnostic.message
    assert diagnostic.field_id == "length"


@pytest.mark.parametrize("fps", ["'24'", "true", "[24]", "{a: 1}", "null"])
def test_a_frame_rate_that_is_not_a_number_is_refused(builder, fps) -> None:
    diagnostics = reject(
        builder,
        """
        - id: length
          label: Length
          type: integer
          duration: {{fps: {}}}
          bind: {{node: "30", input: steps}}
        """.format(fps),
    )

    diagnostic = only(diagnostics)
    assert "'duration.fps' must be a number" in diagnostic.message
    assert diagnostic.field_id == "length"


@pytest.mark.parametrize("fps", [".nan", ".inf", "-.inf"])
def test_a_frame_rate_that_is_not_finite_is_refused(builder, fps) -> None:
    diagnostics = reject(
        builder,
        """
        - id: length
          label: Length
          type: integer
          duration: {{fps: {}}}
          bind: {{node: "30", input: steps}}
        """.format(fps),
    )

    assert "'duration.fps' must be a finite number" in only(diagnostics).message


def test_a_duration_that_is_not_a_mapping_is_refused(builder) -> None:
    diagnostics = reject(
        builder,
        """
        - id: length
          label: Length
          type: integer
          duration: 24
          bind: {node: "30", input: steps}
        """,
    )

    assert "'duration' must be a mapping declaring an 'fps'" in only(diagnostics).message


def test_an_unknown_key_inside_duration_is_an_error_not_a_comment(builder) -> None:
    diagnostics = reject(
        builder,
        """
        - id: length
          label: Length
          type: integer
          duration: {fps: 24, frame_rate: 24}
          bind: {node: "30", input: steps}
        """,
    )

    messages = [diagnostic.message for diagnostic in diagnostics]
    assert "duration: unknown key 'frame_rate'; allowed keys are 'fps'" in messages


def test_one_bad_field_does_not_take_the_registry_down(builder) -> None:
    builder.add("good", LENGTH_FIELD)
    builder.add(
        "broken",
        """
        - id: length
          label: Length
          type: integer
          duration: {fps: 0}
          bind: {node: "30", input: steps}
        """,
    )
    registry = builder.load()

    assert [workflow.id for workflow in registry.workflows] == ["good"]
    assert "greater than 0" in only(registry.diagnostics).message


# -- the wire value never changes ------------------------------------------


def test_binding_writes_the_frame_count_and_nothing_else(builder) -> None:
    builder.add("timed", LENGTH_FIELD)
    workflow = builder.load().get("timed")

    graph = bind_values(workflow, {"length": 121})

    assert graph["30"]["inputs"]["steps"] == 121
    assert isinstance(graph["30"]["inputs"]["steps"], int)
    # No second key appeared beside it, and nothing carries seconds.
    assert set(graph["30"]["inputs"]) == set(workflow.graph["30"]["inputs"])


def test_a_hinted_field_binds_exactly_what_an_unhinted_one_does(builder) -> None:
    builder.add("timed", LENGTH_FIELD)
    builder.add("plain", PLAIN_LENGTH_FIELD)
    registry = builder.load()

    hinted = bind_values(registry.get("timed"), {"length": 29})
    plain = bind_values(registry.get("plain"), {"length": 29})

    assert hinted == plain


def test_what_comfyui_receives_is_the_frame_count(gateway_factory, builder) -> None:
    """The real submitted seam: a hint changes nothing that goes out."""

    builder.add("timed", LENGTH_FIELD)
    harness = gateway_factory()

    response = harness.submit("timed", {"length": 121})
    assert response.status_code == 201

    submission = harness.fake.submissions[0]
    graph = submission["prompt"]

    assert graph["30"]["inputs"]["steps"] == 121
    for key in ("duration", "fps", "seconds", "duration_seconds"):
        assert key not in graph["30"]["inputs"]


def test_the_declared_bounds_still_bind_a_hinted_field(gateway_factory, builder) -> None:
    builder.add("timed", LENGTH_FIELD)
    harness = gateway_factory()

    response = harness.submit("timed", {"length": 200})

    assert response.status_code == 400
    assert response.json()["error"]["field"] == "length"
    assert harness.fake.submissions == []
