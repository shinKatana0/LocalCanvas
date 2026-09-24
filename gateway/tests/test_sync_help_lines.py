"""Say what the knob does (T-0131, amended by T-0131-02).

`docs/workflow-schema.md` has always given a field an optional ``help`` -- "a
one-line hint" -- the app has always rendered it under the control, and the
shipped examples have always used it.  The importer never wrote one, so a real
catalogue arrived on a phone as ``Cfg``, ``Denoise``, ``Sampler name``,
``Scheduler`` and nothing to say what any of them did.

Two questions decide every assertion here, and they are separate:

**Where does the sentence come from?**  From `semantics.py`, in two tables and
in this order:

    1. the graph's own input name, from ``PlannedField.targets``
    2. only where that said nothing, the role `analysis.py` minted from the
       wiring -- which is how a negative prompt whose own input is called
       ``text`` gets a line at all
    3. otherwise nothing, and no ``help`` key is written

The order is the design.  Keying on the field id was rejected on measured
grounds -- T-0097 mints ``strength_clip-<hash>`` where one role covers two
controls the wiring tells apart, and every one of those would be missed -- so
the first table is never overridden by the second.

**Who owns the sentence once it is in the file?**  ``help`` joins the *label*
mechanism (T-0110) and not the "anything already written wins" rule that
governs ``presentation``.  The generator writes one for every field it knows,
on every run, so presence in the file proves nothing about who wrote it:

    file help == the help this importer generated last time  ->  refresh it
    file help != that help                                   ->  keep it
    nothing remembered at all                                ->  keep it

Under the presentation rule an improved sentence could never reach a catalogue
that already exists, and the vocabulary would be unimprovable from the first
import onward.

Every graph here is built in this file out of node types that exist nowhere
else, and every fixture is an API-format export -- a dict of nodes, which is
what a graph on disk is -- rather than a hand-made plan object, so the path
under test starts where the real one does.  No model, family, vendor or node
pack is named.
"""

from __future__ import annotations

import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Tuple

import pytest
import yaml

from localcanvas_gateway.workflows import load_registry
from localcanvas_gateway.workflows.sync import (
    WorkflowState,
    analyse,
    definitions as definitions_module,
    generated_help,
    run_sync,
    semantics as semantics_module,
)

# Both private, both imported on purpose.  ``_ROLE_ORDER`` is the authority for
# what a role minted from the wiring *is*, and T-0131-02 requires the second
# table to be held to it by name: rename or empty that constant and the test
# below fails, rather than quietly checking nothing.  ``_label`` is how the
# importer turns a role into the words that sit directly above the hint, and it
# is the only honest way to ask "does this sentence merely restate its label".
from localcanvas_gateway.workflows.sync.analysis import _ROLE_ORDER, _label, _polarity

from sync_fixtures import SyncWorkspace, write_json

FIXED = datetime(2026, 1, 2, 3, 4, 5, tzinfo=timezone.utc)


# ==========================================================================
# The graphs
# ==========================================================================


def workshop_graph(*, steps: int = 20) -> Dict[str, Any]:
    """One graph holding every case this card has to decide.

    * nodes 2 and 3 -- two add-ons in a chain, each with its own
      ``strength_model`` and ``strength_clip``.  The wiring tells them apart,
      so T-0097 mints four ids with a disambiguating suffix, and every one of
      them still has to resolve through its *input name*.
    * nodes 4 and 5 -- two text encoders, told apart only by which of the
      sampler's conditioning inputs consumes them.  Both inputs are called
      ``text``; the ids ``prompt`` and ``negative_prompt`` come from the
      wiring, and only the second table can answer for them.
    * node 6 -- ``seed``, ``steps`` and ``cfg``, which the input-name table
      knows, beside ``mystery_dial``, which nothing knows and which must
      therefore be written with no ``help`` key at all.
    """

    return {
        "1": {
            "class_type": "ExampleWeightsLoader",
            "inputs": {"ckpt_name": "chosen-weights.safetensors"},
        },
        "2": {
            "class_type": "ExampleAdapterLoader",
            "inputs": {
                "adapter_name": "first.safetensors",
                "strength_model": 0.8,
                "strength_clip": 0.8,
                "model": ["1", 0],
                "clip": ["1", 1],
            },
        },
        "3": {
            "class_type": "ExampleAdapterLoader",
            "inputs": {
                "adapter_name": "second.safetensors",
                "strength_model": 0.4,
                "strength_clip": 0.4,
                "model": ["2", 0],
                "clip": ["2", 1],
            },
        },
        "4": {
            "class_type": "ExampleTextEncode",
            "inputs": {"text": "a quiet street at dawn", "clip": ["3", 1]},
        },
        "5": {
            "class_type": "ExampleTextEncode",
            "inputs": {"text": "blurry, low quality", "clip": ["3", 1]},
        },
        "6": {
            "class_type": "ExampleSampler",
            "inputs": {
                "seed": 12345,
                "steps": steps,
                "cfg": 6.5,
                "mystery_dial": 3,
                "model": ["3", 0],
                "positive": ["4", 0],
                "negative": ["5", 0],
            },
        },
        "7": {
            "class_type": "ExampleDecode",
            "inputs": {"samples": ["6", 0], "vae": ["1", 2]},
        },
        "8": {"class_type": "ExampleSaveImage", "inputs": {"images": ["7", 0]}},
    }


def two_seeds_graph() -> Dict[str, Any]:
    """One field driving two inputs the graph calls by different names.

    ``docs/workflow-schema.md`` names this case itself -- "one seed in a
    sampler's ``seed`` and a second sampler's ``noise_seed``" -- and
    ``ROLE_SYNONYMS`` is why the two collapse into one field.  The field then
    has two targets whose input names disagree, and one sentence cannot
    honestly describe two differently-named inputs.
    """

    return {
        "1": {
            "class_type": "ExampleWeightsLoader",
            "inputs": {"ckpt_name": "chosen-weights.safetensors"},
        },
        "2": {
            "class_type": "ExampleTextEncode",
            "inputs": {"text": "a quiet street at dawn", "clip": ["1", 1]},
        },
        "3": {
            "class_type": "ExampleSampler",
            "inputs": {"seed": 7, "model": ["1", 0], "positive": ["2", 0]},
        },
        "4": {
            "class_type": "ExampleRefiner",
            "inputs": {"noise_seed": 7, "model": ["1", 0], "positive": ["2", 0]},
        },
        "5": {"class_type": "ExampleSaveImage", "inputs": {"images": ["3", 0]}},
    }


def placeholder_graph() -> Dict[str, Any]:
    """Two nodes whose only input the graph calls ``value`` (T-0097).

    A number reaching a guidance scale and a number reaching a step count,
    named by nobody.  They are told apart by what consumes them, so each gets
    an id of its own -- and nothing generic can be said about either, because
    the graph's own word for both is "value".
    """

    return {
        "1": {
            "class_type": "ExampleWeightsLoader",
            "inputs": {"ckpt_name": "chosen-weights.safetensors"},
        },
        "2": {
            "class_type": "ExampleTextEncode",
            "inputs": {"text": "a quiet street at dawn", "clip": ["1", 1]},
        },
        "3": {"class_type": "ExampleWholeSource", "inputs": {"value": 8}},
        "4": {"class_type": "ExampleWholeSource", "inputs": {"value": 30}},
        "5": {
            "class_type": "ExampleSampler",
            "inputs": {
                "seed": 7,
                "cfg": ["3", 0],
                "steps": ["4", 0],
                "model": ["1", 0],
                "positive": ["2", 0],
            },
        },
        "6": {"class_type": "ExampleSaveImage", "inputs": {"images": ["5", 0]}},
    }


def negative_by_name_graph() -> Dict[str, Any]:
    """A negative prompt whose own input the graph calls ``negative``.

    The one shape where both tables can answer for a single field: the input
    name is a key of ``INPUT_HELP`` and the id is a role ``ROLE_HELP`` holds.
    Built as a graph rather than asserted in prose so that "this pair is
    reachable" is a measurement.
    """

    return {
        "1": {
            "class_type": "ExampleWeightsLoader",
            "inputs": {"ckpt_name": "chosen-weights.safetensors"},
        },
        "3": {
            "class_type": "ExampleTextEncode",
            "inputs": {"text": "a quiet street at dawn", "clip": ["1", 1]},
        },
        "4": {
            "class_type": "ExampleTextEncode",
            "inputs": {"negative": "blurry, low quality", "clip": ["1", 1]},
        },
        "5": {
            "class_type": "ExampleSampler",
            "inputs": {
                "seed": 7,
                "model": ["1", 0],
                "positive": ["3", 0],
                "negative": ["4", 0],
            },
        },
        "6": {"class_type": "ExampleSaveImage", "inputs": {"images": ["5", 0]}},
    }


