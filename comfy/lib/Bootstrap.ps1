<#
.SYNOPSIS
    The one place the optional ComfyUI bootstrap may change anything on disk.

.DESCRIPTION
    Dot-sourced by comfy/setup.ps1. It holds four things, and the first of them
    is the reason the file exists at all.

    1. THE CHOKE POINT. Every persistent action goes through Invoke-LcStep,
       which under -DryRun prints the plan and does not invoke the action. That
       alone is not enough -- a reference bootstrap stack examined before this
       layer was written had exactly this helper and
       still created seven directories during a dry run, because seven call
       sites simply did not use it. So the primitives underneath refuse as
       well: nothing writes to disk without first calling
       Assert-LcMutationAllowed, which throws when the run is a dry run and
       throws when it is called from outside a step. A bypass is not a missed
       convention here; it is an exception with nothing written.

    2. THE PRIMITIVES. Exactly one directory creator, one file writer and one
       place a git subcommand runs. Each is a single call site, so the guard in
       front of it cannot be walked around by adding another.

    3. MANIFEST READING. A manifest entry must carry a pinned 40-character
       commit id. Of 16 node entries across the reference stack's two
       registries not one carried a revision, so
       "known-good" had to be built here rather than adapted. A missing
       revision is a hard refusal of the manifest, never a silent default
       branch. The models half of the same file is validated by Models.ps1,
       from inside this reader, so one call reads one manifest.

    4. INSPECTION. Read-only answers about what is already on disk: is this a
       ComfyUI, is this a git repository, does it have local changes. Every one
       of these runs identically under -DryRun, because looking is not a
       change.

    WHAT THIS FILE NEVER DOES, under any argument: write inside a ComfyUI it
    did not install, install anything into an interpreter it did not create,
    change the firewall, elevate, change anything global to Windows, address a
    process by name, mutate this or any console's encoding, or fetch a byte
    over the network. The one fetch in this layer lives in Models.ps1, behind
    an explicit flag, a printed plan and a consent question, and it calls the
    same Assert-LcMutationAllowed as everything else here.

    Paths: -LiteralPath on every cmdlet that takes one, and .NET path APIs
    where a cmdlet has no literal form (New-Item has no -LiteralPath at all).
    Both are literal, so a path containing a space, a bracket or a backtick
    survives.
#>

Set-StrictMode -Version Latest

# The terminal vocabulary of docs/runtime.md -- [INFO] / [ OK ] / [WARN] /
# [FAIL] -- comes from the project's own library rather than being written a
# second time here.
. (Join-Path $PSScriptRoot '..\..\scripts\lib\Common.ps1')

# The model half of the manifest, the profiles, and the one fetch in this
# layer. Dot-sourced HERE rather than beside it in setup.ps1 so that there is
# exactly one manifest reader: Read-LcBootstrapManifest below validates the
# models section through Read-LcModelManifest, and a second reader for the
# second half of the same file is how two rules about one format drift apart.
. (Join-Path $PSScriptRoot 'Models.ps1')

# --------------------------------------------------------------------------
# The choke point
# --------------------------------------------------------------------------

$script:LcBootstrapContext = $null
$script:LcBootstrapInsideStep = $false

function Initialize-LcBootstrap {
    <#
        Open a run. Everything below refuses to act until this has been called,
        so a library that is merely dot-sourced cannot write anything.
    #>
    param([switch]$DryRun)
    $script:LcBootstrapContext = [pscustomobject]@{
        DryRun    = [bool]$DryRun
        Planned   = [System.Collections.Generic.List[string]]::new()
        Performed = [System.Collections.Generic.List[string]]::new()
        Git       = $null
    }
    $script:LcBootstrapInsideStep = $false
    return $script:LcBootstrapContext
}

function Get-LcBootstrapContext {
    if ($null -eq $script:LcBootstrapContext) {
        throw 'REFUSED: the bootstrap context has not been opened. Call Initialize-LcBootstrap first.'
    }
    return $script:LcBootstrapContext
}

function Test-LcBootstrapDryRun {
    return (Get-LcBootstrapContext).DryRun
}

