"""A string that only ever becomes numbers is computation, not a setting (T-0218).

Two kinds of text held real workflows back for review: an arithmetic
expression a math node evaluates, and a comma-separated list of numbers a node
turns into a sampler's schedule.  Both are short text under a name nothing in
`semantics.py` knows, so ``classify`` answers ``UNCERTAIN`` -- and it is right
to, because neither the name nor the value says what the text is for.

What says it is the node, through the runtime: a class whose **every**
declared output is a number turns whatever the text says into numbers another
node reads.  So, and only then, the importer locks the string with the
``computation`` slug at exactly the value the graph carries.

The file is organised around the ways of getting that wrong:

* **the reader** -- ``output`` is read as written, whole or not at all;
* **the two cases the card is about** lock with a contract and stay held
  without one, and with a contract that does not declare the class;
* **"every", not "any"** -- one non-numeric socket beside the numbers and the
  text proves nothing; a node with no outputs at all proves nothing either;
* **after the existing evidence** -- a declared choice list, a node shape, and
  every verdict ``classify`` settles by itself all keep their own answer;
* **only strings**.

Every class name, input name and value below is invented.
"""

from __future__ import annotations

from typing import Any, Dict, Optional, Sequence, Tuple

import pytest

from localcanvas_gateway.workflows.sync import analyse
from localcanvas_gateway.workflows.sync.analysis import (
    LOCKED_KINDS,
    ControlRecord,
    NotExposed,
)
from localcanvas_gateway.workflows.sync.contract import (
    RuntimeContract,
    declared_outputs,
    read_object_info,
)
from localcanvas_gateway.workflows.sync.semantics import Exposure, classify

#: Written out rather than imported from the module under test, so a renamed
#: slug is a failing test and not a silently renamed report column.
COMPUTATION_SLUG = "computation"

#: A node that evaluates an arithmetic expression over its wired inputs.
ARITHMETIC = "ExampleArithmetic"
FORMULA = "formula"
FORMULA_VALUE = "a * b + 1"

#: A node that turns a written list of numbers into a sampler's schedule.
SCHEDULE = "ExampleScheduleFromText"
LEVELS = "levels"
LEVELS_VALUE = "1, 0.5"

DIGEST = "sha256:computation"


def graph_with(class_type: str, inputs: Dict[str, Any]) -> Dict[str, Any]:
    """One readable generation whose node ``1`` is of the given class.

    Node ``1``'s first output is wired into the sampler's ``steps`` and
    nothing else, so the rest of the graph imports on its own and "the
    workflow imports" is something this fixture can show rather than assume.
    """

    return {
        "1": {"class_type": class_type, "inputs": dict(inputs)},
        "2": {
            "class_type": "ExampleTextEncode",
            "inputs": {"text": "a quiet street at dawn"},
        },
        "3": {
            "class_type": "ExampleSampler",
            "inputs": {"seed": 7, "steps": ["1", 0], "positive": ["2", 0]},
        },
    }


