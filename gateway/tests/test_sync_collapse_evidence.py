"""Holding the same number is not being the same control.

`analysis.py` collapses two node inputs into one logical field on **provable
sameness**, and the proof used to be the role and the value.  That argument
holds only while the role is a real word for what the input does.  It is not
proof when the graph's own word *is* the placeholder -- ``value`` is what
ComfyUI's ``Primitive*`` family calls its only input, and two of them holding
the number ``4`` is no evidence at all that they are one control.  Measured on
a real catalogue, one of them was a guidance scale and the other a sampler's
step count, and a single slider silently set both.

The evidence that separates them is the one the module already trusts for a
list of choices: **what the ComfyUI that will run this graph declares the input
to be**.  A ``value`` the runtime calls ``FLOAT`` and a ``value`` it calls
``INT`` are provably not one control, on the runtime's own word.  So the
declared *kind of number* joined the grouping key, exactly as the declared
choice list is already in it.

The kind of number, and nothing else about the declaration -- and only where
that is not the kind the value is already written as.  Two narrowings, each
measured and each with its own section below:

* a ``min``, a ``max`` and a ``step`` say how far one node's input goes; none
  of them says two inputs are different controls, and a step is a widget
  increment that cannot make a node refuse a value at all.  In the key they
  split one seed a user sets once for two sampler stages into two fields and
  destroyed the id ``seed``, because one class declared an increment the other
  did not;
* **silence is not a disagreement, and neither is agreement.**  A key that said
  "somebody spoke about this input" would split that same seed the moment one
  of the two classes was missing from the ComfyUI that answered -- a node pack
  it does not have, a version skew, a spec shape the parser does not read.  The
  same catalogue synced against two machines would then produce two different
  sets of field ids, and every saved default keyed on the id that vanished
  would be orphaned with nothing about the workflow having changed.  A
  declaration that only confirms what the value says is no reason to split
  either: the field's type is what it would have been.

What is asserted here, in the order it matters:

* **the split happens where the field's real kind of number differs, and
  nowhere else.**  The same graph, the same two numbers, the same everything --
  with a runtime that calls one of them something other than what its value
  says they are two controls, and with no runtime at all they are the one
  control they always were.  The fixture cannot make either answer true by
  itself, because it is the same fixture in both;
* **a range never decides identity, and is reconciled instead.**  Two nodes
  behind one control keep the greatest ``min``, the least ``max``, and the
  ``step`` they both declare -- and the same bound written ``1`` on one and
  ``1.0`` on the other is one bound, answered the same way whichever node
  carries which, because ``1 == 1.0`` in Python and a rule reading one member
  would answer from whichever class sorted first.  What the intersection is
  worth is conditional and is stated as such: where the value the graph carries
  lies inside it, the range offered is one every node accepts; where the value
  contradicts an end of it, that end is dropped rather than moved, exactly as
  for a single input, and that side is as unbounded as it was before this card;
* **each of the two then gets its own declared type and its own bounds.**  The
  fractional one is a float from ``0.0`` to ``100.0``, asserted verbatim.  That
  is the T-0098 regression this file exists to close: the group used to form
  *before* the numeric authority was resolved, so the two declarations
  disagreed, no type was authoritative, and a declared ``FLOAT`` became a
  whole-number control with both of its bounds thrown away;
* **a genuine collapse still collapses.**  Two inputs the runtime declares
  alike are one control however placeholder-ish their name is -- including two
  inputs both called ``value``.  Nothing here keys on a list of meaningless
  words, and the test that would fail if it did is the one where two ``value``
  inputs *do* become one field;
* **the class type is not in the key.**  One ``seed`` shared by two different
  sampler classes is a legitimate collapse, and it stays one field with one id;
* **no id is derived from the declaration.**  Change the declared bounds and
  every id is the same string.  An id moves only where a role stopped being
  unique, which is where one id was standing for two inputs that end up two
  different kinds of control;
* **no runtime, no change.**  Against the bytes the shipped importer wrote for
  this fixture, captured by running the module out of git at the commit this
  branch started from -- not against a second run of the code under test.

On the guards this made redundant.  The kind of number a field will really be
is settled by two components of the grouping key together -- the type read from
the value, and the declared type wherever it differs from that -- and both are
strings, so every member of a group ends up the same kind of number by
construction.  The unanimity checks that used to stand in
``_numeric_type_of`` and ``_numeric_bounds`` could then only ever agree with
the key: no input could tell the two apart, and no test could fail on the
second one alone.  They were removed rather than left standing.  What replaced
them, :func:`analysis._resolved_declaration`, is not a guard at all: it reads
every member of the group and combines them, so there is no "the first member's
word" for a mutation to move to the last member's, and the tests below
enumerate what it must answer.

Every node class and value in this file is invented for it.  The input *names*
are ComfyUI's ordinary vocabulary, which is what the defect is about
(no model family, no custom node and no personal workflow is named anywhere
here).
"""

from __future__ import annotations

from typing import Any, Dict, List, Tuple

import pytest

from localcanvas_gateway.workflows.sync import analyse
from localcanvas_gateway.workflows.sync.analysis import ImportPlan, PlannedField
from localcanvas_gateway.workflows.sync.contract import (
    RuntimeContract,
    read_object_info,
)
from localcanvas_gateway.workflows.sync.definitions import (
    definition_document,
    render_definition,
)

# --------------------------------------------------------------------------
# One graph with all three shapes in it
# --------------------------------------------------------------------------

