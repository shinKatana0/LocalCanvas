"""A value no declared shape names is held for review, whatever ``classify`` said (T-0223).

T-0195 asks the node-shape declaration before ``semantics.classify`` and, as
first decided, took only its ``LOCKED`` answer there.  So where ``classify``
settled an input by itself and the graph's value was **none** of the declared
keys, the input stayed what ``classify`` made it: an editable string, on an
input where only the declared keys are legal and a different one changes which
inputs the node has.  That is the defect T-0195 fixed, surviving for values no
shape declares -- and such a value cannot run on this ComfyUI as saved.

The decision: such an input is held for review, whatever ``classify``
answered, with one sentence that names the input and the declared shapes and
does **not** quote the value.  The file shows it from every side the design
names:

* **whatever classify answered** -- an input it exposes, one it locks for
  another reason, and one it leaves unsettled are held alike, and each
  "before" is measured on the path the rule does not touch (no contract);
* **the sentence** is written out whole, and the saved value is shown absent
  from every sentence the plan carries;
* **a declared key still locks** as it did, for the same three inputs;
* **with no contract, and with a contract silent about the class, nothing
  changes**;
* **a sub-input** a chosen shape declares a node shape is held on the same
  terms.

Every node class, input name, key and value below is invented.
"""

from __future__ import annotations

from typing import Any, Dict, List

import pytest

from localcanvas_gateway.workflows.sync import analyse
from localcanvas_gateway.workflows.sync.analysis import ControlRecord, NotExposed
from localcanvas_gateway.workflows.sync.contract import RuntimeContract, read_object_info
from localcanvas_gateway.workflows.sync.semantics import Exposure, classify

#: Written out rather than imported from the module under test.
SHAPE_SLUG = "node_shape"

RIG = "ExampleCameraRig"
KEYS = ("orbit", "dolly")
#: The value no key names.  Chosen so that no declared key, class name or
#: input name contains it, which is what lets "the sentence does not contain
#: the value" be a measurement.
UNDECLARED = "Zigzag"

DIGEST = "sha256:node-shape-hold"


def shape(*keys: Any, blocks: Dict[Any, Any] = None) -> List[Any]:
    blocks = blocks or {}
    return [
        "COMFY_DYNAMICCOMBO_V3",
        {
            "options": [
                {"key": key, "inputs": blocks.get(key, {"required": {}})} for key in keys
            ]
        },
    ]


def contract_for(class_type: str, **inputs: Any) -> RuntimeContract:
    return read_object_info(
        {class_type: {"input": {"required": dict(inputs)}, "output": ["IMAGE"]}},
        identity_digest=DIGEST,
    )


def graph_with(inputs: Dict[str, Any]) -> Dict[str, Any]:
    """One readable generation whose node ``1`` is the rig."""

    return {
        "1": {"class_type": RIG, "inputs": dict(inputs, image=["3", 0])},
        "2": {
            "class_type": "ExampleTextEncode",
            "inputs": {"text": "a quiet street at dawn"},
        },
        "3": {"class_type": "ExampleSampler", "inputs": {"seed": 7, "positive": ["2", 0]}},
        "4": {"class_type": "ExampleImageSave", "inputs": {"images": ["1", 0]}},
    }


def control_for(plan, name: str) -> ControlRecord:
    found = [item for item in plan.controls if item.target == ("1", name)]
    assert len(found) == 1, (name, plan.controls)
    return found[0]


def held_sentence(name: str, keys: str) -> str:
    return (
        "input {!r} is one this ComfyUI declares as a choice between shapes of "
        "node class {!r} rather than as a value: the shapes it offers are {}. "
        "The value saved there is not one of the shapes this ComfyUI declares, "
        "so what this node would be is not something the graph and this runtime "
        "agree on. Nothing was substituted -- look at it and decide.".format(
            name, RIG, keys
        )
    )


def locked_sentence(name: str, value: str) -> str:
    return (
        "input {!r} holds {!r}, which the ComfyUI that runs this workflow "
        "declares as one of the shapes node class {!r} can take: choosing "
        "another would add or remove inputs on that node rather than change "
        "this one. The workflow's author already chose it, LocalCanvas keeps "
        "it exactly as saved, and offers no control for it.".format(name, value, RIG)
    )


#: One input per answer ``classify`` gives, each asserted below to be that
#: answer before anything is built on it.
ANSWERS = [
    pytest.param("mode", Exposure.EXPOSE, id="classify-exposes"),
    pytest.param("output", Exposure.LOCKED, id="classify-locks"),
    pytest.param("codec", Exposure.UNCERTAIN, id="classify-unsettled"),
]


@pytest.mark.parametrize("name,answer", ANSWERS)
def test_the_fixtures_are_the_three_answers_classify_gives(
    name: str, answer: Exposure
) -> None:
    assert classify(name, UNDECLARED).exposure is answer
    for key in KEYS:
        assert classify(name, key).exposure is answer


