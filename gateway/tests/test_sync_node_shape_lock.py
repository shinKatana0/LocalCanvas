"""An option that is not a value but a node shape, and why it is not a control.

One type of declaration on a current ComfyUI does not offer values at all.
Each of its options is an object carrying its own ``required``/``optional``
inputs, so choosing ``h264`` *adds* an ``encoding`` input to the node and
choosing ``re-encode`` under that *adds* a ``crf`` float.  T-0180 refused the
type outright rather than guess what a user would be picking between; this is
the answer, and it is smaller than the shape suggests.

**The value such an input carries is not a setting somebody tuned. It is which
node this is.**  A workflow's author already chose one of those shapes and
saved the graph that way, so where the value is one the runtime declares, the
importer locks it at exactly that value: the workflow imports, it runs as
written, and nobody is handed a control whose meaning is "change which inputs
this node has".  Where the value is none of them, the workflow is held for
review exactly as before -- an honest unknown stays one.

The file is organised around the five ways of getting that wrong that the
design names, and each of them is asserted from both sides:

* **the shape the graph chose, never a default.**  The capture's first key is
  ``auto``; a graph that chose ``h264`` locks at ``h264``, and one that chose
  ``auto`` locks at ``auto``.  Both halves, so neither passes by accident of
  ordering.
* **nothing nested is read.**  The capture declares a ``crf`` FLOAT two levels
  down.  A graph carrying its own ``crf`` on that very class must be typed as
  if that declaration did not exist -- and the same test shows a genuine
  top-level FLOAT declaration *does* reach an identical input, so the absence
  is one that was available to be seen.
* **the key is never a select.**  An ordinary ``COMBO`` on the same node
  becomes a select in the same plan, so "no select appeared" is a measurement
  and not a silence.
* **an unrecognised value is refused, not locked.**
* **the type is still not a plain combo.**  T-0180's rule lives in
  ``test_sync_runtime_contract.py`` and is untouched; what is asserted here is
  that this card did not reach around it.

Every node class and input name below is invented.  The *specs* are verbatim
captures of what a runtime declares, tooltips shortened, because the two-level
nesting is the whole point of the fixture and an invented one would be a
fixture that confirms itself.  The one exception is named where it is: a single
option key carrying a slash, which is invented because every real one on the
measured runtime is a model identifier, and no model family may be named
here at all.
"""

from __future__ import annotations

import copy
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import pytest

from localcanvas_gateway.comfy.fake import FakeComfy
from localcanvas_gateway.workflows import load_registry
from localcanvas_gateway.workflows.sync import analyse, run_sync
from localcanvas_gateway.workflows.sync.analysis import ControlRecord, NotExposed
from localcanvas_gateway.workflows.sync.contract import (
    RuntimeContract,
    declared_options,
    declared_structural_keys,
    read_object_info,
)
from localcanvas_gateway.workflows.sync.definitions import definition_document
from localcanvas_gateway.workflows.sync.report import report_document
from localcanvas_gateway.workflows.sync.semantics import Exposure, classify

from bridge_fixtures import Browser, make_bridge, ui_graph
from sync_fixtures import SyncWorkspace, write_json

# --------------------------------------------------------------------------
# The shape, verbatim, and the names this file gives the things in it
# --------------------------------------------------------------------------

#: The slug the judgement carries.  Written out here rather than imported from
#: the module under test: a test that took the name from the code would still
#: pass if the code started grouping this with something else in a curator's
#: report, which is exactly the change a reader of that report would notice.
SHAPE_SLUG = "node_shape"

#: The slug T-0100's judgement carries, for the one test that shows which of
#: the two owns an input both could reach.
LOAD_SLUG = "load_setting"

#: The input T-0185 was about.  A short unremarkable word in no vocabulary of
#: `semantics.py`'s, which is what makes it ``UNCERTAIN`` on the graph's own
#: evidence.  Since T-0195 the node-shape declaration is asked before
#: ``classify`` for every input, so this is no longer the only situation it
#: reaches -- see the section at the end of this file for the inputs
#: ``classify`` settles by itself.
SHAPE_INPUT = "codec"

#: A node that saves something, so nothing about loading can be what decides.
VIDEO_SAVE = "ExampleVideoSave"

#: The same declaration on a node whose class type says its job is loading.
LOADING_SAVE = "ExampleVideoLoader"

#: The nested input names the capture carries, at one and two levels down.
#: Named here so every absence assertion below says which words it looked for.
NESTED_DYNAMIC = "encoding"
NESTED_FLOAT = "crf"


def captured_dynamic() -> List[Any]:
    """``SaveVideo.codec`` as a current ComfyUI declares it, whole.

    Two options; the first adds nothing to the node and the second adds an
    ``encoding`` input which is itself one of these, one of *whose* options
    adds a ``crf`` FLOAT.  That second level is the only depth-2 case on the
    runtime this was captured from, so it is the fixture that matters.

    Returned from a function rather than held as a constant, because several
    tests below hand it to a parser and one of them mutates a copy: a shared
    mutable capture is a fixture that could make the next test's assertion
    true by itself.
    """

    return [
        "COMFY_DYNAMICCOMBO_V3",
        {
            "tooltip": "The codec to use for the video.",
            "options": [
                {"key": "auto", "inputs": {"required": {}}},
                {
                    "key": "h264",
                    "inputs": {
                        "required": {},
                        "optional": {
                            NESTED_DYNAMIC: [
                                "COMFY_DYNAMICCOMBO_V3",
                                {
                                    "display_name": "encoding mode",
                                    "options": [
                                        {"key": "auto", "inputs": {"required": {}}},
                                        {
                                            "key": "re-encode",
                                            "inputs": {
                                                "required": {
                                                    NESTED_FLOAT: [
                                                        "FLOAT",
                                                        {
                                                            "default": 23.0,
                                                            "min": 0.0,
                                                            "max": 51.0,
                                                            "step": 1.0,
                                                        },
                                                    ]
                                                }
                                            },
                                        },
                                    ],
                                },
                            ]
                        },
                    },
                },
            ],
        },
    ]


