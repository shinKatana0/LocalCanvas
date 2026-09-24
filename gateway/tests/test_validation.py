"""Every way a definition is rejected, and what the diagnostic says.

The diagnostics are read by a curator fixing their own YAML, so each test
checks the message actually names the problem -- not merely that something
was rejected.
"""

from __future__ import annotations

import json

import pytest

from conftest import PROMPT_FIELD, graph_copy, only

VALID_FIELD = PROMPT_FIELD


def reject(builder, fields=VALID_FIELD, **kwargs):
    """Write one definition, load, and assert it did not make it in."""

    builder.add("bad", fields, **kwargs)
    registry = builder.load()
    assert registry.workflows == (), "the definition should have been rejected"
    assert registry.diagnostics, "a rejected definition must say why"
    return registry.diagnostics


# -- the definition file itself -------------------------------------------


def test_malformed_yaml_is_reported_as_a_yaml_error(builder):
    builder.write("broken", "id: broken\n  name: [unclosed\n", graph=graph_copy())
    diagnostic = only(builder.load().diagnostics)
    assert "YAML parse error" in diagnostic.message
    assert diagnostic.source.name == "broken.yaml"


def test_an_empty_definition_file_is_reported(builder):
    builder.write("blank", "\n", graph=graph_copy())
    assert "empty" in only(builder.load().diagnostics).message


def test_a_definition_that_is_not_a_mapping_is_reported(builder):
    builder.write("listy", "- id: a\n- id: b\n", graph=graph_copy())
    assert "mapping at the top level" in only(builder.load().diagnostics).message


@pytest.mark.parametrize(
    "body, needle",
    [
        ("name: No Id\nworkflow: x_api.json\ninputs: []\n", "'id' is required"),
        ("id: 76\nname: N\nworkflow: x_api.json\ninputs: []\n", "'id' must be a string"),
        ("id: Bad Id!\nname: N\nworkflow: x_api.json\ninputs: []\n", "is not allowed"),
        ("id: ok\nworkflow: x_api.json\ninputs: []\n", "'name' is required"),
        ("id: ok\nname: N\ninputs: []\n", "'workflow' is required"),
        ("id: ok\nname: N\nworkflow: x_api.json\n", "'inputs' is required"),
    ],
)
def test_the_required_top_level_keys_are_required(builder, body, needle):
    builder.write("x", body, graph=graph_copy(), json_name="x_api.json")
    messages = [diagnostic.message for diagnostic in builder.load().diagnostics]
    assert any(needle in message for message in messages), messages


def test_an_unknown_top_level_key_is_rejected_rather_than_ignored(builder):
    builder.write(
        "typo",
        "id: typo\nname: N\nworkflow: typo_api.json\ninput: []\ninputs: []\n",
        graph=graph_copy(),
    )
    diagnostic = only(builder.load().diagnostics)
    assert "unknown key 'input'" in diagnostic.message
    assert "'inputs'" in diagnostic.message  # the message lists what is allowed


@pytest.mark.parametrize(
    "workflow_value",
    [
        "C:/somewhere/graph.json",    # drive-letter absolute
        "C:graph.json",               # drive-relative: still not this folder
        "/somewhere/graph.json",      # rooted but driveless
        "//server/share/graph.json",  # a network share
    ],
)
def test_a_rooted_workflow_path_is_rejected_on_either_platform(builder, workflow_value):
    """A rooted path is not relative, whichever platform's rules you read it by.

    PureWindowsPath("/x.json") reports itself as not absolute -- it has no
    drive -- and it is certainly not relative either.
    """

    builder.write(
        "abs",
        'id: abs\nname: N\nworkflow: "{}"\ninputs: []\n'.format(workflow_value),
        graph=graph_copy(),
    )
    diagnostic = only(builder.load().diagnostics)
    assert "must be a path relative to the definition file" in diagnostic.message
    # Not the misleading "workflow JSON not found" a rooted path used to give.
    assert "not found" not in diagnostic.message


