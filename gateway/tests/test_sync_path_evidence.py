"""A separator is not evidence that a string is a path (T-0095).

`looks_like_a_path` used to answer yes to any string carrying a ``/`` or a
``\\``.  Two things followed from that, and the second is much the worse:

* a genuine settings dropdown whose options read ``K+V w/ C penalty`` -- ``w/``
  being how English abbreviates *with* -- was refused as a list of file names,
  and its workflow stayed ``NEEDS_REVIEW``.  That is the defect the card was
  filed for;
* **a prompt containing a slash was locked away as a filesystem path.**
  ``portrait of a woman, 3/4 view`` and ``cinematic, 16/9`` are ordinary
  prompts, and the most important field in an image workflow silently
  disappeared from the app while the workflow still imported, so nothing
  reported it.  That is the defect the card *found*, and the test named for it
  below is the highest-value guard in this file.

This is one lesson arriving a third time.  A ``.png`` suffix was not evidence
that a string is media (T-0072); a media word in a name was not evidence
without the value bearing it out (T-0080); a separator is not evidence of a
path.  What is asserted here is therefore a **property** and never a
vocabulary: no test below turns on the word ``w/``, on the name of any input
observed anywhere, or on any node class that exists.

Four things are held here, in the order they matter:

* the truth table, verbatim and in both directions -- every shape that is
  still a path, and every shape that has stopped being one;
* **each clause of the rule fails a test of its own.**  Five clauses, five
  cases no other clause can answer for, so none of them can be deleted with
  the suite still green;
* a whole-decision **differential** against the rule this card replaced, over
  a generated grid, carrying the invariant as corrected in design: *nothing
  path-shaped stops being locked*;
* the two ends of the card in one piece each -- a prompt with a slash reaches
  the user, and an option set of ordinary words reaches them as a ``select``
  through the real contract path, while a loader's dropdown stays locked
  although its choices parse perfectly well.

The one thing quoted from outside this file is :data:`REAL_OPTION_SET`: four
option strings a ComfyUI declares through its public ``/object_info``.  They
are the evidence the card was filed on, they name no model, no family and no
custom node, and they are here as a fixture and never as a case in the code.
"""

from __future__ import annotations

import dataclasses
import re
from typing import Any, Dict, List, Optional, Tuple

import pytest

from localcanvas_gateway.workflows.sync import analyse, semantics
from localcanvas_gateway.workflows.sync.analysis import SELECT_FIELD_TYPE
from localcanvas_gateway.workflows.sync.contract import (
    RuntimeContract,
    names_files,
    read_object_info,
)
from localcanvas_gateway.workflows.sync.semantics import (
    Exposure,
    Verdict,
    classify,
    looks_like_a_file_name,
    looks_like_a_path,
)

# --------------------------------------------------------------------------
# The rule this card replaced
# --------------------------------------------------------------------------

#: The Windows-path pattern as `main` had it before this card, written out
#: here rather than imported: the module's own patterns are what this card
#: changes, so a differential that read one of them would quietly move with
#: the rule it is supposed to be measuring.
_WINDOWS_PATH_BEFORE_T0095 = re.compile(r"^(?:[A-Za-z]:[\\/]|\\\\)")


#: `looks_like_a_path` exactly as it stood before T-0095, kept so that the
#: differential below is a real before-and-after and not a description of one.
#: A test that asserted "the new rule refuses this" without the old rule in
#: the room would pass just as well on a rule that had always refused it.
def rule_before_t0095(value: str) -> bool:
    return (
        "/" in value
        or "\\" in value
        or value.startswith("~")
        or bool(_WINDOWS_PATH_BEFORE_T0095.match(value))
    )


# --------------------------------------------------------------------------
# The truth table, verbatim, in both directions
# --------------------------------------------------------------------------