def entry(outputs: Any, inputs: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """One class in ``/object_info``'s own shape."""

    found: Dict[str, Any] = {"input": {"required": dict(inputs or {})}, "name": "x"}
    if outputs is not _ABSENT:
        found["output"] = outputs
    return found


_ABSENT = object()


def contract_for(class_type: str, outputs: Any, **inputs: Any) -> RuntimeContract:
    """A contract read by the production parser from a document of that shape."""

    return read_object_info(
        {class_type: entry(outputs, inputs)}, identity_digest=DIGEST
    )


def control_for(plan, node: str, name: str) -> ControlRecord:
    found = [item for item in plan.controls if item.target == (node, name)]
    assert len(found) == 1, (node, name, plan.controls)
    return found[0]


def held_sentence(name: str, value: str) -> str:
    """What ``classify`` itself says about the input -- read from it, not retyped."""

    verdict = classify(name, value)
    assert verdict.exposure is Exposure.UNCERTAIN, verdict
    return verdict.reason


def computation_sentence(name: str, class_type: str, outputs: str) -> str:
    return (
        "input {!r} holds text on node class {!r}, and every output the ComfyUI "
        "that runs this workflow declares for that class is a number ({}): "
        "whatever the text says, what it becomes is numbers another node reads. "
        "That is computation, not a setting -- LocalCanvas keeps it exactly as "
        "saved and offers no control for it.".format(name, class_type, outputs)
    )


def assert_held(plan, name: str, value: str) -> None:
    """Held for review with ``classify``'s own sentence, and nothing else."""

    reason = held_sentence(name, value)
    assert control_for(plan, "1", name) == ControlRecord(
        node="1", input=name, section="needs_review", reason=reason
    )
    assert plan.problems == ("Node 1 " + reason,)
    assert plan.not_exposed == ()
    assert plan.fields == ()


def assert_locked(plan, name: str, class_type: str, outputs: str) -> None:
    reason = computation_sentence(name, class_type, outputs)
    assert control_for(plan, "1", name) == ControlRecord(
        node="1",
        input=name,
        section="locked",
        reason=reason,
        kind=COMPUTATION_SLUG,
    )
    assert plan.not_exposed == (
        NotExposed("1", name, "locked", reason, COMPUTATION_SLUG),
    )
    assert plan.problems == ()
    # The rest of the graph imports, so the lock is what let it through.
    assert [field.id for field in plan.fields] == ["prompt", "seed"]


# ==========================================================================
# The reader
# ==========================================================================


def test_the_reader_keeps_each_class_outputs_as_written() -> None:
    document = {
        "ExampleNumbers": entry(["FLOAT", "INT", "BOOLEAN"]),
        "ExampleNothingOut": entry([]),
        "ExampleNoInputBlock": {"output": ["SIGMAS"]},
    }

    found = read_object_info(document, identity_digest=DIGEST)

    assert dict(found.outputs) == {
        "ExampleNumbers": ("FLOAT", "INT", "BOOLEAN"),
        "ExampleNothingOut": (),
        "ExampleNoInputBlock": ("SIGMAS",),
    }
    assert found.outputs_for("ExampleNumbers") == ("FLOAT", "INT", "BOOLEAN")
    # "Declared to have none" and "not declared" are two answers.
    assert found.outputs_for("ExampleNothingOut") == ()
    assert found.outputs_for("ExampleNotInstalled") is None
    # And none of it is counted as a choice list a report already counts.
    assert found.declared == 0


@pytest.mark.parametrize(
    "outputs",
    [
        _ABSENT,
        "FLOAT",
        None,
        {"0": "FLOAT"},
        ["FLOAT", ["low", "high"]],
        ["FLOAT", ""],
        ["FLOAT", 3],
    ],
    ids=["absent", "a-string", "null", "a-mapping", "a-choice-socket", "empty-name", "a-number"],
)
def test_an_output_list_that_cannot_be_read_whole_is_not_read(outputs: Any) -> None:
    assert declared_outputs(entry(outputs)) is None
    found = read_object_info({"ExampleNumbers": entry(outputs)}, identity_digest=DIGEST)
    assert found.outputs_for("ExampleNumbers") is None
    assert dict(found.outputs) == {}


def test_a_contract_built_without_outputs_declares_none() -> None:
    """The table is a new field with an empty default, so older callers are unchanged."""

    built = RuntimeContract(identity_digest=DIGEST, options={})
    assert built.outputs_for(ARITHMETIC) is None


# ==========================================================================
# The two cases the card is about
# ==========================================================================


@pytest.mark.parametrize(
    "class_type, name, value, outputs, listed",
    [
        (ARITHMETIC, FORMULA, FORMULA_VALUE, ["FLOAT", "INT", "BOOLEAN"], "FLOAT, INT, BOOLEAN"),
        (SCHEDULE, LEVELS, LEVELS_VALUE, ["SIGMAS"], "SIGMAS"),
    ],
    ids=["math-expression", "sigma-list"],
)
def test_the_two_cases_lock_with_a_contract_and_stay_held_without_one(
    class_type: str, name: str, value: str, outputs: Sequence[str], listed: str
) -> None:
    graph = graph_with(class_type, {name: value})

    # Without a runtime to ask, exactly as before this card.
    assert_held(analyse(graph), name, value)
    # With a runtime that does not have the class: nothing to go on either.
    assert_held(
        analyse(graph, contract=contract_for("ExampleSomethingElse", list(outputs))),
        name,
        value,
    )
    # With a runtime that has the class but whose outputs it could not read.
    assert_held(
        analyse(graph, contract=contract_for(class_type, _ABSENT)), name, value
    )

    plan = analyse(graph, contract=contract_for(class_type, list(outputs)))
    assert_locked(plan, name, class_type, listed)


@pytest.mark.parametrize("output", ["INT", "FLOAT", "BOOLEAN", "SIGMAS"])
def test_each_numeric_output_type_is_enough_by_itself(output: str) -> None:
    graph = graph_with(ARITHMETIC, {FORMULA: FORMULA_VALUE})

    plan = analyse(graph, contract=contract_for(ARITHMETIC, [output]))

    assert_locked(plan, FORMULA, ARITHMETIC, output)


def test_the_value_locked_is_the_one_in_the_graph() -> None:
    """Nothing is parsed or tidied: a malformed expression is kept as written."""

    odd = "floor (a * b + 1"
    graph = graph_with(ARITHMETIC, {FORMULA: odd})

    plan = analyse(graph, contract=contract_for(ARITHMETIC, ["FLOAT"]))

    assert_locked(plan, FORMULA, ARITHMETIC, "FLOAT")
    assert graph["1"]["inputs"][FORMULA] == odd


# ==========================================================================
# Every output, not any output
# ==========================================================================


@pytest.mark.parametrize(
    "outputs",
    [
        ["STRING"],
        ["IMAGE"],
        ["LATENT"],
        ["CONDITIONING"],
        ["MASK"],
        ["*"],
        ["float"],
        ["FLOAT", "STRING"],
        ["STRING", "INT"],
        ["SIGMAS", "IMAGE"],
        [],
    ],
    ids=[
        "string",
        "image",
        "latent",
        "conditioning",
        "mask",
        "any-type",
        "lowercase-float",
        "float-and-string",
        "string-and-int",
        "sigmas-and-image",
        "no-outputs",
    ],
)
def test_a_node_that_produces_anything_but_numbers_proves_nothing(
    outputs: Sequence[str],
) -> None:
    graph = graph_with(ARITHMETIC, {FORMULA: FORMULA_VALUE})
    declared = contract_for(ARITHMETIC, list(outputs))
    # The declaration really was read, so the rule had it in its hands.
    assert declared.outputs_for(ARITHMETIC) == tuple(outputs)

    assert_held(analyse(graph, contract=declared), FORMULA, FORMULA_VALUE)


# ==========================================================================
# After the existing evidence, and only for strings
# ==========================================================================


def test_a_declared_choice_list_keeps_its_own_answer() -> None:
    """A list is the runtime saying the input is a choice; the rule is never asked.

    Three outcomes of that list on an all-numeric node, each exactly what it
    was: the value offered is a select, a value not offered is held with the
    list's sentence, and a list of file names is held and counted as refused.
    """

    numbers = ["FLOAT", "INT"]

    offered = analyse(
        graph_with(ARITHMETIC, {FORMULA: "sum"}),
        contract=contract_for(ARITHMETIC, numbers, formula=[["sum", "product"], {}]),
    )
    assert offered.problems == ()
    assert [(field.id, field.type, field.options) for field in offered.fields] == [
        ("prompt", "multiline", ()),
        ("formula", "select", ("sum", "product")),
        ("seed", "integer", ()),
    ]

    refused = analyse(
        graph_with(ARITHMETIC, {FORMULA: "mean"}),
        contract=contract_for(ARITHMETIC, numbers, formula=[["sum", "product"], {}]),
    )
    assert refused.problems == (
        "Node 1 input 'formula' holds 'mean', and the ComfyUI that would run this "
        "workflow does not offer that: for node class 'ExampleArithmetic' it "
        "declares 'sum', 'product'. Nothing was substituted -- this graph was "
        "saved against a different version of that node, and choosing one of the "
        "values above on your behalf would silently change what it generates.",
    )
    assert refused.not_exposed == ()

    files = analyse(
        graph_with(ARITHMETIC, {FORMULA: "a.txt"}),
        contract=contract_for(ARITHMETIC, numbers, formula=[["a.txt", "b.txt"], {}]),
    )
    assert files.refused_as_file_names == (("1", FORMULA),)
    assert files.not_exposed == ()
    assert control_for(files, "1", FORMULA).section == "needs_review"


def test_a_node_shape_value_outside_its_keys_keeps_its_own_sentence() -> None:
    shape = [
        "COMFY_DYNAMICCOMBO_V3",
        {"options": [{"key": "sum", "inputs": {}}, {"key": "product", "inputs": {}}]},
    ]
    plan = analyse(
        graph_with(ARITHMETIC, {FORMULA: "mean"}),
        contract=contract_for(ARITHMETIC, ["FLOAT"], formula=shape),
    )

    record = control_for(plan, "1", FORMULA)
    assert record.section == "needs_review"
    assert record.reason.startswith(
        "input 'formula' is one this ComfyUI declares as a choice between shapes"
    ), record.reason
    assert plan.not_exposed == ()


def test_what_classify_settles_on_the_same_node_is_untouched() -> None:
    """Only an UNCERTAIN string is asked; a prompt, a number and a lock stay theirs."""

    inputs = {
        FORMULA: FORMULA_VALUE,
        "text": "a lighthouse at dusk",
        "steps": 12,
        "ckpt_name": "weights.safetensors",
    }
    graph = graph_with(ARITHMETIC, inputs)
    without = analyse(graph)
    plan = analyse(graph, contract=contract_for(ARITHMETIC, ["FLOAT"]))

    for name in ("text", "steps", "ckpt_name"):
        assert control_for(plan, "1", name) == control_for(without, "1", name), name
    assert control_for(plan, "1", "ckpt_name").kind == "weights_file"
    assert control_for(plan, "1", FORMULA).kind == COMPUTATION_SLUG


def test_a_number_nothing_could_name_is_not_computation() -> None:
    """``classify`` answers UNCERTAIN for a nameless number too; only text is locked."""

    graph = graph_with(ARITHMETIC, {"__": 3})
    reason = classify("__", 3).reason

    plan = analyse(graph, contract=contract_for(ARITHMETIC, ["FLOAT"]))

    assert control_for(plan, "1", "__") == ControlRecord(
        node="1", input="__", section="needs_review", reason=reason
    )
    assert plan.not_exposed == ()


def test_the_slug_is_one_the_frozen_set_knows() -> None:
    assert COMPUTATION_SLUG in LOCKED_KINDS


def test_the_slug_is_exported_beside_the_other_lock_kinds() -> None:
    import localcanvas_gateway.workflows.sync as sync

    assert sync.COMPUTATION_KIND == COMPUTATION_SLUG
    assert "COMPUTATION_KIND" in sync.__all__
    assert sync.NODE_SHAPE_KIND in sync.LOCKED_KINDS
