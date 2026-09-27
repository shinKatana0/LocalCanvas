#requires -Version 7.0
<#
.SYNOPSIS
    Builds LocalCanvas-<version>-windows-x64.zip: the one file a Windows user
    downloads, extracts and runs.

.DESCRIPTION
    Four steps, in order:

      1. Publish the launcher (dotnet publish, the win-x64 profile) -- one
         self-contained LocalCanvas.exe that needs no .NET installed.
      2. Assemble an ALLOWLIST, not a denylist, into a temporary staging
         folder: which files ship is decided here, once, and everything not
         named is left out by construction rather than by remembering to
         exclude it.
      3. Zip the staging folder into LocalCanvas-<version>-windows-x64.zip,
         with a single top-level LocalCanvas\ folder inside it.
      4. VERIFY the zip it just wrote, reading the archive back rather than
         trusting the staging step: every entry is on the allowlist, no
         forbidden pattern is present, and LocalCanvas.exe is exactly where
         the launcher expects to find itself
         (LocalCanvas\LocalCanvas.exe -- see Core/LauncherRoot.cs).

    The allowlist is read against `git ls-files`, never against the working
    tree directly: a local edit under config\local\ or a stray file dropped
    next to a tracked one must not be able to reach the zip. That is also why
    a dirty tree is refused by default (see -AllowDirty).

    WHAT SHIPS, at the root of the zip's single LocalCanvas\ folder:
    LocalCanvas.exe; scripts\ without scripts\tests\; gateway\ without
    gateway\tests\ and without gateway\conftest.py (pytest-only: it puts
    gateway\ on sys.path for pytest, and nothing setup.ps1, start.ps1 or the
    gateway package itself ever reads); comfy\ without any comfy\tests\; config\examples\;
    config\local\.gitkeep only; workflows\examples\; docs\; LICENSE,
    README.md, README.ru.md, README.ja.md, CHANGELOG.md, SECURITY.md,
    CONTRIBUTING.md. Nothing else -- in particular never app\, the launcher's
    own sources, .github\, .gitignore, any directory named tests, or anything
    under a build output, a cache or config\local\ besides the placeholder.

.PARAMETER OutputDirectory
    Where the zip is written. Defaults to launcher\dist\, which is gitignored.
    This script only ever writes and deletes its own staging subfolder and
    the one zip filename it produces, both by exact path; it refuses outright
    to use a folder that already has files in it and that an earlier run of
    this script did not create (see Assert-LcSafeOutputDirectory) -- it never
    deletes -OutputDirectory itself or anything else already in it.

.PARAMETER AllowDirty
    Skip the clean-tree check. FOR LOCAL TESTING ONLY: the files this script
    copies for everything except the built exe come straight off the working
    tree once the tree is known to match `git ls-files`, and that guarantee is
    exactly what a dirty tree takes away. A packaged zip meant for anyone else
    is built from a clean tree.

.PARAMETER SkipPublish
    Reuse whatever is already at the publish profile's output directory
    instead of running `dotnet publish` again. For iterating on the staging
    and verification steps without waiting on a full self-contained publish.

.EXAMPLE
    pwsh -File launcher\package.ps1
    pwsh -File launcher\package.ps1 -OutputDirectory C:\temp\lc-package -AllowDirty
#>