#: Strings that name a place on a disk.  Every one of them was a path before
#: this card and has to stay one: weakening a lock is the way this change
#: could do damage, and this list is the wall against it.
#:
#: **Both kinds of machine are in it, deliberately.**  Most ComfyUI
#: installations are not on Windows, and a first version of this table held
#: only drive letters and backslash UNC -- so a rule that had quietly stopped
#: recognising ``/home/u/ComfyUI/models`` and ``//nas/models`` passed every
#: test here.  The gap was as much in the data as in the rule.
STILL_A_PATH: Tuple[str, ...] = (
    # a drive, either slash direction, either case
    "C:\\models\\foo.safetensors",
    "C:/models/foo.safetensors",
    "c:/models/foo.safetensors",
    "C:\\models\\checkpoints",
    # a root, on the machines most ComfyUI installations run on
    "/home/u/ComfyUI/models",
    "/workspace",
    "/mnt/models/loras",
    # a UNC host, spelled either way
    "\\\\server\\share\\model.bin",
    "\\\\server\\share",
    "//nas/models/loras",
    "//server/share/models",
    # the root of the current drive
    "\\models\\loras",
    # a home
    "~/loras/study.safetensors",
    "~/models/checkpoints",
    # an explicit relative prefix
    "./input/reference.png",
    "../models/foo.bin",
    # un-rooted, and carrying a file name
    "models/checkpoints/foo.safetensors",
    "portraits/photo.png",
)

#: Strings that carry a separator and are not paths.  A slash inside ordinary
#: text proves nothing -- it abbreviates a word, separates a pair, names a
#: ratio or writes a MIME type.
NO_LONGER_A_PATH: Tuple[str, ...] = (
    "K+V w/ C penalty",
    "K+mean(V) w/ C penalty",
    "input/output",
    "before/after",
    "A/B test",
    "high/low",
    "image/gif",
    "16/9",
    "and/or",
    "models/checkpoints",
    "characters/other",
    # A trailing separator is not a fifth kind of evidence, by decision:
    # `looks_like_a_file_name` already puts a directory written that way out
    # of scope, and `output` is in LOCKED_STRING_WORDS, so an input holding
    # this is locked by its **name** before its value is ever consulted --
    # asserted below rather than left as a remark.
    "output/",
)

#: Strings with no separator in them at all.  Here because the rule's last
#: clause is a conjunction, and dropping the separator half of it would make
#: every ordinary file name a path -- the overcorrection in the *other*
#: direction, and the one no weak-evidence case can catch.
NOT_A_PATH_AND_NEVER_WAS: Tuple[str, ...] = (
    "photo.png",
    "foo.safetensors",
    "plain",
    "1.5",
    "v1.5.2",
    "",
)


@pytest.mark.parametrize("value", STILL_A_PATH)
def test_a_string_that_names_a_place_on_a_disk_is_still_a_path(value: str) -> None:
    assert looks_like_a_path(value) is True


@pytest.mark.parametrize("value", NO_LONGER_A_PATH)
def test_a_separator_inside_ordinary_text_is_not_a_path(value: str) -> None:
    assert looks_like_a_path(value) is False


@pytest.mark.parametrize("value", NOT_A_PATH_AND_NEVER_WAS)
def test_a_string_with_no_separator_is_not_a_path(value: str) -> None:
    assert looks_like_a_path(value) is False


def test_the_two_directions_are_a_change_and_not_a_description_of_one() -> None:
    """The weak column has to have *moved*, or the table above proves nothing.

    An assertion that ``'K+V w/ C penalty'`` is not a path would pass just as
    happily against a rule that never called it one.  What makes the table
    evidence is that the rule this card replaced disagreed with every entry in
    the weak column and agreed with every entry in the strong one.
    """

    assert [value for value in NO_LONGER_A_PATH if not rule_before_t0095(value)] == []
    assert [value for value in STILL_A_PATH if not rule_before_t0095(value)] == []
    assert [value for value in NOT_A_PATH_AND_NEVER_WAS if rule_before_t0095(value)] == []


# --------------------------------------------------------------------------
# Each clause fails a test of its own
# --------------------------------------------------------------------------
#
# Four clauses answer for four different kinds of evidence.  Each test below
# carries a value that only its own clause can answer for -- which is what
# stops any one of them being deleted with the suite still green, and it is
# the finding this phase has now made four times.


def _no_drive(value: str) -> None:
    assert semantics._DRIVE_PATH.match(value) is None, "a drive could have answered"


def _no_leading_separator(value: str) -> None:
    assert not value.startswith(("/", "\\")), "a leading separator could have answered"


def _no_home(value: str) -> None:
    assert not value.startswith("~"), "a home could have answered"


