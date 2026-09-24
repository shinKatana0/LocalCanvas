"""Asking the user's own ComfyUI what an input accepts, and what that may do.

A graph carries the value a node *has* and never the list it would *accept*,
so an unrecognised string is ``UNCERTAIN`` and its workflow needs review.  The
runtime contract does not weaken that rule -- it supplies the one piece of
evidence the graph never had, from the installation that will actually run it.

The properties held here, in the order they matter:

* the contract may only ever **upgrade an ``UNCERTAIN``**.  A structural
  dropdown stays locked *although its choices are known*, and the proof is not
  that the field is absent -- it is that the contract was never asked about it,
  watched by a contract that records every question;
* the choices come from the **matching class and the matching input**, and from
  neither of the two things that look almost right;
* a current value **in** the declared list becomes the default; a value **not**
  in it is ``NEEDS_REVIEW`` naming the input and the value, and nothing is
  substituted;
* a declared list of **file names** is a file picker and never an editable
  field.  Two independent shapes say so, and each is held by a test that fails
  on its own;
* a logical field **id does not move** when the selected value changes or when
  the runtime reorders its list.  Asserted verbatim, because these are the keys
  a user's defaults, drafts and saved setups hang off;
* **no contract, no guessing**: no ComfyUI, an undeclared input, or a contract
  belonging to another installation each leave the run exactly where it was.

Every node class, input name and choice below is invented for this file.  None
of them names a real node, a real model or a setting observed anywhere: what is
under test is the rule "the runtime declared a finite list for this class and
this input", which is not a vocabulary.

One section is the exception, and has to be.  *The shape a declaration is
written in* is not a rule this project gets to invent -- it is ComfyUI's, and a
fixture written from memory of it would prove only that the parser agrees with
the memory.  So the specs in "The two shapes one enumeration is declared in"
are **verbatim captures** from a current ComfyUI's ``/object_info`` (0.33.0,
T-0180), keys and all, with the node classes they came from left out and long
tooltips shortened.  What they bring in with them is ComfyUI's own vocabulary
for containers and codecs -- ``mp4``, ``vp9`` -- and nothing else: no model,
no path, no machine, and nothing about the installation they were read on.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import pytest

from localcanvas_gateway.comfy.fake import FakeComfy
from localcanvas_gateway.workflows import load_registry
from localcanvas_gateway.workflows.sync import analyse, run_sync
from localcanvas_gateway.workflows.sync.bridge import ComfyIdentity
from localcanvas_gateway.workflows.sync.contract import (
    ContractCache,
    RuntimeContract,
    declared_options,
    names_files,
    read_object_info,
)
from localcanvas_gateway.workflows.sync.definitions import definition_document
from localcanvas_gateway.workflows.sync.report import report_document

from bridge_fixtures import Browser, make_bridge, ui_graph
from sync_fixtures import SyncWorkspace, write_json

# --------------------------------------------------------------------------
# The graph, and the runtime that has an opinion about it
# --------------------------------------------------------------------------

#: The node class whose one unsettled input this file is about.
SAMPLER = "ExampleSampler"
#: An input name nothing in `semantics.py` recognises: not a number, not a
#: path, not prose, not media, not one of the node's known settings.  It is
#: therefore ``UNCERTAIN`` on the graph's evidence alone, which is the only
#: situation the contract is allowed to touch.
UNSETTLED = "mixing"
#: What a runtime might declare for it.  Words, deliberately: nothing here may
#: look like a file, or the file-name rule would be doing the work instead of
#: the rule under test.
CHOICES: Tuple[str, ...] = ("steady", "drifting", "layered")

#: The loader input that must stay locked although its choices are knowable.
LOADER = "ExampleWeightsLoader"
LOADER_INPUT = "ckpt_name"


def graph(value: str = "steady") -> Dict[str, Any]:
    """One ordinary generation with one input nothing can settle."""

    return {
        "1": {
            "class_type": LOADER,
            "inputs": {LOADER_INPUT: "chosen-weights.safetensors"},
        },
        "2": {
            "class_type": "ExampleTextEncode",
            "inputs": {"text": "a quiet street at dawn", "clip": ["1", 1]},
        },
        "3": {
            "class_type": SAMPLER,
            "inputs": {
                "seed": 7,
                "steps": 20,
                UNSETTLED: value,
                "model": ["1", 0],
                "positive": ["2", 0],
            },
        },
    }


def object_info(*declarations: Tuple[str, str, Any]) -> Dict[str, Any]:
    """``/object_info`` in ComfyUI's own shape, for the given declarations.

    Each declaration is ``(class type, input name, spec)`` and the spec is
    written exactly as ComfyUI writes one: ``[[...], {}]`` for a finite list of
    choices, ``["INT", {}]`` for an input declared as a type.
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

    Built through the production parser rather than by filling the table by
    hand: a test that constructed the table directly would still pass if the
    parser stopped recognising ComfyUI's shape.
    """

    return read_object_info(object_info(*declarations), identity_digest=digest)


def choices(*values: Any) -> List[Any]:
    """One ``/object_info`` spec declaring a finite list of choices.

    The **legacy** shape, with the values at position 0.  Kept as the default
    spelling throughout this file so that every rule already held here goes on
    being held against the shape it was written for.
    """

    return [list(values), {}]


def combo(*values: Any, **config: Any) -> List[Any]:
    """The same declaration in the shape **current** ComfyUI writes it in.

    The type name at position 0 and the values under ``options`` in the mapping
    beside it.  ``config`` is whatever else that mapping carries -- ``default``,
    ``tooltip``, ``multiselect`` -- because a real one always carries several
    keys and a fixture that carried only ``options`` would not show that the
    others are ignored.
    """

    declared = dict(config)
    declared["options"] = list(values)
    return ["COMBO", declared]


class Watching:
    """A contract that records every question asked of it.

    "The contract is never consulted for a locked input" is a claim about a
    call that does not happen, and the only honest way to check it is to hold
    the thing that would have been called.

    The three questions are recorded **apart**, because they are asked in
    different situations and a single list would make one of them alibi the
    others: the choice list is asked only for an input nothing could settle
    (:attr:`asked`), the numeric type only for one the graph settled as a
    number (:attr:`asked_numeric`), and the node shapes T-0185 added are asked
    for every input, **before** ``classify`` (:attr:`asked_structural`) --
    T-0195 moved that one, and it may only lock.  T-0098's tests hold the
    second and T-0185's and T-0195's the third; the ones here hold the first,
    and it still says exactly what it said.
    """

    def __init__(self, inner: RuntimeContract) -> None:
        self._inner = inner
        self.asked: List[Tuple[str, str]] = []
        self.asked_numeric: List[Tuple[str, str]] = []
        self.asked_structural: List[Tuple[str, str]] = []

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
        self.asked_numeric.append((class_type, input_name))
        return self._inner.numeric_for(class_type, input_name)

    def structural_for(self, class_type: str, input_name: str):
        self.asked_structural.append((class_type, input_name))
        return self._inner.structural_for(class_type, input_name)


def field_named(plan, field_id: str):
    found = [item for item in plan.fields if item.id == field_id]
    assert found, "no field {!r}; there are {}".format(
        field_id, [item.id for item in plan.fields]
    )
    return found[0]


def problem_about(plan, name: str) -> str:
    found = [item for item in plan.problems if repr(name) in item]
    assert found, "nothing was said about {!r}; problems are {}".format(
        name, plan.problems
    )
    return found[0]


# ==========================================================================
# What the contract reads, and what it refuses to read
# ==========================================================================


def test_a_finite_list_of_choices_is_read_in_the_order_it_was_declared() -> None:
    found = declared_options(choices("steady", "drifting", "layered"))

    assert found == ("steady", "drifting", "layered")


@pytest.mark.parametrize(
    "spec",
    [
        pytest.param(["INT", {"default": 0}], id="a type name, not a list"),
        pytest.param(["STRING", {"multiline": True}], id="a string input"),
        pytest.param([[], {}], id="an empty list offers no choice"),
        pytest.param([[["a"], "b"], {}], id="a choice that is itself a list"),
        pytest.param([[True, False], {}], id="booleans are not option values"),
        pytest.param([["a", ""], {}], id="an empty choice cannot be shown"),
        pytest.param([[1, 1.0], {}], id="two equal choices of different types"),
        pytest.param([], id="nothing at all"),
        pytest.param("COMBO", id="a bare type name"),
        pytest.param({"options": ["a", "b"]}, id="a shape this does not read"),
    ],
)
def test_anything_that_is_not_plainly_a_list_of_choices_declares_nothing(
    spec: Any,
) -> None:
    """Not declared is not "declared empty": the caller must be left as it was.

    The last case matters most.  A shape this module does not recognise is
    answered with ``None`` and never with a guess at what it might have
    meant -- a wrong guess here puts a control in front of a user that ComfyUI
    then refuses.
    """

    assert declared_options(spec) is None


def test_an_input_declared_in_the_optional_section_is_read_too() -> None:
    document = {
        SAMPLER: {"input": {"optional": {UNSETTLED: choices(*CHOICES)}}},
    }

    found = read_object_info(document, identity_digest="sha256:x")

    assert found.options_for(SAMPLER, UNSETTLED) == CHOICES


def test_an_input_declared_twice_is_read_from_the_required_section() -> None:
    """No answer of this module's may depend on the order a dict happens to be in.

    A build that declares one input in both sections is malformed, and reading
    whichever came last would make the contract depend on how ComfyUI happened
    to serialise its answer.  ``required`` is the node's own declaration, so it
    is the one that is taken -- fixed, and written down.
    """

    document = {
        SAMPLER: {
            "input": {
                "required": {UNSETTLED: choices("steady", "drifting")},
                "optional": {UNSETTLED: choices("something", "else")},
            }
        }
    }

    found = read_object_info(document, identity_digest="sha256:x")

    assert found.options_for(SAMPLER, UNSETTLED) == ("steady", "drifting")


def test_a_document_that_is_not_an_object_info_answer_declares_nothing() -> None:
    """An unreadable answer costs the run nothing beyond the contract."""

    for document in (None, [], "", {"A": "not a class"}, {"A": {"input": []}}):
        found = read_object_info(document, identity_digest="sha256:x")
        assert found.declared == 0
        assert found.options_for(SAMPLER, UNSETTLED) is None


# ==========================================================================
# The two shapes one enumeration is declared in
# ==========================================================================
#
# Every spec in this section is a verbatim capture from a current ComfyUI's
# ``/object_info`` (see this file's docstring).  They are written out as
# literals rather than built by :func:`combo`, because what is under test here
# is ComfyUI's shape and a helper would only prove the parser agrees with the
# helper.

#: An enumeration in the current shape, carrying every key a real one carries.
CAPTURED_FORMAT: List[Any] = [
    "COMBO",
    {
        "tooltip": "The format to save the video as.",
        "default": "auto",
        "multiselect": False,
        "options": ["auto", "mp4"],
    },
]

#: The same shape with no ``default`` -- the mapping's other keys vary, and
#: none of them may be what makes the options readable.
CAPTURED_CODEC: List[Any] = [
    "COMBO",
    {"multiselect": False, "options": ["vp9", "av1"]},
]

#: Six choices in an order that is neither sorted nor reverse-sorted, so that
#: "the declared order is kept" is a claim that can fail.
CAPTURED_SIX: List[Any] = [
    "COMBO",
    {
        "tooltip": "Corrects colour shifts in the upscaled output.",
        "default": "lab",
        "multiselect": False,
        "options": ["lab", "wavelet", "wavelet_adaptive", "hsv", "adain", "none"],
    },
]

#: A dynamic combo, whole.  Each option is an object carrying its own nested
#: ``required``/``optional`` inputs, one of which carries a further dynamic
#: combo, one of whose options carries a ``FLOAT``.  That is the design
#: question T-0180 refuses to guess at, and this is what it really looks like.
CAPTURED_DYNAMIC: List[Any] = [
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
                        "encoding": [
                            "COMFY_DYNAMICCOMBO_V3",
                            {
                                "display_name": "encoding mode",
                                "options": [
                                    {"key": "auto", "inputs": {"required": {}}},
                                    {
                                        "key": "re-encode",
                                        "inputs": {
                                            "required": {
                                                "crf": [
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

#: The honest refusal: free text that happens to hold something list-like.
#: There is no option list anywhere in it and there never was.
CAPTURED_FREE_TEXT: List[Any] = ["STRING", {"default": "a + b", "multiline": True}]

#: A ``COMBO`` that declares no ``options`` at all -- the choices are fetched
#: later from a route.  Nothing has been declared *here*, so nothing is read.
CAPTURED_REMOTE: List[Any] = [
    "COMBO",
    {
        "image_upload": True,
        "image_folder": "output",
        "remote": {
            "route": "/internal/files/output",
            "refresh_button": True,
            "control_after_refresh": "first",
        },
    },
]

#: A ``COMBO`` whose options list is empty, which is what a loader declares
#: when the user has none of that kind of file.  Fifteen inputs on the runtime
#: this was captured from are one of these two.
CAPTURED_NO_CHOICES: List[Any] = ["COMBO", {"multiselect": False, "options": []}]

#: A real list with a real value in it twice.  The repeat rule was written for
#: the legacy shape and this is the shape it now has to hold in as well; since
#: T-0186 the rule reads an exact repeat once rather than refusing the list.
CAPTURED_VALUE_TWICE: List[Any] = [
    "COMBO",
    {
        "multiselect": False,
        "options": ["area", "lanczos", "bilinear", "nearest-exact", "bilinear", "bicubic"],
    },
]

#: A real list offering an empty choice.  ``docs/workflow-schema.md`` refuses
#: an option nobody can see, so the whole list is refused.
CAPTURED_EMPTY_CHOICE: List[Any] = [
    "COMBO",
    {
        "tooltip": "Specify the pose mode for the generated model.",
        "advanced": True,
        "multiselect": False,
        "options": ["", "A-pose", "T-pose"],
    },
]

#: A real list four of whose values carry a ``/``.  T-0095: a separator is not
#: evidence of a filesystem, and this change is what newly exposes such values.
CAPTURED_WITH_SEPARATORS: List[Any] = [
    "COMBO",
    {
        "multiselect": False,
        "options": [
            "auto",
            "openpose",
            "depth",
            "hed/pidi/scribble/ted",
            "canny/lineart/anime_lineart/mlsd",
            "normal",
            "segment",
            "tile",
            "repaint",
        ],
    },
]

#: The class the captures are hung off where a document is needed.  Invented,
#: as everywhere else in this file: which node they came from is not what is
#: under test and naming it would put somebody's installation in the suite.
VIDEO_SAVE = "ExampleVideoSave"


def test_the_current_shape_declares_its_choices_in_the_order_it_declared_them() -> None:
    """Verbatim, and in order.

    Asserted as whole tuples: "options were found" would pass on a parser that
    sorted them, reversed them, deduplicated them or read the wrong key.  Two
    of the three lists are in an order no sort produces, so the order is a
    claim that can fail rather than one the fixture satisfies by accident.
    """

    assert declared_options(CAPTURED_FORMAT) == ("auto", "mp4")
    assert declared_options(CAPTURED_CODEC) == ("vp9", "av1")
    assert declared_options(CAPTURED_SIX) == (
        "lab",
        "wavelet",
        "wavelet_adaptive",
        "hsv",
        "adain",
        "none",
    )


def test_the_two_shapes_of_one_enumeration_are_read_into_the_same_answer() -> None:
    """The same three choices, written both ways, are one declaration.

    Both sides are also asserted against the values themselves, so a parser
    that stopped reading *both* shapes could not pass this by returning
    ``None`` twice.
    """

    legacy = declared_options(choices("vp9", "av1"))
    current = declared_options(CAPTURED_CODEC)

    assert legacy == ("vp9", "av1")
    assert current == ("vp9", "av1")
    assert legacy == current


@pytest.mark.parametrize(
    "spec",
    [
        pytest.param(CAPTURED_REMOTE, id="captured: no options key at all"),
        pytest.param(CAPTURED_NO_CHOICES, id="captured: an empty options list"),
        pytest.param(
            ["COMBO", {"options": [1, 1.0]}], id="two equal choices of different types"
        ),
        pytest.param(CAPTURED_EMPTY_CHOICE, id="captured: an empty choice"),
        pytest.param(["COMBO"], id="a type name and nothing else"),
        pytest.param(["COMBO", None], id="no mapping beside the type name"),
        pytest.param(["COMBO", ["auto", "mp4"]], id="a list where the mapping goes"),
        pytest.param(["COMBO", {"multiselect": False}], id="a mapping with no options"),
        pytest.param(["COMBO", {"options": None}], id="options declared as nothing"),
        pytest.param(["COMBO", {"options": "mp4"}], id="options declared as a string"),
        pytest.param(["COMBO", {"options": {"mp4": 1}}], id="options as a mapping"),
        pytest.param(["COMBO", {"options": [["mp4"], "webm"]}], id="a nested choice"),
        pytest.param(["COMBO", {"options": ["mp4", ["3", 0]]}], id="a wire as a choice"),
        pytest.param(["COMBO", {"options": [True, False]}], id="booleans as choices"),
        pytest.param(["COMBO", {"OPTIONS": ["auto", "mp4"]}], id="another key entirely"),
    ],
)
def test_a_current_shape_that_declares_no_usable_list_declares_nothing(
    spec: Any,
) -> None:
    """Every way of not declaring a list, in the shape that now reads one.

    Each of these is ``None`` and none of them raises: ``read_object_info``
    reads another program's document, and a section it cannot make sense of
    must cost the run nothing beyond the inputs in it.

    The four captured cases are not hypothetical -- fifteen inputs on the
    runtime T-0180 was measured on declare ``COMBO`` with no usable list, and
    four more are refused for their values.
    """

    assert declared_options(spec) is None


def test_the_current_shape_reads_a_repeat_once_exactly_as_the_legacy_one_does() -> None:
    """One rule over both shapes, not one rule and a copy of it.

    The list is real and its repeat is real.  The same values with the repeat
    taken out by hand are the expected answer, for both shapes (T-0186: an
    exact repeat is read once, the first occurrence in its place).
    """

    without = [
        value for index, value in enumerate(CAPTURED_VALUE_TWICE[1]["options"])
        if index != 4
    ]

    assert declared_options(combo(*without)) == (
        "area",
        "lanczos",
        "bilinear",
        "nearest-exact",
        "bicubic",
    )
    assert declared_options(CAPTURED_VALUE_TWICE) == tuple(without)
    assert declared_options(choices(*CAPTURED_VALUE_TWICE[1]["options"])) == tuple(without)


def test_a_dynamic_combo_declares_nothing_and_its_option_keys_are_not_flattened() -> None:
    """The one this card refuses, with the refusal made expensive to lose.

    A dynamic combo's options are not values -- each is an object carrying its
    own nested inputs, and choosing ``h264`` adds an ``encoding`` input which
    can add a ``crf`` float.  What a user would be picking between is a
    question with its own card, and the convenient wrong answer is to flatten
    the options to their ``key`` and call it a dropdown.

    So the keys are taken out of the capture and shown to be a list this
    module **would** read if a runtime declared it honestly.  The refusal is
    therefore about what the spec is, not about the parser failing to find
    anything in it, and a parser that flattened would return exactly the tuple
    on the first line.
    """

    keys = tuple(option["key"] for option in CAPTURED_DYNAMIC[1]["options"])

    assert declared_options(combo(*keys)) == ("auto", "h264")
    assert declared_options(CAPTURED_DYNAMIC) is None


def test_the_dynamic_type_is_refused_by_its_name_and_not_by_what_it_carries() -> None:
    """Which rule does the refusing, isolated.

    The previous test would still pass if the type name stopped being checked
    at all, because a dynamic combo's options are objects and an object is not
    an option value -- the refusal would come from the wrong rule and nothing
    would say so.

    This one moves one thing.  The payload is identical and readable; only the
    type name differs, and the answer changes.  The second spec is a probe and
    not a shape ComfyUI writes: what it proves is that
    ``COMFY_DYNAMICCOMBO_V3`` is refused for being that type, so a build that
    starts declaring plain values under it is still refused rather than
    quietly becoming a control.
    """

    payload = {"options": ["auto", "h264"]}

    assert declared_options(["COMBO", dict(payload)]) == ("auto", "h264")
    assert declared_options(["COMFY_DYNAMICCOMBO_V3", dict(payload)]) is None


def test_a_document_carrying_both_shapes_is_read_whole() -> None:
    """The two shapes side by side in one class, as a real document has them.

    Also the count: ``declared`` is what a run's report shows a curator, and
    two of these four inputs are declarations.
    """

    document = object_info(
        (VIDEO_SAVE, "quality", choices("draft", "final")),
        (VIDEO_SAVE, "format", CAPTURED_FORMAT),
        (VIDEO_SAVE, "codec", CAPTURED_DYNAMIC),
        (VIDEO_SAVE, "expression", CAPTURED_FREE_TEXT),
    )

    found = read_object_info(document, identity_digest="sha256:x")

    assert found.options_for(VIDEO_SAVE, "quality") == ("draft", "final")
    assert found.options_for(VIDEO_SAVE, "format") == ("auto", "mp4")
    assert found.options_for(VIDEO_SAVE, "codec") is None
    assert found.options_for(VIDEO_SAVE, "expression") is None
    assert found.declared == 2


def test_the_shape_a_runtime_used_changes_nothing_downstream_of_the_contract() -> None:
    """One declaration, two spellings, one plan.

    Compared as whole field records rather than as "both produced a field":
    the id is what a user's defaults and saved setups hang off, and the
    options, the default and the section are what they see.
    """

    def described(plan) -> List[Any]:
        return [
            (item.id, item.type, item.options, item.default, item.section)
            for item in plan.fields
        ]

    legacy = analyse(graph(), contract=contract((SAMPLER, UNSETTLED, choices(*CHOICES))))
    current = analyse(
        graph(),
        contract=contract(
            (SAMPLER, UNSETTLED, combo(*CHOICES, default="steady", multiselect=False))
        ),
    )

    assert legacy.problems == ()
    assert current.problems == ()
    assert field_named(current, UNSETTLED).options == CHOICES
    assert described(current) == described(legacy)


def test_a_newly_readable_choice_carrying_a_separator_is_not_read_as_a_path() -> None:
    """T-0095, in the shape that newly exposes such values.

    Four of the nine choices here carry a ``/`` and none of them names a place
    on anybody's disk.  Before this change the whole list was invisible, so the
    rule that a separator is not evidence now has hundreds more inputs to hold
    for -- and the values are asserted verbatim, because "a field appeared"
    would pass on a list that had been filtered.
    """

    offered = tuple(CAPTURED_WITH_SEPARATORS[1]["options"])
    assert "hed/pidi/scribble/ted" in offered, "the fixture carries no separator"

    plan = analyse(
        graph("hed/pidi/scribble/ted"),
        contract=contract((SAMPLER, UNSETTLED, CAPTURED_WITH_SEPARATORS)),
    )

    assert plan.problems == ()
    item = field_named(plan, UNSETTLED)
    assert item.type == "select"
    assert item.options == offered
    assert item.default == "hed/pidi/scribble/ted"


def test_a_list_of_file_names_in_the_current_shape_is_refused_as_it_always_was() -> None:
    """The file-name guard, held against the shape that now reaches it.

    The same two values without the file name among them are shown to be a
    select first.  Without that half this would be an absence test that passed
    just as well on a parser which could not read the current shape at all --
    which is precisely the state this card is fixing, and precisely the test
    that would have said nothing about it.
    """

    readable = analyse(
        graph("compact"), contract=contract((SAMPLER, UNSETTLED, combo("compact", "wide")))
    )
    assert field_named(readable, UNSETTLED).options == ("compact", "wide")

    refused = analyse(
        graph("compact"),
        contract=contract(
            (SAMPLER, UNSETTLED, combo("compact", "chosen-weights.safetensors"))
        ),
    )

    assert refused.needs_review
    assert [item.id for item in refused.fields] == []
    said = problem_about(refused, UNSETTLED)
    assert "list of file names" in said
    assert "chosen-weights.safetensors" not in said


# ==========================================================================
# The order: LOCKED, then EXPOSE, and only then the contract
# ==========================================================================


def test_a_structural_dropdown_stays_locked_although_its_choices_are_known() -> None:
    """The case the whole ordering exists for.

    ``/object_info`` lists every installed set of weights as a literal option
    list, so a rule that read the contract first would turn "which model this
    workflow is" into a control **because** its choices are known.

    The declared choices here are deliberately plain words rather than file
    names, so the file-name rule cannot be what refuses them.  The only thing
    keeping this input locked is that the contract is asked after ``LOCKED``
    has already answered -- and the watcher proves that by never being asked,
    while being asked about the input in the very same graph that is genuinely
    unsettled.
    """

    watcher = Watching(
        contract(
            (LOADER, LOADER_INPUT, choices("alpha", "beta")),
            (SAMPLER, UNSETTLED, choices(*CHOICES)),
        )
    )

    plan = analyse(graph(), contract=watcher)

    assert (SAMPLER, UNSETTLED) in watcher.asked, (
        "the watcher was never asked anything, so its silence about the loader "
        "proves nothing"
    )
    assert (LOADER, LOADER_INPUT) not in watcher.asked
    # The node-shape table is asked first since T-0195, and a choice list is
    # not in it: asked, declined, and the silence of ``asked`` above is still
    # the proof that no list reached a locked input.
    assert (LOADER, LOADER_INPUT) in watcher.asked_structural
    assert [item.id for item in plan.fields] == ["prompt", UNSETTLED, "seed", "steps"]
    locked = [item for item in plan.not_exposed if item.input == LOADER_INPUT]
    assert [(item.exposure, item.kind) for item in locked] == [
        ("locked", "weights_file")
    ]


def test_the_contract_is_not_asked_about_an_input_already_exposed() -> None:
    """An ``EXPOSE`` verdict is not up for reconsideration either.

    Same watcher, same graph: a number the graph already settles must not
    become a list of choices because a runtime happens to declare one for it.
    """

    watcher = Watching(
        contract(
            (SAMPLER, "steps", choices(10, 20, 30)),
            (SAMPLER, UNSETTLED, choices(*CHOICES)),
        )
    )

    plan = analyse(graph(), contract=watcher)

    assert (SAMPLER, UNSETTLED) in watcher.asked, "the watcher recorded nothing"
    assert (SAMPLER, "steps") not in watcher.asked
    # Asked first since T-0195 and declined: this is a choice list, not a shape.
    assert (SAMPLER, "steps") in watcher.asked_structural
    steps = field_named(plan, "steps")
    assert (steps.type, steps.options, steps.default) == ("integer", (), 20)


# ==========================================================================
# The upgrade itself
# ==========================================================================


def test_an_unsettled_string_with_no_runtime_metadata_still_needs_review() -> None:
    """The behaviour this card starts from, and the one it must preserve."""

    plan = analyse(graph())

    assert plan.needs_review
    assert [item.id for item in plan.fields] == []
    assert repr(UNSETTLED) in problem_about(plan, UNSETTLED)


def test_a_declared_choice_list_makes_the_input_a_select_over_those_choices() -> None:
    plan = analyse(graph(), contract=contract((SAMPLER, UNSETTLED, choices(*CHOICES))))

    assert plan.problems == ()
    item = field_named(plan, UNSETTLED)
    assert item.type == "select"
    assert item.options == ("steady", "drifting", "layered")
    assert item.default == "steady"
    assert item.has_default is True
    assert item.section == "advanced"
    assert item.required is False
    assert item.translatable is False
    assert item.targets == (("3", UNSETTLED),)


def test_a_contract_that_declares_nothing_leaves_the_run_exactly_as_it_was() -> None:
    """Rule 6, as an equality rather than as a description of one.

    An empty contract, and a contract that declares something about a class
    this graph does not contain, both have to produce the same plan as no
    contract at all -- the same problems, the same fields, the same sentences.
    """

    without = analyse(graph())
    empty = analyse(graph(), contract=read_object_info({}, identity_digest="sha256:x"))
    elsewhere = analyse(
        graph(), contract=contract(("ExampleOtherNode", UNSETTLED, choices(*CHOICES)))
    )

    assert without.problems == empty.problems == elsewhere.problems
    assert without.problems, "the fixture settled everything, so nothing was compared"
    assert [item.id for item in empty.fields] == []
    assert [item.id for item in elsewhere.fields] == []


# ==========================================================================
# The right class, and the right input
# ==========================================================================


def test_choices_declared_for_another_class_are_not_used() -> None:
    """Both halves in one test: the same list, moved one class over.

    Without the first half this would be an absence test that never proved the
    list could have been written at all.
    """

    right = analyse(graph(), contract=contract((SAMPLER, UNSETTLED, choices(*CHOICES))))
    wrong = analyse(
        graph(),
        contract=contract(("ExampleOtherSampler", UNSETTLED, choices(*CHOICES))),
    )

    assert field_named(right, UNSETTLED).options == CHOICES
    assert wrong.needs_review
    assert [item.id for item in wrong.fields] == []
    assert repr(UNSETTLED) in problem_about(wrong, UNSETTLED)


def test_choices_declared_for_another_input_of_the_right_class_are_not_used() -> None:
    """The near miss: right class, wrong input.

    ``steps`` is an input the same node really has, so this is the shape a
    lookup that dropped the input name would take.
    """

    right = analyse(graph(), contract=contract((SAMPLER, UNSETTLED, choices(*CHOICES))))
    wrong = analyse(graph(), contract=contract((SAMPLER, "steps", choices(*CHOICES))))

    assert field_named(right, UNSETTLED).options == CHOICES
    assert wrong.needs_review
    assert [item.id for item in wrong.fields] == []
    assert field_named(right, "steps").options == ()


# ==========================================================================
# The current value
# ==========================================================================


def test_a_value_the_runtime_does_not_offer_is_review_and_nothing_is_substituted() -> None:
    """An absent value is evidence, not noise.

    It means the graph was saved against a different version of that node, and
    silently choosing one of the values that *do* exist would change what the
    workflow generates without anybody being told.
    """

    plan = analyse(
        graph("from-an-older-node"),
        contract=contract((SAMPLER, UNSETTLED, choices(*CHOICES))),
    )

    assert plan.needs_review
    assert [item.id for item in plan.fields] == []
    said = problem_about(plan, UNSETTLED)
    assert "'from-an-older-node'" in said
    assert "does not offer" in said
    for choice in CHOICES:
        assert repr(choice) in said, "the sentence does not say what is offered"
    assert "Nothing was substituted" in said


def test_an_input_with_no_name_an_id_can_be_made_from_is_still_review() -> None:
    """A declared list is not a licence to mint an id out of nothing.

    A node's input name is a JSON key and a custom node may use anything as
    one.  Without a word to build an id from there is no key for a user's
    defaults and saved setups to hang off, and a field called after nothing in
    particular is worse than a workflow somebody looks at.
    """

    odd = {"3": {"class_type": SAMPLER, "inputs": {"!!": "steady"}}}

    plan = analyse(odd, contract=contract((SAMPLER, "!!", choices(*CHOICES))))

    assert plan.needs_review
    assert [item.id for item in plan.fields] == []


def test_the_value_must_match_the_declared_choice_exactly() -> None:
    """``"20"`` is not ``20``: a near match is a mismatch.

    A contract that compared loosely would write a string into an input the
    runtime declares as numbers, which fails at ComfyUI and not here.
    """

    numeric = analyse(
        graph("20"), contract=contract((SAMPLER, UNSETTLED, choices(10, 20, 30)))
    )
    exact = analyse(
        {"3": {"class_type": SAMPLER, "inputs": {UNSETTLED: "20"}}},
        contract=contract((SAMPLER, UNSETTLED, choices("10", "20", "30"))),
    )

    assert numeric.needs_review
    assert field_named(exact, UNSETTLED).default == "20"


# ==========================================================================
# A list of file names is a file picker
# ==========================================================================


def test_a_declared_list_of_file_names_does_not_become_an_editable_field() -> None:
    """The shape of a file name, on an input no vocabulary recognises.

    ``.avif`` is in none of `semantics.py`'s suffix lists on purpose: what
    refuses this is the *shape* of a file name and not membership of a list,
    which is the same discipline T-0072 settled for media.

    The graph's own value is a plain word that **is** one of the choices, so
    everything else about this input is in order.  Take the file-name shape out
    of the rule and this becomes a perfectly valid ``select`` over a list of
    somebody's files -- which is the bug, not merely a different message.
    """

    plan = analyse(
        graph("plain"),
        contract=contract((SAMPLER, UNSETTLED, choices("plain", "portrait.avif"))),
    )

    assert plan.needs_review
    assert [item.id for item in plan.fields] == []
    assert "list of file names" in problem_about(plan, UNSETTLED)


def test_a_declared_list_of_folders_does_not_become_an_editable_field() -> None:
    """The other shape, and the one the first test cannot catch.

    Neither choice here has an extension, so the file-name shape answers "no"
    for both of them; what refuses this list is `looks_like_a_path`, and each
    guard therefore fails a test of its own -- which is what stops one of them
    being deleted unnoticed, and, as above, removing it produces the bug
    rather than a different sentence.

    The folder is written from a **home**, and that is the point rather than
    decoration: since T-0095 a bare separator is not evidence of a path, so
    ``characters/other`` -- which this test used to carry -- is ordinary text
    as far as this project is concerned, and a list containing it is no longer
    a file picker.  What still says "a place on the machine" is a root, and
    that is what the choice below has.
    """

    plan = analyse(
        graph("hero"),
        contract=contract((SAMPLER, UNSETTLED, choices("hero", "~/characters/other"))),
    )

    assert plan.needs_review
    assert [item.id for item in plan.fields] == []
    assert "list of file names" in problem_about(plan, UNSETTLED)


def test_a_refused_list_of_file_names_is_not_repeated_back_in_the_report() -> None:
    """The user's own file names are the user's, including in a refusal.

    The two sentences this card composes are asymmetric on purpose.  The one
    about a value the runtime does not offer names the choices, because a
    curator has to see what they may pick instead -- and it is only ever
    reached for a list that is *not* file names, since the file test answers
    first.  The one about a file picker names none of them: a report crosses a
    pipe, is rendered by a script and gets pasted into an issue, and somebody's
    model and picture names have no business travelling that way.
    """

    # One of each shape the refusal recognises, so that no entry here is in
    # the list for a reason that stopped being true: two file names, and a
    # folder written from a home, which is what says "a place on the machine"
    # now that a bare separator does not (T-0095).
    files = ("chosen-weights.safetensors", "a private study.png", "~/vault/secret")

    plan = analyse(
        graph("plain"),
        contract=contract((SAMPLER, UNSETTLED, choices("plain", *files))),
    )

    said = problem_about(plan, UNSETTLED)
    for name in files:
        assert name not in said, "a declared file name reached the report"
    assert "list of file names" in said


def test_a_refusal_for_file_names_is_counted_apart_from_a_silent_runtime() -> None:
    """Two silences that look alike and mean opposite things.

    Nothing is exposed either way and the workflow needs review either way, so
    the plan on its own cannot tell "this ComfyUI declared no list here" from
    "it declared one and every choice was a file name".  The first says look at
    the runtime; the second says the rule is working and these inputs really
    are pickers.  So the second is counted, by node and input, and the first is
    not counted at all.
    """

    refused = analyse(
        graph("plain"),
        contract=contract((SAMPLER, UNSETTLED, choices("plain", "portrait.avif"))),
    )
    silent = analyse(graph("plain"), contract=contract())
    settled = analyse(graph(), contract=contract((SAMPLER, UNSETTLED, choices(*CHOICES))))

    assert refused.refused_as_file_names == (("3", UNSETTLED),)
    assert silent.refused_as_file_names == ()
    assert settled.refused_as_file_names == ()
    assert refused.needs_review and silent.needs_review, (
        "both fixtures have to reach review, or they are not the two silences"
    )


def test_one_file_name_among_the_choices_is_enough() -> None:
    """A picker over the user's files commonly offers "None" beside them."""

    assert names_files(["None", "chosen-weights.safetensors"]) is True
    assert names_files(list(CHOICES)) is False


