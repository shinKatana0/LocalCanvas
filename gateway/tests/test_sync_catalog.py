"""The catalogue: prose a curator is offered, and prose a curator keeps.

The properties this file exists to hold:

* **no generated string exists without the evidence rule that produced it**,
  and that is a property of the code rather than a claim -- an entry cannot be
  built without its sentence, and the ``presentation`` mapping is derived from
  the entries;
* a key no rule fired for is **absent** from the YAML and named in the notes,
  never filled with something plausible;
* the prose generator is **structurally incapable** of reading the source file
  name, established by calling it rather than by reading it;
* ``AI image generation workflow.`` and its siblings are **rejected by a bar
  this file defines and proves has teeth**, not merely avoided;
* the ``example_prompt`` semantics, each against the mistake it guards: no
  prompt field means no key, the graph's own default beats every template, a
  prompt beside a required picture is an *instruction* and not a scene, and a
  declared frame rate is video guidance -- and a tag-shaped **negative** prompt
  says nothing about the positive one, which is the claim the deleted
  tag-style branch used to make;
* what goes in is said once per **kind**, so two Main media fields are "two
  pictures you supply" and not the same phrase twice;
* **a curator's words survive a CHANGED sync**, key by key and value by value;
  a key they deleted comes back; ``inputs`` and ``bind`` are regenerated;
* a definition on disk that cannot be read is neither ignored nor written
  over;
* nothing here reaches a network or a translation backend, proved with a stub
  this machine can genuinely import rather than with a library it could not
  have loaded anyway.
"""

from __future__ import annotations

import ast
import importlib
import inspect
import json
import re
import socket
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Set, Tuple

import pytest
import yaml

from localcanvas_gateway.workflows import load_registry
from localcanvas_gateway.workflows.definition import PRESENTATION_KEYS
from localcanvas_gateway.workflows.sync import (
    PRESENTATION_ORDER,
    Catalog,
    CatalogEntry,
    WorkflowState,
    analyse,
    catalog as catalog_module,
    definitions as definitions_module,
    describe,
    readable_name,
    report_document,
    run_sync,
)
from sync_fixtures import SyncWorkspace, write_json

FIXED = datetime(2026, 1, 2, 3, 4, 5, tzinfo=timezone.utc)

CATALOG_SOURCE = Path(catalog_module.__file__).resolve()
SYNC_PACKAGE = CATALOG_SOURCE.parent


@pytest.fixture()
def workspace(tmp_path: Path) -> SyncWorkspace:
    return SyncWorkspace(tmp_path)


# ==========================================================================
# Graphs.  Every one is built here, from node types that exist nowhere but in
# this file: nothing depends on a real ComfyUI, a real model or a real node
# pack, and no model, family or vendor is named anywhere.
# ==========================================================================


def text_to_image() -> Dict[str, Any]:
    """A whole ordinary generation: two prompts, a size, a sampler, a save."""

    return {
        "4": {
            "class_type": "ExampleWeightsLoader",
            "inputs": {"ckpt_name": "chosen-weights.safetensors"},
        },
        "5": {
            "class_type": "ExampleEmptyCanvas",
            "inputs": {"width": 1024, "height": 768, "batch_size": 1},
        },
        "6": {
            "class_type": "ExampleTextEncode",
            "inputs": {"text": "a quiet street at dawn", "clip": ["4", 1]},
        },
        "7": {
            "class_type": "ExampleTextEncode",
            "inputs": {"text": "blurry, low quality", "clip": ["4", 1]},
        },
        "3": {
            "class_type": "ExampleSampler",
            "inputs": {
                "seed": 12345,
                "steps": 24,
                "cfg": 6.5,
                "sampler_name": "euler",
                "scheduler": "normal",
                "denoise": 1.0,
                "add_noise": True,
                "model": ["4", 0],
                "positive": ["6", 0],
                "negative": ["7", 0],
                "latent_image": ["5", 0],
            },
        },
        "8": {
            "class_type": "ExampleDecode",
            "inputs": {"samples": ["3", 0], "vae": ["4", 2]},
        },
        "9": {
            # Named for saving a *picture*: a name that says only "save" proves
            # nothing about what comes out (T-0268), and this graph is here to
            # be a picture workflow.
            "class_type": "ExampleSaveImage",
            "inputs": {"filename_prefix": "generated", "images": ["8", 0]},
        },
    }


def text_to_image_without_a_written_prompt() -> Dict[str, Any]:
    """The same graph with both prompt fields left empty by their author.

    Which is what makes the templates reachable: with a default in the file,
    the default wins and no template is ever chosen.
    """

    graph = text_to_image()
    graph["6"]["inputs"]["text"] = ""
    graph["7"]["inputs"]["text"] = ""
    return graph


def negative_prompt_written_as(text: str) -> Dict[str, Any]:
    """Both prompts empty except the negative one, which holds ``text``.

    The near-universal ``blurry, low quality`` is a *negative* prompt, and it
    used to switch the generated example to a tag-shaped template. Two graphs
    from this builder, one tag-shaped and one prose, must now be indis-
    tinguishable to the catalogue.
    """

    graph = text_to_image_without_a_written_prompt()
    graph["7"]["inputs"]["text"] = text
    return graph


def image_and_reference_edit() -> Dict[str, Any]:
    """A source picture and a semantically distinct reference: case B.

    Two required media fields both land in Main, which is the shape that made
    ``short_description`` say "a picture you supply and a picture you supply".
    """

    return {
        "1": {
            "class_type": "ExampleWeightsLoader",
            "inputs": {"ckpt_name": "chosen-weights.safetensors"},
        },
        "2": {"class_type": "ExampleLoadImage", "inputs": {"image": "source.png"}},
        "3": {"class_type": "ExampleLoadImage", "inputs": {"image": "guide.png"}},
        "4": {
            "class_type": "ExampleTextEncode",
            "inputs": {"instruction": "", "clip": ["1", 1]},
        },
        "5": {
            "class_type": "ExampleSampler",
            "inputs": {
                "seed": 11,
                "positive": ["4", 0],
                "image": ["2", 0],
                "reference": ["3", 0],
                "model": ["1", 0],
            },
        },
        "6": {
            "class_type": "ExampleSaveImage",
            "inputs": {"filename_prefix": "edited", "images": ["5", 0]},
        },
    }


def settings_only() -> Dict[str, Any]:
    """Fields, but nothing a person is asked for up front: Main is empty.

    Exactly one ``how_to_use`` rule fires here (the seed), which is the
    boundary the two-sentence minimum defends, and no ``input_summary`` can be
    written at all.
    """

    return {
        "1": {
            "class_type": "ExampleNoiseSource",
            "inputs": {"steps": 12, "cfg": 5.0},
        },
        "2": {
            "class_type": "ExampleSampler",
            "inputs": {"seed": 8, "denoise": 1.0, "latent": ["1", 0]},
        },
    }


def image_edit() -> Dict[str, Any]:
    """A picture goes in with an instruction; a picture comes out."""

    return {
        "1": {
            "class_type": "ExampleWeightsLoader",
            "inputs": {"ckpt_name": "chosen-weights.safetensors"},
        },
        "2": {"class_type": "ExampleLoadImage", "inputs": {"image": "source.png"}},
        "3": {
            "class_type": "ExampleTextEncode",
            "inputs": {"instruction": "", "clip": ["1", 1]},
        },
        "4": {
            "class_type": "ExampleSampler",
            "inputs": {
                "seed": 11,
                "denoise": 0.6,
                "positive": ["3", 0],
                "image": ["2", 0],
                "model": ["1", 0],
            },
        },
        "5": {
            "class_type": "ExampleSaveImage",
            "inputs": {"filename_prefix": "edited", "images": ["4", 0]},
        },
    }


def text_to_video() -> Dict[str, Any]:
    """A prompt, a frame count and a rate the graph itself declares."""

    return {
        "1": {
            "class_type": "ExampleWeightsLoader",
            "inputs": {"ckpt_name": "chosen-weights.safetensors"},
        },
        "2": {
            "class_type": "ExampleTextEncode",
            "inputs": {"text": "", "clip": ["1", 1]},
        },
        "3": {
            "class_type": "ExampleSampler",
            "inputs": {
                "seed": 3,
                "steps": 20,
                "length": 49,
                "positive": ["2", 0],
                "model": ["1", 0],
            },
        },
        "4": {
            "class_type": "ExampleVideoCombine",
            "inputs": {"fps": 24, "images": ["3", 0]},
        },
    }