def _no_explicit_relative(value: str) -> None:
    assert not value.startswith("./"), "an explicit relative could have answered"
    assert not value.startswith("../"), "an explicit relative could have answered"


def _no_file_name(value: str) -> None:
    assert looks_like_a_file_name(value) is False, "a file name could have answered"


@pytest.mark.parametrize(
    "value",
    [
        pytest.param("C:\\models\\checkpoints", id="backslashes"),
        pytest.param("C:/models/checkpoints", id="forward slashes"),
        pytest.param("c:/models/checkpoints", id="lower case"),
    ],
)
def test_a_drive_is_evidence_although_nothing_after_it_looks_like_a_file(
    value: str,
) -> None:
    """Delete the drive clause and this is what fails.

    A drive letter is the one root that does **not** begin with a separator,
    which is why it needs a clause of its own.  Nothing here has an extension,
    so the file-name clause answers no; nothing starts with a separator, with
    ``~`` or with an explicit ``./``.
    """

    _no_leading_separator(value)
    _no_home(value)
    _no_explicit_relative(value)
    _no_file_name(value)
    assert looks_like_a_path(value) is True


@pytest.mark.parametrize(
    "value",
    [
        pytest.param("/home/u/ComfyUI/models", id="an absolute path, not Windows"),
        pytest.param("/workspace", id="an absolute path of one component"),
        pytest.param("/mnt/models/loras", id="a mounted volume"),
        pytest.param("//nas/models/loras", id="a UNC host, forward slashes"),
        pytest.param("\\\\server\\share", id="a UNC host, backslashes"),
        pytest.param("\\models\\loras", id="the root of the current drive"),
    ],
)
def test_a_leading_separator_is_evidence_whichever_machine_wrote_it(
    value: str,
) -> None:
    """Delete the leading-separator clause and this is what fails.

    This clause is the review finding of round 1 in one line.  The rule knew
    only a drive letter and a backslash UNC host, so every root a Linux or
    macOS ComfyUI writes stopped being a path -- and an ``/object_info``
    option list of that machine's own folders stopped being refused as a file
    picker, becoming an editable dropdown of somebody's directory names in the
    app.  Most ComfyUI installations are not on Windows.

    None of these has an extension, a drive letter, a ``~`` or an explicit
    ``./``, so the leading separator is the only thing that can be speaking.
    """

    _no_drive(value)
    _no_home(value)
    _no_explicit_relative(value)
    _no_file_name(value)
    assert looks_like_a_path(value) is True


def test_the_leading_separator_clause_refuses_nothing_it_should_not() -> None:
    """The other half of that clause: it costs the card's unlock nothing.

    A root is a *leading* separator and never one in the middle, so nothing in
    the weak column moves.  Asserted over the whole column rather than by
    example, because the risk of adding a clause is that it takes something
    back.
    """

    assert [value for value in NO_LONGER_A_PATH if value.startswith(("/", "\\"))] == []
    assert [value for value in NO_LONGER_A_PATH if looks_like_a_path(value)] == []


def test_a_home_is_evidence_although_nothing_after_it_looks_like_a_file() -> None:
    """Delete the ``~`` clause and this is what fails."""

    value = "~/models/checkpoints"

    _no_drive(value)
    _no_leading_separator(value)
    _no_explicit_relative(value)
    _no_file_name(value)
    assert looks_like_a_path(value) is True


@pytest.mark.parametrize(
    "value",
    [
        pytest.param("./output", id="here"),
        pytest.param("../output", id="one up"),
        pytest.param(".\\output", id="here, on the other kind of machine"),
    ],
)
def test_an_explicit_relative_prefix_is_evidence_on_its_own(value: str) -> None:
    """Delete the ``./`` clause and this is what fails.

    Spelling out where something is reached from is a statement about a
    filesystem even when the tail is a bare word, and no other clause here can
    see it: there is no root, no home, and ``output`` is not a file name.
    """

    _no_drive(value)
    _no_leading_separator(value)
    _no_home(value)
    _no_file_name(value)
    assert looks_like_a_path(value) is True


def test_a_separator_whose_last_part_is_a_file_name_is_evidence() -> None:
    """Delete the file-name clause and this is what fails.

    The un-rooted case, which is the commonest real one: no drive, no home, no
    explicit ``./``, and what makes it a path is that the last component is
    shaped like the name of a file.
    """

    value = "models/checkpoints/foo.safetensors"

    _no_drive(value)
    _no_leading_separator(value)
    _no_home(value)
    _no_explicit_relative(value)
    assert looks_like_a_file_name(value) is True
    assert looks_like_a_path(value) is True