# ==========================================================================
# Identity: neither the value nor the list may move an id
# ==========================================================================

#: The ids :func:`graph` produces once the contract has settled its one
#: unsettled input.  Written out rather than derived, because "the ids did not
#: move" is only worth anything against ids somebody wrote down.
EXPECTED_IDS = ["prompt", "mixing", "seed", "steps"]


def test_the_field_ids_do_not_move_when_the_selected_value_changes() -> None:
    declared = contract((SAMPLER, UNSETTLED, choices(*CHOICES)))

    before = analyse(graph("steady"), contract=declared)
    after = analyse(graph("layered"), contract=declared)

    assert [item.id for item in before.fields] == EXPECTED_IDS
    assert [item.id for item in after.fields] == EXPECTED_IDS
    assert field_named(before, UNSETTLED).default == "steady"
    assert field_named(after, UNSETTLED).default == "layered", (
        "the value under test did not actually change"
    )


def test_the_field_ids_do_not_move_when_the_runtime_reorders_its_choices() -> None:
    """A ComfyUI upgrade reorders a list; a user's saved settings must not move.

    The declared order is still presentation, and still follows the runtime --
    so the two halves are asserted together: the ids are identical and the
    lists really are in different orders.
    """

    declared = contract((SAMPLER, UNSETTLED, choices(*CHOICES)))
    reordered = contract((SAMPLER, UNSETTLED, choices(*reversed(CHOICES))))

    before = analyse(graph(), contract=declared)
    after = analyse(graph(), contract=reordered)

    assert [item.id for item in before.fields] == EXPECTED_IDS
    assert [item.id for item in after.fields] == EXPECTED_IDS
    assert field_named(before, UNSETTLED).options == ("steady", "drifting", "layered")
    assert field_named(after, UNSETTLED).options == ("layered", "drifting", "steady")