LOADER = "ExampleWeightsLoader"
ENCODER = "ExampleTextEncode"
SAMPLER = "ExampleSampler"
REFINER = "ExampleRefinerSampler"
SWITCH = "ExampleSwitch"
ADAPTER = "ExampleAdapterLoader"

#: The two classes whose only input is called ``value``.  One carries whole
#: numbers and the other fractional ones, and *nothing in the graph says so* --
#: which is the whole difficulty.
FRACTIONAL_SOURCE = "ExamplePrimitiveFloat"
WHOLE_SOURCE = "ExamplePrimitiveInt"


def graph(*, held: Any = 4) -> Dict[str, Any]:
    """A graph a ComfyUI author builds by hand, with an A/B switch in it.

    Nodes 3 and 4 are the defect: two placeholder-named inputs holding the same
    number, one of them a guidance scale and the other a step count, told apart
    by nothing the graph itself contains.  Node 7 is the control -- the same
    placeholder name on the same class as node 4, holding a different number,
    so it was never in doubt.  Nodes 20 and 21 are the genuine collapse: one
    strength a user sets once that really does feed two nodes.
    """

    return {
        "1": {
            "class_type": LOADER,
            "inputs": {"ckpt_name": "chosen-weights.safetensors"},
        },
        "2": {
            "class_type": ENCODER,
            "inputs": {"text": "a quiet street at dawn", "clip": ["1", 1]},
        },
        "3": {"class_type": FRACTIONAL_SOURCE, "inputs": {"value": held}},
        "4": {"class_type": WHOLE_SOURCE, "inputs": {"value": held}},
        "5": {"class_type": SWITCH, "inputs": {"on_false": ["3", 0]}},
        "6": {"class_type": SWITCH, "inputs": {"on_true": ["4", 0]}},
        "7": {"class_type": WHOLE_SOURCE, "inputs": {"value": 50}},
        "9": {
            "class_type": SAMPLER,
            "inputs": {
                "seed": 7,
                "cfg": ["5", 0],
                "steps": ["6", 0],
                "batch_size": ["7", 0],
                "model": ["21", 0],
                "positive": ["2", 0],
            },
        },
        "20": {
            "class_type": ADAPTER,
            "inputs": {"strength_model": 1, "strength_clip": 1, "model": ["1", 0]},
        },
        "21": {
            "class_type": ADAPTER,
            "inputs": {"strength_model": 1, "strength_clip": 1, "model": ["20", 0]},
        },
    }


def twin_graph() -> Dict[str, Any]:
    """Two ``value`` inputs that really are one control, on the same class.

    The same placeholder name, the same number, the same declaration -- and two
    nodes, wired into two different places, so a rule that refused to collapse
    a "meaningless" name would make two fields of them.  It makes one.
    """

    return {
        "1": {
            "class_type": LOADER,
            "inputs": {"ckpt_name": "chosen-weights.safetensors"},
        },
        "2": {
            "class_type": ENCODER,
            "inputs": {"text": "a quiet street at dawn", "clip": ["1", 1]},
        },
        "3": {"class_type": WHOLE_SOURCE, "inputs": {"value": 20}},
        "4": {"class_type": WHOLE_SOURCE, "inputs": {"value": 20}},
        "5": {"class_type": SWITCH, "inputs": {"on_true": ["3", 0]}},
        "6": {"class_type": SWITCH, "inputs": {"on_false": ["4", 0]}},
        "9": {
            "class_type": SAMPLER,
            "inputs": {
                "steps": ["5", 0],
                "batch_size": ["6", 0],
                "model": ["1", 0],
                "positive": ["2", 0],
            },
        },
    }


def two_sampler_graph(
    first: str = SAMPLER, second: str = REFINER, *, held: int = 7
) -> Dict[str, Any]:
    """One seed feeding two samplers of two different classes.

    A real shape and a legitimate collapse: the user sets one seed and both
    stages take it.  The class types differ, which is what makes this the case
    that says whether the class type belongs in the grouping key -- and what
    makes it the case for every question about two declarations meeting inside
    one field.

    ``first`` and ``second`` are which class sits on which node, so a test can
    put the same two declarations on the graph the other way round.  Node 3
    sorts before node 4 whichever way it is done, so any answer that changes
    between the two orders was read off one member rather than all of them.

    ``held`` is the seed both nodes carry.  It matters to more than the
    default: a bound the graph's own value contradicts is dropped, so a fixture
    whose value sits outside the range under test can make an assertion true
    for a reason that has nothing to do with the rule it names.
    """

    return {
        "1": {
            "class_type": LOADER,
            "inputs": {"ckpt_name": "chosen-weights.safetensors"},
        },
        "2": {
            "class_type": ENCODER,
            "inputs": {"text": "a quiet street at dawn", "clip": ["1", 1]},
        },
        "3": {
            "class_type": first,
            "inputs": {
                "seed": held,
                "steps": 20,
                "model": ["1", 0],
                "positive": ["2", 0],
            },
        },
        "4": {
            "class_type": second,
            "inputs": {"seed": held, "steps": 8, "samples": ["3", 0]},
        },
    }


# --------------------------------------------------------------------------
# The ComfyUI that knows what its numbers are
# --------------------------------------------------------------------------


def object_info(*declarations: Tuple[str, str, Any]) -> Dict[str, Any]:
    """``/object_info`` in ComfyUI's own shape, for the given declarations."""

    document: Dict[str, Any] = {}
    for class_type, input_name, spec in declarations:
        entry = document.setdefault(
            class_type, {"input": {"required": {}}, "output": [], "name": class_type}
        )
        entry["input"]["required"][input_name] = spec
    return document