def two_negative_prompts_graph() -> Dict[str, Any]:
    """Two prompt fields the wiring gives the same role, named differently.

    Node 3's own input is literally called ``negative_prompt``, which settles
    its polarity by the name; node 4's is called ``text`` and takes the same
    role from the sampler that consumes it.  Two groups, one role, so T-0097
    mints a disambiguating suffix for both ids -- and neither id is then an
    exact match for ``ROLE_HELP``.

    That makes one graph answer two questions at once:

    * the field bound to ``negative_prompt`` must still get its sentence, from
      the **input-name** table, exactly as T-0131-01's criterion about a
      suffixed id requires;
    * the field bound to ``text`` must get nothing, because the only table that
      could describe it matches an id exactly and this id is suffixed.
    """

    return {
        "1": {
            "class_type": "ExampleWeightsLoader",
            "inputs": {"ckpt_name": "chosen-weights.safetensors"},
        },
        "3": {
            "class_type": "ExampleTextEncode",
            "inputs": {
                "negative_prompt": "a quiet street at dawn",
                "clip": ["1", 1],
            },
        },
        "4": {
            "class_type": "ExampleTextEncode",
            "inputs": {"text": "blurry, low quality", "clip": ["1", 1]},
        },
        "5": {
            "class_type": "ExampleSampler",
            "inputs": {
                "seed": 7,
                "model": ["1", 0],
                "positive": ["3", 0],
                "negative": ["4", 0],
            },
        },
        "6": {"class_type": "ExampleSaveImage", "inputs": {"images": ["5", 0]}},
    }


def renumbered(graph: Dict[str, Any], offset: int = 700) -> Dict[str, Any]:
    """The same graph with every node id moved, and every wire moved with it.

    Used so that "the definition really was rewritten" is a fact about
    ``bind``, which cannot survive a renumbering, rather than a claim.
    """

    mapping = {node: str(int(node) + offset) for node in graph}
    moved: Dict[str, Any] = {}
    for node, body in graph.items():
        inputs: Dict[str, Any] = {}
        for name, value in body["inputs"].items():
            if isinstance(value, list) and len(value) == 2 and value[0] in mapping:
                inputs[name] = [mapping[value[0]], value[1]]
            else:
                inputs[name] = value
        moved[mapping[node]] = {"class_type": body["class_type"], "inputs": inputs}
    return moved


# ==========================================================================
# What the vocabulary says today, verbatim
# ==========================================================================
#
# Written out rather than read from the table under test.  A test that pulled
# the expected sentence out of `semantics.py` would pass whatever `semantics.py`
# happened to say, including a sentence somebody changed by accident -- which
# is one of the mutations this file has to die on.

SEED_HELP = "The starting point for the randomness. The same number repeats a result."
STEPS_HELP = "How much work goes into the result. More steps, more detail, more waiting."
CFG_HELP = "How closely your words are followed. Too high looks harsh and overcooked."
STRENGTH_CLIP_HELP = "How strongly the add-on changes the way your words are read."
STRENGTH_MODEL_HELP = "How strongly the add-on changes the picture. Zero turns it off."
PROMPT_HELP = "Describe what you want to see. More detail gives more to go on."
NEGATIVE_PROMPT_HELP = (
    "What to keep out of the result. Leave it empty if nothing comes to mind."
)

#: The whole of what this fixture is written with, by field id.  A field absent
#: from here is a field with **no** ``help`` key, and the tests below say so of
#: each one by name rather than by counting.
WORKSHOP_HELP = {
    "prompt": PROMPT_HELP,
    "negative_prompt": NEGATIVE_PROMPT_HELP,
    "cfg": CFG_HELP,
    "seed": SEED_HELP,
    "steps": STEPS_HELP,
    "strength_clip-e727c2a7": STRENGTH_CLIP_HELP,
    "strength_clip-ed120a9b": STRENGTH_CLIP_HELP,
    "strength_model-6a581364": STRENGTH_MODEL_HELP,
    "strength_model-ba4d10db": STRENGTH_MODEL_HELP,
}

#: Fields of that fixture that must carry no hint at all, and why each one is
#: here.  ``mystery_dial`` is a perfectly ordinary exposed control the
#: vocabulary has nothing true to say about.
WORKSHOP_SILENT = ("mystery_dial",)

#: What a person might type over one of them.  No table produces either.
BY_HAND_SEED = "Change this for a different picture, keep it for the same one"
BY_HAND_STEPS = "Twenty is plenty for a quick look"


# ==========================================================================
# Helpers
# ==========================================================================


@pytest.fixture()
def workspace(tmp_path: Path) -> SyncWorkspace:
    return SyncWorkspace(tmp_path)


def sync_once(
    workspace: SyncWorkspace,
    graph: Dict[str, Any],
    *,
    name: str = "one",
):
    """Write the graph into the source folder and run one whole sync."""

    folder = workspace.sources[0] if workspace.sources else workspace.add_source()
    write_json(folder / "{}.json".format(name), graph)
    workspace.write_config()
    return run_sync(workspace.load(), now=FIXED)


def definition_path(workspace: SyncWorkspace, workflow_id: str = "one") -> Path:
    return workspace.repo / "config" / "local" / "workflows" / "{}.yaml".format(
        workflow_id
    )


def only_workflow(report):
    assert len(report.workflows) == 1, [item.state for item in report.workflows]
    return report.workflows[0]


def fields_in(path: Path) -> Dict[str, Dict[str, Any]]:
    document = yaml.safe_load(path.read_text(encoding="utf-8"))
    return {item["id"]: item for item in document["inputs"]}


def help_in(path: Path) -> Dict[str, str]:
    """``{field id: help}`` for the fields that have one, and only those.

    A field with no ``help`` key is simply absent, so ``==`` against a table
    tests both halves at once: the sentences that are there, and the absences.
    """

    return {
        field_id: item["help"]
        for field_id, item in fields_in(path).items()
        if "help" in item
    }


def yaml_block(text: str, field_id: str) -> str:
    """The raw lines of one field's YAML entry, as written.

    Parsing turns ``help: ''`` and a missing ``help`` into the same shape once
    a caller stops being careful, and an absence has to be asserted on the text
    that is really on disk.
    """

    lines = text.splitlines()
    starts = [
        index
        for index, line in enumerate(lines)
        if line == "- id: {}".format(field_id)
    ]
    assert len(starts) == 1, "expected one '{}' entry, found {}".format(
        field_id, len(starts)
    )
    start = starts[0]
    end = start + 1
    while end < len(lines) and not lines[end].startswith("- "):
        end += 1
    return "\n".join(lines[start:end])


def remembered_help(workspace: SyncWorkspace, workflow_id: str = "one") -> Dict[str, str]:
    """The record as the **written JSON** holds it, not as an object holds it."""

    entries = workspace.read_inventory()["workflows"]
    found = [entry for entry in entries if entry["id"] == workflow_id]
    assert found, [entry["id"] for entry in entries]
    assert "generated_help" in found[0], sorted(found[0])
    return found[0]["generated_help"]


def rewrite_help(path: Path, replacements: Mapping[str, str]) -> None:
    """Edit the hints of an existing definition, as a curator would.

    The file is loaded and dumped, so what comes back is a definition somebody
    edited and not one this test composed: every other key keeps the value the
    sync wrote.
    """

    document = yaml.safe_load(path.read_text(encoding="utf-8"))
    unknown = set(replacements) - {item["id"] for item in document["inputs"]}
    assert not unknown, "nothing to edit: {}".format(sorted(unknown))
    for item in document["inputs"]:
        if item["id"] in replacements:
            item["help"] = replacements[item["id"]]
    path.write_text(
        yaml.safe_dump(document, sort_keys=False, allow_unicode=True),
        encoding="utf-8",
    )


def improve_the_vocabulary(monkeypatch: pytest.MonkeyPatch) -> None:
    """Make both tables say something else, without editing `semantics.py`.

    This is the whole point of the card's regeneration rule: a better sentence
    has to reach a catalogue that already exists.  A test that only asserted
    today's text could never show that, so the vocabulary is genuinely changed
    here and the definitions have to follow it.
    """

    monkeypatch.setattr(
        semantics_module,
        "INPUT_HELP",
        {key: "Now we say " + value for key, value in semantics_module.INPUT_HELP.items()},
    )
    monkeypatch.setattr(
        semantics_module,
        "ROLE_HELP",
        {key: "Now we say " + value for key, value in semantics_module.ROLE_HELP.items()},
    )


def moved_on(help_lines: Mapping[str, str]) -> Dict[str, str]:
    """The same fields, as the improved vocabulary words them."""

    return {field_id: "Now we say " + text for field_id, text in help_lines.items()}


# ==========================================================================
# The vocabulary itself, as prose
# ==========================================================================


#: Words the sentences may not contain, each of them jargon a hint would be
#: explaining with more jargon, and each one a plausible thing to write.
#:
#: The Russian half (T-0143) is the same list of mistakes in the language they
#: would actually be made in: a translator reaching for a borrowed English term
#: is the single likeliest way for a Russian hint to explain nothing, and
#: "денойзинг" is not more legible to a Russian reader than "denoising" is to
#: an English one.
FORBIDDEN_WORDS = (
    "cfg scale",
    "classifier-free",
    "classifier free",
    "denoising",
    "latent",
    "sigma",
    "unet",
    "checkpoint",
    "embedding",
    "tensor",
    "денойз",
    "сэмплер",
    "семплер",
    "латент",
    "шедулер",
    "чекпоинт",
    "эмбеддинг",
    "тензор",
    "сигма",
    "кфг",
    "гайденс",
)


def every_sentence():
    """Every table, as ``(which table, key, sentence)``.

    All four of them (T-0143), so that a rule the English was held to is a
    rule the Russian is held to as well and nobody has to remember to widen a
    loop when a language is added.
    """

    for table in ("INPUT_HELP", "ROLE_HELP", "INPUT_HELP_RU", "ROLE_HELP_RU"):
        for key, text in sorted(getattr(semantics_module, table).items()):
            yield table, key, text


