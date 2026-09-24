"""Knowing every legal value is not permission to change it.

``/object_info`` truthfully declares the finite list of things a text-encoder
loader's architecture input accepts.  The name is in no vocabulary of
`semantics.py`'s and the value is a short plain word, so ``classify`` answers
``UNCERTAIN``, the contract is asked, and *which model this workflow is* used to
reach the user as an editable Advanced dropdown of which exactly one value
works.  That is the outcome the whole LOCKED-before-contract ordering exists to
prevent, reached through a plain enum instead of through a list of file names.

The judgement that closes it reads the **node**, and this file is organised
around the four ways of getting that wrong that the phase has already paid for:

* **the node, never the input's name.**  ``type`` on a loading node locks and
  the same name with the same value and the same declaration on an ordinary
  node stays a select.  Both halves in one test, always -- an absence that was
  never shown to be available proves nothing.
* **word tokens, never the identifier.**  Seven differently spelled loading
  classes lock, and ``payload``, ``preloaded`` and ``overload`` do not, so no
  substring match could pass.  Parametrisation alone says nothing about a
  *list of names*, though, and that is measured rather than assumed: a closed
  allowlist of every loading class name this file writes down survives the
  whole suite.  What excludes it is
  :func:`test_the_lock_follows_the_vocabulary_and_not_a_list_of_class_names`,
  which builds its class type out of :data:`LOADING_CLASS_WORDS` at the moment
  it runs, from a word patched in that appears nowhere in this repository --
  so the decision is shown to follow the vocabulary, and no list written in
  advance can contain the name it is asked about.
* **never the option values.**  A model family may not be named in application
  logic, so the choices are not read, and the
  refusal does not repeat them back either.
* **it gates the upgrade and nothing else.**  A safe enum on an ordinary node
  is still an Advanced select in two shapes (T-0070); a number, a flag, a
  prompt and a picture on the loading node itself are untouched (T-0072,
  T-0098); an input nobody could settle is still ``NEEDS_REVIEW`` there, so no
  workflow moves into review or out of it.

Every node class, input name and choice below is invented for this file.  None
names a real node, a real model, a real node pack or a setting observed
anywhere: what is under test is "the node's class type says its job is loading",
which is not a vocabulary of anybody's installation.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import pytest

from localcanvas_gateway.comfy.fake import FakeComfy
from localcanvas_gateway.workflows import load_registry
from localcanvas_gateway.workflows.sync import (
    LOADING_CLASS_WORDS,
    LOCKED_KINDS,
    analyse,
    class_words,
    run_sync,
)
from localcanvas_gateway.workflows.sync import analysis as analysis_module
from localcanvas_gateway.workflows.sync.contract import (
    RuntimeContract,
    read_object_info,
)
from localcanvas_gateway.workflows.sync.definitions import definition_document
from localcanvas_gateway.workflows.sync.report import report_document
from localcanvas_gateway.workflows.sync.semantics import Exposure, classify

from bridge_fixtures import Browser, make_bridge, ui_graph
from sync_fixtures import SyncWorkspace, write_json

# --------------------------------------------------------------------------
# The one input this file is about, and the runtime that has an opinion on it
# --------------------------------------------------------------------------

#: The slug the judgement carries.  Written out, not imported from the module
#: under test: a test that took the name from the code would still pass if the
#: code started grouping this with something else in a curator's report.
LOAD_SLUG = "load_setting"

#: The input name the real defect was measured on.  It is in no vocabulary of
#: `semantics.py`'s, which is what makes it ``UNCERTAIN`` -- and it is a name
#: an ordinary tunable could equally have, which is why the name alone must
#: never be what locks it.
ARCHITECTURE = "type"

#: What a runtime might declare for it.  Invented words, and deliberately not
#: file-shaped: the file-name refusal must not be what answers here, or this
#: file would be testing T-0054's rule again instead of T-0100's.
FORMS: Tuple[str, ...] = ("compact", "wide", "layered")

#: A node whose class type says nothing about loading, for every "and on an
#: ordinary node it does not" half below.
PLAIN = "ExampleSampler"


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
    hand, so that a test cannot pass on a table ComfyUI's shape no longer
    produces.
    """

    return read_object_info(object_info(*declarations), identity_digest=digest)


def choices(*values: Any) -> List[Any]:
    """One ``/object_info`` spec declaring a finite list of choices."""

    return [list(values), {}]


def combo(*values: Any) -> List[Any]:
    """The same declaration in the shape current ComfyUI writes it in.

    ComfyUI declares an enumeration in two shapes -- the values at position 0,
    or the type name ``"COMBO"`` there and the values under ``options`` beside
    it -- and T-0180 taught the importer to read the second.  Which one a node
    uses says nothing about the node except how recently it was written, so it
    may not decide whether the input it declares is put in front of a user.
    """

    return ["COMBO", {"multiselect": False, "options": list(values)}]


