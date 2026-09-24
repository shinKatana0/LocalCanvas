"""Two controls in one form need two names.

T-0097 split controls that had been falsely merged -- one slider silently
driving two unrelated settings -- and it was right to.  What it left behind is
this file's subject: the label generator was never asked to name two siblings
apart, so a guidance scale and a sampler step count both reached the form as
``Value (on true)``, and the two loaders of a chain both as
``Strength model (model)``.  Setting the wrong one changes something other than
what the user intended, from a form that looks right.

**Nothing here may merge those pairs again.**  Every shape below is asserted to
be two fields with two ids and two separate bind targets, so a "fix" that put
them back together fails this file rather than passing it.

The two shapes are the real ones
--------------------------------
`config/local/` may not be read, so both are rebuilt here out of public parts,
and both were checked to reproduce the defect on the code as it stood: four
``Primitive``-family nodes feeding two switches that feed a sampler's ``cfg``
and ``steps``, and two loaders chained one into the other and ending at one
sampler.  Every class type, input name, title and value in this file is
invented for it; none names a real node, a real pack, a real model or anybody's
workflow.

What settles which pair, measured rather than assumed
-----------------------------------------------------
* the **switch pair is settled by the wiring alone** -- one value reaches
  ``cfg`` two hops out and the other reaches ``steps``, which is the same kind
  of evidence `analysis.py` already names ``negative_prompt`` from.  Asserted
  with every title removed, so the rung is shown to work on its own;
* the **chained loaders are not**.  Both end at one sampler under one input
  name, and their downstream name sequences are identical -- only the number of
  hops differs, which is a distance and not a name.  Asserted, with titles
  removed, to fall through to the last resort;
* so the loaders are settled by **the author's own node title**, which is
  untrusted free text out of the user's file and is treated as such;
* and where even that says nothing, or says one thing for both, the label says
  **the field's own id**.  That is the rung that makes uniqueness a guarantee
  instead of a likelihood: an emitted definition has no two fields of one id.

Each rung is reachable on its own, and each has a test that fails if only that
rung is taken away -- a ladder whose rungs are only ever tested together is a
ladder with one tested rung.
"""

from __future__ import annotations

import copy
import json
import random
import re
import unicodedata
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Dict, Iterator, List, Tuple

from localcanvas_gateway.workflows.sync import analyse
from localcanvas_gateway.workflows.sync import analysis as analysis_module

#: Every character above ASCII in this file is written as an escape, so that
#: what it measures cannot depend on how an editor, a terminal or a tool in
#: between handled a literal -- which is a real hazard in a file whose whole
#: subject is text that looks like other text.
CYRILLIC = "\u041f\u043e\u0440\u0442\u0440\u0435\u0442"
JAPANESE = "\u30a2\u30cb\u30e1\u8abf"

# ==========================================================================
# The two shapes the card is about
# ==========================================================================


def switch_graph() -> Dict[str, Any]:
    """Four values, two switches, one sampler: a guidance scale and a step count.

    Nodes 31 and 33 both feed an ``on_true``; 32 and 34 both feed an
    ``on_false``.  That is the collision -- one hop out, all four say the same
    thing about themselves -- and two hops out the graph says which sampler
    input each one is really setting.
    """

    return {
        "10": {
            "class_type": "ExampleCheckpointLoader",
            "inputs": {"ckpt_name": "PLACEHOLDER.safetensors"},
        },
        "20": {
            "class_type": "ExampleTextEncoder",
            "inputs": {"text": "a cat", "clip": ["10", 1]},
        },
        "31": {
            "class_type": "ExamplePrimitiveFloat",
            "inputs": {"value": 1.0},
            "_meta": {"title": "Float (fast preview)"},
        },
        "32": {
            "class_type": "ExamplePrimitiveFloat",
            "inputs": {"value": 4.5},
            "_meta": {"title": "Float (quality)"},
        },
        "33": {
            "class_type": "ExamplePrimitiveInt",
            "inputs": {"value": 4},
            "_meta": {"title": "Int (fast preview)"},
        },
        "34": {
            "class_type": "ExamplePrimitiveInt",
            "inputs": {"value": 28},
            "_meta": {"title": "Int (quality)"},
        },
        "41": {
            "class_type": "ExampleSwitch",
            "inputs": {"on_true": ["31", 0], "on_false": ["32", 0], "boolean": True},
        },
        "42": {
            "class_type": "ExampleSwitch",
            "inputs": {"on_true": ["33", 0], "on_false": ["34", 0], "boolean": True},
        },
        "50": {
            "class_type": "ExampleSampler",
            "inputs": {
                "seed": 7,
                "cfg": ["41", 0],
                "steps": ["42", 0],
                "conditioning": ["20", 0],
                "model": ["10", 0],
            },
        },
        "60": {"class_type": "ExampleDecode", "inputs": {"samples": ["50", 0]}},
        "70": {"class_type": "ExampleSaveImage", "inputs": {"images": ["60", 0]}},
    }


def lora_graph() -> Dict[str, Any]:
    """Two adapters chained one into the other, both ending at one sampler."""

    return {
        "10": {
            "class_type": "ExampleCheckpointLoader",
            "inputs": {"ckpt_name": "PLACEHOLDER.safetensors"},
        },
        "21": {
            "class_type": "ExampleAdapterLoader",
            "inputs": {
                "lora_name": "PLACEHOLDER-a.safetensors",
                "strength_model": 0.8,
                "strength_clip": 0.8,
                "model": ["10", 0],
                "clip": ["10", 1],
            },
            "_meta": {"title": "Action LoRA"},
        },
        "22": {
            "class_type": "ExampleAdapterLoader",
            "inputs": {
                "lora_name": "PLACEHOLDER-b.safetensors",
                "strength_model": 0.6,
                "strength_clip": 0.6,
                "model": ["21", 0],
                "clip": ["21", 1],
            },
            "_meta": {"title": "Cel Shading LoRA"},
        },
        "30": {
            "class_type": "ExampleTextEncoder",
            "inputs": {"text": "a cat", "clip": ["22", 1]},
        },
        "40": {
            "class_type": "ExampleSampler",
            "inputs": {"seed": 7, "conditioning": ["30", 0], "model": ["22", 0]},
        },
        "50": {"class_type": "ExampleDecode", "inputs": {"samples": ["40", 0]}},
        "60": {"class_type": "ExampleSaveImage", "inputs": {"images": ["50", 0]}},
    }


