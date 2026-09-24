"""Turning one API-format graph into the logical fields a person would set.

`semantics.py` says what an input *is*; this module says what the graph *does
with it*, groups the inputs a user would think of as one control, and mints
the id that control will be known by for as long as the workflow exists.

Stable ids are the requirement everything else here serves
--------------------------------------------------------
My defaults, the current draft, saved setups and an imported profile are all
keyed on ``workflow_id`` + **logical field id** (Phase 3).  So an id must
survive a CHANGED sync whenever the field's semantic identity is unchanged --
including a re-export in which every node id in the graph moved.

An id is therefore derived from **the part the input plays**, and never from a
node id, a node's place in the file, or its index in any iteration order:

1. **The role.**  The graph's own word for the control (``seed``, ``steps``,
   ``cfg``), canonicalised through the few synonyms `docs/workflow-schema.md`
   names, or a word the wiring proves -- ``negative_prompt`` for a text whose
   conditioning is consumed as a sampler's ``negative``, ``reference_image``
   for a picture consumed under that name.  One role, one field, and the id is
   that role: ``prompt``, ``seed``, ``width``.
2. **A structural fingerprint, and only when the role is not unique.**  Two
   legitimately different seeds are two fields and need two ids, so each takes
   a short digest of what its node is wired *into* and *out of* -- class types
   and input names, never node ids, never titles and never values.
   Renumbering the graph does not change it; editing a prompt does not change
   it.

   **How far it looks is adaptive, and only where it has to be.**  Every
   fingerprint is first taken :data:`FINGERPRINT_DEPTH` hops up and down.
   Where two groups of one role come out identical at that depth -- two seeds
   of a two-pass sampler, two reference pictures -- those groups, and only
   those, are looked at one hop further, and again, until they differ; the
   walk is bounded by the size of the graph and stops as soon as nothing
   further is left to see.  A group that did not collide keeps exactly the id
   it had at the base depth, so this moves no id that was already minted
   (T-0220).  See :func:`_separate`.

   A field that drives several node inputs has one such digest per member, and
   the fingerprint in its id is minted from **all** of them at once: the
   distinct member fingerprints, sorted, digested together -- so **no
   permutation of a group's members can change its id**, and the order the
   members are held in is not an input to an id at all.  Where the members
   speak with one voice -- every field bound to a single input, and any group
   whose members are wired alike -- that one fingerprint *is* the field's,
   unchanged, so this rule moves no id that a first member's fingerprint
   already got right.  Reading ``members[0]`` instead is what made a collapsed
   control's id a function of the graph's numbering, which is the promise of
   this section broken by the code under it (T-0113).
3. **Nothing else.**  Where two same-role inputs cannot be told apart at any
   depth the graph has, or a picture's part cannot be established, the
   workflow is ``NEEDS_REVIEW`` and no id is minted at all.  A guessed id
   either loses a user's saved settings or applies them to the wrong control,
   and both are silent.

Collapsing
----------
One logical field may drive several node inputs, and `docs/workflow-schema.md`
already carries the list form of ``bind``.  Two inputs collapse **only on
provable sameness**: the same role, the same type, the same value, and the
same thing declared about them by the ComfyUI that will run the graph -- the
same list of choices, and the same kind of number.  That is what "the same
value genuinely feeds both" looks like in a file.  Two samplers carrying
different seeds stay two fields; two inputs whose names merely look alike stay
two fields.

The same value is compared as written, type and all -- with one exception, and
it has to be earned.  ``1`` and ``1.0`` are the same number, and a re-export
that writes one input's whole-valued number the other way must not split a
control and move its id (T-0102).  So two groups holding the same number in
those two spellings are joined -- but **only where there is evidence that they
are the same kind of control**, for every pair of inputs across them: the
runtime declares the same kind of number for both, or it declares none for
either and both are the same input on the same class type.  Without that
evidence they stay apart exactly as before, which is what keeps T-0097's two
unrelated ``value`` inputs -- a guidance scale holding ``4.0`` on one class and
a step count holding ``4`` on another -- two controls when no runtime is there
to say so.  ``True`` is never a number.  See
:func:`_one_number_however_written`.

How far a number goes is **not** part of that question.  Two nodes that take
the same whole number over slightly different ranges, or with an increment
declared on one widget and not the other, are still one control -- so the
range is not in the key, and the field carries the range they *share*: the
greatest ``min`` and the least ``max`` either of them declared.  Where the
value the graph carries lies inside that range, it is a range both nodes
accept, which is the thing a range is there for; where the value contradicts
one end of it, that end is dropped rather than moved, exactly as it is for a
single input, and the field is as unbounded on that side as it was before any
of this.  Nothing is clamped, in either direction.

The declaration is in that list because the graph's own word for an input is
not always a word: ``value`` is what ComfyUI's ``Primitive*`` family calls its
only input, and two of them holding the same number is no evidence at all that
they are one control.  One can be a guidance scale and the other a step count,
and merged they are a single slider silently setting both.  What separates
them is not a guess about the name and not the shape of the value -- it is
that the runtime declares one a ``FLOAT`` and the other an ``INT``, which is
positive evidence, on the authority of the machine that will run the graph.
See :func:`_declaration_key`, and :func:`_options_key` beside it, which makes
the identical argument for a list of choices.

**Silence is not evidence, in either direction.**  A runtime that says nothing
about an input has not said it is a different control, so an input one class
declares and another does not still collapse: what the key carries is the kind
of number the field will *really* be, and an undeclared input is the kind of
number its value is written as.  A key that split on "somebody spoke about
this one" would give the same catalogue two different sets of ids on two
machines -- one ComfyUI missing a node pack the other has is enough -- and
every saved default keyed on the id that vanished would be orphaned with
nothing about the workflow having changed.

The four media cases
--------------------
* **A** -- the same picture in several loaders: one role, one value, so it
  collapses into one field with several bindings, by the ordinary rule.
* **B** -- a source and a semantically distinct reference: the wiring consumes
  them under different names, so they take different roles and become two
  fields, each named for its part.
* **C** -- a matte or other technical secondary picture: not exposed at all,
  and recorded as not exposed -- in :attr:`ImportPlan.not_exposed`, in the
  control inventory below, and from there in the run's report and on the
  curator's terminal.
* **D** -- two pictures the graph gives the same role to.  They are told
  apart the way two seeds are: by where each one is wired, looked at as far
  as it takes (point 2 above).  Where the wiring differs, they are two picture
  fields with ``image-<fingerprint>`` ids and labels from the same ladder any
  two same-named controls get.  Where it never differs, there is nothing to
  distinguish "the photo" from "the other photo" by, the *identity of the
  slot* cannot be established, and the workflow is ``NEEDS_REVIEW``.

Several image loaders are never, by themselves, a reason to refuse a
workflow.

Asking the runtime, and the order that makes it safe
----------------------------------------------------
`semantics.py` judges an input from its name and its value, and a string it
cannot prove anything about is ``UNCERTAIN``.  That rule stands.  What this
module adds is a **third authority for that one case**: `contract.py` carries
what the user's own ComfyUI declares an input accepts, and an ``UNCERTAIN``
string whose class and input the runtime declares a finite list of choices for
becomes a ``select`` over exactly those choices.

The order is the whole safety argument, and it is structural rather than a
special case::

    node-shape declaration -> the value is one of its keys -> LOCKED (node_shape);
       (asked first)                                          nothing below is asked
                           -> the value is none of its keys -> held for review;
                                                              nothing below is asked
                           -> no declaration, no contract  -> go on below
    semantics.classify()   -> LOCKED     -> stays locked; no choice list is asked
                           -> EXPOSE     -> stays as it is; no choice list is asked
                           -> UNCERTAIN  -> the choice list is asked,
                                            and may only upgrade -- and an
                                            upgrade on a node whose job is
                                            loading is LOCKED instead;
                                            where no choice list is declared at
                                            all, a string on a node whose every
                                            output is a number is LOCKED
                                            (computation), one on a node whose
                                            every output is a model is LOCKED
                                            (model_patch), and failing that, a
                                            string that is its node's only
                                            input, on a node wired straight into
                                            a prompt, is that prompt; last of
                                            all, text the runtime declares
                                            STRING and saved at exactly its
                                            declared default is LOCKED
                                            (declared_default); what is still
                                            held where the runtime declares a
                                            number and the value is not one is
                                            held with a sentence saying so

The first step reads the one table of a contract that is about **node shapes**,
and it runs before ``classify`` because what it knows is something ``classify``
cannot see: see :func:`_structural_choice`.  Such an input's options are not
values -- each carries its own inputs, so choosing one adds inputs to the node
-- and the value the graph holds at it is which node this is rather than a
setting.  Whether it is safe to change is therefore a fact about the
*declaration*, not about the name or the value, and ``classify``, which reads
only those two, answers ``EXPOSE`` for a ``mode`` holding ``orbit`` just as it
would for any other plain word.  Asked only after ``classify``, such an input
reached the user as a text box whose meaning is "be a different node" (T-0195).

What that step can do is narrow, and that is what makes it safe to take first:

* where the value the graph carries is one of the declared shapes, it answers
  ``LOCKED`` at exactly that value.  That can turn an editable input into a
  locked one, and an input ``classify`` locks for another reason into one
  locked for this one -- the outcome is the same and only the sentence a
  curator reads changes, to the true reason;
* where the value is **none** of the keys (compared exactly, as written and of
  the same type -- ``Orbit`` is not ``orbit``, ``True`` is not ``1``, ``1.0``
  is not ``1``), it holds the workflow for review, whatever ``classify`` would
  have answered (T-0223).  Such an input exposed is a text box where only the
  declared keys are legal and a different one changes the node's shape --
  the defect this step exists for -- and a value no shape declares cannot run
  on this ComfyUI as saved;
* no declaration and no contract answer nothing, and the input goes through
  ``classify`` exactly as it always did.  So the step never unlocks an input
  and never exposes one.

The value tables in a contract are disjoint, so an ordinary list of choices is
never in the one read first, and nothing about a choice list moved.

Every question in that diagram is asked of one declaration, and for a
sub-input a node shape added -- ``parent.child`` in the graph -- that is the
declaration nested under the key the graph holds at each parent on the path,
where each parent is a node shape and its value is one of its keys.  It is
asked exactly as a top-level one is, node-shape step first; a path that does
not resolve asks the top-level contract, as before.  Only the block under the
key in force is ever read: see :func:`_chosen_shape_contract`.

A checkpoint dropdown is the case that matters for those.  ``/object_info``
lists every installed set of weights as a literal option list, so a rule that
read the choice lists first would turn "which model this workflow is" into a
control -- and it would do it *because* the choices are known.  The choice
lists are asked in one place, inside the ``UNCERTAIN`` branch below, after
``LOCKED`` has already returned.  They cannot reach a locked input, and they
cannot change one that is already exposed.  The node-shape step above cannot
weaken that either: the most it can do to any input is lock it or hold it.

Knowing every legal value is not permission to change it
--------------------------------------------------------
That ordering holds for a list of *file names*, because a list of file names is
recognisably one.  It does not hold for a plain enum, and the first real import
proved it: an input naming which architecture a text encoder's weights are read
as is a short unremarkable word, so ``classify`` answers ``UNCERTAIN``, the
runtime truthfully declares its finite list, and *which model this workflow is*
reaches the user as an editable dropdown of which exactly one value works.

``/object_info`` proves what values **exist**.  Nothing in it proves that
changing one is **safe**, and the missing fact was already in this module's
hands: the node's own class type.  So one judgement stands between the
declaration and the control -- :func:`_structural_load`.  A node whose class
type carries the word ``Load`` or ``Loader`` announces that its job is loading,
and a loading node's unrecognised inputs describe what is being loaded and how
it is interpreted rather than how the picture is generated.  The upgrade is
refused and the input is ``LOCKED`` instead, with the
:data:`LOAD_SETTING_KIND` slug.

It is deliberately the narrowest rule that answers the defect, in four
directions at once:

* it gates **the upgrade and nothing else**.  What it can turn into a lock is
  a control that was about to be editable; an input that was going to be held
  for review is still held for review, on a loading node exactly as anywhere
  else.  So this can move no workflow into ``NEEDS_REVIEW`` and none out of it,
  and the number that imports is the number that imported before;
* it reads the **node**, never the input's name.  The name has already been
  judged and found to say nothing, and "it is called ``type``" is precisely the
  evidence T-0072, T-0080 and T-0095 each measured and each rejected;
* it reads **no option value**.  A model family may not be named in application
  logic at all, and the list is the user's own data;
* it reaches nothing a loading node genuinely settles.  A number, a flag, a
  prompt or a picture on that same node is answered by `semantics.py` and never
  passes this way, so a loader's real tunables are untouched.

The contract may also refuse.  A declared list of **file names** is a file
picker, not a setting, and stays ``UNCERTAIN``; a current value the runtime
does not offer is ``NEEDS_REVIEW`` naming the input and the value, and is never
quietly replaced with an option that does exist.  And **nothing about the id
comes from the contract**: not the selected value, not the list, not its order.

A string that only ever becomes numbers
---------------------------------------
Some text in a graph is not a setting in words, it is arithmetic: an
expression a math node evaluates, a comma-separated list a node turns into a
sampler's schedule.  ``classify`` sees a short string under an uninformative
name and answers ``UNCERTAIN``, and it is right to -- the name and the value
say nothing.  What does say something is the node, through the runtime: a
class whose **every** declared output is a number (:data:`COMPUTATION_OUTPUTS`)
turns whatever that text says into numbers another node reads.  Such a string
is ``LOCKED`` with the :data:`COMPUTATION_KIND` slug, at exactly the value the
graph carries.  See :func:`_structural_computation`.

It is a door that opens one way:

* it is asked only for a **literal string** still ``UNCERTAIN`` after every
  earlier authority, on an input the runtime declares **no** choice list for
  -- a declared list that refused the value, or named files, keeps its own
  sentence and stays held;
* it can only lock.  It never exposes, never unlocks, and with no contract, or
  a class the contract does not declare outputs for, it does nothing at all;
* it reads **no class name and no input name** (T-0072, T-0080, T-0095), and
  not ``category`` either, which is menu placement a node pack sets freely.  A
  node with no outputs is not "all numbers": it produces nothing, and it is
  left alone.

The same door opens once more, right after it, for a node whose every declared
output is a **model** (:data:`MODEL_PATCH_OUTPUTS`, the model type alone): the
text on such a node -- a list of layers, of blocks, of frames to keep -- is how
the model it hands on is patched, and it is ``LOCKED`` with the
:data:`MODEL_PATCH_KIND` slug on exactly the terms above.  See
:func:`_structural_model_patch`.

Which kind of number, and how far it goes
-----------------------------------------
The contract answers a second question, in the one place a graph is *also*
unable to: an API-format export writes a ``FLOAT`` widget holding one whole
unit as the JSON number ``1``, and Python reads that back as an ``int``.  Read
from the value alone, a 0.0--1.0 strength becomes a whole-number control that
can be set to 0 or to 1 and to nothing between them -- a control that is
present, looks ordinary, and cannot hold the value the workflow needs.

So a number's **type** comes from what the runtime declares the input to be,
and the value in the graph is only the value:

    the runtime declares INT or FLOAT  ->  that is the type
    it declares nothing usable         ->  exactly the behaviour without it

Never from a decimal point, never from the input's name, and never from what
another workflow in the catalogue happened to be saved with.  ``semantics.py``
is untouched by this: :func:`semantics.field_type_of` still says what a *value*
can be carried as, which is the question it was written to answer, and this
module -- which is the one holding the node's class -- decides which of the two
numeric types the field takes.  Nothing here reaches a ``LOCKED`` input: a
number the graph settles is ``EXPOSE``, and a locked one has already been
recorded and skipped several branches above.

``min``, ``max`` and ``step`` come out of the same declaration, and they are
carried only where they are usable as they stand: the right kind for the
field's type, coherent with each other, and satisfied by the value the graph
already carries.  Where one is not, that one is left out.  Nothing is invented
and nothing is clamped -- a bound narrowed to fit, or a value moved to fit a
bound, would be this importer deciding what a workflow generates.

A field that drives several node inputs has several declarations to answer
from, and it takes the range they **all** allow: the greatest ``min``, the
least ``max``, and the ``step`` they all declare.  Every one of those numbers
was declared by a runtime.  The guarantee is conditional and is worth stating
as one: **where the value the graph already carries lies inside that range,
and each bound is one this field's type can carry, the range offered to the
user is one every node behind the control accepts.**  Where the value lies
outside it, the bound it contradicts is dropped -- as it is for a single input,
and more readily here, because an intersection is the tightest range in play --
and that side is left unbounded rather than clamped.  Where two ranges do not
overlap at all the field carries none, which is what an incoherent pair has
always meant here.

**And none of it is a name.**  Neither the declared type nor the bounds nor
whether a number was written ``1`` or ``1.0`` appears in the role or in the
structural fingerprint, which are the two things an id is made of, so nothing
here renames a control by describing it differently.

What does reach the **grouping key** is the field's type, its second
component, and the kind of number the runtime declares **where that is not the
kind the value is written as**, its fifth.  That is deliberate, because the key
is where "are these two inputs one control" is decided.  It is also the one
indirect way any of this can still move an id: a role carried by exactly one
group is its own id, and a role carried by several gives each of them
``role-fingerprint``, so a group that splits in two can change which of the
two forms is minted.

The two components together say when that happens.  The second is read from
the value, so it is the same for every member the key puts in one group; the
fifth is the declared type only where it differs from the second.  So two
inputs holding the same number **written the same way** are separated precisely
when **the kind of number they will end up being** differs -- one of them is
going to be a fractional control and the other a whole one, which is two
controls, so the id that covered both stood for a field that should never have
existed and an id like that ought to move.

The same number **written two ways**, ``1`` and ``1.0``, is the second and
third components differing over nothing but a spelling, and the key alone
would separate every such pair.  :func:`_one_number_however_written` joins the
two groups back where every pair of inputs across them is declared the same
kind of number, or is undeclared and the same input on the same class type --
so such a pair keeps one id wherever that evidence exists, and is separated,
as it always was, wherever it does not.  That second half is a deliberate
cost: two undeclared inputs on two different classes, or a declared input
beside a silent one, holding ``1`` and ``1.0``, stay two fields even where they
were meant as one, because without evidence the join would also merge T-0097's
unrelated pair.

**And when it moves it goes, rather than landing on one of the two.**  A
collapsed field's id is minted from all of its members (point 2 above), so it
is nobody's single fingerprint and neither half of a split inherits it.  That
is a deliberate change, and the alternative is worth knowing because it was
what happened before: while the id was read off ``members[0]``, the merged id
*was* one member's own id, so the split looked as though it kept an id and
added one -- and **which** half kept it was decided by which node id sorted
first, so renumbering the same graph handed the user's saved value to the other
control.  Measured, not reasoned: the fixture in
``tests/test_sync_collapse_evidence.py`` inherited onto node 3 as written and
onto node 4 renumbered.  A setting that follows a coin-flip half is worse than
one that is plainly orphaned, and orphaning is what this module already does
whenever a field's identity cannot be established -- so the id of a control the
graph never really had is left to go.

Everything else leaves an id where it was, and each of these was measured
rather than assumed.  A ``min``, a ``max`` and a ``step`` are not in the key,
so two nodes declared the same kind of number over different ranges keep their
one id.  Silence is not in the key either: an input one class declares and
another does not keeps the one id as well, so the same catalogue synced
against a ComfyUI missing a node pack produces the ids the other one produced.
A declaration that agrees with the value changes nothing, because it names the
type the field already had.  Whether a number was written ``1`` or ``1.0``
moves no id wherever the join above has its evidence.  The join never splits a
group the key formed and never touches another role, so the only other ids it
can reach are those of the same role's remaining groups, through the two
indirect ways any change in a role's groups has: the role becoming unique, and
a fingerprint collision settled at a different depth (point 2 above).  And with no
runtime to ask, every candidate's fifth component is ``""`` and the grouping is
the one this module made before any of this existed, apart from that join.

Two controls in one form need two names
---------------------------------------
Splitting a falsely merged control into two is only half the work: two fields
in one definition must also be **told apart by the person looking at the
form**.  Before this, a role that produced several fields took its label from
the nearest consumer input name, and two siblings whose values reach the same
kind of place got the identical one -- a guidance scale and a step count both
called ``Value (on true)``, the two loaders of a chain both called
``Strength model (model)``.  Distinct ids do not help there; nobody reads an
id off a form.

So a label is escalated, **only where it collides**, down a ladder of evidence
that ends in something injective.  A field nothing collides with keeps exactly
the label it had, which is why the ordinary catalogue does not churn.

1. **Where the value ends up.**  The nearest consumer input name is one hop of
   a wire; the rest of the wire is evidence of the same kind, and this module
   already names a role from it (``negative_prompt``, above).  A value reaching
   a switch's ``on_true`` and, two hops later, a sampler's ``cfg`` is
   ``Value (on true, cfg)``, and its sibling reaching ``steps`` is
   ``Value (on true, steps)`` -- the graph's own words for what each one
   actually sets.
2. **The node's own title.**  Two loaders chained one into the other end at the
   same sampler input, so the wiring cannot tell them apart -- measured, not
   assumed -- and the only remaining difference the graph carries is the name
   the author gave the node.  It is `unvalidated free text from the user's own
   file`, so it is treated as such: see :func:`_sanitised_title`.
3. **The field's own id.**  Where the wiring says the same thing and the author
   named nothing, there is no name in the graph and one is not invented.  The
   label says the id instead, which is honest in the only way left: it does not
   claim the two controls differ in a way they do not, it is the key a saved
   setting is filed under, and it is unique in every definition this module
   emits -- so the ladder terminates and **uniqueness is guaranteed rather than
   made likelier**.

None of it reaches an id, a grouping key or a fingerprint.  The evidence is
carried on :class:`InputCandidate` alongside the label evidence already there,
read only when a label collides, and merged across a field's members by depth
and by text, so the answer does not depend on node numbering or on iteration
order.

The control inventory
---------------------
Every judgement above is also recorded, as one :class:`ControlRecord` per
literal input the importer considered, whatever it decided.  Completeness is
the point: an input **present** in the inventory carries the decision that was
taken about it, so an input **absent** from it was never a candidate at all --
it is a wire to another node's output, which :func:`semantics.is_literal`
excludes.  A curator can then tell "this was recognised and deliberately
locked" from "this was never seen", which are otherwise the same silence.
"""

