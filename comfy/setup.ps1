#requires -Version 7.0
# LocalCanvas v0.1 requires PowerShell 7 or newer (README.md), so the host
# refuses this script under Windows PowerShell 5.1 before its body parses:
# nothing is read, written, started or changed by a 5.1 run. The helpers
# under lib/ are dot-sourced, not entry points, and deliberately keep their
# 5.1 coverage -- they carry no #requires.

<#
.SYNOPSIS
    Install a known-good ComfyUI for LocalCanvas -- and never touch one you
    already have.

.DESCRIPTION
    Run this only if you do NOT have ComfyUI. If you do, you do not need it:
    LocalCanvas talks to the ComfyUI you already run, over HTTP, and this
    script will find yours, say so, and stop without changing anything.

    RULE ZERO. Under every flag, every argument and every path this script can
    take, it will not:

      * write inside, update, reconfigure, reinstall or repair a ComfyUI it did
        not install;
      * install anything into a Python interpreter it did not create;
      * change ComfyUI's configuration, including extra_model_paths.yaml;
      * touch a repository that has local changes;
      * change the firewall, elevate, change anything global to Windows, or
        address a process by name;
      * download a model because somebody ran a setup script. A model arrives
        only under -InstallModels, and only after this script has printed what
        it is, how big it is, where it comes from and under what licence, and
        somebody has said yes. -InstallModels is a new way to write to disk, so
        it inherits every refusal above: a models root inside a ComfyUI this
        script did not install is refused before a byte is requested.

    Finding an installation and stopping is the SUCCESS path, not a failure,
    and it exits 0.

    WHAT IT DOES. Clones ComfyUI at the exact commit named in a manifest,
    clones the custom nodes that manifest lists for the selected profile, each
    at its own exact commit, creates the model directories, and writes a record
    of all of it beside the installation so that "known-good" is a version
    somebody can read back.

    THE THREE PROFILES, and there is no fourth. Minimal is a
    LocalCanvas-compatible ComfyUI runtime and nothing more: ComfyUI itself is
    enough to answer /system_stats and /object_info and to serve its own
    editor, which is all LocalCanvas needs of it, so no model is intrinsically
    required and Minimal downloads none. That is a property of the manifest
    format rather than of this file -- an entry that tries to put a model in
    the minimal profile is refused when the manifest is read. Recommended adds
    the manifest's small image stack. Video is separate and explicit, and
    nothing in it is ever installed by a Minimal or a Recommended run.

    IDEMPOTENT. A second run with the same manifest checks everything and
    changes nothing, and says so.

    -DryRun PLANS AND WRITES NOTHING. Not "almost nothing": every persistent
    action in this layer goes through Invoke-LcStep in comfy/lib/Bootstrap.ps1,
    and underneath it every primitive that can write calls
    Assert-LcMutationAllowed, which throws during a dry run. A dry run that
    created a single directory would be a crash, not a quiet surprise.

    One byte-level event a dry run CAN cause, stated rather than glossed: when
    it inspects a git repository, the read-only `git status` it runs may
    refresh git's own stat cache -- .git/index, rewritten with identical bytes
    and a new modification time. That is git caching what it just read, not
    this script writing; it can only happen in a repository this script
    installed, because in an installation it did not install no git process is
    started at all.

    EXIT CODES
      0  installed, or already complete, or an existing installation was found
         and left alone, or a dry run planned successfully
      1  refused or failed -- and a refusal changes nothing

.PARAMETER ComfyRoot
    Where to install. The ComfyUI checkout goes in <ComfyRoot>\ComfyUI and the
    install record beside it, in <ComfyRoot>. Omitted, it defaults to
    %LOCALAPPDATA%\LocalCanvas\comfyui -- a directory this project owns, chosen
    because it is nowhere near where anyone keeps an existing installation.

.PARAMETER ModelsRoot
    Where models live. Omitted, it is the installation's own models directory.
    Given, the directory tree is created and recorded. Nothing is downloaded,
    and ComfyUI is NOT told about it: pointing ComfyUI at another directory
    edits ComfyUI's own configuration, which is a separate action that has to
    be asked for explicitly and is not part of this script.

