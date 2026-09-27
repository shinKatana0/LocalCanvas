#requires -Version 7.0
<#
.SYNOPSIS
    Builds the CURRENT checkout into a runnable local dogfood copy of the
    Windows launcher: artifacts\dev\LocalCanvas\LocalCanvas.exe.

.DESCRIPTION
    This is NOT a second launcher. It is the exact same launcher project,
    built the exact same way (Release, the win-x64 self-contained
    single-file publish profile) that launcher\package.ps1 uses for the
    release zip -- only the packaging mechanics differ. The two scripts
    share Invoke-LcLauncherPublish, Get-LcPackageVersion,
    Test-LcPackageEntryAllowed and Test-LcPackageEntryForbidden (all defined
    in launcher\package.ps1, dot-sourced below): there is one allowlist of
    what a LocalCanvas folder contains, one publish step, and one version
    reader, used by both.

    Unlike package.ps1, this build is allowed to run against an UNCOMMITTED
    checkout on purpose -- dogfooding means running what is on disk right
    now, work in progress included -- so there is no clean-tree gate, and
    the files this script copies come straight off the working tree.

    Four steps, in order:

      1. Publish the launcher (dotnet publish, the win-x64 profile), with
         the current commit's short SHA passed as SourceRevisionId so the
         exe's own ProductVersion/InformationalVersion reads
         "<version>+<short sha>" -- the one place this dev build's
         provenance is recorded that a user can see without opening a file.
      2. Stage the SAME allowlisted files package.ps1 zips, into a THROWAWAY
         staging folder under artifacts\dev\.staging -- never touching the
         real output folder yet.
      3. VERIFY the staged folder: every file is on the allowlist, nothing
         forbidden is present, and LocalCanvas.exe is there.
      4. Swap only the BUILD-OWNED files into artifacts\dev\LocalCanvas\,
         guided by a manifest this script writes and reads
         (.localcanvas-dev-build-manifest.json, inside that folder). A file
         this script did not put there -- a real .venv\, config\local\*
         content the setup wizard wrote, a .runtime\ this dev build's own
         launcher created -- is never touched, because it is never in the
         manifest. A file this script owned in an EARLIER build but does
         not want in this one is removed by its exact recorded path; nothing
         else in the destination is ever deleted, and a compile or publish
         failure leaves the destination exactly as it was (steps 1-3 happen
         before anything in the destination is touched).

.PARAMETER SkipPublish
    Reuse whatever is already at the publish profile's output directory
    instead of running `dotnet publish` again. For iterating on the staging
    and swap steps without waiting on a full self-contained publish.

.PARAMETER Run
    After a successful build, start the built LocalCanvas.exe (a plain
    Start-Process, no -Wait). If a LocalCanvas launcher is already running,
    single-instance behaviour is entirely the running exe's own: the new
    process signals the existing one and exits, and this script never
    inspects, signals or stops any process itself.

.PARAMETER LauncherProjectPathForTests
    TEST SEAM ONLY, never used by an ordinary build. Overrides which project
    `dotnet publish` runs, so the test suite can point it at a throwaway,
    deliberately broken copy of the project and prove that a real compile
    failure leaves artifacts\dev\LocalCanvas\ untouched -- without ever
    touching this repository's own launcher sources.

.PARAMETER RunStartPathForTests
    TEST SEAM ONLY, never used by an ordinary build. Overrides what -Run
    starts, so the test suite can point it at a harmless stub instead of
    launching the real, full LocalCanvas.exe during a test run.

.PARAMETER OutputRootPathForTests
    TEST SEAM ONLY, never used by an ordinary build. Overrides the folder
    this script treats as artifacts\dev (LocalCanvas\ and .staging\ are
    created under it). Without this, every pipeline test would build,
    rebuild and rmtree the REAL repository's own artifacts\dev -- exactly
    the folder that holds a developer's actual .venv, config\local content
    and .runtime once they have used this script for real. Every automated
    test in scripts\tests\run_tests.py passes this and never references the
    real path at all.