from __future__ import annotations

import hashlib
import math
import re
import unicodedata
from dataclasses import dataclass, replace
from typing import Any, Dict, List, Mapping, Optional, Sequence, Set, Tuple

from . import contract as runtime_contract
from . import semantics
from .contract import NumericDeclaration, RuntimeContract, _value_key
from .semantics import Exposure, Verdict

#: How far the structural fingerprint looks along the wires, to begin with.
#: Two hops each way is enough to tell most stages of a pipeline apart and
#: short enough that an unrelated change at the far end of a graph does not
#: move an id that had no reason to move.  Groups this depth cannot tell apart
#: are looked at further, and only they: see :func:`_separate`.
FINGERPRINT_DEPTH = 2

#: How near a consumer has to be for its name to mean "this is a matte".
#: Immediate, or one node further on, which is where a conversion sits.
MASK_EVIDENCE_DEPTH = 2

#: Consumer input names that say nothing about a picture's part beyond "it is
#: the picture": a role taken from one of these is just ``image``/``video``.
GENERIC_MEDIA_LABELS = frozenset(
    {
        "image",
        "images",
        "video",
        "videos",
        "pixels",
        "source",
        "src",
        "input",
        "input_image",
        "init_image",
        "frames",
    }
)

#: Case C, which only the graph can decide: a value and a name alone never say
#: that a picture is a matte.  The four slugs beside it are `semantics.py`'s,
#: one per branch of :func:`semantics.classify` that locks.
TECHNICAL_MEDIA_KIND = "technical_media"

#: The other case only the graph can decide: an input nothing settles, on a
#: node whose own class type says its job is to load something.  See
#: :func:`_structural_load`.
LOAD_SETTING_KIND = "load_setting"

#: The third case only a runtime can decide: an input whose declared options
#: are **node shapes** rather than values, so choosing another one adds or
#: removes inputs on the node instead of changing this one.  See
#: :func:`_structural_choice`.
NODE_SHAPE_KIND = "node_shape"

#: How a graph names an input a node shape added: the parent's name, this
#: character, the sub-input's name -- ``parent.child``, and again at every
#: further depth.  See :func:`_chosen_shape_contract`.
SHAPE_PATH_SEPARATOR = "."

#: The fourth: a string on a node whose every declared output is a number, so
#: what the text says is computation rather than a setting.  See
#: :func:`_structural_computation`.
COMPUTATION_KIND = "computation"

#: The output type names that make a node's product a number: ComfyUI's two
#: numeric types, its flag, and a sampler's schedule, which is a list of
#: numbers.  Matched exactly, as the runtime spells them.  A node is
#: computation only when **every** output it declares is one of these -- one
#: ``STRING`` or ``IMAGE`` socket beside them and the text may be what that
#: socket carries on.
COMPUTATION_OUTPUTS = frozenset({"INT", "FLOAT", "BOOLEAN", "SIGMAS"})

#: The fifth: a string on a node whose every declared output is a model, so
#: what the text says is how that model is patched.  See
#: :func:`_structural_model_patch`.
MODEL_PATCH_KIND = "model_patch"

#: The output type name that makes a node's product a patched model.  ComfyUI's
#: own name for the handle, matched exactly, and the only one: it is the only
#: handle type measured to carry nothing but structural text, and a node is a
#: model patch only when **every** output it declares is this one.
MODEL_PATCH_OUTPUTS = frozenset({"MODEL"})

#: The sixth: text the runtime declares ``STRING``, still unsettled after every
#: other authority, saved at exactly the default the runtime declares for it.
#: See :func:`_declared_default`.
DECLARED_DEFAULT_KIND = "declared_default"

#: `semantics.py`'s slug for an input whose name says it chooses the model
#: architecture, family or version the workflow is built for (T-0193), named
#: here beside the others so the package exports every lock kind from one
#: place.  It reaches :data:`LOCKED_KINDS` through
#: :data:`semantics.LOCKED_KINDS_FROM_VALUE`, like every slug ``classify`` returns.
MODEL_ARCHITECTURE_KIND = semantics.LOCKED_MODEL_ARCHITECTURE

#: Every slug a locked or technical control may carry.  Frozen on purpose: a
#: slug that is not in here has no judgement behind it, and inventing one would
#: be adding a classification rather than reporting one.
LOCKED_KINDS = frozenset(
    semantics.LOCKED_KINDS_FROM_VALUE
    | {
        TECHNICAL_MEDIA_KIND,
        LOAD_SETTING_KIND,
        NODE_SHAPE_KIND,
        COMPUTATION_KIND,
        MODEL_PATCH_KIND,
        DECLARED_DEFAULT_KIND,
    }
)

#: Word tokens inside a node's class type that say the node's job is to
#: **load** something.  One word in three spellings, and it is ComfyUI's own
#: vocabulary for the thing rather than anybody's node pack: a class called
#: ``…Loader`` or ``Load…`` announces what it does in the name its author
#: chose.
#:
#: Matched as :func:`class_words` tokens and never as substrings, for the same
#: reason `semantics.py` matches input names on words: ``payload`` and
#: ``preloaded`` contain the letters of ``load`` and mean nothing of the kind.
#:
#: A **tuple** and not the frozenset the vocabularies beside it are, because
#: this one is also read in order: a class type can carry two of these, the
#: sentence :func:`_structural_load` writes names the one it matched, and
#: taking that from a set would name a different word in each process --
#: Python randomises string hashing, so a curator diffing two runs over one
#: file would see the sentence change.  Written down here, the choice is a
#: property of this line instead of of a hash seed.
LOADING_CLASS_WORDS: Tuple[str, ...] = ("load", "loader", "loaders")

#: Every value :attr:`ControlRecord.section` may take.  ``main`` and
#: ``advanced`` are :attr:`PlannedField.section`; ``locked`` and ``technical``
#: are :attr:`NotExposed.exposure`; ``needs_review`` is an input that stopped
#: this workflow from being imported.  One vocabulary, not a second one.
CONTROL_SECTIONS = frozenset({"main", "advanced", "locked", "technical", "needs_review"})

#: The sections of an input a user is never shown.  What a curator reads a
#: report for, and what must never appear among a definition's ``bind``
#: targets.
HIDDEN_SECTIONS = frozenset({"locked", "technical"})

#: Field ordering.  Presentation is T-0055's work; this is only so that two
#: runs over the same bytes produce the same file, and so that the shape of a
#: generated definition is readable while that card is still to come.
_SECTION_ORDER = {"main": 0, "advanced": 1}
_ROLE_ORDER = ("prompt", "negative_prompt")

_ID_CHARS = re.compile(r"[^a-z0-9_-]+")


@dataclass(frozen=True)
class InputCandidate:
    """One node input that could carry a user's value."""

    node: str
    input: str
    value: Any
    class_type: str
    verdict: Verdict
    #: The refined role: what the wiring says this input is for.
    role: str
    #: Structural, renumbering-proof, value-independent.  See the module
    #: docstring.
    fingerprint: str
    #: The nearest consumer input name, for a label a person can read.
    nearest_label: Optional[str] = None
    #: Every consumer input name this node's value reaches, with how many hops
    #: away the nearest one of that name is, ordered by depth and then by
    #: text.  :attr:`nearest_label` is its first entry; the rest is the same
    #: evidence a further hop out, and it is what tells two siblings apart when
    #: one hop says the same thing about both.  Presentation only: no id, no
    #: fingerprint and no grouping key is derived from it, and two candidates
    #: that carry different chains are collapsed exactly as before.
    downstream: Tuple[Tuple[str, int], ...] = ()
    #: What the author called this node in their own editor, verbatim.
    #: Untrusted free text -- it may be absent, empty, enormous, duplicated
    #: between two nodes or in any language -- and never read except through
    #: :func:`_sanitised_title`.  Presentation only, on the same terms as
    #: :attr:`downstream`.
    title: str = ""
    #: The choices the runtime declares for this input, in declared order, when
    #: `contract.py` answered for it.  Presentation only: no id is derived from
    #: it, and two candidates that carry different lists are never collapsed
    #: into one control.
    options: Tuple[Any, ...] = ()
    #: What the runtime declares this number to be, when the input is a number
    #: and the runtime declared one.  ``None`` is "nobody said", and a ``None``
    #: here leaves the field exactly what it would have been.  Like
    #: :attr:`options`, no id is derived from it, and two candidates that will
    #: end up two different kinds of number are never collapsed into one
    #: control.  Two things do **not** separate two candidates: the declared
    #: *ranges*, since a field with several bindings carries the range they all
    #: share, and a ``None`` here, since an input nobody spoke about is the
    #: kind of number its value is written as and nothing has been shown about
    #: it at all.
    numeric: Optional[NumericDeclaration] = None

    @property
    def target(self) -> Tuple[str, str]:
        return (self.node, self.input)


@dataclass(frozen=True)
class PlannedField:
    """One logical field, ready to be written as YAML."""

    id: str
    label: str
    type: str
    section: str
    required: bool
    has_default: bool
    default: Any
    translatable: bool
    role_hint: Optional[str]
    pair: Optional[str]
    duration_fps: Optional[float]
    targets: Tuple[Tuple[str, str], ...]
    #: Why this field exists and why it has this id, in one sentence.
    evidence: str
    #: For a ``select``: the choices the runtime declares, in declared order.
    #: Empty on every other type, and empty is what a ``select`` can never be.
    options: Tuple[Any, ...] = ()
    #: ``min``/``max``/``step`` as the runtime declared them, each one present
    #: only where it is usable on this field as it stands.  ``None`` is "not
    #: declared" and never "no limit": nothing downstream may fill one in.
    minimum: Optional[float] = None
    maximum: Optional[float] = None
    step: Optional[float] = None


@dataclass(frozen=True)
class NotExposed:
    """One input a user will never see, and the reason it is not shown."""

    node: str
    input: str
    exposure: str
    reason: str
    #: Which judgement locked it, as a slug from :data:`LOCKED_KINDS`.
    kind: Optional[str] = None