function Invoke-LcStep {
    <#
        The only way anything persistent happens.

        Under -DryRun the action is recorded and printed and NOT invoked.
        Otherwise it is invoked with the in-step flag raised, which is the only
        condition under which the primitives below agree to act.
    #>
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    $context = Get-LcBootstrapContext
    $context.Planned.Add($Description)
    if ($context.DryRun) {
        Write-Host "[PLAN] $Description"
        return
    }
    Write-LcInfo $Description
    $previous = $script:LcBootstrapInsideStep
    $script:LcBootstrapInsideStep = $true
    try {
        & $Action | Out-Null
    } finally {
        $script:LcBootstrapInsideStep = $previous
    }
    $context.Performed.Add($Description)
}

function Assert-LcMutationAllowed {
    <#
        The interlock the reference stack's seven dry-run directories would have hit.

        Two independent refusals, in this order:

          * a dry run may not write, whatever the caller believes. This one
            catches a broken Invoke-LcStep, not just a careless caller -- so
            even a step helper that forgot its own switch cannot produce a
            file;
          * a write outside a step is refused, so a primitive called directly
            from anywhere is an exception rather than an unannounced change.
    #>
    param(
        [Parameter(Mandatory)][string]$What,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Target
    )
    $context = Get-LcBootstrapContext
    if ($context.DryRun) {
        throw ("REFUSED: $What would have changed '$Target' during -DryRun. " +
            'A dry run writes nothing at all; this is the interlock underneath ' +
            'Invoke-LcStep, and reaching it means a step was bypassed.')
    }
    if (-not $script:LcBootstrapInsideStep) {
        throw ("REFUSED: $What tried to change '$Target' outside Invoke-LcStep. " +
            'Every persistent action is announced and routed through one place, ' +
            'so that -DryRun cannot be bypassed. Nothing was changed.')
    }
}

function Get-LcBootstrapPlanCount { return (Get-LcBootstrapContext).Planned.Count }
function Get-LcBootstrapPerformedCount { return (Get-LcBootstrapContext).Performed.Count }

# --------------------------------------------------------------------------
# The primitives: one call site each
# --------------------------------------------------------------------------

function New-LcBootstrapDirectory {
    <#
        The only directory creation in the bootstrap layer.

        .NET rather than the cmdlet, because New-Item has no -LiteralPath at
        all, so a path containing [ or ] would be read as a wildcard. The .NET
        API is literal by construction and creates missing parents.
    #>
    param([Parameter(Mandatory)][string]$Path)
    Assert-LcMutationAllowed -What 'creating a directory' -Target $Path
    [void][System.IO.Directory]::CreateDirectory($Path)
}

function Set-LcBootstrapFile {
    <#
        The only file write in the bootstrap layer. UTF-8 without a BOM, and
        the same bytes under Windows PowerShell 5.1 and PowerShell 7 -- which
        Set-Content is not, and which matters because the caller compares the
        bytes it is about to write against the bytes already there and skips
        the write when they are equal.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )
    Assert-LcMutationAllowed -What 'writing a file' -Target $Path
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

# --------------------------------------------------------------------------
# git: one call site, and a read path that cannot run a mutating subcommand
# --------------------------------------------------------------------------

# Subcommands that only ever read. Anything not on this list has to come
# through the mutating wrapper, which is guarded by Assert-LcMutationAllowed --
# so a dry run cannot fetch, clone, check out or reset even by accident.
$script:LcGitReadOnlySubcommands = @('rev-parse', 'status', 'ls-remote', '--version')