def upscale() -> Dict[str, Any]:
    """A picture in, a bigger picture out, and nothing to write anywhere."""

    return {
        "1": {
            "class_type": "ExampleUpscaleModelLoader",
            "inputs": {"model_name": "chosen-upscaler.pth"},
        },
        "2": {"class_type": "ExampleLoadImage", "inputs": {"image": "source.png"}},
        "3": {
            "class_type": "ExampleImageUpscaleWithModel",
            "inputs": {"upscale_model": ["1", 0], "image": ["2", 0]},
        },
        "4": {
            "class_type": "ExampleSaveImage",
            "inputs": {"filename_prefix": "upscaled", "images": ["3", 0]},
        },
    }


def clip_edit() -> Dict[str, Any]:
    """A clip goes in with an instruction, and no class type says "video".

    Deliberately: the only thing that proves this workflow plays over time is
    the *field* -- the loader's input, which the importer reads as a clip --
    and no node in it is named for video, nor is a frame rate declared
    anywhere.  It is the case the other two video rules would miss.

    The input is named ``video`` rather than ``source`` because a value's
    suffix no longer makes an input media by itself (T-0072): media is what an
    input *is*.  What this fixture exists to exercise is unchanged -- the third
    video rule, the field's own type, is still the only one that fires.
    """

    return {
        "1": {"class_type": "ExampleMediaLoader", "inputs": {"video": "clip.mp4"}},
        "2": {"class_type": "ExampleTextEncode", "inputs": {"instruction": ""}},
        "3": {
            "class_type": "ExampleSampler",
            "inputs": {"seed": 2, "frames": ["1", 0], "positive": ["2", 0]},
        },
        "4": {
            "class_type": "ExampleSaveImages",
            "inputs": {"filename_prefix": "out", "images": ["3", 0]},
        },
    }


def no_output_stage() -> Dict[str, Any]:
    """A fragment: a prompt and a sampler, and nothing that saves anything."""

    return {
        "1": {"class_type": "ExampleTextEncode", "inputs": {"text": "a quiet street"}},
        "2": {
            "class_type": "ExampleSampler",
            "inputs": {"seed": 5, "positive": ["1", 0]},
        },
    }


def renumbered(graph: Dict[str, Any], offset: int = 700) -> Dict[str, Any]:
    """The same graph with every node id moved, and every wire moved with it."""

    mapping = {node: str(int(node) + offset) for node in graph}
    moved: Dict[str, Any] = {}
    for node, body in graph.items():
        inputs = {}
        for name, value in body["inputs"].items():
            if isinstance(value, list) and len(value) == 2 and value[0] in mapping:
                inputs[name] = [mapping[value[0]], value[1]]
            else:
                inputs[name] = value
        moved[mapping[node]] = {"class_type": body["class_type"], "inputs": inputs}
    return moved


# ==========================================================================
# Helpers
# ==========================================================================


def catalogued(graph: Dict[str, Any]) -> Catalog:
    plan = analyse(graph)
    assert not plan.problems, plan.problems
    assert plan.fields, "this graph produced no field, so nothing was described"
    return describe(plan, graph)


def presented(graph: Dict[str, Any]) -> Dict[str, Any]:
    return catalogued(graph).presentation


def synced(
    workspace: SyncWorkspace, graph: Dict[str, Any], *, name: str = "one"
) -> Tuple[Any, Path]:
    """One whole sync over one graph; the report and the definition's path."""

    folder = workspace.sources[0] if workspace.sources else workspace.add_source()
    write_json(folder / "{}.json".format(name), graph)
    workspace.write_config()
    report = run_sync(workspace.load(), now=FIXED)
    definitions = workspace.repo / "config" / "local" / "workflows"
    return report, definitions / "{}.yaml".format(_slug(name))


def _slug(name: str) -> str:
    return re.sub(r"[^a-z0-9_-]+", "-", name.casefold()).strip("-")


def only_workflow(report):
    assert len(report.workflows) == 1, [item.state for item in report.workflows]
    return report.workflows[0]


def field_named(plan, field_id: str):
    found = [item for item in plan.fields if item.id == field_id]
    assert found, "no field {!r}; there are {}".format(
        field_id, [item.id for item in plan.fields]
    )
    return found[0]


def text_of(presentation: Dict[str, Any]) -> str:
    """Every user-facing string in one presentation, joined."""

    parts: List[str] = []
    for value in presentation.values():
        if isinstance(value, str):
            parts.append(value)
        else:
            parts.extend(value)
    return "\n".join(parts)


# ==========================================================================
# The bar for a description, and the proof that the bar has teeth
# ==========================================================================

#: Words that would be true of half the workflows on earth.  A description
#: made only of these says nothing the graph proved.
_FILLER = frozenset(
    """
    a an the this that these those it its of for and or with without
    using use uses used to into in on from by is are be
    ai artificial intelligence workflow workflows pipeline
    generation generate generates generating generated
    image images picture pictures photo photos art
    model models based your you
    """.split()
)


def reject_empty(text: str) -> None:
    """Refuse a description that names nothing the graph proved.

    This is the card's bar, expressed as a check rather than as a hope.  It is
    proved to fire in :func:`test_the_bar_for_a_description_has_teeth` below,
    because a bar that cannot reject anything is not a bar.
    """

    assert isinstance(text, str) and text.strip(), "there is no description at all"
    words = {word for word in re.findall(r"[a-z]+", text.lower())} - _FILLER
    assert len(words) >= 4, (
        "{!r} is an empty description: once the filler is removed it says "
        "{}".format(text, sorted(words) or "nothing at all")
    )


REJECTED_DESCRIPTIONS = (
    "AI image generation workflow.",
    "An AI workflow that generates images.",
    "Generates images using AI.",
    "Image generation.",
    "This workflow uses a model to generate an image.",
    "A workflow for generating pictures.",
)


def test_the_bar_for_a_description_has_teeth() -> None:
    """The card names one rejected description; here are six, and they fail.

    Without this, ``reject_empty`` could be a function that accepts everything
    and the test below it would pass for no reason at all.
    """

    for description in REJECTED_DESCRIPTIONS:
        with pytest.raises(AssertionError):
            reject_empty(description)
    with pytest.raises(AssertionError):
        reject_empty("")
    # And it does accept something concrete, so it is not simply always false.
    reject_empty("A picture you supply goes in; an enlarged copy of it comes out.")


def test_no_generated_description_is_an_empty_one() -> None:
    """Four structurally different workflows, four different descriptions.

    Asserted verbatim rather than counted: a counted assertion would survive a
    template that produced the same sentence for all four, which is exactly the
    failure ``AI image generation workflow.`` names.
    """

    descriptions = {
        "text_to_image": presented(text_to_image())["short_description"],
        "image_edit": presented(image_edit())["short_description"],
        "text_to_video": presented(text_to_video())["short_description"],
        "upscale": presented(upscale())["short_description"],
    }

    assert descriptions["text_to_image"] == (
        "A written description goes in; a still image comes out. Negative "
        "prompt, Add noise and 9 more settings are kept under Advanced."
    )
    assert descriptions["image_edit"] == (
        "A written description and a picture you supply go in; a still image "
        "comes out. Denoise and Seed are kept under Advanced."
    )
    assert descriptions["text_to_video"] == (
        "A written description goes in; a video clip comes out. Fps, Length "
        "and 2 more settings are kept under Advanced."
    )
    assert descriptions["upscale"] == (
        "A picture you supply goes in; an enlarged copy of it comes out."
    )

    for name, description in descriptions.items():
        assert description not in REJECTED_DESCRIPTIONS, name
        reject_empty(description)
    assert len(set(descriptions.values())) == len(descriptions), descriptions


