"""Text on a node whose only product is a patched model is part of the model (T-0241).

A list of layer indices, of blocks to skip, of latent frames to keep: short text
under a name nothing in `semantics.py` knows, so ``classify`` answers
``UNCERTAIN`` and the workflow was held.  What says what the text is for is the
node, through the runtime: a class whose **every** declared output is a model
takes a model in and hands a patched one on, so its text changes how the model
is patched.  So, and only then, the importer locks the string with the
``model_patch`` slug at exactly the value the graph carries -- the same slot and
the same shape as T-0218's computation lock.

The file is organised around the ways of getting that wrong:

* **the case** locks with a contract and stays held without one, with a
  contract that does not declare the class, and with one whose outputs it could
  not read;
* **every, not any** -- one output of another type beside the model proves
  nothing, and neither does a node with no outputs;
* **the model type alone** -- no other handle type is enough by itself;
* **after the existing evidence** -- a declared choice list keeps its own
  answer, and only strings are ever locked.

Every class name, input name and value below is invented.
"""

from __future__ import annotations

from typing import Any, Dict, Optional, Sequence

import pytest

from localcanvas_gateway.workflows.sync import analyse
from localcanvas_gateway.workflows.sync.analysis import (
    LOCKED_KINDS,
    ControlRecord,
    NotExposed,
)
from localcanvas_gateway.workflows.sync.contract import RuntimeContract, read_object_info
from localcanvas_gateway.workflows.sync.semantics import Exposure, classify

#: Written out rather than imported from the module under test, so a renamed
#: slug is a failing test and not a silently renamed report column.
MODEL_PATCH_SLUG = "model_patch"

#: A node that takes a model and hands on a patched one.
PATCHER = "ExampleLayerPatcher"
LAYERS = "picked_layers"
LAYERS_VALUE = "4, 5, 6"

DIGEST = "sha256:model-patch"

_ABSENT = object()


def graph_with(inputs: Dict[str, Any]) -> Dict[str, Any]:
    """One readable generation whose node ``1`` patches the model the sampler uses.

    Node ``1``'s output is wired into the sampler's ``model`` and nothing else,
    so the rest of the graph imports on its own and "the workflow imports" is
    something this fixture can show rather than assume.
    """

    return {
        "1": {"class_type": PATCHER, "inputs": dict(inputs, model=["4", 0])},
        "2": {
            "class_type": "ExampleTextEncode",
            "inputs": {"text": "a quiet street at dawn"},
        },
        "3": {
            "class_type": "ExampleSampler",
            "inputs": {"seed": 7, "model": ["1", 0], "positive": ["2", 0]},
        },
        "4": {"class_type": "ExampleModelSource", "inputs": {}},
    }


def contract_for(
    class_type: str, outputs: Any, inputs: Optional[Dict[str, Any]] = None
) -> RuntimeContract:
    """A contract read by the production parser from a document of that shape."""

    entry: Dict[str, Any] = {"input": {"required": dict(inputs or {})}, "name": "x"}
    if outputs is not _ABSENT:
        entry["output"] = outputs
    return read_object_info({class_type: entry}, identity_digest=DIGEST)


def control_for(plan, name: str) -> ControlRecord:
    found = [item for item in plan.controls if item.target == ("1", name)]
    assert len(found) == 1, (name, plan.controls)
    return found[0]


def held_sentence(name: str, value: Any) -> str:
    """What ``classify`` itself says about the input -- read from it, not retyped."""

    verdict = classify(name, value)
    assert verdict.exposure is Exposure.UNCERTAIN, verdict
    return verdict.reason


def model_patch_sentence(name: str, outputs: str) -> str:
    return (
        "input {!r} holds text on node class {!r}, and every output the ComfyUI "
        "that runs this workflow declares for that class is a model ({}): "
        "whatever the text says, what it changes is how that model is patched "
        "before another node uses it. That is part of the model, not a setting "
        "-- LocalCanvas keeps it exactly as saved and offers no control for "
        "it.".format(name, PATCHER, outputs)
    )


def assert_held(plan, name: str, value: Any) -> None:
    reason = held_sentence(name, value)
    assert control_for(plan, name) == ControlRecord(
        node="1", input=name, section="needs_review", reason=reason
    )
    assert plan.problems == ("Node 1 " + reason,)
    assert plan.not_exposed == ()
    assert plan.fields == ()


def assert_locked(plan, name: str, outputs: str) -> None:
    reason = model_patch_sentence(name, outputs)
    assert control_for(plan, name) == ControlRecord(
        node="1", input=name, section="locked", reason=reason, kind=MODEL_PATCH_SLUG
    )
    assert plan.not_exposed == (NotExposed("1", name, "locked", reason, MODEL_PATCH_SLUG),)
    assert plan.problems == ()
    # The rest of the graph imports, so the lock is what let it through.
    assert [field.id for field in plan.fields] == ["prompt", "seed"]


# ==========================================================================
# The case
# ==========================================================================