.PARAMETER Manifest
    The JSON manifest that defines a known-good installation. Resolution order
    when omitted: config\local\comfy-bootstrap.json if it exists, otherwise
    comfy\manifest.json. See config\examples\comfy-bootstrap.example.json.

.PARAMETER Profile
    Which set of the manifest to install. Minimal (the default) is a
    LocalCanvas-compatible ComfyUI runtime and nothing more, and it downloads
    no model at all -- the manifest format refuses to put one in it.
    Recommended adds the manifest's small image stack. Video adds the video
    runtime and is NEVER part of an ordinary Minimal or Recommended run.
    There is no Full and no Everything.

.PARAMETER InstallModels
    Download the models the selected profile names. Without this switch no
    model is fetched under any profile, and the run says what it skipped.
    With it, the files, their approximate total size, where they land, their
    licences, whether any is gated and whether a token is needed are all
    printed BEFORE anything is fetched, and then you are asked.

.PARAMETER AcceptModelDownloads
    Answer that question in advance, for a session that cannot be asked. It
    skips the QUESTION and never the list: the plan above is printed either
    way, because a log that does not say what was downloaded is the same
    failure one step later.

.PARAMETER DryRun
    Print the plan. Write nothing. With -InstallModels it plans every download
    and performs none -- not one byte is requested.

.EXAMPLE
    .\comfy\setup.ps1 -DryRun
    .\comfy\setup.ps1 -ComfyRoot 'C:\LocalCanvas\comfyui'
    .\comfy\setup.ps1 -ComfyRoot 'C:\LocalCanvas\comfyui' -ModelsRoot 'C:\LocalCanvas\models'
    .\comfy\setup.ps1 -Profile Recommended -InstallModels