def test_a_workflow_path_in_a_subfolder_is_accepted(builder):
    """The rootedness check must not reject an ordinary relative path."""

    builder.write(
        "nested_json",
        "id: nested_json\nname: N\nworkflow: graphs/nested_api.json\ninputs: []\n",
        graph=graph_copy(),
        json_name="graphs/nested_api.json",
    )
    registry = builder.load()
    assert registry.diagnostics == ()
    assert registry.ids == ("nested_json",)


def test_a_duplicate_yaml_key_is_rejected_rather_than_last_wins(builder):
    """`name: A` then `name: B` yields B, and one of the two lines does nothing."""

    builder.write(
        "twice",
        "id: twice\nname: First\nworkflow: twice_api.json\nname: Second\ninputs: []\n",
        graph=graph_copy(),
    )
    registry = builder.load()
    diagnostic = only(registry.diagnostics)
    # The line number is half the diagnostic's usefulness, so it is checked
    # exactly: the second `name:` is on line 4 of the file above -- neither the
    # first line nor a neighbour of the right answer.
    assert "duplicate key 'name' on line 4" in diagnostic.message
    assert registry.workflows == ()


def test_a_duplicate_key_inside_a_field_is_rejected(builder):
    diagnostics = reject(
        builder,
        """
        - id: steps
          label: Steps
          type: integer
          default: 20
          default: 30
          bind: {node: "30", input: steps}
        """,
    )
    assert "duplicate key 'default'" in only(diagnostics).message


# -- the workflow JSON -----------------------------------------------------


def test_a_missing_workflow_json_is_reported_with_the_path(builder):
    builder.add("bad", VALID_FIELD, json_name="not_here.json", write_json=False)
    diagnostic = only(builder.load().diagnostics)
    assert "workflow JSON not found" in diagnostic.message
    assert "not_here.json" in diagnostic.message
    assert diagnostic.workflow_id == "bad"


def test_malformed_workflow_json_is_reported_with_the_position(builder):
    diagnostics = reject(builder, json_text='{"10": {"inputs": }}')
    message = only(diagnostics).message
    assert "is not valid JSON" in message
    assert "line" in message and "column" in message


def test_a_ui_format_export_is_rejected_as_not_api_format(builder):
    """The common curator mistake: exporting the UI JSON instead of the API one."""

    diagnostics = reject(
        builder, json_text=json.dumps({"nodes": [], "links": []})
    )
    message = only(diagnostics).message
    assert "not ComfyUI API format" in message
    assert "expected an object" in message or "API format" in message


def test_a_json_array_is_rejected_as_not_api_format(builder):
    diagnostics = reject(builder, json_text="[]")
    assert "not ComfyUI API format" in only(diagnostics).message


# -- fields ----------------------------------------------------------------


def test_duplicate_field_ids_are_rejected(builder):
    diagnostics = reject(
        builder,
        """
        - id: prompt
          label: Prompt
          type: multiline
          bind: {node: "20", input: text}
        - id: prompt
          label: Prompt again
          type: string
          bind: {node: "10", input: name}
        """,
    )
    diagnostic = only(diagnostics)
    assert "duplicate field id 'prompt'" in diagnostic.message
    assert diagnostic.field_id == "prompt"


def test_an_unknown_field_type_is_rejected_and_the_types_are_listed(builder):
    diagnostics = reject(
        builder,
        """
        - id: track
          label: Track
          type: audio
          bind: {node: "10", input: name}
        """,
    )
    message = only(diagnostics).message
    assert "unknown field type 'audio'" in message
    assert "'image'" in message and "'video'" in message


def test_an_unknown_field_key_is_rejected_rather_than_silently_ignored(builder):
    diagnostics = reject(
        builder,
        """
        - id: steps
          label: Steps
          type: integer
          defualt: 20
          bind: {node: "30", input: steps}
        """,
    )
    diagnostic = only(diagnostics)
    assert "unknown key 'defualt'" in diagnostic.message
    assert diagnostic.field_id == "steps"


