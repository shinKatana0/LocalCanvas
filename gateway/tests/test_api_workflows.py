"""The workflow endpoints, and the guarantee that no graph crosses the boundary.

`docs/architecture.md`: *"The app receives presentation-level workflow
descriptions and typed fields; it never sees or reasons about a node graph."*
The list and detail responses are walked key by key here, because a leak would
be a single forgotten field and nothing about the response would look wrong.
"""

from __future__ import annotations

from typing import Any, Iterator

from workflow_fixtures import EVERY_FIELD, MULTI_TARGET_FIELD, PRESENTATION

#: Keys that belong to the binding view and must never appear in a response.
FORBIDDEN_KEYS = {"bind", "node", "class_type", "graph", "bindings", "workflow_path", "source"}

#: The node types in the test graph.  Not one of them may be named in a body.
GRAPH_CLASS_TYPES = (
    "ExampleLoader",
    "ExampleTextEncoder",
    "ExampleSampler",
    "ExampleMediaLoader",
)


def keys_of(value: Any) -> Iterator[str]:
    """Every key at every depth of a decoded JSON body."""

    if isinstance(value, dict):
        for key, item in value.items():
            yield key
            yield from keys_of(item)
    elif isinstance(value, list):
        for item in value:
            yield from keys_of(item)


def build(gateway_factory, builder, count: int = 1):
    for index in range(count):
        builder.add("flow{}".format(index), EVERY_FIELD, presentation=PRESENTATION)
    return gateway_factory()


def test_the_list_serves_every_workflow_in_registry_order(
    gateway_factory, builder
) -> None:
    harness = build(gateway_factory, builder, count=3)

    body = harness.client.get("/api/v1/workflows").json()

    assert [item["id"] for item in body["workflows"]] == ["flow0", "flow1", "flow2"]


def test_a_summary_entry_has_the_documented_keys(gateway_factory, builder) -> None:
    harness = build(gateway_factory, builder)

    entry = harness.client.get("/api/v1/workflows").json()["workflows"][0]

    assert set(entry) == {"id", "name", "presentation", "input_summary", "required_media"}
    assert entry["input_summary"] == "Prompt only"
    assert entry["required_media"] == []


def test_the_detail_view_adds_the_field_schema(gateway_factory, builder) -> None:
    harness = build(gateway_factory, builder)

    body = harness.client.get("/api/v1/workflows/flow0").json()

    assert [field["id"] for field in body["inputs"]] == [
        "prompt",
        "steps",
        "guidance",
        "enabled",
        "mode",
    ]
    steps = body["inputs"][1]
    assert steps["type"] == "integer"
    assert steps["min"] == 1
    assert steps["max"] == 50
    assert steps["section"] == "advanced"


def test_a_select_field_carries_its_options(gateway_factory, builder) -> None:
    harness = build(gateway_factory, builder)

    body = harness.client.get("/api/v1/workflows/flow0").json()
    mode = [field for field in body["inputs"] if field["id"] == "mode"][0]

    assert mode["options"] == [
        {"value": "fast", "label": "Fast"},
        {"value": "slow", "label": "Slow"},
    ]


def test_no_node_id_node_type_or_bind_block_reaches_the_list(
    gateway_factory, builder
) -> None:
    harness = build(gateway_factory, builder)
    response = harness.client.get("/api/v1/workflows")

    assert not FORBIDDEN_KEYS & set(keys_of(response.json()))
    for class_type in GRAPH_CLASS_TYPES:
        assert class_type not in response.text


def test_no_node_id_node_type_or_bind_block_reaches_the_detail(
    gateway_factory, builder
) -> None:
    harness = build(gateway_factory, builder)
    response = harness.client.get("/api/v1/workflows/flow0")

    assert not FORBIDDEN_KEYS & set(keys_of(response.json()))
    for class_type in GRAPH_CLASS_TYPES:
        assert class_type not in response.text


def test_a_field_with_two_targets_leaks_no_more_than_a_field_with_one(
    gateway_factory, builder
) -> None:
    """Several targets are still one field, and still no graph (T-0045)."""

    builder.add("multi", MULTI_TARGET_FIELD, presentation=PRESENTATION)
    harness = gateway_factory()

    detail = harness.client.get("/api/v1/workflows/multi")
    for response in (harness.client.get("/api/v1/workflows"), detail):
        assert not FORBIDDEN_KEYS & set(keys_of(response.json()))
        for class_type in GRAPH_CLASS_TYPES:
            assert class_type not in response.text

    # One logical field, whatever it drives behind the boundary.
    assert [field["id"] for field in detail.json()["inputs"]] == ["prompt"]

    workflow = harness.state.registry.get("multi")
    assert [(target.node, target.input) for target in workflow.bindings_for("prompt")] == [
        ("20", "text"),
        ("10", "name"),
    ]
    for target in workflow.bindings_for("prompt"):
        assert '"{}"'.format(target.node) not in detail.text


def test_the_gateway_still_holds_the_bindings_it_did_not_send(
    gateway_factory, builder
) -> None:
    """The absence above is a boundary, not an empty registry."""

    harness = build(gateway_factory, builder)
    workflow = harness.state.registry.get("flow0")

    assert [target.node for target in workflow.bindings_for("prompt")] == ["20"]
    assert workflow.graph["20"]["class_type"] == "ExampleTextEncoder"


def test_an_unknown_workflow_is_a_404_in_the_documented_shape(
    gateway_factory, builder
) -> None:
    harness = build(gateway_factory, builder)

    response = harness.client.get("/api/v1/workflows/no_such_workflow")

    assert response.status_code == 404
    assert response.json() == {
        "error": {
            "code": "workflow_not_found",
            "message": "That workflow is no longer available.",
            "field": None,
        }
    }


def test_a_media_workflow_declares_what_it_needs(gateway_factory, builder) -> None:
    from workflow_fixtures import IMAGE_FIELD

    builder.add("with_image", EVERY_FIELD + IMAGE_FIELD)
    harness = gateway_factory()

    entry = harness.client.get("/api/v1/workflows").json()["workflows"][0]

    assert entry["required_media"] == ["image"]


def test_a_rejected_definition_does_not_take_the_registry_down(
    gateway_factory, builder
) -> None:
    builder.add("good", EVERY_FIELD)
    builder.add("broken", "- id: prompt\n  label: Prompt\n  type: nonsense\n")
    harness = gateway_factory()

    body = harness.client.get("/api/v1/workflows").json()

    assert [item["id"] for item in body["workflows"]] == ["good"]
