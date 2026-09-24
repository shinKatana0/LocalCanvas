"""Local prompt translation, before binding (`docs/api.md`, `docs/architecture.md`).

One stage, inserted between "the values validate" and "the values are written
into a copy of the graph".  Nothing downstream of it learns that it exists: the
binder is handed text, and ComfyUI is handed a graph.

    original text -> [protect literals -> detect -> translate -> reassemble] -> effective text -> binding

Three facts about this package that are load-bearing rather than incidental:

* **importing it costs nothing.**  The backend that needs ``argostranslate``
  -- and through it ``stanza`` and ``torch``, measured at 981 MB -- imports the
  package inside the method that translates.  The gateway's own suite runs, in
  full, with the ``translation`` extra absent, and that is an acceptance
  criterion of T-0040, not a convenience.
* **no network, ever.**  Nothing here constructs an HTTP client or names an
  endpoint, no failure is recoverable by reaching a service, and the local
  backend refuses to run if it has been configured to answer remotely
  (`backends.py`).  Language models are installed by an explicit setup step and
  never downloaded by a generation request.
* **the original is canonical.**  Translation produces an *effective* text for
  binding.  What the app shows, what a draft keeps and what Generate Again
  resubmits is the text the user typed.

Where each rule lives: literal protection in :mod:`.spans`, language detection
in :mod:`.detect`, the pipeline and field eligibility in :mod:`.service`, the
backend seam in :mod:`.backends`, what this PC can translate at all in
:mod:`.capability`, the deterministic test double in :mod:`.fake` and the three
error codes in :mod:`.errors`.

**:class:`~.service.TranslationService` is imported from its own module, not
re-exported here.**  It is the one part of this package that knows what a
workflow is, and re-exporting it would make importing *anything* here pull the
workflow registry in behind it -- including a configuration read, which
``config.py`` performs to validate ``prompt_translation.sources`` and which
``test_config.py`` pins as a leaf.  So the seam, the scanner, the detector and
the errors are here, and the stage is one import further in.
"""

from .backends import BACKEND_MODULE, ArgosTranslator, Translator
from .capability import LanguagePair, TranslationCapability
from .detect import SUPPORTED_SOURCES, detect_source, has_source_script
from .errors import (
    INSTALL_COMMAND,
    TranslationFailed,
    TranslationModelMissing,
    TranslationUnavailable,
    backend_missing,
    model_command,
)
from .spans import Span, split_spans

__all__ = [
    "ArgosTranslator",
    "BACKEND_MODULE",
    "INSTALL_COMMAND",
    "LanguagePair",
    "SUPPORTED_SOURCES",
    "Span",
    "TranslationCapability",
    "TranslationFailed",
    "TranslationModelMissing",
    "TranslationUnavailable",
    "Translator",
    "backend_missing",
    "detect_source",
    "has_source_script",
    "model_command",
    "split_spans",
]
