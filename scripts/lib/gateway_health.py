"""Is the gateway in this environment the one this checkout declares?

Run by scripts/setup.ps1 with the environment's OWN interpreter, before it
decides whether to install anything:

    .venv\\Scripts\\python.exe scripts\\lib\\gateway_health.py <gateway dir> [extra ...]

It answers with one JSON object on standard output and exits 0:

    {"healthy": true|false, "reason": "...", "imported_from": "..."}

``reason`` is one sentence a person can read, and is empty when healthy.

WHY THIS EXISTS (T-0352). setup used to run ``pip install --editable gateway``
on every run. An editable build resolves ``setuptools>=61`` from the package
index in an isolated build environment, so a second run on a fully set-up
machine with no network failed with exit 1 -- and a run that did reach the
index reinstalled a gateway that was already there. Now setup asks this first
and installs only when the answer is no.

WHAT "HEALTHY" MEANS, and every part of it is decided locally:

  1. the gateway imports, from inside this checkout's gateway/ (the existing
     provenance rule -- asked here, and asked again by setup with the same
     PowerShell function that asks it after an install);
  2. there is an installed record of the project gateway/pyproject.toml names,
     and its version, requires-python and declared dependencies (every extra
     included) are the ones gateway/pyproject.toml declares NOW -- so a
     `git pull` that bumps the version or adds a dependency is a reinstall;
  3. THE WHOLE INSTALLED REQUIREMENT TREE is satisfied: starting from the
     gateway's own record (with the extras named on the command line, which is
     how -Dev asks for [test]), every requirement whose environment marker
     applies here -- the dependencies' dependencies too, with the extras each
     one is asked for -- is installed at a version its specifier accepts. The
     first version of this check stopped at the gateway's direct
     dependencies, and `pip uninstall starlette` (fastapi's) then passed as
     healthy while nothing could start (T-0352 review, R1);
  4. the modules the scripts actually run import: RUNTIME_MODULES below. A
     record on disk is not an importable package -- a dependency whose files
     are gone while its dist-info is still there passes 1-3.

WHAT IT DOES NOT DO, deliberately:

  * It never runs pip and never opens a socket. It reads files and imports the
    gateway's entry modules, which is what start.ps1 does next anyway.
  * It does not use ``packaging``. The copy inside pip (``pip._vendor``) is
    not a public interface and has changed shape between pip releases (older
    ones need pip's vendored pyparsing as well), and an environment may have
    no pip at all. The PEP 508 marker grammar and the PEP 440 comparisons
    this needs are small, are below, and are pinned by the script suite.
  * Anything it cannot decide -- a marker it cannot parse or a variable PEP
    508 does not define, a URL requirement, a version it cannot parse -- is
    answered "not healthy", never "healthy". The cost of that answer is one
    reinstall; the cost of the other would be a gateway that does not start.

Standard library only, and written for the whole supported range (3.10 has no
tomllib, so gateway/pyproject.toml is read by the small reader below).
"""

import json
import os
import platform
import re
import sys

try:
    import importlib.metadata as metadata
except ImportError:  # pragma: no cover - every supported Python has it
    metadata = None


def answer(healthy, reason="", imported_from=""):
    sys.stdout.write(json.dumps(
        {"healthy": bool(healthy), "reason": reason, "imported_from": imported_from}) + "\n")
    sys.exit(0)


# --------------------------------------------------------------------------
# gateway/pyproject.toml, read without tomllib
# --------------------------------------------------------------------------
#
# Only the keys this check needs, and only the shapes TOML gives them: a
# string, or an array of strings that may span lines and carry comments. A
# requirement string may itself hold brackets ("uvicorn[standard]"), so the
# reader tracks quotes rather than counting brackets on a line.

def _strings_until_close(text, start):
    """The strings of the array opening at text[start] == '[', and where it ends."""
    strings, depth, index = [], 0, start
    while index < len(text):
        char = text[index]
        if char in "\"'":
            end = text.find(char, index + 1)
            if end < 0:
                return None, len(text)
            strings.append(text[index + 1:end])
            index = end + 1
            continue
        if char == "#":
            newline = text.find("\n", index)
            index = len(text) if newline < 0 else newline
            continue
        if char == "[":
            depth += 1
        elif char == "]":
            depth -= 1
            if depth == 0:
                return strings, index + 1
        index += 1
    return None, len(text)