def graph_with(
    class_type: str, inputs: Optional[Dict[str, Any]] = None
) -> Dict[str, Any]:
    """One readable generation whose node ``1`` is of the given class.

    Node ``1`` carries the inputs under test; the rest is an ordinary graph, so
    that "the workflow still imports" is a thing this fixture can show rather
    than a thing it makes trivially true.
    """

    return {
        "1": {
            "class_type": class_type,
            "inputs": dict(inputs if inputs is not None else {ARCHITECTURE: "compact"}),
        },
        "2": {
            "class_type": "ExampleTextEncode",
            "inputs": {"text": "a quiet street at dawn", "clip": ["1", 1]},
        },
        "3": {
            "class_type": PLAIN,
            "inputs": {"seed": 7, "steps": 20, "model": ["1", 0], "positive": ["2", 0]},
        },
    }


def control_for(plan, node: str, name: str):
    found = [item for item in plan.controls if item.target == (node, name)]
    assert found, "input {!r} of node {} is not in the inventory at all; it has {}".format(
        name, node, [item.target for item in plan.controls]
    )
    return found[0]


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


class Watching:
    """A contract that records every question asked of it.

    "The contract is never consulted for this input" is a claim about a call
    that does not happen, and the only honest way to check it is to hold the
    thing that would have been called.  The three questions are recorded apart
    for the reason T-0098 separated the first two: the choice list is asked
    only for an input nothing could settle, the numeric type only for one the
    graph settled as a number, T-0185's node shapes for every input and before
    ``classify`` (T-0195, a step that may only lock), and one list would let
    any of them alibi the others.
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


# ==========================================================================
# The fixture cannot make the assertion true by itself
# ==========================================================================


def test_the_input_under_test_is_one_semantics_really_cannot_settle() -> None:
    """Everything below is worthless if `semantics.py` was locking it already.

    Two guards protect "a structural model control never becomes editable":
    `classify`'s own LOCKED branches, and the judgement this card added.  Each
    has to fail a test on its own, so the fixture is held to being ``UNCERTAIN``
    on the graph's own evidence -- no weights suffix, no path, no locked word.
    Take the new judgement out and this input becomes a select; that is the
    defect, and no other guard stands in the way of it.
    """

    verdict = classify(ARCHITECTURE, "compact")

    assert verdict.exposure is Exposure.UNCERTAIN
    assert verdict.kind is None
    assert verdict.field_type is None
    for form in FORMS:
        assert classify(ARCHITECTURE, form).exposure is Exposure.UNCERTAIN


# ==========================================================================
# The defect: an architecture enum on a loader
# ==========================================================================


def test_an_architecture_enum_on_a_text_encoder_loader_stays_locked() -> None:
    """The measured defect, end to end through ``analyse``.

    The runtime declares a perfectly ordinary finite list of plain words and
    the graph's value is one of them, so every other rule in the importer is
    satisfied and the input was becoming an Advanced select.  It is locked
    instead -- and the workflow still imports, with its other fields intact.
    """

    plan = analyse(
        graph_with("ExampleTextEncoderLoader"),
        contract=contract(("ExampleTextEncoderLoader", ARCHITECTURE, choices(*FORMS))),
    )

    assert plan.problems == ()
    assert [item.id for item in plan.fields] == ["prompt", "seed", "steps"]
    assert ARCHITECTURE not in [item.id for item in plan.fields]

    entry = control_for(plan, "1", ARCHITECTURE)
    assert entry.section == "locked"
    assert entry.kind == LOAD_SLUG
    assert entry.field is None
    assert [
        (item.node, item.input, item.exposure, item.kind) for item in plan.not_exposed
    ] == [("1", ARCHITECTURE, "locked", LOAD_SLUG)]


def test_the_same_enum_declared_in_the_current_shape_is_locked_too() -> None:
    """The review's question, asked about the shape that was invisible.

    Until T-0180 the importer read only the legacy spelling of a declaration,
    so hundreds of enumerations -- among them plenty that say which model a
    loading node reads and how -- never reached this judgement at all.  A
    declaration it could not see could not unlock anything; now it can see
    them, and the answer has to be the same one.

    The first half is what makes that a claim rather than an alibi: the very
    same spelling on an ordinary node **is** read, and becomes a select.  So
    the lock below is the node speaking, not the parser still being blind.
    """

    ordinary = analyse(
        graph_with(PLAIN, {ARCHITECTURE: "compact", "seed": 7}),
        contract=contract((PLAIN, ARCHITECTURE, combo(*FORMS))),
    )
    assert field_named(ordinary, ARCHITECTURE).options == FORMS

    plan = analyse(
        graph_with("ExampleTextEncoderLoader"),
        contract=contract(("ExampleTextEncoderLoader", ARCHITECTURE, combo(*FORMS))),
    )

    assert plan.problems == ()
    assert ARCHITECTURE not in [item.id for item in plan.fields]
    entry = control_for(plan, "1", ARCHITECTURE)
    assert entry.section == "locked"
    assert entry.kind == LOAD_SLUG
    assert entry.field is None
    assert [
        (item.node, item.input, item.exposure, item.kind) for item in plan.not_exposed
    ] == [("1", ARCHITECTURE, "locked", LOAD_SLUG)]


def test_a_weights_file_declared_in_the_current_shape_is_locked_before_it_is_asked() -> None:
    """The ordering itself, in the new shape.

    A list of the user's own weights is a file picker whichever way it is
    spelled, and the contract must not even be consulted about it: ``LOCKED``
    has already answered.  The watcher proves the silence is about this input
    and not about every input, because it is asked -- in the same run, in the
    same shape -- about the one the graph genuinely cannot settle.
    """

    watcher = Watching(
        contract(
            ("ExampleWeightsLoader", "ckpt_name", combo("a.safetensors", "b.safetensors")),
            ("ExampleWeightsLoader", ARCHITECTURE, combo(*FORMS)),
        )
    )

    plan = analyse(
        graph_with(
            "ExampleWeightsLoader",
            {"ckpt_name": "a.safetensors", ARCHITECTURE: "compact"},
        ),
        contract=watcher,
    )

    assert ("ExampleWeightsLoader", ARCHITECTURE) in watcher.asked, (
        "the watcher was never asked anything, so its silence proves nothing"
    )
    assert ("ExampleWeightsLoader", "ckpt_name") not in watcher.asked
    # Asked first since T-0195 and declined: a choice list is not a node shape.
    assert ("ExampleWeightsLoader", "ckpt_name") in watcher.asked_structural
    assert [item.id for item in plan.fields] == ["prompt", "seed", "steps"]
    assert control_for(plan, "1", "ckpt_name").section == "locked"
    assert control_for(plan, "1", ARCHITECTURE).section == "locked"


def test_a_finite_list_of_choices_alone_is_not_what_exposes_an_input() -> None:
    """The headline question, asked as a review will ask it.

    *Can a structural model control become editable solely because the runtime
    exposes all its legal values?*  The declaration here is as good as a
    declaration gets -- a finite list, no file names in it, and the graph's own
    value among them -- and the answer is still no.
    """

    declared = contract(("ExampleWeightsLoader", ARCHITECTURE, choices(*FORMS)))
    assert declared.options_for("ExampleWeightsLoader", ARCHITECTURE) == FORMS

    plan = analyse(graph_with("ExampleWeightsLoader"), contract=declared)

    assert [item.type for item in plan.fields if item.id == ARCHITECTURE] == []
    assert control_for(plan, "1", ARCHITECTURE).section == "locked"


#: Seven ways a node's author can say "this node loads something", each spelled
#: differently on purpose.  A rule keyed on whole class-type identifiers cannot
#: pass this list, because no such list is written anywhere; a rule keyed on
#: word tokens passes all seven without knowing any of them.  The identity
#: enums beside them are the four the design names -- a checkpoint, a VAE, a
#: diffusion model and an adapter -- plus the plural, the ``Load`` prefix and a
#: node pack's underscored prefix.
LOADING_SHAPES = [
    pytest.param("ExampleTextEncoderLoader", ARCHITECTURE, id="encoder-architecture"),
    pytest.param("ExampleCheckpointLoader", "precision", id="checkpoint-precision"),
    pytest.param("ExampleVaeLoader", "reading", id="vae-reading"),
    pytest.param("ExampleDiffusionModelLoader", "weight_form", id="unet-weight-form"),
    pytest.param("ExampleAdapterLoader", "interpretation", id="lora-interpretation"),
    pytest.param("LoadExampleWeights", "precision", id="load-prefix"),
    pytest.param("Example_Pack_Loaders", "reading", id="underscored-pack-plural"),
]


@pytest.mark.parametrize("class_type,input_name", LOADING_SHAPES)
def test_every_shape_of_loading_node_locks_its_unsettled_enum(
    class_type: str, input_name: str
) -> None:
    """One rule, seven spellings, no list of names anywhere in the code.

    Each input name here is also in no vocabulary of `semantics.py`'s -- and
    that is asserted, not assumed, so a name that quietly started locking
    itself could not stand in for the judgement under test.
    """

    assert classify(input_name, "compact").exposure is Exposure.UNCERTAIN

    plan = analyse(
        graph_with(class_type, {input_name: "compact"}),
        contract=contract((class_type, input_name, choices(*FORMS))),
    )

    assert plan.problems == ()
    assert input_name not in [item.id for item in plan.fields]
    entry = control_for(plan, "1", input_name)
    assert (entry.section, entry.kind) == ("locked", LOAD_SLUG)


#: One class type per spelling in the vocabulary, **built from the vocabulary**
#: at collection time instead of written out.  Change ``LOADING_CLASS_WORDS``
#: and these change with it, which is what the seven spellings above cannot
#: say: they are a list, and a rule that carried its own list of names passes
#: them all.
DERIVED_LOADING_SHAPES = [
    pytest.param("Example{}Node".format(word.title()), id="derived-{}".format(word))
    for word in LOADING_CLASS_WORDS
]


@pytest.mark.parametrize("class_type", DERIVED_LOADING_SHAPES)
def test_a_class_type_built_from_the_vocabulary_locks(class_type: str) -> None:
    """Every spelling the vocabulary carries is a spelling that locks.

    Written as a derivation so that a spelling added to
    :data:`LOADING_CLASS_WORDS` without a test is not a thing that can happen:
    the case list is the vocabulary.
    """

    plan = analyse(
        graph_with(class_type),
        contract=contract((class_type, ARCHITECTURE, choices(*FORMS))),
    )

    assert plan.problems == ()
    entry = control_for(plan, "1", ARCHITECTURE)
    assert (entry.section, entry.kind) == ("locked", LOAD_SLUG)


def test_the_lock_follows_the_vocabulary_and_not_a_list_of_class_names(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The one thing a parametrised list of names can never establish.

    Seven spellings that lock and three that do not exclude a **substring**
    rule.  They do not exclude a rule that simply carries its own list of class
    names: a closed allowlist of every loading class name this suite writes
    down passes all of them, and that was measured -- 1423 of 1423 -- so the
    claim had to be made true rather than argued.

    It is made true by asking about a class name that exists nowhere in this
    repository.  The vocabulary is replaced with one invented word, the class
    type is built out of *that* word at the moment the test runs, and it has to
    lock; and a class type built from a word the shipped vocabulary really
    carries has to stop locking, because the vocabulary no longer carries it.
    Both halves together are what say the answer is read out of
    ``LOADING_CLASS_WORDS`` -- one alone would pass on a rule that locked
    everything or on a rule that locked nothing.
    """

    invented = "hoists"
    assert invented not in LOADING_CLASS_WORDS, "the word was not invented after all"
    monkeypatch.setattr(analysis_module, "LOADING_CLASS_WORDS", (invented,))

    patched_class = "Example{}Node".format(invented.title())
    shipped_class = "Example{}Node".format(LOADING_CLASS_WORDS[0].title())

    patched = analyse(
        graph_with(patched_class),
        contract=contract((patched_class, ARCHITECTURE, choices(*FORMS))),
    )
    shipped = analyse(
        graph_with(shipped_class),
        contract=contract((shipped_class, ARCHITECTURE, choices(*FORMS))),
    )

    entry = control_for(patched, "1", ARCHITECTURE)
    assert (entry.section, entry.kind) == ("locked", LOAD_SLUG)
    assert "carries the word {!r}:".format(invented) in entry.reason

    assert control_for(shipped, "1", ARCHITECTURE).section == "advanced"
    assert field_named(shipped, ARCHITECTURE).type == "select"


