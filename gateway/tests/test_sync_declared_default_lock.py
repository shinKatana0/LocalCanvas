"""Unsettled text saved at the runtime's declared default is locked (T-0244).

Some text nothing can settle stays unsettled for good: a colour word, a short
subject, an identifier, on a node whose outputs prove nothing.  Held for review
with no override, such a workflow could never import.  The one generic fact
available is that the saved value **equals** the default the ComfyUI that runs
the workflow declares for that input: the author never changed it.  So, and
only then, the importer locks it at the saved value with the
``declared_default`` slug -- the workflow runs exactly as saved, and nobody is
handed a control whose meaning is unknown.

The file is organised around the ways of getting that wrong:

* **the decision** -- equal locks, single-line and multiline;
* **equal means equal** -- one character away, a trailing space, another case,
  another type: held;
* **a default must be declared** -- no default is not the empty string, and a
  type that is not exactly ``STRING`` declares nothing here;
* **runtime-only** -- no contract, or a class it does not declare: held;
* **asked last** -- ``classify``, the computation lock, the model-patch lock
  and the wired prompt each keep their own answer for text at its default;
* **under the chosen shape too** -- a nested text declaration is read the same.

Every class name, input name and value below is invented.
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional, Sequence

import pytest

from localcanvas_gateway.workflows.sync import analyse
from localcanvas_gateway.workflows.sync.analysis import (
    LOCKED_KINDS,
    ControlRecord,
    NotExposed,
)
from localcanvas_gateway.workflows.sync.contract import (
    RuntimeContract,
    StringDeclaration,
    declared_string,
    read_object_info,
)
from localcanvas_gateway.workflows.sync.semantics import Exposure, classify

#: Written out rather than imported from the module under test.
DEFAULT_SLUG = "declared_default"

LABELLER = "ExampleCaptionPainter"
TINT = "tint"
TINT_DEFAULT = "amber"

DIGEST = "sha256:declared-default"


def graph_with(inputs: Dict[str, Any], class_type: str = LABELLER) -> Dict[str, Any]:
    """One readable generation whose node ``1`` paints on the sampled picture.

    Node ``1`` carries a wire beside the inputs under test, so it is never its
    node's only input and the wired-prompt rule cannot be what decides it.
    """

    return {
        "1": {"class_type": class_type, "inputs": dict(inputs, image=["4", 0])},
        "2": {
            "class_type": "ExampleTextEncode",
            "inputs": {"text": "a quiet street at dawn"},
        },
        "3": {"class_type": "ExampleSampler", "inputs": {"seed": 7, "positive": ["2", 0]}},
        "4": {"class_type": "ExampleDecode", "inputs": {"samples": ["3", 0]}},
        "5": {"class_type": "ExampleImageSave", "inputs": {"images": ["1", 0]}},
    }


def contract_for(
    inputs: Dict[str, Any],
    *,
    class_type: str = LABELLER,
    outputs: Sequence[str] = ("IMAGE",),
) -> RuntimeContract:
    return read_object_info(
        {class_type: {"input": {"required": dict(inputs)}, "output": list(outputs)}},
        identity_digest=DIGEST,
    )


def text(default: Any = None, **config: Any) -> List[Any]:
    if default is not None:
        config["default"] = default
    return ["STRING", config]


def control_for(plan, name: str) -> ControlRecord:
    found = [item for item in plan.controls if item.target == ("1", name)]
    assert len(found) == 1, (name, plan.controls)
    return found[0]


def held_sentence(name: str, value: Any) -> str:
    verdict = classify(name, value)
    assert verdict.exposure is Exposure.UNCERTAIN, verdict
    return verdict.reason


def default_sentence(name: str, class_type: str = LABELLER) -> str:
    return (
        "input {!r} on node class {!r} holds exactly the default the ComfyUI "
        "that runs this workflow declares for it, and nothing in the graph says "
        "whether it is a setting a user may change: the workflow's author never "
        "changed it. LocalCanvas keeps it exactly as saved and offers no control "
        "for it.".format(name, class_type)
    )


def assert_held(plan, name: str, value: Any) -> None:
    reason = held_sentence(name, value)
    assert control_for(plan, name) == ControlRecord(
        node="1", input=name, section="needs_review", reason=reason
    )
    assert plan.problems == ("Node 1 " + reason,)
    assert plan.not_exposed == ()


def assert_locked(plan, name: str, class_type: str = LABELLER) -> None:
    reason = default_sentence(name, class_type)
    assert control_for(plan, name) == ControlRecord(
        node="1", input=name, section="locked", reason=reason, kind=DEFAULT_SLUG
    )
    assert NotExposed("1", name, "locked", reason, DEFAULT_SLUG) in plan.not_exposed
    assert plan.problems == ()
    assert [field.id for field in plan.fields] == ["prompt", "seed"]


# ==========================================================================
# The reader
# ==========================================================================


def test_the_reader_keeps_a_text_input_and_whether_it_declares_a_default() -> None:
    assert declared_string(["STRING", {"default": "amber", "multiline": True}]) == (
        StringDeclaration(has_default=True, default="amber")
    )
    assert declared_string(["STRING", {"default": ""}]) == StringDeclaration(True, "")
    assert declared_string(["STRING", {"multiline": True}]) == StringDeclaration(False)
    assert declared_string(["STRING"]) == StringDeclaration(False)
    assert declared_string(["string", {"default": "amber"}]) is None
    assert declared_string(["STRINGS", {"default": "amber"}]) is None
    assert declared_string([["STRING"], {"default": "amber"}]) is None
    assert declared_string("STRING") is None
    assert declared_string([]) is None

    found = contract_for({TINT: text(TINT_DEFAULT)})
    assert found.string_for(LABELLER, TINT) == StringDeclaration(True, TINT_DEFAULT)
    assert found.string_for(LABELLER, "other") is None
    assert found.string_for("ExampleElsewhere", TINT) is None
    assert found.declares(LABELLER, TINT)


# ==========================================================================
# The decision
# ==========================================================================


def test_text_saved_at_its_declared_default_locks() -> None:
    graph = graph_with({TINT: TINT_DEFAULT})

    assert_held(analyse(graph), TINT, TINT_DEFAULT)
    assert_locked(analyse(graph, contract=contract_for({TINT: text(TINT_DEFAULT)})), TINT)


def test_a_multiline_declaration_saved_at_its_default_locks_too() -> None:
    prose = "soft light,\nwarm tones"
    graph = graph_with({"flourish": prose})

    plan = analyse(
        graph, contract=contract_for({"flourish": text(prose, multiline=True)})
    )

    assert_locked(plan, "flourish")


def test_an_empty_text_saved_at_an_empty_default_locks() -> None:
    graph = graph_with({TINT: ""})

    assert_locked(analyse(graph, contract=contract_for({TINT: text("")})), TINT)


# ==========================================================================
# Equal means equal
# ==========================================================================


@pytest.mark.parametrize(
    "saved",
    ["ambers", "ambar", "amber ", " amber", "Amber", "AMBER", "amber\n"],
    ids=["one-more", "one-changed", "trailing-space", "leading-space", "case", "upper", "newline"],
)
def test_text_one_step_away_from_the_default_is_held(saved: str) -> None:
    graph = graph_with({TINT: saved})

    plan = analyse(graph, contract=contract_for({TINT: text(TINT_DEFAULT)}))

    assert_held(plan, TINT, saved)


def test_a_default_of_another_type_is_not_equal_to_its_spelling() -> None:
    graph = graph_with({TINT: "5"})

    plan = analyse(graph, contract=contract_for({TINT: ["STRING", {"default": 5}]}))

    assert_held(plan, TINT, "5")


def test_a_number_equal_to_a_numeric_default_is_not_text() -> None:
    """Only strings: a role-less number equal to what the declaration holds is held."""

    graph = graph_with({"__": 5})

    plan = analyse(graph, contract=contract_for({"__": ["STRING", {"default": 5}]}))

    assert control_for(plan, "__").section == "needs_review"
    assert plan.not_exposed == ()


# ==========================================================================
# A default must be declared, on a STRING
# ==========================================================================


@pytest.mark.parametrize(
    "spec",
    [["STRING", {"multiline": False}], ["STRING"], ["STRING", "not-a-mapping"]],
    ids=["no-default-key", "bare-type", "unreadable-config"],
)
def test_no_declared_default_is_not_the_empty_string(spec: List[Any]) -> None:
    graph = graph_with({TINT: ""})
    declared = contract_for({TINT: spec})
    assert declared.string_for(LABELLER, TINT) == StringDeclaration(False)

    assert_held(analyse(graph, contract=declared), TINT, "")


@pytest.mark.parametrize(
    "type_name", ["string", "STRINGS", "TEXT", "CUSTOM_STRING"]
)
def test_a_type_that_is_not_exactly_string_declares_no_default(type_name: str) -> None:
    graph = graph_with({TINT: TINT_DEFAULT})

    plan = analyse(
        graph, contract=contract_for({TINT: [type_name, {"default": TINT_DEFAULT}]})
    )

    assert_held(plan, TINT, TINT_DEFAULT)


def test_without_a_runtime_that_declares_the_class_it_is_held() -> None:
    graph = graph_with({TINT: TINT_DEFAULT})

    assert_held(analyse(graph, contract=None), TINT, TINT_DEFAULT)
    assert_held(
        analyse(
            graph,
            contract=contract_for({TINT: text(TINT_DEFAULT)}, class_type="ExampleElsewhere"),
        ),
        TINT,
        TINT_DEFAULT,
    )


# ==========================================================================
# Asked last
# ==========================================================================


def test_a_prompt_classify_recognises_stays_a_prompt_at_its_default() -> None:
    graph = graph_with({TINT: TINT_DEFAULT})
    graph["2"]["inputs"]["text"] = "a quiet street"
    declared = read_object_info(
        {
            LABELLER: {"input": {"required": {TINT: text(TINT_DEFAULT)}}, "output": ["IMAGE"]},
            "ExampleTextEncode": {
                "input": {"required": {"text": text("a quiet street", multiline=True)}},
                "output": ["CONDITIONING"],
            },
        },
        identity_digest=DIGEST,
    )

    plan = analyse(graph, contract=declared)

    assert control_for(plan, TINT).kind == DEFAULT_SLUG
    assert [field.id for field in plan.fields] == ["prompt", "seed"]


def test_computation_keeps_its_own_answer_for_text_at_its_default() -> None:
    graph = graph_with({TINT: TINT_DEFAULT})

    plan = analyse(
        graph, contract=contract_for({TINT: text(TINT_DEFAULT)}, outputs=("FLOAT",))
    )

    assert control_for(plan, TINT).kind == "computation"


def test_a_model_patch_keeps_its_own_answer_for_text_at_its_default() -> None:
    graph = graph_with({TINT: TINT_DEFAULT})

    plan = analyse(
        graph, contract=contract_for({TINT: text(TINT_DEFAULT)}, outputs=("MODEL",))
    )

    assert control_for(plan, TINT).kind == "model_patch"


def test_a_wired_prompt_keeps_its_own_answer_for_text_at_its_default() -> None:
    """A string node's only input, wired into an encoder's ``text``, is that prompt."""

    graph = {
        "1": {"class_type": "ExampleStringSource", "inputs": {"value": "a quiet street"}},
        "2": {"class_type": "ExampleTextEncode", "inputs": {"text": ["1", 0]}},
        "3": {"class_type": "ExampleSampler", "inputs": {"seed": 7, "positive": ["2", 0]}},
    }
    declared = contract_for(
        {"value": text("a quiet street")},
        class_type="ExampleStringSource",
        outputs=("STRING",),
    )

    plan = analyse(graph, contract=declared)

    assert control_for(plan, "value").section == "main"
    assert control_for(plan, "value").kind is None
    assert plan.not_exposed == ()


# ==========================================================================
# Under the chosen shape too
# ==========================================================================


def test_nested_text_at_the_default_the_chosen_shape_declares_locks() -> None:
    name = "variant.tint"
    spec = [
        "COMFY_DYNAMICCOMBO_V3",
        {
            "options": [
                {"key": "plain", "inputs": {"required": {"tint": text("crimson")}}},
                {"key": "tuned", "inputs": {"required": {"tint": text(TINT_DEFAULT)}}},
            ]
        },
    ]
    declared = contract_for({"variant": spec})

    chosen = analyse(graph_with({"variant": "tuned", name: TINT_DEFAULT}), contract=declared)
    other = analyse(graph_with({"variant": "plain", name: TINT_DEFAULT}), contract=declared)

    assert_locked(chosen, name)
    reason = held_sentence(name, TINT_DEFAULT)
    assert control_for(other, name) == ControlRecord(
        node="1", input=name, section="needs_review", reason=reason
    )
    assert other.problems == ("Node 1 " + reason,)


def test_the_slug_is_one_the_frozen_set_knows() -> None:
    assert DEFAULT_SLUG in LOCKED_KINDS


def test_the_slug_is_exported_beside_the_other_lock_kinds() -> None:
    import localcanvas_gateway.workflows.sync as sync

    assert sync.DECLARED_DEFAULT_KIND == DEFAULT_SLUG
    assert "DECLARED_DEFAULT_KIND" in sync.__all__
    assert sync.DECLARED_DEFAULT_KIND in sync.LOCKED_KINDS
