"""A sub-input a node shape added is judged by the declaration under the chosen key (T-0240).

A node-shape input adds inputs to its node when a key is chosen, and an
API-format graph carries them flattened as ``parent.child``.  The runtime
declares each of them -- but inside the block of the shape that adds it, not
at the top level of the class.  Before this card that block was never read,
so such a sub-input was judged from its name and value alone: a nested node
shape held its workflow for review, and a nested number reached the user with
no declared type and no bounds.

The rule: for ``parent.child`` (at any depth), where every parent on the path
is a node-shape declaration and the graph holds one of its declared keys
there, the declaration nested under **that** key is read, and used exactly as
a top-level declaration is.  Anything else leaves the input exactly as it was.

The file is organised around the ways of getting that wrong:

* **the chosen key, never another** -- the fixture's first key declares the
  same sub-input differently, and a spy proves the unchosen block is never
  even opened;
* **used exactly as a top-level declaration** -- a nested node shape locks, a
  nested number takes its declared kind and bounds, a nested choice list is a
  select, and the class's outputs reach the nested declaration;
* **a path that does not resolve** -- an undeclared key, a parent that is not
  a node shape, an ambiguous key, a name declared at the top level -- is left
  exactly as it was, and each of those is compared with the plan the same
  graph gets with no nested declaration at all;
* **depth** -- ``a.b.c`` resolves through two chosen keys.

Every class name, input name, key and value below is invented.
"""

from __future__ import annotations

import copy
from typing import Any, Dict, List, Optional, Tuple

from localcanvas_gateway.workflows.sync import analyse
from localcanvas_gateway.workflows.sync.contract import RuntimeContract, read_object_info

#: Written out rather than imported from the module under test.
SHAPE_SLUG = "node_shape"
COMPUTATION_SLUG = "computation"

SHAPED = "ExampleShapedNode"
PARENT = "variant"

#: A parent `semantics.py` settles by itself -- ``method`` is a word it exposes
#: as a setting -- for the tests that need a plan to import while the parent
#: holds a value that chose no shape, or has no declaration at all.
SETTLED_PARENT = "method"

#: The key the graphs below choose, and the one declared before it.
CHOSEN = "tuned"
UNCHOSEN = "plain"

NUMBER = PARENT + ".strength"
NESTED_SHAPE = PARENT + ".flavour"
DEEP_NUMBER = NESTED_SHAPE + ".depth"
NESTED_CHOICE = PARENT + ".palette"

DIGEST = "sha256:chosen-shape"


def shape(*options: Tuple[str, Dict[str, Any]]) -> List[Any]:
    """A node-shape declaration in ComfyUI's own shape: ``(key, inputs block)``."""

    return [
        "COMFY_DYNAMICCOMBO_V3",
        {"options": [{"key": key, "inputs": block} for key, block in options]},
    ]


def variant_spec() -> List[Any]:
    """The parent declaration every test below starts from.

    The **first** key, ``plain``, declares ``strength`` as a whole number over
    0..3.  The second, ``tuned``, declares it a float over 0..5 in steps of
    0.01, and adds a nested node shape and a choice list.  So a
    judgement that read the first block, or any block but the chosen one,
    comes out visibly different from one that read the right block.
    """

    return shape(
        (UNCHOSEN, {"required": {"strength": ["INT", {"min": 0, "max": 3}]}}),
        (
            CHOSEN,
            {
                "required": {
                    "strength": ["FLOAT", {"min": 0.0, "max": 5.0, "step": 0.01}],
                    "flavour": shape(
                        ("mild", {"required": {}}),
                        (
                            "sharp",
                            {
                                "required": {
                                    "depth": [
                                        "FLOAT",
                                        {"min": 0.5, "max": 2.0, "step": 0.5},
                                    ]
                                }
                            },
                        ),
                    ),
                    "palette": ["COMBO", {"options": ["warm", "cool"]}],
                }
            },
        ),
    )


def contract_with(
    spec: Any,
    *,
    outputs: Any = ("MODEL", "CLIP"),
    extra: Optional[Dict[str, Any]] = None,
    parent: str = PARENT,
) -> RuntimeContract:
    """A contract read by the production parser from a document of that shape."""

    required: Dict[str, Any] = {parent: spec}
    required.update(extra or {})
    return read_object_info(
        {SHAPED: {"input": {"required": required}, "output": list(outputs)}},
        identity_digest=DIGEST,
    )


