"""What this PC can actually translate, said before a submission (T-0043).

The stage is off unless configured and the backend is an optional install of
about a gigabyte, so "translation is not set up on this PC" is the *common*
case for an unrelated user.  Until this module existed the app could only find
that out by submitting and reading one of the three error codes back.

Three facts, and the reason each one is separate:

* ``enabled`` -- the machine's own configuration switch.  It is what decides
  whether the stage runs at all;
* ``installed`` -- whether the optional extra is present on this PC.  A machine
  with it **not installed** and one where it is installed and idle are two
  different situations with two different fixes, and only the first is fixed by
  installing the extra;
* ``pairs`` -- the language pairs that would really be used: the configured
  sources intersected with the models actually on disk.  Configured but not
  installed is not advertised, because it would not translate.

**Nothing here names a model, a file or a backend.**  This block is served to
an unrelated user's phone (`docs/privacy-security.md`), so it is
a description of capability and never of configuration internals: two booleans
and a list of ISO language codes.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Dict, Tuple

#: One ``(source, target)`` language pair.
LanguagePair = Tuple[str, str]


@dataclass(frozen=True)
class TranslationCapability:
    """The ``capabilities.translation`` block (`docs/api.md`)."""

    #: ``prompt_translation.enabled`` on this PC.
    enabled: bool = False
    #: The optional extra is importable here.  Answered without importing it.
    installed: bool = False
    #: Pairs this gateway would actually translate, source first.  Empty
    #: whenever the stage would translate nothing -- switched off, backend
    #: absent, or no model for any configured source.
    pairs: Tuple[LanguagePair, ...] = ()

    def to_view(self) -> Dict[str, Any]:
        """The serialised shape.  Two booleans and language codes, and that is all."""

        return {
            "enabled": self.enabled,
            "installed": self.installed,
            "pairs": [{"source": source, "target": target} for source, target in self.pairs],
        }


__all__ = ["LanguagePair", "TranslationCapability"]
