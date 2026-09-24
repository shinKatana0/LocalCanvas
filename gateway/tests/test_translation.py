"""Local prompt translation: the whole of the logic, against a fake backend.

Every test in this file runs with the ``translation`` extra **absent**.  That is
not a convenience -- it is an acceptance criterion of T-0040.  The real backend
pulls ``stanza`` and ``torch``, measured at 981 MB across 70 packages, and a
gateway suite that could only be run inside such an environment would stop
being run.  So the seam is a three-line protocol, the logic sits on this side of
it, and the deterministic fake (``translation/fake.py``) is what answers.

What the fake makes provable, and a real model never could: *what was handed to
the translator*.  A protected literal, an English-only fragment and a field the
workflow did not mark are all proved by their **absence** from the call log, and
an absence is only observable when the backend is an instrument.

The one test that needs the real Argos backend is at the bottom, and it skips
with a reason naming the install when the extra is not there.  The logic above
it is never what gets skipped.
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import socket
import subprocess
import sys
import textwrap
from pathlib import Path
from typing import Any, Dict

import pytest

import localcanvas_gateway
from conftest import RegistryBuilder, graph_copy
from localcanvas_gateway.config import ConfigError, PromptTranslationConfig, load_config
from localcanvas_gateway.translation import (
    ArgosTranslator,
    TranslationFailed,
    TranslationModelMissing,
    TranslationUnavailable,
    detect_source,
    split_spans,
)
from localcanvas_gateway.translation.errors import INSTALL_COMMAND, backend_missing
from localcanvas_gateway.translation.fake import FakeTranslator
from localcanvas_gateway.translation.service import TranslationService
from localcanvas_gateway.workflows import TranslationMode

# --------------------------------------------------------------------------
# The texts.  Written out here rather than built in the tests, because these
# exact strings -- with their spacing -- are the subject.
# --------------------------------------------------------------------------

#: The card's own example, and the one that produced the measured corruption.
SPEC_PROMPT = 'ночной Токио, мужчина возле вывески "居酒屋", cinematic lighting'
SPEC_CORE = "ночной Токио, мужчина возле вывески"
SPEC_TRANSLATED_CORE = "Tokyo at night, a man near a sign"
SPEC_EFFECTIVE = 'Tokyo at night, a man near a sign "居酒屋", cinematic lighting'
#: What the card measured when the spacing was not preserved.  Named so the
#: assertion below says what it is refusing, not merely that two strings differ.
SPEC_CORRUPTED = 'Tokyo at night, a man near a sign"居酒屋"cinematic lighting'

#: An optimised English prompt: the text that must come back byte-identical.
ENGLISH_PROMPT = "a rainy alley at night,  cinematic lighting, 35mm, f/1.8, (masterpiece:1.2)"

RUSSIAN_PROMPT = "ночной Токио, мужчина возле вывески"
JAPANESE_PROMPT = "夜の東京、ネオンサインのそばに立つ男性"


def service(
    *,
    enabled: bool = True,
    translator: FakeTranslator = None,
    **settings: Any,
) -> TranslationService:
    """A service over the fake, configured the way a test needs it."""

    return TranslationService(
        PromptTranslationConfig(enabled=enabled, **settings),
        translator=FakeTranslator() if translator is None else translator,
    )


# ==========================================================================
# The scanner: which parts of the text are never given to a translator
# ==========================================================================


@pytest.mark.parametrize(
    "text",
    [
        "",
        "plain text",
        SPEC_PROMPT,
        'one "two" three "four" five',
        'unterminated "from here on',
        '"leading literal", then text',
        'escaped \\" outside a literal',
        'a "literal with \\" inside it" and a tail',
        '""',
        '"',
        'trailing backslash inside "a literal\\',
    ],
)
def test_the_spans_are_a_partition_of_the_input(text: str) -> None:
    """Reassembly is the invariant everything else rests on.

    If the spans do not concatenate back to the input, then "unchanged text
    comes back byte-identical" cannot be true however carefully the rest is
    written.
    """

    assert "".join(span.text for span in split_spans(text)) == text


def test_a_quoted_literal_is_protected_together_with_its_quote_characters() -> None:
    spans = split_spans('a man near a sign "居酒屋" at night')

    assert [(span.text, span.protected) for span in spans] == [
        ("a man near a sign ", False),
        ('"居酒屋"', True),
        (" at night", False),
    ]


def test_an_escaped_quote_does_not_close_the_literal() -> None:
    spans = split_spans('say "he said \\"hi\\" loudly" now')

    assert [span.text for span in spans if span.protected] == ['"he said \\"hi\\" loudly"']


def test_several_literals_in_one_prompt_are_each_protected() -> None:
    spans = split_spans('"居酒屋" and "Hello" and "日本語"')

    assert [span.text for span in spans if span.protected] == [
        '"居酒屋"',
        '"Hello"',
        '"日本語"',
    ]


def test_an_unterminated_literal_runs_to_the_end_of_the_text() -> None:
    """The documented rule, and the reason for it: it cannot corrupt.

    The quote character is never dropped and the gateway never guesses where
    the author meant to close it; the cost is that the tail is not translated.
    """

    spans = split_spans('ночной Токио, вывеска "居酒屋, cinematic lighting')

    assert [(span.text, span.protected) for span in spans] == [
        ("ночной Токио, вывеска ", False),
        ('"居酒屋, cinematic lighting', True),
    ]


def test_switching_literal_protection_off_hands_the_whole_text_over() -> None:
    spans = split_spans('a "literal" here', preserve_quoted_literals=False)

    assert [(span.text, span.protected) for span in spans] == [('a "literal" here', False)]


# ==========================================================================
# Detection: conservative on purpose
# ==========================================================================


@pytest.mark.parametrize(
    "text,expected",
    [
        ("ночной Токио", "ru"),
        ("夜の東京", "ja"),  # kana present
        ("ネオン", "ja"),  # katakana only
        ("a rainy alley at night", None),
        ("", None),
        ("35mm, f/1.8, (masterpiece:1.2)", None),
        # Han with no kana is ambiguous -- the same characters are Chinese --
        # so it is never enough on its own to call text Japanese.
        ("居酒屋", None),
        ("東京", None),
    ],
)
def test_detection_is_script_based_and_refuses_to_guess(text: str, expected) -> None:
    assert detect_source(text, ("ru", "ja")) == expected


def test_a_language_that_is_not_configured_is_not_detected() -> None:
    assert detect_source("ночной Токио", ("ja",)) is None


def test_the_configured_order_decides_when_two_scripts_are_present() -> None:
    both = "ночной 東京 ネオン"

    assert detect_source(both, ("ru", "ja")) == "ru"
    assert detect_source(both, ("ja", "ru")) == "ja"


# ==========================================================================
# The pipeline
# ==========================================================================


def test_russian_is_translated_to_english() -> None:
    fake = FakeTranslator().teach("ru", "en", RUSSIAN_PROMPT, SPEC_TRANSLATED_CORE)

    result = service(translator=fake).translate_text(RUSSIAN_PROMPT)

    assert result.effective == SPEC_TRANSLATED_CORE
    assert result.applied is True
    assert result.source == "ru"
    assert result.target == "en"
    assert fake.texts == [RUSSIAN_PROMPT]


def test_japanese_is_translated_to_english() -> None:
    fake = FakeTranslator().teach(
        "ja", "en", JAPANESE_PROMPT, "Tokyo at night, a man standing by a neon sign"
    )

    result = service(translator=fake).translate_text(JAPANESE_PROMPT)

    assert result.effective == "Tokyo at night, a man standing by a neon sign"
    assert result.source == "ja"
    assert fake.texts == [JAPANESE_PROMPT]


def test_an_english_prompt_comes_back_byte_identical_and_is_never_translated() -> None:
    """Byte equality, not similarity, and the translator is never even asked.

    An optimised prompt full of weights and tags is the most valuable text a
    user types.  Nothing may normalise its double spaces, its brackets or its
    punctuation.
    """

    fake = FakeTranslator()

    result = service(translator=fake).translate_text(ENGLISH_PROMPT)

    assert result.effective == ENGLISH_PROMPT
    assert result.effective is ENGLISH_PROMPT  # the input itself, not a rebuild
    assert result.applied is False
    assert result.source is None
    assert fake.calls == []


def test_the_spec_example_keeps_its_spacing_and_punctuation() -> None:
    """The measurement this whole design exists to answer (T-0040)."""

    fake = FakeTranslator().teach("ru", "en", SPEC_CORE, SPEC_TRANSLATED_CORE)

    result = service(translator=fake).translate_text(SPEC_PROMPT)

    assert result.effective == SPEC_EFFECTIVE
    assert result.effective != SPEC_CORRUPTED
    # The literal was never handed over: that is why it survived, rather than
    # having survived a round trip through a model.
    assert fake.texts == [SPEC_CORE]


def test_the_whitespace_around_a_translated_fragment_is_re_attached_verbatim() -> None:
    """Leading and trailing whitespace is split off, never sent, never rebuilt."""

    fake = FakeTranslator().teach("ru", "en", "Токио", "Tokyo")

    result = service(translator=fake).translate_text('\n  Токио  "居酒屋"\t')

    assert result.effective == '\n  Tokyo  "居酒屋"\t'
    assert fake.texts == ["Токио"]


def test_only_the_non_english_fragment_of_a_mixed_prompt_is_handed_over() -> None:
    fake = FakeTranslator().teach("ru", "en", "ночной Токио", "Tokyo at night")

    result = service(translator=fake).translate_text(
        'ночной Токио "neon" , cinematic lighting, 8k'
    )

    assert result.effective == 'Tokyo at night "neon" , cinematic lighting, 8k'
    # The English fragment and the literal were never translated -- and the
    # ", cinematic lighting, 8k" fragment kept its leading comma and space,
    # which is precisely what the measured naive splice lost.
    assert fake.texts == ["ночной Токио"]


def test_only_the_non_japanese_fragment_of_a_mixed_prompt_is_handed_over() -> None:
    fake = FakeTranslator().teach("ja", "en", "夜の東京", "Tokyo at night")

    result = service(translator=fake).translate_text('夜の東京 "居酒屋" , 35mm photography')

    assert result.effective == 'Tokyo at night "居酒屋" , 35mm photography'
    assert fake.texts == ["夜の東京"]


@pytest.mark.parametrize(
    "literal",
    ['"居酒屋"', '"Hello"', '"ночной Токио"', '"日本語 かな"', '"a \\" b"'],
)
def test_a_quoted_literal_survives_in_any_language(literal: str) -> None:
    fake = FakeTranslator()
    text = "вывеска {} рядом".format(literal)

    result = service(translator=fake).translate_text(text)

    assert literal in result.effective
    assert all(literal not in handed for handed in fake.texts)


def test_the_unterminated_quote_rule_is_what_the_module_documents() -> None:
    fake = FakeTranslator().teach("ru", "en", "ночной Токио, вывеска", "Tokyo at night, a sign")

    result = service(translator=fake).translate_text(
        'ночной Токио, вывеска "居酒屋, cinematic lighting'
    )

    assert result.effective == 'Tokyo at night, a sign "居酒屋, cinematic lighting'
    assert fake.texts == ["ночной Токио, вывеска"]


def test_translation_can_be_switched_off_globally() -> None:
    fake = FakeTranslator()

    result = service(enabled=False, translator=fake).translate_text(SPEC_PROMPT)

    assert result.effective is SPEC_PROMPT
    assert fake.calls == []


def test_a_backend_failure_is_an_error_and_never_untranslated_text() -> None:
    """The rule: text that was not translated is never passed off as translated."""

    fake = FakeTranslator(
        fails_with=TranslationFailed("The translation model on the PC failed.")
    )

    with pytest.raises(TranslationFailed):
        service(translator=fake).translate_text(RUSSIAN_PROMPT)


# ==========================================================================
# Which fields.  The workflow decides; nothing here guesses.
# ==========================================================================

TRANSLATABLE_WORKFLOW = """
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
- id: style
  label: Style
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