def test_a_bare_file_name_with_no_separator_is_not_a_path() -> None:
    """The other half of that clause, and the guard on its conjunction.

    ``looks_like_a_file_name`` is true of ``photo.png`` all by itself.  Drop
    the separator from the last clause and every ordinary file name in every
    graph becomes a place on a disk -- an overcorrection no weak-evidence case
    could catch, because the weak cases all *have* separators.
    """

    assert looks_like_a_file_name("photo.png") is True
    assert looks_like_a_path("photo.png") is False


def test_an_unrooted_directory_with_no_file_component_is_no_longer_a_path() -> None:
    """The behaviour this card gives up, said out loud rather than discovered.

    ``models/checkpoints`` names a folder and nothing in the string says so.
    A trailing separator is not a fifth kind of evidence either: ``output/``
    stays in this bucket by decision, because it is marginal evidence and
    because the name is already doing the work.

    It is given up knowingly, and what catches such an input instead is
    asserted here beside the value so the two cannot drift apart: the words
    are in :data:`LOCKED_STRING_WORDS`, and an input carrying one of them is
    locked whatever it holds.  A rooted directory is untouched by any of this
    -- ``/mnt/models`` is still a path on its value alone.
    """

    assert looks_like_a_path("models/checkpoints") is False
    assert looks_like_a_path("output/") is False
    assert {"path", "dir", "folder", "output"} <= semantics.LOCKED_STRING_WORDS
    assert classify("output_dir", "models/checkpoints").exposure is Exposure.LOCKED
    assert classify("model_path", "models/checkpoints").exposure is Exposure.LOCKED
    assert classify("output_dir", "output/").exposure is Exposure.LOCKED
    assert looks_like_a_path("/mnt/models") is True


# --------------------------------------------------------------------------
# The prompt box that silently disappeared
# --------------------------------------------------------------------------

#: Prompts a person actually writes.  Every one of them was ``LOCKED`` as a
#: filesystem path before this card, so every one of them was a prompt box
#: missing from the app of a workflow that imported without complaint.
REAL_PROMPTS: Tuple[str, ...] = (
    "portrait of a woman, 3/4 view, soft rim light",
    "cinematic, 16/9, shallow depth of field",
    "a quiet street at dawn, high/low key lighting",
    "a cat w/ a hat",
)


def _without_reason(verdict: Verdict) -> Verdict:
    """A verdict with its sentence removed, so the rest can be asserted whole.

    The sentence is prose composed for a curator's terminal; everything else
    is the decision.  Comparing the decision entire is what makes this a test
    of a verdict rather than of one field of one.
    """

    return dataclasses.replace(verdict, reason="")


@pytest.mark.parametrize("text", REAL_PROMPTS)
@pytest.mark.parametrize("name", ["text", "prompt"])
def test_a_prompt_containing_a_slash_reaches_the_user_as_a_prompt(
    name: str, text: str
) -> None:
    """The defect this card found, and the guard that stops it coming back.

    A prompt is the one field an image workflow cannot do without, and before
    T-0095 any prompt carrying a slash was locked away as a path: no field, no
    complaint, and a workflow that still imported.  Asserted as a **whole
    verdict** -- exposure, field type, id stem, translatability and the
    absence of every other claim -- because "it is not locked any more" would
    pass on a verdict that had turned it into something else again.

    Reinstate any rule that reads a bare separator as a path and this is the
    test that fails.
    """

    verdict = classify(name, text)

    assert _without_reason(verdict) == Verdict(
        Exposure.EXPOSE,
        "",
        field_type="multiline",
        role=name,
        prompt=True,
    )
    assert "own language" in verdict.reason, "a different branch answered"
    assert rule_before_t0095(text) is True, (
        "this prompt was not locked before the card, so it guards nothing"
    )