def test_two_media_inputs_are_counted_and_never_said_twice() -> None:
    """`analysis.py`'s case B, in the sentence a person actually reads.

    A source picture and a semantically distinct reference are two Main media
    fields, which is an ordinary edit-workflow shape and not a curiosity. Said
    once per field, the description read "a written description, a picture you
    supply and a picture you supply go in" -- and three media fields said it
    three times.
    """

    catalog = catalogued(image_and_reference_edit())
    description = catalog.presentation["short_description"]

    assert description == (
        "A written description and two pictures you supply go in; a still "
        "image comes out. Seed is kept under Advanced."
    )
    assert description.count("you supply") == 1
    assert "a picture you supply and a picture you supply" not in description
    assert catalog.presentation["input_summary"] == "Prompt, Image and Reference image"

    # The fixture really has two Main media fields -- otherwise this asserts
    # nothing about the case it is named for.
    plan = analyse(image_and_reference_edit())
    media = [
        item.id for item in plan.fields if item.section == "main" and item.type == "image"
    ]
    assert media == ["image", "reference_image"], media

    # And one media field is still said as one, so the fix is not "always
    # count" in disguise.
    assert presented(image_edit())["short_description"] == (
        "A written description and a picture you supply go in; a still image "
        "comes out. Denoise and Seed are kept under Advanced."
    )


def test_a_workflow_whose_result_is_not_proved_gets_no_description_at_all() -> None:
    """Half the sentence is missing, so the sentence is not written.

    The fragment has a prompt and nothing that saves anything, so nothing in it
    says what comes out.  Omission is the answer; a guess would be a lie in a
    file somebody trusts.
    """

    catalog = catalogued(no_output_stage())

    assert "short_description" not in catalog.presentation
    assert any(
        note.startswith("short_description: ") for note in catalog.notes
    ), catalog.notes
    # Not vacuous: the same generator does write one where the evidence is there.
    assert "short_description" in presented(text_to_image())


# ==========================================================================
# The invariant: no generated string without the rule that produced it
# ==========================================================================


def test_a_generated_key_cannot_be_built_without_its_evidence() -> None:
    """Structural, not a convention: the constructor refuses."""

    for empty in ("", "   ", None):
        with pytest.raises(ValueError):
            CatalogEntry(key="badge", value="VIDEO", evidence=empty)
    with pytest.raises(ValueError):
        CatalogEntry(key="", value="VIDEO", evidence="because the graph says so.")

    entry = CatalogEntry(key="badge", value="VIDEO", evidence="the rate is declared.")
    assert entry.value == "VIDEO"


def test_the_presentation_is_derived_from_the_entries_and_from_nothing_else() -> None:
    """One way in, and the schema's order is what comes out.

    Four keys, chosen so that the schema's order for them differs from
    alphabetical order, from reverse-alphabetical order, from the order they
    were emitted in, and from that order reversed. Those four are what a
    plausible mistake here produces, and the assertions below prove the fixture
    can tell them apart before asserting anything about the code.

    Two keys could not: ``badge`` before ``example_prompt`` is simultaneously
    the schema's order, alphabetical order and reversed-insertion order, so a
    mutation sorting alphabetically and a mutation reversing insertion order
    both survived the older form of this test. ``_merge_presentation`` is the
    second guard over the same property and it does fail on its own -- which is
    exactly why this one has to as well.
    """

    emitted = (
        CatalogEntry("best_for", ("first",), "one."),
        CatalogEntry("short_description", "second", "two."),
        CatalogEntry("group", "third", "three."),
        CatalogEntry("badge", "fourth", "four."),
    )
    expected = ["group", "badge", "short_description", "best_for"]
    emitted_order = [entry.key for entry in emitted]

    assert expected != sorted(expected), "alphabetical order would pass this"
    assert expected != sorted(expected, reverse=True)
    assert expected != emitted_order, "insertion order would pass this"
    assert expected != list(reversed(emitted_order))
    assert set(expected) == set(emitted_order)

    catalog = Catalog(entries=emitted)

    assert list(catalog.presentation) == expected
    assert list(catalog.evidence) == expected
    assert catalog.presentation == {
        "group": "third",
        "badge": "fourth",
        "short_description": "second",
        "best_for": ["first"],
    }
    assert catalog.evidence["group"] == "three."


@pytest.mark.parametrize(
    "builder",
    [
        text_to_image,
        image_edit,
        image_and_reference_edit,
        text_to_video,
        clip_edit,
        upscale,
        no_output_stage,
    ],
    ids=[
        "text_to_image",
        "image_edit",
        "image_and_reference_edit",
        "text_to_video",
        "clip_edit",
        "upscale",
        "no_output_stage",
    ],
)
def test_every_generated_key_names_the_rule_that_produced_it(builder) -> None:
    """``settings_only`` is deliberately not here: it generates nothing at all,
    so it belongs to the test below and would make this one vacuous."""

    catalog = catalogued(builder())

    assert catalog.presentation, "nothing was generated, so nothing was checked"
    assert set(catalog.presentation) == set(catalog.evidence)
    for key, sentence in catalog.evidence.items():
        assert sentence.strip(), key
        assert sentence.rstrip().endswith("."), (key, sentence)
        assert len(sentence.split()) >= 5, (key, sentence)


@pytest.mark.parametrize(
    "builder",
    [
        text_to_image,
        image_edit,
        image_and_reference_edit,
        text_to_video,
        clip_edit,
        upscale,
        settings_only,
        no_output_stage,
    ],
    ids=[
        "text_to_image",
        "image_edit",
        "image_and_reference_edit",
        "text_to_video",
        "clip_edit",
        "upscale",
        "settings_only",
        "no_output_stage",
    ],
)
def test_every_key_is_either_generated_or_named_in_the_notes(builder) -> None:
    """Nothing is quietly missing: a key is written, or the curator is told.

    ``settings_only`` is the extreme of it -- a graph that proves nothing about
    itself gets an empty ``presentation`` and all nine keys named in the notes,
    which is the correct outcome and not a failure to try.
    """

    catalog = catalogued(builder())
    noted = {note.split(":", 1)[0] for note in catalog.notes}

    assert set(catalog.presentation) | noted == set(PRESENTATION_ORDER)
    assert not (set(catalog.presentation) & noted), "a key was both written and noted"


def test_the_catalogue_knows_exactly_the_keys_the_loader_accepts() -> None:
    """A key the schema does not know would be refused at load time."""

    assert set(PRESENTATION_ORDER) == PRESENTATION_KEYS
    assert len(set(PRESENTATION_ORDER)) == len(PRESENTATION_ORDER)


def test_no_category_is_ever_generated() -> None:
    """`docs/workflow-schema.md`'s secondary descriptor is the curator's."""

    for builder in (text_to_image, image_edit, text_to_video, upscale):
        catalog = catalogued(builder())
        assert "category" not in catalog.presentation, builder.__name__
        assert any(note.startswith("category: ") for note in catalog.notes)
        assert "not_ideal_for" not in catalog.presentation, builder.__name__
        assert any(note.startswith("not_ideal_for: ") for note in catalog.notes)


# ==========================================================================
# The prose generator cannot see a file name
# ==========================================================================


def test_the_prose_generator_cannot_be_given_a_source_file_name() -> None:
    """Established by calling it, not by reading it for discipline."""

    parameters = inspect.signature(describe).parameters
    assert list(parameters) == ["plan", "graph"]
    assert all(
        parameter.kind
        in (parameter.POSITIONAL_ONLY, parameter.POSITIONAL_OR_KEYWORD)
        for parameter in parameters.values()
    ), "a **kwargs would let a file name in through the back door"

    graph = text_to_image()
    plan = analyse(graph)
    for keyword in ("source_name", "stem", "file_name", "path", "name"):
        with pytest.raises(TypeError):
            describe(plan, graph, **{keyword: "portrait_v3"})


def test_a_distinctive_file_stem_reaches_the_name_and_nothing_else(
    workspace: SyncWorkspace,
) -> None:
    """The whole sync, with a file named something nothing else could produce."""

    _, definition = synced(workspace, text_to_image(), name="ZzUnmistakableStem")
    document = yaml.safe_load(definition.read_text(encoding="utf-8"))

    assert document["name"] == "ZzUnmistakableStem"
    assert document["presentation"], "there was no prose to look through"
    assert "ZzUnmistakableStem" not in text_of(document["presentation"])
    assert "zzunmistakablestem" not in text_of(document["presentation"]).lower()


def test_the_name_is_the_stem_made_readable_and_claims_nothing_more() -> None:
    assert readable_name("a-small-one") == "A Small One"
    assert readable_name("01_my portrait workflow") == "My Portrait Workflow"
    assert readable_name("02 - Cinematic  Look") == "Cinematic Look"
    assert readable_name("7.evening") == "Evening"
    assert readable_name("2024 vacation") == "2024 Vacation", (
        "four digits is a year somebody meant, not an ordering prefix"
    )
    assert readable_name("MyExport") == "MyExport"
    assert readable_name("   ") == ""
    assert readable_name("01") == "01", "there is nothing left if the prefix goes"