#: The keys that capture declares, in declared order.  Written out rather than
#: read back out of the fixture: a test that derived them from the same object
#: it hands the parser would agree with itself whatever the parser did.
SHAPES: Tuple[str, ...] = ("auto", "h264")


def captured_ordinary_dynamic() -> List[Any]:
    """The representative case: shapes with sub-inputs, one level deep.

    The measured runtime's ordinary instance declares nine of these, and the
    first two keys here are its own, verbatim -- ordinary English with a space
    in it.  The third is **invented**, and deliberately: 34 real option keys on
    that runtime carry a slash and every one of them is a model identifier, so
    writing one down here would name a model family in this repository.
    What the test built on it is about is the
    *shape* of such a value -- words, a space, a separator in the middle -- and
    T-0095's rule, which is that a separator in the middle is not evidence that
    the value names a place on somebody's disk.
    """

    return [
        "COMFY_DYNAMICCOMBO_V3",
        {
            "tooltip": "Select how to resize.",
            "options": [
                {
                    "key": "scale dimensions",
                    "inputs": {
                        "required": {
                            "width": ["INT", {"default": 512, "min": 0, "max": 16384}]
                        }
                    },
                },
                {
                    "key": "scale by multiplier",
                    "inputs": {
                        "required": {
                            "multiplier": ["FLOAT", {"default": 2.0, "min": 0.01}]
                        }
                    },
                },
                {
                    "key": "pro mode / 5s duration",
                    "inputs": {"required": {}},
                },
            ],
        },
    ]


def captured_flat_dynamic() -> List[Any]:
    """The one input of the 133 whose options carry no sub-inputs at all.

    Verbatim, and here for one reason only: to show that **nothing special
    happens to it**.  One instance is not a pattern, so it goes through the
    same reader and the same judgement as the other 132 and comes out locked
    like them -- rather than being handed a select because its shapes happen to
    add nothing.
    """

    return [
        "COMFY_DYNAMICCOMBO_V3",
        {
            "options": [
                {"key": "disabled", "inputs": {"required": {}}},
                {"key": "enabled", "inputs": {"required": {}}},
            ]
        },
    ]


