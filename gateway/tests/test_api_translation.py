"""Translation as the submit path sees it: before binding, and reported back.

`test_translation.py` proves the pipeline.  This file proves its **place**: the
graph ComfyUI receives carries the effective text, the answer carries both texts
with the original marked as the canonical one, and a translation that could not
run stops the submission instead of quietly generating from untranslated text.

Every test here runs against the deterministic fake translator and the fake
ComfyUI, so the extra is not installed for any of it.
"""

from __future__ import annotations

import pytest

from localcanvas_gateway.config import PromptTranslationConfig
from localcanvas_gateway.translation.errors import (
    TranslationModelMissing,
    backend_missing,
)
from localcanvas_gateway.translation.fake import FakeTranslator

RUSSIAN = "ночной Токио, мужчина возле вывески"
RUSSIAN_IN_ENGLISH = "Tokyo at night, a man near a sign"
ENGLISH = "a rainy alley at night, cinematic lighting, 35mm, (masterpiece:1.2)"

#: A workflow with one translatable field and three that are not: a model name,
#: a select identifier and a number.  The values submitted into them below are
#: Russian too, so a gateway deciding by content rather than by declaration
#: would be caught here.
FIELDS = """
- id: prompt
  label: Prompt
  type: multiline
  required: true
  translatable: true
  bind:
    node: "20"
    input: text

- id: checkpoint
  label: Model
  type: string
  bind:
    node: "10"
    input: name

- id: mode
  label: Mode
  type: select
  options:
    - value: fast
    - value: медленный
  bind:
    node: "30"
    input: mode

- id: steps
  label: Steps
  type: integer
  bind:
    node: "30"
    input: steps
"""

OFF_DEFINITION = """
id: no_translation
name: Untranslated workflow
workflow: off_api.json
translation:
  mode: off
inputs:
  - id: prompt
    label: Prompt
    type: multiline
    required: true
    translatable: true
    bind:
      node: "20"
      input: text
"""


def taught() -> FakeTranslator:
    return FakeTranslator().teach("ru", "en", RUSSIAN, RUSSIAN_IN_ENGLISH)


@pytest.fixture
def translating(gateway_factory, builder):
    """A gateway with translation on, over the deterministic fake."""

    builder.add("flow", FIELDS)
    return gateway_factory(
        prompt_translation=PromptTranslationConfig(enabled=True),
        translator=taught(),
    )


def submitted_graph(harness):
    return harness.fake.submissions[0]["prompt"]


# -- the stage, and where it sits -------------------------------------------


def test_the_graph_carries_the_effective_text(translating) -> None:
    """Translation happens before binding, which is what this asserts.

    Not "the response mentions a translation" -- the bound graph, which is what
    ComfyUI is actually given.
    """

    response = translating.submit("flow", {"prompt": RUSSIAN})

    assert response.status_code == 201, response.text
    assert submitted_graph(translating)["20"]["inputs"]["text"] == RUSSIAN_IN_ENGLISH


def test_both_texts_come_back_and_the_original_is_the_users_own(translating) -> None:
    body = translating.submit("flow", {"prompt": RUSSIAN}).json()

    assert body["translation"] == {
        "applied": True,
        "fields": {
            "prompt": {
                "original": RUSSIAN,
                "effective": RUSSIAN_IN_ENGLISH,
                "translation": {"applied": True, "source": "ru", "target": "en"},
            }
        },
    }


def test_no_span_bookkeeping_reaches_the_response(translating) -> None:
    field = translating.submit("flow", {"prompt": RUSSIAN}).json()["translation"]["fields"][
        "prompt"
    ]

    assert set(field) == {"original", "effective", "translation"}
    assert set(field["translation"]) == {"applied", "source", "target"}


def test_an_english_prompt_reaches_comfyui_exactly_as_typed(translating) -> None:
    body = translating.submit("flow", {"prompt": ENGLISH}).json()

    assert submitted_graph(translating)["20"]["inputs"]["text"] == ENGLISH
    assert body["translation"]["applied"] is False
    assert body["translation"]["fields"]["prompt"] == {
        "original": ENGLISH,
        "effective": ENGLISH,
        "translation": {"applied": False, "source": None, "target": "en"},
    }


def test_generate_again_resubmits_from_the_original(translating) -> None:
    """The original is what persists, so resubmitting it is the whole feature.

    A gateway that handed back the effective text as the prompt would translate
    an English string on the second run -- or, worse, translate a translation.
    """

    first = translating.submit("flow", {"prompt": RUSSIAN}).json()

    again = translating.submit("flow", {"prompt": first["translation"]["fields"]["prompt"]["original"]})

    assert again.status_code == 201, again.text
    graphs = [submission["prompt"] for submission in translating.fake.submissions]
    assert [graph["20"]["inputs"]["text"] for graph in graphs] == [
        RUSSIAN_IN_ENGLISH,
        RUSSIAN_IN_ENGLISH,
    ]
    assert again.json()["translation"]["fields"]["prompt"]["original"] == RUSSIAN


