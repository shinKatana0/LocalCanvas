"""A number's type is what the node declares, and never what its value looks like.

An API-format export writes a ``FLOAT`` widget holding one whole unit as the
JSON number ``1``, and Python reads it back as an ``int``.  Judged from the
value alone -- which is all `semantics.py` can see -- a 0.0--1.0 strength
becomes a whole-number control that can be set to 0 or to 1 and to nothing
between them.  The field is there, the definition validates, the registry loads
it, and the control cannot hold the value the workflow needs.  Nothing anywhere
says so, which is why it took a real import to find it.

The properties held here, in the order they matter:

* **the declared type wins over the value.**  A ``FLOAT`` holding ``1``, ``4``
  or ``0`` is a float; an ``INT`` holding ``4`` or ``1`` is an integer.  Both
  halves, because a rule that only ever widened would break every genuine whole
  number in a catalogue;
* **no authority means no change.**  No ComfyUI, a class it does not have, an
  input it does not declare, a type name this does not read -- each leaves the
  run byte-identical to what it was, and that is checked against bytes captured
  from the code before this card, not against a description of them;
* **the type is never derived.**  Not from a decimal point, not from the input's
  name, not from what another workflow carries.  A runtime that declares
  nothing about ``denoise`` leaves ``denoise`` exactly as it was;
* **bounds ride along, and only where they are usable as they stand.**
  Incoherent, wrong-kinded, or contradicted by the value the graph already
  carries -- each is left out, one at a time, and never invented or clamped;
* **no id moves.**  Not on a type change, not on a bounds change, not on ``1``
  against ``1.0``.  Asserted verbatim, because those ids are the keys a user's
  defaults, drafts and saved setups hang off;
* **`semantics.py` is not widened.**  The authority is consulted in
  `analysis.py`, which holds the node's class; the contract is never asked
  about an input that was already locked, and the watcher proves it by never
  being asked while being asked about its neighbours.

Every node class and input value below is invented for this file.  The input
*names* are ComfyUI's ordinary vocabulary, which `semantics.py` already carries
and which this file is about (no model family, no custom node, no personal
workflow is named anywhere here).
"""

from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import pytest

from localcanvas_gateway.comfy.fake import FakeComfy
from localcanvas_gateway.workflows import load_registry
from localcanvas_gateway.workflows.sync import analyse, run_sync
from localcanvas_gateway.workflows.sync.analysis import ImportPlan
from localcanvas_gateway.workflows.sync.contract import (
    NumericDeclaration,
    RuntimeContract,
    declared_numeric,
    read_object_info,
)
from localcanvas_gateway.workflows.sync.definitions import (
    definition_document,
    render_definition,
)

from bridge_fixtures import Browser, make_bridge, ui_graph
from sync_fixtures import SyncWorkspace, write_json

# --------------------------------------------------------------------------
# One ordinary generation, and the ComfyUI that knows what its numbers are
# --------------------------------------------------------------------------

LOADER = "ExampleWeightsLoader"
ENCODER = "ExampleTextEncode"
SAMPLER = "ExampleSampler"
LATENT = "ExampleLatent"


def graph(
    *,
    denoise: Any = 1,
    cfg: Any = 4,
    steps: Any = 20,
    seed: Any = 7,
) -> Dict[str, Any]:
    """A graph whose numbers are all written as whole numbers.

    Which is the shape the defect lives in: ``denoise`` and ``cfg`` are
    fractional controls in ComfyUI, and a workflow saved at 1 and 4 carries
    them as JSON integers.
    """

    return {
        "1": {"class_type": LOADER, "inputs": {"ckpt_name": "chosen-weights.safetensors"}},
        "2": {
            "class_type": ENCODER,
            "inputs": {"text": "a quiet street at dawn", "clip": ["1", 1]},
        },
        "3": {
            "class_type": SAMPLER,
            "inputs": {
                "seed": seed,
                "steps": steps,
                "cfg": cfg,
                "denoise": denoise,
                "model": ["1", 0],
                "positive": ["2", 0],
            },
        },
        "4": {
            "class_type": LATENT,
            "inputs": {"width": 512, "height": 512, "samples": ["3", 0]},
        },
    }


def object_info(*declarations: Tuple[str, str, Any]) -> Dict[str, Any]:
    """``/object_info`` in ComfyUI's own shape, for the given declarations.

    Each declaration is ``(class type, input name, spec)``, and a spec is
    written exactly as ComfyUI writes one: ``["FLOAT", {"min": 0.0}]`` for an
    input declared as a fractional number, ``[[...], {}]`` for a finite list of
    choices.
    """

    document: Dict[str, Any] = {}
    for class_type, input_name, spec in declarations:
        entry = document.setdefault(
            class_type, {"input": {"required": {}}, "output": [], "name": class_type}
        )
        entry["input"]["required"][input_name] = spec
    return document


def contract(
    *declarations: Tuple[str, str, Any], digest: str = "sha256:runtime-a"
) -> RuntimeContract:
    """A contract read from an ``/object_info`` of that shape.

    Built through the production parser rather than by filling the tables by
    hand: a test that constructed them directly would still pass if the parser
    stopped recognising ComfyUI's shape.
    """

    return read_object_info(object_info(*declarations), identity_digest=digest)


def number(kind: str, **config: Any) -> List[Any]:
    """One ``/object_info`` spec declaring an input as a numeric type."""

    return [kind, dict(config)]


#: What a ComfyUI declares about the sampler and the latent above.  ``denoise``
#: and ``cfg`` are fractional, the rest are whole -- which is the point: the
#: same graph, the same values, and two different answers, decided by the node
#: and not by the number.
DECLARED: Tuple[Tuple[str, str, Any], ...] = (
    (SAMPLER, "seed", number("INT", min=0, max=1125899906842624)),
    (SAMPLER, "steps", number("INT", min=1, max=10000)),
    (SAMPLER, "cfg", number("FLOAT", min=0.0, max=100.0, step=0.1)),
    (SAMPLER, "denoise", number("FLOAT", min=0.0, max=1.0, step=0.01)),
    (LATENT, "width", number("INT", min=16, max=16384, step=8)),
    (LATENT, "height", number("INT", min=16, max=16384, step=8)),
)


def field_named(plan: ImportPlan, field_id: str):
    found = [item for item in plan.fields if item.id == field_id]
    assert found, "no field {!r}; there are {}".format(
        field_id, [item.id for item in plan.fields]
    )
    return found[0]


def typed(plan: ImportPlan) -> Dict[str, str]:
    return {item.id: item.type for item in plan.fields}


def bounds(item) -> Tuple[Any, Any, Any]:
    return (item.minimum, item.maximum, item.step)


# ==========================================================================
# What the contract reads out of one declaration
# ==========================================================================


def test_a_declared_numeric_type_is_read_with_the_range_beside_it() -> None:
    found = declared_numeric(number("FLOAT", min=0.0, max=1.0, step=0.01))

    assert found == NumericDeclaration(
        field_type="float", minimum=0.0, maximum=1.0, step=0.01
    )


def test_a_whole_number_input_is_read_as_the_schema_calls_one() -> None:
    """``INT`` is ComfyUI's word; ``integer`` is `docs/workflow-schema.md`'s."""

    found = declared_numeric(number("INT", min=1, max=10000))

    assert found == NumericDeclaration(
        field_type="integer", minimum=1, maximum=10000, step=None
    )


