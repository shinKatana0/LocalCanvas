"""A choice of model architecture, family or version is structural, on any node.

T-0100 closed "which model this workflow is" reaching a user as a dropdown, but
only where the node's class type says its job is loading.  The same choice sits
on nodes that load nothing -- a scheduler told which family of model it is
scheduling for, an upscaler told which variant of its weights to use, a hosted
service pinned to the version the workflow was built against -- and there it
reached the user as an editable Advanced select, once T-0180 let the runtime
declare the list in its current shape.  Knowing every legal value is still not
permission to change it: exactly one of them matches the rest of the graph.

T-0193's rule is read from the input's **name**, because on those nodes the name
is the only evidence there is: its word tokens carry ``model`` together with one
of ``type``, ``version``, ``arch``, ``architecture``, ``family`` or ``base``, or
the whole name is ``arch`` or ``architecture``.  This file holds it in the
shapes the review has to be able to break it in:

* **it locks, with its own slug and sentence**, on an ordinary node, in both
  declaration shapes, with and without a runtime to ask -- and it is answered
  before the runtime's choice list is ever asked for;
* **both halves of the pair are required.**  A bare ``model`` or ``model_name``
  selector stays a select, and so does a ``type`` or a ``version`` with no
  ``model`` beside it; each pair word is asked about by name, so dropping one
  from the set fails here;
* **it takes nothing from an older lock**: a weights file, a path, a web address
  and a machine setting under such a name keep their own kind;
* **it holds whatever the input holds** -- a number, a flag, a word under a
  name that also says media.

Every node class, input name and choice below is invented for this file, except
the one declaration T-0193's acceptance criterion names outright
(``SD1``/``SDXL``/``SVD``).  Those three are runtime data here, exactly as a
user's ComfyUI would declare them, and they sit beside the invented ones on
purpose: the rule never reads an option value, so the two must answer alike.
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional, Tuple

import pytest

import localcanvas_gateway.workflows.sync as sync
from localcanvas_gateway.workflows.sync import LOCKED_KINDS, analyse
from localcanvas_gateway.workflows.sync import semantics as semantics_module
from localcanvas_gateway.workflows.sync.contract import (
    RuntimeContract,
    read_object_info,
)
from localcanvas_gateway.workflows.sync.definitions import definition_document
from localcanvas_gateway.workflows.sync.semantics import Exposure, classify

# --------------------------------------------------------------------------
# The inputs this file is about, and the runtime that declares them
# --------------------------------------------------------------------------

#: The slug, written out rather than imported: a test that took it from the code
#: would still pass if the code started grouping this with something else.
ARCHITECTURE_SLUG = "model_architecture"

#: A node whose class type says nothing about loading, so T-0100's judgement
#: cannot be what answers for it.
ORDINARY = "ExampleStepSchedule"

#: A node whose class type does say loading.
LOADING = "ExampleCheckpointLoader"

#: A node standing for a hosted service's generator.
HOSTED = "ExampleHostedImageNode"

#: Invented, deliberately not file-shaped: the file-name refusal must not be
#: what answers here.
FORMS: Tuple[str, ...] = ("compact", "wide", "layered")

#: The one declaration T-0193's acceptance criterion names.
CRITERION_CHOICES: Tuple[str, ...] = ("SD1", "SDXL", "SVD")


def sentence(name: str) -> str:
    """The sentence T-0193 writes, verbatim, for an input called ``name``."""

    return (
        "input {!r} selects which model architecture the workflow is built for, "
        "which only the workflow's author can change safely.".format(name)
    )


def legacy(*values: Any) -> List[Any]:
    """A choice list in ComfyUI's legacy shape: the values at position 0."""

    return [list(values), {}]


def combo(*values: Any) -> List[Any]:
    """The same choice list in the shape current ComfyUI writes."""

    return ["COMBO", {"multiselect": False, "options": list(values)}]