#>
[CmdletBinding()]
param(
    [string]$ComfyRoot,
    [string]$ModelsRoot,
    [string]$Manifest,
    [ValidateSet('Minimal', 'Recommended', 'Video')][string]$Profile = 'Minimal',
    [switch]$InstallModels,
    [switch]$AcceptModelDownloads,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Bootstrap.ps1')

# The model directories ComfyUI itself reads. Directory names, not model
# families: LocalCanvas names no model family anywhere.
$script:LcModelDirectories = @(
    'checkpoints', 'clip', 'clip_vision', 'configs', 'controlnet',
    'diffusion_models', 'embeddings', 'loras', 'style_models',
    'upscale_models', 'vae'
)

function Resolve-LcFullPath {
    <#
        An argument turned into an absolute path, without Resolve-Path -- which
        requires the path to exist, and the whole point here is that it usually
        does not yet. Relative paths resolve against the shell's current
        directory, which is not always the process's.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $combined = [System.IO.Path]::Combine($PWD.ProviderPath, $Path)
    $full = [System.IO.Path]::GetFullPath($combined)
    # Trim a trailing separator, but never off a root: 'D:\' trimmed is 'D:',
    # which is drive-RELATIVE, and every Join-Path after it would build a path
    # somewhere else entirely.
    if ($full -ne [System.IO.Path]::GetPathRoot($full)) { $full = $full.TrimEnd('\') }
    return $full
}

function Get-LcDefaultComfyRoot {
    $base = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
    if (-not $base) {
        throw ('There is no LOCALAPPDATA on this machine, so there is no safe default ' +
            'install location. Pass -ComfyRoot and name the directory yourself.')
    }
    return (Join-Path (Join-Path $base 'LocalCanvas') 'comfyui')
}

function Get-LcTimestamp {
    # InvariantCulture: ':' is the culture's time separator in a .NET format
    # string, so on some machines this would otherwise not be ISO-8601 at all.
    return (Get-Date).ToUniversalTime().ToString(
        'yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-LcTimestampText {
    <#
        The timestamp out of a record that has been through ConvertFrom-Json.

        ConvertFrom-Json turns an ISO-8601 string into a [datetime], and
        "$value" then renders it in the machine's own culture -- so the record
        this script wrote would never compare equal to the record it is about
        to write, and every run would rewrite the file and call it a change.
        Measured: a round trip produced '09/11/2026 14:27:30' from
        '2026-09-11T14:27:30Z'.
    #>
    param($Value)
    if ($Value -is [datetime]) {
        return $Value.ToUniversalTime().ToString(
            'yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return "$Value"
}

function Resolve-LcManifestPath {
    param([string]$Requested)
    if ($Requested) { return (Resolve-LcFullPath -Path $Requested) }
    $repoRoot = Get-LcRepoRoot
    $local = Join-Path $repoRoot 'config\local\comfy-bootstrap.json'
    if (Test-Path -LiteralPath $local -PathType Leaf) { return $local }
    return (Join-Path $repoRoot 'comfy\manifest.json')
}

function Sync-LcPinnedCheckout {
    <#
        Put $Path on exactly $Revision.

        Two routes, because servers differ. Asking for one commit is cheap and
        is what a pin deserves, but a server only serves an arbitrary commit id
        when it has been configured to (uploadpack.allowAnySHA1InWant), which
        most are not. So if that is refused, the whole history is fetched and
        the commit checked out from it. Either way the caller verifies HEAD
        afterwards: the pin is not a note, it is the thing that got checked out.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Revision
    )
    $direct = Invoke-LcGitMutation -Arguments @('fetch', '--depth', '1', 'origin', $Revision) `
        -WorkingDirectory $Path -Target $Path -AllowFailure
    if ($direct.ExitCode -eq 0) {
        [void](Invoke-LcGitMutation -Arguments @('checkout', '--detach', 'FETCH_HEAD') `
                -WorkingDirectory $Path -Target $Path)
        return
    }
    Write-LcDetail 'The server would not serve that commit on its own; fetching the history instead.'
    [void](Invoke-LcGitMutation -Arguments @('fetch', '--tags', 'origin') `
            -WorkingDirectory $Path -Target $Path)
    [void](Invoke-LcGitMutation -Arguments @('checkout', '--detach', $Revision) `
            -WorkingDirectory $Path -Target $Path)
}

function Install-LcPinnedRepository {
    <#
        Bring one repository to one pinned commit, or refuse and leave it
        exactly as it was.

        The three refusals are the ones that protect somebody else's data, and
        each of them changes nothing:

          * a directory that is not a git repository is never turned into one;
          * a repository with local changes is never updated, reset or cleaned;
          * a checkout that does not land on the pinned commit is a failure,
            not a warning.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Revision,
        [AllowEmptyString()][string]$Label = '',
        [Parameter(Mandatory)][string]$What
    )

    $named = if ($Label) { "$Revision ($Label)" } else { $Revision }
    $state = Get-LcGitRepositoryState -Path $Path

    if ($state.Kind -eq 'NotARepository') {
        throw ("There is already something at '$Path', and it is not a git repository. " +
            "$What was NOT installed and nothing in that directory was read, moved or " +
            'changed. Move it aside, or choose another location, and run this again.')
    }

    if ($state.Kind -eq 'Repository') {
        if ($state.Dirty) {
            throw ("The repository at '$Path' has local changes. $What was left exactly as " +
                'it is: this script does not update, reset or clean a repository somebody ' +
                'has edited. Commit or revert them, or move the directory aside, and run ' +
                'this again.')
        }
        if ($state.Head -eq $Revision) {
            Write-LcOk "$What is already at $named"
            return 'unchanged'
        }
        $current = if ($state.Head) { $state.Head } else { 'an unknown commit' }
        Invoke-LcStep -Description "$What -- check out $named in $Path (currently $current)" -Action {
            Sync-LcPinnedCheckout -Path $Path -Revision $Revision
        }
    } else {
        Invoke-LcStep -Description "$What -- clone $Repository into $Path at $named" -Action {
            New-LcBootstrapDirectory -Path $Path
            [void](Invoke-LcGitMutation -Arguments @('init', '--quiet') -WorkingDirectory $Path -Target $Path)
            [void](Invoke-LcGitMutation -Arguments @('remote', 'add', 'origin', $Repository) `
                    -WorkingDirectory $Path -Target $Path)
            Sync-LcPinnedCheckout -Path $Path -Revision $Revision
        }
    }

    if (Test-LcBootstrapDryRun) { return 'planned' }

    $after = Get-LcGitRepositoryState -Path $Path
    if ($after.Head -ne $Revision) {
        throw ("$What was supposed to be at $Revision and is at '$($after.Head)'. The pinned " +
            'revision is what makes this installation reproducible, so this is a failure ' +
            'rather than a warning.')
    }
    Write-LcOk "$What is at $named"
    return 'installed'
}

function ConvertTo-LcJsonText {
    <#
        One string, as a JSON string literal, spelled the same way everywhere.

        Not ConvertTo-Json, and this is the second half of a defect whose first
        half was fixed by hand: the record has to compare equal to ITSELF, and
        the shell kept spelling it differently.

          * measured: install under pwsh, re-run under Windows PowerShell 5.1
            and the record is rewritten with a different length and a different
            hash. "Running it twice changes nothing" was false across the two
            hosts (README.md supports only PowerShell 7 or newer; 5.1 ran this
            layer then and cannot reach this script at all since T-0294);
          * and the difference is not only the indentation. Measured on one
            string in both shells: Windows PowerShell 5.1 escapes the four
            characters  less-than, greater-than, ampersand and apostrophe  as
            six-character unicode escapes (003c, 003e, 0026, 0027), and
            PowerShell 7 writes each of them
            as itself. So a path containing an ampersand -- an ordinary thing
            for a directory name to contain, and measured as such -- would have
            gone on rewriting the record after the indentation was dealt with.
            (Neither shell escapes non-ASCII letters. An earlier version of
            this comment said they differed there; they do not, and that
            sentence was wrong.)

        So the whole document is written out by hand above, and this is the
        only place a value is escaped: backslash, quote, the five short escapes
        and anything below U+0020. Everything else, non-ASCII included, is
        written as itself into a UTF-8 file with no BOM.
    #>
    param([AllowEmptyString()][AllowNull()][string]$Value)
    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append('"')
    foreach ($character in "$Value".ToCharArray()) {
        if ($character -ceq '"') { [void]$builder.Append('\"') }
        elseif ($character -ceq '\') { [void]$builder.Append('\\') }
        elseif ($character -ceq "`b") { [void]$builder.Append('\b') }
        elseif ($character -ceq "`f") { [void]$builder.Append('\f') }
        elseif ($character -ceq "`n") { [void]$builder.Append('\n') }
        elseif ($character -ceq "`r") { [void]$builder.Append('\r') }
        elseif ($character -ceq "`t") { [void]$builder.Append('\t') }
        elseif ([int][char]$character -lt 0x20) {
            [void]$builder.Append('\u{0:x4}' -f [int][char]$character)
        } else { [void]$builder.Append($character) }
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Get-LcInstallRecordJson {
    <#
        The record, as the exact text that would be on disk.

        'state' is why the record is written BEFORE the cloning starts as well
        as after it. A run interrupted halfway would otherwise leave a ComfyUI
        checkout with no record beside it -- and the next run would read that
        as somebody else's installation, refuse to touch it, and report success
        over a half-finished directory that can never be finished. Claiming the
        root first, as 'installing', keeps an interrupted install resumable and
        keeps the refusal rule honest.
    #>
    param(
        [Parameter(Mandatory)]$ManifestData,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Nodes,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$AppDirectory,
        [Parameter(Mandatory)][string]$Models,
        [Parameter(Mandatory)][string]$Profile,
        [Parameter(Mandatory)][string]$InstalledAt,
        [Parameter(Mandatory)][ValidateSet('installing', 'complete')][string]$State
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('{')
    $lines.Add('  "schema": ' + (ConvertTo-LcJsonText (Get-LcBootstrapSchema)) + ',')
    $lines.Add('  "state": ' + (ConvertTo-LcJsonText $State) + ',')
    $lines.Add('  "installedAt": ' + (ConvertTo-LcJsonText $InstalledAt) + ',')
    $lines.Add('  "comfyRoot": ' + (ConvertTo-LcJsonText $Root) + ',')
    $lines.Add('  "appDirectory": ' + (ConvertTo-LcJsonText $AppDirectory) + ',')
    $lines.Add('  "modelsRoot": ' + (ConvertTo-LcJsonText $Models) + ',')
    # The profile is recorded because it is what decides which of the
    # manifest's entries this installation actually has. Two runs of the same
    # manifest under different profiles are different installations, and
    # without this field the record for a profile with no custom nodes would
    # be identical to the record for another one.
    $lines.Add('  "profile": ' + (ConvertTo-LcJsonText $Profile) + ',')
    $lines.Add('  "manifest": {')
    $lines.Add('    "path": ' + (ConvertTo-LcJsonText $ManifestData.Path) + ',')
    $lines.Add('    "sha256": ' + (ConvertTo-LcJsonText $ManifestData.Sha256))
    $lines.Add('  },')
    $lines.Add('  "comfyui": {')
    $lines.Add('    "repository": ' + (ConvertTo-LcJsonText $ManifestData.ComfyUI.Repository) + ',')
    $lines.Add('    "revision": ' + (ConvertTo-LcJsonText $ManifestData.ComfyUI.Revision) + ',')
    $lines.Add('    "revisionLabel": ' + (ConvertTo-LcJsonText $ManifestData.ComfyUI.RevisionLabel))
    $lines.Add('  },')
    # The nodes this profile installs, not every node in the manifest: a record
    # that listed a Video pack beside a Recommended installation would describe
    # something that is not on the disk it sits beside.
    if ($Nodes.Count -eq 0) {
        $lines.Add('  "customNodes": []')
    } else {
        $lines.Add('  "customNodes": [')
        for ($index = 0; $index -lt $Nodes.Count; $index++) {
            $node = $Nodes[$index]
            $comma = if ($index -lt $Nodes.Count - 1) { ',' } else { '' }
            $lines.Add('    {')
            $lines.Add('      "name": ' + (ConvertTo-LcJsonText $node.Name) + ',')
            $lines.Add('      "repository": ' + (ConvertTo-LcJsonText $node.Repository) + ',')
            $lines.Add('      "revision": ' + (ConvertTo-LcJsonText $node.Revision) + ',')
            $lines.Add('      "revisionLabel": ' + (ConvertTo-LcJsonText $node.RevisionLabel))
            $lines.Add('    }' + $comma)
        }
        $lines.Add('  ]')
    }
    $lines.Add('}')
    # "`n" and not [Environment]::NewLine, and written by hand and not by
    # ConvertTo-Json: see ConvertTo-LcJsonText. Every byte of this file has to
    # be decided here, or the file stops comparing equal to itself.
    return (($lines -join "`n") + "`n")
}

function Write-LcInstallRecord {
    <#
        Write the record only when it would differ from the one already there.

        The no-op detection is the best idea in the reference stack, and it
        is what makes a second run genuinely idempotent
        rather than merely harmless: a rewrite with identical content still
        changes a modification time, and then "nothing changed" is not a
        statement anybody can check.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Candidate,
        [Parameter(Mandatory)][scriptblock]$WithTimestamp
    )
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $existing = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ($existing -eq $Candidate) {
            Write-LcOk "The install record is already up to date: $Path"
            return 'unchanged'
        }
    }
    $content = & $WithTimestamp
    Invoke-LcStep -Description "write the install record $Path" -Action {
        Set-LcBootstrapFile -Path $Path -Content $content
    }
    return 'written'
}

try {
    $context = Initialize-LcBootstrap -DryRun:$DryRun

    $profileName = ConvertTo-LcProfileName -Name $Profile
    $root = if ($ComfyRoot) { Resolve-LcFullPath -Path $ComfyRoot } else { Get-LcDefaultComfyRoot }
    $appDirectory = Join-Path $root 'ComfyUI'
    $manifestPath = Resolve-LcManifestPath -Requested $Manifest

    Write-LcBanner
    Write-LcInfo 'LocalCanvas ComfyUI bootstrap'
    if ($context.DryRun) {
        Write-LcDetail 'Mode:      DRY RUN - this run writes nothing at all'
    } else {
        Write-LcDetail 'Mode:      install'
    }
    Write-LcDetail "Root:      $root"
    Write-LcDetail "Manifest:  $manifestPath"
    Write-LcDetail "Profile:   $profileName"
    Write-Host ''

    $manifestData = Read-LcBootstrapManifest -Path $manifestPath
    $profileNodes = @(Select-LcProfileNodes -Nodes $manifestData.CustomNodes -Profile $profileName)
    $profileModels = @(Select-LcProfileModels -Models $manifestData.Models -Profile $profileName)
    Write-LcOk ("Manifest read: $($profileNodes.Count) custom node(s) and " +
        "$($profileModels.Count) model(s) in profile '$profileName', " +
        "sha256 $($manifestData.Sha256)")
    if (-not $InstallModels) {
        Write-LcDetail ("No model will be downloaded: -InstallModels was not given. " +
            "Profile '$profileName' names $($profileModels.Count) model(s); pass " +
            '-InstallModels to see what they are and be asked about them.')
    }

    $git = Resolve-LcGitCommand
    Write-LcDetail "git:       $git"

    $installation = Get-LcComfyInstallation -Root $root
    if ($installation.Kind -eq 'Existing') {
        Write-Host ''
        Write-LcOk 'A ComfyUI is already installed here. LocalCanvas changed nothing.'
        Write-LcDetail "Root:      $root"
        foreach ($line in $installation.Evidence) { Write-LcDetail "Found:     $line" }
        Write-Host ''
        Write-LcDetail 'This script installs a ComfyUI only where there is none. It does not write'
        Write-LcDetail 'inside, update, reconfigure or repair an installation it did not create, and'
        Write-LcDetail 'it has not read anything in this one beyond the file names above.'
        Write-LcDetail 'Nothing was installed, and that is the expected outcome here.'
        Write-Host ''
        exit 0
    }
    if ($installation.Kind -eq 'Occupied') {
        throw ("'$root' already contains something that is not a ComfyUI and not an " +
            "installation this script made: $($installation.Evidence -join '; '). Nothing " +
            'in it was changed. Choose an empty directory, or pass -ComfyRoot somewhere else.')
    }
    if ($installation.Kind -eq 'Ours') {
        Write-LcOk "This installation was made by this script; re-checking it against the manifest."
    }

    # RULE ZERO, at every path this run was given and not only at the root it
    # installs into. -ModelsRoot pointed inside somebody's ComfyUI used to
    # create the model directory tree in it; an explicitly named path is not a
    # licence to write there. A person who passes -ModelsRoot at their old
    # installation is asking LocalCanvas to USE the models in it, not to
    # reorganise the directory. Both refusals are non-zero exits, because a
    # refusal is not a no-op, and both name what was found.
    $enclosing = Find-LcEnclosingInstallation -Path $root -ExcludeSelf
    if ($enclosing) {
        throw ("'$root' is inside a ComfyUI this script did not install: " +
            "$($enclosing.Root) (main.py in $($enclosing.AppDirectory)). " +
            'Nothing was changed. Installing there would write inside somebody else''s ' +
            'installation, which this script does not do under any argument. Choose a ' +
            'location outside it.')
    }

    $models = if ($ModelsRoot) { Resolve-LcFullPath -Path $ModelsRoot } else { Join-Path $appDirectory 'models' }
    $enclosing = Find-LcEnclosingInstallation -Path $models
    if ($enclosing) {
        throw ("-ModelsRoot '$models' is inside a ComfyUI this script did not install: " +
            "$($enclosing.Root) (main.py in $($enclosing.AppDirectory)). " +
            'Nothing was changed, and no directory was created in it. ' +
            'LocalCanvas does not write inside an installation it did not make, and an ' +
            'explicitly named path does not change that. Point -ModelsRoot at a directory ' +
            'outside that installation; to USE the models already in it, leave them where ' +
            'they are -- nothing here has to move for ComfyUI to read them.')
    }
    Write-LcDetail "Models:    $models"
    Write-Host ''

    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        Invoke-LcStep -Description "create $root" -Action {
            New-LcBootstrapDirectory -Path $root
        }
    }

    $recordPath = Get-LcInstallRecordPath -Root $root
    $previous = $installation.Record
    $stamp = if ($previous -and (Test-LcHasProperty -Object $previous -Name 'installedAt')) {
        ConvertTo-LcTimestampText -Value $previous.installedAt
    } else {
        Get-LcTimestamp
    }
    $recordOf = {
        param([string]$State, [string]$At)
        Get-LcInstallRecordJson -ManifestData $manifestData -Nodes $profileNodes -Root $root `
            -AppDirectory $appDirectory -Models $models -Profile $profileName `
            -InstalledAt $At -State $State
    }
    if (-not $previous) {
        [void](Write-LcInstallRecord -Path $recordPath `
                -Candidate (& $recordOf 'installing' $stamp) `
                -WithTimestamp { & $recordOf 'installing' (Get-LcTimestamp) })
    }

    [void](Install-LcPinnedRepository -Path $appDirectory `
            -Repository $manifestData.ComfyUI.Repository `
            -Revision $manifestData.ComfyUI.Revision `
            -Label $manifestData.ComfyUI.RevisionLabel `
            -What 'ComfyUI')

    # THE FOLDER COMFYUI SAVES WORKFLOWS INTO, created here and only here.
    #
    # A ComfyUI that has never been started has no user\default\workflows, and
    # that is exactly the path a user is told to configure as their workflow
    # source. Measured on a Minimal bootstrap (T-0173, B2):
    # scripts\sync-workflows.ps1 -DryRun against it exited 2 with "this folder
    # does not exist ... there is nothing to fall back to", and creating the
    # empty folder made the identical command exit 0. So a bootstrap that
    # stops one step short of it hands over an installation whose very next
    # documented step fails.
    #
    # RULE ZERO IS NOT WEAKENED BY IT, and that is structural rather than
    # careful: everything from here on is only reached for an installation
    # that was Absent or is Ours. 'Existing' -- a ComfyUI this script did not
    # install -- has already exited 0 above without a byte written, and
    # 'Occupied' has already thrown. This directory can therefore only ever
    # appear inside an installation this script made itself.
    #
    # It is a step like every other one, so -DryRun plans it and writes
    # nothing, and a second run finds it there and reports no change. ComfyUI
    # ignores user\ in its own .gitignore, so it is not a local change in the
    # checkout either, and the next run's dirty check does not see it.
    $workflowsDirectory = Join-Path (Join-Path (Join-Path $appDirectory 'user') 'default') 'workflows'
    if (-not (Test-Path -LiteralPath $workflowsDirectory -PathType Container)) {
        Invoke-LcStep -Description "create $workflowsDirectory" -Action {
            New-LcBootstrapDirectory -Path $workflowsDirectory
        }
    }

    if ($profileNodes.Count -gt 0) {
        $nodeRoot = Join-Path $appDirectory 'custom_nodes'
        if (-not (Test-Path -LiteralPath $nodeRoot -PathType Container)) {
            Invoke-LcStep -Description "create $nodeRoot" -Action {
                New-LcBootstrapDirectory -Path $nodeRoot
            }
        }
        foreach ($node in $profileNodes) {
            [void](Install-LcPinnedRepository -Path (Join-Path $nodeRoot $node.Name) `
                    -Repository $node.Repository `
                    -Revision $node.Revision `
                    -Label $node.RevisionLabel `
                    -What "custom node '$($node.Name)'")
        }
    }

    if ($ModelsRoot) {
        foreach ($directory in @($models) + @($script:LcModelDirectories | ForEach-Object { Join-Path $models $_ })) {
            if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
                Invoke-LcStep -Description "create $directory" -Action {
                    New-LcBootstrapDirectory -Path $directory
                }
            }
        }
    }

    # AFTER the runtime is in place and BEFORE the closing summary, because a
    # download is the one action here a person is asked about, and asking about
    # it is worth nothing if the thing being installed around it already
    # failed. $models has already been through Find-LcEnclosingInstallation
    # above, so a download can no more land inside somebody else's ComfyUI than
    # a directory can.
    if ($InstallModels) {
        Install-LcProfileModels -Models $profileModels -ModelsRoot $models `
            -Profile $profileName -Accepted:$AcceptModelDownloads
    }

    [void](Write-LcInstallRecord -Path $recordPath `
            -Candidate (& $recordOf 'complete' $stamp) `
            -WithTimestamp { & $recordOf 'complete' (Get-LcTimestamp) })

    Write-Host ''
    if ($context.DryRun) {
        Write-LcOk ("Dry run complete: $($context.Planned.Count) action(s) planned, " +
            "$($context.Performed.Count) performed. Nothing was written.")
    } elseif ($context.Performed.Count -eq 0) {
        Write-LcOk 'Already complete. Nothing needed changing.'
    } else {
        Write-LcOk "Bootstrap complete: $($context.Performed.Count) action(s) performed."
    }
    Write-LcField -Label 'ComfyUI' -Value "$appDirectory`n$($manifestData.ComfyUI.Revision)"
    Write-LcField -Label 'Record' -Value $recordPath
    if ($ModelsRoot) {
        Write-Host ''
        Write-LcDetail 'ComfyUI has not been told to read models from -ModelsRoot. That edits'
        Write-LcDetail 'ComfyUI''s own configuration file, and this script does not write there.'
    }
    # WHAT THE DOCTOR SHOULD BE TOLD TO REQUIRE. comfy/doctor.ps1 already takes
    # -RequireNodeClass and looks each name up in the live /object_info; a
    # profile that needs a node pack states the classes that pack registers,
    # and this line is the whole of the hand-off between the two. One
    # mechanism, not a second one -- and the names are printed exactly as the
    # manifest spells them, because the doctor's lookup is case-sensitive.
    $classes = @(Get-LcProfileNodeClasses -Nodes $manifestData.CustomNodes -Profile $profileName)
    Write-Host ''
    Write-LcDetail 'Check this installation against a running ComfyUI with:'
    if ($classes.Count -gt 0) {
        $quoted = @($classes | ForEach-Object { "'" + $_ + "'" })
        Write-LcDetail "  comfy\doctor.ps1 -RequireNodeClass $($quoted -join ',')"
    } else {
        Write-LcDetail '  comfy\doctor.ps1'
        Write-LcDetail ("  (profile '$profileName' names no node classes, so there is " +
            'nothing for -RequireNodeClass to ask about)')
    }

    Write-Host ''
    Write-LcDetail 'No Python environment was built and no package was installed: this script'
    Write-LcDetail 'installs source at a pinned revision and nothing else.'
    Write-Host ''
    exit 0
} catch {
    # -ErrorRecord writes a log file, and a dry run writes nothing -- including
    # when it fails.
    $isDryRun = $false
    try { $isDryRun = Test-LcBootstrapDryRun } catch { $isDryRun = [bool]$DryRun }
    if ($isDryRun) {
        Write-LcFailure -What 'The bootstrap did not complete' -Detail @("$($_.Exception.Message)") `
            -Fix 'Nothing was changed. Fix the problem above and run comfy\setup.ps1 again.'
    } else {
        Write-LcFailure -What 'The bootstrap did not complete' -Detail @("$($_.Exception.Message)") `
            -Fix 'Nothing was changed. Fix the problem above and run comfy\setup.ps1 again.' `
            -ErrorRecord $_
    }
    exit 1
}