def test_a_type_declared_with_no_configuration_beside_it_still_declares_the_type() -> None:
    """The half that matters most, on its own.

    A node that writes a bare ``["FLOAT"]`` has said the thing this card is
    about.  Bounds are a nicety; the type is the difference between a control
    that can hold 0.5 and one that cannot.
    """

    assert declared_numeric(["FLOAT"]) == NumericDeclaration(field_type="float")
    assert declared_numeric(["FLOAT", None]) == NumericDeclaration(field_type="float")


@pytest.mark.parametrize(
    "spec",
    [
        pytest.param(["STRING", {"multiline": True}], id="a string input"),
        pytest.param(["BOOLEAN", {"default": True}], id="a flag"),
        pytest.param(["IMAGE"], id="a wire, not a widget"),
        pytest.param(["int", {}], id="a type name in the wrong case"),
        pytest.param(["NUMBER", {}], id="a numeric type this does not know"),
        pytest.param([["INT", "FLOAT"], {}], id="a list that happens to name types"),
        pytest.param([], id="nothing at all"),
        pytest.param("INT", id="a bare type name outside a list"),
        pytest.param({"type": "FLOAT"}, id="a shape this does not read"),
    ],
)
def test_anything_that_is_not_plainly_a_numeric_type_declares_nothing(
    spec: Any,
) -> None:
    """Not declared is not "declared something like it".

    A type name this module does not know is answered with ``None`` and never
    with a guess at which of the two it resembles: an input a future build
    calls ``NUMBER`` leaves the caller exactly where it was, which is the only
    answer that cannot be wrong.
    """

    assert declared_numeric(spec) is None


@pytest.mark.parametrize(
    "declared, expected",
    [
        pytest.param(True, None, id="a boolean is not the bound 1"),
        pytest.param(False, None, id="a boolean is not the bound 0"),
        pytest.param("10", None, id="a bound written as text"),
        pytest.param(None, None, id="a key present and empty"),
        pytest.param(float("nan"), None, id="not a number"),
        pytest.param(float("inf"), None, id="an infinity"),
        pytest.param(0, 0, id="zero is a bound like any other"),
    ],
)
def test_a_bound_that_is_not_a_finite_number_is_not_read(
    declared: Any, expected: Any
) -> None:
    """``True`` is an ``int`` in Python, and ``NaN`` compares false both ways.

    The last case is the one that keeps the others honest: a rule written as
    "anything falsy is absent" would drop a perfectly good ``min: 0``, which
    is the most common lower bound ComfyUI declares.
    """

    found = declared_numeric(number("FLOAT", min=declared))

    assert found is not None
    assert found.minimum == expected
    assert found.field_type == "float", "the type must survive an unusable bound"


def test_a_declared_number_and_a_declared_choice_list_are_kept_apart() -> None:
    """One input has one declaration, and the two tables never mix.

    Both halves asserted in both directions, so a lookup that answered from
    the wrong table would fail here rather than somewhere downstream where it
    would look like a different bug.
    """

    found = contract(
        (SAMPLER, "steps", number("INT", min=1)),
        (SAMPLER, "sampler_name", [["steady", "drifting"], {}]),
    )

    assert found.numeric_for(SAMPLER, "steps") == NumericDeclaration(
        field_type="integer", minimum=1
    )
    assert found.options_for(SAMPLER, "steps") is None
    assert found.options_for(SAMPLER, "sampler_name") == ("steady", "drifting")
    assert found.numeric_for(SAMPLER, "sampler_name") is None


def test_the_count_a_report_prints_still_counts_choice_lists_only() -> None:
    """``declared`` is a number a curator reads, and it means what it meant.

    A run whose ComfyUI declares numeric types for twenty inputs and a choice
    list for none has declared no choice lists, and a report that suddenly said
    ``20`` would be answering a different question under the old sentence.
    """

    numbers_only = contract(*DECLARED)
    with_a_list = contract(*DECLARED, (SAMPLER, "sampler_name", [["a", "b"], {}]))

    assert numbers_only.declared == 0
    assert with_a_list.declared == 1


def test_an_input_declared_in_both_sections_is_read_from_the_required_one() -> None:
    """One rule over both tables, so the two cannot come to disagree.

    A build that declares one input twice is malformed either way; what must
    not happen is that the declaration this module recognises depends on which
    table happened to look first.
    """

    document = {
        SAMPLER: {
            "input": {
                "required": {"cfg": number("FLOAT", min=0.0)},
                "optional": {"cfg": [["a", "b"], {}]},
            }
        }
    }

    found = read_object_info(document, identity_digest="sha256:x")

    assert found.numeric_for(SAMPLER, "cfg") == NumericDeclaration(
        field_type="float", minimum=0.0
    )
    assert found.options_for(SAMPLER, "cfg") is None


def test_a_numeric_type_declared_in_the_optional_section_is_read_too() -> None:
    document = {SAMPLER: {"input": {"optional": {"denoise": number("FLOAT")}}}}

    found = read_object_info(document, identity_digest="sha256:x")

    assert found.numeric_for(SAMPLER, "denoise") == NumericDeclaration(
        field_type="float"
    )


def test_an_unreadable_object_info_declares_no_numbers_either() -> None:
    for document in (None, [], "", {"A": "not a class"}, {"A": {"input": []}}):
        found = read_object_info(document, identity_digest="sha256:x")
        assert found.numeric_for(SAMPLER, "denoise") is None


# ==========================================================================
# The defect, and both directions of the rule that fixes it
# ==========================================================================


def test_a_float_input_holding_a_whole_number_is_a_float_control() -> None:
    """The card, in one assertion.

    ``denoise`` is a 0.0--1.0 strength and every graph in the world carries it
    as ``1``.  Read from the value it is a whole number and the user is offered
    0 or 1; read from the declaration it is what it has always been.
    """

    plan = analyse(graph(), contract=contract(*DECLARED))

    assert plan.problems == ()
    assert field_named(plan, "denoise").type == "float"
    assert field_named(plan, "denoise").default == 1, (
        "the value is the graph's and is not rewritten by naming its type"
    )


@pytest.mark.parametrize("value", [1, 4, 0])
def test_a_float_input_stays_a_float_at_every_whole_value(value: int) -> None:
    """``1``, ``4`` and ``0``: the three whole numbers the catalogue is full of.

    ``0`` is the one a rule written around truthiness would get wrong, and
    ``4`` is what ``cfg`` carries in the workflows that produced this card.
    """

    plan = analyse(graph(denoise=value), contract=contract(*DECLARED))

    item = field_named(plan, "denoise")
    assert item.type == "float"
    assert item.default == value


@pytest.mark.parametrize("value", [4, 1])
def test_an_integer_input_stays_an_integer(value: int) -> None:
    """The other direction, and the one a "play safe, make it a float" rule loses.

    ``steps`` is a count.  A float control for it would be wrong in exactly the
    way this card is about, pointing the other way.
    """

    plan = analyse(graph(steps=value), contract=contract(*DECLARED))

    item = field_named(plan, "steps")
    assert item.type == "integer"
    assert item.default == value