def test_two_inputs_the_runtime_offers_different_choices_for_are_two_controls() -> None:
    """One name, one value, two node classes, two different lists.

    Collapsed into one control the user would set a value that only one of the
    two nodes accepts, and the job would fail at ComfyUI from a form that
    looked right.  So they stay two fields, each carrying what its own class
    declares.
    """

    two = {
        "1": {"class_type": SAMPLER, "inputs": {UNSETTLED: "steady"}},
        "2": {
            "class_type": "ExampleOtherSampler",
            "inputs": {UNSETTLED: "steady", "samples": ["1", 0]},
        },
    }
    declared = contract(
        (SAMPLER, UNSETTLED, choices("steady", "drifting")),
        ("ExampleOtherSampler", UNSETTLED, choices("steady", "layered")),
    )

    plan = analyse(two, contract=declared)

    assert plan.problems == ()
    found = {item.id: item for item in plan.fields}
    assert len(found) == 2, sorted(found)
    by_target = {
        item.targets[0][0]: item.options for item in plan.fields
    }
    assert by_target == {
        "1": ("steady", "drifting"),
        "2": ("steady", "layered"),
    }


def test_two_classes_offering_one_set_in_two_orders_are_one_control() -> None:
    """The other half of the rule above, and the one that guards an id.

    Same input name, same value, same *set* of choices -- and two node packs
    that happened to write that set in different orders.  With
    ``weight``-shaped input names declared in fifteen or twenty classes at a
    time, two nodes of different classes carrying one name and one value is an
    ordinary shape in a real tree, not a contrived one.

    They are one control, and its id is ``mixing``.  Let the declared order
    into the grouping key and this becomes two fields whose ids are salted with
    a fingerprint -- ``mixing-682000f9`` and ``mixing-fde5bf00`` -- so a
    ComfyUI upgrade that reorders one pack's list moves the key a user's saved
    setups hang off.  That is the same forbidden outcome as an id salted with
    the option list directly, reached by a different route: the grouping key
    *is* the fingerprint, and `docs/workflow-schema.md`'s stability rule covers
    both.

    The set really is one set and the orders really are two -- asserted first,
    so this cannot pass on a fixture that quietly declared the same thing
    twice.
    """

    two = {
        "1": {"class_type": SAMPLER, "inputs": {UNSETTLED: "steady"}},
        "2": {
            "class_type": "ExampleOtherSampler",
            "inputs": {UNSETTLED: "steady", "samples": ["1", 0]},
        },
    }
    declared = contract(
        (SAMPLER, UNSETTLED, choices("steady", "drifting")),
        ("ExampleOtherSampler", UNSETTLED, choices("drifting", "steady")),
    )
    first = declared.options_for(SAMPLER, UNSETTLED)
    second = declared.options_for("ExampleOtherSampler", UNSETTLED)
    assert first != second, "the two lists are in the same order"
    assert set(first) == set(second), "the two lists are not the same set"

    plan = analyse(two, contract=declared)

    assert plan.problems == ()
    assert [item.id for item in plan.fields] == ["mixing"]
    assert plan.fields[0].targets == (("1", UNSETTLED), ("2", UNSETTLED))