@pytest.mark.parametrize(
    "field_yaml, needle",
    [
        (
            "- id: s\n  type: string\n  bind: {node: \"10\", input: name}",
            "'label' must be a non-empty string",
        ),
        (
            "- id: s\n  label: S\n  bind: {node: \"10\", input: name}",
            "'type' is required",
        ),
        ("- id: s\n  label: S\n  type: string", "'bind' is required"),
        (
            "- id: s\n  label: S\n  type: string\n  section: extra\n"
            "  bind: {node: \"10\", input: name}",
            "'section' must be 'main' or 'advanced'",
        ),
        (
            "- id: s\n  label: S\n  type: string\n  required: yes please\n"
            "  bind: {node: \"10\", input: name}",
            "'required' must be a boolean",
        ),
        (
            "- label: S\n  type: string\n  bind: {node: \"10\", input: name}",
            "'id' must be a non-empty string",
        ),
    ],
)
def test_field_level_requirements(builder, field_yaml, needle):
    diagnostics = reject(builder, field_yaml)
    assert any(needle in diagnostic.message for diagnostic in diagnostics), [
        diagnostic.message for diagnostic in diagnostics
    ]


# -- numeric constraints ---------------------------------------------------


@pytest.mark.parametrize(
    "extra, needle",
    [
        ("default: twenty", "'default' must be an integer"),
        ("default: 20.5", "'default' must be an integer"),
        ("default: true", "'default' must be an integer"),
        ("min: 1\n  max: 50\n  default: 0", "below 'min'"),
        ("min: 1\n  max: 50\n  default: 99", "above 'max'"),
        ("min: 50\n  max: 1", "is greater than 'max'"),
        ("min: 1.5", "must be an integer on an 'integer' field"),
        ("step: 0", "'step' must be greater than 0"),
    ],
)
def test_integer_constraints(builder, extra, needle):
    diagnostics = reject(
        builder,
        "- id: steps\n  label: Steps\n  type: integer\n  {}\n"
        '  bind: {{node: "30", input: steps}}'.format(extra),
    )
    assert any(needle in diagnostic.message for diagnostic in diagnostics), [
        diagnostic.message for diagnostic in diagnostics
    ]


@pytest.mark.parametrize(
    "extra, needle",
    [
        ("default: high", "'default' must be a number"),
        ("min: 1.0\n  max: 20.0\n  default: 0.5", "below 'min'"),
        ("min: 1.0\n  max: 20.0\n  default: 25.0", "above 'max'"),
        ("min: 20.0\n  max: 1.0", "is greater than 'max'"),
    ],
)
def test_float_constraints(builder, extra, needle):
    diagnostics = reject(
        builder,
        "- id: guidance\n  label: Guidance\n  type: float\n  {}\n"
        '  bind: {{node: "30", input: cfg}}'.format(extra),
    )
    assert any(needle in diagnostic.message for diagnostic in diagnostics), [
        diagnostic.message for diagnostic in diagnostics
    ]


def test_an_integer_field_accepts_an_integer_default_on_the_bound(builder):
    """The bounds are inclusive; a valid definition must not be rejected."""

    builder.add(
        "edges",
        """
        - id: steps
          label: Steps
          type: integer
          min: 1
          max: 50
          default: 50
          bind: {node: "30", input: steps}
        """,
    )
    registry = builder.load()
    assert registry.diagnostics == ()
    assert registry.get("edges").field("steps").default == 50


def test_min_max_and_step_are_not_valid_on_a_string_field(builder):
    diagnostics = reject(
        builder,
        """
        - id: line
          label: Line
          type: string
          min: 1
          bind: {node: "10", input: name}
        """,
    )
    assert "'min' is not valid for a field of type 'string'" in only(diagnostics).message


# -- select ----------------------------------------------------------------


@pytest.mark.parametrize(
    "options_yaml",
    ["options: []", "options: {}", ""],
)
def test_select_requires_a_non_empty_options_list(builder, options_yaml):
    diagnostics = reject(
        builder,
        "- id: mode\n  label: Mode\n  type: select\n"
        + ("  {}\n".format(options_yaml) if options_yaml else "")
        + '  bind: {node: "30", input: mode}',
    )
    assert "non-empty 'options' list" in only(diagnostics).message


def test_a_select_default_must_be_one_of_the_options(builder):
    diagnostics = reject(
        builder,
        """
        - id: mode
          label: Mode
          type: select
          default: turbo
          options:
            - {value: fast, label: Fast}
            - {value: slow, label: Slow}
          bind: {node: "30", input: mode}
        """,
    )
    message = only(diagnostics).message
    assert "'default' 'turbo' is not one of the options" in message
    assert "'fast'" in message and "'slow'" in message


