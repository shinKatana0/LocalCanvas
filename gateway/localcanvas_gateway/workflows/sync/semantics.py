"""What one node input *means*, judged from its name and its value alone.

This module is the vocabulary; `analysis.py` is the graph.  Split that way
because the two answer different questions and fail differently: "is
``ckpt_name`` a thing a user may change" is a question about ComfyUI's own
input naming, true of every graph ever exported, while "is this the positive
prompt or the negative one" is a question only the wiring can answer.

The node's own ``class_type`` is on neither side of that split: it says what a
node *does* and never which of its inputs is the file it does it to, so a
loader's type would make every string on that node a picture -- which is the
bug this module was fixed for, at full width, on the one node class every real
workflow contains.  Measured on ``LoadImage`` (T-0072 review).

Three rules shape everything here.

**Nothing branches on a model family.**  Not one name of one model, family or
custom node appears below -- LocalCanvas is generic by default, and it is
also the only way this can keep working: a graph built on something released
next year has to import as well as one built today.  What is recognised is
ComfyUI's *input vocabulary* (``seed``, ``steps``, ``ckpt_name``) and the
*shape of a value* (a string ending in a weights suffix, a string that names a
place on a disk).
Both are properties of the API format, not of anybody's model collection.

**The three-way split is deliberate.**  An input is one of:

* :attr:`Exposure.EXPOSE` -- provably safe to put in front of a user.  Writing
  a number, a flag or a known choice into it changes how the graph generates
  and nothing else.
* :attr:`Exposure.LOCKED` -- provably structural.  It names a file to load, a
  place on a disk, a device, the model architecture the graph is built for,
  or a switch that changes what the graph *is* --
  or it is bookkeeping ComfyUI writes into its own export, which was never a
  control anybody chose.  It is never exposed, and it is reported -- it
  reaches the run's control inventory (`analysis.py`), the report document
  (`report.py`) and the curator's terminal (`scripts/sync-workflows.ps1`),
  each time with its node, its input and the sentence below -- so that "not
  exposed" is visible rather than silent.
* :attr:`Exposure.UNCERTAIN` -- neither could be proved.  The workflow goes to
  ``NEEDS_REVIEW``.  This is the expensive-looking option and it is the
  correct one: an id minted for a control we guessed at either loses a user's
  saved settings later or applies them to the wrong control, and both
  failures are silent.

**The order of the questions is part of the answer.**  A value with a slash in
it on an input called ``image`` is a picture's own subfolder and not a path to
lock away, which is why media is asked before the shape of the string.

What the order does *not* do is make something media.  A value ending in
``.png`` on an input called ``filename_prefix`` is not an image the user
uploads -- and neither is one on any other input whose **name** does not say it
takes media: the media question answers "no" for it whatever the value ends in.
The suffix corroborates a kind the name established and never establishes one
on its own (T-0072); ``filename_prefix`` was previously safe only because
``filename`` is a locked word, which said nothing about the next string.

**Media takes both halves of the evidence, and each half alone has been a bug.**
The name must say media *and* the value must bear that out by looking like the
name of a file.  A name alone made ``image_format = 'nearest-exact'`` and
``video_codec = 'h264'`` required uploads -- the user asked for a photograph
before the workflow would run, for the sake of a codec's name (T-0080), which
is the same harm as the suffix-alone bug arriving from the other side.  What
corroborates is the **shape** of a file name and never membership of a suffix
list, so a picture saved as ``photo.avif`` still imports and only its *kind*
is left to the lists below.

**A separator is not a path, for the same reason a suffix is not media.**  A
slash joins the halves of ``K+V w/ C penalty``, ``before/after`` and
``image/gif`` as readily as it joins the parts of a folder, so a value that
merely contains one proves nothing.  :func:`looks_like_a_path` therefore asks
for a *root* -- a drive, a **leading** separator, a home, an explicit ``./``
-- or for a separator whose last component is shaped like the name of a file.
A leading separator is deliberately not spelled "Windows UNC": most ComfyUI
installations are not on Windows, and the root a graph carries is whichever
kind its own host writes.  That was the third arrival of one lesson (T-0072,
T-0080, T-0095): classify from corroborated semantics, never from the
superficial shape of a value.

:func:`classify` asks the questions in one fixed order, and every verdict
carries the sentence that says which one answered -- so a surprising verdict
can be read back rather than guessed at.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from enum import Enum
from typing import Any, Iterable, Optional, Set, Tuple
from urllib.parse import urlsplit

# --------------------------------------------------------------------------
# Value evidence
# --------------------------------------------------------------------------

#: Suffixes that mean "this string names a file of weights".  A container
#: format, never a model, a family or a vendor: judging the suffix rather than
#: the input's name is what makes this hold for a loader nobody here has ever
#: heard of.
WEIGHT_SUFFIXES = (
    ".safetensors",
    ".sft",
    ".ckpt",
    ".pt",
    ".pth",
    ".bin",
    ".gguf",
    ".onnx",
    ".pkl",
    ".npz",
)

IMAGE_SUFFIXES = (".png", ".jpg", ".jpeg", ".webp", ".bmp", ".gif", ".tif", ".tiff")
VIDEO_SUFFIXES = (".mp4", ".mov", ".webm", ".mkv", ".avi", ".m4v", ".mpg", ".mpeg")

#: A drive-qualified path, matched as text rather than with ``os.path``: the
#: graph may have been exported on the other kind of machine, and what matters
#: is that the *string* names a place on a disk.  A drive letter is the one
#: root that does **not** begin with a separator, which is why it needs a
#: pattern of its own; every other root is :data:`_ROOTED_PATH`'s.
_DRIVE_PATH = re.compile(r"^[A-Za-z]:[\\/]")

#: A path written from a root, in either slash direction: ``/home/u/models``
#: and ``/workspace`` on the machines most ComfyUI installations run on,
#: ``//nas/models`` and ``\\server\share`` for a UNC host, ``\models`` for the
#: root of the current drive.
#:
#: One rule covers all four because they are one fact -- a **leading**
#: separator says "start again from a root", which no ordinary text does; a
#: separator anywhere else says nothing at all, and that is the whole subject
#: of this module's path rule.  Writing it as "Windows UNC" instead cost this
#: card a review: a list of a Linux ComfyUI's own folders stopped being
#: recognised as a file picker and would have been rendered to a user as an
#: editable dropdown of their own directory names.
_ROOTED_PATH = re.compile(r"^[\\/]")

#: An **explicit** relative prefix -- ``./`` or ``../``, either slash
#: direction.  Writing one is a deliberate statement that what follows is
#: reached from somewhere on a disk, which is why it is evidence on its own
#: even when nothing after it looks like a file.  A lone dot is not: a dot
#: inside ordinary text is not a claim about a filesystem.
_RELATIVE_PATH = re.compile(r"^\.\.?[\\/]")

#: The characters that join the parts of a path -- and the parts of a great
#: many things that are not one.  Nothing here asks this question by itself.
_PATH_SEPARATORS = ("/", "\\")

#: What the tail of a file name looks like, once the last dot has been found:
#: letters and digits, with **at least one letter** among them.  The letter is
#: the whole discrimination.  It admits ``png``, ``mp4`` and an ``avif`` this
#: module has never heard of -- which it must, because refusing an unlisted
#: format would refuse a real workflow outright -- and it refuses the ``5`` of
#: ``1.5`` and the ``2`` of ``v1.5.2``, whose only dot is a decimal point.
_FILE_EXTENSION = re.compile(r"^[A-Za-z0-9]*[A-Za-z][A-Za-z0-9]*$")


def _tokens(name: str) -> Tuple[str, ...]:
    """An input name split into the words it is made of.

    ``strength_model`` is two words, and that is exactly why the locked
    vocabulary is matched on words and never on substrings: ``model`` inside
    ``strength_model`` would lock the one number the design insists a user may
    tune, and ``lora`` inside ``lora_strength`` would lock it twice over.
    """

    return tuple(part for part in re.split(r"[^a-z0-9]+", name.strip().lower()) if part)


#: Words that make a **string** input structural.  Each names something the
#: machine owns -- a file, a folder, a set of weights -- rather than something
#: the picture is made of.
LOCKED_STRING_WORDS = frozenset(
    {
        "path",
        "paths",
        "dir",
        "dirs",
        "directory",
        "folder",
        "filename",
        "file",
        "filepath",
        "output",
        "save",
        "url",
        "endpoint",
        "checkpoint",
        "ckpt",
        "vae",
        "unet",
        "encoder",
        "tokenizer",
        "weights",
        "lora",
        "embedding",
        "embeddings",
    }
)

#: Words that make an input structural **whatever its type is**: a device
#: index is a number, a debug switch is a boolean, and a bypass flag rewires
#: the graph rather than changing what it generates.
LOCKED_ANY_WORDS = frozenset(
    {
        "device",
        "provider",
        "backend",
        "cache",
        "debug",
        "verbose",
        "log",
        "logs",
        "host",
        "port",
        "token",
        "apikey",
        "bypass",
        "mute",
    }
)

#: The word an input name has to carry for :data:`ARCHITECTURE_PAIR_WORDS` to
#: mean anything (T-0193).  On its own it is not evidence: a bare ``model`` or
#: ``model_name`` on a node that calls a hosted service picks one of several
#: models that each work, and ``strength_model``, ``model_seed`` and
#: ``unload_model`` are a number, a number and a flag.
ARCHITECTURE_MODEL_WORD = "model"

#: Words that, **beside** :data:`ARCHITECTURE_MODEL_WORD` in one input name,
#: make that input a choice of which model architecture, family or version the
#: rest of the graph is built for (T-0193): ``model_type``, ``model_version``,
#: ``base_model``, ``model_arch``.
#:
#: Such a choice is structural whatever node carries it and whatever it holds.
#: Knowing every value it accepts does not make changing it safe: exactly one
#: of them matches the weights the graph loads, and a dropdown over all of them
#: is "which model this workflow is" turned into a control -- T-0100's defect,
#: on a node whose class type says nothing about loading.
#:
#: Matched as word tokens, like every vocabulary here.  So ``modeltype`` and
#: ``model_types`` are **not** matched: the first is one word and the second
#: pairs ``model`` with ``types``, which this set does not carry.  That is a
#: measured choice rather than an oversight -- no such spelling occurred among
#: the inputs one current ComfyUI installation declared (some eleven thousand),
#: nor in the workflows converted on it.
ARCHITECTURE_PAIR_WORDS = frozenset(
    {"type", "version", "arch", "architecture", "family", "base"}
)

#: Whole input names that are that choice with no ``model`` beside them.
#: Compared entire, after the same normalisation of case and separators
#: :func:`_is_bookkeeping` uses -- ``arch`` as a *token* would also reach
#: an ``arch_strength`` somebody may tune.
ARCHITECTURE_INPUT_NAMES = frozenset({"arch", "architecture"})

#: How a graph names an input a node shape added: ``parent.child``.  The same
#: character as ``analysis.SHAPE_PATH_SEPARATOR`` -- written here because this
#: module is imported by that one and cannot import it back, and a test holds
#: the two equal.  Read only by :func:`_names_a_model_architecture`.
SHAPE_PATH_SEPARATOR = "."

#: Text a person writes in their own language.  The only fields that may ever
#: carry ``translatable: true`` (`docs/workflow-schema.md`).
PROMPT_WORDS = frozenset(
    {
        "text",
        "prompt",
        "positive",
        "negative",
        "instruction",
        "instructions",
        "caption",
        "description",
    }
)

#: String inputs whose value is one of a fixed set the node itself offers.
#: They are safe -- writing one changes sampling behaviour, not what loads --
#: and they are exposed as plain text, because an API-format graph carries the
#: value a node *has* and never the list of values it would *accept*.
#: Inventing that list is the one thing this importer must not do.
SAFE_STRING_WORDS = frozenset(
    {
        "sampler",
        "scheduler",
        "mode",
        "method",
        "interpolation",
        "crop",
        "align",
        "direction",
    }
)

#: Input names ComfyUI writes into its **own** API export as bookkeeping.
#: Nothing here is a control a person set: the editor puts these beside a
#: widget, and they are therefore in the export of every graph containing that
#: node.  They are locked rather than left uncertain, because "we could not
#: read this" is the wrong thing to say about a value nobody chose -- and they
#: are locked rather than dropped, so a curator still sees the importer
#: recognised them.
#:
#: **Matched on the whole input name, never on word tokens.**  This is the one
#: place in this module where the word-token instrument is the wrong one, and
#: the reason is in the names: ``upload`` as a token would reach an
#: ``upload_strength`` a user may genuinely tune, and ``control`` or
#: ``generate`` as tokens would reach every ``control_*`` a node really
#: offers.  Each entry below is a *complete* input name, so the complete name
#: is the evidence.  Do not "fix" this into a token match.
#:
#: An entry may be added only for something ComfyUI's **public API format**
#: justifies, and the justification is written beside it.  No ComfyUI
#: installation was read to build this list and none may be: it stays small,
#: and the next entry is added when a real workflow produces one.  Nothing
#: model-shaped ever goes in here -- this is ComfyUI's input vocabulary,
#: exactly as the sets above are.
BOOKKEEPING_INPUT_NAMES = frozenset(
    {
        # ComfyUI's image loaders carry an upload *button* as a widget of the
        # node.  The API export writes it out as an ordinary input whose value
        # is the literal kind it uploads -- ``"upload": "image"`` -- so it is
        # in every img2img, inpaint, edit, reference and upscale-from-file
        # export there is.  It is the editor's file picker; the graph does not
        # read it, and writing something else into it would generate nothing
        # different.
        "upload",
        # Newer ComfyUI adds a second widget beside an integer that asked for
        # one -- in practice a seed -- holding ``fixed``, ``increment``,
        # ``decrement`` or ``randomize``.  It says what the **editor** does to
        # that number *after* a run, so it describes the next export rather
        # than this one, and it is not a setting of the workflow at all.
        "control_after_generate",
    }
)

#: An input holding a picture or a clip the user supplies.
#:
#: ``clip`` is deliberately **not** here although a person would call a short
#: video one: it is also what ComfyUI calls a text encoder, and ``clip_name``
#: -- a loader input naming a file of weights -- would then be read as a video
#: a user uploads.  Measured on exactly that input.
MEDIA_WORDS = frozenset({"image", "images", "video", "videos", "picture"})

#: The subsets of :data:`MEDIA_WORDS` that say *which* kind of media.  A name
#: carrying one of these settles the kind by itself; a name that says "media"
#: without saying which leaves that to the value's suffix.
VIDEO_WORDS = frozenset({"video", "videos"})
IMAGE_WORDS = frozenset({"image", "images", "picture"})

#: Technical media: a matte, not a subject.  Case C of the four media cases.
MASK_WORDS = frozenset({"mask", "matte", "alpha"})

#: Names that mean the same control under two spellings.  Kept to the ones
#: `docs/workflow-schema.md` names outright -- "one seed in a sampler's
#: ``seed`` and a second sampler's ``noise_seed``" -- because a synonym
#: invented here would collapse two controls a graph deliberately keeps apart.
ROLE_SYNONYMS = {
    "noise_seed": "seed",
    "random_seed": "seed",
    "rand_seed": "seed",
}

#: Integer inputs that count frames of video.  They may be *presented* as a
#: duration, but only when the graph also declares the rate to read them at
#: (`docs/workflow-schema.md`, "duration").
FRAME_COUNT_NAMES = frozenset(
    {"length", "frames", "num_frames", "frame_count", "video_frames", "video_length"}
)

#: Inputs that declare that rate.  Nothing else is ever read as one, and a
#: field's *name* never switches the hint on by itself.
FRAME_RATE_NAMES = frozenset({"fps", "frame_rate", "framerate", "frames_per_second"})

#: The paired dimensions `docs/workflow-schema.md` gives a layout hint for.
DIMENSION_NAMES = frozenset({"width", "height"})

#: The one v0.1 ``role``.
SEED_ROLE = "seed"

# --------------------------------------------------------------------------
# What one input does, in one line
# --------------------------------------------------------------------------
#
# `docs/workflow-schema.md` gives a field an optional ``help`` -- "a one-line
# hint" -- and the app renders it as muted text under the control.  Until this
# table existed nothing generated one, so every advanced control arrived on a
# phone as a bare ComfyUI word with nothing to say what it did.  `docs/ui-ux.md`
# asks for "no raw ComfyUI terminology unless genuinely necessary"; ``cfg`` and
# ``sampler_name`` are genuinely necessary, because they are what the graph
# calls them, and the line below is what makes the necessary word legible.
#
# It is a **vocabulary**, on exactly the terms the rest of this module is one:
# keyed on ComfyUI's own input name, never on a model, a family, a vendor or a
# custom node.  Every sentence is therefore true of that
# input in any graph that has it, and none of them describes a workflow.
#
# The rules the sentences are written to, which a test enforces mechanically:
#
# * **one line, short enough to read on a phone.**  It renders under the
#   control in small type; three wrapped lines cost more than they teach.
# * **say what moving it changes, and name the cost where there is one.**
#   "More steps, more detail, more waiting" is worth the space; "the number of
#   steps" is not.
# * **do not restate the label** -- it sits directly above.
# * **do not explain jargon with jargon.**  No "CFG scale", no
#   "classifier-free guidance", no "denoising strength", no sampler names.
# * **do not promise a range or a default.**  The field already carries
#   ``min``/``max``/``step``/``default``, and a sentence repeating them goes
#   stale the moment a graph declares different ones.
# * **no colon.**  A colon makes YAML quote the whole scalar, so one sentence
#   would be written ``help: 'like this'`` and every other one bare.  A file a
#   curator is invited to edit should not look like two formats.
#
# **Silence is a valid output, and the correct one twice over.**  Nothing
# generic can be said about ``value`` -- what ComfyUI's primitive family calls
# its only input, and what T-0097's ``value-<hash>`` fields are named for -- so
# it is deliberately absent, and a field bound to it gets no line rather than a
# vacuous one.  The same goes for any name whose meaning is not settled: an
# absent entry writes no ``help`` key at all, which is exactly what the app
# shows nothing for.
#
# **Where a name here can also reach a role, the two tables must agree.**  A
# field is answered by :func:`help_for` on its input name and, failing that, by
# :func:`help_for_role` on the role the wiring minted.  Some fields can be
# reached by both -- and the harm is not that two tables know it, it is two
# tables saying **different** things about it, because then only the lookup
# order decides which words a person reads.  A test enumerates every such pair
# from `analysis.py`'s own polarity rule and asserts the sentences are equal.
#
# The pairing is the whole argument.  Measured on a real catalogue, all four
# pairings occur:
#
#     id 'prompt'           bound to an input named 'text'
#     id 'negative_prompt'  bound to an input named 'text'
#     id 'prompt'           bound to an input named 'prompt'
#     id 'negative_prompt'  bound to an input named 'prompt'   <- these
#
# Some workflows carry a **negative** prompt field whose bound input is
# literally called ``prompt``: `analysis.py` reads the polarity off the wiring
# and overrides the name.  So ``prompt`` must never be a key here while
# ``ROLE_HELP`` says something else under ``negative_prompt`` -- add it, an
# obvious and well-meant improvement, and those workflows get "describe what you
# want" printed under the *negative* prompt.  Wrong words, in the very field
# this vocabulary exists to explain.  That is one forbidden pair, and the
# agreement rule forbids exactly it.
#
# ``negative`` and ``negative_prompt`` are both here and both safe, for the
# mirror-image reason: "negative" in an input's name settles the polarity by
# itself, and `analysis.py` reads it that way, so there the name really is
# evidence and the two tables say the same words.  "prompt" in a name settles
# nothing at all.
#
# ``negative_prompt`` in particular has to be here, and a rule that merely kept
# the two key sets apart deleted it and cost real behaviour: a field whose graph
# input is literally called ``negative_prompt`` loses its sentence the moment
# T-0097 gives its id a disambiguating suffix, because ``ROLE_HELP`` matches an
# id exactly and cannot answer, and this table is the only one that can.
INPUT_HELP = {
    "batch_size": "How many pictures to make in one go. More at once needs more memory.",
    "cfg": "How closely your words are followed. Too high looks harsh and overcooked.",
    "combine_embeds": "How several references are merged when you supply more than one.",
    "crop_position": "Which part of the picture to keep when it has to be cropped.",
    "denoise": "How much of the starting picture is redrawn. Lower keeps more of it.",
    "embeds_scaling": "How the reference's influence is scaled. Changes how forceful it feels.",
    "end_at": "When during the run this stops. Earlier leaves the final detail alone.",
    "end_percent": "When during the run this stops. Earlier leaves the final detail alone.",
    "height": "How tall the result is, in pixels. Bigger costs more time and memory.",
    "interpolation": "The method used when the picture is resized. Affects sharpness slightly.",
    "lora_strength": "How strongly the add-on changes the result. Zero turns it off.",
    "negative": "What to keep out of the result. Leave it empty if nothing comes to mind.",
    "negative_prompt": "What to keep out of the result. Leave it empty if nothing comes to mind.",
    # `pre_cfg` and `reference_latents_method` were here and are deliberately
    # gone.  Neither sentence survived being read: one had no antecedent -- "the
    # effect", with nothing said about which -- and promised an outcome this
    # vocabulary cannot keep, and the other's second clause had no subject and
    # carried no information.  Nothing truer would come, so silence is the
    # output, which is this table's own rule and not a concession: a line that
    # teaches nothing still costs a phone's vertical space, and a curator can
    # write what they know.
    "rand_seed": "The starting point for the randomness. The same number repeats a result.",
    "random_seed": "The starting point for the randomness. The same number repeats a result.",
    "noise_seed": "The starting point for the randomness. The same number repeats a result.",
    "sampler_name": "The method used to build the picture. Each has a slightly different look.",
    "scheduler": "How the effort is spread over the run. Affects texture more than content.",
    "seed": "The starting point for the randomness. The same number repeats a result.",
    "sharpening": "How much extra edge definition to add. Too much of it looks crunchy.",
    "shift": "Biases the run towards the overall shape or towards the fine detail.",
    "start_at": "When during the run this begins. Later leaves the early shape alone.",
    "start_percent": "When during the run this begins. Later leaves the early shape alone.",
    "steps": "How much work goes into the result. More steps, more detail, more waiting.",
    "strength": "How strongly this effect is applied. Zero leaves the result untouched.",
    "strength_clip": "How strongly the add-on changes the way your words are read.",
    "strength_model": "How strongly the add-on changes the picture. Zero turns it off.",
    "weight": "How strongly it is applied. Higher pushes the result further.",
    "weight_faceidv2": "How strongly the face reference counts, on top of the main strength.",
    "weight_type": "Chooses how that strength is applied, not how much of it there is.",
    "width": "How wide the result is, in pixels. Bigger costs more time and memory.",
}

#: The **second** table, and the only other one (T-0131-02).  Consulted by
#: `definitions.py` if and only if :data:`INPUT_HELP` said nothing, and never
#: instead of it.
#:
#: It exists because a few fields are named by the **wiring** rather than by an
#: input.  A text encoder's own input is called ``text`` in every graph; what
#: makes one of them the negative prompt is that its conditioning is consumed
#: as a sampler's ``negative``, which `analysis.py` reads and mints a role
#: from.  So the field id says ``negative_prompt`` while the input name says
#: ``text`` -- and ``text`` can never go in the table above, because it is
#: equally the input name of the *positive* prompt and one sentence cannot be
#: both.  Measured on a real catalogue: most workflows carry a
#: ``negative_prompt`` field, the commonest advanced field after ``seed``.
#:
#: **Its keys are roles, not ids in general.**  Every key here is one
#: `analysis.py` mints from the wiring, and ``analysis._ROLE_ORDER`` is the
#: authority for what those are -- a test asserts the subset, importing that
#: symbol, so this cannot quietly grow into "key on the field id", which is
#: the rule T-0131-01 rejected on measured grounds.
#:
#: **Where a role and an input name can both answer for one field, the two
#: tables must say the same words**, held by a test that enumerates those pairs
#: from `analysis.py`'s own polarity rule.  Two tables knowing a field is
#: harmless; two tables *disagreeing* about it is not, because then only the
#: lookup order decides what a person reads.  The measurement above
#: :data:`INPUT_HELP` names the pair this forbids.
#:
#: The earlier form of this rule -- keeping the two key sets *disjoint* -- was
#: broader than the hazard and cost real behaviour.  It deleted
#: ``INPUT_HELP['negative_prompt']``, and a field whose graph input is literally
#: called ``negative_prompt`` then lost its sentence as soon as T-0097 gave its
#: id a suffix: this table matches an id exactly and cannot answer, and the key
#: that could have was the one the rule removed.  Agreement permits that key and
#: still forbids the pair that matters.
#:
#: **Exact match only.**  A disambiguated ``negative_prompt-<hash>`` from
#: T-0097 gets no line **from here** rather than a guess about which of two
#: prompts it is.  It may still get one from :data:`INPUT_HELP`, on its input
#: name, which is a different question answered by different evidence.
#:
#: Why ``prompt`` is deliberately **not** a key of the table above, although
#: ``negative`` and ``negative_prompt`` are: the word "negative" in an input's
#: name settles its polarity by itself, and `analysis.py` reads it that way, so
#: the name is honest evidence and the two tables agree.  The word "prompt"
#: settles nothing -- an input called ``prompt`` wired into a sampler's
#: ``negative`` is the negative prompt, and that graph is reachable in five of
#: the catalogue's workflows -- so for the positive prompt the wiring is the
#: only authority, and it answers here.
ROLE_HELP = {
    "prompt": "Describe what you want to see. More detail gives more to go on.",
    "negative_prompt": "What to keep out of the result. Leave it empty if nothing comes to mind.",
}

# --------------------------------------------------------------------------
# The same vocabulary, in Russian (T-0143)
# --------------------------------------------------------------------------
#
# The two tables below are the *same sentences*, and nothing else.  They are
# not a second vocabulary and they do not describe one more input than the
# English ones do: a test asserts the key sets are **equal**, so a sentence
# added to one and forgotten in the other is a failing test rather than a
# field that silently speaks English to a Russian reader.
#
# **They never reach a definition file.**  The importer writes the English
# line and only the English line, which is also what a curator sees when they
# open the YAML.  These are read at *serve* time, by
# ``api/workflows.py``, for a request that asked for Russian -- so no file on
# anybody's disk changes, and `docs/workflow-schema.md` is untouched.
#
# Held to exactly the rules the English was held to, and the same mechanical
# test enforces them over both languages: one line, 40-90 characters, no
# colon, ends in a full stop, never names a model, a family or a vendor, does
# not restate the label above it, and does not explain jargon with jargon --
# no "CFG", no "денойзинг", no "сэмплер", no sampler names.
#
# Two vocabulary choices, made once and kept everywhere below so that a
# reader meets one word per idea:
#
# * a reference image is an "образец" -- ``combine_embeds``,
#   ``embeds_scaling``, ``weight_faceidv2``;
# * a LoRA-shaped extra is a "дополнение", never its file format's name --
#   ``lora_strength``, ``strength_model``, ``strength_clip``.
#
# And one rule that only the second language needed, because it is the one a
# translation breaks without changing a single English word: **a word this
# table uses for a quality a person WANTS may not also be the word it warns
# with.**  ``cfg`` first read "Перебор делает картинку резкой", and `резкость`
# is what ``sharpening`` and ``interpolation`` both offer as an improvement --
# so the warning could be read as a promise.  Check a new adjective against
# the whole set, not against its own sentence.
#
# **The agreement invariant of T-0131 holds in Russian too**, and the test
# that enforces it enumerates the reachable pairs once and checks every
# language.  ``negative``, ``negative_prompt`` and the ``negative_prompt``
# role therefore carry one identical Russian sentence, exactly as they carry
# one identical English one.
INPUT_HELP_RU = {
    "batch_size": "Сколько картинок сделать за один раз. Чем больше сразу, тем больше нужно памяти.",
    # "резкой" was here and is deliberately gone.  In an image-generation UI
    # `резкость` reads first as *in focus*, which is a quality a person WANTS
    # -- and this table uses it that way twice, under `sharpening` and
    # `interpolation`.  So the sentence could be read as "overdoing it makes
    # the picture sharp", which is the opposite of the warning.  `жёсткой`
    # was the obvious replacement and would only have moved the collision:
    # `sharpening` already ends "неестественно жёстко".  `контрастной` is used
    # nowhere else in this vocabulary and is how over-driven guidance really
    # looks.
    "cfg": "Насколько точно выполняются ваши слова. Перебор делает картинку контрастной и грубой.",
    "combine_embeds": "Как объединяются несколько образцов, когда вы даёте больше одного.",
    "crop_position": "Какую часть картинки оставить, когда её приходится обрезать.",
    "denoise": "Насколько сильно перерисовать исходную картинку. Меньше — больше от неё останется.",
    "embeds_scaling": "Как пересчитывается влияние образца. Меняет, насколько сильно оно ощущается.",
    "end_at": "Когда по ходу работы это заканчивается. Раньше — мелкие детали не тронуты.",
    "end_percent": "Когда по ходу работы это заканчивается. Раньше — мелкие детали не тронуты.",
    "height": "Какой высоты будет результат в пикселях. Больше — дольше и больше памяти.",
    "interpolation": "Способ, которым картинка меняет размер. Немного влияет на резкость.",
    "lora_strength": "Насколько сильно дополнение меняет результат. Ноль выключает его.",
    "negative": "Что не должно попасть в результат. Оставьте пустым, если ничего не приходит на ум.",
    "negative_prompt": "Что не должно попасть в результат. Оставьте пустым, если ничего не приходит на ум.",
    "noise_seed": "Отправная точка для случайности. То же число повторяет тот же результат.",
    "rand_seed": "Отправная точка для случайности. То же число повторяет тот же результат.",
    "random_seed": "Отправная точка для случайности. То же число повторяет тот же результат.",
    "sampler_name": "Способ, которым строится картинка. У каждого немного свой вид.",
    # "а не на содержание" was here and said more than the English does.
    # "Affects texture MORE THAN content" is a comparison; "а не" is a denial,
    # and this vocabulary's own rule is not to promise what it cannot keep.
    "scheduler": "Как усилия распределяются по ходу работы. Влияет больше на фактуру, чем на содержание.",
    "seed": "Отправная точка для случайности. То же число повторяет тот же результат.",
    "sharpening": "Сколько добавить резкости краям. Перебор выглядит неестественно жёстко.",
    "shift": "Смещает работу в сторону общей формы или в сторону мелких деталей.",
    "start_at": "Когда по ходу работы это начинается. Позже — общая форма не тронута.",
    "start_percent": "Когда по ходу работы это начинается. Позже — общая форма не тронута.",
    "steps": "Сколько труда вкладывается в результат. Больше шагов — больше деталей и ожидания.",
    "strength": "Насколько сильно применяется этот эффект. Ноль оставляет результат как есть.",
    "strength_clip": "Насколько сильно дополнение меняет прочтение ваших слов.",
    "strength_model": "Насколько сильно дополнение меняет картинку. Ноль выключает его.",
    "weight": "Насколько сильно это применяется. Больше — сильнее сдвигает результат.",
    # "насколько много значит" was here.  It is grammatical and nobody says
    # it -- the shape a sentence takes when it is converted rather than
    # written, which is the one thing this table cannot afford.
    "weight_faceidv2": "Насколько важен образец лица, сверх основной силы.",
    "weight_type": "Выбирает, как именно применяется эта сила, а не сколько её.",
    "width": "Какой ширины будет результат в пикселях. Больше — дольше и больше памяти.",
}

#: :data:`ROLE_HELP` in Russian.  Same keys, same two roles, same agreement
#: with :data:`INPUT_HELP_RU` that the English pair has with
#: :data:`INPUT_HELP`.
ROLE_HELP_RU = {
    "prompt": "Опишите, что хотите увидеть. Чем больше подробностей, тем лучше.",
    "negative_prompt": "Что не должно попасть в результат. Оставьте пустым, если ничего не приходит на ум.",
}

#: The language every caller gets when it asks for nothing, and the language
#: the importer writes into a definition file.  English is the fallback for a
#: language this vocabulary does not have -- never an error, and never an
#: empty string (`docs/api.md`).
DEFAULT_HELP_LANGUAGE = "en"

#: Every language the vocabulary speaks, English first.  Two, and adding a
#: third is adding two tables and nothing else.
HELP_LANGUAGES = ("en", "ru")

#: Language -> the **name** of the table that speaks it.  Keyed rather than
#: branched on, so the lookup functions below have one shape and a missing
#: language cannot take a different code path from a present one.
#:
#: The name and not the dict, so that the table is read at call time.  A
#: mapping that captured the objects at import would go on answering with the
#: sentences that existed when this module was first imported -- which is not
#: a hypothetical: T-0131's proof that an improved sentence reaches a
#: catalogue that already exists works by replacing :data:`INPUT_HELP`, and a
#: captured copy makes that test measure nothing.
_INPUT_HELP_BY_LANGUAGE = {"en": "INPUT_HELP", "ru": "INPUT_HELP_RU"}
_ROLE_HELP_BY_LANGUAGE = {"en": "ROLE_HELP", "ru": "ROLE_HELP_RU"}


def _table(by_language: dict, language: str) -> Optional[dict]:
    """The table for one language, read now, or ``None`` for a language we
    do not speak."""

    name = by_language.get(language)
    if name is None:
        return None
    return globals()[name]

# --------------------------------------------------------------------------
# Why a control is locked, as a slug
# --------------------------------------------------------------------------
#
# The prose reason below is what a curator reads; a slug is what groups thirty
# workflows' worth of locked controls together.  There is exactly one slug per
# judgement of :func:`classify` that returns :attr:`Exposure.LOCKED`, and no
# slug that no branch returns -- this is a name for a judgement that is already
# made, never a second taxonomy laid over it.  One judgement, "a web address",
# is asked in two places (branches 3 and 4c) and carries one slug in both.

#: Branch 2 -- the value ends in one of :data:`WEIGHT_SUFFIXES`.
LOCKED_WEIGHTS_FILE = "weights_file"
#: Branch 3 -- the value names a place on a disk, and is not a web address.
LOCKED_FILESYSTEM_PATH = "filesystem_path"
#: Branch 3b -- the whole input name is one of
#: :data:`BOOKKEEPING_INPUT_NAMES`.
LOCKED_EDITOR_BOOKKEEPING = "editor_bookkeeping"
#: Branch 4a -- the input's name is one of :data:`LOCKED_ANY_WORDS`.
LOCKED_MACHINE_SETTING = "machine_setting"
#: Branch 4b -- a string input whose name is one of
#: :data:`LOCKED_STRING_WORDS`.
LOCKED_FILE_REFERENCE = "file_reference"
#: Branches 3 and 4c -- the whole value is a web address
#: (:func:`looks_like_a_web_address`): in branch 3 one that is also path-like,
#: in branch 4c any other.
LOCKED_URL = "url"
#: Branch 4d -- the input's name says it chooses the model architecture,
#: family or version the workflow is built for
#: (:func:`_names_a_model_architecture`).
LOCKED_MODEL_ARCHITECTURE = "model_architecture"

#: Every slug this module can return.  ``analysis.py`` adds the one case that
#: only the graph can decide, and holds the union.
LOCKED_KINDS_FROM_VALUE = frozenset(
    {
        LOCKED_WEIGHTS_FILE,
        LOCKED_FILESYSTEM_PATH,
        LOCKED_EDITOR_BOOKKEEPING,
        LOCKED_MACHINE_SETTING,
        LOCKED_FILE_REFERENCE,
        LOCKED_URL,
        LOCKED_MODEL_ARCHITECTURE,
    }
)


class Exposure(str, Enum):
    """What may be done with one node input."""

    EXPOSE = "expose"
    LOCKED = "locked"
    UNCERTAIN = "uncertain"


@dataclass(frozen=True)
class Verdict:
    """What one input is, before the graph is consulted."""

    exposure: Exposure
    #: Why, in a sentence the curator's report prints as it stands.
    reason: str
    #: For :attr:`Exposure.EXPOSE`: the `docs/workflow-schema.md` field type.
    field_type: Optional[str] = None
    #: The provisional id stem.  ``analysis.py`` may replace it with something
    #: the wiring proves -- a prompt's polarity, a picture's part to play.
    role: Optional[str] = None
    #: Natural language, and therefore translatable.
    prompt: bool = False
    #: ``image`` or ``video`` when this input takes uploaded media.
    media: Optional[str] = None
    #: The input names a matte rather than a subject (case C).
    mask: bool = False
    #: For :attr:`Exposure.LOCKED`: which question locked it, as a slug from
    #: :data:`LOCKED_KINDS_FROM_VALUE`.  The reason above says it in words;
    #: this says it in one that can be counted.
    kind: Optional[str] = None

    @property
    def exposed(self) -> bool:
        return self.exposure is Exposure.EXPOSE


def is_literal(value: Any) -> bool:
    """Can a user's value be written here at all?

    A list or a mapping at ``inputs[name]`` is a wire to another node's
    output, and `docs/workflow-schema.md` refuses to bind over one -- that is
    a connection, not a value.  ``None`` is not a wire, but nothing can be
    said about the type behind it, so it is not a field either.
    """

    return value is not None and isinstance(value, (str, int, float, bool))


def looks_like_a_path(value: str) -> bool:
    """Does this string name a place on somebody's disk?

    **A separator on its own is not evidence and never was.**  ``w/`` is how
    English abbreviates *with*, and ``input/output``, ``before/after``,
    ``A/B test``, ``high/low`` and ``image/gif`` are all ordinary text a node
    offers as a setting.  Reading the slash in them as a path refused seven
    real workflows' worth of genuine dropdowns (T-0095), which is T-0072's and
    T-0080's lesson arriving a third time from a third direction.

    So the string has to carry one of five things, and each of them is a
    separate claim that can be wrong on its own:

    * a **drive** and a separator, ``C:\\`` or ``C:/`` (:data:`_DRIVE_PATH`).
      Matched as text and not with ``os.path``, because the graph may have
      been exported on the other kind of machine;
    * a **leading separator**, which is every other root there is
      (:data:`_ROOTED_PATH`): ``/home/u/models`` and ``/workspace``,
      ``//nas/models`` and ``\\\\server\\share`` for a UNC host, ``\\models``
      for the root of the current drive.  Most ComfyUI installations are not
      on Windows, and a rule that knew only one kind of machine's roots would
      hand a Linux user's own folder list to the app as an editable dropdown;
    * a **home** prefix, ``~``;
    * an **explicit relative** prefix, ``./`` or ``../``
      (:data:`_RELATIVE_PATH`).  Spelling one out is a statement about a
      filesystem even when the tail is a bare word;
    * a **separator whose last component is shaped like a file name**, which
      is the un-rooted case: ``models/checkpoints/foo.safetensors``.  Both
      halves are required.  Without the separator every ordinary
      ``photo.png`` would become a path; without
      :func:`looks_like_a_file_name` the slash would be doing the work again.

    That last clause is deliberately :func:`looks_like_a_file_name` and not a
    third opinion about the shape of a file: this project has answered that
    question twice already, and a third answer is how two of them come to
    disagree.

    What this gives up is an **un-rooted** directory carrying no file
    component -- ``models/checkpoints`` and ``output/`` are no longer
    path-like.  It is given up knowingly: such an input is almost always
    locked by its **name** instead (:data:`LOCKED_STRING_WORDS` holds
    ``path``, ``dir``, ``folder`` and ``output``), and what is left goes to
    review rather than to a user.  A value this stops calling a path never
    becomes editable by that alone -- :func:`classify` carries on to the
    locked words, the prompt rule, the safe-string rule and finally
    ``UNCERTAIN``.
    """

    if _DRIVE_PATH.match(value):
        return True
    if _ROOTED_PATH.match(value):
        return True
    if value.startswith("~"):
        return True
    if _RELATIVE_PATH.match(value):
        return True
    return _has_separator(value) and looks_like_a_file_name(value)


def looks_like_a_web_address(value: str) -> bool:
    """Is this string, **as a whole**, a web address?

    Surrounding whitespace is ignored and inner whitespace is not allowed, and
    what is left must parse -- with the standard library's
    :func:`urllib.parse.urlsplit`, not a pattern of our own -- to a non-empty
    scheme **and** a non-empty host name.  Each half refuses something real:

    * **the whole value.**  ``see https://example.invalid/page for the
      style`` is a prompt that mentions a web address, and a prompt stays a
      prompt.  Inner whitespace means any of it, not only a space:
      :func:`urlsplit` silently drops a tab or a newline, so two addresses
      joined by one would otherwise parse as one address;
    * **the host name.**  ``mode:fast`` and ``quality:high`` split into a
      "scheme" and a remainder like any ``word:word`` setting does, and they
      are settings, not places on the web.  It is the host **name**
      (``hostname``), not the whole authority (``netloc``): ``http://@`` and
      ``http://:80`` have an authority with no host in it, and name no place.

    A scheme is whatever :func:`urlsplit` accepts as one, so ``1http://x``
    counts as a web address.  That is known and left alone: a false yes here
    only locks a value, it never hands one to a user.

    Two schemes that parse with a host are **paths** and are refused (T-0272):

    * **a single letter** is a drive, in either case.  :func:`urlsplit` reads
      ``C://models/x.png`` as scheme ``c`` and host ``models``, and ComfyUI
      node packs do write ``X://insert/path/`` as a placeholder for a folder;
    * **file**: ``file://server/share/photo.png`` names a file on a share,
      not a place on the web.

    A value :func:`urlsplit` refuses to parse at all is not a web address by
    this definition, and goes on to the questions below it as it always did.
    """

    stripped = value.strip()
    if any(character.isspace() for character in stripped):
        return False
    try:
        parts = urlsplit(stripped)
    except ValueError:
        return False
    # urlsplit lower-cases the scheme, so ``C:`` and ``FILE:`` arrive as ``c``
    # and ``file``.
    if len(parts.scheme) == 1:
        return False
    if parts.scheme == "file":
        return False
    return bool(parts.scheme) and bool(parts.hostname)


def _has_separator(value: str) -> bool:
    """Does anything in this string join two parts the way a path does?"""

    return any(separator in value for separator in _PATH_SEPARATORS)


def _without_input_marker(value: str) -> str:
    """A loader's value with ComfyUI's trailing ``[input]`` marker taken off.

    ComfyUI writes ``photo.png [input]`` into an image loader to say which of
    its own folders the picture came from.  That is bookkeeping about where
    the file is, not part of the file's name, and every question here about
    the shape of a value has to be asked of the name.
    """

    stripped = value.strip()
    if stripped.endswith("]") and "[" in stripped:
        stripped = stripped[: stripped.rindex("[")].strip()
    return stripped


def has_suffix(value: str, suffixes: Tuple[str, ...]) -> bool:
    """Does this value end in one of ``suffixes``?

    The trailing ``[input]`` ComfyUI writes after a picture's name is stripped
    first, so a real loader value is still recognised as a picture.
    """

    lowered = _without_input_marker(value).lower()
    return any(lowered.endswith(suffix) for suffix in suffixes)


def looks_like_a_file_name(value: str) -> bool:
    """Does this string name a file, rather than merely being a word?

    A file name is a stem, a dot and an extension, and it is the **last path
    segment** that has to be one: ``portraits/photo.png`` names a file, while
    an aspect ratio written ``16/9`` does not, and neither does a folder
    written with a trailing separator.

    The extension is where the discrimination lives, and
    :data:`_FILE_EXTENSION` says what it is: alphanumeric with a letter in
    it.  Deliberately **not** "one of the suffixes this module lists" -- that
    would refuse a real workflow whose picture happens to be an ``.avif``,
    which is the mirror of the bug this predicate exists for.  ``1.5`` and
    ``v1.5.2`` are refused because a decimal point is not a dot before an
    extension, and ``.png`` alone is refused because a file has a name as
    well as a type.
    """

    leaf = re.split(r"[\\/]", _without_input_marker(value))[-1].strip()
    stem, dot, extension = leaf.rpartition(".")
    return bool(dot) and bool(stem.strip()) and bool(_FILE_EXTENSION.match(extension))


def sanitize_role(name: str) -> str:
    """An input name as a `docs/workflow-schema.md` id stem, or ``""``.

    The graph's own word for a control is the most honest stem available: it
    is what the curator sees in ComfyUI, it says what the input is *for*, and
    it does not move when node ids do.
    """

    role = "_".join(_tokens(name))
    return ROLE_SYNONYMS.get(role, role)


def help_for(name: str, language: str = DEFAULT_HELP_LANGUAGE) -> Optional[str]:
    """The one-line hint for a ComfyUI input name, or ``None`` for silence.

    Matched on the **whole** input name, normalised for case and for the
    character between its words, exactly as :func:`_is_bookkeeping` matches
    its own table -- and for the same reason.  A token match would reach
    ``strength`` inside ``strength_model`` and put the wrong sentence under a
    control that has its own, and it would reach ``weight`` inside
    ``weight_type``, where the two entries deliberately say different things.

    ``None`` is a first-class answer: the caller writes no ``help`` key at all
    rather than an empty one.  A name this vocabulary has nothing true to say
    about -- ``value`` above all -- is better left silent than filled in.

    ``language`` defaults to English, which is why the importer's call site
    did not change and why a definition file still carries the English line.
    A language this vocabulary does not speak falls back to English, and so
    does a name the Russian table happens to be missing -- silence would be a
    lie (the field *is* understood) and an error would be worse.  The missing
    key is caught by the test asserting the two key sets are equal, which is
    where that defect belongs; here it costs a reader English rather than a
    500.
    """

    if not isinstance(name, str):
        return None
    key = "_".join(_tokens(name))
    table = _table(_INPUT_HELP_BY_LANGUAGE, language)
    if table is not None and key in table:
        return table[key]
    return INPUT_HELP.get(key)


def help_for_role(role: str, language: str = DEFAULT_HELP_LANGUAGE) -> Optional[str]:
    """The hint for a role `analysis.py` minted from the wiring, or ``None``.

    The fallback of :func:`help_for` and never its equal: `definitions.py`
    reaches this only where the input name yielded nothing, so a field whose
    input name is known can never take its sentence from here.

    **Exact match, and no normalisation.**  A role is a string this project
    mints, not a word a graph wrote, so there is no spelling to forgive -- and
    an exact match is what keeps a T-0097 ``negative_prompt-<hash>`` out: two
    prompts the wiring told apart must not both be described as the negative
    one.

    ``language`` behaves exactly as it does in :func:`help_for`.
    """

    if not isinstance(role, str):
        return None
    table = _table(_ROLE_HELP_BY_LANGUAGE, language)
    if table is not None and role in table:
        return table[role]
    return ROLE_HELP.get(role)


def help_for_field(
    input_names: Iterable[str], role: str, language: str = DEFAULT_HELP_LANGUAGE
) -> Optional[str]:
    """This vocabulary's sentence for one field, or ``None`` for silence.

    The whole field-level rule in one place, so that the importer's writing
    of a hint and the gateway's serving of it cannot drift apart: the same
    two lookups in the same order, and the same refusal when a field's
    targets disagree.

    * ``input_names`` -- every graph input this field writes into.  Exactly
      one distinct name, or nothing is said at all: one sentence cannot
      honestly describe two differently-named inputs, and that absolute
      reading is `definitions.py`'s deliberate, measured decision, restated
      here rather than reinvented.
    * ``role`` -- the field's id, which for a field with no T-0097
      disambiguating suffix *is* the role `analysis.py` minted.  Consulted if
      and only if the input name said nothing.

    :func:`~localcanvas_gateway.workflows.sync.definitions._generated_help` is
    the importer's copy of this rule, on a ``PlannedField``; a test asserts
    the two answer identically for every field of every fixture graph, so a
    change to one that is not made to the other fails.
    """

    names = {name for name in input_names}
    if len(names) != 1:
        return None
    from_input_name = help_for(next(iter(names)), language)
    if from_input_name is not None:
        return from_input_name
    return help_for_role(role, language)


def field_type_of(value: Any) -> Optional[str]:
    """The schema type a literal binds as.  ``bool`` is checked first.

    In Python ``True`` is an ``int``; a boolean input read as an integer field
    would go back to ComfyUI as ``0``/``1`` and would then be a different
    graph from the one the user saw.
    """

    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, int):
        return "integer"
    if isinstance(value, float):
        return "float"
    if isinstance(value, str):
        return "string"
    return None


def classify(name: str, value: Any) -> Verdict:
    """What ``inputs[name] = value`` is, from the two of them and nothing else.

    The questions are asked in one fixed order, and the order carries meaning
    -- see the module docstring.
    """

    words = set(_tokens(name))
    role = sanitize_role(name)
    kind = field_type_of(value)
    if kind is None:
        return Verdict(
            Exposure.UNCERTAIN,
            "input {!r} holds {}, which is not a value a field can carry.".format(
                name, type(value).__name__
            ),
        )

    text = value if isinstance(value, str) else None
    # An architecture choice is a structural name too, so the media question
    # below is not asked of it: a name that also carries a media word must not
    # reach review through 1b, where a declared list would be offered to it.
    architecture_name = _names_a_model_architecture(name)
    structural_name = (
        bool(words & LOCKED_STRING_WORDS)
        or bool(words & LOCKED_ANY_WORDS)
        or architecture_name
    )

    # 1. Media, before any question about the shape of the string.  ComfyUI
    #    writes a picture's own subfolder into a loader input, so a slash here
    #    is part of the picture's name and not a path to lock away.
    if not structural_name:
        media = _media_kind(words, text)
        if media is not None:
            return Verdict(
                Exposure.EXPOSE,
                "input {!r} takes {} the user supplies.".format(
                    name, "a picture" if media == "image" else "a clip"
                ),
                field_type=media,
                role=role,
                media=media,
                mask=bool(words & MASK_WORDS),
            )
        # 1b. The name said media and the value did not bear it out.  Said
        #     here rather than left to rule 8, because the two halves of the
        #     evidence disagreeing is a different thing from a string nothing
        #     recognises, and the sentence reaches a curator's terminal.
        #
        #     This branch can take a verdict away from nothing below it: the
        #     media question above claims *every* string on a non-structural
        #     media-named input, so no such input has ever reached the
        #     questions below.  The only movement this card makes is out of
        #     EXPOSE-as-media and into review.
        if text is not None and _name_says_media(words):
            return Verdict(
                Exposure.UNCERTAIN,
                "input {!r} is named for media, but holds the text {!r}, which "
                "does not look like the name of a file a user would upload. It "
                "is neither exposed nor dropped: look at it and decide.".format(
                    name, _shorten(text)
                ),
            )

    # 2. A value that names a file of weights is structural whatever the input
    #    is called -- which is what makes this hold for an unknown loader.
    if text is not None and has_suffix(text, WEIGHT_SUFFIXES):
        return Verdict(
            Exposure.LOCKED,
            "input {!r} names a file of weights to load; which file loads is "
            "what the workflow *is*, not how it generates.".format(name),
            kind=LOCKED_WEIGHTS_FILE,
        )

    # 3. A value that names a place on a disk.  A web address whose last
    #    component is shaped like a file is path-like too, and it is locked
    #    here, before the name-driven locks below -- but what locks it is a
    #    web address, and the sentence and the slug say so (T-0082).
    if text is not None and looks_like_a_path(text):
        if looks_like_a_web_address(text):
            return _web_address(name)
        return Verdict(
            Exposure.LOCKED,
            "input {!r} holds a path on this machine; LocalCanvas never puts a "
            "filesystem path in front of a user.".format(name),
            kind=LOCKED_FILESYSTEM_PATH,
        )

    # 3b. ComfyUI's own bookkeeping, recognised by the **whole** input name.
    #     Asked here, after the media question and after both questions about
    #     the shape of the value, so that it cannot take a verdict away from a
    #     branch that already reached one: everything above still answers
    #     first.  Nor does it take one from a branch below -- none of the
    #     name-driven vocabularies further down shares a word with the two
    #     names here -- so this sits where it can only add an answer.
    if _is_bookkeeping(name):
        return Verdict(
            Exposure.LOCKED,
            "input {!r} is bookkeeping ComfyUI writes into its own API export "
            "beside a widget; nobody chose it, and nothing about what the "
            "workflow generates changes with it.".format(name),
            kind=LOCKED_EDITOR_BOOKKEEPING,
        )

    # 4. Names that are structural whatever they hold.
    machine_word = _first(words & LOCKED_ANY_WORDS)
    if machine_word is not None:
        return Verdict(
            Exposure.LOCKED,
            "input {!r} names {!r}, which belongs to the machine rather than to "
            "the picture.".format(name, machine_word),
            kind=LOCKED_MACHINE_SETTING,
        )
    file_word = _first(words & LOCKED_STRING_WORDS)
    if file_word is not None and text is not None:
        return Verdict(
            Exposure.LOCKED,
            "input {!r} names a file, a folder or a model to load "
            "({!r}).".format(name, file_word),
            kind=LOCKED_FILE_REFERENCE,
        )

    # 4c. A value that is, as a whole, a web address (T-0267).  Asked after
    #     every lock above -- a web address ending in a weights suffix stays
    #     a weights file, and a name-driven lock keeps its own kind -- so it
    #     takes no verdict away from any of them.  Asked before the prompt
    #     rule, the safe-setting rule and the final UNCERTAIN, each of which
    #     would otherwise hand the address to a user as a field to edit or
    #     to a curator as a string nothing recognised.
    if text is not None and looks_like_a_web_address(text):
        return _web_address(name)

    # 4d. A choice of which model architecture, family or version the graph is
    #     built for (T-0193).  Asked after every lock above, so a weights file,
    #     a path or a web address held under such a name keeps its own kind,
    #     and before everything that can expose or hold: a number, a flag, a
    #     safe-sounding word and an unsettled string all lock here, whatever
    #     they hold.  Asked here and not in `analysis.py` because the evidence
    #     is the name, so it holds on every node and whether or not a runtime
    #     declares a list -- the list proves which values exist, never that
    #     changing one is safe.
    if architecture_name:
        return Verdict(
            Exposure.LOCKED,
            "input {!r} selects which model architecture the workflow is built "
            "for, which only the workflow's author can change safely.".format(name),
            kind=LOCKED_MODEL_ARCHITECTURE,
        )

    # 5. Natural language.
    if text is not None and (words & PROMPT_WORDS):
        return Verdict(
            Exposure.EXPOSE,
            "input {!r} holds text written in a person's own language.".format(name),
            field_type="multiline",
            role=role,
            prompt=True,
        )

    # 6. Numbers and flags.  Writing one cannot change which files load or how
    #    the graph is wired: the worst it can do is generate differently, and
    #    that is exactly what Advanced is for.
    if kind in ("integer", "float", "boolean"):
        if not role:
            return Verdict(
                Exposure.UNCERTAIN,
                "input {!r} has no name this can turn into a field id.".format(name),
            )
        return Verdict(
            Exposure.EXPOSE,
            "input {!r} is a {} that changes how the workflow generates.".format(
                name, "flag" if kind == "boolean" else "number"
            ),
            field_type=kind,
            role=role,
        )

    # 7. A string naming one of the node's own choices.
    if (words & SAFE_STRING_WORDS) and role:
        return Verdict(
            Exposure.EXPOSE,
            "input {!r} selects one of the node's own settings.".format(name),
            field_type="string",
            role=role,
        )

    # 8. Neither could be proved.  Never a guess.
    return Verdict(
        Exposure.UNCERTAIN,
        "input {!r} holds the text {!r}, and nothing in the graph says whether "
        "that is a setting a user may change or something structural. It is "
        "neither exposed nor dropped: look at it and decide.".format(
            name, _shorten(str(value))
        ),
    )


def _web_address(name: str) -> Verdict:
    """The one verdict for an input holding a web address."""

    return Verdict(
        Exposure.LOCKED,
        "input {!r} holds a web address; LocalCanvas never puts a web address "
        "in front of a user as a field to edit.".format(name),
        kind=LOCKED_URL,
    )


def _is_bookkeeping(name: str) -> bool:
    """Is this input one ComfyUI writes for itself, by its **whole** name?

    The name is normalised for case and for the character between its words,
    and then compared **entire** against :data:`BOOKKEEPING_INPUT_NAMES`.  The
    normalisation is not a token match and must not become one: it is the same
    complete name written another way, so ``upload_strength`` and
    ``control_scale`` are untouched by it.  The vocabulary says why that
    matters.
    """

    return "_".join(_tokens(name)) in BOOKKEEPING_INPUT_NAMES


def _names_a_model_architecture(name: str) -> bool:
    """Does this input's name say it chooses a model architecture?  (T-0193)

    Either its word tokens carry :data:`ARCHITECTURE_MODEL_WORD` **and** one of
    :data:`ARCHITECTURE_PAIR_WORDS`, or the whole name, normalised, is one of
    :data:`ARCHITECTURE_INPUT_NAMES`.  Both halves of the pair are required:
    ``model`` alone is a hosted service's model selector, and ``type`` or
    ``version`` alone is any node's setting.

    **Only the input's own name is read** -- for a sub-input a node shape added,
    the part after the last :data:`SHAPE_PATH_SEPARATOR`.  `analysis.py` asks
    about such an input under its whole path, ``parent.child``, and the path's
    words are two names' words: a child ``task_type`` under a parent called
    ``model`` would otherwise pair the parent's ``model`` with its own ``type``
    and lock a task mode as an architecture (T-0193 review).  A child whose own
    name is in the class, ``parent.model_type``, still locks.
    """

    tokens = _tokens(name.rsplit(SHAPE_PATH_SEPARATOR, 1)[-1])
    words = set(tokens)
    if ARCHITECTURE_MODEL_WORD in words and words & ARCHITECTURE_PAIR_WORDS:
        return True
    return "_".join(tokens) in ARCHITECTURE_INPUT_NAMES


def _name_says_media(words: Set[str]) -> bool:
    """Does the input's own name say it takes media?  Half of the evidence."""

    return bool(words & MEDIA_WORDS) or bool(words & MASK_WORDS)


