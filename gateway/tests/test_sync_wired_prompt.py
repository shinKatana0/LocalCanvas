"""A string that is its node's only input, wired straight into a prompt, is the prompt (T-0219).

A string node's one input is called ``value``, a name that says nothing, so
``classify`` answers ``UNCERTAIN`` for the prose it holds and the workflow was
held for review -- although the same prose written on the encoder's own
``text`` imports as the prompt.  The evidence is where the node's output lands:
directly into an input ``classify`` would call a prompt by its name.

What is held down here:

* the positive, the negative, and the one feeding both -- through the existing
  polarity rule, with its review sentence verbatim;
* **the node's only input** (T-0219's review): a join, a replace and a
  language-model node wired into a prompt are held exactly as before -- none
  of their strings is the text the node outputs -- and so is a string beside a
  number or beside a wire;
* **one hop**: an output reaching a prompt only through another node proves
  nothing;
* an output feeding a non-prompt input stays held, beside a prompt-named
  literal elsewhere in the graph that is not what the rule reads;
* everything an earlier authority settles keeps its answer;
* the interaction with collapsing (T-0106's question): two string nodes holding
  the same prose into two positive encoders are one prompt control, by the
  ordinary rule, and nothing about the class is read.

Every class name, input name and value below is invented.
"""

from __future__ import annotations

from typing import Any, Dict, List, Tuple

from localcanvas_gateway.workflows.sync import analyse
from localcanvas_gateway.workflows.sync.analysis import ControlRecord, PlannedField
from localcanvas_gateway.workflows.sync.contract import read_object_info
from localcanvas_gateway.workflows.sync.semantics import Exposure, classify

PROSE = "a lighthouse on a cliff at dusk, oil painting"
NEGATIVE_PROSE = "blurry, low detail"
STRING_NODE = "ExampleTextValue"


def sampler_graph(positive_from: str, negative_from: str) -> Dict[str, Any]:
    """A string node ``1``, two encoders, a sampler.

    ``positive_from``/``negative_from`` name which encoder feeds the sampler's
    ``positive`` and ``negative``: ``"2"`` is the one the string node is wired
    into, ``"3"`` the one holding its own literal text.
    """

    return {
        "1": {"class_type": STRING_NODE, "inputs": {"value": PROSE}},
        "2": {"class_type": "ExampleTextEncode", "inputs": {"text": ["1", 0]}},
        "3": {"class_type": "ExampleTextEncode", "inputs": {"text": NEGATIVE_PROSE}},
        "4": {
            "class_type": "ExampleSampler",
            "inputs": {
                "seed": 7,
                "positive": [positive_from, 0],
                "negative": [negative_from, 0],
            },
        },
    }


def wired_sentence(inputs: str = "an input named 'text'") -> str:
    return (
        "input 'value' is the only input of its node and holds text its own name "
        "says nothing about, and this node's output is wired straight into {}, "
        "where a prompt is written: the wiring makes it that prompt.".format(inputs)
    )


def summary(fields: Tuple[PlannedField, ...]) -> List[Tuple[Any, ...]]:
    return [
        (
            field.id,
            field.label,
            field.type,
            field.section,
            field.required,
            field.default,
            field.translatable,
            field.targets,
        )
        for field in fields
    ]


def control_for(plan, node: str, name: str) -> ControlRecord:
    found = [item for item in plan.controls if item.target == (node, name)]
    assert len(found) == 1, (node, name, plan.controls)
    return found[0]


def held(name: str, value: str) -> str:
    verdict = classify(name, value)
    assert verdict.exposure is Exposure.UNCERTAIN, verdict
    return verdict.reason


def test_the_fixture_is_held_on_the_name_alone() -> None:
    """The input the card is about is one ``classify`` cannot settle, and the
    encoder's own ``text`` is one it can -- so the only thing that can make the
    difference below is the wire."""

    assert classify("value", PROSE).exposure is Exposure.UNCERTAIN
    assert classify("text", PROSE).prompt


def test_a_string_wired_into_the_positive_encoder_is_the_prompt() -> None:
    plan = analyse(sampler_graph(positive_from="2", negative_from="3"))

    assert plan.problems == ()
    assert summary(plan.fields) == [
        ("prompt", "Prompt", "multiline", "main", True, PROSE, True, (("1", "value"),)),
        (
            "negative_prompt",
            "Negative prompt",
            "multiline",
            "advanced",
            False,
            NEGATIVE_PROSE,
            True,
            (("3", "text"),),
        ),
        ("seed", "Seed", "integer", "advanced", False, 7, False, (("4", "seed"),)),
    ]
    assert control_for(plan, "1", "value") == ControlRecord(
        node="1",
        input="value",
        section="main",
        reason=wired_sentence(),
        field="prompt",
        label="Prompt",
    )


