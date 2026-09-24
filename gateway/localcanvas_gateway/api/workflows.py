"""The workflow endpoints -- T-0002's presentation views, served verbatim.

Both bodies come from :meth:`WorkflowDefinition.summary_view` and
:meth:`~WorkflowDefinition.detail_view`, which were built to contain no node id,
no node type and no ``bind`` block: the binding view lives in separate
attributes and is never assembled into a response here.  This module adds no
field of its own beyond ``input_summary``, which `docs/api.md` shows at the top
level of a summary entry as a convenience for the picker.

Filtering a graph out of a response would be a filter someone can forget.  The
two views being separate objects is what makes the guarantee structural.

**One thing is not served verbatim, and only one** (T-0143): a field's ``help``
when the request asked for a language other than English.  The importer writes
a hint from a vocabulary of 33 sentences, and until this card those sentences
were English wherever the app's interface was.  The vocabulary is this
project's own prose, not the user's data, so the translation lives in the code
that owns it -- ``workflows/sync/semantics.py`` -- and **no definition file on
anybody's disk changes**.  See :func:`_localised` for how a generated sentence
is told from a curated one at serve time, and for the guarantee that a curated
sentence is never touched in any language.
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional

from fastapi import APIRouter, Request

from ..errors import ApiError
from ..workflows import WorkflowDefinition
from .state import gateway

router = APIRouter()

#: The language a request that says nothing gets, and the language every
#: definition file is written in.  The same string as
#: ``semantics.DEFAULT_HELP_LANGUAGE``, which a test asserts rather than
#: assumes -- it is repeated here so that an English request never has to
#: import the importer to find out that it is English.
ENGLISH = "en"


@router.get("/workflows")
def list_workflows(request: Request) -> dict:
    registry = gateway(request).registry
    return {"workflows": [_summary(workflow) for workflow in registry.workflows]}


@router.get("/workflows/{workflow_id}")
def get_workflow(workflow_id: str, request: Request) -> dict:
    registry = gateway(request).registry
    workflow = registry.get(workflow_id)
    if workflow is None:
        raise ApiError(
            status_code=404,
            code="workflow_not_found",
            message="That workflow is no longer available.",
        )
    return _detail(workflow, requested_language(request))


def _summary(workflow: WorkflowDefinition) -> Dict[str, Any]:
    view = workflow.summary_view()
    view["input_summary"] = workflow.presentation.input_summary
    return view


def _detail(workflow: WorkflowDefinition, language: str = ENGLISH) -> Dict[str, Any]:
    view = workflow.detail_view()
    view["input_summary"] = workflow.presentation.input_summary
    if language != ENGLISH:
        view["inputs"] = _localised(workflow, view["inputs"], language)
    return view


def requested_language(request: Request) -> str:
    """The language tag this request asked for, or :data:`ENGLISH`.

    ``Accept-Language`` as `docs/api.md` documents it and as the app sends it:
    **one bare tag, no region, no quality values**.  The app derives it from
    its own interface language, which is a single choice, so there is nothing
    to negotiate and no list to rank.  Anything that is not a bare tag --
    ``ru-RU``, ``ru;q=0.9,en;q=0.8``, a comma, an empty header -- is not
    something this contract promises to understand, and the answer for
    everything this vocabulary cannot serve is the same one: English.  That is
    stated in `docs/api.md` so nobody has to guess it from here.

    Case is forgiven because HTTP language tags are case-insensitive; nothing
    else is.  A tag that is well-formed but unknown -- ``fr`` -- is not
    rejected here: it travels on and the vocabulary answers English for it,
    so one rule covers "we do not speak it" and "we do not have that
    sentence".
    """

    header = request.headers.get("accept-language")
    if header is None:
        return ENGLISH
    tag = header.strip().lower()
    if not tag:
        return ENGLISH
    return tag


def _localised(
    workflow: WorkflowDefinition, views: List[Dict[str, Any]], language: str
) -> List[Dict[str, Any]]:
    """The field views with every **generated** hint said in ``language``.

    THE PROBLEM, and it is the whole of this card.  A definition on disk
    carries one ``help`` string per field and does not record who wrote it.
    Two sentences look identical in the file: one the importer generated from
    the vocabulary, which is this project's prose and may be said in another
    language, and one a curator typed, which is the user's own words and may
    not be touched in any language at all.

    THE ANSWER.  A field's help is *generated* if it is exactly what the
    English vocabulary would produce for that field, and the gateway can work
    that out from what it already holds: the definition carries the field's
    ``bind``, so the graph's input names are available, and the field's id is
    the role `analysis.py` minted for it.  ``help_for_field`` is the same rule
    the importer wrote with.  Anything else -- a different sentence, or a
    sentence where the vocabulary has none -- is the curator's and is returned
    untouched.

    So a curated hint survives every locale, **including a Russian one asked
    for in English**, which is the case that makes the direction of the rule
    matter: the test for it is
    ``test_a_curated_russian_hint_is_served_untouched_when_english_is_asked_for``.

    The one ambiguity, stated rather than hidden: a curator who types, by
    hand, a sentence identical word for word to the vocabulary's English is
    indistinguishable from the importer, and a Russian reader is then served
    the Russian of *that same sentence*.  It says what they wrote, in the
    language they asked for, so the ambiguity costs nothing -- and no
    curated sentence whose words differ from the vocabulary's can ever be
    replaced.

    WHAT IT COSTS, in the other direction, and it is a real cost.  The
    recomputation asks what the vocabulary says **now**; the file was written
    by whatever the vocabulary said **then**.  So rewording one English
    sentence stops that one line matching in every catalogue already on disk,
    and it is served in English until the next import -- which is the same act
    that would have refreshed the English.  Per field and per catalogue, never
    an error, and it degrades to exactly what shipped before this feature.
    That is the price of keeping no translation table on the user's disk, and
    it is the better half of the trade: the alternative -- a record of what
    the last sync wrote -- would serve the *new* Russian beside the *old*
    English, which is worse than one language served consistently.
    `docs/api.md` lists it as a fallback case and
    ``test_a_hint_the_vocabulary_has_since_reworded_falls_back_to_the_file``
    pins it.

    WHY NOT THE INVENTORY'S ``generated_help`` RECORD, which knows the answer
    exactly.  It is a **sync artifact**: written by the importer beside the
    catalogue, absent from a catalogue nobody imported, and deletable without
    breaking anything today.  Reading it here would put a developer tool's
    bookkeeping file on the request path, give the gateway a new way to fail
    (missing, stale, unreadable), and make a hand-written catalogue -- the
    three definitions in ``workflows/examples`` among them -- unable to speak
    Russian at all.  It also answers a subtly different question, "what did
    the last sync write", so a catalogue that has not been re-synced since the
    vocabulary improved would be served the *new* Russian beside the *old*
    English, which is worse than being served English.

    THE IMPORT IS DEFERRED ON PURPOSE.  ``workflows/sync`` is a curator tool
    and its own docstring holds it to "starting the gateway does not load a
    line of it"; ``workflows/cli.py`` already imports it from outside the
    subpackage inside the function that needs it, and this is the same shape.
    A gateway that is never asked for another language therefore still loads
    none of it, and an English request never reaches this function at all.
    """

    from ..workflows.sync import semantics

    localised: List[Dict[str, Any]] = []
    for view in views:
        replacement = _localised_help(workflow, view, language, semantics)
        if replacement is None:
            localised.append(view)
        else:
            localised.append({**view, "help": replacement})
    return localised


def _localised_help(
    workflow: WorkflowDefinition,
    view: Dict[str, Any],
    language: str,
    semantics: Any,
) -> Optional[str]:
    """The translated sentence for one field, or ``None`` to leave it alone.

    ``None`` covers three different cases on purpose, because all three have
    the same correct outcome -- serve exactly what the file says:

    * the field has no ``help`` at all, so silence stays silence and no key
      appears;
    * the vocabulary says nothing about this field, so whatever is there was
      written by a person;
    * the vocabulary says something and it is *not* what the file carries, so
      whatever is there was written by a person.
    """

    written = view.get("help")
    if written is None:
        return None
    english = semantics.help_for_field(
        (binding.input for binding in workflow.bindings_for(view["id"])),
        view["id"],
    )
    if english is None or english != written:
        return None
    return semantics.help_for_field(
        (binding.input for binding in workflow.bindings_for(view["id"])),
        view["id"],
        language,
    )


__all__ = ["router", "requested_language", "ENGLISH"]