# ==========================================================================
# What is written, and that the real loader accepts it
# ==========================================================================


def test_the_definition_writes_the_choices_the_runtime_declared() -> None:
    plan = analyse(graph(), contract=contract((SAMPLER, UNSETTLED, choices(*CHOICES))))

    document = definition_document(
        plan, workflow_id="one", name="One", workflow_relative="../g.json"
    )
    written = [item for item in document["inputs"] if item["id"] == UNSETTLED]

    assert written == [
        {
            "id": UNSETTLED,
            "label": "Mixing",
            "type": "select",
            "section": "advanced",
            "options": [
                {"value": "steady"},
                {"value": "drifting"},
                {"value": "layered"},
            ],
            "default": "steady",
            "bind": [{"node": "3", "input": UNSETTLED}],
        }
    ]


# ==========================================================================
# The whole run, against a stand-in ComfyUI and a stand-in browser
# ==========================================================================


@pytest.fixture()
def workspace(tmp_path: Path) -> SyncWorkspace:
    return SyncWorkspace(tmp_path)


@pytest.fixture()
def comfy():
    """A ComfyUI that declares a finite list of choices for one input."""

    with FakeComfy() as running:
        running.installed_nodes = (SAMPLER,)
        running.node_inputs = {SAMPLER: {UNSETTLED: choices(*CHOICES)}}
        yield running