def contract(*declarations: Tuple[str, str, Any]) -> RuntimeContract:
    """A contract read by the production parser from ``/object_info``'s shape."""

    document: Dict[str, Any] = {}
    for class_type, input_name, spec in declarations:
        entry = document.setdefault(
            class_type, {"input": {"required": {}}, "output": [], "name": class_type}
        )
        entry["input"]["required"][input_name] = spec
    return read_object_info(document, identity_digest="sha256:architecture")


def graph_with(class_type: str, inputs: Dict[str, Any]) -> Dict[str, Any]:
    """One readable generation whose node ``1`` carries the inputs under test.

    The rest is an ordinary graph with a prompt, a seed and steps, so "the
    workflow still imports" is something a plan can show rather than something
    an empty graph makes trivially true.
    """

    return {
        "1": {"class_type": class_type, "inputs": dict(inputs)},
        "2": {
            "class_type": "ExampleTextEncode",
            "inputs": {"text": "a quiet street at dawn", "clip": ["1", 1]},
        },
        "3": {
            "class_type": "ExampleSampler",
            "inputs": {"seed": 7, "steps": 20, "model": ["1", 0], "positive": ["2", 0]},
        },
    }


def control_for(plan, node: str, name: str):
    found = [item for item in plan.controls if item.target == (node, name)]
    assert found, "input {!r} of node {} is not in the inventory at all; it has {}".format(
        name, node, [item.target for item in plan.controls]
    )
    return found[0]


def field_named(plan, field_id: str):
    found = [item for item in plan.fields if item.id == field_id]
    assert found, "no field {!r}; there are {}".format(
        field_id, [item.id for item in plan.fields]
    )
    return found[0]


class Watching:
    """A contract that records which choice lists it was asked for."""

    def __init__(self, inner: RuntimeContract) -> None:
        self._inner = inner
        self.asked: List[Tuple[str, str]] = []

    @property
    def identity_digest(self) -> str:
        return self._inner.identity_digest

    @property
    def declared(self) -> int:
        return self._inner.declared

    def options_for(self, class_type: str, input_name: str) -> Optional[Tuple[Any, ...]]:
        self.asked.append((class_type, input_name))
        return self._inner.options_for(class_type, input_name)

    def numeric_for(self, class_type: str, input_name: str):
        return self._inner.numeric_for(class_type, input_name)

    def structural_for(self, class_type: str, input_name: str):
        return self._inner.structural_for(class_type, input_name)


def assert_architecture_lock(plan, name: str, node: str = "1") -> None:
    """Locked with this card's slug and sentence, visible, and holding nothing back."""

    entry = control_for(plan, node, name)
    assert (entry.section, entry.kind) == ("locked", ARCHITECTURE_SLUG), entry
    assert entry.reason == sentence(name)
    assert (node, name, ARCHITECTURE_SLUG) in [
        (item.node, item.input, item.kind) for item in plan.not_exposed
    ]
    assert all((node, name) not in item.targets for item in plan.fields)
    assert plan.problems == (), plan.problems


# ==========================================================================
# The fixture cannot make the assertion true by itself
# ==========================================================================


