<#
.SYNOPSIS
    The only place in LocalCanvas that can fetch a model, and everything that
    has to be true before it does.

.DESCRIPTION
    Dot-sourced by comfy/setup.ps1, on top of Bootstrap.ps1, whose choke point
    and interlock this file obeys rather than repeats.

    THE RULE THIS FILE EXISTS FOR:

      No download happens because somebody ran a setup script. A model arrives
      only when a person asked for models, having been told what, how big,
      from where and under what licence -- in that order, before a byte moves.

    THE FAILURE THIS FILE IS ARRANGED AGAINST. A reference bootstrap stack
    examined before this layer was written had four
    downloaders. Three verified a sha256 and exited hard on a mismatch. The
    fourth verified nothing -- and the fourth was the one its bootstrap
    actually called, over a registry whose 42 model entries carried zero
    hashes. The verification existed; it was not on the path anybody used. So
    the question this file is written to answer is not "does it verify" but
    "is the verification on the path that runs", and the answer is structural:

      * there is ONE fetch in the whole layer, Invoke-LcModelFetch, held to one
        call site by a lint, and it is the only place an HttpClient exists;
      * that fetch hashes while it writes, so the verification is not a second
        pass somebody can forget to call;
      * an entry that carries no sha256 does not silently skip verification --
        it has to SAY "verification": "none", or the manifest is refused, and
        every such download is announced as UNVERIFIED in the plan and again
        when it lands.

    WHAT A DOWNLOAD IS HELD TO, all of it before the file exists:

      * a temporary <name>.part, then one atomic move into place. A partial
        download is never the final file;
      * an entry with no sha256 must declare sizeBytes, and the byte count that
        arrives must equal it EXACTLY. An unverified entry has to say something
        checkable about the bytes or "unverified" means "anything at all,
        including an error page saved under the name of a model". There is no
        equivalent check against the server's own Content-Length, and the
        reason is measured rather than assumed: .NET's HttpClient throws "The
        response ended prematurely" when a server declares more than it sends,
        so such a check could never fire on this machine, and a guard that
        cannot fail is not a guard. What it could not see is a response with no
        Content-Length at all, cut short at a clean end of stream -- and that
        is exactly the case sizeBytes covers;
      * no resume, deliberately. Resume done right has to handle the case
        that makes it dangerous -- a server that answers 200
        to a Range request produces a file that is a corrupt concatenation. Not
        resuming makes that failure unreachable. A leftover .part is discarded
        and the transfer starts from zero. Stated cost: a large interrupted
        download starts again.

    WHAT IT NEVER DOES:

      * accept a gated model's licence on anybody's behalf. A gated entry stops
        the run BEFORE any download, names what the user must do, and exits
        non-zero. LocalCanvas has agreed to nothing;
      * write a credential anywhere. The token is read from the process
        environment at the point of use, goes into one request header, and
        reaches no file, no log line and no command line. There is no
        LocalCanvas credential subsystem and this is not the start of one;
      * write during -DryRun. Every primitive here calls
        Assert-LcMutationAllowed, the fetch included, so a dry run that
        downloaded anything would be an exception rather than a surprise.
#>

Set-StrictMode -Version Latest

# Invoke-LcModelFetch constructs HttpClientHandler, HttpClient and
# HttpRequestMessage, which live in System.Net.Http -- an assembly Windows
# PowerShell 5.1 does not load by default, so every download failed there with
# "Unable to find type [System.Net.Http.HttpClientHandler]." (T-0217, measured).
# This file does not dot-source scripts/lib/Common.ps1, which loads the same
# assembly for the probe; Bootstrap.ps1 happens to load Common.ps1 first, but the
# library that constructs the client is the one that says what it needs.
# Harmless under pwsh, where the assembly is already loaded.
Add-Type -AssemblyName 'System.Net.Http'

# The three profiles, and the whole list of them. No Full and no Everything:
# a profile that means "all of it" is how "bootstrap quietly pulled thirty
# gigabytes" happens, and the card that commissioned this file forbids one.
$script:LcModelProfiles = @('minimal', 'recommended', 'video')

# The environment variable a host's credential comes from. This holds the NAME
# and never the value -- which is why it is not called a token: the suite's
# credential lint refuses any $...token... variable on a line that prints,
# writes a file or builds an argument list, and the name of the variable is
# printed on purpose, in the plan, so that a person knows what to set.
$script:LcModelCredentialVariable = 'HF_TOKEN'

function Get-LcModelProfiles { return $script:LcModelProfiles }

function Get-LcModelCredentialVariableName { return $script:LcModelCredentialVariable }

function ConvertTo-LcProfileName {
    <#
        One spelling of a profile name. Our own vocabulary, so case is not
        meaningful here -- unlike a node class name, which is exact because
        ComfyUI's registry is.
    #>
    param([Parameter(Mandatory)][string]$Name)
    return $Name.Trim().ToLowerInvariant()
}

function Test-LcModelSha256 {
    <#
        A sha256 is 64 hex characters or it is not one.

        -match is case-insensitive on purpose: an upper-case digest names the
        same bytes, and the reader canonicalises it to lower case so that the
        comparison after the download is a plain string equality.
    #>
    param([AllowEmptyString()][AllowNull()][string]$Value)
    if (-not $Value) { return $false }
    return [bool]($Value -match '^[0-9a-f]{64}$')
}