def _value_corroborates_media(text: str) -> bool:
    """Does the value bear out a name that says media?  The other half.

    Two things do.  **Nothing at all** -- a graph saved before a picture was
    chosen carries an empty value, and refusing that would refuse the very
    workflow a user is about to supply a picture to.  And a value shaped like
    the name of a file, which is what a reference to media looks like.

    ``nearest-exact``, ``h264``, ``8`` and ``1.5`` are none of those: they are
    tokens that happen to sit on an input whose name contains a media word,
    and reading them as pictures is what asked a user to upload a photograph
    for a codec (T-0080).
    """

    return not _without_input_marker(text) or looks_like_a_file_name(text)


def _media_kind(words: Set[str], text: Optional[str]) -> Optional[str]:
    """``image``, ``video`` or neither, from **both** halves of the evidence.

    The input's own name has to establish it -- a word from
    :data:`MEDIA_WORDS` or :data:`MASK_WORDS` -- *and* the value has to
    corroborate that there is media here at all, by being empty or by looking
    like the name of a file.  Only then is the value's suffix read, and only
    to settle **which** kind, because a matte may be a still or a clip.

    Each half alone has been a bug, in opposite directions.  A suffix that
    could establish media by itself made every string whose default happened
    to end in ``.png`` a required upload (T-0072); it can no longer do so at
    any point, so where the name does not say media this returns ``None``
    whatever the value ends in.  A **name** that could establish it by itself
    made ``image_format = 'nearest-exact'`` a required upload (T-0080); it
    can no longer do so either, so where the value does not look like a file
    this returns ``None`` whatever the name contains.

    Narrowing :data:`MEDIA_WORDS` is not the fix for the second of those and
    would not be one: a genuine ``images`` input has to stay media.
    """

    if text is None:
        return None
    if not _name_says_media(words):
        return None
    if not _value_corroborates_media(text):
        return None

    if words & VIDEO_WORDS:
        return "video"
    if words & IMAGE_WORDS:
        return "image"
    # The name says media without saying which.  The suffix breaks the tie,
    # and a value that says nothing leaves the commoner of the two.
    return _kind_from_suffix(text) or "image"