def test_without_the_rule_the_same_declaration_really_is_an_advanced_select(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The graph, the node and the list are ones the rest of the importer exposes.

    With the pair vocabulary emptied, the very graph and contract every lock
    below is asserted on produce an editable select -- so what locks them is
    T-0193's rule, not a loading word in the class type, a file-shaped option
    or a name another vocabulary already knows.  ``raising=False`` lets the same
    check run on a tree from before T-0193, where it passes as well: that is the
    defect's own shape.
    """

    monkeypatch.setattr(
        semantics_module, "ARCHITECTURE_PAIR_WORDS", frozenset(), raising=False
    )
    monkeypatch.setattr(
        semantics_module, "ARCHITECTURE_INPUT_NAMES", frozenset(), raising=False
    )

    for name, choices in (("model_type", CRITERION_CHOICES), ("model_version", FORMS)):
        plan = analyse(
            graph_with(ORDINARY, {name: choices[1]}),
            contract=contract((ORDINARY, name, combo(*choices))),
        )
        assert plan.problems == ()
        item = field_named(plan, name)
        assert (item.type, item.section, item.options) == ("select", "advanced", choices)


# ==========================================================================
# The rule locks, and says why
# ==========================================================================


def test_a_model_type_on_an_ordinary_node_is_locked_with_its_own_sentence() -> None:
    """The acceptance criterion, as written: ``SD1``/``SDXL``/``SVD`` on a non-loader.

    On main this was an Advanced select of three model families, of which one
    matches the checkpoint the graph loads.
    """

    plan = analyse(
        graph_with(ORDINARY, {"model_type": "SDXL"}),
        contract=contract((ORDINARY, "model_type", combo(*CRITERION_CHOICES))),
    )

    assert_architecture_lock(plan, "model_type")
    assert plan.not_exposed[0].reason == (
        "input 'model_type' selects which model architecture the workflow is "
        "built for, which only the workflow's author can change safely."
    )
    assert [item.id for item in plan.fields] == ["prompt", "seed", "steps"]


@pytest.mark.parametrize("shape", [legacy, combo], ids=["legacy", "combo"])
def test_both_declaration_shapes_lock_alike(shape) -> None:
    plan = analyse(
        graph_with(ORDINARY, {"model_version": "wide"}),
        contract=contract((ORDINARY, "model_version", shape(*FORMS))),
    )

    assert_architecture_lock(plan, "model_version")


def test_with_no_runtime_to_ask_it_is_locked_and_not_held_for_review() -> None:
    """The rule answers from the name, before any list could be asked for.

    Design decision 5: with no runtime contract an in-class input is locked
    rather than held, as every other name-driven lock already is.
    """

    plan = analyse(graph_with(ORDINARY, {"model_type": "compact"}), contract=None)

    assert plan.needs_review is False
    assert_architecture_lock(plan, "model_type")


def test_the_choice_list_is_never_asked_for_it() -> None:
    """Answered before the ``UNCERTAIN`` branch, where the declared lists live.

    The watcher is asked about a neighbouring input nothing settles in the same
    graph, so its silence about the architecture input is a measurement.
    """

    graph = graph_with(ORDINARY, {"model_type": "compact", "preset": "wide"})
    watcher = Watching(
        contract(
            (ORDINARY, "model_type", combo(*FORMS)),
            (ORDINARY, "preset", combo(*FORMS)),
        )
    )

    plan = analyse(graph, contract=watcher)

    assert (ORDINARY, "preset") in watcher.asked, "the watcher was asked nothing"
    assert (ORDINARY, "model_type") not in watcher.asked
    assert_architecture_lock(plan, "model_type")
    assert field_named(plan, "preset").type == "select"


def test_the_reason_repeats_none_of_the_declared_choices_back() -> None:
    plan = analyse(
        graph_with(ORDINARY, {"model_type": "SVD"}),
        contract=contract((ORDINARY, "model_type", combo(*CRITERION_CHOICES))),
    )

    said = control_for(plan, "1", "model_type").reason
    for choice in CRITERION_CHOICES:
        assert choice not in said


def test_the_locked_input_is_never_a_bind_target_of_the_definition() -> None:
    plan = analyse(
        graph_with(ORDINARY, {"model_type": "compact"}),
        contract=contract((ORDINARY, "model_type", combo(*FORMS))),
    )
    document = definition_document(
        plan, workflow_id="one", name="One", workflow_relative="../g.json"
    )

    bound = {
        (target["node"], target["input"])
        for item in document["inputs"]
        for target in item["bind"]
    }
    assert bound, "the definition binds nothing, so the absence below is empty"
    assert ("1", "model_type") not in bound


def test_on_a_loading_node_it_stays_locked_under_this_cards_slug() -> None:
    """Design decision 4: still locked; only the slug and the sentence move.

    On main T-0100 locked this as ``load_setting`` because the runtime offered
    a list on a loading node.  The name now answers first, on that node as on
    any other.
    """

    plan = analyse(
        graph_with(LOADING, {"base_model": "wide"}),
        contract=contract((LOADING, "base_model", legacy(*FORMS))),
    )

    assert_architecture_lock(plan, "base_model")


# ==========================================================================
# The class: which names are in it, spelled which ways
# ==========================================================================

#: Every pair word, named here one by one rather than read out of the module's
#: set -- so a word dropped from the set is a failing case, not a shorter list.
IN_CLASS = [
    pytest.param("model_type", id="model-type"),
    pytest.param("type_model", id="type-model"),
    pytest.param("model_version", id="model-version"),
    pytest.param("version_model", id="version-model"),
    pytest.param("model_arch", id="model-arch"),
    pytest.param("model_architecture", id="model-architecture"),
    pytest.param("model_family", id="model-family"),
    pytest.param("base_model", id="base-model"),
    pytest.param("model_base", id="model-base"),
    pytest.param("arch", id="whole-arch"),
    pytest.param("architecture", id="whole-architecture"),
    pytest.param("Model Type", id="spaced-capitals"),
    pytest.param("MODEL-VERSION", id="dashed-upper"),
    pytest.param("upscale_model_version", id="three-words"),
]


@pytest.mark.parametrize("name", IN_CLASS)
def test_every_name_in_the_class_locks_on_an_ordinary_node(name: str) -> None:
    plan = analyse(
        graph_with(ORDINARY, {name: "compact"}),
        contract=contract((ORDINARY, name, combo(*FORMS))),
    )

    assert_architecture_lock(plan, name)


#: Names outside the class that a careless rule would take in, each with what it
#: holds.  Half of each pair alone, the pair's letters without its words, and the
#: whole-name entries used as a token.
NOT_IN_CLASS = [
    pytest.param("model", "compact", id="bare-model"),
    pytest.param("model_name", "compact", id="model-name"),
    pytest.param("type", "compact", id="bare-type"),
    pytest.param("version", "compact", id="bare-version"),
    pytest.param("base", "compact", id="bare-base"),
    pytest.param("family", "compact", id="bare-family"),
    pytest.param("modeltype", "compact", id="joined-modeltype"),
    pytest.param("modelType", "compact", id="camel-modelType"),
    pytest.param("model_types", "compact", id="plural-types"),
    pytest.param("arch_style", "compact", id="arch-as-a-token"),
    pytest.param("architectural_style", "compact", id="architecture-inside-a-word"),
]


@pytest.mark.parametrize("name,value", NOT_IN_CLASS)
def test_a_name_outside_the_class_stays_a_select(name: str, value: str) -> None:
    """Measured, not assumed: no joined, camel-case or plural spelling of the pair
    occurred among the inputs one measured ComfyUI installation declared, so those stay outside
    the class as the word-token rule leaves them."""

    assert classify(name, value).exposure is Exposure.UNCERTAIN

    plan = analyse(
        graph_with(ORDINARY, {name: value}),
        contract=contract((ORDINARY, name, combo(*FORMS))),
    )

    assert plan.problems == ()
    item = field_named(plan, "_".join(semantics_module._tokens(name)))
    assert (item.type, item.section, item.options) == ("select", "advanced", FORMS)
    assert control_for(plan, "1", name).kind is None


def test_a_hosted_model_selector_stays_a_select_even_offering_only_versions() -> None:
    """Design decisions 1 and 3: each hosted model works, so it is a choice.

    ``model`` offering two version numbers stays a select beside a
    ``model_version`` on the same node that locks -- the name decides, never
    what the options look like.
    """

    plan = analyse(
        graph_with(
            HOSTED,
            {"model": "3.1", "model_name": "wide", "model_version": "3.1"},
        ),
        contract=contract(
            (HOSTED, "model", combo("3.0", "3.1")),
            (HOSTED, "model_name", combo(*FORMS)),
            (HOSTED, "model_version", combo("3.0", "3.1")),
        ),
    )

    assert field_named(plan, "model").options == ("3.0", "3.1")
    assert field_named(plan, "model").type == "select"
    assert field_named(plan, "model_name").options == FORMS
    assert_architecture_lock(plan, "model_version")


def test_numbers_and_flags_carrying_the_model_word_alone_stay_editable() -> None:
    """The measured neighbours: a strength, a seed, an unload flag and
    ``inpaint_model`` (design decision 1, filed as T-0277)."""

    plan = analyse(
        graph_with(
            ORDINARY,
            {
                "strength_model": 0.8,
                "model_seed": 11,
                "unload_model": False,
                "inpaint_model": False,
                "arch_strength": 0.5,
            },
        ),
        contract=None,
    )

    assert plan.problems == ()
    types = {item.id: item.type for item in plan.fields}
    assert {
        "strength_model": "float",
        "model_seed": "integer",
        "unload_model": "boolean",
        "inpaint_model": "boolean",
        "arch_strength": "float",
    }.items() <= types.items(), types


# ==========================================================================
# Where the question is asked among the others
# ==========================================================================


def test_it_holds_whatever_the_input_holds() -> None:
    """A number, a flag and a word under a name that also says media all lock.

    Asked before the number rule, and the name counts as structural before the
    media question -- which would otherwise hold the word for review, where a
    declared list is offered.
    """

    plan = analyse(
        graph_with(
            ORDINARY,
            {"model_version": 3, "base_model": True, "video_model_type": "compact"},
        ),
        contract=contract((ORDINARY, "video_model_type", combo(*FORMS))),
    )

    for name in ("model_version", "base_model", "video_model_type"):
        assert_architecture_lock(plan, name)


OLDER_LOCKS = [
    pytest.param("model_version", "chosen-weights.safetensors", "weights_file", id="weights"),
    pytest.param("model_type", "C:/somewhere/else", "filesystem_path", id="path"),
    pytest.param("model_type", "https://example.invalid/x", "url", id="web-address"),
    pytest.param("model_type_device", "compact", "machine_setting", id="machine"),
    pytest.param("model_type_file", "compact", "file_reference", id="file-word"),
]


@pytest.mark.parametrize("name,value,slug", OLDER_LOCKS)
def test_an_older_lock_under_such_a_name_keeps_its_own_kind(
    name: str, value: Any, slug: str
) -> None:
    """Asked after every lock that was there before, so none of them is taken over."""

    verdict = classify(name, value)

    assert (verdict.exposure, verdict.kind) == (Exposure.LOCKED, slug)


# ==========================================================================
# A sub-input a node shape added is judged by its own name (T-0193 review)
# ==========================================================================

#: A node whose ``model`` input is a node shape: each key adds inputs of its own,
#: and a graph carries them flattened as ``model.<child>``.
SHAPED = "ExampleHostedClipNode"

#: The key the graphs below choose.
CHOSEN = "studio"

#: A child whose own name is an ordinary setting -- ``task_type`` -- under the
#: parent called ``model``, and its invented choices.
TASK = "model.task_type"
TASKS: Tuple[str, ...] = ("draft", "refine", "extend")


def shaped_contract(parent: str, children: Dict[str, Any]) -> RuntimeContract:
    """``parent`` declared as a node shape whose chosen key adds ``children``."""

    spec = [
        "COMFY_DYNAMICCOMBO_V3",
        {
            "options": [
                {"key": "plain", "inputs": {"required": {}}},
                {"key": CHOSEN, "inputs": {"required": dict(children)}},
            ]
        },
    ]
    return contract((SHAPED, parent, spec))


def test_a_child_named_task_type_under_a_parent_named_model_is_what_it_was() -> None:
    """The review's defect: the path's words are two names' words.

    ``model.task_type`` split on every separator carries ``model`` and ``type``,
    and a rule reading the whole path locked a task mode as an architecture.
    Read by its own name it is an ordinary setting, and it comes out as it did
    before T-0193: a select over its declared choices, and held for review with
    no runtime to ask.  The parent itself is a node shape and locks as one.
    """

    assert classify(TASK, "refine").exposure is Exposure.UNCERTAIN

    declared = analyse(
        graph_with(SHAPED, {"model": CHOSEN, TASK: "refine"}),
        contract=shaped_contract("model", {"task_type": combo(*TASKS)}),
    )

    assert declared.problems == ()
    item = field_named(declared, "model_task_type")
    assert (item.type, item.section, item.options) == ("select", "advanced", TASKS)
    assert control_for(declared, "1", TASK).kind is None
    assert control_for(declared, "1", "model").kind == "node_shape"

    undeclared = analyse(graph_with(SHAPED, {"model": CHOSEN, TASK: "refine"}), contract=None)

    assert control_for(undeclared, "1", TASK).section == "needs_review"


def test_a_nested_child_whose_own_name_is_in_the_class_locks() -> None:
    """The other half: the child's own name is what is read, and it can lock."""

    child = "variant.model_type"

    declared = analyse(
        graph_with(SHAPED, {"variant": CHOSEN, child: "wide"}),
        contract=shaped_contract("variant", {"model_type": combo(*FORMS)}),
    )
    undeclared = analyse(
        graph_with(SHAPED, {"variant": CHOSEN, child: "wide"}), contract=None
    )

    assert control_for(declared, "1", child).reason == sentence(child)
    assert (control_for(declared, "1", child).section, control_for(declared, "1", child).kind) == (
        "locked",
        ARCHITECTURE_SLUG,
    )
    assert all(("1", child) not in item.targets for item in declared.fields)
    assert (control_for(undeclared, "1", child).section, control_for(undeclared, "1", child).kind) == (
        "locked",
        ARCHITECTURE_SLUG,
    )


NESTED_NAMES = [
    pytest.param("model.task_type", "compact", Exposure.UNCERTAIN, None, id="model-parent-type-child"),
    pytest.param("base.model_seed", 3, Exposure.EXPOSE, None, id="base-parent-model-child"),
    pytest.param("model_version.strength", 0.5, Exposure.EXPOSE, None, id="in-class-parent-plain-child"),
    pytest.param("arch.style", "compact", Exposure.UNCERTAIN, None, id="arch-parent"),
    pytest.param("model.arch", "compact", Exposure.LOCKED, ARCHITECTURE_SLUG, id="whole-name-child"),
    pytest.param("a.b.model_family", "compact", Exposure.LOCKED, ARCHITECTURE_SLUG, id="two-deep"),
]


@pytest.mark.parametrize("name,value,exposure,kind", NESTED_NAMES)
def test_only_the_part_after_the_last_separator_is_read(
    name: str, value: Any, exposure: Exposure, kind: Optional[str]
) -> None:
    verdict = classify(name, value)

    assert (verdict.exposure, verdict.kind) == (exposure, kind)


def test_the_separator_is_the_one_the_graph_uses_for_a_sub_input() -> None:
    from localcanvas_gateway.workflows.sync import analysis as analysis_module

    assert semantics_module.SHAPE_PATH_SEPARATOR == analysis_module.SHAPE_PATH_SEPARATOR


# ==========================================================================
# The slug is one the frozen set and the package know
# ==========================================================================


def test_the_slug_is_one_the_frozen_set_knows() -> None:
    assert ARCHITECTURE_SLUG in LOCKED_KINDS
    assert classify("model_type", "compact").kind in LOCKED_KINDS


def test_the_slug_is_exported_beside_the_other_lock_kinds() -> None:
    assert sync.MODEL_ARCHITECTURE_KIND == ARCHITECTURE_SLUG
    assert "MODEL_ARCHITECTURE_KIND" in sync.__all__