def test_the_readable_name_is_computed_by_a_function_of_its_own() -> None:
    """It feeds ``name`` and nothing else, so it is not part of the prose."""

    parameters = inspect.signature(readable_name).parameters
    assert list(parameters) == ["stem"]
    assert readable_name is not describe


def test_no_class_type_and_no_locked_value_reaches_the_prose() -> None:
    """No model name in the prose, at the one place one could leak in.

    A model, a family or a vendor lives in exactly two places in a graph: the
    node types and the values a loader names its weights with.  Neither may
    reach a sentence a user reads.
    """

    graph = text_to_image()
    for node in graph:
        graph[node]["class_type"] = "ZzVendorSecret" + graph[node]["class_type"]
    graph["4"]["inputs"]["ckpt_name"] = "ZzVendorSecretWeights.safetensors"

    presentation = presented(graph)

    assert "ZzVendorSecret" in json.dumps(graph), "the fixture proves nothing"
    assert presentation, "nothing was generated, so nothing was checked"
    joined = text_of(presentation).lower()
    assert "zzvendorsecret" not in joined
    assert "safetensors" not in joined


def test_a_vocabulary_word_is_matched_as_a_word_and_never_as_an_identifier() -> None:
    """The frozen vocabulary is looked up among words, never in a substring."""

    assert catalog_module.class_words("ExampleVideoCombine") == {
        "example",
        "video",
        "combine",
    }
    assert catalog_module.class_words("VHS_VideoCombine") == {
        "vhs",
        "video",
        "combine",
    }
    assert catalog_module.class_words("SaveImage") == {"save", "image"}
    assert catalog_module.class_words("ExampleProvideoThing") == {
        "example",
        "provideo",
        "thing",
    }, "a vocabulary word was found inside a longer word rather than as a word"
    assert "video" not in catalog_module.class_words("ExampleProvideoThing")
    assert catalog_module.class_words("") == frozenset()
    assert catalog_module.class_words(None) == frozenset()


def test_the_catalogue_reads_a_node_class_type_with_the_importer_s_own_reader() -> None:
    """One reader of ``graph[node]['class_type']``, not two (T-0104).

    The splitter was consolidated into `analysis.py` because two answers to one
    question about another program's document eventually disagree; the reader
    that feeds it is the same question.  A private copy in `catalog.py` agrees
    today and would have to be changed in step for ever, with nothing failing
    when it was changed once -- so what is held is that there is one function.
    """

    from localcanvas_gateway.workflows.sync import analysis as analysis_module

    assert catalog_module._class_type is analysis_module._class_type
    assert catalog_module.class_words is analysis_module.class_words


# ==========================================================================
# badge and group
# ==========================================================================


def test_the_badge_and_the_group_come_from_what_the_graph_consumes_and_makes() -> None:
    assert presented(text_to_image())["badge"] == "TXT2IMG"
    assert presented(text_to_image())["group"] == "Create"
    assert presented(image_edit())["badge"] == "IMG2IMG"
    assert presented(image_edit())["group"] == "Edit"
    assert presented(text_to_video())["badge"] == "VIDEO"
    assert presented(text_to_video())["group"] == "Video"
    assert presented(upscale())["badge"] == "UPSCALE"
    assert presented(upscale())["group"] == "Enhance"


def test_where_the_evidence_does_not_settle_it_both_are_absent() -> None:
    """Not one of the two, and not a plausible default: both, or neither."""

    catalog = catalogued(no_output_stage())

    assert "badge" not in catalog.presentation
    assert "group" not in catalog.presentation
    assert any(note.startswith("badge: ") for note in catalog.notes)
    assert any(note.startswith("group: ") for note in catalog.notes)
    # Not vacuous: with an output stage the same generator writes both.
    assert presented(text_to_image())["badge"] == "TXT2IMG"


def text_to_image_ending_in(class_type: str) -> Dict[str, Any]:
    """:func:`text_to_image` with its output node renamed to ``class_type``."""

    graph = text_to_image()
    graph["9"]["class_type"] = class_type
    return graph


#: Output nodes whose names say where a result leaves the graph and nothing
#: about what it is.  A mesh, a sound or a text leaves through one as well as a
#: picture does.
OUTPUT_NAMES_THAT_SAY_NOTHING_OF_A_PICTURE = [
    pytest.param("ExampleSave", id="save-alone"),
    pytest.param("ExampleSaveMesh", id="save-mesh"),
    pytest.param("ExamplePreview3D", id="preview-3d"),
    pytest.param("ExampleExportModel", id="export"),
]


@pytest.mark.parametrize("output", OUTPUT_NAMES_THAT_SAY_NOTHING_OF_A_PICTURE)
def test_an_output_named_only_for_saving_claims_no_picture(output: str) -> None:
    """T-0268: "save", "preview" or "export" alone is not "a still image".

    The graph is :func:`text_to_image` in every respect but the name of its
    output node, so what differs below is that name's doing.  With nothing
    else saying what comes out, nothing is said: no badge, no group, no short
    description, and no capability that turns a description into a picture.
    """

    words = catalog_module.class_words(output)
    assert words & catalog_module.OUTPUT_WORDS, "the fixture is not named for output"
    assert not words & catalog_module.IMAGE_WORDS, "the fixture is named for a picture"
    assert not words & catalog_module.VIDEO_WORDS

    catalog = catalogued(text_to_image_ending_in(output))
    presentation = catalog.presentation

    assert "badge" not in presentation
    assert "group" not in presentation
    assert "short_description" not in presentation
    assert any(
        note == (
            "short_description: the fields prove nothing that comes out, which is "
            "not enough to say what this workflow does without inventing the other "
            "half."
        )
        for note in catalog.notes
    ), catalog.notes
    assert any(note.startswith("badge: ") for note in catalog.notes), catalog.notes
    assert any(note.startswith("group: ") for note in catalog.notes), catalog.notes
    assert "Turning a written description into a picture" not in presentation.get(
        "best_for", []
    )
    assert "still image" not in text_of(presentation)
    assert "named for saving" not in " ".join(catalog.evidence.values())

    # What goes in is still said: only the claim about what comes out is gone.
    assert presentation["input_summary"] == "Prompt only"

    # Not vacuous: named for saving a picture, the very same graph is one.
    picture = catalogued(text_to_image_ending_in("ExampleSaveImage"))
    assert picture.presentation["badge"] == "TXT2IMG"
    assert picture.presentation["group"] == "Create"
    assert picture.evidence["badge"] == (
        "field 'prompt' is the only thing that goes in, and an output node of "
        "this graph is named for saving a picture."
    )
    assert picture.presentation["short_description"].startswith(
        "A written description goes in; a still image comes out."
    )


def test_an_output_named_only_for_saving_leaves_a_video_a_video() -> None:
    """The video evidence never leaned on the output name, and still does not."""

    graph = text_to_video()
    graph["5"] = {"class_type": "ExampleSave", "inputs": {"images": ["3", 0]}}

    catalog = catalogued(graph)

    assert catalog.presentation["badge"] == "VIDEO"
    assert catalog.presentation["short_description"].startswith(
        "A written description goes in; a video clip comes out."
    )


# ==========================================================================
# best_for
# ==========================================================================


def test_best_for_carries_between_two_and_five_items_each_from_one_rule() -> None:
    catalog = catalogued(text_to_image())

    assert catalog.presentation["best_for"] == [
        "Turning a written description into a picture",
        "Reproducing an exact result by keeping its seed",
        "Choosing the size of the result",
        "Steering the result away from what you do not want",
    ]
    assert 2 <= len(catalog.presentation["best_for"]) <= 5
    for item in catalog.presentation["best_for"]:
        assert repr(item) in catalog.evidence["best_for"], item


def test_best_for_is_absent_rather_than_padded_when_one_rule_fires() -> None:
    """The upscale graph proves one capability, and one is not a list."""

    catalog = catalogued(upscale())

    assert "best_for" not in catalog.presentation
    assert any(note.startswith("best_for: ") for note in catalog.notes), catalog.notes
    # Asserted only after proving the same generator does produce a list where
    # two rules fire, so this absence cannot pass vacuously.
    assert len(presented(text_to_image())["best_for"]) == 4