def shared_binding_graph() -> Dict[str, Any]:
    """One control driving two node inputs, each ending somewhere different.

    Nodes 31 and 32 hold the same value, so the importer collapses them into a
    single field the user sets once -- and that one field reaches both ``cfg``
    and ``steps``.  Node 33 holds a different value and is its own field, and
    one hop out all three say ``on_true``.

    The shape exists because a field with several bindings is where an
    order-dependent rule hides: read the first member's wiring instead of all
    of them and the answer becomes a function of which node id sorts first.
    """

    graph: Dict[str, Any] = {
        "10": {
            "class_type": "ExampleCheckpointLoader",
            "inputs": {"ckpt_name": "PLACEHOLDER.safetensors"},
        },
        "20": {
            "class_type": "ExampleTextEncoder",
            "inputs": {"text": "a cat", "clip": ["10", 1]},
        },
        "50": {
            "class_type": "ExampleSampler",
            "inputs": {"seed": 7, "conditioning": ["20", 0], "model": ["10", 0]},
        },
        "60": {"class_type": "ExampleDecode", "inputs": {"samples": ["50", 0]}},
        "70": {"class_type": "ExampleSaveImage", "inputs": {"images": ["60", 0]}},
    }
    for node, value, target in (
        ("31", 1.0, "cfg"),
        ("32", 1.0, "steps"),
        ("33", 2.0, "denoise"),
    ):
        switch = "4" + node
        graph[node] = {
            "class_type": "ExamplePrimitiveValue",
            "inputs": {"value": value},
        }
        graph[switch] = {
            "class_type": "ExampleSwitch",
            "inputs": {"on_true": [node, 0], "boolean": True},
        }
        graph["50"]["inputs"][target] = [switch, 0]
    return graph


def split_binding_graph() -> Dict[str, Any]:
    """A collapsed control whose members do **not** agree one hop out.

    Nodes 31 and 32 hold the same value and collapse into one control, but one
    of them feeds a switch's ``on_true`` and the other its ``on_false``.  So
    the *base* label -- the one this module produced before any of this, from
    ``_hint(members[0])`` -- depends on which of the two node ids sorts first,
    and a renumbering moves it.

    That is pre-existing and is T-0113's mechanism arriving at a label rather
    than at an id: the same movement happens on the commit this rule was
    written against.  The shape is here so that the determinism this file
    claims is measured on a corpus that contains the case it does **not**
    cover, instead of on shapes that cannot break.
    """

    graph: Dict[str, Any] = {
        "10": {
            "class_type": "ExampleCheckpointLoader",
            "inputs": {"ckpt_name": "PLACEHOLDER.safetensors"},
        },
        "20": {
            "class_type": "ExampleTextEncoder",
            "inputs": {"text": "a cat", "clip": ["10", 1]},
        },
        "31": {"class_type": "ExamplePrimitiveValue", "inputs": {"value": 4}},
        "32": {"class_type": "ExamplePrimitiveValue", "inputs": {"value": 4}},
        "33": {"class_type": "ExamplePrimitiveValue", "inputs": {"value": 50}},
        "41": {
            "class_type": "ExampleSwitch",
            "inputs": {"on_true": ["31", 0], "on_false": ["32", 0], "boolean": True},
        },
        "43": {
            "class_type": "ExampleSwitch",
            "inputs": {"on_true": ["33", 0], "boolean": True},
        },
        "50": {
            "class_type": "ExampleSampler",
            "inputs": {
                "seed": 7,
                "steps": ["41", 0],
                "batch_size": ["43", 0],
                "conditioning": ["20", 0],
                "model": ["10", 0],
            },
        },
        "60": {"class_type": "ExampleDecode", "inputs": {"samples": ["50", 0]}},
        "70": {"class_type": "ExampleSaveImage", "inputs": {"images": ["60", 0]}},
    }
    return graph


def one_named_one_silent_graph() -> Dict[str, Any]:
    """One control over two nodes, of which the author named exactly one.

    Adapters 21 and 23 are set to the same strength and collapse into a single
    control; 21 carries a title and 23 was never named.  A third adapter keeps
    the role from being unique, so the labels collide and the ladder runs, and
    every one of the three ends at the same sampler input, so the wiring rung
    has nothing to add.

    The commonest way a chain gets annotated is exactly this -- a curator names
    the node they care about and leaves the other alone -- so the control has
    to end up with the name that was written rather than with neither.
    """

    graph = lora_graph()
    graph["21"]["_meta"] = {"title": "Action LoRA"}
    graph["22"]["_meta"] = {"title": "Cel Shading LoRA"}
    graph["23"] = {
        "class_type": "ExampleAdapterLoader",
        "inputs": {
            "lora_name": "PLACEHOLDER-c.safetensors",
            "strength_model": 0.8,
            "strength_clip": 0.8,
            "model": ["22", 0],
            "clip": ["22", 1],
        },
    }
    graph["30"]["inputs"]["clip"] = ["23", 1]
    graph["40"]["inputs"]["model"] = ["23", 0]
    return graph


def one_adapter_graph() -> Dict[str, Any]:
    """The ordinary shape: one adapter, so no role is carried twice."""

    graph = lora_graph()
    del graph["22"]
    graph["30"]["inputs"]["clip"] = ["21", 1]
    graph["40"]["inputs"]["model"] = ["21", 0]
    return graph


def untitled(graph: Dict[str, Any]) -> Dict[str, Any]:
    """The same graph with every node title removed."""

    graph = copy.deepcopy(graph)
    for node in graph.values():
        node.pop("_meta", None)
    return graph


def titled(graph: Dict[str, Any], **titles: Any) -> Dict[str, Any]:
    """The same graph with ``node=title`` written into ``_meta``."""

    graph = copy.deepcopy(graph)
    for node, title in titles.items():
        graph[node]["_meta"] = {"title": title}
    return graph


def labelled(graph: Dict[str, Any]) -> List[Tuple[str, str]]:
    """``[(id, label)]`` for one graph, in the plan's own order."""

    plan = analyse(graph)
    assert not plan.problems, plan.problems
    return [(field.id, field.label) for field in plan.fields]


def label_of(graph: Dict[str, Any], field_id: str) -> str:
    found = dict(labelled(graph))
    assert field_id in found, "no field {!r} in {}".format(field_id, sorted(found))
    return found[field_id]


# ==========================================================================
# The two pairs, verbatim
# ==========================================================================


