"""The prose a curator is offered: evidence in, ``presentation`` out.

`semantics.py` says what one input is, `analysis.py` says what the wiring does
with it, and this module says what a person would read about the whole thing.
It produces the `docs/workflow-schema.md` ``presentation`` block, and nothing
else in the sync composes a sentence.

The one invariant, and it is structural
---------------------------------------
**No generated string exists without a named evidence rule that produced it.**
That is not a promise in this docstring; it is the shape of the code.  A key
reaches the YAML only as a :class:`CatalogEntry`, an entry cannot be built
without the sentence that justifies it (:meth:`CatalogEntry.__post_init__`
refuses), and :attr:`Catalog.presentation` is *derived* from the entries rather
than kept beside them.  There is therefore no path by which a plausible-looking
string gets into a definition with nothing behind it.

A key no rule fired for is **omitted from the YAML entirely** and named in
:attr:`Catalog.notes`.  Omission is the conservative outcome and it is the
correct one: `docs/workflow-schema.md` says outright that the importer offers a
starting point to the curator and never takes the decision from them, so a key
this cannot prove is one the curator writes.

What may be read, and what may not
----------------------------------
Read: ``plan.fields`` (types, ids, roles, sections, ``required``,
``translatable``, media kind, the declared frame rate), ``plan.frame_rate``,
``plan.not_exposed`` as *structural* evidence only -- that a graph loads
something at all -- never its text, and the graph as **word tokens inside a
``class_type``**, matched against the small frozen vocabulary below.

Never read: a whole class-type identifier, a custom node's name, a model,
family or vendor -- and never **the source file's
name**.  That last one is enforced by the signature: :func:`describe` takes a
plan and a graph, and there is no parameter a file name could arrive through.
The readable name is computed by :func:`readable_name`, a separate function
whose result feeds ``name`` and nothing else.  A tidied echo of the curator's
own file name is honest; a claim about what model it uses would not be, and
none is made anywhere here.

Nothing in this module reaches a network, and nothing in it imports a
translation or a model backend.  The prose is templates and evidence, computed
on the machine the sync runs on, with no service consulted -- which is what
"normal sync uses no cloud LLM" means in practice.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

from . import semantics
from .analysis import ImportPlan, PlannedField, _class_type, class_words

#: The order the ``presentation`` keys are written in, matching the example in
#: `docs/workflow-schema.md`.  Fixed, so that two runs over the same bytes
#: produce byte-identical YAML whatever order anything was decided in.
PRESENTATION_ORDER: Tuple[str, ...] = (
    "group",
    "category",
    "badge",
    "short_description",
    "best_for",
    "how_to_use",
    "input_summary",
    "example_prompt",
    "not_ideal_for",
)

#: Keys this importer never generates, and the reason each one is the
#: curator's.  ``category`` is `docs/workflow-schema.md`'s "secondary
#: descriptor" and nothing in a graph proves one; ``not_ideal_for`` is a
#: judgement about results, and a graph contains no results.
CURATOR_ONLY: Tuple[str, ...] = ("category", "not_ideal_for")

#: How many items ``best_for`` may carry, per the card's own bar.
BEST_FOR_MIN = 2
BEST_FOR_MAX = 5

#: How many sentences ``how_to_use`` may carry.
HOW_TO_USE_MIN = 2
HOW_TO_USE_MAX = 4

# --------------------------------------------------------------------------
# The class-type vocabulary
# --------------------------------------------------------------------------

#: Words that mean "this node is where the result leaves the graph".
OUTPUT_WORDS = frozenset({"save", "preview", "export", "publish"})

#: Words that mean "what moves through here is a still picture".
IMAGE_WORDS = frozenset({"image", "images", "picture", "pictures"})

#: Words that mean "what moves through here plays over time".
VIDEO_WORDS = frozenset({"video", "videos", "animation", "animated", "anim"})

#: Words that mean "this node makes something bigger than it was".
UPSCALE_WORDS = frozenset({"upscale", "upscaler", "upscaling", "enlarge"})

#: :func:`~localcanvas_gateway.workflows.sync.analysis.class_words` splits an
#: identifier into the words above, so that a whole class-type identifier is
#: never what a decision is taken on.  It was written here and now lives in
#: `analysis.py`, which takes a judgement on the same tokens and is lower in
#: the import order; it is imported rather than written twice, because two
#: splitters would eventually disagree about one class type.  The reader that
#: hands it a node's class type is imported from there for the same reason:
#: what counts as a readable node entry is one answer, not two.

#: Separators inside a file stem, for :func:`readable_name`.
_STEM_SEPARATORS = re.compile(r"[\s._\-()\[\]#+]+")

#: The longest leading run of digits :func:`readable_name` reads as an ordering
#: prefix.  ``01_``, ``02 - `` and ``7.`` are orderings; ``2024`` is a year
#: somebody meant to keep.
_ORDER_PREFIX_DIGITS = 3


# --------------------------------------------------------------------------
# What comes out
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class CatalogEntry:
    """One generated ``presentation`` key, and why it holds what it holds."""

    key: str
    value: Any
    #: The sentence naming the rule that produced :attr:`value`.  Required:
    #: an entry without one cannot be constructed, which is what makes "no
    #: generated string without evidence" a property of the code.
    evidence: str

    def __post_init__(self) -> None:
        if not isinstance(self.key, str) or not self.key.strip():
            raise ValueError("a catalog entry must name the key it fills")
        if not isinstance(self.evidence, str) or not self.evidence.strip():
            raise ValueError(
                "presentation.{} was generated with no evidence behind it; every "
                "generated string names the rule that produced it".format(self.key)
            )


@dataclass(frozen=True)
class Catalog:
    """The ``presentation`` block for one workflow, and the record behind it."""

    entries: Tuple[CatalogEntry, ...] = ()
    #: One sentence per key evidence could not settle, naming the key and
    #: saying why it is the curator's to write.
    notes: Tuple[str, ...] = ()

    @property
    def presentation(self) -> Dict[str, Any]:
        """The mapping to write, derived from the entries and from nothing else."""

        found = {entry.key: entry.value for entry in self.entries}
        document: Dict[str, Any] = {}
        for key in PRESENTATION_ORDER:
            if key not in found:
                continue
            value = found[key]
            document[key] = list(value) if isinstance(value, tuple) else value
        return document

    @property
    def evidence(self) -> Dict[str, str]:
        """``key -> the sentence that produced it``, for every generated key."""

        found = {entry.key: entry.evidence for entry in self.entries}
        return {key: found[key] for key in PRESENTATION_ORDER if key in found}


class _Draft:
    """Collects entries and notes so that neither can be written by hand."""

    def __init__(self) -> None:
        self._entries: List[CatalogEntry] = []
        self._notes: List[Tuple[str, str]] = []

    def emit(self, key: str, value: Any, evidence: str) -> None:
        self._entries.append(CatalogEntry(key=key, value=value, evidence=evidence))

    def omit(self, key: str, reason: str) -> None:
        self._notes.append((key, reason))

    def finish(self) -> Catalog:
        order = {key: index for index, key in enumerate(PRESENTATION_ORDER)}

        def rank(key: str) -> int:
            return order.get(key, len(order))

        entries = tuple(sorted(self._entries, key=lambda entry: rank(entry.key)))
        notes = tuple(
            "{}: {}".format(key, reason)
            for key, reason in sorted(self._notes, key=lambda note: rank(note[0]))
        )
        return Catalog(entries=entries, notes=notes)


# --------------------------------------------------------------------------
# The readable name -- a separate function, on purpose
# --------------------------------------------------------------------------


def readable_name(stem: str) -> str:
    """A file stem tidied into something a person would read.

    Separators become spaces, runs collapse, an ordering prefix is dropped and
    a word that is already capitalised is left as its owner wrote it.  Nothing
    is added and nothing is claimed: this is the curator's own file name with
    the punctuation taken out, which is the one honest human-readable thing a
    sync actually has.

    It is deliberately **not** part of :func:`describe`.  The prose generator
    cannot see a file name at all, so no description, no badge and no example
    can ever be a guess made from one.
    """

    if not isinstance(stem, str):
        return ""
    words = [word for word in _STEM_SEPARATORS.split(stem.strip()) if word]
    if (
        len(words) > 1
        and words[0].isdigit()
        and len(words[0]) <= _ORDER_PREFIX_DIGITS
    ):
        words = words[1:]
    tidied = [
        word if any(character.isupper() for character in word) else _capitalise(word)
        for word in words
    ]
    return " ".join(tidied)


def _capitalise(word: str) -> str:
    return word[:1].upper() + word[1:]


# --------------------------------------------------------------------------
# The evidence
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class _Facts:
    """Everything the rules below are allowed to look at, gathered once."""

    prompt: Optional[PlannedField] = None
    negative: Optional[PlannedField] = None
    media: Tuple[PlannedField, ...] = ()
    required_media: Tuple[PlannedField, ...] = ()
    seed: Optional[PlannedField] = None
    dimensions: Tuple[PlannedField, ...] = ()
    duration: Optional[PlannedField] = None
    main: Tuple[PlannedField, ...] = ()
    advanced: Tuple[PlannedField, ...] = ()
    frame_rate: Optional[float] = None
    produces_image: bool = False
    produces_video: bool = False
    upscales: bool = False
    #: How many inputs are structural and hidden.  A count, never their text.
    locked: int = 0
    #: The sentence naming what makes this a video workflow, or ``None``.
    video_reason: Optional[str] = None
    #: The sentence naming what makes this a still-picture workflow, or ``None``.
    image_reason: Optional[str] = None


def _is_negative(item: PlannedField) -> bool:
    return item.id == "negative_prompt" or item.id.startswith("negative_prompt-")


def _prompt_fields(plan: ImportPlan) -> Tuple[PlannedField, ...]:
    return tuple(
        item for item in plan.fields if item.translatable and item.type in ("string", "multiline")
    )


def _gather(plan: ImportPlan, graph: Mapping[str, Any]) -> _Facts:
    prompts = _prompt_fields(plan)
    positive = next((item for item in prompts if not _is_negative(item)), None)
    negative = next((item for item in prompts if _is_negative(item)), None)

    media = tuple(item for item in plan.fields if item.type in ("image", "video"))
    required_media = tuple(item for item in media if item.required)
    seed = next(
        (item for item in plan.fields if item.role_hint == semantics.SEED_ROLE), None
    )
    dimensions = tuple(item for item in plan.fields if item.pair is not None)
    duration = next(
        (item for item in plan.fields if item.duration_fps is not None), None
    )
    main = tuple(item for item in plan.fields if item.section == "main")
    advanced = tuple(item for item in plan.fields if item.section == "advanced")

    words = [class_words(_class_type(graph, node)) for node in _nodes(graph)]
    image_output = any((word & OUTPUT_WORDS) and (word & IMAGE_WORDS) for word in words)
    video_words = any(word & VIDEO_WORDS for word in words)
    upscales = any(word & UPSCALE_WORDS for word in words)
    video_input = next((item for item in media if item.type == "video"), None)

    video_reason = None
    if plan.frame_rate is not None:
        video_reason = (
            "the graph declares a frame rate of {} on a frame-rate input, so "
            "what it makes plays over time".format(_number(plan.frame_rate))
        )
    elif video_words:
        video_reason = (
            "a node of this graph is named for video, so what it makes plays "
            "over time"
        )
    elif video_input is not None:
        video_reason = "field {!r} takes a clip the user supplies".format(
            video_input.id
        )

    produces_video = video_reason is not None
    # A still image is claimed only from an output node named for saving a
    # **picture**.  A name that says only "save", "preview" or "export" says
    # where a result leaves the graph, not what it is: a mesh, a sound, a text
    # or a number leaves through one just as well (T-0268).  With nothing else
    # to go on, nothing is said about what comes out.
    image_reason = None
    if not produces_video and image_output:
        image_reason = "an output node of this graph is named for saving a picture"

    return _Facts(
        prompt=positive,
        negative=negative,
        media=media,
        required_media=required_media,
        seed=seed,
        dimensions=dimensions,
        duration=duration,
        main=main,
        advanced=advanced,
        frame_rate=plan.frame_rate,
        produces_image=image_reason is not None,
        produces_video=produces_video,
        upscales=upscales,
        locked=len(plan.not_exposed),
        video_reason=video_reason,
        image_reason=image_reason,
    )


def _nodes(graph: Mapping[str, Any]) -> Sequence[str]:
    if not isinstance(graph, Mapping):
        return ()
    return sorted(str(node) for node in graph)


def _number(value: float) -> str:
    return "%g" % float(value)


def _supplied(facts: "_Facts") -> str:
    """What the user hands this workflow, in the word they would use.

    A clip is not a picture, and a sentence that calls it one is wrong in a
    file somebody trusts.  The field's own type settles it.
    """

    if facts.required_media and facts.required_media[0].type == "video":
        return "clip"
    return "picture"


# --------------------------------------------------------------------------
# The rules
# --------------------------------------------------------------------------


def describe(plan: ImportPlan, graph: Mapping[str, Any]) -> Catalog:
    """The ``presentation`` block one graph's evidence supports.

    The signature is the contract: a plan and a graph, and no way for a file
    name to arrive.  Everything below is a rule over those two, and every key
    it fills carries the sentence that filled it.
    """

    facts = _gather(plan, graph)
    draft = _Draft()

    for key in CURATOR_ONLY:
        draft.omit(key, _CURATOR_ONLY_REASONS[key])

    _badge_and_group(draft, facts)
    _short_description(draft, facts)
    _best_for(draft, facts)
    _how_to_use(draft, facts)
    _input_summary(draft, facts)
    _example_prompt(draft, facts)
    return draft.finish()


_CURATOR_ONLY_REASONS = {
    "category": (
        "a secondary descriptor is a judgement about the results, and nothing "
        "in a graph proves one, so the importer never writes it. Add your own "
        "if you want one."
    ),
    "not_ideal_for": (
        "only you know what this workflow is bad at, and a graph does not say, "
        "so the importer never writes it."
    ),
}


def _badge_and_group(draft: _Draft, facts: _Facts) -> None:
    """What the graph proves it consumes and produces, in two words.

    `docs/workflow-schema.md` is explicit that these are *data, not an
    enumeration in code* -- nothing branches on the values written here, and an
    unknown group renders as its own section.  The words follow the
    conventions the schema's own examples use.
    """

    badge: Optional[str] = None
    group: Optional[str] = None
    evidence: Optional[str] = None

    if facts.produces_video:
        badge, group = "VIDEO", "Video"
        evidence = facts.video_reason
    elif facts.upscales and facts.required_media and facts.prompt is None:
        badge, group = "UPSCALE", "Enhance"
        evidence = (
            "a node of this graph is named for upscaling, it requires field "
            "{!r}, and it has no prompt to write into".format(
                facts.required_media[0].id
            )
        )
    elif facts.required_media and facts.prompt is not None:
        badge, group = "IMG2IMG", "Edit"
        evidence = (
            "field {!r} is a required {} and field {!r} is the prompt, so this "
            "graph changes something the user supplies rather than making one "
            "from nothing".format(
                facts.required_media[0].id,
                facts.required_media[0].type,
                facts.prompt.id,
            )
        )
    elif facts.prompt is not None and not facts.required_media and facts.produces_image:
        badge, group = "TXT2IMG", "Create"
        evidence = (
            "field {!r} is the only thing that goes in, and {}".format(
                facts.prompt.id, facts.image_reason
            )
        )

    if badge is None or group is None or evidence is None:
        reason = (
            "what this workflow consumes and produces did not settle it, so "
            "nothing was written rather than a marker that might be wrong."
        )
        draft.omit("badge", reason)
        draft.omit("group", reason)
        return
    draft.emit("badge", badge, evidence + ".")
    draft.emit("group", group, evidence + ".")


def _short_description(draft: _Draft, facts: _Facts) -> None:
    """What goes in and what comes out, in the workflow's own terms."""

    goes_in = _input_phrase(facts)
    comes_out = _output_phrase(facts)
    if goes_in is None or comes_out is None:
        draft.omit(
            "short_description",
            "the fields prove {}, which is not enough to say what this "
            "workflow does without inventing the other half.".format(
                "nothing that goes in" if goes_in is None else "nothing that comes out"
            ),
        )
        return

    text = "{} {} in; {} comes out.".format(
        _capitalise(goes_in), "goes" if len(facts.main) == 1 else "go", comes_out
    )
    settings = _settings_sentence(facts)
    if settings is not None:
        text += " " + settings
    draft.emit(
        "short_description",
        text,
        "composed from the {} field{} the user sets and the kind of result the "
        "graph's output stage produces.".format(
            len(facts.main), "" if len(facts.main) == 1 else "s"
        ),
    )


