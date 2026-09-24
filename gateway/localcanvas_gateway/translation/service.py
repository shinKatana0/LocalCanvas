"""The stage between validation and binding: original text in, effective out.

The pipeline, in order, and it is the contract (T-0040):

    original text
      -> split into protected and translatable spans      (`spans.py`)
      -> detect the language of the translatable spans     (`detect.py`)
      -> translate only those, only if a supported source is present
      -> reassemble, protected spans copied verbatim
      -> effective text
      -> field binding

Four properties this module is written to guarantee, each of which a test pins:

* **an English prompt comes back byte-identical.**  Not similar, not tidied,
  not normalised -- the same string.  An optimised prompt full of model tags is
  the most valuable text a user types and the easiest thing in the world to
  ruin by "improving" it.
* **a quoted literal never reaches the translator.**  It is copied from the
  input to the output, with its quote characters, its Unicode, its case and its
  spacing.
* **spacing around a translated fragment survives.**  Each translatable span is
  split into leading whitespace, a core, and trailing whitespace; only the core
  is translated and the whitespace is re-attached verbatim.  Skipping this is
  measured to produce ``a man near a sign"...."cinematic lighting``.
* **the original is canonical.**  Both texts are returned; the effective text
  goes to binding and is never persisted as the user's prompt.  Nothing about
  the span bookkeeping appears in any response.

Which fields are eligible is the **workflow's** decision, never a guess about
whether a value "looks like a sentence": a field is translated only if its
definition says ``translatable: true``, which the schema allows on text fields
only (`docs/workflow-schema.md`).  Model names, checkpoints, LoRA filenames,
samplers, select identifiers, paths, ids and numbers therefore cannot be
reached from here at all.
"""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any, Dict, List, Mapping, Optional, Tuple

from ..workflows import TranslationMode, WorkflowDefinition
from .backends import ArgosTranslator, Translator
from .capability import LanguagePair, TranslationCapability
from .detect import detect_source, has_source_script
from .errors import TranslationFailed
from .spans import split_spans

if TYPE_CHECKING:  # pragma: no cover - import only for the annotation
    from ..config import PromptTranslationConfig

log = logging.getLogger(__name__)


@dataclass(frozen=True)
class FieldTranslation:
    """What happened to one field's text.  The original is the canonical one."""

    field_id: str
    original: str
    effective: str
    applied: bool
    source: Optional[str]
    target: str

    def to_view(self) -> Dict[str, Any]:
        """The documented per-field shape (`docs/api.md`)."""

        return {
            "original": self.original,
            "effective": self.effective,
            "translation": {
                "applied": self.applied,
                "source": self.source,
                "target": self.target,
            },
        }


@dataclass(frozen=True)
class TranslationResult:
    """The values binding should use, plus what the app is told about them."""

    #: Field id -> value, with translated fields replaced.  Every other value
    #: is the one validation produced, untouched.
    values: Dict[str, Any]
    fields: Tuple[FieldTranslation, ...] = ()

    @property
    def applied(self) -> bool:
        return any(item.applied for item in self.fields)

    def to_view(self) -> Dict[str, Any]:
        return {
            "applied": self.applied,
            "fields": {item.field_id: item.to_view() for item in self.fields},
        }


@dataclass(frozen=True)
class WarmUp:
    """What loading the models at startup did, and what it cost (T-0122).

    A duration rather than a flag, because the claim being made is about a
    duration: the trade this makes is "the gateway starts N seconds later so
    that nobody's first Generate does", and N belongs on the record where the
    person who starts the gateway can read it.
    """

    #: Pairs whose model is now loaded and will not be loaded again.
    loaded: Tuple[LanguagePair, ...] = ()
    #: Pairs that were installed and would not load.  Not advertised, not fatal.
    failed: Tuple[LanguagePair, ...] = ()
    #: Wall-clock seconds spent warming.  Zero when nothing was warmed.
    seconds: float = 0.0

    @property
    def attempted(self) -> bool:
        """Was anything warmed at all?  False on a PC with nothing to warm."""

        return bool(self.loaded or self.failed)