#: What the two shapes produced **before** this rule existed, measured on
#: f06eb2d.  The ids are here so that a reader can see at a glance that not one
#: of them moved; the labels are here because they are the defect.
BEFORE_SWITCH = [
    ("prompt", "Prompt"),
    ("boolean", "Boolean"),
    ("seed", "Seed"),
    ("value-0e7bd66d", "Value (on true)"),
    ("value-3bb92393", "Value (on false)"),
    ("value-6b55232b", "Value (on true)"),
    ("value-ba91676e", "Value (on false)"),
]

BEFORE_LORA = [
    ("prompt", "Prompt"),
    ("seed", "Seed"),
    ("strength_clip-11249765", "Strength clip (model)"),
    ("strength_clip-e7db671c", "Strength clip (model)"),
    ("strength_model-5d923eae", "Strength model (model)"),
    ("strength_model-a47918c4", "Strength model (model)"),
]


def test_the_shapes_reproduce_the_defect_they_were_built_for():
    """The fixtures are the real shapes: same ids, same collisions.

    Without this the file could be testing two graphs that never had the
    problem, and every assertion below would be about nothing.  The collision
    is stated as the pair of labels that used to be identical, so a fixture
    that quietly stopped producing it fails here rather than passing silently
    everywhere else.
    """

    assert [field_id for field_id, _ in BEFORE_SWITCH] == [
        field_id for field_id, _ in labelled(switch_graph())
    ]
    assert [field_id for field_id, _ in BEFORE_LORA] == [
        field_id for field_id, _ in labelled(lora_graph())
    ]

    before_switch = [label for _, label in BEFORE_SWITCH]
    assert before_switch.count("Value (on true)") == 2
    assert before_switch.count("Value (on false)") == 2
    before_lora = [label for _, label in BEFORE_LORA]
    assert before_lora.count("Strength model (model)") == 2
    assert before_lora.count("Strength clip (model)") == 2


def test_a_guidance_scale_and_a_step_count_get_two_names():
    """The wiring says which sampler input each value is really setting."""

    assert labelled(switch_graph()) == [
        ("prompt", "Prompt"),
        ("boolean", "Boolean"),
        ("seed", "Seed"),
        ("value-0e7bd66d", "Value (on true, cfg)"),
        ("value-3bb92393", "Value (on false, steps)"),
        ("value-6b55232b", "Value (on true, steps)"),
        ("value-ba91676e", "Value (on false, cfg)"),
    ]


def test_two_chained_adapters_get_two_names():
    """The wiring cannot tell them apart, so the author's own names do."""

    assert labelled(lora_graph()) == [
        ("prompt", "Prompt"),
        ("seed", "Seed"),
        ("strength_clip-11249765", "Strength clip (Cel Shading LoRA)"),
        ("strength_clip-e7db671c", "Strength clip (Action LoRA)"),
        ("strength_model-5d923eae", "Strength model (Cel Shading LoRA)"),
        ("strength_model-a47918c4", "Strength model (Action LoRA)"),
    ]


def test_no_id_moved_when_the_labels_did():
    """Verbatim, on both real shapes.  Phase 3 keys saved settings on these."""

    assert [field_id for field_id, _ in labelled(switch_graph())] == [
        "prompt",
        "boolean",
        "seed",
        "value-0e7bd66d",
        "value-3bb92393",
        "value-6b55232b",
        "value-ba91676e",
    ]
    assert [field_id for field_id, _ in labelled(lora_graph())] == [
        "prompt",
        "seed",
        "strength_clip-11249765",
        "strength_clip-e7db671c",
        "strength_model-5d923eae",
        "strength_model-a47918c4",
    ]


def test_no_id_is_derived_from_a_title():
    """Change nothing but the naming evidence and no id may move.

    A title reaches a label and nothing else.  An implementation that folded
    it into the fingerprint would rename the field a user's saved defaults are
    filed under every time the curator retitled a node in their editor.
    """

    renamed = titled(lora_graph(), **{"21": "Something Else", "22": "And Another"})
    assert [field_id for field_id, _ in labelled(renamed)] == [
        field_id for field_id, _ in labelled(lora_graph())
    ]
    assert [label for _, label in labelled(renamed)] != [
        label for _, label in labelled(lora_graph())
    ]


def test_the_pairs_are_still_two_controls_each():
    """T-0097 is not reversed: two fields, two ids, two separate bind targets.

    A "fix" that named the pair once by merging it would satisfy every
    uniqueness assertion in this file and would be the original defect back.
    """

    for graph, role, expected in (
        (switch_graph(), "value", 4),
        (lora_graph(), "strength_model", 2),
        (lora_graph(), "strength_clip", 2),
    ):
        plan = analyse(graph)
        found = [
            field
            for field in plan.fields
            if field.id == role or field.id.startswith(role + "-")
        ]
        assert len(found) == expected, [field.id for field in found]
        assert len({field.id for field in found}) == expected
        assert len({field.label for field in found}) == expected
        bound = [target for field in found for target in field.targets]
        assert len(bound) == expected, bound
        assert len(set(bound)) == expected, bound


# ==========================================================================
# Which rung settles which pair
# ==========================================================================


def test_the_wiring_settles_the_switch_pair_with_no_title_in_the_graph():
    """The rung that reads the wire, on its own.

    Every title is removed, so nothing but where the value ends up can be
    telling these four apart.  Take the wiring rung away and this shape falls
    to the last resort and this test says so.
    """

    graph = untitled(switch_graph())
    assert all("_meta" not in node for node in graph.values())
    assert labelled(graph) == [
        ("prompt", "Prompt"),
        ("boolean", "Boolean"),
        ("seed", "Seed"),
        ("value-0e7bd66d", "Value (on true, cfg)"),
        ("value-3bb92393", "Value (on false, steps)"),
        ("value-6b55232b", "Value (on true, steps)"),
        ("value-ba91676e", "Value (on false, cfg)"),
    ]