def object_info(*declarations: Tuple[str, str, Any]) -> Dict[str, Any]:
    """``/object_info`` in ComfyUI's own shape, for the given declarations."""

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

    Built through the production parser rather than by filling the table by
    hand, so a test cannot pass against a table ComfyUI's shape no longer
    produces.
    """

    return read_object_info(object_info(*declarations), identity_digest=digest)


def combo(*values: Any) -> List[Any]:
    """A plain enumeration, in the shape current ComfyUI writes it in."""

    return ["COMBO", {"multiselect": False, "options": list(values)}]


def graph_with(
    class_type: str, inputs: Dict[str, Any], *, extra: Optional[Dict[str, Any]] = None
) -> Dict[str, Any]:
    """One readable generation whose node ``1`` is of the given class.

    Node ``1`` carries the inputs under test; the rest is an ordinary graph
    that imports on its own, so "the workflow still imports" is something this
    fixture can show rather than something it makes trivially true.
    """

    graph: Dict[str, Any] = {
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
    if extra:
        graph.update(copy.deepcopy(extra))
    return graph


def control_for(plan, node: str, name: str):
    found = [item for item in plan.controls if item.target == (node, name)]
    assert found, "input {!r} of node {} is not in the inventory at all; it has {}".format(
        name, node, [item.target for item in plan.controls]
    )
    return found[0]


def field_binding(plan, node: str, name: str):
    """The field bound to that input, or ``None`` when nothing binds it."""

    for item in plan.fields:
        if (node, name) in item.targets:
            return item
    return None


# ==========================================================================
# What the runtime declaration is read as
# ==========================================================================


def test_the_capture_yields_its_keys_and_the_nested_block_is_left_where_it_is() -> None:
    """The reader takes the ``key`` of each option, in order, and nothing else.

    The second half is the one that matters and it is asserted against a
    fixture that really does carry something to leak: the capture is walked
    here, by hand and independently of the parser, to show that a ``crf``
    declaration is genuinely present two levels inside it.  Only then does
    "the keys are exactly these two" say anything.
    """

    spec = captured_dynamic()

    nested = spec[1]["options"][1]["inputs"]["optional"][NESTED_DYNAMIC]
    deeper = nested[1]["options"][1]["inputs"]["required"]
    assert deeper[NESTED_FLOAT][0] == "FLOAT"

    assert declared_structural_keys(spec) == SHAPES


def test_the_same_keys_would_be_read_as_choices_if_a_runtime_declared_them_so() -> None:
    """The refusal is about the declaration, not about the parser finding none.

    A parser that flattened this to a dropdown would return exactly the tuple
    on the first line, so the first line is what makes the third meaningful:
    ``declared_options`` can read those two values perfectly well and still
    answers ``None`` here, which is T-0180's rule standing after this card.
    """

    assert declared_options(combo(*SHAPES)) == SHAPES
    assert declared_options(captured_dynamic()) is None
    assert declared_structural_keys(combo(*SHAPES)) is None


def test_the_flat_case_goes_through_the_same_reader_as_the_other_hundred() -> None:
    """One instance is not a pattern, so it gets no rule of its own.

    The single declaration on the measured runtime whose options add no inputs
    is read exactly like the ones that do.  Its being flat is not a fact this
    module records anywhere, which is why nothing downstream can act on it.
    """

    assert declared_structural_keys(captured_flat_dynamic()) == ("disabled", "enabled")


REFUSED_SPECS = [
    pytest.param(["COMBO", {"options": [{"key": "auto"}]}], id="another-type-name"),
    pytest.param(["COMFY_DYNAMICCOMBO_V3"], id="nothing-beside-the-name"),
    pytest.param(["COMFY_DYNAMICCOMBO_V3", ["auto"]], id="not-a-mapping"),
    pytest.param(["COMFY_DYNAMICCOMBO_V3", {"tooltip": "x"}], id="no-options-at-all"),
    pytest.param(["COMFY_DYNAMICCOMBO_V3", {"options": []}], id="empty-options"),
    pytest.param(
        ["COMFY_DYNAMICCOMBO_V3", {"options": "auto"}], id="options-not-a-list"
    ),
    pytest.param(
        ["COMFY_DYNAMICCOMBO_V3", {"options": ["auto", "h264"]}], id="options-are-values"
    ),
    pytest.param(
        ["COMFY_DYNAMICCOMBO_V3", {"options": [{"key": "auto"}, {"inputs": {}}]}],
        id="an-option-with-no-key",
    ),
    pytest.param(
        ["COMFY_DYNAMICCOMBO_V3", {"options": [{"key": "auto"}, {"key": ""}]}],
        id="an-empty-key",
    ),
    pytest.param(
        ["COMFY_DYNAMICCOMBO_V3", {"options": [{"key": True}]}], id="a-boolean-key"
    ),
    pytest.param("COMFY_DYNAMICCOMBO_V3", id="a-bare-string"),
    pytest.param([], id="an-empty-spec"),
]


@pytest.mark.parametrize("spec", REFUSED_SPECS)
def test_a_declaration_this_cannot_read_whole_is_one_it_did_not_read(
    spec: Any,
) -> None:
    """Every way of not being that declaration produces the same ``None``.

    Including the partial ones: an options list with one unreadable entry is
    refused entire rather than read down to the entries that parsed. A partial
    answer would make "the author's value is none of the keys" a sentence this
    module said about its own failure.
    """

    assert declared_structural_keys(spec) is None


def test_the_three_tables_of_a_contract_do_not_overlap() -> None:
    """One input, one declaration, and a caller that asks the right question.

    A choice list, a number and a node shape are three different answers, and
    the one that would do real harm is a shape read as a choice list -- that
    is the dropdown this whole card exists not to offer.  ``declared`` is a
    figure a curator reads in the run's report, and it counts choice lists, so
    a shape must not move it.
    """

    found = contract(
        (VIDEO_SAVE, "quality", combo("draft", "final")),
        (VIDEO_SAVE, "frames", ["INT", {"min": 1, "max": 120}]),
        (VIDEO_SAVE, SHAPE_INPUT, captured_dynamic()),
    )

    assert found.options_for(VIDEO_SAVE, "quality") == ("draft", "final")
    assert found.numeric_for(VIDEO_SAVE, "frames").field_type == "integer"
    assert found.structural_for(VIDEO_SAVE, SHAPE_INPUT) == SHAPES

    assert found.options_for(VIDEO_SAVE, SHAPE_INPUT) is None
    assert found.numeric_for(VIDEO_SAVE, SHAPE_INPUT) is None
    assert found.structural_for(VIDEO_SAVE, "quality") is None
    assert found.declared == 1


def test_no_nested_declaration_reaches_the_contract_under_its_own_name() -> None:
    """The nested inputs describe a node that does not exist unless chosen.

    Reading them into the contract would key a ``FLOAT`` on
    ``(class, 'crf')`` -- and any graph on that class carrying an input of
    that name would then be typed from a declaration belonging to a shape it
    never chose.  So they are absent from all three tables, and the test shows
    it is able to see one: the very same names, declared at the top level of
    another class, are read and answered for.
    """

    found = contract(
        (VIDEO_SAVE, SHAPE_INPUT, captured_dynamic()),
        ("ExampleEncoder", NESTED_FLOAT, ["FLOAT", {"min": 0.0, "max": 51.0}]),
        ("ExampleEncoder", NESTED_DYNAMIC, captured_flat_dynamic()),
    )

    assert found.numeric_for("ExampleEncoder", NESTED_FLOAT).field_type == "float"
    assert found.structural_for("ExampleEncoder", NESTED_DYNAMIC) == (
        "disabled",
        "enabled",
    )

    assert found.numeric_for(VIDEO_SAVE, NESTED_FLOAT) is None
    assert found.options_for(VIDEO_SAVE, NESTED_FLOAT) is None
    assert found.structural_for(VIDEO_SAVE, NESTED_FLOAT) is None
    assert found.numeric_for(VIDEO_SAVE, NESTED_DYNAMIC) is None
    assert found.options_for(VIDEO_SAVE, NESTED_DYNAMIC) is None
    assert found.structural_for(VIDEO_SAVE, NESTED_DYNAMIC) is None


# ==========================================================================
# The judgement: locked at the shape the graph chose
# ==========================================================================


def test_the_shape_the_graph_chose_is_the_shape_that_is_locked() -> None:
    """Not the first key, not a default -- the value the author saved.

    ``h264`` is the *second* declared shape, so a judgement that reached for
    the runtime's own first answer would lock at ``auto`` instead and silently
    turn this workflow into a different one.  The whole sentence is asserted,
    because that sentence is the only place a curator can read back which
    value was kept.
    """

    plan = analyse(
        graph_with(VIDEO_SAVE, {SHAPE_INPUT: "h264"}),
        contract=contract((VIDEO_SAVE, SHAPE_INPUT, captured_dynamic())),
    )

    entry = control_for(plan, "1", SHAPE_INPUT)
    assert entry.section == "locked"
    assert entry.kind == SHAPE_SLUG
    assert entry.reason == (
        "input 'codec' holds 'h264', which the ComfyUI that runs this "
        "workflow declares as one of the shapes node class "
        "'ExampleVideoSave' can take: choosing another would add or remove "
        "inputs on that node rather than change this one. The workflow's "
        "author already chose it, LocalCanvas keeps it exactly as saved, and "
        "offers no control for it."
    )
    assert plan.problems == ()
    assert field_binding(plan, "1", SHAPE_INPUT) is None


def test_the_first_declared_shape_locks_at_itself_and_not_at_the_other_one() -> None:
    """The other half, so the test above cannot pass on the ordering alone.

    A graph that chose ``auto`` -- which is what the value carried by the
    workflows this card is about actually is -- locks at ``auto``.  Run
    against the identical declaration, so the only thing that moved is the
    value in the graph and the only thing that moved in the answer is the
    value in the sentence.
    """

    plan = analyse(
        graph_with(VIDEO_SAVE, {SHAPE_INPUT: "auto"}),
        contract=contract((VIDEO_SAVE, SHAPE_INPUT, captured_dynamic())),
    )

    entry = control_for(plan, "1", SHAPE_INPUT)
    assert entry.section == "locked"
    assert entry.kind == SHAPE_SLUG
    assert "holds 'auto'" in entry.reason
    assert "'h264'" not in entry.reason
    assert plan.problems == ()


def test_a_value_the_runtime_does_not_declare_is_refused_and_never_locked() -> None:
    """An honest unknown stays one, and says which input and which value.

    Locking here would be the importer deciding that a word it has never seen
    is a node shape; substituting a key that does exist would be it deciding
    what the workflow generates.  It does neither, the workflow is held, and
    the sentence names the input and the shapes the runtime declares so a
    curator can act on it.  Since T-0223 it does not quote the value.
    """

    plan = analyse(
        graph_with(VIDEO_SAVE, {SHAPE_INPUT: "vp9"}),
        contract=contract((VIDEO_SAVE, SHAPE_INPUT, captured_dynamic())),
    )

    entry = control_for(plan, "1", SHAPE_INPUT)
    assert entry.section == "needs_review"
    assert entry.kind is None
    assert plan.problems == (
        "Node 1 input 'codec' is one this ComfyUI declares as a choice between "
        "shapes of node class 'ExampleVideoSave' rather than as a value: the "
        "shapes it offers are 'auto', 'h264'. The value saved there is not one "
        "of the shapes this ComfyUI declares, so what this node would be is not "
        "something the graph and this runtime agree on. Nothing was "
        "substituted -- look at it and decide.",
    )
    assert "vp9" not in plan.problems[0]
    assert [item.target for item in plan.not_exposed] == []


def test_without_the_declaration_the_same_input_is_held_exactly_as_before() -> None:
    """The lock is the runtime's word, so a runtime that says nothing locks nothing.

    Same graph, same value, a contract that simply does not describe that
    class.  The input goes back to the sentence `semantics.py` has always
    written for it, which is the behaviour this card must leave untouched
    everywhere it does not speak.
    """

    silent = analyse(
        graph_with(VIDEO_SAVE, {SHAPE_INPUT: "h264"}),
        contract=contract(("ExampleOther", "quality", combo("draft", "final"))),
    )
    declared = analyse(
        graph_with(VIDEO_SAVE, {SHAPE_INPUT: "h264"}),
        contract=contract((VIDEO_SAVE, SHAPE_INPUT, captured_dynamic())),
    )

    assert control_for(silent, "1", SHAPE_INPUT).section == "needs_review"
    assert control_for(silent, "1", SHAPE_INPUT).kind is None
    assert len(silent.problems) == 1
    assert "node shape" not in silent.problems[0]

    assert control_for(declared, "1", SHAPE_INPUT).section == "locked"


def test_the_key_is_never_offered_as_a_select() -> None:
    """Not even where the chosen shape adds nothing, and the test can see one.

    The flat declaration is the tempting case: its shapes add no inputs, so a
    dropdown over them would appear harmless -- and it would still be a
    dropdown whose entries mean "be a different node".  An ordinary ``COMBO``
    on the same node in the same plan **does** become a select, so "no select
    was produced" is a measurement rather than a plan that produced nothing.
    """

    plan = analyse(
        graph_with(VIDEO_SAVE, {SHAPE_INPUT: "enabled", "quality": "draft"}),
        contract=contract(
            (VIDEO_SAVE, SHAPE_INPUT, captured_flat_dynamic()),
            (VIDEO_SAVE, "quality", combo("draft", "final")),
        ),
    )

    quality = field_binding(plan, "1", "quality")
    assert quality is not None
    assert quality.type == "select"
    assert quality.options == ("draft", "final")

    assert field_binding(plan, "1", SHAPE_INPUT) is None
    assert control_for(plan, "1", SHAPE_INPUT).section == "locked"
    assert [item.type for item in plan.fields].count("select") == 1


def test_nothing_nested_changes_a_field_the_graph_really_does_carry() -> None:
    """The sharpest form of "nothing nested is read", and it has both halves.

    The capture declares ``crf`` as a ``FLOAT`` two levels down.  The graph
    here carries its own ``crf`` on that same node, written ``23`` -- so if
    that nested declaration had been read into the contract, T-0098's own
    machinery would pick it up and the field would come out a **float**.  It
    comes out an integer, because nothing nested was read.

    And the same value, on a class that declares ``crf`` as a top-level
    ``FLOAT``, does come out a float in the same run -- so the mechanism that
    reports "integer" above is one that demonstrably notices a declaration
    when there is one to notice.
    """

    plan = analyse(
        graph_with(
            VIDEO_SAVE,
            {SHAPE_INPUT: "h264", NESTED_FLOAT: 23},
            extra={
                "4": {
                    "class_type": "ExampleEncoder",
                    "inputs": {NESTED_FLOAT: 23, "latent": ["3", 0]},
                }
            },
        ),
        contract=contract(
            (VIDEO_SAVE, SHAPE_INPUT, captured_dynamic()),
            ("ExampleEncoder", NESTED_FLOAT, ["FLOAT", {"min": 0.0, "max": 51.0}]),
        ),
    )

    undeclared = field_binding(plan, "1", NESTED_FLOAT)
    declared = field_binding(plan, "4", NESTED_FLOAT)
    assert undeclared is not None and declared is not None
    assert declared.type == "float"
    assert undeclared.type == "integer"
    assert undeclared.minimum is None and undeclared.maximum is None


def test_the_nested_choice_is_not_locked_by_the_declaration_above_it() -> None:
    """A sub-input the graph carries is not settled by its parent's options.

    ``encoding`` is declared only *inside* one of ``codec``'s shapes, so the
    runtime has said nothing about it as an input of this node.  It is held
    for review, exactly as an undeclared word always was -- while ``codec``
    beside it, which the runtime did declare, locks in the same plan.  Both
    halves, so "it was not locked" is not a plan in which nothing was.
    """

    plan = analyse(
        graph_with(VIDEO_SAVE, {SHAPE_INPUT: "h264", NESTED_DYNAMIC: "re-encode"}),
        contract=contract((VIDEO_SAVE, SHAPE_INPUT, captured_dynamic())),
    )

    assert control_for(plan, "1", SHAPE_INPUT).section == "locked"

    nested = control_for(plan, "1", NESTED_DYNAMIC)
    assert nested.section == "needs_review"
    assert nested.kind is None
    assert field_binding(plan, "1", NESTED_DYNAMIC) is None
    assert [item.kind for item in plan.not_exposed] == [SHAPE_SLUG]


def test_a_shape_key_carrying_a_slash_is_not_read_as_a_path() -> None:
    """T-0095, arriving here: a separator in the middle is not evidence.

    Several of these keys are ordinary English with a space or a slash in it.
    A value like ``pro mode / 5s duration`` must lock as the node shape it is,
    with this card's slug -- not as somebody's folder, which would be the same
    outcome reached through a judgement that is simply wrong about it.
    """

    plan = analyse(
        graph_with(VIDEO_SAVE, {"resize_type": "pro mode / 5s duration"}),
        contract=contract((VIDEO_SAVE, "resize_type", captured_ordinary_dynamic())),
    )

    entry = control_for(plan, "1", "resize_type")
    assert entry.section == "locked"
    assert entry.kind == SHAPE_SLUG
    assert "holds 'pro mode / 5s duration'" in entry.reason


def test_the_declaration_decides_and_not_the_node_it_sits_on() -> None:
    """The same shape on a loader and on a saver, answered the same way.

    T-0100 locks an upgraded input on a node whose class type says its job is
    loading, and its slug would be a plausible answer here.  It is the wrong
    one: what makes this input unsafe is the *declaration*, which says the
    options are shapes, and that is true wherever the node sits.  Two plans,
    one difference, and the slug does not move.
    """

    spec = captured_dynamic()
    saver = analyse(
        graph_with(VIDEO_SAVE, {SHAPE_INPUT: "h264"}),
        contract=contract((VIDEO_SAVE, SHAPE_INPUT, spec)),
    )
    loader = analyse(
        graph_with(LOADING_SAVE, {SHAPE_INPUT: "h264"}),
        contract=contract((LOADING_SAVE, SHAPE_INPUT, spec)),
    )

    assert control_for(saver, "1", SHAPE_INPUT).kind == SHAPE_SLUG
    assert control_for(loader, "1", SHAPE_INPUT).kind == SHAPE_SLUG
    assert LOAD_SLUG not in [item.kind for item in loader.not_exposed]


# ==========================================================================
# The whole run, against a stand-in ComfyUI and a stand-in browser
# ==========================================================================


@pytest.fixture()
def workspace(tmp_path: Path) -> SyncWorkspace:
    return SyncWorkspace(tmp_path)


def run_against(
    workspace: SyncWorkspace,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    comfy: FakeComfy,
    converted: Dict[str, Any],
):
    """One whole sync of one editor workflow, through the production path."""

    folder = workspace.add_source()
    write_json(folder / "a canvas.json", ui_graph("one"))
    workspace.write_config()
    browser = Browser(tmp_path, monkeypatch, default={"ok": True, "output": converted})
    with make_bridge(comfy.base_url, browser) as bridge:
        return run_sync(workspace.load(), bridge=bridge)


def test_a_whole_run_imports_the_workflow_and_writes_no_field_for_the_shape(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The seam a curator reads, through the loader the gateway itself runs.

    The workflow imports -- which is the whole point of the card, because
    before it the same graph was refused -- the definition the real registry
    loader accepts carries no field for the input, nothing named after a
    nested input appears anywhere in that document, and the run's report shows
    the decision with its slug.
    """

    with FakeComfy() as comfy:
        comfy.installed_nodes = (VIDEO_SAVE,)
        comfy.node_inputs = {VIDEO_SAVE: {SHAPE_INPUT: captured_dynamic()}}
        report = run_against(
            workspace,
            tmp_path,
            monkeypatch,
            comfy,
            graph_with(VIDEO_SAVE, {SHAPE_INPUT: "h264"}),
        )

    item = report.workflows[0]
    assert item.state.value == "NEW", item.reason

    registry = load_registry(workspace.repo / "config" / "local" / "workflows")
    assert list(registry.diagnostics) == []
    definition = registry.workflows[0]
    assert [entry.id for entry in definition.inputs] == ["prompt", "seed", "steps"]

    document = report_document(report)
    locked = [
        entry
        for workflow in document["workflows"]
        for entry in workflow.get("controls", ())
        if entry["section"] == "locked"
    ]
    assert [(entry["input"], entry["kind"]) for entry in locked] == [
        (SHAPE_INPUT, SHAPE_SLUG)
    ]
    assert document["runtime_contract"]["declared"] == 0


