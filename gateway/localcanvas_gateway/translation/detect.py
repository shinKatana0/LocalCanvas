"""Which supported language a piece of prompt text is written in.

Script-based and deliberately conservative (T-0040).  There is no statistical
language detector here and no model: detection decides whether text is handed
to a translator at all, so a confident wrong answer is far more expensive than
"I do not know", which simply leaves the text alone.

The rules, and the whole of them:

* **Cyrillic present** -> Russian is a candidate;
* **Hiragana or Katakana present** -> Japanese is a candidate;
* **Han characters alone are ambiguous** and are *not* enough to call text
  Japanese.  The same characters are Chinese, and a Han-only string in a prompt
  is as likely to be a name or a piece of typography as a sentence.  Text with
  no kana therefore stays untranslated unless some other script decides it.

When more than one candidate's script is present in one field, the **configured
``sources`` order decides**, first match wins.  It is an arbitrary case with no
right answer; what matters is that it is deterministic and written down.

Nothing outside :data:`SOURCE_SCRIPTS` can be a source, which is why
``prompt_translation.sources`` is validated against exactly these codes: a
language this module cannot recognise is one the gateway could only guess at.
"""

from __future__ import annotations

from typing import Callable, Iterable, Mapping, Optional, Sequence, Tuple

#: ``(first, last)`` inclusive code point ranges, by script.
_CYRILLIC_RANGES: Tuple[Tuple[int, int], ...] = (
    (0x0400, 0x04FF),  # Cyrillic
    (0x0500, 0x052F),  # Cyrillic Supplement
    (0x2DE0, 0x2DFF),  # Cyrillic Extended-A
    (0xA640, 0xA69F),  # Cyrillic Extended-B
)

_KANA_RANGES: Tuple[Tuple[int, int], ...] = (
    (0x3040, 0x309F),  # Hiragana
    (0x30A0, 0x30FF),  # Katakana
    (0x31F0, 0x31FF),  # Katakana Phonetic Extensions
    (0xFF66, 0xFF9D),  # Halfwidth Katakana
)

#: Han.  Present for the rule it does *not* trigger: see the module docstring.
_HAN_RANGES: Tuple[Tuple[int, int], ...] = (
    (0x3400, 0x4DBF),  # CJK Unified Ideographs Extension A
    (0x4E00, 0x9FFF),  # CJK Unified Ideographs
    (0xF900, 0xFAFF),  # CJK Compatibility Ideographs
)


def _contains(ranges: Tuple[Tuple[int, int], ...]) -> Callable[[str], bool]:
    def present(text: str) -> bool:
        return any(
            first <= ord(character) <= last
            for character in text
            for first, last in ranges
        )

    return present


has_cyrillic = _contains(_CYRILLIC_RANGES)
has_kana = _contains(_KANA_RANGES)
has_han = _contains(_HAN_RANGES)

#: The source languages this gateway can recognise, and the test that decides
#: each.  The keys are the only values ``prompt_translation.sources`` accepts.
SOURCE_SCRIPTS: Mapping[str, Callable[[str], bool]] = {
    "ru": has_cyrillic,
    "ja": has_kana,
}

#: Sorted, so an error message listing them reads the same every time.
SUPPORTED_SOURCES: Tuple[str, ...] = tuple(sorted(SOURCE_SCRIPTS))


def has_source_script(text: str, source: str) -> bool:
    """Does ``text`` carry the script of ``source``?  Unknown source -> ``False``."""

    test = SOURCE_SCRIPTS.get(source)
    return False if test is None else test(text)


def detect_source(text: str, sources: Iterable[str]) -> Optional[str]:
    """The first of ``sources`` whose script appears in ``text``, or ``None``.

    ``None`` means "nothing supported and non-English is present here", and the
    caller's answer to that is to return the text byte-identical.
    """

    ordered: Sequence[str] = tuple(sources)
    for code in ordered:
        if has_source_script(text, code):
            return code
    return None


__all__ = [
    "SOURCE_SCRIPTS",
    "SUPPORTED_SOURCES",
    "detect_source",
    "has_cyrillic",
    "has_han",
    "has_kana",
    "has_source_script",
]