def test_the_wiring_does_not_settle_the_chained_adapters():
    """Measured, not assumed -- and the card asked for it to be measured.

    Both adapters end at one sampler under one input name, so their downstream
    name sequences are identical: ``model``, then ``samples``, then ``images``.
    Only the number of hops differs, and a distance is not a name.  With no
    title in the graph the labels therefore fall to the last resort, which is
    what proves the wiring rung was tried and failed rather than skipped.
    """

    graph = untitled(lora_graph())
    assert labelled(graph) == [
        ("prompt", "Prompt"),
        ("seed", "Seed"),
        ("strength_clip-11249765", "Strength clip (strength_clip-11249765)"),
        ("strength_clip-e7db671c", "Strength clip (strength_clip-e7db671c)"),
        ("strength_model-5d923eae", "Strength model (strength_model-5d923eae)"),
        ("strength_model-a47918c4", "Strength model (strength_model-a47918c4)"),
    ]
    # And no label pretended the shared tail of the graph was a difference.
    assert not [
        label for _, label in labelled(graph) if "samples" in label or "images" in label
    ]


def test_the_wiring_is_preferred_to_the_title():
    """Both kinds of evidence are present in the switch shape; the wire wins.

    The graph's own word for what a value sets is a fact about the workflow;
    a title is a person's note about a node.  Where both are available the
    ladder takes the first, which is also the order the card argued for.
    """

    graph = switch_graph()
    assert graph["31"]["_meta"]["title"] == "Float (fast preview)"
    assert label_of(graph, "value-0e7bd66d") == "Value (on true, cfg)"


def test_where_nothing_distinguishes_the_label_says_the_id():
    """The last resort, stated: no difference is invented that is not there.

    The id is the one thing left that is certainly not shared -- it is what a
    saved default, a draft and a portable profile are filed under -- so a
    label that says it is honest about there being no other answer, and cannot
    fail to separate the two.
    """

    graph = untitled(lora_graph())
    assert label_of(graph, "strength_model-a47918c4") == (
        "Strength model (strength_model-a47918c4)"
    )


def test_one_title_written_on_both_nodes_names_neither():
    """A name two nodes share is not a name that tells them apart."""

    graph = titled(lora_graph(), **{"21": "LoRA", "22": "LoRA"})
    assert labelled(graph) == labelled(untitled(lora_graph()))


def test_a_control_whose_nodes_disagree_about_its_name_has_none():
    """One field, several node inputs, and two different titles behind it.

    A logical field may drive several node inputs -- here two adapters set to
    the same strength collapse into one control -- and each of those nodes
    carries its own title.  Where they disagree the control has no name of its
    own, and picking one of the two would be this importer choosing which of
    the user's notes to believe.  So it takes neither and the id is used.
    """

    graph = lora_graph()
    graph["21"]["_meta"] = {"title": "Alpha"}
    graph["22"]["_meta"] = {"title": "Gamma"}
    graph["22"]["inputs"]["strength_model"] = 0.6
    graph["22"]["inputs"]["strength_clip"] = 0.6
    graph["23"] = {
        "class_type": "ExampleAdapterLoader",
        "inputs": {
            "lora_name": "PLACEHOLDER-c.safetensors",
            "strength_model": 0.8,
            "strength_clip": 0.8,
            "model": ["22", 0],
            "clip": ["22", 1],
        },
        "_meta": {"title": "Beta"},
    }
    graph["30"]["inputs"]["clip"] = ["23", 1]
    graph["40"]["inputs"]["model"] = ["23", 0]

    plan = analyse(graph)
    assert not plan.problems, plan.problems
    shared = [field for field in plan.fields if len(field.targets) > 1]
    assert [field.targets for field in shared] == [
        (("21", "strength_clip"), ("23", "strength_clip")),
        (("21", "strength_model"), ("23", "strength_model")),
    ]
    # The last rung says the field's own id, and these two fields are
    # collapsed ones -- so their ids are the ones T-0113 moved, from the first
    # member's fingerprint (``strength_clip-a7810fff``,
    # ``strength_model-bffefff9``, which a renumbering used to change) to one
    # minted from all the members at once.  What this test is about is that the
    # rung says an id at all; which id it is belongs to
    # `test_sync_id_stability.py`.
    assert [field.label for field in shared] == [
        "Strength clip (strength_clip-ab4b6804)",
        "Strength model (strength_model-7827666e)",
    ]
    # The field whose nodes agree -- there is only one of them -- still gets
    # its author's name, so the refusal above is about disagreement and not
    # about titles having stopped working.
    assert label_of(graph, "strength_model-e511c396") == "Strength model (Gamma)"


def test_a_node_the_author_never_named_does_not_out_vote_one_they_did():
    """Silence is not a second opinion, and the guard for that needs its own test.

    Two nodes of one control, one titled and one not, is the ordinary way a
    chain gets annotated: a curator names the node they care about and leaves
    the other alone.  ``_shared_title`` drops the empty answers before it asks
    whether the rest agree, so the control keeps the name that was actually
    written.

    Without that one line the untitled sibling counts as a second, different
    title, the members "disagree", and the control falls to the raw id --
    a worse name, with uniqueness untouched, which is precisely the kind of
    quiet loss no other assertion in this file notices.  So it is asserted
    here, verbatim, against the shape that distinguishes the two.
    """

    graph = one_named_one_silent_graph()
    plan = analyse(graph)
    assert not plan.problems, plan.problems

    shared = [field for field in plan.fields if len(field.targets) > 1]
    assert [field.targets for field in shared] == [
        (("21", "strength_clip"), ("23", "strength_clip")),
        (("21", "strength_model"), ("23", "strength_model")),
    ]
    assert graph["21"]["_meta"]["title"] == "Action LoRA"
    assert "_meta" not in graph["23"]
    assert [field.label for field in shared] == [
        "Strength clip (Action LoRA)",
        "Strength model (Action LoRA)",
    ]

    # The role is still carried by more than one field, so the ladder really
    # did run here -- the labels above are a rung's answer and not the
    # untouched base label.
    assert label_of(graph, "strength_model-e511c396") == (
        "Strength model (Cel Shading LoRA)"
    )


# ==========================================================================
# The ordinary shape does not churn
# ==========================================================================


def test_a_role_carried_once_keeps_the_label_it_has_today():
    """One adapter, one ``strength_model``, and no qualifier at all.

    This is the differential in miniature: the ordinary catalogue shape is a
    role that appears once, and it must come out of this rule untouched.
    """

    assert labelled(one_adapter_graph()) == [
        ("prompt", "Prompt"),
        ("seed", "Seed"),
        ("strength_clip", "Strength clip"),
        ("strength_model", "Strength model"),
    ]