function Test-LcModelRelativePath {
    <#
        The destination of a model entry, as a path that cannot leave the
        models root.

        Forward slashes only, one or more segments, each segment starting with
        a letter or a digit. That refuses '..', an absolute path, a drive
        letter, a UNC path, a leading separator and a backslash in one rule,
        by saying what a segment may be rather than listing what it may not.
    #>
    param([AllowEmptyString()][AllowNull()][string]$Value)
    if (-not $Value) { return $false }
    return [bool]($Value -cmatch '^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*$')
}

function Format-LcApproximateSize {
    <#
        A byte count a person can judge before agreeing to it. "how big" in
        the rule above is the number somebody decides on, so it is printed in
        units they think in AND in bytes, never only in bytes.
    #>
    param([Parameter(Mandatory)][long]$Bytes)
    if ($Bytes -lt 0) { return 'unknown' }
    $units = @('bytes', 'KB', 'MB', 'GB', 'TB')
    $value = [double]$Bytes
    $index = 0
    while (($value -ge 1024) -and ($index -lt ($units.Count - 1))) {
        $value = $value / 1024
        $index = $index + 1
    }
    if ($index -eq 0) { return "$Bytes bytes" }
    # InvariantCulture, and measured rather than assumed: on a machine whose
    # culture uses a comma for the decimal separator, "{0}" -f 8.1 prints
    # "8,1". The number a person is shown before agreeing to a download must
    # not depend on which machine is showing it.
    $rounded = [math]::Round($value, 1)
    $text = $rounded.ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture)
    return "$text $($units[$index])"
}

function Get-LcModelEntryProfiles {
    <#
        The profiles one manifest entry belongs to.

        An entry with no profiles belongs to none: membership is declared, not
        assumed. The alternative -- "no profiles means every profile" -- is the
        shape that makes a Video model arrive in a Recommended run because
        somebody forgot a field.
    #>
    param($Entry, [Parameter(Mandatory)][string]$Where)
    if (-not (Test-LcHasProperty -Object $Entry -Name 'profiles')) {
        throw ("$Where has no 'profiles'. Every entry says which profiles it belongs to; " +
            'an entry with no profiles would otherwise have to be treated as belonging ' +
            'to all of them, which is how a video model arrives in an image install. ' +
            'Nothing was changed.')
    }
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($raw in @($Entry.profiles)) {
        $name = ConvertTo-LcProfileName -Name "$raw"
        if ($script:LcModelProfiles -notcontains $name) {
            throw ("$Where names the profile '$raw', and the profiles are " +
                "$($script:LcModelProfiles -join ', '). A misspelled profile name would " +
                'silently exclude the entry rather than fail, so it is refused. ' +
                'Nothing was changed.')
        }
        if ($names -notcontains $name) { $names.Add($name) }
    }
    if ($names.Count -eq 0) {
        throw "$Where has an empty 'profiles' list. Nothing was changed."
    }
    return @($names)
}

function Read-LcNodeClassNames {
    <#
        The node classes one custom-node entry registers, exactly as ComfyUI
        spells them.

        THE NAMES ARE NOT NORMALISED, and that is the rule rather than an
        oversight. comfy/doctor.ps1 looks each one up in the live /object_info
        with a case-SENSITIVE comparison, because ComfyUI's own registry is
        case-sensitive and a class_type that differs by a letter's case is a
        class_type ComfyUI will reject. So a class name in a manifest is exact,
        and the only liberty taken here is stripping the whitespace JSON may
        have left around it.
    #>
    param($Entry, [Parameter(Mandatory)][string]$Where)
    $classes = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-LcHasProperty -Object $Entry -Name 'nodeClasses')) { return @($classes) }
    foreach ($raw in @($Entry.nodeClasses)) {
        $name = "$raw".Trim()
        if (-not $name) {
            throw "$Where has an empty entry in 'nodeClasses'. Nothing was changed."
        }
        if ($classes -ccontains $name) {
            throw "$Where lists the node class '$name' more than once. Nothing was changed."
        }
        $classes.Add($name)
    }
    return @($classes)
}