def workflow_with(builder: RegistryBuilder, fields: str = TRANSLATABLE_WORKFLOW, **kwargs):
    builder.add("t", fields, **kwargs)
    registry = builder.load()
    assert [str(item) for item in registry.diagnostics] == []
    return registry.get("t")


def test_only_fields_the_workflow_marks_translatable_are_translated(builder) -> None:
    """Eligibility is a declaration, never a guess about the value.

    Every non-prompt value below is Russian too, so a gateway that decided by
    content rather than by declaration would rewrite them and fail here.
    """

    workflow = workflow_with(builder)
    fake = FakeTranslator().teach("ru", "en", "ночной Токио", "Tokyo at night")
    values: Dict[str, Any] = {
        "prompt": "ночной Токио",
        "checkpoint": "модель.safetensors",
        "style": "медленный",
        "steps": 24,
    }

    result = service(translator=fake).apply(workflow, values)

    assert result.values == {
        "prompt": "Tokyo at night",
        "checkpoint": "модель.safetensors",
        "style": "медленный",
        "steps": 24,
    }
    assert fake.texts == ["ночной Токио"]
    assert [item.field_id for item in result.fields] == ["prompt"]


def test_the_original_and_the_effective_text_are_both_reported(builder) -> None:
    workflow = workflow_with(builder)
    fake = FakeTranslator().teach("ru", "en", "ночной Токио", "Tokyo at night")

    view = service(translator=fake).apply(workflow, {"prompt": "ночной Токио"}).to_view()

    assert view == {
        "applied": True,
        "fields": {
            "prompt": {
                "original": "ночной Токио",
                "effective": "Tokyo at night",
                "translation": {"applied": True, "source": "ru", "target": "en"},
            }
        },
    }


