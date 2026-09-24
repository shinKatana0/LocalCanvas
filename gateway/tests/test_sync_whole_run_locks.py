"""The runtime-backed locks, reached by a whole run rather than by ``analyse`` alone (T-0230).

Four judgements lock a string only because of what the ComfyUI that runs the
workflow declares: every output of the node is a number (``computation``,
T-0218), every output is a model (``model_patch``, T-0241), the text equals the
declared default (``declared_default``, T-0244), and a sub-input a node shape
added is a node shape of its own under the key the graph chose (T-0240).  Each
has its own file at the level of ``analyse`` and ``read_object_info``.  What no
test showed is the seam between them: the stand-in ComfyUI serving the
declaration, the bridge reading it while it establishes which ComfyUI this is,
the ContractCache handing it back for that identity, and ``run_sync`` asking it.

Two of the four read a class's ``output`` list, which the stand-in could not
declare until ``FakeComfy.node_outputs`` existed; that is what this card adds,
and the first test proves it changes nothing for a fake that does not use it.

Each lock is shown from both sides in one test:

* **declared** -- the canvas imports, the input is locked with its slug and its
  sentence (written out here, never formatted from the module), and the
  definition the gateway's own loader reads carries no field for it;
* **unavailable** -- the very same graph, put in the tree as an API export,
  establishes no identity, so the run has no contract at all: it asks the
  stand-in nothing, reports ``declared: None``, and the workflow is held on
  the input's own sentence from ``classify``.

Every node class, input name and value below is invented.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple
from urllib.request import urlopen

import pytest

from localcanvas_gateway.comfy.fake import OBJECT_INFO, FakeComfy
from localcanvas_gateway.workflows import load_registry
from localcanvas_gateway.workflows.sync import run_sync
from localcanvas_gateway.workflows.sync.report import report_document
from localcanvas_gateway.workflows.sync.semantics import Exposure, classify

from bridge_fixtures import Browser, make_bridge, ui_graph
from sync_fixtures import SyncWorkspace, write_json

# --------------------------------------------------------------------------
# The stand-in's document, with and without declared outputs
# --------------------------------------------------------------------------


def served(comfy: FakeComfy) -> bytes:
    """``/object_info`` as the stand-in puts it on the wire."""

    with urlopen(comfy.base_url + "/object_info", timeout=5) as response:
        return response.read()


def test_a_fake_that_declares_no_outputs_serves_the_document_it_always_served() -> None:
    """Byte for byte, for the three ways an existing test configures the fake.

    The expected document is built here from the fake's own constant and the
    shape every installed class had before ``node_outputs`` -- ``"output": []``
    -- so a fake that started declaring something for a class nobody gave an
    entry would differ from it.
    """

    def before(installed: Tuple[str, ...], inputs: Dict[str, Any]) -> bytes:
        document = dict(OBJECT_INFO)
        for name in installed:
            document[name] = {
                "input": {"required": dict(inputs.get(name, {}))},
                "output": [],
                "name": name,
                "category": "fake",
            }
        return json.dumps(document).encode("utf-8")

    configurations: List[Tuple[Tuple[str, ...], Dict[str, Any]]] = [
        ((), {}),
        (("ExampleExtraNode",), {}),
        (
            ("ExampleSampler", "ExampleOther"),
            {"ExampleSampler": {"mixing": [["steady", "drifting"], {}]}},
        ),
    ]
    for installed, inputs in configurations:
        with FakeComfy() as comfy:
            comfy.installed_nodes = installed
            comfy.node_inputs = inputs
            assert served(comfy) == before(installed, inputs), installed


def test_declared_outputs_are_served_for_exactly_the_classes_given_them() -> None:
    """The one class with an entry carries it, in socket order; the other keeps ``[]``."""

    with FakeComfy() as comfy:
        comfy.installed_nodes = ("ExampleCounter", "ExampleQuiet")
        comfy.node_outputs = {"ExampleCounter": ["FLOAT", "INT"]}
        document = json.loads(served(comfy))

    assert document["ExampleCounter"]["output"] == ["FLOAT", "INT"]
    assert document["ExampleQuiet"]["output"] == []
    assert document["FakeNode"] == OBJECT_INFO["FakeNode"]


# --------------------------------------------------------------------------
# The four locks, each through a whole run
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class Lock:
    """One runtime-backed lock: what the stand-in declares, the graph, the verdict."""

    class_type: str
    #: The input the lock is about, and the text the graph carries in it.
    name: str
    value: str
    #: Everything else node ``1`` carries -- a wire, a parent shape.
    beside: Dict[str, Any]
    #: ``node_inputs`` / ``node_outputs`` for :attr:`class_type`.
    inputs: Dict[str, Any]
    outputs: List[str]
    #: What node ``1`` hands on to the rest of the graph.
    downstream: Callable[[], Dict[str, Any]]
    kind: str
    sentence: str


def into_steps() -> Dict[str, Any]:
    return {
        "2": {"class_type": "ExampleTextEncode", "inputs": {"text": "a quiet street at dawn"}},
        "3": {
            "class_type": "ExampleSampler",
            "inputs": {"seed": 7, "steps": ["1", 0], "positive": ["2", 0]},
        },
    }


def into_model() -> Dict[str, Any]:
    return {
        "2": {"class_type": "ExampleTextEncode", "inputs": {"text": "a quiet street at dawn"}},
        "3": {
            "class_type": "ExampleSampler",
            "inputs": {"seed": 7, "model": ["1", 0], "positive": ["2", 0]},
        },
        "4": {"class_type": "ExampleModelSource", "inputs": {}},
    }


def onto_picture() -> Dict[str, Any]:
    return {
        "2": {"class_type": "ExampleTextEncode", "inputs": {"text": "a quiet street at dawn"}},
        "3": {"class_type": "ExampleSampler", "inputs": {"seed": 7, "positive": ["2", 0]}},
        "4": {"class_type": "ExampleDecode", "inputs": {"samples": ["3", 0]}},
        "5": {"class_type": "ExampleImageSave", "inputs": {"images": ["1", 0]}},
    }


def shape(*options: Tuple[str, Dict[str, Any]]) -> List[Any]:
    return [
        "COMFY_DYNAMICCOMBO_V3",
        {"options": [{"key": key, "inputs": block} for key, block in options]},
    ]


LOCKS = [
    pytest.param(
        Lock(
            class_type="ExampleWholeRunArithmetic",
            name="formula",
            value="a * b + 1",
            beside={},
            inputs={"formula": ["STRING", {"multiline": False}]},
            outputs=["FLOAT", "INT"],
            downstream=into_steps,
            kind="computation",
            sentence=(
                "input 'formula' holds text on node class "
                "'ExampleWholeRunArithmetic', and every output the ComfyUI that "
                "runs this workflow declares for that class is a number (FLOAT, "
                "INT): whatever the text says, what it becomes is numbers another "
                "node reads. That is computation, not a setting -- LocalCanvas "
                "keeps it exactly as saved and offers no control for it."
            ),
        ),
        id="computation",
    ),
    pytest.param(
        Lock(
            class_type="ExampleWholeRunPatcher",
            name="picked_layers",
            value="4, 5, 6",
            beside={"model": ["4", 0]},
            inputs={"picked_layers": ["STRING", {"multiline": False}]},
            outputs=["MODEL"],
            downstream=into_model,
            kind="model_patch",
            sentence=(
                "input 'picked_layers' holds text on node class "
                "'ExampleWholeRunPatcher', and every output the ComfyUI that runs "
                "this workflow declares for that class is a model (MODEL): "
                "whatever the text says, what it changes is how that model is "
                "patched before another node uses it. That is part of the model, "
                "not a setting -- LocalCanvas keeps it exactly as saved and offers "
                "no control for it."
            ),
        ),
        id="model_patch",
    ),
    pytest.param(
        Lock(
            class_type="ExampleWholeRunCaption",
            name="tint",
            value="amber",
            beside={"image": ["4", 0]},
            inputs={"tint": ["STRING", {"default": "amber"}]},
            outputs=["IMAGE"],
            downstream=onto_picture,
            kind="declared_default",
            sentence=(
                "input 'tint' on node class 'ExampleWholeRunCaption' holds exactly "
                "the default the ComfyUI that runs this workflow declares for it, "
                "and nothing in the graph says whether it is a setting a user may "
                "change: the workflow's author never changed it. LocalCanvas keeps "
                "it exactly as saved and offers no control for it."
            ),
        ),
        id="declared_default",
    ),
    pytest.param(
        Lock(
            class_type="ExampleWholeRunShaped",
            name="variant.flavour",
            value="sharp",
            beside={"variant": "tuned"},
            inputs={
                "variant": shape(
                    ("plain", {"required": {}}),
                    (
                        "tuned",
                        {
                            "required": {
                                "flavour": shape(
                                    ("mild", {"required": {}}),
                                    ("sharp", {"required": {}}),
                                )
                            }
                        },
                    ),
                )
            },
            outputs=["MODEL", "CLIP"],
            downstream=into_model,
            kind="node_shape",
            sentence=(
                "input 'variant.flavour' holds 'sharp', which the ComfyUI that runs "
                "this workflow declares as one of the shapes node class "
                "'ExampleWholeRunShaped' can take: choosing another would add or "
                "remove inputs on that node rather than change this one. The "
                "workflow's author already chose it, LocalCanvas keeps it exactly "
                "as saved, and offers no control for it."
            ),
        ),
        id="chosen_shape_sub_input",
    ),
]


def graph_for(lock: Lock) -> Dict[str, Any]:
    graph = {"1": {"class_type": lock.class_type, "inputs": dict(lock.beside)}}
    graph["1"]["inputs"][lock.name] = lock.value
    graph.update(lock.downstream())
    return graph


@pytest.fixture()
def workspace(tmp_path: Path) -> SyncWorkspace:
    return SyncWorkspace(tmp_path)


def controls_of(report) -> List[Dict[str, Any]]:
    document = report_document(report)
    return [
        entry
        for workflow in document["workflows"]
        for entry in workflow.get("controls", ())
    ]


def the_control(report, name: str) -> Dict[str, Any]:
    found = [
        entry
        for entry in controls_of(report)
        if (entry["node"], entry["input"]) == ("1", name)
    ]
    assert len(found) == 1, (name, controls_of(report))
    return found[0]


@pytest.mark.parametrize("lock", LOCKS)
def test_a_whole_run_locks_the_string_and_the_same_graph_is_held_with_no_contract(
    lock: Lock, workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    graph = graph_for(lock)
    held = classify(lock.name, lock.value)
    assert held.exposure is Exposure.UNCERTAIN, "classify settles the fixture by itself"

    folder = workspace.add_source()
    write_json(folder / "a canvas.json", ui_graph("one"))
    workspace.write_config()
    browser = Browser(tmp_path, monkeypatch, default={"ok": True, "output": graph})
    with FakeComfy() as comfy:
        comfy.installed_nodes = (lock.class_type,)
        comfy.node_inputs = {lock.class_type: lock.inputs}
        comfy.node_outputs = {lock.class_type: list(lock.outputs)}
        with make_bridge(comfy.base_url, browser) as bridge:
            declared = run_sync(workspace.load(), bridge=bridge)
        asked = sorted(set(comfy.requests))

    assert "GET /object_info" in asked
    item = declared.workflows[0]
    assert item.state.value == "NEW", item.reason
    control = the_control(declared, lock.name)
    assert (control["section"], control["kind"], control["reason"], control["field"]) == (
        "locked",
        lock.kind,
        lock.sentence,
        None,
    )
    registry = load_registry(workspace.repo / "config" / "local" / "workflows")
    assert list(registry.diagnostics) == []
    assert [entry.id for entry in registry.workflows] == [item.id]
    written = sorted(entry.id for entry in registry.workflows[0].inputs)
    fields = sorted({entry["field"] for entry in controls_of(declared) if entry["field"]})
    assert written == fields
    assert "seed" in written, "the definition carries no field, so the absence says nothing"

    # The same graph, with no contract: an API export establishes no identity.
    unavailable = SyncWorkspace(tmp_path / "unavailable")
    export_folder = unavailable.add_source()
    write_json(export_folder / "an export.json", graph)
    unavailable.write_config()
    with FakeComfy() as comfy:
        comfy.installed_nodes = (lock.class_type,)
        comfy.node_inputs = {lock.class_type: lock.inputs}
        comfy.node_outputs = {lock.class_type: list(lock.outputs)}
        with make_bridge(comfy.base_url, browser) as bridge:
            without = run_sync(unavailable.load(), bridge=bridge)
        assert comfy.requests == []

    assert without.workflows[0].state.value == "NEEDS_REVIEW"
    assert report_document(without)["runtime_contract"]["declared"] is None
    control = the_control(without, lock.name)
    assert (control["section"], control["kind"], control["reason"]) == (
        "needs_review",
        None,
        held.reason,
    )
