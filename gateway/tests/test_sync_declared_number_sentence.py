"""A declared number holding a non-number is reported as broken, not undecided (T-0242).

Text in an input the runtime declares ``INT`` or ``FLOAT`` was held with
``classify``'s sentence: "nothing in the graph says whether that is a setting
... look at it and decide".  Something does say.  The workflow is broken as
saved, and the curator is told so.  **Only the sentence changes**: the input is
still held, nothing is exposed, locked or substituted, and the saved text is
not quoted.

"Not a number" is a boolean, or a string Python's ``float()`` refuses -- for
``INT`` and ``FLOAT`` alike, because ``float()`` is the more accepting of the
two conversions and the new sentence claims ComfyUI will not run the workflow.

Every class name, input name and value below is invented.
"""

from __future__ import annotations

from typing import Any, Dict, List

import pytest

from localcanvas_gateway.workflows.sync import analyse
from localcanvas_gateway.workflows.sync.analysis import ControlRecord
from localcanvas_gateway.workflows.sync.contract import RuntimeContract, read_object_info
from localcanvas_gateway.workflows.sync.semantics import Exposure, classify

BLENDER = "ExampleGuideBlend"
AMOUNT = "amount"
PROSE = "wide shot, soft light,\ndistant hills"

DIGEST = "sha256:declared-number"


def graph_with(inputs: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "1": {"class_type": BLENDER, "inputs": dict(inputs, guide=["2", 0])},
        "2": {"class_type": "ExampleTextEncode", "inputs": {"text": "a quiet street"}},
        "3": {"class_type": "ExampleSampler", "inputs": {"seed": 7, "positive": ["1", 0]}},
    }


def contract_for(inputs: Dict[str, Any]) -> RuntimeContract:
    return read_object_info(
        {BLENDER: {"input": {"required": dict(inputs)}, "output": ["CONDITIONING"]}},
        identity_digest=DIGEST,
    )


def number(type_name: str) -> List[Any]:
    return [type_name, {"min": 0.0, "max": 10.0}]


def broken_sentence(name: str, field_type: str) -> str:
    return (
        "input {!r} is one the ComfyUI that runs this workflow declares a number "
        "for on node class 'ExampleGuideBlend' ({}), and the value saved there is "
        "not a number, so ComfyUI will not run this workflow as it was saved. "
        "Nothing was substituted -- the workflow needs fixing in ComfyUI.".format(
            name, field_type
        )
    )


def old_sentence(name: str, value: Any) -> str:
    verdict = classify(name, value)
    assert verdict.exposure is Exposure.UNCERTAIN, verdict
    return verdict.reason


def assert_held_with(plan, name: str, reason: str) -> None:
    assert [item for item in plan.controls if item.target == ("1", name)] == [
        ControlRecord(node="1", input=name, section="needs_review", reason=reason)
    ]
    assert plan.problems == ("Node 1 " + reason,)
    assert plan.not_exposed == ()
    assert plan.fields == ()


@pytest.mark.parametrize(
    "type_name,field_type", [("FLOAT", "float"), ("INT", "integer")]
)
def test_text_in_a_declared_number_is_held_with_the_broken_sentence(
    type_name: str, field_type: str
) -> None:
    graph = graph_with({AMOUNT: PROSE})

    plan = analyse(graph, contract=contract_for({AMOUNT: number(type_name)}))

    assert_held_with(plan, AMOUNT, broken_sentence(AMOUNT, field_type))


def test_the_sentence_does_not_quote_the_saved_text() -> None:
    plan = analyse(graph_with({AMOUNT: PROSE}), contract=contract_for({AMOUNT: number("FLOAT")}))

    assert len(plan.problems) == 1
    for fragment in ("wide shot", "distant hills", PROSE):
        assert fragment not in plan.problems[0]
    # The old sentence did quote it, so the absence is one the fixture can show.
    assert "wide shot" in old_sentence(AMOUNT, PROSE)


def test_a_flag_in_a_declared_number_is_not_a_number() -> None:
    """``True`` is an ``int`` in Python; it is not a number here."""

    graph = graph_with({"__": True})

    plan = analyse(graph, contract=contract_for({"__": number("INT")}))

    assert_held_with(plan, "__", broken_sentence("__", "integer"))


@pytest.mark.parametrize("saved", ["1.5", " 2 ", "1e3", "nan", "-0"])
@pytest.mark.parametrize("type_name", ["FLOAT", "INT"])
def test_text_that_reads_as_a_number_keeps_the_old_sentence(saved: str, type_name: str) -> None:
    graph = graph_with({AMOUNT: saved})

    plan = analyse(graph, contract=contract_for({AMOUNT: number(type_name)}))

    assert_held_with(plan, AMOUNT, old_sentence(AMOUNT, saved))


def test_a_number_nothing_could_name_keeps_the_old_sentence() -> None:
    graph = graph_with({"__": 3})

    plan = analyse(graph, contract=contract_for({"__": number("INT")}))

    assert_held_with(plan, "__", old_sentence("__", 3))


def test_without_a_declared_number_the_old_sentence_stands() -> None:
    graph = graph_with({AMOUNT: PROSE})

    assert_held_with(analyse(graph), AMOUNT, old_sentence(AMOUNT, PROSE))
    assert_held_with(
        analyse(graph, contract=contract_for({AMOUNT: ["STRING", {"multiline": True}]})),
        AMOUNT,
        old_sentence(AMOUNT, PROSE),
    )
    assert_held_with(
        analyse(graph, contract=contract_for({"other": number("FLOAT")})),
        AMOUNT,
        old_sentence(AMOUNT, PROSE),
    )