def test_adding_a_second_control_renames_only_what_collides():
    """Everything the collision does not touch keeps its exact label.

    The switch shape's prompt, seed and boolean are the ordinary catalogue
    around the defect, and the rule must not reach them.  Asserted as a
    difference between two graphs rather than as a list, so a rule that
    renamed everything in sight fails here even if its names were unique.
    """

    plain = dict(labelled(one_adapter_graph()))
    both = dict(labelled(lora_graph()))
    untouched = {"prompt", "seed"}
    assert {key: plain[key] for key in untouched} == {
        key: both[key] for key in untouched
    }
    assert plain["prompt"] == "Prompt" and plain["seed"] == "Seed"


# ==========================================================================
# A node title is untrusted input
# ==========================================================================


def test_a_title_cannot_close_the_bracket_it_is_written_inside():
    """Brackets are dropped, so no title can fake the end of a qualifier."""

    graph = titled(
        lora_graph(), **{"21": "Action) and (something", "22": "Cel [shading]"}
    )
    assert label_of(graph, "strength_model-a47918c4") == (
        "Strength model (Action and something)"
    )
    assert label_of(graph, "strength_model-5d923eae") == "Strength model (Cel shading)"


def test_a_title_cannot_reorder_the_line_it_appears_in():
    """A direction override is a format character, and format characters go.

    Left in, ``U+202E`` reverses everything drawn after it: a label would then
    read as something other than what it says, which is exactly the harm this
    card exists to remove.
    """

    graph = titled(lora_graph(), **{"21": "\u202eAction\u202c", "22": "Cel"})
    label = label_of(graph, "strength_model-a47918c4")
    assert label == "Strength model (Action)"
    assert not [
        character
        for character in label
        if unicodedata.category(character) == "Cf"
    ]


def test_a_title_cannot_carry_a_control_character_into_a_label():
    graph = titled(lora_graph(), **{"21": "Ac\u0000ti\ton\n", "22": "Cel"})
    assert label_of(graph, "strength_model-a47918c4") == "Strength model (Acti on)"


def test_a_title_is_bounded():
    """A label is read on a phone; a title has no length at all."""

    graph = titled(lora_graph(), **{"21": "A" * 500, "22": "Cel"})
    label = label_of(graph, "strength_model-a47918c4")
    assert label == "Strength model ({}{})".format(
        "A" * analysis_module.TITLE_LABEL_CHARS, analysis_module.TITLE_CUT
    )
    assert len(label) < 60


def test_two_long_titles_that_share_a_beginning_are_not_two_names():
    """Truncation must not be a way of manufacturing a collision.

    Cut to the same forty characters the two titles are one string, so the
    ladder does not stop there -- it goes on to the id, and the two controls
    are still told apart.
    """

    long_a = "The very long descriptive title a person typed " + "x" * 60
    graph = titled(lora_graph(), **{"21": long_a + "one", "22": long_a + "two"})
    assert labelled(graph) == labelled(untitled(lora_graph()))


def test_two_titles_that_look_alike_do_not_both_become_labels():
    """Invisible and compatibility differences are not differences on a form.

    A zero-width joiner and a full-width letter both draw as something the
    user cannot tell from the plain form.  Normalising first turns each pair
    into one string, the pair then collides, and the ladder gives both
    controls names that genuinely differ.
    """

    for other in ("A\u200bction", "\uff21\uff43\uff54\uff49\uff4f\uff4e"):
        graph = titled(lora_graph(), **{"21": "Action", "22": other})
        assert labelled(graph) == labelled(untitled(lora_graph())), other


def test_a_title_in_another_script_is_kept():
    """"Any language" is a real case, not a hostile one.

    The filter keeps letters, numbers and marks of every script -- an
    ASCII-only rule would silently delete most of the world's titles and send
    those graphs to the id rung for no reason.
    """

    graph = titled(lora_graph(), **{"21": CYRILLIC, "22": JAPANESE})
    assert label_of(graph, "strength_model-a47918c4") == (
        "Strength model ({})".format(CYRILLIC)
    )
    assert label_of(graph, "strength_model-5d923eae") == (
        "Strength model ({})".format(JAPANESE)
    )


def test_a_title_that_says_nothing_is_not_a_name():
    """Whitespace, punctuation and symbols alone leave a field with no title."""

    for empty in ("", "   ", "***", "\u2014\u2014\u2014", "\U0001f525"):
        graph = titled(lora_graph(), **{"21": empty, "22": "Cel"})
        assert label_of(graph, "strength_model-a47918c4") == (
            "Strength model (strength_model-a47918c4)"
        ), empty
        # ...and the sibling that does have a name still gets it, so an empty
        # title on one node does not disable the rung for the other.
        assert label_of(graph, "strength_model-5d923eae") == "Strength model (Cel)"


def test_a_meta_block_that_is_not_a_title_says_nothing():
    """A graph is a file the user wrote; every shape of it has to be survivable."""

    shapes = (
        {},
        {"title": None},
        {"title": 7},
        {"title": ["a"]},
        "not an object",
        None,
    )
    for meta in shapes:
        graph = copy.deepcopy(lora_graph())
        graph["21"]["_meta"] = meta
        assert label_of(graph, "strength_model-a47918c4") == (
            "Strength model (strength_model-a47918c4)"
        ), meta

    without = copy.deepcopy(lora_graph())
    del without["21"]["_meta"]
    assert label_of(without, "strength_model-a47918c4") == (
        "Strength model (strength_model-a47918c4)"
    )


# ==========================================================================
# The property, over generated output
# ==========================================================================


#: Sampler inputs a switched value can end up at.  One per switch and never
#: reused: two switches feeding one input is not a graph, and a switch whose
#: output goes nowhere is wired like every other one, which the importer
#: rightly refuses to import at all.
_SAMPLER_INPUTS = ("cfg", "steps", "denoise", "guidance", "shift", "sharpness")

#: Titles the corpus writes on its nodes: present, absent, shared, hostile and
#: confusable, so the title rung is exercised in every state it has.
_TITLES = (
    None,
    "",
    "Alpha",
    "Beta",
    "Alpha",
    "  ",
    "\u202eAlpha\u202c",
    "\uff21lpha",
    "A" * 200,
    CYRILLIC,
    ")(][",
)