@dataclass(frozen=True)
class ControlRecord:
    """One literal input the importer considered, and what it decided.

    There is one of these for **every** literal input of the graph, exposed or
    not.  That is what makes an absence readable: see the module docstring.
    """

    node: str
    input: str
    #: One of :data:`CONTROL_SECTIONS`.
    section: str
    #: The sentence the judgement that decided this input already composed.
    #: Not written here and not reworded here -- this is where it is carried.
    reason: str
    #: The logical field id when this input became one, ``None`` otherwise.
    field: Optional[str] = None
    #: That field's label, when there is one.
    label: Optional[str] = None
    #: The slug on a locked or technical entry, ``None`` on any other.
    kind: Optional[str] = None

    @property
    def target(self) -> Tuple[str, str]:
        return (self.node, self.input)

    @property
    def hidden(self) -> bool:
        """Is this an input a user will never be shown?"""

        return self.section in HIDDEN_SECTIONS


@dataclass(frozen=True)
class ImportPlan:
    """Everything one graph turned into -- or every reason it did not."""

    fields: Tuple[PlannedField, ...] = ()
    not_exposed: Tuple[NotExposed, ...] = ()
    #: Every literal input of the graph, with the decision taken about it.
    controls: Tuple[ControlRecord, ...] = ()
    #: Non-empty exactly when the workflow is ``NEEDS_REVIEW``.  Each entry is
    #: a sentence naming the node, the input and the decision that could not
    #: be made.
    problems: Tuple[str, ...] = ()
    #: The one frame rate the graph declares, when it declares exactly one.
    frame_rate: Optional[float] = None
    #: ``(node, input)`` for every input the runtime **did** declare a list of
    #: choices for, which was refused because the choices name files.
    #:
    #: Counted separately from everything else because it is the one outcome a
    #: report cannot otherwise tell apart: "this ComfyUI declared nothing" and
    #: "this ComfyUI declared plenty and we refused all of it" both show up as
    #: no fields and a needs-review workflow, and they need opposite actions.
    refused_as_file_names: Tuple[Tuple[str, str], ...] = ()

    @property
    def needs_review(self) -> bool:
        return bool(self.problems)

    @property
    def review_reason(self) -> Optional[str]:
        if not self.problems:
            return None
        return (
            "this workflow was not imported, because part of it could not be "
            "read with confidence: " + " ".join(self.problems)
        )


# --------------------------------------------------------------------------
# The graph
# --------------------------------------------------------------------------


def _class_type(graph: Mapping[str, Any], node: str) -> str:
    entry = graph.get(node)
    if not isinstance(entry, dict):
        return ""
    value = entry.get("class_type")
    return value if isinstance(value, str) else ""


#: Splits an identifier into the words it is made of, so that a whole
#: class-type identifier is never what a decision is taken on:
#: ``ExampleVideoCombine`` is ``example``, ``video``, ``combine``, and only a
#: frozen vocabulary is ever looked up among them.  A vendor's or a node
#: pack's name is a word nothing here has heard of, so it matches nothing and
#: changes nothing.
#:
#: A run of **digits is a word of its own** (T-0105), so ``ExampleLoader2`` is
#: ``example``, ``loader``, ``2`` and a version number written against a word
#: does not hide the word.
_WORD = re.compile(r"[A-Z]+(?![a-z])|[A-Z]?[a-z]+|[0-9]+")


def class_words(class_type: str) -> frozenset:
    """The word tokens inside a class type, lowercased.

    ``VHS_VideoCombine`` is ``{vhs, video, combine}``.  Words, never the whole
    identifier: an importer that branched on ``VHS_VideoCombine`` would stop
    working the day that node pack renamed anything, and would have a node
    pack's name baked into LocalCanvas for ever.

    It lives here rather than in `catalog.py`, which is where it was written,
    because both modules ask the same question of the same string and two
    splitters would eventually answer it differently.  This is the module
    lower in the import order, so this is the one that can hold it; `catalog.py`
    imports it from here and its own callers are unchanged.

    **Letters and digits are separate words.**  ``ExampleLoader2`` is
    ``{example, loader, 2}``: a version number written against a word is not
    part of the word, and before this a node called ``…Loader2`` was not a
    loader.  ``ExampleLoader3D`` is ``{example, loader, 3, d}`` rather than
    ``{example, loader, 3d}``, because keeping ``3D`` whole would need a rule
    that joins a digit to the capital after it, and that rule would split
    ``Loader3D`` and ``loader3d`` differently -- the lowercase spelling has no
    capital to join.  One boundary between letters and digits answers both the
    same, and no vocabulary looked up among these words carries a digit, so
    nothing is lost by it.

    Two limits are **known and accepted**, because recovering either needs a
    dictionary of words and not a splitter:

    * an all-capitals run keeps no boundary inside it, so ``EXAMPLELOADER`` is
      ``{exampleloader}`` and is not a loader.  Case is the only evidence of a
      boundary this has, and that spelling carries none;
    * a capital starts a word wherever it stands, so a brand spelled
      ``LoadStar`` is ``{load, star}`` and reads as a loader.  Its cost is one
      visible, reasoned locked control, never a refused import.
    """

    if not isinstance(class_type, str):
        return frozenset()
    return frozenset(match.group(0).lower() for match in _WORD.finditer(class_type))


def _inputs(graph: Mapping[str, Any], node: str) -> Mapping[str, Any]:
    entry = graph.get(node)
    if not isinstance(entry, dict):
        return {}
    inputs = entry.get("inputs")
    return inputs if isinstance(inputs, dict) else {}


def _wire(value: Any) -> Optional[Tuple[str, int]]:
    """``["12", 0]`` -- the source node and output slot -- or ``None``."""

    if not isinstance(value, list) or len(value) != 2:
        return None
    source, slot = value
    if not isinstance(source, (str, int)) or isinstance(source, bool):
        return None
    if not isinstance(slot, int) or isinstance(slot, bool):
        return None
    return str(source), slot


def _natural(node: str) -> Tuple[int, int, str]:
    """Sort key for a node id: numerically when it is a number.

    Used only where an order has to exist -- the order ``bind`` targets are
    written in.  No id is ever derived from it.
    """

    return (0, int(node), "") if node.isdigit() else (1, 0, node)


def _consumers(graph: Mapping[str, Any]) -> Dict[str, List[Tuple[str, str]]]:
    """``source node -> [(consumer node, input name)]`` for its first output.

    Only the first output slot: a loader that hands a picture out of one
    socket and a matte out of another must not have the matte's consumers
    counted against the picture.  The first output is the one a graph's main
    flow runs through, at every hop.
    """

    edges: Dict[str, List[Tuple[str, str]]] = {}
    for node in sorted(graph, key=_natural):
        for name in sorted(_inputs(graph, node)):
            wire = _wire(_inputs(graph, node)[name])
            if wire is None:
                continue
            source, slot = wire
            if slot != 0 or source not in graph:
                continue
            edges.setdefault(source, []).append((node, name))
    return edges


def _upstream(graph: Mapping[str, Any], node: str) -> List[Tuple[str, str]]:
    """``[(input name, source node)]`` for every wired input of ``node``."""

    found: List[Tuple[str, str]] = []
    for name in sorted(_inputs(graph, node)):
        wire = _wire(_inputs(graph, node)[name])
        if wire is not None and wire[0] in graph:
            found.append((name, wire[0]))
    return found


def _downstream_labels(
    graph: Mapping[str, Any], consumers: Mapping[str, List[Tuple[str, str]]], node: str
) -> Dict[str, int]:
    """``consumer input name -> how many hops away`` for everything ``node`` feeds."""

    labels: Dict[str, int] = {}
    seen = {node}
    frontier = [node]
    depth = 0
    while frontier:
        depth += 1
        nxt: List[str] = []
        for current in frontier:
            for consumer, name in consumers.get(current, ()):
                if name not in labels:
                    labels[name] = depth
                if consumer not in seen:
                    seen.add(consumer)
                    nxt.append(consumer)
        frontier = nxt
    return labels


def _fingerprint(
    graph: Mapping[str, Any],
    consumers: Mapping[str, List[Tuple[str, str]]],
    node: str,
    input_name: str,
) -> str:
    """A digest of the part this input's node plays, and of nothing else.

    Built from input names and class types only.  No node id goes into it, so
    a graph renumbered from end to end fingerprints identically; no value goes
    into it, so editing a prompt or a seed leaves every id where it was.

    This is the fingerprint at :data:`FINGERPRINT_DEPTH`, and every id minted
    before adaptive depth existed is one of these, byte for byte.  A deeper
    one, for groups this cannot tell apart, is :meth:`_DeepShapes.key`.
    """

    text = "|".join(
        (
            "input=" + input_name,
            "node=" + _class_type(graph, node),
            "up=" + _up_shape(graph, node, FINGERPRINT_DEPTH),
            "down=" + _down_shape(graph, consumers, node, FINGERPRINT_DEPTH),
        )
    )
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:8]


def _group_fingerprint(members: Sequence[InputCandidate]) -> str:
    """The one fingerprint a whole logical field is known by.

    A field may drive several node inputs, each with a fingerprint of its own,
    and the field's is minted from **all** of them: the distinct member
    fingerprints, sorted, digested together.  Sorting is what makes it a
    property of the *set* -- no permutation of the members can change the
    answer, so the order they happen to be held in, which is node order and
    therefore a function of the graph's numbering, is not an input to an id.

    Where the members agree on one fingerprint the answer **is** that
    fingerprint, byte for byte and not a digest of it.  Every field bound to a
    single input is that case, so this rule mints exactly the id the previous
    one minted for all of them; only a field whose members are wired into
    genuinely different places -- the one case the previous rule got wrong --
    gets an id it did not have before (T-0113).

    The distinct set, not the list: two members wired into the same shape say
    the same thing twice, and a field does not change identity because one of
    two identical bindings was added or removed.  Two *groups* whose members
    occupy the same set of positions are looked at further out
    (:func:`_separate`, which calls this again on the deeper fingerprints), and
    only where they never differ are they refused as "wired identically, so
    nothing tells one from the other".

    **What this costs, for whoever changes it next.**  Because the answer is
    nobody's single fingerprint, a group that later *splits* -- a runtime
    arrives and declares one of its inputs a different kind of number, which is
    the T-0097 case -- loses this id altogether instead of handing it to one of
    the halves.  The obvious alternative, ``min(marks)``, would keep it and
    hand it to whichever half carries the smaller fingerprint.  That was
    rejected deliberately: it is the same coin flip the old rule made with node
    order, so a user's saved value would land on a guidance scale or on a step
    count depending on a hash comparison, and this module refuses that kind of
    guess everywhere else.  See the module docstring, under the grouping key,
    and ``tests/test_sync_collapse_evidence.py::
    test_the_id_that_moves_is_the_one_that_stood_for_two_controls``, which
    states the movement in full.
    """

    marks = sorted({member.fingerprint for member in members})
    if len(marks) == 1:
        return marks[0]
    return hashlib.sha256("+".join(marks).encode("utf-8")).hexdigest()[:8]


def _up_shape(graph: Mapping[str, Any], node: str, depth: int) -> str:
    if depth <= 0:
        return ""
    parts = [
        "{}>{}({})".format(
            name, _class_type(graph, source), _up_shape(graph, source, depth - 1)
        )
        for name, source in _upstream(graph, node)
    ]
    return ",".join(sorted(parts))


def _down_shape(
    graph: Mapping[str, Any],
    consumers: Mapping[str, List[Tuple[str, str]]],
    node: str,
    depth: int,
) -> str:
    if depth <= 0:
        return ""
    parts = [
        "{}<{}({})".format(
            name,
            _class_type(graph, consumer),
            _down_shape(graph, consumers, consumer, depth - 1),
        )
        for consumer, name in consumers.get(node, ())
    ]
    return ",".join(sorted(parts))


class _DeepShapes:
    """The up and down shapes of every node, one hop deeper at a time.

    What :func:`_up_shape` and :func:`_down_shape` write out as nested text,
    this holds as a **digest per node per depth**: the shape of a node at depth
    ``d`` is the sorted list of ``input>class(shape at d - 1)`` entries, as
    there, with each nested shape replaced by its digest.  Two shapes are equal
    exactly when the nested texts would be, and a node with nothing further to
    reach reads the same as a shape cut off at the boundary, as it does there.

    Digests rather than text because this is the walk that can go far.  Nested
    text repeats a subgraph once for every path that reaches it, and a chain of
    nodes that each take two inputs from the one before doubles that at every
    hop; a digest per node per depth costs one entry however many paths there
    are, and each depth is computed once, from the one before, for the whole
    graph.  Built only when two groups actually collide, so an ordinary import
    never pays for it.

    Class types and input names are all that goes in -- the same material as
    the base fingerprint, and never a node id, a title or a value.
    """

    def __init__(
        self, graph: Mapping[str, Any], consumers: Mapping[str, List[Tuple[str, str]]]
    ) -> None:
        self._graph = graph
        self._consumers = consumers
        self._upstream = {node: _upstream(graph, node) for node in graph}
        self._up: List[Dict[str, str]] = [{node: "" for node in graph}]
        self._down: List[Dict[str, str]] = [{node: "" for node in graph}]

    def key(self, candidate: "InputCandidate", depth: int) -> str:
        """One input's structural identity at ``depth``, in full."""

        while len(self._up) <= depth:
            self._deepen()
        text = "|".join(
            (
                "input=" + candidate.input,
                "node=" + candidate.class_type,
                "up=" + self._up[depth].get(candidate.node, ""),
                "down=" + self._down[depth].get(candidate.node, ""),
            )
        )
        return hashlib.sha256(text.encode("utf-8")).hexdigest()

    def _deepen(self) -> None:
        graph = self._graph
        up, down = self._up[-1], self._down[-1]
        self._up.append(
            {
                node: _digest_parts(
                    "{}>{}({})".format(name, _class_type(graph, source), up[source])
                    for name, source in self._upstream[node]
                )
                for node in graph
            }
        )
        self._down.append(
            {
                node: _digest_parts(
                    "{}<{}({})".format(name, _class_type(graph, consumer), down[consumer])
                    for consumer, name in self._consumers.get(node, ())
                )
                for node in graph
            }
        )


def _digest_parts(parts: Any) -> str:
    """The digest of a shape's sorted entries, and ``""`` for a shape with none."""

    ordered = sorted(parts)
    if not ordered:
        return ""
    return hashlib.sha256(",".join(ordered).encode("utf-8")).hexdigest()


def _separate(
    graph: Mapping[str, Any],
    consumers: Mapping[str, List[Tuple[str, str]]],
    members_list: Sequence[Sequence["InputCandidate"]],
) -> Optional[Tuple[List[List["InputCandidate"]], List[str]]]:
    """A distinct fingerprint for every group of one role, or ``None``.

    Every group first takes :func:`_group_fingerprint` of its members as they
    are, at :data:`FINGERPRINT_DEPTH`.  Groups whose fingerprints are all
    different are returned untouched -- the members and the marks both -- and
    that is the whole promise to an existing catalogue: **a group that did not
    collide keeps exactly its base-depth id.**

    Groups that share a fingerprint are a *collision*, and each collision is
    settled on its own, from its own members only: they are looked at one hop
    further up and down, then another, until every group in it has a
    different mark.  Each such group's members are handed back carrying the
    deeper fingerprint, so the id minted, the label ladder's last resort and
    the evidence all speak of the depth that told the group apart.  One depth
    for the whole collision, the shallowest that separates all of it; a second
    collision elsewhere in the same role never changes the depth of the first.

    The walk ends without an answer -- and the caller refuses as it always has
    -- when the graph is exhausted in either sense: every member's shape at one
    depth is its shape at the one before, so nothing further will ever differ,
    or the depth reaches the number of nodes in the graph, which no path
    without a cycle can exceed.
    """

    marks = [_group_fingerprint(members) for members in members_list]
    result = [list(members) for members in members_list]
    collisions: Dict[str, List[int]] = {}
    for index, mark in enumerate(marks):
        collisions.setdefault(mark, []).append(index)
    shapes: Optional[_DeepShapes] = None
    for mark in sorted(collisions):
        indices = collisions[mark]
        if len(indices) < 2:
            continue
        if shapes is None:
            shapes = _DeepShapes(graph, consumers)
        separated = _deepen_collision(
            shapes, [members_list[index] for index in indices], len(graph)
        )
        if separated is None:
            return None
        for index, (members, deeper) in zip(indices, separated):
            result[index] = members
            marks[index] = deeper
    return result, marks


