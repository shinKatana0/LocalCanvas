"""A media name is half the evidence; the value is the other half.

T-0072 made the input's **name** the evidence for media and demoted the
value's suffix to a tie-breaker for which kind.  That removed the bug where
any string ending in ``.png`` became a required upload -- and left the mirror
of it standing, because the value was then consulted for the *kind* and never
for whether this was media at all.  Measured on ``main``::

    image_format = 'nearest-exact'  ->  EXPOSE, media=image   (required upload)
    video_codec  = 'h264'           ->  EXPOSE, media=video   (required upload)

The user is asked to upload a picture for a codec's name, and the workflow
cannot run without one.  The rule now takes **both** halves: the name must say
media *and* the value must bear that out by looking like the name of a file --
or by being empty, which is what a graph saved before a picture was chosen
carries.

What corroboration is **not**, and this is the shape of the whole fix: "the
value ends in a suffix this module lists".  A real workflow whose picture is
an ``.avif`` would then be refused outright, which is the same harm arriving
from a third side.  The suffix lists settle *which* kind and never *whether*.

Two mutations, each killing a **different** test:

* **drop the corroboration requirement** -- let the name decide alone, as
  ``main`` does -- and every row of ``MUST_NOT_BE_MEDIA`` dies:
  ``test_a_name_that_says_media_over_a_value_that_does_not_is_held_for_review``,
  together with the two graph tests below it.  The positives are untouched by
  it, because a name-only rule still answers "media" for all of them.
* **make corroboration require a listed extension** -- ``.avif`` refused --
  and ``test_a_picture_in_a_format_nobody_listed_is_still_a_picture`` dies,
  along with ``test_an_unlisted_extension_still_falls_back_to_a_picture``.
  The negatives are untouched by it, because a listed-suffix rule refuses
  ``nearest-exact`` too.

Nothing here reaches for the graph.  ``class_type`` is not evidence and must
not become any: a loader's type says the node loads media and never which of
its inputs is the file, which is how T-0072's first attempt put its own bug
back at full width.  The evidence is the name and the value, and no ComfyUI
installation was read to write any of it.

Read the file in the order it is written: the positives come first, so no
absence below them can pass by the classifier having stopped producing media
at all.
"""

from __future__ import annotations

import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Optional

import pytest

from localcanvas_gateway.workflows.sync import WorkflowState, analyse, run_sync
from localcanvas_gateway.workflows.sync.semantics import (
    IMAGE_SUFFIXES,
    MASK_WORDS,
    MEDIA_WORDS,
    VIDEO_SUFFIXES,
    Exposure,
    Verdict,
    classify,
    has_suffix,
)
from sync_fixtures import SyncWorkspace, write_json

FIXED = datetime(2026, 1, 2, 3, 4, 5, tzinfo=timezone.utc)


@pytest.fixture()
def workspace(tmp_path: Path) -> SyncWorkspace:
    return SyncWorkspace(tmp_path)


def _supplies(name: str, kind: str, mask: bool = False) -> Verdict:
    """The verdict a corroborated media input gets, written out once."""

    return Verdict(
        Exposure.EXPOSE,
        "input {!r} takes {} the user supplies.".format(
            name, "a picture" if kind == "image" else "a clip"
        ),
        field_type=kind,
        role=name,
        media=kind,
        mask=mask,
    )


# ==========================================================================
# First: what must still be media.  Written before the absences, so none of
# them can pass by media having stopped being produced.
# ==========================================================================

