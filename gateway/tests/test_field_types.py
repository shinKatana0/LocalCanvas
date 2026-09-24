"""Parsing of the eight v0.1 field types and their attributes."""

from __future__ import annotations

import pytest

from conftest import only
from localcanvas_gateway.workflows import FieldPair, FieldRole, FieldType, Section

ALL_TYPES_FIELDS = """
- id: line
  label: Line
  type: string
  default: hello
  bind: {node: "10", input: name}
- id: story
  label: Story
  type: multiline
  required: true
  bind: {node: "20", input: text}
- id: steps
  label: Steps
  type: integer
  section: advanced
  default: 20
  min: 1
  max: 50
  step: 1
  bind: {node: "30", input: steps}
- id: guidance
  label: Guidance
  type: float
  section: advanced
  default: 6.0
  min: 1.0
  max: 20.0
  step: 0.5
  bind: {node: "30", input: cfg}
- id: enabled
  label: Enabled
  type: boolean
  default: true
  bind: {node: "30", input: enabled}
- id: mode
  label: Mode
  type: select
  default: fast
  options:
    - {value: fast, label: Fast}
    - {value: slow, label: Slow}
  bind: {node: "30", input: mode}
- id: picture
  label: Picture
  type: image
  required: true
  bind: {node: "40", input: image}
- id: clip
  label: Clip
  type: video
  bind: {node: "40", input: video}
"""


@pytest.fixture
def all_types(builder):
    builder.add("every_type", ALL_TYPES_FIELDS)
    registry = builder.load()
    assert [str(item) for item in registry.diagnostics] == []
    return registry.get("every_type")


def test_all_eight_types_parse(all_types):
    assert [field.type for field in all_types.inputs] == [
        FieldType.STRING,
        FieldType.MULTILINE,
        FieldType.INTEGER,
        FieldType.FLOAT,
        FieldType.BOOLEAN,
        FieldType.SELECT,
        FieldType.IMAGE,
        FieldType.VIDEO,
    ]


def test_required_and_optional_are_distinguished(all_types):
    assert all_types.field("story").required is True
    assert all_types.field("picture").required is True
    # `required` defaults to false, and the default is not "everything is required".
    assert all_types.field("line").required is False
    assert all_types.field("clip").required is False


def test_sections_default_to_main_and_advanced_is_kept(all_types):
    assert all_types.field("line").section is Section.MAIN
    assert all_types.field("steps").section is Section.ADVANCED
    assert all_types.field("guidance").section is Section.ADVANCED


def test_numeric_bounds_and_step_are_carried(all_types):
    steps = all_types.field("steps")
    assert (steps.min, steps.max, steps.step, steps.default) == (1, 50, 1, 20)
    guidance = all_types.field("guidance")
    assert (guidance.min, guidance.max, guidance.step, guidance.default) == (1.0, 20.0, 0.5, 6.0)


def test_select_options_are_parsed_in_order_with_labels(all_types):
    mode = all_types.field("mode")
    assert [(option.value, option.label) for option in mode.options] == [
        ("fast", "Fast"),
        ("slow", "Slow"),
    ]
    assert mode.default == "fast"


def test_defaults_keep_their_python_type(all_types):
    assert all_types.field("line").default == "hello"
    assert all_types.field("enabled").default is True
    assert isinstance(all_types.field("steps").default, int)
    assert isinstance(all_types.field("guidance").default, float)


def test_media_fields_have_no_default_and_are_reported_as_media(all_types):
    for field_id in ("picture", "clip"):
        field = all_types.field(field_id)
        assert field.is_media is True
        assert field.has_default is False
        assert field.default is None
    assert all_types.field("line").is_media is False
    assert all_types.required_media == ("image",)


def test_help_is_optional_and_kept_when_given(builder):
    builder.add(
        "helped",
        """
        - id: steps
          label: Steps
          type: integer
          help: More steps take longer.
          bind: {node: "30", input: steps}
        - id: mode
          label: Mode
          type: select
          options: [{value: fast}]
          bind: {node: "30", input: mode}
        """,
    )
    workflow = builder.load().get("helped")
    assert workflow.field("steps").help == "More steps take longer."
    assert workflow.field("mode").help is None
    # An option with no label falls back to its value rather than being rejected.
    assert workflow.field("mode").options[0].label == "fast"


def test_presentation_hints_are_carried_through(builder):
    builder.add(
        "hinted",
        """
        - id: seed
          label: Seed
          type: integer
          role: seed
          bind: {node: "30", input: seed}
        - id: steps
          label: Steps
          type: integer
          pair: width
          bind: {node: "30", input: steps}
        """,
    )
    workflow = builder.load().get("hinted")
    assert workflow.field("seed").role is FieldRole.SEED
    assert workflow.field("seed").pair is None
    assert workflow.field("steps").pair is FieldPair.WIDTH


def test_presentation_block_is_parsed(builder):
    builder.add(
        "presented",
        """
        - id: prompt
          label: Prompt
          type: multiline
          required: true
          bind: {node: "20", input: text}
        """,
        presentation="""
        group: Create
        category: Example
        badge: TXT2IMG
        short_description: One line.
        input_summary: Prompt only
        example_prompt: A quiet street
        how_to_use: Type something.
        best_for:
          - Portraits
        not_ideal_for:
          - Video
        """,
    )
    workflow = builder.load().get("presented")
    presentation = workflow.presentation
    assert presentation.group == "Create"
    assert presentation.badge == "TXT2IMG"
    assert presentation.best_for == ("Portraits",)
    assert presentation.not_ideal_for == ("Video",)

    summary = workflow.summary_view()
    # `input_summary` lives inside `presentation`, where the YAML puts it and
    # where docs/workflow-schema.md documents it -- in one place, not two.
    assert summary["presentation"]["input_summary"] == "Prompt only"
    assert "input_summary" not in summary
    assert summary["presentation"]["short_description"] == "One line."
    assert "inputs" not in summary


def test_presentation_is_optional(builder):
    builder.add(
        "bare",
        """
        - id: prompt
          label: Prompt
          type: multiline
          bind: {node: "20", input: text}
        """,
    )
    registry = builder.load()
    assert registry.diagnostics == ()
    workflow = registry.get("bare")
    assert workflow.presentation.group is None
    assert workflow.summary_view()["presentation"] == {}


def test_a_workflow_with_no_fields_is_legal(builder):
    builder.write(
        "empty_inputs",
        """
        id: empty_inputs
        name: No Fields
        workflow: empty_inputs_api.json
        inputs: []
        """,
        graph={"10": {"class_type": "ExampleLoader", "inputs": {"name": "PLACEHOLDER"}}},
    )
    registry = builder.load()
    assert registry.diagnostics == ()
    assert only(registry.workflows).inputs == ()