def _deepen_collision(
    shapes: _DeepShapes,
    groups: Sequence[Sequence["InputCandidate"]],
    bound: int,
) -> Optional[List[Tuple[List["InputCandidate"], str]]]:
    previous: Optional[List[List[str]]] = None
    for depth in range(FINGERPRINT_DEPTH + 1, bound + 1):
        keys = [[shapes.key(member, depth) for member in members] for members in groups]
        deeper = [
            [replace(member, fingerprint=key[:8]) for member, key in zip(members, found)]
            for members, found in zip(groups, keys)
        ]
        marks = [_group_fingerprint(members) for members in deeper]
        if len(set(marks)) == len(marks):
            return list(zip(deeper, marks))
        if keys == previous:
            return None
        previous = keys
    return None


# --------------------------------------------------------------------------
# One graph, from end to end
# --------------------------------------------------------------------------


def analyse(
    graph: Mapping[str, Any], *, contract: Optional[RuntimeContract] = None
) -> ImportPlan:
    """Every logical field in ``graph``, or every reason there is none.

    ``contract`` is what the ComfyUI that will run this graph declares its
    inputs accept (`contract.py`).  ``None`` -- no ComfyUI, an older one, a
    run that never talked to one -- is not a degraded mode with a fallback in
    it: it is the behaviour this function had before the contract existed, and
    every input that was ``UNCERTAIN`` without one is ``UNCERTAIN`` still.
    """

    if not isinstance(graph, Mapping):
        return ImportPlan(problems=("the workflow is not an object of nodes.",))

    consumers = _consumers(graph)
    frame_rate = _declared_frame_rate(graph)

    candidates: List[InputCandidate] = []
    not_exposed: List[NotExposed] = []
    problems: List[str] = []
    # One entry per literal input, added by whichever branch decided it.  The
    # branches below are mutually exclusive and every one of them records, so
    # the inventory is complete by construction rather than by a later sweep
    # that could disagree with what actually happened.
    controls: List[ControlRecord] = []
    # Inputs the runtime declared a list for, refused because it names files.
    # Kept apart from ``problems`` because it answers a different question:
    # not "why is this workflow held back" but "was there evidence at all".
    refused_as_file_names: List[Tuple[str, str]] = []

    for node in sorted(graph, key=_natural):
        for name in sorted(_inputs(graph, node)):
            value = _inputs(graph, node)[name]
            if not semantics.is_literal(value):
                continue
            class_type = _class_type(graph, node)
            # A sub-input a node shape added is asked about through the
            # declaration nested under the key the graph chose for each parent
            # on its path (T-0240), and every question below then goes to that
            # one declaration exactly as it would go to a top-level one.  A
            # path that does not resolve hands back ``contract`` itself, so
            # everything below is asked exactly what it was asked before.
            asked = _chosen_shape_contract(
                contract, class_type, name, _inputs(graph, node)
            )
            # The node-shape declaration is asked FIRST (T-0195).  Whether a
            # different value would change which inputs this node has is a
            # fact about the declaration, which nothing `semantics.classify`
            # reads can see -- so a ``mode`` holding ``orbit`` is EXPOSE there,
            # and asking only after it handed such an input to the user as a
            # text box.
            #
            # Where the runtime declares the input a node shape, its answer
            # is the verdict, whatever `classify` would have said: LOCKED
            # where the graph's value is one of the declared shapes, and
            # UNCERTAIN -- held for review -- where it is none of them
            # (T-0223).  A text box on such an input is the defect T-0195
            # fixed, and a value no shape declares cannot run on this ComfyUI
            # as saved.  No declaration and no contract answer nothing, and
            # the input goes through `classify` exactly as it always did.  An
            # ordinary choice list is not in this table (the contract's
            # tables are disjoint), so a checkpoint dropdown still meets
            # `classify` before any list.
            shaped = _structural_choice(asked, class_type, name, value)
            if shaped is not None:
                verdict = shaped
            else:
                verdict = semantics.classify(name, value)
            options: Tuple[Any, ...] = ()
            if verdict.exposure is Exposure.UNCERTAIN:
                # The one place the contract's choice lists are consulted, and
                # it is reached only by an input `semantics.classify` could
                # not settle: a LOCKED or an EXPOSE verdict does not enter
                # this branch, so neither is ever offered a runtime's list.
                #
                # A node-shape declaration that reaches here is one whose
                # value is none of its keys, and nothing else is asked about
                # it: it is held for review with the sentence
                # :func:`_structural_choice` wrote.
                if shaped is None:
                    upgraded, options, reason, file_shaped, listed = (
                        _ask_the_runtime(asked, class_type, name, value, verdict)
                    )
                    if file_shaped:
                        refused_as_file_names.append((node, name))
                    if upgraded is None:
                        verdict = Verdict(Exposure.UNCERTAIN, reason)
                        # Asked only where the runtime declared no choice list
                        # at all: a list that refused this value, or named
                        # files, is the runtime saying this input is a choice,
                        # and its own sentence stands.  See
                        # :func:`_structural_computation` -- it may only lock.
                        if not listed:
                            computed = _structural_computation(
                                asked, class_type, name, value
                            )
                            if computed is None:
                                # T-0241, the same slot and the same door:
                                # see :func:`_structural_model_patch`.
                                computed = _structural_model_patch(
                                    asked, class_type, name, value
                                )
                            if computed is not None:
                                verdict = computed
                            else:
                                # T-0219, and it needs no runtime: evidence
                                # from the wiring, asked last.  See
                                # :func:`_wired_prompt`.
                                wired = _wired_prompt(
                                    graph, consumers, node, name, value
                                )
                                if wired is not None:
                                    verdict = wired
                                else:
                                    # T-0244, after every other
                                    # authority: see
                                    # :func:`_declared_default`.
                                    kept = _declared_default(
                                        asked, class_type, name, value
                                    )
                                    if kept is not None:
                                        verdict = kept
                                    else:
                                        # T-0242: still held, and only the
                                        # sentence says why.  See
                                        # :func:`_declared_number_not_saved`.
                                        broken = _declared_number_not_saved(
                                            asked, class_type, name, value
                                        )
                                        if broken is not None:
                                            verdict = broken
                    else:
                        # The runtime would make this a select.  One question
                        # stands between a declaration and a control, and it
                        # is the one only this module can ask, because only
                        # this module holds the node: see
                        # :func:`_structural_load`.  It gates the *upgrade*
                        # and nothing else -- an input that was going to be
                        # held for review is still held for review, on a
                        # loading node as anywhere else, because "look at
                        # this" is the more useful of the two silences and
                        # T-0072 chose it deliberately.
                        #
                        # The choices read a moment ago are deliberately not
                        # cleared when this locks: the branch below returns
                        # before any candidate is built, so nothing carries
                        # them anywhere, and a line no test could fail on is a
                        # line that can be deleted with the suite still green.
                        structural = _structural_load(class_type, name)
                        verdict = upgraded if structural is None else structural
                # Still unsettled after all three authorities have spoken --
                # from no contract, from a list of file names, from a value
                # the runtime does not offer, or from a node shape it does not
                # declare.  One exit for all of them, so the sentence a
                # curator reads is the sentence the judgement wrote.
                if verdict.exposure is Exposure.UNCERTAIN:
                    problems.append("Node {} {}".format(node, verdict.reason))
                    controls.append(
                        ControlRecord(
                            node=node,
                            input=name,
                            section="needs_review",
                            reason=verdict.reason,
                        )
                    )
                    continue
            if verdict.exposure is Exposure.LOCKED:
                not_exposed.append(
                    NotExposed(node, name, "locked", verdict.reason, verdict.kind)
                )
                controls.append(
                    ControlRecord(
                        node=node,
                        input=name,
                        section="locked",
                        reason=verdict.reason,
                        kind=verdict.kind,
                    )
                )
                continue

            labels = _downstream_labels(graph, consumers, node)
            nearest = _nearest_label(labels)
            if verdict.media is not None and _is_technical_media(verdict, labels):
                reason = (
                    "input {!r} on node {} is a matte the graph uses internally, "
                    "not a picture a user chooses.".format(name, node)
                )
                not_exposed.append(
                    NotExposed(node, name, "technical", reason, TECHNICAL_MEDIA_KIND)
                )
                controls.append(
                    ControlRecord(
                        node=node,
                        input=name,
                        section="technical",
                        reason=reason,
                        kind=TECHNICAL_MEDIA_KIND,
                    )
                )
                continue

            role, role_problem = _role_for(node, name, verdict, labels, nearest)
            if role_problem is not None:
                problems.append(role_problem)
                controls.append(
                    ControlRecord(
                        node=node,
                        input=name,
                        section="needs_review",
                        reason=role_problem,
                    )
                )
                continue
            candidates.append(
                InputCandidate(
                    node=node,
                    input=name,
                    value=value,
                    class_type=_class_type(graph, node),
                    verdict=verdict,
                    role=role,
                    fingerprint=_fingerprint(graph, consumers, node, name),
                    nearest_label=nearest,
                    downstream=_downstream_chain(labels),
                    title=_node_title(graph, node),
                    options=options,
                    numeric=_declared_numeric(
                        asked, _class_type(graph, node), name, verdict
                    ),
                )
            )

    fields, field_problems, rejected = _fields_from(
        candidates, frame_rate, graph, consumers
    )
    problems.extend(field_problems)
    controls.extend(_field_controls(fields, candidates))
    for candidate, problem in rejected:
        controls.append(
            ControlRecord(
                node=candidate.node,
                input=candidate.input,
                section="needs_review",
                reason=problem,
            )
        )

    return ImportPlan(
        fields=tuple(fields) if not problems else (),
        not_exposed=tuple(sorted(not_exposed, key=lambda item: (item.node, item.input))),
        controls=tuple(
            sorted(controls, key=lambda item: (_natural(item.node), item.input))
        ),
        problems=tuple(sorted(problems)),
        frame_rate=frame_rate,
        refused_as_file_names=tuple(
            sorted(refused_as_file_names, key=lambda item: (_natural(item[0]), item[1]))
        ),
    )


def _field_controls(
    fields: Sequence[PlannedField], candidates: Sequence[InputCandidate]
) -> List[ControlRecord]:
    """One entry per input a planned field binds, in that field's section.

    The reason is still the verdict's own sentence -- what was decided about
    *this input* -- and never the field's evidence, which is a sentence about
    a group.  The field id and the label say which control it became.
    """

    by_target = {candidate.target: candidate for candidate in candidates}
    records: List[ControlRecord] = []
    for item in fields:
        for target in item.targets:
            candidate = by_target[target]
            records.append(
                ControlRecord(
                    node=target[0],
                    input=target[1],
                    section=item.section,
                    reason=candidate.verdict.reason,
                    field=item.id,
                    label=item.label,
                )
            )
    return records


# --------------------------------------------------------------------------
# What a node's own job says about an input nothing else settles
# --------------------------------------------------------------------------


def _structural_load(class_type: str, name: str) -> Optional[Verdict]:
    """Locked, when the input the runtime just settled sits on a loading node.

    ``/object_info`` proves **what values exist**.  It does not prove that
    changing one is safe, and on a loading node it usually is not: an input
    such a node offers that nothing in `semantics.py` recognises is which
    architecture the weights are read as, which precision they are read at,
    which of several forms the file is in -- *what is being loaded and how it
    is interpreted*, never how the picture is generated.  Every value of it is
    legal and exactly one of them works, so a dropdown over all of them is
    "which model this workflow is" turned into a control.  That is the outcome
    the LOCKED-before-contract ordering exists to prevent, arrived at through a
    plain enum instead of through a list of file names.

    Four things this deliberately is **not**:

    * **not a judgement about the input's name.**  The name is not consulted
      here at all beyond going into the sentence: `semantics.py` has already
      had its say about the name and the value and answered ``UNCERTAIN``, and
      "it is called ``type``" is not evidence -- that is the lesson of T-0072,
      T-0080 and T-0095, three cards in a row.
    * **not a judgement about the option values.**  They are not read, and
      they may not be: naming a model family in application logic is forbidden,
      and the list is the user's curated data.
    * **not "everything on a loading node is locked".**  Only an input the
      graph could not settle reaches here.  A number, a flag, a prompt and a
      picture on the very same node are all settled by `semantics.py` and never
      see this function, so a loading node's genuine tunables are untouched.
    * **not a way of holding a workflow back.**  The caller asks this only
      once the runtime has answered with a usable list, so what is refused is
      an *editable control*.  An input nobody could settle at all is
      ``NEEDS_REVIEW`` here exactly as it is on any other node.

    The evidence is :data:`LOADING_CLASS_WORDS` among the class type's word
    tokens: a node's author writing ``Loader`` or ``Load`` into the name they
    chose.  Word tokens and not the identifier, for `catalog.py`'s reason --
    keying on one installation's spelling of a loader would bake that
    installation's node names into LocalCanvas and would answer nothing about
    the next pack.  The sentence names the **first** spelling that matched, in
    that tuple's own order, so two runs over one file say the same thing.
    """

    words = class_words(class_type)
    word = next((entry for entry in LOADING_CLASS_WORDS if entry in words), None)
    if word is None:
        return None
    return Verdict(
        Exposure.LOCKED,
        "input {!r} is one nothing in the graph settles, on a node whose class "
        "type carries the word {!r}: what a loading node's unrecognised inputs "
        "describe is what is being loaded and how it is interpreted, not how "
        "the picture is generated. Knowing every value it accepts is not "
        "permission to change it.".format(name, word),
        kind=LOAD_SETTING_KIND,
    )


def _structural_choice(
    contract: Optional[RuntimeContract],
    class_type: str,
    name: str,
    value: Any,
) -> Optional[Verdict]:
    """Locked, when the input does not hold a value but a **node shape**.

    One type of declaration on a current ComfyUI does not offer values at all.
    Each of its options is an object carrying its own ``required``/``optional``
    inputs, so choosing one *adds inputs to the node* and choosing another
    takes them away -- and on this runtime nearly every one of them really does
    carry some.  What the graph holds at such an input is therefore not a
    setting its author tuned; it is **which node this is**.

    So the answer is not a smaller control, it is no control:

    * the value the graph carries is one of the declared keys -> ``LOCKED`` at
      exactly that value, with the :data:`NODE_SHAPE_KIND` slug.  The workflow
      imports and runs exactly as its author wrote it, and nobody is offered a
      field whose meaning is "change which inputs this node has";
    * it is none of them -> ``UNCERTAIN``, naming the input and the shapes the
      runtime declares, and **not** the value: it is held for review.  The
      caller asks this **before** `semantics.classify` and takes this answer
      whatever ``classify`` would have said -- an input it would expose, lock
      or leave unsettled is held alike (T-0223).  Exposed, it would be a text
      box on an input where only the declared keys are legal and a different
      one changes the node's shape, which is the defect T-0195 fixed; and a
      value no shape declares cannot run on this ComfyUI as saved.  An
      unrecognised word is an honest unknown and stays one; nothing is
      substituted, least of all a key that happens to exist.  "None of them"
      is exact: as written, with no case folding and no trimming, and of the
      same type -- :func:`_value_key`'s rule, so ``True`` is not the key ``1``
      and ``1.0`` is not the key ``1`` (nor ``1`` the key ``1.0``).

    **The value locked is the one out of the graph**, always.  Not the first
    declared key, not a runtime default -- a workflow saved with the second
    shape must not quietly come back as the first, because the two are
    different nodes.  The sentence below names it for that reason: it is the
    one thing about this decision a curator has to be able to read back.

    Why ``LOCKED`` and not a ``select`` over the keys, which would be easy:

    * T-0100 already says that knowing every legal value is not permission to
      change one.  This is strictly the stronger case -- a different choice
      here does not change what a node is given, it changes what the node
      *is*, and the graph LocalCanvas submitted would not be the graph it
      imported;
    * the keys are not comparable with one another.  One of them may add three
      inputs and the next one none, so a list of them offers entries that
      differ in kind, and the control would be a worse answer than no control;
    * and nothing nested is read to make this decision.  `contract.py` keeps
      each option whole, its block included, in
      :attr:`~localcanvas_gateway.workflows.sync.contract.RuntimeContract.shapes`,
      and reads none of them when the document is read; this decision uses
      the keys alone.  The one block ever read is the one under the key the
      graph holds, and it is read for the sub-inputs that shape added
      (:func:`_chosen_shape_contract`), never to offer the node another shape.

    Four things this deliberately is **not**, in the shape of
    :func:`_structural_load`'s list beside it:

    * **not a judgement about the input's name.**  The name goes into the
      sentence and nowhere else, for T-0072's, T-0080's and T-0095's reason.
    * **not a judgement about the node's class type.**  That is
      :func:`_structural_load`'s evidence and it answers a different question.
      This one is settled by the *declaration*, so it holds on a loader and on
      an ordinary node alike.
    * **not a judgement about what the values mean.**  They are compared, never
      interpreted: no key is read for what it names, no vocabulary is consulted,
      and a model family may not be named in application logic at all.
      Membership, type included, is the whole of it.
    * **not a way of quietly widening what imports.**  An input whose value the
      runtime does not declare stops the workflow.

    The held sentence does not quote the value (T-0223).  What a curator needs
    from it is that the value is none of the declared shapes and which shapes
    those are; the value itself is in the workflow they open to fix it.
    """

    if contract is None:
        return None
    keys = contract.structural_for(class_type, name)
    if not keys:
        return None
    # Type-exact, by :func:`_value_key`: Python's ``in`` compares with ``==``,
    # and ``True == 1`` and ``1.0 == 1``.  Since T-0195 this is asked for every
    # literal, a flag and a number included, so a plain ``in`` would lock a
    # ``True`` against a declared key ``1`` with a sentence saying the runtime
    # declared it.  A boolean never matches a number, and an ``int`` never
    # matches a ``float``: the same rule collapsing already uses.
    if _value_key(value) not in [_value_key(key) for key in keys]:
        return Verdict(
            Exposure.UNCERTAIN,
            "input {!r} is one this ComfyUI declares as a choice between shapes "
            "of node class {!r} rather than as a value: the shapes it offers are "
            "{}. The value saved there is not one of the shapes this ComfyUI "
            "declares, so what this node would be is not something the graph "
            "and this runtime agree on. Nothing was substituted -- look at it "
            "and decide.".format(name, class_type, _listed(keys)),
        )
    return Verdict(
        Exposure.LOCKED,
        "input {!r} holds {!r}, which the ComfyUI that runs this workflow "
        "declares as one of the shapes node class {!r} can take: choosing "
        "another would add or remove inputs on that node rather than change "
        "this one. The workflow's author already chose it, LocalCanvas keeps "
        "it exactly as saved, and offers no control for "
        "it.".format(name, value, class_type),
        kind=NODE_SHAPE_KIND,
    )