def test_a_workflow_can_switch_translation_off_for_itself(builder) -> None:
    builder.write(
        "off",
        """
        id: off_workflow
        name: No translation
        workflow: off_api.json
        translation:
          mode: off
        inputs:
          - id: prompt
            label: Prompt
            type: multiline
            translatable: true
            bind:
              node: "20"
              input: text
        """,
        json_name="off_api.json",
        graph=graph_copy(),
    )
    registry = builder.load()
    workflow = registry.get("off_workflow")
    fake = FakeTranslator()

    assert workflow.translation_mode is TranslationMode.OFF
    result = service(translator=fake).apply(workflow, {"prompt": SPEC_PROMPT})

    assert result.values == {"prompt": SPEC_PROMPT}
    assert result.fields == ()
    assert result.to_view() == {"applied": False, "fields": {}}
    assert fake.calls == []


def test_a_workflow_says_auto_when_it_says_nothing(builder) -> None:
    assert workflow_with(builder).translation_mode is TranslationMode.AUTO


def test_translatable_is_refused_on_a_field_that_is_not_text(builder) -> None:
    """A select identifier, a number or a media reference is not prose."""

    builder.add(
        "bad",
        """
        - id: style
          label: Style
          type: select
          translatable: true
          options:
            - value: fast
          bind:
            node: "30"
            input: mode
        """,
    )

    messages = [str(item) for item in builder.load().diagnostics]

    assert any("'translatable' is not valid for a field of type 'select'" in m for m in messages)