#: Number words for the counts a Main section realistically reaches.  Beyond
#: them the digits are used, which is never pretty and never wrong.
_COUNT_WORDS = ("no", "one", "two", "three", "four", "five", "six")

#: The media kinds, and how to say one of them and several of them.
_MEDIA_NOUNS = (("image", "a picture", "pictures"), ("video", "a clip", "clips"))


def _input_phrase(facts: _Facts) -> Optional[str]:
    """What goes in: once per **kind**, never once per field.

    A graph with a source picture and a semantically distinct reference has two
    Main media fields -- ``analysis.py``'s case B, and an ordinary edit-workflow
    shape rather than a curiosity.  Said once per field that produced *"a
    written description, a picture you supply and a picture you supply"*, which
    is worse than saying nothing: it reads like a bug, because it was one.
    """

    parts: List[str] = []
    if facts.prompt is not None and any(
        item.id == facts.prompt.id for item in facts.main
    ):
        parts.append("a written description")
    for kind, one, many in _MEDIA_NOUNS:
        found = [item for item in facts.main if item.type == kind]
        if not found:
            continue
        parts.append(
            "{} you supply".format(one)
            if len(found) == 1
            else "{} {} you supply".format(_count_word(len(found)), many)
        )
    if not parts:
        return None
    if len(parts) == 1:
        return parts[0]
    return "{} and {}".format(", ".join(parts[:-1]), parts[-1])