def test_best_for_never_claims_an_aesthetic_the_graph_does_not_prove() -> None:
    """Capabilities, not use cases nothing in the file supports."""

    for builder in (text_to_image, image_edit, text_to_video):
        items = presented(builder())["best_for"]
        joined = " ".join(items).lower()
        for invented in ("portrait", "anime", "photoreal", "cinematic", "landscape"):
            assert invented not in joined, (builder.__name__, items)


# ==========================================================================
# how_to_use and input_summary
# ==========================================================================


def test_how_to_use_is_practical_sentences_and_never_a_graph_tutorial() -> None:
    catalog = catalogued(text_to_image())
    text = catalog.presentation["how_to_use"]

    assert text == (
        "Describe the subject, the setting and the light you want to see. Use "
        "the negative prompt for anything you do not want in the result. Set "
        "the width and the height before you generate. Keep the seed to get "
        "the same result again, or change it for a different one."
    )
    sentences = [part for part in text.split(". ") if part.strip()]
    assert 2 <= len(sentences) <= 4, sentences
    lowered = text.lower()
    for forbidden in ("node", "class_type", "sampler", "encode", "latent", "graph"):
        assert forbidden not in lowered, forbidden


def test_how_to_use_is_absent_rather_than_padded_at_the_two_sentence_boundary() -> None:
    """One rule firing is not two, and the difference is not made up.

    ``settings_only`` has fields and no Main section at all, so exactly one
    ``how_to_use`` rule fires -- the seed. The minimum is two, and the answer is
    to write none rather than to invent the second.
    """

    catalog = catalogued(settings_only())

    assert "how_to_use" not in catalog.presentation
    assert any(note.startswith("how_to_use: ") for note in catalog.notes), catalog.notes
    assert "fewer than 2 practical sentences" in " ".join(catalog.notes)

    # Exactly one rule was available -- not zero, which would make the boundary
    # untested -- and the same generator writes four sentences where four fire.
    plan = analyse(settings_only())
    assert field_named(plan, "seed").role_hint == "seed"
    assert not [item for item in plan.fields if item.section == "main"]
    assert plan.not_exposed == (), "a locked input would have fired a second rule"
    assert presented(text_to_image())["how_to_use"].count(". ") == 3


def test_input_summary_names_the_main_fields_and_only_them() -> None:
    assert presented(text_to_image())["input_summary"] == "Prompt only"
    assert presented(image_edit())["input_summary"] == "Prompt and Image"
    assert presented(upscale())["input_summary"] == "Image only"
    # Advanced controls are not in it: the seed is Advanced in every graph here.
    assert "Seed" not in presented(text_to_image())["input_summary"]


def test_input_summary_is_absent_when_there_is_no_main_field_to_summarise() -> None:
    """Nothing is asked for up front, so there is nothing to summarise.

    The tempting wrong answer is ``Prompt only`` -- which is what four of the
    five graphs in this file happen to produce, and would be a lie here.
    """

    catalog = catalogued(settings_only())

    assert "input_summary" not in catalog.presentation
    assert any(
        note.startswith("input_summary: ") for note in catalog.notes
    ), catalog.notes
    assert "no Main field" in " ".join(catalog.notes)

    # The fixture has fields -- they are all Advanced -- so this is not the
    # empty-plan case, and the same generator does write a summary elsewhere.
    plan = analyse(settings_only())
    assert [item.id for item in plan.fields] == ["cfg", "denoise", "seed", "steps"]
    assert all(item.section == "advanced" for item in plan.fields)
    assert presented(text_to_image())["input_summary"] == "Prompt only"


# ==========================================================================
# example_prompt -- the four semantics, in order
# ==========================================================================


def test_a_workflow_with_a_prompt_gets_an_example_and_one_without_gets_none() -> None:
    """The absence is asserted only after the presence, never on its own."""

    with_prompt = catalogued(text_to_image())
    assert with_prompt.presentation["example_prompt"] == "a quiet street at dawn"

    without = catalogued(upscale())
    assert "example_prompt" not in without.presentation
    assert any(
        note.startswith("example_prompt: ") for note in without.notes
    ), without.notes
    assert "no prompt-like field" in " ".join(without.notes)


def test_the_graphs_own_prompt_default_is_the_example_verbatim() -> None:
    """The curator's own text out of their own workflow beats any template."""

    graph = text_to_image()
    graph["6"]["inputs"]["text"] = "  a harbour at first light, gulls, cold air  "

    catalog = catalogued(graph)

    assert (
        catalog.presentation["example_prompt"]
        == "  a harbour at first light, gulls, cold air  "
    )
    assert "carries this text in the workflow itself" in catalog.evidence[
        "example_prompt"
    ]


def test_a_prompt_beside_a_required_picture_is_an_instruction_not_a_scene() -> None:
    """The failure the card says a review will look for first."""

    edit = presented(image_edit())["example_prompt"]
    scene = presented(text_to_image_without_a_written_prompt())["example_prompt"]

    assert edit == (
        "Make the sky overcast and the light softer, and leave everything else "
        "as it is"
    )
    assert scene == (
        "A quiet street at dawn, wet cobblestones, soft light and a shallow "
        "depth of field"
    )
    assert edit != scene, "an image-edit workflow was handed a scene description"


def test_a_clip_is_called_a_clip_and_never_a_picture() -> None:
    """The three video rules are not one rule, and the noun follows the type.

    ``clip_edit`` declares no frame rate and no node in it is named for video,
    so the only evidence is the field's own type -- and every sentence about
    what the user supplies has to say "clip".  A workflow that told somebody to
    "pick the picture" when the field takes an mp4 is wrong in a file they
    trust.
    """

    catalog = catalogued(clip_edit())

    assert catalog.presentation["badge"] == "VIDEO"
    assert catalog.evidence["badge"] == (
        "field 'video' takes a clip the user supplies."
    )
    assert catalog.presentation["short_description"] == (
        "A written description and a clip you supply go in; a video clip comes "
        "out. Seed is kept under Advanced."
    )
    assert catalog.presentation["best_for"][0] == (
        "Changing a clip you already have by describing the change"
    )
    assert catalog.presentation["how_to_use"].startswith(
        "Pick the clip you want to change, then describe the change you want."
    )
    assert catalog.presentation["example_prompt"] == (
        "A gentle push in on the clip you supplied, the movement slow and the "
        "framing steady"
    )
    # The same rules over an image say "picture", so the word really follows
    # the field and is not simply hard-coded the other way round.
    assert presented(image_edit())["best_for"][0] == (
        "Changing a picture you already have by describing the change"
    )
    assert "picture" not in text_of(catalog.presentation)


def test_a_graph_that_declares_a_frame_rate_gets_video_guidance() -> None:
    video = presented(text_to_video())["example_prompt"]

    assert video == (
        "A slow push in on a quiet harbour at dawn, the camera steady and the "
        "movement gentle"
    )
    assert video != presented(text_to_image_without_a_written_prompt())["example_prompt"]


def test_a_tag_shaped_negative_prompt_says_nothing_about_the_positive_one() -> None:
    """The claim the deleted tag-style branch used to make, and why it is gone.

    A tag-shaped default on the *negative* prompt -- ``blurry, low quality`` is
    on half the graphs in existence -- used to switch the generated example to
    a tag-shaped template and emit the sentence "the graph's own prompt text is
    written as tags". That sentence was true of the **negative** prompt and
    asserted about the **positive** one, and an untrue sentence in the evidence
    record defeats the invariant this whole module is built on. So these two
    graphs, which differ only in the shape of a negative prompt nobody wrote an
    example for, must be indistinguishable in what they produce.

    The branch was not narrowed to the positive prompt: a non-empty positive
    default is consumed by the verbatim rule above, so a narrowed flag could
    never fire and the templates behind it could never be reached.
    """

    prose = catalogued(negative_prompt_written_as("something blurry and soft."))
    tagged = catalogued(negative_prompt_written_as("blurry, low quality, watermark"))

    assert tagged.presentation["example_prompt"] == (
        "A quiet street at dawn, wet cobblestones, soft light and a shallow "
        "depth of field"
    )
    assert (
        tagged.presentation["example_prompt"] == prose.presentation["example_prompt"]
    )
    assert tagged.evidence["example_prompt"] == prose.evidence["example_prompt"]
    assert "tag" not in tagged.evidence["example_prompt"].lower()

    # The two graphs really do differ, and in the field the deleted branch read.
    negative = field_named(analyse(negative_prompt_written_as(
        "blurry, low quality, watermark"
    )), "negative_prompt")
    assert negative.default == "blurry, low quality, watermark"
    assert field_named(analyse(negative_prompt_written_as(
        "something blurry and soft."
    )), "negative_prompt").default == "something blurry and soft."