def converted() -> Dict[str, Any]:
    """What the stand-in frontend answers with: the graph, in API format."""

    return graph()


def run_against(workspace: SyncWorkspace, tmp_path: Path, monkeypatch, comfy: FakeComfy):
    """One whole sync of one editor workflow, through the production path."""

    folder = workspace.add_source()
    write_json(folder / "a canvas.json", ui_graph("one"))
    workspace.write_config()
    browser = Browser(tmp_path, monkeypatch, default={"ok": True, "output": converted()})
    with make_bridge(comfy.base_url, browser) as bridge:
        return run_sync(workspace.load(), bridge=bridge)


def test_a_converted_workflow_imports_with_the_choices_its_comfyui_declares(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
    comfy: FakeComfy,
) -> None:
    """End to end, and through the loader the gateway itself runs.

    The same canvas without the declaration is ``NEEDS_REVIEW``: that is the
    measured difference this card exists to make, and it is asserted here
    rather than described.
    """

    report = run_against(workspace, tmp_path, monkeypatch, comfy)

    item = report.workflows[0]
    assert item.state.value == "NEW", item.reason
    registry = load_registry(workspace.repo / "config" / "local" / "workflows")
    assert list(registry.diagnostics) == []
    assert [entry.id for entry in registry.workflows] == [item.id]
    definition = registry.workflows[0]
    found = [entry for entry in definition.inputs if entry.id == UNSETTLED]
    assert len(found) == 1, [entry.id for entry in definition.inputs]
    assert found[0].type.value == "select"
    assert [option.value for option in found[0].options] == list(CHOICES)
    assert [option.label for option in found[0].options] == list(CHOICES)
    assert found[0].default == "steady"

    document = report_document(report)
    assert document["runtime_contract"] == {
        "declared": 1,
        "fields": 1,
        "refused_as_file_names": 0,
    }


