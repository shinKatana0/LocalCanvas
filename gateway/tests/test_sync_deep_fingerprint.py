"""Same-role inputs the base fingerprint cannot tell apart, told apart further out (T-0220).

Two seeds in a two-pass sampler and two reference pictures are ordinary, and
two hops of wiring is often not enough to say which is which: both seeds feed a
sampler of one class whose output goes to a node of one class, and only the
third hop differs.  The importer refused those workflows rather than mint an
unstable id.  Now it looks one hop further, and again, for the colliding groups
and only for them.

What is held down here, each against the mistake it guards:

* **the ids, verbatim** -- for two seeds and for two image loaders that are
  identical at depth 2 and differ at depth 3;
* **stable across a renumbering** of every node id, and across the order the
  nodes are written in the JSON -- nothing about a node id is in an id;
* **no title in an id**: the same graph with node titles added mints the same
  ids, and two groups that differ only by title are still refused;
* **a group that did not collide keeps its depth-2 id**, validated against the
  id the pre-change importer minted for it;
* **a second collision does not move the first**;
* **genuinely indistinguishable groups are still refused**, verbatim, for
  seeds and for pictures, including a graph with a cycle in it, which is where
  the bound on the walk is what stops it.

Every class name, input name and value below is invented.
"""

from __future__ import annotations

import copy
from types import SimpleNamespace
from typing import Any, Callable, Dict, List, Tuple

from localcanvas_gateway.workflows.sync import analyse
from localcanvas_gateway.workflows.sync import analysis as analysis_module


def seeds_graph() -> Dict[str, Any]:
    """Two noise seeds, identical for two hops, different at the third.

    ``1 -> 3 -> 5 -> 7 -> 9`` and ``2 -> 4 -> 6 -> 8 -> 10``: a sampler of one
    class, an upscale of one class, then a decoder on one side and a refiner on
    the other, and a save of one class after each.  The last hop is there so
    that a fourth hop *adds* something: an id taken at depth 4 is then a
    different id from one taken at depth 3, and a rule that looked further than
    it had to could not hide behind a chain that had already ended.
    """

    return {
        "1": {"class_type": "ExampleNoise", "inputs": {"noise_seed": 11}},
        "2": {"class_type": "ExampleNoise", "inputs": {"noise_seed": 22}},
        "3": {"class_type": "ExampleSampler", "inputs": {"noise": ["1", 0]}},
        "4": {"class_type": "ExampleSampler", "inputs": {"noise": ["2", 0]}},
        "5": {"class_type": "ExampleUpscale", "inputs": {"samples": ["3", 0]}},
        "6": {"class_type": "ExampleUpscale", "inputs": {"samples": ["4", 0]}},
        "7": {"class_type": "ExampleDecode", "inputs": {"samples": ["5", 0]}},
        "8": {"class_type": "ExampleRefine", "inputs": {"samples": ["6", 0]}},
        "9": {"class_type": "ExampleSave", "inputs": {"images": ["7", 0]}},
        "10": {"class_type": "ExampleSave", "inputs": {"images": ["8", 0]}},
    }


def pictures_graph() -> Dict[str, Any]:
    """Two reference pictures, identical for two hops, different at the third."""

    return {
        "11": {"class_type": "ExampleImageLoad", "inputs": {"image": "first.png"}},
        "12": {"class_type": "ExampleImageLoad", "inputs": {"image": "second.png"}},
        "13": {"class_type": "ExampleScale", "inputs": {"image": ["11", 0]}},
        "14": {"class_type": "ExampleScale", "inputs": {"image": ["12", 0]}},
        "15": {"class_type": "ExampleEncode", "inputs": {"pixels": ["13", 0]}},
        "16": {"class_type": "ExampleEncode", "inputs": {"pixels": ["14", 0]}},
        "17": {"class_type": "ExampleGuide", "inputs": {"latent": ["15", 0]}},
        "18": {"class_type": "ExampleStartFrame", "inputs": {"latent": ["16", 0]}},
    }


def both_graph() -> Dict[str, Any]:
    graph = seeds_graph()
    graph.update(pictures_graph())
    return graph


def third_seed(graph: Dict[str, Any]) -> Dict[str, Any]:
    """Add a seed wired somewhere else, so it does not collide at depth 2."""

    graph = copy.deepcopy(graph)
    graph["31"] = {"class_type": "ExampleNoise", "inputs": {"noise_seed": 33}}
    graph["32"] = {"class_type": "ExampleOtherSampler", "inputs": {"noise": ["31", 0]}}
    return graph