function Get-LcFileSha256 {
    <#
        The sha256 of a file, in lower case, computed through .NET.

        NOT Get-FileHash, and here is exactly what is known.

        OBSERVED: the first run of the cross-shell test failed under Windows
        PowerShell 5.1 with "The term 'Get-FileHash' is not recognized as the
        name of a cmdlet". That happened, and it is why this function exists.

        NOT EXPLAINED: the explanation that used to be written here -- that the
        command depends on which shell started 5.1 -- did not survive
        independent re-measurement across nine configurations, every one of
        which reported it present. So the cause is unknown, and naming a wrong
        one would be worse than naming none.

        WHY THE FUNCTION STAYS ANYWAY: this file is dot-sourced and carries no
        version gate, so it is still expected to work under Windows PowerShell
        5.1 and is still measured there (T-0294) -- not because 5.1 is supported,
        which README.md says plainly it is not, but because a second engine is
        the cheapest way to catch an assumption only PowerShell 7 satisfies. A
        hash over a file is four lines of .NET that either host has, and a
        dependency that failed once for a reason nobody can state is a
        dependency worth not having. It costs nothing to keep, and it cannot
        fail that way again.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $algorithm.ComputeHash([System.IO.File]::ReadAllBytes($Path))
    } finally {
        $algorithm.Dispose()
    }
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Resolve-LcGitCommand {
    <#
        Find git, once, and say where it is. A missing prerequisite is
        reported and never installed: installing tooling onto the user's
        machine is precisely the part of the reference stack not to be ported.
    #>
    $context = Get-LcBootstrapContext
    if ($context.Git) { return $context.Git }
    $command = Get-Command 'git' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $command) {
        throw ('git was not found. The bootstrap installs ComfyUI by cloning it at a ' +
            'pinned revision, so git is required. Install Git for Windows and run this ' +
            'again. LocalCanvas does not install tools on your machine.')
    }
    $context.Git = $command.Source
    return $context.Git
}

function Invoke-LcBootstrapGitCore {
    <#
        The single place a git process is started.

        -AllowMutation is the difference between the two wrappers below, and it
        is decided here rather than by the caller's good intentions: without
        it, a subcommand outside the read-only list is refused outright; with
        it, the mutation interlock has to pass first.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$WorkingDirectory,
        [switch]$AllowMutation,
        [string]$Target
    )
    if ($Arguments.Count -lt 1) { throw 'REFUSED: a git invocation with no subcommand.' }
    $subcommand = $Arguments[0]
    if ($AllowMutation) {
        $named = if ($Target) { $Target } else { $WorkingDirectory }
        Assert-LcMutationAllowed -What "git $subcommand" -Target $named
    } elseif ($script:LcGitReadOnlySubcommands -notcontains $subcommand) {
        throw ("REFUSED: 'git $subcommand' is not one of the read-only subcommands " +
            "($($script:LcGitReadOnlySubcommands -join ', ')), so it may not run through " +
            'the read path. Nothing was changed.')
    }

    $git = Resolve-LcGitCommand
    $full = @()
    if ($WorkingDirectory) { $full += @('-C', $WorkingDirectory) }
    $full += $Arguments

    # Function-scoped, so it restores itself on return. git writes progress to
    # stderr, and under Windows PowerShell 5.1 a native command's stderr is a
    # terminating error while $ErrorActionPreference is 'Stop' -- the shell
    # difference T-0112 is about. The exit code is read explicitly below.
    $ErrorActionPreference = 'Continue'
    $output = & $git @full 2>&1
    $code = $LASTEXITCODE
    $lines = @($output | ForEach-Object { "$_" })
    return [pscustomobject]@{
        ExitCode = $code
        Lines    = $lines
        Text     = ($lines -join [Environment]::NewLine)
        Command  = "git $($full -join ' ')"
    }
}

function Invoke-LcGitRead {
    param([Parameter(Mandatory)][string[]]$Arguments, [string]$WorkingDirectory)
    return Invoke-LcBootstrapGitCore -Arguments $Arguments -WorkingDirectory $WorkingDirectory
}