def graph_with(inputs: Dict[str, Any]) -> Dict[str, Any]:
    """One readable generation whose node ``1`` is the shaped node."""

    return {
        "1": {"class_type": SHAPED, "inputs": dict(inputs)},
        "2": {
            "class_type": "ExampleTextEncode",
            "inputs": {"text": "a quiet street at dawn", "clip": ["1", 1]},
        },
        "3": {
            "class_type": "ExampleSampler",
            "inputs": {"seed": 7, "model": ["1", 0], "positive": ["2", 0]},
        },
    }


def control_for(plan, name: str):
    found = [item for item in plan.controls if item.target == ("1", name)]
    assert len(found) == 1, (name, plan.controls)
    return found[0]


def field_for(plan, name: str):
    found = [item for item in plan.fields if ("1", name) in item.targets]
    assert len(found) == 1, (name, [item.targets for item in plan.fields], plan.problems)
    return found[0]


def number_shape(plan, name: str) -> Tuple[str, str, Any, Any, Any]:
    item = field_for(plan, name)
    return (item.id, item.type, item.minimum, item.maximum, item.step)


def shape_sentence(name: str, value: str) -> str:
    return (
        "input {!r} holds {!r}, which the ComfyUI that runs this workflow "
        "declares as one of the shapes node class {!r} can take: choosing "
        "another would add or remove inputs on that node rather than change "
        "this one. The workflow's author already chose it, LocalCanvas keeps "
        "it exactly as saved, and offers no control for it.".format(name, value, SHAPED)
    )


# ==========================================================================
# The chosen key, and never another
# ==========================================================================


def test_a_nested_number_takes_its_kind_and_bounds_from_the_chosen_key() -> None:
    """``2`` reads as a whole number; the chosen shape declares a float over 0..5."""

    plan = analyse(
        graph_with({PARENT: CHOSEN, NUMBER: 2}), contract=contract_with(variant_spec())
    )

    assert not plan.problems
    assert number_shape(plan, NUMBER) == ("variant_strength", "float", 0.0, 5.0, 0.01)


def test_the_same_number_without_the_nested_declaration_is_what_it_was() -> None:
    """The pre-change path, pinned: no contract, and a contract with no block.

    Both are what every sub-input got before this card, so the float above is
    a difference this rule made and not one the fixture makes on its own.
    """

    name = SETTLED_PARENT + ".strength"
    graph = graph_with({SETTLED_PARENT: CHOSEN, name: 2})
    expected = ("method_strength", "integer", None, None, None)

    assert number_shape(analyse(graph, contract=None), name) == expected
    empty = shape((UNCHOSEN, {"required": {}}), (CHOSEN, {"required": {}}))
    emptied = contract_with(empty, parent=SETTLED_PARENT)
    assert number_shape(analyse(graph, contract=emptied), name) == expected
    declared = contract_with(variant_spec(), parent=SETTLED_PARENT)
    assert number_shape(analyse(graph, contract=declared), name)[1] == "float"


def test_the_unchosen_key_declares_it_differently_and_that_is_seen_when_chosen() -> None:
    """The absence test's first half: the other block really would change the answer.

    The graph that chooses ``plain`` gets ``plain``'s whole number over 0..3.
    So when the graph chooses ``tuned`` and the answer is ``tuned``'s float,
    the unchosen block was available to be read and was not.
    """

    plan = analyse(
        graph_with({PARENT: UNCHOSEN, NUMBER: 2}), contract=contract_with(variant_spec())
    )

    assert number_shape(plan, NUMBER) == ("variant_strength", "integer", 0, 3, None)


class WatchedOption(dict):
    """One option of a node-shape declaration that records which keys are read."""

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        self.read: List[str] = []

    def get(self, key: Any, default: Any = None) -> Any:
        self.read.append(key)
        return super().get(key, default)

    def __getitem__(self, key: Any) -> Any:
        self.read.append(key)
        return super().__getitem__(key)


def test_the_block_under_a_key_the_graph_did_not_choose_is_never_opened() -> None:
    """Not read, not counted: its ``inputs`` key is never asked for.

    The chosen option's block **is** asked for in the same run -- so the spy is
    one that sees a read when there is one.
    """

    spec = variant_spec()
    unchosen, chosen = (WatchedOption(option) for option in spec[1]["options"])
    spec[1]["options"] = [unchosen, chosen]

    plan = analyse(graph_with({PARENT: CHOSEN, NUMBER: 2}), contract=contract_with(spec))

    assert number_shape(plan, NUMBER)[1] == "float"
    assert "inputs" in chosen.read
    assert "inputs" not in unchosen.read
    assert set(unchosen.read) == {"key"}