.EXAMPLE
    pwsh .\scripts\build-launcher.ps1
    pwsh .\scripts\build-launcher.ps1 -Run
#>

[CmdletBinding()]
param(
    [switch]$SkipPublish,
    [switch]$Run,
    [string]$LauncherProjectPathForTests,
    [string]$RunStartPathForTests,
    [string]$OutputRootPathForTests
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#: The one repo-relative layout an ORDINARY build ever writes to. Every dev
#: build lands in the same place on purpose, so a rebuild can find (and
#: preserve) what an earlier one left there. The success banner always names
#: this fixed label, even under -OutputRootPathForTests (a test-only seam;
#: see below) -- it describes the real, documented output layout, not
#: whatever throwaway folder one particular run happened to use.
$script:DevOutputRelative = 'artifacts\dev\LocalCanvas'
$script:ManifestFileName = '.localcanvas-dev-build-manifest.json'
$script:BuildInfoFileName = 'build-info.json'
#: A publish directory of this script's OWN, never shared with
#: launcher\package.ps1's release build (bin\publish\win-x64\). Sharing one
#: directory meant a dev build's -SkipPublish could silently pick up a
#: release-stamped exe (or the reverse for package.ps1), so the two now
#: never touch the same physical output at all -- a build that names one
#: publishes to the other's private, DEV-only folder regardless of which
#: ran most recently.
$script:DevPublishDirRelative = 'bin\publish\win-x64-dev'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

# Captured BEFORE dot-sourcing package.ps1: that script's own param block
# (-OutputDirectory, -AllowDirty, -SkipPublish) runs on ANY dot-source, even
# with no arguments given to it, and dot-sourcing binds those parameters into
# THIS script's scope -- so $SkipPublish above would otherwise be silently
# reset to $false by the dot-source itself, regardless of what was passed on
# this script's own command line. Measured: without this capture, -SkipPublish
# was silently ignored and a full publish ran every time.
$skipPublishRequested = [bool]$SkipPublish

# Reuse package.ps1's allowlist, version reader and publish step -- one
# source of truth shared with the release zip. Dot-sourcing it only defines
# functions and returns; see the comment at the bottom of that file.
. (Join-Path $repoRoot 'launcher\package.ps1')

function Test-LcStaleManifestEntryRemovable {
    <#
        May $Relative -- a path read from an EARLIER manifest, not from this
        run's own staging -- be deleted from $Destination?

        The manifest lives inside the user-writable output folder, so
        nothing in it is trusted for a deletion just because it is there:
        every entry is re-checked, independently, against three things.
        ALL must hold:

          - it resolves ([System.IO.Path]::GetFullPath) strictly inside
            $Destination -- rejects a "..\..\..." escape outright, string
            containment alone is not enough;
          - it is something this script could plausibly have written
            itself: LocalCanvas.exe, build-info.json, or a path
            Test-LcPackageEntryAllowed names;
          - it is never anywhere under .venv\, .runtime\ or config\local\ --
            except the one allowlisted placeholder, config\local\.gitkeep,
            which this script does own and already ships.

        Anything that fails any one of these is left alone; the caller
        reports the skip rather than silently doing nothing.
    #>
    param(
        [Parameter(Mandatory)][string]$Relative,
        [Parameter(Mandatory)][string]$Destination
    )
    $target = Join-Path $Destination $Relative
    $resolvedTarget = [System.IO.Path]::GetFullPath($target)
    $resolvedDestination = [System.IO.Path]::GetFullPath($Destination)
    $destinationPrefix = $resolvedDestination.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) +
        [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedTarget.StartsWith($destinationPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    $relativeSlash = $Relative -replace '\\', '/'
    $isProtected = (
        $relativeSlash -eq '.venv' -or
        $relativeSlash.StartsWith('.venv/', [System.StringComparison]::OrdinalIgnoreCase) -or
        $relativeSlash -eq '.runtime' -or
        $relativeSlash.StartsWith('.runtime/', [System.StringComparison]::OrdinalIgnoreCase) -or
        (
            ($relativeSlash -eq 'config/local' -or
                $relativeSlash.StartsWith('config/local/', [System.StringComparison]::OrdinalIgnoreCase)) -and
            $relativeSlash -ne $script:ConfigLocalPlaceholder
        )
    )
    if ($isProtected) { return $false }

    if ($relativeSlash -eq 'LocalCanvas.exe') { return $true }
    if ($relativeSlash -eq $script:BuildInfoFileName) { return $true }
    return (Test-LcPackageEntryAllowed -Path $relativeSlash)
}

$realLauncherProject = Join-Path $repoRoot 'launcher\LocalCanvas.Launcher'
$launcherProject = if ($LauncherProjectPathForTests) { $LauncherProjectPathForTests } else { $realLauncherProject }
# Derived from $launcherProject, not always $realLauncherProject: a test that
# overrides -LauncherProjectPathForTests with its own copy of the project
# must look for the exe under THAT copy, never under this repository's own
# launcher\ regardless of what the override points at. The directory itself
# is this script's own ($script:DevPublishDirRelative), never
# package.ps1's bin\publish\win-x64\ -- see the comment on that constant.
$publishDir = Join-Path $launcherProject $script:DevPublishDirRelative
$publishedExe = Join-Path $publishDir 'LocalCanvas.exe'

$devRoot = if ($OutputRootPathForTests) { $OutputRootPathForTests } else { Join-Path $repoRoot 'artifacts\dev' }
$destination = Join-Path $devRoot 'LocalCanvas'
$stagingRoot = Join-Path $devRoot '.staging'
$stagingPackageRoot = Join-Path $stagingRoot 'LocalCanvas'
$manifestPath = Join-Path $destination $script:ManifestFileName
$buildInfoPath = Join-Path $destination $script:BuildInfoFileName

Write-Host 'LocalCanvas developer build'
Write-Host "Repository: $repoRoot"

# -- provenance: the current commit, dirty or not ---------------------------

$shortSha = (& git -C $repoRoot rev-parse --short HEAD 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw ("Cannot determine the source revision (git rev-parse failed, exit " +
        "$LASTEXITCODE): $shortSha`nA developer build needs a git checkout.")
}
$shortSha = "$shortSha".Trim()
$porcelain = (& git -C $repoRoot status --porcelain 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "git status failed in $repoRoot (exit $LASTEXITCODE): $porcelain"
}
$dirty = [bool]$porcelain
$sourceLabel = if ($dirty) { "$shortSha + uncommitted changes" } else { $shortSha }

$version = Get-LcPackageVersion -RepoRoot $repoRoot
Write-Host "Version: $version (from launcher\Directory.Build.props)"
Write-Host "Source: $sourceLabel"

# -- 1. publish ---------------------------------------------------------

Invoke-LcLauncherPublish -LauncherProject $launcherProject -PublishedExePath $publishedExe `
    -SkipPublish:$skipPublishRequested `
    -ExtraPublishArgs @(
        # Overrides the win-x64 profile's own <PublishDir> (bin\publish\
        # win-x64\): a command-line property is a global property and wins
        # over one set inside the imported .pubxml, so this dev build's own
        # output never lands in -- or gets read back from -- the same
        # physical folder launcher\package.ps1's release build uses. See
        # $script:DevPublishDirRelative above.
        "-p:PublishDir=$publishDir\",
        "-p:SourceRevisionId=$shortSha",
        # Without this, the SDK's own AddSourceRevisionToInformationalVersion
        # target never runs unless a SourceLink package is referenced, and
        # SourceRevisionId above would be passed and silently ignored.
        '-p:SourceControlInformationFeatureSupported=true'
    )

$exeInfo = Get-Item -LiteralPath $publishedExe
$exeSha256 = Get-LcFileSha256 -Path $publishedExe
Write-Host "LocalCanvas.exe: $($exeInfo.Length) bytes, SHA-256 $exeSha256"

# -- 2. stage, into a throwaway folder -- the real destination is not
#    touched until the stage below is verified -------------------------

if (Test-Path -LiteralPath $stagingRoot) {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force
}
[void](New-Item -ItemType Directory -Path $stagingPackageRoot -Force)
Copy-Item -LiteralPath $publishedExe -Destination (Join-Path $stagingPackageRoot 'LocalCanvas.exe')

$trackedFiles = & git -C $repoRoot ls-files
if ($LASTEXITCODE -ne 0) {
    throw "git ls-files failed in $repoRoot (exit $LASTEXITCODE)."
}
$owned = [System.Collections.Generic.List[string]]::new()
$owned.Add('LocalCanvas.exe')
foreach ($relative in $trackedFiles) {
    if (-not (Test-LcPackageEntryAllowed -Path $relative)) { continue }
    $source = Join-Path $repoRoot ($relative -replace '/', '\')
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        # This build reads the WORKING TREE, uncommitted changes included,
        # not a clean commit -- unlike package.ps1's release zip, a dirty
        # tree is expected here. A file git still lists but that is missing
        # on disk right now (deleted, not yet staged) is skipped rather than
        # treated as a hard error.
        continue
    }
    $relativeWindows = $relative -replace '/', '\'
    $destinationFile = Join-Path $stagingPackageRoot $relativeWindows
    $destinationDir = Split-Path -Parent $destinationFile
    if (-not (Test-Path -LiteralPath $destinationDir)) {
        [void](New-Item -ItemType Directory -Path $destinationDir -Force)
    }
    Copy-Item -LiteralPath $source -Destination $destinationFile
    $owned.Add($relativeWindows)
}
Write-Host "Staged $($owned.Count) file(s) under $stagingPackageRoot"

# -- 3. verify the staged folder, reading it back rather than trusting the
#    staging step -- the same two allowlist checks package.ps1 uses to
#    verify the zip it writes ------------------------------------------

$stagedFiles = @(Get-ChildItem -LiteralPath $stagingPackageRoot -Recurse -File)
$forbidden = @()
$unexplained = @()
foreach ($file in $stagedFiles) {
    $relativeSlash = $file.FullName.Substring($stagingPackageRoot.Length + 1) -replace '\\', '/'
    $entryName = "LocalCanvas/$relativeSlash"
    if (Test-LcPackageEntryForbidden -EntryName $entryName) { $forbidden += $entryName; continue }
    if ($relativeSlash -eq 'LocalCanvas.exe') { continue }
    if (-not (Test-LcPackageEntryAllowed -Path $relativeSlash)) { $unexplained += $relativeSlash }
}
if ($forbidden.Count -gt 0) {
    throw ("Refused: the staged developer build contains forbidden entries:`n" + ($forbidden -join "`n"))
}
if ($unexplained.Count -gt 0) {
    throw ("Refused: the staged developer build contains entries the allowlist does not name:`n" +
        ($unexplained -join "`n"))
}
if ($stagedFiles.Count -ne $owned.Count) {
    throw ("Refused: staged $($stagedFiles.Count) file(s) but recorded $($owned.Count) as owned -- " +
        "the manifest would not match what was actually written.")
}
Write-Host "Verified: $($stagedFiles.Count) file(s), all on the allowlist, no forbidden pattern present."

# -- destination exe must not be in use -- checked BEFORE any swap, so a
#    running dev launcher never leaves the destination half-updated --------

$destinationExePath = Join-Path $destination 'LocalCanvas.exe'
if (Test-Path -LiteralPath $destinationExePath -PathType Leaf) {
    $handle = $null
    try {
        $handle = [System.IO.File]::Open(
            $destinationExePath, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    } catch [System.IO.IOException] {
        throw ("LocalCanvas.exe in $destination is in use - exit the running " +
            "LocalCanvas from its tray menu, then rebuild.")
    } finally {
        if ($handle) { $handle.Dispose() }
    }
}

# -- 4. swap: only the files this script owns, guided by its own manifest --

[void](New-Item -ItemType Directory -Path $destination -Force)

$previousOwned = @()
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    try {
        $previousManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        if ($previousManifest.owned_files) { $previousOwned = @($previousManifest.owned_files) }
    } catch {
        # A manifest this script cannot read is treated as "nothing recorded
        # yet": the worst that does is leave a stale build-owned file behind
        # from an earlier build (harmless) -- it can never make this script
        # delete something it does not already know it owns.
        $previousOwned = @()
    }
}

$ownedArray = @($owned)
$newOwnedSet = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]$ownedArray, [System.StringComparer]::OrdinalIgnoreCase)
$staleOwned = @($previousOwned | Where-Object { -not $newOwnedSet.Contains($_) })