function Read-LcModelEntry {
    <#
        One model entry, validated to the point where a person could agree to
        it without being surprised afterwards.

        VERIFICATION IS DECLARED, NEVER DEFAULTED. An entry carries either a
        sha256 or the words "verification": "none", and carrying neither is a
        refusal of the whole manifest. Carrying both is also a refusal,
        because then two fields disagree about whether the file is checked and
        the reader would have to pick one.

        This is T-0170's reasoning about a commit id applied to a file: a URL
        without a hash is a URL whose contents can change, so the manifest
        either pins the bytes or says out loud that it does not.
    #>
    param($Entry, [Parameter(Mandatory)][string]$Where)

    $name = Get-LcManifestString -Entry $Entry -Name 'name' -Where $Where
    $where = "the model entry '$name'"

    $file = Get-LcManifestString -Entry $Entry -Name 'file' -Where $where
    if (-not (Test-LcModelRelativePath -Value $file)) {
        throw ("$where has the destination '$file', which is not a plain relative path " +
            'under the models root. A destination that could leave that directory is ' +
            'refused. Nothing was changed.')
    }

    $url = Get-LcManifestString -Entry $Entry -Name 'url' -Where $where
    if (($url -notlike 'https://*') -and ($url -notlike 'http://*')) {
        throw ("$where has the url '$url', which is not an http or https URL. " +
            'Nothing was changed.')
    }

    $sha256 = ''
    if (Test-LcHasProperty -Object $Entry -Name 'sha256') {
        $sha256 = "$($Entry.sha256)".Trim()
    }
    $declaredNone = $false
    if (Test-LcHasProperty -Object $Entry -Name 'verification') {
        $declared = "$($Entry.verification)".Trim().ToLowerInvariant()
        if ($declared -ne 'none') {
            throw ("$where has 'verification': '$($Entry.verification)'. The only value " +
                "this field takes is 'none', which is how an entry says out loud that it " +
                'carries no hash. Nothing was changed.')
        }
        $declaredNone = $true
    }
    if ($sha256 -and $declaredNone) {
        throw ("$where carries both a sha256 and 'verification': 'none'. Those two say " +
            'opposite things about whether the download is checked. Nothing was changed.')
    }
    if ((-not $sha256) -and (-not $declaredNone)) {
        throw ("$where carries neither a 'sha256' nor 'verification': 'none'. A URL " +
            'without a hash is a URL whose contents can change, so an entry either pins ' +
            'the bytes or says in as many words that it does not -- silence is refused, ' +
            'because a reader cannot tell it apart from an oversight. Nothing was changed.')
    }
    if ($sha256 -and (-not (Test-LcModelSha256 -Value $sha256))) {
        throw ("$where has the sha256 '$sha256', which is not a 64-character hex digest. " +
            'Nothing was changed.')
    }
    if ($sha256) { $sha256 = $sha256.ToLowerInvariant() }

    # sizeBytes is two different things depending on the entry, and the
    # difference is stated here because it is the only integrity statement an
    # unverified entry can make:
    #   * with a sha256, it is for the plan a person reads before agreeing, so
    #     it may be approximate and nothing compares against it -- the hash is
    #     the check;
    #   * with "verification": "none", it is REQUIRED and it is EXACT. The
    #     download is refused if the byte count differs.
    $size = [long](-1)
    if (Test-LcHasProperty -Object $Entry -Name 'sizeBytes') {
        $text = "$($Entry.sizeBytes)".Trim()
        if ($text -notmatch '^[0-9]+$') {
            throw ("$where has 'sizeBytes': '$text', which is not a whole number of " +
                'bytes. Nothing was changed.')
        }
        $size = [long]$text
    }
    if ($declaredNone -and ($size -lt 0)) {
        throw ("$where declares 'verification': 'none' and carries no 'sizeBytes'. An " +
            'entry that pins nothing about its bytes would accept anything the URL ' +
            'happened to return, an error page included, so an unverified entry has to ' +
            'state its exact length. Nothing was changed.')
    }

    $license = Get-LcManifestString -Entry $Entry -Name 'license' -Where $where
    $licenseUrl = ''
    if (Test-LcHasProperty -Object $Entry -Name 'licenseUrl') {
        $licenseUrl = "$($Entry.licenseUrl)".Trim()
    }

    $gated = $false
    if (Test-LcHasProperty -Object $Entry -Name 'gated') { $gated = [bool]$Entry.gated }
    $gatedInstructions = ''
    if (Test-LcHasProperty -Object $Entry -Name 'gatedInstructions') {
        $gatedInstructions = "$($Entry.gatedInstructions)".Trim()
    }
    if ($gated -and (-not $gatedInstructions)) {
        throw ("$where is gated and carries no 'gatedInstructions'. A gated model stops " +
            'this run, so the entry has to say what the person must go and do; ' +
            '"it is gated" on its own is not an instruction. Nothing was changed.')
    }

    $needsToken = $false
    if (Test-LcHasProperty -Object $Entry -Name 'requiresToken') {
        $needsToken = [bool]$Entry.requiresToken
    }
    # A credential never crosses a network in plain text (T-0215). Over http the
    # Authorization header is readable by anyone on the path, so an entry that
    # needs a token must be https -- unless the host is this machine itself,
    # where the request never reaches a network at all.
    #
    # A redirect is not a way round this, and that is MEASURED rather than
    # assumed: .NET's HttpClientHandler dropped the Authorization header on
    # every redirect it followed in T-0215's probe -- to another origin and to
    # the same one alike -- so the token only ever goes to the url written
    # here.
    if ($needsToken -and ($url -notlike 'https://*')) {
        $parsed = $null
        $loopback = [System.Uri]::TryCreate($url, [System.UriKind]::Absolute, [ref]$parsed) -and
            $parsed.IsLoopback
        if (-not $loopback) {
            throw ("$where needs a token and its url '$url' is not https. The token would " +
                'cross the network in plain text, readable by anyone on the path, so this ' +
                'entry is refused. Use the https address of the same file. Nothing was changed.')
        }
    }

    $profiles = Get-LcModelEntryProfiles -Entry $Entry -Where $where
    if ($profiles -contains 'minimal') {
        throw ("$where puts a model in the 'minimal' profile. Minimal is a " +
            'LocalCanvas-compatible ComfyUI runtime and nothing else: it downloads no ' +
            'model at all, and that is a property of this format rather than of the ' +
            'manifest that happens to be installed. Nothing was changed.')
    }

    return [pscustomobject]@{
        Name              = $name
        File              = $file
        Url               = $url
        Sha256            = $sha256
        SizeBytes         = $size
        License           = $license
        LicenseUrl        = $licenseUrl
        Gated             = $gated
        GatedInstructions = $gatedInstructions
        RequiresToken     = $needsToken
        Profiles          = $profiles
    }
}