def contract(*declarations: Tuple[str, str, Any]) -> RuntimeContract:
    """A contract read from an ``/object_info`` of that shape.

    Built through the production parser, so that a test still says something
    about the shape ComfyUI really sends.
    """

    return read_object_info(object_info(*declarations), identity_digest="sha256:runtime-a")


def number(kind: str, **config: Any) -> List[Any]:
    """One ``/object_info`` spec declaring an input as a numeric type."""

    return [kind, dict(config)]


#: What the runtime says about the graph above.  The two ``value`` inputs are
#: the point: the same name, and two different declarations.
DECLARED: Tuple[Tuple[str, str, Any], ...] = (
    (FRACTIONAL_SOURCE, "value", number("FLOAT", min=0.0, max=100.0, step=0.1)),
    (WHOLE_SOURCE, "value", number("INT", min=1, max=200)),
    (ADAPTER, "strength_model", number("FLOAT", min=0.0, max=10.0, step=0.01)),
    (ADAPTER, "strength_clip", number("FLOAT", min=0.0, max=10.0, step=0.01)),
)

#: The ids this fixture mints.  Written down rather than read off the plan: a
#: test that compared the run against ids the same run produced would pass on
#: any id at all, and these are the keys a user's saved settings hang off.
FRACTIONAL_FIELD = "value-ba91676e"
WHOLE_FIELD = "value-6b55232b"
CONTROL_FIELD = "value-ad814b5c"

#: And the id of the one field that stood for both of them, with no runtime to
#: tell them apart.  It is the only field in this file bound to two nodes that
#: are wired into different places, so it is the only id here that T-0113
#: moved: while a collapsed field took its fingerprint from whichever member
#: sorted first, this was ``value-ba91676e`` -- the same string as the
#: fractional field's, because node 3 sorted first and it is node 3's
#: fingerprint -- and a re-export that renumbered the graph changed it to the
#: other member's.  It is now minted from both members at once, so it is no
#: longer any single member's fingerprint and no numbering can move it.
MERGED_FIELD = "value-185940ea"


# --------------------------------------------------------------------------
# Looking at a plan
# --------------------------------------------------------------------------


def field_named(plan: ImportPlan, field_id: str) -> PlannedField:
    found = [item for item in plan.fields if item.id == field_id]
    assert found, "no field {!r}; there are {}".format(
        field_id, [item.id for item in plan.fields]
    )
    return found[0]


def binding(plan: ImportPlan, target: Tuple[str, str]) -> PlannedField:
    """The one field that writes into ``target``, or a loud failure."""

    found = [item for item in plan.fields if target in item.targets]
    assert len(found) == 1, "{} is bound by {}".format(
        target, [item.id for item in found]
    )
    return found[0]


def bounds(item: PlannedField) -> Tuple[Any, Any, Any]:
    return (item.minimum, item.maximum, item.step)


def ids(plan: ImportPlan) -> Tuple[str, ...]:
    return tuple(item.id for item in plan.fields)


# ==========================================================================
# The defect, and the evidence that ends it
# ==========================================================================


def test_a_guidance_scale_and_a_step_count_are_two_controls_when_the_runtime_says_so() -> None:
    """The same graph twice.  Only the runtime differs, and it decides.

    Without a declaration the two are one field, which is the defect preserved:
    there is no evidence in the graph, and this importer does not invent any.
    With one, they are two fields, each binding its own node -- and the field
    that used to write into both no longer exists in that form.
    """

    without = analyse(graph())
    declared = analyse(graph(), contract=contract(*DECLARED))

    # The fixture on its own proves nothing: this is the same graph.
    assert binding(without, ("3", "value")) is binding(without, ("4", "value"))
    assert binding(without, ("3", "value")).targets == (("3", "value"), ("4", "value"))

    fractional = binding(declared, ("3", "value"))
    whole = binding(declared, ("4", "value"))
    assert fractional.id == FRACTIONAL_FIELD
    assert whole.id == WHOLE_FIELD
    assert fractional.targets == (("3", "value"),)
    assert whole.targets == (("4", "value"),)


def test_each_of_the_two_receives_its_own_declared_type_and_its_own_bounds() -> None:
    """The T-0098 regression this card exists to close.

    The group used to be formed before the numeric authority was resolved, so
    the two declarations met each other inside one field, disagreed, and left
    the field with the type its *value* looked like and no bounds at all: a
    declared ``FLOAT`` reaching the user as a whole-number control that cannot
    hold 4.5.  Both halves are asserted verbatim, because a rule that only ever
    widened would break every genuine whole number in a catalogue.
    """

    declared = analyse(graph(), contract=contract(*DECLARED))

    fractional = field_named(declared, FRACTIONAL_FIELD)
    assert fractional.type == "float"
    assert bounds(fractional) == (0.0, 100.0, 0.1)
    assert fractional.default == 4

    whole = field_named(declared, WHOLE_FIELD)
    assert whole.type == "integer"
    assert bounds(whole) == (1, 200, None)
    assert whole.default == 4


def test_the_number_beside_them_that_was_never_ambiguous_is_untouched() -> None:
    """The control: one more ``value``, on a class already in the graph.

    It holds a different number, so it was its own field before this card and
    is its own field after it, with the same id and the same declared range.
    """

    declared = analyse(graph(), contract=contract(*DECLARED))

    control = binding(declared, ("7", "value"))
    assert control.id == CONTROL_FIELD
    assert control.type == "integer"
    assert bounds(control) == (1, 200, None)
    assert control.targets == (("7", "value"),)
    assert ids(analyse(graph())).count(CONTROL_FIELD) == 1, "it had this id before too"