def test_the_quoted_spelling_of_off_means_the_same_thing(builder) -> None:
    """`off` and `"off"` are the same setting.

    YAML reads a bare ``off`` as the boolean ``False``, so the two spellings
    arrive here as different types.  A curator should never have to know that.
    """

    builder.write(
        "quoted",
        """
        id: quoted_off
        name: No translation
        workflow: quoted_api.json
        translation:
          mode: "off"
        inputs: []
        """,
        json_name="quoted_api.json",
        graph=graph_copy(),
    )

    assert builder.load().get("quoted_off").translation_mode is TranslationMode.OFF


def test_there_is_no_on_mode(builder) -> None:
    builder.write(
        "on",
        """
        id: on_workflow
        name: On
        workflow: on_api.json
        translation:
          mode: on
        inputs: []
        """,
        json_name="on_api.json",
        graph=graph_copy(),
    )

    messages = [str(item) for item in builder.load().diagnostics]

    assert any("there is no 'on'" in m for m in messages)


def test_an_unknown_translation_mode_is_refused(builder) -> None:
    builder.write(
        "bad",
        """
        id: bad_mode
        name: Bad
        workflow: bad_api.json
        translation:
          mode: sometimes
        inputs: []
        """,
        json_name="bad_api.json",
        graph=graph_copy(),
    )

    messages = [str(item) for item in builder.load().diagnostics]

    assert any("translation.mode must be 'auto' or 'off'" in m for m in messages)


