"""One number, written ``1`` or ``1.0``, is one control with one id.

An API-format export writes a whole-valued number either way, and which way is
not something the workflow's author chose: the same ``FLOAT`` widget holding one
whole unit comes back from JSON as ``1`` from one export and ``1.0`` from the
next.  The grouping key in `analysis.py` compares a value by its Python type as
well as by what it is, so where two inputs carried one number spelled two ways
they became two fields, and the control lost its bare id -- ``denoise`` became
``denoise-<fingerprint>`` twice over, and every default, draft and saved setup
keyed on ``denoise`` was orphaned by a re-export that changed nothing (T-0102).

The type half of that comparison cannot simply go.  It is, with no runtime to
ask, the only thing keeping T-0097's two unrelated ``value`` inputs apart: a
guidance scale on one ``Primitive`` class holding ``4.0`` and a step count on
another holding ``4``.  So two groups holding the same number in the two
spellings are joined **only on evidence that they are the same kind of
control**, for every pair of inputs across them:

* the runtime declares the same kind of number for both -- ``INT`` and ``INT``,
  or ``FLOAT`` and ``FLOAT``; or
* it declares no number for either, and both are the same input on the same
  class type.

What is asserted here:

* **the invariant, verbatim.**  Two nodes of one class, one ``denoise`` each,
  wired differently, holding ``1`` and ``1.0`` in both orders: one field, the
  bare id ``denoise``, both bindings -- with no runtime, with ``FLOAT`` declared
  and with ``INT`` declared -- and the ids are the ids of the same graph written
  ``1`` and ``1``;
* **the type and the default** of the joined field: the declared kind where one
  is declared, else ``float``, and the first member's value normalised to it;
* **everything without that evidence stays apart**, with the ids the importer
  minted before this card, written down: T-0097's pair with and without a
  runtime, two undeclared classes, ``INT`` against ``FLOAT``, a declared input
  beside a silent one, two different settings declared alike, and ``True``
  beside ``1`` and ``1.0``;
* **a default is rewritten only in a join**: a number written alike keeps the
  graph's own value, type and all;
* **the evidence has to hold for every pair**, not for one member of a group
  the ordinary key had already formed on other evidence;
* ``contract._value_key`` **is untouched**: its other callers still tell ``1``
  from ``1.0``.

Every class and value here is invented; the input names are ComfyUI's ordinary
vocabulary.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict, Optional, Tuple

import pytest

from localcanvas_gateway.workflows import load_registry
from localcanvas_gateway.workflows.sync import analyse
from localcanvas_gateway.workflows.sync.analysis import ImportPlan, PlannedField
from localcanvas_gateway.workflows.sync.contract import (
    RuntimeContract,
    _value_key,
    declared_options,
    read_object_info,
)
from localcanvas_gateway.workflows.sync.definitions import (
    definition_document,
    render_definition,
)

LOADER = "ExampleWeightsLoader"
ENCODER = "ExampleTextEncode"
SAMPLER = "ExampleSampler"
OTHER_SAMPLER = "ExampleOtherSampler"
SWITCH = "ExampleSwitch"
FRACTIONAL_SOURCE = "ExamplePrimitiveFloat"
WHOLE_SOURCE = "ExamplePrimitiveInt"

#: Where each of the two inputs under test sits.  Node 3 sorts first.
FIRST = ("3", "denoise")
SECOND = ("4", "denoise")


def stages(
    first: Any, second: Any, *, first_class: str = SAMPLER, second_class: str = SAMPLER
) -> Dict[str, Any]:
    """Two sampler stages with a ``denoise`` each, wired into different places.

    The wiring differs -- node 3 takes the model and the prompt, node 4 the
    first stage's samples -- so two groups of ``denoise`` get two different
    fingerprints and two ids, rather than being refused as indistinguishable.
    That is what makes the bare id ``denoise`` something a split can visibly
    destroy.
    """

    return {
        "1": {"class_type": LOADER, "inputs": {"ckpt_name": "chosen-weights.safetensors"}},
        "2": {
            "class_type": ENCODER,
            "inputs": {"text": "a quiet street at dawn", "clip": ["1", 1]},
        },
        "3": {
            "class_type": first_class,
            "inputs": {"denoise": first, "model": ["1", 0], "positive": ["2", 0]},
        },
        "4": {
            "class_type": second_class,
            "inputs": {"denoise": second, "samples": ["3", 0]},
        },
    }


def contract(*declarations: Tuple[str, str, str]) -> RuntimeContract:
    """A contract read by the production parser from ``/object_info``'s own shape."""

    document: Dict[str, Any] = {}
    for class_type, input_name, kind in declarations:
        entry = document.setdefault(
            class_type, {"input": {"required": {}}, "output": [], "name": class_type}
        )
        entry["input"]["required"][input_name] = [kind, {}]
    return read_object_info(document, identity_digest="sha256:runtime-t0102")