function Invoke-LcGitMutation {
    <#
        A git subcommand that changes something. Only ever reached from inside
        an Invoke-LcStep action; the interlock in the core enforces that.

        -AllowFailure returns the result instead of throwing, for the one case
        where a non-zero exit is an answer rather than an error: asking a
        server for a single commit, which many servers decline to serve.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$Target,
        [switch]$AllowFailure
    )
    $result = Invoke-LcBootstrapGitCore -Arguments $Arguments -WorkingDirectory $WorkingDirectory `
        -AllowMutation -Target $Target
    if ($result.ExitCode -ne 0 -and -not $AllowFailure) {
        throw ("$($result.Command) failed with exit code $($result.ExitCode):" +
            [Environment]::NewLine + $result.Text)
    }
    return $result
}

# --------------------------------------------------------------------------
# Reading what is already on disk
# --------------------------------------------------------------------------

function Get-LcGitRepositoryState {
    <#
        What is at $Path, as one of three answers:

          Absent          -- nothing there
          NotARepository  -- something there, but not a git working tree of its own
          Repository      -- a working tree; Head and Dirty describe it

        "Dirty" means a TRACKED file differs from HEAD -- `git status
        --porcelain --untracked-files=no`. Untracked files are deliberately not
        dirt: a ComfyUI that has ever run has outputs, caches, downloaded
        models and user settings inside it, and a rule that called those local
        changes would refuse on every real installation and so would protect
        nothing.

        NO PATH IS COMPARED HERE, and that is deliberate. This used to ask for
        `rev-parse --show-toplevel` and compare the answer with the path it had
        asked about, to tell a repository from a directory sitting inside
        somebody else's. git resolves a junction and .NET's GetFullPath does
        not, so the two disagreed, a checkout this script had JUST MADE ITSELF
        read as "not a repository", and every later run refused to touch it --
        an ordinary Windows path shape turned a bootstrap into a one-shot.
        `--show-prefix` asks the same question inside git's own coordinates: it
        is empty at the top of a working tree and names the subdirectory
        anywhere below it. Junctions, subst drives, mapped drives, short names
        and letter case all stop mattering, because no two path strings ever
        meet.

        (`--show-prefix` is also empty inside a repository's own .git
        directory, which `--is-inside-work-tree` is asked about first. Neither
        path this script inspects can be one -- a node name must begin with a
        letter or a digit -- but a guard that depends on that is a guard with a
        footnote.)
    #>
    param([Parameter(Mandatory)][string]$Path)

    $state = [pscustomobject]@{
        Path  = $Path
        Kind  = 'Absent'
        Head  = $null
        Dirty = $false
    }
    if (-not (Test-Path -LiteralPath $Path)) { return $state }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        $state.Kind = 'NotARepository'
        return $state
    }

    $inside = Invoke-LcGitRead -Arguments @('rev-parse', '--is-inside-work-tree') -WorkingDirectory $Path
    if ($inside.ExitCode -ne 0) {
        $state.Kind = 'NotARepository'
        return $state
    }
    if ((@($inside.Lines | Where-Object { $_ }) | Select-Object -First 1) -ne 'true') {
        $state.Kind = 'NotARepository'
        return $state
    }
    # A directory inside somebody else's repository is not a repository of its
    # own, and must not be treated as one: git would answer about the parent.
    $prefix = Invoke-LcGitRead -Arguments @('rev-parse', '--show-prefix') -WorkingDirectory $Path
    if ($prefix.ExitCode -ne 0) {
        $state.Kind = 'NotARepository'
        return $state
    }
    if (@($prefix.Lines | Where-Object { $_.Trim() }).Count -gt 0) {
        $state.Kind = 'NotARepository'
        return $state
    }

    $state.Kind = 'Repository'
    $head = Invoke-LcGitRead -Arguments @('rev-parse', 'HEAD') -WorkingDirectory $Path
    if ($head.ExitCode -eq 0) {
        $state.Head = @($head.Lines | Where-Object { $_ }) | Select-Object -First 1
    }
    $status = Invoke-LcGitRead -Arguments @('status', '--porcelain', '--untracked-files=no') `
        -WorkingDirectory $Path
    if ($status.ExitCode -ne 0) {
        throw "Could not read the state of the git repository at '$Path': $($status.Text)"
    }
    $state.Dirty = [bool](@($status.Lines | Where-Object { $_.Trim() }).Count)
    return $state
}

# --------------------------------------------------------------------------
# The install record
# --------------------------------------------------------------------------

$script:LcInstallRecordName = 'localcanvas-bootstrap.json'
$script:LcBootstrapSchema = 'localcanvas.comfy-bootstrap/1'