def summary(graph: Dict[str, Any]) -> List[Tuple[str, str, str, Tuple[Tuple[str, str], ...]]]:
    plan = analyse(graph)
    assert plan.problems == (), plan.problems
    return [(field.id, field.label, field.type, field.targets) for field in plan.fields]


def depth_two(graph: Dict[str, Any], node: str, name: str) -> str:
    return analysis_module._fingerprint(
        graph, analysis_module._consumers(graph), node, name
    )


def renumber(graph: Dict[str, Any], rename: Callable[[str], str]) -> Dict[str, Any]:
    """The same graph with every node id replaced, wires included, written in
    the reverse of its original order."""

    moved: Dict[str, Any] = {}
    for node in reversed(list(graph)):
        entry = copy.deepcopy(graph[node])
        entry["inputs"] = {
            name: ([rename(value[0]), value[1]] if isinstance(value, list) else value)
            for name, value in reversed(list(entry["inputs"].items()))
        }
        moved[rename(node)] = entry
    assert len(moved) == len(graph)
    return moved


#: A permutation that neither keeps nor reverses the numeric order.
_PERMUTATION = {
    "1": "508", "2": "77", "3": "9", "4": "1203", "5": "41", "6": "300",
    "7": "2", "8": "666", "9": "70", "10": "4", "11": "5", "12": "912", "13": "120", "14": "31",
    "15": "7", "16": "88", "17": "1000", "18": "13", "31": "400", "32": "3",
}


def moved(target: Tuple[str, str]) -> Tuple[str, str]:
    return (_PERMUTATION[target[0]], target[1])


# ==========================================================================
# The fixtures are the shape the card is about
# ==========================================================================


def test_the_fixture_groups_collide_at_depth_two() -> None:
    """Without this, "told apart at depth 3" could be told apart at depth 2."""

    seeds = seeds_graph()
    assert depth_two(seeds, "1", "noise_seed") == depth_two(seeds, "2", "noise_seed")
    pictures = pictures_graph()
    assert depth_two(pictures, "11", "image") == depth_two(pictures, "12", "image")
    assert analysis_module.FINGERPRINT_DEPTH == 2


# ==========================================================================
# Distinct, verbatim, stable
# ==========================================================================

SEED_FIELDS = [
    ("seed-03302d7c", "Seed (seed-03302d7c)", "integer", (("1", "noise_seed"),)),
    ("seed-599dbeb6", "Seed (seed-599dbeb6)", "integer", (("2", "noise_seed"),)),
]

PICTURE_FIELDS = [
    ("image-63ae6e50", "Image (image-63ae6e50)", "image", (("11", "image"),)),
    ("image-704d0827", "Image (image-704d0827)", "image", (("12", "image"),)),
]


def test_two_seeds_identical_at_depth_two_get_distinct_ids() -> None:
    assert summary(seeds_graph()) == SEED_FIELDS


def test_two_pictures_identical_at_depth_two_get_two_picture_fields() -> None:
    assert summary(pictures_graph()) == PICTURE_FIELDS


def test_the_ids_survive_a_renumbering_and_a_reordering() -> None:
    graph = both_graph()
    original = summary(graph)
    assert original == PICTURE_FIELDS + SEED_FIELDS

    renumbered = summary(renumber(graph, lambda node: _PERMUTATION[node]))

    assert renumbered == [
        (field_id, label, kind, tuple(moved(target) for target in targets))
        for field_id, label, kind, targets in original
    ]


def test_node_titles_are_not_part_of_an_id() -> None:
    graph = both_graph()
    for node, title in (("1", "First pass"), ("2", "Second pass"), ("11", "Face"), ("12", "Pose")):
        graph[node]["_meta"] = {"title": title}

    ids = [field[0] for field in summary(graph)]

    assert ids == [field[0] for field in PICTURE_FIELDS + SEED_FIELDS]


def upstream_graph() -> Dict[str, Any]:
    """Two samplers told apart only by what feeds them, three hops up (T-0220's review).

    Each sampler holds its own seed.  Downstream both go decode -> save, the
    same classes all the way to the end of the graph.  Upstream each takes its
    model through a patch and a shift, of one class each, from a loader -- and
    the two loaders are of different classes.  So the pair collides at depth 2,
    and nothing but the **upstream** half of a deeper fingerprint can separate
    it.  Every fixture above separates downstream from nodes with nothing
    upstream, which is how a fingerprint ignoring its upstream half went
    unnoticed.
    """

    graph: Dict[str, Any] = {}
    for prefix, seed, loader in (("2", 101, "ExampleModelLoader"), ("6", 202, "ExampleOtherModelLoader")):
        loader_id, shift, patch, sampler, decode, save = (
            prefix + suffix for suffix in ("0", "1", "2", "3", "4", "5")
        )
        graph.update(
            {
                loader_id: {"class_type": loader, "inputs": {}},
                shift: {"class_type": "ExampleShift", "inputs": {"model": [loader_id, 0]}},
                patch: {"class_type": "ExamplePatch", "inputs": {"model": [shift, 0]}},
                sampler: {
                    "class_type": "ExampleSampler",
                    "inputs": {"seed": seed, "model": [patch, 0]},
                },
                decode: {"class_type": "ExampleDecode", "inputs": {"samples": [sampler, 0]}},
                save: {"class_type": "ExampleSave", "inputs": {"images": [decode, 0]}},
            }
        )
    return graph