def _structural_computation(
    contract: Optional[RuntimeContract],
    class_type: str,
    name: str,
    value: Any,
) -> Optional[Verdict]:
    """Locked, when a string sits on a node whose every output is a number.

    A math expression and a hand-written sigma schedule are both short text
    under an uninformative name, so `semantics.classify` answers ``UNCERTAIN``
    for each and is right to: nothing in the name or the value says what the
    text is for.  What says it is the node.  A class the runtime declares to
    produce **only** numbers -- every output one of
    :data:`COMPUTATION_OUTPUTS` -- turns whatever the text says into numbers
    another node reads.  The string is how that computation is written down,
    not a setting a person tunes from a phone: changing ``a * b + 1`` rewires
    arithmetic between nodes, and changing a schedule is changing the sampler.

    The caller asks this only for an input nothing earlier settled, and only
    where the runtime declared no choice list for it.  The answer:

    * ``LOCKED`` with :data:`COMPUTATION_KIND`, at exactly the value the graph
      carries -- nothing is parsed, normalised or checked for being valid
      arithmetic, because what is decided here is whether a person is offered
      the text, not whether the text is right;
    * ``None`` -- nothing is said, and the input stays exactly as uncertain as
      it was -- for everything else: no contract, a class the runtime does not
      declare outputs for, a class declaring no outputs at all, one output that
      is not a number, and a value that is not a string.

    Four things this deliberately is **not**, in the shape of
    :func:`_structural_load`'s and :func:`_structural_choice`'s lists:

    * **not a judgement about any name.**  Neither the class type nor the input
      name is read to decide; both only go into the sentence.  A rule keyed on
      ``expression`` or ``sigmas`` is the rule T-0072, T-0080 and T-0095 each
      rejected.
    * **not a judgement about ``category``**, which the same ``/object_info``
      entry carries.  It is where a node's author files the node in a menu, and
      a node pack may file anything anywhere.
    * **not "any numeric output"**.  One ``STRING`` or ``IMAGE`` socket beside
      the numbers and the text may be what that socket hands on -- a caption, a
      prompt -- so the node proves nothing, and nothing is said.
    * **not a way of exposing anything, or of holding anything back.**  It turns
      an input that was going to be held for review into a locked one, and
      does nothing else.
    """

    if contract is None or not isinstance(value, str):
        return None
    produced = contract.outputs_for(class_type)
    if not produced:
        return None
    if not all(output in COMPUTATION_OUTPUTS for output in produced):
        return None
    return Verdict(
        Exposure.LOCKED,
        "input {!r} holds text on node class {!r}, and every output the ComfyUI "
        "that runs this workflow declares for that class is a number ({}): "
        "whatever the text says, what it becomes is numbers another node reads. "
        "That is computation, not a setting -- LocalCanvas keeps it exactly as "
        "saved and offers no control for it.".format(
            name, class_type, ", ".join(produced)
        ),
        kind=COMPUTATION_KIND,
    )


def _structural_model_patch(
    contract: Optional[RuntimeContract],
    class_type: str,
    name: str,
    value: Any,
) -> Optional[Verdict]:
    """Locked, when a string sits on a node whose every output is a model.

    A list of layer indices, of blocks to skip, of latent frames to keep: short
    text under a name `semantics.classify` does not know, so it answers
    ``UNCERTAIN``.  What says what the text is for is, again, the node.  A class
    the runtime declares to produce **only** a model -- every output one of
    :data:`MODEL_PATCH_OUTPUTS` -- takes a model in and hands a patched one on;
    the text never reaches a prompt or an output as text, it changes how the
    model is patched.  Changing it from a phone is changing the model the
    workflow samples with, so it is ``LOCKED`` with :data:`MODEL_PATCH_KIND`, at
    exactly the value the graph carries.

    It is :func:`_structural_computation`'s door, asked in the same place, right
    after it, and on the same terms:

    * asked only for an input still ``UNCERTAIN`` after every earlier authority,
      on an input the runtime declares no choice list for;
    * it can only lock -- never expose, never unlock -- and with no contract, a
      class the contract does not declare outputs for, a class declaring none,
      or a value that is not a string, it says nothing;
    * **every**, not any: one output of another type beside the model -- a
      conditioning, a string, a picture -- and the text may be what that socket
      hands on, so nothing is said;
    * the model type alone.  Other handle types were not measured to carry only
      structural text, so they are not in :data:`MODEL_PATCH_OUTPUTS`;
    * **no name is read** to decide -- not the class type, not the input's name,
      not ``category`` -- for the reasons in :func:`_structural_computation`.
    """

    if contract is None or not isinstance(value, str):
        return None
    produced = contract.outputs_for(class_type)
    if not produced:
        return None
    if not all(output in MODEL_PATCH_OUTPUTS for output in produced):
        return None
    return Verdict(
        Exposure.LOCKED,
        "input {!r} holds text on node class {!r}, and every output the ComfyUI "
        "that runs this workflow declares for that class is a model ({}): "
        "whatever the text says, what it changes is how that model is patched "
        "before another node uses it. That is part of the model, not a setting "
        "-- LocalCanvas keeps it exactly as saved and offers no control for "
        "it.".format(name, class_type, ", ".join(produced)),
        kind=MODEL_PATCH_KIND,
    )


def _declared_default(
    contract: Optional[RuntimeContract],
    class_type: str,
    name: str,
    value: Any,
) -> Optional[Verdict]:
    """Locked, when unsettled text is exactly the default the runtime declares.

    Some text nothing can settle stays unsettled for good: a colour word, a
    short subject, a hosted identifier, on a node whose outputs prove nothing.
    Holding such a workflow is a correct refusal under the evidence rules, and
    with no override it is also a refusal nobody can ever lift.  One generic
    fact is available in exactly that situation: the saved value **equals** the
    default the ComfyUI that runs the workflow declares for the input.  That
    does not prove what the input is.  It proves the author never changed it,
    so locking it runs the workflow exactly as it was saved, and no control
    whose meaning is unknown is ever put in front of anyone (T-0244).

    Asked last, for an input still ``UNCERTAIN`` after every other authority --
    the node-shape step, ``classify``, a declared choice list, the computation
    and model-patch locks, and the wired prompt -- and it locks only where all
    of these hold:

    * the value is a literal string;
    * the runtime declares the input ``STRING``, type-exact
      (:meth:`RuntimeContract.string_for`) -- at the top level, or under the
      shape the graph chose (:func:`_chosen_shape_contract`);
    * the declaration **carries** a default.  No default is not the empty
      string: an empty text with nothing declared stays held;
    * the value equals that default as the same type and character for
      character, by :func:`_value_key` -- no trimming, no case folding.
      Multiline declarations are not set apart: equal is equal.

    Everything else says nothing and the input stays held: no contract, a class
    or input the runtime does not declare, another declared type, a value one
    character away.  No class, input or category name is read, and the value
    is not quoted in the sentence -- it may be prose.
    """

    if contract is None or not isinstance(value, str):
        return None
    declared = contract.string_for(class_type, name)
    if declared is None or not declared.has_default:
        return None
    if _value_key(value) != _value_key(declared.default):
        return None
    return Verdict(
        Exposure.LOCKED,
        "input {!r} on node class {!r} holds exactly the default the ComfyUI "
        "that runs this workflow declares for it, and nothing in the graph says "
        "whether it is a setting a user may change: the workflow's author never "
        "changed it. LocalCanvas keeps it exactly as saved and offers no control "
        "for it.".format(name, class_type),
        kind=DECLARED_DEFAULT_KIND,
    )


def _declared_number_not_saved(
    contract: Optional[RuntimeContract],
    class_type: str,
    name: str,
    value: Any,
) -> Optional[Verdict]:
    """Still held, with the true reason, when a declared number holds a non-number.

    An input the runtime declares ``INT`` or ``FLOAT`` that holds text reached
    the curator as "nothing in the graph says whether that is a setting ... look
    at it and decide".  Something does say: the ComfyUI that runs the workflow
    declares a number there, and the value saved is not one.  There is nothing
    to decide -- the workflow is broken as saved, and ComfyUI is expected to
    refuse it as well.  That last part is an expectation, not a measurement:
    confirming it would mean submitting a broken job to somebody's ComfyUI,
    and nothing here does that.  So the input stays ``UNCERTAIN`` exactly as before, and **only the sentence
    changes** (T-0242).  Nothing is exposed, locked or substituted, and the
    saved value is not quoted: it may be a paragraph of somebody's prose.

    Asked last, for an input still ``UNCERTAIN`` after every other authority.
    "Not a number" is:

    * a **boolean** -- a flag is not a number, although Python calls ``True`` an
      ``int``;
    * a **string Python's** ``float()`` **refuses**, for ``INT`` and ``FLOAT``
      alike.  ``float()`` is the more accepting of the two conversions -- it
      takes ``"1.5"``, ``" 2 "``, ``"1e3"``, ``"nan"`` -- so text either
      conversion could read as a number keeps the old sentence.  The new one
      claims ComfyUI will not run the workflow, and a claim like that is made
      only where no numeric reading of the text exists at all.

    A number, of either kind, is never this case.  ``None`` -- the input keeps
    its old sentence -- for everything else: no contract, an input the runtime
    does not declare a number, and text that reads as one.
    """

    if contract is None:
        return None
    declared = contract.numeric_for(class_type, name)
    if declared is None:
        return None
    if not isinstance(value, bool):
        if not isinstance(value, str):
            return None
        try:
            float(value)
        except ValueError:
            pass
        else:
            return None
    return Verdict(
        Exposure.UNCERTAIN,
        "input {!r} is one the ComfyUI that runs this workflow declares a number "
        "for on node class {!r} ({}), and the value saved there is not a number, "
        "so ComfyUI will not run this workflow as it was saved. Nothing was "
        "substituted -- the workflow needs fixing in ComfyUI.".format(
            name, class_type, declared.field_type
        ),
    )


def _chosen_shape_contract(
    contract: Optional[RuntimeContract],
    class_type: str,
    name: str,
    inputs: Mapping[str, Any],
) -> Optional[RuntimeContract]:
    """The declaration a sub-input is judged by: the one under the shape in force.

    A node shape adds inputs to its node, and the graph carries them flattened
    as ``parent.child`` -- at any depth, ``a.b.c`` being ``c`` inside the shape
    ``a.b`` holds, inside the shape ``a`` holds.  The runtime declares each of
    them, but only inside the block of the shape that adds it, so the
    top-level tables say nothing about ``a.b`` and such an input used to be
    judged from its name and value alone (T-0240).

    The path is resolved one parent at a time, and each step needs both:

    * the parent is a **node-shape declaration** -- :meth:`structural_for`
      answers for it, at the top level for the first parent and inside the
      block chosen one step earlier for every later one;
    * the value the graph holds at the parent is **exactly one** of that
      declaration's keys, type-exact by :func:`_value_key` -- the rule
      :func:`_structural_choice` locks the parent by.  A value that is none of
      them chose no shape, and one that matches two keys chose no single one.

    Then the block under that key is read, for the next name on the path and
    nothing else (:meth:`RuntimeContract.under_shape`).  A shape the graph did
    not choose is never read, counted or offered: that is still T-0185's
    safety argument, and it is why the key comes out of the graph and never out
    of the declaration.

    The answer is a contract declaring exactly ``name``, which the caller asks
    every question it asks a top-level input -- node-shape step first, then
    the choice list in the ``UNCERTAIN`` branch, then numeric kind and bounds.
    There is no second copy of those rules here.

    Everything else hands ``contract`` back untouched, so the input is judged
    exactly as it was before this existed: a name with no separator, no
    contract, a parent that is not a node shape or holds no declared key, a
    sub-input the chosen block does not declare -- and a name this runtime
    already declares at the top level of the class, which keeps that
    declaration.
    """

    if contract is None:
        return contract
    parts = name.split(SHAPE_PATH_SEPARATOR)
    if len(parts) < 2:
        return contract
    level = contract
    for depth in range(1, len(parts)):
        parent = SHAPE_PATH_SEPARATOR.join(parts[:depth])
        keys = level.structural_for(class_type, parent)
        if not keys:
            return contract
        held = _value_key(inputs.get(parent))
        chosen = [index for index, key in enumerate(keys) if _value_key(key) == held]
        if len(chosen) != 1:
            return contract
        found = level.under_shape(
            class_type,
            parent,
            chosen[0],
            parts[depth],
            SHAPE_PATH_SEPARATOR.join(parts[: depth + 1]),
        )
        if found is None:
            return contract
        level = found
    if contract.declares(class_type, name):
        return contract
    return level


# --------------------------------------------------------------------------
# The runtime contract, asked in exactly one situation
# --------------------------------------------------------------------------

#: `docs/workflow-schema.md`'s type for "one of a declared list".  It is the
#: one field type nothing in `semantics.py` can produce: a graph carries the
#: value a node has and never the list it accepts, so this type exists exactly
#: when a runtime declared that list.
SELECT_FIELD_TYPE = "select"

#: How many choices a sentence names before it stops listing them.  A list a
#: person cannot read is not evidence, and the count that follows is.
_LISTED_OPTIONS = 8