function Read-LcModelManifest {
    <#
        The models section of an already-read manifest document, plus the
        profile membership of the custom nodes beside it.

        The document is the one Read-LcBootstrapManifest validated, so the
        schema has already been compared exactly. These fields are additions
        to that same schema rather than a schema of their own: they are
        optional, a manifest written before they existed still reads, and
        there is exactly one reader of this format in the world. Bumping the
        schema id instead would have invalidated every manifest already on a
        user's disk to gain nothing.
    #>
    param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][string]$Path)
    $models = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if (Test-LcHasProperty -Object $Document -Name 'models') {
        foreach ($entry in @($Document.models)) {
            if ($null -eq $entry) { continue }
            $model = Read-LcModelEntry -Entry $entry -Where "a models entry in '$Path'"
            if (-not $seen.Add($model.File)) {
                throw ("The manifest '$Path' sends two model entries to the same file, " +
                    "'$($model.File)'. Nothing was changed.")
            }
            $models.Add($model)
        }
    }
    return @($models)
}

function Select-LcProfileModels {
    <#
        The models one profile asks for, in manifest order.

        Membership and nothing else decides this. A Recommended run sees no
        entry that did not say 'recommended', which is what keeps the video
        stack out of it -- there is no "and also" anywhere in this function.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Models,
        [Parameter(Mandatory)][string]$Profile)
    $wanted = ConvertTo-LcProfileName -Name $Profile
    $selected = [System.Collections.Generic.List[object]]::new()
    foreach ($model in $Models) {
        if ($model.Profiles -contains $wanted) { $selected.Add($model) }
    }
    return @($selected)
}

function Select-LcProfileNodes {
    <#
        The custom nodes one profile asks for.

        A node entry with no 'profiles' belongs to every profile, and that is
        the opposite of the rule for a model, deliberately: a manifest written
        before profiles existed listed the nodes its author wanted installed,
        and silently dropping them on upgrade would change what an existing
        manifest means. A model entry has no such history -- this file is the
        first thing that could read one -- and the cost of the two defaults is
        not symmetrical: a node pack arriving is a directory, a model arriving
        is tens of gigabytes.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Nodes,
        [Parameter(Mandatory)][string]$Profile)
    $wanted = ConvertTo-LcProfileName -Name $Profile
    $selected = [System.Collections.Generic.List[object]]::new()
    foreach ($node in $Nodes) {
        if ($node.Profiles.Count -eq 0) { $selected.Add($node); continue }
        if ($node.Profiles -contains $wanted) { $selected.Add($node) }
    }
    return @($selected)
}

function Get-LcProfileNodeClasses {
    <#
        The node classes a profile's packs register, exactly as ComfyUI spells
        them.

        This is the whole of what this layer hands to comfy/doctor.ps1, which
        already takes -RequireNodeClass and looks each name up in the live
        /object_info. That interface was written before profiles existed and
        is not changed here: a profile states the class names, the doctor
        reads them, and there is one mechanism rather than two.

        The names are passed through untouched. The doctor's lookup is
        case-sensitive because ComfyUI's registry is, so a class name in a
        manifest is exact and this function is not allowed to be helpful
        about it.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Nodes,
        [Parameter(Mandatory)][string]$Profile)
    $classes = [System.Collections.Generic.List[string]]::new()
    foreach ($node in @(Select-LcProfileNodes -Nodes $Nodes -Profile $Profile)) {
        foreach ($class in $node.NodeClasses) {
            if ($classes -cnotcontains $class) { $classes.Add($class) }
        }
    }
    return @($classes)
}

function Get-LcModelToken {
    <#
        The token, from the process environment, at the point of use.

        This is the ONLY place in LocalCanvas that reads it. The reference
        stack's base downloader took the
        same credential as a command-line ARGUMENT, which puts it in a process
        command line any other process on the machine can read -- and that
        archive's own status script printed a command line to the console. So:
        environment or nothing, never an argument, never a log line, never a
        file. Returns an empty string when it is not set, which the caller
        turns into a refusal to start that one download rather than into an
        unauthenticated request that would 401 and look like a server fault.
    #>
    $value = [Environment]::GetEnvironmentVariable($script:LcModelCredentialVariable)
    if (-not $value) { return '' }
    return "$value".Trim()
}