UPSTREAM_FIELDS = [
    ("seed-32a023e8", "Seed (seed-32a023e8)", "integer", (("23", "seed"),)),
    ("seed-5356b858", "Seed (seed-5356b858)", "integer", (("63", "seed"),)),
]


def test_two_seeds_told_apart_only_upstream_get_distinct_ids() -> None:
    graph = upstream_graph()
    consumers = analysis_module._consumers(graph)
    # The shape the case needs: one depth-2 fingerprint, the same downstream
    # shape as far as the graph goes, and an upstream shape that differs only
    # at the third hop.
    assert depth_two(graph, "23", "seed") == depth_two(graph, "63", "seed")
    assert analysis_module._down_shape(graph, consumers, "23", 6) == analysis_module._down_shape(
        graph, consumers, "63", 6
    )
    assert analysis_module._up_shape(graph, "23", 2) == analysis_module._up_shape(graph, "63", 2)
    assert analysis_module._up_shape(graph, "23", 3) != analysis_module._up_shape(graph, "63", 3)

    assert summary(graph) == UPSTREAM_FIELDS

    renumbered = summary(renumber(graph, lambda node: str(5000 - int(node) * 7)))
    assert [(field_id, label) for field_id, label, _, _ in renumbered] == [
        (field_id, label) for field_id, label, _, _ in UPSTREAM_FIELDS
    ]


# ==========================================================================
# Only a collision is looked at further
# ==========================================================================


def test_a_group_that_did_not_collide_keeps_its_depth_two_id() -> None:
    """The pin, validated against the pre-change importer.

    ``seed-fa575d99`` is what the importer minted for node 31 before adaptive
    depth existed, in the variant below where nodes 1 and 2 hold one value and
    are therefore one control -- so no collision exists and that importer had
    an id to give.  It must be the id node 31 gets now in both graphs: the one
    where 1 and 2 collide and are separated further out, and that variant.
    """

    pinned = "seed-fa575d99"
    colliding = third_seed(seeds_graph())
    collapsed = copy.deepcopy(colliding)
    collapsed["2"]["inputs"]["noise_seed"] = 11

    for graph in (colliding, collapsed):
        plan = analyse(graph)
        assert plan.problems == (), plan.problems
        found = [field.id for field in plan.fields if ("31", "noise_seed") in field.targets]
        assert found == [pinned]
    assert pinned == "seed-" + depth_two(colliding, "31", "noise_seed")

    # And the two that collided really were given deeper ids.
    assert [field.id for field in analyse(colliding).fields] == [
        "seed-03302d7c",
        "seed-599dbeb6",
        pinned,
    ]


def test_a_second_collision_does_not_move_the_first() -> None:
    """Two collisions in one role, settled at different depths, independently."""

    graph = seeds_graph()
    # A second pair, identical for three hops and different at the fourth.
    graph.update(
        {
            "41": {"class_type": "ExampleNoise", "inputs": {"noise_seed": 44}},
            "42": {"class_type": "ExampleNoise", "inputs": {"noise_seed": 55}},
            "43": {"class_type": "ExampleVideoSampler", "inputs": {"noise": ["41", 0]}},
            "44": {"class_type": "ExampleVideoSampler", "inputs": {"noise": ["42", 0]}},
            "45": {"class_type": "ExampleUpscale", "inputs": {"samples": ["43", 0]}},
            "46": {"class_type": "ExampleUpscale", "inputs": {"samples": ["44", 0]}},
            "47": {"class_type": "ExampleDecode", "inputs": {"samples": ["45", 0]}},
            "48": {"class_type": "ExampleDecode", "inputs": {"samples": ["46", 0]}},
            "49": {"class_type": "ExampleSave", "inputs": {"images": ["47", 0]}},
            "50": {"class_type": "ExamplePreview", "inputs": {"images": ["48", 0]}},
        }
    )
    assert depth_two(graph, "41", "noise_seed") == depth_two(graph, "42", "noise_seed")
    # The second pair still collides at depth 3, where the first separates --
    # so a rule taking one depth for the whole role would move the first ids.
    shapes = analysis_module._DeepShapes(graph, analysis_module._consumers(graph))

    def key(node: str, depth: int) -> str:
        return shapes.key(
            SimpleNamespace(node=node, input="noise_seed", class_type="ExampleNoise"), depth
        )

    assert key("41", 3) == key("42", 3)
    assert key("41", 4) != key("42", 4)
    assert key("1", 3) != key("2", 3)
    # And the first pair's shapes still grow at depth 4, so an id taken there
    # would not be the id taken at depth 3.
    assert key("1", 4) != key("1", 3)

    plan = analyse(graph)
    assert plan.problems == ()
    fields = {field.targets: field.id for field in plan.fields}

    assert fields[(("1", "noise_seed"),)] == "seed-03302d7c"
    assert fields[(("2", "noise_seed"),)] == "seed-599dbeb6"
    assert fields[(("41", "noise_seed"),)] == "seed-af5ba98e"
    assert fields[(("42", "noise_seed"),)] == "seed-4a25ad5f"