def _ask_the_runtime(
    contract: Optional[RuntimeContract],
    class_type: str,
    name: str,
    value: Any,
    verdict: Verdict,
) -> Tuple[Optional[Verdict], Tuple[Any, ...], str, bool, bool]:
    """What the ComfyUI that will run this graph says about one unsettled input.

    Called for an ``UNCERTAIN`` verdict and for nothing else -- see the module
    docstring for why that ordering is the safety argument rather than a
    convention.  The answer is either an ``EXPOSE`` verdict with the choices
    beside it, or ``None`` and the sentence that says why the input still has
    to be looked at.

    The fourth value is one thing a caller cannot work out from the first
    three: whether the runtime **did** declare a list here and it was refused
    for naming files.  "Nothing was declared" and "a file picker was declared
    and refused" are the same silence otherwise, and they need opposite
    actions from whoever reads the run.

    The fifth is the other: whether the runtime declared a list here **at
    all**, whatever became of it.  Only an input with no list behind it may be
    asked the computation question afterwards (T-0218) -- a declared list is
    the runtime saying this input is a choice -- and asking the contract a
    second time to find out would be a second question a spy has to tell apart
    from the first.

    Every way of not knowing produces the sentence `semantics.py` already
    wrote, unchanged, because it is the same situation: no contract, or a class
    and input this runtime declares no list for.  The two sentences composed
    here are for the two situations that are **new** -- a list of file names,
    and a value the runtime does not offer -- and neither of them existed to be
    described before there was a runtime to ask.

    Two checks that would read as care are deliberately **not** here, because
    a mutation proved each of them dead.  Neither "the value is a string" nor
    "the name yields an id" can fail: `semantics.classify` answers
    ``UNCERTAIN`` for a number only when the input has no usable name, and an
    input with no usable name is refused a few lines further on by
    :func:`_role_for`, which is where that judgement has always lived.  A
    clause no test can fail on is a clause that can be deleted with the suite
    still green, so it is deleted here instead.
    """

    if contract is None:
        return None, (), verdict.reason, False, False
    options = contract.options_for(class_type, name)
    if not options:
        return None, (), verdict.reason, False, False

    if runtime_contract.names_files(options):
        return None, (), (
            "input {!r} is one this ComfyUI offers as a list of file names, so "
            "it picks something on the machine rather than a setting, and "
            "LocalCanvas never puts that in front of a user as a field to "
            "edit. It is neither exposed nor dropped: look at it and "
            "decide.".format(name)
        ), True, True

    if value not in options:
        return None, (), (
            "input {!r} holds {!r}, and the ComfyUI that would run this "
            "workflow does not offer that: for node class {!r} it declares "
            "{}. Nothing was substituted -- this graph was saved against a "
            "different version of that node, and choosing one of the values "
            "above on your behalf would silently change what it "
            "generates.".format(name, value, class_type, _listed(options))
        ), False, True

    return (
        Verdict(
            Exposure.EXPOSE,
            "input {!r} takes one of {} choices the ComfyUI that runs this "
            "workflow declares for node class {!r}, and the value in the graph "
            "is one of them.".format(name, len(options), class_type),
            field_type=SELECT_FIELD_TYPE,
            role=semantics.sanitize_role(name),
        ),
        tuple(options),
        "",
        False,
        True,
    )


#: The two `docs/workflow-schema.md` types a runtime's numeric declaration can
#: speak about.  A verdict carrying one of them is a number the graph settled,
#: which is the only situation in which "which kind of number" is a question.
NUMERIC_FIELD_TYPES = frozenset({"integer", "float"})


def _declared_numeric(
    contract: Optional[RuntimeContract],
    class_type: str,
    name: str,
    verdict: Verdict,
) -> Optional[NumericDeclaration]:
    """What the runtime declares this number to be, or ``None``.

    Asked for a number and for nothing else.  A string, a flag, a picture and
    a ``select`` the contract itself just produced are all left alone: what is
    being decided here is *which* numeric type an already-numeric input takes,
    never whether something is a number at all -- a value is what the graph
    carries, and no declaration turns one kind of value into another.

    ``None`` from here is the whole of decision 3 of this card: no contract, a
    class this ComfyUI does not have, an input it does not declare, or an input
    declared as something other than ``INT``/``FLOAT``, all leave the field
    exactly as it was before there was a runtime to ask.  There is deliberately
    no "when in doubt, float": that would make an integer of nothing, and it
    would break ``steps``, ``width`` and every genuine whole number in the
    catalogue for the sake of the ones this card is about.
    """

    if verdict.field_type not in NUMERIC_FIELD_TYPES:
        return None
    if contract is None:
        return None
    return contract.numeric_for(class_type, name)


def _resolved_declaration(
    members: Sequence[InputCandidate],
) -> Optional[NumericDeclaration]:
    """What this field is declared to be, resolved over **all** of its inputs.

    One logical field can drive several node inputs and a declaration is per
    ``(class, input)``, so a field with two bindings has two declarations to
    answer from.  Every one of them is read here, and nothing is taken from a
    single member: a rule that read "the first" would answer differently
    depending on which node id sorted first, which is not evidence about
    anything, and a rule that read "the first" while *claiming* the members all
    agree would be resting on an invariant nothing enforces.

    **The kind of number** is the one every declaring member carries, and that
    is by construction rather than by a check here.  Two components of the
    grouping key say so together, and both halves are needed: the second is the
    type `semantics.py` read from the value, so it is the same for every member
    of a group; the fifth (:func:`_declaration_key`) is the declared type
    wherever the runtime contradicted that, and ``""`` wherever it did not.  So
    a group whose fifth component names a type has every member declared to be
    that type, and a group whose fifth component is ``""`` has every declaring
    member declaring exactly the second -- one answer either way, and it is
    always the type the field really takes.  Both components are strings, which
    compare by value and by type, so neither can quietly hold two answers the
    way a declared bound can.  The set is read rather than checked: a second
    unanimity test over a property the key already decides is a guard no input
    could ever fail.

    A group :func:`_one_number_however_written` joined out of ``1`` and ``1.0``
    is the one group whose members' second components differ, and it keeps the
    property for its own reason: it was joined only where every member is
    declared the same kind of number, or no member is declared at all.

    A ``""`` group **may** hold a declared member beside a silent one, and that
    is the one place a declaration reaches an input its own runtime said
    nothing about.  It reaches only the bounds -- the type is what the value
    already said -- and a bound narrows what may be set where the alternative
    is no bound at all, on one control writing one value into both nodes.

    **The range is the intersection**: the greatest declared ``min`` and the
    least declared ``max``.  A member that declares neither is unbounded and
    narrows nothing, so it is simply absent from the comparison.  The result is
    the range every member that spoke allows, which is the range this one
    control may offer; it is strictly stronger than keeping a range only where
    all members declared the same one, which took the slider away and left
    every value reachable anyway.  What it does not do is guarantee that
    whatever survives into the field is a limit on both sides -- see the last
    paragraph, and :func:`_numeric_bounds`.

    **The step is the one they all declare**, and nothing where they differ.  A
    step is a widget's increment; reconciling two would invent an increment
    nobody declared, and there is no arithmetic on it that is not an invention.

    Nothing here is a bound the runtime did not declare, and nothing here is
    wider than what it declared.  What comes out is then still put through
    :func:`_numeric_bounds`, which is where a bound this schema cannot carry,
    an incoherent pair and a bound the graph's own value contradicts are each
    left out, exactly as before.

    That last one is why the intersection carries **no promise about what the
    field ends up with**.  Where the value the graph already holds lies outside
    the intersection, the bound it contradicts is dropped and that side is as
    unbounded as it was before any of this existed -- and an intersection, being
    the tightest range in play, is contradicted more readily than any single
    declaration was.  A workflow saved with a value its ComfyUI no longer
    accepts is a real thing, and the two ways to make it fit are to move the
    user's value or to move the bound: both are this importer deciding what the
    workflow generates, so neither happens.  The guarantee here is therefore
    conditional and worth stating exactly: **where the graph's own value lies
    inside the intersection, and each bound is one this field's type can carry,
    the range the user is offered is one every node behind the control
    accepts.**
    """

    declared = [member.numeric for member in members if member.numeric is not None]
    if not declared:
        return None
    return NumericDeclaration(
        # Sorted so the expression is total and its answer never depends on set
        # iteration order.  The key makes this set a single element; the sort
        # is not a tie-break, because there is no tie to break.
        field_type=sorted({item.field_type for item in declared})[0],
        minimum=_tightest([item.minimum for item in declared], max),
        maximum=_tightest([item.maximum for item in declared], min),
        step=_shared_step([item.step for item in declared]),
    )


def _tightest(bounds: Sequence[Optional[float]], narrower: Any) -> Optional[float]:
    """The tightest of the bounds that were declared, or ``None`` if none was.

    ``narrower`` is :func:`max` for a lower bound and :func:`min` for an upper
    one, which is what "the intersection of the declared ranges" means for one
    end of it.

    The tie is the whole difficulty, and it is why this is a function and not a
    call to ``max``.  ``1`` and ``1.0`` are equal numbers with equal hashes in
    Python, so a runtime that declares one input ``min: 1`` and another
    ``min: 1.0`` offers two spellings of one bound -- and the two are **not**
    interchangeable downstream, because :func:`_usable_bound` carries a whole
    bound on a whole field and drops a fractional one.  ``max`` returns the
    first of several equals, so taking its answer would make the field's range
    depend on which node id sorted first: the same graph, the same runtime, a
    bound present or absent according to how the nodes happened to be numbered.

    So among bounds that are the same number, the whole spelling wins.  It is
    the same bound either way -- nothing is widened, narrowed or invented -- and
    it is the one this schema can carry on both kinds of field.

    ``isinstance(..., int)`` is the whole test, and it is safe here for the
    reason ``True`` usually makes it unsafe: `contract.py` refuses a boolean as
    a bound before one can ever reach this, so an ``int`` here is a number.
    """

    given = [bound for bound in bounds if bound is not None]
    if not given:
        return None
    tightest = narrower(given)
    whole = [bound for bound in given if bound == tightest and isinstance(bound, int)]
    return whole[0] if whole else tightest


def _shared_step(steps: Sequence[Optional[float]]) -> Optional[float]:
    """The step every member declares, or ``None`` where they do not all agree.

    Compared with the type beside the value, like :func:`_value_key` and
    :func:`_options_key` do and for the same reason: ``1`` and ``1.0`` are one
    key in a plain ``set`` and are two different things to
    :func:`_usable_bound`, so a set of the bare numbers would call two runtimes
    agreed and then carry whichever spelling it happened to keep -- which is to
    say, whichever node id sorted first.

    So ``1`` and ``1.0`` are two answers here and no step is carried, and that
    is deliberately not what :func:`_tightest` does with the same two spellings
    of a bound.  The two are worth different things.  A bound is a limit, and
    losing it lets a user reach a value a node refuses, so it is worth
    resolving a tie to keep one.  A step is how far an arrow moves the value:
    losing it costs the arrows and nothing else, and choosing between two
    spellings of it would be reconciling two declarations rather than reading
    them.
    """

    tagged = {(type(step).__name__, step) for step in steps}
    if len(tagged) != 1:
        return None
    return tagged.pop()[1]


def _numeric_bounds(
    declared: NumericDeclaration, field_type: str, value: Any
) -> Tuple[Optional[float], Optional[float], Optional[float]]:
    """``min``, ``max`` and ``step`` this field may carry as declared.

    Takes the declaration :func:`_resolved_declaration` computed for the whole
    group rather than the group itself: which range applies to a field with
    several bindings is settled there, by intersecting the declared ones, so
    what is left here is the single question of whether a bound is usable as it
    stands.

    Each bound is carried only if it is:

    * the right kind of number for the field's own type -- `the schema
      <docs/workflow-schema.md>`_ wants whole bounds on a whole field, and its
      loader refuses the definition otherwise, which would cost the workflow
      its import rather than its slider;
    * ``step`` greater than zero, and ``min`` not greater than ``max``, which
      are the schema's own coherence rules -- and, since the range handed in
      may be an intersection, this is also where two members whose declared
      ranges do not overlap at all end with no range rather than an impossible
      one;
    * satisfied by the value the graph already carries.  A workflow saved with
      a value outside the range its ComfyUI now declares is a real thing -- a
      node was updated, or the value was typed past the widget -- and the two
      ways to make it fit are to move the user's value or to move the bound.
      Both are this importer deciding what the workflow generates, so neither
      happens: the bound that the value contradicts is the one left out, and
      the value is written exactly as the graph has it.

    Left out, never softened: there is no widened range, no rounded step and no
    bound borrowed from another field.  The one place a bound does come from
    somewhere other than a single declaration is the intersection above, and
    that is not borrowing: every input of this one control declared it, and the
    tighter of two limits on the same control is a limit both nodes keep.  A
    field with no bounds is a typed entry box, which is what every imported
    number was before this card.
    """

    whole = field_type == "integer"
    minimum = _usable_bound(declared.minimum, whole)
    maximum = _usable_bound(declared.maximum, whole)
    step = _usable_bound(declared.step, whole)

    if step is not None and step <= 0:
        step = None
    if minimum is not None and maximum is not None and minimum > maximum:
        minimum = maximum = None
    if minimum is not None and value < minimum:
        minimum = None
    if maximum is not None and value > maximum:
        maximum = None
    return minimum, maximum, step


def _usable_bound(bound: Optional[float], whole: bool) -> Optional[float]:
    """A declared bound, if this field's type can carry it, else ``None``.

    An ``integer`` field takes whole bounds only -- `docs/workflow-schema.md`
    says so and its loader enforces it -- and a runtime that declares a
    fractional limit for a whole input has said something this schema has no
    way to write down.  It is dropped rather than rounded: rounding invents a
    limit nobody declared, in whichever direction the rounding happens to go.
    """

    if bound is None:
        return None
    if whole and isinstance(bound, float):
        return None
    return bound


def _listed(options: Sequence[Any]) -> str:
    """The choices, as a sentence names them."""

    shown = ", ".join(repr(option) for option in options[:_LISTED_OPTIONS])
    remaining = len(options) - _LISTED_OPTIONS
    if remaining > 0:
        return "{} and {} more".format(shown, remaining)
    return shown


def _declared_frame_rate(graph: Mapping[str, Any]) -> Optional[float]:
    """The rate the graph declares, when it declares exactly one.

    `docs/workflow-schema.md` is emphatic that a duration is **declared, never
    inferred**: a field's name switches nothing on by itself.  What is read
    here is a literal frame rate written in the graph, and only when every
    such literal agrees -- two different rates mean the graph plays two
    things, and there is no one rate to present a frame count at.
    """

    rates = set()
    for node in graph:
        for name, value in _inputs(graph, node).items():
            if semantics.sanitize_role(name) not in semantics.FRAME_RATE_NAMES:
                continue
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                continue
            if not math.isfinite(value) or value <= 0:
                continue
            rates.add(float(value))
    if len(rates) != 1:
        return None
    return rates.pop()


def _nearest_label(labels: Mapping[str, int]) -> Optional[str]:
    if not labels:
        return None
    return sorted(labels, key=lambda name: (labels[name], name))[0]


def _downstream_chain(labels: Mapping[str, int]) -> Tuple[Tuple[str, int], ...]:
    """The whole downstream map, ordered nearest first and then by name.

    The same evidence :func:`_nearest_label` takes one entry of, kept entire so
    that a label which collides can look one hop further out.  The order is a
    function of the names and the depths alone, so renumbering the graph cannot
    change it, and nothing about a node id is in it to begin with.
    """

    return tuple(sorted(labels.items(), key=lambda item: (item[1], item[0])))


def _node_title(graph: Mapping[str, Any], node: str) -> str:
    """What the author called this node, verbatim, or ``""``.

    ``_meta.title`` is written by the editor the curator exports from and is
    theirs, not this importer's: nothing here validates it, and every reader of
    it goes through :func:`_sanitised_title` first.  A graph without the key,
    with a ``_meta`` that is not an object, or with a title that is not a
    string, has not said anything -- which is the same answer as a graph that
    said nothing.
    """

    entry = graph.get(node) if isinstance(graph, Mapping) else None
    if not isinstance(entry, Mapping):
        return ""
    meta = entry.get("_meta")
    if not isinstance(meta, Mapping):
        return ""
    title = meta.get("title")
    return title if isinstance(title, str) else ""


def _is_technical_media(verdict: Verdict, labels: Mapping[str, int]) -> bool:
    if verdict.mask:
        return True
    for name, depth in labels.items():
        if depth > MASK_EVIDENCE_DEPTH:
            continue
        if set(re.split(r"[^a-z0-9]+", name.lower())) & semantics.MASK_WORDS:
            return True
    return False


def _role_for(
    node: str,
    name: str,
    verdict: Verdict,
    labels: Mapping[str, int],
    nearest: Optional[str],
) -> Tuple[str, Optional[str]]:
    """The role this input plays, or the reason it could not be established."""

    if verdict.prompt:
        polarity, problem = _polarity(node, name, labels)
        if problem is not None:
            return "", problem
        return ("negative_prompt" if polarity == "negative" else "prompt"), None

    if verdict.media is not None:
        return _media_role(verdict.media, name, nearest), None

    role = verdict.role or semantics.sanitize_role(name)
    if not role:
        return "", "Node {} input {!r} has no name an id can be made from.".format(
            node, name
        )
    return role, None