#: Class types whose **letters** contain ``load`` and whose **words** do not.
#: The mirror of `catalog.py`'s ``ExampleProvideoThing``: a substring match
#: would lock all three, and each is an ordinary node that has to keep its
#: settings.
NOT_LOADING_SHAPES = [
    pytest.param("ExamplePayloadRouter", id="payload"),
    pytest.param("ExamplePreloadedMixer", id="preloaded"),
    pytest.param("ExampleOverloadGuard", id="overload"),
]


@pytest.mark.parametrize("class_type", NOT_LOADING_SHAPES)
def test_a_class_type_that_merely_contains_the_letters_does_not_lock(
    class_type: str,
) -> None:
    """Words, never substrings -- the discipline `semantics.py` set for names.

    ``payload`` is not ``load`` any more than ``strength_model`` is ``model``,
    and a rule that could not tell them apart would take the settings off every
    node whose author happened to use one of these words.
    """

    plan = analyse(
        graph_with(class_type),
        contract=contract((class_type, ARCHITECTURE, choices(*FORMS))),
    )

    assert plan.problems == ()
    item = field_named(plan, ARCHITECTURE)
    assert (item.type, item.section, item.options) == ("select", "advanced", FORMS)


#: A version number written straight against a loading word (T-0105).  Before
#: letters and digits were split, each of these tokenised to ``loader2``,
#: ``loader3``, ``load3`` -- words no vocabulary carries -- and the node's
#: architecture enum reached the user as an editable dropdown.
DIGIT_SUFFIXED_LOADING_SHAPES = [
    pytest.param("ExampleLoader2", id="loader-2"),
    pytest.param("ExampleLoader3D", id="loader-3d"),
    pytest.param("example_loader2", id="lowercase-loader-2"),
    pytest.param("Load3DExample", id="load-3d-prefix"),
]