# ==========================================================================
# Used exactly as a top-level declaration is
# ==========================================================================


def test_a_nested_node_shape_holding_a_declared_key_locks() -> None:
    """The node-shape step, asked of the nested declaration -- and first.

    Without the nested declaration the same input is held for review, which
    is what this card found holding a real workflow.
    """

    graph = graph_with({PARENT: CHOSEN, NESTED_SHAPE: "sharp"})

    plan = analyse(graph, contract=contract_with(variant_spec()))

    assert not plan.problems
    nested = control_for(plan, NESTED_SHAPE)
    assert (nested.section, nested.kind) == ("locked", SHAPE_SLUG)
    assert nested.reason == shape_sentence(NESTED_SHAPE, "sharp")
    assert control_for(plan, PARENT).kind == SHAPE_SLUG

    empty = shape((UNCHOSEN, {"required": {}}), (CHOSEN, {"required": {}}))
    before = analyse(graph, contract=contract_with(empty))
    assert control_for(before, PARENT).kind == SHAPE_SLUG
    assert control_for(before, NESTED_SHAPE).section == "needs_review"


def test_a_nested_node_shape_locks_even_where_classify_would_expose_it() -> None:
    """Node-shape step first, before ``classify``, for a nested input as for any.

    ``method`` is a word `semantics.py` exposes as a setting; declared as a
    shape inside the chosen block, it is which node this is.
    """

    spec = shape(
        (
            CHOSEN,
            {"required": {"method": shape(("orbit", {"required": {}}), ("drift", {}))}},
        ),
    )
    name = PARENT + ".method"

    empty = shape((CHOSEN, {"required": {}}))
    exposed = analyse(
        graph_with({PARENT: CHOSEN, name: "drift"}), contract=contract_with(empty)
    )
    assert field_for(exposed, name).type == "string"

    plan = analyse(graph_with({PARENT: CHOSEN, name: "drift"}), contract=contract_with(spec))

    assert (control_for(plan, name).section, control_for(plan, name).kind) == (
        "locked",
        SHAPE_SLUG,
    )
    assert all(("1", name) not in item.targets for item in plan.fields)


def test_a_nested_node_shape_holding_no_declared_key_keeps_the_shape_sentence() -> None:
    plan = analyse(
        graph_with({PARENT: CHOSEN, NESTED_SHAPE: "bitter"}),
        contract=contract_with(variant_spec()),
    )

    assert plan.problems == (
        "Node 1 input 'variant.flavour' is one this ComfyUI declares as a choice "
        "between shapes of node class 'ExampleShapedNode' rather than as a "
        "value: the shapes it offers are 'mild', 'sharp'. The value saved there "
        "is not one of the shapes this ComfyUI declares, so what this node would "
        "be is not something the graph and this runtime agree on. Nothing was "
        "substituted -- look at it and decide.",
    )


def test_a_nested_choice_list_is_a_select_over_exactly_its_choices() -> None:
    plan = analyse(
        graph_with({PARENT: CHOSEN, NESTED_CHOICE: "cool"}),
        contract=contract_with(variant_spec()),
    )

    item = field_for(plan, NESTED_CHOICE)
    assert (item.id, item.type, item.options) == ("variant_palette", "select", ("warm", "cool"))


def test_the_class_outputs_reach_a_resolved_nested_declaration() -> None:
    """Text in the nested number, on a node whose every output is a number.

    The sub-input resolves -- the chosen block declares it -- so every question
    after that goes to the nested declaration, the class's outputs included,
    and T-0218's computation lock answers as it would at the top level.  Held
    with the same contract on a node that also produces a model, so the lock
    comes from the outputs and not from the nesting.
    """

    graph = graph_with({PARENT: CHOSEN, NUMBER: "a * b"})

    numbers = analyse(
        graph, contract=contract_with(variant_spec(), outputs=("FLOAT", "INT"))
    )
    assert (control_for(numbers, NUMBER).section, control_for(numbers, NUMBER).kind) == (
        "locked",
        COMPUTATION_SLUG,
    )

    mixed = analyse(graph, contract=contract_with(variant_spec()))
    assert control_for(mixed, NUMBER).section == "needs_review"


# ==========================================================================
# A path that does not resolve leaves the input as it was
# ==========================================================================