def test_duplicate_option_values_are_rejected(builder):
    diagnostics = reject(
        builder,
        """
        - id: mode
          label: Mode
          type: select
          options:
            - {value: fast, label: Fast}
            - {value: fast, label: Also fast}
          bind: {node: "30", input: mode}
        """,
    )
    assert "duplicate option value 'fast'" in only(diagnostics).message


def test_options_are_not_valid_on_a_non_select_field(builder):
    diagnostics = reject(
        builder,
        """
        - id: steps
          label: Steps
          type: integer
          options: [{value: 1}]
          bind: {node: "30", input: steps}
        """,
    )
    assert "'options' is not valid for a field of type 'integer'" in only(diagnostics).message


# -- boolean and text defaults --------------------------------------------


def test_a_boolean_default_must_be_a_boolean(builder):
    diagnostics = reject(
        builder,
        """
        - id: enabled
          label: Enabled
          type: boolean
          default: "yes"
          bind: {node: "30", input: enabled}
        """,
    )
    assert "'default' must be a boolean" in only(diagnostics).message


def test_a_string_default_must_be_a_string(builder):
    diagnostics = reject(
        builder,
        """
        - id: line
          label: Line
          type: string
          default: 12
          bind: {node: "10", input: name}
        """,
    )
    assert "'default' must be a string" in only(diagnostics).message


def test_a_null_default_is_rejected(builder):
    diagnostics = reject(
        builder,
        """
        - id: line
          label: Line
          type: string
          default: null
          bind: {node: "10", input: name}
        """,
    )
    assert "must not be null" in only(diagnostics).message


def test_a_required_field_cannot_declare_an_empty_default(builder):
    diagnostics = reject(
        builder,
        """
        - id: prompt
          label: Prompt
          type: multiline
          required: true
          default: ""
          bind: {node: "20", input: text}
        """,
    )
    assert "required field cannot declare an empty 'default'" in only(diagnostics).message


# -- media -----------------------------------------------------------------


def test_a_media_field_cannot_declare_a_default(builder):
    diagnostics = reject(
        builder,
        """
        - id: picture
          label: Picture
          type: image
          default: photo.png
          bind: {node: "40", input: image}
        """,
    )
    assert "media field cannot declare a 'default'" in only(diagnostics).message


# -- presentation hints ----------------------------------------------------


def test_an_unknown_role_is_rejected(builder):
    diagnostics = reject(
        builder,
        """
        - id: steps
          label: Steps
          type: integer
          role: lucky
          bind: {node: "30", input: steps}
        """,
    )
    assert "unknown 'role' 'lucky'" in only(diagnostics).message


def test_role_and_pair_are_only_legal_on_an_integer(builder):
    diagnostics = reject(
        builder,
        """
        - id: line
          label: Line
          type: string
          role: seed
          bind: {node: "10", input: name}
        - id: guidance
          label: Guidance
          type: float
          pair: width
          bind: {node: "30", input: cfg}
        """,
    )
    messages = [diagnostic.message for diagnostic in diagnostics]
    assert "'role' is not valid for a field of type 'string'" in messages
    assert "'pair' is not valid for a field of type 'float'" in messages


def test_an_unknown_pair_value_is_rejected(builder):
    diagnostics = reject(
        builder,
        """
        - id: steps
          label: Steps
          type: integer
          pair: depth
          bind: {node: "30", input: steps}
        """,
    )
    assert "'pair' must be 'width' or 'height'" in only(diagnostics).message


# -- binding ---------------------------------------------------------------


def test_a_bind_node_absent_from_the_json_is_rejected(builder):
    diagnostics = reject(
        builder,
        """
        - id: steps
          label: Steps
          type: integer
          bind: {node: "999", input: steps}
        """,
    )
    diagnostic = only(diagnostics)
    assert "bind.node '999' is not present in the workflow JSON" in diagnostic.message
    assert diagnostic.field_id == "steps"