def test_a_float_input_holding_a_fraction_is_unaffected() -> None:
    """The declaration agrees with the value, and nothing moves.

    Worth its own test because it is the case a reader assumes is the same one:
    it is not, and a rule that only ever fired when the two disagreed would
    pass every other test in this file.
    """

    plan = analyse(graph(cfg=5.5), contract=contract(*DECLARED))

    item = field_named(plan, "cfg")
    assert (item.type, item.default) == ("float", 5.5)


def test_the_same_input_is_the_same_type_whatever_the_graph_was_saved_with() -> None:
    """The catalogue-level symptom, in one comparison.

    The two workflows that produced this card differ only in the number saved
    into ``cfg``, and they imported as two different control types.  Here they
    are the same type, and the two values really are different -- asserted, so
    this cannot pass on a fixture that saved the same number twice.
    """

    saved_whole = analyse(graph(cfg=4), contract=contract(*DECLARED))
    saved_fractional = analyse(graph(cfg=5.5), contract=contract(*DECLARED))

    assert field_named(saved_whole, "cfg").default == 4
    assert field_named(saved_fractional, "cfg").default == 5.5
    assert field_named(saved_whole, "cfg").type == "float"
    assert field_named(saved_fractional, "cfg").type == "float"


def test_a_declaration_for_another_class_or_another_input_is_not_used() -> None:
    """The two near misses, each against the run that proves it could have worked.

    Without the first half these would be absence tests that never showed the
    declaration was capable of reaching the field at all.
    """

    right = analyse(graph(), contract=contract((SAMPLER, "denoise", number("FLOAT"))))
    wrong_class = analyse(
        graph(), contract=contract(("ExampleOtherSampler", "denoise", number("FLOAT")))
    )
    wrong_input = analyse(
        graph(), contract=contract((SAMPLER, "denoize", number("FLOAT")))
    )

    assert field_named(right, "denoise").type == "float"
    assert field_named(wrong_class, "denoise").type == "integer"
    assert field_named(wrong_input, "denoise").type == "integer"


def test_a_number_is_never_made_fractional_by_the_way_it_is_written() -> None:
    """No decimal point, no input name, no neighbouring workflow.

    ``denoise`` is declared by nobody here, so the only evidence available is
    the evidence this card forbids: a name that reads like a strength, and a
    sibling input whose runtime *does* declare ``FLOAT``.  It stays an integer.
    """

    plan = analyse(graph(), contract=contract((SAMPLER, "cfg", number("FLOAT"))))

    assert field_named(plan, "cfg").type == "float", "the fixture declared nothing"
    assert field_named(plan, "denoise").type == "integer"
    assert field_named(plan, "steps").type == "integer"


# ==========================================================================
# No authority, no change -- against bytes from before this card
# ==========================================================================

#: Exactly what this graph generated before T-0098 existed, captured by running
#: the importer on the commit this branch started from.  Written out rather
#: than compared against a freshly generated twin: a differential between two
#: runs of the same code proves they agree with each other, and the claim is
#: that they agree with what shipped.  ``cfg: integer`` and ``denoise: integer``
#: below are the defect itself, preserved on purpose -- this is the behaviour a
#: run with no authoritative type must keep, exactly and to the byte.
#:
#: The ``help`` lines arrived with T-0131, which taught the importer to write
#: the one-line hint the schema always had a key for.  They are the only
#: addition since this text was captured: every type, every bound, every
#: ``default``, every ``bind`` and the order of all of them are still the bytes
#: that shipped, which is what these tests are about.  ``prompt``'s line comes
#: from the second table (T-0131-02) rather than the first: its graph input is
#: called ``text``, which no input-name table can answer, and the role the
#: wiring proved is what names it.
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
- id: cfg
  label: Cfg
  type: integer
  section: advanced
  default: 4
  help: How closely your words are followed. Too high looks harsh and overcooked.
  bind:
  - node: '3'
    input: cfg
- id: denoise
  label: Denoise
  type: integer
  section: advanced
  default: 1
  help: How much of the starting picture is redrawn. Lower keeps more of it.
  bind:
  - node: '3'
    input: denoise
- id: height
  label: Height
  type: integer
  section: advanced
  default: 512
  help: How tall the result is, in pixels. Bigger costs more time and memory.
  pair: height
  bind:
  - node: '4'
    input: height
- id: seed
  label: Seed
  type: integer
  section: advanced
  default: 7
  help: The starting point for the randomness. The same number repeats a result.
  role: seed
  bind:
  - node: '3'
    input: seed
- id: steps
  label: Steps
  type: integer
  section: advanced
  default: 20
  help: How much work goes into the result. More steps, more detail, more waiting.
  bind:
  - node: '3'
    input: steps