def test_every_example_template_is_reachable_and_none_is_a_variant() -> None:
    """Four situations, four templates, and no second axis choosing between them.

    A second axis is what let a claim about one field be made from another. The
    table is now keyed by the situation alone, and every key in it is produced
    by a graph in this file -- so a template nothing can reach cannot sit here
    unnoticed, which is how four of them once did.
    """

    assert sorted(catalog_module._EXAMPLES) == [
        "edit",
        "scene",
        "video",
        "video_edit",
    ]

    produced = {
        presented(text_to_image_without_a_written_prompt())["example_prompt"],
        presented(image_edit())["example_prompt"],
        presented(text_to_video())["example_prompt"],
        presented(clip_edit())["example_prompt"],
    }
    assert len(produced) == 4, produced

    unreachable = {
        key
        for key, template in catalog_module._EXAMPLES.items()
        if not any(template.format(supplied=noun) in produced
                   for noun in ("picture", "clip"))
    }
    assert unreachable == set(), unreachable


# ==========================================================================
# Curated presentation survives a CHANGED sync
# ==========================================================================

CURATED_PRESENTATION = {
    "group": "My own shelf",
    "category": "Photoreal",
    "badge": "EVENING",
    "short_description": "The one I actually reach for after sunset.",
    "best_for": ["Evening light", "Close portraits", "Anything indoors"],
    "how_to_use": "Write the subject. Leave everything else alone.",
    "input_summary": "Just the prompt, honestly",
    "example_prompt": "a lit window on a wet street, exactly as I typed it",
    "not_ideal_for": ["Wide landscapes"],
}


def _write_curated(
    definition: Path,
    generated: Dict[str, Any],
    presentation: Dict[str, Any],
    *,
    name: str = "Evening portraits",
) -> None:
    document = {
        "id": generated["id"],
        "name": name,
        "workflow": generated["workflow"],
        "presentation": presentation,
        "inputs": generated["inputs"],
        "translation": {"mode": "off"},
    }
    definition.write_text(
        yaml.safe_dump(document, sort_keys=False, allow_unicode=True),
        encoding="utf-8",
    )


def test_curated_presentation_survives_a_changed_sync(
    workspace: SyncWorkspace,
) -> None:
    """Every key, by name and by value.  Not a count, not a document compare.

    A counted assertion would survive a merge that kept nine keys and replaced
    their values; comparing whole documents would fail for the right reason and
    the wrong one at once, since ``inputs`` and ``workflow`` are *supposed* to
    change.  So each key is named here, and the value is asserted verbatim.
    """

    folder = workspace.add_source()
    write_json(folder / "one.json", text_to_image())
    workspace.write_config()
    run_sync(workspace.load(), now=FIXED)
    definition = workspace.repo / "config" / "local" / "workflows" / "one.yaml"

    generated = yaml.safe_load(definition.read_text(encoding="utf-8"))
    assert generated["name"] == "One"
    assert generated["presentation"]["badge"] == "TXT2IMG", (
        "there was nothing here for a curator's words to have to survive"
    )
    steps_before = _field(generated, "steps")["default"]
    assert steps_before == 24

    _write_curated(definition, generated, dict(CURATED_PRESENTATION))

    # The graph really changes: renumbered from end to end and edited.
    changed = renumbered(text_to_image())
    changed["703"]["inputs"]["steps"] = 40
    write_json(folder / "one.json", changed)

    report = run_sync(workspace.load(), now=FIXED)

    assert only_workflow(report).state is WorkflowState.CHANGED
    assert only_workflow(report).definition.written is True
    after = yaml.safe_load(definition.read_text(encoding="utf-8"))

    # -- the words, one at a time --------------------------------------
    assert after["name"] == "Evening portraits"
    assert after["translation"] == {"mode": "off"}
    assert after["presentation"]["group"] == "My own shelf"
    assert after["presentation"]["category"] == "Photoreal"
    assert after["presentation"]["badge"] == "EVENING"
    assert after["presentation"]["short_description"] == (
        "The one I actually reach for after sunset."
    )
    assert after["presentation"]["best_for"] == [
        "Evening light",
        "Close portraits",
        "Anything indoors",
    ]
    assert after["presentation"]["how_to_use"] == (
        "Write the subject. Leave everything else alone."
    )
    assert after["presentation"]["input_summary"] == "Just the prompt, honestly"
    assert after["presentation"]["example_prompt"] == (
        "a lit window on a wet street, exactly as I typed it"
    )
    assert after["presentation"]["not_ideal_for"] == ["Wide landscapes"]
    assert set(after["presentation"]) == set(CURATED_PRESENTATION)

    # -- the structure, regenerated ------------------------------------
    assert _field(after, "steps")["default"] == 40
    assert _field(after, "steps")["bind"] == [{"node": "703", "input": "steps"}]
    assert _field(generated, "steps")["bind"] == [{"node": "3", "input": "steps"}], (
        "the graph did not move, so 'bind was regenerated' proved nothing"
    )
    assert [item["id"] for item in after["inputs"]] == [
        item["id"] for item in generated["inputs"]
    ]

    # -- and the file still loads --------------------------------------
    registry = load_registry(definition.parent)
    assert registry.diagnostics == ()
    assert registry.workflows[0].presentation.badge == "EVENING"
    assert registry.workflows[0].name == "Evening portraits"


def test_a_key_the_curator_deleted_comes_back_from_this_run(
    workspace: SyncWorkspace,
) -> None:
    """Absent means "fill it"; present means "leave it".  There is no third state.

    This is the whole reason the rule is "what is written wins" rather than
    "what the generator wrote last time loses": a curator who deletes a key can
    see what they did, and gets a fresh one.
    """

    folder = workspace.add_source()
    write_json(folder / "one.json", text_to_image())
    workspace.write_config()
    run_sync(workspace.load(), now=FIXED)
    definition = workspace.repo / "config" / "local" / "workflows" / "one.yaml"
    generated = yaml.safe_load(definition.read_text(encoding="utf-8"))

    kept = dict(CURATED_PRESENTATION)
    del kept["input_summary"]
    del kept["example_prompt"]
    _write_curated(definition, generated, kept)

    changed = text_to_image()
    changed["3"]["inputs"]["steps"] = 40
    write_json(folder / "one.json", changed)
    run_sync(workspace.load(), now=FIXED)

    after = yaml.safe_load(definition.read_text(encoding="utf-8"))

    assert after["presentation"]["input_summary"] == "Prompt only"
    assert after["presentation"]["example_prompt"] == "a quiet street at dawn"
    assert after["presentation"]["badge"] == "EVENING", (
        "a key the curator kept was refilled too, so the rule is not 'what is "
        "written wins' at all"
    )
    assert after["presentation"]["short_description"] == (
        "The one I actually reach for after sunset."
    )


def test_a_curated_key_the_schema_does_not_know_is_carried_and_not_dropped(
    workspace: SyncWorkspace,
) -> None:
    """Somebody's typo is still somebody's words.

    Dropping it would silently edit their file and make a broken definition
    load, which is worse than a diagnostic that names the key.
    """

    folder = workspace.add_source()
    write_json(folder / "one.json", text_to_image())
    workspace.write_config()
    run_sync(workspace.load(), now=FIXED)
    definition = workspace.repo / "config" / "local" / "workflows" / "one.yaml"
    generated = yaml.safe_load(definition.read_text(encoding="utf-8"))

    typo = dict(CURATED_PRESENTATION)
    typo["best_fro"] = ["the one I meant to write"]
    _write_curated(definition, generated, typo)
    before = definition.read_bytes()

    changed = text_to_image()
    changed["3"]["inputs"]["steps"] = 40
    write_json(folder / "one.json", changed)
    report = run_sync(workspace.load(), now=FIXED)

    item = only_workflow(report)
    assert item.state is WorkflowState.NEEDS_REVIEW
    assert item.definition.written is False
    assert "best_fro" in item.definition.problem
    assert definition.read_bytes() == before, "their file was written over anyway"


# ==========================================================================
# A definition on disk that cannot be read
# ==========================================================================