def test_a_bind_input_absent_on_that_node_is_rejected_and_the_inputs_are_listed(builder):
    diagnostics = reject(
        builder,
        """
        - id: steps
          label: Steps
          type: integer
          bind: {node: "30", input: stpes}
        """,
    )
    message = only(diagnostics).message
    assert "bind.input 'stpes' is not present on node '30'" in message
    assert "'steps'" in message  # the message shows what that node does offer


def test_an_input_wired_to_another_node_is_not_bindable(builder):
    """`"conditioning": ["20", 0]` is a connection, not a value."""

    diagnostics = reject(
        builder,
        """
        - id: cond
          label: Conditioning
          type: string
          bind: {node: "30", input: conditioning}
        """,
    )
    assert "wired to another node's output" in only(diagnostics).message


def test_a_node_without_an_inputs_object_is_reported(builder):
    graph = {"10": {"class_type": "ExampleLoader"}}
    diagnostics = reject(
        builder,
        """
        - id: line
          label: Line
          type: string
          bind: {node: "10", input: name}
        """,
        graph=graph,
    )
    assert "has no 'inputs' object" in only(diagnostics).message


def test_two_fields_may_not_drive_the_same_node_input(builder):
    diagnostics = reject(
        builder,
        """
        - id: steps
          label: Steps
          type: integer
          bind: {node: "30", input: steps}
        - id: also_steps
          label: Steps again
          type: integer
          bind: {node: 30, input: steps}
        """,
    )
    message = only(diagnostics).message
    assert "already binds to" in message
    assert "'steps'" in message


# -- several targets for one field (T-0045) --------------------------------


def test_a_field_may_not_name_the_same_target_twice(builder):
    """A repeated target is an authoring mistake, not a no-op to deduplicate."""

    diagnostics = reject(
        builder,
        """
        - id: steps
          label: Steps
          type: integer
          bind:
            - {node: "30", input: steps}
            - {node: 30, input: steps}
        """,
    )
    diagnostic = only(diagnostics)
    assert diagnostic.field_id == "steps"
    assert "may not name the same target twice" in diagnostic.message
    assert "'30'" in diagnostic.message
    assert "'steps'" in diagnostic.message
    assert "bind[1]" in diagnostic.message and "bind[0]" in diagnostic.message


def test_an_empty_bind_list_is_refused(builder):
    diagnostics = reject(
        builder,
        """
        - id: steps
          label: Steps
          type: integer
          bind: []
        """,
    )
    diagnostic = only(diagnostics)
    assert diagnostic.field_id == "steps"
    assert "'bind' is an empty list" in diagnostic.message


def test_a_later_field_may_not_take_a_target_an_earlier_list_already_holds(builder):
    diagnostics = reject(
        builder,
        """
        - id: steps
          label: Steps
          type: integer
          bind:
            - {node: "30", input: steps}
            - {node: "30", input: seed}
        - id: also_seed
          label: Seed again
          type: integer
          bind: {node: "30", input: seed}
        """,
    )
    diagnostic = only(diagnostics)
    assert diagnostic.field_id == "also_seed"          # the field that lost
    assert "'steps'" in diagnostic.message             # the field that had it
    assert "'seed'" in diagnostic.message              # the target
    assert "already binds to" in diagnostic.message


def test_a_conflict_on_any_target_of_a_list_is_caught_not_only_the_first(builder):
    """`steps` is free; the *second* target is the one another field holds."""

    diagnostics = reject(
        builder,
        """
        - id: seed
          label: Seed
          type: integer
          bind: {node: "30", input: seed}
        - id: paired
          label: Paired
          type: integer
          bind:
            - {node: "30", input: steps}
            - {node: "30", input: seed}
        """,
    )
    diagnostic = only(diagnostics)
    assert diagnostic.field_id == "paired"
    assert "'seed'" in diagnostic.message
    assert "already binds to" in diagnostic.message


def test_every_field_conflicting_with_a_list_is_reported_at_once(builder):
    """Both of a field's targets are checked, not the first that fails."""

    diagnostics = reject(
        builder,
        """
        - id: seed
          label: Seed
          type: integer
          bind: {node: "30", input: seed}
        - id: steps
          label: Steps
          type: integer
          bind: {node: "30", input: steps}
        - id: paired
          label: Paired
          type: integer
          bind:
            - {node: "30", input: steps}
            - {node: "30", input: seed}
        """,
    )
    messages = [diagnostic.message for diagnostic in diagnostics]
    assert len(messages) == 2, messages
    assert any("'steps'" in message for message in messages), messages
    assert any("'seed'" in message for message in messages), messages