function Get-LcModelDestination {
    param([Parameter(Mandatory)][string]$ModelsRoot, [Parameter(Mandatory)]$Model)
    $relative = $Model.File.Replace('/', '\')
    return [System.IO.Path]::Combine($ModelsRoot, $relative)
}

function Write-LcModelPlan {
    <#
        Everything a person needs in order to say yes, printed before the
        first byte and in the order the rule names it: what, how big, from
        where, under what licence. Then the two facts that decide whether the
        download can happen at all -- gated, and whether a token is needed --
        and then whether the bytes will be checked when they arrive.

        A non-interactive consent flag skips the QUESTION below. It never
        skips this: a log that does not say what was downloaded is the same
        failure one step later.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Models,
        [Parameter(Mandatory)][string]$ModelsRoot,
        [Parameter(Mandatory)][string]$Profile
    )
    $total = [long]0
    $unknown = 0
    foreach ($model in $Models) {
        if ($model.SizeBytes -ge 0) { $total = $total + $model.SizeBytes } else { $unknown = $unknown + 1 }
    }
    Write-Host ''
    Write-LcInfo ("Models to download for profile '$(ConvertTo-LcProfileName -Name $Profile)': " +
        "$($Models.Count) file(s)")
    $index = 0
    foreach ($model in $Models) {
        $index = $index + 1
        Write-Host ''
        Write-LcDetail "  $index. $($model.Name)"
        Write-LcDetail "     what:     $($model.File)"
        $size = if ($model.SizeBytes -lt 0) {
            'not stated in the manifest'
        } elseif ($model.Sha256) {
            ("$(Format-LcApproximateSize -Bytes $model.SizeBytes) " +
                "($($model.SizeBytes) bytes as stated in the manifest)")
        } else {
            ("$(Format-LcApproximateSize -Bytes $model.SizeBytes) " +
                "($($model.SizeBytes) bytes exactly, and checked on arrival)")
        }
        Write-LcDetail "     size:     $size"
        Write-LcDetail "     from:     $($model.Url)"
        $licence = if ($model.LicenseUrl) { "$($model.License) -- $($model.LicenseUrl)" } else { $model.License }
        Write-LcDetail "     licence:  $licence"
        if ($model.Gated) {
            Write-LcDetail '     gated:    YES -- this run will stop and download nothing'
        } else {
            Write-LcDetail '     gated:    no'
        }
        if ($model.RequiresToken) {
            Write-LcDetail "     token:    required, read from the $($script:LcModelCredentialVariable) environment variable"
        } else {
            Write-LcDetail '     token:    not needed'
        }
        if ($model.Sha256) {
            Write-LcDetail "     verify:   sha256 $($model.Sha256)"
        } else {
            Write-LcDetail '     verify:   UNVERIFIED -- this entry carries no sha256'
        }
        Write-LcDetail "     lands at: $(Get-LcModelDestination -ModelsRoot $ModelsRoot -Model $model)"
    }
    Write-Host ''
    $totalText = if ($unknown -gt 0) {
        "~$(Format-LcApproximateSize -Bytes $total) ($total bytes), plus $unknown file(s) of unstated size"
    } else {
        "~$(Format-LcApproximateSize -Bytes $total) ($total bytes)"
    }
    Write-LcInfo "Total approximate download: $totalText"
    Write-LcInfo "Destination: $ModelsRoot"
}

function Assert-LcNoGatedModel {
    <#
        A gated model is never accepted on anybody's behalf.

        Before any download, and a refusal of the whole run rather than a skip
        of one entry: LocalCanvas does not click a licence through, does not
        imply it has agreed to anything, and does not quietly install the rest
        while leaving the person to discover later what did not arrive. It
        prints what to go and do, and stops.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Models)
    $gated = [System.Collections.Generic.List[object]]::new()
    foreach ($model in $Models) { if ($model.Gated) { $gated.Add($model) } }
    if ($gated.Count -eq 0) { return }
    Write-Host ''
    Write-LcFail "$($gated.Count) of these model(s) require you to accept a licence first."
    foreach ($model in $gated) {
        Write-LcDetail "  $($model.Name): $($model.GatedInstructions)"
    }
    Write-Host ''
    throw ('A gated model is never accepted on your behalf. LocalCanvas has agreed to ' +
        'nothing and downloaded nothing. Do what the line(s) above say, then run this ' +
        'again -- or remove the gated entries from the manifest.')
}

function Request-LcModelConsent {
    <#
        Asked once, after the plan and before the first byte.

        -AcceptModelDownloads skips the question and nothing else. A session
        that cannot be asked -- a scheduled task, a CI runner, a
        -NonInteractive shell -- is refused rather than defaulted: "nobody was
        there to say no" has never meant yes.
    #>
    param([switch]$Accepted)
    Write-Host ''
    if ($Accepted) {
        Write-LcOk ('Consent: -AcceptModelDownloads was given, so nothing was asked. ' +
            'The list above is exactly what will be downloaded.')
        return
    }
    $answer = ''
    try {
        $answer = Read-Host 'Download these files? Type yes to continue'
    } catch {
        throw ('Nothing was downloaded. This session cannot be asked for consent ' +
            "($($_.Exception.Message)), and a download is never assumed. Run this from a " +
            'console, or pass -AcceptModelDownloads once you have read the list above.')
    }
    if ("$answer".Trim().ToLowerInvariant() -ne 'yes') {
        throw ("Nothing was downloaded: the answer was '$answer' and not 'yes'.")
    }
    Write-LcOk 'Consent given.'
}

# --------------------------------------------------------------------------
# The one fetch, and the three primitives that put its bytes on disk
# --------------------------------------------------------------------------

function New-LcModelPartStream {
    <#
        The only stream this layer opens for writing. It writes to
        <destination>.part and never to the destination, so the final file
        cannot exist in a partial state at any instant.
    #>
    param([Parameter(Mandatory)][string]$Path)
    Assert-LcMutationAllowed -What 'opening a download file' -Target $Path
    return [System.IO.FileStream]::new($Path, 'Create', 'Write', 'None')
}

