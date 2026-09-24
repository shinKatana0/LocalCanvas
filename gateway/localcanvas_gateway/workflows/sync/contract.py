"""What the ComfyUI that will run a graph declares one of its inputs accepts.

`semantics.py` says what an input *means* from its name and its value;
`analysis.py` says what the graph *does with it*.  Neither of them can say what
a node would **accept**, and an API-format graph cannot either: it carries the
value a node *has* and never the list it would take.  That is why an input
holding an unrecognised word is ``UNCERTAIN`` and the workflow needs review,
and that rule is not weakened here.

What is added is a third authority for the one question the graph cannot
answer.  ``/object_info`` is the user's own ComfyUI stating, for a node class
and an input name, the finite list of choices it offers.  Reading it is
**asking**, not inventing -- the same distinction ``bridge.py`` already makes
about the conversion itself.

Four rules shape this module.

**It only ever reports what the runtime declared.**  There is no default list,
no list keyed on an input's name, no list borrowed from a neighbouring class
and no list carried over from another workflow.  A class this ComfyUI does not
have, an input it does not declare, or an input declared as a type rather than
as a list of choices, all produce the same answer: nothing, and the caller's
behaviour is then exactly what it was before this module existed.

**A declared list is not automatically a setting.**  Some of them enumerate the
user's own files -- their weights, their pictures -- and a list of file names is
a file picker, not a control someone may type into.  :func:`names_files` is the
test, and it reuses `semantics.py`'s existing opinion about the shape of a file
name rather than writing a second one.  An option set that fails it is refused
here, so nothing downstream has to remember to refuse it.

*Why that test is two predicates and not three.*  ``semantics.has_suffix``
against the weights and media suffix lists would answer for every option this
module has to refuse -- and for none that ``looks_like_a_file_name`` does not
already refuse, because a value ending in ``.safetensors`` with a non-empty
stem satisfies both.  The only values it would add are ones with no stem at
all, such as a bare ``".safetensors"``, which is not a thing an option list
contains.  A third clause no honest test could fail on its own is a clause that
can be deleted with the suite still green, so the two that can are the two that
are here: the **shape** of a file name, and :func:`semantics.looks_like_a_path`,
which catches a list of the user's folders that carries no extension at all
**when those folders are rooted** -- a drive (``C:\\models``), a leading
separator (``/home/u/models``, ``\\\\server\\share``), a home ``~`` or an
explicit ``./`` or ``../``.  Its other clause, a separator whose last component
is shaped like a file name, adds nothing here: that last component already
satisfies the first predicate.  A bare separator is not evidence (T-0095), so an
un-rooted folder list such as ``models/checkpoints`` is caught by neither.

**A contract belongs to one ComfyUI.**  It is keyed on
:class:`~localcanvas_gateway.workflows.sync.bridge.ComfyIdentity`'s digest --
the fingerprint T-0084 already computes -- and :class:`ContractCache` hands one
back only for the identity it was built from.  Nothing here computes a second
fingerprint of its own, and no contract from one runtime may describe a
snapshot produced by another.

**It is a per-run memory and not a file.**  The identity probe already fetches
``/object_info`` once per run, so the contract costs one parse of a document
this run has in its hands.  Writing it to disk would be a second cache format,
with its own way of going stale, in exchange for nothing.

The shape that is read
----------------------
ComfyUI's ``/object_info`` gives each class an ``input`` block with
``required`` and ``optional`` sections, and each entry in them is a list whose
**first element** is either the name of a type (``"INT"``, ``"STRING"``, and so
on, as a string) or the finite list of choices the node offers.  A finite list
is one contract; ``"INT"`` and ``"FLOAT"`` are the second, the type whose
options are node shapes rather than values is the third, and ``"STRING"`` --
read for one fact, the default it declares -- is the fourth.  Anything else -- a
type this does not read, an empty list, a list holding something that is not a
plain value -- is read as "not declared", because the alternative is guessing,
and guessing here would put a control in front of a user that ComfyUI then
refuses.

An enumeration is declared in **two** shapes, not one
-----------------------------------------------------
ComfyUI is part-way through moving enumerations out of that first element.  The
older shape puts the choices there::

    "sampler_name": [["euler", "heun"], {...}]

and the current one puts a type name there, exactly like a number's, and moves
the choices into the configuration mapping beside it::

    "format": ["COMBO", {"options": ["auto", "mp4"], "default": "auto"}]

Both are the same declaration -- *this input takes one of these values* -- and
both are read here.  Reading only the first is not a smaller contract, it is a
**wrong** one: the runtime has said what an input accepts and the answer would
be "nothing was declared", which is the one sentence this module is not allowed
to say when something was.  Which shape a node uses says nothing about the node
except how recently it was written, and a rule that turned that into a
difference a user can see would be a rule about ComfyUI's release history.

The type name is matched exactly.  ``"COMBO"`` is an enumeration of plain
values; ``"COMFY_DYNAMICCOMBO_V3"`` is **not one of those**, and deliberately
never becomes one.  Each of its options carries its own nested
``required``/``optional`` inputs -- choosing one adds inputs to the node -- so
it is not a list of values a user picks between, and flattening it to the keys
of those options would offer a control whose meaning this module does not know.
:func:`declared_options` therefore answers ``None`` for it, exactly as it does
for a type name it has never heard of.

Everything a declared list has to satisfy is asked of both shapes and in one
place: an empty list declares nothing, an exact repeat of a value is read once,
two values equal in Python but of different types refuse the whole list, a
value that is not a plain option value refuses it, and the declared order is
kept.  There is deliberately no second copy of those rules for the
second shape -- two copies is how the two shapes would come to disagree.

A choice that changes the node, read as what it is
---------------------------------------------------
The dynamic type is still *read*, by :func:`declared_structural_keys`, and into
a table of its own that no caller can mistake for a list of choices.  What is
taken out of it when a document is read is the ``key`` of each option and
nothing else.  Each option object is kept whole, its ``inputs`` block
included, in :attr:`RuntimeContract.shapes` -- and kept **unread**: not
counted, not keyed on its own names.  Only the block of the one option a graph
chose is ever read, and only on request (below).

The reason the keys are worth having at all is a question only this document
can settle: **did the value the graph carries come out of this declaration?**
A workflow's author already picked one of these shapes and saved the graph that
way, and a value that is one of the declared keys is that choice, recorded.  A
value that is none of them is a word nothing on this machine recognises, and it
stays the honest unknown it has always been.  What is *done* with either answer
is `analysis.py`'s to decide, and it decides it in one place; this module
reports and judges nothing.

The one block that is read: the shape the graph chose
-----------------------------------------------------
Choosing a shape adds inputs to the node, and a graph carries them flattened
under the parent's name -- ``parent.child``, at any depth.  Such a sub-input is
an input like any other, and the runtime **does** declare it: inside the block
of the shape that added it.  Leaving that block unread judged it from its name
and value alone, which held a workflow whose sub-input the runtime declares a
node shape of its own, and handed out number controls with no declared type
and no bounds on workflows that already imported (T-0240).

So one block is read, and only on request: :meth:`RuntimeContract.under_shape`
reads the ``inputs`` of **the option a caller names**, and out of it the one
sub-input it names, and nothing else.  The caller -- `analysis.py` -- names the
option the graph holds, and only where that value is one of the declared keys;
a shape the graph did not choose is never read, counted or offered, which is
still the reason the block is not read with the rest of the document.  A
nested declaration describes a node that does not exist unless its key is the
one in force, and read for a shape the graph did not choose it would type an
input from a node this workflow is not.

What is found there is read by :func:`read_object_info`, the same reader as
every top-level entry, as a declaration of the flattened name on that class.
There is no second copy of those rules, so a sub-input is a choice list, a
number or a node shape on exactly the terms a top-level input is.

A number's type is one of the two things it declares
----------------------------------------------------
An API-format graph carries the value an input *has*, and a ``FLOAT`` widget
holding one whole unit is written out as the JSON number ``1``, which reads
back as a Python ``int``.  Deciding from that alone that the input is a whole
number makes a 0.0--1.0 strength a control that can be set to 0 or to 1 and to
nothing in between: the value is what the graph carries, and the **type** is
what the node declares, and the two are different questions.  So ``"INT"`` and
``"FLOAT"`` are read here beside the choice lists, from the same document and
the same entry.

The configuration mapping beside that type name carries ``min``, ``max`` and
``step``, which `docs/workflow-schema.md` already defines and the registry
loader already validates.  They are read here in the same pass, because they
are in the same three-line mapping and a second reader for them would be a
second thing to keep in step with ComfyUI's shape.  What this module does with
them is only what it does with everything else: report exactly what was
declared.  Whether a declared bound may be *written* -- whether it fits the
field's type, whether it is coherent, whether the value the graph already
carries satisfies it -- is a question about a field, and it is answered in
`analysis.py`, which is the module that has the field.

What a node hands on is declared too
------------------------------------
Beside its ``input`` block every class carries an ``output`` list: the type
name of each socket the node offers another node, in socket order --
``["FLOAT", "INT"]``, ``["IMAGE", "MASK"]``.  It is read here for one question
`analysis.py` asks about a string nothing else could settle: *does everything
this node produces go on to be a number?*  See :func:`declared_outputs`.

The same discipline as everything above.  The list is reported as written and
never interpreted here; a list this cannot read **whole** -- an entry that is
not a type name, as a node exposing a list of choices on a socket writes -- is
one it did not read, so the class carries no declaration rather than a partial
one.  ``category``, which sits beside it, is **not** read: it is where a node's
author files the node in a menu, and a node pack may put anything there.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Any, Dict, Mapping, Optional, Sequence, Set, Tuple

from . import semantics

#: The two sections of a class's ``input`` block that describe inputs a graph
#: can carry a literal value in.  Read in this order, and ``required`` wins:
#: an input cannot be in both, and if some build ever writes one twice, the
#: required declaration is the one the node is built around.
OBJECT_INFO_SECTIONS: Tuple[str, ...] = ("required", "optional")

#: ComfyUI's name for a numeric input type, and `docs/workflow-schema.md`'s
#: name for the same thing.  Exactly these two, spelled exactly this way: a
#: type name this does not know is not declared, and a runtime that one day
#: writes a third one gets the behaviour of a runtime that said nothing.
NUMERIC_TYPE_NAMES: Mapping[str, str] = {"INT": "integer", "FLOAT": "float"}

#: The keys of the configuration mapping beside a numeric type name that this
#: reads.  The schema has these three and no others, so nothing else is read:
#: ComfyUI writes several more (``default``, ``round``, ``control_after_generate``
#: and whatever a custom node adds), and a key with nowhere to go is a key that
#: would have to be invented a meaning for.
NUMERIC_BOUND_KEYS: Tuple[str, ...] = ("min", "max", "step")

#: ComfyUI's name for "one of a declared list", written where the legacy shape
#: wrote the list itself.  Exactly this word: ``COMFY_DYNAMICCOMBO_V3`` is a
#: different thing whose options carry nested inputs of their own, and a match
#: loose enough to take it would offer a control this module cannot describe.
COMBO_TYPE_NAME: str = "COMBO"

#: The key that the configuration mapping beside :data:`COMBO_TYPE_NAME`
#: carries the choices under.  The mapping also carries ``default``,
#: ``tooltip``, ``multiselect`` and whatever a custom node adds; none of those
#: are read, for :data:`NUMERIC_BOUND_KEYS`' reason.
COMBO_OPTIONS_KEY: str = "options"

#: ComfyUI's name for an input whose options are **node shapes** rather than
#: values.  Each of its options carries its own ``required``/``optional``
#: block, so picking one adds inputs to the node and picking another takes
#: them away again.  Spelled in full and matched exactly, for
#: :data:`COMBO_TYPE_NAME`'s reason.
DYNAMIC_COMBO_TYPE_NAME: str = "COMFY_DYNAMICCOMBO_V3"

#: The key one option of a :data:`DYNAMIC_COMBO_TYPE_NAME` input carries its
#: own name under.  The other key beside it is :data:`DYNAMIC_OPTION_INPUTS_KEY`.
DYNAMIC_OPTION_KEY: str = "key"

#: The key of the block one option of a :data:`DYNAMIC_COMBO_TYPE_NAME` input
#: would add to the node, in a class's own ``required``/``optional`` shape.
#: Never read by :func:`declared_structural_keys`; read only by
#: :meth:`RuntimeContract.under_shape`, for the one option a caller names.
DYNAMIC_OPTION_INPUTS_KEY: str = "inputs"

#: The key of a class's entry that lists the type names of its outputs.
OBJECT_INFO_OUTPUT_KEY: str = "output"


def _value_key(value: Any) -> Tuple[str, Any]:
    """Two values are the same value only when their types agree as well.

    Kept here, and imported by `analysis.py`, so that the two modules share one
    copy of the rule: ``1``, ``1.0`` and ``True`` are equal in Python and are
    three different values here.

    **Do not widen this to call** ``1`` **and** ``1.0`` **one value.**  Its
    callers need it type-exact: a declared choice list tidies away only an
    exact repeat and refuses ``1`` beside ``1.0`` (T-0186), and a node-shape
    key or a declared default is matched as written (T-0223, T-0244).  The one
    place the two spellings of a number are the same number is the grouping of
    fields, and that has its own function, ``analysis._number_key``, used by
    the grouping alone and only where there is evidence that the two inputs are
    one kind of control (T-0102).
    """

    return (type(value).__name__, value)


def _is_option_value(value: Any) -> bool:
    """Is this something `docs/workflow-schema.md` accepts as an option value?

    A string or a number, never a boolean -- ``True in [1]`` is true in Python,
    and the schema's own loader refuses a boolean option for that reason.  An
    empty string is refused too: the loader does, and an option nobody can see
    is not a choice.
    """

    if isinstance(value, bool):
        return False
    if isinstance(value, str):
        return bool(value)
    return isinstance(value, (int, float))


def _combo_options(spec: Sequence[Any]) -> Optional[Sequence[Any]]:
    """The choices a current-shape entry carries, before any of them is judged.

    ``spec[0]`` has already been established to be a string, so the only
    question left is whether it is the one type name that carries choices, and
    whether the mapping beside it holds a list of them.  Every way of not
    holding one is the same answer: a mapping that is not a mapping, absent
    (some builds write a ``remote`` route where the choices would be, and fetch
    them later), not a list, or empty.

    What it does **not** do is look at the values.  Judging them is
    :func:`declared_options`' single loop, which the legacy shape goes through
    as well -- so a repeated value is read the same way in both shapes, and
    neither can grow a rule the other does not have.

    There is deliberately no separate clause for ``options`` declared as a
    *string*: a string is not a list, the check below already refuses it, and a
    clause no honest test could fail on is a clause that can be deleted with
    the suite still green.
    """

    if spec[0] != COMBO_TYPE_NAME:
        return None
    config = spec[1] if len(spec) > 1 else None
    if not isinstance(config, Mapping):
        return None
    declared = config.get(COMBO_OPTIONS_KEY)
    if not isinstance(declared, (list, tuple)):
        return None
    if not declared:
        return None
    return declared


def declared_options(spec: Any) -> Optional[Tuple[Any, ...]]:
    """The finite list of choices ``spec`` declares, or ``None``.

    ``spec`` is one entry of a class's ``required`` or ``optional`` block, in
    either of the two shapes the module docstring sets out: the legacy one
    carrying the choices at ``spec[0]``, and the current one carrying
    ``"COMBO"`` there and the choices under ``options`` in the mapping beside
    it.  Where the choices were written makes no difference to anything below
    this line.

    The answer is ``None`` for everything that is not unambiguously such a
    list -- a type name with nothing behind it, an empty list, a list carrying
    a wire, a nested list, a dynamic combo whose options are not values at all,
    or a list holding two values Python calls equal that are of different
    types (``1`` and ``1.0``), which the schema's loader would refuse as a
    duplicate and which are not the same value either.

    An **exact** repeat -- the same value of the same type, by
    :func:`_value_key` -- is tidied up, and only that: the first occurrence is
    kept, in its declared place, and the later ones are dropped (T-0186).
    ComfyUI itself offers such a list, the same value twice in one widget, and
    choosing either submits the same value, so reading it once loses no
    choice.  Refusing it would hold every workflow carrying that node for a
    fault that is the node's.

    Choices a widget fetches from another route are not a declaration (T-0187).
    A ``COMBO`` whose mapping carries a ``remote`` route and no ``options``
    list declares nothing here, and LocalCanvas never requests that route: what
    the runtime states in ``/object_info`` is the whole of what is read.

    The **declared order is kept**.  It is the order the node's own author put
    the choices in and the order a user sees in ComfyUI, and it is presentation
    only: nothing downstream may derive an identity from it.
    """

    if isinstance(spec, str) or not isinstance(spec, (list, tuple)) or not spec:
        return None
    first = spec[0]
    if isinstance(first, str):
        declared = _combo_options(spec)
        if declared is None:
            return None
    elif isinstance(first, (list, tuple)) and first:
        declared = first
    else:
        return None
    options: list = []
    seen: list = []
    for value in declared:
        if not _is_option_value(value):
            return None
        # The same value again, of the same type: offered twice, read once.
        if _value_key(value) in seen:
            continue
        # Equal in Python but of another type (``1`` and ``1.0``): not a
        # repeat, and not two choices either -- the schema's loader compares
        # option values with ``==`` and refuses such a pair as a duplicate.
        if value in options:
            return None
        seen.append(_value_key(value))
        options.append(value)
    return tuple(options)


def declared_structural_keys(spec: Any) -> Optional[Tuple[Any, ...]]:
    """The names of the shapes a shape-changing input chooses between.

    :data:`DYNAMIC_COMBO_TYPE_NAME` is the one type on this runtime whose
    options are not values.  Each is an object carrying its own
    ``required``/``optional`` inputs, so choosing ``shape_a`` *adds* a
    ``sub_shape`` input to the node and choosing ``shape_b`` under that
    *adds* a ``sub_number`` float.  What the graph carries at such an input is
    therefore not a setting somebody tuned; it is **which node this is**.

    This reads exactly one thing out of that declaration: the ``key`` of each
    option, in declared order.  It is the only fact the importer needs, and it
    is needed for one question -- *did the value the workflow was saved with
    come out of this list?* -- which is what tells an author's deliberate
    choice apart from a word nothing on this machine recognises.

    **The ``inputs`` block beside each key is not looked at here.**  Not to
    count it, not to decide anything by it, and not to read a nested input out
    of it: a nested declaration describes a node that does not exist unless the
    key beside it is the one in force, and this function does not know which
    key that is.  The graph does, so the one block read is read later, and only
    for the key the graph holds -- :meth:`RuntimeContract.under_shape`, asked by
    `analysis.py` once that value has been found among these keys.  The keys
    themselves are never offered either -- see ``analysis.py``'s
    ``_structural_choice``, which is where the judgement lives.  This function
    only reports what was declared.

    ``None`` for everything that is not unambiguously such a declaration: a
    different type name, no configuration mapping, no ``options``, an empty
    ``options``, an option that is not an object, or an option whose ``key``
    is not a value `docs/workflow-schema.md` would accept.  A declaration this
    cannot read **whole** is one it did not read, exactly as a single bad
    entry refuses the whole list in :func:`declared_options` -- because a
    partial answer here would be "the author's value is not among the keys I
    managed to read", which is a refusal made out of this module's own failure
    rather than out of the runtime's declaration.

    There is deliberately **no rule about the same key twice** -- the keys are
    kept exactly as declared, repeats included, where :func:`declared_options`
    reads an exact repeat once.  The two lists are put to different uses and
    the difference is the whole reason: a choice list is *shown* to a user and
    the schema's own loader refuses a duplicate in one, while these keys are
    shown to nobody and written nowhere.  They answer a membership question,
    and a value is in a list or is not whether or not something else in it
    repeats; and `analysis.py` needs a repeated key kept, because a key
    declared twice chooses no single block.
    """

    if isinstance(spec, str) or not isinstance(spec, (list, tuple)) or not spec:
        return None
    if spec[0] != DYNAMIC_COMBO_TYPE_NAME:
        return None
    config = spec[1] if len(spec) > 1 else None
    if not isinstance(config, Mapping):
        return None
    declared = config.get(COMBO_OPTIONS_KEY)
    if not isinstance(declared, (list, tuple)) or not declared:
        return None
    keys: list = []
    for option in declared:
        if not isinstance(option, Mapping):
            return None
        key = option.get(DYNAMIC_OPTION_KEY)
        if not _is_option_value(key):
            return None
        keys.append(key)
    return tuple(keys)


@dataclass(frozen=True)
class NumericDeclaration:
    """What a runtime says one numeric input is, and what range it takes.

    ``field_type`` is `docs/workflow-schema.md`'s word -- ``integer`` or
    ``float`` -- because that is the vocabulary everything downstream of here
    speaks.  The three bounds are ``None`` wherever the runtime declared
    nothing usable, and a ``None`` here means exactly that: **not declared**,
    never "no limit" and never a limit to be filled in from somewhere else.

    Compared by value, so that two inputs of one logical field can be asked
    whether their runtimes said the same thing.
    """

    field_type: str
    minimum: Optional[float] = None
    maximum: Optional[float] = None
    step: Optional[float] = None


def _declared_bound(value: Any) -> Optional[float]:
    """One of ``min``/``max``/``step`` as the runtime declared it, or ``None``.

    A finite number that is not a boolean.  ``True`` is an ``int`` in Python
    and would become the bound ``1``; ``NaN`` and the infinities are what
    Python's own JSON reader produces for the ``NaN`` and ``Infinity`` tokens
    it accepts, and a comparison against either is false in both directions, so
    a bound built from one would be a rule nothing can satisfy or break.
    """

    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if not math.isfinite(value):
        return None
    return value


def declared_numeric(spec: Any) -> Optional[NumericDeclaration]:
    """The numeric type ``spec`` declares and its range, or ``None``.

    ``spec`` is one entry of a class's ``required`` or ``optional`` block, and
    the answer comes from its **first element** only: an input this runtime
    calls ``"FLOAT"`` is a float however whole the number in the graph looks,
    and an input it calls ``"INT"`` is an integer however the graph was saved.

    Nothing else in the entry decides the type.  Not the value in the graph --
    that is the mistake this exists to end -- not the input's name, and not
    what another workflow in the same catalogue happens to carry.  A spec whose
    first element is a type name this does not know, or is not a type name at
    all, declares nothing, and the caller is then exactly where it was.

    The configuration mapping is optional: ComfyUI writes one for every numeric
    input, but a node that declares a bare ``["INT"]`` has still declared that
    the input is whole, and that is the more important half.
    """

    if isinstance(spec, str) or not isinstance(spec, (list, tuple)) or not spec:
        return None
    first = spec[0]
    if not isinstance(first, str):
        return None
    field_type = NUMERIC_TYPE_NAMES.get(first)
    if field_type is None:
        return None
    config = spec[1] if len(spec) > 1 else None
    if not isinstance(config, Mapping):
        config = {}
    minimum, maximum, step = (
        _declared_bound(config.get(key)) for key in NUMERIC_BOUND_KEYS
    )
    return NumericDeclaration(
        field_type=field_type, minimum=minimum, maximum=maximum, step=step
    )


#: ComfyUI's name for a text input, matched exactly as spelled.
STRING_TYPE_NAME: str = "STRING"

#: The key of the configuration mapping beside a type name that carries the
#: value the node starts with.  Read for :data:`STRING_TYPE_NAME` only.
DEFAULT_KEY: str = "default"


@dataclass(frozen=True)
class StringDeclaration:
    """What a runtime says one text input starts with, if anything.

    ``has_default`` is whether the configuration mapping carries a
    :data:`DEFAULT_KEY` at all, and ``default`` is that value exactly as
    written -- whatever its type.  With no default declared, ``default`` is
    ``None`` and means nothing: "declared no default" is never "declared the
    empty string", and nothing downstream may read it as one.
    """

    has_default: bool
    default: Any = None


def declared_string(spec: Any) -> Optional[StringDeclaration]:
    """The text type ``spec`` declares and its default, or ``None``.

    ``spec[0]`` must be exactly :data:`STRING_TYPE_NAME`.  The mapping beside it
    is optional -- a bare ``["STRING"]`` still declares a text input, one with
    no default -- and nothing in it but the default is read: ``multiline``,
    ``placeholder`` and the rest describe a widget, not what the node starts
    with.
    """

    if isinstance(spec, str) or not isinstance(spec, (list, tuple)) or not spec:
        return None
    if spec[0] != STRING_TYPE_NAME:
        return None
    config = spec[1] if len(spec) > 1 else None
    if not isinstance(config, Mapping) or DEFAULT_KEY not in config:
        return StringDeclaration(has_default=False)
    return StringDeclaration(has_default=True, default=config[DEFAULT_KEY])


def declared_outputs(entry: Any) -> Optional[Tuple[str, ...]]:
    """The type names of every output one class declares, in socket order, or ``None``.

    ``entry`` is one class's whole entry in ``/object_info``.  The answer is
    its ``output`` list exactly as written, and ``None`` for everything that is
    not unambiguously such a list: no ``output`` key, something that is not a
    list, or a list with an entry that is not a non-empty string.  A node that
    offers a list of choices on a socket writes that list where a type name
    would be, and a declaration this cannot read whole is one it did not read
    -- the rule :func:`declared_structural_keys` follows, for its reason.

    An **empty** list is an answer, not an absence: a node with no outputs has
    declared exactly that.  What a caller makes of "every output is one of
    these" over no outputs at all is the caller's question, and `analysis.py`
    answers it.
    """

    if not isinstance(entry, Mapping):
        return None
    declared = entry.get(OBJECT_INFO_OUTPUT_KEY)
    if isinstance(declared, str) or not isinstance(declared, (list, tuple)):
        return None
    for name in declared:
        if not isinstance(name, str) or not name:
            return None
    return tuple(declared)


def names_files(options: Sequence[Any]) -> bool:
    """Do these choices enumerate somebody's files rather than settings?

    One option is enough.  A list of the user's weights commonly carries a
    ``"None"`` beside them, and a list with one file name in it is a file
    picker whatever else is in it.

    Both halves are `semantics.py`'s, deliberately: the shape of a file name is
    a question this project has already answered twice, and answering it a
    third time here is how the two answers would come to disagree.
    """

    for value in options:
        if not isinstance(value, str):
            continue
        if semantics.looks_like_a_file_name(value):
            return True
        if semantics.looks_like_a_path(value):
            return True
    return False


@dataclass(frozen=True, eq=False)
class RuntimeContract:
    """What one ComfyUI declares, for the inputs it declares a choice list for.

    Keyed on ``(class type, input name)`` and on nothing looser.  A list
    declared for one class says nothing about another class, and a list
    declared for one input says nothing about the next input of the same class
    -- both of those confusions would produce a control that looks right and is
    refused the moment a job runs.
    """

    #: The digest of the ComfyUI this was read from
    #: (:class:`~localcanvas_gateway.workflows.sync.bridge.ComfyIdentity`).
    identity_digest: str
    #: ``(class type, input name) -> the declared choices, in declared order``.
    options: Mapping[Tuple[str, str], Tuple[Any, ...]]
    #: ``(class type, input name) -> what the runtime declares the number is``.
    #: A separate table from :attr:`options` and not a merged one, because the
    #: two answer different questions and are asked at different moments: a
    #: choice list is asked for an input nothing could settle, a numeric type
    #: for one the graph settled *as a number* and only the runtime can say
    #: which kind of number.
    numerics: Mapping[Tuple[str, str], NumericDeclaration] = field(
        default_factory=dict
    )
    #: ``(class type, input name) -> the keys of the shapes it chooses
    #: between``.  A **third** table and not a merged one, for the reason
    #: :attr:`numerics` is separate: what is in here is not a list of values a
    #: user may pick from, it is the names of the node shapes the declaration
    #: offers, and a caller that took it for :attr:`options` would put "change
    #: which inputs this node has" in front of somebody as a dropdown.  The
    #: value tables are disjoint by construction -- one input carries one
    #: declaration, and :func:`read_object_info` records it once.
    structural: Mapping[Tuple[str, str], Tuple[Any, ...]] = field(
        default_factory=dict
    )
    #: ``(class type, input name) -> the options of that node-shape
    #: declaration, as the document holds them``, for exactly the inputs in
    #: :attr:`structural` and in the same order as its keys.  Kept, not read:
    #: nothing is taken out of an option's ``inputs`` block until
    #: :meth:`under_shape` is asked for one of them.
    shapes: Mapping[Tuple[str, str], Tuple[Any, ...]] = field(default_factory=dict)
    #: ``(class type, input name) -> what the runtime declares that text input
    #: starts with``.  A **fourth** table, disjoint from the other three for the
    #: same reason they are disjoint from each other: one input carries one
    #: declaration.
    strings: Mapping[Tuple[str, str], StringDeclaration] = field(
        default_factory=dict
    )
    #: ``class type -> the type names of its outputs, in socket order``.  Keyed
    #: on the class alone, because an output belongs to the node and not to any
    #: one of its inputs.  A class whose ``output`` list could not be read whole
    #: is absent, never present with part of it.
    outputs: Mapping[str, Tuple[str, ...]] = field(default_factory=dict)

    def options_for(self, class_type: str, input_name: str) -> Optional[Tuple[Any, ...]]:
        """The choices this runtime declares for that input, or ``None``."""

        return self.options.get((class_type, input_name))

    def numeric_for(
        self, class_type: str, input_name: str
    ) -> Optional[NumericDeclaration]:
        """What this runtime declares that number to be, or ``None``.

        Keyed on the class **and** the input, for the reason in this class's
        own docstring: two node classes carrying an input of the same name say
        nothing about each other, and one of them declaring a float is not
        evidence about the other.
        """

        return self.numerics.get((class_type, input_name))

    def structural_for(
        self, class_type: str, input_name: str
    ) -> Optional[Tuple[Any, ...]]:
        """The shape names this runtime declares that input chooses between.

        ``None`` for every input that is not one of those -- including every
        ordinary choice list, which lives in :attr:`options` and is reached
        through :meth:`options_for`.  Keyed on the class **and** the input for
        this class's own reason.
        """

        return self.structural.get((class_type, input_name))

    def outputs_for(self, class_type: str) -> Optional[Tuple[str, ...]]:
        """The output type names this runtime declares for that class, or ``None``.

        ``None`` is "not declared" -- a class this ComfyUI does not have, or one
        whose list was unreadable -- and ``()`` is a class declared to have no
        outputs.  The two are different answers and are kept apart.
        """

        return self.outputs.get(class_type)

    def string_for(
        self, class_type: str, input_name: str
    ) -> Optional[StringDeclaration]:
        """What this runtime declares that text input starts with, or ``None``.

        ``None`` for every input not declared ``STRING`` -- including one this
        ComfyUI does not have.  Keyed on the class **and** the input for this
        class's own reason.
        """

        return self.strings.get((class_type, input_name))

    def declares(self, class_type: str, input_name: str) -> bool:
        """Did this runtime declare that input in any table at all?"""

        key = (class_type, input_name)
        return (
            key in self.options
            or key in self.numerics
            or key in self.structural
            or key in self.strings
        )

    def under_shape(
        self,
        class_type: str,
        parent: str,
        index: int,
        child: str,
        input_name: str,
    ) -> Optional["RuntimeContract"]:
        """What one shape of a node-shape declaration declares for one sub-input.

        ``parent`` is an input this contract declares a node shape for, and
        ``index`` the position, among :meth:`structural_for`'s keys, of the one
        shape to look inside.  Which shape that is, is the caller's to know:
        the graph holds it, and `analysis.py` names it only where the graph's
        value is one of the declared keys.  Only that option's ``inputs`` block
        is read, and out of it only ``child``.

        The answer is a contract declaring exactly ``input_name`` -- the name
        the graph carries the sub-input under -- on ``class_type``, read by
        :func:`read_object_info` from a document holding that one entry, with
        this contract's outputs for the class beside it.  So the entry is a
        choice list, a number or a node shape on exactly the terms a top-level
        entry is, ``required`` winning over ``optional`` included.

        ``None`` wherever nothing is read: ``parent`` is not a node shape here,
        ``index`` is not one of its positions, the option's block is not a
        mapping, or nothing under ``child`` is a declaration this module reads.
        """

        options = self.shapes.get((class_type, parent))
        if options is None or isinstance(index, bool) or not isinstance(index, int):
            return None
        if not 0 <= index < len(options):
            return None
        block = options[index].get(DYNAMIC_OPTION_INPUTS_KEY)
        if not isinstance(block, Mapping):
            return None
        sections = {
            section: {input_name: block[section][child]}
            for section in OBJECT_INFO_SECTIONS
            if isinstance(block.get(section), Mapping) and child in block[section]
        }
        entry: Dict[str, Any] = {"input": sections}
        produced = self.outputs.get(class_type)
        if produced is not None:
            entry[OBJECT_INFO_OUTPUT_KEY] = list(produced)
        found = read_object_info(
            {class_type: entry}, identity_digest=self.identity_digest
        )
        if not found.declares(class_type, input_name):
            return None
        return found

    @property
    def declared(self) -> int:
        """How many inputs this runtime declares a choice list for.

        Choice lists only.  It is what a run's report already counts and what
        the sentence beside that number already means; folding a second kind of
        declaration into it would silently change a figure a curator reads.
        """

        return len(self.options)


def read_object_info(
    document: Any, *, identity_digest: str
) -> RuntimeContract:
    """Every literal choice list in one ``/object_info`` answer.

    Read defensively from end to end: this is another program's document, and
    a build that writes a section this does not recognise must cost nothing
    more than the inputs in that section.  An unreadable document produces an
    **empty** contract rather than an error -- a contract with nothing in it
    leaves every caller exactly where it was.
    """

    options: Dict[Tuple[str, str], Tuple[Any, ...]] = {}
    numerics: Dict[Tuple[str, str], NumericDeclaration] = {}
    structural: Dict[Tuple[str, str], Tuple[Any, ...]] = {}
    shape_options: Dict[Tuple[str, str], Tuple[Any, ...]] = {}
    strings: Dict[Tuple[str, str], StringDeclaration] = {}
    outputs: Dict[str, Tuple[str, ...]] = {}
    # Every input something was read for, in any of the four tables.  One
    # input has one declaration -- a list of choices, a numeric type, a set
    # of node shapes or a text type, never two of them -- so "``required``
    # wins" is one rule over all four tables and not four rules that could
    # come to disagree.
    seen: Set[Tuple[str, str]] = set()
    if not isinstance(document, Mapping):
        return RuntimeContract(
            identity_digest=identity_digest,
            options=options,
            numerics=numerics,
            structural=structural,
            shapes=shape_options,
            strings=strings,
            outputs=outputs,
        )
    for class_type, entry in document.items():
        if not isinstance(class_type, str) or not isinstance(entry, Mapping):
            continue
        # Read before the input block, and whatever that block looks like: a
        # node's outputs are a fact about the node, and one with no readable
        # inputs still declares what it hands on.
        produced = declared_outputs(entry)
        if produced is not None:
            outputs[class_type] = produced
        block = entry.get("input")
        if not isinstance(block, Mapping):
            continue
        for section in OBJECT_INFO_SECTIONS:
            declared = block.get(section)
            if not isinstance(declared, Mapping):
                continue
            for input_name, spec in declared.items():
                if not isinstance(input_name, str):
                    continue
                key = (class_type, input_name)
                if key in seen:
                    continue
                found = declared_options(spec)
                if found is not None:
                    options[key] = found
                    seen.add(key)
                    continue
                number = declared_numeric(spec)
                if number is not None:
                    numerics[key] = number
                    seen.add(key)
                    continue
                # Read last and recorded apart, because what it holds is not a
                # list of choices: see :attr:`RuntimeContract.structural`.
                shapes = declared_structural_keys(spec)
                if shapes is not None:
                    structural[key] = shapes
                    shape_options[key] = tuple(spec[1][COMBO_OPTIONS_KEY])
                    seen.add(key)
                    continue
                text = declared_string(spec)
                if text is not None:
                    strings[key] = text
                    seen.add(key)
    return RuntimeContract(
        identity_digest=identity_digest,
        options=options,
        numerics=numerics,
        structural=structural,
        shapes=shape_options,
        strings=strings,
        outputs=outputs,
    )


class ContractCache:
    """One contract per ComfyUI, handed back only to the ComfyUI it came from.

    The check is one comparison and it is the whole of the provenance rule:
    a contract read from one installation must never describe a graph produced
    by another, because what an input accepts is exactly what moves when a
    custom node is installed, updated or removed.  T-0084's digest already
    says when that has happened, and this asks it rather than inventing a
    second way of noticing.
    """

    def __init__(self) -> None:
        self._contracts: Dict[str, RuntimeContract] = {}

    def store(self, contract: RuntimeContract) -> None:
        self._contracts[contract.identity_digest] = contract

    def get(self, identity_digest: str) -> Optional[RuntimeContract]:
        """The contract for that identity, or ``None`` for any other.

        The lookup **is** the guard: the digest is the key, so a run asking
        with a different one finds nothing rather than finding the contract of
        an installation it is not talking to.  There is deliberately no second
        comparison beside it -- a check the key already made is a check no test
        could fail on its own.
        """

        return self._contracts.get(identity_digest)


__all__ = [
    "COMBO_OPTIONS_KEY",
    "COMBO_TYPE_NAME",
    "DEFAULT_KEY",
    "DYNAMIC_COMBO_TYPE_NAME",
    "DYNAMIC_OPTION_INPUTS_KEY",
    "DYNAMIC_OPTION_KEY",
    "NUMERIC_BOUND_KEYS",
    "NUMERIC_TYPE_NAMES",
    "OBJECT_INFO_OUTPUT_KEY",
    "OBJECT_INFO_SECTIONS",
    "STRING_TYPE_NAME",
    "ContractCache",
    "NumericDeclaration",
    "RuntimeContract",
    "StringDeclaration",
    "declared_numeric",
    "declared_options",
    "declared_outputs",
    "declared_string",
    "declared_structural_keys",
    "names_files",
    "read_object_info",
]