#: Both tables, word for word, so that **every** sentence is guarded and not
#: only the nine this file's fixtures happen to exercise.  The card's own rule
#: is "assert verbatim, never counted", and a count of entries passes a run that
#: reworded one of them or dropped it.
#:
#: It is a golden copy on purpose.  Editing a sentence in `semantics.py` fails
#: here, which is the point: these lines are read by strangers on a phone, and
#: changing one should cost a deliberate second edit rather than happening in
#: passing. Nothing derives it from the module under test -- a table computed
#: from `semantics.py` would agree with whatever `semantics.py` said.
EXPECTED_INPUT_HELP = {
    "batch_size": "How many pictures to make in one go. More at once needs more memory.",
    "cfg": "How closely your words are followed. Too high looks harsh and overcooked.",
    "combine_embeds": "How several references are merged when you supply more than one.",
    "crop_position": "Which part of the picture to keep when it has to be cropped.",
    "denoise": "How much of the starting picture is redrawn. Lower keeps more of it.",
    "embeds_scaling": "How the reference's influence is scaled. Changes how forceful it feels.",
    "end_at": "When during the run this stops. Earlier leaves the final detail alone.",
    "end_percent": "When during the run this stops. Earlier leaves the final detail alone.",
    "height": "How tall the result is, in pixels. Bigger costs more time and memory.",
    "interpolation": "The method used when the picture is resized. Affects sharpness slightly.",
    "lora_strength": "How strongly the add-on changes the result. Zero turns it off.",
    "negative": "What to keep out of the result. Leave it empty if nothing comes to mind.",
    "negative_prompt": "What to keep out of the result. Leave it empty if nothing comes to mind.",
    "noise_seed": "The starting point for the randomness. The same number repeats a result.",
    "rand_seed": "The starting point for the randomness. The same number repeats a result.",
    "random_seed": "The starting point for the randomness. The same number repeats a result.",
    "sampler_name": "The method used to build the picture. Each has a slightly different look.",
    "scheduler": "How the effort is spread over the run. Affects texture more than content.",
    "seed": "The starting point for the randomness. The same number repeats a result.",
    "sharpening": "How much extra edge definition to add. Too much of it looks crunchy.",
    "shift": "Biases the run towards the overall shape or towards the fine detail.",
    "start_at": "When during the run this begins. Later leaves the early shape alone.",
    "start_percent": "When during the run this begins. Later leaves the early shape alone.",
    "steps": "How much work goes into the result. More steps, more detail, more waiting.",
    "strength": "How strongly this effect is applied. Zero leaves the result untouched.",
    "strength_clip": "How strongly the add-on changes the way your words are read.",
    "strength_model": "How strongly the add-on changes the picture. Zero turns it off.",
    "weight": "How strongly it is applied. Higher pushes the result further.",
    "weight_faceidv2": "How strongly the face reference counts, on top of the main strength.",
    "weight_type": "Chooses how that strength is applied, not how much of it there is.",
    "width": "How wide the result is, in pixels. Bigger costs more time and memory.",
}

EXPECTED_ROLE_HELP = {
    "prompt": "Describe what you want to see. More detail gives more to go on.",
    "negative_prompt": "What to keep out of the result. Leave it empty if nothing comes to mind.",
}

#: The same golden copy for Russian (T-0143), and for the same reason: these
#: lines are read by strangers on a phone, in a language most contributors to this
#: repository do not read, so the one thing that must not happen is a sentence
#: changing in passing.  Every one of them is spelled out here.
EXPECTED_INPUT_HELP_RU = {
    "batch_size": "Сколько картинок сделать за один раз. Чем больше сразу, тем больше нужно памяти.",
    "cfg": "Насколько точно выполняются ваши слова. Перебор делает картинку контрастной и грубой.",
    "combine_embeds": "Как объединяются несколько образцов, когда вы даёте больше одного.",
    "crop_position": "Какую часть картинки оставить, когда её приходится обрезать.",
    "denoise": "Насколько сильно перерисовать исходную картинку. Меньше — больше от неё останется.",
    "embeds_scaling": "Как пересчитывается влияние образца. Меняет, насколько сильно оно ощущается.",
    "end_at": "Когда по ходу работы это заканчивается. Раньше — мелкие детали не тронуты.",
    "end_percent": "Когда по ходу работы это заканчивается. Раньше — мелкие детали не тронуты.",
    "height": "Какой высоты будет результат в пикселях. Больше — дольше и больше памяти.",
    "interpolation": "Способ, которым картинка меняет размер. Немного влияет на резкость.",
    "lora_strength": "Насколько сильно дополнение меняет результат. Ноль выключает его.",
    "negative": "Что не должно попасть в результат. Оставьте пустым, если ничего не приходит на ум.",
    "negative_prompt": "Что не должно попасть в результат. Оставьте пустым, если ничего не приходит на ум.",
    "noise_seed": "Отправная точка для случайности. То же число повторяет тот же результат.",
    "rand_seed": "Отправная точка для случайности. То же число повторяет тот же результат.",
    "random_seed": "Отправная точка для случайности. То же число повторяет тот же результат.",
    "sampler_name": "Способ, которым строится картинка. У каждого немного свой вид.",
    "scheduler": "Как усилия распределяются по ходу работы. Влияет больше на фактуру, чем на содержание.",
    "seed": "Отправная точка для случайности. То же число повторяет тот же результат.",
    "sharpening": "Сколько добавить резкости краям. Перебор выглядит неестественно жёстко.",
    "shift": "Смещает работу в сторону общей формы или в сторону мелких деталей.",
    "start_at": "Когда по ходу работы это начинается. Позже — общая форма не тронута.",
    "start_percent": "Когда по ходу работы это начинается. Позже — общая форма не тронута.",
    "steps": "Сколько труда вкладывается в результат. Больше шагов — больше деталей и ожидания.",
    "strength": "Насколько сильно применяется этот эффект. Ноль оставляет результат как есть.",
    "strength_clip": "Насколько сильно дополнение меняет прочтение ваших слов.",
    "strength_model": "Насколько сильно дополнение меняет картинку. Ноль выключает его.",
    "weight": "Насколько сильно это применяется. Больше — сильнее сдвигает результат.",
    "weight_faceidv2": "Насколько важен образец лица, сверх основной силы.",
    "weight_type": "Выбирает, как именно применяется эта сила, а не сколько её.",
    "width": "Какой ширины будет результат в пикселях. Больше — дольше и больше памяти.",
}

EXPECTED_ROLE_HELP_RU = {
    "prompt": "Опишите, что хотите увидеть. Чем больше подробностей, тем лучше.",
    "negative_prompt": "Что не должно попасть в результат. Оставьте пустым, если ничего не приходит на ум.",
}

#: Names the vocabulary deliberately does **not** hold, each with the reason,
#: because an absence is a decision here and a golden copy alone would let one
#: reappear under a plausible-looking sentence nobody weighed.
DELIBERATELY_SILENT = {
    "value": "the graph's own word for a control it never named; T-0097's ids",
    "text": "equally the positive prompt's input and the negative one's",
    "prompt": "settles no polarity, and five catalogue workflows wire an input "
    "called this into a sampler's negative",
    "pre_cfg": "no antecedent for 'the effect', and an outcome nobody can promise",
    "reference_latents_method": "nothing true and useful fits in one line",
    "preprocessor": "nothing true of it in every graph that has one",
    "resolution": "nothing true of it in every graph that has one",
}


def test_both_tables_are_exactly_these_sentences() -> None:
    """Every sentence, verbatim, and not the nine the fixtures happen to use.

    The card's rule is "assert verbatim, never counted", and this is where it
    is honoured for the whole vocabulary: reword an entry, drop one, or add one
    nobody weighed, and this fails by name.  The tests below that assert a
    written definition still matter -- they say the right sentence reaches the
    right *field* -- but they can only reach the entries their fixtures use.
    """

    assert semantics_module.INPUT_HELP == EXPECTED_INPUT_HELP
    assert semantics_module.ROLE_HELP == EXPECTED_ROLE_HELP


def test_both_russian_tables_are_exactly_these_sentences() -> None:
    """The same guard for the second language (T-0143).

    Worth more here than it is in English, not less.  A contributor to this
    repository can read an English sentence and judge it; a Russian one they
    cannot read is exactly the kind of string that gets "tidied" by a later
    change nobody weighs.  Spelled out, every edit to one costs a deliberate
    second edit here.
    """

    assert semantics_module.INPUT_HELP_RU == EXPECTED_INPUT_HELP_RU
    assert semantics_module.ROLE_HELP_RU == EXPECTED_ROLE_HELP_RU


def test_the_two_languages_know_exactly_the_same_names() -> None:
    """A sentence added to one table and forgotten in the other fails here.

    This is the defect the whole card is exposed to: the lookup falls back to
    English for a key Russian is missing, which is the right thing to *serve*
    and the wrong thing to leave undetected -- a Russian reader would get one
    English line among thirty Russian ones and nobody would ever hear about
    it.  Equality of the key sets is where that is caught, so the fallback can
    stay forgiving.
    """

    assert set(semantics_module.INPUT_HELP) == set(semantics_module.INPUT_HELP_RU)
    assert set(semantics_module.ROLE_HELP) == set(semantics_module.ROLE_HELP_RU)
    assert semantics_module.INPUT_HELP_RU, "an empty table would make this vacuous"
    assert semantics_module.ROLE_HELP_RU, "an empty table would make this vacuous"