function Remove-LcModelPartFile {
    <#
        The only delete in this layer, and it can only ever name a .part file
        -- which is checked here rather than trusted, because a delete that
        can be pointed at a destination is a delete that will eventually be.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not $Path.EndsWith('.part')) {
        throw "REFUSED: $Path is not a partial download, so this will not delete it."
    }
    Assert-LcMutationAllowed -What 'discarding a partial download' -Target $Path
    if (Test-Path -LiteralPath $Path -PathType Leaf) { [System.IO.File]::Delete($Path) }
}

function Move-LcModelIntoPlace {
    <#
        The atomic half of "temporary file, then replace".
        A move within one filesystem is atomic on Windows and on POSIX alike,
        so the destination either does not exist or is the whole verified
        file. There is no window in which it is half of one.
    #>
    param([Parameter(Mandatory)][string]$Part, [Parameter(Mandatory)][string]$Destination)
    Assert-LcMutationAllowed -What 'installing a downloaded file' -Target $Destination
    [System.IO.File]::Move($Part, $Destination)
}

function Close-LcAbandonedRead {
    <#
        THE ONLY PLACE A STALL IS REPORTED, BECAUSE IT IS THE ONLY PLACE THE
        STREAM IS CLOSED (T-0301).

        Read-LcModelChunk reports the same stall from more than one path, and
        which of them runs is decided by a race: one token cancels both the
        read and the delay, and whichever completion the scheduler marks first
        picks the path. Until this function existed only one of those paths
        closed anything, so the identical sentence left the stream open or shut
        depending on the machine's load -- measured on the tracked library, 5
        of 24 identical runs ended with the stream still readable, and public
        CI saw it as an intermittent red job.

        So closing and reporting are one act here and not two. A path that
        forgets to close cannot be written, because reporting the stall IS this
        call. The response goes with the stream and never separately: the
        caller relies on both being gone. Neither Dispose is allowed to keep
        the sentence from being thrown, and neither is allowed to keep the
        other from running, which is what the two guards are for -- the message
        is a contract three other tests assert verbatim.
    #>
    param($Stream, $Response, [Parameter(Mandatory)][string]$Stalled)
    try { if ($Stream) { $Stream.Dispose() } } catch { }
    try { if ($Response) { $Response.Dispose() } } catch { }
    throw $Stalled
}

function Read-LcModelChunk {
    <#
        One read of a download's body, abandoned if no byte arrives within
        -StallSeconds (T-0214). A stall is reported in words, and the caller's
        own failure path discards the .part exactly as it does for a cut
        transfer.

        THE BOUND DOES NOT RELY ON THE TOKEN (T-0249). Under Windows PowerShell
        5.1 .NET Framework's response stream does not observe it once the read
        is under way: measured, a 3-second stall bound ended at 30 seconds,
        when the server hung up, and a server that never hangs up would have
        been waited on for ever. So the read is raced against a delay that ends
        at -StallSeconds: an endless Task.Delay that the stall bound's own
        source cancels, so each read costs no timer beyond the one it already
        had. If the read has not finished when the race ends, the stream and
        the response are disposed, which ends the pending read -- measured on a
        silent loopback transfer: at once under 5.1, within about two seconds
        under pwsh 7.6 -- and the transfer is abandoned without waiting for it.
        The token is still passed to the read: under pwsh it cancels the read
        itself. Nothing here is a PowerShell scriptblock handed to .NET as a
        callback, which would need a runspace on whichever thread ran it.

        WHICH OF THE TWO COMPLETIONS ARRIVES FIRST IS A RACE, AND THE ANSWER
        MAY NOT DEPEND ON IT (T-0301). One token cancels both tasks, so under
        pwsh the read is sometimes already marked cancelled by the time the
        race is judged and sometimes is not. The three outcomes are therefore
        written out here as three, and only the first of them returns bytes:

          * the read ran to completion -- bytes arrived, possibly in the same
            instant the bound fired, and data that DID arrive is never thrown
            away;
          * the bound fired -- whether the read is still pending or already
            cancelled, the transfer is abandoned through
            Close-LcAbandonedRead, which closes the stream and the response
            before it says so. Both ways round, and under both shells;
          * anything else -- the read failed for its own reason, and that
            reason is what the caller hears, not a stall that did not happen.
    #>
    param(
        [Parameter(Mandatory)]$Stream,
        [Parameter(Mandatory)][byte[]]$Buffer,
        [Parameter(Mandatory)][double]$StallSeconds,
        $Response
    )
    $stalled = ("no data arrived for $StallSeconds seconds, so the transfer was " +
        'abandoned as stalled')
    $cancel = [System.Threading.CancellationTokenSource]::new(
        [System.TimeSpan]::FromSeconds($StallSeconds))
    try {
        $read = $Stream.ReadAsync($Buffer, 0, $Buffer.Length, $cancel.Token)
        $delay = [System.Threading.Tasks.Task]::Delay(-1, $cancel.Token)
        [void][System.Threading.Tasks.Task]::WhenAny(
            [System.Threading.Tasks.Task[]]@($read, $delay)).GetAwaiter().GetResult()
        if ($read.IsCompleted -and -not $read.IsFaulted -and -not $read.IsCanceled) {
            return $read.GetAwaiter().GetResult()
        }
        if ($cancel.IsCancellationRequested) {
            Close-LcAbandonedRead -Stream $Stream -Response $Response -Stalled $stalled
        }
        return $read.GetAwaiter().GetResult()
    } finally {
        $cancel.Dispose()
    }
}