@pytest.mark.parametrize("class_type", DIGIT_SUFFIXED_LOADING_SHAPES)
def test_a_digit_written_against_a_loading_word_does_not_hide_it(
    class_type: str,
) -> None:
    """``Loader2`` is a loader: letters and digits are separate words."""

    plan = analyse(
        graph_with(class_type),
        contract=contract((class_type, ARCHITECTURE, choices(*FORMS))),
    )

    assert plan.problems == ()
    assert ARCHITECTURE not in [item.id for item in plan.fields]
    entry = control_for(plan, "1", ARCHITECTURE)
    assert (entry.section, entry.kind) == ("locked", LOAD_SLUG)


def test_letters_and_digits_split_into_separate_words() -> None:
    """The splitter's own answer, including the ``3D`` choice it documents."""

    assert class_words("ExampleLoader2") == {"example", "loader", "2"}
    assert class_words("ExampleLoader3D") == {"example", "loader", "3", "d"}
    assert class_words("example_loader3d") == {"example", "loader", "3", "d"}


#: The substring half has to survive the digit split: a digit beside a word
#: that merely *contains* ``load`` must not free the letters inside it.
DIGIT_SUFFIXED_NOT_LOADING_SHAPES = [
    pytest.param("ExampleDownloader2", id="downloader-2"),
    pytest.param("ExamplePayload3D", id="payload-3d"),
    pytest.param("example_preloader2", id="lowercase-preloader-2"),
]