#: The value in each row is a different reason to believe there is a file
#: here -- an ordinary name, nothing chosen yet, a subfolder, ComfyUI's own
#: trailing marker, shouting, a clip, a matte, and an extension this module
#: has never heard of.  Asserted as **whole verdicts**: a row that stopped
#: being media by becoming something else is not a row that passed.
MUST_BE_MEDIA = [
    pytest.param("image", "photo.png", _supplies("image", "image"), id="ordinary"),
    pytest.param("image", "", _supplies("image", "image"), id="nothing-chosen-yet"),
    pytest.param(
        "image", "subfolder/photo.png", _supplies("image", "image"), id="subfolder"
    ),
    pytest.param(
        "image", "photo.png [input]", _supplies("image", "image"), id="input-marker"
    ),
    pytest.param("image", "PHOTO.PNG", _supplies("image", "image"), id="shouted"),
    pytest.param("video", "clip.mp4", _supplies("video", "video"), id="a-clip"),
    pytest.param("mask", "cutout.png", _supplies("mask", "image", True), id="a-matte"),
    pytest.param(
        "image", "photo.avif", _supplies("image", "image"), id="unlisted-extension"
    ),
]


@pytest.mark.parametrize("name,value,expected", MUST_BE_MEDIA)
def test_a_value_that_bears_out_a_media_name_is_still_media(
    name: str, value: str, expected: Verdict
) -> None:
    assert classify(name, value) == expected


def test_a_picture_in_a_format_nobody_listed_is_still_a_picture() -> None:
    """The row that shapes the rule, restated on its own so it cannot be lost.

    ``.avif`` is in neither suffix list -- asserted, not assumed, because a
    row that quietly became a listed suffix would make the whole
    unlisted-extension property untestable while still passing.  A
    corroboration written as "ends in a suffix I know" refuses this value, and
    with it a real workflow, which is the harm T-0079 was filed for.
    """

    assert not has_suffix("photo.avif", IMAGE_SUFFIXES)
    assert not has_suffix("photo.avif", VIDEO_SUFFIXES)

    assert classify("image", "photo.avif") == _supplies("image", "image")


def test_an_unlisted_extension_still_falls_back_to_a_picture() -> None:
    """``mask`` says media without saying which, so the value settles it.

    With no suffix to read, the commoner of the two kinds is the answer -- and
    reaching that fallback at all requires a value that corroborates without
    being listed, which is what makes this a second death for the over-tight
    rule and not a restatement of the test above.
    """

    verdict = classify("mask", "matte.avif")

    assert verdict == _supplies("mask", "image", True)


def test_the_suffix_still_settles_the_kind_where_the_name_does_not() -> None:
    """The job the suffix keeps.  One name, two kinds, decided by the value."""

    assert classify("mask", "cutout.png").media == "image"
    assert classify("mask", "matte.mp4").media == "video"


def test_a_number_on_a_media_named_input_is_still_a_number() -> None:
    """``image_count = 8`` was already right and must stay right.

    The corroboration question is asked of a **string**; an integer never
    reaches it, and the whole verdict here says the change did not swallow the
    branch that answers for numbers.
    """

    assert classify("image_count", 8) == Verdict(
        Exposure.EXPOSE,
        "input 'image_count' is a number that changes how the workflow generates.",
        field_type="integer",
        role="image_count",
    )


# ==========================================================================
# Then: what must not be media, now that media is really produced above
# ==========================================================================


def _no_file_here(name: str, value: str) -> Verdict:
    """The sentence branch 1b composes.  A curator reads it as it stands."""

    return Verdict(
        Exposure.UNCERTAIN,
        "input {!r} is named for media, but holds the text {!r}, which does "
        "not look like the name of a file a user would upload. It is neither "
        "exposed nor dropped: look at it and decide.".format(name, value),
    )


#: A resampling method, a codec, a count and a scale.  ``image_scale = '1.5'``
#: is the trap in the obvious predicate: it has a dot in it, so "the value
#: contains a dot" is not the rule, and a decimal point is not an extension.
MUST_NOT_BE_MEDIA = [
    pytest.param(
        "image_format",
        "nearest-exact",
        _no_file_here("image_format", "nearest-exact"),
        id="a-resampling-method",
    ),
    pytest.param(
        "video_codec", "h264", _no_file_here("video_codec", "h264"), id="a-codec"
    ),
    pytest.param(
        "mask_mode",
        "nearest-exact",
        _no_file_here("mask_mode", "nearest-exact"),
        id="a-method-on-a-matte",
    ),
    pytest.param(
        "image_count", "8", _no_file_here("image_count", "8"), id="a-count-as-text"
    ),
    pytest.param(
        "image_scale",
        "1.5",
        _no_file_here("image_scale", "1.5"),
        id="a-scale-with-a-dot",
    ),
]