[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [switch]$AllowDirty,
    [switch]$SkipPublish
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Layout constants -- named once, used by both the staging step and the
# independent verification step that reads the produced zip back.
# ---------------------------------------------------------------------------

#: The single folder every shipped file sits under, inside the zip.
$script:ZipRootFolder = 'LocalCanvas'
#: Root-level files that ship as-is.
$script:RootAllowlist = @(
    'LICENSE', 'README.md', 'README.ru.md', 'README.ja.md',
    'CHANGELOG.md', 'SECURITY.md', 'CONTRIBUTING.md'
)
#: Directories that ship in full, except for a directory named "tests"
#: anywhere under them -- see Test-LcPackageEntryAllowed.
$script:DirectoryAllowlist = @('scripts', 'gateway', 'comfy', 'docs')
#: Narrower directories that ship only a part of themselves.
$script:ConfigExamplesPrefix = 'config/examples/'
$script:ConfigLocalPlaceholder = 'config/local/.gitkeep'
$script:WorkflowExamplesPrefix = 'workflows/examples/'

function Test-LcPackageEntryAllowed {
    <#
        Is this git-relative path (forward slashes, as `git ls-files` prints
        it) one the allowlist names? The single decision both the staging
        copy and the post-hoc zip verification are built on -- so the two
        cannot quietly drift apart from each other.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if ($script:RootAllowlist -contains $Path) { return $true }
    # pytest-only: puts gateway\ on sys.path for pytest and is read by nothing
    # setup.ps1, start.ps1 or the gateway package itself ever imports.
    if ($Path -eq 'gateway/conftest.py') { return $false }
    if ($Path -eq $script:ConfigLocalPlaceholder) { return $true }
    if ($Path.StartsWith($script:ConfigExamplesPrefix, [System.StringComparison]::Ordinal)) { return $true }
    if ($Path.StartsWith($script:WorkflowExamplesPrefix, [System.StringComparison]::Ordinal)) { return $true }
    $segments = $Path -split '/'
    if ($segments.Count -lt 2) { return $false }
    if ($script:DirectoryAllowlist -notcontains $segments[0]) { return $false }
    # No directory component named "tests", anywhere under the allowed root:
    # scripts/tests/, gateway/tests/ and a comfy/tests/ this checkout does not
    # have yet are all excluded by the same rule.
    if ($segments[1..($segments.Count - 1)] -contains 'tests') { return $false }
    return $true
}

function Test-LcPackageEntryForbidden {
    <#
        The independent half of the check: read straight off the zip entry's
        own name, with no reference to the allowlist above, so a bug in the
        staging step's use of that allowlist cannot also hide from
        verification. Every one of these strings is something that must never
        appear in a shipped zip, spelled out rather than derived.
    #>
    param([Parameter(Mandatory)][string]$EntryName)
    $normalized = $EntryName -replace '\\', '/'
    $forbiddenPrefixes = @(
        "$($script:ZipRootFolder)/app/",
        "$($script:ZipRootFolder)/.github/",
        "$($script:ZipRootFolder)/.venv/",
        "$($script:ZipRootFolder)/.runtime/"
    )
    foreach ($prefix in $forbiddenPrefixes) {
        if ($normalized.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    if ($normalized -eq "$($script:ZipRootFolder)/.gitignore") { return $true }
    if ($normalized -eq "$($script:ZipRootFolder)/gateway/conftest.py") { return $true }
    # The launcher's own C# sources: LocalCanvas.exe itself is allowed, and is
    # the only thing directly under the zip root beside the shipped folders.
    if ($normalized -match '(?i)^LocalCanvas/launcher/') { return $true }
    if ($normalized -match '(?i)(^|/)tests/') { return $true }
    if ($normalized -match '(?i)__pycache__') { return $true }
    if ($normalized -match '(?i)\.egg-info(/|$)') { return $true }
    if ($normalized -match '(?i)(^|/)build/') { return $true }
    # config/local ships only its placeholder; anything else there is a
    # user's own machine-specific configuration and must never be packaged.
    if ($normalized -match '(?i)^LocalCanvas/config/local/' -and
        $normalized -ne "$($script:ZipRootFolder)/config/local/.gitkeep") {
        return $true
    }
    return $false
}

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

function Get-LcFileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

#: The marker this script leaves in an -OutputDirectory it created, so a later
#: run (or a second run pointed at the same folder) can tell "an output folder
#: this script made" apart from "some other folder that happens to be empty,
#: or that a caller pointed -OutputDirectory at by mistake." See
#: Assert-LcSafeOutputDirectory -- the only thing this script's own cleanup
#: ever deletes is its own staging\ subfolder and the one zip filename it is
#: about to write, both by exact literal path. It never deletes
#: -OutputDirectory itself, and never wildcard-deletes anything in it.
$script:OutputMarkerName = '.localcanvas-package-output'
$script:OutputMarkerText = (
    "This folder is launcher\package.ps1's own output folder.`n" +
    "Everything in it is safe to delete; this file is only how the script " +
    "tells its own folder apart from one it did not create.`n"
)

function Assert-LcSafeOutputDirectory {
    <#
        Claim $Path as this script's output folder, or refuse outright.

        A folder this script did not make is left completely alone: no
        Remove-Item of any kind runs against it or its contents. That is the
        fix for the bug this function replaces -- the previous version ran
        `Remove-Item -LiteralPath $OutputDirectory -Recurse -Force`, which
        deletes whatever is already there. `-OutputDirectory .` inside an
        unrelated, non-empty folder must find files it does not recognise and
        stop, never wipe them.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        [void](New-Item -ItemType Directory -Path $Path -Force)
        Set-Content -LiteralPath (Join-Path $Path $script:OutputMarkerName) `
            -Value $script:OutputMarkerText -NoNewline
        return
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Refused: $Path exists and is not a folder."
    }
    $marker = Join-Path $Path $script:OutputMarkerName
    if (Test-Path -LiteralPath $marker -PathType Leaf) { return }
    $existing = @(Get-ChildItem -LiteralPath $Path -Force)
    if ($existing.Count -gt 0) {
        throw ("Refused: $Path already has files in it, and this script did not create it " +
            "(there is no $script:OutputMarkerName marker in it). This script only ever " +
            "deletes its own staging folder and the one zip it is about to write -- never " +
            "the output folder itself or anything else already in it. Pass -OutputDirectory " +
            "an empty or new folder, or clear this one out yourself first. NOTHING has been " +
            "deleted.")
    }
    # Empty, and not yet marked: claim it for this and later runs.
    Set-Content -LiteralPath $marker -Value $script:OutputMarkerText -NoNewline
}

function Get-LcPackageVersion {
    <#
        The one source of truth: Directory.Build.props's <Version>, shared by
        the launcher and its tests. No second copy of the version number is
        read or written anywhere in this script.
    #>
    param([Parameter(Mandatory)][string]$RepoRoot)
    $propsPath = Join-Path $RepoRoot 'launcher\Directory.Build.props'
    if (-not (Test-Path -LiteralPath $propsPath -PathType Leaf)) {
        throw "Cannot read the package version: $propsPath is missing."
    }
    [xml]$props = Get-Content -LiteralPath $propsPath -Raw
    $version = ($props.Project.PropertyGroup | Where-Object { $_.Version } | Select-Object -First 1).Version
    if (-not $version) {
        throw "Cannot read the package version: no <Version> in $propsPath."
    }
    return "$version".Trim()
}

function Invoke-LcLauncherPublish {
    <#
        Runs the launcher's win-x64 publish profile (self-contained,
        single-file, Release) -- the one step this script and
        scripts\build-launcher.ps1 must never each write their own copy of, so
        a release zip's exe and a local dev build's exe come from the exact
        same `dotnet publish` invocation shape.

        -SkipPublish reuses whatever is already at $PublishedExePath instead
        of publishing again -- for iterating without waiting on a full
        self-contained publish; the caller is responsible for deciding when
        that is safe. -ExtraPublishArgs is appended after the fixed profile
        arguments, unused by this script's own release build and read by
        scripts\build-launcher.ps1 to add build-time provenance (SourceRevisionId).
    #>
    param(
        [Parameter(Mandatory)][string]$LauncherProject,
        [Parameter(Mandatory)][string]$PublishedExePath,
        [switch]$SkipPublish,
        [string[]]$ExtraPublishArgs = @()
    )
    if ($SkipPublish) {
        Write-Host 'SkipPublish was given: reusing the existing publish output.'
        if (-not (Test-Path -LiteralPath $PublishedExePath -PathType Leaf)) {
            throw "SkipPublish was given but $PublishedExePath does not exist. Publish at least once."
        }
        return
    }
    Write-Host 'Publishing the launcher (dotnet publish, win-x64)...'
    $publishArgs = @($LauncherProject, '-c', 'Release', '-p:PublishProfile=win-x64') + @($ExtraPublishArgs)
    & dotnet publish @publishArgs
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish failed with exit code $LASTEXITCODE."
    }
    if (-not (Test-Path -LiteralPath $PublishedExePath -PathType Leaf)) {
        throw "dotnet publish reported success but $PublishedExePath is missing."
    }
}

# Dot-sourcing (`. launcher\package.ps1`) defines the functions above and
# runs nothing else -- how a self-test exercises Test-LcPackageEntryAllowed and
# Test-LcPackageEntryForbidden against a deliberately planted forbidden entry
# without publishing, staging or zipping anything, and how
# scripts\build-launcher.ps1 reuses the same allowlist, version reader and
# publish step. An ordinary run (`pwsh -File launcher\package.ps1`) is
# unaffected: InvocationName is then the script's own path, never the dot.
if ($MyInvocation.InvocationName -eq '.') { return }

# ---------------------------------------------------------------------------
# The run
# ---------------------------------------------------------------------------

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$launcherProject = Join-Path $repoRoot 'launcher\LocalCanvas.Launcher'
$publishDir = Join-Path $launcherProject 'bin\publish\win-x64'
$publishedExe = Join-Path $publishDir 'LocalCanvas.exe'

if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot 'launcher\dist' }

Write-Host 'LocalCanvas packaging'
Write-Host "Repository: $repoRoot"

# -- the clean-tree gate ----------------------------------------------------

if (-not $AllowDirty) {
    $gitStatus = & git -C $repoRoot status --porcelain 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ("git status failed in $repoRoot (exit $LASTEXITCODE): $gitStatus`n" +
            'This script reads the allowlist from `git ls-files` and needs a working git checkout.')
    }
    if ($gitStatus) {
        throw ("Refused: the working tree is not clean, and files outside the built exe are " +
            "copied off it once it is known to match `git ls-files`. Commit or stash your " +
            "changes, or pass -AllowDirty for local testing only.`n" +
            (($gitStatus | Select-Object -First 20) -join "`n"))
    }
    Write-Host 'Working tree is clean.'
} else {
    Write-Host 'AllowDirty was given: skipping the clean-tree check (local testing only).'
}

$version = Get-LcPackageVersion -RepoRoot $repoRoot
Write-Host "Version: $version (from launcher\Directory.Build.props)"

# -- 1. publish ---------------------------------------------------------

Invoke-LcLauncherPublish -LauncherProject $launcherProject -PublishedExePath $publishedExe -SkipPublish:$SkipPublish
$exeInfo = Get-Item -LiteralPath $publishedExe
$exeSha256 = Get-LcFileSha256 -Path $publishedExe
Write-Host "LocalCanvas.exe: $($exeInfo.Length) bytes, SHA-256 $exeSha256"

# -- 2. stage -------------------------------------------------------------

Assert-LcSafeOutputDirectory -Path $OutputDirectory
$stagingRoot = Join-Path $OutputDirectory 'staging'
if (Test-Path -LiteralPath $stagingRoot) {
    # Assert-LcSafeOutputDirectory above already refused any -OutputDirectory
    # this script does not own, so a staging\ folder found here is only ever
    # this script's own leftover from an earlier run -- safe to remove by this
    # exact, literal path, never a wildcard and never $OutputDirectory itself.
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force
}
$packageRoot = Join-Path $stagingRoot $script:ZipRootFolder
[void](New-Item -ItemType Directory -Path $packageRoot -Force)

Copy-Item -LiteralPath $publishedExe -Destination (Join-Path $packageRoot 'LocalCanvas.exe')

$trackedFiles = & git -C $repoRoot ls-files
if ($LASTEXITCODE -ne 0) {
    throw "git ls-files failed in $repoRoot (exit $LASTEXITCODE)."
}
$staged = 0
foreach ($relative in $trackedFiles) {
    if (-not (Test-LcPackageEntryAllowed -Path $relative)) { continue }
    $source = Join-Path $repoRoot ($relative -replace '/', '\')
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "git ls-files names $relative but it is not on disk at $source."
    }
    $destination = Join-Path $packageRoot ($relative -replace '/', '\')
    $destinationDir = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $destinationDir)) {
        [void](New-Item -ItemType Directory -Path $destinationDir -Force)
    }
    Copy-Item -LiteralPath $source -Destination $destination
    $staged++
}
Write-Host "Staged $staged tracked file(s) plus LocalCanvas.exe under $packageRoot"