def runtime(kind: Optional[str]) -> Optional[RuntimeContract]:
    """No runtime, or one declaring ``denoise`` on :data:`SAMPLER` as ``kind``."""

    return None if kind is None else contract((SAMPLER, "denoise", kind))


def ids(plan: ImportPlan) -> Tuple[str, ...]:
    return tuple(item.id for item in plan.fields)


def binding(plan: ImportPlan, target: Tuple[str, str]) -> PlannedField:
    found = [item for item in plan.fields if target in item.targets]
    assert len(found) == 1, "{} is bound by {}".format(target, [item.id for item in found])
    return found[0]


def two_controls(plan: ImportPlan, first: Tuple[str, str], second: Tuple[str, str]) -> None:
    """``first`` and ``second`` are each bound, alone, by a field of their own."""

    one, other = binding(plan, first), binding(plan, second)
    assert one.id != other.id
    assert one.targets == (first,)
    assert other.targets == (second,)


# ==========================================================================
# One number, two spellings, one control
# ==========================================================================

#: The ids of :func:`stages`, written down: a test that compared a plan with
#: ids the same run produced would agree with any answer.
ONE_CONTROL = ("prompt", "denoise")

#: The two spellings, in both orders, so that nothing can depend on which
#: spelling sits on the node that sorts first.
ORDERS = [pytest.param(1, 1.0, id="1-then-1.0"), pytest.param(1.0, 1, id="1.0-then-1")]


@pytest.mark.parametrize("first, second", ORDERS)
@pytest.mark.parametrize(
    "declared, kind, default",
    [
        pytest.param(None, "float", 1.0, id="no-runtime"),
        pytest.param("FLOAT", "float", 1.0, id="FLOAT-FLOAT"),
        pytest.param("INT", "integer", 1, id="INT-INT"),
    ],
)
def test_one_input_written_1_on_one_node_and_1_0_on_another_is_one_control(
    first: Any, second: Any, declared: Optional[str], kind: str, default: Any
) -> None:
    """The card's own measurement, closed: the bare id, and both bindings.

    Same class, same input, so both kinds of evidence are available -- the
    runtime's word where one is asked, the class and input where none is.  The
    ids are also the ids of the same graph with the number written alike,
    which is the invariant itself: a spelling moves nothing.
    """

    plan = analyse(stages(first, second), contract=runtime(declared))
    alike = analyse(stages(1, 1), contract=runtime(declared))

    assert ids(plan) == ONE_CONTROL
    assert ids(alike) == ONE_CONTROL
    field = binding(plan, FIRST)
    assert field.id == "denoise"
    assert field.targets == (FIRST, SECOND)
    assert field.type == kind
    assert field.default == default
    assert type(field.default) is type(default), (
        "1 == 1.0 in Python, so only the type says which one the default is"
    )
    assert list(plan.problems) == []
    assert not plan.needs_review


