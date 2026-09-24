#requires -Version 7.0
# LocalCanvas v0.1 requires PowerShell 7 or newer (README.md), so the host
# refuses this script under Windows PowerShell 5.1 before its body parses:
# nothing is read, written, started or changed by a 5.1 run. The helpers
# under lib/ are dot-sourced, not entry points, and deliberately keep their
# 5.1 coverage -- they carry no #requires.

<#
.SYNOPSIS
    The first command a new LocalCanvas user runs. It leaves the machine ready
    for scripts\start.ps1 and says so.

.DESCRIPTION
    Two commands, and nothing else, get a user who already runs ComfyUI from a
    fresh clone to a working gateway:

        pwsh .\scripts\setup.ps1
        pwsh .\scripts\start.ps1

    So this script does everything the second one needs: it chooses a supported
    Python, builds LocalCanvas's own .venv, installs the gateway into it,
    verifies the gateway it can import is THIS checkout, and writes the local
    configuration that start.ps1 reads. NOTHING here asks anyone to run
    `python -m venv`, `pip install`, `python -m` anything, to set PYTHONPATH, or
    to hand-write a line of YAML. The number of configuration files a user edits
    by hand is zero.

    IT ASKS TWO QUESTIONS, and a third only when an inference fails.

      1. "Do you start ComfyUI yourself, or should LocalCanvas start it?"  This
         one is asked FIRST because it collapses everything after it: in
         external mode comfy.root and the launcher are optional
         (gateway/localcanvas_gateway/config.py), and somebody who already runs
         ComfyUI happily is the external-mode user.
      2. "Where is your ComfyUI?"  Unanswerable any other way. There is no
         discovery code in this project and there will not be: docs/runtime.md
         forbids searching the machine, so this
         script scans no drive, walks no directory tree and reads no registry.
         It offers the optional bootstrap layer's own install location as a
         default WHEN THAT LOCATION VALIDATES, and validates whatever is typed.
      3. "Where are your workflows?"  Only when <ComfyUI>\user\default\workflows
         -- ComfyUI's own location for them -- is not there.

    Everything else is inferred, and asking it would be theatre: the display
    name from COMPUTERNAME, ComfyUI's address from ComfyUI's own default, the
    gateway's from docs/api.md, the launcher from the validated root, the
    workflow registry from config/local/, extra_args from nothing at all -- and
    the startup, media and prompt_translation sections are left out entirely,
    because every value in them equals the gateway's own default and they are
    twenty-seven lines a beginner must not have to read.

    IDEMPOTENT. A second run prints a status table and "Nothing to change." It
    never recreates a healthy environment, never rewrites a configuration file
    that is already there -- yours is yours, whatever is in it -- never touches a
    workflow, never downloads a model and never writes anything inside ComfyUI.

    IT NEVER WAITS FOR A PERSON WHO IS NOT THERE. Every question can be answered
    in advance by a parameter, and a session that cannot be asked -- a scheduled
    task, a -NonInteractive shell, a pipe -- is never prompted: it is told what
    is missing and which parameter supplies it, and it exits.

    Two rules from docs/runtime.md shape the environment half.

    Interpreter selection is explicit and observable. A Windows machine commonly
    has several Python installations and a bare `py` resolves to the NEWEST one,
    not a supported one -- so this script only ever uses an explicit `py -3.x`
    version selector or the path you pass in -PythonExe, and it prints the
    interpreter path and version it actually used. The versions it tries come
    from the WHOLE range gateway/pyproject.toml declares, floor and ceiling
    both, and an interpreter outside that range is refused BEFORE a virtual
    environment or pip exists (T-0282).

    Gateway dependencies are never installed into ComfyUI's Python. Every
    install below runs as `.venv\Scripts\python.exe -m pip`, so the only
    environment this script can write to is LocalCanvas's own.

.PARAMETER PythonExe
    Path to the base interpreter to build .venv/ from. When omitted, explicit
    `py -3.x` selectors are tried in order, lowest supported version first.

.PARAMETER VenvPath
    Where to build the environment. Defaults to .venv/ at the repository root,
    which is where every other script looks for it. Everything else is
    identical -- this is how a second environment is built without disturbing
    the one you are using.

.PARAMETER Config
    The runtime configuration to create, if it is not already there. Defaults to
    config\local\runtime.yaml, which is where start.ps1 looks. The workflow
    source list is written beside it, under the name sync-workflows.ps1 reads.

.PARAMETER Mode
    The answer to question 1, given in advance. External -- you start ComfyUI
    yourself; Managed -- LocalCanvas may start it for you.

.PARAMETER ComfyRoot
    The answer to question 2, given in advance: your ComfyUI installation. The
    folder holding main.py, or the folder holding that folder for a portable
    build. Both layouts are recognised; neither is guessed at.

.PARAMETER WorkflowSource
    The answer to question 3, given in advance: the folder your ComfyUI
    workflows are saved in. Only needed when it is not ComfyUI's own
    user\default\workflows.

.PARAMETER ComfyHost
    Where ComfyUI listens, when it is not ComfyUI's own 127.0.0.1.

.PARAMETER ComfyPort
    The port ComfyUI listens on, when it is not ComfyUI's own default.

.PARAMETER Recreate
    Delete and rebuild an existing .venv/. The delete is recursive, so the
    target must prove it is a virtual environment first: without a pyvenv.cfg
    at its root, -Recreate refuses and removes nothing. That is what stops a
    mistyped or constructed -VenvPath from taking a directory of yours with it.

.PARAMETER Dev
    Also install the gateway's test extra. On an environment that already has
    it, nothing is installed.

.PARAMETER SkipPipUpgrade
    Do not attempt to upgrade pip inside a newly created .venv/. An environment
    that already exists never has pip upgraded by this script.

.EXAMPLE
    .\scripts\setup.ps1
    .\scripts\setup.ps1 -Mode External -ComfyRoot 'C:\path\to\ComfyUI'
    .\scripts\setup.ps1 -PythonExe "C:\Python310\python.exe" -Recreate
#>
[CmdletBinding()]
param(
    [string]$PythonExe,
    [string]$VenvPath,
    [string]$Config,
    [ValidateSet('External', 'Managed')][string]$Mode,
    [string]$ComfyRoot,
    [string]$WorkflowSource,
    [string]$ComfyHost,
    [int]$ComfyPort,
    [switch]$Recreate,
    [switch]$Dev,
    [switch]$SkipPipUpgrade
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
# The two read-only answers about a ComfyUI on disk come from the optional
# bootstrap layer, which already has them and has them right:
# Find-LcComfyApplicationDirectory tests for main.py AS A FILE across both
# layouts, and Get-LcComfyInstallation classifies what is there with evidence.
# Dot-sourcing it defines functions and writes nothing -- that layer refuses
# every mutation outside an opened run -- and a second probe for "is this a
# ComfyUI" is exactly how two answers to one question come to disagree.
$script:BootstrapLibrary = Join-Path $PSScriptRoot '..\comfy\lib\Bootstrap.ps1'
if (Test-Path -LiteralPath $script:BootstrapLibrary -PathType Leaf) {
    . $script:BootstrapLibrary
}

$repoRoot = Get-LcRepoRoot
$venvPath = if ($VenvPath) { $VenvPath } else { Join-Path $repoRoot '.venv' }
$venvPython = if ($VenvPath) { Join-Path $VenvPath 'Scripts\python.exe' } else { Get-LcVenvPython }
$gatewayDir = Join-Path $repoRoot 'gateway'
$configPath = if ($Config) { $Config } else { Join-Path $repoRoot 'config\local\runtime.yaml' }

# ComfyUI's own defaults, and docs/api.md's for the gateway. Not preferences:
# the numbers those two projects ship with, which is why nobody is asked.
$script:DefaultComfyHost = '127.0.0.1'
$script:DefaultComfyPort = 8188
$script:DefaultGatewayHost = '0.0.0.0'
$script:DefaultGatewayPort = 7801

# The bound on creating a virtual environment. `python -m venv` unpacks a
# standard library and runs ensurepip; it is an operation rather than a
# question, so its number is not the version probe's.
$script:VenvCreateSeconds = 600
# The bound on one pip invocation. It may reach a package index over somebody
# else's network, so it is the largest number here -- and it is still finite,
# because an install that has stopped making progress is not one a person
# should have to recognise by watching a still screen.
$script:PipSeconds = 1800
# The bound on the environment check (scripts\lib\gateway_health.py). A
# question, but one that imports the gateway's entry modules and with them
# FastAPI and its tree -- measured at 1.5 to 4 seconds on a warm machine, more
# on a first import that writes bytecode -- so it has its own number rather
# than the version probe's. A check that does not answer in time is a
# reinstall, never a pass.
$script:HealthCheckSeconds = 120
$script:Installed = $false
# Set when the environment check still fails after a reinstall; see there.
$script:StillBroken = ''

# How many times a question that was answered with something unusable is asked
# again before the run gives up. Not unbounded: a loop nobody can leave is a
# hang wearing a prompt.
$script:MaxAnswerAttempts = 3

# Set beside a `throw` when the generic closing advice would be wrong. The
# leading case is the one this card exists for: an environment built on an
# unsupported interpreter cannot be fixed by running setup again, and telling
# somebody to do that is a wedge, not a remedy.
$script:FixHint = ''

$script:Changes = [System.Collections.Generic.List[string]]::new()
$script:Status = [System.Collections.Generic.List[pscustomobject]]::new()

function Add-Change {
    param([Parameter(Mandatory)][string]$What)
    $script:Changes.Add($What)
}

function Add-Status {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$State,
        [string]$Detail = ''
    )
    $script:Status.Add([pscustomobject]@{ Name = $Name; State = $State; Detail = $Detail })
}