# ==========================================================================
# The backend seam.  Nothing below installs anything.
# ==========================================================================


# -- the extra is not dragged in, asked where the answer is about the code --
#
# Both questions below are about what is *absent* from ``sys.modules``, and in
# a session that is a question about everything that ran before it: this suite
# really does import the extra -- the live-backend test at the bottom of this
# file does on a PC that has it, and so does any gateway assembled with the
# real adapter.  Asked of a fresh interpreter, the answer is about the gateway,
# and it is the same one alone, in this file, and in a full run in any order
# (T-0125).

#: What that interpreter is asked.  It answers on stdout as one JSON document,
#: so a child that died says so through its exit code and its stderr instead of
#: through an assertion that passed because nothing ran.
IMPORT_PROBE = """import json, sys

gateway_root, stub_root = sys.argv[1], sys.argv[2]
# The checkout under test, ahead of anything installed in this interpreter: a
# subprocess otherwise resolves `localcanvas_gateway` through whatever is
# installed, which has no necessary relationship to this branch -- the hazard
# `test_config_seam.py` was written about.  The parent checks the file this
# answer came out of against its own.
sys.path.insert(0, gateway_root)
# ...and behind it a real, importable `argostranslate`, so that "not imported"
# is a statement about the gateway rather than about this PC.
sys.path.insert(1, stub_root)

import importlib.util

answer = {"extra_importable": importlib.util.find_spec("argostranslate") is not None}

# The whole surface a start-up walks, so that an import added anywhere in it is
# caught wherever it was added.
import localcanvas_gateway
import localcanvas_gateway.api
import localcanvas_gateway.__main__
from localcanvas_gateway.translation import ArgosTranslator

answer["gateway_file"] = localcanvas_gateway.__file__
answer["imported_by_importing"] = "argostranslate" in sys.modules

ArgosTranslator()
answer["imported_by_constructing"] = "argostranslate" in sys.modules

answer["installed_answers"] = ArgosTranslator().installed()
answer["imported_by_asking"] = "argostranslate" in sys.modules

print(json.dumps(answer))
"""


def ask_a_clean_interpreter(stub_root: Path) -> Dict[str, Any]:
    """Run the probe, and prove it was this checkout that answered."""

    package = Path(localcanvas_gateway.__file__).resolve()
    environment = dict(os.environ)
    # Whatever PYTHONPATH says is not what this test is about; the path the
    # child is given on the command line is.
    environment.pop("PYTHONPATH", None)

    result = subprocess.run(
        [sys.executable, "-c", IMPORT_PROBE, str(package.parent.parent), str(stub_root)],
        capture_output=True,
        text=True,
        env=environment,
        timeout=600,
    )

    assert result.returncode == 0, result.stderr
    answer = json.loads(result.stdout)
    assert Path(answer["gateway_file"]).resolve() == package, (
        "the child imported {}, not the checkout under test at {}".format(
            answer["gateway_file"], package
        )
    )
    return answer


def test_importing_the_gateway_does_not_import_the_translation_extra(
    importable_backend,
) -> None:
    """The lazy import is the reason the suite runs without a 1 GB install.

    ``importable_backend`` is on the child's path, so the extra was there to be
    imported: an absence nothing could have supplied says nothing about the
    code that did not supply it.
    """

    answer = ask_a_clean_interpreter(importable_backend)

    assert answer["extra_importable"] is True
    assert answer["imported_by_importing"] is False
    assert answer["imported_by_constructing"] is False  # nor constructing one


def test_a_missing_package_names_the_command_that_installs_it(monkeypatch) -> None:
    # A ``None`` entry makes the import raise however the machine is set up, so
    # this test says the same thing on a PC that does have the extra.
    monkeypatch.setitem(sys.modules, "argostranslate", None)

    with pytest.raises(TranslationUnavailable) as raised:
        ArgosTranslator().translate("ночной Токио", source="ru", target="en")

    assert raised.value.code == "translation_unavailable"
    assert raised.value.status_code == 500
    assert INSTALL_COMMAND in raised.value.message
    assert "gateway[translation]" in raised.value.message


