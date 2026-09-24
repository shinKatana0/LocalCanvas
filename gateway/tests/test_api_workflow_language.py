# -*- coding: utf-8 -*-
"""The generated hints, served in the language the app asked for (T-0143).

T-0131 gave every advanced control a one-line hint from a vocabulary of 33
sentences.  They were written in English, and T-0142 is putting a Russian
interface around them -- so without this the app would say "Резкость" over
"How much extra edge definition to add", which delivers the shell of that card
and not its point.

**Two sentences look identical in a definition file** and must be treated as
opposites: one the importer generated, which is this project's prose and may be
said in another language, and one a curator typed, which is the user's own
words and may not be touched in any language at all.  The file does not record
which is which.  The gateway works it out: a hint is generated **if and only if
it is exactly what the English vocabulary would produce for that field**, from
the field's own ``bind`` and its id.  Everything here is a question about that
rule.

Every sentence below is written out.  Nothing is imported from
`semantics.py` and nothing is derived from the fixture, because a test that
asked the module what it says would agree with whatever the module said -- and
what is being asserted is what a phone receives.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any, Dict

# --------------------------------------------------------------------------
# The sentences, spelled out
# --------------------------------------------------------------------------

SEED_EN = "The starting point for the randomness. The same number repeats a result."
SEED_RU = "Отправная точка для случайности. То же число повторяет тот же результат."

CFG_EN = "How closely your words are followed. Too high looks harsh and overcooked."
CFG_RU = "Насколько точно выполняются ваши слова. Перебор делает картинку контрастной и грубой."

STRENGTH_CLIP_EN = "How strongly the add-on changes the way your words are read."
STRENGTH_CLIP_RU = "Насколько сильно дополнение меняет прочтение ваших слов."

PROMPT_EN = "Describe what you want to see. More detail gives more to go on."
PROMPT_RU = "Опишите, что хотите увидеть. Чем больше подробностей, тем лучше."

NEGATIVE_EN = "What to keep out of the result. Leave it empty if nothing comes to mind."
NEGATIVE_RU = (
    "Что не должно попасть в результат. Оставьте пустым, если ничего не приходит на ум."
)

WIDTH_EN = "How wide the result is, in pixels. Bigger costs more time and memory."

#: What a curator wrote, in two languages, and neither of them is anything the
#: vocabulary would ever produce.  Both are checked in **both** locales: the
#: English one must survive a Russian request, and the Russian one must survive
#: an English request, which is the direction that catches a rule written as
#: "translate unless it is already Russian".
CURATED_EN = "Leave this at twenty unless the picture looks unfinished."
CURATED_RU = "Оставьте двадцать, если картинка не выглядит незаконченной."

#: The T-0097 shape: one role covering two controls the wiring tells apart, so
#: the id carries a disambiguating suffix and only the *input name* can answer.
SUFFIXED_ID = "strength_clip-e727c2a7"


# --------------------------------------------------------------------------
# The graph and the definition
# --------------------------------------------------------------------------

#: Node types that exist nowhere else, and not one model, family or vendor
#: name.
LANGUAGE_GRAPH: Dict[str, Any] = {
    "10": {"class_type": "ExampleLoader", "inputs": {"name": "PLACEHOLDER"}},
    "20": {
        "class_type": "ExampleTextEncoder",
        "inputs": {"text": "placeholder", "model": ["10", 0]},
    },
    "21": {
        "class_type": "ExampleTextEncoder",
        "inputs": {"text": "placeholder", "model": ["10", 0]},
    },
    "30": {
        "class_type": "ExampleSampler",
        "inputs": {
            "seed": 0,
            "steps": 20,
            "cfg": 6.0,
            "batch_size": 1,
            "mystery_dial": 3,
            "positive": ["20", 0],
            "negative": ["21", 0],
        },
    },
    "31": {
        "class_type": "ExampleAdapter",
        "inputs": {"strength_clip": 0.8, "strength_model": 0.8},
    },
    "50": {"class_type": "ExampleLatent", "inputs": {"width": 512, "height": 512}},
}

#: One field per question this file asks, and the ``help`` values are the ones
#: that would really be on disk: the vocabulary's English under the generated
#: ones, a person's own words under the curated ones, and no key at all under
#: the field the vocabulary does not know.
LANGUAGE_FIELDS = """
- id: prompt
  label: Prompt
  type: multiline
  required: true
  help: "Describe what you want to see. More detail gives more to go on."
  bind:
    node: "20"
    input: text