@pytest.mark.parametrize("class_type", DIGIT_SUFFIXED_NOT_LOADING_SHAPES)
def test_a_digit_does_not_turn_a_containing_word_into_a_loading_one(
    class_type: str,
) -> None:
    plan = analyse(
        graph_with(class_type),
        contract=contract((class_type, ARCHITECTURE, choices(*FORMS))),
    )

    assert plan.problems == ()
    item = field_named(plan, ARCHITECTURE)
    assert (item.type, item.section, item.options) == ("select", "advanced", FORMS)


# ==========================================================================
# The node, never the input's name
# ==========================================================================


def test_the_same_name_and_value_on_an_ordinary_node_stays_a_select() -> None:
    """The whole of "names alone are never evidence", in one comparison.

    Same input name, same value, same declared choices; the *only* difference
    is what the node says its job is.  A rule keyed on the name ``type`` would
    lock both, and a rule that locked nothing would expose both, so this one
    test fails on either mistake.
    """

    loading = analyse(
        graph_with("ExampleTextEncoderLoader"),
        contract=contract(("ExampleTextEncoderLoader", ARCHITECTURE, choices(*FORMS))),
    )
    ordinary = analyse(
        graph_with("ExampleColourGrade"),
        contract=contract(("ExampleColourGrade", ARCHITECTURE, choices(*FORMS))),
    )

    assert control_for(loading, "1", ARCHITECTURE).kind == LOAD_SLUG
    assert ARCHITECTURE not in [item.id for item in loading.fields]

    item = field_named(ordinary, ARCHITECTURE)
    assert (item.type, item.section, item.default) == ("select", "advanced", "compact")
    assert control_for(ordinary, "1", ARCHITECTURE).kind is None


def test_an_input_named_nothing_like_a_type_locks_on_a_loading_node_too() -> None:
    """The other direction: the name is not consulted at all.

    A rule that had quietly grown a list of "structural-sounding" names --
    ``type``, ``mode``, ``model`` -- would pass every test above and fail this
    one, because ``finish`` sounds like a tunable and is on a node that loads.
    """

    assert classify("finish", "compact").exposure is Exposure.UNCERTAIN

    plan = analyse(
        graph_with("ExampleWeightsLoader", {"finish": "compact"}),
        contract=contract(("ExampleWeightsLoader", "finish", choices(*FORMS))),
    )

    assert control_for(plan, "1", "finish").kind == LOAD_SLUG


# ==========================================================================
# T-0070 is not quietly undone: a safe enum on an ordinary node
# ==========================================================================

#: Two real shapes from the measured catalogue, with the vendor's name taken
#: out: a workflow-specific quality preset on an effects node, and a strength
#: mode on an adapter node.  Both are settings a person may genuinely change,
#: both are what T-0070 was built to deliver, and neither node loads anything.
SAFE_ENUMS = [
    pytest.param("ExampleFrameRestore", "preset", id="preset-on-an-effect"),
    pytest.param("ExampleAdapterAdvanced", "embeds_scaling", id="scaling-on-an-adapter"),
]


@pytest.mark.parametrize("class_type,input_name", SAFE_ENUMS)
def test_a_safe_enum_on_an_ordinary_node_is_still_an_advanced_select(
    class_type: str, input_name: str
) -> None:
    """What this card must leave exactly as it found it.

    Widen the judgement to every node -- the obvious way to write it wrong --
    and both of these lock, the user loses two working controls and the report
    says a settings dropdown is structural.
    """

    plan = analyse(
        graph_with(class_type, {input_name: "compact"}),
        contract=contract((class_type, input_name, choices(*FORMS))),
    )

    assert plan.problems == ()
    item = field_named(plan, input_name)
    assert item.type == "select"
    assert item.section == "advanced"
    assert item.options == FORMS
    assert item.default == "compact"
    assert control_for(plan, "1", input_name).section == "advanced"


# ==========================================================================
# What the judgement cannot reach at all
# ==========================================================================


def test_a_sampler_and_a_scheduler_are_never_put_to_the_contract() -> None:
    """The two controls a person actually tunes, and the reason they are safe.

    ``sampler_name`` and ``scheduler`` are ``SAFE_STRING_WORDS``, so ``classify``
    answers ``EXPOSE`` and the ``UNCERTAIN`` branch -- the only branch either
    the contract's choice lists or this card's judgement lives in -- is never
    entered for them.  The watcher proves it by being asked about the loading
    node's input in the very same graph, so its silence about these two is a
    measurement and not an empty list.  (The node-shape table is asked about
    them, before ``classify``, since T-0195; it declines, and it could only
    ever have locked them.)
    """

    tuned = graph_with("ExampleTextEncoderLoader")
    tuned["3"]["inputs"]["sampler_name"] = "steady_pace"
    tuned["3"]["inputs"]["scheduler"] = "even_steps"
    watcher = Watching(
        contract(
            ("ExampleTextEncoderLoader", ARCHITECTURE, choices(*FORMS)),
            (PLAIN, "sampler_name", choices("steady_pace", "other_pace")),
            (PLAIN, "scheduler", choices("even_steps", "front_loaded")),
        )
    )

    plan = analyse(tuned, contract=watcher)

    assert ("ExampleTextEncoderLoader", ARCHITECTURE) in watcher.asked, (
        "the watcher was never asked anything, so its silence proves nothing"
    )
    assert (PLAIN, "sampler_name") not in watcher.asked
    assert (PLAIN, "scheduler") not in watcher.asked
    # Asked first since T-0195 and declined: a choice list is not a node shape.
    assert (PLAIN, "sampler_name") in watcher.asked_structural
    assert (PLAIN, "scheduler") in watcher.asked_structural
    for input_name in ("sampler_name", "scheduler"):
        item = field_named(plan, input_name)
        assert item.type == "string"
        assert item.options == ()
        assert control_for(plan, "3", input_name).kind is None