@pytest.mark.parametrize("name,value,expected", MUST_NOT_BE_MEDIA)
def test_a_name_that_says_media_over_a_value_that_does_not_is_held_for_review(
    name: str, value: str, expected: Verdict
) -> None:
    """``UNCERTAIN``, and the reason names what was odd.

    Not an exposed text field: a workflow held for a human to glance at beats
    one that demands a photograph it has no use for, and this is the same
    conservative answer T-0054 settled and T-0072 kept.
    """

    assert classify(name, value) == expected


def test_every_refused_name_really_does_say_media() -> None:
    """The fixture check, and the one that stops the forbidden fix.

    Each name above has to carry a word from the media vocabulary, or the
    test above proves nothing: it would be passing because the name says
    nothing about media, not because the value was refused.  This is also
    what fails the day somebody "fixes" this card by narrowing
    :data:`MEDIA_WORDS` or :data:`MASK_WORDS` instead -- which would mask the
    defect and take a genuine ``images`` input with it.
    """

    vocabulary = MEDIA_WORDS | MASK_WORDS
    for case in MUST_NOT_BE_MEDIA:
        name = case.values[0]
        words = set(part for part in re.split(r"[^a-z0-9]+", name.lower()) if part)
        assert words & vocabulary, name


# ==========================================================================
# The whole way through a real graph, and a real run
# ==========================================================================


def _edit_graph(image_format: Optional[str] = None) -> Dict[str, Any]:
    """An img2img-shaped export: a loader, its editor bookkeeping, a resize.

    The shape every export of that kind has, including the ``upload`` widget
    ComfyUI writes beside an image loader (T-0079).  ``image_format`` is the
    input this card is about, and it is left out entirely when nothing is
    passed -- so the two graph tests differ in that one input and in nothing
    else.
    """

    resize: Dict[str, Any] = {"image": ["1", 0], "width": 1024, "height": 1024}
    if image_format is not None:
        resize["image_format"] = image_format
    return {
        "1": {
            "class_type": "ExampleImageLoader",
            "inputs": {"image": "photo.png", "upload": "image"},
        },
        "2": {"class_type": "ExampleResize", "inputs": resize},
        "3": {
            "class_type": "ExampleTextEncode",
            "inputs": {"text": "a quiet street at dawn"},
        },
        "4": {
            "class_type": "ExampleSampler",
            "inputs": {
                "conditioning": ["3", 0],
                "pixels": ["2", 0],
                "seed": 0,
                "steps": 20,
            },
        },
        "5": {
            "class_type": "ExampleOutput",
            "inputs": {"images": ["4", 0], "filename_prefix": "LocalCanvas"},
        },
    }


def test_that_graph_without_the_odd_input_imports_and_offers_the_picture() -> None:
    """The positive the test below needs, or its refusal proves nothing.

    Without ``image_format`` the graph imports, and the *genuine* upload -- the
    loader's own ``image`` -- is the required image field in Main.  So the
    refusal below is about that one input and not about a graph this importer
    could never read.
    """

    plan = analyse(_edit_graph())

    assert plan.problems == ()
    assert plan.needs_review is False
    assert [
        (field.id, field.type, field.section, field.required) for field in plan.fields
    ][:2] == [("prompt", "multiline", "main", True), ("image", "image", "main", True)]