def flavour_in_every_block(*keys: Any) -> List[Any]:
    """A parent shape each of whose keys declares ``flavour`` a node shape.

    For the tests whose parent holds no declared key.  Since T-0223 such a
    parent is itself held for review, so the plan carries no fields and a
    sub-input's number kind is not visible in it; a nested node shape is,
    because a block that was read would **lock** it.  Every block declares
    it, so reading any block at all -- the first, or one matched loosely --
    shows.
    """

    return shape(
        *(
            (
                key,
                {"required": {"flavour": shape(("sharp", {"required": {}}), ("mild", {}))}},
            )
            for key in keys
        )
    )


def test_a_held_value_that_is_not_a_declared_key_leaves_the_input_as_today() -> None:
    """``Tuned`` is not ``tuned``: no shape was chosen, so no block is read."""

    name = SETTLED_PARENT + ".flavour"
    spec = flavour_in_every_block(UNCHOSEN, CHOSEN)
    graph = graph_with({SETTLED_PARENT: "Tuned", name: "sharp"})

    plan = analyse(graph, contract=contract_with(spec, parent=SETTLED_PARENT))

    assert control_for(plan, name) == control_for(analyse(graph, contract=None), name)
    assert control_for(plan, name).section != "locked"
    assert control_for(plan, SETTLED_PARENT).section == "needs_review"
    chosen = graph_with({SETTLED_PARENT: CHOSEN, name: "sharp"})
    declared = analyse(chosen, contract=contract_with(spec, parent=SETTLED_PARENT))
    assert (control_for(declared, name).section, control_for(declared, name).kind) == (
        "locked",
        SHAPE_SLUG,
    )


def test_a_parent_that_is_a_plain_choice_list_is_not_a_node_shape() -> None:
    """The same key, declared as an ordinary value, adds nothing to the node."""

    graph = graph_with({PARENT: CHOSEN, NUMBER: 2})

    plan = analyse(
        graph, contract=contract_with(["COMBO", {"options": [UNCHOSEN, CHOSEN]}])
    )

    assert number_shape(plan, NUMBER) == ("variant_strength", "integer", None, None, None)


def test_a_parent_of_another_type_with_the_same_option_shape_is_not_a_node_shape() -> None:
    """The type name is matched exactly, so the option shape alone decides nothing.

    The very same options under ``COMFY_DYNAMICCOMBO_V3`` do resolve, in the
    same test, so the absence is one the fixture could have shown.
    """

    other = variant_spec()
    other[0] = "EXAMPLE_OTHER_COMBO_V3"

    settled = SETTLED_PARENT + ".strength"
    as_other = analyse(
        graph_with({SETTLED_PARENT: CHOSEN, settled: 2}),
        contract=contract_with(other, parent=SETTLED_PARENT),
    )
    assert number_shape(as_other, settled) == ("method_strength", "integer", None, None, None)
    as_shape = analyse(
        graph_with({SETTLED_PARENT: CHOSEN, settled: 2}),
        contract=contract_with(variant_spec(), parent=SETTLED_PARENT),
    )
    assert number_shape(as_shape, settled) == ("method_strength", "float", 0.0, 5.0, 0.01)


def test_a_held_value_equal_to_a_key_only_under_python_equality_chooses_nothing() -> None:
    """``True == 1`` in Python; a flag is not the key ``1`` (``_value_key``'s rule)."""

    spec = flavour_in_every_block(1)
    name = SETTLED_PARENT + ".flavour"
    flag_graph = graph_with({SETTLED_PARENT: True, name: "sharp"})

    flag = analyse(flag_graph, contract=contract_with(spec, parent=SETTLED_PARENT))
    number = analyse(
        graph_with({SETTLED_PARENT: 1, name: "sharp"}),
        contract=contract_with(spec, parent=SETTLED_PARENT),
    )

    assert control_for(flag, name) == control_for(analyse(flag_graph, contract=None), name)
    assert control_for(flag, name).section != "locked"
    assert (control_for(number, name).section, control_for(number, name).kind) == (
        "locked",
        SHAPE_SLUG,
    )


def test_a_key_declared_twice_chooses_no_single_block() -> None:
    """Two options under the graph's key: which block is in force is not known."""

    spec = variant_spec()
    spec[1]["options"].append(
        {"key": CHOSEN, "inputs": {"required": {"strength": ["INT", {"max": 9}]}}}
    )
    graph = graph_with({PARENT: CHOSEN, NUMBER: 2})

    plan = analyse(graph, contract=contract_with(spec))

    assert number_shape(plan, NUMBER) == ("variant_strength", "integer", None, None, None)
    assert control_for(plan, PARENT).kind == SHAPE_SLUG