def test_a_string_wired_into_the_negative_encoder_is_the_negative_prompt() -> None:
    plan = analyse(sampler_graph(positive_from="3", negative_from="2"))

    assert plan.problems == ()
    assert summary(plan.fields) == [
        (
            "prompt",
            "Prompt",
            "multiline",
            "main",
            True,
            NEGATIVE_PROSE,
            True,
            (("3", "text"),),
        ),
        (
            "negative_prompt",
            "Negative prompt",
            "multiline",
            "advanced",
            False,
            PROSE,
            True,
            (("1", "value"),),
        ),
        ("seed", "Seed", "integer", "advanced", False, 7, False, (("4", "seed"),)),
    ]


def test_a_string_feeding_both_is_held_with_the_polarity_sentence() -> None:
    graph = sampler_graph(positive_from="2", negative_from="3")
    # The string node now feeds both encoders, which feed both conditionings.
    graph["3"]["inputs"]["text"] = ["1", 0]

    plan = analyse(graph)

    sentence = (
        "Node 1 input 'value' feeds both a positive and a negative conditioning "
        "input, so which prompt it is cannot be decided."
    )
    assert plan.problems == (sentence,)
    assert control_for(plan, "1", "value") == ControlRecord(
        node="1", input="value", section="needs_review", reason=sentence
    )
    assert plan.fields == ()


def test_a_string_feeding_a_non_prompt_input_stays_held() -> None:
    graph = sampler_graph(positive_from="3", negative_from="2")
    # Node 2 is no longer an encoder: what the string feeds is not a prompt,
    # while node 3 beside it still holds a prompt-named literal of its own.
    graph["2"] = {"class_type": "ExampleOverlay", "inputs": {"label": ["1", 0]}}
    assert classify("label", PROSE).exposure is Exposure.UNCERTAIN

    plan = analyse(graph)

    reason = held("value", PROSE)
    assert plan.problems == ("Node 1 " + reason,)
    assert control_for(plan, "1", "value") == ControlRecord(
        node="1", input="value", section="needs_review", reason=reason
    )


def test_one_hop_only() -> None:
    """Through a relay the output still reaches ``text``, two hops away -- and
    the same relay's own ``text`` input one hop away is what makes it a prompt,
    so the distance is the only difference between the two graphs."""

    relayed = sampler_graph(positive_from="2", negative_from="3")
    relayed["5"] = {"class_type": "ExampleRelay", "inputs": {"anything": ["1", 0]}}
    relayed["2"]["inputs"]["text"] = ["5", 0]
    assert classify("anything", PROSE).exposure is Exposure.UNCERTAIN

    plan = analyse(relayed)
    reason = held("value", PROSE)
    assert plan.problems == ("Node 1 " + reason,)

    direct = sampler_graph(positive_from="2", negative_from="3")
    direct["5"] = {"class_type": "ExampleRelay", "inputs": {"text": ["1", 0]}}
    direct["2"]["inputs"]["text"] = ["5", 0]
    assert control_for(analyse(direct), "1", "value").field == "prompt"


def test_every_prompt_named_input_it_feeds_is_named() -> None:
    graph = sampler_graph(positive_from="2", negative_from="3")
    graph["5"] = {"class_type": "ExampleNotes", "inputs": {"caption": ["1", 0], "label": ["1", 0]}}

    plan = analyse(graph)

    assert control_for(plan, "1", "value").reason == wired_sentence(
        "inputs named 'caption', 'text'"
    )
    assert control_for(plan, "1", "value").field == "prompt"


def test_what_an_earlier_authority_settles_is_not_asked() -> None:
    """A declared choice list and the computation rule each answer first."""

    graph = sampler_graph(positive_from="2", negative_from="3")

    listed = analyse(
        graph,
        contract=read_object_info(
            {STRING_NODE: {"input": {"required": {"value": [["calm", "stormy"], {}]}}}},
            identity_digest="sha256:wired",
        ),
    )
    record = control_for(listed, "1", "value")
    assert record.section == "needs_review"
    assert record.reason.startswith("input 'value' holds {!r}, and the ComfyUI".format(PROSE))

    computed = analyse(
        graph,
        contract=read_object_info(
            {STRING_NODE: {"input": {"required": {}}, "output": ["FLOAT"]}},
            identity_digest="sha256:wired",
        ),
    )
    assert control_for(computed, "1", "value").kind == "computation"

    # And a contract that says nothing about the class changes nothing.
    silent = analyse(
        graph,
        contract=read_object_info(
            {"ExampleUnrelated": {"input": {"required": {}}, "output": ["STRING"]}},
            identity_digest="sha256:wired",
        ),
    )
    assert silent == analyse(graph)
    assert control_for(silent, "1", "value").field == "prompt"