def test_every_russian_sentence_is_really_in_russian() -> None:
    """Cyrillic present, Latin absent -- an untranslated entry fails here.

    The golden copy above catches a *known* entry left in English.  This
    catches the next one: a key added to both tables with the English text
    copied into the Russian one, which is the shape a hurried change takes and
    which reads, on the phone, as a bug in the app.

    "No Latin letter at all" is a strong rule and it is affordable, because
    every sentence in this vocabulary describes a control in plain words --
    there is no unit, no code and no product name in any of the thirty-three.
    It also subsumes
    ``test_no_sentence_names_a_model_a_family_or_a_vendor`` for the Russian
    tables: every family name that test lists is Latin, so none of them can
    survive this one.
    """

    latin = re.compile(r"[A-Za-z]")
    cyrillic = re.compile(r"[Ѐ-ӿ]")
    checked = 0
    for table, key, text in every_sentence():
        if not table.endswith("_RU"):
            continue
        checked += 1
        where = "{}[{!r}]".format(table, key)
        assert cyrillic.search(text), "{} is not in Russian: {!r}".format(where, text)
        assert not latin.search(text), "{} carries Latin letters: {!r}".format(
            where, text
        )
    assert checked == 33, "expected 33 Russian sentences, walked {}".format(checked)


def test_the_two_languages_say_the_same_thing_about_the_same_names() -> None:
    """Where two names share one English sentence they share one Russian one.

    Four names mean "the starting point for the randomness" and take one
    English sentence between them; ``end_at`` and ``end_percent`` take another;
    ``negative`` and ``negative_prompt`` a third.  That is not decoration -- it
    is the statement that those names are the *same idea under different
    spellings*, and a translation that gave two of them different Russian
    would be asserting a distinction the English does not make, under two
    controls that behave identically.

    Checked in both directions, so a Russian table that *merges* two names the
    English keeps apart fails too.
    """

    english = semantics_module.INPUT_HELP
    russian = semantics_module.INPUT_HELP_RU
    names = sorted(english)
    assert len(names) > 1, "one name cannot be compared with another"
    compared = 0
    for index, first in enumerate(names):
        for second in names[index + 1 :]:
            compared += 1
            assert (english[first] == english[second]) == (
                russian[first] == russian[second]
            ), (
                "{!r} and {!r} are one sentence in one language and two in the "
                "other:\n  en: {!r}\n      {!r}\n  ru: {!r}\n      {!r}".format(
                    first,
                    second,
                    english[first],
                    english[second],
                    russian[first],
                    russian[second],
                )
            )
    assert compared == len(names) * (len(names) - 1) // 2


def test_a_language_the_vocabulary_does_not_have_falls_back_to_english() -> None:
    """`docs/api.md`'s promise, at the level of the lookup.

    Neither an error nor an empty string: an app asking for a language nobody
    has written yet gets the sentence that exists.  The two arms are asserted
    separately because they fail differently -- a language that is not there
    at all, and a language that is there but has no entry for that name.
    """

    english = semantics_module.INPUT_HELP["seed"]
    russian = semantics_module.INPUT_HELP_RU["seed"]
    assert english != russian, "this test would prove nothing if they matched"

    assert semantics_module.help_for("seed", "ru") == russian
    assert semantics_module.help_for("seed", "en") == english
    assert semantics_module.help_for("seed") == english
    for unknown in ("fr", "ja", "ru-RU", "RU", "", "en-GB"):
        assert semantics_module.help_for("seed", unknown) == english, unknown
        assert (
            semantics_module.help_for_role("prompt", unknown)
            == semantics_module.ROLE_HELP["prompt"]
        ), unknown

    # A name no table holds is silent in every language, and silence is not a
    # thing the fallback may fill in.
    for language in ("en", "ru", "fr"):
        assert semantics_module.help_for("mystery_dial", language) is None, language
        assert semantics_module.help_for_role("mystery_dial", language) is None, language


def test_the_names_left_out_are_still_left_out() -> None:
    """The absences, which a golden copy of what is present cannot state.

    Each of these was considered and refused, and the reason is beside it.  A
    later entry for one is a decision somebody has to take again, in front of
    this list, rather than a gap that quietly closed.
    """

    for name, reason in sorted(DELIBERATELY_SILENT.items()):
        assert name not in semantics_module.INPUT_HELP, "{}: {}".format(name, reason)
        assert name not in semantics_module.INPUT_HELP_RU, "{}: {}".format(name, reason)
        for language in semantics_module.HELP_LANGUAGES:
            assert semantics_module.help_for(name, language) is None, (name, language)

    # ``value`` is the one the card names outright, and it must be silent in
    # both tables rather than only in the first.
    assert "value" not in semantics_module.ROLE_HELP
    assert "value" not in semantics_module.ROLE_HELP_RU
    for language in semantics_module.HELP_LANGUAGES:
        assert semantics_module.help_for_role("value", language) is None, language


def test_every_sentence_obeys_the_writing_rules() -> None:
    """The mechanical half of the writing rules, over the whole vocabulary.

    Not a substitute for reading them -- "say what moving it changes" is not
    checkable by a machine -- but these four are, and each of them is a real
    way to spoil the feature:

    * a line that wraps to three lines on a phone costs more space than it
      teaches, so there is a ceiling;
    * a line that is one word is not a hint, so there is a floor;
    * a second line would be rendered as one run-on paragraph;
    * a sentence equal to the label it sits directly under says nothing at
      all, and ``_label`` is imported so that this asks the importer's own
      question rather than a guess at it;
    * a colon makes YAML quote that one scalar and leave every other bare, in
      a file a curator is invited to edit by hand.
    """

    for table, key, text in every_sentence():
        where = "{}[{!r}]".format(table, key)
        assert text == text.strip(), where
        assert "\n" not in text and "\r" not in text, where
        assert 40 <= len(text) <= 90, "{}: {} characters".format(where, len(text))
        assert ":" not in text, where
        assert text.endswith("."), where
        assert text.casefold() != _label(key).casefold(), where
        assert text.rstrip(".").casefold() != _label(key).casefold(), where
        lowered = text.casefold()
        for word in FORBIDDEN_WORDS:
            assert word not in lowered, "{} explains jargon with {!r}".format(
                where, word
            )


def test_no_sentence_names_a_model_a_family_or_a_vendor() -> None:
    """No model family is named: `semantics.py`'s own first rule.

    These sentences ship to strangers with unrelated ComfyUI installations, so
    a family name in one of them would be a public architectural assumption
    made in prose.  The list is the shape of the mistake, not a claim to be
    exhaustive -- the rule is enforced by review as well.
    """

    families = (
        "flux",
        "sdxl",
        "sd15",
        "sd 1.5",
        "qwen",
        "krea",
        "pony",
        "lora",
        "ipadapter",
        "controlnet",
        "comfyui",
    )
    for table, key, text in every_sentence():
        lowered = text.casefold()
        for family in families:
            assert family not in lowered, "{}[{!r}] names {!r}".format(
                table, key, family
            )


def test_value_is_deliberately_not_in_the_vocabulary() -> None:
    """The one absence the card names outright.

    ``value`` is what ComfyUI's primitive family calls its only input, and what
    T-0097's ``value-<hash>`` ids are named for.  Nothing generic is true of a
    control whose own graph called it "value", and a vacuous line under a
    control costs vertical space on a phone to teach nothing.
    """

    assert "value" not in semantics_module.INPUT_HELP
    assert "value" not in semantics_module.ROLE_HELP
    assert semantics_module.help_for("value") is None
    assert semantics_module.help_for_role("value") is None


def test_the_second_table_is_keyed_on_roles_and_cannot_widen_into_ids() -> None:
    """T-0131-02's guard, anchored to the symbol that defines a role.

    The fallback exists for the handful of fields `analysis.py` names from the
    wiring rather than from an input.  Keyed on "the field id" in general it
    would become the rule T-0131-01 rejected on measured grounds, and every
    T-0097-suffixed field would start taking a sentence meant for the role it
    was split out of.  ``_ROLE_ORDER`` is imported rather than copied so that
    renaming or emptying it fails here instead of silently checking nothing.
    """

    assert _ROLE_ORDER, "the authority for what a role is has been emptied"
    assert set(semantics_module.ROLE_HELP) <= set(_ROLE_ORDER), sorted(
        set(semantics_module.ROLE_HELP) - set(_ROLE_ORDER)
    )
    assert set(semantics_module.ROLE_HELP), "the subset above would be vacuous"


def reachable_pairs() -> List[Tuple[str, str]]:
    """Every ``(input name, role)`` one single field could carry at once.

    Derived, never listed.  An input name can reach a role only if the input is
    a prompt at all, and `semantics.classify`'s rule 5 makes that exactly "the
    name's words meet ``PROMPT_WORDS``" -- the same expression, on the same two
    symbols, so a change to either is a change here.

    Which role it then reaches is `analysis._polarity`'s answer, called with no
    wiring so it speaks only about the name:

    * "negative" in the name -> the negative prompt, always;
    * "positive" in the name -> the positive prompt, always;
    * neither -> the wiring decides, so **every** role is reachable.

    The roles come out of ``_ROLE_ORDER`` rather than being written here, so a
    role added later is covered and an emptied constant leaves this with
    nothing to check -- which the caller asserts against.
    """

    pairs: List[Tuple[str, str]] = []
    for name in sorted(semantics_module.INPUT_HELP):
        words = set(semantics_module._tokens(name))
        if not (words & semantics_module.PROMPT_WORDS):
            # Not a prompt, so it can never be a field the wiring names.
            continue
        settled, problem = _polarity("1", name, {})
        assert problem is None, (name, problem)
        if settled == "negative":
            excluded = {"prompt"}
        elif settled == "positive":
            excluded = {"negative_prompt"}
        else:
            excluded = set()
        for role in _ROLE_ORDER:
            if role in excluded or role not in semantics_module.ROLE_HELP:
                continue
            pairs.append((name, role))
    return pairs


