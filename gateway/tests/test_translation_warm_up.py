"""The first generation must not be the slow one (T-0122).

A person pressed Generate on a phone, was told *"The server didn't answer."*,
and concluded their network was broken.  It was not: translation runs during
job submission, that submission was the first one after a gateway start, and
loading the language model took longer than the app's 8 s job timeout.  The
generation ran to completion; nobody was listening by then.

So this file is about a **duration**, and every claim in it is measured rather
than asserted about a call:

* the first translated submission after a start, and a later one, are timed and
  compared -- an implementation that warmed nothing, or warmed on first use,
  fails on the numbers;
* the same translator, prepared but not warmed, is timed too -- so the load
  this file is about is proved to be real and payable, rather than a fixture
  that would pass whatever the gateway did (T-0182);
* what warming cost at startup is read back and compared with the wall clock
  that contains it.

The translator below is the one thing here that is not real: it has a model
that takes a measurable, fixed time to load, once, exactly like the backend
that produced the bug -- and it does not know or care whether the warm-up or
the first submission is what triggers the load.  That indifference is what
makes the measurements mean something.
"""

from __future__ import annotations

import time
from pathlib import Path
from typing import Any, Iterable, List, Optional, Tuple

import pytest

import localcanvas_gateway
from localcanvas_gateway.api import translation_summary
from localcanvas_gateway.config import PromptTranslationConfig
from localcanvas_gateway.translation.backends import WARM_UP_TEXT, ArgosTranslator
from localcanvas_gateway.translation.detect import SUPPORTED_SOURCES, has_source_script
from localcanvas_gateway.translation.errors import TranslationFailed
from localcanvas_gateway.translation.service import TranslationService, WarmUp

#: How long this file's model takes to load.  Long enough to tell apart from
#: everything else a submission does on a loaded machine, short enough that a
#: handful of them do not change what the suite costs.
LOAD_SECONDS = 0.8

#: What a request that did **not** load a model has to come in under.  A
#: quarter of the load, so the gap being measured is a factor of four and not a
#: few milliseconds of scheduling noise.
NO_LOAD_SECONDS = LOAD_SECONDS / 4

#: How far under ``LOAD_SECONDS`` a wall-clock measurement of a load may read
#: and still be a load that was paid (T-0194).
#:
#: A load here is ``time.sleep(LOAD_SECONDS)``, and on Windows the sleep and
#: ``time.perf_counter`` are not the same clock: the sleep is a wait counted in
#: timer ticks, the measurement is QueryPerformanceCounter, and the wait can
#: end before the counter says the interval is over.  Observed failing this
#: file's assertions in full-suite runs: 24 us and 18 us short (T-0194), 144 us
#: short (T-0269).  Measured for this constant on the same machine, Python
#: 3.10: 1020 sleeps of ``LOAD_SECONDS`` timed with ``perf_counter``, quiet and
#: beside a busy loop on half the cores, at the default and at a 1 ms timer
#: period -- 11 came back early, the worst by 840.6 us.
#:
#: 10 ms is about twelve times that worst case, and no defect this file is
#: about lives inside it.  Measured with a warm-up that never loads, 80 times:
#: it reports 1.3 to 6.7 us, and the whole assembly around it takes 15.9 to
#: 99.9 ms -- both far under ``NO_LOAD_SECONDS``, let alone ``LOAD_SECONDS``
#: less this.
SLEEP_SHORTFALL_SECONDS = 0.01

#: How far a reported warm-up may exceed the startup that contains it (T-0141).
#:
#: Unlike the sleep above, these two are the same clock: the warm-up times
#: itself with ``time.perf_counter`` and ``timed`` times the assembly around it
#: with ``time.perf_counter``, which is monotonic, so the startup's two
#: readings bracket the warm-up's.  What is left is rounding each reading to a
#: float: the gap between adjacent floats at this machine's counter value
#: measured 2.9e-11 s.  So this is a tolerance and not a shared reading: a
#: shared reading would mean replacing the ``time`` the service module sees,
#: which pins the test to how the service happens to call its clock.
#:
#: 1 us is thousands of times that rounding, and far below the real gap the
#: containment leaves: the assembly outside the warm-up measured at least
#: 13.7 ms (80 assemblies beside a busy loop on half the cores; 15.8 ms over
#: 100 quiet ones).  A warm-up inflating its number by less than that gap is
#: invisible to this comparison whatever the tolerance.
SAME_CLOCK_ROUNDING_SECONDS = 1e-6