def _count_word(number: int) -> str:
    return _COUNT_WORDS[number] if number < len(_COUNT_WORDS) else str(number)


def _output_phrase(facts: _Facts) -> Optional[str]:
    if facts.upscales and facts.required_media:
        return "an enlarged copy of it"
    if facts.produces_video:
        return "a video clip"
    if facts.produces_image:
        return "a still image"
    return None


def _settings_sentence(facts: _Facts) -> Optional[str]:
    labels = [item.label for item in facts.advanced]
    if not labels:
        return None
    if len(labels) == 1:
        return "{} is kept under Advanced.".format(labels[0])
    if len(labels) == 2:
        return "{} and {} are kept under Advanced.".format(labels[0], labels[1])
    return "{}, {} and {} more settings are kept under Advanced.".format(
        labels[0], labels[1], len(labels) - 2
    )


def _best_for(draft: _Draft, facts: _Facts) -> None:
    """Capabilities the graph proves.  One item is one rule firing."""

    found: List[Tuple[str, str]] = []

    if facts.prompt is not None and facts.required_media:
        found.append(
            (
                "Changing a {} you already have by describing the "
                "change".format(_supplied(facts)),
                "field {!r} is the prompt and field {!r} is a required "
                "{}".format(
                    facts.prompt.id,
                    facts.required_media[0].id,
                    facts.required_media[0].type,
                ),
            )
        )
    elif facts.prompt is not None:
        if facts.produces_video:
            found.append(
                (
                    "Turning a written description into a short clip",
                    "field {!r} is the prompt, and {}".format(
                        facts.prompt.id, facts.video_reason
                    ),
                )
            )
        elif facts.produces_image:
            found.append(
                (
                    "Turning a written description into a picture",
                    "field {!r} is the prompt, and {}".format(
                        facts.prompt.id, facts.image_reason
                    ),
                )
            )
        else:
            found.append(
                (
                    "Working from a written description you type in",
                    "field {!r} is the prompt".format(facts.prompt.id),
                )
            )
    elif facts.required_media and facts.upscales:
        found.append(
            (
                "Enlarging a picture you already have",
                "field {!r} is required and a node of this graph is named for "
                "upscaling".format(facts.required_media[0].id),
            )
        )
    elif facts.required_media:
        found.append(
            (
                "Working from a {} you supply".format(_supplied(facts)),
                "field {!r} is a required {} and there is no prompt".format(
                    facts.required_media[0].id, facts.required_media[0].type
                ),
            )
        )

    if facts.seed is not None:
        found.append(
            (
                "Reproducing an exact result by keeping its seed",
                "field {!r} carries the seed role".format(facts.seed.id),
            )
        )
    if len(facts.dimensions) == 2:
        found.append(
            (
                "Choosing the size of the result",
                "fields {!r} and {!r} are the paired dimensions".format(
                    facts.dimensions[0].id, facts.dimensions[1].id
                ),
            )
        )
    if facts.duration is not None:
        found.append(
            (
                "Choosing how long the result runs",
                "field {!r} counts frames at a rate the graph declares".format(
                    facts.duration.id
                ),
            )
        )
    if facts.negative is not None:
        found.append(
            (
                "Steering the result away from what you do not want",
                "field {!r} is the negative prompt, decided by the "
                "wiring".format(facts.negative.id),
            )
        )

    if len(found) < BEST_FOR_MIN:
        draft.omit(
            "best_for",
            "fewer than {} capabilities could be proved from the fields, and a "
            "list padded to length would say less than no list at all.".format(
                BEST_FOR_MIN
            ),
        )
        return
    chosen = found[:BEST_FOR_MAX]
    draft.emit(
        "best_for",
        tuple(item for item, _ in chosen),
        "; ".join("{!r} because {}".format(item, why) for item, why in chosen) + ".",
    )