function Invoke-LcModelFetch {
    <#
        THE ONLY PLACE LOCALCANVAS FETCHES BYTES, and a lint holds it to one
        call site for this reason: the reference stack had four
        copies of this function and they had already diverged, so three
        verified a hash and the one its bootstrap called did not.

        It streams, hashes what it streams, and returns the digest of what
        actually arrived -- so the verification cannot be a later pass over a
        file somebody forgot to re-read, and cannot be skipped by a caller.

        Assert-LcMutationAllowed first, because a download is a write: a dry
        run that reached this function would throw rather than fetch.

        The token, when the entry needs one, goes into the request's
        Authorization header and nowhere else. It is not logged, not recorded,
        and there is no process to put it on the command line of.

        TWO DEADLINES, AND WHICH IS WHICH IS MEASURED (T-0214).
          * -TimeoutSeconds bounds the wait for the response HEADERS and
            nothing after them. With ResponseHeadersRead, HttpClient.Timeout
            does not reach the body: a 10-second trickle completed under a
            3-second timeout. That is what lets a model larger than ten
            minutes of transfer download at all.
          * -StallSeconds bounds each READ of the body: no bytes for that long
            and the transfer is abandoned. Without it a server that sent its
            headers and then fell silent was still being waited on 25 seconds
            into a 3-second timeout, and would have been indefinitely. It is a
            stall bound and not a speed bound -- a slow download that keeps
            moving is never cut off.
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$PartPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Token,
        [double]$TimeoutSeconds = 600,
        [double]$StallSeconds = 120
    )
    Assert-LcMutationAllowed -What 'downloading a file' -Target $PartPath

    $client = $null
    $request = $null
    $response = $null
    $stream = $null
    $file = $null
    $hasher = $null
    $digest = ''
    $received = [long]0
    try {
        $handler = [System.Net.Http.HttpClientHandler]::new()
        $handler.UseProxy = $false
        $client = [System.Net.Http.HttpClient]::new($handler)
        $client.Timeout = [System.TimeSpan]::FromSeconds($TimeoutSeconds)
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Url)
        if ($Token) {
            $request.Headers.Authorization =
            [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Token)
        }
        $response = $client.SendAsync($request,
            [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            throw ("the server answered HTTP $([int]$response.StatusCode) " +
                "($($response.ReasonPhrase))")
        }
        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $hasher = [System.Security.Cryptography.SHA256]::Create()
        $file = New-LcModelPartStream -Path $PartPath
        $buffer = [byte[]]::new(1048576)
        while ($true) {
            $read = Read-LcModelChunk -Stream $stream -Buffer $buffer -StallSeconds $StallSeconds `
                -Response $response
            if ($read -le 0) { break }
            [void]$hasher.TransformBlock($buffer, 0, $read, $null, 0)
            $file.Write($buffer, 0, $read)
            $received = $received + $read
        }
        [void]$hasher.TransformFinalBlock($buffer, 0, 0)
        # Flush(true) pushes the file's own buffers through to the device, so
        # the bytes the move is about to publish are the bytes that arrived.
        $file.Flush($true)
        # The digest is taken here rather than after the finally, so that the
        # hasher can be disposed on EVERY path out of this function -- including
        # a transfer that was cut, which is the path that happens most.
        $digest = [System.BitConverter]::ToString($hasher.Hash).Replace('-', '').ToLowerInvariant()
    } finally {
        if ($file) { $file.Dispose() }
        if ($stream) { $stream.Dispose() }
        if ($response) { $response.Dispose() }
        if ($request) { $request.Dispose() }
        if ($client) { $client.Dispose() }
        if ($hasher) { $hasher.Dispose() }
    }

    return [pscustomobject]@{
        Sha256   = $digest
        Received = $received
    }
}

function Install-LcModel {
    <#
        One model, from nothing on disk to a verified file -- or to nothing on
        disk at all.

        The order is the point:

          1. a destination that already exists is never overwritten. With a
             hash it is checked and reported; without one it is left alone and
             reported as unverified. Either way this script does not replace a
             file somebody already has;
          2. a stale .part is discarded rather than resumed (see the file
             header);
          3. the bytes are fetched into the .part and hashed as they arrive;
          4. for an entry with no sha256, the byte count must equal the
             sizeBytes the manifest declared. That is the only thing pinned
             about such a file, and without it "unverified" would mean
             "whatever the URL returned";
          5. the digest is compared when the entry has one. A mismatch deletes
             the .part and fails. The destination is never created;
          6. only then, the atomic move.

        Every failure above leaves the destination absent, which is what makes
        "a partial download never becomes the final file" a property of the
        order rather than of care.
    #>
    param(
        [Parameter(Mandatory)]$Model,
        [Parameter(Mandatory)][string]$ModelsRoot,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Token,
        [double]$TimeoutSeconds = 600,
        [double]$StallSeconds = 120
    )
    $destination = Get-LcModelDestination -ModelsRoot $ModelsRoot -Model $Model
    $part = "$destination.part"

    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        if ($Model.Sha256) {
            $actual = Get-LcFileSha256 -Path $destination
            if ($actual -eq $Model.Sha256) {
                Write-LcOk "$($Model.Name) is already present and its sha256 matches: $destination"
                return 'unchanged'
            }
            throw ("$($Model.Name) is already at '$destination' and its sha256 is $actual, " +
                "not the $($Model.Sha256) this manifest names. It was NOT replaced and NOT " +
                'deleted: a file you already have is yours. Move it aside if you want the ' +
                'manifest''s version.')
        }
        Write-LcWarn ("$($Model.Name) is already present and was NOT verified " +
            "(this entry carries no sha256): $destination")
        return 'unchanged'
    }

    $directory = [System.IO.Path]::GetDirectoryName($destination)
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-LcBootstrapDirectory -Path $directory
    }
    Remove-LcModelPartFile -Path $part

    $result = $null
    try {
        $result = Invoke-LcModelFetch -Url $Model.Url -PartPath $part -Token $Token `
            -TimeoutSeconds $TimeoutSeconds -StallSeconds $StallSeconds
    } catch {
        Remove-LcModelPartFile -Path $part
        throw ("$($Model.Name) was not downloaded: $($_.Exception.Message). Nothing was " +
            "installed at '$destination'.")
    }

    if ((-not $Model.Sha256) -and ($result.Received -ne $Model.SizeBytes)) {
        Remove-LcModelPartFile -Path $part
        throw ("$($Model.Name) is not the size this manifest states: $($Model.SizeBytes) " +
            "bytes were declared and $($result.Received) arrived. This entry carries no " +
            'sha256, so its length is the only thing pinned about it and it did not ' +
            "match. The download was discarded and nothing was installed at '$destination'.")
    }

    if ($Model.Sha256) {
        if ($result.Sha256 -ne $Model.Sha256) {
            Remove-LcModelPartFile -Path $part
            throw ("$($Model.Name) failed verification: the manifest names sha256 " +
                "$($Model.Sha256) and $($result.Sha256) arrived. The download was " +
                "discarded and nothing was installed at '$destination'.")
        }
        Move-LcModelIntoPlace -Part $part -Destination $destination
        Write-LcOk "$($Model.Name) verified (sha256 $($result.Sha256)) and installed: $destination"
        return 'installed'
    }

    Move-LcModelIntoPlace -Part $part -Destination $destination
    Write-LcWarn ("$($Model.Name) was downloaded UNVERIFIED -- this manifest entry carries " +
        "no sha256, so nothing here proves these are the intended bytes. Its sha256 is " +
        "$($result.Sha256): $destination")
    return 'installed'
}