def test_the_definition_written_for_it_mentions_no_nested_input_anywhere(
    tmp_path: Path,
) -> None:
    """An absence over the whole document, shown able to see what it looks for.

    The first document is searched for the two nested names and has neither.
    The second is the same graph with those names as **real** inputs the
    runtime declares at the top level, and the identical search finds both --
    so the search is one that would notice a leak rather than one that finds
    nothing in any document.
    """

    def words(document: Any) -> str:
        return repr(document)

    locked_only = definition_document(
        analyse(
            graph_with(VIDEO_SAVE, {SHAPE_INPUT: "h264"}),
            contract=contract((VIDEO_SAVE, SHAPE_INPUT, captured_dynamic())),
        ),
        workflow_id="example",
        name="Example",
        workflow_relative="example.json",
    )

    visible_graph = graph_with(
        VIDEO_SAVE, {NESTED_FLOAT: 23, NESTED_DYNAMIC: "wide"}
    )
    visible = definition_document(
        analyse(
            visible_graph,
            contract=contract(
                (VIDEO_SAVE, NESTED_FLOAT, ["FLOAT", {"min": 0.0, "max": 51.0}]),
                (VIDEO_SAVE, NESTED_DYNAMIC, combo("wide", "narrow")),
            ),
        ),
        workflow_id="example",
        name="Example",
        workflow_relative="example.json",
    )

    assert NESTED_FLOAT in words(visible)
    assert NESTED_DYNAMIC in words(visible)

    assert NESTED_FLOAT not in words(locked_only)
    assert NESTED_DYNAMIC not in words(locked_only)