def _how_to_use(draft: _Draft, facts: _Facts) -> None:
    """Short practical sentences about the form, never about the graph."""

    found: List[Tuple[str, str]] = []

    if facts.prompt is not None and facts.required_media:
        found.append(
            (
                "Pick the {} you want to change, then describe the change you "
                "want.".format(_supplied(facts)),
                "the prompt is consumed alongside required field {!r}".format(
                    facts.required_media[0].id
                ),
            )
        )
    elif facts.prompt is not None:
        found.append(
            (
                "Describe the subject, the setting and the light you want to see.",
                "field {!r} is the prompt and nothing else is required".format(
                    facts.prompt.id
                ),
            )
        )
    elif facts.required_media:
        found.append(
            (
                "Pick the {} you want to work on and generate; there is "
                "nothing to write.".format(_supplied(facts)),
                "field {!r} is required and no field takes text".format(
                    facts.required_media[0].id
                ),
            )
        )

    if facts.negative is not None:
        found.append(
            (
                "Use the negative prompt for anything you do not want in the "
                "result.",
                "field {!r} is the negative prompt".format(facts.negative.id),
            )
        )
    if len(facts.dimensions) == 2:
        found.append(
            (
                "Set the width and the height before you generate.",
                "fields {!r} and {!r} are the paired dimensions".format(
                    facts.dimensions[0].id, facts.dimensions[1].id
                ),
            )
        )
    if facts.duration is not None and facts.frame_rate is not None:
        found.append(
            (
                "Length is counted in frames, at {} frames a second.".format(
                    _number(facts.frame_rate)
                ),
                "field {!r} counts frames and the graph declares the "
                "rate".format(facts.duration.id),
            )
        )
    if facts.seed is not None:
        found.append(
            (
                "Keep the seed to get the same result again, or change it for a "
                "different one.",
                "field {!r} carries the seed role".format(facts.seed.id),
            )
        )
    if facts.locked:
        found.append(
            (
                "Anything not shown here is fixed in the workflow itself.",
                "{} input{} of this graph {} structural and never "
                "exposed".format(
                    facts.locked,
                    "" if facts.locked == 1 else "s",
                    "is" if facts.locked == 1 else "are",
                ),
            )
        )

    if len(found) < HOW_TO_USE_MIN:
        draft.omit(
            "how_to_use",
            "fewer than {} practical sentences could be written from the field "
            "set, and the rest would have been a graph tutorial.".format(
                HOW_TO_USE_MIN
            ),
        )
        return
    chosen = found[:HOW_TO_USE_MAX]
    draft.emit(
        "how_to_use",
        " ".join(sentence for sentence, _ in chosen),
        "; ".join(why for _, why in chosen) + ".",
    )