RUSSIAN = "ночной Токио"
RUSSIAN_IN_ENGLISH = "Tokyo at night"

FIELDS = """
- id: prompt
  label: Prompt
  type: multiline
  required: true
  translatable: true
  bind:
    node: "20"
    input: text
"""


# ==========================================================================
# Provenance: which checkout is being measured
# ==========================================================================


def test_the_measurements_are_about_this_checkout() -> None:
    """The package under test is the one beside these tests, and not another.

    An editable install of this project maps ``localcanvas_gateway`` to
    whichever checkout it was installed from, through a meta-path finder that
    knows nothing about worktrees -- measured: ``import localcanvas_gateway``
    outside pytest, from this very directory, resolves to another checkout
    entirely.  What keeps the suite honest is ``gateway/conftest.py``, one
    level above this one, which puts the gateway root on ``sys.path``; the
    ``conftest.py`` beside these tests inserts nothing and is not the
    mechanism.

    That is a chain of two things going right, and the numbers this file
    reports are worth nothing if either stops -- so which package was really
    imported is asserted rather than assumed, once, where the failure is
    readable.
    """

    imported = Path(localcanvas_gateway.__file__).resolve()
    expected = (Path(__file__).resolve().parents[1] / "localcanvas_gateway").resolve()

    assert imported.parent == expected, (
        "these tests imported {} but sit beside {}: run them with the gateway "
        "directory on sys.path (python -m pytest from it)".format(imported, expected)
    )


# ==========================================================================
# A translator with a model that really takes time to load
# ==========================================================================


class SlowToLoad:
    """A backend whose pair costs :attr:`load_seconds` the first time, once.

    The shape of the real one: looking a pair up is free, the first sentence
    through it reads the model, and everything after that is fast.  Whether
    that first sentence is a warm-up or somebody's prompt is not this class's
    business, which is the point -- it charges whoever gets there first.
    """

    def __init__(
        self,
        *,
        pairs: Iterable[Tuple[str, str]] = (("ru", "en"),),
        load_seconds: float = LOAD_SECONDS,
        load_fails: Optional[Exception] = None,
    ) -> None:
        self.pairs = tuple(pairs)
        self.load_seconds = load_seconds
        self.load_fails = load_fails
        #: One entry per model actually loaded, so a second load would show.
        self.loads: List[Tuple[str, str]] = []
        #: Texts handed over as *translations*, in order.
        self.texts: List[str] = []
        #: One entry per warm-up asked for, in order.
        self.warm_ups: List[Tuple[str, str]] = []
        self._loaded: set = set()

    # -- the seam ----------------------------------------------------------

    def translate(self, text: str, *, source: str, target: str) -> str:
        self._load(source, target)
        self.texts.append(text)
        return RUSSIAN_IN_ENGLISH if text == RUSSIAN else "[{}]".format(text)

    def installed(self) -> bool:
        return True

    def installed_pairs(
        self, sources: Iterable[str], target: str
    ) -> Tuple[Tuple[str, str], ...]:
        # Free, like the real walk relative to a load: it says which models are
        # there, and reads none of them.
        return tuple(
            (source, target) for source in sources if (source, target) in self.pairs
        )

    def warm(self, source: str, target: str) -> None:
        self.warm_ups.append((source, target))
        self._load(source, target)

    # -- the model -----------------------------------------------------------

    def _load(self, source: str, target: str) -> None:
        if (source, target) in self._loaded:
            return
        time.sleep(self.load_seconds)
        if self.load_fails is not None:
            raise self.load_fails
        self._loaded.add((source, target))
        self.loads.append((source, target))