def test_only_the_declared_field_is_translated(translating) -> None:
    translating.submit(
        "flow",
        {
            "prompt": RUSSIAN,
            "checkpoint": "модель.safetensors",
            "mode": "медленный",
            "steps": 24,
        },
    )

    graph = submitted_graph(translating)

    assert graph["20"]["inputs"]["text"] == RUSSIAN_IN_ENGLISH
    assert graph["10"]["inputs"]["name"] == "модель.safetensors"
    assert graph["30"]["inputs"]["mode"] == "медленный"
    assert graph["30"]["inputs"]["steps"] == 24


# -- both ways of switching it off ------------------------------------------


def test_translation_switched_off_binds_the_text_as_typed(gateway_factory, builder) -> None:
    builder.add("flow", FIELDS)
    harness = gateway_factory(translator=taught())  # the shipped default: off

    body = harness.submit("flow", {"prompt": RUSSIAN}).json()

    assert submitted_graph(harness)["20"]["inputs"]["text"] == RUSSIAN
    assert body["translation"] == {"applied": False, "fields": {}}


def test_a_workflow_that_says_off_is_not_translated(gateway_factory, builder) -> None:
    from conftest import graph_copy

    builder.write("off", OFF_DEFINITION, json_name="off_api.json", graph=graph_copy())
    harness = gateway_factory(
        prompt_translation=PromptTranslationConfig(enabled=True),
        translator=taught(),
    )

    body = harness.submit("no_translation", {"prompt": RUSSIAN}).json()

    assert submitted_graph(harness)["20"]["inputs"]["text"] == RUSSIAN
    assert body["translation"] == {"applied": False, "fields": {}}


# -- when it cannot run ------------------------------------------------------


def failing(error) -> FakeTranslator:
    return FakeTranslator(fails_with=error)


@pytest.mark.parametrize(
    "error,code,expected",
    [
        (backend_missing(), "translation_unavailable", "gateway[translation]"),
        (
            TranslationModelMissing("ru", "en"),
            "translation_model_missing",
            "argospm install translate-ru_en",
        ),
    ],
)
def test_a_translation_that_cannot_run_stops_the_submission(
    gateway_factory, builder, error, code, expected
) -> None:
    """Never a shrug, and never untranslated text passed off as translated."""

    builder.add("flow", FIELDS)
    harness = gateway_factory(
        prompt_translation=PromptTranslationConfig(enabled=True),
        translator=failing(error),
    )

    response = harness.submit("flow", {"prompt": RUSSIAN})

    assert response.status_code == 500
    body = response.json()["error"]
    assert body["code"] == code
    assert expected in body["message"]
    # The one that matters: ComfyUI was never asked to generate anything.
    assert harness.fake.submissions == []


def test_an_english_prompt_still_works_when_the_backend_is_missing(
    gateway_factory, builder
) -> None:
    """Passthrough asks the backend for nothing, so it cannot fail on it.

    A user who never writes Russian or Japanese is not stopped by an extra they
    have no reason to install.
    """

    builder.add("flow", FIELDS)
    harness = gateway_factory(
        prompt_translation=PromptTranslationConfig(enabled=True),
        translator=failing(backend_missing()),
    )

    response = harness.submit("flow", {"prompt": ENGLISH})

    assert response.status_code == 201, response.text
    assert submitted_graph(harness)["20"]["inputs"]["text"] == ENGLISH


# ==========================================================================
# The per-submission override (T-0043)
#
# One word, and it only ever subtracts.  Every test below is written so that
# an implementation which let a request *add* translation would fail it.
# ==========================================================================

OFF = {"mode": "off"}


def test_a_submission_can_switch_translation_off_for_itself(translating) -> None:
    """The effective text is the original, and the answer says so.

    The translator is asked for nothing at all: switching the stage off is not
    a translation that happened to change nothing, and a gateway that ran the
    pipeline and discarded the answer would still have sent the user's prompt
    to a language model.
    """

    response = translating.submit("flow", {"prompt": RUSSIAN}, translation=OFF)

    assert response.status_code == 201, response.text
    assert submitted_graph(translating)["20"]["inputs"]["text"] == RUSSIAN
    assert response.json()["translation"] == {"applied": False, "fields": {}}
    assert translating.state.translation.translator.calls == []


def test_the_override_changes_nothing_the_next_submission_sees(translating) -> None:
    """Per submission, and stateless: the gateway remembers no preference.

    Phase 3 is what remembers this choice, on the phone. A gateway that kept it
    would silently stop translating for every other client on the LAN.
    """

    translating.submit("flow", {"prompt": RUSSIAN}, translation=OFF)
    second = translating.submit("flow", {"prompt": RUSSIAN})

    assert second.status_code == 201, second.text
    texts = [
        submission["prompt"]["20"]["inputs"]["text"]
        for submission in translating.fake.submissions
    ]
    assert texts == [RUSSIAN, RUSSIAN_IN_ENGLISH]
    assert second.json()["translation"]["applied"] is True