def test_where_both_tables_can_answer_for_one_field_they_say_the_same_thing() -> None:
    """The invariant, and it is about the sentences rather than about the keys.

    Two tables knowing one field is harmless.  Two tables saying **different**
    things about it is not, because then only the order they are consulted in
    decides which words a person reads -- and an order is not a thing a reader
    of `semantics.py` can see.

    The pairing is the whole argument.  Measured on a real catalogue, all four
    pairings occur:

        id 'prompt'           bound to an input named 'text'
        id 'negative_prompt'  bound to an input named 'text'
        id 'prompt'           bound to an input named 'prompt'
        id 'negative_prompt'  bound to an input named 'prompt'   <- these

    Some workflows carry a **negative** prompt field whose bound input is
    literally called ``prompt``, because `analysis.py` reads the polarity off
    the wiring and overrides the name.  Adding ``prompt`` to ``INPUT_HELP`` with
    the positive sentence is an obvious, well-meant improvement that nothing
    else in the code would stop, and it would print "describe what you want"
    under the negative prompt in every one of those.  This test is what
    stops it, and it stops nothing else:

        (input 'prompt',          role 'negative_prompt')  differ -> forbidden
        (input 'negative_prompt', role 'negative_prompt')  equal  -> allowed
        (input 'negative',        role 'negative_prompt')  equal  -> allowed

    The two allowed pairs matter.  An earlier and broader form of this rule kept
    the two key sets *disjoint*, which deleted ``INPUT_HELP['negative_prompt']``
    -- and a field whose graph input is literally called ``negative_prompt``
    then lost its sentence the moment T-0097 gave its id a suffix, because
    ``ROLE_HELP`` matches an id exactly and the only table that could answer had
    had its key removed.  A rule broader than its hazard costs behaviour.

    The pairs are enumerated from `analysis.py`'s own rules rather than listed,
    so a key added to either table is covered without anybody remembering to
    come back here.
    """

    assert _ROLE_ORDER, "the authority for what a role is has been emptied"
    assert semantics_module.ROLE_HELP, "there is no second table to disagree with"
    assert semantics_module.INPUT_HELP, "there is no first table to disagree with"

    pairs = reachable_pairs()
    assert pairs, (
        "no field can be answered by both tables, so this asserts nothing -- "
        "which is either a real change of design or a broken enumeration"
    )

    # Both languages (T-0143).  The invariant is about what a person reads, so
    # it has to hold in the language they read it in: a Russian table whose
    # ``negative`` and ``negative_prompt`` drifted apart would put the lookup
    # order back in charge of the words, in Russian only, where nobody
    # reviewing this repository would see it.
    tables = (
        ("INPUT_HELP", semantics_module.INPUT_HELP, semantics_module.ROLE_HELP),
        ("INPUT_HELP_RU", semantics_module.INPUT_HELP_RU, semantics_module.ROLE_HELP_RU),
    )
    for where, by_name, by_role in tables:
        for name, role in pairs:
            assert by_name[name] == by_role[role], (
                "a field whose input is called {!r} takes the role {!r}, so both "
                "tables answer for it and they disagree in {}:\n  by name: {!r}\n  by "
                "role: {!r}".format(name, role, where, by_name[name], by_role[role])
            )


def test_the_pairs_that_invariant_covers_are_really_reachable() -> None:
    """The enumeration above, checked against a graph rather than trusted.

    An invariant over a derived set is only as good as the derivation, and a
    derivation that quietly stopped matching `analysis.py` would leave the test
    above passing over pairs that no longer exist while missing the ones that
    do.  So one pair is reproduced the long way -- build the graph, analyse it,
    read the id and the input name off the plan -- and the enumeration has to
    contain it.
    """

    plan = analyse(negative_by_name_graph())
    assert not plan.problems, plan.problems
    named = {item.id: item.targets for item in plan.fields}
    assert named["negative_prompt"] == (("4", "negative"),), named

    assert ("negative", "negative_prompt") in reachable_pairs()


def test_each_table_answers_for_the_fields_it_is_for() -> None:
    """The lookup, at the level of the decision, on a plan from a real graph.

    Three answers, one function: the input name where it is known, the role
    where the input name is not, and nothing where neither is.  Asserted here
    once so the definition-level tests below can be about the *file*.

    **It does not claim to prove the order**, and the name says so.  Wherever
    both tables can answer for one field they are held to say the same words --
    the agreement invariant above -- so swapping the two lookups changes no
    output anywhere and the order is unobservable from outside.  That is the
    point of the invariant rather than a gap in this test: there is nothing
    left for a behavioural test to catch, and the guard against a field being
    given the wrong sentence is the agreement, not the ordering.

    **The order-swapping mutant is therefore an equivalent mutant, and it is
    equivalent only while agreement holds.**  Weaken
    ``test_where_both_tables_can_answer_for_one_field_they_say_the_same_thing``
    and the order becomes load-bearing again with nothing watching it -- so
    that test is not a tidiness check to be relaxed, it is what this one leans
    on.
    """

    plan = analyse(workshop_graph())
    produced = generated_help(plan)

    assert produced["seed"] == SEED_HELP, "the input name was not consulted"
    assert produced["negative_prompt"] == NEGATIVE_PROMPT_HELP, "the role was not"
    assert "mystery_dial" not in produced, "something answered for an unknown name"


def test_the_importer_and_the_gateway_ask_one_rule_and_not_two() -> None:
    """The one rule, written twice, held to agreeing (T-0143).

    ``definitions._generated_help`` decides what the importer *writes*;
    ``semantics.help_for_field`` decides what the gateway *serves*, because
    the gateway has to work out for itself which hints in a file were
    generated and may be said in another language.  Two copies of a rule drift
    -- that is what they do -- and this is where a drift fails instead of
    producing a Russian sentence under a field the importer would never have
    written one for, or none under a field it did.

    Every field of every graph in this file, not a chosen one: the answers
    include sentences from the input-name table, sentences from the role
    table, and silence, and the counts are asserted so a rule that answered
    ``None`` everywhere could not pass by agreeing with itself.
    """

    graphs = {
        "workshop": workshop_graph(),
        "two_seeds": two_seeds_graph(),
        "placeholder": placeholder_graph(),
        "negative_by_name": negative_by_name_graph(),
        "two_negative_prompts": two_negative_prompts_graph(),
    }
    sentences = 0
    silences = 0
    for where, graph in sorted(graphs.items()):
        plan = analyse(graph)
        assert plan.fields, where
        for item in plan.fields:
            writes = definitions_module._generated_help(item)
            serves = semantics_module.help_for_field(
                (name for _node, name in item.targets), item.id
            )
            assert writes == serves, (
                "{}: the importer would write {!r} under {!r} and the gateway "
                "would recognise {!r}".format(where, writes, item.id, serves)
            )
            if writes is None:
                silences += 1
            else:
                sentences += 1

    assert sentences >= 10, sentences
    assert silences >= 1, silences


def test_every_line_a_sync_writes_is_recognised_as_generated_when_served(
    workspace: SyncWorkspace,
) -> None:
    """The two halves fitting, measured on a real file rather than argued.

    A sync runs, a definition lands on disk, the **registry loader** reads it
    back the way the gateway does, and every hint in it is put to the question
    the serving path asks: *is this exactly what the English vocabulary would
    produce for this field?*  If the answer were ever no, that hint would be
    treated as a curator's and would stay English forever, silently, for every
    Russian reader -- which is the failure this feature can have without
    anything crashing.

    The absences are checked in the same breath: a field the vocabulary does
    not know must be unrecognised as well as unwritten, or the serving path
    would be inventing a sentence the file never carried.
    """

    sync_once(workspace, workshop_graph())
    path = definition_path(workspace)
    written = help_in(path)
    assert written == WORKSHOP_HELP, "the fixture stopped writing what it wrote"

    registry = load_registry(path.parent)
    assert not registry.diagnostics, registry.diagnostics
    workflow = registry.get("one")
    assert workflow is not None, [item.id for item in registry.workflows]

    recognised = {}
    for field in workflow.inputs:
        answer = semantics_module.help_for_field(
            (binding.input for binding in workflow.bindings_for(field.id)), field.id
        )
        if answer is not None:
            recognised[field.id] = answer

    assert recognised == written
    for silent in WORKSHOP_SILENT:
        assert silent in {item.id for item in workflow.inputs}, silent
        assert silent not in recognised, silent


# ==========================================================================
# The fixture, measured, so every assertion below means something
# ==========================================================================


