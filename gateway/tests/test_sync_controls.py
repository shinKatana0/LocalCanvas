"""The control inventory: every literal input, and the decision taken about it.

The properties this file exists to hold:

* **completeness.**  One entry per literal input of the graph, no more and no
  fewer, and every ``(node, input)`` pair exactly once.  That is the whole
  mechanism: an input *present* carries the decision, so an input *absent* was
  never a candidate -- it is a wire to another node's output.  Without the
  equality a reader cannot tell "recognised and deliberately locked" from
  "never seen", and both look like silence.
* **a stable slug on every locked entry**, from a frozen set, with every slug
  in that set produced by a judgement branch that exists.  The prose reason is
  for reading; the slug is for grouping thirty workflows' worth of them.
* **a reported control is never an editable one.**  The ``(node, input)`` pairs
  the inventory reports as locked or technical and the ``bind`` targets of the
  generated definition are disjoint.  This card makes structural values
  *visible to a curator*; it does not turn one of them into an app field.
  The second guard over that same property is
  ``test_api_boundary.py::test_no_response_body_ever_names_a_node_class``,
  which is a different test in a different file on purpose -- neither is
  allowed to be the only one that can fail.
* **the report document carries it**, with every key present on every entry,
  because `scripts/sync-workflows.ps1` runs under ``Set-StrictMode`` and a
  key that is sometimes absent is a throw waiting for the run that matters.

No graph here comes from anywhere: every node type is invented in this file,
and no model, family or node pack is named.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Set, Tuple

import pytest

from localcanvas_gateway.workflows import load_registry
from localcanvas_gateway.workflows.sync import (
    HIDDEN_SECTIONS,
    LOCKED_KINDS,
    WorkflowState,
    analyse,
    report_document,
    run_sync,
)
from localcanvas_gateway.workflows.sync.contract import (
    RuntimeContract,
    read_object_info,
)
from sync_fixtures import UI_GRAPH, SyncWorkspace, write_json

FIXED = datetime(2026, 1, 2, 3, 4, 5, tzinfo=timezone.utc)


@pytest.fixture()
def workspace(tmp_path: Path) -> SyncWorkspace:
    return SyncWorkspace(tmp_path)


# ==========================================================================
# Graphs
# ==========================================================================


def decided_graph() -> Dict[str, Any]:
    """A graph the importer can read end to end, with four decisions in it.

    One prompt (main), two numbers (advanced), two structural strings (locked,
    by two different branches) and a matte (technical).  Every other input is
    a wire, which is what makes the absences in these tests mean something.
    """

    return {
        "1": {
            "class_type": "ExampleWeightsLoader",
            "inputs": {"ckpt_name": "chosen-weights.safetensors"},
        },
        "2": {
            "class_type": "ExampleTextEncode",
            "inputs": {"text": "a quiet street at dawn", "clip": ["1", 1]},
        },
        "3": {
            "class_type": "ExampleSampler",
            "inputs": {
                "seed": 12345,
                "steps": 24,
                "model": ["1", 0],
                "positive": ["2", 0],
            },
        },
        "4": {
            "class_type": "ExampleMatteLoader",
            "inputs": {"mask": "cutout.png"},
        },
        "5": {
            "class_type": "ExampleComposite",
            "inputs": {"mask": ["4", 0], "samples": ["3", 0]},
        },
        "6": {
            "class_type": "ExampleSave",
            "inputs": {"filename_prefix": "generated", "images": ["5", 0]},
        },
    }


def other_decided_graph() -> Dict[str, Any]:
    """A second importable graph, locked by the other two branches.

    A disjointness that held on one fixture would be a statement about that
    fixture.  This one locks a path and a device, and exposes a number whose
    name merely *looks* structural -- ``strength_model`` is the tunable the
    schema insists a user may set.
    """

    return {
        "10": {
            "class_type": "ExampleAdapterLoader",
            "inputs": {
                "lora_name": "a-style.safetensors",
                "strength_model": 0.8,
                "device": 0,
            },
        },
        "11": {
            "class_type": "ExampleTextEncode",
            "inputs": {"text": "a lighthouse at noon", "model": ["10", 0]},
        },
        "12": {
            "class_type": "ExampleSampler",
            "inputs": {"noise_seed": 9, "cfg": 6.5, "conditioning": ["11", 0]},
        },
        "13": {
            "class_type": "ExampleWriter",
            "inputs": {"output_dir": "C:/renders", "images": ["12", 0]},
        },
    }


def indistinguishable_graph() -> Dict[str, Any]:
    """Two same-role inputs the graph gives no way to tell apart.

    Both ``steps`` inputs sit on the same class of node, are fed by the same
    canvas and are consumed by the same class of decoder, so their structural
    fingerprints collide; only their values differ.  ``_fields_from`` refuses
    to mint an id for either -- and the two of them are still literal inputs a
    curator has to be able to find.
    """

    return {
        "1": {"class_type": "ExampleSampler", "inputs": {"steps": 20, "latent": ["5", 0]}},
        "2": {"class_type": "ExampleSampler", "inputs": {"steps": 30, "latent": ["5", 0]}},
        "3": {"class_type": "ExampleDecode", "inputs": {"samples": ["1", 0]}},
        "4": {"class_type": "ExampleDecode", "inputs": {"samples": ["2", 0]}},
        "5": {"class_type": "ExampleEmptyCanvas", "inputs": {"width": 512}},
    }


def both_polarities_graph() -> Dict[str, Any]:
    """One text feeding a sampler's ``positive`` and its ``negative`` alike.

    The wiring is what decides a prompt's polarity, and here it decides
    nothing: the same conditioning arrives at both inputs, one hop away each.
    ``_role_for`` returns a problem rather than a role, so this input never
    becomes a candidate -- and must still be in the inventory, or it is
    indistinguishable from a wire.
    """

    return {
        "1": {"class_type": "ExampleTextEncode", "inputs": {"text": "a wet street"}},
        "2": {
            "class_type": "ExampleSampler",
            "inputs": {"seed": 7, "positive": ["1", 0], "negative": ["1", 0]},
        },
    }


def undecided_graph() -> Dict[str, Any]:
    """The same graph plus one input nothing in it settles.

    The workflow is ``NEEDS_REVIEW`` and no definition is written -- and the
    inventory still has to account for every literal input, including the ones
    that were fine.  A run that reported only what it could import would be
    exactly the silence this card is about.
    """

    graph = decided_graph()
    graph["7"] = {"class_type": "ExampleThing", "inputs": {"style": "PLACEHOLDER"}}
    return graph


def literal_inputs(graph: Dict[str, Any]) -> Set[Tuple[str, str]]:
    """Every ``(node, input)`` a user's value could be written into.

    Written here rather than taken from ``semantics.is_literal``: a count that
    comes from the code under test is that code agreeing with itself.  A list
    or a mapping is a wire to another node's output and is not one of these.
    """

    found: Set[Tuple[str, str]] = set()
    for node, body in graph.items():
        for name, value in body["inputs"].items():
            if isinstance(value, (str, int, float, bool)):
                found.add((node, name))
    return found


def wired_inputs(graph: Dict[str, Any]) -> Set[Tuple[str, str]]:
    found: Set[Tuple[str, str]] = set()
    for node, body in graph.items():
        for name, value in body["inputs"].items():
            if isinstance(value, list):
                found.add((node, name))
    return found


def imported(workspace: SyncWorkspace, graph: Dict[str, Any]):
    """One whole sync over one graph: (report, registry)."""

    folder = workspace.sources[0] if workspace.sources else workspace.add_source()
    write_json(folder / "one.json", graph)
    workspace.write_config()
    report = run_sync(workspace.load(), now=FIXED)
    registry = load_registry(workspace.repo / "config" / "local" / "workflows")
    return report, registry


def sections_of(plan) -> Dict[Tuple[str, str], str]:
    return {(item.node, item.input): item.section for item in plan.controls}


# ==========================================================================
# Completeness -- the property the rest of the card rests on
# ==========================================================================


@pytest.mark.parametrize(
    "graph", [decided_graph(), undecided_graph()], ids=["decided", "needs-review"]
)
def test_every_literal_input_appears_exactly_once(graph: Dict[str, Any]) -> None:
    """The equality, both ways, and the pairs as well as the count.

    A count alone would pass for an inventory that listed one input twice and
    another not at all, which is precisely the failure that would make an
    absence unreadable.
    """

    plan = analyse(graph)
    pairs = [(item.node, item.input) for item in plan.controls]
    expected = literal_inputs(graph)

    assert len(pairs) == len(expected)
    assert sorted(pairs) == sorted(expected)
    assert len(set(pairs)) == len(pairs), "an input was inventoried twice"


def test_a_needs_review_graph_still_accounts_for_the_inputs_that_were_fine() -> None:
    """The half a "report only what was imported" bug would drop.

    ``plan.fields`` is empty for this graph -- nothing is imported on a guess
    -- so the inventory is the only thing that can still say what the other
    six inputs are.
    """

    plan = analyse(undecided_graph())

    assert plan.problems, "this graph was supposed to need review"
    assert plan.fields == ()
    assert sections_of(plan)[("7", "style")] == "needs_review"
    assert sections_of(plan)[("2", "text")] == "main"
    assert sections_of(plan)[("3", "seed")] == "advanced"


def test_a_group_the_collapsing_rejected_is_still_in_the_inventory() -> None:
    """``needs_review`` reached after the candidates were built, not before.

    An UNCERTAIN verdict is one of three ways an input ends up here; this is
    the second, and it is decided by ``_fields_from`` long after ``analyse``'s
    scan has moved on.  Without an entry each, two inputs that were **seen and
    refused** would be indistinguishable in the report from two that were
    never candidates at all -- the exact confusion this inventory exists to
    end.

    The equality first, then both entries verbatim: the sentence is the one
    the collapsing already composed, and it names both inputs, so a curator
    reading either row learns what the other one was.
    """

    graph = indistinguishable_graph()
    plan = analyse(graph)
    entries = {(item.node, item.input): item for item in plan.controls}

    assert len(plan.controls) == len(literal_inputs(graph)) == 3
    assert sorted(entries) == [("1", "steps"), ("2", "steps"), ("5", "width")]

    refused = (
        "node 1 input 'steps', node 2 input 'steps' hold different values for "
        "'steps' and are wired identically, so nothing tells one from the "
        "other and no id can be minted for either."
    )
    for target in (("1", "steps"), ("2", "steps")):
        assert entries[target].section == "needs_review", target
        assert entries[target].reason == refused, target
        assert entries[target].field is None
        assert entries[target].kind is None
    # And the input the graph *could* decide is still decided, so this is a
    # statement about the two that were refused and not about a plan that
    # gave up on the whole graph.
    assert entries[("5", "width")].section == "advanced"
    assert entries[("5", "width")].field == "width"


def test_an_input_whose_part_could_not_be_established_is_still_in_the_inventory() -> None:
    """The third way in, and the one the scan itself takes.

    The wiring decides a prompt's polarity; here the same conditioning reaches
    a sampler's ``positive`` and its ``negative`` at the same distance, so
    ``_role_for`` hands back a problem instead of a role and the input never
    becomes a candidate.  It is nonetheless a literal input somebody wrote a
    value into, and the report has to say so.
    """

    graph = both_polarities_graph()
    plan = analyse(graph)
    entries = {(item.node, item.input): item for item in plan.controls}

    assert len(plan.controls) == len(literal_inputs(graph)) == 2
    assert sorted(entries) == [("1", "text"), ("2", "seed")]

    assert entries[("1", "text")].section == "needs_review"
    assert entries[("1", "text")].reason == (
        "Node 1 input 'text' feeds both a positive and a negative conditioning "
        "input, so which prompt it is cannot be decided."
    )
    assert entries[("1", "text")].field is None
    assert entries[("1", "text")].kind is None
    # The other literal was decided normally, so the entry above is about this
    # input rather than about an inventory that marks everything unreadable.
    assert entries[("2", "seed")].section == "advanced"
    assert entries[("2", "seed")].field == "seed"


def test_the_inventory_uses_one_vocabulary_and_covers_every_decision() -> None:
    """All five sections on graphs that between them take every branch.

    Also the fixture check: if a graph stopped producing one of these the
    tests above would still pass while covering less, so the sections are
    asserted as an exact set.
    """

    sections = set(sections_of(analyse(undecided_graph())).values())

    assert sections == {"main", "advanced", "locked", "technical", "needs_review"}


# ==========================================================================
# Recognised and locked, versus never seen at all
# ==========================================================================


def test_a_locked_control_is_listed_and_a_wire_is_absent() -> None:
    """Both halves of the question a curator actually asks, on one graph.

    Present, with its node, its input and the sentence that locked it -- so
    "this was recognised and deliberately locked" is readable.  Absent, for
    every input that is a wire -- so "this was never a candidate" is readable
    as the *other* thing.  Without the second half an inventory that simply
    listed everything would look the same.
    """

    graph = decided_graph()
    plan = analyse(graph)
    by_target = {(item.node, item.input): item for item in plan.controls}

    locked = by_target[("1", "ckpt_name")]
    assert locked.section == "locked"
    assert locked.field is None
    assert locked.reason == (
        "input 'ckpt_name' names a file of weights to load; which file loads "
        "is what the workflow *is*, not how it generates."
    )

    wires = wired_inputs(graph)
    assert wires == {
        ("2", "clip"),
        ("3", "model"),
        ("3", "positive"),
        ("5", "mask"),
        ("5", "samples"),
        ("6", "images"),
    }, "the fixture no longer wires what this test is about"
    for target in wires:
        assert target not in by_target


def test_a_technical_picture_is_listed_rather_than_dropped() -> None:
    """Case C of the four media cases, which the docstring says is recorded."""

    plan = analyse(decided_graph())
    by_target = {(item.node, item.input): item for item in plan.controls}

    matte = by_target[("4", "mask")]
    assert matte.section == "technical"
    assert matte.reason == (
        "input 'mask' on node 4 is a matte the graph uses internally, not a "
        "picture a user chooses."
    )


# ==========================================================================
# The slug
# ==========================================================================

#: One input per branch of ``semantics.classify()`` that locks, plus the
#: technical-media case only the graph can decide.  The slug each one has to
#: produce is named here, so a branch that started returning a different one
#: fails rather than quietly regrouping a curator's report.
SLUG_CASES = [
    pytest.param("ckpt_name", "chosen-weights.safetensors", "weights_file", id="weights"),
    pytest.param("style_reference", "C:/somewhere/else", "filesystem_path", id="path"),
    pytest.param("upload", "image", "editor_bookkeeping", id="bookkeeping"),
    pytest.param("device", 0, "machine_setting", id="machine"),
    pytest.param("output_dir", "renders", "file_reference", id="file-word"),
    pytest.param("mode", "https://example.invalid/x", "url", id="web-address"),
    pytest.param("model_type", "compact", "model_architecture", id="model-architecture"),
]


@pytest.mark.parametrize("name,value,slug", SLUG_CASES)
def test_each_locking_branch_carries_its_own_slug(
    name: str, value: Any, slug: str
) -> None:
    graph = {
        "1": {"class_type": "ExampleLoader", "inputs": {name: value}},
        "2": {
            "class_type": "ExampleTextEncode",
            "inputs": {"text": "a quiet street", "model": ["1", 0]},
        },
    }

    plan = analyse(graph)
    entry = {(item.node, item.input): item for item in plan.controls}[("1", name)]

    assert entry.section == "locked"
    assert entry.kind == slug
    assert [(item.node, item.input, item.kind) for item in plan.not_exposed] == [
        ("1", name, slug)
    ]


def structural_load_graph() -> Dict[str, Any]:
    """A graph whose one unsettled input sits on a node that loads something.

    ``interpretation`` is in no vocabulary of `semantics.py`'s and ``compact``
    is a plain word, so the input is ``UNCERTAIN`` on the graph's own evidence
    -- which is the only situation either the runtime contract's choice lists
    or T-0100's judgement is allowed to touch.
    """

    return {
        "1": {
            "class_type": "ExampleEncoderLoader",
            "inputs": {"interpretation": "compact"},
        },
        "2": {
            "class_type": "ExampleTextEncode",
            "inputs": {"text": "a quiet street", "clip": ["1", 1]},
        },
    }


def structural_load_contract() -> RuntimeContract:
    """A runtime that declares choices for that input, read by the real parser.

    T-0100's slug is produced only where a runtime declared a usable list,
    because the judgement gates the *upgrade* and never the review: without
    this declaration the same input is ``NEEDS_REVIEW`` and carries no slug at
    all.
    """

    return read_object_info(
        {
            "ExampleEncoderLoader": {
                "input": {"required": {"interpretation": [["compact", "wide"], {}]}}
            }
        },
        identity_digest="sha256:controls",
    )


def node_shape_graph() -> Dict[str, Any]:
    """A graph whose one unsettled input holds a shape of its own node.

    ``codec`` is in no vocabulary of `semantics.py`'s and ``h264`` is a plain
    word, so the input is ``UNCERTAIN`` on the graph's own evidence.  (Since
    T-0195 the node-shape declaration is asked before ``classify`` and would
    lock this input whatever ``classify`` said; ``UNCERTAIN`` is simply the
    case T-0185 was written around.)
    """

    return {
        "1": {"class_type": "ExampleVideoSave", "inputs": {"codec": "h264"}},
        "2": {
            "class_type": "ExampleTextEncode",
            "inputs": {"text": "a quiet street", "latent": ["1", 0]},
        },
    }


def node_shape_contract() -> RuntimeContract:
    """A runtime declaring that input as a choice between shapes of the node.

    Read by the real parser, from the shape a current ComfyUI really writes:
    each option is an object carrying its own inputs, so choosing one changes
    what the node has rather than what it is given.  T-0185's slug is produced
    only where a runtime declared one of these -- without the declaration the
    same input is ``NEEDS_REVIEW`` and carries no slug at all.
    """

    return read_object_info(
        {
            "ExampleVideoSave": {
                "input": {
                    "required": {
                        "codec": [
                            "COMFY_DYNAMICCOMBO_V3",
                            {
                                "options": [
                                    {"key": "auto", "inputs": {"required": {}}},
                                    {
                                        "key": "h264",
                                        "inputs": {
                                            "optional": {
                                                "encoding": [
                                                    "COMBO",
                                                    {"options": ["auto", "re-encode"]},
                                                ]
                                            }
                                        },
                                    },
                                ]
                            },
                        ]
                    }
                }
            }
        },
        identity_digest="sha256:controls",
    )


def computation_graph() -> Dict[str, Any]:
    """A graph whose one unsettled input is text on a node producing only numbers."""

    return {
        "1": {"class_type": "ExampleArithmetic", "inputs": {"formula": "a + 1"}},
        "2": {
            "class_type": "ExampleSampler",
            "inputs": {"steps": ["1", 0], "seed": 7},
        },
    }


def computation_contract() -> RuntimeContract:
    """A runtime declaring that class's every output a number (T-0218).

    Without it the same input is ``NEEDS_REVIEW`` and carries no slug at all.
    """

    return read_object_info(
        {"ExampleArithmetic": {"input": {"required": {}}, "output": ["FLOAT", "INT"]}},
        identity_digest="sha256:controls",
    )


def model_patch_graph() -> Dict[str, Any]:
    """A graph whose one unsettled input is text on a node producing only a model."""

    return {
        "1": {"class_type": "ExampleLayerPatcher", "inputs": {"picked_layers": "4, 5"}},
        "2": {
            "class_type": "ExampleSampler",
            "inputs": {"model": ["1", 0], "seed": 7},
        },
    }


def model_patch_contract() -> RuntimeContract:
    """A runtime declaring that class's every output a model (T-0241).

    Without it the same input is ``NEEDS_REVIEW`` and carries no slug at all.
    """

    return read_object_info(
        {"ExampleLayerPatcher": {"input": {"required": {}}, "output": ["MODEL"]}},
        identity_digest="sha256:controls",
    )


def declared_default_graph() -> Dict[str, Any]:
    """A graph whose one unsettled input is text saved at its declared default."""

    return {
        "1": {
            "class_type": "ExampleCaptionPainter",
            "inputs": {"tint": "amber", "image": ["2", 0]},
        },
        "2": {"class_type": "ExampleSampler", "inputs": {"seed": 7}},
    }


def declared_default_contract() -> RuntimeContract:
    """A runtime declaring that input ``STRING`` with that default (T-0244).

    Without it the same input is ``NEEDS_REVIEW`` and carries no slug at all.
    """

    return read_object_info(
        {
            "ExampleCaptionPainter": {
                "input": {"required": {"tint": ["STRING", {"default": "amber"}]}},
                "output": ["IMAGE"],
            }
        },
        identity_digest="sha256:controls",
    )


def test_every_slug_in_the_frozen_set_is_produced_by_a_branch() -> None:
    """No slug without a judgement behind it, and none missing either.

    A frozen set nothing produces is a taxonomy invented here rather than a
    name for a decision the importer already takes -- which is the one thing
    this card must not do.
    """

    produced = {slug for _, _, slug in [case.values for case in SLUG_CASES]}
    produced |= {
        item.kind
        for item in analyse(decided_graph()).controls
        if item.kind is not None
    }
    produced |= {
        item.kind
        for item in analyse(
            structural_load_graph(), contract=structural_load_contract()
        ).controls
        if item.kind is not None
    }
    produced |= {
        item.kind
        for item in analyse(
            node_shape_graph(), contract=node_shape_contract()
        ).controls
        if item.kind is not None
    }
    produced |= {
        item.kind
        for item in analyse(
            computation_graph(), contract=computation_contract()
        ).controls
        if item.kind is not None
    }
    produced |= {
        item.kind
        for item in analyse(
            model_patch_graph(), contract=model_patch_contract()
        ).controls
        if item.kind is not None
    }
    produced |= {
        item.kind
        for item in analyse(
            declared_default_graph(), contract=declared_default_contract()
        ).controls
        if item.kind is not None
    }

    assert produced == set(LOCKED_KINDS)


def test_an_exposed_control_carries_no_slug() -> None:
    """The slug says why something is hidden; a visible control has no why."""

    plan = analyse(decided_graph())

    for item in plan.controls:
        if item.section in HIDDEN_SECTIONS:
            assert item.kind in LOCKED_KINDS, item
        else:
            assert item.kind is None, item


# ==========================================================================
# The critical invariant: reporting a control never exposes it
# ==========================================================================


@pytest.mark.parametrize(
    "graph,expected_hidden",
    [
        pytest.param(
            decided_graph(),
            {("1", "ckpt_name"), ("4", "mask"), ("6", "filename_prefix")},
            id="weights-matte-and-file-word",
        ),
        pytest.param(
            other_decided_graph(),
            {("10", "lora_name"), ("10", "device"), ("13", "output_dir")},
            id="weights-device-and-path",
        ),
    ],
)
def test_a_reported_control_is_never_an_editable_one(
    workspace: SyncWorkspace,
    graph: Dict[str, Any],
    expected_hidden: Set[Tuple[str, str]],
) -> None:
    """Disjoint, and proved to have had something to be disjoint from.

    The order matters: the locked and technical pairs are asserted to exist,
    by name, first.  An emptiness test run before anything was reported would
    pass for an importer that reported nothing at all -- which is exactly the
    state this card was filed to fix.
    """

    report, registry = imported(workspace, graph)
    plan = report.workflows[0].plan
    hidden = {
        (item.node, item.input)
        for item in plan.controls
        if item.section in HIDDEN_SECTIONS
    }

    assert hidden == expected_hidden

    bound = {
        (binding.node, binding.input)
        for workflow in registry.workflows
        for field in workflow.inputs
        for binding in workflow.bindings_for(field.id)
    }
    assert bound, "no definition bound anything; the comparison is empty"
    assert bound & hidden == set(), "a locked control reached the app's fields"


def test_a_workflow_that_needs_review_binds_nothing_at_all(
    workspace: SyncWorkspace,
) -> None:
    """The third fixture, where disjointness holds for a different reason.

    Nothing is imported on a guess, so there is no definition and nothing to
    leak into -- and the inventory still names every locked control, which is
    the only way anyone can see them for this workflow at all.
    """

    folder = workspace.add_source()
    write_json(folder / "one.json", undecided_graph())
    workspace.write_config()

    report = run_sync(workspace.load(), now=FIXED)
    workflow = report.workflows[0]
    hidden = {
        (item.node, item.input)
        for item in workflow.plan.controls
        if item.section in HIDDEN_SECTIONS
    }

    assert workflow.state is WorkflowState.NEEDS_REVIEW
    assert hidden == {("1", "ckpt_name"), ("4", "mask"), ("6", "filename_prefix")}
    assert not (workspace.repo / "config" / "local" / "workflows").exists()


def test_the_definition_this_is_measured_against_really_binds_something(
    workspace: SyncWorkspace,
) -> None:
    """The negative control for the disjointness above.

    On the decided graph a definition is written and it does bind inputs, so
    "the two sets do not overlap" is a statement about the decision rather
    than about an empty set.
    """

    _, registry = imported(workspace, decided_graph())

    workflow = registry.workflows[0]
    bound = {
        (binding.node, binding.input)
        for field in workflow.inputs
        for binding in workflow.bindings_for(field.id)
    }
    assert bound == {("2", "text"), ("3", "seed"), ("3", "steps")}


def test_no_locked_value_or_input_name_reaches_the_view_the_app_receives(
    workspace: SyncWorkspace,
) -> None:
    """The inventory is a curator's document; the app is served a different one.

    Asserted on the workflow view the API renders, so that "the report says
    more now" cannot become "the app is told more now" without a failure here.
    """

    _, registry = imported(workspace, decided_graph())

    view = json.dumps(registry.workflows[0].detail_view())
    for hidden in ("ckpt_name", "chosen-weights.safetensors", "filename_prefix",
                   "cutout.png", "ExampleWeightsLoader"):
        assert hidden not in view, hidden


# ==========================================================================
# The document the front end renders
# ==========================================================================


def test_the_report_carries_the_whole_inventory(workspace: SyncWorkspace) -> None:
    report, _ = imported(workspace, decided_graph())

    document = report_document(report)
    workflow = document["workflows"][0]

    # Key by key rather than by counting them: a shape refactor that renamed
    # one would keep the count and break the script that reads it.
    assert sorted(workflow) == [
        "aliases",
        "content_hash",
        "controls",
        "conversion",
        "definition",
        "format",
        "id",
        "reason",
        "source_path",
        "source_relative",
        "state",
    ]
    entries = {(item["node"], item["input"]): item for item in workflow["controls"]}
    assert sorted(entries) == [
        ("1", "ckpt_name"),
        ("2", "text"),
        ("3", "seed"),
        ("3", "steps"),
        ("4", "mask"),
        ("6", "filename_prefix"),
    ]
    assert entries[("1", "ckpt_name")] == {
        "node": "1",
        "input": "ckpt_name",
        "field": None,
        "label": None,
        "section": "locked",
        "kind": "weights_file",
        "reason": (
            "input 'ckpt_name' names a file of weights to load; which file "
            "loads is what the workflow *is*, not how it generates."
        ),
    }
    assert entries[("2", "text")] == {
        "node": "2",
        "input": "text",
        "field": "prompt",
        "label": "Prompt",
        "section": "main",
        "kind": None,
        "reason": "input 'text' holds text written in a person's own language.",
    }
    # Still ASCII on the wire, which is what crosses the pipe on Windows.
    assert json.dumps(document, ensure_ascii=True) == json.dumps(
        document, ensure_ascii=False
    )


def test_a_workflow_no_graph_was_read_for_carries_an_empty_inventory(
    workspace: SyncWorkspace,
) -> None:
    """The key is always there, so the front end never has to ask whether it is.

    An editor export is never analysed, so there is nothing to say about it --
    and "nothing to say" is an empty list, not a missing key: reading an
    absent one throws under ``Set-StrictMode``.
    """

    folder = workspace.add_source()
    write_json(folder / "editor.json", UI_GRAPH)
    workspace.write_config()

    document = report_document(run_sync(workspace.load(), now=FIXED))
    workflow = document["workflows"][0]

    assert workflow["state"] == WorkflowState.NEEDS_API_EXPORT.value
    assert workflow["controls"] == []
    assert "controls" in workflow