function Install-LcProfileModels {
    <#
        The whole of -InstallModels, in the order the rule requires.

        Told, then asked, then -- and only then -- fetched. The gated refusal
        and the missing-token refusal both sit BEFORE the consent question, so
        nobody is asked to agree to something that is not going to happen.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Models,
        [Parameter(Mandatory)][string]$ModelsRoot,
        [Parameter(Mandatory)][string]$Profile,
        [switch]$Accepted,
        [double]$TimeoutSeconds = 600,
        [double]$StallSeconds = 120
    )
    if ($Models.Count -eq 0) {
        Write-Host ''
        Write-LcOk ("Profile '$(ConvertTo-LcProfileName -Name $Profile)' names no models, " +
            'so -InstallModels has nothing to download and nothing was fetched.')
        return
    }

    Write-LcModelPlan -Models $Models -ModelsRoot $ModelsRoot -Profile $Profile
    Assert-LcNoGatedModel -Models $Models

    $token = ''
    $needsToken = $false
    foreach ($model in $Models) { if ($model.RequiresToken) { $needsToken = $true } }
    if ($needsToken) {
        $token = Get-LcModelToken
        if (-not $token) {
            throw ("One or more of these models needs a token, and " +
                "$($script:LcModelCredentialVariable) is not set in this session. Nothing was " +
                'downloaded. Set it for this session only -- LocalCanvas never writes it ' +
                'to a file, a log or a command line, and never stores it.')
        }
    }

    # A dry run is not asked. It downloads nothing by construction -- the
    # interlock inside Invoke-LcModelFetch throws during one -- so a question
    # would be asking somebody to agree to something that cannot happen, and
    # in a non-interactive session it would turn a dry run into a failure.
    # Everything ABOVE this line still runs in a dry run, including the gated
    # refusal and the missing-token refusal, because a dry run that did not
    # report the two things that would stop the real run would be worthless.
    if (Test-LcBootstrapDryRun) {
        Write-Host ''
        Write-LcDetail ('Dry run: you were not asked, because nothing will be downloaded. ' +
            'The list above is what a real run would ask about.')
    } else {
        Request-LcModelConsent -Accepted:$Accepted
    }

    foreach ($model in $Models) {
        $destination = Get-LcModelDestination -ModelsRoot $ModelsRoot -Model $model
        $entryToken = if ($model.RequiresToken) { $token } else { '' }
        Invoke-LcStep -Description "download $($model.Name) to $destination" -Action {
            [void](Install-LcModel -Model $model -ModelsRoot $ModelsRoot -Token $entryToken `
                    -TimeoutSeconds $TimeoutSeconds -StallSeconds $StallSeconds)
        }
    }
}