function Get-LcBootstrapSchema { return $script:LcBootstrapSchema }

function Get-LcInstallRecordPath {
    param([Parameter(Mandatory)][string]$Root)
    return (Join-Path $Root $script:LcInstallRecordName)
}

function Read-LcInstallRecord {
    <#
        The record this script writes beside -- never inside -- the ComfyUI it
        installed. Outside, because a file written into the checkout would show
        up as a change in that repository, and the dirty check is not allowed
        to be tripped by our own footprint.

        Returns $null for "no record", which is how an installation is judged
        to be somebody else's.
    #>
    param([Parameter(Mandatory)][string]$Root)
    $path = Get-LcInstallRecordPath -Root $Root
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $document = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw ("There is a LocalCanvas install record at '$path' that cannot be read: " +
            "$($_.Exception.Message). Nothing was changed. Move it aside if you want a " +
            'fresh install here.')
    }
    if (-not (Test-LcHasProperty -Object $document -Name 'schema')) {
        throw "The install record at '$path' carries no schema field. Nothing was changed."
    }
    if ($document.schema -ne $script:LcBootstrapSchema) {
        throw ("The install record at '$path' is schema '$($document.schema)', and this " +
            "script understands '$($script:LcBootstrapSchema)'. Nothing was changed.")
    }
    return $document
}

function Get-LcComfyLayoutCandidate {
    <#
        The two places a ComfyUI's application directory can be under $Root:
        $Root itself (a plain clone) and $Root\ComfyUI (the portable layout,
        which is what the portable build ships).

        THE ONE DEFINITION OF THAT, on purpose. There used to be two probes for
        it -- this one and a second inside Find-LcEnclosingInstallation that
        only looked at $Root -- and they drifted exactly as two copies of a
        rule do: the same script called a portable root an installation when
        asked directly and "not inside an installation" when asked about an
        ancestor, so -ComfyRoot one directory below it cloned a whole ComfyUI
        into somebody's installation. Everything that asks "is there a ComfyUI
        here" asks through here.
    #>
    param([Parameter(Mandatory)][string]$Root)
    return @($Root, (Join-Path $Root 'ComfyUI'))
}

function Find-LcComfyApplicationDirectory {
    <#
        The application directory of a ComfyUI at $Root, or $null.

        A file test, not a name test, so a renamed directory still resolves.
        Both layouts, because there are two: main.py in
        $Root itself, and main.py in $Root\ComfyUI, which is what the portable
        build ships.

        -NestedLayout $false asks the first question only, and the caller that
        needs it is the ancestor walk. The difference matters and is measured:
        "this directory HOLDS a directory called ComfyUI" is a statement about
        a portable root when the directory is the one you were about to write
        into, and it is a statement about nothing at all several levels up,
        where a home directory, a drive root or an AI folder very commonly
        holds one. Asked unbounded, this probe called the user's profile
        directory an installation, because a directory named ComfyUI sat
        inside it, and so refused the script's OWN default location under
        %LOCALAPPDATA% -- which is under that profile.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [bool]$NestedLayout = $true
    )
    $candidates = if ($NestedLayout) { Get-LcComfyLayoutCandidate -Root $Root } else { @($Root) }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'main.py') -PathType Leaf) {
            return $candidate
        }
    }
    return $null
}