def test_a_prompt_containing_a_slash_reaches_the_app_as_a_field() -> None:
    """The same claim one level up: it is a field of the imported workflow.

    A verdict is the judgement; this is the plan a user's app is built from.
    Both are asserted because the field could be lost between them, and a
    missing prompt box is what the user actually experiences.

    The id is ``prompt`` and not ``text``: the graph has one piece of prose in
    it and `analysis.py` reads its part from the wiring, which is exactly the
    division of labour the two modules are built around.  It is asserted as
    the graph produces it, not as `semantics.py` proposed it.
    """

    plan = analyse(
        {
            "1": {
                "class_type": "ExampleTextEncode",
                "inputs": {"text": "portrait of a woman, 3/4 view, soft rim light"},
            }
        }
    )

    assert [item.id for item in plan.fields] == ["prompt"]
    field = plan.fields[0]
    assert field.type == "multiline"
    assert field.section == "main"
    assert field.default == "portrait of a woman, 3/4 view, soft rim light"
    assert plan.needs_review is False


def test_a_prompt_holding_a_real_path_is_still_locked() -> None:
    """The lock the test above must not have taken with it.

    The prompt rule sits *after* the path rule, so an input named ``text``
    that genuinely holds a place on a disk is still refused -- what changed is
    only what counts as evidence of one.

    None of these ends in a weights suffix, deliberately: rule 2 would answer
    first and this would then be a test of that rule instead, passing however
    the path rule behaved.
    """

    for value in (
        "C:/models/checkpoints",
        "~/models/checkpoints",
        "./output",
        "portraits/photo.png",
    ):
        verdict = classify("text", value)
        assert verdict.exposure is Exposure.LOCKED, value
        assert verdict.kind == semantics.LOCKED_FILESYSTEM_PATH, value


# --------------------------------------------------------------------------
# What must not move
# --------------------------------------------------------------------------


def test_a_suffix_still_does_not_make_a_string_media() -> None:
    """T-0072, unregressed.

    ``out.png`` on an input whose name says nothing about media is not a
    picture a user uploads, and this card gave the path rule no new way to
    make it one.  Asserted as a whole verdict: what it must be is
    ``UNCERTAIN``, holding no media kind and no field type at all.
    """

    verdict = classify("prefix", "out.png")

    assert _without_reason(verdict) == Verdict(Exposure.UNCERTAIN, "")
    assert verdict.media is None


def test_a_picture_in_its_own_subfolder_is_still_a_picture() -> None:
    """The ordering the design says must not move, held as a whole verdict.

    ComfyUI writes a picture's own subfolder into a loader input, so the media
    question is asked *before* anything about the shape of the string.  The
    value here is path-shaped under the new rule as well -- the last component
    is a file name -- which is exactly why the ordering and not the rule is
    what keeps this a picture.
    """

    assert looks_like_a_path("subfolder/photo.png") is True

    verdict = classify("image", "subfolder/photo.png")

    assert _without_reason(verdict) == Verdict(
        Exposure.EXPOSE,
        "",
        field_type="image",
        role="image",
        media="image",
    )


# --------------------------------------------------------------------------
# The differential: nothing path-shaped stops being locked
# --------------------------------------------------------------------------

#: One input name from each family the vocabulary knows, so that the grid
#: covers every route out of :func:`classify` rather than the one route the
#: card was filed about.
GRID_NAMES: Tuple[str, ...] = (
    "mixing",           # nothing recognises it
    "style_reference",  # nothing recognises it either, two words
    "text",             # PROMPT_WORDS
    "prompt",           # PROMPT_WORDS
    "sampler",          # SAFE_STRING_WORDS
    "mode",             # SAFE_STRING_WORDS
    "ckpt_name",        # LOCKED_STRING_WORDS
    "output_path",      # LOCKED_STRING_WORDS, twice over
    "device",           # LOCKED_ANY_WORDS
    "image",            # MEDIA_WORDS
    "mask",             # MASK_WORDS
    "upload",           # BOOKKEEPING_INPUT_NAMES
)

GRID_VALUES: Tuple[str, ...] = STILL_A_PATH + NO_LONGER_A_PATH + NOT_A_PATH_AND_NEVER_WAS