# -- 3. zip -----------------------------------------------------------------

$zipName = "LocalCanvas-$version-windows-x64.zip"
$zipPath = Join-Path $OutputDirectory $zipName
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

Add-Type -AssemblyName System.IO.Compression.FileSystem
# $packageRoot itself, not $stagingRoot: includeBaseDirectory=true names the
# zip's top-level entries after the LEAF of the folder it is given, and the
# leaf has to be LocalCanvas\ -- the staging folder's own name must never
# leak into the archive.
[System.IO.Compression.ZipFile]::CreateFromDirectory(
    $packageRoot, $zipPath,
    [System.IO.Compression.CompressionLevel]::Optimal, $true)

$zipInfo = Get-Item -LiteralPath $zipPath
$zipSha256 = Get-LcFileSha256 -Path $zipPath
Write-Host "Wrote $zipPath ($($zipInfo.Length) bytes, SHA-256 $zipSha256)"

# -- 4. verify, reading the zip back ----------------------------------------

$archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $entryNames = @($archive.Entries | ForEach-Object { $_.FullName })
} finally {
    $archive.Dispose()
}

$forbidden = @($entryNames | Where-Object { Test-LcPackageEntryForbidden -EntryName $_ })
if ($forbidden.Count -gt 0) {
    throw ("Refused: the built zip contains forbidden entries:`n" + ($forbidden -join "`n"))
}

