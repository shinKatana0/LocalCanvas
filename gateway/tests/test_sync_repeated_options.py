"""A runtime list that repeats a value is read once per value (T-0186).

A real node on a real ComfyUI declares a choice list with the same value in it
twice.  ``declared_options`` refused such a list, so the input declared
nothing and every workflow carrying that node was held for a fault that is the
node's.  The decision: an **exact** repeat -- the same value of the same type --
is dropped, the first occurrence kept in its declared place.

What does **not** change, each pinned here separately so the halves of the
card are decided separately:

* two values Python calls equal that are of different types (``1`` and
  ``1.0``) still refuse the whole list -- they are not the same value, and the
  schema's loader, which compares option values with ``==``, would refuse the
  pair as a duplicate;
* a boolean still refuses the list;
* the empty-string choice still refuses the list.

And the reason the first bullet matters: a definition imported from a list
with an exact repeat must load in the gateway's own registry loader, which
refuses a duplicate option value -- shown able to refuse one in the same test.

Every class name, input name and value below is invented.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict, List

import pytest

from localcanvas_gateway.workflows import load_registry
from localcanvas_gateway.workflows.sync import analyse
from localcanvas_gateway.workflows.sync.contract import declared_options, read_object_info
from localcanvas_gateway.workflows.sync.definitions import (
    definition_document,
    render_definition,
)
from localcanvas_gateway.workflows.sync.semantics import Exposure, classify

SAMPLER = "ExampleBlendSampler"
UNSETTLED = "mixing"


def legacy(*values: Any) -> List[Any]:
    return [list(values), {}]


def current(*values: Any) -> List[Any]:
    return ["COMBO", {"multiselect": False, "options": list(values)}]


SHAPES = [pytest.param(legacy, id="legacy"), pytest.param(current, id="current")]


@pytest.mark.parametrize("shape", SHAPES)
def test_a_value_repeated_exactly_is_read_once(shape) -> None:
    assert declared_options(shape("steady", "drifting", "steady")) == ("steady", "drifting")
    assert declared_options(shape(2, 3, 2, 2)) == (2, 3)
    assert declared_options(shape(0.5, 0.5)) == (0.5,)
    # An exact repeat beside a value of another type equal to it: the repeat
    # is read once and the pair still refuses the list.
    assert declared_options(shape("steady", 2, 2, 2.0)) is None
    assert declared_options(shape("steady", 2.0, 2, 2)) is None


@pytest.mark.parametrize("shape", SHAPES)
def test_the_first_occurrence_keeps_its_declared_place(shape) -> None:
    """Keeping the last one instead would move ``drifting`` ahead of ``steady``."""

    assert declared_options(shape("drifting", "steady", "drifting", "layered")) == (
        "drifting",
        "steady",
        "layered",
    )


@pytest.mark.parametrize("shape", SHAPES)
def test_values_of_different_types_are_never_repeats_of_each_other(shape) -> None:
    """``"1"`` and ``1`` are not equal at all, so both are kept, in order."""

    assert declared_options(shape("1", 1, "1")) == ("1", 1)


@pytest.mark.parametrize("shape", SHAPES)
@pytest.mark.parametrize(
    "values",
    [
        pytest.param((1, 1.0), id="int-then-float"),
        pytest.param((1.0, 1), id="float-then-int"),
        pytest.param(("steady", 2, 2.0), id="beside-another-value"),
    ],
)
def test_equal_values_of_different_types_still_refuse_the_list(shape, values) -> None:
    """Not the same value, and not two choices the schema's loader accepts.

    The same lists without the second type are read, so the refusal is about
    the pair and not about the values.
    """

    assert declared_options(shape(*values)) is None
    ints_only = [value for value in values if not isinstance(value, float)]
    assert declared_options(shape(*ints_only)) is not None


@pytest.mark.parametrize("shape", SHAPES)
def test_a_boolean_still_refuses_the_list(shape) -> None:
    assert declared_options(shape("steady", True)) is None
    assert declared_options(shape(1, True)) is None
    assert declared_options(shape(1, 2)) == (1, 2)


@pytest.mark.parametrize("shape", SHAPES)
def test_an_empty_choice_still_refuses_the_list(shape) -> None:
    """The other half of the card, left as it was -- repeated or not."""

    assert declared_options(shape("", "steady")) is None
    assert declared_options(shape("steady", "", "")) is None
    assert declared_options(shape("steady", "steady", "")) is None
    assert declared_options(shape("steady", "drifting")) == ("steady", "drifting")


def test_a_definition_imported_from_a_repeating_list_loads_offline(tmp_path: Path) -> None:
    graph: Dict[str, Any] = {
        "1": {
            "class_type": SAMPLER,
            "inputs": {"seed": 7, UNSETTLED: "steady", "positive": ["2", 0]},
        },
        "2": {"class_type": "ExampleTextEncode", "inputs": {"text": "a quiet street at dawn"}},
    }
    assert classify(UNSETTLED, "steady").exposure is Exposure.UNCERTAIN
    contract = read_object_info(
        {
            SAMPLER: {
                "input": {"required": {UNSETTLED: current("steady", "drifting", "steady")}},
                "output": ["LATENT"],
            }
        },
        identity_digest="sha256:repeated-options",
    )

    plan = analyse(graph, contract=contract)
    assert plan.problems == ()
    document = definition_document(
        plan, workflow_id="repeated", name="Repeated", workflow_relative="graph.json"
    )
    written = [item for item in document["inputs"] if item["id"] == UNSETTLED]
    assert written[0]["options"] == [{"value": "steady"}, {"value": "drifting"}]

    def load(doc: Dict[str, Any], folder: str):
        definitions = tmp_path / folder
        definitions.mkdir()
        (definitions / "graph.json").write_text(json.dumps(graph), encoding="utf-8")
        (definitions / "repeated.yaml").write_text(render_definition(doc), encoding="utf-8")
        return load_registry(definitions)

    loaded = load(document, "as-imported")
    assert [item.message for item in loaded.diagnostics] == []
    assert [workflow.id for workflow in loaded.workflows] == ["repeated"]

    # The loader does refuse a duplicate option value: the check above could fail.
    duplicated = dict(document)
    duplicated["inputs"] = [
        dict(item, options=item["options"] + [{"value": "steady"}])
        if item["id"] == UNSETTLED
        else item
        for item in document["inputs"]
    ]
    refused = load(duplicated, "with-a-duplicate")
    assert refused.workflows == ()
    assert any(
        "duplicate option value 'steady'" in item.message for item in refused.diagnostics
    )