def timed(call) -> Tuple[Any, float]:
    """Run it and say what it took.  Wall clock, because that is the complaint."""

    started = time.perf_counter()
    result = call()
    return result, time.perf_counter() - started


def translating_gateway(gateway_factory, builder, translator, *, enabled: bool = True):
    """Assemble a gateway around ``translator`` and time the assembly."""

    builder.add("flow", FIELDS)
    return timed(
        lambda: gateway_factory(
            prompt_translation=PromptTranslationConfig(enabled=enabled),
            translator=translator,
        )
    )


# ==========================================================================
# The measurement the card is about
# ==========================================================================


def test_the_first_translated_submission_costs_what_a_later_one_costs(
    gateway_factory, builder
) -> None:
    """Both are timed, and both have to be nowhere near a model load.

    This is the whole bug, in the units the user experienced it in.  An
    implementation that never warms, or warms on first use, pays
    ``LOAD_SECONDS`` in the first ``POST /api/v1/jobs`` and fails here on the
    first number -- and one that warms *after* reporting itself ready fails on
    the third, because the load has to be inside the assembly.
    """

    translator = SlowToLoad()
    harness, startup = translating_gateway(gateway_factory, builder, translator)

    first, first_seconds = timed(lambda: harness.submit("flow", {"prompt": RUSSIAN}))
    second, second_seconds = timed(lambda: harness.submit("flow", {"prompt": RUSSIAN}))

    assert first.status_code == 201, first.text
    assert second.status_code == 201, second.text
    # Translation really happened on both, so these are the durations of the
    # path the bug is on and not of a submission that skipped it.
    assert translator.texts == [RUSSIAN, RUSSIAN]
    assert first.json()["translation"]["applied"] is True

    assert first_seconds < NO_LOAD_SECONDS, (
        "the first translated submission after a start paid {:.2f}s -- a model "
        "load, in the request the app gives up on".format(first_seconds)
    )
    assert second_seconds < NO_LOAD_SECONDS, second_seconds
    assert startup >= LOAD_SECONDS - SLEEP_SHORTFALL_SECONDS, (
        "the model load has to be inside starting up, and startup took only "
        "{:.2f}s".format(startup)
    )
    # Loaded once, by the warm-up, and never again.
    assert translator.loads == [("ru", "en")]


def test_without_the_warm_up_that_same_first_submission_is_the_slow_one() -> None:
    """The fixture is proved able to fail the test above (T-0182).

    Prepared and not warmed is exactly what the gateway did before T-0122: the
    models are known, none is loaded, and the first field through the stage
    pays for it.  Without this, "the first submission was fast" could be a
    statement about a translator that was never slow.
    """

    service = TranslationService(
        PromptTranslationConfig(enabled=True), translator=SlowToLoad()
    )
    service.prepare()

    _, first_seconds = timed(lambda: service.translate_text(RUSSIAN))
    _, second_seconds = timed(lambda: service.translate_text(RUSSIAN))

    assert first_seconds >= LOAD_SECONDS - SLEEP_SHORTFALL_SECONDS, first_seconds
    assert second_seconds < NO_LOAD_SECONDS, second_seconds


def test_warming_moves_that_cost_and_nothing_else() -> None:
    """The same service, warmed, pays it before the first text arrives."""

    service = TranslationService(
        PromptTranslationConfig(enabled=True), translator=SlowToLoad()
    )
    service.prepare()

    _, warm_seconds = timed(service.warm)
    _, first_seconds = timed(lambda: service.translate_text(RUSSIAN))

    assert warm_seconds >= LOAD_SECONDS - SLEEP_SHORTFALL_SECONDS, warm_seconds
    assert first_seconds < NO_LOAD_SECONDS, first_seconds


# ==========================================================================
# What it cost, said out loud
# ==========================================================================