def _switch_corpus(rng: random.Random, count: int) -> Dict[str, Any]:
    """``count`` values through ``count // 2`` switches into one sampler."""

    graph: Dict[str, Any] = {
        "10": {
            "class_type": "ExampleCheckpointLoader",
            "inputs": {"ckpt_name": "PLACEHOLDER.safetensors"},
        },
        "20": {
            "class_type": "ExampleTextEncoder",
            "inputs": {"text": "a cat", "clip": ["10", 1]},
        },
        "50": {
            "class_type": "ExampleSampler",
            "inputs": {"seed": 7, "conditioning": ["20", 0], "model": ["10", 0]},
        },
        "60": {"class_type": "ExampleDecode", "inputs": {"samples": ["50", 0]}},
        "70": {"class_type": "ExampleSaveImage", "inputs": {"images": ["60", 0]}},
    }
    for index in range(count):
        switch = "4{}".format(index)
        first, second = "1{}0".format(index), "1{}1".format(index)
        for node, value in ((first, float(index + 1)), (second, index + 2)):
            graph[node] = {
                "class_type": "ExamplePrimitiveValue",
                "inputs": {"value": value},
            }
            title = rng.choice(_TITLES)
            if title is not None:
                graph[node]["_meta"] = {"title": title}
        graph[switch] = {
            "class_type": "ExampleSwitch",
            "inputs": {"on_true": [first, 0], "on_false": [second, 0], "boolean": True},
        }
        graph["50"]["inputs"][_SAMPLER_INPUTS[index]] = [switch, 0]
    return graph


def _chain_corpus(rng: random.Random, count: int) -> Dict[str, Any]:
    """``count`` adapters chained one into the next and into one sampler."""

    graph: Dict[str, Any] = {
        "10": {
            "class_type": "ExampleCheckpointLoader",
            "inputs": {"ckpt_name": "PLACEHOLDER.safetensors"},
        },
    }
    model: List[Any] = ["10", 0]
    clip: List[Any] = ["10", 1]
    for index in range(count):
        node = "2{}".format(index)
        strength = round(0.1 * (index + 1), 3)
        graph[node] = {
            "class_type": "ExampleAdapterLoader",
            "inputs": {
                "lora_name": "PLACEHOLDER-{}.safetensors".format(index),
                "strength_model": strength,
                "strength_clip": strength,
                "model": model,
                "clip": clip,
            },
        }
        title = rng.choice(_TITLES)
        if title is not None:
            graph[node]["_meta"] = {"title": title}
        model, clip = [node, 0], [node, 1]
    graph["30"] = {
        "class_type": "ExampleTextEncoder",
        "inputs": {"text": "a cat", "clip": clip},
    }
    graph["40"] = {
        "class_type": "ExampleSampler",
        "inputs": {"seed": 7, "conditioning": ["30", 0], "model": model},
    }
    graph["50"] = {"class_type": "ExampleDecode", "inputs": {"samples": ["40", 0]}}
    graph["60"] = {"class_type": "ExampleSaveImage", "inputs": {"images": ["50", 0]}}
    return graph


def corpus() -> Iterator[Tuple[str, Dict[str, Any]]]:
    """Every shape this file knows how to build, deterministically.

    Seeded, and seeded per graph, so the corpus is the same corpus on every
    machine and in every run: a property that only holds for the shapes one
    session happened to draw is not a property.
    """

    yield "switch", switch_graph()
    yield "switch-untitled", untitled(switch_graph())
    yield "adapters", lora_graph()
    yield "adapters-untitled", untitled(lora_graph())
    yield "one-adapter", one_adapter_graph()
    yield "shared-binding", shared_binding_graph()
    yield "split-binding", split_binding_graph()
    yield "one-named-one-silent", one_named_one_silent_graph()
    for count in range(1, 6):
        for seed in range(6):
            rng = random.Random((count, seed, "switch").__repr__())
            yield "switch-{}-{}".format(count, seed), _switch_corpus(rng, count)
            rng = random.Random((count, seed, "chain").__repr__())
            yield "chain-{}-{}".format(count, seed), _chain_corpus(rng, count)


@contextmanager
def without_the_rule() -> Iterator[None]:
    """Run the importer with the naming ladder taken out, and put it back.

    The substitute is the identity on the fields it is handed, which is
    exactly what this module did before the rule existed.  Patched on the
    module object, for the length of one ``with`` block, and never on disk --
    a mutation written into a file is a mutation somebody's crashed run leaves
    behind.

    ``setattr`` here is deliberately the raising kind: an implementation that
    renamed or deleted the function fails at this line instead of quietly
    measuring nothing.
    """

    original = getattr(analysis_module, "_distinguish")
    setattr(analysis_module, "_distinguish", lambda fields, namings: list(fields))
    try:
        yield
    finally:
        setattr(analysis_module, "_distinguish", original)
    assert analysis_module._distinguish is original


def test_the_corpus_is_one_the_old_rule_fails_on():
    """A property test over a corpus with no collisions in it proves nothing.

    The rule is taken out for the length of this test and the corpus is
    required to produce the defect.  So the assertion below is about the code
    and not about the shapes this file happened to invent.
    """

    with without_the_rule():
        collided = [
            name
            for name, graph in corpus()
            if len({field.label for field in analyse(graph).fields})
            != len(analyse(graph).fields)
        ]

    assert len(collided) >= 20, collided
    # And the same corpus, with the rule back, has none.
    assert not [
        name
        for name, graph in corpus()
        if len({field.label for field in analyse(graph).fields})
        != len(analyse(graph).fields)
    ]


def test_only_a_label_that_collided_ever_moves():
    """The differential, as a test: nothing else in the catalogue churns.

    Every field of every corpus graph is planned twice -- once with the rule
    and once without -- and the two are compared field by field.  A label that
    was already the only one of its name must come out identical, and a label
    that was one of two must come out different.  A rule that renamed
    everything in sight would satisfy uniqueness and fail here, which is the
    mistake this is written against.
    """

    with without_the_rule():
        plain = {name: labelled(graph) for name, graph in corpus()}

    kept = 0
    moved = 0
    for name, graph in corpus():
        was = plain[name]
        now = labelled(graph)
        assert [field_id for field_id, _ in was] == [
            field_id for field_id, _ in now
        ], name
        alone = {
            label for label in [label for _, label in was] if [
                other for _, other in was
            ].count(label) == 1
        }
        for (field_id, before), (_, after) in zip(was, now):
            if before in alone:
                assert before == after, (name, field_id, before, after)
                kept += 1
            else:
                assert before != after, (name, field_id, before)
                moved += 1

    # Both halves have to have happened, or the loop above proved nothing.
    assert kept > 100, kept
    assert moved > 100, moved