def read_pyproject(path):
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    tables = {}
    table = ""
    index = 0
    key_line = re.compile(r"[ \t]*([A-Za-z0-9_.-]+|\"[^\"]+\")[ \t]*=[ \t]*")
    header = re.compile(r"[ \t]*\[([^\[\]]+)\][ \t]*(?:#.*)?$")
    while index < len(text):
        newline = text.find("\n", index)
        end = len(text) if newline < 0 else newline
        line = text[index:end]
        found = header.match(line)
        if found:
            table = found.group(1).strip()
            tables.setdefault(table, {})
            index = end + 1
            continue
        found = key_line.match(line)
        if found:
            key = found.group(1).strip('"')
            value_at = index + found.end()
            if value_at < len(text) and text[value_at] == "[":
                strings, after = _strings_until_close(text, value_at)
                tables.setdefault(table, {})[key] = strings
                newline = text.find("\n", after)
                index = len(text) if newline < 0 else newline + 1
                continue
            rest = line[found.end():]
            quoted = re.match(r"\"([^\"]*)\"|'([^']*)'", rest)
            if quoted:
                value = quoted.group(1) if quoted.group(1) is not None else quoted.group(2)
                tables.setdefault(table, {})[key] = value
            else:
                tables.setdefault(table, {})[key] = rest.split("#", 1)[0].strip()
        index = end + 1
    return tables


# --------------------------------------------------------------------------
# Requirements and versions, as far as this check needs them
# --------------------------------------------------------------------------

def canonical(name):
    return re.sub(r"[-_.]+", "-", name).lower()


_REQUIREMENT = re.compile(
    r"^\s*([A-Za-z0-9][A-Za-z0-9._-]*)\s*(\[[^\]]*\])?\s*(.*?)\s*$")


def split_requirement(text):
    """(name, extras, specifier, marker), or None for a shape not handled here."""
    marker = ""
    if ";" in text:
        text, marker = text.split(";", 1)
    if "@" in text:
        return None
    found = _REQUIREMENT.match(text)
    if not found:
        return None
    extras = tuple(sorted(
        canonical(item) for item in (found.group(2) or "[]")[1:-1].split(",") if item.strip()))
    specifier = found.group(3).strip()
    if specifier.startswith("(") and specifier.endswith(")"):
        specifier = specifier[1:-1]
    clauses = tuple(sorted(
        clause.replace(" ", "") for clause in specifier.split(",") if clause.strip()))
    return canonical(found.group(1)), extras, clauses, marker.strip()


def normalised(text, extra=None):
    """One requirement as a comparable string, the way both sides can write it.

    The metadata setuptools writes reorders specifiers ("<2,>=1.11" for
    ">=1.11,<2") and spells an extra's requirement with a marker of its own,
    so both sides are brought to one form before they are compared.
    """
    parts = split_requirement(text)
    if parts is None:
        return "unreadable:" + text.strip()
    name, extras, clauses, marker = parts
    marker = re.sub(r"[\s\"']", "", marker).lower()
    if extra is not None:
        tag = "extra==" + canonical(extra)
        marker = "({})and{}".format(marker, tag) if marker else tag
    return "{}[{}]{};{}".format(name, ",".join(extras), ",".join(clauses), marker)


_VERSION = re.compile(
    r"^v?(?:(\d+)!)?(\d+(?:\.\d+)*)"
    r"(?:[-_.]?(a|b|c|rc|alpha|beta|pre|preview)[-_.]?(\d*))?"
    r"(?:-(\d+)|[-_.]?(?:post|rev|r)[-_.]?(\d*))?"
    r"(?:[-_.]?(dev)[-_.]?(\d*))?"
    r"(?:\+[a-z0-9]+(?:[-_.][a-z0-9]+)*)?$")

_PRE_RANK = {"a": 0, "alpha": 0, "b": 1, "beta": 1, "c": 2, "rc": 2, "pre": 2, "preview": 2}