- id: negative_prompt
  label: Negative prompt
  type: multiline
  section: advanced
  help: "What to keep out of the result. Leave it empty if nothing comes to mind."
  bind:
    node: "21"
    input: text

- id: seed
  label: Seed
  type: integer
  default: 0
  section: advanced
  help: "The starting point for the randomness. The same number repeats a result."
  bind:
    node: "30"
    input: seed

- id: cfg
  label: Cfg
  type: float
  default: 6.0
  section: advanced
  help: "How closely your words are followed. Too high looks harsh and overcooked."
  bind:
    node: "30"
    input: cfg

- id: strength_clip-e727c2a7
  label: Strength clip
  type: float
  default: 0.8
  section: advanced
  help: "How strongly the add-on changes the way your words are read."
  bind:
    node: "31"
    input: strength_clip

- id: mystery_dial
  label: Mystery dial
  type: integer
  default: 3
  section: advanced
  bind:
    node: "30"
    input: mystery_dial

- id: steps
  label: Steps
  type: integer
  default: 20
  section: advanced
  help: "Leave this at twenty unless the picture looks unfinished."
  bind:
    node: "30"
    input: steps

- id: batch_size
  label: Batch size
  type: integer
  default: 1
  section: advanced
  help: "Оставьте двадцать, если картинка не выглядит незаконченной."
  bind:
    node: "30"
    input: batch_size

- id: size
  label: Size
  type: integer
  default: 512
  section: advanced
  help: "Оставьте двадцать, если картинка не выглядит незаконченной."
  bind:
    - {node: "50", input: width}
    - {node: "50", input: height}