def test_the_odd_input_holds_the_whole_workflow_for_review() -> None:
    """Refused for the right reason -- which on ``main`` it was not.

    Measured by running the parent commit's ``semantics.py``: this graph was
    **already** ``NEEDS_REVIEW`` with no fields before this card, and not
    because anything here was understood.  ``image_format`` became a second
    picture, ``analysis.py`` gave it the same part to play as the loader's
    genuine ``image``, and case D refused two pictures it could not tell
    apart.  A fabricated conflict, reported as one.

    So what this test pins is the *reason*, not the refusal: one problem,
    naming node 2's input and saying the value does not look like a file.
    The graph that witnesses the card's actual harm -- a required upload
    conjured out of nothing -- is the one below, and it has no picture in it
    at all.
    """

    plan = analyse(_edit_graph("nearest-exact"))

    assert plan.needs_review
    assert plan.fields == ()
    assert plan.problems == (
        "Node 2 " + _no_file_here("image_format", "nearest-exact").reason,
    )
    sections = {(item.node, item.input): item.section for item in plan.controls}
    assert sections[("2", "image_format")] == "needs_review"


def _txt2img_graph(image_format: Optional[str] = None) -> Dict[str, Any]:
    """A graph with **no picture in it anywhere**: text in, one picture out.

    Not one literal here is media.  Every media-typed value in it is a wire
    between nodes, which :func:`semantics.is_literal` excludes from the
    question entirely -- so any image field this importer produces from this
    graph was invented rather than found.  ``image_format`` is added only
    when a value is passed, so the two halves of the test below differ in
    that one input and in nothing else.
    """

    upscale: Dict[str, Any] = {"pixels": ["4", 0]}
    if image_format is not None:
        upscale["image_format"] = image_format
    return {
        "1": {
            "class_type": "ExampleWeightsLoader",
            "inputs": {"ckpt_name": "chosen-weights.safetensors"},
        },
        "2": {
            "class_type": "ExampleTextEncode",
            "inputs": {"text": "a quiet street at dawn", "conditioner": ["1", 1]},
        },
        "3": {
            "class_type": "ExampleEmptyCanvas",
            "inputs": {"width": 1024, "height": 1024},
        },
        "4": {
            "class_type": "ExampleSampler",
            "inputs": {
                "model": ["1", 0],
                "conditioning": ["2", 0],
                "canvas": ["3", 0],
                "seed": 0,
                "steps": 20,
            },
        },
        "5": {"class_type": "ExampleUpscale", "inputs": upscale},
        "6": {
            "class_type": "ExampleOutput",
            "inputs": {"images": ["5", 0], "filename_prefix": "LocalCanvas"},
        },
    }


def test_one_odd_string_no_longer_conjures_an_upload_out_of_nothing() -> None:
    """The harm this card exists to remove, witnessed on the graph that has it.

    Measured against the parent commit's ``semantics.py``, one input apart:

        without ``image_format``  ->  imports, no media field at all
        with    ``image_format``  ->  imports, and REQUIRED UPLOADS == ['image']
                                      bound to node 5's ``image_format``

    A text-to-image workflow that would not run until the user supplied a
    photograph it has no slot for, asked for by a resampling method's name.
    In an import inventory that phantom is indistinguishable from a genuine
    upload without opening the graph, which is why it blocked T-0056.

    Both halves are asserted here and the clean one first, so the absence in
    the second is a statement about the input: the same graph really is
    readable, really does produce fields, and really has no media in it for
    the refusal to be about.
    """

    clean = analyse(_txt2img_graph())

    assert clean.problems == ()
    assert clean.needs_review is False
    assert [
        (field.id, field.type, field.section, field.required) for field in clean.fields
    ] == [
        ("prompt", "multiline", "main", True),
        ("height", "integer", "advanced", False),
        ("seed", "integer", "advanced", False),
        ("steps", "integer", "advanced", False),
        ("width", "integer", "advanced", False),
    ]

    held = analyse(_txt2img_graph("nearest-exact"))

    assert held.needs_review
    assert held.fields == ()
    assert held.problems == (
        "Node 5 " + _no_file_here("image_format", "nearest-exact").reason,
    )
    sections = {(item.node, item.input): item.section for item in held.controls}
    assert sections[("5", "image_format")] == "needs_review"