def test_the_inventory_says_which_field_each_of_the_two_inputs_became() -> None:
    """A curator reads the inventory, and it has to agree with the fields.

    An entry per literal input is the promise; two inputs that are now two
    different controls must not both point at one field id.
    """

    declared = analyse(graph(), contract=contract(*DECLARED))
    named = {
        item.target: (item.section, item.field)
        for item in declared.controls
    }

    assert named[("3", "value")] == ("advanced", FRACTIONAL_FIELD)
    assert named[("4", "value")] == ("advanced", WHOLE_FIELD)
    assert named[("7", "value")] == ("advanced", CONTROL_FIELD)


# ==========================================================================
# What must still collapse
# ==========================================================================


def test_two_inputs_the_runtime_declares_alike_are_one_control_still() -> None:
    """The genuine collapse: one strength, two nodes, one control.

    The only multi-target collapse in the measured catalogue has this shape,
    and it is the whole reason the fix is positive evidence rather than a rule
    against collapsing.  Both ids are asserted verbatim and both are the bare
    role, which is what a user's saved defaults are keyed on.
    """

    declared = analyse(graph(), contract=contract(*DECLARED))

    model = field_named(declared, "strength_model")
    clip = field_named(declared, "strength_clip")

    assert model.targets == (("20", "strength_model"), ("21", "strength_model"))
    assert clip.targets == (("20", "strength_clip"), ("21", "strength_clip"))
    assert model.type == clip.type == "float"
    assert bounds(model) == bounds(clip) == (0.0, 10.0, 0.01)


def test_two_placeholder_named_inputs_the_runtime_declares_alike_are_one_control() -> None:
    """``value`` is not a forbidden word, and this is the test that says so.

    Two inputs both called ``value``, on two nodes, wired into two different
    places -- so a rule that refused to collapse a "meaningless" name, or one
    that keyed the group on the node's class, would make two fields here.  They
    are one field with two bindings, because the evidence says they are one
    control: the same number, and the same thing declared about both.
    """

    document = twin_graph()
    assert document["3"]["class_type"] == document["4"]["class_type"]
    declared = analyse(
        document, contract=contract((WHOLE_SOURCE, "value", number("INT", min=1, max=200)))
    )

    together = binding(declared, ("3", "value"))
    assert together.targets == (("3", "value"), ("4", "value"))
    assert together.type == "integer"
    assert bounds(together) == (1, 200, None)
    assert len([item for item in declared.fields if item.id.startswith("value")]) == 1


def test_a_seed_two_sampler_classes_share_is_one_control_with_one_id() -> None:
    """The class type is real evidence, and it is not in the key.

    Two different sampler classes carrying one seed is an ordinary two-stage
    graph, and the user sets that seed once.  Keying the group on the class
    would make two seed fields of it and move the id off ``seed`` -- so the
    class type stays out, and this is the case that would notice if it did not.
    Both directions are asserted: with a runtime that declares the two alike,
    and with no runtime at all.
    """

    document = two_sampler_graph()
    assert document["3"]["class_type"] != document["4"]["class_type"], (
        "the classes must really differ, or this test proves nothing"
    )

    for plan in (
        analyse(document),
        analyse(
            document,
            contract=contract(
                (SAMPLER, "seed", number("INT", min=0, max=1125899906842624)),
                (REFINER, "seed", number("INT", min=0, max=1125899906842624)),
            ),
        ),
    ):
        seed = binding(plan, ("3", "seed"))
        assert seed.id == "seed"
        assert seed.targets == (("3", "seed"), ("4", "seed"))
        assert seed.role_hint == "seed"


# ==========================================================================
# The kind of number, and not how far it goes
#
# What separates two controls is the runtime calling one of them whole and the
# other fractional.  A ``min``, a ``max`` and a ``step`` say how far one node's
# input goes, and none of them says the two inputs are different controls -- so
# none of them is in the grouping key, and a field with several bindings
# carries the range they all share.  The alternative was measured and rejected:
# with the range in the key, a `step` declared on one widget and not the other
# split a seed a user sets once into two fields and destroyed the id ``seed``.
# ==========================================================================


def seed_contract(first: Any, second: Any) -> RuntimeContract:
    """Two declarations for one ``seed``, one per sampler class."""

    return contract((SAMPLER, "seed", first), (REFINER, "seed", second))


def the_seed(plan: ImportPlan) -> PlannedField:
    """The seed field, insisting it is one field with both bindings.

    Written once because every test in this section makes the same two claims
    about identity before it says anything about a range: the id is the bare
    role, and both nodes are bound to it.
    """

    seed = binding(plan, ("3", "seed"))
    assert seed.id == "seed"
    assert seed.targets == (("3", "seed"), ("4", "seed"))
    return seed


def test_a_step_on_one_widget_and_not_the_other_does_not_split_a_control() -> None:
    """A step is an increment, and an increment cannot make a node refuse.

    Two classes declare the same whole number over the same range and one of
    them also declares how far the arrows move it.  If that reached the
    grouping key the user's one seed would become two fields and the id
    ``seed`` would cease to exist -- for a difference that cannot make either
    node reject a value.  It stays one control; the step is the one they all
    declare, and here they do not all declare one, so none is carried.
    """

    plan = analyse(
        two_sampler_graph(),
        contract=seed_contract(
            number("INT", min=0, max=100, step=1), number("INT", min=0, max=100)
        ),
    )

    assert bounds(the_seed(plan)) == (0, 100, None)