def _grid(monkeypatch: pytest.MonkeyPatch) -> Dict[Tuple[str, str], Tuple[Verdict, Verdict]]:
    """Every cell of the grid, decided by both rules.

    The old rule is put back through the module attribute :func:`classify`
    reads, so what is compared is the **whole decision** and not the predicate
    -- a differential on the predicate alone would say nothing about the seven
    branches that come after it.
    """

    cells: Dict[Tuple[str, str], Tuple[Verdict, Verdict]] = {}
    for name in GRID_NAMES:
        for value in GRID_VALUES:
            after = classify(name, value)
            with monkeypatch.context() as patched:
                patched.setattr(semantics, "looks_like_a_path", rule_before_t0095)
                before = classify(name, value)
            cells[(name, value)] = (before, after)
    return cells


def test_the_grid_reaches_the_rule_it_is_a_differential_of(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Before asserting what did not move, prove something did.

    A differential over a grid no verdict changes in would satisfy every
    assertion below it while testing nothing at all.  Both halves are named:
    the grid has to contain values the new rule still calls paths, and it has
    to contain cells whose verdict this card changed.
    """

    cells = _grid(monkeypatch)
    changed = [key for key, (before, after) in cells.items() if before != after]
    path_shaped = [value for value in GRID_VALUES if looks_like_a_path(value)]

    assert sorted(path_shaped) == sorted(STILL_A_PATH)
    assert changed, "no verdict moved; the differential is vacuous"


def test_nothing_that_is_still_path_shaped_stopped_being_locked(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The safety property of this card, as corrected in design.

    Not "nothing moves from LOCKED to EXPOSE" -- that was unsatisfiable, and
    the movement it forbade was the prompt box coming back.  The property that
    says the lock was not weakened is this one: **for every value the new rule
    still calls path-like, no verdict moved at all.**  A value that stops
    being path-like may honestly become locked for another reason, held for
    review, or -- where its name says prose or a known setting -- a field; a
    value that is *still* a path may become nothing.
    """

    cells = _grid(monkeypatch)
    moved = sorted(
        key
        for key, (before, after) in cells.items()
        if looks_like_a_path(key[1]) and before != after
    )

    assert moved == []


def test_every_exposed_path_shaped_value_is_there_by_the_media_ordering(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The other half: which path-shaped values a user is shown, and why.

    Some are, and they are not an accident -- ``image`` and ``mask`` ask the
    media question before the path question on purpose, so a picture in its
    own subfolder stays a picture.  Asserted by naming every such cell
    verbatim, and by requiring each one to carry a media kind: if a
    path-shaped value ever reached a user through some *other* branch, it
    would be in this list without one and this test would fail.
    """

    cells = _grid(monkeypatch)
    exposed = sorted(
        key
        for key, (_before, after) in cells.items()
        if looks_like_a_path(key[1]) and after.exposure is Exposure.EXPOSE
    )

    assert exposed == [
        ("image", "../models/foo.bin"),
        ("image", "./input/reference.png"),
        ("image", "C:/models/foo.safetensors"),
        ("image", "C:\\models\\foo.safetensors"),
        ("image", "\\\\server\\share\\model.bin"),
        ("image", "c:/models/foo.safetensors"),
        ("image", "models/checkpoints/foo.safetensors"),
        ("image", "portraits/photo.png"),
        ("image", "~/loras/study.safetensors"),
        ("mask", "../models/foo.bin"),
        ("mask", "./input/reference.png"),
        ("mask", "C:/models/foo.safetensors"),
        ("mask", "C:\\models\\foo.safetensors"),
        ("mask", "\\\\server\\share\\model.bin"),
        ("mask", "c:/models/foo.safetensors"),
        ("mask", "models/checkpoints/foo.safetensors"),
        ("mask", "portraits/photo.png"),
        ("mask", "~/loras/study.safetensors"),
    ]
    for key in exposed:
        assert cells[key][1].media is not None, key


#: What each family of input name does with a value that carries a separator
#: and is not a path -- the whole of this card's narrowing, written out rather
#: than counted.  ``locked -> expose`` on the prompt and setting names is the
#: prompt box coming back; ``locked -> uncertain`` on the names no vocabulary
#: recognises is what the runtime contract is then allowed to settle.
NARROWING: Dict[str, Tuple[str, str]] = {
    "mixing": ("locked", "uncertain"),
    "style_reference": ("locked", "uncertain"),
    "text": ("locked", "expose"),
    "prompt": ("locked", "expose"),
    "sampler": ("locked", "expose"),
    "mode": ("locked", "expose"),
    "ckpt_name": ("locked", "locked"),
    "output_path": ("locked", "locked"),
    "device": ("locked", "locked"),
    "image": ("uncertain", "uncertain"),
    "mask": ("uncertain", "uncertain"),
    "upload": ("locked", "locked"),
}


def test_the_narrowing_is_exactly_this_and_nothing_else(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Every changed verdict, grouped by the family of the input's name.

    Written out per family because within a family every weak value behaves
    identically -- and because a count would be satisfied by any twelve
    transitions at all.  A future change that moves one family into another's
    column has to say so here.
    """

    cells = _grid(monkeypatch)
    observed: Dict[str, set] = {name: set() for name in GRID_NAMES}
    for (name, value), (before, after) in cells.items():
        if value in NO_LONGER_A_PATH:
            observed[name].add((before.exposure.value, after.exposure.value))

    assert observed == {name: {NARROWING[name]} for name in GRID_NAMES}


def test_no_strong_evidence_value_changed_anywhere_in_the_grid(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The overcorrection guard, at the whole-decision level.

    Weakening the rule until a rooted, UNC or explicitly relative path stops
    being protected would show up here as a moved cell, whatever the input is
    called and whichever branch used to answer for it.
    """

    cells = _grid(monkeypatch)
    moved = sorted(
        key
        for key, (before, after) in cells.items()
        if key[1] in STILL_A_PATH and before != after
    )

    assert moved == []


# --------------------------------------------------------------------------
# End to end: the option set that started this, through the real contract
# --------------------------------------------------------------------------

#: The option list a ComfyUI declares through its public ``/object_info`` for
#: one of its inputs, quoted verbatim because it is the evidence this card was
#: filed on.  ``w/`` is English for *with*; two of the four carry it, and the
#: old rule therefore refused the whole set as a list of file names.  It is a
#: **fixture**: nothing in `semantics.py` or `contract.py` knows any of these
#: strings, and the input name and node class below are invented for this file.
REAL_OPTION_SET: Tuple[str, ...] = (
    "V only",
    "K+V",
    "K+V w/ C penalty",
    "K+mean(V) w/ C penalty",
)

#: Invented, and unrecognised by every vocabulary in `semantics.py` -- which is
#: what leaves the verdict ``UNCERTAIN`` and lets the contract be asked at all.
BLENDER = "ExampleBlender"
BLEND_INPUT = "blending"


def object_info(*declarations: Tuple[str, str, Any]) -> Dict[str, Any]:
    """``/object_info`` in ComfyUI's own shape."""

    document: Dict[str, Any] = {}
    for class_type, input_name, spec in declarations:
        entry = document.setdefault(
            class_type, {"input": {"required": {}}, "output": [], "name": class_type}
        )
        entry["input"]["required"][input_name] = spec
    return document


def contract(*declarations: Tuple[str, str, Any]) -> RuntimeContract:
    """A contract read through the production parser, never filled by hand."""

    return read_object_info(
        object_info(*declarations), identity_digest="sha256:runtime-a"
    )


def choices(*values: Any) -> List[Any]:
    return [list(values), {}]


class Watching:
    """A contract that records every question asked of it.

    "The contract was never consulted" is a claim about a call that does not
    happen, and holding the thing that would have been called is the only
    honest way to check it.

    :attr:`asked` holds the question this file is about -- which choices does
    this runtime declare -- and nothing else.  The numeric declaration T-0098
    added is a different question asked in a different situation, so it is
    forwarded and not recorded here: counting it in the same list would let a
    number's type stand in as evidence about a choice list.  T-0185's node
    shapes are forwarded on the same terms and for the same reason.
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

    def options_for(self, class_type: str, input_name: str) -> Optional[Tuple[Any, ...]]:
        self.asked.append((class_type, input_name))
        return self._inner.options_for(class_type, input_name)

    def numeric_for(self, class_type: str, input_name: str):
        return self._inner.numeric_for(class_type, input_name)

    def structural_for(self, class_type: str, input_name: str):
        return self._inner.structural_for(class_type, input_name)


def blend_graph(value: str) -> Dict[str, Any]:
    """One generation whose single unsettled input holds one of those options."""

    return {
        "1": {
            "class_type": "ExampleWeightsLoader",
            "inputs": {"ckpt_name": "chosen-weights.safetensors"},
        },
        "2": {
            "class_type": "ExampleTextEncode",
            "inputs": {"text": "a quiet street at dawn", "clip": ["1", 1]},
        },
        "3": {
            "class_type": BLENDER,
            "inputs": {
                "seed": 7,
                "steps": 20,
                BLEND_INPUT: value,
                "model": ["1", 0],
                "positive": ["2", 0],
            },
        },
    }


def test_an_option_set_of_ordinary_words_is_no_longer_refused_as_file_names() -> None:
    """The predicate the card was filed on, at the level the refusal lives."""

    assert names_files(list(REAL_OPTION_SET)) is False
    assert [value for value in REAL_OPTION_SET if rule_before_t0095(value)] == [
        "K+V w/ C penalty",
        "K+mean(V) w/ C penalty",
    ]


def test_that_option_set_becomes_a_select_through_the_real_contract_path() -> None:
    """End to end, and the whole of the unlock this card was filed for.

    The graph carries one of the four; the runtime declares all four; the
    workflow imports without review, and the input is a ``select`` over the
    declared choices **in the declared order**.  Before this card the list was
    refused as file names and the workflow stayed ``NEEDS_REVIEW``.
    """

    declared = contract((BLENDER, BLEND_INPUT, choices(*REAL_OPTION_SET)))

    plan = analyse(blend_graph("K+V w/ C penalty"), contract=declared)

    assert plan.needs_review is False
    assert plan.problems == ()
    assert plan.refused_as_file_names == ()
    assert [item.id for item in plan.fields] == ["prompt", "blending", "seed", "steps"]
    field = [item for item in plan.fields if item.id == BLEND_INPUT][0]
    assert field.type == SELECT_FIELD_TYPE
    assert field.options == REAL_OPTION_SET
    assert field.default == "K+V w/ C penalty"


@pytest.mark.parametrize("value", REAL_OPTION_SET)
def test_the_field_id_does_not_move_with_the_option_chosen(value: str) -> None:
    """The ids a user's saved settings hang off, asserted verbatim.

    One of the four contains no separator and two of them do, so if any part
    of this rule ever reached an id, these four would not agree.
    """

    declared = contract((BLENDER, BLEND_INPUT, choices(*REAL_OPTION_SET)))

    plan = analyse(blend_graph(value), contract=declared)

    assert [item.id for item in plan.fields] == ["prompt", "blending", "seed", "steps"]


def test_a_loader_dropdown_stays_locked_although_its_choices_parse() -> None:
    """Structural leakage: being an enum has never been a reason to expose.

    The runtime here declares a perfectly readable list for a loader's input,
    and the choices contain no separator at all -- so nothing about the shape
    of a value refuses them, and the *ordering* is the whole of the argument.
    The proof is not that the field is absent but that the contract was never
    asked, watched by a contract that records every question.
    """

    watcher = Watching(
        contract(
            (BLENDER, BLEND_INPUT, choices(*REAL_OPTION_SET)),
            ("ExampleWeightsLoader", "ckpt_name", choices("chosen-weights.safetensors")),
        )
    )

    plan = analyse(blend_graph("V only"), contract=watcher)

    assert ("ExampleWeightsLoader", "ckpt_name") not in watcher.asked
    assert (BLENDER, BLEND_INPUT) in watcher.asked, (
        "the watcher recorded nothing, so its silence about the loader is worthless"
    )
    assert [item.id for item in plan.fields] == ["prompt", "blending", "seed", "steps"]
    locked = [item for item in plan.controls if item.input == "ckpt_name"]
    assert [item.section for item in locked] == ["locked"]
    assert [item.kind for item in locked] == [semantics.LOCKED_WEIGHTS_FILE]


def test_a_declared_list_of_the_users_files_is_still_refused() -> None:
    """The refusal this card must not have loosened, on the same input.

    Same class, same input, same graph shape -- only the declared list is a
    picker over somebody's weights, and it stays refused and counted.
    """

    declared = contract(
        (BLENDER, BLEND_INPUT, choices("V only", "chosen-weights.safetensors"))
    )

    plan = analyse(blend_graph("V only"), contract=declared)

    assert plan.needs_review is True
    assert plan.refused_as_file_names == (("3", BLEND_INPUT),)
    assert [item.id for item in plan.fields] == []
