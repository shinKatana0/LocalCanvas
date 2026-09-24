"""Discovery, ordering, duplicate ids, and the two failure classes."""

from __future__ import annotations

import os
from pathlib import Path

import pytest

from conftest import PROMPT_FIELD, RegistryBuilder, graph_copy
from localcanvas_gateway.workflows import RegistryError, load_registry


def field_for(node="20", input_key="text"):
    return (
        "- id: prompt\n  label: Prompt\n  type: multiline\n"
        '  bind: {{node: "{}", input: {}}}'.format(node, input_key)
    )


# -- ordering --------------------------------------------------------------


def test_workflows_are_ordered_by_id_not_by_filename(builder):
    """The file named first on disk holds the id that sorts last."""

    builder.add("aaa_file", PROMPT_FIELD, workflow_id="zulu")
    builder.add("mmm_file", PROMPT_FIELD, workflow_id="mike")
    builder.add("zzz_file", PROMPT_FIELD, workflow_id="alpha")

    registry = builder.load()
    assert registry.ids == ("alpha", "mike", "zulu")


def test_ordering_is_plain_codepoint_order_not_locale_collation(builder):
    """'-' (U+002D) < '_' (U+005F) < 'b'; a collation that ignores punctuation differs."""

    for index, workflow_id in enumerate(("ab", "a_b", "a-b")):
        builder.add("file{}".format(index), PROMPT_FIELD, workflow_id=workflow_id)

    assert builder.load().ids == ("a-b", "a_b", "ab")


def test_two_runs_over_one_registry_produce_identical_output(builder):
    builder.add("one", PROMPT_FIELD, workflow_id="zulu")
    builder.add("two", PROMPT_FIELD, workflow_id="alpha")
    builder.add("broken_b", field_for(node="999"), workflow_id="b_broken")
    builder.add("broken_a", field_for(node="998"), workflow_id="a_broken")

    first, second = builder.load(), builder.load()
    assert first.ids == second.ids
    assert [str(item) for item in first.diagnostics] == [str(item) for item in second.diagnostics]
    # Diagnostics are ordered by workflow id, the same rule as the workflows.
    assert [item.workflow_id for item in first.diagnostics] == ["a_broken", "b_broken"]


# -- discovery -------------------------------------------------------------


def test_definitions_are_found_in_subfolders_and_with_either_suffix(builder):
    builder.add("top", PROMPT_FIELD, workflow_id="top")
    builder.add("nested", PROMPT_FIELD, workflow_id="nested", subdir="deeper/still")
    builder.write(
        "short_suffix",
        "id: short_suffix\nname: N\nworkflow: short_suffix_api.json\ninputs: []\n",
        graph=graph_copy(),
        suffix=".yml",
    )

    assert builder.load().ids == ("nested", "short_suffix", "top")


def test_dot_directories_are_not_scanned(builder):
    builder.add("real", PROMPT_FIELD, workflow_id="real")
    builder.add("hidden", PROMPT_FIELD, workflow_id="hidden", subdir=".cache")

    assert builder.load().ids == ("real",)


def test_a_json_file_alone_is_not_a_workflow(builder):
    (builder.root).mkdir(parents=True, exist_ok=True)
    (builder.root / "stray_api.json").write_text("{}", encoding="utf-8")

    registry = builder.load()
    assert registry.workflows == ()
    assert registry.diagnostics == ()


# -- duplicate ids ---------------------------------------------------------


def test_duplicate_ids_reject_both_claimants_and_name_both_files(builder):
    first = builder.add("first_file", PROMPT_FIELD, workflow_id="twin")
    second = builder.add("second_file", PROMPT_FIELD, workflow_id="twin")
    builder.add("innocent", PROMPT_FIELD, workflow_id="innocent")

    registry = builder.load()

    # Nothing is silently shadowed: neither claimant loads.
    assert registry.ids == ("innocent",)
    assert registry.get("twin") is None

    diagnostics = [item for item in registry.diagnostics if item.workflow_id == "twin"]
    assert len(diagnostics) == 2
    assert {item.source for item in diagnostics} == {first, second}
    for diagnostic in diagnostics:
        assert "duplicate workflow id 'twin'" in diagnostic.message
        other = second if diagnostic.source == first else first
        assert str(other) in diagnostic.message


def test_a_broken_claimant_still_claims_the_id(builder):
    """The duplicate check keys off the id a definition claims, not off validity.

    Otherwise fixing an unrelated typo in one file flips the *other* workflow
    from working to both-rejected -- which is precisely the surprise rejecting
    both claimants exists to prevent.
    """

    good = builder.add("first_file", PROMPT_FIELD, workflow_id="twin")
    broken = builder.add("second_file", field_for(node="999"), workflow_id="twin")

    registry = builder.load()

    assert registry.get("twin") is None
    assert registry.workflows == ()

    duplicates = [
        item for item in registry.diagnostics if "duplicate workflow id" in item.message
    ]
    assert {item.source for item in duplicates} == {good, broken}
    for diagnostic in duplicates:
        assert diagnostic.workflow_id == "twin"
        other = broken if diagnostic.source == good else good
        assert str(other) in diagnostic.message

    # The broken claimant still reports its own problem as well.
    assert any("bind.node '999'" in item.message for item in registry.diagnostics)