# --------------------------------------------------------------------------
# Interpreters
# --------------------------------------------------------------------------

function Get-InterpreterInfo {
    <#
        Which interpreter is this, and what version?

        Through Invoke-LcExecutableProbe rather than the call operator (T-0299,
        T-0302): the standard input a candidate interpreter is handed is a pipe
        of our own and is closed before it can be read, the question carries a
        deadline, and a path that is not an executable fails in tens of
        milliseconds instead of going round Windows' shell-execute machinery.
        This script asks it of paths a user typed, which is exactly where a
        file that is not an interpreter turns up.

        $null when it did not answer as an interpreter, for any reason.
    #>
    param([Parameter(Mandatory)][string[]]$Command)
    # No quote character in the code: Windows PowerShell 5.1 drops an embedded
    # double quote from a native argument, and the probe then failed for every
    # interpreter (T-0248, measured). chr(46) is the dot.
    $probe = 'import sys;print(sys.executable);print(*sys.version_info[:3], sep=chr(46))'
    $exe = $Command[0]
    $rest = if ($Command.Length -gt 1) { @($Command[1..($Command.Length - 1)]) } else { @() }
    $result = Invoke-LcExecutableProbe -FilePath $exe -Arguments (@($rest) + @('-c', $probe)) `
        -Component 'The Python interpreter' -TimeoutSeconds $script:PythonVersionProbeSeconds `
        -WorkingDirectory $repoRoot
    if (-not $result.Exited -or $result.ExitCode -ne 0) { return $null }
    $lines = @("$($result.StandardOutput)" -split "`r?`n" |
        ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    if ($lines.Count -lt 2) { return $null }
    return [pscustomobject]@{ Path = $lines[0]; Version = $lines[1] }
}

function Get-SupportedRangeText {
    param($Floor)
    if ($Floor) { return $Floor.Specifier }
    return 'the range gateway/pyproject.toml declares'
}

function Get-SupportedVersionWords {
    <#
        The declared range as a person says it: "3.10 to 3.13", "3.10 or
        newer". Read from the same parsed gateway/pyproject.toml as everything
        else here -- a second, hand-written copy of the range is how the text
        and the gate come to disagree.
    #>
    param($Floor)
    if (-not $Floor) { return $null }
    $first = "$($Floor.Major).$($Floor.Minor)"
    if ((Test-LcHasProperty -Object $Floor -Name 'Ceiling') -and $Floor.Ceiling) {
        $candidates = @(Get-InterpreterCandidate -Floor $Floor)
        if ($candidates.Count -eq 0) { return $null }
        $last = "$($candidates[-1])".TrimStart('-')
        if ($last -eq $first) { return $first }
        return "$first to $last"
    }
    return "$first or newer"
}

function Get-InstallPythonAdvice {
    <#
        What to do on a machine with no usable Python: install one, from the
        one place that serves every supported version. The Windows installer
        from there also installs the `py` launcher this script selects with.
    #>
    param($Floor)
    $words = Get-SupportedVersionWords -Floor $Floor
    $which = if ($words) { "Python $words" } else { 'a Python inside ' + (Get-SupportedRangeText -Floor $Floor) }
    return ("Install $which from https://www.python.org/downloads/ (its Windows installer " +
        "includes the 'py' launcher), then run this again.")
}

function Assert-SupportedInterpreter {
    <#
        The WHOLE declared range, and before anything is built.

        This used to be Test-LcVersionAtLeast -- the FLOOR alone -- while the
        line above it printed the whole specifier. On a machine whose only
        Python is newer than the ceiling that stamped [ OK ] on the
        interpreter, built the environment, upgraded pip inside it, and let PIP
        deliver the refusal (T-0282, measured). Worse, the leftover environment
        was then waved through by every later run, over a remedy -- "run setup
        again" -- that could not possibly work.

        So the range is asked in full, it is asked at every gate, and it is
        asked before a directory exists.
    #>
    param(
        [Parameter(Mandatory)][string]$Version,
        $Floor,
        [Parameter(Mandatory)][string]$What,
        [string]$Where = '',
        [string]$Fix = ''
    )
    if (Test-LcPythonVersionSupported -Version $Version -Range $Floor) { return }
    $range = Get-SupportedRangeText -Floor $Floor
    $message = "${What}: Python $Version. The LocalCanvas gateway supports $range " +
        '(declared in gateway/pyproject.toml).'
    if ($Where) { $message = "$message`n$Where" }
    # The remedy goes in ONE place -- the failure block's fix line -- rather
    # than being printed twice under the same [FAIL].
    if ($Fix) { $script:FixHint = $Fix }
    throw $message
}

function Resolve-ExplicitInterpreter {
    <#
        Validate -PythonExe as soon as it is given, whether or not .venv
        already exists. An interpreter the user named explicitly is a request,
        and a request that cannot be honoured is said out loud rather than
        quietly ignored -- including when the reason it cannot be honoured is
        its version, which is checked HERE, before anything has been built.
    #>
    param($Floor)
    if (-not $PythonExe) { return $null }
    if (-not (Test-Path -LiteralPath $PythonExe -PathType Leaf)) {
        throw "The interpreter you passed in -PythonExe does not exist: $PythonExe"
    }
    $resolved = (Resolve-Path -LiteralPath $PythonExe).Path
    $info = Get-InterpreterInfo -Command @($resolved)
    if (-not $info) { throw "'$PythonExe' did not answer as a Python interpreter." }
    Assert-SupportedInterpreter -Version $info.Version -Floor $Floor `
        -What 'The interpreter you passed in -PythonExe is not supported' -Where "Interpreter: $($info.Path)" `
        -Fix 'Pass -PythonExe an interpreter inside that range, or install one and re-run without it. NOTHING has been created.'
    return [pscustomobject]@{ Info = $info; Selector = "-PythonExe $resolved" }
}

function Get-InterpreterCandidate {
    <#
        The `py -3.x` selectors worth trying, LOWEST FIRST -- and no higher
        than the declared ceiling.

        The ceiling half is the fix (T-0282). This used to be "the floor plus
        six", an offset with nothing behind it, so on a declared >=3.10,<3.14 it
        happily tried 3.14, 3.15 and 3.16 -- versions pip refuses -- while
        Get-LcSupportedPythonFloor had parsed the ceiling all along and nothing
        read it. A candidate list that can produce an interpreter the install
        will reject is not a candidate list.
    #>
    param($Floor)
    if (-not $Floor) { return @('-3.10', '-3.11', '-3.12', '-3.13') }
    $last = $Floor.Minor + 6
    if ((Test-LcHasProperty -Object $Floor -Name 'Ceiling') -and $Floor.Ceiling) {
        $ceiling = $Floor.Ceiling
        if ($ceiling.Major -eq $Floor.Major) {
            $last = if ($ceiling.Inclusive) { $ceiling.Minor } else { $ceiling.Minor - 1 }
        } elseif ($ceiling.Major -lt $Floor.Major) {
            $last = $Floor.Minor - 1
        }
    }
    $candidates = @()
    for ($minor = $Floor.Minor; $minor -le $last; $minor++) {
        $candidates += "-$($Floor.Major).$minor"
    }
    return $candidates
}

function Resolve-BaseInterpreter {
    param($Floor, $Explicit)

    if ($Explicit) { return $Explicit }

    $candidates = @(Get-InterpreterCandidate -Floor $Floor)
    $range = Get-SupportedRangeText -Floor $Floor
    if ($candidates.Count -eq 0) {
        throw ("gateway/pyproject.toml declares $range, and no Python version satisfies it. " +
            'Nothing has been created.')
    }

    if (-not (Get-Command 'py' -ErrorAction SilentlyContinue)) {
        # Most often this is a machine with no Python at all, and somebody on
        # it does not need to be told about -PythonExe first -- they need to be
        # told to install one (T-0352, F3). The alternative comes second, for
        # the person who does have a Python that `py` cannot see.
        $script:FixHint = (Get-InstallPythonAdvice -Floor $Floor) + ' ' +
            "Or, if a Python inside $range is already installed, re-run with -PythonExe " +
            'pointing at its python.exe. NOTHING has been created.'
        throw ("No Python was found: the Python launcher 'py' is not on PATH, so there is " +
            'no way to select a supported version.')
    }

    foreach ($selector in $candidates) {
        $info = Get-InterpreterInfo -Command @('py', $selector)
        if (-not $info) { continue }
        # Belt as well as braces: the selector says which version was ASKED
        # for, and this says which one answered.
        if (-not (Test-LcPythonVersionSupported -Version $info.Version -Range $Floor)) { continue }
        return [pscustomobject]@{ Info = $info; Selector = "py $selector" }
    }
    $script:FixHint = ((Get-InstallPythonAdvice -Floor $Floor) + ' ' +
        'Or re-run with -PythonExe naming one you already have. NOTHING has been created.')
    throw ("None of the supported Python versions is installed: " +
        ($candidates -join ', ') + ". The gateway supports $range (gateway/pyproject.toml).")
}

function Invoke-VenvPip {
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$BestEffort)
    # Always through .venv's own interpreter. This is the structural reason a
    # gateway dependency can never land in ComfyUI's Python.
    #
    # Through the probe boundary as well (T-0302): pip is an operation rather
    # than a question, so it gets a bound of its own rather than the version
    # probe's -- but it gets the same closed standard input, so a pip that
    # decides to ask for a credential cannot silently hold a console for ever,
    # and the same rule about what may be stopped: only the process this call
    # started.
    $probe = Invoke-LcExecutableProbe -FilePath $venvPython -Arguments (@('-m', 'pip') + $Arguments) `
        -Component 'pip' -TimeoutSeconds $script:PipSeconds -WorkingDirectory $repoRoot
    $said = @(@("$($probe.StandardOutput)" -split "`r?`n") + @("$($probe.StandardError)" -split "`r?`n") |
        Where-Object { $_ -and $_.Trim() })
    if ($probe.Exited -and $probe.ExitCode -eq 0) { return [pscustomobject]@{ Ok = $true; Said = $said } }
    if ($BestEffort) { return [pscustomobject]@{ Ok = $false; Said = $said } }
    $what = if ($probe.Failure) { $probe.Failure } else { "pip $($Arguments -join ' ') failed with exit code $($probe.ExitCode)." }
    # pip's own words, not a summary of them: when it refuses a Python version
    # or cannot reach an index, its sentence is the one that helps.
    $tail = @($said | Select-Object -Last 12)
    throw ((@($what) + $tail) -join "`n")
}