def test_a_sampler_and_a_scheduler_on_a_loading_node_are_still_editable() -> None:
    """The stronger form: put them where the judgement lives and it still cannot see them.

    A ``LOCKED`` verdict and an ``EXPOSE`` verdict both skip the branch the
    judgement is in, so moving these two onto the loading node itself changes
    nothing about them.  Move the judgement earlier -- before ``classify``, or
    over every input of a loading node -- and this is the test that fails.
    """

    plan = analyse(
        graph_with(
            "ExampleTextEncoderLoader",
            {
                ARCHITECTURE: "compact",
                "sampler_name": "steady_pace",
                "scheduler": "even_steps",
            },
        ),
        contract=contract(("ExampleTextEncoderLoader", ARCHITECTURE, choices(*FORMS))),
    )

    assert plan.problems == ()
    assert [item.id for item in plan.fields] == [
        "prompt",
        "sampler_name",
        "scheduler",
        "seed",
        "steps",
    ]
    assert control_for(plan, "1", ARCHITECTURE).kind == LOAD_SLUG


def test_a_device_control_is_still_machine_setting_and_not_this_cards_slug() -> None:
    """The regression half of the criterion: it was already locked, and by whom.

    ``device``, ``provider`` and ``backend`` are ``LOCKED_ANY_WORDS``, so they
    lock at ``classify`` whatever node they are on and whatever a runtime
    declares for them.  Asserting only "locked" would pass if this card had
    taken the judgement over; the slug is what says which rule still owns it,
    and the watcher says the contract was not asked about them at all.
    """

    watcher = Watching(
        contract(
            ("ExampleTextEncoderLoader", ARCHITECTURE, choices(*FORMS)),
            ("ExampleColourGrade", "device", choices("first", "second")),
            ("ExampleColourGrade", "provider", choices("one", "two")),
            ("ExampleColourGrade", "backend", choices("here", "there")),
        )
    )
    both = graph_with("ExampleTextEncoderLoader")
    both["4"] = {
        "class_type": "ExampleColourGrade",
        "inputs": {
            "device": "first",
            "provider": "one",
            "backend": "here",
            "image": ["3", 0],
        },
    }

    plan = analyse(both, contract=watcher)

    for input_name in ("device", "provider", "backend"):
        entry = control_for(plan, "4", input_name)
        assert entry.section == "locked"
        assert entry.kind == "machine_setting"
        assert ("ExampleColourGrade", input_name) not in watcher.asked
        # Asked first since T-0195 and declined: a choice list is not a shape.
        assert ("ExampleColourGrade", input_name) in watcher.asked_structural
    assert ("ExampleTextEncoderLoader", ARCHITECTURE) in watcher.asked


def test_a_number_a_flag_a_prompt_and_a_picture_on_a_loading_node_are_untouched() -> None:
    """A loading node's genuine controls, including T-0098's declared float.

    Every one of these is settled by `semantics.py`, so none of them enters the
    branch the judgement is in.  The float is here because it is the newest and
    the least obvious: T-0098 made a number's *type* come from the runtime, and
    that lookup happens after this card's branch and must be unaffected by it.
    """

    plan = analyse(
        graph_with(
            "ExampleTextEncoderLoader",
            {
                ARCHITECTURE: "compact",
                "strength": 1,
                "tiled": True,
                "caption": "a quiet street at dawn",
                "image": "photo.png",
            },
        ),
        contract=contract(
            ("ExampleTextEncoderLoader", ARCHITECTURE, choices(*FORMS)),
            ("ExampleTextEncoderLoader", "strength", ["FLOAT", {"min": 0, "max": 2.0}]),
        ),
    )

    assert plan.problems == ()
    # Looked up by the input each field binds rather than by its id: the id is
    # the role the wiring proves -- a caption consumed as conditioning is
    # ``prompt`` -- and what is under test here is which *inputs of the loading
    # node* still reach a user, not what they ended up called.
    bound = {target: item for item in plan.fields for target in item.targets}
    assert bound[("1", "strength")].type == "float"
    assert bound[("1", "strength")].maximum == 2.0
    assert bound[("1", "tiled")].type == "boolean"
    assert bound[("1", "caption")].translatable is True
    assert bound[("1", "image")].type == "image"
    assert ("1", ARCHITECTURE) not in bound
    assert control_for(plan, "1", ARCHITECTURE).kind == LOAD_SLUG


# ==========================================================================
# It gates the upgrade and nothing else
# ==========================================================================