def test_two_inputs_whose_declared_maxima_differ_share_the_range_they_both_allow() -> None:
    """One control, and the range every node behind it accepts.

    The value a user can set has to be one *both* nodes take, so the field
    carries the least declared maximum and the greatest declared minimum.  That
    is stronger than what carrying no range at all used to do here: no range
    left every value reachable and only took the slider away.
    """

    plan = analyse(
        two_sampler_graph(),
        contract=seed_contract(
            number("INT", min=0, max=100), number("INT", min=0, max=50)
        ),
    )

    assert bounds(the_seed(plan)) == (0, 50, None)


def test_two_inputs_whose_declared_minima_differ_share_the_range_they_both_allow() -> None:
    """The other end of the same intersection, so neither is the whole rule."""

    plan = analyse(
        two_sampler_graph(),
        contract=seed_contract(
            number("INT", min=0, max=100), number("INT", min=2, max=100)
        ),
    )

    assert bounds(the_seed(plan)) == (2, 100, None)


def test_declared_ranges_that_do_not_overlap_leave_the_field_with_none() -> None:
    """Nothing is invented where there is nothing both nodes accept.

    An empty intersection is not a range to carry and not a range to widen
    until it is one.  The field falls back to a typed entry box, which is what
    an incoherent pair has always meant here -- and it is still one control,
    because the two nodes disagreeing about limits is not evidence that a user
    is setting two different things.

    The seed is ``3`` and that is the whole care in this fixture.  ``0..5``
    against ``20..100`` intersects to ``min 20, max 5``, which no value can
    satisfy -- so with the graph's usual seed of 7 *both* bounds would be
    dropped for contradicting the value, and this test would pass with the
    coherence rule deleted, confirming its own fixture and saying nothing about
    the code.  At 3 only the ``min`` is contradicted: without the rule the
    field keeps ``max 5``, and the assertion below fails, which is what it is
    for.
    """

    plan = analyse(
        two_sampler_graph(held=3),
        contract=seed_contract(
            number("INT", min=0, max=5), number("INT", min=20, max=100)
        ),
    )

    assert bounds(the_seed(plan)) == (None, None, None)


@pytest.mark.parametrize(
    "arrangement",
    [
        pytest.param((SAMPLER, REFINER), id="the whole spelling on the earlier node"),
        pytest.param((REFINER, SAMPLER), id="the whole spelling on the later node"),
    ],
)
def test_a_bound_written_1_and_1_0_is_one_bound_whichever_node_carries_which(
    arrangement,
) -> None:
    """The same limit spelled two ways, and the answer may not depend on order.

    ``1 == 1.0`` in Python and the two hash alike, so a rule that read the
    range off one member of the group would answer from whichever class landed
    on the lower node id -- and it would matter, because a whole field carries
    a whole bound and drops a fractional one.  The same graph with the two
    classes swapped is the same graph as far as this question goes, so both
    orders are asserted and both must give the whole spelling.

    ``isinstance`` rather than ``==``: ``1 == 1.0`` is exactly the equality
    that makes a value assertion here worth nothing.
    """

    plan = analyse(
        two_sampler_graph(*arrangement),
        contract=seed_contract(
            number("INT", min=1, max=100), number("INT", min=1.0, max=100.0)
        ),
    )

    seed = the_seed(plan)
    assert bounds(seed) == (1, 100, None)
    assert isinstance(seed.minimum, int) and not isinstance(seed.minimum, float)
    assert isinstance(seed.maximum, int) and not isinstance(seed.maximum, float)


@pytest.mark.parametrize(
    "arrangement",
    [
        pytest.param((SAMPLER, REFINER), id="the whole spelling on the earlier node"),
        pytest.param((REFINER, SAMPLER), id="the whole spelling on the later node"),
    ],
)
def test_a_step_spelled_two_ways_is_carried_by_neither_node(arrangement) -> None:
    """The same trap as the bound above, answered the other way, on purpose.

    ``{1, 1.0}`` is one element in a Python set, so a step resolved through a
    plain set would call these two runtimes agreed and then keep whichever
    spelling was inserted first -- and on a whole field one of the two survives
    ``_usable_bound`` and the other does not.  Two spellings are two answers
    here and no step is carried, in both node orders.

    Deliberately not what a *bound* does with the same pair.  A bound lost lets
    a user reach a value a node refuses; a step lost costs the arrows.  Only
    one of those is worth resolving a tie for, and reconciling a step would be
    this importer choosing an increment between two the runtimes gave.
    """

    plan = analyse(
        two_sampler_graph(*arrangement),
        contract=seed_contract(
            number("INT", min=0, max=100, step=1),
            number("INT", min=0, max=100, step=1.0),
        ),
    )

    assert bounds(the_seed(plan)) == (0, 100, None)


def test_the_fractional_spelling_alone_is_still_dropped_on_a_whole_field() -> None:
    """The control that keeps the test above honest.

    If *nobody* declares the whole spelling there is no whole bound to prefer,
    and a fractional limit on a whole field is one this schema cannot write
    down -- so it is left out, exactly as it is for a single input.  Without
    this, "prefer the whole one" could be an implementation that quietly
    rounded a fraction into a bound nobody declared.
    """

    plan = analyse(
        two_sampler_graph(),
        contract=seed_contract(
            number("INT", min=1.0, max=100.0), number("INT", min=1.0, max=100.0)
        ),
    )

    assert bounds(the_seed(plan)) == (None, None, None)