$exeEntryName = "$($script:ZipRootFolder)/LocalCanvas.exe"
if ($entryNames -notcontains $exeEntryName) {
    throw "Refused: the built zip has no $exeEntryName entry."
}

# Every non-directory entry has to be either the exe or something the
# allowlist names (checked against the git-relative path with the
# LocalCanvas\ prefix removed) -- the allowlist's own guarantee, verified a
# second time against the artefact actually written to disk.
$unexplained = @()
foreach ($entry in $entryNames) {
    if ($entry.EndsWith('/')) { continue }
    if ($entry -eq $exeEntryName) { continue }
    $relative = $entry.Substring($script:ZipRootFolder.Length + 1)
    if (-not (Test-LcPackageEntryAllowed -Path $relative)) {
        $unexplained += $entry
    }
}
if ($unexplained.Count -gt 0) {
    throw ("Refused: the built zip contains entries the allowlist does not name:`n" +
        ($unexplained -join "`n"))
}

$fileEntryCount = @($entryNames | Where-Object { -not $_.EndsWith('/') }).Count
Write-Host "Verified: $fileEntryCount file entries, all on the allowlist, no forbidden pattern present."

# Success: remove the staging folder by its own exact, literal path (never
# $OutputDirectory itself). It is an implementation detail of this run, not
# something a user of -OutputDirectory needs to see or clean up themselves.
Remove-Item -LiteralPath $stagingRoot -Recurse -Force
Write-Host ''
Write-Host '=== Summary ==='
Write-Host "Version:        $version"
Write-Host "LocalCanvas.exe: $($exeInfo.Length) bytes, SHA-256 $exeSha256"
Write-Host "Zip:            $zipPath"
Write-Host "                $($zipInfo.Length) bytes, SHA-256 $zipSha256, $fileEntryCount file entries"