def parse_version(text):
    """(release, sort key) for a PEP 440 version, or None when it is not one."""
    found = _VERSION.match(text.strip().lower())
    if not found:
        return None
    epoch = int(found.group(1) or 0)
    release = [int(part) for part in found.group(2).split(".")]
    stripped = list(release)
    while len(stripped) > 1 and stripped[-1] == 0:
        stripped.pop()
    has_post = found.group(5) is not None or found.group(6) is not None
    post = int(found.group(5) or found.group(6) or 0)
    has_dev = found.group(7) is not None
    dev = int(found.group(8) or 0)
    if found.group(3):
        pre = (0, _PRE_RANK[found.group(3)], int(found.group(4) or 0))
    elif has_dev and not has_post:
        pre = (-1, 0, 0)
    else:
        pre = (1, 0, 0)
    key = (epoch, tuple(stripped), pre, (post,) if has_post else (-1,),
           (0, dev) if has_dev else (1, 0))
    return release, key


def satisfies(version, clauses):
    """True / False, or None when this check cannot decide."""
    parsed = parse_version(version)
    if parsed is None:
        return None
    release, key = parsed
    for clause in clauses:
        found = re.match(r"^(~=|===|==|!=|<=|>=|<|>)(.+)$", clause)
        if not found:
            return None
        operator, target = found.group(1), found.group(2)
        if operator == "===":
            ok = version.strip() == target
        elif operator in ("==", "!=") and target.endswith(".*"):
            try:
                prefix = [int(part) for part in target[:-2].split(".")]
            except ValueError:
                return None
            padded = release + [0] * max(0, len(prefix) - len(release))
            ok = (padded[:len(prefix)] == prefix) == (operator == "==")
        else:
            wanted = parse_version(target)
            if wanted is None:
                return None
            if operator == "~=":
                if len(wanted[0]) < 2:
                    return None
                prefix = wanted[0][:-1]
                padded = release + [0] * max(0, len(prefix) - len(release))
                ok = key >= wanted[1] and padded[:len(prefix)] == prefix
            else:
                ok = {
                    "==": key == wanted[1], "!=": key != wanted[1],
                    "<=": key <= wanted[1], ">=": key >= wanted[1],
                    "<": key < wanted[1], ">": key > wanted[1],
                }[operator]
        if not ok:
            return False
    return True


# --------------------------------------------------------------------------
# Environment markers (PEP 508), as far as an installed tree needs them
# --------------------------------------------------------------------------
#
# The grammar is PEP 508's: `or` of `and` of either a parenthesised marker or
# `value op value`, where a value is a quoted string or one of the variables
# below. What is deliberately STRICTER than ``packaging``: an ordering
# comparison (<, <=, >, >=, ~=) between values that are not both versions is
# "cannot decide" here, where packaging falls back to comparing the strings.
# Nothing in a real dependency tree compares a platform name by order, and a
# guess is exactly what this file does not make.

class Undecidable(Exception):
    """A marker this check cannot evaluate; the answer is then "reinstall"."""


def _implementation_version():
    info = sys.implementation.version
    text = "{}.{}.{}".format(info.major, info.minor, info.micro)
    if info.releaselevel != "final":
        text += info.releaselevel[0] + str(info.serial)
    return text


#: Each read only when a marker names it: platform_release and friends are
#: never computed for a tree that does not ask.
_VARIABLES = {
    "os_name": lambda: os.name,
    "sys_platform": lambda: sys.platform,
    "platform_machine": platform.machine,
    "platform_python_implementation": platform.python_implementation,
    "platform_release": platform.release,
    "platform_system": platform.system,
    "platform_version": platform.version,
    "python_version": lambda: ".".join(platform.python_version_tuple()[:2]),
    "python_full_version": platform.python_version,
    "implementation_name": lambda: sys.implementation.name,
    "implementation_version": _implementation_version,
}
# The legacy spellings PEP 508 still accepts.
_ALIASES = {
    "os.name": "os_name", "sys.platform": "sys_platform",
    "platform.version": "platform_version", "platform.machine": "platform_machine",
    "platform.python_implementation": "platform_python_implementation",
    "python_implementation": "platform_python_implementation",
}