def test_the_missing_package_and_missing_model_errors_are_distinct() -> None:
    assert backend_missing().code != TranslationModelMissing("ru", "en").code


def stub_argostranslate(monkeypatch, *, provider: str = "OPENNMT", pair: Any = None) -> None:
    """A stand-in for the extra, so the adapter's own branches are testable.

    It stands in for the *package*, never for the gateway's logic: what is
    under test is which error this module raises for which answer.
    """

    import types

    settings = types.ModuleType("argostranslate.settings")
    settings.model_provider = type("ModelProvider", (), {"name": provider})()

    translate = types.ModuleType("argostranslate.translate")
    language = type(
        "Language",
        (),
        {"get_translation": lambda self, other: pair},
    )()
    translate.get_language_from_code = lambda code: language

    package = types.ModuleType("argostranslate")
    package.settings = settings
    package.translate = translate
    monkeypatch.setitem(sys.modules, "argostranslate", package)
    monkeypatch.setitem(sys.modules, "argostranslate.settings", settings)
    monkeypatch.setitem(sys.modules, "argostranslate.translate", translate)


def test_a_missing_language_model_names_the_setup_command(monkeypatch) -> None:
    stub_argostranslate(monkeypatch, pair=None)

    with pytest.raises(TranslationModelMissing) as raised:
        ArgosTranslator().translate("ночной Токио", source="ru", target="en")

    assert raised.value.code == "translation_model_missing"
    assert "argospm install translate-ru_en" in raised.value.message


def test_a_remote_translation_provider_is_refused_rather_than_used(monkeypatch) -> None:
    """There is no cloud fallback, and a backend configured for one is an error."""

    stub_argostranslate(monkeypatch, provider="LIBRETRANSLATE", pair=object())

    with pytest.raises(TranslationUnavailable) as raised:
        ArgosTranslator().translate("ночной Токио", source="ru", target="en")

    assert "remote" in raised.value.message


def test_the_local_backend_translates_through_the_installed_pair(monkeypatch) -> None:
    stub_argostranslate(
        monkeypatch,
        pair=type("Pair", (), {"translate": lambda self, text: "Tokyo at night"})(),
    )

    assert (
        ArgosTranslator().translate("ночной Токио", source="ru", target="en")
        == "Tokyo at night"
    )


# -- what the backend can be asked *before* a submission (T-0043) -----------


def unusable_pair():
    """A model object that fails the test if anything asks it to translate."""

    def refuse(self, text):  # pragma: no cover - the point is that it is not called
        raise AssertionError("listing the installed pairs translated something")

    return type("Pair", (), {"translate": refuse})()


def test_the_local_backend_lists_the_pairs_it_has_a_model_for(monkeypatch) -> None:
    """The production path behind ``capabilities.translation.pairs``.

    Read-only, and the fixture proves it: the model here raises if it is asked
    to translate, so a probe that ran a translation to find out would fail.
    """

    stub_argostranslate(monkeypatch, pair=unusable_pair())

    pairs = ArgosTranslator().installed_pairs(("ru", "ja"), "en")

    assert pairs == (("ru", "en"), ("ja", "en"))


def test_a_source_with_no_model_is_left_out_of_the_pairs(monkeypatch) -> None:
    """The same lookup that would raise ``translation_model_missing``.

    Advertising it would promise a translation the next submission refuses.
    """

    stub_argostranslate(monkeypatch, pair=None)

    assert ArgosTranslator().installed_pairs(("ru", "ja"), "en") == ()


def test_a_backend_configured_remotely_advertises_nothing(monkeypatch) -> None:
    """It is refused for translating, so it is not offered as a capability."""

    stub_argostranslate(monkeypatch, provider="LIBRETRANSLATE", pair=unusable_pair())

    assert ArgosTranslator().installed_pairs(("ru",), "en") == ()


def test_a_pc_without_the_extra_reports_it_absent_and_asks_for_nothing(
    monkeypatch,
) -> None:
    """``None`` in ``sys.modules`` makes the import fail however the PC is set up.

    So this says the same thing on a machine that does have the extra -- and
    the pair listing stops at the absence rather than reaching past it.
    """

    monkeypatch.setitem(sys.modules, "argostranslate", None)

    translator = ArgosTranslator()

    assert translator.installed() is False
    assert translator.installed_pairs(("ru", "ja"), "en") == ()