# ==========================================================================
# The declaration is asked before the name is (T-0195), and matched exactly
# (T-0201)
# ==========================================================================
#
# Measured on a real runtime (the card, not this file): of 133 node-shape
# declarations, 19 hold values `semantics.classify` answers ``EXPOSE`` for and
# 4 hold values it answers ``LOCKED`` for.  While the declaration was asked
# only inside the ``UNCERTAIN`` branch, the 19 reached the user as text boxes
# and the 4 locked with a sentence that was wrong about why.  The inputs below
# are one of each, on invented node classes; ``mode``/``orbit`` and
# ``invert_crop``/``disabled`` are the two pairs the card measured directly.

#: A node whose ``mode`` is a shape of the node.  Invented.
ORBIT_CAMERA = "ExampleOrbitCamera"
#: A node whose ``invert_crop`` is one.  Invented class; the declaration is
#: :func:`captured_flat_dynamic`, verbatim.
CROP = "ExampleCrop"
#: A node whose ``output`` is one -- a locked string word to `semantics.py`.
RENDER = "ExampleRender"


def shape_spec(*keys: Any) -> List[Any]:
    """A node-shape declaration with the given keys, each adding nothing.

    Invented keys in the verbatim outer shape of :func:`captured_dynamic`.
    What the ordering reads is the keys; the nested blocks are covered above.
    """

    return [
        "COMFY_DYNAMICCOMBO_V3",
        {"options": [{"key": key, "inputs": {"required": {}}} for key in keys]},
    ]