_TOKEN = re.compile(r"""\s*(?:
    (?P<open>\()|(?P<close>\))|
    (?P<string>'[^']*'|"[^"]*")|
    (?P<op>===|==|!=|<=|>=|~=|<|>|not\s+in\b|in\b)|
    (?P<logic>and\b|or\b)|
    (?P<name>[A-Za-z_][A-Za-z0-9_.]*)
)""", re.X)


def _tokens(text):
    tokens, index = [], 0
    while index < len(text):
        if not text[index:].strip():
            break
        found = _TOKEN.match(text, index)
        if not found or found.end() == index:
            raise Undecidable("unreadable marker")
        kind = found.lastgroup
        value = found.group(kind)
        if kind == "op":
            value = re.sub(r"\s+", " ", value)
        tokens.append((kind, value))
        index = found.end()
    return tokens


def _value(token, extra):
    kind, text = token
    if kind == "string":
        return text[1:-1], False
    if kind == "name":
        text = _ALIASES.get(text, text)
        if text == "extra":
            return extra, True
        if text in _VARIABLES:
            return _VARIABLES[text](), False
    raise Undecidable("unknown marker value {!r}".format(text))


_FLIPPED = {"<": ">", ">": "<", "<=": ">=", ">=": "<=", "==": "==", "!=": "!=", "===": "==="}


def _compare(left, operator, right, is_extra):
    if is_extra:
        if operator not in ("==", "!="):
            raise Undecidable("extra compared with " + operator)
        return (canonical(left) == canonical(right)) == (operator == "==")
    if operator == "in":
        return left in right
    if operator == "not in":
        return left not in right
    if operator == "===":
        return left == right
    # A wildcard is a PEP 440 prefix match -- "3.10.*" is not a version, and
    # comparing it as a string gave a confident WRONG answer (T-0352
    # re-review, R3). Only `==`/`!=` with the wildcard on the right and a
    # version on the left is decidable (a wildcard written on the left is
    # refused by the caller); anything else carrying a `*` is not.
    if "*" in left or "*" in right:
        if operator not in ("==", "!=") or "*" in left or not right.endswith(".*"):
            raise Undecidable("wildcard with " + operator)
        verdict = satisfies(left, (operator + right,))
        if verdict is None:
            raise Undecidable("wildcard comparison")
        return verdict
    if parse_version(left) is not None and parse_version(right) is not None:
        verdict = satisfies(left, (operator + right,))
        if verdict is None:
            raise Undecidable("version comparison")
        return verdict
    if operator == "==":
        return left == right
    if operator == "!=":
        return left != right
    raise Undecidable("{} between values that are not versions".format(operator))


def _evaluate(tokens, extra):
    position = [0]

    def peek():
        return tokens[position[0]] if position[0] < len(tokens) else (None, None)

    def take():
        token = peek()
        position[0] += 1
        return token

    def atom():
        if peek()[0] == "open":
            take()
            result = either()
            if take()[0] != "close":
                raise Undecidable("unbalanced parentheses")
            return result
        left_token = take()
        operator_kind, operator = take()
        right_token = take()
        if operator_kind != "op" or None in (left_token[0], right_token[0]):
            raise Undecidable("incomplete comparison")
        left, left_extra = _value(left_token, extra)
        right, right_extra = _value(right_token, extra)
        if left_token[0] == "string" and "*" in left:
            # A wildcard on the left has no agreed meaning (packaging answers
            # False for "3.10.*" == python_version, a flip would say True), so
            # it is not decided here.
            raise Undecidable("wildcard on the left")
        if right_token[0] == "name" and left_token[0] == "string" and operator in _FLIPPED:
            # "3.8" <= python_version is python_version >= "3.8".
            left, right, operator = right, left, _FLIPPED[operator]
        return _compare(left, operator, right, left_extra or right_extra)

    def both():
        results = [atom()]
        while peek() == ("logic", "and"):
            take()
            results.append(atom())
        return all(results)

    def either():
        results = [both()]
        while peek() == ("logic", "or"):
            take()
            results.append(both())
        return any(results)

    result = either()
    if position[0] != len(tokens):
        raise Undecidable("text after the marker")
    return result