# ==========================================================================
# Genuinely indistinguishable is still refused
# ==========================================================================


def test_seeds_wired_identically_all_the_way_are_refused_verbatim() -> None:
    graph = seeds_graph()
    graph["8"]["class_type"] = "ExampleDecode"
    # Titles differ, and they are still not a reason to tell the two apart.
    graph["1"]["_meta"] = {"title": "First pass"}
    graph["2"]["_meta"] = {"title": "Second pass"}

    plan = analyse(graph)

    assert plan.fields == ()
    assert plan.problems == (
        "node 1 input 'noise_seed', node 2 input 'noise_seed' hold different values "
        "for 'seed' and are wired identically, so nothing tells one from the other "
        "and no id can be minted for either.",
    )


def test_pictures_wired_identically_all_the_way_are_refused_verbatim() -> None:
    graph = pictures_graph()
    graph["18"]["class_type"] = "ExampleGuide"

    plan = analyse(graph)

    assert plan.fields == ()
    assert plan.problems == (
        "node 11 input 'image', node 12 input 'image' hold different images and the "
        "graph gives them the same part to play, so which picture belongs in which "
        "slot cannot be decided; a media field bound to the wrong slot is wrong "
        "silently.",
    )


def test_the_walk_stops_when_nothing_further_is_left_to_see() -> None:
    """Identical chains that end: the walk stops at their end, not at the bound.

    Two hundred unconnected nodes make the bound -- the size of the graph --
    far larger than the chains are long, so a walk that only stopped at the
    bound would compute some two hundred depths for all of them.  Counted on
    the one method that computes a depth, so this is a count and not a timing.
    """

    graph = seeds_graph()
    graph["8"]["class_type"] = "ExampleDecode"
    for index in range(200):
        graph[str(1000 + index)] = {"class_type": "ExampleIdle", "inputs": {}}

    computed: List[int] = []
    original = analysis_module._DeepShapes._deepen

    def counting(self: Any) -> None:
        computed.append(1)
        original(self)

    analysis_module._DeepShapes._deepen = counting  # type: ignore[assignment]
    try:
        plan = analyse(graph)
    finally:
        analysis_module._DeepShapes._deepen = original  # type: ignore[assignment]
    assert analysis_module._DeepShapes._deepen is original

    assert plan.fields == ()
    assert "are wired identically" in plan.problems[0], plan.problems
    # The chains are four hops long: depths 1 to 5 are needed to see that the
    # fifth adds nothing to the fourth.
    assert len(computed) == 5, len(computed)


def test_a_cycle_ends_the_walk_at_the_size_of_the_graph() -> None:
    """Two identical loops never stop growing; the bound is what ends the walk."""

    graph = {
        "1": {"class_type": "ExampleNoise", "inputs": {"noise_seed": 11}},
        "2": {"class_type": "ExampleNoise", "inputs": {"noise_seed": 22}},
        "3": {"class_type": "ExampleSampler", "inputs": {"noise": ["1", 0], "latent": ["5", 0]}},
        "4": {"class_type": "ExampleSampler", "inputs": {"noise": ["2", 0], "latent": ["6", 0]}},
        "5": {"class_type": "ExampleLoop", "inputs": {"samples": ["3", 0]}},
        "6": {"class_type": "ExampleLoop", "inputs": {"samples": ["4", 0]}},
    }

    plan = analyse(graph)

    assert plan.fields == ()
    assert "are wired identically" in plan.problems[0], plan.problems