# ==========================================================================
# Silence is not a disagreement
#
# The key carries the kind of number the field will REALLY be, which for an
# input nobody declared is the kind its value is written as.  A key that said
# "somebody spoke about this one" instead would split a seed two stages share
# the moment one class was missing from the ComfyUI that answered -- a node
# pack it does not have, a version skew, a spec the parser does not read -- and
# the bare id `seed` would be gone.  The same catalogue synced against two
# machines would produce two different sets of field ids, and every saved
# default keyed on the old one would be orphaned with nothing about the graph
# having changed.  All four shapes of silence are here because they arrive by
# four different routes through `contract.py`.
# ==========================================================================


@pytest.mark.parametrize(
    "silence",
    [
        pytest.param(
            lambda: contract((SAMPLER, "seed", number("INT", min=0, max=100))),
            id="the other class is absent from object_info",
        ),
        pytest.param(
            lambda: contract(
                (SAMPLER, "seed", number("INT", min=0, max=100)),
                (REFINER, "steps", number("INT", min=1, max=50)),
            ),
            id="the other class is there without this input",
        ),
        pytest.param(
            lambda: contract(
                (SAMPLER, "seed", number("INT", min=0, max=100)),
                (REFINER, "seed", ["NUMBER", {}]),
            ),
            id="a type name this does not read",
        ),
        pytest.param(
            lambda: contract(
                (SAMPLER, "seed", number("INT", min=0, max=100)),
                (REFINER, "seed", "INT"),
            ),
            id="a bare type name outside a list",
        ),
    ],
)
def test_a_runtime_silent_about_one_of_two_inputs_does_not_split_the_control(
    silence,
) -> None:
    """One declared, one not, and it stays the one control it always was.

    Every one of these is an ordinary day: a ComfyUI without the node pack the
    other machine has, a build whose inputs moved, a spec shape this parser
    does not read.  None of them is a statement that the user is setting two
    different things, and treating it as one would hand the same workflow two
    different sets of ids on two machines.

    The declared bounds are asserted as well, because this is where they now
    reach an input whose own runtime said nothing.  That is deliberate and it
    is the narrow half: one control writes one value into both nodes, so a
    limit true of either is a limit on the control, and a bound only ever
    narrows what may be set where the alternative is no bound at all.
    """

    plan = analyse(two_sampler_graph(), contract=silence())

    seed = the_seed(plan)
    assert seed.type == "integer"
    assert bounds(seed) == (0, 100, None)


def test_the_silent_half_is_really_silent() -> None:
    """The control the four cases above cannot do without.

    Each of them says "these two collapse", and a contract that declared
    *nothing at all* would say the same -- so without this they would pass
    against a run in which the first declaration never arrived either, and the
    bounds asserted there would have to come from somewhere.  Here the same two
    routes are put side by side: nothing declared anywhere carries no bounds,
    and the declared half alone carries its own.
    """

    nothing = analyse(two_sampler_graph(), contract=read_object_info(
        {}, identity_digest="sha256:x"
    ))
    one_half = analyse(
        two_sampler_graph(),
        contract=contract((SAMPLER, "seed", number("INT", min=0, max=100))),
    )

    assert bounds(the_seed(nothing)) == (None, None, None)
    assert bounds(the_seed(one_half)) == (0, 100, None)


def test_a_declaration_that_only_confirms_the_value_is_not_a_reason_to_split() -> None:
    """``INT`` over a whole number says nothing new, so it separates nothing.

    The hazard this card is about is a runtime contradicting the value -- a
    ``FLOAT`` over a number written ``4``, which turns a whole-number control
    into a fractional one.  A declaration that names the type the field already
    had changes nothing about the control, so an input carrying it and an input
    carrying nothing are still one field.  Asserted against the same graph with
    no runtime at all, which must give the same id and the same bindings.
    """

    quiet = analyse(two_sampler_graph())
    confirmed = analyse(
        two_sampler_graph(), contract=contract((SAMPLER, "seed", number("INT")))
    )

    assert the_seed(confirmed).id == the_seed(quiet).id == "seed"
    assert the_seed(confirmed).type == the_seed(quiet).type == "integer"


def test_a_runtime_that_contradicts_the_value_of_one_input_does_split_it() -> None:
    """And the hazard the rule above must not swallow, on the same fixture.

    ``FLOAT`` over a seed written ``7`` is the runtime saying this input is not
    the whole number it looks like.  Merged with an input nothing vouched for,
    the user could type ``7.5`` into a node whose runtime never said it would
    take one.  So this pair is two fields -- the same graph, the same silence
    on the other side, and only the *content* of the declaration different from
    the test above.
    """

    plan = analyse(
        two_sampler_graph(), contract=contract((SAMPLER, "seed", number("FLOAT")))
    )

    fractional = binding(plan, ("3", "seed"))
    whole = binding(plan, ("4", "seed"))
    assert fractional is not whole
    assert fractional.type == "float"
    assert whole.type == "integer"
    assert not [item for item in plan.fields if item.id == "seed"]


def test_one_kind_of_number_against_another_still_makes_two_controls() -> None:
    """And the whole of this section leaves the card's own fix standing.

    The same seed, the same two classes, the same collapse in every test above
    -- and the moment the runtime calls one of them fractional and the other
    whole, they are two fields with two ranges.  That is the line: the kind of
    number is evidence about identity and the range is not.
    """

    plan = analyse(
        two_sampler_graph(),
        contract=seed_contract(
            number("INT", min=0, max=100), number("FLOAT", min=0.0, max=100.0)
        ),
    )

    whole = binding(plan, ("3", "seed"))
    fractional = binding(plan, ("4", "seed"))
    assert whole is not fractional
    assert whole.type == "integer"
    assert bounds(whole) == (0, 100, None)
    assert fractional.type == "float"
    assert bounds(fractional) == (0.0, 100.0, None)
    assert not [item for item in plan.fields if item.id == "seed"]