def marker_applies(marker, extras):
    """Does this marker hold here, for a distribution asked for with ``extras``?

    True / False, or None when it cannot be decided. Evaluated the way an
    installer does: once with no extra, and once for each extra asked for.
    """
    try:
        tokens = _tokens(marker)
        if not tokens:
            return True
        return any(_evaluate(tokens, extra) for extra in [""] + sorted(extras))
    except Undecidable:
        return None


# --------------------------------------------------------------------------
# The installed tree, and what has to import
# --------------------------------------------------------------------------

def unsatisfied_requirement(record, extras):
    """The first requirement in the installed tree that is not met, or None.

    Breadth first from the gateway's own record, following every requirement
    whose marker applies, into each dependency with the extras it is asked
    for. Each (distribution, extras) is visited once, so a cycle ends.
    """
    queue = [(record, frozenset(extras), None)]
    seen = {("localcanvas-gateway", frozenset(extras))}
    while queue:
        distribution, asked, parent = queue.pop(0)
        for item in distribution.requires or []:
            parts = split_requirement(item)
            if parts is None:
                return "the requirement {!r}{} cannot be checked here".format(
                    item, " of " + parent if parent else "")
            name, wanted_extras, clauses, marker = parts
            if marker:
                applies = marker_applies(marker, asked)
                if applies is None:
                    return "the requirement {!r}{} cannot be checked here".format(
                        item, " of " + parent if parent else "")
                if not applies:
                    continue
            if parent:
                where = " (needed by {})".format(parent)
            elif marker and not marker_applies(marker, ()):
                where = " (the {} extra)".format(", ".join(sorted(asked)))
            else:
                where = ""
            try:
                dependency = metadata.distribution(name)
            except metadata.PackageNotFoundError:
                return "{} is not installed{}".format(name, where)
            version = dependency.metadata.get("Version") or ""
            verdict = satisfies(version, clauses)
            if verdict is None:
                return "{} {} cannot be checked against {} here".format(
                    name, version, ",".join(clauses))
            if not verdict:
                return "{} {} is installed, and {} needs {}".format(
                    name, version, parent or "the gateway", ",".join(clauses))
            key = (name, frozenset(wanted_extras))
            if key not in seen:
                seen.add(key)
                queue.append((dependency, frozenset(wanted_extras), name))
    return None


#: What the scripts run, and therefore what has to import. Named from the
#: code, and the script suite holds this list to every `-m` target in
#: scripts/ (test_the_import_probe_covers_every_module_the_scripts_run):
RUNTIME_MODULES = (
    # `-m localcanvas_gateway`: start.ps1 serves with it, and the scripts'
    # configuration seam and QR command run through it (lib/Common.ps1).
    "localcanvas_gateway.__main__",
    # `-m localcanvas_gateway.workflows`: the workflow check and sync.
    "localcanvas_gateway.workflows.__main__",
    # ...whose `sync` command is imported only when it runs (workflows/cli.py).
    "localcanvas_gateway.workflows.sync.cli",
    # ...and the server, imported only when serving (__main__._uvicorn_serve).
    "uvicorn",
)


def runtime_import_failure():
    """Import every runtime module; the first failure, as a sentence, or None."""
    import contextlib
    import importlib
    for module in RUNTIME_MODULES:
        try:
            # A module that prints on import must not corrupt the one JSON line.
            with contextlib.redirect_stdout(sys.stderr):
                importlib.import_module(module)
        except BaseException as exc:  # SystemExit too: the answer is "reinstall"
            if isinstance(exc, KeyboardInterrupt):
                raise
            return "{} does not import ({}: {})".format(module, type(exc).__name__, exc)
    return None


# --------------------------------------------------------------------------
# The check
# --------------------------------------------------------------------------