@pytest.mark.parametrize(
    "target, needle",
    [
        ('{node: "999", input: steps}', "bind[1].node '999' is not present"),
        ('{node: "30", input: stpes}', "bind[1].input 'stpes' is not present on node '30'"),
        ('{node: "30", input: conditioning}', "bind[1].input 'conditioning'"),
    ],
)
def test_each_target_of_a_list_is_validated_and_the_diagnostic_names_which(
    builder, target, needle
):
    """The first target is good; only the second is not, and it is named."""

    diagnostics = reject(
        builder,
        """
        - id: steps
          label: Steps
          type: integer
          bind:
            - {{node: "30", input: steps}}
            - {}
        """.format(target),
    )
    message = only(diagnostics).message
    assert needle in message


def test_every_bad_target_in_one_bind_list_is_reported_at_once(builder):
    """A curator should not have to fix one entry, rerun, and find the next."""

    diagnostics = reject(
        builder,
        """
        - id: steps
          label: Steps
          type: integer
          bind:
            - {node: "998", input: steps}
            - {node: "999", input: steps}
        """,
    )
    messages = [diagnostic.message for diagnostic in diagnostics]
    assert any("bind[0].node '998'" in message for message in messages), messages
    assert any("bind[1].node '999'" in message for message in messages), messages


def test_an_unknown_key_inside_one_list_entry_names_that_entry(builder):
    diagnostics = reject(
        builder,
        """
        - id: steps
          label: Steps
          type: integer
          bind:
            - {node: "30", input: steps}
            - {node: "30", input: seed, extra: 1}
        """,
    )
    assert "bind[1]: unknown key 'extra'" in only(diagnostics).message


@pytest.mark.parametrize(
    "bind_yaml, needle",
    [
        ("bind: {input: text}", "bind.node is required"),
        ('bind: {node: "20"}', "bind.input is required"),
        ('bind: {node: "20", input: text, extra: 1}', "unknown key 'extra'"),
        ("bind: 20", "'bind' must be a mapping or a list of mappings"),
        ("bind: [20, text]", "bind[0] must be a mapping"),
        ('bind: {node: [], input: text}', "bind.node must be a node id"),
        ('bind: {node: "20", input: 4}', "bind.input must be a non-empty string"),
    ],
)
def test_bind_block_requirements(builder, bind_yaml, needle):
    diagnostics = reject(
        builder,
        "- id: prompt\n  label: Prompt\n  type: multiline\n  {}".format(bind_yaml),
    )
    assert any(needle in diagnostic.message for diagnostic in diagnostics), [
        diagnostic.message for diagnostic in diagnostics
    ]


# -- what a diagnostic says ------------------------------------------------


def test_a_diagnostic_names_the_file_the_workflow_and_the_field(builder):
    path = builder.add(
        "bad",
        """
        - id: steps
          label: Steps
          type: integer
          default: 500
          min: 1
          max: 50
          bind: {node: "30", input: steps}
        """,
    )
    diagnostic = only(builder.load().diagnostics)
    assert diagnostic.source == path
    assert diagnostic.workflow_id == "bad"
    assert diagnostic.field_id == "steps"

    rendered = str(diagnostic)
    assert str(path) in rendered
    assert "'bad'" in rendered
    assert "'steps'" in rendered
    assert "above 'max'" in rendered


def test_every_problem_in_one_definition_is_reported_at_once(builder):
    """A curator should not have to fix one line, rerun, and find the next."""

    diagnostics = reject(
        builder,
        """
        - id: steps
          label: Steps
          type: integer
          default: 500
          min: 1
          max: 50
          bind: {node: "30", input: steps}
        - id: mode
          label: Mode
          type: select
          options: []
          bind: {node: "30", input: mode}
        """,
    )
    assert {diagnostic.field_id for diagnostic in diagnostics} == {"steps", "mode"}
