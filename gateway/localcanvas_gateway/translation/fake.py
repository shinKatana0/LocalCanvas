"""A deterministic translator, and the reason every logic test uses one.

The real backend is a neural model behind a 1 GB optional install.  Nothing
about *this* gateway's correctness -- which spans are protected, which fields
are eligible, that whitespace survives, that an English prompt comes back
byte-identical, that translation happens before binding -- depends on the
quality of a translation.  So the whole of it is tested against this, and the
suite passes with the extra absent, which is an acceptance criterion of T-0040
rather than a convenience.

Two properties make it useful as a test instrument:

* **it records every call.**  A test can assert what was handed to the
  translator, which is the only way to prove that a protected literal or an
  English-only fragment was never given to it at all.
* **it marks what it touched.**  Text it has no phrase for comes back wrapped
  in ``[ru>en ...]``, so a fragment that was translated when it should not have
  been is visible in the assertion rather than plausible.

It answers the capability half of the seam (T-0043) from the same two fields,
so a fixture states a machine's situation once and both halves agree with it:

* a translator **taught** a pair has that pair installed;
* one whose :attr:`fails_with` is a :class:`TranslationUnavailable` is a PC
  with no backend at all -- which is what that error means -- and reports both
  ``installed`` false and no pairs;
* one taught nothing is the third machine: the extra installed, no model for
  anything, and therefore nothing it can translate.
"""

from __future__ import annotations

from dataclasses import dataclass, field as dataclass_field
from typing import Dict, Iterable, List, Mapping, Optional, Tuple

from .errors import TranslationUnavailable


@dataclass(frozen=True)
class Call:
    """One request the service made of the translator."""

    text: str
    source: str
    target: str


@dataclass
class FakeTranslator:
    """A dictionary lookup with a loud fallback.  No model, no network."""

    #: ``(source, target, text)`` -> the answer.  Anything not listed gets the
    #: marker below, which is deliberately impossible to mistake for prose.
    phrases: Mapping[Tuple[str, str, str], str] = dataclass_field(default_factory=dict)
    calls: List[Call] = dataclass_field(default_factory=list)
    #: One ``(sources, target)`` per :meth:`installed_pairs` call, in order.
    pair_walks: List[Tuple[Tuple[str, ...], str]] = dataclass_field(default_factory=list)
    #: One ``(source, target)`` per :meth:`warm` call, in order.  Kept apart
    #: from :attr:`calls`, which answers a different question: what a
    #: *submission* handed to the translator.  A warm-up is not a submission,
    #: and a test that says "this prompt was never translated" must go on
    #: meaning that on a PC that warmed its models at startup.
    warm_ups: List[Tuple[str, str]] = dataclass_field(default_factory=list)
    #: When set, every call raises it.  How a backend failure is exercised.
    fails_with: Optional[Exception] = None

    def translate(self, text: str, *, source: str, target: str) -> str:
        self.calls.append(Call(text=text, source=source, target=target))
        if self.fails_with is not None:
            raise self.fails_with
        answer = self.phrases.get((source, target, text))
        if answer is not None:
            return answer
        return "[{}>{} {}]".format(source, target, text)

    # -- the capability half of the seam ------------------------------------

    def installed(self) -> bool:
        return not isinstance(self.fails_with, TranslationUnavailable)

    def installed_pairs(
        self, sources: Iterable[str], target: str
    ) -> Tuple[Tuple[str, str], ...]:
        # Recorded, because *how often* this is asked is the thing under test:
        # on the real backend it is the call that imports 981 MB, so a test can
        # prove it happened once at startup and never in a request (T-0043).
        sources = tuple(sources)
        self.pair_walks.append((sources, target))
        if not self.installed():
            return ()
        taught = {(source, to) for source, to, _ in self.phrases}
        return tuple(
            (source, target) for source in sources if (source, target) in taught
        )

    def warm(self, source: str, target: str) -> None:
        """Record it, and fail exactly where the real backend would.

        This double has no model to load, so warming it costs nothing; the
        *cost* of a warm-up is measured against a translator that has one
        (see the gateway's own timing tests).  What it does carry faithfully is
        the failure: a backend that cannot answer cannot be warmed either, and
        :attr:`fails_with` is how a PC whose model will not load is stated.
        """

        self.warm_ups.append((source, target))
        if self.fails_with is not None:
            raise self.fails_with

    # -- what a test asks it -----------------------------------------------

    @property
    def texts(self) -> List[str]:
        """Everything that was handed to the translator, in order."""

        return [call.text for call in self.calls]

    def teach(self, source: str, target: str, text: str, answer: str) -> "FakeTranslator":
        """Add one phrase.  Returns self, so a fixture can chain."""

        phrases: Dict[Tuple[str, str, str], str] = dict(self.phrases)
        phrases[(source, target, text)] = answer
        self.phrases = phrases
        return self


__all__ = ["Call", "FakeTranslator"]