function Get-LcComfyInstallation {
    <#
        Is there a ComfyUI at $Root, and is it one this script installed?

        The application directory comes from Find-LcComfyApplicationDirectory,
        which is the only probe for it in this file.

        Kind is one of:

          Absent    -- nothing there, or an empty directory: safe to install into
          Ours      -- carries this script's own install record: safe to continue
          Existing  -- a ComfyUI this script did not install. STOP. This is the
                       common case and it is a success, not a failure.
          Occupied  -- something else is in the way. Refuse rather than mix an
                       install into a directory whose contents are unknown.
    #>
    param([Parameter(Mandatory)][string]$Root)

    $result = [pscustomobject]@{
        Root         = $Root
        Kind         = 'Absent'
        AppDirectory = $null
        Evidence     = @()
        Record       = $null
    }

    $evidence = [System.Collections.Generic.List[string]]::new()
    $appDirectory = Find-LcComfyApplicationDirectory -Root $Root
    $candidates = Get-LcComfyLayoutCandidate -Root $Root
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'main.py') -PathType Leaf) {
            $evidence.Add("main.py in $candidate")
        }
    }
    foreach ($marker in @('custom_nodes', 'comfy_extras', 'models')) {
        foreach ($candidate in $candidates) {
            $path = Join-Path $candidate $marker
            if (Test-Path -LiteralPath $path -PathType Container) {
                $evidence.Add("$marker in $candidate")
            }
        }
    }
    $result.Evidence = @($evidence)
    $result.AppDirectory = $appDirectory

    $record = Read-LcInstallRecord -Root $Root
    if ($record) {
        $result.Record = $record
        $result.Kind = 'Ours'
        if (-not $result.AppDirectory) {
            $result.AppDirectory = Join-Path $Root 'ComfyUI'
        }
        return $result
    }

    if ($appDirectory) {
        $result.Kind = 'Existing'
        return $result
    }

    if (-not (Test-Path -LiteralPath $Root)) { return $result }
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        $result.Kind = 'Occupied'
        $result.Evidence = @("$Root is a file, not a directory")
        return $result
    }
    $entries = @(Get-ChildItem -LiteralPath $Root -Force -ErrorAction SilentlyContinue)
    if ($entries.Count -gt 0) {
        $result.Kind = 'Occupied'
        if ($evidence.Count -eq 0) {
            $result.Evidence = @("$($entries.Count) existing item(s) in $Root")
        }
        return $result
    }
    return $result
}

