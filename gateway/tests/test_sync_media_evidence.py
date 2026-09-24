"""Media is what an input *is*, never what its value happens to end in.

The bug this file holds shut (T-0072): ``_media_kind()`` read the value's file
suffix before it looked at the input at all, so ``{"prefix": "out.png"}`` --
an ordinary string with a filename-shaped default -- became a **required**
image field.  The user was then asked to upload a picture for something that
is not a picture, and the workflow could not run without one.

The rule now: an input takes user-supplied media because **its own name says
so**.  The value's suffix corroborates -- it settles *which* kind where the
name did not say -- and it establishes media for nothing, ever.

The node's ``class_type`` is deliberately not evidence here.  A loader's type
says the node loads media and never which of its inputs is the file, so
reading it puts the same bug back at full width on the one node class every
real workflow contains -- measured on ``LoadImage`` in this card's own review.

Two guards hold that, and each fails on its own:

* the **absence** tests below die if the suffix may establish media again;
* the **kind** tests below die if the suffix stops corroborating.

Read them in the order they are written.  Every absence in the second half is
preceded by the positive that proves the same assertion was available to be
written: an image field and a video field really are produced by this
importer, so "no media field" is a statement about the input and not about a
classifier that stopped producing media at all.

The four media cases (A/B/C/D) and their graphs live in
``test_sync_importer.py``, where they were written; they are unchanged by this
card and are not restated here.
"""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict

import pytest

from localcanvas_gateway.workflows.sync import WorkflowState, analyse, run_sync
from localcanvas_gateway.workflows.sync.semantics import (
    Exposure,
    Verdict,
    classify,
)
from sync_fixtures import SyncWorkspace, write_json

FIXED = datetime(2026, 1, 2, 3, 4, 5, tzinfo=timezone.utc)


@pytest.fixture()
def workspace(tmp_path: Path) -> SyncWorkspace:
    return SyncWorkspace(tmp_path)

# ==========================================================================
# First: media really is produced.  Nothing below this point can pass
# vacuously, because these say the classifier still has a media answer to
# give.
# ==========================================================================


def test_a_picture_the_user_supplies_is_still_an_image_field() -> None:
    """The whole verdict, not one attribute of it."""

    assert classify("image", "photo.png") == Verdict(
        Exposure.EXPOSE,
        "input 'image' takes a picture the user supplies.",
        field_type="image",
        role="image",
        media="image",
    )


def test_a_clip_the_user_supplies_is_still_a_video_field() -> None:
    assert classify("video", "clip.mp4") == Verdict(
        Exposure.EXPOSE,
        "input 'video' takes a clip the user supplies.",
        field_type="video",
        role="video",
        media="video",
    )


def test_a_picture_is_a_picture_whatever_its_value_ends_in() -> None:
    """The name is the evidence, so a suffix nobody listed changes nothing.

    ``photo.avif`` is in neither suffix list and the input is still an image
    field: the suffix is not what made the two tests above pass.

    This asked ``PLACEHOLDER`` until T-0080, which made the value corroborate
    that there is media here at all -- a bare word no longer does, because a
    bare word is what ``image_format = 'nearest-exact'`` is.  What the test
    was written to prove is unchanged and is proved here by a value with an
    extension this module has never heard of.
    """

    verdict = classify("image", "photo.avif")

    assert verdict.media == "image"
    assert verdict.field_type == "image"
    assert verdict.exposure is Exposure.EXPOSE


def test_a_media_input_keeps_its_own_subfolder_instead_of_being_locked() -> None:
    """The order of the questions, which this card did not change.

    ComfyUI writes a picture's own subfolder into a loader input, so the slash
    here is part of the picture's name.  Asked after the path question this
    would be ``LOCKED`` and the picture would be unreachable.
    """

    verdict = classify("image", "portraits/photo.png")

    assert verdict.exposure is Exposure.EXPOSE
    assert verdict.media == "image"