def _wired_prompt(
    graph: Mapping[str, Any],
    consumers: Mapping[str, List[Tuple[str, str]]],
    node: str,
    name: str,
    value: Any,
) -> Optional[Verdict]:
    """A prompt, when this string is its node's whole input and the node is wired into one.

    A text encoder's ``text`` is a prompt because of its name, and
    `semantics.classify` says so.  The same prose held on a string node and
    *wired into* that ``text`` sits under a name that says nothing -- ComfyUI's
    string primitives call their one input ``value`` -- so ``classify``
    answers ``UNCERTAIN``, correctly, and the workflow was held.  The evidence
    is in the file all the same: where the node's output lands.

    So a literal string nothing earlier settled becomes a prompt when it is
    **the only input its node has**, and that node's output feeds,
    **directly**, an input ``classify`` would itself call a prompt by its name,
    asked with this very value.  The verdict is the one ``classify`` gives a
    prompt written on the encoder, and nothing downstream of it is new: which
    prompt it is -- positive, negative, or "feeds both, so look at it" -- comes
    from :func:`_polarity` exactly as it does for that encoder's own ``text``.

    Deliberately narrow:

    * **the node's only input.**  What a wire proves is that the node's
      *output* is a prompt, and only a node with nothing else to work from can
      be relied on to output the text it holds.  A node with a second input --
      a literal or a wire -- may do anything with the text: join it to
      something with a delimiter, replace one word in something else by
      another, hand a system message and a model name to a language model.
      Each of those strings is on a node wired into a prompt, and none of them
      is the prompt; taking the rule wider made every one of them a required
      "Prompt" field (T-0219's review).  The shape is read -- how many inputs
      the node has -- never its class name;
    * **one hop.**  A node the output reaches only through another node is not
      read; the node in between may do anything to the text, and "somewhere
      downstream is a prompt" is not evidence that this text is one;
    * **the first output only**, which is what :func:`_consumers` indexes for
      every other question in this module;
    * **no class name**, and no reading of this input's own name.  What is read
      is the *consumer's* input name, through ``classify``, and only because
      that is the judgement already made for a prompt written in place;
    * it can only turn an input that was going to be held into a prompt.  An
      input any earlier authority settled -- ``classify``, a node shape, a
      declared choice list, the computation rule -- never reaches here.

    There is no separate "the value is a string" check, and that is not an
    oversight: ``classify`` calls an input a prompt only when it holds text, so
    asking it with a number answers "not a prompt" by itself.  A mutation
    proved such a check dead, and a clause no test can fail on is a clause that
    can be deleted with the suite still green.
    """

    if list(_inputs(graph, node)) != [name]:
        return None
    fed = sorted(
        {
            consumer_input
            for _, consumer_input in consumers.get(node, ())
            if semantics.classify(consumer_input, value).prompt
        }
    )
    if not fed:
        return None
    return Verdict(
        Exposure.EXPOSE,
        "input {!r} is the only input of its node and holds text its own name "
        "says nothing about, and this node's output is wired straight into {} "
        "{}, where a prompt is written: the wiring makes it that prompt.".format(
            name,
            "an input named" if len(fed) == 1 else "inputs named",
            ", ".join(repr(item) for item in fed),
        ),
        field_type="multiline",
        role=semantics.sanitize_role(name),
        prompt=True,
    )


def _polarity(
    node: str, name: str, labels: Mapping[str, int]
) -> Tuple[Optional[str], Optional[str]]:
    """Positive or negative, from the input's own name or from the wiring.

    A text encoder's own input is called ``text`` in every graph; what makes
    one of them the negative prompt is that its conditioning is consumed as a
    sampler's ``negative``.  That is evidence in the file, and it survives
    renumbering.
    """

    words = set(re.split(r"[^a-z0-9]+", name.lower()))
    if "negative" in words:
        return "negative", None
    if "positive" in words:
        return "positive", None

    positive = labels.get("positive")
    negative = labels.get("negative")
    if positive is None and negative is None:
        return None, None
    if positive is not None and negative is not None:
        if positive == negative:
            return None, (
                "Node {} input {!r} feeds both a positive and a negative "
                "conditioning input, so which prompt it is cannot be "
                "decided.".format(node, name)
            )
        return ("positive" if positive < negative else "negative"), None
    return ("positive" if positive is not None else "negative"), None


def _media_role(kind: str, name: str, nearest: Optional[str]) -> str:
    """What part a picture or a clip plays, named for the way it is consumed."""

    label = nearest or name
    role = semantics.sanitize_role(label)
    if not role or role in GENERIC_MEDIA_LABELS:
        return kind
    if kind in re.split(r"[^a-z0-9]+", role):
        return role
    return "{}_{}".format(role, kind)


# --------------------------------------------------------------------------
# Collapsing, and the ids
# --------------------------------------------------------------------------


def _options_key(options: Sequence[Any]) -> Tuple[str, ...]:
    """Two inputs offer the same choices only when the sets are the same.

    Sorted, so that **the order the runtime declared the choices in does not
    reach this key**: a ComfyUI upgrade that reorders a list must not split one
    control into two, which would move an id a user's saved settings hang off.
    The declared order is kept for presentation on the candidate itself.

    Part of the grouping key because two node classes can legitimately declare
    different choice lists for the same input name.  Collapsed into one field
    they would become one control writing a value into a node that does not
    offer it -- a job that fails at ComfyUI, from a form that looked right.
    """

    return tuple(sorted("{}:{}".format(type(option).__name__, option) for option in options))


def _declaration_key(numeric: Optional[NumericDeclaration], field_type: str) -> str:
    """The kind of number this input will really be, when it is not the obvious one.

    ``field_type`` is what `semantics.py` read out of the **value** -- which is
    what every other candidate in a group carries too, since it is the key's
    second component.  So this answers with a type name only where the runtime
    contradicts that reading, and with ``""`` everywhere else:

    * the runtime said nothing about this input -- no ComfyUI, a class it does
      not have, an input it does not declare, a spec shape `contract.py` does
      not read;
    * or it said exactly what the value already says.

    Both of those leave the input the kind of number it looked like, and what
    is in the key is therefore the type the field will **really** have whenever
    that is not the type its value is written as.  Within one group the second
    component is fixed, so two members share this component exactly when the
    two inputs end up the same kind of control -- which is the only question a
    grouping key is allowed to ask.  (The same number written ``1`` in one input
    and ``1.0`` in the other differs in the second component itself, and is
    :func:`_one_number_however_written`'s question, not this one's.)

    Part of the key for exactly the reason :func:`_options_key` is, and the
    argument transfers word for word.  Two node classes can legitimately
    declare the same input name as two different numbers -- a ``value`` a
    runtime calls ``FLOAT`` and a ``value`` it calls ``INT`` is what the
    hand-built A/B switch looks like, where one feeds a guidance scale and the
    other a step count.  Collapsed into one field they become one control the
    user sets once that writes into both, which is two unrelated settings
    moving together from a form that looked right.  Nothing is inferred from
    the input's name and nothing from the shape of the value alone -- both are
    the mistake T-0072, T-0080 and T-0095 each measured and each rejected.

    **Silence is not a disagreement, and that correction is load-bearing.**  A
    key that answered "somebody spoke about this one" would split a seed two
    sampler stages share the moment one of the two classes was missing from
    ``/object_info`` -- a custom-node pack the answering ComfyUI does not have,
    a version skew, a spec this parser cannot read -- and the bare id ``seed``
    would be gone.  The same catalogue synced against two machines would then
    produce two different sets of field ids, and every saved default keyed on
    the old one would be orphaned with nothing about the graph having changed.
    A declaration that only confirms what the value already says is not a
    reason to split either, for the same reason: the field's type is what it
    would have been, so nothing about the control has been shown to differ.

    What that costs is real and is smaller: a declared input merged with a
    silent one takes the declared input's bounds, which is a limit a user is
    held to on a node whose runtime never spoke.  It is one control writing one
    value into both, so a limit true of either is true of the control; and a
    bound can only ever narrow what may be set, where the alternative -- no
    bounds -- lets a user set anything at all.  See :func:`_resolved_declaration`.

    **The range is deliberately not in here, and that is a decision.**  A
    ``min`` or a ``max`` says how far one node's input goes; it does not say
    that two inputs are different controls, and a ``step`` is a widget's
    increment which can never make a node refuse a value at all.  Splitting a
    group over any of the three would take that same shared seed and make two
    fields of it because one class declared an increment the other did not.
    The safety question a range does raise is answered where it belongs, by
    intersecting the declared ranges in :func:`_resolved_declaration`.

    A plain string rather than a tuple of the declaration's fields, and that is
    also a decision: ``1`` and ``1.0`` are equal with equal hashes in Python,
    so a key built from declared bounds would call two different declarations
    one key and hand a group two answers to choose between.  A type name is a
    string, which compares by value and by type, so this component cannot do
    that.
    """

    if numeric is None or numeric.field_type == field_type:
        return ""
    return numeric.field_type


def _number_key(candidate: InputCandidate) -> Optional[Tuple[str, Any]]:
    """The number an input holds, whichever way it was written -- for grouping only.

    ``1`` and ``1.0`` are one number here, and that is the whole of this
    function: the key carries the bare value and no type beside it, and Python
    compares an ``int`` with a ``float`` exactly and hashes equal numbers
    equally -- ``1 == 1.0`` with one hash, while ``2**53 + 1`` is not the float
    it rounds to -- so the two spellings of the same number are one key and
    nothing else is.  (Normalising a whole float to ``int`` first would change
    no answer, and a clause no input can distinguish is not written.)

    ``None`` for every input whose value was not read as a number --
    ``integer`` or ``float`` -- and the one exclusion that matters is ``True``.
    Python calls a boolean an ``int`` and ``True == 1``, so a key built from the
    value alone would put a flag beside a ``1.0``; :func:`semantics.field_type_of`
    answers ``boolean`` for it before it asks about ``int``, so asking for the
    field type is what keeps a flag and a count from ever being one control.

    **Used by :func:`_one_number_however_written`, and by nothing else.**
    :func:`contract._value_key` is deliberately left type-exact, because its
    other callers need exactly that: a declared choice list tidies away only
    an exact repeat and refuses ``1`` beside ``1.0`` (T-0186), and a node-shape
    key and a declared default are matched as written (T-0223, T-0244).
    Widening that function would decide every one of those questions in
    passing; this one answers a single question, for the grouping key, and only
    where :func:`_one_number_however_written` has found evidence that the two
    inputs are the same kind of control.
    """

    if candidate.verdict.field_type not in NUMERIC_FIELD_TYPES:
        return None
    return ("number", candidate.value)


def _one_number_however_written(
    groups: Dict[Tuple[Any, ...], List[InputCandidate]],
) -> Dict[Tuple[Any, ...], List[InputCandidate]]:
    """Join two groups holding one number, written ``1`` in one and ``1.0`` in the other.

    The grouping key compares a value by its Python type as well as by what it
    is (its second and third components), so the same number re-exported as
    ``1.0`` instead of ``1`` used to be a second group -- two fields, and the
    bare id of a control a user's saved settings hang off gone, with nothing
    about the workflow having changed (T-0102).  Those two components cannot
    simply stop comparing types: T-0097's two unrelated ``value`` inputs, a
    guidance scale on one class and a step count on another, are kept apart by
    nothing else when no runtime is there to say what they are.

    So the key is left as it is, every group it forms is kept whole, and two of
    them are joined afterwards **only where there is evidence that they are the
    same kind of control** -- for every pair of inputs across the two:

    * the runtime declares the same kind of number for both (``INT`` and
      ``INT``, or ``FLOAT`` and ``FLOAT``); or
    * the runtime declares no number for either, and both are the same input
      name on the same class type.

    Anything else keeps the separation the key made: a declared input beside a
    silent one, two silent inputs on two classes, ``INT`` against ``FLOAT``.
    "Every pair" is the rule rather than "some pair" because a group may already
    hold inputs the ordinary key joined on other evidence -- one class declared,
    another silent -- and joining such a group on the strength of one of its
    members would join the others with no evidence at all.

    Only groups of one role are candidates, only inputs :func:`_number_key`
    reads as the same number, and only a group holding it
    as a ``float`` with a group holding it any other way -- which, for a
    number, is as an ``int``.  At most one such pair can meet the rule: a
    member declared ``K`` requires the other side to be declared ``K``
    throughout, a silent member requires it to be silent throughout, and either
    requirement fixes that side's fifth key component -- so it is one group.

    The choice list (the fourth key component) is deliberately not compared.
    It is never anything but empty here: an input carries a list only where
    the runtime made it a ``select``, and :func:`_number_key` reads no
    ``select``.  Comparing it anyway would be a clause no input can fail.

    The joined group's field takes its type and its default in :func:`_field`.
    No group the key formed is split, and no other role is touched; what a join
    can still reach is the rest of its own role, by the indirect routes any
    change in a role's groups has (see the module docstring).
    """

    spellings: Dict[Tuple[Any, ...], Dict[bool, List[Tuple[Any, ...]]]] = {}
    for key, members in groups.items():
        number = _number_key(members[0])
        if number is None:
            continue
        spellings.setdefault((key[0], number), {}).setdefault(
            isinstance(members[0].value, float), []
        ).append(key)

    joined = dict(groups)
    for found in spellings.values():
        for whole in found.get(False, []):
            for fractional in found.get(True, []):
                if _same_kind_of_control(groups[whole], groups[fractional]):
                    joined[whole] = joined[whole] + joined.pop(fractional)
    return joined


def _same_kind_of_control(
    ours: Sequence[InputCandidate], theirs: Sequence[InputCandidate]
) -> bool:
    """Evidence, for every pair across the two groups, of one kind of control."""

    return all(_declared_alike(one, other) for one in ours for other in theirs)


def _declared_alike(one: InputCandidate, other: InputCandidate) -> bool:
    """Both declared the same kind of number, or neither declared and one input.

    "Declared" is :attr:`InputCandidate.numeric`: the runtime's ``INT`` or
    ``FLOAT`` for this class and input.  Two undeclared inputs need the same
    input name **and** the same class type -- the name alone is the placeholder
    ``value`` on every ``Primitive*`` class, which is T-0097's whole defect.
    """

    if one.numeric is not None and other.numeric is not None:
        return one.numeric.field_type == other.numeric.field_type
    if one.numeric is None and other.numeric is None:
        return one.class_type == other.class_type and one.input == other.input
    return False