@pytest.mark.parametrize("first, second", ORDERS)
def test_two_classes_the_runtime_declares_alike_are_one_control_too(
    first: Any, second: Any
) -> None:
    """The runtime's word is the evidence, not the class: two classes, both ``FLOAT``.

    Without a runtime these two stay apart (below) -- so what joins them here is
    the declaration, and a join that asked for the same class even where both
    inputs were declared would leave them two fields.
    """

    plan = analyse(
        stages(first, second, second_class=OTHER_SAMPLER),
        contract=contract((SAMPLER, "denoise", "FLOAT"), (OTHER_SAMPLER, "denoise", "FLOAT")),
    )

    assert ids(plan) == ONE_CONTROL
    field = binding(plan, SECOND)
    assert field.targets == (FIRST, SECOND)
    assert field.type == "float"


def test_the_joined_field_carries_the_range_both_nodes_declare() -> None:
    """A join is a group like any other: its range is the intersection.

    And a declared ``INT`` over a member written ``1.0`` must not leave the
    default fractional -- the schema's loader refuses a fractional default on a
    whole field, and that would cost the workflow its import.
    """

    plan = analyse(
        stages(1.0, 1, second_class=OTHER_SAMPLER),
        contract=read_object_info(
            {
                SAMPLER: {
                    "input": {"required": {"denoise": ["INT", {"min": 0, "max": 10}]}},
                    "output": [],
                },
                OTHER_SAMPLER: {
                    "input": {"required": {"denoise": ["INT", {"min": 1, "max": 20}]}},
                    "output": [],
                },
            },
            identity_digest="sha256:runtime-t0102",
        ),
    )

    field = binding(plan, FIRST)
    assert field.id == "denoise"
    assert (field.type, field.minimum, field.maximum) == ("integer", 1, 10)
    assert field.default == 1 and type(field.default) is int


@pytest.mark.parametrize("declared", [None, "INT", "FLOAT"])
def test_the_joined_definition_loads_through_the_real_registry_loader(
    tmp_path: Path, declared: Optional[str]
) -> None:
    """The loader the gateway runs is what says a type and a default agree."""

    graph = stages(1.0, 1)
    plan = analyse(graph, contract=runtime(declared))
    document = definition_document(
        plan, workflow_id="one", name="One", workflow_relative="one.json"
    )
    (tmp_path / "one.yaml").write_text(render_definition(document), encoding="utf-8")
    (tmp_path / "one.json").write_text(json.dumps(graph), encoding="utf-8")

    registry = load_registry(tmp_path)

    assert list(registry.diagnostics) == []
    found = {item.id: item for item in registry.workflows[0].inputs}
    assert sorted(found) == sorted(ONE_CONTROL)


# ==========================================================================
# No evidence, no join -- and the ids the importer already minted
# ==========================================================================

#: Two classes, no runtime: the ids :func:`stages` produced before this card,
#: captured by running the importer at the commit this branch started from.
TWO_UNDECLARED_CLASSES = ("prompt", "denoise-9482b65a", "denoise-9d1a1573")


@pytest.mark.parametrize("first, second", ORDERS)
def test_two_classes_nobody_declared_holding_1_and_1_0_stay_two_controls(
    first: Any, second: Any
) -> None:
    """The same input name on two classes is not evidence of one control.

    It is the name alone, and the name alone is exactly what joins T-0097's
    unrelated pair: every ``Primitive`` class calls its input ``value``.
    """

    plan = analyse(stages(first, second, second_class=OTHER_SAMPLER))

    two_controls(plan, FIRST, SECOND)
    assert ids(plan) == TWO_UNDECLARED_CLASSES


@pytest.mark.parametrize("first, second", ORDERS)
def test_two_inputs_of_one_class_that_only_share_a_role_stay_two_controls(
    first: Any, second: Any
) -> None:
    """The same class is half of the evidence; the same input is the other half.

    ``noise_seed`` is read as the role ``seed``, so one node's ``seed`` and
    another's ``noise_seed`` are one role on one class -- and still two inputs.
    Nothing says the node that has both means them as one setting.
    """

    graph = stages(0, 0)
    del graph["3"]["inputs"]["denoise"], graph["4"]["inputs"]["denoise"]
    graph["3"]["inputs"]["seed"] = first
    graph["4"]["inputs"]["noise_seed"] = second

    plan = analyse(graph)

    two_controls(plan, ("3", "seed"), ("4", "noise_seed"))