- id: width
  label: Width
  type: integer
  section: advanced
  default: 512
  help: How wide the result is, in pixels. Bigger costs more time and memory.
  pair: width
  bind:
  - node: '4'
    input: width
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
            lambda: contract(("ExampleOtherSampler", "denoise", number("FLOAT"))),
            id="a class this graph does not contain",
        ),
        pytest.param(
            lambda: contract((SAMPLER, "denoise", ["STRING", {}])),
            id="an input declared as something else",
        ),
        pytest.param(
            lambda: contract((SAMPLER, "denoise", ["NUMBER", {}])),
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
    """Five ways of not knowing, each identical to the sixth: not asking at all.

    The whole plan is compared, not the types -- the sentences, the control
    inventory, the locked entries and the ids -- and then the file that would
    be written is compared to the bytes above.  A change anywhere in the
    importer's answer fails this.
    """

    without = analyse(graph())
    quiet = analyse(graph(), contract=silent())

    assert quiet == without
    assert rendered(quiet) == BEFORE_THIS_CARD


def test_the_locked_and_reviewed_parts_of_a_run_are_untouched_by_the_authority() -> None:
    """Declaring every number changes the numbers and nothing else.

    The two plans differ in the fields' types and bounds; everything the
    importer says about what it locked, what it refused and what it recorded is
    identical, which is the claim "this card touches numbers only".
    """

    without = analyse(graph())
    declared = analyse(graph(), contract=contract(*DECLARED))

    assert declared.not_exposed == without.not_exposed
    assert declared.problems == without.problems == ()
    assert declared.refused_as_file_names == without.refused_as_file_names
    assert [(item.node, item.input, item.section, item.field, item.reason)
            for item in declared.controls] == [
        (item.node, item.input, item.section, item.field, item.reason)
        for item in without.controls
    ]
    assert typed(declared) != typed(without), "the fixture declared nothing"


# ==========================================================================
# The order: a locked input is never asked about
# ==========================================================================


class WatchingNumbers:
    """A contract that records every numeric question asked of it.

    "The runtime is never asked about an input that is already locked" is a
    claim about a call that does not happen, and holding the thing that would
    have been called is the only way to check it: the field's absence proves
    nothing, because it is absent in a run where the question was asked and
    answered too.
    """

    def __init__(self, inner: RuntimeContract) -> None:
        self._inner = inner
        self.asked: List[Tuple[str, str]] = []

    @property
    def identity_digest(self) -> str:
        return self._inner.identity_digest

    @property
    def declared(self) -> int:
        return self._inner.declared

    def options_for(self, class_type: str, input_name: str):
        return self._inner.options_for(class_type, input_name)

    def numeric_for(self, class_type: str, input_name: str):
        self.asked.append((class_type, input_name))
        return self._inner.numeric_for(class_type, input_name)

    def structural_for(self, class_type: str, input_name: str):
        # Not a numeric question, so not recorded.  Since T-0195 the node-shape
        # table is asked before ``classify`` for every literal input, so a
        # stand-in contract has to answer it; this one passes it through.
        return self._inner.structural_for(class_type, input_name)


def test_a_locked_number_is_never_asked_about_although_its_type_is_declared() -> None:
    """The ordering, on a **number** -- which is what makes it a new claim.

    ``port`` is locked by `semantics.py` whatever it holds, and this ComfyUI
    declares it a ``FLOAT`` outright.  A rule that asked the runtime before the
    locking judgement had answered would turn a machine setting into a control
    *because* its type is known, which is the mistake the ``select`` ordering
    was built to prevent, reached through the other door.

    The watcher is asked about the sampler in the very same run, so its silence
    about the locked input is evidence rather than an accident.
    """

    machine = {
        "1": {"class_type": SAMPLER, "inputs": {"denoise": 1, "port": 8188}},
    }
    watcher = WatchingNumbers(
        contract(
            (SAMPLER, "denoise", number("FLOAT")),
            (SAMPLER, "port", number("FLOAT")),
        )
    )

    plan = analyse(machine, contract=watcher)

    assert (SAMPLER, "denoise") in watcher.asked, "the watcher recorded nothing"
    assert (SAMPLER, "port") not in watcher.asked
    assert [item.id for item in plan.fields] == ["denoise"]
    assert [(item.input, item.exposure) for item in plan.not_exposed] == [
        ("port", "locked")
    ]


def test_a_string_is_not_asked_about_and_is_not_made_a_number() -> None:
    """No declaration turns one kind of value into another.

    A graph carrying the text ``"20"`` on an input this ComfyUI calls ``INT``
    is a graph saved against a different node; writing it out as an integer
    field defaulting to a string is a definition the loader refuses, and
    coercing the text to 20 is this importer changing what the workflow runs.
    Neither happens -- the input is not a number, so it is not this card's
    business at all, and the watcher shows it was never asked.
    """

    text = {
        "1": {
            "class_type": SAMPLER,
            "inputs": {"denoise": 1, "text": "a quiet street at dawn"},
        }
    }
    watcher = WatchingNumbers(
        contract(
            (SAMPLER, "denoise", number("FLOAT")),
            (SAMPLER, "text", number("INT")),
        )
    )

    plan = analyse(text, contract=watcher)

    assert (SAMPLER, "denoise") in watcher.asked, "the watcher recorded nothing"
    assert (SAMPLER, "text") not in watcher.asked
    assert field_named(plan, "prompt").type == "multiline"


def test_a_flag_is_not_asked_about_either() -> None:
    """``True`` is an ``int`` in Python, and must not become one here.

    A boolean read as a number would be sent back to ComfyUI as ``0``/``1`` and
    would be a different graph from the one the user saw -- the mistake
    `semantics.field_type_of` checks for first, and one this card must not
    reintroduce from the other end.
    """

    flagged = {
        "1": {"class_type": SAMPLER, "inputs": {"denoise": 1, "add_noise": True}},
    }
    watcher = WatchingNumbers(
        contract(
            (SAMPLER, "denoise", number("FLOAT")),
            (SAMPLER, "add_noise", number("INT")),
        )
    )

    plan = analyse(flagged, contract=watcher)

    assert (SAMPLER, "denoise") in watcher.asked, "the watcher recorded nothing"
    assert (SAMPLER, "add_noise") not in watcher.asked
    assert field_named(plan, "add_noise").type == "boolean"


# ==========================================================================
# Bounds: carried where they are usable, left out where they are not
# ==========================================================================


def test_the_declared_range_reaches_the_field() -> None:
    plan = analyse(graph(), contract=contract(*DECLARED))

    assert bounds(field_named(plan, "denoise")) == (0.0, 1.0, 0.01)
    assert bounds(field_named(plan, "steps")) == (1, 10000, None)
    assert bounds(field_named(plan, "width")) == (16, 16384, 8)


def test_a_runtime_that_declares_no_range_produces_no_range() -> None:
    """The type without the bounds, which is the common shape of a custom node.

    The mutation this kills is a bound filled in from anywhere at all -- a
    default, the value in the graph, the other end of the same declaration.
    """

    plan = analyse(
        graph(),
        contract=contract(
            (SAMPLER, "denoise", number("FLOAT")),
            (SAMPLER, "steps", ["INT"]),
        ),
    )

    assert field_named(plan, "denoise").type == "float", "nothing was declared at all"
    assert bounds(field_named(plan, "denoise")) == (None, None, None)
    assert bounds(field_named(plan, "steps")) == (None, None, None)


def test_no_contract_means_no_bounds_on_any_field() -> None:
    """The other absence, and the one the whole catalogue was in until now."""

    plan = analyse(graph())

    assert [bounds(item) for item in plan.fields] == [
        (None, None, None) for _ in plan.fields
    ]


@pytest.mark.parametrize("value", [90, 1])
def test_a_minimum_above_the_maximum_takes_both_bounds_out(value: int) -> None:
    """The schema's coherence rule, and its loader refuses the definition.

    Left out, not repaired: swapping them or keeping the one that looks
    plausible would be this importer inventing the range, and the run would
    then offer a user a limit no node ever declared.

    The two values are what makes this a test of the coherence rule rather
    than of the rule below it.  No value can satisfy ``min: 50, max: 4``, so
    with the coherence rule deleted the value-contradiction rule still drops
    one of the two -- and leaves **the other standing**: 90 keeps the minimum,
    1 keeps the maximum, and either is half a range nobody declared.  A single
    fixture here would have passed on a build with no coherence rule at all,
    which is the shape of finding this project keeps producing.
    """

    plan = analyse(
        graph(steps=value),
        contract=contract((SAMPLER, "steps", number("INT", min=50, max=4))),
    )

    assert field_named(plan, "steps").type == "integer", "the declaration was not read"
    assert bounds(field_named(plan, "steps")) == (None, None, None)


@pytest.mark.parametrize("declared_step", [0, -1, -0.5])
def test_a_step_of_zero_or_less_is_left_out(declared_step: Any) -> None:
    """``step`` greater than zero is the schema's rule; the rest is unaffected.

    A separate assertion from the one above, because these are two coherence
    rules and one of them can be deleted while the other still passes.
    """

    plan = analyse(
        graph(),
        contract=contract(
            (SAMPLER, "cfg", number("FLOAT", min=0.0, max=100.0, step=declared_step))
        ),
    )

    assert bounds(field_named(plan, "cfg")) == (0.0, 100.0, None)


def test_a_fractional_bound_on_a_whole_field_is_left_out_and_not_rounded() -> None:
    """`docs/workflow-schema.md` wants whole bounds on a whole field.

    Its loader refuses the definition otherwise, which would cost the workflow
    its **import** and not merely its slider.  Rounding instead would invent a
    limit nobody declared, in whichever direction the rounding went -- so the
    unusable bound is dropped and the usable one beside it is kept, which is
    also what shows the two are decided one at a time.
    """

    plan = analyse(
        graph(),
        contract=contract((SAMPLER, "steps", number("INT", min=1, max=200.5, step=1))),
    )

    assert field_named(plan, "steps").type == "integer"
    assert bounds(field_named(plan, "steps")) == (1, None, 1)


def test_a_whole_bound_on_a_fractional_field_is_kept() -> None:
    """The mirror of the rule above, which the schema allows and the loader takes.

    ``min: 0`` on a ``FLOAT`` is what ComfyUI declares for most of them, and
    refusing it would throw away nearly every range this card can carry.
    """

    plan = analyse(
        graph(), contract=contract((SAMPLER, "cfg", number("FLOAT", min=0, max=100)))
    )

    assert bounds(field_named(plan, "cfg")) == (0, 100, None)


def test_a_bound_the_graphs_own_value_contradicts_is_left_out() -> None:
    """A workflow saved outside the range its ComfyUI now declares.

    A node was updated, or the number was typed past the widget.  Both ways of
    making it fit -- moving the user's value, or moving the bound -- are this
    importer deciding what the workflow generates, so it does neither: the
    contradicted bound is left out and the value is written exactly as the
    graph has it.  If it were written anyway the real loader would refuse the
    definition, and the workflow would lose its import over a slider.
    """

    below = analyse(
        graph(steps=1), contract=contract((SAMPLER, "steps", number("INT", min=4, max=50)))
    )
    above = analyse(
        graph(steps=90), contract=contract((SAMPLER, "steps", number("INT", min=4, max=50)))
    )

    assert bounds(field_named(below, "steps")) == (None, 50, None)
    assert field_named(below, "steps").default == 1
    assert bounds(field_named(above, "steps")) == (4, None, None)
    assert field_named(above, "steps").default == 90


def test_the_value_at_the_edge_of_the_declared_range_keeps_its_bounds() -> None:
    """The boundary itself, which "outside" must not quietly include.

    ``denoise`` at exactly 1 with a declared maximum of 1.0 is the single most
    common shape in a real catalogue; an off-by-one comparison here would drop
    the range on almost every workflow and nothing else would notice.
    """

    plan = analyse(graph(denoise=1), contract=contract(*DECLARED))

    assert bounds(field_named(plan, "denoise")) == (0.0, 1.0, 0.01)


# ==========================================================================
# One control, several inputs: what the declaration decides
#
# T-0097 moved the answer in this section, and moved it deliberately.  When
# this card shipped, a group was formed on the role and the value alone and the
# declaration was consulted afterwards, so two inputs the runtime described
# differently met inside one field, disagreed, and left it with the type its
# value looked like and no bounds at all -- which is this card's own defect,
# arriving through the grouping door.  The declared **kind of number** is now
# part of the grouping key (`analysis._declaration_key`), so an input a runtime
# calls whole and an input it calls fractional are two fields, each carrying
# what its own node's runtime declared.
#
# Two things are NOT in that key and separate nothing.  The **range**: two
# nodes behind one control keep the range they both allow, resolved over every
# member by `analysis._resolved_declaration`, so the last test in this section
# says the opposite of what it said when this card shipped -- and says it for
# the reason this card was written, since a value only one of the two nodes
# accepts is what must not reach a form.  And **silence**: an input one class
# declares and another does not is still one control, because what the key
# carries is the kind of number the field will really be, and an undeclared
# input is the kind of number its value is written as.  So the test above about
# one declared input and one undeclared one turns on the FLOAT it declares over
# a whole number, not on the other one's silence.
# `test_sync_collapse_evidence.py` is the file about all of it.
# ==========================================================================


def two_nodes(value: Any = 4) -> Dict[str, Any]:
    """Two classes, one input name, one value.

    One collapsed control unless the runtime says otherwise: the same role and
    the same value is the importer's own evidence of sameness, and a runtime
    that describes the two inputs differently is evidence against it.
    """

    return {
        "1": {"class_type": SAMPLER, "inputs": {"cfg": value}},
        "2": {"class_type": "ExampleOtherSampler", "inputs": {"cfg": value, "samples": ["1", 0]}},
    }


def test_two_inputs_whose_runtimes_disagree_about_the_type_are_two_controls() -> None:
    """Two descriptions are two controls, and neither takes the other's type.

    The alternative this replaced was one field with both bindings, typed from
    the value: a declared ``FLOAT`` reaching the user as a whole-number control
    that cannot hold 4.5, and writing into the ``INT`` node as well.  Taking
    either member's word for the pair would have been worse still -- the type
    would depend on which node id sorted first, which is not evidence about
    anything.  Each input keeps its own runtime's word, and the ids say the
    role stopped being unique.
    """

    plan = analyse(
        two_nodes(),
        contract=contract(
            (SAMPLER, "cfg", number("FLOAT")),
            ("ExampleOtherSampler", "cfg", number("INT")),
        ),
    )

    fractional = field_named(plan, "cfg-9e3f720b")
    whole = field_named(plan, "cfg-42f59c21")
    assert fractional.type == "float"
    assert fractional.targets == (("1", "cfg"),)
    assert whole.type == "integer"
    assert whole.targets == (("2", "cfg"),)
    assert not [item for item in plan.fields if item.id == "cfg"]


def test_a_float_declared_over_one_of_two_whole_numbers_is_two_controls() -> None:
    """The hazard, and not the generality it was once taken to justify.

    What separates these two is **not** that one runtime spoke and the other
    did not.  It is what the one that spoke said: ``FLOAT`` over a value the
    graph writes as ``4`` turns that input into a control that can hold 4.5,
    and merged with an input nothing has vouched for, a user could write 4.5
    into a node no runtime called fractional.  A declaration is about one
    ``(class, input)`` and says nothing about the next one, so the declared one
    is a float and the undeclared one is left exactly as a run with no runtime
    at all would leave it.

    Silence on its own does **not** split a control -- a declaration that only
    confirms what the value already says does not either, and that correction
    is the subject of ``test_sync_collapse_evidence.py``'s own section on it.
    Both of those cases would keep the bare id ``cfg``; this one cannot,
    because the two inputs really are two kinds of control.
    """

    plan = analyse(
        two_nodes(), contract=contract((SAMPLER, "cfg", number("FLOAT")))
    )

    assert field_named(plan, "cfg-9e3f720b").type == "float"
    assert field_named(plan, "cfg-42f59c21").type == "integer"
    assert not [item for item in plan.fields if item.id == "cfg"]
    assert [item.type for item in analyse(two_nodes()).fields] == ["integer"], (
        "with no runtime at all this is one whole-number control, which is what "
        "the declared side has to be worth splitting away from"
    )


def test_two_inputs_that_agree_about_the_type_get_it() -> None:
    """The half that keeps the two tests above honest.

    Without it they would pass against an implementation that never applied the
    declaration to a collapsed field at all.
    """

    plan = analyse(
        two_nodes(),
        contract=contract(
            (SAMPLER, "cfg", number("FLOAT", min=0.0, max=100.0)),
            ("ExampleOtherSampler", "cfg", number("FLOAT", min=0.0, max=100.0)),
        ),
    )

    item = field_named(plan, "cfg")
    assert item.type == "float"
    assert bounds(item) == (0.0, 100.0, None)
    assert item.targets == (("1", "cfg"), ("2", "cfg"))


def test_two_inputs_that_agree_about_the_type_and_not_the_range_share_the_narrower() -> None:
    """One control, and the range both of its nodes accept.

    Both runtimes call it a float, so it is one control -- how far each node's
    input goes says nothing about whether a user is setting one thing or two,
    and splitting on it would move an id for no reason a user could see.  What
    it does decide is the range: a value only one of the two nodes accepts
    would fail at ComfyUI from a form that looked right, so the field carries
    the intersection.  Carrying no range at all, which is what this did before,
    left that same value reachable and only took the slider away.
    """

    plan = analyse(
        two_nodes(),
        contract=contract(
            (SAMPLER, "cfg", number("FLOAT", min=0.0, max=100.0)),
            ("ExampleOtherSampler", "cfg", number("FLOAT", min=0.0, max=30.0)),
        ),
    )

    item = field_named(plan, "cfg")
    assert item.type == "float"
    assert bounds(item) == (0.0, 30.0, None)
    assert item.targets == (("1", "cfg"), ("2", "cfg"))


# ==========================================================================
# Identity: nothing about a number may move an id
# ==========================================================================

#: The ids this graph produces.  Written out rather than derived, because "the
#: ids did not move" is only worth anything against ids somebody wrote down.
EXPECTED_IDS = ["prompt", "cfg", "denoise", "height", "seed", "steps", "width"]


def test_the_field_ids_do_not_move_when_the_declared_type_changes() -> None:
    """The property Phase 3 rests on: My defaults, drafts, saved setups.

    The types really do change -- asserted, so this cannot pass on a run where
    the authority did nothing.
    """

    before = analyse(graph())
    after = analyse(graph(), contract=contract(*DECLARED))

    assert [item.id for item in before.fields] == EXPECTED_IDS
    assert [item.id for item in after.fields] == EXPECTED_IDS
    assert typed(before)["denoise"] == "integer"
    assert typed(after)["denoise"] == "float"


def test_the_field_ids_do_not_move_when_the_declared_range_changes() -> None:
    """A ComfyUI upgrade widens a range; a user's saved settings must not move."""

    narrow = analyse(
        graph(), contract=contract((SAMPLER, "steps", number("INT", min=1, max=50)))
    )
    wide = analyse(
        graph(), contract=contract((SAMPLER, "steps", number("INT", min=1, max=10000)))
    )

    assert [item.id for item in narrow.fields] == EXPECTED_IDS
    assert [item.id for item in wide.fields] == EXPECTED_IDS
    assert bounds(field_named(narrow, "steps")) != bounds(field_named(wide, "steps")), (
        "the range under test did not actually change"
    )


def test_the_field_ids_do_not_move_when_a_value_is_written_1_point_0() -> None:
    """The same number, saved by two versions of the same editor.

    ``1`` and ``1.0`` are one value written two ways, and a re-export that
    changes only that must not rename the control a user's defaults hang off.
    All four combinations, because the id must be the same one whether or not
    a runtime was there to be asked.
    """

    whole = analyse(graph(denoise=1))
    fractional = analyse(graph(denoise=1.0))
    whole_declared = analyse(graph(denoise=1), contract=contract(*DECLARED))
    fractional_declared = analyse(graph(denoise=1.0), contract=contract(*DECLARED))

    for plan in (whole, fractional, whole_declared, fractional_declared):
        assert [item.id for item in plan.fields] == EXPECTED_IDS

    assert field_named(whole, "denoise").default == 1
    assert field_named(fractional, "denoise").default == 1.0
    assert isinstance(field_named(fractional, "denoise").default, float), (
        "the two fixtures carry the same Python value, so nothing was compared"
    )
    assert field_named(whole_declared, "denoise").type == "float"
    assert field_named(fractional_declared, "denoise").type == "float"


def two_stages() -> Dict[str, Any]:
    """Two sampler stages, each with a ``denoise`` of its own.

    Two same-role inputs holding different values are two controls, so neither
    id can be the bare role: each is salted with the structural fingerprint of
    what its node is wired into and out of.  That is the **second route** an id
    can be reached by, and it is a route the graphs above never take -- every
    role in them is unique, so their ids are bare roles and a fingerprint that
    moved would not show.
    """

    return {
        "1": {"class_type": LOADER, "inputs": {"ckpt_name": "chosen-weights.safetensors"}},
        "2": {
            "class_type": ENCODER,
            "inputs": {"text": "a quiet street at dawn", "clip": ["1", 1]},
        },
        "3": {
            "class_type": SAMPLER,
            "inputs": {"denoise": 1, "model": ["1", 0], "positive": ["2", 0]},
        },
        "4": {"class_type": SAMPLER, "inputs": {"denoise": 0, "samples": ["3", 0]}},
    }


#: The ids of that graph, written out.  A fingerprint is eight hexadecimal
#: characters and means nothing to read, which is exactly why it is written
#: here: these strings are what a user's My defaults, drafts and saved setups
#: are keyed on, and a test that recomputed them would agree with any answer.
FINGERPRINTED_IDS = ["prompt", "denoise-c9ef5608", "denoise-ede69492"]


def test_a_fingerprinted_id_does_not_move_when_the_declared_type_changes() -> None:
    """The route the bare-role tests cannot cover.

    An id salted with the structural fingerprint is minted from class types and
    input names.  Let the declared type into that digest -- directly, or by
    splitting a group so that a field which had a bare role suddenly needs one
    -- and every saved setting in the catalogue is orphaned by a ComfyUI that
    started declaring its types.
    """

    before = analyse(two_stages())
    after = analyse(two_stages(), contract=contract((SAMPLER, "denoise", number("FLOAT"))))

    assert [item.id for item in before.fields] == FINGERPRINTED_IDS
    assert [item.id for item in after.fields] == FINGERPRINTED_IDS
    assert [item.type for item in after.fields] == ["multiline", "float", "float"], (
        "the declaration changed nothing, so no id was tested against a change"
    )


def test_a_fingerprinted_id_does_not_move_when_the_declared_range_changes() -> None:
    """The same route, against the other half of what the runtime declares.

    Two runs of one graph against two ComfyUIs whose ranges differ.  The ids
    are identical and the ranges really are not -- asserted, because a bounds
    test that carried no bounds would pass on any implementation at all.
    """

    narrow = analyse(
        two_stages(),
        contract=contract((SAMPLER, "denoise", number("FLOAT", min=0.0, max=1.0))),
    )
    wide = analyse(
        two_stages(),
        contract=contract((SAMPLER, "denoise", number("FLOAT", min=0.0, max=10.0, step=0.5))),
    )

    assert [item.id for item in narrow.fields] == FINGERPRINTED_IDS
    assert [item.id for item in wide.fields] == FINGERPRINTED_IDS
    assert bounds(field_named(narrow, "denoise-c9ef5608")) == (0.0, 1.0, None)
    assert bounds(field_named(wide, "denoise-c9ef5608")) == (0.0, 10.0, 0.5)


def test_a_fingerprinted_id_does_not_move_when_a_value_is_written_1_point_0() -> None:
    """``1`` against ``1.0``, on the route where an id could actually move.

    The label a fingerprinted field carries is written from the wiring too, so
    it is asserted beside the id: a change there would be an id keeping its
    name while its meaning moved.
    """

    rewritten = two_stages()
    rewritten["3"]["inputs"]["denoise"] = 1.0

    whole = analyse(two_stages())
    fractional = analyse(rewritten)

    assert [item.id for item in whole.fields] == FINGERPRINTED_IDS
    assert [item.id for item in fractional.fields] == FINGERPRINTED_IDS
    assert [item.label for item in whole.fields] == [
        item.label for item in fractional.fields
    ]
    assert isinstance(field_named(fractional, "denoise-c9ef5608").default, float), (
        "both fixtures carry the same Python value, so nothing was compared"
    )


def test_a_declared_number_changes_no_bind_and_no_evidence() -> None:
    """The id is not the only thing that must stay put.

    What a field binds to, and the sentence that says why it exists, are both
    about the part the input plays; a declaration about its type is not
    evidence about either, and a change here would move an id's meaning while
    leaving the id alone.
    """

    before = analyse(graph())
    after = analyse(graph(), contract=contract(*DECLARED))

    assert [(item.id, item.targets, item.evidence, item.label, item.section)
            for item in after.fields] == [
        (item.id, item.targets, item.evidence, item.label, item.section)
        for item in before.fields
    ]


# ==========================================================================
# The presentation hints, which are about the type
# ==========================================================================


def test_the_seed_role_survives_a_declared_integer() -> None:
    """``role: seed`` is legal on an ``integer`` only, and seeds are integers."""

    plan = analyse(graph(), contract=contract(*DECLARED))

    item = field_named(plan, "seed")
    assert (item.type, item.role_hint) == ("integer", "seed")
    assert bounds(item) == (0, 1125899906842624, None)


def test_the_paired_dimensions_survive_a_declared_integer() -> None:
    plan = analyse(graph(), contract=contract(*DECLARED))

    assert [(item.id, item.pair) for item in plan.fields if item.pair] == [
        ("height", "height"),
        ("width", "width"),
    ]


def test_a_dimension_a_runtime_calls_fractional_carries_no_paired_hint() -> None:
    """The hints follow the type the field really has, not the one it had.

    ``pair`` is an ``integer``-only hint in `docs/workflow-schema.md`, and its
    loader refuses it elsewhere -- so a hint decided before the type was known
    would cost that workflow its import.  Nothing here judges whether the
    runtime was right to say so.
    """

    plan = analyse(
        graph(),
        contract=contract(
            (LATENT, "width", number("FLOAT")),
            (LATENT, "height", number("FLOAT")),
        ),
    )

    assert [(item.id, item.type, item.pair) for item in plan.fields if item.id in
            ("width", "height")] == [
        ("height", "float", None),
        ("width", "float", None),
    ]


def test_the_duration_hint_still_follows_a_declared_frame_count() -> None:
    """``duration`` is an ``integer``-only hint, and a frame count is whole.

    Both halves: the runtime calling the count an ``INT`` leaves the hint where
    it was, and the graph's declared rate is still the only thing that switches
    it on.
    """

    clip = {
        "1": {"class_type": SAMPLER, "inputs": {"length": 25, "fps": 24}},
    }

    without = analyse(clip)
    declared = analyse(
        clip,
        contract=contract((SAMPLER, "length", number("INT", min=25, max=121, step=4))),
    )

    assert field_named(without, "length").duration_fps == 24.0
    item = field_named(declared, "length")
    assert (item.type, item.duration_fps) == ("integer", 24.0)
    assert bounds(item) == (25, 121, 4)


# ==========================================================================
# What is written, and that the real loader accepts it
# ==========================================================================


def test_the_definition_writes_the_type_and_the_range_the_runtime_declared() -> None:
    """The whole field document, verbatim.

    ``default: 1`` on a ``float`` field is deliberate and is what the schema's
    loader accepts: the value is the graph's, and this card names its type
    without rewriting it.

    ``help`` is here because T-0131 writes one for every input name its
    vocabulary knows, and the whole document is asserted rather than the keys
    this card cares about -- so a key that appeared from anywhere fails here.
    """

    plan = analyse(graph(), contract=contract(*DECLARED))

    document = definition_document(
        plan, workflow_id="one", name="One", workflow_relative="../g.json"
    )
    written = [item for item in document["inputs"] if item["id"] == "denoise"]

    assert written == [
        {
            "id": "denoise",
            "label": "Denoise",
            "type": "float",
            "section": "advanced",
            "default": 1,
            "min": 0.0,
            "max": 1.0,
            "step": 0.01,
            "help": (
                "How much of the starting picture is redrawn."
                " Lower keeps more of it."
            ),
            "bind": [{"node": "3", "input": "denoise"}],
        }
    ]


def test_a_field_with_no_declared_range_writes_no_range_keys() -> None:
    """An omitted key, not a null one -- the loader refuses ``min: null``."""

    plan = analyse(graph(), contract=contract((SAMPLER, "denoise", number("FLOAT"))))

    document = definition_document(
        plan, workflow_id="one", name="One", workflow_relative="../g.json"
    )
    written = [item for item in document["inputs"] if item["id"] == "denoise"][0]

    assert written["type"] == "float", "the declaration was not read"
    assert set(written) & {"min", "max", "step"} == set()


def test_the_generated_definition_loads_through_the_real_registry_loader(
    tmp_path: Path,
) -> None:
    """The loader the gateway itself runs, not a second implementation of it.

    This is where a bound the schema cannot carry would show up: a fractional
    ``min`` on an integer field, a ``step`` of zero, a default outside its own
    range are each a *refused definition*, and a refused definition is a
    workflow that does not import.
    """

    plan = analyse(graph(), contract=contract(*DECLARED))
    document = definition_document(
        plan, workflow_id="one", name="One", workflow_relative="one.json"
    )
    (tmp_path / "one.yaml").write_text(render_definition(document), encoding="utf-8")
    (tmp_path / "one.json").write_text(json.dumps(graph()), encoding="utf-8")

    registry = load_registry(tmp_path)

    assert list(registry.diagnostics) == []
    found = {item.id: item for item in registry.workflows[0].inputs}
    assert found["denoise"].type.value == "float"
    assert (found["denoise"].min, found["denoise"].max, found["denoise"].step) == (
        0.0,
        1.0,
        0.01,
    )
    assert found["steps"].type.value == "integer"
    assert found["seed"].role is not None and found["seed"].role.value == "seed"


def test_a_float_field_that_holds_a_whole_number_can_hold_a_fraction(
    tmp_path: Path,
) -> None:
    """The user-facing question, answered through the gateway's own validator.

    "Can a ComfyUI FLOAT holding a whole number ever become an integer
    control?" is answered NO by asking the thing that would refuse 0.5 -- the
    same code path a submission takes -- rather than by reading the type off
    the field.
    """

    from localcanvas_gateway.errors import ValidationFailure
    from localcanvas_gateway.validation import validate_inputs

    plan = analyse(graph(), contract=contract(*DECLARED))
    document = definition_document(
        plan, workflow_id="one", name="One", workflow_relative="one.json"
    )
    (tmp_path / "one.yaml").write_text(render_definition(document), encoding="utf-8")
    (tmp_path / "one.json").write_text(json.dumps(graph()), encoding="utf-8")
    definition = load_registry(tmp_path).workflows[0]

    accepted = validate_inputs(definition, {"prompt": "a lane in the rain", "denoise": 0.5})
    assert accepted["denoise"] == 0.5

    with pytest.raises(ValidationFailure) as refused:
        validate_inputs(definition, {"prompt": "a lane in the rain", "steps": 0.5})
    assert refused.value.field == "steps", (
        "a whole-number field has to be the one that refuses it, or this test "
        "would pass on a workflow where every number was a float"
    )


# ==========================================================================
# The whole run, against a stand-in ComfyUI and a stand-in browser
# ==========================================================================


@pytest.fixture()
def workspace(tmp_path: Path) -> SyncWorkspace:
    return SyncWorkspace(tmp_path)


def run_against(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch, comfy: FakeComfy
):
    """One whole sync of one editor workflow, through the production path."""

    folder = workspace.add_source()
    write_json(folder / "a canvas.json", ui_graph("one"))
    workspace.write_config()
    browser = Browser(tmp_path, monkeypatch, default={"ok": True, "output": graph()})
    with make_bridge(comfy.base_url, browser) as bridge:
        return run_sync(workspace.load(), bridge=bridge)


def test_a_converted_workflow_imports_with_the_numeric_types_its_comfyui_declares(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """End to end, and through the loader the gateway itself runs.

    The same canvas against a ComfyUI that declares nothing imports ``denoise``
    as an integer: that is the measured difference this card exists to make,
    and both halves are run here rather than described.
    """

    with FakeComfy() as declaring:
        declaring.installed_nodes = (SAMPLER, LATENT)
        declaring.node_inputs = {
            SAMPLER: {
                "seed": number("INT", min=0, max=1125899906842624),
                "steps": number("INT", min=1, max=10000),
                "cfg": number("FLOAT", min=0.0, max=100.0, step=0.1),
                "denoise": number("FLOAT", min=0.0, max=1.0, step=0.01),
            },
            LATENT: {
                "width": number("INT", min=16, max=16384, step=8),
                "height": number("INT", min=16, max=16384, step=8),
            },
        }
        report = run_against(workspace, tmp_path, monkeypatch, declaring)

    item = report.workflows[0]
    assert item.state.value == "NEW", item.reason
    registry = load_registry(workspace.repo / "config" / "local" / "workflows")
    assert list(registry.diagnostics) == []
    found = {entry.id: entry for entry in registry.workflows[0].inputs}
    assert found["denoise"].type.value == "float"
    assert (found["denoise"].min, found["denoise"].max, found["denoise"].step) == (
        0.0,
        1.0,
        0.01,
    )
    assert found["cfg"].type.value == "float"
    assert found["steps"].type.value == "integer"
    assert (found["width"].min, found["width"].max, found["width"].step) == (
        16,
        16384,
        8,
    )


def test_the_same_canvas_gets_an_integer_denoise_when_its_comfyui_says_nothing(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The other side of the measurement, and the proof it was the declaration.

    Everything is the same but the ``/object_info`` answer, so what changed the
    outcome cannot be anything else -- and the workflow still imports, with the
    behaviour that shipped.
    """

    with FakeComfy() as quiet:
        report = run_against(workspace, tmp_path, monkeypatch, quiet)

    assert report.workflows[0].state.value == "NEW"
    registry = load_registry(workspace.repo / "config" / "local" / "workflows")
    found = {entry.id: entry for entry in registry.workflows[0].inputs}
    assert found["denoise"].type.value == "integer"
    assert (found["denoise"].min, found["denoise"].max) == (None, None)


def test_reading_the_numeric_types_costs_no_request_of_its_own(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The declaration comes out of the answer the identity probe already read.

    The recorder is the fake ComfyUI's own, and the same recorder is shown to
    catch traffic it should not see in
    ``test_sync_bridge.py::test_no_prompt_is_ever_queued_in_order_to_export``.
    """

    with FakeComfy() as declaring:
        declaring.installed_nodes = (SAMPLER,)
        declaring.node_inputs = {SAMPLER: {"denoise": number("FLOAT", min=0.0, max=1.0)}}
        report = run_against(workspace, tmp_path, monkeypatch, declaring)
        requests = sorted(set(declaring.requests))

    registry = load_registry(workspace.repo / "config" / "local" / "workflows")
    found = {entry.id: entry for entry in registry.workflows[0].inputs}
    assert found["denoise"].type.value == "float", (
        "the declaration was not used in this run, so it proves nothing about cost"
    )
    assert report.workflows[0].state.value == "NEW"
    assert requests == ["GET /object_info", "GET /system_stats"]


def test_the_bridge_hands_the_numeric_declarations_out_with_the_choices(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """One document, two tables, one identity -- and nothing read twice."""

    with FakeComfy() as declaring:
        declaring.installed_nodes = (SAMPLER,)
        declaring.node_inputs = {
            SAMPLER: {
                "denoise": number("FLOAT", min=0.0, max=1.0, step=0.01),
                "sampler_name": [["steady", "drifting"], {}],
            }
        }
        browser = Browser(
            tmp_path, monkeypatch, default={"ok": True, "output": graph()}
        )
        with make_bridge(declaring.base_url, browser) as bridge:
            assert bridge.runtime_contract() is None
            established = bridge.ensure_identity()
            found = bridge.runtime_contract()

            assert found is not None
            assert found.identity_digest == established.digest
            assert found.numeric_for(SAMPLER, "denoise") == NumericDeclaration(
                field_type="float", minimum=0.0, maximum=1.0, step=0.01
            )
            assert found.options_for(SAMPLER, "sampler_name") == ("steady", "drifting")
            assert found.numeric_for(SAMPLER, "nothing_declared") is None


def test_a_contract_from_another_installation_declares_no_numbers_here() -> None:
    """Provenance covers the numeric table too, by the one key it already had.

    What an input accepts is exactly what moves when a custom node is
    installed, updated or removed -- and so is whether it is whole.
    """

    from localcanvas_gateway.workflows.sync.contract import ContractCache

    cache = ContractCache()
    cache.store(contract(*DECLARED, digest="sha256:runtime-a"))

    assert cache.get("sha256:runtime-b") is None
    assert cache.get("sha256:runtime-a").numeric_for(SAMPLER, "denoise") is not None


def test_the_bound_reader_is_not_confused_by_a_json_documents_own_infinities() -> None:
    """Python's JSON reader accepts ``NaN`` and ``Infinity``, and ComfyUI is a program.

    Asserted through a real parse rather than by handing the value in, because
    "a document could carry this" is the claim, and a hand-built dictionary
    would not show that it can.
    """

    document = json.loads(
        '{"%s": {"input": {"required": {"cfg": ["FLOAT", {"min": NaN, "max": Infinity}]}}}}'
        % SAMPLER
    )
    assert math.isnan(document[SAMPLER]["input"]["required"]["cfg"][1]["min"])

    found = read_object_info(document, identity_digest="sha256:x")

    assert found.numeric_for(SAMPLER, "cfg") == NumericDeclaration(field_type="float")