def test_the_same_input_with_no_runtime_to_ask_is_review_exactly_as_before() -> None:
    """Locking may not take a workflow out of ``NEEDS_REVIEW`` either.

    Without a declaration nobody knows what this input is -- not `semantics.py`
    and not this card -- and "look at it and decide" is the answer T-0072 chose
    over a silent guess.  A judgement placed before the contract instead of
    over its answer would pass every test above and silently import this.
    """

    plan = analyse(graph_with("ExampleTextEncoderLoader"))

    assert plan.needs_review
    assert plan.fields == ()
    assert repr(ARCHITECTURE) in problem_about(plan, ARCHITECTURE)
    assert control_for(plan, "1", ARCHITECTURE).section == "needs_review"
    assert control_for(plan, "1", ARCHITECTURE).kind is None


def test_a_value_the_runtime_does_not_offer_is_still_review_on_a_loading_node() -> None:
    """A graph saved against a different build of that node is still a question.

    Nothing is locked away here and nothing is substituted: the value in the
    file disagrees with the runtime, and that is a fact a curator has to see
    whatever kind of node it is on.
    """

    plan = analyse(
        graph_with("ExampleTextEncoderLoader", {ARCHITECTURE: "from-an-older-node"}),
        contract=contract(("ExampleTextEncoderLoader", ARCHITECTURE, choices(*FORMS))),
    )

    assert plan.needs_review
    said = problem_about(plan, ARCHITECTURE)
    assert "'from-an-older-node'" in said
    assert "does not offer" in said
    assert control_for(plan, "1", ARCHITECTURE).section == "needs_review"


def test_a_declared_list_of_file_names_on_a_loading_node_is_still_a_refusal() -> None:
    """The two rules meet, and the older one answers first.

    A list of the user's own files is refused and counted as a refusal, which
    is what tells a curator "the picker rule is working" apart from "this
    ComfyUI declared nothing".  Locking it instead would lose that number and
    would quietly import a workflow that used to be held.
    """

    plan = analyse(
        graph_with("ExampleTextEncoderLoader"),
        contract=contract(
            (
                "ExampleTextEncoderLoader",
                ARCHITECTURE,
                choices("compact", "chosen-weights.safetensors"),
            )
        ),
    )

    assert plan.needs_review
    assert plan.refused_as_file_names == (("1", ARCHITECTURE),)
    assert "list of file names" in problem_about(plan, ARCHITECTURE)
    assert control_for(plan, "1", ARCHITECTURE).section == "needs_review"


# ==========================================================================
# A lock nobody can see is the defect T-0069 fixed
# ==========================================================================


def test_the_locked_control_is_visible_with_a_reason_and_a_slug() -> None:
    """What a curator reads, asserted verbatim rather than counted.

    The sentence has to name the input and the evidence -- the word in the
    node's own class type -- because "locked" without a why is the silence
    T-0069 was raised to end.  The slug is what groups thirty workflows' worth
    of these together in a report.
    """

    plan = analyse(
        graph_with("ExampleTextEncoderLoader"),
        contract=contract(("ExampleTextEncoderLoader", ARCHITECTURE, choices(*FORMS))),
    )

    entry = control_for(plan, "1", ARCHITECTURE)
    assert entry.reason == (
        "input 'type' is one nothing in the graph settles, on a node whose "
        "class type carries the word 'loader': what a loading node's "
        "unrecognised inputs describe is what is being loaded and how it is "
        "interpreted, not how the picture is generated. Knowing every value it "
        "accepts is not permission to change it."
    )
    assert entry.kind == LOAD_SLUG
    assert entry.kind in LOCKED_KINDS
    assert plan.not_exposed[0].reason == entry.reason