@pytest.mark.parametrize("first, second", ORDERS)
def test_an_input_declared_INT_and_one_declared_FLOAT_stay_two_controls(
    first: Any, second: Any
) -> None:
    """The declared kind is the evidence, so two kinds are evidence against."""

    plan = analyse(
        stages(first, second, second_class=OTHER_SAMPLER),
        contract=contract((SAMPLER, "denoise", "INT"), (OTHER_SAMPLER, "denoise", "FLOAT")),
    )

    two_controls(plan, FIRST, SECOND)
    assert (binding(plan, FIRST).type, binding(plan, SECOND).type) == ("integer", "float")


@pytest.mark.parametrize("first, second", ORDERS)
def test_a_declared_input_beside_a_silent_one_is_not_evidence_either(
    first: Any, second: Any
) -> None:
    """``FLOAT`` on one class, nothing on the other: neither rule is met.

    The declared input is a ``float`` whichever way it is written, and so is the
    one written ``1.0`` -- the same kind of field, and still no evidence that
    they are the same control, because nobody said what the silent one is.
    """

    plan = analyse(
        stages(first, second, second_class=OTHER_SAMPLER),
        contract=contract((SAMPLER, "denoise", "FLOAT")),
    )

    two_controls(plan, FIRST, SECOND)


def primitives(fractional: Any, whole: Any) -> Dict[str, Any]:
    """T-0097's hand-built A/B switch: a guidance scale and a step count.

    Both inputs are ``value``, on two ``Primitive`` classes, and they reach two
    different sampler inputs through two switches.
    """

    return {
        "1": {"class_type": LOADER, "inputs": {"ckpt_name": "chosen-weights.safetensors"}},
        "2": {
            "class_type": ENCODER,
            "inputs": {"text": "a quiet street at dawn", "clip": ["1", 1]},
        },
        "3": {"class_type": FRACTIONAL_SOURCE, "inputs": {"value": fractional}},
        "4": {"class_type": WHOLE_SOURCE, "inputs": {"value": whole}},
        "5": {"class_type": SWITCH, "inputs": {"on_false": ["3", 0]}},
        "6": {"class_type": SWITCH, "inputs": {"on_true": ["4", 0]}},
        "9": {
            "class_type": SAMPLER,
            "inputs": {
                "cfg": ["5", 0],
                "steps": ["6", 0],
                "model": ["1", 0],
                "positive": ["2", 0],
            },
        },
    }


#: :func:`primitives` holding ``4.0`` and ``4``: the ids before this card, with
#: and without a runtime.  They are also the two ids `test_sync_collapse_evidence`
#: gives the same pair when both hold ``4`` and the runtime tells them apart.
T0097_PAIR = ("prompt", "value-6b55232b", "value-ba91676e")


@pytest.mark.parametrize(
    "runtime_for_pair",
    [
        pytest.param(None, id="no-runtime"),
        pytest.param(
            contract((FRACTIONAL_SOURCE, "value", "FLOAT"), (WHOLE_SOURCE, "value", "INT")),
            id="FLOAT-and-INT",
        ),
    ],
)
def test_t0097s_guidance_scale_and_step_count_written_4_0_and_4_stay_two_controls(
    runtime_for_pair: Optional[RuntimeContract],
) -> None:
    """The pair a join without evidence would weld into one slider again."""

    plan = analyse(primitives(4.0, 4), contract=runtime_for_pair)

    two_controls(plan, ("3", "value"), ("4", "value"))
    assert ids(plan) == T0097_PAIR
    assert binding(plan, ("3", "value")).id == "value-ba91676e"
    assert binding(plan, ("3", "value")).type == "float"
    assert binding(plan, ("4", "value")).type == "integer"