def test_the_startup_cost_of_warming_is_measured_and_reported(
    gateway_factory, builder
) -> None:
    """A trade on the record: N seconds of startup for a first request that is
    not the slow one.

    The number reported is compared with the wall clock that contains it, so a
    warm-up reporting a duration it did not spend is caught in both directions.
    """

    translator = SlowToLoad()
    harness, startup = translating_gateway(gateway_factory, builder, translator)
    warm_up = harness.state.translation.warm_up

    assert warm_up.loaded == (("ru", "en"),)
    assert warm_up.failed == ()
    assert warm_up.attempted is True
    assert warm_up.seconds >= LOAD_SECONDS - SLEEP_SHORTFALL_SECONDS, warm_up.seconds
    assert warm_up.seconds <= startup + SAME_CLOCK_ROUNDING_SECONDS, (
        "warming cannot have taken longer than the assembly that contains it: "
        "{:.2f}s reported inside {:.2f}s".format(warm_up.seconds, startup)
    )

    # And the pairs are still named, as they were before warming existed, with
    # the price beside them.
    capability = harness.state.translation.capability()
    assert capability.pairs == (("ru", "en"),)
    assert translation_summary(capability, warm_up) == "ru->en (models loaded in {:.1f}s)".format(
        warm_up.seconds
    )


def test_a_capability_described_without_a_warm_up_reads_as_it_always_did() -> None:
    """The line is unchanged wherever there is nothing new to say."""

    from localcanvas_gateway.translation.capability import TranslationCapability

    pairs = TranslationCapability(enabled=True, installed=True, pairs=(("ru", "en"),))

    assert translation_summary(pairs) == "ru->en"
    assert translation_summary(pairs, WarmUp()) == "ru->en"
    assert translation_summary(TranslationCapability(), WarmUp()) == "off"
    assert (
        translation_summary(TranslationCapability(enabled=True), WarmUp())
        == "switched on, but not installed on this PC"
    )
    assert (
        translation_summary(
            TranslationCapability(enabled=True, installed=True), WarmUp()
        )
        == "switched on, but no language models are installed on this PC"
    )


# ==========================================================================
# The machines that must warm nothing
# ==========================================================================


@pytest.mark.parametrize(
    "enabled, installed_pairs, warmed",
    [
        # The control, and it is here so that the two absences below are
        # absences of something this fixture demonstrably does.
        (True, (("ru", "en"),), [("ru", "en")]),
        (False, (("ru", "en"),), []),
        (True, (), []),
    ],
    ids=["a pc that translates", "translation switched off", "no model installed"],
)
def test_only_a_pc_that_would_translate_warms_anything(
    gateway_factory, builder, enabled, installed_pairs, warmed
) -> None:
    """Nothing is loaded for a pair nobody installed, or a stage nobody asked for.

    Measured as well as recorded: a machine with nothing to warm must not spend
    a model load's worth of time discovering that.
    """

    translator = SlowToLoad(pairs=installed_pairs)
    harness, startup = translating_gateway(
        gateway_factory, builder, translator, enabled=enabled
    )
    warm_up = harness.state.translation.warm_up

    assert translator.warm_ups == warmed
    assert translator.loads == warmed
    if warmed:
        assert startup >= LOAD_SECONDS - SLEEP_SHORTFALL_SECONDS, startup
        assert warm_up.attempted is True
    else:
        assert startup < LOAD_SECONDS, (
            "a PC with nothing to warm paid {:.2f}s at startup".format(startup)
        )
        assert warm_up == WarmUp(), warm_up
        assert warm_up.seconds == 0.0


def test_a_switched_off_pc_says_nothing_new_at_startup(tmp_path, builder) -> None:
    """And the terminal output is the one it has always been.

    The CLI is run end to end here, so this is the block a person really sees.
    """

    from test_main_cli import run, write_config
    from workflow_fixtures import EVERY_FIELD

    builder.add("flow", EVERY_FIELD)
    config = write_config(tmp_path, builder.root)

    code, out, _ = run(["--config", str(config), "--no-mdns", "--no-qr"])

    assert code == 0
    assert "[ OK ] Translation: off" in out
    assert "loaded in" not in out
    assert "warm" not in out.lower()


# ==========================================================================
# A model that will not load
# ==========================================================================