function Find-LcEnclosingInstallation {
    <#
        Is $Path inside a ComfyUI, and is that ComfyUI one of ours?

        Returns the innermost installation this script did NOT install, as
        { Root; AppDirectory }, or $null when there is none in the chain. Root
        is the directory a person would call the installation; AppDirectory is
        where main.py actually is, and in the portable layout they differ.

        WHY THIS EXISTS. Detecting an installation at the root being installed
        into is not enough. A path can point INTO somebody's ComfyUI without
        being its root -- `-ModelsRoot D:\ComfyUI\models` is the obvious one,
        and it is not exotic: a person with an old installation full of models
        and a new bootstrapped one is exactly who passes it. Before this, that
        created ten directories inside an installation the script did not make.
        The rule has no qualifier in it, so neither does this.

        An installation this script DID make is not an obstacle: its record
        file says so, and anything under a root we own is ours. A record found
        anywhere up the chain therefore ends the walk with $null -- including
        above an installation that is not ours, which can only be a ComfyUI
        sitting inside a root we created.

        HOW FAR EACH OF THE TWO LAYOUTS REACHES, because they are not the same
        question and one measurement settled it:

          * main.py IN an ancestor -- a flat installation, and the application
            directory of a portable one -- counts at ANY depth. That is the
            rule that protects the user's files: everything under it is theirs;
          * main.py in <ancestor>\ComfyUI counts only for the path itself and
            its immediate parent. That one says "this directory is the folder
            you call your ComfyUI", which is true of a portable root you are
            about to write into and false of every directory further up.
            Measured, unbounded: walking up from a scratch path under the
            user's profile directory, this reached the profile itself, found a
            directory named ComfyUI in it, and declared the profile an
            installation -- which would refuse this script's own default
            location, %LOCALAPPDATA%\LocalCanvas\comfyui, on any machine where
            somebody keeps a ComfyUI in their home directory. A folder that
            merely contains one is not one.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$ExcludeSelf
    )

    # GetDirectoryName and not Split-Path: it is literal by construction, it
    # returns $null at a drive or UNC root -- which is what ends the walk --
    # and it has no parameter sets to collide with. (Split-Path -LiteralPath
    # -Parent is not a legal combination at all; measured, it fails with "the
    # parameter set cannot be resolved".)
    $candidate = [System.IO.Path]::GetFullPath($Path)
    $depth = 0
    if ($ExcludeSelf) {
        $candidate = [System.IO.Path]::GetDirectoryName($candidate)
        $depth = 1
    }
    $found = $null
    while ($candidate) {
        if (Read-LcInstallRecord -Root $candidate) { return $null }
        # THE SAME PROBE Get-LcComfyInstallation uses, called rather than
        # re-written. This line used to test $candidate\main.py only, so a
        # portable root -- main.py in $candidate\ComfyUI -- was an installation
        # when the script was asked about it directly and invisible when it was
        # asked about it as an ancestor. Two probes that must agree is what
        # produced that, so now there is one, and how far the nested half of it
        # reaches is the $depth argument rather than a second opinion.
        if (-not $found) {
            $application = Find-LcComfyApplicationDirectory -Root $candidate `
                -NestedLayout ($depth -le 1)
            if ($application) {
                $found = [pscustomobject]@{ Root = $candidate; AppDirectory = $application }
            }
        }
        $parent = [System.IO.Path]::GetDirectoryName($candidate)
        if (-not $parent -or $parent -eq $candidate) { break }
        $candidate = $parent
        $depth++
    }
    return $found
}

# --------------------------------------------------------------------------
# The manifest
# --------------------------------------------------------------------------

function Test-LcPinnedRevision {
    <#
        A pin is a full 40-character commit id and nothing else.

        Not a tag and not a branch: both can be moved to another commit by
        whoever owns the repository, so a manifest pinned to one describes what
        was true on the day it was written. The whole point of this layer is a
        ComfyUI somebody can reproduce, and the reference stack had no pin of
        any kind. A human-readable name travels
        in revisionLabel, where it can be read and cannot be checked out.
    #>
    param([AllowEmptyString()][AllowNull()][string]$Revision)
    if (-not $Revision) { return $false }
    # -match is case-insensitive, deliberately: an upper-case commit id names
    # the same commit, and ConvertTo-LcCanonicalRevision below puts it in the
    # one form everything else compares against.
    return [bool]($Revision -match '^[0-9a-f]{40}$')
}

function ConvertTo-LcCanonicalRevision {
    <#
        One spelling of a commit id, so that the record this script writes can
        be compared byte for byte by anything that reads it. git prints lower
        case everywhere; a manifest typed by hand may not.
    #>
    param([Parameter(Mandatory)][string]$Revision)
    return $Revision.ToLowerInvariant()
}

function Get-LcManifestString {
    param($Entry, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Where)
    if (-not (Test-LcHasProperty -Object $Entry -Name $Name)) {
        throw "$Where has no '$Name'. Nothing was changed."
    }
    $value = "$($Entry.$Name)".Trim()
    if (-not $value) { throw "$Where has an empty '$Name'. Nothing was changed." }
    if ($value.StartsWith('-')) {
        throw ("$Where has a '$Name' beginning with '-': '$value'. A value that would " +
            'reach git as an option is refused. Nothing was changed.')
    }
    return $value
}

function Read-LcBootstrapManifest {
    <#
        Read and validate the manifest that says WHAT a known-good install is.

        JSON, not YAML, for one reason: this script runs before LocalCanvas has
        an environment of its own, so it cannot use the gateway's YAML loader,
        and the project's rule is that PowerShell never grows a second YAML
        parser. ConvertFrom-Json ships with the shell.

        Every failure below is a refusal that changes nothing. A manifest is
        the definition of "known-good"; a manifest that cannot deliver that is
        not a manifest to proceed cautiously with.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "The manifest was not found: '$Path'. Nothing was changed."
    }
    try {
        $document = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "The manifest '$Path' is not readable JSON: $($_.Exception.Message). Nothing was changed."
    }
    if (-not (Test-LcHasProperty -Object $document -Name 'schema')) {
        throw "The manifest '$Path' carries no schema field. Nothing was changed."
    }
    if ($document.schema -ne $script:LcBootstrapSchema) {
        throw ("The manifest '$Path' is schema '$($document.schema)', and this script " +
            "understands '$($script:LcBootstrapSchema)'. Nothing was changed.")
    }
    if (-not (Test-LcHasProperty -Object $document -Name 'comfyui')) {
        throw "The manifest '$Path' has no 'comfyui' section. Nothing was changed."
    }

    $comfyui = [pscustomobject]@{
        Name          = 'ComfyUI'
        Repository    = Get-LcManifestString -Entry $document.comfyui -Name 'repository' -Where "the manifest's comfyui section"
        Revision      = Get-LcManifestString -Entry $document.comfyui -Name 'revision' -Where "the manifest's comfyui section"
        RevisionLabel = ''
    }
    if (Test-LcHasProperty -Object $document.comfyui -Name 'revisionLabel') {
        $comfyui.RevisionLabel = "$($document.comfyui.revisionLabel)".Trim()
    }
    if (-not (Test-LcPinnedRevision -Revision $comfyui.Revision)) {
        throw ("The manifest's comfyui revision is '$($comfyui.Revision)', which is not a " +
            "40-character commit id. A tag or a branch can be moved to another commit by " +
            'whoever owns the repository, so it does not pin anything. Nothing was changed.')
    }
    $comfyui.Revision = ConvertTo-LcCanonicalRevision -Revision $comfyui.Revision

    # ::new() and not New-Object, and the reason is narrower than it once said
    # here. Measured, in both hosts this dot-sourced file runs under (pwsh 7.6.6
    # and Windows PowerShell 5.1.26100.9444 -- the second is not a supported
    # shell, it is this layer's second engine, T-0294):
    # `New-Object System.Collections.Generic.List[object]`
    # CONSTRUCTS, and then throws "Argument types do not match" the moment @()
    # enumerates it. The same form with List[string] enumerates fine, so the
    # rule is about this type -- which is the one used here.
    $nodes = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if (Test-LcHasProperty -Object $document -Name 'customNodes') {
        foreach ($entry in @($document.customNodes)) {
            if ($null -eq $entry) { continue }
            $where = "a customNodes entry in '$Path'"
            $name = Get-LcManifestString -Entry $entry -Name 'name' -Where $where
            if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
                throw ("$where has the name '$name', which is not a plain directory name. " +
                    'A node name becomes a directory under custom_nodes, so anything that ' +
                    'could walk out of it is refused. Nothing was changed.')
            }
            if (-not $seen.Add($name)) {
                throw "The manifest '$Path' lists '$name' more than once. Nothing was changed."
            }
            $where = "the customNodes entry '$name'"
            $node = [pscustomobject]@{
                Name          = $name
                Repository    = Get-LcManifestString -Entry $entry -Name 'repository' -Where $where
                Revision      = Get-LcManifestString -Entry $entry -Name 'revision' -Where $where
                RevisionLabel = ''
                Profiles      = @()
                NodeClasses   = @()
            }
            if (Test-LcHasProperty -Object $entry -Name 'revisionLabel') {
                $node.RevisionLabel = "$($entry.revisionLabel)".Trim()
            }
            if (Test-LcHasProperty -Object $entry -Name 'profiles') {
                $node.Profiles = @(Get-LcModelEntryProfiles -Entry $entry -Where $where)
            }
            $node.NodeClasses = @(Read-LcNodeClassNames -Entry $entry -Where $where)
            if (-not (Test-LcPinnedRevision -Revision $node.Revision)) {
                throw ("$where is pinned to '$($node.Revision)', which is not a 40-character " +
                    'commit id. Every entry must name the exact commit to install, so that ' +
                    'the same manifest produces the same installation later. Nothing was changed.')
            }
            $node.Revision = ConvertTo-LcCanonicalRevision -Revision $node.Revision
            $nodes.Add($node)
        }
    }

    return [pscustomobject]@{
        Path        = (Resolve-Path -LiteralPath $Path).Path
        Sha256      = Get-LcFileSha256 -Path $Path
        ComfyUI     = $comfyui
        CustomNodes = @($nodes)
        # @(): a PowerShell function that returns an empty array emits
        # nothing at all, and the property would be $null rather than an
        # empty list. Under Set-StrictMode that is an error at the first
        # .Count, which is how it was found.
        Models      = @(Read-LcModelManifest -Document $document -Path $Path)
    }
}