def _fields_from(
    candidates: Sequence[InputCandidate],
    frame_rate: Optional[float],
    graph: Mapping[str, Any],
    consumers: Mapping[str, List[Tuple[str, str]]],
) -> Tuple[List[PlannedField], List[str], List[Tuple[InputCandidate, str]]]:
    """The fields, the reasons some inputs produced none, and which inputs.

    ``graph`` and ``consumers`` are here for one question only: telling apart
    same-role groups the base fingerprint could not (:func:`_separate`).

    The third return value is what the control inventory needs: a candidate
    that was safe on its own but whose *group* could not be told apart is
    still a literal input somebody has to be able to find, and the sentence
    that stopped it is the one composed here.
    """

    groups: Dict[
        Tuple[str, str, Tuple[str, Any], Tuple[str, ...], str],
        List[InputCandidate],
    ] = {}
    for candidate in candidates:
        key = (
            candidate.role,
            candidate.verdict.field_type or "",
            _value_key(candidate.value),
            _options_key(candidate.options),
            _declaration_key(candidate.numeric, candidate.verdict.field_type or ""),
        )
        groups.setdefault(key, []).append(candidate)
    groups = _one_number_however_written(groups)

    by_role: Dict[str, List[List[InputCandidate]]] = {}
    for key in sorted(
        groups, key=lambda item: (item[0], item[1], str(item[2]), item[3], item[4])
    ):
        members = sorted(groups[key], key=lambda item: _natural(item.node))
        by_role.setdefault(key[0], []).append(members)

    dimensions = {role for role in by_role if role in semantics.DIMENSION_NAMES}

    fields: List[PlannedField] = []
    # One per entry of ``fields``, in the same order, holding what a label is
    # made of.  Kept beside the fields rather than on them because it is
    # evidence for a name, not part of a definition, and because the escalation
    # below has to be able to build a *different* name out of the same pieces.
    namings: List[_Naming] = []
    problems: List[str] = []
    rejected: List[Tuple[InputCandidate, str]] = []
    for role in sorted(by_role):
        members_list = sorted(
            by_role[role], key=lambda members: (members[0].fingerprint, members[0].input)
        )
        if len(members_list) == 1:
            naming = _naming(members_list[0], role, None)
            namings.append(naming)
            fields.append(
                _field(
                    members_list[0],
                    role,
                    None,
                    dimensions,
                    frame_rate,
                    naming=naming,
                )
            )
            continue

        # Media and scalars alike: the wiring tells same-role groups apart, as
        # deep as it has to (T-0220).  Only where it never does is the role
        # refused -- whole, and in the sentence it always had, which for a
        # picture is about the slot.
        separated = _separate(graph, consumers, members_list)
        if separated is None:
            where = _where(members_list)
            if members_list[0][0].verdict.media is not None:
                problem = (
                    "{} hold different {}s and the graph gives them the same part "
                    "to play, so which picture belongs in which slot cannot be "
                    "decided; a media field bound to the wrong slot is wrong "
                    "silently.".format(where, members_list[0][0].verdict.media)
                )
            else:
                problem = (
                    "{} hold different values for {!r} and are wired identically, "
                    "so nothing tells one from the other and no id can be minted "
                    "for either.".format(where, role)
                )
            problems.append(problem)
            rejected.extend(_each(members_list, problem))
            continue

        for members, fingerprint in zip(*separated):
            naming = _naming(members, role, members[0])
            namings.append(naming)
            fields.append(
                _field(
                    members,
                    "{}-{}".format(role, fingerprint),
                    members[0],
                    dimensions,
                    frame_rate,
                    base_role=role,
                    naming=naming,
                )
            )

    seen: Dict[str, PlannedField] = {}
    for item in fields:
        if item.id in seen:
            problems.append(
                "two logical fields both want the id {!r}; no id is minted on a "
                "collision.".format(item.id)
            )
        seen[item.id] = item

    # Two fields the user can set independently must not reach the form under
    # one name.  Done here, on the whole definition, because that is the only
    # place the question exists: no single field can tell whether its label is
    # also somebody else's.  Before the sort, so that the answer cannot depend
    # on presentation order.
    fields = _distinguish(fields, namings)

    fields.sort(key=_field_order)
    return fields, problems, rejected


def _each(
    members_list: Sequence[Sequence[InputCandidate]], problem: str
) -> List[Tuple[InputCandidate, str]]:
    """Every candidate in ``members_list``, paired with what stopped it."""

    return [
        (member, problem) for members in members_list for member in members
    ]


def _where(members_list: Sequence[Sequence[InputCandidate]]) -> str:
    return ", ".join(
        sorted(
            "node {} input {!r}".format(member.node, member.input)
            for members in members_list
            for member in members
        )
    )


def _field_order(item: PlannedField) -> Tuple[int, int, str]:
    """Prompt first, then the media it works on, then everything else by id."""

    if item.id in _ROLE_ORDER:
        rank = _ROLE_ORDER.index(item.id)
    elif item.type in ("image", "video"):
        rank = len(_ROLE_ORDER)
    else:
        rank = len(_ROLE_ORDER) + 1
    return (_SECTION_ORDER[item.section], rank, item.id)


def _field(
    members: Sequence[InputCandidate],
    field_id: str,
    discriminated: Optional[InputCandidate],
    dimensions: Set[str],
    frame_rate: Optional[float],
    base_role: Optional[str] = None,
    *,
    naming: "_Naming",
) -> PlannedField:
    first = members[0]
    verdict = first.verdict
    role = base_role or first.role
    # What the value can be carried as (`semantics.py`), unless the ComfyUI
    # that will run this graph declares which kind of number the input is --
    # see the module docstring.  The declared type is read here and nowhere
    # else, so everything below that asks about the type of this field, from
    # the ``seed`` role to the frame-count hint, asks about the one it will
    # really have.
    declared = _resolved_declaration(members)
    declared_type = None if declared is None else declared.field_type
    # Several spellings of one number in one field exist only where
    # :func:`_one_number_however_written` joined ``1`` to ``1.0``: with no
    # declaration such a field is fractional, because one of its inputs was
    # written as a fraction, and its default is written as that type.
    spelled = {type(member.value) for member in members}
    written_type = "float" if len(spelled) > 1 else verdict.field_type
    kind = declared_type or written_type or "string"
    media = verdict.media is not None
    is_prompt = verdict.prompt and role == "prompt"

    section = "main" if media or is_prompt else "advanced"
    required = media or is_prompt

    has_default = False
    default: Any = None
    if not media:
        value = first.value
        if isinstance(value, str) and required and not value.strip():
            has_default = False
        else:
            has_default = True
            default = value
            if len(spelled) > 1:
                default = float(value) if kind == "float" else int(value)

    role_hint = "seed" if role == semantics.SEED_ROLE and kind == "integer" else None
    pair = (
        role
        if kind == "integer" and role in dimensions and len(dimensions) == 2
        else None
    )
    duration = (
        frame_rate
        if kind == "integer"
        and frame_rate is not None
        and role in semantics.FRAME_COUNT_NAMES
        else None
    )

    # Reached only for a field whose type the runtime declared, and a declared
    # numeric type is only ever asked for an input the graph already settled as
    # a number -- so ``default`` here is that number, and there is nothing to
    # check about it that is not already true by construction.
    minimum: Optional[float] = None
    maximum: Optional[float] = None
    step: Optional[float] = None
    if declared is not None:
        minimum, maximum, step = _numeric_bounds(declared, kind, default)

    return PlannedField(
        id=_clean_id(field_id),
        label=naming.label,
        type=kind,
        section=section,
        required=required,
        has_default=has_default,
        default=default,
        translatable=bool(verdict.prompt) and kind in ("string", "multiline"),
        role_hint=role_hint,
        pair=pair,
        duration_fps=duration,
        targets=tuple(member.target for member in members),
        evidence=_evidence(members, role, discriminated),
        # The declared order, from the first member -- and the members of a
        # group all carry the same set, because the set is part of what makes
        # them one group.
        options=first.options,
        minimum=minimum,
        maximum=maximum,
        step=step,
    )


def _evidence(
    members: Sequence[InputCandidate], role: str, discriminated: Optional[InputCandidate]
) -> str:
    where = ", ".join(
        "node {} input {!r}".format(member.node, member.input) for member in members
    )
    if len(members) > 1:
        detail = (
            "{} inputs carry the same {!r} value, so they are one control the "
            "user sets once: {}".format(len(members), role, where)
        )
    else:
        detail = "{}: {}".format(where, members[0].verdict.reason)
    if discriminated is not None:
        detail += (
            " A second {!r} exists in this graph with a different value, so this "
            "one is identified by what its node is wired into and out of.".format(role)
        )
    return detail


def _label(role: str) -> str:
    words = role.replace("-", " ").replace("_", " ").strip()
    return words[:1].upper() + words[1:] if words else role


def _hint(candidate: InputCandidate) -> str:
    if candidate.nearest_label:
        return candidate.nearest_label.replace("_", " ")
    if candidate.input != candidate.role:
        return candidate.input.replace("_", " ")
    return candidate.fingerprint


# --------------------------------------------------------------------------
# Two controls in one form need two names
# --------------------------------------------------------------------------

#: How many further consumer input names a colliding label may reach for.
#: Two, because the first hop is the label it already has and the tail of a
#: graph is shared by nearly everything in it -- a longer walk buys almost
#: nothing and costs a name nobody can read.
WIRING_HINTS = 2

#: How long a node's own title may be before a label cuts it short.  A label
#: is read on a phone, and a title is free text of any length at all.
TITLE_LABEL_CHARS = 40

#: The only punctuation a title keeps.  Everything outside this and the
#: letter/number/mark categories is dropped rather than escaped, which is why
#: no title can close the bracket it sits inside, start a new one, or carry a
#: direction override into a line of a form.
TITLE_PUNCTUATION = frozenset("-.,/+&'’")

#: What marks a title the label had to cut short, so that a shortened name
#: reads as one rather than as a name somebody chose.
TITLE_CUT = "…"


@dataclass(frozen=True)
class _Naming:
    """What a field's label is made of, and what else it could be made of.

    :attr:`stem` is the role as a person reads it and :attr:`hint` is the one
    thing that made this field distinguishable from its same-role siblings --
    together they are exactly the label this module has always produced.  The
    members are kept so that a label which turns out to collide can be built
    again out of further evidence, and only then.
    """

    stem: str
    hint: Optional[str]
    members: Tuple[InputCandidate, ...]

    @property
    def label(self) -> str:
        if self.hint is None:
            return self.stem
        return "{} ({})".format(self.stem, self.hint)


def _naming(
    members: Sequence[InputCandidate],
    role: str,
    discriminated: Optional[InputCandidate],
) -> _Naming:
    return _Naming(
        stem=_label(role),
        hint=None if discriminated is None else _hint(discriminated),
        members=tuple(members),
    )


def _distinguish(
    fields: Sequence[PlannedField], namings: Sequence[_Naming]
) -> List[PlannedField]:
    """Relabel until no two fields of one definition share a name.

    Every field starts on the label it would have had, and only a field whose
    label is somebody else's moves -- so a definition that never had the
    problem is byte-for-byte the definition it was.  A field that does move
    steps one rung down :func:`_alternatives`, which ends in the field's own
    id: distinct in every definition this module emits, so a round in which
    everything that clashes is already on the last rung cannot clash.

    That is the whole guarantee, and it is a property of the ladder rather
    than of how well any one rung happens to work.  A rung that fails to
    separate two fields is not a wrong label -- it is a round that does not
    end, and the next one is tried.
    """

    ladders = [
        _alternatives(naming, field) for field, naming in zip(fields, namings)
    ]
    rungs = [0] * len(ladders)
    labels = [ladder[0] for ladder in ladders]
    # Each round moves at least one field one rung further, and no field has
    # more rungs than its ladder, so the walk is bounded by their total.
    for _ in range(sum(len(ladder) for ladder in ladders) + 1):
        counts: Dict[str, int] = {}
        for label in labels:
            counts[label] = counts.get(label, 0) + 1
        moved = False
        for index, label in enumerate(labels):
            if counts[label] > 1 and rungs[index] + 1 < len(ladders[index]):
                rungs[index] += 1
                labels[index] = ladders[index][rungs[index]]
                moved = True
        if not moved:
            break
    return [
        field
        if label == field.label
        else replace(field, label=label, evidence=field.evidence + _RENAMED)
        for field, label in zip(fields, labels)
    ]


#: Added to the evidence of a field this had to rename, so that a label nobody
#: expected is a label with a reason beside it rather than a surprise.
_RENAMED = (
    " Another field of this definition wanted the same label, so this one is "
    "named for what else the graph says about it."
)


def _alternatives(naming: _Naming, field: PlannedField) -> Tuple[str, ...]:
    """The names this field could carry, best first and injective last.

    The first entry is the label the field already has, so a field nothing
    collides with is never renamed.  Then the wiring, then the author's own
    title, then the id -- the order the module docstring argues for, and each
    rung is left out when the graph carries no such evidence rather than
    filled with something weaker.
    """

    found = [naming.label]

    reached = [name for name, _ in _merged_downstream(naming.members)]
    already = naming.hint
    further = [name for name in reached if _readable(name) != already]
    carried = [] if already is None else [already]
    for depth in range(1, min(len(further), WIRING_HINTS) + 1):
        found.append(
            "{} ({})".format(
                naming.stem,
                ", ".join(carried + [_readable(name) for name in further[:depth]]),
            )
        )

    title = _shared_title(naming.members)
    if title:
        found.append("{} ({})".format(naming.stem, title))

    # The last rung, and the only one that cannot fail to separate two fields:
    # an emitted definition has no two fields of one id, because a collision of
    # ids is refused several lines above and takes the whole workflow with it.
    last = "{} ({})".format(naming.stem, field.id)
    ordered = [name for name in dict.fromkeys(found) if name != last]
    ordered.append(last)
    return tuple(ordered)


def _readable(name: str) -> str:
    return name.replace("_", " ")


def _merged_downstream(
    members: Sequence[InputCandidate],
) -> Tuple[Tuple[str, int], ...]:
    """Where a whole field's value ends up, nearest first.

    A field may drive several node inputs, and each of them reaches its own
    part of the graph; the field reaches the union, at the shortest distance
    any of its members reaches it by.  Both the union and the minimum are
    independent of the order the members are in, which is what keeps a
    renumbered graph producing the same names.
    """

    depths: Dict[str, int] = {}
    for member in members:
        for name, depth in member.downstream:
            if name not in depths or depth < depths[name]:
                depths[name] = depth
    return tuple(sorted(depths.items(), key=lambda item: (item[1], item[0])))


def _shared_title(members: Sequence[InputCandidate]) -> str:
    """The one name the author gave this control, or ``""``.

    A field driving several node inputs has a title per node, and only one
    answer is honest: where they all say the same thing that is the control's
    name, and where they disagree the control has no name of its own and the
    ladder goes on without one.  ``""`` from :func:`_sanitised_title` is not a
    title, so a node the author never named does not out-vote one they did.
    """

    titles = {_sanitised_title(member.title) for member in members}
    titles.discard("")
    return titles.pop() if len(titles) == 1 else ""


def _sanitised_title(text: Any) -> str:
    """A node title reduced to something that can safely be part of a name.

    This is untrusted input -- the user's own file, written by hand in an
    editor, in any language and to no rules at all -- and it is read here for
    one purpose only: to tell two controls apart.  So it is cut down rather
    than checked:

    * **compatibility-normalised first.**  Two titles that differ only in a
      form Unicode calls equivalent -- a full-width letter, a ligature, a
      no-break space -- read as one title on a form, so they are made into one
      string here as well.  They then collide, and colliding is what makes the
      ladder go on to the id: two controls that would have looked alike are
      given names that cannot;
    * **letters, numbers, marks, spaces and a short list of punctuation**, and
      nothing else.  A control character, a bidirectional override, a
      zero-width joiner, a bracket, a symbol -- all dropped.  A title cannot
      then close the bracket it is written inside, cannot open another, and
      cannot reorder the line it appears in;
    * **bounded**, because a label is read on a phone and a title has no
      length at all;
    * **empty unless it says something.**  Whitespace, or punctuation with no
      letter or number in it, is not a name, and a field whose title is one is
      treated as a field with no title.

    What it does **not** claim to do is detect a letter of one alphabet drawn
    like a letter of another.  Two titles chosen to look alike in different
    scripts still produce two different labels -- the guarantee this module
    makes is that no two controls carry the *same* name, and that one holds --
    but it does not promise they cannot be made to look similar.  A confusable
    table is a different piece of work from this card's.
    """

    if not isinstance(text, str):
        return ""
    kept: List[str] = []
    for character in unicodedata.normalize("NFKC", text):
        category = unicodedata.category(character)
        if character.isspace() or character == "_":
            kept.append(" ")
        elif category[0] in ("L", "N", "M") or character in TITLE_PUNCTUATION:
            kept.append(character)
    cleaned = " ".join("".join(kept).split())
    if not any(character.isalnum() for character in cleaned):
        return ""
    if len(cleaned) > TITLE_LABEL_CHARS:
        cleaned = cleaned[:TITLE_LABEL_CHARS].rstrip() + TITLE_CUT
    return cleaned


def _clean_id(value: str) -> str:
    cleaned = _ID_CHARS.sub("-", value.strip().lower()).strip("-_")
    return cleaned or "field"


__all__ = [
    "COMPUTATION_KIND",
    "COMPUTATION_OUTPUTS",
    "CONTROL_SECTIONS",
    "DECLARED_DEFAULT_KIND",
    "FINGERPRINT_DEPTH",
    "HIDDEN_SECTIONS",
    "LOADING_CLASS_WORDS",
    "LOAD_SETTING_KIND",
    "LOCKED_KINDS",
    "MODEL_ARCHITECTURE_KIND",
    "MODEL_PATCH_KIND",
    "MODEL_PATCH_OUTPUTS",
    "NODE_SHAPE_KIND",
    "NUMERIC_FIELD_TYPES",
    "SELECT_FIELD_TYPE",
    "TECHNICAL_MEDIA_KIND",
    "TITLE_CUT",
    "TITLE_LABEL_CHARS",
    "TITLE_PUNCTUATION",
    "WIRING_HINTS",
    "ControlRecord",
    "ImportPlan",
    "InputCandidate",
    "NotExposed",
    "PlannedField",
    "analyse",
    "class_words",
]
