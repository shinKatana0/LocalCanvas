"""The semantic importer: logical inputs, safe controls and stable ids.

The properties this file exists to hold, in the order the design states them:

* a logical field id survives a graph renumbered from end to end, and survives
  a value being edited -- the single most important property in the card,
  because My defaults, the current draft, saved setups and an imported profile
  are all keyed on it;
* the four media cases, each built as its own graph: the same picture twice is
  one field with two bindings, a source and a reference are two fields, a
  matte is not exposed at all, and two pictures nothing tells apart are
  ``NEEDS_REVIEW``;
* several image loaders are never by themselves a reason to refuse a workflow;
* collapsing happens only on provable sameness: one seed in two inputs is one
  field, two different seeds are two;
* Advanced carries every safe control, and the locked families -- model, VAE,
  encoder, LoRA file, path, device, output directory, backend and debug --
  reach no field the app would ever receive;
* an uncertain, potentially structural control is ``NEEDS_REVIEW`` rather than
  exposed or dropped;
* ``translatable`` appears only on prompt-like text;
* a duration hint is emitted only where the graph declares the rate;
* everything generated loads through the real registry loader, an invalid one
  never replaces a valid one, and two runs over the same bytes produce the
  same bytes.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

import pytest

from localcanvas_gateway.workflows import load_registry
from localcanvas_gateway.workflows.sync import (
    KEPT_NOTICE,
    WorkflowState,
    analyse,
    definitions as definitions_module,
    run_sync,
)
from sync_fixtures import SyncWorkspace, write_json

FIXED = datetime(2026, 1, 2, 3, 4, 5, tzinfo=timezone.utc)


@pytest.fixture()
def workspace(tmp_path: Path) -> SyncWorkspace:
    return SyncWorkspace(tmp_path)


# ==========================================================================
# Graphs.  Every one is built by the test that needs it, from node types that
# exist nowhere but here: nothing in this suite depends on a real ComfyUI, a
# real model or a real node pack, and no model family is named anywhere.
# ==========================================================================


def text_to_image() -> Dict[str, Any]:
    """A whole ordinary generation: two prompts, a sampler, a save."""

    return {
        "4": {
            "class_type": "ExampleWeightsLoader",
            "inputs": {"ckpt_name": "chosen-weights.safetensors"},
        },
        "5": {
            "class_type": "ExampleEmptyCanvas",
            "inputs": {"width": 1024, "height": 768, "batch_size": 1},
        },
        "6": {
            "class_type": "ExampleTextEncode",
            "inputs": {"text": "a quiet street at dawn", "clip": ["4", 1]},
        },
        "7": {
            "class_type": "ExampleTextEncode",
            "inputs": {"text": "blurry, low quality", "clip": ["4", 1]},
        },
        "3": {
            "class_type": "ExampleSampler",
            "inputs": {
                "seed": 12345,
                "steps": 24,
                "cfg": 6.5,
                "sampler_name": "euler",
                "scheduler": "normal",
                "denoise": 1.0,
                "add_noise": True,
                "model": ["4", 0],
                "positive": ["6", 0],
                "negative": ["7", 0],
                "latent_image": ["5", 0],
            },
        },
        "8": {
            "class_type": "ExampleDecode",
            "inputs": {"samples": ["3", 0], "vae": ["4", 2]},
        },
        "9": {
            "class_type": "ExampleSave",
            "inputs": {"filename_prefix": "generated", "images": ["8", 0]},
        },
    }


def renumbered(graph: Dict[str, Any], offset: int = 700) -> Dict[str, Any]:
    """The same graph with every node id moved, and every wire moved with it.

    This is the re-export a user produces by opening a workflow in ComfyUI,
    changing nothing that matters and saving it again.
    """

    mapping = {node: str(int(node) + offset) for node in graph}
    moved: Dict[str, Any] = {}
    for node, body in graph.items():
        inputs = {}
        for name, value in body["inputs"].items():
            if isinstance(value, list) and len(value) == 2 and value[0] in mapping:
                inputs[name] = [mapping[value[0]], value[1]]
            else:
                inputs[name] = value
        moved[mapping[node]] = {"class_type": body["class_type"], "inputs": inputs}
    return moved


def ids_of(graph: Dict[str, Any]) -> List[str]:
    plan = analyse(graph)
    assert not plan.problems, plan.problems
    return [field.id for field in plan.fields]


def field_named(plan, field_id: str):
    found = [item for item in plan.fields if item.id == field_id]
    assert found, "no field {!r}; there are {}".format(
        field_id, [item.id for item in plan.fields]
    )
    return found[0]


def imported(workspace: SyncWorkspace, graph: Dict[str, Any], *, name: str = "one"):
    """Run one whole sync over one graph and return (report, registry)."""

    folder = workspace.sources[0] if workspace.sources else workspace.add_source()
    write_json(folder / "{}.json".format(name), graph)
    workspace.write_config()
    report = run_sync(workspace.load(), now=FIXED)
    registry = load_registry(workspace.repo / "config" / "local" / "workflows")
    return report, registry


def only_workflow(report):
    assert len(report.workflows) == 1, [item.state for item in report.workflows]
    return report.workflows[0]


# ==========================================================================
# Stable ids -- the requirement everything else serves
# ==========================================================================


def test_a_graph_renumbered_from_end_to_end_keeps_every_logical_id() -> None:
    """The single most important property in this card.

    The check has two halves, and both are needed: the ids are identical, and
    the renumbering really happened -- the graphs share no node id at all, and
    the bindings really do point at the new numbers.  Without the second half
    an implementation that quietly ignored the second graph would pass.
    """

    original = text_to_image()
    moved = renumbered(original)

    assert set(original) & set(moved) == set(), "nothing was renumbered"

    before = analyse(original)
    after = analyse(moved)

    assert [item.id for item in before.fields] == [item.id for item in after.fields]
    assert before.fields, "no field was produced, so nothing was compared"

    before_targets = {
        item.id: sorted(node for node, _ in item.targets) for item in before.fields
    }
    after_targets = {
        item.id: sorted(node for node, _ in item.targets) for item in after.fields
    }
    for field_id, nodes in before_targets.items():
        assert after_targets[field_id] != nodes, (
            "field {!r} still binds to {}, so the graph under test was not "
            "really renumbered".format(field_id, nodes)
        )


def test_a_renumbered_graph_keeps_its_ids_through_a_whole_changed_sync(
    workspace: SyncWorkspace,
) -> None:
    """End to end, which is where the ids actually matter.

    The second run sees a CHANGED workflow -- different bytes, same file --
    and the definition it writes has to carry exactly the field ids the first
    one did, because that is what a user's saved settings are keyed on.
    """

    folder = workspace.add_source()
    write_json(folder / "one.json", text_to_image())
    workspace.write_config()
    run_sync(workspace.load(), now=FIXED)
    definition = workspace.repo / "config" / "local" / "workflows" / "one.yaml"
    first = load_registry(definition.parent).workflows[0]

    write_json(folder / "one.json", renumbered(text_to_image()))
    report = run_sync(workspace.load(), now=FIXED)

    assert only_workflow(report).state is WorkflowState.CHANGED
    second = load_registry(definition.parent).workflows[0]
    assert [item.id for item in second.inputs] == [item.id for item in first.inputs]
    assert second.bindings_for("seed") != first.bindings_for("seed"), (
        "the second definition binds where the first one did, so the graph did "
        "not move"
    )


def test_editing_a_value_never_moves_an_id() -> None:
    """A CHANGED workflow whose semantic identity is unchanged keeps its ids.

    Which is the same statement as "no id is derived from a value": the two
    graphs below differ in every literal a user would ever type.
    """

    original = text_to_image()
    edited = text_to_image()
    edited["6"]["inputs"]["text"] = "a harbour at night"
    edited["7"]["inputs"]["text"] = "text, watermark"
    edited["3"]["inputs"]["seed"] = 999999
    edited["3"]["inputs"]["steps"] = 8
    edited["5"]["inputs"]["width"] = 512

    assert ids_of(original) == ids_of(edited)


def test_no_node_type_from_the_graph_reaches_the_definition() -> None:
    """A node id never crosses to the app, and neither does a node's type.

    `docs/architecture.md` keeps the graph gateway-side, and a custom node's
    name is kept out of what LocalCanvas presents.  An id or a
    label built out of ``class_type`` would put a node pack's name in a user's
    settings file for ever.
    """

    graph = text_to_image()
    for node in graph:
        graph[node]["class_type"] = "ZzDistinctiveNodeType" + node

    plan = analyse(graph)
    assert not plan.problems, plan.problems
    document = definitions_module.definition_document(
        plan, workflow_id="w", name="w", workflow_relative="g.json"
    )
    rendered = definitions_module.render_definition(document)

    assert "ZzDistinctiveNodeType" in json.dumps(graph), "the fixture proves nothing"
    assert "ZzDistinctiveNodeType" not in rendered
    for field in plan.fields:
        assert "zzdistinctive" not in field.id.lower()
        assert "ZzDistinctive" not in field.label


# ==========================================================================
# Collapsing: provable sameness, and nothing weaker
# ==========================================================================


def test_one_seed_in_two_inputs_is_one_field_with_two_bindings() -> None:
    graph = {
        "1": {"class_type": "ExampleSampler", "inputs": {"seed": 42, "steps": 20}},
        "2": {
            "class_type": "ExampleRefiner",
            "inputs": {"noise_seed": 42, "latent": ["1", 0]},
        },
    }

    plan = analyse(graph)

    assert not plan.problems, plan.problems
    seed = field_named(plan, "seed")
    assert sorted(seed.targets) == [("1", "seed"), ("2", "noise_seed")]
    assert seed.role_hint == "seed"


def test_two_legitimately_different_seeds_stay_two_fields() -> None:
    """Two stages of one pipeline, each with its own seed.

    They are distinguishable -- the first sampler's output is the second's
    input -- so both are exposed, with ids taken from that difference and not
    from a node id.
    """

    graph = {
        "1": {"class_type": "ExampleSampler", "inputs": {"seed": 111, "latent": ["3", 0]}},
        "2": {"class_type": "ExampleSampler", "inputs": {"seed": 222, "latent": ["1", 0]}},
        "3": {"class_type": "ExampleEmptyCanvas", "inputs": {"width": 512}},
        "4": {"class_type": "ExampleDecode", "inputs": {"samples": ["2", 0]}},
    }

    plan = analyse(graph)

    assert not plan.problems, plan.problems
    seeds = [item for item in plan.fields if item.id.startswith("seed")]
    assert len(seeds) == 2, [item.id for item in plan.fields]
    assert len({item.id for item in seeds}) == 2
    assert sorted(target for item in seeds for target in item.targets) == [
        ("1", "seed"),
        ("2", "seed"),
    ]
    for item in seeds:
        assert len(item.targets) == 1
    assert ids_of(graph) == ids_of(renumbered(graph)), (
        "the two seeds were told apart by something that moves with the node ids"
    )


def test_two_seeds_nothing_tells_apart_are_never_given_invented_ids() -> None:
    """The honest limit of the fingerprint, stated as a test.

    Two branches wired identically, differing only in a value: there is no
    evidence that says which is which, so no id is minted for either and a
    person is asked.  An implementation that fell back on the node id would
    produce two ids here and would be wrong the next time the graph is saved.
    """

    graph = {
        "1": {"class_type": "ExampleSampler", "inputs": {"seed": 111, "latent": ["5", 0]}},
        "2": {"class_type": "ExampleSampler", "inputs": {"seed": 222, "latent": ["5", 0]}},
        "3": {"class_type": "ExampleDecode", "inputs": {"samples": ["1", 0]}},
        "4": {"class_type": "ExampleDecode", "inputs": {"samples": ["2", 0]}},
        "5": {"class_type": "ExampleEmptyCanvas", "inputs": {"width": 512}},
    }

    plan = analyse(graph)

    assert plan.needs_review
    assert plan.fields == ()
    assert "wired identically" in " ".join(plan.problems)
    assert "'seed'" in " ".join(plan.problems)


def test_values_that_merely_look_alike_are_not_collapsed() -> None:
    """Same value, different roles: two controls, not one.

    ``steps`` and ``cfg`` both being 20 is a coincidence of the graph, and a
    user who lowered one and found the other had moved would have no way to
    understand what happened.
    """

    graph = {
        "1": {"class_type": "ExampleSampler", "inputs": {"steps": 20, "cfg": 20}},
    }

    plan = analyse(graph)

    assert not plan.problems, plan.problems
    assert {item.id for item in plan.fields} == {"steps", "cfg"}
    for item in plan.fields:
        assert len(item.targets) == 1


# ==========================================================================
# The four media cases, each with its own graph
# ==========================================================================


def one_picture_graph() -> Dict[str, Any]:
    return {
        "1": {"class_type": "ExampleImageLoader", "inputs": {"image": "photo.png"}},
        "2": {"class_type": "ExampleEdit", "inputs": {"image": ["1", 0]}},
    }


def test_one_picture_in_the_graph_is_one_logical_image() -> None:
    plan = analyse(one_picture_graph())

    assert not plan.problems, plan.problems
    image = field_named(plan, "image")
    assert image.type == "image"
    assert image.required is True
    assert image.section == "main"
    assert image.has_default is False
    assert image.targets == (("1", "image"),)


def test_case_a_the_same_picture_twice_is_one_field_with_two_bindings() -> None:
    graph = {
        "1": {"class_type": "ExampleImageLoader", "inputs": {"image": "photo.png"}},
        "2": {"class_type": "ExampleImageLoader", "inputs": {"image": "photo.png"}},
        "3": {"class_type": "ExampleEdit", "inputs": {"image": ["1", 0]}},
        "4": {"class_type": "ExampleEdit", "inputs": {"image": ["2", 0]}},
    }

    plan = analyse(graph)

    assert not plan.problems, plan.problems
    images = [item for item in plan.fields if item.type == "image"]
    assert len(images) == 1, [item.id for item in plan.fields]
    assert sorted(images[0].targets) == [("1", "image"), ("2", "image")]


def test_case_b_a_source_and_a_reference_are_two_fields_named_for_their_part() -> None:
    graph = {
        "1": {"class_type": "ExampleImageLoader", "inputs": {"image": "photo.png"}},
        "2": {"class_type": "ExampleImageLoader", "inputs": {"image": "another.png"}},
        "3": {
            "class_type": "ExampleStyleTransfer",
            "inputs": {"image": ["1", 0], "reference_image": ["2", 0]},
        },
    }

    plan = analyse(graph)

    assert not plan.problems, plan.problems
    assert {item.id for item in plan.fields} == {"image", "reference_image"}
    assert field_named(plan, "image").targets == (("1", "image"),)
    assert field_named(plan, "reference_image").targets == (("2", "image"),)


def test_case_c_a_technical_matte_is_not_exposed_at_all() -> None:
    graph = {
        "1": {"class_type": "ExampleImageLoader", "inputs": {"image": "photo.png"}},
        "2": {"class_type": "ExampleImageLoader", "inputs": {"image": "helper.png"}},
        "3": {
            "class_type": "ExampleInpaint",
            "inputs": {"image": ["1", 0], "mask": ["2", 0]},
        },
    }

    plan = analyse(graph)

    assert not plan.problems, plan.problems
    assert [item.id for item in plan.fields] == ["image"]
    assert field_named(plan, "image").targets == (("1", "image"),)
    hidden = [item for item in plan.not_exposed if item.exposure == "technical"]
    assert [(item.node, item.input) for item in hidden] == [("2", "image")], (
        "the matte was dropped without a word, which is not the same as not "
        "exposing it"
    )


def test_case_d_two_pictures_in_the_same_part_of_the_graph_need_review() -> None:
    graph = {
        "1": {"class_type": "ExampleImageLoader", "inputs": {"image": "photo.png"}},
        "2": {"class_type": "ExampleImageLoader", "inputs": {"image": "another.png"}},
        "3": {"class_type": "ExampleEdit", "inputs": {"image": ["1", 0]}},
        "4": {"class_type": "ExampleEdit", "inputs": {"image": ["2", 0]}},
    }

    plan = analyse(graph)

    assert plan.needs_review
    assert plan.fields == ()
    assert "which picture belongs in which slot" in " ".join(plan.problems)


def test_several_image_loaders_are_never_by_themselves_unsupported(
    workspace: SyncWorkspace,
) -> None:
    """The failure of an earlier importer generation, held shut by a test.

    Three loaders, three distinct parts to play: the workflow imports, and no
    state in this run is ``UNSUPPORTED_INPUT``.
    """

    graph = {
        "1": {"class_type": "ExampleImageLoader", "inputs": {"image": "a.png"}},
        "2": {"class_type": "ExampleImageLoader", "inputs": {"image": "b.png"}},
        "3": {"class_type": "ExampleImageLoader", "inputs": {"image": "c.png"}},
        "4": {
            "class_type": "ExampleCompose",
            "inputs": {
                "image": ["1", 0],
                "reference_image": ["2", 0],
                "background_image": ["3", 0],
            },
        },
    }

    report, registry = imported(workspace, graph)

    assert only_workflow(report).state is WorkflowState.NEW
    assert report.counts()[WorkflowState.UNSUPPORTED_INPUT.value] == 0
    assert sorted(item.id for item in registry.workflows[0].inputs) == [
        "background_image",
        "image",
        "reference_image",
    ]


def test_a_video_input_is_a_video_field() -> None:
    graph = {
        "1": {"class_type": "ExampleVideoLoader", "inputs": {"video": "clip.mp4"}},
        "2": {"class_type": "ExampleUpscale", "inputs": {"video": ["1", 0]}},
    }

    plan = analyse(graph)

    assert not plan.problems, plan.problems
    video = field_named(plan, "video")
    assert video.type == "video"
    assert video.required is True
    assert video.has_default is False


# ==========================================================================
# Main, Advanced, Locked
# ==========================================================================


def test_advanced_carries_every_safe_control_the_graph_has() -> None:
    """Not a small whitelist: the test of a good import is that a user rarely
    has to reopen ComfyUI to tune generation behaviour."""

    plan = analyse(text_to_image())

    assert not plan.problems, plan.problems
    by_section: Dict[str, List[str]] = {"main": [], "advanced": []}
    for item in plan.fields:
        by_section[item.section].append(item.id)

    assert by_section["main"] == ["prompt"]
    assert sorted(by_section["advanced"]) == [
        "add_noise",
        "batch_size",
        "cfg",
        "denoise",
        "height",
        "negative_prompt",
        "sampler_name",
        "scheduler",
        "seed",
        "steps",
        "width",
    ]
    assert field_named(plan, "add_noise").type == "boolean"
    assert field_named(plan, "add_noise").default is True
    assert field_named(plan, "sampler_name").type == "string"
    assert field_named(plan, "sampler_name").default == "euler"
    assert field_named(plan, "cfg").type == "float"
    assert field_named(plan, "seed").role_hint == "seed"
    assert field_named(plan, "width").pair == "width"
    assert field_named(plan, "height").pair == "height"


def test_a_fixed_loras_strength_is_tunable_and_its_file_is_not() -> None:
    """The line the design draws, in one graph.

    A number a user may turn is a number; changing which file loads is
    structural, and no field ever offers it.
    """

    graph = {
        "1": {
            "class_type": "ExampleAdapterLoader",
            "inputs": {
                "lora_name": "chosen-adapter.safetensors",
                "strength_model": 0.8,
                "strength_clip": 0.6,
            },
        },
        "2": {"class_type": "ExampleSampler", "inputs": {"model": ["1", 0], "steps": 20}},
    }

    plan = analyse(graph)

    assert not plan.problems, plan.problems
    assert sorted(item.id for item in plan.fields) == [
        "steps",
        "strength_clip",
        "strength_model",
    ]
    assert field_named(plan, "strength_model").type == "float"
    assert field_named(plan, "strength_model").section == "advanced"
    assert [(item.node, item.input) for item in plan.not_exposed] == [("1", "lora_name")]


#: One graph position, filled twice: once with something structural and once
#: with something safe.  The second arm is what makes the first an absence
#: worth asserting -- it proves the input was genuinely there to be exposed.
LOCKED_FAMILIES = [
    pytest.param("ckpt_name", "chosen-weights.safetensors", id="model"),
    pytest.param("vae_name", "chosen-decoder.safetensors", id="vae"),
    pytest.param("clip_name", "chosen-encoder.safetensors", id="encoder"),
    pytest.param("lora_name", "chosen-adapter.safetensors", id="lora-file"),
    pytest.param("input_path", "X:/somewhere/on/a/disk", id="path"),
    pytest.param("device", "gpu", id="device"),
    pytest.param("output_dir", "renders", id="output-directory"),
    pytest.param("backend", "fast", id="backend"),
    pytest.param("debug", True, id="debug"),
]


@pytest.mark.parametrize("name,value", LOCKED_FAMILIES)
def test_a_locked_family_reaches_no_field_the_app_would_receive(
    workspace: SyncWorkspace, name: str, value: Any
) -> None:
    graph = {
        "1": {"class_type": "ExampleLoader", "inputs": {name: value}},
        "2": {
            "class_type": "ExampleTextEncode",
            "inputs": {"text": "a quiet street", "model": ["1", 0]},
        },
    }

    report, registry = imported(workspace, graph)

    assert only_workflow(report).state is WorkflowState.NEW, only_workflow(report).reason
    workflow = registry.workflows[0]
    assert [item.id for item in workflow.inputs] == ["prompt"]
    for field in workflow.inputs:
        assert ("1", name) not in workflow.bindings_for(field.id)
    view = json.dumps(workflow.detail_view())
    assert name not in view
    assert str(value) not in view
    assert [(item.node, item.input) for item in report.workflows[0].plan.not_exposed] == [
        ("1", name)
    ]


@pytest.mark.parametrize("name,value", LOCKED_FAMILIES)
def test_the_same_graph_position_holding_something_safe_is_exposed(
    name: str, value: Any
) -> None:
    """The other half of the test above.

    Without it, "no field binds node 1" would also pass for an importer that
    never looked at node 1 at all, or at any node that is not wired to a
    sampler.  With the input renamed to something the graph proves is safe, a
    field appears at exactly that position -- so the absence above is a
    decision and not an oversight.
    """

    safe_value = "balanced" if isinstance(value, str) else value
    graph = {
        "1": {"class_type": "ExampleLoader", "inputs": {"mode": safe_value}},
        "2": {
            "class_type": "ExampleTextEncode",
            "inputs": {"text": "a quiet street", "model": ["1", 0]},
        },
    }

    plan = analyse(graph)

    assert not plan.problems, plan.problems
    assert field_named(plan, "mode").targets == (("1", "mode"),)


def test_an_uncertain_control_is_neither_exposed_nor_dropped() -> None:
    """Neither proved safe nor proved structural: a person decides.

    The reason names the node, the input and the value, because a curator
    with a hundred workflows needs to find it in ComfyUI without guessing.
    """

    graph = {
        "1": {
            "class_type": "ExampleUnknownNode",
            "inputs": {"preset_selection": "studio-b"},
        },
        "2": {"class_type": "ExampleTextEncode", "inputs": {"text": "a street"}},
    }

    plan = analyse(graph)

    assert plan.needs_review
    assert plan.fields == ()
    problem = " ".join(plan.problems)
    assert "preset_selection" in problem
    assert "studio-b" in problem
    assert "Node 1" in problem


def test_an_uncertain_control_stops_the_definition_being_written(
    workspace: SyncWorkspace,
) -> None:
    folder = workspace.add_source()
    write_json(
        folder / "one.json",
        {"1": {"class_type": "ExampleUnknownNode", "inputs": {"preset": "studio-b"}}},
    )
    workspace.write_config()

    report = run_sync(workspace.load(), now=FIXED)

    assert only_workflow(report).state is WorkflowState.NEEDS_REVIEW
    assert report.definitions_written == 0
    assert "preset" in only_workflow(report).reason
    # Not an empty definition, and not a folder of them either: the inventory
    # is the only thing this run had anything to write.
    assert workspace.output_names() == ["workflow-inventory.json"]


# ==========================================================================
# Translation
# ==========================================================================


def test_translatable_marks_prompts_and_nothing_else() -> None:
    graph = text_to_image()
    graph["1"] = {
        "class_type": "ExampleAdapterLoader",
        "inputs": {"lora_name": "chosen-adapter.safetensors", "strength_model": 0.5},
    }

    plan = analyse(graph)

    assert not plan.problems, plan.problems
    translatable = sorted(item.id for item in plan.fields if item.translatable)
    assert translatable == ["negative_prompt", "prompt"]
    for item in plan.fields:
        if item.translatable:
            assert item.type in ("string", "multiline")
    assert field_named(plan, "sampler_name").translatable is False
    assert field_named(plan, "scheduler").translatable is False
    assert field_named(plan, "strength_model").translatable is False


def test_the_negative_prompt_is_decided_by_the_wiring_and_not_by_a_name() -> None:
    """Both encoders call their input ``text``; only the graph says which is
    which, and swapping the two wires swaps the two fields."""

    graph = text_to_image()
    graph["3"]["inputs"]["positive"] = ["7", 0]
    graph["3"]["inputs"]["negative"] = ["6", 0]

    plan = analyse(graph)

    assert not plan.problems, plan.problems
    assert field_named(plan, "prompt").targets == (("7", "text"),)
    assert field_named(plan, "negative_prompt").targets == (("6", "text"),)


def test_a_text_feeding_both_polarities_is_not_guessed_at() -> None:
    graph = {
        "1": {"class_type": "ExampleTextEncode", "inputs": {"text": "a street"}},
        "2": {
            "class_type": "ExampleSampler",
            "inputs": {"positive": ["1", 0], "negative": ["1", 0]},
        },
    }

    plan = analyse(graph)

    assert plan.needs_review
    assert "which prompt it is cannot be decided" in " ".join(plan.problems)


# ==========================================================================
# Duration, and the rate that has to be declared
# ==========================================================================


def video_graph(rate: Optional[Any] = 24, second_rate: Optional[Any] = None):
    """A clip of ``length`` frames, played at whatever the graph declares.

    A second rate, when the test asks for one, lives on a node of another type
    -- so the two rate fields are told apart by the wiring and the graph is
    importable.  What is then under test is the rate, and not the ability to
    tell two identical nodes apart, which has its own test.
    """

    graph: Dict[str, Any] = {
        "1": {"class_type": "ExampleVideoLatent", "inputs": {"length": 49}},
        "2": {"class_type": "ExampleSampler", "inputs": {"latent": ["1", 0], "steps": 20}},
        "3": {"class_type": "ExampleVideoCombine", "inputs": {"images": ["2", 0]}},
    }
    if rate is not None:
        graph["3"]["inputs"]["frame_rate"] = rate
    if second_rate is not None:
        graph["4"] = {
            "class_type": "ExampleVideoPreview",
            "inputs": {"frame_rate": second_rate, "preview": ["2", 0]},
        }
    return graph


def test_a_frame_count_is_shown_as_a_duration_when_the_graph_declares_the_rate() -> None:
    plan = analyse(video_graph(rate=24))

    assert not plan.problems, plan.problems
    length = field_named(plan, "length")
    assert length.type == "integer"
    assert length.duration_fps == 24.0
    # The value is never changed by the hint: what binds is the frame count.
    assert length.default == 49
    assert field_named(plan, "frame_rate").duration_fps is None


def test_a_frame_count_with_no_declared_rate_stays_a_plain_number() -> None:
    """`docs/workflow-schema.md`: declared, never inferred.

    The field is still called ``length`` and still holds a plausible frame
    count -- so the only thing that changed is the evidence, and the hint is
    gone with it.
    """

    plan = analyse(video_graph(rate=None))

    assert not plan.problems, plan.problems
    length = field_named(plan, "length")
    assert length.default == 49
    assert length.duration_fps is None


def test_two_declared_rates_are_not_one_rate() -> None:
    plan = analyse(video_graph(rate=24, second_rate=30))

    assert not plan.problems, plan.problems
    assert field_named(plan, "length").duration_fps is None


def test_the_same_rate_declared_twice_is_still_one_rate() -> None:
    plan = analyse(video_graph(rate=24, second_rate=24))

    assert not plan.problems, plan.problems
    assert field_named(plan, "length").duration_fps == 24.0


def test_a_rate_that_is_not_a_usable_number_is_no_rate() -> None:
    plan = analyse(video_graph(rate=0))

    assert not plan.problems, plan.problems
    assert field_named(plan, "length").duration_fps is None


# ==========================================================================
# What is written, and what it takes to write it
# ==========================================================================


def test_a_generated_definition_loads_through_the_real_registry_loader(
    workspace: SyncWorkspace,
) -> None:
    report, registry = imported(workspace, text_to_image())

    assert registry.diagnostics == ()
    workflow = registry.workflows[0]
    assert workflow.id == "one"
    # T-0055: the stem, made readable, and only the stem -- ``one.json``.
    assert workflow.name == "One"
    assert [item.id for item in workflow.inputs][0] == "prompt"
    assert only_workflow(report).definition.written is True
    assert only_workflow(report).definition.path == (
        workspace.repo / "config" / "local" / "workflows" / "one.yaml"
    )


def test_every_bind_target_names_a_node_and_an_input_that_exist(
    workspace: SyncWorkspace,
) -> None:
    graph = {
        "1": {"class_type": "ExampleSampler", "inputs": {"seed": 7, "steps": 20}},
        "2": {"class_type": "ExampleRefiner", "inputs": {"noise_seed": 7, "l": ["1", 0]}},
    }

    _, registry = imported(workspace, graph)

    workflow = registry.workflows[0]
    assert workflow.graph, "the workflow was loaded without its graph"
    seed_targets = workflow.bindings_for("seed")
    assert len(seed_targets) == 2, seed_targets
    for field in workflow.inputs:
        for binding in workflow.bindings_for(field.id):
            assert binding.node in workflow.graph
            assert binding.input in workflow.graph[binding.node]["inputs"]


def test_the_generated_definition_is_exactly_this(workspace: SyncWorkspace) -> None:
    """One whole file, asserted verbatim.

    A counted assertion -- eleven fields, two of them translatable -- would
    survive a shape change that moved ``bind`` or dropped ``section``, and the
    definition format is a contract with a loader and with whoever opens the
    file next.

    This graph is also the *partial evidence* case, and the presentation block
    below is what that has to look like (T-0055).  It has no output stage at
    all, so nothing proves what comes out of it: ``badge``, ``group`` and
    ``short_description`` are absent from the file rather than filled with
    something plausible, and ``category`` is absent because it is never
    generated at all.

    Both fields carry a ``help`` since T-0131, and they get there by different
    routes: ``seed``'s comes from its graph input name, and ``prompt``'s from
    the role the wiring proved, because its own input is called ``text``.  The
    file is asserted whole, so a ``help`` that appeared under one and not the
    other fails here, and so does one whose words changed.
    """

    graph = {
        "1": {"class_type": "ExampleTextEncode", "inputs": {"text": "a quiet street"}},
        "2": {
            "class_type": "ExampleSampler",
            "inputs": {"seed": 5, "positive": ["1", 0]},
        },
    }
    _, registry = imported(workspace, graph, name="a small one")

    written = (
        workspace.repo / "config" / "local" / "workflows" / "a-small-one.yaml"
    ).read_text(encoding="utf-8")
    graph_name = (registry.workflows[0].workflow_path).name

    assert written == (
        "# Generated by the LocalCanvas workflow sync from the workflow named below.\n"
        "# Edit it freely -- it is yours. A later sync writes this file again when the\n"
        "# workflow it came from has changed, or when this importer now reads that\n"
        "# unchanged workflow differently. Either way it keeps the name, presentation,\n"
        "# translation setting and every field label and help line you wrote, and\n"
        "# generates everything else again from the workflow.\n"
        "id: a-small-one\n"
        "name: A Small One\n"
        "workflow: ../imported-workflows/{}\n"
        "presentation:\n"
        "  best_for:\n"
        "  - Working from a written description you type in\n"
        "  - Reproducing an exact result by keeping its seed\n"
        "  how_to_use: Describe the subject, the setting and the light you want to see."
        " Keep the seed to get the same result again, or change it for a different one.\n"
        "  input_summary: Prompt only\n"
        "  example_prompt: a quiet street\n"
        "inputs:\n"
        "- id: prompt\n"
        "  label: Prompt\n"
        "  type: multiline\n"
        "  required: true\n"
        "  section: main\n"
        "  default: a quiet street\n"
        "  help: Describe what you want to see. More detail gives more to go on.\n"
        "  translatable: true\n"
        "  bind:\n"
        "  - node: '1'\n"
        "    input: text\n"
        "- id: seed\n"
        "  label: Seed\n"
        "  type: integer\n"
        "  section: advanced\n"
        "  default: 5\n"
        "  help: The starting point for the randomness."
        " The same number repeats a result.\n"
        "  role: seed\n"
        "  bind:\n"
        "  - node: '2'\n"
        "    input: seed\n"
    ).format(graph_name)


def test_the_imported_copy_of_the_graph_is_the_source_file_byte_for_byte(
    workspace: SyncWorkspace,
) -> None:
    folder = workspace.add_source()
    source = folder / "one.json"
    write_json(source, text_to_image(), indent=4)
    workspace.write_config()

    run_sync(workspace.load(), now=FIXED)

    copies = sorted((workspace.repo / "config" / "local" / "imported-workflows").glob("*.json"))
    assert len(copies) == 1, copies
    assert copies[0].read_bytes() == source.read_bytes()


def test_the_same_bytes_produce_the_same_definition_twice(tmp_path: Path) -> None:
    """Determinism, measured in two workspaces rather than two runs.

    Two runs in one workspace would also pass for an importer that noticed
    the file was already there and left it alone, which is a different
    property (and has its own test below).
    """

    graph = text_to_image()
    produced = []
    for index in range(2):
        workspace = SyncWorkspace(tmp_path / "run {}".format(index))
        folder = workspace.add_source()
        write_json(folder / "one.json", graph)
        workspace.write_config()
        run_sync(workspace.load(), now=FIXED)
        produced.append(
            (workspace.repo / "config" / "local" / "workflows" / "one.yaml").read_bytes()
        )

    assert produced[0] == produced[1]
    assert b"prompt" in produced[0], "the runs produced nothing to compare"


def test_a_workflow_that_has_not_changed_keeps_the_definition_on_disk(
    workspace: SyncWorkspace,
) -> None:
    """Whatever a curator wrote in it is worth more than a regeneration.

    T-0055 will put prose in these files by hand; a sync that rewrote them
    every run would delete it.
    """

    folder = workspace.add_source()
    write_json(folder / "one.json", text_to_image())
    workspace.write_config()
    run_sync(workspace.load(), now=FIXED)

    definition = workspace.repo / "config" / "local" / "workflows" / "one.yaml"
    original = definition.read_text(encoding="utf-8")
    edited = original.replace("name: One", "name: My favourite one")
    assert edited != original, "the edit changed nothing, so nothing was tested"
    definition.write_text(edited, encoding="utf-8")

    report = run_sync(workspace.load(), now=FIXED)

    assert only_workflow(report).state is WorkflowState.UNCHANGED
    assert definition.read_text(encoding="utf-8") == edited
    assert only_workflow(report).definition.written is False
    assert only_workflow(report).definition.skipped == KEPT_NOTICE


def test_a_definition_that_was_deleted_is_written_again(
    workspace: SyncWorkspace,
) -> None:
    folder = workspace.add_source()
    write_json(folder / "one.json", text_to_image())
    workspace.write_config()
    run_sync(workspace.load(), now=FIXED)
    definition = workspace.repo / "config" / "local" / "workflows" / "one.yaml"
    definition.unlink()

    report = run_sync(workspace.load(), now=FIXED)

    assert only_workflow(report).state is WorkflowState.UNCHANGED
    assert definition.exists()
    assert only_workflow(report).definition.written is True


def test_a_dry_run_writes_no_definition_but_says_where_one_would_go(
    workspace: SyncWorkspace,
) -> None:
    folder = workspace.add_source()
    write_json(folder / "one.json", text_to_image())
    workspace.write_config()

    report = run_sync(workspace.load(), dry_run=True, now=FIXED)

    assert workspace.output_names() == []
    written = only_workflow(report).definition
    assert written.written is False
    assert written.path == workspace.repo / "config" / "local" / "workflows" / "one.yaml"
    assert report.definitions_written == 0


# ==========================================================================
# An invalid definition never replaces a valid one.  Two interlocks, and each
# one fails on its own.
# ==========================================================================


def _break_the_renderer(monkeypatch: pytest.MonkeyPatch) -> None:
    """Render a definition that binds to a node no graph has.

    Not a syntax error: something the loader's own rules refuse, so what is
    proved is that the loader really is consulted and not that YAML parsing
    happens to fail.
    """

    def render(document):
        document = dict(document)
        document["inputs"] = [
            {
                "id": "prompt",
                "label": "Prompt",
                "type": "multiline",
                "bind": [{"node": "nonexistent", "input": "text"}],
            }
        ]
        return definitions_module.GENERATED_HEADER + json.dumps(document)

    monkeypatch.setattr(definitions_module, "render_definition", render)


def test_a_definition_that_would_not_load_never_replaces_the_one_that_does(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    folder = workspace.add_source()
    write_json(folder / "one.json", text_to_image())
    workspace.write_config()
    run_sync(workspace.load(), now=FIXED)
    definition = workspace.repo / "config" / "local" / "workflows" / "one.yaml"
    before = definition.read_bytes()
    assert before, "there was no previous definition to protect"

    changed = text_to_image()
    changed["3"]["inputs"]["steps"] = 30
    write_json(folder / "one.json", changed)
    _break_the_renderer(monkeypatch)

    report = run_sync(workspace.load(), now=FIXED)

    assert definition.read_bytes() == before
    assert load_registry(definition.parent).diagnostics == ()
    workflow = only_workflow(report)
    assert workflow.state is WorkflowState.NEEDS_REVIEW
    assert "does not load" in workflow.definition.problem
    assert report.definitions_failed == 1


def test_a_swap_that_fails_leaves_the_previous_definition_alone(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The second interlock, and it fails on its own.

    The generated definition here is perfectly valid and passes the loader; it
    is the atomic replace that is refused, which is the failure a full disk or
    a locked file produces.
    """

    folder = workspace.add_source()
    write_json(folder / "one.json", text_to_image())
    workspace.write_config()
    run_sync(workspace.load(), now=FIXED)
    definition = workspace.repo / "config" / "local" / "workflows" / "one.yaml"
    before = definition.read_bytes()

    changed = text_to_image()
    changed["3"]["inputs"]["steps"] = 30
    write_json(folder / "one.json", changed)

    def refuse(source, target):
        raise OSError(13, "Access is denied")

    monkeypatch.setattr(definitions_module, "_replace", refuse)

    report = run_sync(workspace.load(), now=FIXED)

    assert definition.read_bytes() == before
    workflow = only_workflow(report)
    assert workflow.state is WorkflowState.NEEDS_REVIEW
    assert "left as it was" in workflow.definition.problem
    assert [
        name for name in workspace.output_names() if name.endswith(".tmp")
    ] == [], "a temporary file was left behind"


def test_one_workflow_that_cannot_be_imported_never_stops_the_others(
    workspace: SyncWorkspace,
) -> None:
    folder = workspace.add_source()
    write_json(folder / "good.json", text_to_image())
    write_json(
        folder / "puzzling.json",
        {"1": {"class_type": "ExampleUnknownNode", "inputs": {"preset": "studio-b"}}},
    )
    workspace.write_config()

    report = run_sync(workspace.load(), now=FIXED)

    states = {item.id: item.state.value for item in report.workflows}
    assert states == {"good": "NEW", "puzzling": "NEEDS_REVIEW"}
    registry = load_registry(workspace.repo / "config" / "local" / "workflows")
    assert [workflow.id for workflow in registry.workflows] == ["good"]
    assert registry.diagnostics == ()