def test_asking_whether_the_extra_is_installed_does_not_import_it(
    importable_backend,
) -> None:
    """The question the handshake asks, and it must stay on the cheap side.

    The stub on the child's path is what makes this a guard: without a real,
    importable ``argostranslate`` the last assertion holds for any
    implementation, including one that imports on every call.  With it, the
    answer is ``True`` -- so something was found -- and ``sys.modules`` is
    still empty, so what was found was not imported.

    Same fresh interpreter as the guard above, and for the same reason: in this
    session the module is often already there, and then this question cannot be
    asked at all (T-0125).
    """

    answer = ask_a_clean_interpreter(importable_backend)

    assert answer["extra_importable"] is True
    assert answer["installed_answers"] is True
    assert answer["imported_by_asking"] is False


def test_listing_the_pairs_is_where_the_import_is_allowed_to_happen(
    importable_backend,
) -> None:
    """The other side of the same line, stated so it cannot drift.

    ``installed_pairs`` is the expensive question, which is why it is asked at
    startup and never in a request (`api/app.py`).  It reaches the backend by
    design; the guard above is about ``installed``, and this is what makes the
    two genuinely different rather than accidentally alike.
    """

    assert ArgosTranslator().installed_pairs(("ru",), "en") == ()

    assert "argostranslate" in sys.modules


# ==========================================================================
# No network at request time
# ==========================================================================

TRANSLATION_PACKAGE = Path(
    sys.modules["localcanvas_gateway.translation"].__file__
).resolve().parent

#: Anything that would reach a network, in the form it would be written in.
NETWORK_TOKENS = (
    "http://",
    "https://",
    "ws://",
    "wss://",
    "httpx",
    "aiohttp",
    "urllib",
    "api_key",
    "openai",
)
NETWORK_IMPORT = re.compile(
    r"^\s*(?:import|from)\s+(?:httpx|requests|urllib|http|socket|aiohttp|ssl|ftplib)\b",
    re.MULTILINE,
)


def test_no_module_on_the_translation_path_names_a_network_service() -> None:
    """A source scan, because "it did not connect this time" is not the claim.

    The claim is that there is nothing to connect *with*: no endpoint, no HTTP
    client, no import that could open one.
    """

    offenders = {}
    for module in sorted(TRANSLATION_PACKAGE.glob("*.py")):
        text = module.read_text(encoding="utf-8")
        found = [token for token in NETWORK_TOKENS if token in text]
        if NETWORK_IMPORT.search(text):
            found.append("a network import")
        if found:
            offenders[module.name] = found

    assert offenders == {}


def test_translating_opens_no_socket(monkeypatch, builder) -> None:
    def refuse(*args, **kwargs):  # pragma: no cover - the point is that it is not called
        raise AssertionError("the translation path opened a socket")

    monkeypatch.setattr(socket, "socket", refuse)
    monkeypatch.setattr(socket, "create_connection", refuse)

    workflow = workflow_with(builder)
    fake = FakeTranslator().teach("ru", "en", "ночной Токио", "Tokyo at night")

    result = service(translator=fake).apply(workflow, {"prompt": "ночной Токио"})

    assert result.values["prompt"] == "Tokyo at night"


# ==========================================================================
# Configuration
# ==========================================================================


def write_config(tmp_path: Path, section: str) -> Path:
    directory = tmp_path / "config" / "local"
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / "runtime.yaml"
    path.write_text(
        textwrap.dedent(
            """
            runtime:
              manage_comfy: false
            comfy:
              host: 127.0.0.1
              port: 8188
            workflows:
              registry: workflows/examples
            gateway:
              host: 0.0.0.0
              port: 7801
            identity:
              display_name: A PC
            """
        ).lstrip()
        + textwrap.dedent(section),
        encoding="utf-8",
    )
    return path


def test_translation_is_off_when_the_section_is_absent(tmp_path: Path) -> None:
    """Absent means off: the backend is an optional install of about a gigabyte."""

    config = load_config(write_config(tmp_path, ""))

    assert config.prompt_translation == PromptTranslationConfig()
    assert config.prompt_translation.enabled is False


