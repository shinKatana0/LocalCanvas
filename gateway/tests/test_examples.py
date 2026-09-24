"""The repository's public examples must actually validate.

`workflows/examples` is what an unrelated user copies. If the validator and the
examples ever disagree, one of them is wrong and this suite says so.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from conftest import EXAMPLES_ROOT, only
from localcanvas_gateway.workflows import FieldPair, FieldRole, FieldType, load_registry

EXPECTED_IDS = ("example_img2img", "example_txt2img", "example_video")

#: Everything the three shipped examples show the app, captured from the tree
#: before T-0045 touched `bind:` and committed unchanged since.  The gateway is
#: free to grow new binding shapes; what an unrelated user's phone renders is
#: not free to move underneath them.
VIEW_PIN = Path(__file__).resolve().parent / "data" / "example_views_pin.json"

#: The keys a field may show the app.  Anything else is a leak.
ALLOWED_FIELD_VIEW_KEYS = {
    "id",
    "label",
    "type",
    "required",
    "section",
    "default",
    "help",
    "min",
    "max",
    "step",
    "options",
    "role",
    "pair",
}


@pytest.fixture(scope="module")
def examples():
    return load_registry(EXAMPLES_ROOT)


def views_of(registry):
    """Every view the three examples produce, serialized the one same way."""

    return {
        workflow.id: {
            "summary_view": workflow.summary_view(),
            "detail_view": workflow.detail_view(),
            "field_views": [field.to_view() for field in workflow.inputs],
            "presentation_view": workflow.presentation.to_view(),
        }
        for workflow in registry
    }


def test_the_shipped_examples_views_are_byte_identical_to_the_pin(examples):
    """Backwards compatibility, checked rather than assumed.

    The pin was written from the tree as it stood before `bind:` learned a
    second shape, so a change that quietly altered what the app receives --
    a reordered field, a dropped key, a default that stopped being emitted --
    fails here rather than on somebody's phone.
    """

    serialized = (
        json.dumps(views_of(examples), indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    )
    assert serialized == VIEW_PIN.read_text(encoding="utf-8")


def test_every_shipped_example_graph_imports_through_the_real_importer():
    """What an unrelated user who copies the examples and runs a sync sees (T-0081).

    Each placeholder standing where a user's weights go carries a file suffix,
    so the weights-suffix branch locks it and nothing is left for review.  The
    video example's used to carry none and came back ``NEEDS_REVIEW`` with no
    definition written; the importer was right to refuse it, the example was
    what was wrong.
    """

    from localcanvas_gateway.workflows.sync import analyse

    graphs = sorted(EXAMPLES_ROOT.glob("*_api.json"))
    assert [path.name for path in graphs] == [
        "example_img2img_api.json",
        "example_txt2img_api.json",
        "example_video_api.json",
    ], "an example was added or renamed; this test would no longer cover all of them"

    for path in graphs:
        plan = analyse(json.loads(path.read_text(encoding="utf-8")))
        assert plan.problems == (), path.name
        assert plan.needs_review is False, path.name

    video = analyse(
        json.loads((EXAMPLES_ROOT / "example_video_api.json").read_text(encoding="utf-8"))
    )
    loader = only(
        entry for entry in video.controls if (entry.node, entry.input) == ("1", "model_name")
    )
    assert (loader.section, loader.kind) == ("locked", "weights_file")


def test_every_example_loads_without_a_single_diagnostic(examples):
    assert [str(diagnostic) for diagnostic in examples.diagnostics] == []
    assert examples.ids == EXPECTED_IDS


def test_the_three_v01_shapes_are_present(examples):
    prompt_only = examples.get("example_txt2img")
    image_input = examples.get("example_img2img")
    video_input = examples.get("example_video")

    assert prompt_only.required_media == ()
    assert image_input.required_media == ("image",)
    assert video_input.required_media == ("video",)

    assert prompt_only.presentation.badge == "TXT2IMG"
    assert image_input.presentation.badge == "IMG2IMG"
    assert video_input.presentation.badge == "VIDEO"


def test_examples_between_them_exercise_all_eight_field_types(examples):
    used = {field.type for workflow in examples for field in workflow.inputs}
    assert used == set(FieldType)


def test_examples_carry_presentation_hints(examples):
    txt2img = examples.get("example_txt2img")
    assert txt2img.field("seed").role is FieldRole.SEED
    assert txt2img.field("width").pair is FieldPair.WIDTH
    assert txt2img.field("height").pair is FieldPair.HEIGHT
    assert txt2img.field("steps").role is None
    assert txt2img.field("steps").pair is None


def test_a_yaml_integer_node_id_binds_like_the_json_string_key(examples):
    """example_txt2img writes `node: 40`; the JSON keys that node "40"."""

    txt2img = examples.get("example_txt2img")
    steps = only(txt2img.bindings_for("steps"))
    assert steps.node == "40"
    assert steps.node in txt2img.graph


def test_no_node_id_is_reachable_from_the_presentation_view(examples):
    for workflow in examples:
        view = workflow.detail_view()
        for field_view in view["inputs"]:
            assert set(field_view) <= ALLOWED_FIELD_VIEW_KEYS, field_view

        serialized = json.dumps(view)
        assert "bind" not in serialized
        assert "class_type" not in serialized
        for targets in workflow.bindings.values():
            for binding in targets:
                # The node id and its input key never appear together in the view.
                assert not (
                    '"{}"'.format(binding.node) in serialized
                    and '"{}"'.format(binding.input) in serialized
                )


def test_examples_name_no_model_family_or_developer_path(examples):
    """The examples are public: placeholder content only."""

    forbidden = ("flux", "sdxl", "qwen", "krea", "stable-diffusion", "c:\\users", "/home/")
    for workflow in examples:
        for path in (workflow.source, workflow.workflow_path):
            text = path.read_text(encoding="utf-8").lower()
            for needle in forbidden:
                assert needle not in text, "{} names {!r}".format(path, needle)
