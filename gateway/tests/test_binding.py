"""Binding values into a copy of the graph, and never into the loaded one."""

from __future__ import annotations

import json

import pytest

from conftest import EXAMPLES_ROOT
from localcanvas_gateway.workflows import BindingError, bind_values, load_registry

FIELDS = """
- id: prompt
  label: Prompt
  type: multiline
  required: true
  bind: {node: "20", input: text}
- id: steps
  label: Steps
  type: integer
  default: 20
  min: 1
  max: 50
  bind: {node: 30, input: steps}
- id: enabled
  label: Enabled
  type: boolean
  default: true
  bind: {node: "30", input: enabled}
- id: picture
  label: Picture
  type: image
  bind: {node: "40", input: image}
"""


class RecordingResolver:
    """Stands in for the media store LCM-006 will provide."""

    def __init__(self, value="RESOLVED_BY_THE_MEDIA_STORE.png"):
        self.value = value
        self.calls = []

    def resolve(self, field, value):
        self.calls.append((field.id, field.type.value, value))
        return self.value


@pytest.fixture
def workflow(builder):
    builder.add("bindable", FIELDS)
    registry = builder.load()
    assert registry.diagnostics == ()
    return registry.get("bindable")


def test_values_are_written_at_node_inputs_input(workflow):
    graph = bind_values(workflow, {"prompt": "a quiet street", "steps": 12})

    assert graph["20"]["inputs"]["text"] == "a quiet street"
    assert graph["30"]["inputs"]["steps"] == 12
    # An untouched input keeps whatever the export had.
    assert graph["30"]["inputs"]["cfg"] == 6.0


def test_a_yaml_integer_node_id_binds_into_the_json_string_key(workflow):
    assert [target.node for target in workflow.bindings_for("steps")] == ["30"]
    graph = bind_values(workflow, {"prompt": "x", "steps": 7})
    assert graph["30"]["inputs"]["steps"] == 7


def test_binding_never_mutates_the_loaded_graph(workflow):
    before = json.dumps(workflow.graph, sort_keys=True)

    first = bind_values(workflow, {"prompt": "first", "steps": 1})
    second = bind_values(workflow, {"prompt": "second", "steps": 2})

    # Two bindings of one workflow do not see each other.
    assert first["20"]["inputs"]["text"] == "first"
    assert second["20"]["inputs"]["text"] == "second"
    assert first["30"]["inputs"]["steps"] == 1
    assert second["30"]["inputs"]["steps"] == 2

    # And the source is exactly as it was loaded.
    assert json.dumps(workflow.graph, sort_keys=True) == before
    assert workflow.graph["20"]["inputs"]["text"] == "placeholder"


def test_the_returned_graph_shares_no_mutable_structure_with_the_source(workflow):
    graph = bind_values(workflow, {"prompt": "x"})

    assert graph is not workflow.graph
    assert graph["30"] is not workflow.graph["30"]
    assert graph["30"]["inputs"] is not workflow.graph["30"]["inputs"]

    # A nested list in the copy is not the source's list either.
    graph["30"]["inputs"]["conditioning"].append("tampered")
    assert workflow.graph["30"]["inputs"]["conditioning"] == ["20", 0]


def test_the_file_on_disk_is_not_touched(workflow):
    before = workflow.workflow_path.read_bytes()
    bind_values(workflow, {"prompt": "x", "steps": 3})
    assert workflow.workflow_path.read_bytes() == before


def test_an_omitted_optional_field_leaves_the_graphs_own_value(workflow):
    graph = bind_values(workflow, {"prompt": "x"})
    assert graph["30"]["inputs"]["steps"] == 20
    assert graph["30"]["inputs"]["enabled"] is True


def test_an_unknown_field_id_is_refused_rather_than_dropped(workflow):
    with pytest.raises(BindingError) as error:
        bind_values(workflow, {"prompt": "x", "stpes": 12})
    assert "'stpes'" in str(error.value)
    assert "bindable" in str(error.value)


def test_a_missing_required_value_is_refused(workflow):
    with pytest.raises(BindingError) as error:
        bind_values(workflow, {"steps": 12})
    assert "'prompt'" in str(error.value)


def test_a_media_field_needs_a_resolver(workflow):
    with pytest.raises(BindingError) as error:
        bind_values(workflow, {"prompt": "x", "picture": {"media_id": "m-1"}})
    assert "media value resolver" in str(error.value)
    assert "'picture'" in str(error.value)


def test_the_resolver_decides_what_a_media_field_binds(workflow):
    resolver = RecordingResolver()
    graph = bind_values(
        workflow,
        {"prompt": "x", "picture": {"media_id": "m-1"}},
        media_resolver=resolver,
    )

    assert graph["40"]["inputs"]["image"] == "RESOLVED_BY_THE_MEDIA_STORE.png"
    assert resolver.calls == [("picture", "image", {"media_id": "m-1"})]


def test_a_workflow_without_media_needs_no_resolver(workflow):
    graph = bind_values(workflow, {"prompt": "x", "steps": 5})
    assert graph["40"]["inputs"]["image"] == "PLACEHOLDER.png"


def test_graph_copy_hands_out_a_copy(workflow):
    first = workflow.graph_copy()
    first["30"]["inputs"]["steps"] = 999
    assert workflow.graph["30"]["inputs"]["steps"] == 20


def test_binding_an_example_workflow(builder):
    """The published examples are bindable, not merely parseable."""

    registry = load_registry(EXAMPLES_ROOT)
    txt2img = registry.get("example_txt2img")

    graph = bind_values(txt2img, {"prompt": "a quiet street", "steps": 12, "sampler": "dpmpp_2m"})
    assert graph["20"]["inputs"]["text"] == "a quiet street"
    assert graph["40"]["inputs"]["steps"] == 12
    assert graph["40"]["inputs"]["sampler_name"] == "dpmpp_2m"
    assert txt2img.graph["40"]["inputs"]["steps"] == 20