def test_a_claimant_broken_before_its_id_is_read_still_claims_it(builder):
    """The same guarantee when the definition fails earlier than its `id:` line.

    An unknown top-level key is found before the id is parsed, so this is the
    case where "record the claim only if nothing has gone wrong yet" would
    quietly let the other claimant through.
    """

    good = builder.add("first_file", PROMPT_FIELD, workflow_id="twin")
    broken = builder.write(
        "second_file",
        "input: []\nid: twin\nname: N\nworkflow: second_file_api.json\ninputs: []\n",
        graph=graph_copy(),
    )

    registry = builder.load()

    assert registry.get("twin") is None
    duplicates = [
        item for item in registry.diagnostics if "duplicate workflow id" in item.message
    ]
    assert {item.source for item in duplicates} == {good, broken}


def test_three_claimants_are_all_rejected(builder):
    for index in range(3):
        builder.add("file{}".format(index), PROMPT_FIELD, workflow_id="twin")

    registry = builder.load()
    assert registry.workflows == ()
    assert len(registry.diagnostics) == 3


# -- isolation -------------------------------------------------------------


def test_one_broken_workflow_does_not_take_the_registry_down(builder):
    builder.add("good_one", PROMPT_FIELD, workflow_id="good_one")
    builder.add("good_two", PROMPT_FIELD, workflow_id="good_two")
    builder.write("unparseable", "id: [unclosed\n", graph=graph_copy())
    builder.add("bad_bind", field_for(node="999"), workflow_id="bad_bind")
    builder.add("no_json", PROMPT_FIELD, workflow_id="no_json", write_json=False)

    registry = builder.load()
    assert registry.ids == ("good_one", "good_two")
    assert len(registry.diagnostics) == 3
    assert registry.get("good_one").field("prompt") is not None


# -- registry-fatal --------------------------------------------------------


def test_a_missing_root_raises(tmp_path):
    missing = tmp_path / "nowhere"
    with pytest.raises(RegistryError) as error:
        load_registry(missing)
    assert "does not exist" in str(error.value)
    assert str(missing) in str(error.value)


def test_a_root_that_is_a_file_raises(tmp_path):
    not_a_directory = tmp_path / "registry.yaml"
    not_a_directory.write_text("id: x\n", encoding="utf-8")
    with pytest.raises(RegistryError) as error:
        load_registry(not_a_directory)
    assert "not a directory" in str(error.value)


def test_a_root_that_cannot_be_read_raises(builder, monkeypatch):
    builder.add("fine", PROMPT_FIELD, workflow_id="fine")

    def refuse(top, onerror=None, **kwargs):
        error = PermissionError(13, "Permission denied")
        if onerror is not None:
            onerror(error)
        return iter(())

    monkeypatch.setattr(os, "walk", refuse)
    with pytest.raises(RegistryError) as error:
        load_registry(builder.root)
    assert "cannot be read" in str(error.value)


def test_an_empty_root_is_an_empty_registry_not_an_error(tmp_path):
    empty = tmp_path / "empty registry"
    empty.mkdir()

    registry = load_registry(empty)
    assert registry.workflows == ()
    assert registry.diagnostics == ()
    assert len(registry) == 0


# -- paths with spaces -----------------------------------------------------


def test_a_registry_root_with_a_space_works_end_to_end(tmp_path):
    builder = RegistryBuilder(tmp_path / "my workflow registry")
    builder.add(
        "my workflow",
        PROMPT_FIELD,
        workflow_id="spaced",
        json_name="my workflow api.json",
        subdir="a folder",
    )

    registry = load_registry(builder.root)
    assert registry.diagnostics == ()
    assert registry.ids == ("spaced",)
    assert " " in str(registry.get("spaced").workflow_path)


def test_the_registry_root_may_be_given_as_a_string(builder):
    builder.add("one", PROMPT_FIELD, workflow_id="one")
    assert load_registry(str(builder.root)).ids == ("one",)


# -- lookup ----------------------------------------------------------------


def test_get_returns_none_for_an_unknown_id(builder):
    builder.add("one", PROMPT_FIELD, workflow_id="one")
    registry = builder.load()
    assert registry.get("one") is not None
    assert registry.get("nope") is None


def test_the_summary_list_follows_the_same_order(builder):
    builder.add("a_file", PROMPT_FIELD, workflow_id="zulu")
    builder.add("z_file", PROMPT_FIELD, workflow_id="alpha")
    registry = builder.load()
    assert [item["id"] for item in registry.summary_view()] == ["alpha", "zulu"]