# Remove only paths THIS SCRIPT recorded as its own in an earlier run, and
# that this build no longer wants -- never anything else already in the
# destination folder, which is exactly where a user's own .venv\,
# config\local\* content and .runtime\ live. The manifest is a file inside
# that same user-writable folder, so a tampered or hand-edited entry gets no
# special trust: Test-LcStaleManifestEntryRemovable re-derives, independently,
# whether $relative is even something safe to touch before anything is
# removed, and a rejected entry is reported rather than silently ignored.
foreach ($relative in $staleOwned) {
    if (-not (Test-LcStaleManifestEntryRemovable -Relative $relative -Destination $destination)) {
        Write-Warning "Skipped a manifest entry that is not safe to remove: $relative"
        continue
    }
    $target = Join-Path $destination $relative
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        Remove-Item -LiteralPath $target -Force
    }
}

foreach ($relative in $ownedArray) {
    $source = Join-Path $stagingPackageRoot $relative
    $target = Join-Path $destination $relative
    $targetDir = Split-Path -Parent $target
    if ($targetDir -and -not (Test-Path -LiteralPath $targetDir)) {
        [void](New-Item -ItemType Directory -Path $targetDir -Force)
    }
    Copy-Item -LiteralPath $source -Destination $target -Force
}

$builtUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')