def main(arguments):
    if not arguments:
        answer(False, "the health check was run without a gateway directory")
    gateway = os.path.abspath(arguments[0])
    extras = [canonical(extra) for extra in arguments[1:] if extra.strip()]
    if metadata is None:
        answer(False, "this Python has no importlib.metadata, so the installed gateway cannot be read")

    try:
        import localcanvas_gateway as package
    except Exception as exc:  # anything at all: the answer is "reinstall"
        answer(False, "the gateway does not import ({}: {})".format(type(exc).__name__, exc))
    imported_from = os.path.abspath(getattr(package, "__file__", "") or "")
    # First, because every answer below reads the package it imported: a
    # shadowing copy would otherwise be reported as whatever is wrong with it.
    inside = os.path.normcase(gateway).rstrip("\\/") + os.sep
    if not os.path.normcase(imported_from).startswith(inside):
        answer(False, "the gateway it imports is not this checkout's ({})".format(
            imported_from or "no file"), imported_from)

    pyproject = os.path.join(gateway, "pyproject.toml")
    try:
        tables = read_pyproject(pyproject)
    except OSError as exc:
        answer(False, "gateway/pyproject.toml could not be read ({})".format(exc), imported_from)
    project = tables.get("project", {})
    name = project.get("name")
    dependencies = project.get("dependencies")
    if not isinstance(name, str) or not name or not isinstance(dependencies, list):
        answer(False, "gateway/pyproject.toml could not be read here (no project name or "
               "dependency list)", imported_from)
    optional = {
        canonical(key): value
        for key, value in tables.get("project.optional-dependencies", {}).items()
    }
    if any(not isinstance(value, list) for value in optional.values()):
        answer(False, "gateway/pyproject.toml's optional dependencies could not be read here",
               imported_from)

    declared_version = project.get("version")
    if not isinstance(declared_version, str) or not declared_version:
        dynamic = project.get("dynamic") or []
        attribute = tables.get("tool.setuptools.dynamic", {}).get("version", "")
        found = re.search(r"attr\s*=\s*[\"']([A-Za-z0-9_.]+)[\"']", str(attribute))
        if "version" not in dynamic or not found:
            answer(False, "gateway/pyproject.toml's version could not be read here", imported_from)
        module, _, attr = found.group(1).rpartition(".")
        if module != package.__name__:
            answer(False, "gateway/pyproject.toml takes its version from {}, which this check "
                   "does not read".format(found.group(1)), imported_from)
        declared_version = getattr(package, attr, None)
        if not isinstance(declared_version, str) or not declared_version:
            answer(False, "the gateway in this checkout declares no {}".format(attr), imported_from)

    try:
        record = metadata.distribution(name)
    except metadata.PackageNotFoundError:
        answer(False, "there is no installed record of {} in this environment".format(name),
               imported_from)

    installed = record.metadata.get("Version") or ""
    if installed.strip().lower() != declared_version.strip().lower():
        answer(False, "the installed gateway is version {}, and this checkout is {}".format(
            installed or "(none)", declared_version), imported_from)

    declared_python = project.get("requires-python") or ""
    recorded_python = record.metadata.get("Requires-Python") or ""
    if normalised("python" + declared_python) != normalised("python" + recorded_python):
        answer(False, "the installed gateway was built for Python {}, and "
               "gateway/pyproject.toml now declares {}".format(
                   recorded_python or "(any)", declared_python or "(any)"), imported_from)

    wanted = {normalised(item): item for item in dependencies}
    for extra, items in optional.items():
        wanted.update({normalised(item, extra): item for item in items})
    recorded = {normalised(item): item for item in (record.requires or [])}
    if set(wanted) != set(recorded):
        added = sorted(wanted[key].split(";")[0].strip() for key in set(wanted) - set(recorded))
        removed = sorted(recorded[key].split(";")[0].strip() for key in set(recorded) - set(wanted))
        change = "; ".join(filter(None, (
            "now declared: " + ", ".join(added) if added else "",
            "no longer declared: " + ", ".join(removed) if removed else "")))
        answer(False, "gateway/pyproject.toml declares different dependencies from the "
               "installed gateway ({})".format(change), imported_from)

    unknown = [extra for extra in extras if extra not in optional]
    if unknown:
        answer(False, "gateway/pyproject.toml declares no extra named {}".format(
            ", ".join(unknown)), imported_from)

    problem = unsatisfied_requirement(record, extras)
    if problem:
        answer(False, problem, imported_from)

    problem = runtime_import_failure()
    if problem:
        answer(False, problem, imported_from)

    answer(True, "", imported_from)


if __name__ == "__main__":
    main(sys.argv[1:])