def test_the_documented_translation_settings_are_read(tmp_path: Path) -> None:
    config = load_config(
        write_config(
            tmp_path,
            """
            prompt_translation:
              enabled: true
              target: en
              sources: [ru, ja]
              preserve_quoted_literals: true
            """,
        )
    )

    assert config.prompt_translation == PromptTranslationConfig(
        enabled=True, target="en", sources=("ru", "ja"), preserve_quoted_literals=True
    )


@pytest.mark.parametrize(
    "section,expected",
    [
        ("prompt_translation:\n  enabled: yes please\n", "enabled"),
        ("prompt_translation:\n  translate_everything: true\n", "unknown key"),
        ("prompt_translation:\n  sources: [de]\n", "cannot be detected"),
        ("prompt_translation:\n  sources: ru\n", "expected a list"),
        ("prompt_translation:\n  sources: []\n", "at least one"),
        ("prompt_translation:\n  sources: [ru, ru]\n", "listed twice"),
        ("prompt_translation:\n  target: english\n", "language code"),
        ("prompt_translation:\n  sources: [ru]\n  target: ru\n", "also the target"),
    ],
)
def test_a_wrong_translation_setting_names_the_key_and_the_expectation(
    tmp_path: Path, section: str, expected: str
) -> None:
    with pytest.raises(ConfigError) as raised:
        load_config(write_config(tmp_path, section))

    message = str(raised.value)
    assert "prompt_translation" in message
    assert expected in message


# ==========================================================================
# The real backend.  Skipped, loudly, when the extra is not installed.
#
# Integration as well (tests/conftest.py): with the extra installed its verdict
# still depends on whether the ru->en model is present in this user's Argos data
# directory, which is machine state outside the test's control.
#
# The missing extra is checked in the BODY and not with `skipif`, which is the
# difference between one skip reason and two.  pytest evaluates every `skipif`
# before any `skip` mark, so a decorator here would win over the integration
# skip conftest adds at collection -- and the reason an ordinary run printed
# would then be whichever of the two this machine happened to produce.  A
# machine with the extra said "integration test: ...", a machine without it
# said "the extra is not installed", and the test below that reads that reason
# passed in one checkout and failed in the other (measured from a clean clone:
# 1 failed, 2378 passed).  The gate that decides whether this test runs at all
# is the integration one, so it is the one that speaks first.
# ==========================================================================

TRANSLATION_EXTRA_MISSING = (
    "the 'translation' extra is not installed; install it with "
    + INSTALL_COMMAND
    + " and the ru->en model with 'argospm update && argospm install translate-ru_en'"
)


@pytest.mark.integration
def test_the_real_argos_backend_translates_and_preserves_a_literal() -> None:
    """The one test that needs the model.  Everything above it does not.

    It asserts what a translation *is* rather than what it says: the Russian is
    gone, the quoted literal is byte-identical, and the spacing around it
    survived.  Pinning a model's exact wording would be pinning the model.
    """

    if importlib.util.find_spec("argostranslate") is None:
        pytest.skip(TRANSLATION_EXTRA_MISSING)

    from localcanvas_gateway.translation import ArgosTranslator
    from localcanvas_gateway.translation.detect import has_cyrillic

    live = TranslationService(
        PromptTranslationConfig(enabled=True), translator=ArgosTranslator()
    )

    result = live.translate_text(SPEC_PROMPT)

    assert result.applied is True
    assert result.source == "ru"
    assert '"居酒屋"' in result.effective
    assert not has_cyrillic(result.effective)
    assert result.original == SPEC_PROMPT
    assert " " + '"居酒屋"' + "," in result.effective


def test_the_translation_extra_is_declared_as_an_extra_and_not_a_dependency() -> None:
    """An unrelated user must not download ~1 GB to run LocalCanvas."""

    pyproject = (Path(__file__).resolve().parents[1] / "pyproject.toml").read_text(
        encoding="utf-8"
    )
    base, _, extras = pyproject.partition("[project.optional-dependencies]")

    assert "argostranslate" not in base
    assert "argostranslate" in extras
    assert "translation = [" in extras
