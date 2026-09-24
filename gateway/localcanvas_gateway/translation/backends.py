"""The translator seam, and the one real backend behind it.

:class:`Translator` is three lines wide on purpose: text in, text out, source
and target named.  Everything that makes translation *correct* -- literal
protection, whitespace, detection, which fields are eligible -- lives in
:mod:`localcanvas_gateway.translation.service` and is therefore testable
against a deterministic fake, with no model, no download and no 1 GB
environment (`fake.py`).

:class:`ArgosTranslator` is the local backend.  Two properties of it are
contract, not implementation:

* **the import is lazy.**  ``argostranslate`` pulls ``stanza`` and ``torch`` --
  measured at 981 MB across 70 packages -- so it is an optional extra and
  importing the gateway must never cost it.  Nothing at module scope here
  imports it, and constructing an :class:`ArgosTranslator` does not either: the
  import happens inside :meth:`ArgosTranslator.translate`, on the first
  translation actually asked for.  :meth:`ArgosTranslator.installed` is asked
  on every handshake and stays on the cheap side of that line -- it searches
  the path and never imports what it finds -- while
  :meth:`ArgosTranslator.installed_pairs` does read the models, and is reached
  only on a PC whose stage is switched on, where the same import is what the
  next generation would pay anyway.

  Lazy is not the same as *late*.  Looking a pair up does not load its weights:
  the first real translation does, and measured on a PC with ``ru->en``
  installed that is 7.3 s -- paid inside ``POST /api/v1/jobs`` while somebody
  waits with their thumb on Generate, and past the app's timeout (T-0122).  So
  :meth:`ArgosTranslator.warm` exists to pay it at startup, and it pays it by
  translating rather than by claiming to: the load a warm-up skipped is a load
  the first submission still pays.
* **it is local, and it is checked.**  ``argostranslate`` can be configured
  through its own environment variables to answer from a remote service.  That
  is refused here rather than used: LocalCanvas translates on the PC or reports
  that it cannot (`docs/privacy-security.md`).  No module in this package
  constructs an HTTP client or names an endpoint.

Model files are never downloaded at request time.  A missing language pair is
an error naming the explicit setup command, which is the only thing that
installs one.
"""

from __future__ import annotations

import importlib.util
import logging
import sys
from typing import Any, Dict, Iterable, Mapping, Protocol, Tuple

from .errors import (
    TranslationFailed,
    TranslationModelMissing,
    TranslationUnavailable,
    backend_missing,
)

log = logging.getLogger(__name__)

#: The provider name ``argostranslate`` gives its own local models.  Its other
#: providers reach a network service, and this module refuses them.
LOCAL_MODEL_PROVIDER = "OPENNMT"

#: The optional extra's own top-level module.  Named here for the presence
#: check below and imported nowhere at module scope.
BACKEND_MODULE = "argostranslate"

#: Distinguishes "not in ``sys.modules``" from an entry that is ``None``.
_NOT_IMPORTED = object()

#: One short phrase per source language, translated at startup to make the
#: backend load that pair's model before anybody is waiting for it (T-0122).
#:
#: It has to be written in the source language's own script, because that is
#: the text a real prompt would carry and the whole point is to walk the same
#: path.  Written as escapes so this source file stays ASCII; a source language
#: with no phrase here is a language the warm-up cannot walk, which is why
#: covering :data:`~localcanvas_gateway.translation.detect.SUPPORTED_SOURCES`
#: is pinned by a test rather than left to whoever adds the next one.
WARM_UP_TEXT: Mapping[str, str] = {
    # "Privet" -- hello.
    "ru": "\u041f\u0440\u0438\u0432\u0435\u0442",
    # "Konnichiwa" -- hello.
    "ja": "\u3053\u3093\u306b\u3061\u306f",
}


class Translator(Protocol):
    """Text in, text out -- plus the questions asked *before* a submission.

    ``translate`` is the seam T-0040 defined.  The next two exist because a
    client has to be able to learn what this PC can do without submitting
    anything (T-0043): whether the backend is here at all, and which language
    pairs it really has.  Both are read-only and neither may translate.

    ``warm`` is the fourth, and it is the one that *does* translate: it makes a
    backend load one pair's model at a moment of the gateway's choosing rather
    than inside the first person's ``POST /api/v1/jobs`` (T-0122).
    """

    def translate(self, text: str, *, source: str, target: str) -> str:
        ...  # pragma: no cover - protocol

    def installed(self) -> bool:
        """Is the backend present on this PC?"""

        ...  # pragma: no cover - protocol

    def installed_pairs(
        self, sources: Iterable[str], target: str
    ) -> Tuple[Tuple[str, str], ...]:
        """Which of ``sources`` can really be translated into ``target``."""

        ...  # pragma: no cover - protocol

    def warm(self, source: str, target: str) -> None:
        """Load whatever this pair's first translation would have to load.

        Raises on a pair that will not load -- what the caller does about that
        is its decision, and it is never to stop the gateway.
        """

        ...  # pragma: no cover - protocol