$manifestOwned = @($ownedArray) + @($script:BuildInfoFileName)
$manifest = [ordered]@{
    version      = $version
    source       = $sourceLabel
    built_utc    = $builtUtc
    owned_files  = $manifestOwned
}
($manifest | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $manifestPath -NoNewline -Encoding utf8

$buildInfo = [ordered]@{
    version       = $version
    source        = $shortSha
    dirty         = $dirty
    configuration = 'Release'
    built_utc     = $builtUtc
}
($buildInfo | ConvertTo-Json) | Set-Content -LiteralPath $buildInfoPath -NoNewline -Encoding utf8

# The staging folder is this run's own implementation detail, removed by its
# own exact, literal path -- never the destination, and never a wildcard.
Remove-Item -LiteralPath $stagingRoot -Recurse -Force

$exeRelativePath = Join-Path $script:DevOutputRelative 'LocalCanvas.exe'

Write-Host ''
Write-Host 'LocalCanvas developer build ready:'
Write-Host $exeRelativePath
Write-Host 'Version:'
Write-Host $version
Write-Host 'Source:'
Write-Host $sourceLabel

if ($Run) {
    $toStart = if ($RunStartPathForTests) { $RunStartPathForTests } else { Join-Path $destination 'LocalCanvas.exe' }
    Write-Host ''
    Write-Host "Starting: $toStart"
    # Plain start, no -Wait: if a LocalCanvas launcher is already running,
    # single-instance behaviour is the running exe's own (it signals the
    # existing primary and exits) -- this script never looks for, signals or
    # stops any process itself.
    Start-Process -FilePath $toStart
}