def _kind_from_suffix(text: str) -> Optional[str]:
    if has_suffix(text, VIDEO_SUFFIXES):
        return "video"
    if has_suffix(text, IMAGE_SUFFIXES):
        return "image"
    return None


def _first(values: Iterable[str]) -> Optional[str]:
    ordered = sorted(values)
    return ordered[0] if ordered else None


def _shorten(text: str, limit: int = 60) -> str:
    flat = " ".join(text.split())
    return flat if len(flat) <= limit else flat[: limit - 3] + "..."


__all__ = [
    "ARCHITECTURE_INPUT_NAMES",
    "ARCHITECTURE_MODEL_WORD",
    "ARCHITECTURE_PAIR_WORDS",
    "BOOKKEEPING_INPUT_NAMES",
    "DEFAULT_HELP_LANGUAGE",
    "DIMENSION_NAMES",
    "Exposure",
    "HELP_LANGUAGES",
    "INPUT_HELP_RU",
    "ROLE_HELP_RU",
    "FRAME_COUNT_NAMES",
    "FRAME_RATE_NAMES",
    "IMAGE_SUFFIXES",
    "INPUT_HELP",
    "IMAGE_WORDS",
    "LOCKED_ANY_WORDS",
    "LOCKED_EDITOR_BOOKKEEPING",
    "LOCKED_FILESYSTEM_PATH",
    "LOCKED_FILE_REFERENCE",
    "LOCKED_KINDS_FROM_VALUE",
    "LOCKED_MACHINE_SETTING",
    "LOCKED_MODEL_ARCHITECTURE",
    "LOCKED_STRING_WORDS",
    "LOCKED_URL",
    "LOCKED_WEIGHTS_FILE",
    "MASK_WORDS",
    "MEDIA_WORDS",
    "PROMPT_WORDS",
    "ROLE_HELP",
    "ROLE_SYNONYMS",
    "SAFE_STRING_WORDS",
    "SEED_ROLE",
    "VIDEO_SUFFIXES",
    "VIDEO_WORDS",
    "WEIGHT_SUFFIXES",
    "Verdict",
    "classify",
    "field_type_of",
    "has_suffix",
    "help_for",
    "help_for_field",
    "help_for_role",
    "is_literal",
    "looks_like_a_file_name",
    "looks_like_a_path",
    "looks_like_a_web_address",
    "sanitize_role",
]