#: One entry per input ``classify`` settles as ``EXPOSE``: the node class, the
#: input, the value the graph carries, the declaration, and the whole sentence
#: the lock must carry -- written out, never formatted from the module.
SETTLED_AS_EXPOSE = [
    pytest.param(
        ORBIT_CAMERA,
        "mode",
        "orbit",
        lambda: shape_spec("orbit", "dolly"),
        "input 'mode' holds 'orbit', which the ComfyUI that runs this workflow "
        "declares as one of the shapes node class 'ExampleOrbitCamera' can "
        "take: choosing another would add or remove inputs on that node rather "
        "than change this one. The workflow's author already chose it, "
        "LocalCanvas keeps it exactly as saved, and offers no control for it.",
        id="mode-orbit",
    ),
    pytest.param(
        CROP,
        "invert_crop",
        "disabled",
        captured_flat_dynamic,
        "input 'invert_crop' holds 'disabled', which the ComfyUI that runs this "
        "workflow declares as one of the shapes node class 'ExampleCrop' can "
        "take: choosing another would add or remove inputs on that node rather "
        "than change this one. The workflow's author already chose it, "
        "LocalCanvas keeps it exactly as saved, and offers no control for it.",
        id="invert_crop-disabled",
    ),
]


def test_classify_settles_every_fixture_below_by_itself() -> None:
    """The fixtures are what the card says they are, or nothing below means anything.

    If ``classify`` answered ``UNCERTAIN`` for ``mode``/``orbit``, T-0185's
    lock would already have been reached and the tests below would pass on the
    old ordering.  So each input is held to the verdict that made it a defect:
    ``EXPOSE`` as a string, ``LOCKED`` as a file reference, and ``UNCERTAIN``
    for ``codec`` and every case variant T-0201 is about.
    """

    for name, value in (("mode", "orbit"), ("mode", "Orbit"), ("invert_crop", "disabled")):
        verdict = classify(name, value)
        assert (verdict.exposure, verdict.kind, verdict.field_type) == (
            Exposure.EXPOSE,
            None,
            "string",
        ), (name, value)

    for value in ("depth", "Depth"):
        verdict = classify("output", value)
        assert (verdict.exposure, verdict.kind) == (Exposure.LOCKED, "file_reference")

    for value in ("h264", "H264", "H264 ", "Auto", "h264 "):
        assert classify(SHAPE_INPUT, value).exposure is Exposure.UNCERTAIN, value


@pytest.mark.parametrize("class_type,name,value,spec,sentence", SETTLED_AS_EXPOSE)
def test_an_input_classify_would_expose_locks_when_its_declaration_is_a_shape(
    class_type: str, name: str, value: str, spec: Any, sentence: str
) -> None:
    """Locked at the graph's value, with the node-shape slug and its sentence.

    The "before" is measured in the same test, on the path this card left
    unchanged: the same graph with no declaration for the input, and with the
    same keys declared as an ordinary list of choices.  Both are an editable
    ``string`` field -- which is what the declared input also was until the
    declaration was asked first -- and both are exactly the plan analysis
    produces with no contract at all.
    """

    graph = graph_with(class_type, {name: value})
    keys = tuple(entry["key"] for entry in spec()[1]["options"])

    declared = analyse(graph, contract=contract((class_type, name, spec())))

    assert control_for(declared, "1", name) == ControlRecord(
        node="1", input=name, section="locked", reason=sentence, kind=SHAPE_SLUG
    )
    assert declared.not_exposed == (
        NotExposed("1", name, "locked", sentence, SHAPE_SLUG),
    )
    assert field_binding(declared, "1", name) is None
    assert declared.problems == ()
    assert [item.id for item in declared.fields] == ["prompt", "seed", "steps"]

    silent = analyse(graph, contract=contract(("ExampleOther", name, spec())))
    as_a_list = analyse(graph, contract=contract((class_type, name, combo(*keys))))
    for before in (silent, as_a_list):
        field = field_binding(before, "1", name)
        assert field is not None
        assert (field.type, field.options, field.default) == ("string", (), value)
        assert control_for(before, "1", name).kind is None
        assert before.not_exposed == ()
        assert before == analyse(graph, contract=None)