@pytest.fixture
def broken_model(gateway_factory, builder):
    """A PC whose installed model raises when it is asked to load.

    ``load_seconds=0`` because what is under test here is the outcome, not a
    duration; the pair is found by the walk and dies on the load, which is the
    case the walk cannot detect.
    """

    translator = SlowToLoad(
        load_seconds=0.0,
        load_fails=TranslationFailed("The translation models on the PC could not be read."),
    )
    harness, _ = translating_gateway(gateway_factory, builder, translator)
    return harness


def test_a_model_that_will_not_load_does_not_stop_the_gateway(broken_model) -> None:
    """Forty-odd workflows do not go unserved because one model is broken.

    The registry is asked over HTTP, not read off the state object: what has to
    survive is the gateway a phone talks to.
    """

    response = broken_model.client.get("/api/v1/workflows")

    assert response.status_code == 200, response.text
    assert [item["id"] for item in response.json()["workflows"]] == ["flow"]


def test_a_model_that_will_not_load_is_reported_unavailable(broken_model) -> None:
    """It is not advertised, because it would fail every submission that used it.

    The shape of the block is the app's contract (`docs/api.md`) and is
    unchanged: the same two booleans and the same list, with nothing in it.
    """

    block = broken_model.client.get("/api/v1/info").json()["capabilities"]["translation"]

    assert block == {"enabled": True, "installed": True, "pairs": []}

    warm_up = broken_model.state.translation.warm_up
    assert warm_up.failed == (("ru", "en"),)
    assert warm_up.loaded == ()
    assert (
        translation_summary(broken_model.state.translation.capability(), warm_up)
        == "switched on, but ru->en would not load on this PC"
    )


def test_a_pair_that_loads_beside_one_that_does_not_is_still_offered(
    gateway_factory, builder
) -> None:
    """One broken model is not every model.

    Written because the cheap way to implement the test above -- drop the whole
    capability when anything fails -- passes it and takes a working language
    away from the user with it.
    """

    class OneBrokenPair(SlowToLoad):
        def _load(self, source: str, target: str) -> None:
            if source == "ja":
                raise TranslationFailed("This model is unusable.")
            super()._load(source, target)

    translator = OneBrokenPair(
        pairs=(("ru", "en"), ("ja", "en")), load_seconds=0.0
    )
    harness, _ = translating_gateway(gateway_factory, builder, translator)
    warm_up = harness.state.translation.warm_up

    assert warm_up.loaded == (("ru", "en"),)
    assert warm_up.failed == (("ja", "en"),)
    assert harness.state.translation.capability().pairs == (("ru", "en"),)
    assert (
        translation_summary(harness.state.translation.capability(), warm_up)
        == "ru->en (models loaded in {:.1f}s); ja->en would not load on this PC".format(
            warm_up.seconds
        )
    )


# ==========================================================================
# The real backend's warm-up is a translation, not a lookup
# ==========================================================================


class Recorder:
    """Stands in for one loaded ``argostranslate`` translation object."""

    def __init__(self) -> None:
        self.texts: List[str] = []

    def translate(self, text: str) -> str:
        self.texts.append(text)
        return "warmed"


def test_the_local_backend_warms_by_translating(monkeypatch) -> None:
    """Looking the pair up is not what costs 7.3 s -- the first sentence is.

    A warm-up that only resolved the pair would leave the load exactly where
    T-0122 found it, in the first submission, while looking like it had done
    its job.  So what the backend hands the model is asserted verbatim.

    Nothing is imported here: the pair is already in the backend's cache, which
    is what an installed model looks like after the walk at startup.
    """

    backend = ArgosTranslator()
    recorder = Recorder()
    backend._pairs[("ru", "en")] = recorder

    backend.warm("ru", "en")

    assert recorder.texts == [WARM_UP_TEXT["ru"]]


def test_every_supported_source_has_a_phrase_in_its_own_script() -> None:
    """A phrase in the wrong script warms a path no prompt would take.

    And a source language with no phrase at all cannot be warmed, so the two
    lists are pinned together rather than left to whoever adds the next
    language.
    """

    assert set(WARM_UP_TEXT) == set(SUPPORTED_SOURCES)
    for source, text in WARM_UP_TEXT.items():
        assert has_source_script(text, source), (source, text)