def test_an_image_field_reaches_the_plan_of_a_real_graph() -> None:
    """Through ``analyse()`` rather than the classifier alone: the field the
    app would receive is the thing the bug was about."""

    plan = analyse(
        {
            "1": {"class_type": "ExampleImageLoader", "inputs": {"image": "photo.png"}},
            "2": {"class_type": "ExampleEdit", "inputs": {"image": ["1", 0]}},
        }
    )

    assert not plan.problems, plan.problems
    assert [(item.id, item.type, item.required) for item in plan.fields] == [
        ("image", "image", True)
    ]


# ==========================================================================
# The bug: an ordinary string whose value looks like a file name
# ==========================================================================

#: The sentence rule 8 composes.  Written out once, because every absence
#: below asserts the *whole* verdict and not merely that some field is missing.
def _undecided(name: str, value: str) -> Verdict:
    return Verdict(
        Exposure.UNCERTAIN,
        "input {!r} holds the text {!r}, and nothing in the graph says whether "
        "that is a setting a user may change or something structural. It is "
        "neither exposed nor dropped: look at it and decide.".format(name, value),
    )


def test_the_bugs_own_example_is_uncertain_and_carries_no_media() -> None:
    """``{"prefix": "out.png"}``: the input measured in the T-0054 review.

    ``UNCERTAIN`` is the correct outcome and not a regression -- an
    unrecognised string is neither exposed nor dropped.  A workflow held for a
    human to glance at is strictly better than one that demands a photograph
    before it will run.
    """

    verdict = classify("prefix", "out.png")

    assert verdict == _undecided("prefix", "out.png")
    assert verdict.media is None
    assert verdict.field_type is None
    assert verdict.exposure is Exposure.UNCERTAIN


@pytest.mark.parametrize(
    "name,value",
    [
        ("prefix", "out.png"),
        ("prefix", "reference.jpg"),
        ("note", "clip.mp4"),
        ("style", "poster.webp"),
    ],
)
def test_an_ordinary_string_that_looks_like_a_file_name_is_not_media(
    name: str, value: str
) -> None:
    assert classify(name, value) == _undecided(name, value)


@pytest.mark.parametrize(
    "value", ["OUT.PNG", "Out.Png", "REFERENCE.JPG", "Clip.MP4", "clip.MoV"]
)
def test_case_does_not_smuggle_a_media_suffix_past_the_rule(value: str) -> None:
    """Half of the case-insensitivity property: shouting does not help."""

    assert classify("prefix", value) == _undecided("prefix", value)


@pytest.mark.parametrize(
    "name,value,kind",
    [
        ("image", "PHOTO.PNG", "image"),
        ("image", "Photo.Jpeg", "image"),
        ("video", "CLIP.MP4", "video"),
        ("mask", "CUTOUT.PNG", "image"),
        ("mask", "MATTE.MP4", "video"),
    ],
)
def test_a_genuine_media_input_survives_a_shouted_value(
    name: str, value: str, kind: str
) -> None:
    """The other half, and the one a case-sensitive fix would fail alone.

    A fix that lower-cased nothing would still pass every test above, because
    every test above wants the answer "not media".
    """

    verdict = classify(name, value)

    assert verdict.media == kind
    assert verdict.field_type == kind
    assert verdict.exposure is Exposure.EXPOSE


@pytest.mark.parametrize(
    "class_type",
    ["ExampleThing", "ExampleImageLoader", "ExampleLoadImage", "ExampleLoadVideo"],
)
def test_a_string_that_looks_like_a_file_name_needs_review_in_a_real_graph(
    class_type: str,
) -> None:
    """The whole way through ``analyse()``: no field, and the workflow is held.

    The node's type is varied and the answer does not move.  Three of the four
    are loader-shaped -- named for loading *and* for media -- because reading
    a class type is exactly how this card's first attempt put the bug back:
    a type says a node loads media, never which of its inputs is the file, so
    on a loader every string ending in ``.png`` became a required upload
    again.  Held here on the shape that made it dangerous.
    """

    graph: Dict[str, Any] = {
        "1": {"class_type": class_type, "inputs": {"prefix": "out.png"}},
        "2": {
            "class_type": "ExampleTextEncode",
            "inputs": {"text": "a quiet street", "thing": ["1", 0]},
        },
    }

    plan = analyse(graph)

    assert plan.needs_review
    assert plan.fields == ()
    assert plan.problems == (
        "Node 1 " + _undecided("prefix", "out.png").reason,
    )
    sections = {(item.node, item.input): item.section for item in plan.controls}
    assert sections[("1", "prefix")] == "needs_review"