def test_no_id_moves_when_the_rule_runs():
    """Ids are what saved settings hang off, so nothing in naming may reach one.

    Compared against the same importer with the rule removed, over the whole
    corpus: an implementation that let a label, a title or a downstream name
    into the fingerprint moves an id here even where every label looks right.
    """

    with without_the_rule():
        plain = {
            name: [field.id for field in analyse(graph).fields]
            for name, graph in corpus()
        }
    for name, graph in corpus():
        assert [field.id for field in analyse(graph).fields] == plain[name], name


def test_no_definition_ever_carries_two_fields_under_one_label():
    """The property itself, over every graph the corpus generates."""

    for name, graph in corpus():
        plan = analyse(graph)
        labels = [field.label for field in plan.fields]
        assert len(labels) == len(set(labels)), (name, sorted(labels))
        ids = [field.id for field in plan.fields]
        assert len(ids) == len(set(ids)), (name, sorted(ids))
        assert all(label.strip() for label in labels), (name, labels)


def test_no_label_in_the_corpus_is_a_counter():
    """A number appended to a repeated name is the defect again, quieter.

    ``Value (on true) 2`` says nothing about which control it is, which is the
    whole harm.  Every qualifier this rule writes is either a word out of the
    graph's own wiring, a name the author typed, or the field's id.
    """

    counter = re.compile(r"[\s(]\d+\)?$")
    for name, graph in corpus():
        for field in analyse(graph).fields:
            assert not counter.search(field.label), (name, field.label)


def test_a_renamed_field_says_why_in_its_evidence():
    """No generated string without a rule named beside it, labels included."""

    plan = analyse(lora_graph())
    renamed = [field for field in plan.fields if field.id.startswith("strength_model-")]
    assert len(renamed) == 2
    for field in renamed:
        assert "wanted the same label" in field.evidence

    ordinary = analyse(one_adapter_graph())
    assert not [
        field for field in ordinary.fields if "wanted the same label" in field.evidence
    ]


# ==========================================================================
# Deterministic, and independent of node numbering
# ==========================================================================


def renumber(graph: Dict[str, Any], rename) -> Dict[str, Any]:
    """The same graph with every node id replaced, wires included."""

    def wire(value: Any) -> Any:
        if (
            isinstance(value, list)
            and len(value) == 2
            and isinstance(value[0], str)
            and value[0] in graph
        ):
            return [rename(value[0]), value[1]]
        return value

    moved: Dict[str, Any] = {}
    for node, entry in graph.items():
        copied = copy.deepcopy(entry)
        copied["inputs"] = {
            name: wire(value) for name, value in copied.get("inputs", {}).items()
        }
        moved[rename(node)] = copied
    assert len(moved) == len(graph)
    return moved


#: Renumberings chosen to break different orderings: the first reverses the
#: numeric order every ``sorted`` in the importer walks, the second makes the
#: ids non-numeric so they sort as text instead.
RENUMBERINGS = {
    "reversed": lambda node: str(9000 - int(node)),
    "lettered": lambda node: "n{}".format(node),
}


#: The corpus shapes whose labels a renumbering **does** move, with the
#: movement written out.  There is one mechanism behind every entry, it is not
#: this rule's doing, and it is here rather than excluded so that the guarantee
#: below is a statement about the whole corpus instead of about a chosen part of
#: it.
#:
#: ``split-binding`` collapses two inputs into one control whose members reach
#: two *different* consumer input names, ``on_true`` and ``on_false``.  The
#: base label -- the one this module produced before any of this, from
#: ``_hint(members[0])`` -- is read off whichever member sorts first, so a
#: numeric renumbering swaps which of the two names it uses, and once the base
#: label differs the two fields no longer collide and the ladder is never
#: reached.  Measured identical on f06eb2d: the same graph moves the same way
#: there, where it also arrives with the duplicate label this card is about.
#: It is T-0113's mechanism, coming out at a label instead of at an id, and
#: T-0113 is where it gets fixed.  When it is, this entry fails and goes.
#:
#: The seeded switch shapes of two or more values reach the same mechanism since
#: T-0102.  Each holds the number ``n`` twice, written ``n.0`` on one
#: ``ExamplePrimitiveValue`` and ``n`` on another -- the same undeclared input on
#: the same class -- and one number written two ways is one control, as it was
#: when written alike.  Those collapsed controls feed one switch's ``on_false``
#: and the next switch's ``on_true``, so their base label is read off whichever
#: member sorts first, exactly as ``split-binding``'s is.  The movement depends
#: only on the value count (a seed chooses node titles, and these labels come
#: from the wiring), and it is T-0160's to remove along with the entry above.
_SWITCH_LABELS_MOVED = {
    2: {
        "Value (on true)": "Value (on true, cfg)",
        "Value (on false, steps)": "Value (on false)",
        "Value (on false, on true)": "Value (on true, on false)",
    },
    3: {
        "Value (on true)": "Value (on true, cfg)",
        "Value (on false, denoise)": "Value (on false)",
        "Value (on false, on true, cfg)": "Value (on true, on false, cfg)",
        "Value (on false, on true, denoise)": "Value (on true, on false, denoise)",
    },
    4: {
        "Value (on true)": "Value (on true, cfg)",
        "Value (on false, guidance)": "Value (on false)",
        "Value (on false, on true, cfg)": "Value (on true, on false, cfg)",
    },
    5: {
        "Value (on true)": "Value (on true, cfg)",
        "Value (on false, shift)": "Value (on false)",
        "Value (on false, on true, cfg)": "Value (on true, on false, cfg)",
        "Value (on false, on true, guidance)": "Value (on true, on false, guidance)",
    },
}
LABELS_MOVED_BY_RENUMBERING = {
    ("split-binding", "reversed"): {
        "Value (on true, on false)": "Value (on false)",
        "Value (on true, batch size)": "Value (on true)",
    },
    **{
        ("switch-{}-{}".format(count, seed), "reversed"): moved
        for count, moved in _SWITCH_LABELS_MOVED.items()
        for seed in range(6)
    },
}