# -- one logical field, several graph inputs (T-0045) -----------------------
#
# A ComfyUI graph routinely carries the same user concept in several places.
# Every node below starts from a *distinct* placeholder, so a test that only
# checked the first target would still see the others holding their own
# original value: the fixture cannot make these assertions true by itself.

MULTI_GRAPH = {
    "10": {"class_type": "ExampleTextEncoder", "inputs": {"text": "first placeholder"}},
    "11": {"class_type": "ExampleTextEncoder", "inputs": {"text": "second placeholder"}},
    "12": {"class_type": "ExampleTextEncoder", "inputs": {"text": "third placeholder"}},
    "20": {"class_type": "ExampleSampler", "inputs": {"seed": 1, "steps": 20}},
    "21": {"class_type": "ExampleSampler", "inputs": {"noise_seed": 2}},
    "30": {"class_type": "ExampleMediaLoader", "inputs": {"image": "FIRST.png"}},
    "31": {"class_type": "ExampleMediaLoader", "inputs": {"image": "SECOND.png"}},
}


def multi_graph():
    return json.loads(json.dumps(MULTI_GRAPH))


def load_multi(builder, fields, stem="multi"):
    builder.add(stem, fields, graph=multi_graph())
    registry = builder.load()
    assert [str(diagnostic) for diagnostic in registry.diagnostics] == []
    return registry.get(stem)


def test_a_single_mapping_bind_is_exactly_a_one_element_list(builder):
    """The shape every definition written before T-0045 uses, unchanged."""

    mapping = load_multi(
        builder,
        """
        - id: prompt
          label: Prompt
          type: multiline
          bind: {node: "10", input: text}
        """,
        stem="as_mapping",
    )
    listed = load_multi(
        builder,
        """
        - id: prompt
          label: Prompt
          type: multiline
          bind:
            - {node: "10", input: text}
        """,
        stem="as_list",
    )

    assert mapping.bindings_for("prompt") == listed.bindings_for("prompt")
    assert len(mapping.bindings_for("prompt")) == 1
    assert bind_values(mapping, {"prompt": "x"}) == bind_values(listed, {"prompt": "x"})


def test_one_prompt_field_writes_into_both_conditioning_nodes(builder):
    workflow = load_multi(
        builder,
        """
        - id: prompt
          label: Prompt
          type: multiline
          bind:
            - {node: "10", input: text}
            - {node: "11", input: text}
        """,
    )

    graph = bind_values(workflow, {"prompt": "a quiet street"})

    assert graph["10"]["inputs"]["text"] == "a quiet street"
    assert graph["11"]["inputs"]["text"] == "a quiet street"
    # The loaded graph is still untouched, both targets included.
    assert workflow.graph["10"]["inputs"]["text"] == "first placeholder"
    assert workflow.graph["11"]["inputs"]["text"] == "second placeholder"


def test_three_targets_are_all_written_and_keep_the_authors_order(builder):
    workflow = load_multi(
        builder,
        """
        - id: prompt
          label: Prompt
          type: multiline
          bind:
            - {node: "12", input: text}
            - {node: "10", input: text}
            - {node: "11", input: text}
        """,
    )

    assert [(target.node, target.input) for target in workflow.bindings_for("prompt")] == [
        ("12", "text"),
        ("10", "text"),
        ("11", "text"),
    ]

    graph = bind_values(workflow, {"prompt": "three at once"})
    assert graph["10"]["inputs"]["text"] == "three at once"
    assert graph["11"]["inputs"]["text"] == "three at once"
    assert graph["12"]["inputs"]["text"] == "three at once"


def test_one_seed_field_sets_seed_on_one_node_and_noise_seed_on_another(builder):
    workflow = load_multi(
        builder,
        """
        - id: seed
          label: Seed
          type: integer
          role: seed
          bind:
            - {node: "20", input: seed}
            - {node: "21", input: noise_seed}
        """,
    )

    graph = bind_values(workflow, {"seed": 123456})

    assert graph["20"]["inputs"]["seed"] == 123456
    assert graph["21"]["inputs"]["noise_seed"] == 123456


def test_one_image_field_puts_the_same_resolved_value_in_both_loaders(builder):
    workflow = load_multi(
        builder,
        """
        - id: picture
          label: Picture
          type: image
          required: true
          bind:
            - {node: "30", input: image}
            - {node: "31", input: image}
        """,
    )
    resolver = RecordingResolver()

    graph = bind_values(workflow, {"picture": {"media_id": "m-1"}}, media_resolver=resolver)

    assert graph["30"]["inputs"]["image"] == "RESOLVED_BY_THE_MEDIA_STORE.png"
    assert graph["31"]["inputs"]["image"] == "RESOLVED_BY_THE_MEDIA_STORE.png"
    # Resolved once for the field, not once per target: two calls could return
    # two different values, and the user supplied one picture.
    assert resolver.calls == [("picture", "image", {"media_id": "m-1"})]


def test_an_omitted_multi_target_field_leaves_every_targets_own_value(builder):
    workflow = load_multi(
        builder,
        """
        - id: prompt
          label: Prompt
          type: multiline
          bind:
            - {node: "10", input: text}
            - {node: "11", input: text}
        """,
    )

    graph = bind_values(workflow, {})

    assert graph["10"]["inputs"]["text"] == "first placeholder"
    assert graph["11"]["inputs"]["text"] == "second placeholder"