def test_a_float_declared_over_one_of_the_two_whole_numbers_separates_them() -> None:
    """``FLOAT`` over a ``4`` is a contradiction, and a contradiction separates.

    Not because one input was spoken about and the other was not -- that alone
    keeps them together, and there is a section below that says so.  This one
    turns on *what* was said: the runtime calls node 3's ``value`` fractional
    while the graph writes it ``4``, so that input becomes a control that can
    hold 4.5, and node 4's has nothing vouching for a fractional value at all.
    The declared one takes what it was declared; the other is left exactly as a
    run with no runtime would have left it.
    """

    declared = analyse(
        graph(), contract=contract((FRACTIONAL_SOURCE, "value", number("FLOAT", min=0.0)))
    )

    fractional = binding(declared, ("3", "value"))
    whole = binding(declared, ("4", "value"))

    assert fractional is not whole
    assert fractional.type == "float"
    assert bounds(fractional) == (0.0, None, None)
    assert whole.type == "integer"
    assert bounds(whole) == (None, None, None)


# ==========================================================================
# Ids: what may move, and what may not
# ==========================================================================


@pytest.mark.parametrize(
    "declaration",
    [
        pytest.param(number("FLOAT", min=0.0, max=100.0, step=0.1), id="the declared range"),
        pytest.param(number("FLOAT", min=0.0, max=50.0, step=0.5), id="a narrower one"),
        pytest.param(number("FLOAT"), id="a type with no range at all"),
        pytest.param(number("FLOAT", min=-1.0), id="a bound the value contradicts"),
    ],
)
def test_no_id_is_derived_from_what_the_runtime_declared(declaration: Any) -> None:
    """Four declarations, four different sets of bounds, one set of ids.

    The declaration decides *whether two inputs are one control*, and that is
    all it decides.  Nothing about the numbers in it reaches the role or the
    fingerprint, so a ComfyUI upgrade that widens a range renames nothing a
    user's defaults, drafts and saved setups hang off.
    """

    plan = analyse(
        graph(),
        contract=contract(
            (FRACTIONAL_SOURCE, "value", declaration),
            (WHOLE_SOURCE, "value", number("INT", min=1, max=200)),
            (ADAPTER, "strength_model", number("FLOAT", min=0.0, max=10.0, step=0.01)),
            (ADAPTER, "strength_clip", number("FLOAT", min=0.0, max=10.0, step=0.01)),
        ),
    )

    assert ids(plan) == (
        "prompt",
        "seed",
        "strength_clip",
        "strength_model",
        WHOLE_FIELD,
        CONTROL_FIELD,
        FRACTIONAL_FIELD,
    )


def test_the_id_that_moves_is_the_one_that_stood_for_two_controls() -> None:
    """Every id this fix moves, enumerated, in the one place it happens.

    The ids of everything that was never in doubt are untouched -- the prompt,
    the seed, the two strengths and ``value-ad814b5c``, the number beside them
    that always was its own control.  Exactly one id goes and exactly two
    appear, and they are the same field: the one that stood for two controls
    stops existing, and the two real ones arrive in its place.

    **The id that goes used to stay, and why it no longer does (T-0113).**
    While a collapsed field took its fingerprint from whichever member sorted
    first, the merged field's id *was* one of the two members' ids -- node 3's,
    because node 3 sorted first -- so the split looked as though it kept an id
    and added one.  That was an accident of the numbering: renumber this graph
    and the merged field would have carried node 4's id instead, and the same
    saved settings would have followed the other half.  A collapsed field's id
    is now minted from all of its members at once, so it is nobody's single
    fingerprint, and when the group splits it is no id at all.  Which is the
    honest answer: the control it named is the one this card exists to say
    should never have existed, and half of a user's saved value silently
    landing on a guidance scale or a step count, decided by which hash sorted
    lower, is the kind of guess this module refuses everywhere else.
    """

    before = ids(analyse(graph()))
    after = ids(analyse(graph(), contract=contract(*DECLARED)))

    assert before == (
        "prompt",
        "seed",
        "strength_clip",
        "strength_model",
        MERGED_FIELD,
        CONTROL_FIELD,
    )
    assert set(before) - set(after) == {MERGED_FIELD}, "the merged id is the one that goes"
    assert set(after) - set(before) == {
        WHOLE_FIELD,
        FRACTIONAL_FIELD,
    }, "one id per real control appears"
    assert binding(analyse(graph()), ("3", "value")).id == MERGED_FIELD
    assert binding(analyse(graph()), ("4", "value")).id == MERGED_FIELD
    assert binding(analyse(graph(), contract=contract(*DECLARED)), ("4", "value")).id == (
        WHOLE_FIELD
    )
    assert binding(analyse(graph(), contract=contract(*DECLARED)), ("3", "value")).id == (
        FRACTIONAL_FIELD
    )


# ==========================================================================
# No runtime, no change -- against bytes from before this card
# ==========================================================================