def test_the_reason_names_the_first_spelling_of_the_vocabulary_it_matched(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Which spelling the sentence names is read out of the tuple's order.

    A class type can carry more than one of the spellings, so *which one the
    sentence names* is a choice, and it is taken from
    :data:`LOADING_CLASS_WORDS` in that tuple's own order -- a property of a
    line of source rather than of a set's iteration, which Python randomises
    per process.

    Asserting only that the answer is ``'load'`` would not say that.  The
    shipped tuple happens to be alphabetical, so ``min()`` over a set of the
    matches gives the same answer for every possible input, and a suite that
    checked one order could not tell the two apart.  So the vocabulary is
    **reordered** and the sentence has to follow: correct code names
    ``'loaders'`` under the patch and ``'load'`` without it, while anything
    that sorts, or that takes whatever a set hands over, cannot do both.
    """

    class_type = "Example_Loaders_Load"
    assert {"load", "loaders"} <= class_words(class_type)
    assert LOADING_CLASS_WORDS.index("load") < LOADING_CLASS_WORDS.index("loaders")

    declared = contract((class_type, ARCHITECTURE, choices(*FORMS)))
    plan = analyse(graph_with(class_type), contract=declared)

    said = control_for(plan, "1", ARCHITECTURE).reason
    assert "carries the word 'load':" in said
    assert "loaders" not in said

    monkeypatch.setattr(
        analysis_module, "LOADING_CLASS_WORDS", ("loaders", "loader", "load")
    )
    reordered = analyse(graph_with(class_type), contract=declared)

    also_said = control_for(reordered, "1", ARCHITECTURE).reason
    assert "carries the word 'loaders':" in also_said
    assert control_for(reordered, "1", ARCHITECTURE).kind == LOAD_SLUG


def test_the_reason_repeats_none_of_the_declared_choices_back() -> None:
    """Somebody's installed vocabulary is theirs, including in a refusal.

    A report crosses a pipe, is rendered by a script and gets pasted into an
    issue.  Naming the choices would also be this module taking an interest in
    what they are, which is the one thing it may never do.
    """

    plan = analyse(
        graph_with("ExampleTextEncoderLoader"),
        contract=contract(("ExampleTextEncoderLoader", ARCHITECTURE, choices(*FORMS))),
    )

    said = control_for(plan, "1", ARCHITECTURE).reason
    for form in FORMS:
        assert form not in said, "a declared choice reached the report"


def test_the_locked_input_is_never_a_bind_target_of_the_definition() -> None:
    """Reporting a control is not exposing it.

    The definition the app receives is written from the same plan, and the
    ``(node, input)`` the inventory calls locked must appear in none of its
    ``bind`` lists -- otherwise the dropdown is gone from the form and the
    value is still writable through the field it hid behind.
    """

    plan = analyse(
        graph_with("ExampleTextEncoderLoader"),
        contract=contract(("ExampleTextEncoderLoader", ARCHITECTURE, choices(*FORMS))),
    )
    document = definition_document(
        plan, workflow_id="one", name="One", workflow_relative="../g.json"
    )

    bound = {
        (target["node"], target["input"])
        for item in document["inputs"]
        for target in item["bind"]
    }
    assert bound, "the definition binds nothing, so the absence below is empty"
    assert ("1", ARCHITECTURE) not in bound


# ==========================================================================
# Ids: locking moves none of them, and none of them comes from the list
# ==========================================================================


def test_locking_moves_no_other_field_id_and_none_depends_on_the_choice() -> None:
    """The keys a user's defaults, drafts and saved setups hang off.

    Three graphs: the loading node with the value it was saved with, the same
    with a different declared value, and the same with the runtime's list in
    the opposite order.  Every id is written out verbatim -- a count would pass
    on three different sets of the same size.
    """

    expected = ["prompt", "seed", "steps"]
    declared = contract(("ExampleTextEncoderLoader", ARCHITECTURE, choices(*FORMS)))
    reordered = contract(
        ("ExampleTextEncoderLoader", ARCHITECTURE, choices(*reversed(FORMS)))
    )

    first = analyse(graph_with("ExampleTextEncoderLoader"), contract=declared)
    other_value = analyse(
        graph_with("ExampleTextEncoderLoader", {ARCHITECTURE: "layered"}),
        contract=declared,
    )
    other_order = analyse(graph_with("ExampleTextEncoderLoader"), contract=reordered)

    assert [item.id for item in first.fields] == expected
    assert [item.id for item in other_value.fields] == expected
    assert [item.id for item in other_order.fields] == expected
    assert declared.options_for("ExampleTextEncoderLoader", ARCHITECTURE) != (
        reordered.options_for("ExampleTextEncoderLoader", ARCHITECTURE)
    ), "the two declarations are in the same order, so nothing was reordered"


def test_a_neighbouring_selects_id_survives_the_lock_beside_it() -> None:
    """The select on the ordinary node keeps the id it had before this card.

    Written out, because this is the id a saved setup is keyed on: a lock that
    changed the grouping of the inputs around it would move it silently.
    """

    beside = graph_with("ExampleTextEncoderLoader")
    beside["3"]["inputs"]["preset"] = "compact"

    plan = analyse(
        beside,
        contract=contract(
            ("ExampleTextEncoderLoader", ARCHITECTURE, choices(*FORMS)),
            (PLAIN, "preset", choices(*FORMS)),
        ),
    )

    assert [item.id for item in plan.fields] == ["prompt", "preset", "seed", "steps"]
    assert field_named(plan, "preset").targets == (("3", "preset"),)


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


def test_a_whole_run_imports_the_workflow_and_hides_the_structural_control(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The seam a curator actually reads, through the loader the gateway runs.

    The workflow imports -- locking a control never holds one back -- the
    definition the real registry loader accepts carries no ``type`` field, and
    the run's own report says one input was locked.
    """

    with FakeComfy() as comfy:
        comfy.installed_nodes = ("ExampleTextEncoderLoader",)
        comfy.node_inputs = {
            "ExampleTextEncoderLoader": {ARCHITECTURE: choices(*FORMS)}
        }
        report = run_against(
            workspace,
            tmp_path,
            monkeypatch,
            comfy,
            graph_with("ExampleTextEncoderLoader"),
        )

    item = report.workflows[0]
    assert item.state.value == "NEW", item.reason

    registry = load_registry(workspace.repo / "config" / "local" / "workflows")
    assert list(registry.diagnostics) == []
    definition = registry.workflows[0]
    assert [entry.id for entry in definition.inputs] == ["prompt", "seed", "steps"]

    document = report_document(report)
    assert document["runtime_contract"] == {
        "declared": 1,
        "fields": 0,
        "refused_as_file_names": 0,
    }