def test_renumbering_a_graph_does_not_rename_a_control():
    """Proved by renumbering, not by asserting that nothing reads a node id.

    Labels, and the fields they belong to, are compared by binding rather than
    by id: a re-export moves node ids, and ``bind`` says which node input a
    control writes into, so the pairing survives the renumbering that the
    assertion is about.

    **What is guaranteed, exactly.**  Every rung this card added reads only
    names, shapes and depths, merged across a field's members in ways that do
    not depend on the order the members are in -- so no rung of the ladder can
    be moved by a renumbering, and :data:`LABELS_MOVED_BY_RENUMBERING` is
    empty for every shape the ladder decides.  What is **not** guaranteed is
    rung 0, the base label, which predates this card and is read from the
    first member of a group in node order.  One corpus shape reached it when
    this was written, and moved identically on the commit it was written
    against; the switch shapes have reached it too since T-0102 made one number
    written two ways one control.  Every such movement is written down above
    rather than excluded from the corpus.

    Ids are not asserted here, because they are somebody else's subject: a
    collapsed field used to take its id from whichever member sorted first,
    and since T-0113 it does not.  `test_sync_id_stability.py` measures that
    over this corpus as well as its own.
    """

    seen = set()
    for name, graph in corpus():
        plan = analyse(graph)
        for form, rename in RENUMBERINGS.items():
            moved = analyse(renumber(graph, rename))
            assert not moved.problems, (name, form, moved.problems)
            # ``bind`` is written in node order, so the order of a field's
            # targets legitimately moves with the numbering; which inputs a
            # control writes into does not, and that is the identity used.
            known = LABELS_MOVED_BY_RENUMBERING.get((name, form), {})
            if known:
                seen.add((name, form))
            expected = {
                frozenset(
                    (rename(node), input_name) for node, input_name in field.targets
                ): known.get(field.label, field.label)
                for field in plan.fields
            }
            assert {
                frozenset(field.targets): field.label for field in moved.fields
            } == expected, (name, form)

    # Every documented exception has to have been reached, or the dictionary
    # above is quietly excusing a shape the corpus no longer contains.
    assert seen == set(LABELS_MOVED_BY_RENUMBERING), (
        seen,
        set(LABELS_MOVED_BY_RENUMBERING),
    )


def test_the_one_label_a_renumbering_moves_is_the_base_label_and_predates_this():
    """The exception above, stated on its own so that it cannot be missed.

    Two inputs holding one value collapse into one control; one of them feeds
    a switch's ``on_true`` and the other its ``on_false``.  Under the numbering
    the graph was exported with, the base label of both fields is
    ``Value (on true)`` -- they collide, and the ladder names them apart.
    Renumbered, the collapsed field's first member is the other one, its base
    label becomes ``Value (on false)``, the two no longer collide, and the
    ladder is never asked.

    So the movement is not a rung choosing differently: it is the input to the
    ladder that moved.  Asserted here so that the limit of the determinism
    claim is a measured fact in this file rather than a sentence in a
    docstring, and so that fixing T-0113 has a test that says what changed.
    """

    graph = split_binding_graph()
    # Sorted, both times.  The plan is ordered by field id, T-0113 moved the
    # collapsed field's id when it stopped minting from the first member, and
    # the two ``Value`` fields therefore changed places in the list.  Which
    # labels a definition carries is what this test is about; the ids
    # themselves are `test_sync_id_stability.py`'s subject, and no renumbering
    # moves one any more.
    assert sorted(label for _, label in labelled(graph)) == [
        "Boolean",
        "Prompt",
        "Seed",
        "Value (on true, batch size)",
        "Value (on true, on false)",
    ]
    moved = labelled(renumber(graph, RENUMBERINGS["reversed"]))
    assert sorted(label for _, label in moved) == [
        "Boolean",
        "Prompt",
        "Seed",
        "Value (on false)",
        "Value (on true)",
    ]
    # Whatever else moved, the guarantee this card makes did not: the two
    # controls still have two names.
    assert len({label for _, label in moved}) == len(moved)


def test_a_control_with_several_bindings_is_named_from_all_of_them():
    """One field, two node inputs, two different places its value ends up.

    The name is built from the union of what its bindings reach, at the
    shortest distance any of them reaches it by -- both order-independent --
    rather than from whichever member happened to sort first.  Renumbering is
    what proves it: read the first member instead and this label becomes
    ``Value (on true, steps)`` as soon as the node ids move.
    """

    def collapsed(graph: Dict[str, Any]) -> List[Any]:
        return [
            field
            for field in analyse(graph).fields
            if len(field.targets) > 1 and field.id.startswith("value")
        ]

    graph = shared_binding_graph()
    shared = collapsed(graph)
    assert [field.targets for field in shared] == [(("31", "value"), ("32", "value"))]
    assert [field.label for field in shared] == ["Value (on true, cfg)"]

    for form, rename in RENUMBERINGS.items():
        moved = collapsed(renumber(graph, rename))
        assert [field.label for field in moved] == ["Value (on true, cfg)"], form


def test_two_runs_over_one_graph_agree():
    """Nothing here depends on a hash seed or on a set's iteration order."""

    for name, graph in corpus():
        assert labelled(graph) == labelled(copy.deepcopy(graph)), name


def test_the_order_the_nodes_are_written_in_does_not_change_a_label():
    """A re-export that shuffles the JSON is the same workflow."""

    for name, graph in corpus():
        shuffled = {node: graph[node] for node in reversed(list(graph))}
        assert list(shuffled) != list(graph), name
        assert labelled(shuffled) == labelled(graph), name


# ==========================================================================
# Provenance
# ==========================================================================


def test_the_suite_measured_this_checkout():
    """Which package tree these assertions were made against.

    Stated as a relationship between two paths rather than as a claim about
    the mechanism: the module under test has to be the one that sits beside
    this test file in the same checkout.  A run that imported an installed
    copy, or another worktree's, would fail here -- which is the only thing a
    reader of a green suite actually needs to know.
    """

    here = Path(__file__).resolve()
    checkout = here.parents[2]
    module = Path(analysis_module.__file__).resolve()
    assert module == checkout / "gateway" / "localcanvas_gateway" / "workflows" / (
        "sync"
    ) / "analysis.py", (module, checkout)


def test_the_public_examples_still_import_unchanged():
    """The repository's own redistributable graphs, as a last differential."""

    examples = Path(__file__).resolve().parents[2] / "workflows" / "examples"
    found = sorted(examples.glob("*_api.json"))
    assert found, examples
    for path in found:
        graph = json.loads(path.read_text(encoding="utf-8"))
        plan = analyse(graph)
        labels = [field.label for field in plan.fields]
        assert len(labels) == len(set(labels)), (path.name, labels)
        assert not [
            field for field in plan.fields if "wanted the same label" in field.evidence
        ], path.name