def test_switching_it_off_gets_a_prompt_past_a_backend_that_is_not_there(
    gateway_factory, builder
) -> None:
    """The submission that would otherwise be refused, and the point of the word.

    Translation is switched on, the extra is not installed, and the text is
    Russian: without the override this is ``translation_unavailable`` and no
    generation at all.
    """

    builder.add("flow", FIELDS)
    harness = gateway_factory(
        prompt_translation=PromptTranslationConfig(enabled=True),
        translator=failing(backend_missing()),
    )

    response = harness.submit("flow", {"prompt": RUSSIAN}, translation=OFF)

    assert response.status_code == 201, response.text
    assert submitted_graph(harness)["20"]["inputs"]["text"] == RUSSIAN
    assert response.json()["translation"] == {"applied": False, "fields": {}}


@pytest.mark.parametrize(
    "override",
    [
        {"mode": "on"},
        {"mode": "auto"},
        {"mode": "OFF"},
        {"mode": True},
        {"mode": "off", "sources": ["ru"]},
        {},
        "off",
        ["off"],
        True,
    ],
    ids=[
        "on",
        "auto",
        "wrong-case",
        "not-a-string",
        "an-extra-key",
        "empty",
        "a-bare-string",
        "a-list",
        "a-boolean",
    ],
)
def test_anything_but_off_is_refused_rather_than_ignored(translating, override) -> None:
    """A word the gateway does not act on is never accepted quietly.

    ``on`` is the one that matters: a client that believed it had switched
    translation on and was silently ignored would have been told exactly the
    confident lie this whole stage is written to avoid.
    """

    response = translating.submit("flow", {"prompt": RUSSIAN}, translation=override)

    assert response.status_code == 400, response.text
    error = response.json()["error"]
    assert error["code"] == "invalid_request"
    assert error["field"] == "translation"
    assert translating.fake.submissions == []


def test_a_workflow_that_says_off_cannot_be_talked_into_translating(
    gateway_factory, builder
) -> None:
    """The first direction that matters: the curator's decision holds.

    Both shapes a client could try are exercised. ``off`` is accepted and
    changes nothing, because the workflow had already decided; ``on`` is
    refused. Neither produces a translated graph.
    """

    from conftest import graph_copy

    builder.write("off", OFF_DEFINITION, json_name="off_api.json", graph=graph_copy())
    harness = gateway_factory(
        prompt_translation=PromptTranslationConfig(enabled=True),
        translator=taught(),
    )

    switched_off = harness.submit("no_translation", {"prompt": RUSSIAN}, translation=OFF)
    switched_on = harness.submit(
        "no_translation", {"prompt": RUSSIAN}, translation={"mode": "on"}
    )

    assert switched_off.status_code == 201, switched_off.text
    assert switched_on.status_code == 400, switched_on.text
    assert submitted_graph(harness)["20"]["inputs"]["text"] == RUSSIAN
    assert switched_off.json()["translation"] == {"applied": False, "fields": {}}
    assert harness.state.translation.translator.calls == []


def test_a_pc_with_no_backend_cannot_be_talked_into_translating(
    gateway_factory, builder
) -> None:
    """The second direction: the machine's own configuration holds too.

    Translation is switched off here and the extra is not installed, which is
    the shipped default and the common case. No request can start a stage this
    PC was never set up for.
    """

    builder.add("flow", FIELDS)
    harness = gateway_factory(translator=failing(backend_missing()))

    switched_off = harness.submit("flow", {"prompt": RUSSIAN}, translation=OFF)
    switched_on = harness.submit("flow", {"prompt": RUSSIAN}, translation={"mode": "on"})

    assert switched_off.status_code == 201, switched_off.text
    assert switched_on.status_code == 400, switched_on.text
    assert submitted_graph(harness)["20"]["inputs"]["text"] == RUSSIAN
    assert switched_off.json()["translation"] == {"applied": False, "fields": {}}
    assert harness.state.translation.translator.calls == []


def test_a_submission_that_says_nothing_about_translation_is_unchanged(
    translating,
) -> None:
    """The compatibility case: every client written before the override.

    It is the same request the tests at the top of this file send, asserted
    here as the property it now is -- the absent key means "whatever this PC
    and this workflow already decided", never "off".
    """

    response = translating.submit("flow", {"prompt": RUSSIAN})

    assert response.status_code == 201, response.text
    assert submitted_graph(translating)["20"]["inputs"]["text"] == RUSSIAN_IN_ENGLISH
    assert response.json()["translation"]["applied"] is True