@pytest.mark.parametrize(
    "body, detail",
    [
        ("name: [unclosed\n", "could not be read"),
        ("- one\n- two\n", "top level is a list"),
        ("id: one\nname: One\npresentation: nope\n", "'presentation' is a str"),
    ],
    ids=["not_yaml", "not_a_mapping", "presentation_is_not_a_mapping"],
)
def test_a_definition_that_cannot_be_read_is_never_written_over(
    workspace: SyncWorkspace, body: str, detail: str
) -> None:
    """It may hold words somebody wrote, and this run cannot tell which.

    So it is not overwritten and it is not ignored: this one workflow says why,
    and the file is left byte for byte as it was.
    """

    folder = workspace.add_source()
    write_json(folder / "one.json", text_to_image())
    workspace.write_config()
    run_sync(workspace.load(), now=FIXED)
    definition = workspace.repo / "config" / "local" / "workflows" / "one.yaml"

    definition.write_text(body, encoding="utf-8")
    before = definition.read_bytes()

    changed = text_to_image()
    changed["3"]["inputs"]["steps"] = 40
    write_json(folder / "one.json", changed)
    report = run_sync(workspace.load(), now=FIXED)

    item = only_workflow(report)
    assert item.state is WorkflowState.NEEDS_REVIEW
    assert item.definition.written is False
    assert item.definition.problem is not None
    assert detail in item.definition.problem, item.definition.problem
    assert str(definition) in item.definition.problem
    assert definition.read_bytes() == before


def test_one_unreadable_definition_never_stops_the_others(
    workspace: SyncWorkspace,
) -> None:
    folder = workspace.add_source()
    write_json(folder / "one.json", text_to_image())
    write_json(folder / "two.json", image_edit())
    workspace.write_config()
    run_sync(workspace.load(), now=FIXED)

    definitions = workspace.repo / "config" / "local" / "workflows"
    (definitions / "one.yaml").write_text("name: [unclosed\n", encoding="utf-8")

    changed_one = text_to_image()
    changed_one["3"]["inputs"]["steps"] = 40
    write_json(folder / "one.json", changed_one)
    changed_two = image_edit()
    changed_two["4"]["inputs"]["denoise"] = 0.9
    write_json(folder / "two.json", changed_two)

    report = run_sync(workspace.load(), now=FIXED)

    by_id = {item.id: item for item in report.workflows}
    assert by_id["one"].definition.written is False
    assert by_id["one"].definition.problem is not None
    assert by_id["two"].definition.written is True
    two = yaml.safe_load((definitions / "two.yaml").read_text(encoding="utf-8"))
    assert _field(two, "denoise")["default"] == 0.9


# ==========================================================================
# Determinism, and what the report says
# ==========================================================================


def test_two_runs_over_the_same_bytes_produce_the_same_presentation(
    tmp_path: Path,
) -> None:
    """Two workspaces rather than two runs: a second run in one workspace also
    passes for an importer that noticed the file was there and left it alone.
    """

    graph = text_to_image()
    produced = []
    for index in range(2):
        workspace = SyncWorkspace(tmp_path / "run {}".format(index))
        folder = workspace.add_source()
        write_json(folder / "one.json", graph)
        workspace.write_config()
        run_sync(workspace.load(), now=FIXED)
        produced.append(
            (workspace.repo / "config" / "local" / "workflows" / "one.yaml").read_bytes()
        )

    assert produced[0] == produced[1]
    assert b"presentation:" in produced[0], "the runs produced no presentation"
    assert b"short_description:" in produced[0]
    assert b"example_prompt:" in produced[0]


def test_the_report_carries_what_was_generated_and_what_was_left_to_the_curator(
    workspace: SyncWorkspace,
) -> None:
    report, _ = synced(workspace, upscale())

    document = report_document(report)
    definition = document["workflows"][0]["definition"]

    assert definition["presentation"]["badge"] == "UPSCALE"
    assert definition["presentation"]["group"] == "Enhance"
    assert definition["presentation"]["input_summary"] == "Image only"
    assert "example_prompt" not in definition["presentation"]
    assert "category" not in definition["presentation"]

    prefixes = [note.split(":", 1)[0] for note in definition["notes"]]
    assert prefixes == ["category", "best_for", "example_prompt", "not_ideal_for"], (
        definition["notes"]
    )
    # Still ASCII on the wire, which is what crosses the pipe on Windows.
    assert json.dumps(document, ensure_ascii=True) == json.dumps(
        document, ensure_ascii=False
    )


def test_a_dry_run_still_says_what_it_would_have_written(
    workspace: SyncWorkspace,
) -> None:
    folder = workspace.add_source()
    write_json(folder / "one.json", text_to_image())
    workspace.write_config()

    report = run_sync(workspace.load(), dry_run=True, now=FIXED)

    definition = only_workflow(report).definition
    assert definition.written is False
    assert definition.presentation["badge"] == "TXT2IMG"
    assert definition.notes
    assert not (workspace.repo / "config" / "local" / "workflows").exists()


# ==========================================================================
# No network, no backend -- and a guard proved able to fire
# ==========================================================================

#: Roots that would mean this module talks to something, or leans on a model.
#: ``asyncio`` and ``subprocess`` are here because either would be a way to
#: reach a network without naming one.
FORBIDDEN_ROOTS = frozenset(
    {
        "aiohttp",
        "anthropic",
        "argostranslate",
        "asyncio",
        "ctranslate2",
        "deep_translator",
        "ftplib",
        "googletrans",
        "http",
        "httpx",
        "openai",
        "requests",
        "smtplib",
        "socket",
        "ssl",
        "subprocess",
        "telnetlib",
        "tokenizers",
        "torch",
        "transformers",
        "urllib",
        "urllib3",
        "webbrowser",
        "websockets",
        "xmlrpc",
    }
)

#: Modules under a forbidden root that may be imported, by their **full** name
#: and only by it.  ``urllib.parse`` splits a string into its parts and opens
#: nothing; `semantics.py` reads a web address with it (T-0267, T-0082).  The
#: bare ``urllib`` package and every other module in it -- ``request``,
#: ``error``, ``response``, ``robotparser`` -- stay forbidden, and so does
#: ``from urllib import parse``: the allowance is a module name, not a root.
ALLOWED_MODULES = frozenset({"urllib.parse"})

#: Ways to import something without writing an import statement.
_DYNAMIC = frozenset({"__import__", "eval", "exec", "compile"})


def _forbidden_in(
    path: Path,
    package: Optional[Path] = None,
    seen: Optional[Set[Path]] = None,
) -> Set[str]:
    """Every forbidden root reachable from ``path``, following its own imports.

    Read as source, so a network import that is never executed still fails, and
    followed through ``package``'s own relative imports, so a module that
    reached a backend one hop away would not slip past.
    """

    package = SYNC_PACKAGE if package is None else package
    seen = set() if seen is None else seen
    resolved = path.resolve()
    if resolved in seen:
        return set()
    seen.add(resolved)

    tree = ast.parse(resolved.read_text(encoding="utf-8"), filename=str(resolved))
    found: Set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                found |= _check(alias.name)
        elif isinstance(node, ast.ImportFrom):
            if node.level == 0 and node.module:
                found |= _check(node.module)
            elif node.level == 1:
                for sibling in _siblings(node):
                    neighbour = package / "{}.py".format(sibling)
                    if neighbour.exists():
                        found |= _forbidden_in(neighbour, package, seen)
        elif isinstance(node, ast.Name) and node.id in _DYNAMIC:
            found.add(node.id)
        elif isinstance(node, ast.Attribute) and node.attr == "import_module":
            found.add("importlib")
    return found


def _siblings(node: ast.ImportFrom) -> Iterable[str]:
    if node.module:
        return [node.module.split(".")[0]]
    return [alias.name for alias in node.names]


def _check(module: str) -> Set[str]:
    if module in ALLOWED_MODULES:
        return set()
    root = module.split(".")[0]
    return {root} if root in FORBIDDEN_ROOTS else set()


def test_nothing_the_catalogue_imports_reaches_a_network_or_a_backend() -> None:
    assert _forbidden_in(CATALOG_SOURCE) == set()
    # The scan really ran over the module it was meant to.
    assert "def describe(" in CATALOG_SOURCE.read_text(encoding="utf-8")