def _input_summary(draft: _Draft, facts: _Facts) -> None:
    """One phrase naming the Main fields, and only them."""

    labels = [item.label for item in facts.main]
    if not labels:
        draft.omit(
            "input_summary",
            "this workflow has no Main field, so there is nothing to summarise.",
        )
        return
    if len(labels) == 1:
        text = "{} only".format(labels[0])
    else:
        text = "{} and {}".format(", ".join(labels[:-1]), labels[-1])
    draft.emit(
        "input_summary",
        text,
        "the Main section holds {}.".format(", ".join(repr(item) for item in labels)),
    )


#: One template per situation, and the situation is proved by the graph.
#:
#: There is deliberately **no tag-shaped variant** of any of these.  A graph
#: that genuinely writes its prompts as tags carries that text in its own
#: positive prompt field, and the rule above emits it *verbatim* -- which is a
#: real tag-style example rather than an invented one, and always a better one.
#: The only other way a tag-shaped template could ever have been chosen is a
#: *negative* prompt's default, and a sentence saying "this graph's prompt is
#: written as tags" on the strength of the negative prompt is a claim about one
#: field made from another.  An untrue sentence in the evidence record defeats
#: the invariant this module is built on, so the branch was not narrowed to the
#: positive prompt -- narrowing would have left four templates nothing can
#: reach, because the rule above consumes that default first.  It is gone.
_EXAMPLES = {
    "scene": (
        "A quiet street at dawn, wet cobblestones, soft light and a shallow "
        "depth of field"
    ),
    "edit": (
        "Make the sky overcast and the light softer, and leave everything else "
        "as it is"
    ),
    "video": (
        "A slow push in on a quiet harbour at dawn, the camera steady and the "
        "movement gentle"
    ),
    "video_edit": (
        "A gentle push in on the {supplied} you supplied, the movement slow "
        "and the framing steady"
    ),
}