def test_a_name_the_class_declares_at_the_top_level_keeps_that_declaration() -> None:
    graph = graph_with({PARENT: CHOSEN, NUMBER: 2})

    plan = analyse(
        graph,
        contract=contract_with(
            variant_spec(), extra={NUMBER: ["INT", {"min": 1, "max": 7}]}
        ),
    )

    assert number_shape(plan, NUMBER) == ("variant_strength", "integer", 1, 7, None)


def test_a_block_that_is_not_a_mapping_declares_nothing() -> None:
    spec = shape((CHOSEN, {}))
    spec[1]["options"][0]["inputs"] = [["strength", ["FLOAT", {"max": 5.0}]]]

    plan = analyse(graph_with({PARENT: CHOSEN, NUMBER: 2}), contract=contract_with(spec))

    assert number_shape(plan, NUMBER) == ("variant_strength", "integer", None, None, None)


def test_required_wins_over_optional_and_optional_is_read_where_required_is_not_a_block() -> None:
    both = shape(
        (
            CHOSEN,
            {
                "required": {"strength": ["FLOAT", {"max": 5.0}]},
                "optional": {"strength": ["INT", {"max": 9}]},
            },
        )
    )
    only_optional = shape(
        (CHOSEN, {"required": [], "optional": {"strength": ["FLOAT", {"max": 4.0}]}})
    )
    graph = graph_with({PARENT: CHOSEN, NUMBER: 2})

    assert number_shape(analyse(graph, contract=contract_with(both)), NUMBER) == (
        "variant_strength",
        "float",
        None,
        5.0,
        None,
    )
    assert number_shape(analyse(graph, contract=contract_with(only_optional)), NUMBER) == (
        "variant_strength",
        "float",
        None,
        4.0,
        None,
    )


def test_the_contract_answers_nothing_under_a_shape_where_nothing_is_read() -> None:
    """:meth:`under_shape` itself: ``None`` rather than an empty contract."""

    found = contract_with(variant_spec())

    assert found.under_shape(SHAPED, PARENT, 1, "strength", NUMBER).declares(SHAPED, NUMBER)
    assert found.under_shape(SHAPED, PARENT, 1, "missing", PARENT + ".missing") is None
    assert found.under_shape(SHAPED, "not-a-shape", 0, "strength", NUMBER) is None
    # A position that is not one of the keys' positions names no shape: past
    # the end, before the start, and a flag that Python would index with.
    assert found.under_shape(SHAPED, PARENT, 2, "strength", NUMBER) is None
    assert found.under_shape(SHAPED, PARENT, -1, "strength", NUMBER) is None
    assert found.under_shape(SHAPED, PARENT, True, "strength", NUMBER) is None
    unreadable = shape((CHOSEN, {"required": {"strength": ["IMAGE", {}]}}))
    assert contract_with(unreadable).under_shape(SHAPED, PARENT, 0, "strength", NUMBER) is None


# ==========================================================================
# Depth
# ==========================================================================


def test_a_path_two_shapes_deep_resolves_through_both_chosen_keys() -> None:
    """``variant.flavour.depth``: ``tuned`` inside ``variant``, ``sharp`` inside that."""

    graph = graph_with({PARENT: CHOSEN, NESTED_SHAPE: "sharp", DEEP_NUMBER: 1})

    plan = analyse(graph, contract=contract_with(variant_spec()))

    assert not plan.problems
    assert number_shape(plan, DEEP_NUMBER) == (
        "variant_flavour_depth",
        "float",
        0.5,
        2.0,
        0.5,
    )


def test_a_deep_path_whose_middle_shape_chose_no_block_declaring_it_is_as_today() -> None:
    """``mild`` adds nothing, so ``depth`` under it is not declared."""

    graph = graph_with({PARENT: CHOSEN, NESTED_SHAPE: "mild", DEEP_NUMBER: 1})

    plan = analyse(graph, contract=contract_with(variant_spec()))

    assert control_for(plan, NESTED_SHAPE).kind == SHAPE_SLUG
    assert number_shape(plan, DEEP_NUMBER) == (
        "variant_flavour_depth",
        "integer",
        None,
        None,
        None,
    )


def test_the_fixtures_are_not_mutated_by_being_read() -> None:
    """A shared capture that one read changed would make the next test pass by itself."""

    spec = variant_spec()
    before = copy.deepcopy(spec)

    analyse(
        graph_with({PARENT: CHOSEN, NESTED_SHAPE: "sharp", DEEP_NUMBER: 1, NUMBER: 2}),
        contract=contract_with(spec),
    )

    assert spec == before