def test_a_number_on_a_string_node_is_not_a_prompt() -> None:
    graph = sampler_graph(positive_from="2", negative_from="3")
    graph["1"]["inputs"] = {"__": 3}

    plan = analyse(graph)

    assert control_for(plan, "1", "__").section == "needs_review"


def test_two_string_nodes_with_one_prose_into_two_positive_encoders_are_one_prompt() -> None:
    """T-0106's collapse question, measured: the ordinary rule, and no class read."""

    graph = {
        "1": {"class_type": STRING_NODE, "inputs": {"value": PROSE}},
        "2": {"class_type": "ExampleOtherTextValue", "inputs": {"value": PROSE}},
        "3": {"class_type": "ExampleTextEncode", "inputs": {"text": ["1", 0]}},
        "4": {"class_type": "ExampleTextEncode", "inputs": {"text": ["2", 0]}},
        "5": {"class_type": "ExampleSampler", "inputs": {"positive": ["3", 0], "seed": 1}},
        "6": {"class_type": "ExampleSampler", "inputs": {"positive": ["4", 0], "seed": 1}},
    }

    plan = analyse(graph)

    assert plan.problems == ()
    assert summary(plan.fields) == [
        (
            "prompt",
            "Prompt",
            "multiline",
            "main",
            True,
            PROSE,
            True,
            (("1", "value"), ("2", "value")),
        ),
        ("seed", "Seed", "integer", "advanced", False, 1, False, (("5", "seed"), ("6", "seed"))),
    ]


# ==========================================================================
# Only a node with nothing but the string (T-0219's review)
# ==========================================================================


def shaped_graph(class_type: str, inputs: Dict[str, Any]) -> Dict[str, Any]:
    """Node ``1`` of the given shape, its output wired into a positive encoder."""

    return {
        "1": {"class_type": class_type, "inputs": dict(inputs)},
        "9": {"class_type": "ExampleTextSource", "inputs": {}},
        "3": {"class_type": "ExampleTextEncode", "inputs": {"text": ["1", 0]}},
        "4": {"class_type": "ExampleTextEncode", "inputs": {"text": NEGATIVE_PROSE}},
        "5": {
            "class_type": "ExampleSampler",
            "inputs": {"seed": 7, "positive": ["3", 0], "negative": ["4", 0]},
        },
    }


#: Nodes wired into a prompt whose strings are not the text they output.
SHAPES: List[Tuple[str, str, Dict[str, Any]]] = [
    ("join", "ExampleJoin", {"first": ["9", 0], "second": "highly detailed", "delimiter": ", "}),
    ("replace", "ExampleReplace", {"source": ["9", 0], "find": "cat", "replacement": "dog"}),
    (
        "language-model",
        "ExampleLanguageModel",
        {
            "system": "You write image prompts.",
            "model": "some-model:7b",
            "seed": 3,
            "image": ["9", 0],
        },
    ),
    # Strings and nothing else: no wire and no number to give the node away.
    (
        "two-strings-only",
        "ExampleJoin",
        {"first": "a lighthouse at dusk", "second": "highly detailed"},
    ),
    ("prose-beside-a-number", STRING_NODE, {"value": PROSE, "strength": 0.5}),
    ("prose-beside-a-wire", STRING_NODE, {"value": PROSE, "clip": ["9", 0]}),
]


def test_a_node_with_anything_beside_the_string_is_held_as_before() -> None:
    """Every uncertain string on such a node is held with ``classify``'s own
    sentence and no field binds any of them -- which is what the importer did
    before T-0219 (the plans are compared with the pre-change importer in the
    replay measured for T-0219).

    The same wiring with the node reduced to one of those strings alone **does**
    become the prompt, so the rule was in reach of every one of these graphs and
    the absence is not a fixture that could not have produced one.
    """

    for label, class_type, inputs in SHAPES:
        plan = analyse(shaped_graph(class_type, inputs))

        uncertain = sorted(
            name
            for name, value in inputs.items()
            if isinstance(value, str)
            and classify(name, value).exposure is Exposure.UNCERTAIN
        )
        assert uncertain, label
        assert plan.problems == tuple(
            sorted("Node 1 " + held(name, inputs[name]) for name in uncertain)
        ), label
        for name in uncertain:
            assert control_for(plan, "1", name) == ControlRecord(
                node="1",
                input=name,
                section="needs_review",
                reason=held(name, inputs[name]),
            ), (label, name)
        assert plan.fields == (), label

        for name in uncertain:
            alone = analyse(shaped_graph(class_type, {name: inputs[name]}))
            assert control_for(alone, "1", name).field == "prompt", (label, name)