class ArgosTranslator:
    """Argos Translate, imported lazily and used strictly locally."""

    def __init__(self) -> None:
        # (source, target) -> the backend's translation object.  Loading one
        # reads a model off disk, so a second field in the same submission does
        # not pay for it twice.
        self._pairs: Dict[Tuple[str, str], Any] = {}

    def translate(self, text: str, *, source: str, target: str) -> str:
        translation = self._pair(source, target)
        try:
            result = translation.translate(text)
        except Exception as exc:  # the backend's own failure, whatever it is
            log.error("translation %s->%s failed: %s", source, target, exc)
            raise TranslationFailed(
                "The translation model on the PC could not translate this text."
            ) from exc
        if not isinstance(result, str):
            raise TranslationFailed(
                "The translation model on the PC returned an unusable answer."
            )
        return result

    # -- paying the model load early ---------------------------------------

    def warm(self, source: str, target: str) -> None:
        """Translate one short phrase, so the model is loaded and stays loaded.

        **It really translates.**  Looking the pair up is not what costs the
        7.3 s measured on a PC with ``ru->en`` installed -- the first sentence
        through it is, because that is what reads the weights off disk and
        builds the sentence splitter.  A warm-up that only looked the pair up
        would leave the cost exactly where T-0122 found it, in the first
        submission, and would still look like it had done its job.

        The phrase is in ``source``'s own script, because a warm-up that walks
        a different path from a prompt warms a different thing.  Nothing about
        it is kept: the answer is thrown away, and what is left behind is the
        loaded model inside the backend.
        """

        text = WARM_UP_TEXT.get(source)
        if text is None:
            # A source language nobody wrote a phrase for.  Loading the pair is
            # what can still be done for it honestly; the caller sees the same
            # failure it would see for a broken model if even that fails.
            self._pair(source, target)
            return
        self.translate(text, source=source, target=target)

    # -- what can be translated here, asked before anything is submitted ----

    def installed(self) -> bool:
        """Is the extra installed on this PC?  **Without importing it.**

        ``find_spec`` searches the path and stops there, so the answer to a
        question the app asks on every handshake never costs the 981 MB import
        the lazy rule above exists to avoid.

        An entry already in ``sys.modules`` is the answer, and is read first:
        it is what a machine that has translated once has, and a ``None`` there
        is the documented way to make the import fail, which is a PC the extra
        cannot be imported on however the path looks.  Nothing about a module
        this cannot describe is guessed at -- an unusable entry is reported as
        absent, which is what the next translation would find too.
        """

        module = sys.modules.get(BACKEND_MODULE, _NOT_IMPORTED)
        if module is not _NOT_IMPORTED:
            return module is not None
        try:
            return importlib.util.find_spec(BACKEND_MODULE) is not None
        except (ImportError, ValueError):
            return False

    def installed_pairs(
        self, sources: Iterable[str], target: str
    ) -> Tuple[Tuple[str, str], ...]:
        """The pairs among ``sources`` that have a model on this PC, in order.

        Read-only: it looks a pair up exactly as a translation would and
        translates nothing.  Every documented way a lookup can fail -- no
        extra, no model, a remote provider, an unreadable install -- means the
        gateway would not translate that pair, so it is left out rather than
        advertised.  Nothing is ever downloaded to answer this.
        """

        if not self.installed():
            return ()
        found = []
        for source in sources:
            if source == target:
                continue
            try:
                self._pair(source, target)
            except (TranslationUnavailable, TranslationModelMissing, TranslationFailed):
                continue
            found.append((source, target))
        return tuple(found)

    # -- the lazy part -----------------------------------------------------

    def _pair(self, source: str, target: str) -> Any:
        cached = self._pairs.get((source, target))
        if cached is not None:
            return cached

        argos_translate, settings = self._import()
        # A backend that reports no provider at all is taken at its word as a
        # local one: the extra pins a version that reports one, so the silent
        # case is an older install, not a remote service that hid itself.
        provider = getattr(getattr(settings, "model_provider", None), "name", None)
        if provider is not None and provider != LOCAL_MODEL_PROVIDER:
            raise TranslationUnavailable(
                "Translation on the PC is configured to use a remote provider, which "
                "LocalCanvas will not use. Unset ARGOS_MODEL_PROVIDER on the PC to "
                "translate locally."
            )

        try:
            from_language = argos_translate.get_language_from_code(source)
            to_language = argos_translate.get_language_from_code(target)
            pair = (
                None
                if from_language is None or to_language is None
                else from_language.get_translation(to_language)
            )
        except Exception as exc:  # pragma: no cover - depends on the install
            log.error("looking up the %s->%s model failed: %s", source, target, exc)
            raise TranslationFailed(
                "The translation models on the PC could not be read."
            ) from exc

        if pair is None:
            raise TranslationModelMissing(source, target)

        self._pairs[(source, target)] = pair
        return pair

    @staticmethod
    def _import():
        """Import the extra, or say how to install it.  Never at module scope."""

        try:
            from argostranslate import settings, translate as argos_translate
        except ImportError as exc:
            raise backend_missing() from exc
        return argos_translate, settings


__all__ = [
    "BACKEND_MODULE",
    "LOCAL_MODEL_PROVIDER",
    "WARM_UP_TEXT",
    "ArgosTranslator",
    "Translator",
]