def test_no_definition_is_written_for_it_in_a_whole_run(
    workspace: SyncWorkspace,
) -> None:
    """``NEEDS_REVIEW`` is a state the run a curator starts really reaches.

    Nothing is written on a guess in the meantime, which is the point: a
    definition carrying a spurious required upload would be the acceptance
    evidence for the first real import.

    The reason is asserted **verbatim** rather than by looking for the input's
    name in it, and that is not fussiness.  Measured: with the corroboration
    removed, this graph is still refused -- ``image_format`` becomes a second
    picture and case D refuses two pictures the graph gives the same part to.
    That refusal names ``image_format`` too, so a substring check passes under
    the mutation and says nothing.  The sentence is what distinguishes the two.
    """

    folder = workspace.add_source()
    write_json(folder / "one.json", _edit_graph("nearest-exact"))
    workspace.write_config()

    report = run_sync(workspace.load(), now=FIXED)

    assert len(report.workflows) == 1
    assert report.workflows[0].state is WorkflowState.NEEDS_REVIEW
    assert report.workflows[0].reason == (
        "this workflow was not imported, because part of it could not be read "
        "with confidence: Node 2 "
        + _no_file_here("image_format", "nearest-exact").reason
    )
    assert report.definitions_written == 0


# ==========================================================================
# No other verdict near the media question moved
# ==========================================================================

#: Pairs on both sides of the media question that this card must leave alone:
#: media names over values that do corroborate, media names over values no
#: string branch answers, and the three locked routes the media question sits
#: in front of.
#:
#: **Generated by running the parent commit's ``semantics.py``** beside the
#: new one, so every expectation below is the old module's own answer rather
#: than something written to match the new code.  Pairs whose verdict this
#: card moves are in ``MUST_NOT_BE_MEDIA`` above, and the generator emitted
#: none of them here: all sixteen were already unchanged.
#:
#: The module-wide table -- at least one input per branch of ``classify()`` --
#: is ``test_sync_bookkeeping.py``'s ``UNCHANGED``, generated the same way one
#: card earlier and still passing; this one is the neighbourhood of the change.
UNCHANGED_NEAR_MEDIA = [
    pytest.param(
        "image",
        "a subfolder/photo.png [input]",
        Verdict(
            Exposure.EXPOSE,
            "input 'image' takes a picture the user supplies.",
            field_type="image",
            role="image",
            media="image",
        ),
    ),
    pytest.param(
        "image",
        "PLACEHOLDER_INPUT_IMAGE.png",
        Verdict(
            Exposure.EXPOSE,
            "input 'image' takes a picture the user supplies.",
            field_type="image",
            role="image",
            media="image",
        ),
    ),
    pytest.param(
        "image",
        "photo.safetensors",
        Verdict(
            Exposure.EXPOSE,
            "input 'image' takes a picture the user supplies.",
            field_type="image",
            role="image",
            media="image",
        ),
    ),
    pytest.param(
        "image",
        "   ",
        Verdict(
            Exposure.EXPOSE,
            "input 'image' takes a picture the user supplies.",
            field_type="image",
            role="image",
            media="image",
        ),
    ),
    pytest.param(
        "images",
        "frame.0001.png",
        Verdict(
            Exposure.EXPOSE,
            "input 'images' takes a picture the user supplies.",
            field_type="image",
            role="images",
            media="image",
        ),
    ),
    pytest.param(
        "picture",
        "portrait.jpg",
        Verdict(
            Exposure.EXPOSE,
            "input 'picture' takes a picture the user supplies.",
            field_type="image",
            role="picture",
            media="image",
        ),
    ),
    pytest.param(
        "video",
        "PLACEHOLDER_INPUT_VIDEO.mp4",
        Verdict(
            Exposure.EXPOSE,
            "input 'video' takes a clip the user supplies.",
            field_type="video",
            role="video",
            media="video",
        ),
    ),
    pytest.param(
        "mask",
        "mattes/cutout.png",
        Verdict(
            Exposure.EXPOSE,
            "input 'mask' takes a picture the user supplies.",
            field_type="image",
            role="mask",
            media="image",
            mask=True,
        ),
    ),
    pytest.param(
        "mask_strength",
        0.5,
        Verdict(
            Exposure.EXPOSE,
            "input 'mask_strength' is a number that changes how the workflow "
            "generates.",
            field_type="float",
            role="mask_strength",
        ),
    ),
    pytest.param(
        "image_count",
        8,
        Verdict(
            Exposure.EXPOSE,
            "input 'image_count' is a number that changes how the workflow "
            "generates.",
            field_type="integer",
            role="image_count",
        ),
    ),
    pytest.param(
        "prefix",
        "out.png",
        Verdict(
            Exposure.UNCERTAIN,
            "input 'prefix' holds the text 'out.png', and nothing in the graph "
            "says whether that is a setting a user may change or something "
            "structural. It is neither exposed nor dropped: look at it and "
            "decide.",
        ),
    ),
    pytest.param(
        "filename_prefix",
        "out.png",
        Verdict(
            Exposure.LOCKED,
            "input 'filename_prefix' names a file, a folder or a model to load "
            "('filename').",
            kind="file_reference",
        ),
    ),
    pytest.param(
        "image_path",
        "C:/photos/a.png",
        Verdict(
            Exposure.LOCKED,
            "input 'image_path' holds a path on this machine; LocalCanvas never "
            "puts a filesystem path in front of a user.",
            kind="filesystem_path",
        ),
    ),
    pytest.param(
        "clip_name",
        "a-text-encoder.safetensors",
        Verdict(
            Exposure.LOCKED,
            "input 'clip_name' names a file of weights to load; which file "
            "loads is what the workflow *is*, not how it generates.",
            kind="weights_file",
        ),
    ),
    pytest.param(
        "upload",
        "image",
        Verdict(
            Exposure.LOCKED,
            "input 'upload' is bookkeeping ComfyUI writes into its own API "
            "export beside a widget; nobody chose it, and nothing about what "
            "the workflow generates changes with it.",
            kind="editor_bookkeeping",
        ),
    ),
    pytest.param(
        "image",
        ["4", 0],
        Verdict(
            Exposure.UNCERTAIN,
            "input 'image' holds list, which is not a value a field can carry.",
        ),
    ),
]