"""

PRESENTATION = """
group: Create
category: Example
short_description: A test workflow.
input_summary: Prompt only
how_to_use: Type a prompt and press Generate.
"""


def build(gateway_factory, builder):
    builder.add(
        "flow",
        LANGUAGE_FIELDS,
        presentation=PRESENTATION,
        graph=json.loads(json.dumps(LANGUAGE_GRAPH)),
    )
    return gateway_factory()


def detail(harness, language=None) -> Dict[str, Any]:
    """``GET /api/v1/workflows/flow``, with the header only when given."""

    headers = {} if language is None else {"Accept-Language": language}
    response = harness.client.get("/api/v1/workflows/flow", headers=headers)
    assert response.status_code == 200, response.text
    return response.json()


def hints(body: Dict[str, Any]) -> Dict[str, str]:
    """``{field id: help}`` for the fields that carry one, and only those.

    A field with no ``help`` key is simply absent, so ``==`` against a table
    asserts the sentences and the silences in one comparison.
    """

    return {
        field["id"]: field["help"] for field in body["inputs"] if "help" in field
    }


def digest(root: Path) -> Dict[str, str]:
    """Every file under a directory, by content hash.

    Not a modification time: a rewrite with identical bytes is not a change,
    and a rewrite within the same clock tick is.
    """

    return {
        str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(root.rglob("*"))
        if path.is_file()
    }


# ==========================================================================
# The fixture, measured, so every assertion below means something
# ==========================================================================


def test_the_definition_on_disk_is_the_one_these_tests_are_written_about(
    gateway_factory, builder
) -> None:
    """What the file really carries, before any question about language.

    Without this, "the Russian arrives" could be satisfied by a fixture that
    was already Russian, and "a curated line is untouched" by a field that has
    no hint at all.  Both are stated here as facts about the definition the
    registry loaded, in English, from the bytes on disk.
    """

    harness = build(gateway_factory, builder)
    body = detail(harness)

    assert hints(body) == {
        "prompt": PROMPT_EN,
        "negative_prompt": NEGATIVE_EN,
        "seed": SEED_EN,
        "cfg": CFG_EN,
        SUFFIXED_ID: STRENGTH_CLIP_EN,
        "steps": CURATED_EN,
        "batch_size": CURATED_RU,
        "size": CURATED_RU,
    }
    assert "mystery_dial" in [field["id"] for field in body["inputs"]]

    # The suffixed id really is suffixed, so the test below about it is about
    # the property T-0131 nearly lost and not about an ordinary field.
    assert SUFFIXED_ID.startswith("strength_clip-")
    assert len(SUFFIXED_ID.split("-")[1]) == 8

    # And the curated sentences are nothing the vocabulary could produce, so
    # "it was left alone" cannot be confused with "it was translated back".
    for curated in (CURATED_EN, CURATED_RU):
        assert curated not in (SEED_EN, SEED_RU, CFG_EN, CFG_RU, PROMPT_EN, PROMPT_RU)


# ==========================================================================
# The four locales
# ==========================================================================


def test_a_request_for_russian_gets_the_russian_sentences(
    gateway_factory, builder
) -> None:
    """Every generated hint, verbatim, in Russian -- and nothing else moved.

    The whole table is compared at once rather than one sentence at a time, so
    a rule that translated too much fails here as loudly as one that
    translated too little.
    """

    harness = build(gateway_factory, builder)

    assert hints(detail(harness, "ru")) == {
        "prompt": PROMPT_RU,
        "negative_prompt": NEGATIVE_RU,
        "seed": SEED_RU,
        "cfg": CFG_RU,
        SUFFIXED_ID: STRENGTH_CLIP_RU,
        "steps": CURATED_EN,
        "batch_size": CURATED_RU,
        "size": CURATED_RU,
    }


def test_a_request_for_english_gets_the_english_sentences(
    gateway_factory, builder
) -> None:
    """The header naming the language the file is already in changes nothing."""

    harness = build(gateway_factory, builder)

    assert hints(detail(harness, "en")) == {
        "prompt": PROMPT_EN,
        "negative_prompt": NEGATIVE_EN,
        "seed": SEED_EN,
        "cfg": CFG_EN,
        SUFFIXED_ID: STRENGTH_CLIP_EN,
        "steps": CURATED_EN,
        "batch_size": CURATED_RU,
        "size": CURATED_RU,
    }


def test_a_language_the_gateway_does_not_have_gets_english_and_not_an_error(
    gateway_factory, builder
) -> None:
    """`docs/api.md`'s promise: English, never a 406 and never an empty string.

    An empty string would be worse than English rather than better: the app
    renders a hint only when it is non-empty, so the control would arrive as a
    bare ComfyUI word with nothing under it -- the exact state T-0131 existed
    to end -- and nothing would have failed anywhere to say so.

    The spellings here are the ones a real client sends by accident: a
    language nobody has written, a regioned tag, a quality list, and an empty
    header.  `docs/api.md` promises a bare tag and answers everything else in
    English rather than guessing.
    """

    harness = build(gateway_factory, builder)
    english = hints(detail(harness, "en"))
    assert english["seed"] == SEED_EN

    for header in ("fr", "ja", "ru-RU", "ru;q=0.9,en;q=0.8", "ru,en", "", "  ", "zz"):
        served = hints(detail(harness, header))
        assert served == english, header
        assert served["seed"] == SEED_EN, header
        assert served["seed"] != "", header


def test_a_request_with_no_header_at_all_gets_exactly_what_it_gets_today(
    gateway_factory, builder
) -> None:
    """The compatibility claim of `docs/versioning.md`, pinned.

    An app built before this card sends no ``Accept-Language``, and the answer
    it gets has to be the answer it got yesterday -- which is why
    ``api_version`` does not move.  Pinned against the whole body rather than
    against the hints, so a key added, dropped or reordered by the localising
    path fails here too, and pinned as **bytes** so that "identical" means
    identical.
    """

    harness = build(gateway_factory, builder)

    bare = harness.client.get("/api/v1/workflows/flow")
    english = harness.client.get(
        "/api/v1/workflows/flow", headers={"Accept-Language": "en"}
    )
    assert bare.status_code == 200, bare.text
    assert bare.content == english.content

    body = bare.json()
    assert list(body) == ["id", "name", "presentation", "required_media", "inputs", "input_summary"]
    assert body["id"] == "flow"
    assert body["presentation"] == {
        "group": "Create",
        "category": "Example",
        "short_description": "A test workflow.",
        "how_to_use": "Type a prompt and press Generate.",
        "input_summary": "Prompt only",
    }
    assert body["inputs"][2] == {
        "id": "seed",
        "label": "Seed",
        "type": "integer",
        "required": False,
        "section": "advanced",
        "default": 0,
        "help": SEED_EN,
    }

    # And the number that decides whether an app and a gateway talk at all has
    # not moved, because nothing above broke.
    info = harness.client.get("/api/v1/info").json()
    assert info["api_version"] == 1


# ==========================================================================
# The curator's words
# ==========================================================================


def test_a_curated_hint_is_served_untouched_in_every_locale(
    gateway_factory, builder
) -> None:
    """The rule that does not bend: if the curator wrote it, serve it.

    ``steps`` carries a sentence a person typed, and the vocabulary has an
    entry for ``steps`` -- so this is not "there was nothing to translate", it
    is the gateway declining to translate something it could have.  Asserted
    in every locale the gateway can be asked for, including ones it does not
    have.
    """

    harness = build(gateway_factory, builder)

    for header in (None, "en", "ru", "fr", "ru-RU"):
        served = hints(detail(harness, header))
        assert served["steps"] == CURATED_EN, header


def test_a_curated_russian_hint_is_served_untouched_when_english_is_asked_for(
    gateway_factory, builder
) -> None:
    """The direction that catches "translate unless it is already Russian".

    ``batch_size`` carries a Russian sentence a curator wrote, and the
    vocabulary has an English entry for ``batch_size``.  A rule that decided
    what to serve from the *language of the text* rather than from **who wrote
    it** would replace this with the English line the moment an English client
    asked -- silently rewriting somebody's own words into words this project
    chose.
    """

    harness = build(gateway_factory, builder)

    for header in (None, "en", "ru", "fr"):
        served = hints(detail(harness, header))
        assert served["batch_size"] == CURATED_RU, header


def test_a_hint_the_vocabulary_has_since_reworded_falls_back_to_the_file(
    gateway_factory, builder, monkeypatch
) -> None:
    """The fifth fallback case, pinned rather than left to be discovered.

    The gateway recognises a generated hint by asking what the vocabulary says
    **now**; the definition was written by whatever it said **then**.  So
    improving one English sentence stops that one line matching in every
    catalogue already on disk, and it is served in English until the next
    import -- the same act that would have refreshed the English.

    That is a genuine cost of choosing recomputation over a record of what the
    last sync wrote, and it is the better half of the trade: the record would
    have served the *new* Russian beside the *old* English. It is documented
    in `docs/api.md` as a fallback case, and this is what stops it being
    rediscovered as a bug.

    The vocabulary is genuinely moved on rather than simulated, exactly as
    T-0131 proves an improved sentence reaches an existing catalogue -- and
    the control is the whole point: ``seed``, whose sentence did not move, is
    still Russian in the same response, so this is one line falling back and
    not localisation switching off.
    """

    from localcanvas_gateway.workflows.sync import semantics

    harness = build(gateway_factory, builder)
    assert hints(detail(harness, "ru"))["cfg"] == CFG_RU, "the control never held"

    improved = dict(semantics.INPUT_HELP)
    improved["cfg"] = "A better sentence about this control than the last one."
    assert improved["cfg"] != semantics.INPUT_HELP["cfg"]
    monkeypatch.setattr(semantics, "INPUT_HELP", improved)

    served = hints(detail(harness, "ru"))
    assert served["cfg"] == CFG_EN, "the file's own line is what must be served"
    assert served["seed"] == SEED_RU, "only the reworded line may fall back"

    # And the file is untouched, so re-running the importer is what fixes it.
    text = (builder.root / "flow.yaml").read_text(encoding="utf-8")
    assert CFG_EN in text
    assert improved["cfg"] not in text


def test_a_field_whose_targets_disagree_keeps_whatever_the_file_says(
    gateway_factory, builder
) -> None:
    """One field driving two differently-named inputs is nobody's generated line.

    ``size`` writes into ``width`` and ``height``.  Each of those names has a
    sentence of its own and the two say different things, so no single
    sentence is honestly this field's -- which is why the importer writes none,
    and why anything found there was written by a person and is served
    untouched.

    The two names really would have answered separately, which is asserted by
    serving a definition that binds one of them alone.
    """

    harness = build(gateway_factory, builder)

    for header in (None, "en", "ru"):
        assert hints(detail(harness, header))["size"] == CURATED_RU, header

    # ``width`` alone is answered, and by a sentence that is not ``height``'s,
    # so the silence above is the disagreement rule rather than an unknown
    # name.
    builder.add(
        "solo",
        """
        - id: width
          label: Width
          type: integer
          default: 512
          section: advanced
          help: "How wide the result is, in pixels. Bigger costs more time and memory."
          bind:
            node: "50"
            input: width
        """,
        graph=json.loads(json.dumps(LANGUAGE_GRAPH)),
    )
    solo = gateway_factory()
    body = solo.client.get(
        "/api/v1/workflows/solo", headers={"Accept-Language": "ru"}
    ).json()
    served = {field["id"]: field.get("help") for field in body["inputs"]}
    assert served["width"] == "Какой ширины будет результат в пикселях. Больше — дольше и больше памяти."
    assert served["width"] != WIDTH_EN


# ==========================================================================
# Silence
# ==========================================================================


def test_a_field_the_vocabulary_does_not_know_still_has_no_help_key_at_all(
    gateway_factory, builder
) -> None:
    """Silence is still the specified output, in both languages.

    ``mystery_dial`` reached the response -- its type, its default and its
    section are read out first, so this is a field that is really there --
    and it carries no ``help`` key.  Not an empty string, which the app would
    render as a blank line under the control, and not a key at all, which is
    what `docs/workflow-schema.md` means by an absent hint.
    """

    harness = build(gateway_factory, builder)

    for header in (None, "en", "ru", "fr"):
        body = detail(harness, header)
        found = [field for field in body["inputs"] if field["id"] == "mystery_dial"]
        assert len(found) == 1, header
        field = found[0]
        assert field["type"] == "integer", header
        assert field["default"] == 3, header
        assert field["section"] == "advanced", header
        assert "help" not in field, (header, field)


# ==========================================================================
# The two shapes T-0131 nearly lost
# ==========================================================================


def test_a_suffixed_id_resolves_through_its_input_name_in_both_languages(
    gateway_factory, builder
) -> None:
    """T-0097's ``strength_clip-<hash>``, which no table holds as a key.

    Its sentence can only have come from the graph's own input name, read off
    the field's ``bind``.  A serving path that looked the field **id** up
    would find nothing here and would serve English forever -- for exactly the
    fields where one role covers two controls, which is the case the
    input-name rule exists for.
    """

    harness = build(gateway_factory, builder)

    assert hints(detail(harness, "en"))[SUFFIXED_ID] == STRENGTH_CLIP_EN
    assert hints(detail(harness, "ru"))[SUFFIXED_ID] == STRENGTH_CLIP_RU
    assert STRENGTH_CLIP_EN != STRENGTH_CLIP_RU


def test_both_prompt_roles_resolve_in_both_languages(
    gateway_factory, builder
) -> None:
    """The two fields named by the wiring rather than by an input.

    Both prompts' own graph input is called ``text``, which no input-name
    table may ever hold, because it is equally the other one's.  They are
    answered by the role in the field's id -- and the two sentences are
    asserted to differ from each other in both languages, so a lookup that
    found the right table and the wrong row fails as well.
    """

    harness = build(gateway_factory, builder)

    english = hints(detail(harness, "en"))
    russian = hints(detail(harness, "ru"))

    assert english["prompt"] == PROMPT_EN
    assert english["negative_prompt"] == NEGATIVE_EN
    assert russian["prompt"] == PROMPT_RU
    assert russian["negative_prompt"] == NEGATIVE_RU

    assert PROMPT_EN != NEGATIVE_EN
    assert PROMPT_RU != NEGATIVE_RU


# ==========================================================================
# What must not happen
# ==========================================================================


def test_serving_a_catalogue_in_two_languages_writes_nothing_to_disk(
    gateway_factory, builder
) -> None:
    """Nothing on the user's disk changes, which is the card's hard constraint.

    The whole registry root is hashed by content before any request and after
    a Russian one, an English one and a Russian one again.  The substitution
    happens on the way out and touches no file, so the definitions a curator
    opens are the definitions they wrote -- still carrying the English line,
    still valid, still the same bytes.
    """

    harness = build(gateway_factory, builder)
    root = builder.root
    before = digest(root)
    assert before, "the registry root is empty, so this would assert nothing"
    assert any(name.endswith(".yaml") for name in before), sorted(before)

    assert hints(detail(harness, "ru"))["seed"] == SEED_RU
    assert hints(detail(harness, "en"))["seed"] == SEED_EN
    assert hints(detail(harness, "ru"))["seed"] == SEED_RU

    assert digest(root) == before


def test_the_curator_prose_in_the_picker_is_never_translated(
    gateway_factory, builder
) -> None:
    """The presentation block is the user's content and is out of scope forever.

    ``name``, ``short_description``, ``how_to_use``, ``input_summary`` -- all
    of it is what the curator wrote about their own workflow, and no locale
    changes any of it.  Asserted on both endpoints, because the picker reads
    the list and the detail view repeats it.
    """

    harness = build(gateway_factory, builder)

    for header in (None, "en", "ru"):
        headers = {} if header is None else {"Accept-Language": header}
        listed = harness.client.get("/api/v1/workflows", headers=headers).json()
        entry = listed["workflows"][0]
        assert entry["name"] == "Test Workflow", header
        assert entry["input_summary"] == "Prompt only", header
        assert entry["presentation"]["short_description"] == "A test workflow.", header
        assert entry["presentation"]["how_to_use"] == "Type a prompt and press Generate.", header

        body = detail(harness, header)
        assert body["name"] == "Test Workflow", header
        assert body["presentation"]["how_to_use"] == "Type a prompt and press Generate.", header


def test_the_labels_are_not_translated_either(gateway_factory, builder) -> None:
    """Only ``help`` moves, and only where the vocabulary wrote it.

    A field's ``label`` is the curator's word for the control -- generated at
    first import and then theirs to change (T-0110) -- and this card says
    nothing about it.  Stated as a test rather than as an intention, because
    "translate the field" is a one-word change away from "translate the hint".
    """

    harness = build(gateway_factory, builder)

    russian = {field["id"]: field["label"] for field in detail(harness, "ru")["inputs"]}
    english = {field["id"]: field["label"] for field in detail(harness, "en")["inputs"]}

    assert russian == english
    assert russian["seed"] == "Seed"
    assert russian["cfg"] == "Cfg"


# ==========================================================================
# The header itself
# ==========================================================================


def test_the_header_is_read_as_one_bare_tag_and_case_is_forgiven() -> None:
    """``requested_language``, on its own, against what a client really sends.

    HTTP language tags are case-insensitive, so ``RU`` is Russian.  Nothing
    else is forgiven: `docs/api.md` promises a bare tag, and everything that
    is not one is answered in English rather than guessed at -- which is one
    rule for "we do not speak it" and "that is not a tag we promised to
    parse".
    """

    from localcanvas_gateway.api.workflows import ENGLISH, requested_language

    class Fake:
        def __init__(self, value):
            self.headers = {} if value is None else {"accept-language": value}

    assert requested_language(Fake(None)) == ENGLISH
    assert requested_language(Fake("")) == ENGLISH
    assert requested_language(Fake("   ")) == ENGLISH
    assert requested_language(Fake("en")) == ENGLISH
    assert requested_language(Fake("ru")) == "ru"
    assert requested_language(Fake("RU")) == "ru"
    assert requested_language(Fake(" ru ")) == "ru"
    assert requested_language(Fake("Ru")) == "ru"
    # Not a bare tag, so not something this contract undertakes to read.
    assert requested_language(Fake("ru-RU")) == "ru-ru"
    assert requested_language(Fake("ru;q=0.9,en")) == "ru;q=0.9,en"


def test_the_serving_path_and_the_vocabulary_agree_on_what_english_is() -> None:
    """One string, in two modules, asserted equal rather than assumed.

    ``api/workflows.py`` keeps its own ``ENGLISH`` so that an English request
    never has to import the importer to find out that it is English.  That is
    a copy, and a copy is only safe while something fails when the two drift.
    """

    from localcanvas_gateway.api.workflows import ENGLISH
    from localcanvas_gateway.workflows.sync import semantics

    assert ENGLISH == semantics.DEFAULT_HELP_LANGUAGE
    assert ENGLISH in semantics.HELP_LANGUAGES
    assert "ru" in semantics.HELP_LANGUAGES


def test_asking_for_a_workflow_in_english_never_loads_the_importer() -> None:
    """``workflows/sync`` is a curator tool, and the gateway does not run it.

    Its own docstring holds it to "starting the gateway does not load a line of
    it", and ``workflows/cli.py`` already imports it from outside the
    subpackage inside the function that needs it.  The localising path is the
    same shape, so a gateway nobody asks in another language still loads none
    of it -- and this asserts that rather than trusting the comment saying so.

    **Both halves are measured in one fresh interpreter**, because either
    alone is worthless: a serving path that had quietly stopped localising
    would satisfy "not loaded" perfectly.  So the probe asks the question
    twice -- once after the application is assembled, once after the
    localising function has actually run -- and the two answers must differ.
    """

    import subprocess
    import sys

    gateway_root = Path(__file__).resolve().parents[1]
    probe = (
        "import sys\n"
        "import localcanvas_gateway\n"
        "from localcanvas_gateway.api import create_app\n"
        "from localcanvas_gateway.api.workflows import _localised\n"
        "print(localcanvas_gateway.__file__)\n"
        "print('localcanvas_gateway.workflows.sync' in sys.modules)\n"
        "class Nothing:\n"
        "    def bindings_for(self, field_id):\n"
        "        return ()\n"
        "_localised(Nothing(), [], 'ru')\n"
        "print('localcanvas_gateway.workflows.sync' in sys.modules)\n"
    )
    finished = subprocess.run(
        [sys.executable, "-c", probe],
        capture_output=True,
        text=True,
        cwd=str(gateway_root),
    )
    assert finished.returncode == 0, finished.stderr
    # Split on newlines, never on all whitespace (T-0286).  The first of the
    # three values the probe prints is a filesystem path, so a checkout whose
    # path contains a space made ``.split()`` yield four or more tokens and the
    # unpack below died with ``too many values to unpack`` -- which meant that
    # on exactly those machines the property this test exists for was never
    # asserted at all.  The count is kept as its own assertion so that nothing
    # is weakened by the change: three lines, no more and no less.
    printed = finished.stdout.splitlines()
    assert len(printed) == 3, finished.stdout
    resolved, before, after = printed
    # The probe has to have measured *this* checkout.  ``python -c`` puts the
    # working directory first on ``sys.path``, so it does -- but the ``.venv``
    # holds an editable install pointing somewhere else, and a probe that
    # resolved through it would be answering about another tree entirely.
    assert Path(resolved).resolve().is_relative_to(gateway_root), resolved
    assert before == "False", finished.stdout
    assert after == "True", finished.stdout