def test_the_fixture_plans_the_fields_these_tests_are_written_about() -> None:
    """What this graph turns into, before any question about ``help``.

    Without this, "``strength_clip-e727c2a7`` still gets the ``strength_clip``
    sentence" could be satisfied by a fixture whose ids never carried a suffix
    at all, and "``mystery_dial`` has no hint" by a field that was never
    exposed.  Both are asserted here as facts about the plan.
    """

    plan = analyse(workshop_graph())
    assert not plan.problems, plan.problems

    targets = {item.id: item.targets for item in plan.fields}
    assert targets == {
        "prompt": (("4", "text"),),
        "negative_prompt": (("5", "text"),),
        "cfg": (("6", "cfg"),),
        "mystery_dial": (("6", "mystery_dial"),),
        "seed": (("6", "seed"),),
        "steps": (("6", "steps"),),
        "strength_clip-e727c2a7": (("3", "strength_clip"),),
        "strength_clip-ed120a9b": (("2", "strength_clip"),),
        "strength_model-6a581364": (("3", "strength_model"),),
        "strength_model-ba4d10db": (("2", "strength_model"),),
    }

    # The two prompts are named by the wiring: their own input is ``text``,
    # which neither table may hold, because it is equally the other one's.
    assert "text" not in semantics_module.INPUT_HELP
    assert semantics_module.help_for("text") is None

    # And the four add-on strengths carry a suffix no table holds, so their
    # sentences can only have come from the input name.
    for field_id in ("strength_clip-e727c2a7", "strength_model-ba4d10db"):
        assert re.fullmatch(r"strength_(clip|model)-[0-9a-f]{8}", field_id)
        assert field_id not in semantics_module.INPUT_HELP
        assert field_id not in semantics_module.ROLE_HELP


def test_the_improved_vocabulary_really_says_something_else() -> None:
    """The lever the refresh tests pull, proved to move before it is used.

    An "it was refreshed" test is worthless if the vocabulary's output never
    changed: the old text and the new one would be the same string.
    """

    plan = analyse(workshop_graph())
    before = generated_help(plan)
    assert before == WORKSHOP_HELP

    with pytest.MonkeyPatch.context() as patch:
        improve_the_vocabulary(patch)
        after = generated_help(analyse(workshop_graph()))

    assert after == moved_on(WORKSHOP_HELP)
    assert set(after) == set(before), "the improvement changed which fields have one"
    for field_id, text in before.items():
        assert after[field_id] != text, field_id


# ==========================================================================
# One sync, and what is written in the file
# ==========================================================================


def test_every_sentence_in_a_generated_definition_is_this_one(
    workspace: SyncWorkspace,
) -> None:
    """The whole set, verbatim, in the file the sync actually wrote.

    Verbatim and not counted: a count of ``help`` keys passes a run that wrote
    the wrong sentence under every one of them.  Compared as a whole mapping so
    the absences are asserted in the same breath as the sentences -- a hint
    that appeared under ``mystery_dial`` fails here too.
    """

    sync_once(workspace, workshop_graph())
    definition = definition_path(workspace)

    assert help_in(definition) == WORKSHOP_HELP

    # And the loader the gateway itself runs accepts the file, so these are
    # hints a user really sees rather than a definition nothing will load.
    registry = load_registry(definition.parent)
    assert registry.diagnostics == ()
    rendered = {item.id: item.help for item in registry.workflows[0].inputs}
    assert rendered["seed"] == SEED_HELP
    assert rendered["mystery_dial"] is None


def test_a_t0097_suffixed_id_still_takes_its_input_names_sentence(
    workspace: SyncWorkspace,
) -> None:
    """The measured reason the lookup is on the input name and not the id.

    All four of these ids carry a disambiguating suffix, so a vocabulary keyed
    on the id would find none of them -- and the two ``strength_clip`` fields
    would then be as unexplained as they were before this card.  The two
    sentences differ from each other, so the test also fails a lookup that
    reached the right table and read the wrong row.
    """

    sync_once(workspace, workshop_graph())
    written = fields_in(definition_path(workspace))

    assert written["strength_clip-e727c2a7"]["help"] == STRENGTH_CLIP_HELP
    assert written["strength_clip-ed120a9b"]["help"] == STRENGTH_CLIP_HELP
    assert written["strength_model-6a581364"]["help"] == STRENGTH_MODEL_HELP
    assert written["strength_model-ba4d10db"]["help"] == STRENGTH_MODEL_HELP
    assert STRENGTH_CLIP_HELP != STRENGTH_MODEL_HELP

    # The suffixes really are there, and they really are what the binds say.
    assert written["strength_clip-e727c2a7"]["bind"] == [
        {"node": "3", "input": "strength_clip"}
    ]
    assert written["strength_model-ba4d10db"]["bind"] == [
        {"node": "2", "input": "strength_model"}
    ]


def test_a_prompt_named_by_the_wiring_gets_the_second_tables_sentence(
    workspace: SyncWorkspace,
) -> None:
    """T-0131-02, on the commonest advanced field in a real catalogue.

    Both encoders' own input is called ``text``.  What makes one of them the
    negative prompt is that its conditioning is consumed as the sampler's
    ``negative`` -- evidence in the file, which `analysis.py` reads and mints a
    role from.  No input-name table can ever answer for ``text``, so without
    the second table both of these are blank.

    The two sentences are asserted separately and are different text, so a
    swap of the two rows fails here rather than passing as "both have one".
    """

    sync_once(workspace, workshop_graph())
    written = fields_in(definition_path(workspace))

    assert written["prompt"]["help"] == PROMPT_HELP
    assert written["negative_prompt"]["help"] == NEGATIVE_PROMPT_HELP
    assert PROMPT_HELP != NEGATIVE_PROMPT_HELP

    # It really is the wiring that told them apart, and not the input name.
    assert written["prompt"]["bind"] == [{"node": "4", "input": "text"}]
    assert written["negative_prompt"]["bind"] == [{"node": "5", "input": "text"}]


def test_a_field_the_vocabulary_does_not_know_writes_no_help_key_at_all(
    workspace: SyncWorkspace,
) -> None:
    """An absence, asserted on the text on disk and not on a ``None``.

    ``help: ''`` and ``help: null`` both survive a dict-shaped assertion and
    both are wrong: the first is a blank line of muted text under the control,
    and the second the loader refuses outright.

    The absence is only meaningful once the field is shown to have reached the
    document at all, so ``mystery_dial``'s own entry is read out of the file
    first, with its type, its default and its bind -- a field that was never
    exposed would have no ``help`` either, and would be a different bug.
    """

    sync_once(workspace, workshop_graph())
    definition = definition_path(workspace)
    text = definition.read_text(encoding="utf-8")

    written = fields_in(definition)["mystery_dial"]
    assert written["type"] == "integer", "the field never reached the document"
    assert written["default"] == 3
    assert written["bind"] == [{"node": "6", "input": "mystery_dial"}]

    block = yaml_block(text, "mystery_dial")
    assert "help" not in block, block
    assert "default: 3" in block, "the wrong block was read"

    # ...while the field written directly beside it does have one, so this is
    # an absence in a file that was perfectly able to write the key.
    assert "help: " + SEED_HELP in yaml_block(text, "seed")


def test_a_suffixed_prompt_id_takes_its_input_names_sentence_and_not_the_roles(
    workspace: SyncWorkspace,
) -> None:
    """Both halves of the T-0097 suffix, in one file, in one run.

    The first half is behaviour a broader invariant once destroyed: a field
    whose graph input is literally called ``negative_prompt`` keeps its sentence
    when T-0097 gives its id a suffix, because the **input-name** table can
    still answer even though ``ROLE_HELP`` cannot.  Deleting that key -- which
    a rule about key identity rather than about sentences does -- takes the
    sentence away, and the same field with an input called ``negative`` keeps
    it, which is an arbitrary difference in the output produced by a rule about
    the table.

    The second half is T-0131-02's "exact match only": the field beside it is
    bound to ``text``, and its id is ``negative_prompt-<hash>``.  Nothing
    describes it, and nothing may guess.  A lookup that trimmed the suffix
    before consulting ``ROLE_HELP`` would write a sentence here, and would be
    asserting which of two prompts this is on the strength of a string
    operation.
    """

    sync_once(workspace, two_negative_prompts_graph())
    definition = definition_path(workspace)
    text = definition.read_text(encoding="utf-8")
    written = fields_in(definition)

    by_name = "negative_prompt-add842c8"
    by_wiring = "negative_prompt-716a0cfb"
    assert set(written) == {by_name, by_wiring, "seed"}, sorted(written)

    # Both ids really are suffixed, so neither is an exact match for a role.
    for field_id in (by_name, by_wiring):
        assert re.fullmatch(r"negative_prompt-[0-9a-f]{8}", field_id)
        assert field_id not in semantics_module.ROLE_HELP
        assert semantics_module.help_for_role(field_id) is None, (
            "the second table answered for a suffixed id"
        )

    assert written[by_name]["bind"] == [{"node": "3", "input": "negative_prompt"}]
    assert written[by_name]["help"] == NEGATIVE_PROMPT_HELP

    assert written[by_wiring]["bind"] == [{"node": "4", "input": "text"}]
    assert written[by_wiring]["type"] == "multiline", "the field never reached the file"
    assert "help" not in yaml_block(text, by_wiring), yaml_block(text, by_wiring)


def test_a_value_hash_field_gets_no_line_rather_than_a_vacuous_one(
    workspace: SyncWorkspace,
) -> None:
    """The T-0097 ids, and the one thing that cannot be said about them.

    Both of these are exposed controls with an id, a type, a default and a
    bind: they reached the document, and the vocabulary declined to describe
    them.  ``value`` is the graph's own word for both, and it means nothing.
    """

    sync_once(workspace, placeholder_graph())
    definition = definition_path(workspace)
    text = definition.read_text(encoding="utf-8")

    written = fields_in(definition)
    placeholders = sorted(item for item in written if item.startswith("value-"))
    assert len(placeholders) == 2, sorted(written)

    for field_id in placeholders:
        assert written[field_id]["type"] == "integer"
        assert written[field_id]["bind"], field_id
        assert "help" not in yaml_block(text, field_id), field_id

    # The seed in the same file has one, so silence here is a decision.
    assert written["seed"]["help"] == SEED_HELP