def test_that_guard_fires_on_a_backend_this_machine_can_genuinely_import(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The vacuity check the card asks for, done the way it asks.

    ``deep_translator`` is not installed here, so a guard that merely watched
    for a failed import would pass for the wrong reason for ever.  A stub of it
    goes on ``sys.path`` and is imported for real, so the import genuinely
    succeeds on this machine -- and only then is the guard asked about a copy of
    ``catalog.py`` that imports it.
    """

    (tmp_path / "deep_translator.py").write_text(
        "VERSION = 'stub for a test'\n", encoding="utf-8"
    )
    monkeypatch.syspath_prepend(str(tmp_path))
    try:
        stub = importlib.import_module("deep_translator")
        assert stub.VERSION == "stub for a test", (
            "the stub did not import, so nothing was proved about the guard"
        )

        source = CATALOG_SOURCE.read_text(encoding="utf-8")
        tainted = tmp_path / "tainted_catalog.py"
        tainted.write_text("import deep_translator\n" + source, encoding="utf-8")

        assert _forbidden_in(tainted) == {"deep_translator"}
        # And the real module, checked while the backend is importable, is
        # still clean -- so the clean result above was not a missing library.
        assert _forbidden_in(CATALOG_SOURCE) == set()
    finally:
        sys.modules.pop("deep_translator", None)


def test_the_two_guards_over_this_property_each_catch_what_the_other_misses(
    tmp_path: Path,
) -> None:
    """Two guards protect "the sync does not talk to anything", and neither is
    redundant: the package-wide substring lint in ``test_sync_engine.py`` sees a
    *mention*, and the import scan here sees a *reachable import*.  Each is
    given something the other lets through.
    """

    source = CATALOG_SOURCE.read_text(encoding="utf-8")
    lint_patterns = ("import socket", "import httpx", "import urllib", "webbrowser")

    hidden = tmp_path / "hidden.py"
    hidden.write_text("from httpx import AsyncClient\n" + source, encoding="utf-8")
    hidden_text = hidden.read_text(encoding="utf-8")
    assert not any(pattern in hidden_text for pattern in lint_patterns), (
        "the substring lint would have caught this, so it proves nothing"
    )
    assert _forbidden_in(hidden) == {"httpx"}

    mentioned = tmp_path / "mentioned.py"
    mentioned.write_text(source + "\n_HINT = 'webbrowser'\n", encoding="utf-8")
    assert _forbidden_in(mentioned) == set(), (
        "the import scan would have caught this, so it proves nothing"
    )
    assert "webbrowser" in mentioned.read_text(encoding="utf-8")


def test_a_reachable_backend_one_hop_away_is_caught_too(tmp_path: Path) -> None:
    """The scan follows the package's own relative imports.

    Otherwise ``catalog.py`` could stay clean while the module beside it, which
    it imports, did the talking.  Proved in a package of this test's own making
    -- the real one is never written to, and a sibling that reaches a backend is
    exactly what has to be caught.
    """

    assert "from . import semantics" in CATALOG_SOURCE.read_text(encoding="utf-8"), (
        "catalog.py no longer imports semantics.py, so this test follows nothing"
    )
    assert _forbidden_in(SYNC_PACKAGE / "semantics.py") == set()
    assert _forbidden_in(SYNC_PACKAGE / "analysis.py") == set()

    package = tmp_path / "pretend_package"
    package.mkdir()
    (package / "innocent.py").write_text(
        "from . import helper\n\n\ndef describe(plan, graph):\n    return helper\n",
        encoding="utf-8",
    )
    (package / "helper.py").write_text("import torch\n", encoding="utf-8")

    assert _forbidden_in(package / "innocent.py", package) == {"torch"}, (
        "a backend one hop away was not followed, so the scan of catalog.py "
        "says nothing about what catalog.py imports"
    )
    (package / "helper.py").write_text("VALUE = 1\n", encoding="utf-8")
    assert _forbidden_in(package / "innocent.py", package) == set()


def test_the_guard_lets_exactly_urllib_parse_through_the_real_chain(
    tmp_path: Path,
) -> None:
    """``urllib.parse`` is allowed and nothing else under ``urllib`` is (T-0082).

    Both halves are asked of the catalogue's **real** import chain, copied: the
    copy as it stands passes although `semantics.py` imports ``urllib.parse``,
    and the same copy with ``urllib.request`` imported one hop away from
    ``catalog.py`` fails.  The real package is never written to.
    """

    semantics_source = (SYNC_PACKAGE / "semantics.py").read_text(encoding="utf-8")
    assert "from urllib.parse import urlsplit" in semantics_source, (
        "semantics.py no longer imports urllib.parse, so the allowance below "
        "is exercised by nothing"
    )

    copy = tmp_path / "sync_copy"
    copy.mkdir()
    for module in SYNC_PACKAGE.glob("*.py"):
        (copy / module.name).write_text(module.read_text(encoding="utf-8"), encoding="utf-8")
    assert _forbidden_in(copy / "catalog.py", copy) == set()

    (copy / "semantics.py").write_text(
        semantics_source + "\nfrom urllib.request import urlopen\n", encoding="utf-8"
    )
    assert _forbidden_in(copy / "catalog.py", copy) == {"urllib"}, (
        "urllib.request one hop from the catalogue passed the guard"
    )


@pytest.mark.parametrize(
    "statement,expected",
    [
        pytest.param("from urllib.parse import urlsplit", set(), id="from-parse"),
        pytest.param("import urllib.parse", set(), id="import-parse"),
        pytest.param("from urllib.request import urlopen", {"urllib"}, id="from-request"),
        pytest.param("import urllib.request", {"urllib"}, id="import-request"),
        pytest.param("import urllib", {"urllib"}, id="import-package"),
        pytest.param("from urllib import request", {"urllib"}, id="from-package-request"),
        pytest.param("from urllib import parse", {"urllib"}, id="from-package-parse"),
        pytest.param("import urllib.error", {"urllib"}, id="import-error"),
        pytest.param("import urllib.response", {"urllib"}, id="import-response"),
        pytest.param("from urllib.robotparser import RobotFileParser", {"urllib"}, id="robotparser"),
        pytest.param("import urllib.parse.extra", {"urllib"}, id="below-parse"),
        pytest.param("import urllib3", {"urllib3"}, id="urllib3"),
    ],
)
def test_the_urllib_allowance_is_one_module_name(
    tmp_path: Path, statement: str, expected: Set[str]
) -> None:
    """Every spelling of a ``urllib`` import, one hop from the scanned module."""

    package = tmp_path / "pretend_package"
    package.mkdir()
    (package / "innocent.py").write_text(
        "from . import helper\n\n\ndef describe(plan, graph):\n    return helper\n",
        encoding="utf-8",
    )
    (package / "helper.py").write_text(statement + "\n", encoding="utf-8")

    assert _forbidden_in(package / "innocent.py", package) == expected


def test_generating_prose_never_opens_a_socket(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A guard proved to fire on this very process, at the end of the test."""

    def refuse(*args, **kwargs):
        raise AssertionError("the catalogue opened a socket")

    monkeypatch.setattr(socket, "socket", refuse)
    monkeypatch.setattr(socket, "create_connection", refuse)
    monkeypatch.setattr(socket, "getaddrinfo", refuse)

    for builder in (text_to_image, image_edit, text_to_video, upscale):
        catalog = catalogued(builder())
        assert catalog.presentation

    with pytest.raises(AssertionError, match="opened a socket"):
        socket.socket()


# ==========================================================================
# Small helpers used above
# ==========================================================================


def _field(document: Dict[str, Any], field_id: str) -> Dict[str, Any]:
    found = [item for item in document["inputs"] if item["id"] == field_id]
    assert found, "no field {!r}; there are {}".format(
        field_id, [item["id"] for item in document["inputs"]]
    )
    return found[0]


def test_the_merge_is_a_function_and_can_be_asked_directly() -> None:
    """The curated overlay, on its own, without a filesystem in the way."""

    plan = analyse(text_to_image())
    catalog = describe(plan, text_to_image())
    curated = definitions_module.CuratedDefinition(
        document={"name": "Mine", "presentation": {"badge": "MINE"}}
    )

    document = definitions_module.definition_document(
        plan,
        workflow_id="one",
        name="One",
        workflow_relative="g.json",
        presentation=catalog.presentation,
        curated=curated,
    )

    assert document["name"] == "Mine"
    assert document["presentation"]["badge"] == "MINE"
    assert document["presentation"]["group"] == "Create", (
        "a key the curator did not write was not filled from this run"
    )
    assert "translation" not in document, "the curator wrote none, so none is written"