def test_that_graph_is_needs_review_in_a_whole_run_and_writes_no_definition(
    workspace: SyncWorkspace,
) -> None:
    """The same graph through the run a curator actually starts.

    ``NEEDS_REVIEW`` is a state the report carries, not only a flag on a plan,
    and the outcome this card wants is that a human looks at the string --
    with nothing written on a guess in the meantime.
    """

    folder = workspace.add_source()
    write_json(
        folder / "one.json",
        {"1": {"class_type": "ExampleThing", "inputs": {"prefix": "out.png"}}},
    )
    workspace.write_config()

    report = run_sync(workspace.load(), now=FIXED)

    assert len(report.workflows) == 1
    assert report.workflows[0].state is WorkflowState.NEEDS_REVIEW
    assert "prefix" in report.workflows[0].reason
    assert report.definitions_written == 0


# ==========================================================================
# The suffix, in the one job it keeps: which kind
# ==========================================================================


@pytest.mark.parametrize(
    "value,kind",
    [
        ("cutout.png", "image"),
        ("matte.mp4", "video"),
        ("alpha.webm", "video"),
        ("cutout.tiff", "image"),
    ],
)
def test_the_suffix_settles_the_kind_where_the_name_does_not(
    value: str, kind: str
) -> None:
    """``mask`` says "media" without saying which, and a matte may be either.

    This is the guard that dies if the suffix stops corroborating: the same
    input name produces two different kinds, and only the value tells them
    apart.
    """

    verdict = classify("mask", value)

    assert verdict.media == kind
    assert verdict.field_type == kind
    assert verdict.mask is True


def test_a_name_that_says_which_kind_outranks_the_suffix() -> None:
    """Corroboration, not authority: the input's own word wins a disagreement."""

    assert classify("video", "still.png").media == "video"
    assert classify("image", "movie.mp4").media == "image"


def test_a_matte_with_nothing_to_read_falls_back_to_a_picture() -> None:
    """``matte.avif`` names a file and says nothing about which kind it is.

    ``PLACEHOLDER`` reached this fallback until T-0080; a value has to look
    like a file now, and an unlisted extension is the way to a value that
    corroborates media while leaving the kind unsaid.
    """

    verdict = classify("mask", "matte.avif")

    assert verdict.media == "image"
    assert verdict.mask is True


def test_comfyuis_trailing_input_marker_is_still_stripped() -> None:
    """``photo.png [input]`` is what a loader's value really looks like.

    Asserted where the suffix still decides something -- the kind -- because
    that is the only place a broken :func:`has_suffix` could now be seen.
    """

    assert classify("mask", "matte.mp4 [input]").media == "video"
    assert classify("mask", "cutout.png [input]").media == "image"


# ==========================================================================
# The two locked routes, which the media question must not swallow
# ==========================================================================


def test_a_weights_file_is_still_locked() -> None:
    verdict = classify("name", "chosen-weights.safetensors")

    assert verdict.exposure is Exposure.LOCKED
    assert verdict.kind == "weights_file"
    assert verdict.media is None


def test_a_path_is_still_locked_even_when_it_ends_in_a_picture() -> None:
    """The route the bug used to take instead.

    ``renders/out.png`` was media before this card, so this is a value that
    changed hands from one question to another -- and it must arrive at the
    locked one, not at review.
    """

    verdict = classify("prefix", "renders/out.png")

    assert verdict.exposure is Exposure.LOCKED
    assert verdict.kind == "filesystem_path"
    assert verdict.media is None


def test_a_matte_with_a_subfolder_in_its_value_is_not_locked_either() -> None:
    """The mirror of the test above, so neither reading is left to chance.

    The same shape of value -- a slash and a picture's name -- on an input the
    graph *does* say takes media: it must reach the media question, not the
    path one.  Asserted on the mask branch, so the two sides of the media
    question are each represented rather than one of them twice.
    """

    verdict = classify("mask", "mattes/cutout.png")

    assert verdict.exposure is Exposure.EXPOSE
    assert verdict.media == "image"
    assert verdict.mask is True