#: Exactly what this fixture generated before T-0097, captured by executing
#: `analysis.py` as it stands at the commit this branch started from (05b1c7c)
#: and rendering the definition from it.  Not a twin run of the code under
#: test: a differential between two runs of the same code proves only that it
#: agrees with itself.
#:
#: ``value-185940ea`` binding both node 3 and node 4 below is the defect
#: itself, preserved on purpose.  With no runtime there is no evidence, and an
#: importer that split them anyway would be guessing -- which is the whole
#: mistake this card is written against.
#:
#: Two things have changed since the capture, and they are the only two.  The
#: ``help`` lines arrived with T-0131.  And that one field's id was
#: ``value-ba91676e`` when this was taken: it is the only field here bound to
#: more than one node whose two nodes are wired into different places, so it is
#: the only one T-0113 moved when it stopped minting a collapsed field's id
#: from whichever member sorted first -- the same reason it also changed places
#: with the field below it, since a definition is written in id order.  Every
#: other id, every bound and every ``bind`` are still the bytes that shipped.
#: Note which fields have no ``help``.  ``prompt``'s graph input
#: is called ``text``, so its line comes from the second table (T-0131-02) --
#: the role the wiring proved -- while ``strength_clip`` and ``strength_model``
#: take theirs from the input name.  Neither ``value-`` field has a line at
#: all: nothing generic can be said about an input whose own graph called it
#: ``value``, and the vocabulary is silent rather than vacuous.
#:
#: Header lines 2 to 6 are T-0246's: they now say a definition is also
#: written again when the importer reads an unchanged workflow
#: differently.  The header is a comment, not part of what the importer
#: decides, and never reaches the fingerprint.
BEFORE_THIS_CARD = """\
# Generated by the LocalCanvas workflow sync from the workflow named below.
# Edit it freely -- it is yours. A later sync writes this file again when the
# workflow it came from has changed, or when this importer now reads that
# unchanged workflow differently. Either way it keeps the name, presentation,
# translation setting and every field label and help line you wrote, and
# generates everything else again from the workflow.
id: one
name: One
workflow: ../graphs/one.json
inputs:
- id: prompt
  label: Prompt
  type: multiline
  required: true
  section: main
  default: a quiet street at dawn
  help: Describe what you want to see. More detail gives more to go on.
  translatable: true
  bind:
  - node: '2'
    input: text
- id: seed
  label: Seed
  type: integer
  section: advanced
  default: 7
  help: The starting point for the randomness. The same number repeats a result.
  role: seed
  bind:
  - node: '9'
    input: seed
- id: strength_clip
  label: Strength clip
  type: integer
  section: advanced
  default: 1
  help: How strongly the add-on changes the way your words are read.
  bind:
  - node: '20'
    input: strength_clip
  - node: '21'
    input: strength_clip
- id: strength_model
  label: Strength model
  type: integer
  section: advanced
  default: 1
  help: How strongly the add-on changes the picture. Zero turns it off.
  bind:
  - node: '20'
    input: strength_model
  - node: '21'
    input: strength_model
- id: value-185940ea
  label: Value (on false)
  type: integer
  section: advanced
  default: 4
  bind:
  - node: '3'
    input: value
  - node: '4'
    input: value
- id: value-ad814b5c
  label: Value (batch size)
  type: integer
  section: advanced
  default: 50
  bind:
  - node: '7'
    input: value
"""


def rendered(plan: ImportPlan) -> str:
    return render_definition(
        definition_document(
            plan, workflow_id="one", name="One", workflow_relative="../graphs/one.json"
        )
    )


def test_with_no_runtime_at_all_the_definition_is_the_one_that_shipped() -> None:
    """The differential, against bytes and not against a description of them."""

    assert rendered(analyse(graph())) == BEFORE_THIS_CARD


@pytest.mark.parametrize(
    "silent",
    [
        pytest.param(lambda: None, id="no ComfyUI was talked to"),
        pytest.param(
            lambda: read_object_info({}, identity_digest="sha256:x"),
            id="a ComfyUI that declares nothing",
        ),
        pytest.param(
            lambda: contract(("ExampleOtherSource", "value", number("FLOAT"))),
            id="a class this graph does not contain",
        ),
        pytest.param(
            lambda: contract((FRACTIONAL_SOURCE, "amount", number("FLOAT"))),
            id="an input this class does not have",
        ),
        pytest.param(
            lambda: contract((FRACTIONAL_SOURCE, "value", ["STRING", {}])),
            id="an input declared as something else",
        ),
        pytest.param(
            lambda: contract((FRACTIONAL_SOURCE, "value", ["NUMBER", {}])),
            id="a type name this does not read",
        ),
        pytest.param(
            lambda: contract((SAMPLER, "sampler_name", [["a", "b"], {}])),
            id="a runtime with only choice lists to give",
        ),
    ],
)
def test_a_runtime_that_declares_no_number_leaves_the_run_exactly_as_it_was(
    silent,
) -> None:
    """Seven ways of not knowing, each identical to not asking at all.

    The whole plan is compared and not only the fields -- the sentences, the
    inventory, the locked entries and the ids -- and then the file that would
    be written is compared to the bytes above.  A declaration that reached the
    grouping key when it should not have been read at all fails here.
    """

    without = analyse(graph())
    quiet = analyse(graph(), contract=silent())

    assert quiet == without
    assert rendered(quiet) == BEFORE_THIS_CARD


def test_the_declaration_reaches_the_grouping_and_nothing_it_has_no_business_in() -> None:
    """Declaring every number changes the numbers and the grouping, and no more.

    What the importer locked, what it refused and what it recorded about every
    input it never exposed is identical with the runtime and without it.  The
    fields differ -- that is the card -- and everything else does not.
    """

    without = analyse(graph())
    declared = analyse(graph(), contract=contract(*DECLARED))

    assert declared.not_exposed == without.not_exposed
    assert declared.problems == without.problems == ()
    assert declared.refused_as_file_names == without.refused_as_file_names
    assert declared.frame_rate == without.frame_rate
    hidden = [item for item in declared.controls if item.hidden]
    assert hidden == [item for item in without.controls if item.hidden]
    assert ids(declared) != ids(without), "the fixture declared nothing"