def test_the_same_canvas_needs_review_when_its_comfyui_declares_nothing(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The other side of the measurement, and the proof it was the contract.

    Everything is the same but the ``/object_info`` answer, so what changed the
    outcome cannot be anything else.
    """

    with FakeComfy() as quiet:
        report = run_against(workspace, tmp_path, monkeypatch, quiet)

    item = report.workflows[0]
    assert item.state.value == "NEEDS_REVIEW"
    assert UNSETTLED in (item.reason or "")
    assert not (workspace.output_tree / "workflows").exists()
    assert report_document(report)["runtime_contract"] == {
        "declared": 0,
        "fields": 0,
        "refused_as_file_names": 0,
    }


def test_the_report_tells_a_silent_runtime_from_one_whose_lists_were_refused(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The headline distinction, at the seam a person actually reads.

    Read against its neighbour above: that run's ComfyUI declared nothing and
    reports ``declared: 0``; this one declares a list for the very same input
    and every choice in it is a file, so it reports ``declared: 1`` and
    ``refused_as_file_names: 1``. Both workflows need review and neither has a
    field, so without the third number the two runs are the same document -
    and they call for opposite next steps.
    """

    with FakeComfy() as picker:
        picker.installed_nodes = (SAMPLER,)
        picker.node_inputs = {SAMPLER: {UNSETTLED: choices("plain", "portrait.avif")}}
        folder = workspace.add_source()
        write_json(folder / "a canvas.json", ui_graph("one"))
        workspace.write_config()
        browser = Browser(
            tmp_path, monkeypatch, default={"ok": True, "output": graph("plain")}
        )
        with make_bridge(picker.base_url, browser) as bridge:
            report = run_sync(workspace.load(), bridge=bridge)

    item = report.workflows[0]
    assert item.state.value == "NEEDS_REVIEW"
    assert report_document(report)["runtime_contract"] == {
        "declared": 1,
        "fields": 0,
        "refused_as_file_names": 1,
    }


def test_the_contract_costs_no_request_beyond_the_probe_that_already_happens(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
    comfy: FakeComfy,
) -> None:
    """Reading what a node accepts talks to nothing but the one ComfyUI.

    The recorder is the fake ComfyUI's own, and the same recorder is shown to
    catch traffic it should not see in
    ``test_sync_bridge.py::test_no_prompt_is_ever_queued_in_order_to_export``.
    """

    report = run_against(workspace, tmp_path, monkeypatch, comfy)

    assert report_document(report)["runtime_contract"]["fields"] == 1, (
        "the contract was not used in this run, so it proves nothing about cost"
    )
    assert sorted(set(comfy.requests)) == ["GET /object_info", "GET /system_stats"]


def test_a_registry_of_api_exports_still_asks_its_comfyui_nothing(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
    comfy: FakeComfy,
) -> None:
    """The contract does not make a user who converts nothing pay for it.

    A tree of API exports establishes no identity, so there is no contract to
    hand out -- and the workflow that would have been settled by one is
    ``NEEDS_REVIEW``, exactly as it was before this card.
    """

    folder = workspace.add_source()
    write_json(folder / "an export.json", graph())
    workspace.write_config()
    browser = Browser(tmp_path, monkeypatch, default={"ok": True, "output": converted()})
    with make_bridge(comfy.base_url, browser) as bridge:
        report = run_sync(workspace.load(), bridge=bridge)

    assert comfy.requests == []
    assert report.workflows[0].state.value == "NEEDS_REVIEW"
    assert report_document(report)["runtime_contract"] == {
        "declared": None,
        "fields": 0,
        "refused_as_file_names": 0,
    }


# ==========================================================================
# Provenance: one contract belongs to one ComfyUI
# ==========================================================================


def identity(*node_types: str) -> ComfyIdentity:
    return ComfyIdentity.build(
        comfyui_version="1", frontend_version="1", node_types=list(node_types)
    )


def test_a_contract_is_handed_back_only_for_the_comfyui_it_was_read_from() -> None:
    """Two installations, two digests, and no borrowing between them.

    The digests are T-0084's own, computed from two genuinely different node
    lists -- what an input accepts is exactly what moves when a custom node is
    installed, updated or removed.
    """

    one = identity("A", "B")
    other = identity("A", "B", "C")
    assert one.digest != other.digest

    cache = ContractCache()
    cache.store(contract((SAMPLER, UNSETTLED, choices(*CHOICES)), digest=one.digest))

    assert cache.get(other.digest) is None
    assert cache.get(one.digest) is not None
    assert cache.get(one.digest).options_for(SAMPLER, UNSETTLED) == CHOICES


def test_a_bridge_that_has_asked_nothing_has_no_contract_to_give(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, comfy: FakeComfy
) -> None:
    """No probe, no identity, no contract -- and the same after a failed probe.

    A contract that cannot be attributed to an installation must not describe
    a graph, so "ComfyUI is not reachable" degrades to no contract rather than
    to a stale one.
    """

    browser = Browser(tmp_path, monkeypatch, default={"ok": True, "output": converted()})
    with make_bridge(comfy.base_url, browser) as bridge:
        assert bridge.runtime_contract() is None
        assert bridge.ensure_identity() is not None
        assert bridge.runtime_contract() is not None

    dead = "http://127.0.0.1:9"
    with make_bridge(dead, browser) as bridge:
        assert bridge.runtime_contract() is None
        with pytest.raises(Exception):
            bridge.ensure_identity()
        assert bridge.runtime_contract() is None


def test_the_bridge_reads_the_contract_out_of_the_object_info_it_already_fetched(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, comfy: FakeComfy
) -> None:
    """The values, for what a node accepts; the keys, for which ComfyUI it is.

    Both come from one answer, and the digest is the keys only -- so adding a
    model to a folder still invalidates nothing.
    """

    browser = Browser(tmp_path, monkeypatch, default={"ok": True, "output": converted()})
    with make_bridge(comfy.base_url, browser) as bridge:
        found = bridge.runtime_contract()
        assert found is None
        established = bridge.ensure_identity()
        found = bridge.runtime_contract()
        assert found is not None
        assert found.identity_digest == established.digest
        assert found.options_for(SAMPLER, UNSETTLED) == CHOICES
        assert found.options_for("FakeNode", "value") is None