@pytest.mark.parametrize("name,value,expected", UNCHANGED_NEAR_MEDIA)
def test_no_verdict_beside_the_media_question_has_moved(
    name: str, value: Any, expected: Verdict
) -> None:
    assert classify(name, value) == expected


def test_the_shipped_examples_classify_no_worse_than_before() -> None:
    """The three example graphs, whose plans this card left byte-identical.

    ``example_video_api.json`` was ``NEEDS_REVIEW`` when this was written -- its
    ``model_name`` held a placeholder with no file suffix, which T-0079
    deliberately left alone.  T-0081 gave the placeholder a suffix like the
    other two examples', so all three now import, and each keeps the media
    field it had.
    """

    from conftest import EXAMPLES_ROOT

    def plan_for(name: str):
        return analyse(
            json.loads((EXAMPLES_ROOT / name).read_text(encoding="utf-8"))
        )

    img2img = plan_for("example_img2img_api.json")
    assert img2img.needs_review is False
    assert ("image", "image", True) in [
        (field.id, field.type, field.required) for field in img2img.fields
    ]

    txt2img = plan_for("example_txt2img_api.json")
    assert txt2img.needs_review is False
    media_kinds = ("image", "video")
    assert [f.id for f in txt2img.fields if f.type in media_kinds] == []

    video = plan_for("example_video_api.json")
    assert video.needs_review is False
    assert video.problems == ()
    assert [
        (field.id, field.type, field.required)
        for field in video.fields
        if field.type in media_kinds
    ] == [("video", "video", True)]