class TranslationService:
    """One configured translation stage, shared by every submission."""

    def __init__(
        self,
        config: "PromptTranslationConfig",
        translator: Optional[Translator] = None,
    ) -> None:
        self.config = config
        # Constructing the real backend costs nothing: it imports the extra on
        # its first translation, not here (`backends.py`).
        self.translator: Translator = (
            translator if translator is not None else ArgosTranslator()
        )
        #: What :meth:`prepare` found.  Empty until it has run, which is why
        #: running it is part of assembling the gateway rather than optional.
        self._pairs: Tuple[LanguagePair, ...] = ()
        #: What :meth:`warm` did and what it cost.  A gateway with nothing to
        #: warm has one of these too, saying so and costing nothing.
        self.warm_up: WarmUp = WarmUp()

    # -- what this PC can do, before anything is submitted -----------------

    def prepare(self) -> TranslationCapability:
        """Walk the installed language models **once, at startup** (T-0043).

        This is the expensive half of the capability and the reason it is not
        answered inside a request.  Reading which models are installed goes
        through the backend, and reaching the backend imports it -- 981 MB
        across ``stanza`` and ``torch`` (`backends.py`).  ``GET /api/v1/info``
        is inside the app's handshake timeout and is also the reconnect probe
        (`docs/recovery.md`), so it cannot be the thing that pays that.  A PC
        that has deliberately configured translation can pay it once, before
        the server starts listening, with nobody waiting on it.

        Nothing is imported here either unless this PC is actually set up to
        translate: a switched-off stage, or an absent extra, walks nothing.

        Called by ``build_gateway`` -- the one place a gateway is assembled --
        and safe to call again; it simply walks again.
        """

        self._pairs = (
            tuple(self.translator.installed_pairs(self.config.sources, self.config.target))
            if self.config.enabled and self.translator.installed()
            else ()
        )
        return self.capability()

    def warm(self) -> WarmUp:
        """Load the models :meth:`prepare` found, **before anyone submits** (T-0122).

        Walking the installed models does not load them.  The first sentence
        through a pair does, and on the PC this was found on that was 7.3 s
        inside ``POST /api/v1/jobs`` -- past the app's 8 s timeout, so the
        first person to press Generate after a start was told the server had
        not answered while their generation ran to completion.  Nothing about
        that cost is avoidable; where it is paid is entirely a choice, and this
        is it paid where somebody is already waiting for a service to start.

        Three rules, and each of them is a decision rather than an oversight:

        * **only pairs that are really there.**  The loop is over what
          :meth:`prepare` found, which is empty on a switched-off stage, on a
          PC without the extra, and on one with no model.  So a machine that
          does not translate warms nothing, imports nothing, and waits for
          nothing.  Nothing is ever downloaded here (`backends.py`).
        * **a failure is not fatal.**  A model that will not load means
          translation is unavailable; it does not mean the other forty-odd
          workflows go unserved.  The pair is dropped from what this PC
          advertises -- an unloadable model would fail every submission that
          used it -- logged, and reported by the caller.
        * **it is timed.**  What this trades is startup time for a first
          request that costs what the second one does, and the price belongs
          where it can be read rather than assumed.
        """

        if not self._pairs:
            return self._recorded(WarmUp())

        started = time.perf_counter()
        loaded: List[LanguagePair] = []
        failed: List[LanguagePair] = []
        for source, target in self._pairs:
            try:
                self.translator.warm(source, target)
            except Exception as exc:  # a backend failure of any kind
                log.warning(
                    "the %s->%s translation model did not load, so it will not be "
                    "used: %s",
                    source,
                    target,
                    exc,
                )
                failed.append((source, target))
            else:
                loaded.append((source, target))
        seconds = time.perf_counter() - started

        # What did not load is not advertised: `capability` reports the pairs
        # this gateway would really translate, and a model that raised on the
        # way up would raise again on a submission.
        self._pairs = tuple(loaded)
        log.info(
            "translation models loaded in %.1fs: %s",
            seconds,
            ", ".join("{}->{}".format(*pair) for pair in loaded) or "none",
        )
        return self._recorded(
            WarmUp(loaded=tuple(loaded), failed=tuple(failed), seconds=seconds)
        )

    def _recorded(self, warm_up: WarmUp) -> WarmUp:
        self.warm_up = warm_up
        return warm_up

    def capability(self) -> TranslationCapability:
        """An honest description of the stage on this PC (T-0043).

        Two of the three answers are **live**, and neither imports anything:
        ``enabled`` is read off the configuration, and ``installed`` off
        :meth:`Translator.installed`, which searches the path and stops there.
        A capability is a promise, and a remembered one goes on being made
        after it has stopped being true.

        ``pairs`` is the exception, and it is a deliberate one: it is what
        :meth:`prepare` found at startup, less anything :meth:`warm` then
        failed to load -- a model that will not load is a model this gateway
        would not translate with, and advertising it would promise the phone a
        language every submission then failed in (T-0122).  A model installed
        while the gateway runs therefore appears after a restart -- which is
        the same explicit setup step that installed it (`errors.py`), and the
        price of a handshake that imports nothing.  It is reported as empty
        whenever the live answers say nothing would be translated anyway, so a
        stage switched off after startup cannot go on advertising pairs.
        """

        installed = bool(self.translator.installed())
        return TranslationCapability(
            enabled=self.config.enabled,
            installed=installed,
            pairs=self._pairs if (self.config.enabled and installed) else (),
        )

    # -- the stage ---------------------------------------------------------

    def apply(
        self,
        workflow: WorkflowDefinition,
        values: Mapping[str, Any],
        *,
        translate: bool = True,
    ) -> TranslationResult:
        """Translate this workflow's translatable fields in ``values``.

        Switched off globally, or off for this workflow, the values are handed
        back exactly as they came in and no field is even examined -- so the
        response says nothing about fields the gateway did not look at.

        ``translate=False`` is the per-submission override (`docs/api.md`), and
        it is one more way to arrive at that same passthrough.  It **only ever
        subtracts**: it is a third condition on the same ``and``, so no value
        of it can translate a submission the configuration or the workflow had
        already decided against.  There is no way to ask for the opposite --
        the request vocabulary has one word and it is ``off`` -- because a
        client cannot switch on a stage the machine was never set up for
        (`docs/workflow-schema.md`).
        """

        if (
            not translate
            or not self.config.enabled
            or workflow.translation_mode is TranslationMode.OFF
        ):
            return TranslationResult(values=dict(values))

        translated: Dict[str, Any] = dict(values)
        entries: List[FieldTranslation] = []
        for field in workflow.inputs:
            if not field.translatable or field.id not in values:
                continue
            text = values[field.id]
            if not isinstance(text, str):  # pragma: no cover - the schema forbids it
                continue
            entry = self.translate_text(text, field_id=field.id)
            entries.append(entry)
            if entry.applied:
                translated[field.id] = entry.effective
        return TranslationResult(values=translated, fields=tuple(entries))

    def translate_text(self, text: str, *, field_id: str = "") -> FieldTranslation:
        """One field's text through the whole pipeline."""

        target = self.config.target
        if not self.config.enabled:
            # The switch is checked here as well as in :meth:`apply`, so that
            # no caller can reach the pipeline around the configuration.
            return FieldTranslation(
                field_id=field_id,
                original=text,
                effective=text,
                applied=False,
                source=None,
                target=target,
            )

        spans = split_spans(
            text, preserve_quoted_literals=self.config.preserve_quoted_literals
        )
        cores = [_trimmed(span.text)[1] for span in spans if not span.protected]

        source = detect_source("".join(cores), self.config.sources)
        if source is None or source == target:
            # Nothing supported and non-English is here.  The input is the
            # answer -- the same string, not a rebuilt copy of it.
            return FieldTranslation(
                field_id=field_id,
                original=text,
                effective=text,
                applied=False,
                source=None,
                target=target,
            )

        pieces: List[str] = []
        applied = False
        for span in spans:
            if span.protected:
                pieces.append(span.text)
                continue
            lead, core, trail = _trimmed(span.text)
            if not core or not has_source_script(core, source):
                # An English-only fragment between two literals is content the
                # user wrote and nobody asked to change.
                pieces.append(span.text)
                continue
            pieces.append(lead + self._translate(core, source, target) + trail)
            applied = True

        # Reassembly is a concatenation of a partition of the input, so this
        # reproduces the input exactly wherever nothing was translated.  The
        # stronger promise -- that a passthrough hands back the *same string*
        # rather than an equal one -- is kept by the early return above, which
        # is the path an English prompt actually takes.
        effective = "".join(pieces)
        return FieldTranslation(
            field_id=field_id,
            original=text,
            effective=effective,
            applied=applied,
            source=source if applied else None,
            target=target,
        )

    def _translate(self, core: str, source: str, target: str) -> str:
        answer = self.translator.translate(core, source=source, target=target)
        if not isinstance(answer, str):  # pragma: no cover - a broken backend
            log.error("the %s->%s backend returned %r", source, target, type(answer))
            raise TranslationFailed(
                "The translation model on the PC returned an unusable answer."
            )
        return answer


def _trimmed(text: str) -> Tuple[str, str, str]:
    """``(leading whitespace, core, trailing whitespace)``.

    Whitespace only.  Punctuation stays in the core, because a comma between
    two clauses belongs to the sentence being translated; the whitespace is
    what the translator drops.
    """

    stripped = text.strip()
    if not stripped:
        return text, "", ""
    lead = text[: len(text) - len(text.lstrip())]
    trail = text[len(text.rstrip()) :]
    return lead, stripped, trail


__all__ = ["FieldTranslation", "TranslationResult", "TranslationService", "WarmUp"]