def test_an_input_classify_locks_for_another_reason_locks_for_the_true_one() -> None:
    """Same outcome; the sentence a curator reads changes to the real reason.

    ``output`` is a locked string word, so ``classify`` locks it as a file
    reference.  Declared as a node shape, it is locked as one -- and without
    the declaration it is still ``classify``'s file reference, word for word.
    """

    graph = graph_with(RENDER, {"output": "depth"})
    sentence = (
        "input 'output' holds 'depth', which the ComfyUI that runs this workflow "
        "declares as one of the shapes node class 'ExampleRender' can take: "
        "choosing another would add or remove inputs on that node rather than "
        "change this one. The workflow's author already chose it, LocalCanvas "
        "keeps it exactly as saved, and offers no control for it."
    )

    declared = analyse(
        graph, contract=contract((RENDER, "output", shape_spec("depth", "normal")))
    )
    assert control_for(declared, "1", "output") == ControlRecord(
        node="1", input="output", section="locked", reason=sentence, kind=SHAPE_SLUG
    )
    assert declared.problems == ()

    before = analyse(
        graph, contract=contract(("ExampleOther", "output", shape_spec("depth")))
    )
    by_name = classify("output", "depth")
    assert control_for(before, "1", "output") == ControlRecord(
        node="1",
        input="output",
        section="locked",
        reason=by_name.reason,
        kind="file_reference",
    )
    assert by_name.reason != sentence


def test_codec_lands_exactly_as_it_did_before_the_declaration_moved() -> None:
    """T-0185's own input, whole: the record, the slug and the sentence.

    ``codec`` was always ``UNCERTAIN`` and always reached the declaration, so
    moving the declaration earlier must not change one character of it.
    """

    sentence = (
        "input 'codec' holds 'h264', which the ComfyUI that runs this workflow "
        "declares as one of the shapes node class 'ExampleVideoSave' can take: "
        "choosing another would add or remove inputs on that node rather than "
        "change this one. The workflow's author already chose it, LocalCanvas "
        "keeps it exactly as saved, and offers no control for it."
    )

    plan = analyse(
        graph_with(VIDEO_SAVE, {SHAPE_INPUT: "h264"}),
        contract=contract((VIDEO_SAVE, SHAPE_INPUT, captured_dynamic())),
    )

    assert control_for(plan, "1", SHAPE_INPUT) == ControlRecord(
        node="1", input=SHAPE_INPUT, section="locked", reason=sentence, kind=SHAPE_SLUG
    )
    assert plan.not_exposed == (
        NotExposed("1", SHAPE_INPUT, "locked", sentence, SHAPE_SLUG),
    )
    assert plan.problems == ()
    assert [item.id for item in plan.fields] == ["prompt", "seed", "steps"]


@pytest.mark.parametrize(
    "class_type,name,value,spec",
    [
        pytest.param(
            ORBIT_CAMERA, "mode", "Orbit", lambda: shape_spec("orbit", "dolly"), id="expose"
        ),
        pytest.param(
            RENDER, "output", "Depth", lambda: shape_spec("depth", "normal"), id="locked"
        ),
    ],
)
def test_a_value_outside_the_keys_holds_an_input_classify_settles(
    class_type: str, name: str, value: str, spec: Any
) -> None:
    """A case variant of a declared key is not locked, and not left as classify left it.

    The match is exact, so the value is none of the keys; and since T-0223 the
    step asked first holds such an input for review whatever ``classify``
    said -- an editable string here would be a text box on an input only the
    declared keys are legal in.  The "before" is the same graph with no
    contract, which is still exactly what ``classify`` makes of it.
    """

    graph = graph_with(class_type, {name: value})
    keys = ", ".join(repr(entry["key"]) for entry in spec()[1]["options"])
    before = analyse(graph, contract=None)
    assert before.problems == ()
    assert control_for(before, "1", name).section != "needs_review"

    declared = analyse(graph, contract=contract((class_type, name, spec())))

    reason = (
        "input {!r} is one this ComfyUI declares as a choice between shapes of "
        "node class {!r} rather than as a value: the shapes it offers are {}. "
        "The value saved there is not one of the shapes this ComfyUI declares, "
        "so what this node would be is not something the graph and this runtime "
        "agree on. Nothing was substituted -- look at it and "
        "decide.".format(name, class_type, keys)
    )
    assert control_for(declared, "1", name) == ControlRecord(
        node="1", input=name, section="needs_review", reason=reason
    )
    assert declared.problems == ("Node 1 " + reason,)
    assert declared.fields == ()
    assert declared.not_exposed == ()


@pytest.mark.parametrize("value", ["H264", "H264 ", "Auto", "h264 "])
def test_a_case_variant_of_a_declared_shape_is_held_for_review_and_never_locked(
    value: str,
) -> None:
    """T-0201: exact match, no case folding and no trimming.

    Locking ``H264`` would submit a value this runtime does not declare, and a
    locked input shows nothing on any screen, so the wrong answer would be
    visible nowhere.  The same declaration locks ``h264`` in the same test, so
    the refusal is not a declaration that matches nothing.

    Each value is aimed at one way of loosening the match: ``H264`` and
    ``Auto`` at case folding, ``h264 `` at trimming alone, and ``H264 `` at the
    two together -- trimming alone leaves ``H264``, which still misses.
    """

    exact = analyse(
        graph_with(VIDEO_SAVE, {SHAPE_INPUT: "h264"}),
        contract=contract((VIDEO_SAVE, SHAPE_INPUT, captured_dynamic())),
    )
    assert control_for(exact, "1", SHAPE_INPUT).section == "locked"

    plan = analyse(
        graph_with(VIDEO_SAVE, {SHAPE_INPUT: value}),
        contract=contract((VIDEO_SAVE, SHAPE_INPUT, captured_dynamic())),
    )

    reason = (
        "input 'codec' is one this ComfyUI declares as a choice between shapes "
        "of node class 'ExampleVideoSave' rather than as a value: the shapes it "
        "offers are 'auto', 'h264'. The value saved there is not one of the "
        "shapes this ComfyUI declares, so what this node would be is not "
        "something the graph and this runtime agree on. Nothing was substituted "
        "-- look at it and decide."
    )
    assert value not in reason
    assert plan.problems == ("Node 1 " + reason,)
    assert control_for(plan, "1", SHAPE_INPUT) == ControlRecord(
        node="1", input=SHAPE_INPUT, section="needs_review", reason=reason
    )
    assert plan.not_exposed == ()
    assert plan.fields == ()