@pytest.mark.parametrize("name,answer", ANSWERS)
def test_a_value_no_shape_declares_is_held_whatever_classify_answered(
    name: str, answer: Exposure
) -> None:
    graph = graph_with({name: UNDECLARED})

    # Before: the path this rule does not touch, which is what the same input
    # used to be with the declaration too, unless classify left it unsettled.
    before = analyse(graph, contract=None)
    record = control_for(before, name)
    by_name = classify(name, UNDECLARED)
    if answer is Exposure.EXPOSE:
        assert record.section in ("main", "advanced")
        assert before.problems == ()
    elif answer is Exposure.LOCKED:
        assert (record.section, record.reason) == ("locked", by_name.reason)
        assert before.problems == ()
    else:
        assert (record.section, record.reason) == ("needs_review", by_name.reason)

    plan = analyse(graph, contract=contract_for(RIG, **{name: shape(*KEYS)}))

    sentence = held_sentence(name, "'orbit', 'dolly'")
    assert control_for(plan, name) == ControlRecord(
        node="1", input=name, section="needs_review", reason=sentence
    )
    assert plan.problems == ("Node 1 " + sentence,)
    assert plan.fields == ()
    assert plan.not_exposed == ()


def test_the_sentence_never_carries_the_saved_value() -> None:
    """Absent from every sentence the plan carries -- and shown able to appear.

    The same input holding a declared key is locked with a sentence that does
    quote its value, so a search for a value in a plan's sentences is one that
    finds what is there.
    """

    def sentences(plan) -> List[str]:
        return list(plan.problems) + [item.reason for item in plan.controls]

    contract = contract_for(RIG, mode=shape(*KEYS))
    held = analyse(graph_with({"mode": UNDECLARED}), contract=contract)
    locked = analyse(graph_with({"mode": "dolly"}), contract=contract)

    assert any("'dolly'" in text for text in sentences(locked))
    assert control_for(held, "mode").section == "needs_review"
    assert [text for text in sentences(held) if UNDECLARED in text] == []
    assert [text for text in sentences(held) if UNDECLARED.lower() in text.lower()] == []


@pytest.mark.parametrize("name,answer", ANSWERS)
def test_a_declared_key_still_locks_as_before(name: str, answer: Exposure) -> None:
    for key in KEYS:
        plan = analyse(
            graph_with({name: key}), contract=contract_for(RIG, **{name: shape(*KEYS)})
        )
        sentence = locked_sentence(name, key)
        assert control_for(plan, name) == ControlRecord(
            node="1", input=name, section="locked", reason=sentence, kind=SHAPE_SLUG
        )
        assert plan.not_exposed == (NotExposed("1", name, "locked", sentence, SHAPE_SLUG),)
        assert plan.problems == ()
        assert [item.id for item in plan.fields] == ["prompt", "seed"]


@pytest.mark.parametrize("name,answer", ANSWERS)
def test_with_no_contract_or_a_silent_one_nothing_changes(
    name: str, answer: Exposure
) -> None:
    """No contract, and a contract declaring the shape for another class only.

    Both are compared with what ``classify`` says, input by input, and the
    exposed one is shown to be a field -- so this is not two empty plans
    agreeing with each other.
    """

    graph = graph_with({name: UNDECLARED})
    none = analyse(graph, contract=None)
    silent = analyse(
        graph, contract=contract_for("ExampleOtherRig", **{name: shape(*KEYS)})
    )

    assert silent == none
    record = control_for(none, name)
    assert record.reason == classify(name, UNDECLARED).reason
    if answer is Exposure.EXPOSE:
        assert [item.id for item in none.fields] == ["prompt", name, "seed"]
    elif answer is Exposure.LOCKED:
        assert record.section == "locked"
    else:
        assert record.section == "needs_review"


def test_a_sub_input_the_chosen_shape_declares_a_shape_is_held_on_the_same_terms() -> None:
    """``classify`` exposes ``variant.mode``; declared a shape under ``tuned``, it is held."""

    name = "variant.mode"
    spec = shape(
        "plain",
        "tuned",
        blocks={"tuned": {"required": {"mode": shape(*KEYS)}}},
    )
    graph = graph_with({"variant": "tuned", name: UNDECLARED})
    assert classify(name, UNDECLARED).exposure is Exposure.EXPOSE

    unread = analyse(graph, contract=contract_for(RIG, variant=shape("plain", "tuned")))
    assert control_for(unread, name).section in ("main", "advanced")
    assert unread.problems == ()

    plan = analyse(graph, contract=contract_for(RIG, variant=spec))

    sentence = held_sentence(name, "'orbit', 'dolly'")
    assert control_for(plan, name) == ControlRecord(
        node="1", input=name, section="needs_review", reason=sentence
    )
    assert plan.problems == ("Node 1 " + sentence,)
    assert control_for(plan, "variant").kind == SHAPE_SLUG