def _example_prompt(draft: _Draft, facts: _Facts) -> None:
    """Three semantics, in the order the card states them.

    No prompt-like field means no key at all.  A non-empty default on the
    workflow's own prompt is the example, verbatim -- the curator's own text
    out of their own graph, which beats every template here.  Otherwise a
    template chosen by what the graph proves about the prompt.

    The card listed a fourth, a tag-shaped variant of each template. It is
    deliberately not implemented; see :data:`_EXAMPLES`.
    """

    if facts.prompt is None:
        draft.omit(
            "example_prompt",
            "this workflow has no prompt-like field, so there is nothing to "
            "show an example for. That is the answer, not a gap.",
        )
        return

    if facts.prompt.has_default and isinstance(facts.prompt.default, str):
        written = facts.prompt.default.strip()
        if written:
            draft.emit(
                "example_prompt",
                facts.prompt.default,
                "field {!r} carries this text in the workflow itself, so it is "
                "the curator's own example and beats any template.".format(
                    facts.prompt.id
                ),
            )
            return

    if facts.required_media and facts.produces_video:
        kind, why = "video_edit", (
            "the prompt is consumed alongside required field {!r} and {}".format(
                facts.required_media[0].id, facts.video_reason
            )
        )
    elif facts.required_media:
        kind, why = "edit", (
            "the prompt is consumed alongside required field {!r}, so the "
            "example is an instruction about a picture rather than a scene "
            "description".format(facts.required_media[0].id)
        )
    elif facts.produces_video:
        kind, why = "video", facts.video_reason or ""
    else:
        kind, why = "scene", (
            "nothing the user supplies goes in but the prompt, so the example "
            "is a scene description"
        )

    draft.emit(
        "example_prompt",
        _EXAMPLES[kind].format(supplied=_supplied(facts)),
        why + ".",
    )


__all__ = [
    "BEST_FOR_MAX",
    "BEST_FOR_MIN",
    "CURATOR_ONLY",
    "HOW_TO_USE_MAX",
    "HOW_TO_USE_MIN",
    "IMAGE_WORDS",
    "OUTPUT_WORDS",
    "PRESENTATION_ORDER",
    "UPSCALE_WORDS",
    "VIDEO_WORDS",
    "Catalog",
    "CatalogEntry",
    "class_words",
    "describe",
    "readable_name",
]