def test_text_on_a_node_whose_every_output_is_a_model_locks_with_a_contract() -> None:
    graph = graph_with({LAYERS: LAYERS_VALUE})

    plan = analyse(graph, contract=contract_for(PATCHER, ["MODEL"]))

    assert_locked(plan, LAYERS, "MODEL")


def test_the_same_text_is_held_without_anything_to_go_on() -> None:
    graph = graph_with({LAYERS: LAYERS_VALUE})

    # Without a runtime to ask, exactly as before this card.
    assert_held(analyse(graph), LAYERS, LAYERS_VALUE)
    # With a runtime that does not have the class.
    assert_held(
        analyse(graph, contract=contract_for("ExampleSomethingElse", ["MODEL"])),
        LAYERS,
        LAYERS_VALUE,
    )
    # With a runtime that has the class but whose outputs it could not read.
    assert_held(analyse(graph, contract=contract_for(PATCHER, _ABSENT)), LAYERS, LAYERS_VALUE)


def test_several_model_outputs_are_still_every_output_a_model() -> None:
    plan = analyse(
        graph_with({LAYERS: LAYERS_VALUE}), contract=contract_for(PATCHER, ["MODEL", "MODEL"])
    )

    assert_locked(plan, LAYERS, "MODEL, MODEL")


def test_an_empty_text_locks_exactly_as_saved() -> None:
    """Nothing is parsed or tidied: an empty list is kept as the graph has it."""

    graph = graph_with({LAYERS: ""})

    plan = analyse(graph, contract=contract_for(PATCHER, ["MODEL"]))

    assert_locked(plan, LAYERS, "MODEL")
    assert graph["1"]["inputs"][LAYERS] == ""


# ==========================================================================
# Every output, and the model type alone
# ==========================================================================


@pytest.mark.parametrize(
    "outputs",
    [
        ["MODEL", "CONDITIONING"],
        ["STRING", "MODEL"],
        ["MODEL", "IMAGE"],
        ["CONDITIONING"],
        ["CLIP"],
        ["LATENT"],
        ["VAE"],
        ["STRING"],
        ["model"],
        ["*"],
        [],
    ],
    ids=[
        "model-and-conditioning",
        "string-and-model",
        "model-and-image",
        "conditioning",
        "clip",
        "latent",
        "vae",
        "string",
        "lowercase-model",
        "any-type",
        "no-outputs",
    ],
)
def test_a_node_that_produces_anything_but_models_proves_nothing(
    outputs: Sequence[str],
) -> None:
    graph = graph_with({LAYERS: LAYERS_VALUE})
    declared = contract_for(PATCHER, list(outputs))
    # The declaration really was read, so the rule had it in its hands.
    assert declared.outputs_for(PATCHER) == tuple(outputs)

    assert_held(analyse(graph, contract=declared), LAYERS, LAYERS_VALUE)


# ==========================================================================
# After the existing evidence, and only for strings
# ==========================================================================


def test_a_declared_choice_list_keeps_its_own_answer() -> None:
    """A list is the runtime saying the input is a choice; the rule is never asked."""

    graph = graph_with({LAYERS: "sixth"})

    plan = analyse(
        graph,
        contract=contract_for(
            PATCHER, ["MODEL"], {LAYERS: ["COMBO", {"options": ["first", "second"]}]}
        ),
    )

    record = control_for(plan, LAYERS)
    assert record.section == "needs_review"
    assert record.reason == (
        "input 'picked_layers' holds 'sixth', and the ComfyUI that would run this "
        "workflow does not offer that: for node class 'ExampleLayerPatcher' it "
        "declares 'first', 'second'. Nothing was substituted -- this graph was "
        "saved against a different version of that node, and choosing one of the "
        "values above on your behalf would silently change what it generates."
    )
    assert plan.not_exposed == ()


def test_a_number_nothing_could_name_is_not_a_model_patch() -> None:
    """Only strings: a role-less number on the same node stays held."""

    graph = graph_with({"__": 3})

    plan = analyse(graph, contract=contract_for(PATCHER, ["MODEL"]))

    reason = held_sentence("__", 3)
    assert control_for(plan, "__") == ControlRecord(
        node="1", input="__", section="needs_review", reason=reason
    )
    assert plan.not_exposed == ()


def test_what_classify_settles_on_the_same_node_is_untouched() -> None:
    """A number on a model patcher is still a number control."""

    graph = graph_with({LAYERS: LAYERS_VALUE, "strength": 0.5})

    plan = analyse(graph, contract=contract_for(PATCHER, ["MODEL"]))

    assert control_for(plan, LAYERS).kind == MODEL_PATCH_SLUG
    assert [field.id for field in plan.fields] == ["prompt", "seed", "strength"]


def test_the_slug_is_one_the_frozen_set_knows() -> None:
    assert MODEL_PATCH_SLUG in LOCKED_KINDS


def test_the_slug_is_exported_beside_the_other_lock_kinds() -> None:
    import localcanvas_gateway.workflows.sync as sync

    assert sync.MODEL_PATCH_KIND == MODEL_PATCH_SLUG
    assert "MODEL_PATCH_KIND" in sync.__all__
    assert sync.MODEL_PATCH_KIND in sync.LOCKED_KINDS