def test_a_checkpoint_dropdown_and_a_sampler_select_are_untouched_beside_a_shape() -> None:
    """Choice lists are not node shapes, and the step asked first acts in this plan.

    One plan: a loader's weights declared as a plain-word list, a sampler name
    declared as a list, an unsettled sampler input the runtime upgrades to a
    select -- and a ``codec`` shape on another node, which does lock, so the
    step demonstrably ran.  Every choice-list input comes out exactly as in
    the same graph without that shape.
    """

    def build(with_shape: bool) -> Dict[str, Any]:
        graph = graph_with("ExampleWeightsLoader", {"ckpt_name": "alpha"})
        graph["3"]["inputs"].update({"sampler_name": "steady_pace", "mixing": "layered"})
        graph["4"] = {
            "class_type": VIDEO_SAVE,
            "inputs": {SHAPE_INPUT: "h264"} if with_shape else {},
        }
        return graph

    lists = (
        ("ExampleWeightsLoader", "ckpt_name", combo("alpha", "beta")),
        ("ExampleSampler", "sampler_name", combo("steady_pace", "other_pace")),
        ("ExampleSampler", "mixing", combo("steady", "drifting", "layered")),
    )
    plan = analyse(
        build(True),
        contract=contract(*lists, (VIDEO_SAVE, SHAPE_INPUT, captured_dynamic())),
    )
    without = analyse(build(False), contract=contract(*lists))

    assert control_for(plan, "4", SHAPE_INPUT).kind == SHAPE_SLUG

    assert control_for(plan, "1", "ckpt_name") == ControlRecord(
        node="1",
        input="ckpt_name",
        section="locked",
        reason=classify("ckpt_name", "alpha").reason,
        kind="file_reference",
    )
    sampler = field_binding(plan, "3", "sampler_name")
    assert sampler is not None
    assert (sampler.type, sampler.options, sampler.default) == ("string", (), "steady_pace")
    mixing = field_binding(plan, "3", "mixing")
    assert mixing is not None
    assert (mixing.type, mixing.options, mixing.default) == (
        "select",
        ("steady", "drifting", "layered"),
        "layered",
    )

    assert plan.fields == without.fields
    assert [item for item in plan.controls if item.target != ("4", SHAPE_INPUT)] == list(
        without.controls
    )
    assert plan.problems == without.problems == ()


#: A node whose ``level`` and ``flag`` are declared as shapes with **number**
#: keys.  Invented; `contract.py` accepts an ``int`` or ``float`` key.
NUMBERED = "ExampleNumberedShape"


@pytest.mark.parametrize(
    "name,value,keys,field_type",
    [
        pytest.param("flag", True, (1, 2), "boolean", id="True-against-int-keys"),
        pytest.param("level", 1.0, (1, 2), "float", id="float-against-int-keys"),
        pytest.param("level", 1, (1.0, 2.0), "integer", id="int-against-float-keys"),
    ],
)
def test_a_value_equal_to_a_key_only_under_python_equality_is_not_that_key(
    name: str, value: Any, keys: Tuple[Any, ...], field_type: str
) -> None:
    """The match is type-exact: ``True == 1`` and ``1.0 == 1`` are not declarations.

    The step asked first sees every literal, a flag and a number included, so
    a plain ``in`` would lock ``True`` against a declared key ``1`` with a
    sentence saying the runtime declared it.  Each value here is none of the
    keys, so it is held for review (T-0223) and never locked; without the
    declaration it is exactly what ``classify`` makes it.
    """

    verdict = classify(name, value)
    assert (verdict.exposure, verdict.field_type) == (Exposure.EXPOSE, field_type)

    graph = graph_with(NUMBERED, {name: value})
    before = analyse(graph, contract=None)
    field = field_binding(before, "1", name)
    assert field is not None
    assert (field.type, field.default) == (field_type, value)
    assert type(field.default) is type(value)

    plan = analyse(graph, contract=contract((NUMBERED, name, shape_spec(*keys))))

    reason = (
        "input {!r} is one this ComfyUI declares as a choice between shapes of "
        "node class 'ExampleNumberedShape' rather than as a value: the shapes it "
        "offers are {}. The value saved there is not one of the shapes this "
        "ComfyUI declares, so what this node would be is not something the "
        "graph and this runtime agree on. Nothing was substituted -- look at it "
        "and decide.".format(name, ", ".join(repr(key) for key in keys))
    )
    assert control_for(plan, "1", name) == ControlRecord(
        node="1", input=name, section="needs_review", reason=reason
    )
    assert plan.not_exposed == ()
    assert plan.problems == ("Node 1 " + reason,)


def test_a_number_that_is_a_declared_key_of_its_own_type_locks() -> None:
    """The other half: the step acts on a number, not only on a plain string.

    ``2`` against the keys ``1`` and ``2`` is ``classify``'s integer field
    without the declaration, and locked at ``2`` with it -- so the type rule
    above is a rule about matching and not a step that stopped reaching
    numbers.
    """

    graph = graph_with(NUMBERED, {"level": 2})
    assert classify("level", 2).field_type == "integer"

    plan = analyse(graph, contract=contract((NUMBERED, "level", shape_spec(1, 2))))

    sentence = (
        "input 'level' holds 2, which the ComfyUI that runs this workflow "
        "declares as one of the shapes node class 'ExampleNumberedShape' can "
        "take: choosing another would add or remove inputs on that node rather "
        "than change this one. The workflow's author already chose it, "
        "LocalCanvas keeps it exactly as saved, and offers no control for it."
    )
    assert control_for(plan, "1", "level") == ControlRecord(
        node="1", input="level", section="locked", reason=sentence, kind=SHAPE_SLUG
    )
    assert plan.not_exposed == (NotExposed("1", "level", "locked", sentence, SHAPE_SLUG),)
    assert field_binding(plan, "1", "level") is None
    assert plan.problems == ()

    before = analyse(graph, contract=None)
    field = field_binding(before, "1", "level")
    assert field is not None
    assert (field.type, field.default) == ("integer", 2)
