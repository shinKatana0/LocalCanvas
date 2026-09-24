"""Splitting prompt text into protected and translatable spans.

The scanner is the whole of the literal-protection design, and it is a scanner
rather than a regular expression or a placeholder substitution for a measured
reason (T-0040): a token handed to a neural translator may come back rewritten
-- four of five placeholder styles tried were corrupted -- so **nothing that
must survive is ever given to the translator**.  A quoted literal is never
handed over; it is copied from the input to the output.

What the scanner yields
-----------------------
Alternating :class:`Span` values whose ``text`` concatenates back to exactly the
input.  That is an invariant, not a hope: the assembler downstream copies every
protected span, and every span it does not translate, verbatim -- so a text with
nothing to translate comes out byte-identical.

The rules
---------
* a ``"`` opens a literal; the quote characters are **part of** the protected
  span, so they survive too;
* inside a literal a backslash escapes the next character, which is how ``\\"``
  stays inside the literal instead of closing it;
* **an unterminated literal runs to the end of the text.**  This is the one
  documented deterministic rule for an unmatched quote (`docs/api.md`): from the
  unmatched ``"`` to the end of the text is protected and left untranslated.
  It is chosen because it cannot corrupt -- the character is never dropped, and
  the gateway never guesses where the author meant to close it.  The cost is
  bounded and visible: that tail is not translated.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import List, Tuple

#: The one quoting character LocalCanvas protects.  A single quote is an
#: apostrophe far more often than it is a quote, so it is left alone.
QUOTE = '"'

#: Inside a literal only.  Outside one there is nothing to escape.
ESCAPE = "\\"


@dataclass(frozen=True)
class Span:
    """One run of the input, either protected or offered to the translator."""

    text: str
    protected: bool


def split_spans(text: str, *, preserve_quoted_literals: bool = True) -> Tuple[Span, ...]:
    """Split ``text`` into protected and translatable spans, in order.

    ``"".join(span.text for span in split_spans(t)) == t`` holds for every
    ``t``: the spans are a partition of the input, never a rewriting of it.

    With ``preserve_quoted_literals`` false the whole text is one translatable
    span -- the setting is off, so quoting is not special and nothing is held
    back.
    """

    if not text:
        return ()
    if not preserve_quoted_literals:
        return (Span(text, protected=False),)

    spans: List[Span] = []
    pending: List[str] = []
    index = 0
    length = len(text)

    def flush() -> None:
        if pending:
            spans.append(Span("".join(pending), protected=False))
            pending.clear()

    while index < length:
        if text[index] != QUOTE:
            pending.append(text[index])
            index += 1
            continue

        end = _literal_end(text, index)
        flush()
        spans.append(Span(text[index:end], protected=True))
        index = end

    flush()
    return tuple(spans)


def _literal_end(text: str, start: int) -> int:
    """Where the literal opened at ``start`` ends -- end of text if unterminated."""

    index = start + 1
    length = len(text)
    while index < length:
        character = text[index]
        if character == ESCAPE and index + 1 < length:
            # The escaped character is copied like any other; nothing here
            # unescapes anything, because the literal is reproduced verbatim.
            index += 2
            continue
        index += 1
        if character == QUOTE:
            return index
    return length


__all__ = ["ESCAPE", "QUOTE", "Span", "split_spans"]
