"""An id that survives a renumbering, including a collapsed control's.

`analysis.py` promises that a logical field's id is derived from the part the
input plays and never from a node id -- because Phase 3 keys My defaults, the
current draft, saved setups and imported profiles on it.  It kept that promise
for a field bound to one input and broke it for a field bound to several: the
id took its fingerprint from ``members[0]``, members are sorted by node id, so
a re-export that renumbered the graph put a different member first and minted a
**different id** for a control nothing about which had changed (T-0113).

That is not a theoretical ordering nit.  ComfyUI renumbers nodes on re-export,
so the shape of the harm is: a user sets up a workflow, edits it in their own
editor, syncs, and their settings are gone -- attached to an id nothing
produces any more.

What this file measures, and why in this order
----------------------------------------------
* the fixtures **are** the shape the defect needs, asserted rather than
  assumed: a role carried by more than one group *and* a group with more than
  one member.  A first attempt at measuring this bug used two chained loaders,
  which have a unique role and therefore a bare-role id with no fingerprint in
  it at all, and saw nothing move.  A fixture that cannot break makes every
  assertion below vacuous, so :func:`test_the_fixtures_are_the_shape_the_defect_needs`
  comes first;
* the **old rule is put back**, for the length of a ``with`` block and never on
  disk, and the corpus is required to move an id under it.  So the assertions
  are about this module's code and not about graphs that were never at risk;
* then the property itself, twice and from two directions: **by permuting** the
  members of a real analysed graph -- every permutation, checked at the moment
  the id is minted -- and **by renumbering** whole graphs end to end and
  comparing the ids verbatim.

Every id in this file is written out in full.  A count of stable ids passes a
run in which two of them swapped.

Every class type, input name, title and value below is invented for this file.
None of it names a real node, a real pack, a real model or anybody's workflow,
and `config/local/` was not read to write it.
"""

from __future__ import annotations

import copy
import itertools
import json
import random
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Callable, Dict, Iterator, List, Tuple

from localcanvas_gateway.workflows.sync import analyse
from localcanvas_gateway.workflows.sync import analysis as analysis_module

# ==========================================================================
# The shapes
# ==========================================================================