def test_targets_that_disagree_on_the_input_name_write_no_help(
    workspace: SyncWorkspace,
) -> None:
    """One field, two inputs, two names -- and one sentence cannot be both.

    ``seed`` and ``noise_seed`` are synonyms `docs/workflow-schema.md` names
    itself, so the two collapse into a single field with two binds.  Each name
    on its own is in the vocabulary, which is what makes the absence a
    decision: a lookup that took the first target, or the last, or the field's
    id, would write a sentence here.
    """

    sync_once(workspace, two_seeds_graph())
    definition = definition_path(workspace)

    written = fields_in(definition)["seed"]
    assert written["bind"] == [
        {"node": "3", "input": "seed"},
        {"node": "4", "input": "noise_seed"},
    ], "the two inputs did not collapse, so nothing is under test"

    # Both names would have answered, separately.
    assert semantics_module.help_for("seed") == SEED_HELP
    assert semantics_module.help_for("noise_seed") == SEED_HELP

    block = yaml_block(definition.read_text(encoding="utf-8"), "seed")
    assert "help" not in block, block
    assert "input: noise_seed" in block, "the wrong block was read"


# ==========================================================================
# A sentence somebody wrote, and a sentence nobody touched
# ==========================================================================


def test_an_untouched_sentence_is_refreshed_when_the_vocabulary_improves(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The criterion the card turns on, and it kills both rejected rules.

    "Present in the file is curated" freezes every one of these lines for ever,
    because a generated definition writes one for every field it knows.
    "Differs from what we would generate now is curated" freezes them the
    moment the vocabulary changes -- which is exactly the moment under test.
    """

    sync_once(workspace, workshop_graph())
    definition = definition_path(workspace)
    assert help_in(definition) == WORKSHOP_HELP
    assert remembered_help(workspace) == WORKSHOP_HELP

    improve_the_vocabulary(monkeypatch)
    report = sync_once(workspace, workshop_graph(steps=40))

    assert only_workflow(report).definition.written is True
    assert help_in(definition) == moved_on(WORKSHOP_HELP)
    assert help_in(definition)["seed"] == "Now we say " + SEED_HELP
    assert remembered_help(workspace) == moved_on(WORKSHOP_HELP)


def test_a_hand_written_sentence_survives_a_sync_that_rewrites_the_definition(
    workspace: SyncWorkspace,
) -> None:
    """The question a review must answer NO to, asked directly.

    ``bind`` and ``default`` are asserted as well, because "the words survived"
    would also be true of a run that wrote nothing at all -- and a run that
    wrote nothing is a different bug, not this rule.
    """

    sync_once(workspace, workshop_graph())
    definition = definition_path(workspace)
    assert fields_in(definition)["steps"]["default"] == 20

    rewrite_help(definition, {"seed": BY_HAND_SEED, "steps": BY_HAND_STEPS})

    report = sync_once(workspace, renumbered(workshop_graph(steps=40)))

    assert only_workflow(report).definition.written is True
    after = help_in(definition)
    assert after["seed"] == BY_HAND_SEED
    assert after["steps"] == BY_HAND_STEPS
    assert after["cfg"] == CFG_HELP, "a line nobody touched was not regenerated"

    # The file really was rewritten from the new graph, so the two sentences
    # above survived a regeneration rather than an absence of one.
    assert fields_in(definition)["steps"]["default"] == 40
    assert fields_in(definition)["prompt"]["bind"] == [{"node": "704", "input": "text"}]

    registry = load_registry(definition.parent)
    assert registry.diagnostics == ()
    assert {item.id: item.help for item in registry.workflows[0].inputs}["seed"] == (
        BY_HAND_SEED
    )


def test_one_curated_line_and_one_untouched_go_opposite_ways_in_one_run(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The decision is per field, in one file, in one sync.

    Both halves in a single run, so neither a rule that keeps everything nor a
    rule that keeps nothing can pass this.
    """

    sync_once(workspace, workshop_graph())
    definition = definition_path(workspace)
    rewrite_help(definition, {"seed": BY_HAND_SEED})

    improve_the_vocabulary(monkeypatch)
    sync_once(workspace, workshop_graph(steps=40))

    after = help_in(definition)
    assert after["seed"] == BY_HAND_SEED
    assert after["steps"] == "Now we say " + STEPS_HELP
    assert after["negative_prompt"] == "Now we say " + NEGATIVE_PROMPT_HELP

    # And what is remembered is what the *vocabulary* produced, never what was
    # written: remembering the curator's own words would hand them straight
    # back to the generator on the very next run.
    assert remembered_help(workspace)["seed"] == "Now we say " + SEED_HELP


def test_with_no_record_at_all_every_sentence_in_the_file_is_preserved(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Deleting the inventory forces a re-import.  It must destroy nothing.

    Two workspaces, the same scenario in both, differing in one act: one of
    them loses its inventory.  Without the control run this would prove only
    that something was preserved; with it, the deletion is shown to be the
    cause, because the run that kept its inventory refreshed the same line in
    the same sync.
    """

    kept = SyncWorkspace(tmp_path / "with the record")
    lost = SyncWorkspace(tmp_path / "without the record")

    for workspace in (kept, lost):
        sync_once(workspace, workshop_graph())
        rewrite_help(definition_path(workspace), {"seed": BY_HAND_SEED})
        assert remembered_help(workspace) == WORKSHOP_HELP

    lost.inventory_path.unlink()
    assert not lost.inventory_path.exists()

    improve_the_vocabulary(monkeypatch)
    for workspace in (kept, lost):
        sync_once(workspace, workshop_graph(steps=40))

    # The control: with the record, an untouched line followed the vocabulary.
    assert help_in(definition_path(kept))["steps"] == "Now we say " + STEPS_HELP

    # And with no record, nothing in the file was overwritten -- not the words
    # a person wrote, and not a line this run cannot prove was its own.
    without = help_in(definition_path(lost))
    assert without["seed"] == BY_HAND_SEED
    assert without["steps"] == STEPS_HELP
    assert without == dict(WORKSHOP_HELP, seed=BY_HAND_SEED)


def test_a_sentence_the_vocabulary_dropped_is_removed_and_not_left_behind(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The half of the rule that only ``help`` has, because ours may be *nothing*.

    A label always has a replacement; a hint may not.  When the vocabulary
    stops standing behind a sentence, the line it wrote last time is its own
    to withdraw -- so it goes, key and all, rather than staying in the file as
    a fossil nobody can now account for.  The curated line beside it is
    untouched by the same run, which is what makes this a withdrawal of our
    own words rather than an erasure.
    """

    sync_once(workspace, workshop_graph())
    definition = definition_path(workspace)
    rewrite_help(definition, {"steps": BY_HAND_STEPS})
    assert help_in(definition)["seed"] == SEED_HELP

    thinner = dict(semantics_module.INPUT_HELP)
    del thinner["seed"]
    monkeypatch.setattr(semantics_module, "INPUT_HELP", thinner)

    sync_once(workspace, workshop_graph(steps=40))

    text = definition.read_text(encoding="utf-8")
    assert "help" not in yaml_block(text, "seed"), yaml_block(text, "seed")
    assert help_in(definition)["steps"] == BY_HAND_STEPS
    assert "seed" not in remembered_help(workspace)


# ==========================================================================
# The record: written, read back, and never in the definition
# ==========================================================================


def test_a_curator_who_empties_a_hint_has_switched_it_off_for_good(
    workspace: SyncWorkspace,
) -> None:
    """``help: ''`` is a curator's edit, and it survives every later run.

    The loader accepts an empty ``help`` and the app renders nothing for one,
    so deleting the words is the way a person switches a hint off without
    deleting the field.  The generator never produces an empty sentence, so an
    empty one in the file can only be theirs.

    Two halves, and they catch different mistakes.  Naming the wrong one for a
    half would be worse than saying nothing, so each is stated against the
    change it actually fails on:

    * **the key present and empty in the YAML text, after the first sync that
      follows the edit.**  This is where ``if help_text is not None`` tidied
      into ``if help_text`` dies, immediately: the key is dropped, and the file
      stops saying that anybody switched anything off.  The assertion is on the
      text rather than on the parsed document, because a dropped key and an
      empty one are the same ``None`` once a caller stops being careful.
    * **the second sync, and the key still empty.**  This is where a record
      that advanced to the *curator's* text instead of the vocabulary's dies.
      Such a record would say "we generated an empty sentence last time", the
      file would agree with it, the emptied hint would read as ours rather than
      theirs, and the words would be written back -- one run later than the
      edit, which is what makes that failure quiet.  The message on that
      assertion says so: "an emptied hint came back on the next sync".

    Neither half stands in for the other, and the second one is not decoration.
    """

    sync_once(workspace, workshop_graph())
    definition = definition_path(workspace)
    assert help_in(definition)["seed"] == SEED_HELP
    assert remembered_help(workspace)["seed"] == SEED_HELP

    rewrite_help(definition, {"seed": ""})
    sync_once(workspace, workshop_graph(steps=40))

    block = yaml_block(definition.read_text(encoding="utf-8"), "seed")
    assert "help: ''" in block, block
    assert fields_in(definition)["seed"]["help"] == ""

    # The run that would undo it, if the key had been dropped above.
    sync_once(workspace, workshop_graph(steps=50))
    assert fields_in(definition)["seed"]["help"] == "", (
        "an emptied hint came back on the next sync"
    )
    assert "help: ''" in yaml_block(definition.read_text(encoding="utf-8"), "seed")

    # ...and the field beside it is untouched, so this is a curator's edit being
    # honoured rather than the vocabulary having stopped writing anything.
    assert fields_in(definition)["steps"]["help"] == STEPS_HELP

    # The loader still accepts the file, so an emptied hint is a definition a
    # user can actually run rather than one the gateway refuses.
    registry = load_registry(definition.parent)
    assert registry.diagnostics == ()
    assert {item.id: item.help for item in registry.workflows[0].inputs}["seed"] == ""


def test_the_record_round_trips_through_the_inventory_on_disk(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Asserted on the written JSON key, then proved to be read back.

    Two halves, because either alone is weak.  The first reads the key out of
    the file the sync wrote, so the serialisation is what is under test rather
    than an object in memory.  The second edits that file by hand and runs
    again: a reader that ignored the key would refresh the line the record now
    disagrees with, and a reader that ignored the key's *absence* would
    overwrite the one it says nothing about.
    """

    sync_once(workspace, workshop_graph())
    definition = definition_path(workspace)

    document = json.loads(workspace.inventory_path.read_text(encoding="utf-8"))
    entry = document["workflows"][0]
    assert "generated_help" in entry, sorted(entry)
    assert entry["generated_help"] == WORKSHOP_HELP
    assert "mystery_dial" not in entry["generated_help"], (
        "a field with no sentence was recorded as having one"
    )

    # Rewrite the record by hand so that it no longer describes ``seed`` at
    # all, and so that it claims something else entirely for ``steps``.  The
    # file itself is untouched.
    del entry["generated_help"]["seed"]
    entry["generated_help"]["steps"] = "Something no vocabulary ever produced."
    workspace.inventory_path.write_text(json.dumps(document), encoding="utf-8")

    improve_the_vocabulary(monkeypatch)
    sync_once(workspace, workshop_graph(steps=40))

    after = help_in(definition)
    assert after["seed"] == SEED_HELP, "an absent record was not read as absent"
    assert after["steps"] == STEPS_HELP, "a record that disagrees was not read"
    assert after["cfg"] == "Now we say " + CFG_HELP, (
        "the readable, agreeing part of the record was thrown away with the rest"
    )


def test_a_record_value_that_is_not_a_sentence_is_dropped_and_never_coerced(
    workspace: SyncWorkspace,
) -> None:
    """A record this cannot read is a record this does not have.

    Anything but a string keyed by a string cannot have come from this
    importer, which only ever records the text it generated -- so believing it
    could only ever hand somebody's own words back to the generator.  The
    readable half of the same record still works, so the drop is per entry and
    not per file.
    """

    sync_once(workspace, workshop_graph())
    definition = definition_path(workspace)

    document = json.loads(workspace.inventory_path.read_text(encoding="utf-8"))
    document["workflows"][0]["generated_help"]["seed"] = 40
    workspace.inventory_path.write_text(json.dumps(document), encoding="utf-8")

    rewrite_help(definition, {"seed": BY_HAND_SEED})
    sync_once(workspace, workshop_graph(steps=40))

    after = help_in(definition)
    assert after["seed"] == BY_HAND_SEED, "a record that is not a sentence was believed"
    assert after["steps"] == STEPS_HELP, (
        "the readable half of the record was thrown away with the unreadable half"
    )


def test_the_record_never_reaches_the_definition(workspace: SyncWorkspace) -> None:
    """An absence, after showing there was something present to leak.

    The schema rejects every key it does not know, so a record written *into*
    the definition would be refused by the loader and nothing would be written
    at all -- "the text does not contain it" would then be true of a run that
    failed.  So the written flag is asserted first, and the record is shown to
    be non-empty in the inventory.
    """

    sync_once(workspace, workshop_graph())
    rewrite_help(definition_path(workspace), {"seed": BY_HAND_SEED})
    report = sync_once(workspace, workshop_graph(steps=40))

    item = only_workflow(report)
    assert item.definition.problem is None
    assert item.definition.written is True
    assert remembered_help(workspace), "there was no record for the definition to leak"

    text = definition_path(workspace).read_text(encoding="utf-8")
    assert "generated_help" not in text


def test_the_record_follows_the_file_and_not_the_run(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The record describes the file on disk, whichever run put it there.

    Before T-0246 an unchanged workflow kept its definition whatever this run
    would now generate, and this test held that such a skip left the record
    alone.  T-0246 reverses the premise: the same bytes with an improved
    vocabulary now write the definition again -- so the invariant underneath
    is asserted on that rewrite instead: the lines refreshed, and the record
    moved with them, never ahead of the file or behind it.
    """

    sync_once(workspace, workshop_graph())
    definition = definition_path(workspace)
    before = definition.read_bytes()

    improve_the_vocabulary(monkeypatch)

    report = sync_once(workspace, workshop_graph())
    item = only_workflow(report)
    assert item.state is WorkflowState.UNCHANGED
    assert item.definition.written is True
    assert definition.read_bytes() != before
    assert help_in(definition) == moved_on(WORKSHOP_HELP)
    assert remembered_help(workspace) == moved_on(WORKSHOP_HELP), (
        "the record did not follow the file it describes"
    )

    # Now the workflow really changes, and the untouched lines must still
    # refresh -- which they cannot if the run above overwrote the record.
    sync_once(workspace, workshop_graph(steps=40))
    assert help_in(definition) == moved_on(WORKSHOP_HELP)


# ==========================================================================
# Determinism
# ==========================================================================


def test_the_hints_add_no_churn_to_the_yaml_or_to_the_inventory(
    tmp_path: Path,
) -> None:
    """The same scenario twice, in two workspaces, byte for byte.

    A definition promises that two runs over the same bytes produce identical
    YAML.  A second table read back through a mapping is exactly the sort of
    thing that can reorder ``inputs`` between runs, so the whole scenario --
    generate, curate, regenerate -- is played out twice and compared as bytes,
    and the stored record as *text*, so a different key order fails rather than
    compares equal.
    """

    produced: List[bytes] = []
    stored: List[str] = []
    for name in ("first time", "second time"):
        workspace = SyncWorkspace(tmp_path / name)
        sync_once(workspace, workshop_graph())
        rewrite_help(definition_path(workspace), {"seed": BY_HAND_SEED})
        sync_once(workspace, renumbered(workshop_graph(steps=40)))
        produced.append(definition_path(workspace).read_bytes())
        stored.append(json.dumps(remembered_help(workspace)))

    assert produced[0] == produced[1]
    assert stored[0] == stored[1]
    assert json.loads(stored[0]) == WORKSHOP_HELP

    # And a third run over the very same bytes leaves the file alone entirely.
    workspace = SyncWorkspace(tmp_path / "third time")
    sync_once(workspace, workshop_graph())
    rewrite_help(definition_path(workspace), {"seed": BY_HAND_SEED})
    sync_once(workspace, renumbered(workshop_graph(steps=40)))
    settled = definition_path(workspace).read_bytes()
    sync_once(workspace, renumbered(workshop_graph(steps=40)))
    assert definition_path(workspace).read_bytes() == settled


def test_the_hint_changes_the_help_and_nothing_else_in_the_document() -> None:
    """A differential between the two code paths, not a claim about one.

    The same plan and the same curated file are rendered twice: once the way
    the document was built before this record existed (``remembered_help``
    absent), once with it.  Every part of every field except ``help`` must come
    out identical -- and the hints must differ, or the comparison is vacuous.
    """

    plan = analyse(workshop_graph())
    curated = definitions_module.CuratedDefinition(
        document={
            "name": "Evening portraits",
            "inputs": [
                # One the curator wrote, one an older vocabulary wrote.
                {"id": "seed", "label": "Seed", "help": BY_HAND_SEED},
                {"id": "steps", "label": "Steps", "help": "An older sentence."},
            ],
        }
    )
    #: What that older vocabulary recorded: 'An older sentence.' was its own
    #: work, and today's seed line is what it wrote where the curator has since
    #: typed their own.
    record = dict(WORKSHOP_HELP, steps="An older sentence.")

    def build(remembered: Optional[Mapping[str, str]]) -> Dict[str, Any]:
        return definitions_module.definition_document(
            plan,
            workflow_id="one",
            name="One",
            workflow_relative="g.json",
            curated=curated,
            remembered_help=remembered,
        )

    without = build(None)
    with_record = build(record)

    def unhinted(document: Dict[str, Any]) -> Dict[str, Any]:
        copy = dict(document)
        copy["inputs"] = [
            {key: value for key, value in item.items() if key != "help"}
            for item in document["inputs"]
        ]
        return copy

    assert unhinted(without) == unhinted(with_record)
    assert list(without) == list(with_record), "the key order moved"

    # Not vacuous: the two differ, and only in a hint.  With no record the
    # file's older sentence is preserved because nothing proves it was ours;
    # with the record it matches what we wrote last time and refreshes.
    hints_without = {
        item["id"]: item.get("help") for item in without["inputs"]
    }
    hints_with = {item["id"]: item.get("help") for item in with_record["inputs"]}
    assert hints_without != hints_with
    assert hints_without["steps"] == "An older sentence."
    assert hints_with["steps"] == STEPS_HELP
    assert hints_without["seed"] == hints_with["seed"] == BY_HAND_SEED