@pytest.mark.parametrize("number", [1, 1.0])
def test_a_flag_is_never_the_number_1(number: Any) -> None:
    """``True == 1`` in Python; a flag and a count are still two controls.

    Same class, same input, no runtime -- so every other piece of evidence the
    join accepts is present, and only the flag not being a number stops it.
    """

    plan = analyse(stages(True, number))

    two_controls(plan, FIRST, SECOND)
    assert binding(plan, FIRST).type == "boolean"
    assert binding(plan, FIRST).default is True


@pytest.mark.parametrize("first, second", ORDERS)
def test_two_settings_declared_alike_holding_1_and_1_0_stay_two_controls(
    first: Any, second: Any
) -> None:
    """One number in two spellings on two different inputs is two settings.

    ``cfg`` and ``denoise`` are both declared ``FLOAT`` on one class, so the
    declaration half of the evidence is met for the pair -- and they are still
    two things a user sets.  The join is asked only within one role, and the
    ids stay the bare roles they are when nothing is joined.
    """

    graph = stages(first, second)
    graph["3"]["inputs"]["cfg"] = graph["3"]["inputs"].pop("denoise")

    plan = analyse(
        graph,
        contract=contract((SAMPLER, "cfg", "FLOAT"), (SAMPLER, "denoise", "FLOAT")),
    )

    two_controls(plan, ("3", "cfg"), SECOND)
    assert ids(plan) == ("prompt", "cfg", "denoise")


@pytest.mark.parametrize(
    "held, declared",
    [
        pytest.param(0.5, "INT", id="0.5-under-INT"),
        pytest.param(1, "FLOAT", id="1-under-FLOAT"),
    ],
)
def test_outside_a_join_a_default_is_written_as_the_graph_holds_it(
    held: Any, declared: str
) -> None:
    """Rewriting a default to the field's type belongs to the join and to nothing else.

    Both inputs hold the number written alike, so nothing is joined and the
    default is the graph's own value, type and all, exactly as before this
    card -- a normalisation that leaked out of the join would turn ``0.5``
    into ``0`` under a declared ``INT``, changing what the workflow generates.
    """

    plan = analyse(stages(held, held), contract=runtime(declared))

    field = binding(plan, FIRST)
    assert field.targets == (FIRST, SECOND)
    assert field.default == held
    assert type(field.default) is type(held)


def test_the_evidence_has_to_hold_for_every_input_joined() -> None:
    """A group the ordinary key formed is joined whole or not at all.

    Nodes 3 and 5 are one class, undeclared, holding ``1``; node 4 is another
    class, undeclared, also holding ``1`` -- the key already makes one control
    of all three.  Node 6 is node 3's class holding ``1.0``.  Node 6 and node 3
    have the evidence; node 6 and node 4 do not.  Joining node 6 in would make
    it one control with node 4 on no evidence at all, so it stays apart, and
    the three the key joined stay exactly as they were.
    """

    graph = stages(1, 1, second_class=OTHER_SAMPLER)
    graph["5"] = {"class_type": SAMPLER, "inputs": {"denoise": 1, "samples": ["4", 0]}}
    graph["6"] = {"class_type": SAMPLER, "inputs": {"denoise": 1.0, "latent": ["5", 0]}}

    plan = analyse(graph)

    assert binding(plan, FIRST).targets == (FIRST, SECOND, ("5", "denoise"))
    assert binding(plan, ("6", "denoise")).targets == (("6", "denoise"),)


# ==========================================================================
# The other questions `_value_key` answers are not this one
# ==========================================================================


def test_value_key_still_tells_1_from_1_0_for_everybody_else() -> None:
    """The grouping has its own key; this one stays type-exact.

    A declared choice list holding ``1`` beside ``1.0`` is still refused, as
    the schema's loader would refuse it, and an exact repeat is still read
    once -- so widening ``_value_key`` would fail here and not only in the
    files about those rules.
    """

    assert _value_key(1) != _value_key(1.0)
    assert _value_key(True) != _value_key(1)
    assert declared_options([[1, 1.0, 2]]) is None
    assert declared_options([[1, 1, 2]]) == (1, 2)