def _frame() -> Dict[str, Any]:
    """The parts every graph here needs to be an importable workflow."""

    return {
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


def _values(graph: Dict[str, Any], *wiring: Tuple[str, Any, str]) -> Dict[str, Any]:
    """Add ``(node, value, sampler input)`` triples, each through its own switch.

    The switch is what puts a second hop between the value and the sampler, so
    that the three members of a collapsed control reach three *different*
    consumer names and therefore carry three different fingerprints.  Without
    it every member of a group would be wired alike, the group would speak with
    one voice, and the bug would have nothing to choose between.
    """

    for node, value, target in wiring:
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


def three_bindings_graph() -> Dict[str, Any]:
    """One control over three node inputs, each ending somewhere different.

    Nodes 31, 32 and 33 hold the same value, so the importer collapses them
    into a single field the user sets once -- and that one field reaches
    ``cfg``, ``denoise`` and ``noise_scale``, three different places, so its
    three members carry three different fingerprints.  Node 34 holds a
    different value and is a field of its own, which is what keeps the role
    ``value`` from being unique and makes every id here carry a fingerprint.

    Three rather than two members deliberately: with two, "sorted the other
    way" and "permuted" are the same thing, and a rule that merely reversed the
    sort would look fixed.
    """

    return _values(
        _frame(),
        ("31", 1.0, "cfg"),
        ("32", 1.0, "denoise"),
        ("33", 1.0, "noise_scale"),
        ("34", 2.0, "guidance"),
    )


def two_bindings_graph() -> Dict[str, Any]:
    """The measured shape from the card: two members collapse, one does not."""

    return _values(
        _frame(),
        ("31", 1.0, "cfg"),
        ("32", 1.0, "steps"),
        ("33", 2.0, "denoise"),
    )


def single_bindings_graph() -> Dict[str, Any]:
    """No group has more than one member: nothing here was ever at risk.

    Here so that "the fix moved nothing that was already right" is measured on
    a graph whose ids are minted by the very path the fix rewrote, rather than
    on graphs whose ids are bare roles and could not have moved either way.
    """

    return _values(
        _frame(),
        ("31", 1.0, "cfg"),
        ("32", 2.0, "steps"),
        ("33", 3.0, "denoise"),
    )


def one_voice_graph() -> Dict[str, Any]:
    """A collapsed control whose two members are wired **alike**.

    Nodes 31 and 32 hold the same value and each feeds its own switch's
    ``on_true``, and each switch feeds the ``cfg`` of its own sampler -- and
    the two samplers are of one class.  A fingerprint is built from input names
    and class types and from nothing else, so within the two hops it looks the
    two members are the same shape and carry the **same fingerprint**.  Node 33
    is wired into a ``denoise`` instead, so its fingerprint differs and the role
    ``value`` is carried by two groups, which is what makes these ids carry a
    fingerprint at all.

    This is the case the reduction is written for and the one nothing else
    reaches: measured over every corpus in this file and in
    `test_sync_label_uniqueness.py`, ``_group_fingerprint`` is called 381 times
    and not once with a group of several members that agree.  Without this
    graph the sentence "any group whose members are wired alike" is a promise
    no test is pointed at, which is this phase's own commonest way of being
    wrong.
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
    }
    for node, value, target, sampler in (
        ("31", 1.0, "cfg", "51"),
        ("32", 1.0, "cfg", "52"),
        ("33", 2.0, "denoise", "51"),
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
        entry = graph.setdefault(
            sampler,
            {
                "class_type": "ExampleSampler",
                "inputs": {"seed": 7, "conditioning": ["20", 0], "model": ["10", 0]},
            },
        )
        entry["inputs"][target] = [switch, 0]
    graph["60"] = {"class_type": "ExampleDecode", "inputs": {"samples": ["51", 0]}}
    graph["61"] = {"class_type": "ExampleDecode", "inputs": {"samples": ["52", 0]}}
    graph["70"] = {"class_type": "ExampleSaveImage", "inputs": {"images": ["60", 0]}}
    graph["71"] = {"class_type": "ExampleSaveImage", "inputs": {"images": ["61", 0]}}
    return graph


def corpus() -> Iterator[Tuple[str, Dict[str, Any]]]:
    yield "three-bindings", three_bindings_graph()
    yield "two-bindings", two_bindings_graph()
    yield "single-bindings", single_bindings_graph()
    yield "one-voice", one_voice_graph()


# ==========================================================================
# Reading a plan, and renumbering a graph
# ==========================================================================


def ids(graph: Dict[str, Any]) -> List[str]:
    """Every field id of one graph, in the plan's own order."""

    plan = analyse(graph)
    assert not plan.problems, plan.problems
    return [field.id for field in plan.fields]


def by_binding(graph: Dict[str, Any]) -> Dict[frozenset, str]:
    """``{which node inputs a field writes into} -> its id``.

    Fields are identified by their bindings rather than by their ids, because
    the id is the thing under test: comparing ids to ids across a renumbering
    would be comparing a value with itself.
    """

    plan = analyse(graph)
    assert not plan.problems, plan.problems
    found = {frozenset(field.targets): field.id for field in plan.fields}
    assert len(found) == len(plan.fields), "two fields with one set of bindings"
    return found


def renumber(graph: Dict[str, Any], rename: Callable[[str], str]) -> Dict[str, Any]:
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
    assert len(moved) == len(graph), "a renumbering that merged two nodes"
    return moved


#: A fixed permutation of the node numbers these graphs use.  A permutation
#: rather than an arithmetic rule, because every cheap arithmetic rule --
#: adding, multiplying, prefixing -- turns out to preserve the order of small
#: numbers, which is the one thing this renumbering exists not to do.  Seeded
#: from a constant, so it is the same permutation on every machine and in every
#: run: a property that holds only for the ordering one session happened to
#: draw is not a property.
_SCRAMBLED = list(range(1009))
random.Random("T-0113").shuffle(_SCRAMBLED)


def _scramble(node: str) -> str:
    """A numbering that neither reverses the order nor preserves it.

    ``reversed`` moves a group of two into its only other order, so a rule that
    merely sorted the other way would satisfy it.  This one puts a group of
    three into an order that is neither, and it is injective, so no two nodes
    can be merged by it -- asserted, because a renumbering that quietly merged
    two nodes would be measuring a different graph.
    """

    number = int(node)
    assert 0 <= number < len(_SCRAMBLED), node
    return str(100000 + _SCRAMBLED[number])


#: Renumberings chosen to break different orderings: the first reverses the
#: numeric order every ``sorted`` in the importer walks, the second makes the
#: ids sort as text instead of numerically, the third does neither.
RENUMBERINGS: Dict[str, Callable[[str], str]] = {
    "reversed": lambda node: str(9000 - int(node)),
    "lettered": lambda node: "n{}".format(node),
    "scrambled": _scramble,
}


# ==========================================================================
# The old rule, and the permutation spy
# ==========================================================================


@contextmanager
def the_old_rule() -> Iterator[None]:
    """Mint an id the way this module minted it before T-0113, and put it back.

    The substitute reads the first member's fingerprint, which is exactly what
    ``_fields_from`` did on ``f06eb2d``.  Patched on the module object, for the
    length of one ``with`` block, and never on disk -- a mutation written into
    a file is one somebody's crashed run leaves behind.

    ``getattr`` here is deliberately the raising kind: an implementation that
    renamed the function, or inlined it back into its caller, fails at this
    line instead of quietly measuring nothing.
    """

    original = getattr(analysis_module, "_group_fingerprint")
    setattr(
        analysis_module,
        "_group_fingerprint",
        lambda members: members[0].fingerprint,
    )
    try:
        yield
    finally:
        setattr(analysis_module, "_group_fingerprint", original)
    assert analysis_module._group_fingerprint is original


@contextmanager
def every_permutation_checked() -> Iterator[List[Tuple[str, ...]]]:
    """Check every ordering of every group, at the moment its id is minted.

    The members handed to the real rule during a real analysis are the members
    a real graph produced -- so this permutes an analysed graph's own groups
    rather than a hand-made object that may or may not resemble one.  The
    answer for every ordering has to be the one answer.

    Yields the groups it saw, as their node ids, so that a caller can prove the
    spy was reached at all and reached something with more than one member in
    it.  A guard nothing was ever pointed at is not a guard.
    """

    original = getattr(analysis_module, "_group_fingerprint")
    seen: List[Tuple[str, ...]] = []

    def spy(members):
        nodes = tuple(member.node for member in members)
        assert len(nodes) <= 6, nodes  # factorial; the fixtures are small
        answers = {
            original(list(order)) for order in itertools.permutations(members)
        }
        assert len(answers) == 1, (nodes, sorted(answers))
        seen.append(nodes)
        return original(members)

    setattr(analysis_module, "_group_fingerprint", spy)
    try:
        yield seen
    finally:
        setattr(analysis_module, "_group_fingerprint", original)
    assert analysis_module._group_fingerprint is original


# ==========================================================================
# The fixtures are the shape the defect needs
# ==========================================================================


def test_the_fixtures_are_the_shape_the_defect_needs():
    """A role on more than one group, and a group with more than one member.

    Both halves, because either one alone is a graph the bug cannot reach: a
    role carried by exactly one group takes the bare role as its id and no
    fingerprint is involved, and a group of one member has no first member to
    choose.  Asserted here so that a fixture which quietly stopped producing
    the shape fails at this line rather than passing silently everywhere else.
    """

    for name, graph in (("three-bindings", three_bindings_graph()),
                        ("two-bindings", two_bindings_graph())):
        plan = analyse(graph)
        collapsed = [field for field in plan.fields if len(field.targets) > 1
                     and field.id.startswith("value")]
        siblings = [field for field in plan.fields if field.id.startswith("value-")]
        assert len(collapsed) == 1, (name, [field.id for field in plan.fields])
        assert len(collapsed[0].targets) > 1, (name, collapsed[0].targets)
        assert len(siblings) > 1, (name, [field.id for field in siblings])
        # And the ids really do carry a fingerprint, which is the only part of
        # an id any ordering rule could ever have reached.
        assert all(field.id.startswith("value-") for field in siblings), name

    # The members of the collapsed group must also disagree with each other:
    # a group whose members are wired alike has one fingerprint to choose from
    # and cannot show the defect either.
    plan = analyse(three_bindings_graph())
    collapsed = [
        field
        for field in plan.fields
        if len(field.targets) > 1 and field.id.startswith("value-")
    ][0]
    assert collapsed.targets == (("31", "value"), ("32", "value"), ("33", "value")), (
        collapsed.targets
    )
    with the_old_rule():
        assert ids(three_bindings_graph()) != ids(
            renumber(three_bindings_graph(), RENUMBERINGS["reversed"])
        )

    # And the renumberings really do reorder that group's members, which is
    # the only reason any of them could move an id.  ``lettered`` is the
    # exception on purpose: it keeps the order and changes how it is arrived
    # at, and it is here because the original measurement of this bug found
    # that shape producing the *original* id by luck.
    members = ("31", "32", "33")
    for form in ("reversed", "scrambled"):
        moved = [RENUMBERINGS[form](node) for node in members]
        assert moved != sorted(moved, key=int), (form, moved)
    lettered = [RENUMBERINGS["lettered"](node) for node in members]
    assert lettered == sorted(lettered), lettered


def test_the_single_binding_fixture_has_no_group_to_choose_from():
    """The control graph for the "nothing that was right moved" assertions."""

    plan = analyse(single_bindings_graph())
    valued = [field for field in plan.fields if field.id.startswith("value")]
    assert len(valued) == 3, [field.id for field in plan.fields]
    assert all(len(field.targets) == 1 for field in valued), [
        (field.id, field.targets) for field in valued
    ]
    assert all(field.id.startswith("value-") for field in valued), [
        field.id for field in valued
    ]


# ==========================================================================
# The old rule moves an id; this one does not
# ==========================================================================


def test_the_old_rule_moves_a_collapsed_id_and_this_one_does_not():
    """The differential, verbatim and in both directions.

    The left-hand column is what ``f06eb2d`` minted and what a re-export turned
    it into -- the movement the card was filed for -- and the right-hand one is
    what this module mints now.  Written out in full: a test that counted
    stable ids would pass a run in which two of them swapped.
    """

    graph = two_bindings_graph()
    moved = renumber(graph, RENUMBERINGS["reversed"])

    with the_old_rule():
        assert ids(graph) == [
            "prompt",
            "boolean",
            "seed",
            "value-08a3c496",
            "value-cf706f24",
        ]
        assert ids(moved) == [
            "prompt",
            "boolean",
            "seed",
            "value-24ae45d8",
            "value-cf706f24",
        ]

    assert ids(graph) == [
        "prompt",
        "boolean",
        "seed",
        "value-aacff1b0",
        "value-cf706f24",
    ]
    assert ids(moved) == [
        "prompt",
        "boolean",
        "seed",
        "value-aacff1b0",
        "value-cf706f24",
    ]


def test_the_old_rule_moved_only_the_collapsed_ids_and_this_one_moves_none():
    """Which ids the fix changed at all, over the whole corpus, verbatim.

    Two facts in one place, because separately either can mislead.  The ids
    that moved between the old rule and this one are exactly the collapsed
    ones -- so no id that was already stable was disturbed, which is the whole
    of the "no migration" argument.  And under this rule no id moves under a
    renumbering at all, which is the defect gone.
    """

    changed_by_the_fix: Dict[str, Dict[str, str]] = {}
    for name, graph in corpus():
        with the_old_rule():
            was = by_binding(graph)
        now = by_binding(graph)
        assert set(was) == set(now), name
        changed_by_the_fix[name] = {
            was[binding]: now[binding] for binding in was if was[binding] != now[binding]
        }

    assert changed_by_the_fix == {
        "three-bindings": {"value-08a3c496": "value-87c2b184"},
        "two-bindings": {"value-08a3c496": "value-aacff1b0"},
        "single-bindings": {},
        # A collapsed field, and still nothing: its two members agree, so the
        # first member's fingerprint and the whole group's are the same string.
        "one-voice": {},
    }


# ==========================================================================
# No permutation of a group's members changes its id
# ==========================================================================


def test_no_permutation_of_a_groups_members_changes_its_id():
    """Proved by permuting, not by reasoning about the sort order.

    Every group of every corpus graph, in every one of its orderings, at the
    moment the importer actually mints from it -- so these are the member lists
    a real analysis of a real exported graph produced, not hand-made planner
    objects arranged to agree.

    The spy also reports what it was pointed at, and this test refuses to pass
    unless it was pointed at a group with more than one member in it.  A
    permutation test over groups of one permutes nothing.
    """

    for name, graph in corpus():
        with every_permutation_checked() as seen:
            analyse(graph)
        assert seen, name
        assert max(len(nodes) for nodes in seen) > 1 or name == "single-bindings", (
            name,
            seen,
        )

    with every_permutation_checked() as seen:
        analyse(three_bindings_graph())
    assert sorted(seen, key=len)[-1] == ("31", "32", "33"), seen


def _minted(*graphs: Dict[str, Any]) -> List[Tuple[Tuple[str, ...], str]]:
    """``(the members' fingerprints, the answer)`` for every group minted from.

    Read off the real calls during a real analysis, so what is classified below
    is what the importer actually had in its hands.
    """

    seen: List[Tuple[Tuple[str, ...], str]] = []
    original = getattr(analysis_module, "_group_fingerprint")

    def spy(members):
        answer = original(members)
        seen.append((tuple(member.fingerprint for member in members), answer))
        return answer

    setattr(analysis_module, "_group_fingerprint", spy)
    try:
        for graph in graphs:
            analyse(graph)
    finally:
        setattr(analysis_module, "_group_fingerprint", original)
    assert analysis_module._group_fingerprint is original
    return seen


def test_a_group_that_speaks_with_one_voice_keeps_that_voice():
    """The rule's own reduction, which is why no existing id moved.

    A field whose members all carry one fingerprint takes that fingerprint
    itself, byte for byte, rather than a digest of it.  Asserted against the
    fingerprints the importer really computed, so it is a statement about the
    code rather than about the docstring.

    **Three kinds of group, and the test fails unless it saw all three.**  The
    reduction has two halves that look alike and are not: a group of one member
    (the common case, and 374 of the 381 calls a sweep of every corpus in this
    file and in `test_sync_label_uniqueness.py` recorded), and a group of
    several members that agree -- which that sweep recorded **zero** of.  So
    the second half of this rule's promise had no case pointed at it, and a
    rule nothing is pointed at is the way this phase keeps being wrong.
    :func:`one_voice_graph` is that case, and the counts below are asserted so
    that it cannot silently stop being it.
    """

    seen = _minted(three_bindings_graph(), single_bindings_graph(), one_voice_graph())

    alone = [(marks, answer) for marks, answer in seen if len(marks) == 1]
    together = [
        (marks, answer)
        for marks, answer in seen
        if len(marks) > 1 and len(set(marks)) == 1
    ]
    split = [(marks, answer) for marks, answer in seen if len(set(marks)) > 1]

    assert alone, seen
    assert together, "no group of several members that agree was ever minted from"
    assert split, seen
    assert len(alone) + len(together) + len(split) == len(seen)

    # One voice, whether it is one member's or several members' -- the answer
    # is that voice itself and not a digest of it.
    for marks, answer in alone + together:
        assert answer == marks[0], (marks, answer)
        assert len(answer) == 8, answer
    # And where they disagree the answer is nobody's: a digest of them all, so
    # no member's fingerprint can be read back out of the id.
    for marks, answer in split:
        assert answer not in marks, (marks, answer)


def test_the_one_voice_shape_is_a_group_of_several_members_that_agree():
    """The fixture is that case, and its id is the bare fingerprint, verbatim.

    Two nodes holding one value, each through its own switch into its own
    sampler's ``cfg``, and the two samplers of one class -- so within the two
    hops a fingerprint looks, the two members are the same shape.  A third
    value at a ``denoise`` keeps the role from being unique, so the ids carry a
    fingerprint at all.

    The id is ``value-08a3c496`` and it is exactly the fingerprint both members
    carry.  That is the reduction doing its job where it matters: this is a
    *collapsed* field, the kind whose id T-0113 moved, and it does not move,
    because its members never disagreed about anything.
    """

    seen = _minted(one_voice_graph())
    together = [
        (marks, answer)
        for marks, answer in seen
        if len(marks) > 1 and len(set(marks)) == 1
    ]
    assert together == [(("08a3c496", "08a3c496"), "08a3c496")], seen

    expected = ["prompt", "boolean", "seed", "value-08a3c496", "value-cf706f24"]
    assert ids(one_voice_graph()) == expected
    assert by_binding(one_voice_graph())[
        frozenset({("31", "value"), ("32", "value")})
    ] == "value-08a3c496"
    with the_old_rule():
        assert ids(one_voice_graph()) == expected, "the old rule minted this one too"
    for form, rename in RENUMBERINGS.items():
        assert ids(renumber(one_voice_graph(), rename)) == expected, form


# ==========================================================================
# Renumbering a whole graph, end to end
# ==========================================================================


def test_renumbering_a_graph_leaves_every_id_where_it_was():
    """Every corpus shape, every renumbering, compared by binding.

    ``bind`` says which node input a control writes into, and a re-export moves
    those node ids too -- so the fields are paired through the renumbering
    itself and what is compared is only the id.
    """

    for name, graph in corpus():
        before = by_binding(graph)
        for form, rename in RENUMBERINGS.items():
            after = by_binding(renumber(graph, rename))
            expected = {
                frozenset(
                    (rename(node), input_name) for node, input_name in binding
                ): field_id
                for binding, field_id in before.items()
            }
            assert after == expected, (name, form)


def test_the_ids_of_the_three_binding_shape_verbatim_under_every_numbering():
    """The same list of ids, written out, four times.

    The test above compares one run against another, which is the right shape
    for a corpus and the wrong shape for a reader: two runs that agree can
    still both be wrong.  This one states what the ids *are*.
    """

    expected = [
        "prompt",
        "boolean",
        "seed",
        "value-0e45dcbe",
        "value-87c2b184",
    ]
    assert ids(three_bindings_graph()) == expected
    for form, rename in RENUMBERINGS.items():
        assert ids(renumber(three_bindings_graph(), rename)) == expected, form


def test_a_stable_id_is_byte_identical_after_the_fix():
    """The single-binding case, verbatim, and unchanged by any numbering.

    These are the ids the previous rule already got right -- many
    workflows in a real catalogue are this shape and none of them may move -- so
    they are quoted here as literals rather than compared to another run.

    ``value-08a3c496`` and ``value-24ae45d8`` are worth reading twice: they are
    the two ids the card's own measurement watched a *collapsed* field flip
    between when the graph was renumbered.  They are the fingerprints of "a
    value reaching the sampler's ``cfg``" and "a value reaching its ``steps``",
    and the old rule handed one field whichever of the two sorted first.  Here
    each belongs to a field of its own, where it always did, and stays there.
    """

    expected = [
        "prompt",
        "boolean",
        "seed",
        "value-08a3c496",
        "value-24ae45d8",
        "value-cf706f24",
    ]
    assert ids(single_bindings_graph()) == expected
    with the_old_rule():
        assert ids(single_bindings_graph()) == expected
    for form, rename in RENUMBERINGS.items():
        assert ids(renumber(single_bindings_graph(), rename)) == expected, form


def test_no_id_moves_across_a_corpus_this_card_did_not_design():
    """The same property, on shapes chosen by somebody else for something else.

    `test_sync_label_uniqueness.py` builds around seventy graphs for T-0111 --
    the two real shapes, a collapsed control whose members disagree, a chain
    the author named half of, and seeded random switch and adapter graphs.
    Fixtures written by the person proving a property are the easiest kind to
    get wrong, so the property is measured on that corpus as well as on this
    file's own.

    And the corpus is required to have been able to break: with the old rule
    put back, the shapes below move an id, written out.  Without that half this
    would be an absence test over graphs that were never at risk.
    """

    from test_sync_label_uniqueness import corpus as naming_corpus

    def moving() -> Dict[str, Dict[str, str]]:
        found: Dict[str, Dict[str, str]] = {}
        for name, graph in naming_corpus():
            before = {
                frozenset(field.targets): field.id for field in analyse(graph).fields
            }
            for form, rename in RENUMBERINGS.items():
                after = {
                    frozenset(field.targets): field.id
                    for field in analyse(renumber(graph, rename)).fields
                }
                for binding, field_id in before.items():
                    moved_to = after.get(
                        frozenset(
                            (rename(node), input_name) for node, input_name in binding
                        )
                    )
                    if moved_to != field_id:
                        found.setdefault(
                            "{}/{}".format(name, form), {}
                        )[field_id] = moved_to
        return found

    with the_old_rule():
        was = moving()

    # The seeded switch shapes join the list since T-0102.  Each of them holds
    # the number ``n`` twice -- written ``n.0`` on one ``ExamplePrimitiveValue``
    # and ``n`` on another, the same undeclared input on the same class -- and
    # one number written two ways is one control now, as it always was when it
    # was written alike.  So every switch shape of two or more values carries
    # collapsed fields whose members sit on different switches, which is the
    # shape the old rule moves.  The movement depends only on the value count:
    # a shape's seed chooses its node titles, and no id is minted from a title.
    switch_moves = {
        2: {"reversed": {"value-c1a4a411": "value-24ae45d8"}},
        3: {
            "reversed": {
                "value-4fa53895": "value-cf706f24",
                "value-c1a4a411": "value-24ae45d8",
            },
        },
        4: {
            "reversed": {
                "value-300e245d": "value-0e45dcbe",
                "value-4fa53895": "value-cf706f24",
                "value-c1a4a411": "value-24ae45d8",
            },
            "scrambled": {"value-300e245d": "value-0e45dcbe"},
        },
        5: {
            "reversed": {
                "value-300e245d": "value-0e45dcbe",
                "value-4fa53895": "value-cf706f24",
                "value-c1a4a411": "value-24ae45d8",
                "value-c363adb3": "value-ac3e68c8",
            },
            "scrambled": {
                "value-300e245d": "value-0e45dcbe",
                "value-c363adb3": "value-ac3e68c8",
            },
        },
    }
    switches = {
        "switch-{}-{}/{}".format(count, seed, form): moved
        for count, forms in switch_moves.items()
        for seed in range(6)
        for form, moved in forms.items()
    }

    assert was == {
        **switches,
        "shared-binding/reversed": {"value-08a3c496": "value-24ae45d8"},
        "shared-binding/scrambled": {"value-08a3c496": "value-24ae45d8"},
        "split-binding/reversed": {"value-24ae45d8": "value-4fa53895"},
        "split-binding/scrambled": {"value-24ae45d8": "value-4fa53895"},
        # Not ``one-named-one-silent/scrambled``: this permutation happens to
        # leave that shape's two collapsed nodes in the order they were in, so
        # the old rule read the same first member and the id stayed. Written
        # down rather than smoothed over -- an ordering bug is invisible under
        # a renumbering that does not reorder anything, which is exactly why
        # this file renumbers three different ways.
        "one-named-one-silent/reversed": {
            "strength_clip-a7810fff": "strength_clip-0acc5257",
            "strength_model-bffefff9": "strength_model-2d2d7768",
        },
    }

    assert moving() == {}


def test_the_order_the_nodes_are_written_in_does_not_change_an_id():
    """A re-export that shuffles the JSON is the same workflow."""

    for name, graph in corpus():
        shuffled = {node: graph[node] for node in reversed(list(graph))}
        assert list(shuffled) != list(graph), name
        assert ids(shuffled) == ids(graph), name


def test_two_runs_over_one_graph_agree():
    """Nothing here depends on a hash seed or on a set's iteration order."""

    for name, graph in corpus():
        assert ids(graph) == ids(copy.deepcopy(graph)), name


# ==========================================================================
# The repository's own redistributable graphs
# ==========================================================================


#: Every id `workflows/examples/` produces, measured on ``ff46930`` -- before
#: this card changed anything -- and required to be byte-identical after it.
#: The card's own measurement says nothing in a representative test
#: catalogue moves; this is the same claim about the graphs that ship, made
#: where anyone can re-run it.  Not one of them carries a fingerprint
#: suffix, which is why: every role in them is unique.
EXAMPLE_IDS = {
    "example_img2img_api.json": [
        "prompt",
        "image",
        "negative_prompt",
        "cfg",
        "denoise",
        "sampler_name",
        "scheduler",
        "seed",
        "steps",
    ],
    "example_txt2img_api.json": [
        "prompt",
        "negative_prompt",
        "batch_size",
        "cfg",
        "denoise",
        "height",
        "sampler_name",
        "scheduler",
        "seed",
        "steps",
        "width",
    ],
    # Empty until T-0081: its placeholder carried no file suffix, so it was
    # NEEDS_REVIEW and planned no fields.  The placeholder now carries one,
    # like the other two examples', and these are the ids it plans.
    "example_video_api.json": [
        "prompt",
        "video",
        "fps",
        "frame_cap",
        "loop",
        "motion_strength",
        "seed",
        "steps",
    ],
}


def _examples() -> Path:
    return Path(__file__).resolve().parents[2] / "workflows" / "examples"


def test_every_public_example_id_is_the_one_it_was():
    """The before/after list, as literals, for the graphs this repository ships."""

    found = sorted(_examples().glob("*_api.json"))
    assert [path.name for path in found] == sorted(EXAMPLE_IDS), found
    for path in found:
        graph = json.loads(path.read_text(encoding="utf-8"))
        assert [
            field.id for field in analyse(graph).fields
        ] == EXAMPLE_IDS[path.name], path.name


def test_no_public_example_id_moves_under_a_renumbering():
    """And the same graphs re-exported, which is how the harm would arrive."""

    for path in sorted(_examples().glob("*_api.json")):
        graph = json.loads(path.read_text(encoding="utf-8"))
        before = {frozenset(field.targets): field.id for field in analyse(graph).fields}
        for form, rename in RENUMBERINGS.items():
            moved = analyse(renumber(graph, rename))
            after = {frozenset(field.targets): field.id for field in moved.fields}
            assert after == {
                frozenset(
                    (rename(node), input_name) for node, input_name in binding
                ): field_id
                for binding, field_id in before.items()
            }, (path.name, form)


# ==========================================================================
# Provenance
# ==========================================================================


def test_the_suite_measured_this_checkout():
    """Which package tree these assertions were made against.

    Stated as a relationship between two paths rather than as a claim about
    the mechanism: the module under test has to be the one that sits beside
    this test file in the same checkout.  A run that imported an installed
    copy, or another worktree's, fails here.
    """

    here = Path(__file__).resolve()
    checkout = here.parents[2]
    module = Path(analysis_module.__file__).resolve()
    assert module == checkout / "gateway" / "localcanvas_gateway" / "workflows" / (
        "sync"
    ) / "analysis.py", (module, checkout)