function Test-GatewayHealth {
    <#
        Does the environment that is already here need an install at all?

        { Healthy; Reason; ImportedFrom }. Asked of scripts\lib\gateway_health.py
        through the environment's own interpreter, under the probe boundary and
        its own deadline ($script:HealthCheckSeconds). It runs no pip and opens no
        socket; see that file for exactly what it checks and what it does not.

        Every answer that is not a clear "yes" is a "no", with a reason: a
        checker that is missing, that times out or that prints something other
        than its one JSON line costs one reinstall, which is what every run did
        before this check existed. And "yes" additionally has to import the
        gateway from THIS checkout, asked by the same function that asks it
        after an install, so the two answers cannot disagree.
    #>
    param([string[]]$Extras = @())
    $unhealthy = { param($Why) [pscustomobject]@{ Healthy = $false; Reason = $Why; ImportedFrom = '' } }
    $checker = Join-Path $PSScriptRoot 'lib\gateway_health.py'
    if (-not (Test-Path -LiteralPath $checker -PathType Leaf)) {
        return (& $unhealthy "the environment check is missing from this checkout ($checker)")
    }
    $probe = Invoke-LcExecutableProbe -FilePath $venvPython `
        -Arguments (@($checker, $gatewayDir) + @($Extras)) `
        -Component 'The environment check' -TimeoutSeconds $script:HealthCheckSeconds `
        -WorkingDirectory $repoRoot
    if (-not $probe.Exited -or $probe.ExitCode -ne 0) {
        $why = if ($probe.Failure) { $probe.Failure } else { "it exited with code $($probe.ExitCode)" }
        return (& $unhealthy "the environment could not be checked ($why)")
    }
    $line = @("$($probe.StandardOutput)" -split "`r?`n" | Where-Object { "$_".Trim() }) | Select-Object -Last 1
    try {
        $said = "$line" | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return (& $unhealthy 'the environment check did not answer')
    }
    foreach ($name in @('healthy', 'reason', 'imported_from')) {
        if (-not (Test-LcHasProperty -Object $said -Name $name)) {
            return (& $unhealthy 'the environment check did not answer')
        }
    }
    if ($said.healthy -ne $true) {
        $why = "$($said.reason)".Trim()
        if (-not $why) { $why = 'the environment check found a problem it did not name' }
        return (& $unhealthy $why)
    }
    $from = "$($said.imported_from)"
    if (-not $from -or -not (Test-LcPathIsUnder -Path $from -Root $gatewayDir)) {
        return (& $unhealthy "the gateway it imports is not this checkout's ($from)")
    }
    return [pscustomobject]@{ Healthy = $true; Reason = ''; ImportedFrom = $from }
}

# --------------------------------------------------------------------------
# Questions -- informational, never blocking
# --------------------------------------------------------------------------

function Test-CanAsk {
    <#
        Is there a person on the other end of this run?

        Two interlocks, because either alone lets a run hang or a run decide.
        A redirected standard input is answered without asking at all: Read-Host
        on a closed pipe returns an empty string forever, which is a loop rather
        than an answer. And the ask itself is inside a try/catch, because
        -NonInteractive throws instead -- the convention this repository already
        has (comfy/lib/Models.ps1, scripts/strict-lan.ps1).

        The difference in KIND from those two is deliberate. They gate a
        consequential action -- a download, a firewall rule -- and correctly
        refuse when they cannot ask, because nobody being there to say no has
        never meant yes. The questions here choose where a file is, so a session
        that cannot be asked is told exactly which parameter carries the answer
        instead of being made to guess.
    #>
    if ([Console]::IsInputRedirected) { return $false }
    return $true
}

function Request-Answer {
    <#
        One question, or $null when this session has nobody to ask.
        $null is a real answer here and is never confused with an empty one.
    #>
    param([Parameter(Mandatory)][string]$Prompt)
    if (-not (Test-CanAsk)) { return $null }
    try {
        return "$(Read-Host $Prompt)".Trim()
    } catch {
        return $null
    }
}

function Stop-ForMissingAnswer {
    param(
        [Parameter(Mandatory)][string]$What,
        [Parameter(Mandatory)][string]$Parameters
    )
    $script:FixHint = "Run it from a PowerShell 7 console, or pass the answer: $Parameters"
    throw ("$What, and this session cannot be asked for it (its standard input is not a " +
        'console). Nothing has been written to config.')
}

# --------------------------------------------------------------------------
# ComfyUI, as it is on disk
# --------------------------------------------------------------------------

function Get-BootstrapComfyRoot {
    <#
        Where comfy\setup.ps1 installs when it is not told otherwise.

        Offered as question 2's default only when a ComfyUI really is there, so
        somebody who used the bootstrap layer answers that question by pressing
        Enter. This location is DEFINED by Get-LcDefaultComfyRoot in
        comfy/setup.ps1, which is an entry point and cannot be dot-sourced;
        keeping the two in step is the subject of its own card rather than
        something to paper over with a search.
    #>
    $base = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
    if (-not $base) { return $null }
    return (Join-Path (Join-Path $base 'LocalCanvas') 'comfyui')
}

function Test-ComfyRoot {
    <#
        Is there a ComfyUI at this path? The bootstrap layer's answer, verbatim.

        { Ok; AppDirectory; Reason }. scripts\doctor.ps1 asks a weaker question
        of the same path -- Test-Path -PathType Container, which any empty
        folder satisfies -- and an empty folder is precisely the answer a person
        gives when they meant a different drive.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $failed = [pscustomobject]@{ Ok = $false; AppDirectory = $null; Reason = '' }
    if (-not (Get-Command 'Get-LcComfyInstallation' -ErrorAction SilentlyContinue)) {
        $failed.Reason = ("The ComfyUI inspection helpers are missing: $($script:BootstrapLibrary) " +
            'is not in this checkout, so a path cannot be validated. Restore it and run this again.')
        return $failed
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        $failed.Reason = "there is nothing at that path."
        return $failed
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        $failed.Reason = "that is a file, not a folder."
        return $failed
    }
    $full = (Resolve-Path -LiteralPath $Path).Path
    $installation = Get-LcComfyInstallation -Root $full
    if ($installation.AppDirectory) {
        return [pscustomobject]@{ Ok = $true; AppDirectory = $installation.AppDirectory; Reason = '' }
    }
    $evidence = @($installation.Evidence)
    $reason = "there is no main.py in it, and none in a ComfyUI folder inside it."
    if ($evidence.Count -gt 0) { $reason = "$reason What is there: $($evidence -join '; ')." }
    $failed.Reason = $reason
    return $failed
}

function Resolve-ComfyLauncher {
    <#
        How ComfyUI is started, derived from the root that was just validated.

        THE EXAMPLE FILE CANNOT DO THIS (F6). config/examples/runtime.example.yaml
        shipped `script: ComfyUI/main.py`, which is right for a portable build
        and wrong for a plain clone -- and against the clone the doctor printed a
        path ending ...\ComfyUI\ComfyUI\main.py, because both halves of the
        answer were relative to a root whose layout nobody had looked at. The
        layout is a fact about the disk, so it is read off the disk.

        Returns { Executable; Script } with both values relative to the root,
        which is how the gateway resolves them -- or $null when no interpreter
        is there to be found.

        $null rather than "python", which is what the example file offers for a
        ComfyUI on system Python and which DOES NOT WORK: the gateway resolves a
        relative launcher path against comfy.root (config.py, _under), so a bare
        "python" becomes <root>\python and names nothing. This script does not
        write a value it has not seen on disk.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$AppDirectory
    )
    $mainScript = Get-RelativeUnder -Root $Root -Path (Join-Path $AppDirectory 'main.py')
    foreach ($candidate in @(
            'python_embeded\python.exe',
            (Join-Path (Get-RelativeUnder -Root $Root -Path $AppDirectory) 'venv\Scripts\python.exe'),
            (Join-Path (Get-RelativeUnder -Root $Root -Path $AppDirectory) '.venv\Scripts\python.exe'),
            'venv\Scripts\python.exe',
            '.venv\Scripts\python.exe')) {
        $full = Join-Path $Root $candidate
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            return [pscustomobject]@{ Executable = $candidate; Script = $mainScript }
        }
    }
    return $null
}

function Test-SamePath {
    <#
        Do these two strings name the same place? A path question, not a string
        one: 'x\workflows' and 'x\.\workflows' are the same directory and do
        not compare equal, and neither has to exist to be asked about.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Left,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Right
    )
    if (-not $Left -or -not $Right) { return $false }
    try {
        $one = [System.IO.Path]::GetFullPath($Left).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
        $two = [System.IO.Path]::GetFullPath($Right).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    } catch {
        return $false
    }
    return $one.Equals($two, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-RelativeUnder {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Path)
    $base = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full.Length -gt ($base.Length + 1) -and
        $full.StartsWith($base + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($base.Length + 1)
    }
    return $full
}

# --------------------------------------------------------------------------
# The documents -- generated, never a template with holes in it
# --------------------------------------------------------------------------

function ConvertTo-YamlText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return '"' + ($Value -replace '\\', '\\' -replace '"', '\"') + '"'
}

function ConvertTo-YamlPath {
    <#
        A Windows path as a YAML scalar. Forward slashes, which Windows accepts
        everywhere and which cost no escaping, so a path with a space, a
        bracket or a backtick in it survives being read back.
    #>
    param([Parameter(Mandatory)][string]$Value)
    return ConvertTo-YamlText (($Value -replace '\\', '/'))
}

function New-RuntimeDocument {
    param(
        [Parameter(Mandatory)][bool]$ManageComfy,
        [string]$Root,
        $Launcher,
        [Parameter(Mandatory)][string]$ComfyHostName,
        [Parameter(Mandatory)][int]$ComfyPortNumber,
        [Parameter(Mandatory)][string]$Registry,
        [Parameter(Mandatory)][string]$DisplayName
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# LocalCanvas runtime configuration.')
    $lines.Add('#')
    $lines.Add('# Written by scripts\setup.ps1. It is yours now: setup never rewrites a file')
    $lines.Add('# that is already here, so edit it freely. config/local/ is gitignored, so')
    $lines.Add('# nothing below ever enters the repository.')
    $lines.Add('#')
    $lines.Add('# The startup, media and prompt_translation sections are left out on purpose:')
    $lines.Add('# every value in them would equal the gateway''s own default. See')
    $lines.Add('# config/examples/runtime.example.yaml for what they can hold.')
    $lines.Add('')
    $lines.Add('runtime:')
    if ($ManageComfy) {
        $lines.Add('  # LocalCanvas may start ComfyUI, and only ever stops one it started itself.')
        $lines.Add('  manage_comfy: true')
    } else {
        $lines.Add('  # You start ComfyUI yourself. LocalCanvas never launches it and never stops')
        $lines.Add('  # one it did not start; it checks that it is reachable and nothing more.')
        $lines.Add('  manage_comfy: false')
    }
    $lines.Add('')
    $lines.Add('comfy:')
    if ($Root) {
        $lines.Add('  root: ' + (ConvertTo-YamlPath $Root))
    }
    $lines.Add('  host: ' + (ConvertTo-YamlText $ComfyHostName))
    $lines.Add('  port: ' + $ComfyPortNumber)
    if ($Launcher) {
        $lines.Add('  # Both paths are relative to root, and were read off the installation above.')
        $lines.Add('  launcher:')
        $lines.Add('    executable: ' + (ConvertTo-YamlPath $Launcher.Executable))
        $lines.Add('    script: ' + (ConvertTo-YamlPath $Launcher.Script))
    }
    $lines.Add('  # Extra ComfyUI arguments, passed through and not interpreted. Empty, because')
    $lines.Add('  # nothing here knows anything about your graphics card.')
    $lines.Add('  extra_args: []')
    $lines.Add('')
    $lines.Add('workflows:')
    $lines.Add('  registry: ' + (ConvertTo-YamlPath $Registry))
    $lines.Add('')
    $lines.Add('gateway:')
    $lines.Add('  # The only LAN-facing surface. Allow this port through Windows Firewall on')
    $lines.Add('  # Private networks only. See docs/privacy-security.md.')
    $lines.Add('  host: ' + (ConvertTo-YamlText $script:DefaultGatewayHost))
    $lines.Add('  port: ' + $script:DefaultGatewayPort)
    $lines.Add('')
    $lines.Add('identity:')
    $lines.Add('  # Shown in the app when it is looking for this PC.')
    $lines.Add('  display_name: ' + (ConvertTo-YamlText $DisplayName))
    $lines.Add('')
    return ($lines -join [Environment]::NewLine)
}

function New-WorkflowSourcesDocument {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Definitions,
        [Parameter(Mandatory)][string]$ImportedApi,
        [Parameter(Mandatory)][string]$Inventory
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# Where LocalCanvas reads your ComfyUI workflows from.')
    $lines.Add('#')
    $lines.Add('# Written by scripts\setup.ps1, and yours to edit. The folders under sources')
    $lines.Add('# are the ONLY folders LocalCanvas ever reads, it never looks above one, and')
    $lines.Add('# your workflow files are only ever READ - nothing here renames, moves,')
    $lines.Add('# deletes, reformats or rewrites one.')
    $lines.Add('#')
    $lines.Add('# Then:  .\scripts\sync-workflows.ps1 -DryRun    # look, change nothing')
    $lines.Add('#        .\scripts\sync-workflows.ps1            # look, and record what was found')
    $lines.Add('')
    $lines.Add('sources:')
    $lines.Add('  - path: ' + (ConvertTo-YamlPath $Source))
    $lines.Add('    recursive: true')
    $lines.Add('')
    $lines.Add('output:')
    $lines.Add('  definitions: ' + (ConvertTo-YamlPath $Definitions))
    $lines.Add('  imported_api: ' + (ConvertTo-YamlPath $ImportedApi))
    $lines.Add('  inventory: ' + (ConvertTo-YamlPath $Inventory))
    $lines.Add('')
    return ($lines -join [Environment]::NewLine)
}

function Write-NewFile {
    <#
        Create a file that is not there. It NEVER overwrites: every caller has
        already decided the file is absent, and this is the second lock on that
        decision rather than a restatement of it.
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
    if (Test-Path -LiteralPath $Path) {
        throw "Refused: $Path already exists, and setup does not overwrite a configuration file."
    }
    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
    # No BOM: the loader reads UTF-8, and a BOM in a YAML document is one more
    # thing that can go wrong in a file nobody was supposed to have to look at.
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Get-ConfiguredPath {
    <#
        A path to write into a configuration document.

        Relative when the document sits in this repository's own config\local,
        because that is what both loaders measure a relative path from and it is
        the form the tracked examples use; absolute otherwise, because a
        document somewhere else has no repository above it to be measured from.
    #>
    param(
        [Parameter(Mandatory)][string]$ConfigDirectory,
        [Parameter(Mandatory)][string]$Relative
    )
    $standard = Join-Path $repoRoot 'config\local'
    if (Test-LcPathIsUnder -Path $ConfigDirectory -Root $standard) {
        return "config/local/$Relative"
    }
    return (Join-Path $ConfigDirectory $Relative)
}

function Resolve-ConfiguredPath {
    param([Parameter(Mandatory)][string]$Value)
    if ([System.IO.Path]::IsPathRooted($Value)) { return $Value }
    return (Join-Path $repoRoot ($Value -replace '/', '\'))
}

# --------------------------------------------------------------------------
# The run
# --------------------------------------------------------------------------

try {
    Write-LcBanner
    Write-LcInfo 'LocalCanvas setup'
    Write-LcDetail "Repository: $repoRoot"
    Write-Host ''

    if (-not (Test-Path -LiteralPath $gatewayDir -PathType Container)) {
        throw "The gateway package directory is missing: $gatewayDir"
    }

    $floor = Get-LcSupportedPythonFloor
    if ($floor) {
        # THE WHOLE SPECIFIER, not the floor of it. This line used to print
        # ">= 3.10" while the metadata declared ">=3.10,<3.14", so on a machine
        # whose default `py` is 3.14 it told the user their interpreter was
        # supported and pip then refused it (T-0173, B3). The text comes out of
        # gateway/pyproject.toml itself, so the two cannot drift.
        Write-LcInfo "Supported Python: $($floor.Specifier) (from gateway/pyproject.toml)"
    } else {
        Write-LcWarn 'Could not read the supported Python range from gateway/pyproject.toml; pip will enforce it.'
    }

    # BEFORE ANY VENV AND BEFORE ANY PIP. An interpreter the user named that is
    # outside the declared range is refused here, with nothing created.
    $explicitBase = Resolve-ExplicitInterpreter -Floor $floor

    if ($Recreate -and (Test-Path -LiteralPath $venvPath)) {
        <#
            -VenvPath is an arbitrary string from the command line and the
            next line is a recursive, unrecoverable delete. So the target has
            to prove what it is before it is removed, rather than the caller
            being trusted to have meant it.

            pyvenv.cfg is that proof: `python -m venv` writes one at the root
            of every environment it creates, and no ordinary directory of a
            user's has one. It is cheap, it needs nothing installed, and it
            fails in the safe direction -- a real environment without it is
            not one this script built, and refusing to delete a directory is
            never the damaging answer.
        #>
        $venvMarker = Join-Path $venvPath 'pyvenv.cfg'
        if (-not (Test-Path -LiteralPath $venvMarker -PathType Leaf)) {
            throw ("Refused: -Recreate will not delete $venvPath because it is not a " +
                'virtual environment. There is no pyvenv.cfg in it, and every environment ' +
                'built by `python -m venv` has one. -Recreate deletes its target ' +
                'recursively, so a path that cannot prove it is an environment is left ' +
                'alone. NOTHING has been deleted.')
        }
        Write-LcInfo "Removing existing environment: $venvPath"
        Remove-Item -LiteralPath $venvPath -Recurse -Force
        Add-Change 'the existing environment was removed'
    }

    $venvExists = Test-Path -LiteralPath $venvPython -PathType Leaf
    if ($venvExists) {
        $existing = Get-InterpreterInfo -Command @($venvPython)
        if (-not $existing) {
            $script:FixHint = 'Re-run with -Recreate to rebuild the environment.'
            throw ("$venvPython exists but does not answer as a Python interpreter.")
        }
        # THE SECOND WEDGE, and the one that is not in T-0282. A .venv built on
        # an unsupported interpreter was waved through here by a floor-only
        # check, over the advice "run setup again" -- the one action that could
        # never work, since running setup again reused the same environment.
        # The environment has to be REBUILT, so that is what it says.
        Assert-SupportedInterpreter -Version $existing.Version -Floor $floor `
            -What "The environment at $venvPath is built on an unsupported interpreter" `
            -Where "Interpreter: $venvPython" `
            -Fix ('Running setup again cannot change that -- it would reuse this environment. ' +
                'Rebuild it on a supported interpreter: scripts\setup.ps1 -Recreate ' +
                '(add -PythonExe if `py` cannot find one). NOTHING has been changed.')
        Write-LcOk "Environment already present - reusing it"
        Write-LcDetail "Interpreter: $venvPython"
        Write-LcDetail "Version:     Python $($existing.Version)"
        Add-Status -Name 'Python environment' -State 'present' -Detail "Python $($existing.Version)"
        if ($explicitBase) {
            Write-LcInfo "-PythonExe names $($explicitBase.Info.Path) (Python $($explicitBase.Info.Version))"
            Write-LcDetail 'The existing .venv was kept. Re-run with -Recreate to rebuild it on that interpreter.'
        }
    } else {
        Write-LcInfo 'Selecting a base interpreter...'
        $base = Resolve-BaseInterpreter -Floor $floor -Explicit $explicitBase
        # A third gate for the same range: the selector said which version was
        # asked for, this says which one answered, and neither creates anything.
        Assert-SupportedInterpreter -Version $base.Info.Version -Floor $floor `
            -What 'The interpreter that was selected is not supported' -Where "Interpreter: $($base.Info.Path)" `
            -Fix 'Re-run with -PythonExe naming an interpreter inside that range. NOTHING has been created.'
        Write-LcOk "Base interpreter selected via $($base.Selector)"
        Write-LcDetail "Interpreter: $($base.Info.Path)"
        Write-LcDetail "Version:     Python $($base.Info.Version)"
        Write-Host ''

        Write-LcInfo "Creating $venvPath ..."
        $created = Invoke-LcExecutableProbe -FilePath $base.Info.Path -Arguments @('-m', 'venv', $venvPath) `
            -Component 'Creating the virtual environment' -TimeoutSeconds $script:VenvCreateSeconds `
            -WorkingDirectory $repoRoot
        if (-not $created.Exited -or $created.ExitCode -ne 0) {
            $what = if ($created.Failure) { $created.Failure } else { "Creating the virtual environment failed with exit code $($created.ExitCode)." }
            $said = @("$($created.StandardError)" -split "`r?`n" |
                Where-Object { $_ -and $_.Trim() } | Select-Object -Last 8)
            throw ((@($what) + $said) -join "`n")
        }
        if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
            throw "The virtual environment was created but $venvPython is missing."
        }
        Write-LcOk 'Environment created'
        Add-Change 'the Python environment was created'
        $newVersion = Get-InterpreterInfo -Command @($venvPython)
        Add-Status -Name 'Python environment' -State 'created' `
            -Detail $(if ($newVersion) { "Python $($newVersion.Version)" } else { '' })
    }

    <#
        INSTALL ONLY WHAT IS MISSING (T-0352, F1).

        Every run used to upgrade pip and run `pip install --editable gateway`.
        The editable build resolves setuptools from the package index in an
        isolated build environment, so a second run on a machine that was
        fully set up and had no network failed with exit 1 -- measured -- and
        a run that did reach the index reinstalled a gateway that was already
        there. "Nothing to change." was printed over a reinstall.

        So an environment that already exists is ASKED first, locally, by
        scripts\lib\gateway_health.py run with the environment's own
        interpreter: does the gateway import from this checkout, does its
        installed record match gateway/pyproject.toml as it is now (version,
        requires-python, declared dependencies), and are the dependencies --
        and, with -Dev, the test extra's -- installed at versions their
        specifiers accept. No pip, no network. Only a "no" installs, and the
        reason is printed in one line. pip itself is upgraded only in an
        environment this run just created.
    #>
    $extras = @(if ($Dev) { 'test' })
    $health = $null
    if ($venvExists) { $health = Test-GatewayHealth -Extras $extras }

    if ($health -and $health.Healthy) {
        $importedFrom = $health.ImportedFrom
        Write-Host ''
        Write-LcOk 'Gateway already installed from this checkout - nothing to install'
        if ($Dev) { Write-LcDetail 'The test extra (-Dev) is installed as well.' }
    } else {
        Write-Host ''
        if (-not $venvExists -and -not $SkipPipUpgrade) {
            Write-LcInfo 'Upgrading pip inside .venv ...'
            if ((Invoke-VenvPip -Arguments @('install', '--upgrade', 'pip') -BestEffort).Ok) {
                Write-LcOk 'pip up to date'
            } else {
                Write-LcWarn 'pip could not be upgraded; continuing with the version already installed.'
            }
            Write-Host ''
        }

        $target = if ($Dev) { "$gatewayDir[test]" } else { $gatewayDir }
        if ($health) {
            # One line, and the reason is the checker's own sentence.
            Write-LcInfo "Reinstalling the LocalCanvas gateway into .venv: $($health.Reason)."
        } else {
            Write-LcInfo 'Installing the LocalCanvas gateway into .venv ...'
        }
        Write-LcDetail "Source: $target"
        if (-not $venvExists) {
            # Said only when it is true. A first run fetches the whole dependency
            # set; a later one usually finds everything already satisfied, and
            # telling somebody to expect minutes every time teaches them to stop
            # reading the line.
            Write-LcDetail 'This is a first run, so the dependencies are fetched now: it takes a few minutes.'
        }
        [void](Invoke-VenvPip -Arguments @('install', '--editable', $target))
        $script:Installed = $true
        if ($health) { Add-Change "the gateway was reinstalled ($($health.Reason))" }

        $import = Invoke-LcExecutableProbe -FilePath $venvPython `
            -Arguments @('-c', 'import localcanvas_gateway as g; print(g.__file__)') `
            -Component 'The installed gateway' -TimeoutSeconds $script:PythonVersionProbeSeconds `
            -WorkingDirectory $repoRoot
        $importedFrom = @("$($import.StandardOutput)" -split "`r?`n" |
            ForEach-Object { "$_".Trim() } | Where-Object { $_ }) | Select-Object -First 1
        if (-not $import.Exited -or $import.ExitCode -ne 0 -or -not $importedFrom) {
            $said = if ($import.Failure) { $import.Failure } else { "$($import.StandardError)".Trim() }
            throw ("The gateway package was installed but cannot be imported from " +
                "$venvPython. pip said the install succeeded; the import said: $said")
        }
    }
    <#
        THE GATEWAY THIS RUN INSTALLED, OR SOMEBODY ELSE'S?

        pip reporting success is not the same statement as "this checkout is
        what will be imported". A gateway frozen into site-packages by an older
        `pip install .`, or a directory on PYTHONPATH, shadows an editable
        install without a word -- and then every script here runs code that is
        not the code in front of you, which is the worst kind of wrong because
        the version number still looks right. So the import is asked where it
        came from, and the answer has to be inside this repository's gateway/.
    #>
    if (-not (Test-LcPathIsUnder -Path $importedFrom -Root $gatewayDir)) {
        $script:FixHint = ('Remove the other installation from that environment, or clear PYTHONPATH, ' +
            'and run this again. NOTHING in this checkout has been changed.')
        throw ("The gateway that $venvPython imports is not the one in this checkout." + "`n" +
            "Imported from: $importedFrom" + "`n" +
            "Expected under: $gatewayDir" + "`n" +
            'A frozen copy in site-packages or a directory on PYTHONPATH is shadowing it, so ' +
            'every script here would run code that is not the code in this repository.')
    }
    $installedVersion = Get-InterpreterInfo -Command @($venvPython)
    if (-not ($health -and $health.Healthy)) { Write-LcOk 'Gateway installed' }
    Write-LcDetail "Imported from: $importedFrom"
    if ($health -and -not $health.Healthy) {
        # Asked again after a REINSTALL. `pip install --editable` does not
        # replace a package whose record says it is installed, so some damage
        # -- a dependency's files gone while its dist-info stays -- survives
        # it. Said here, with the remedy that does work, rather than left to
        # surface as a start that fails; not a failure of this run, because
        # the check can be wrong where pip is right.
        $after = Test-GatewayHealth -Extras $extras
        if (-not $after.Healthy) {
            $script:StillBroken = $after.Reason
            Write-LcWarn "After the reinstall, the environment check still reports: $($after.Reason)."
            Write-LcDetail 'pip does not replace a package it believes is installed. Rebuild the environment:'
            Write-LcDetail '    pwsh .\scripts\setup.ps1 -Recreate'
        }
    }
    Add-Status -Name 'Gateway' -State 'installed' -Detail $importedFrom

    # ----------------------------------------------------------------------
    # Configuration
    # ----------------------------------------------------------------------

    Write-Host ''
    $configDirectory = Split-Path -Parent $configPath
    if (-not $configDirectory) { $configDirectory = $repoRoot }
    $sourcesPath = Join-Path $configDirectory 'workflow-sources.yaml'
    $registryValue = Get-ConfiguredPath -ConfigDirectory $configDirectory -Relative 'workflows'

    $comfyHostName = if ($ComfyHost) { $ComfyHost } else { $script:DefaultComfyHost }
    $comfyPortNumber = if ($ComfyPort -gt 0) { $ComfyPort } else { $script:DefaultComfyPort }

    $comfyAppDirectory = $null
    $validatedRoot = $null

    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        Write-LcOk 'Configuration already present - leaving it exactly as it is'
        Write-LcDetail "File: $configPath"
        Add-Status -Name 'Configuration' -State 'present' -Detail $configPath
    } else {
        Write-LcInfo 'No configuration yet. Two questions, and then you are done.'
        Write-Host ''

        # -- question 1 ----------------------------------------------------
        $manageComfy = $false
        if ($Mode) {
            $manageComfy = ($Mode -eq 'Managed')
            Write-LcOk "ComfyUI: -Mode $Mode was given, so nothing was asked."
        } else {
            Write-Host '       Question 1 of 2 - ComfyUI'
            Write-Host '       Do you start ComfyUI yourself, or should LocalCanvas start it for you?'
            Write-Host '         1  I start ComfyUI myself              (recommended if you already use it)'
            Write-Host '         2  LocalCanvas starts ComfyUI for me'
            $answer = Request-Answer -Prompt '       Answer 1 or 2 [1]'
            if ($null -eq $answer) {
                Stop-ForMissingAnswer -What 'The configuration has not been written yet' `
                    -Parameters "-Mode External   (or -Mode Managed -ComfyRoot 'C:\path\to\ComfyUI')"
            }
            $attempts = 1
            while ($answer -and $answer -notin @('1', '2') -and $attempts -lt $script:MaxAnswerAttempts) {
                Write-LcWarn "'$answer' is not 1 or 2."
                $answer = Request-Answer -Prompt '       Answer 1 or 2 [1]'
                $attempts++
            }
            if ($answer -eq '2') { $manageComfy = $true }
            elseif ($answer -and $answer -ne '1') {
                throw "'$answer' is not 1 or 2, and the question has been asked $script:MaxAnswerAttempts times. Nothing has been written to config."
            }
            Write-LcOk $(if ($manageComfy) { 'LocalCanvas will start ComfyUI for you.' } else { 'You start ComfyUI yourself.' })
        }
        Write-Host ''

        # -- question 2 ----------------------------------------------------
        $rootAnswer = $ComfyRoot
        if ($rootAnswer) {
            $check = Test-ComfyRoot -Path $rootAnswer
            if (-not $check.Ok) {
                $script:FixHint = 'Pass -ComfyRoot the folder that holds ComfyUI''s main.py, or the folder that holds that folder.'
                throw "That is not a ComfyUI installation: $rootAnswer - $($check.Reason) Nothing has been written to config."
            }
            $validatedRoot = (Resolve-Path -LiteralPath $rootAnswer).Path
            $comfyAppDirectory = $check.AppDirectory
            Write-LcOk "ComfyUI: -ComfyRoot was given, so nothing was asked."
            Write-LcDetail "Root:   $validatedRoot"
            Write-LcDetail "main.py in: $comfyAppDirectory"
        } else {
            $suggestion = Get-BootstrapComfyRoot
            if ($suggestion) {
                $offered = Test-ComfyRoot -Path $suggestion
                if (-not $offered.Ok) { $suggestion = $null }
            }
            Write-Host '       Question 2 of 2 - where is your ComfyUI?'
            Write-Host '       The folder that holds main.py, or the folder that holds that folder'
            Write-Host '       (that is how the portable build is laid out). Nothing is searched for.'
            $prompt = if ($suggestion) { "       Path [$suggestion]" } else { '       Path' }
            $attempts = 0
            while ($true) {
                $attempts++
                $typed = Request-Answer -Prompt $prompt
                if ($null -eq $typed) {
                    # Nobody to ask. Managed mode CANNOT be configured without
                    # this -- the loader requires comfy.root when manage_comfy
                    # is true -- so that one stops here. External mode can:
                    # the root is optional there, so the run writes what it
                    # safely can and says what it did not get.
                    if ($manageComfy) {
                        Stop-ForMissingAnswer -What 'Managed mode needs to know where ComfyUI is' `
                            -Parameters "-Mode Managed -ComfyRoot 'C:\path\to\ComfyUI'"
                    }
                    Write-LcWarn ('This session cannot be asked where ComfyUI is, so the ' +
                        'configuration is being written without it.')
                    Write-LcDetail ('External mode does not need it. Re-run with -ComfyRoot to ' +
                        'record it and to find your workflows.')
                    break
                }
                if (-not $typed -and $suggestion) { $typed = $suggestion }
                if (-not $typed) {
                    if (-not $manageComfy) {
                        Write-LcWarn 'No ComfyUI folder given. Carrying on without it: external mode does not need it.'
                        Write-LcDetail 'Your workflows can be pointed at later with scripts\sync-workflows.ps1.'
                        break
                    }
                    Write-LcWarn 'Managed mode cannot start a ComfyUI it has not been shown.'
                } else {
                    $check = Test-ComfyRoot -Path $typed
                    if ($check.Ok) {
                        $validatedRoot = (Resolve-Path -LiteralPath $typed).Path
                        $comfyAppDirectory = $check.AppDirectory
                        Write-LcOk "ComfyUI found: $validatedRoot"
                        Write-LcDetail "main.py in: $comfyAppDirectory"
                        break
                    }
                    Write-LcWarn "That is not a ComfyUI installation - $($check.Reason)"
                }
                if ($attempts -ge $script:MaxAnswerAttempts) {
                    $script:FixHint = 'Run it again with -ComfyRoot naming the folder that holds ComfyUI''s main.py.'
                    throw "No ComfyUI installation was named in $script:MaxAnswerAttempts attempts. Nothing has been written to config."
                }
            }
        }

        if ($manageComfy -and -not $validatedRoot) {
            $script:FixHint = 'Pass -ComfyRoot, or choose external mode with -Mode External.'
            throw 'Managed mode needs a ComfyUI root, and none was given. Nothing has been written to config.'
        }

        $launcher = $null
        if ($validatedRoot -and $comfyAppDirectory) {
            $launcher = Resolve-ComfyLauncher -Root $validatedRoot -AppDirectory $comfyAppDirectory
        }
        if ($manageComfy -and -not $launcher) {
            # Managed mode without a launcher is a configuration the loader
            # refuses, and a launcher this script has not seen on disk is a
            # guess. Neither is written.
            $script:FixHint = ('Start ComfyUI yourself and re-run with -Mode External - that needs no ' +
                'launcher at all - or add the two comfy.launcher values yourself; ' +
                'config\examples\runtime.example.yaml shows the shape.')
            throw ("There is no Python beside $validatedRoot to start ComfyUI with: no " +
                'python_embeded\python.exe, no venv\Scripts\python.exe and no ' +
                '.venv\Scripts\python.exe. LocalCanvas will not guess at an interpreter it ' +
                'has not found. Nothing has been written to config.')
        }

        $displayName = [Environment]::GetEnvironmentVariable('COMPUTERNAME')
        if (-not $displayName) { $displayName = 'LocalCanvas PC' }

        Write-NewFile -Path $configPath -Content (New-RuntimeDocument -ManageComfy $manageComfy `
            -Root $validatedRoot -Launcher $launcher -ComfyHostName $comfyHostName `
            -ComfyPortNumber $comfyPortNumber -Registry $registryValue -DisplayName $displayName)
        Write-Host ''
        Write-LcOk 'Configuration written'
        Write-LcDetail "File: $configPath"
        Add-Change "$configPath was written"
        Add-Status -Name 'Configuration' -State 'created' -Detail $configPath
        if ($validatedRoot -and -not $launcher) {
            Write-LcDetail ('No Python was found beside your ComfyUI, so no launcher was written. ' +
                'External mode does not need one.')
        }

    }

    # ----------------------------------------------------------------------
    # Does the configuration load?
    # ----------------------------------------------------------------------
    #
    # Before the workflow source list rather than after it, and that order is
    # the fix for a defect this file had: everything below needs to know what
    # the configuration SAYS -- where ComfyUI is, where the registry is -- and
    # the only reader of that is the gateway's own loader, across the seam.
    # Deriving it a second time from the answers this run happened to collect
    # is what made the source list invisible to a run that asked no questions.

    Write-Host ''
    Write-LcInfo 'Checking the configuration the way start.ps1 will read it ...'
    $loaded = Read-LcConfig -ConfigPath $configPath -PythonExe $venvPython
    if (-not $loaded.Ok) {
        $script:FixHint = if ($script:StillBroken) {
            # The loader runs inside the environment, so a broken environment
            # fails here first -- and the configuration is not what to fix.
            "The environment is still broken ($script:StillBroken). Rebuild it: pwsh .\scripts\setup.ps1 -Recreate"
        } elseif ($loaded.Hint) { $loaded.Hint } else { 'Correct the configuration and run this again.' }
        throw ((@($loaded.What) + @($loaded.Detail)) -join "`n")
    }
    Write-LcOk 'Configuration loads'

    # ----------------------------------------------------------------------
    # The workflow source list -- OUTSIDE the branch above, on purpose
    # ----------------------------------------------------------------------
    <#
        THIS BLOCK USED TO LIVE INSIDE THE `else` ABOVE, and that was the
        card's own headline failure class reintroduced twenty lines from where
        it was killed. With runtime.yaml present and workflow-sources.yaml
        absent -- which is the state of EVERY user who already followed the
        README's manual flow, and of three other paths besides -- the whole
        block was skipped: -WorkflowSource was accepted and silently ignored,
        the run exited 0, nothing was written, and the closing advice was "run
        setup again with -WorkflowSource". A printed remedy that can never
        work.

        So the question it asks is about the SOURCE LIST, not about the run
        that created the runtime configuration, and it is asked whenever the
        source list is missing. What it needs -- where ComfyUI is -- comes from
        the loaded configuration when this run did not ask for it, so a user
        who wrote comfy.root by hand years ago is covered by the same code.
    #>
    $registryDirectory = [string](Get-LcConfigValue -Document $loaded.Document -Path 'workflows.registry' -Optional)
    if (-not $registryDirectory) { $registryDirectory = Resolve-ConfiguredPath -Value $registryValue }
    # The source list's `definitions` and the runtime's `registry` are one
    # place, so they are written from one value: the one the loader reports.
    $definitionsValue = if (Test-SamePath -Left (Resolve-ConfiguredPath -Value $registryValue) -Right $registryDirectory) {
        $registryValue
    } else {
        $registryDirectory
    }

    if (Test-Path -LiteralPath $sourcesPath -PathType Leaf) {
        Add-Status -Name 'Workflow sources' -State 'present' -Detail $sourcesPath
        if ($WorkflowSource) {
            Write-LcInfo "The workflow source list is already there, so -WorkflowSource was not used."
            Write-LcDetail "File: $sourcesPath"
        }
    } else {
        # Where ComfyUI is, from this run's own answer if it had one and from
        # the configuration otherwise. Still no search of the machine.
        if (-not $comfyAppDirectory) {
            $configuredRoot = [string](Get-LcConfigValue -Document $loaded.Document -Path 'comfy.root' -Optional)
            if ($configuredRoot) {
                $known = Test-ComfyRoot -Path $configuredRoot
                if ($known.Ok) { $comfyAppDirectory = $known.AppDirectory }
            }
        }

        $workflowFolder = $WorkflowSource
        if ($workflowFolder -and -not (Test-Path -LiteralPath $workflowFolder -PathType Container)) {
            $script:FixHint = ('Run setup again with -WorkflowSource naming a folder that exists. ' +
                'Everything else is already in place, so that run will only write the source list.')
            throw ("That workflow folder does not exist: $workflowFolder" + "`n" +
                'Nothing was written to it and no source list was created.')
        }
        if (-not $workflowFolder -and $comfyAppDirectory) {
            # ComfyUI's own place for saved workflows. A rule, not a search.
            $derived = Join-Path $comfyAppDirectory 'user\default\workflows'
            if (Test-Path -LiteralPath $derived -PathType Container) { $workflowFolder = $derived }
        }
        if (-not $workflowFolder) {
            Write-Host ''
            Write-Host '       One more - where are your ComfyUI workflows?'
            if ($comfyAppDirectory) {
                Write-Host "       They are usually in $(Join-Path $comfyAppDirectory 'user\default\workflows'),"
                Write-Host '       and that folder is not there. Press Enter to skip; you can do this later.'
            } else {
                Write-Host '       The folder your ComfyUI saves them in. Press Enter to skip.'
            }
            $typed = Request-Answer -Prompt '       Path (or Enter to skip)'
            if ($typed) {
                if (-not (Test-Path -LiteralPath $typed -PathType Container)) {
                    Write-LcWarn "There is no folder at $typed - skipping the workflow source list."
                } else {
                    $workflowFolder = (Resolve-Path -LiteralPath $typed).Path
                }
            }
        }

        if ($workflowFolder) {
            $workflowFolder = (Resolve-Path -LiteralPath $workflowFolder).Path
            Write-NewFile -Path $sourcesPath -Content (New-WorkflowSourcesDocument -Source $workflowFolder `
                -Definitions $definitionsValue `
                -ImportedApi (Get-ConfiguredPath -ConfigDirectory $configDirectory -Relative 'imported-workflows') `
                -Inventory (Get-ConfiguredPath -ConfigDirectory $configDirectory -Relative 'workflow-inventory.json'))
            Write-Host ''
            Write-LcOk 'Workflow source list written'
            Write-LcDetail "File:    $sourcesPath"
            Write-LcDetail "Reading: $workflowFolder"
            Add-Change "$sourcesPath was written"
            Add-Status -Name 'Workflow sources' -State 'created' -Detail $workflowFolder
        } else {
            Write-LcWarn 'No workflow folder yet, so no source list was written.'
            Write-LcDetail 'Setup can write it whenever you know the folder - nothing else has to be redone.'
            Add-Status -Name 'Workflow sources' -State 'not configured' `
                -Detail "run: pwsh .\scripts\setup.ps1 -WorkflowSource '<your workflow folder>'"
        }
    }

    # The registry directory has to exist before the gateway will start: an
    # empty one is a registry with no workflows in it, a missing one is an
    # error the user did nothing to cause. Its location comes from the loaded
    # configuration, so a registry the user moved is the one that is created.
    if (-not (Test-Path -LiteralPath $registryDirectory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $registryDirectory -Force)
        Add-Change "$registryDirectory was created"
    }

    # ComfyUI's address is the one thing here that was inferred rather than
    # read off disk, so it is looked at rather than asserted -- and a ComfyUI
    # that is simply not running yet is not a failure of anything. Note what
    # this can and cannot say: an answer confirms the address, and silence
    # confirms nothing, because a ComfyUI that is not running and a port that
    # is wrong look exactly the same from here.
    $endpoints = Get-LcEndpoints -Config $loaded.Document
    $reachable = Invoke-LcProbe -Url $endpoints.ComfyHealthUrl -TimeoutSeconds 2
    if ($reachable.Ok) {
        Write-LcOk "ComfyUI answered at $($endpoints.ComfyBaseUrl)"
        Add-Status -Name 'ComfyUI' -State 'reachable' -Detail $endpoints.ComfyBaseUrl
    } else {
        Write-LcInfo "ComfyUI did not answer at $($endpoints.ComfyBaseUrl)."
        Write-LcDetail 'That is expected if it is not running yet. If it IS running, the address is wrong:'
        Write-LcDetail "check comfy.host and comfy.port in $configPath."
        Add-Status -Name 'ComfyUI' -State 'no answer' -Detail $endpoints.ComfyBaseUrl
    }

    # ----------------------------------------------------------------------
    # What it looks like now, and what to do next
    # ----------------------------------------------------------------------

    Write-Host ''
    if ($script:Changes.Count -eq 0) {
        Write-LcOk 'Nothing to change.'
    } else {
        Write-LcOk 'Setup complete'
    }
    Write-Host ''
    $width = 0
    foreach ($row in $script:Status) { if ($row.Name.Length -gt $width) { $width = $row.Name.Length } }
    foreach ($row in $script:Status) {
        Write-Host ("       {0}  {1}" -f $row.Name.PadRight($width), $row.State)
        if ($row.Detail) { Write-Host ("       {0}  {1}" -f ''.PadRight($width), $row.Detail) }
    }
    Write-LcField -Label 'Interpreter' -Value $venvPython
    if ($installedVersion) { Write-LcField -Label 'Version' -Value "Python $($installedVersion.Version)" }
    Write-Host ''
    if ($script:Installed) {
        # Only when there WAS an install: on a run that installed nothing the
        # sentence is about nothing (T-0352 review).
        Write-LcDetail 'ComfyUI''s own Python was not touched: every install above ran'
        Write-LcDetail 'as .venv\Scripts\python.exe -m pip.'
        Write-Host ''
    }
    Write-LcOk 'Next, start LocalCanvas:'
    Write-Host ''
    Write-Host '       pwsh .\scripts\start.ps1'
    Write-Host ''
    if (-not (Test-Path -LiteralPath $sourcesPath -PathType Leaf)) {
        # An action that works from exactly the state this run is leaving
        # behind: everything else is in place, so this run writes the source
        # list and nothing else. It is checked by a test, because the last
        # time this sentence was here it named a run that did nothing.
        Write-LcDetail 'Your ComfyUI workflows are not configured yet. When you know the folder:'
        Write-LcDetail ''
        Write-LcDetail '       pwsh .\scripts\setup.ps1 -WorkflowSource ''<your workflow folder>'''
        Write-LcDetail ''
        Write-LcDetail 'Nothing else is redone by that run; it writes the source list and stops.'
    } else {
        Write-LcDetail 'To bring your ComfyUI workflows in: pwsh .\scripts\sync-workflows.ps1'
    }
    Write-Host ''
    exit 0
} catch {
    $fix = if ($script:FixHint) { $script:FixHint } else { 'Fix the problem above and run scripts\setup.ps1 again.' }
    Write-LcFailure -What 'Setup did not complete' -Detail @("$($_.Exception.Message)") `
        -Fix $fix -ErrorRecord $_
    exit 1
}
