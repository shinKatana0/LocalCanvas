#requires -Version 7.0
# LocalCanvas v0.1 requires PowerShell 7 or newer (README.md), so the host
# refuses this script under Windows PowerShell 5.1 before its body parses:
# nothing is read, written, started or changed by a 5.1 run. The helpers
# under lib/ are dot-sourced, not entry points, and deliberately keep their
# 5.1 coverage -- they carry no #requires.

<#
.SYNOPSIS
    Strict LAN mode: enable / status / verify / disable.

.DESCRIPTION
    Machine-level Windows Firewall enforcement of LAN-only operation, per
    docs/privacy-security.md. Firewall *guidance* tells you what to do; this
    actually does it, and can be undone.

    Two rules bind every subcommand, and this script is arranged around them.

    REVERSIBLE. Every rule is created under one identifiable group,
    'LocalCanvas Strict LAN'. Nothing here edits, disables or deletes a rule it
    did not create, and nothing here changes a firewall profile's default
    inbound or outbound action. `disable` removes precisely that group, so the
    prior state returns because it was never rewritten -- only overlaid.

    That last sentence is enforced rather than intended: removal refuses any
    name that does not carry LocalCanvas's own rule prefix and any name
    carrying a wildcard character, and it reports what it refused. The check
    lives in the removal itself (Invoke-LcStrictLanRemove), because a rule name
    can arrive from a -FactsFile description as easily as from this machine.

    NEVER SILENT. Nothing changes without the actual rules being printed first
    -- not a summary afterwards. Every subcommand takes -Plan, which prints
    exactly what it would do and changes nothing at all.

    Elevation is required to change firewall policy. Without it the plan is
    still printed in full and then refused, plainly, with nothing applied.

.PARAMETER Action
    enable | status | verify | disable. Default: status.

.PARAMETER Config
    Path to the runtime configuration. Default: config/local/runtime.yaml.

.PARAMETER PythonExe
    LocalCanvas's own interpreter. Default: .venv\Scripts\python.exe.

.PARAMETER Plan
    Print exactly what this subcommand would do and change nothing. Every
    subcommand supports it, including `verify`, which then names the probes it
    would run without running any of them.

.PARAMETER Json
    Print one machine-readable JSON document instead of the human report.
    Implies no change of any kind for `status` and, with -Plan, for the rest.

.PARAMETER Yes
    Skip the confirmation `enable` asks for before applying. Without it, and
    without a console to ask on, `enable` refuses rather than applying.

.PARAMETER FactsFile
    Compute the plan from a JSON description of a machine instead of from this
    one: its interfaces (address and prefix_length, optionally name and
    profile), default_gateways, dns_servers, and optionally owned_rules -- the
    LocalCanvas rules that machine already carries, which decides the reported
    state. An absent owned_rules means "read them from this machine"; a present
    but empty one means "it carries none".

    A planning aid only, in BOTH directions: a plan built from a described
    machine is never applied, and a removal list read from one is never
    removed. A rule set derived from a network nobody checked against this
    machine is how a machine loses its own LAN; a removal list read the same
    way is how it loses firewall policy that cannot be put back.

.EXAMPLE
    .\scripts\strict-lan.ps1 enable -Plan
    .\scripts\strict-lan.ps1 status
    .\scripts\strict-lan.ps1 verify
    .\scripts\strict-lan.ps1 disable
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('enable', 'status', 'verify', 'disable')]
    [string]$Action = 'status',
    [string]$Config,
    [string]$PythonExe,
    [switch]$Plan,
    [switch]$Json,
    [switch]$Yes,
    [string]$FactsFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
. (Join-Path $PSScriptRoot 'lib\StrictLan.ps1')

$EXIT_OK = 0
$EXIT_UNEXPECTED = 1
$EXIT_CONFIG = 2
$EXIT_REFUSED = 3
$EXIT_NOT_PROVEN = 4

<#
    The addresses `verify` uses to establish that non-local connectivity is
    genuinely unavailable. IP literals on purpose: a hostname would be resolved
    by the LAN resolver, which strict mode permits, so a lookup succeeding or
    failing would say nothing about egress. Nothing is sent to them -- only a
    TCP connection is attempted, and while strict mode is on none of these
    attempts leaves this machine.
#>
$script:WanProbes = @(
    [pscustomobject]@{ Address = '1.1.1.1'; Port = 53; Label = 'a public DNS resolver (IPv4)' }
    [pscustomobject]@{ Address = '8.8.8.8'; Port = 53; Label = 'a second public DNS resolver (IPv4)' }
    [pscustomobject]@{ Address = '9.9.9.9'; Port = 443; Label = 'a public resolver on the HTTPS port (IPv4)' }
    [pscustomobject]@{ Address = '2606:4700:4700::1111'; Port = 53; Label = 'a public DNS resolver (IPv6)' }
)

function Format-WanProbeTarget {
    param([Parameter(Mandatory)]$Probe)
    $literal = if ($Probe.Address -like '*:*') { "[$($Probe.Address)]" } else { $Probe.Address }
    return "${literal}:$($Probe.Port)"
}

$repoRoot = Get-LcRepoRoot
if (-not $Config) { $Config = Join-Path $repoRoot 'config\local\runtime.yaml' }

function Write-Lines {
    param([string[]]$Lines)
    foreach ($line in $Lines) { Write-LcDetail $line }
}

<#
    -Json promises "one machine-readable document instead of the human report",
    and `verify` is the one subcommand that does its work as it prints. So its
    report goes through here, which says nothing at all when -Json is set --
    otherwise the document would arrive with a page of prose in front of it and
    nothing could parse it.
#>
$script:ReportQuietly = [bool]$Json

function Out-Report {
    param(
        [ValidateSet('info', 'ok', 'warn', 'fail', 'detail', 'blank')][string]$Kind = 'detail',
        [string]$Text = ''
    )
    if ($script:ReportQuietly) { return }
    switch ($Kind) {
        'info' { Write-LcInfo $Text }
        'ok' { Write-LcOk $Text }
        'warn' { Write-LcWarn $Text }
        'fail' { Write-LcFail $Text }
        'detail' { Write-LcDetail $Text }
        'blank' { Write-Host '' }
    }
}

function Test-LcTcpReachable {
    <#
        One TCP connection attempt with a deadline. Returns { Ok; Error }.
        A refused or timed-out connection is the expected outcome here, so it
        is a result and never an exception.
    #>
    param(
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][int]$Port,
        [double]$TimeoutSeconds = 3
    )
    $client = $null
    try {
        $parsed = [System.Net.IPAddress]::Parse($Address)
        $client = [System.Net.Sockets.TcpClient]::new($parsed.AddressFamily)
        $task = $client.ConnectAsync($parsed, $Port)
        if (-not $task.Wait([int]($TimeoutSeconds * 1000))) {
            return [pscustomobject]@{ Ok = $false; Error = "no answer within ${TimeoutSeconds}s" }
        }
        if ($task.IsFaulted) {
            $inner = $task.Exception.GetBaseException()
            return [pscustomobject]@{ Ok = $false; Error = $inner.Message }
        }
        return [pscustomobject]@{ Ok = $true; Error = '' }
    } catch {
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        return [pscustomobject]@{ Ok = $false; Error = $inner.Message }
    } finally {
        if ($client) { $client.Dispose() }
    }
}

try {
    # ------------------------------------------------------------------
    # Everything every subcommand needs: the interpreter, the configuration
    # across the seam, the facts, and the plan computed from both.
    # ------------------------------------------------------------------
    try {
        $python = Resolve-LcPython -PythonExe $PythonExe
    } catch [System.IO.FileNotFoundException] {
        Write-LcBanner
        Write-LcFailure -What 'LocalCanvas has no Python environment yet' `
            -Detail @("Expected: $(if ($PythonExe) { $PythonExe } else { Get-LcVenvPython })") `
            -Fix 'Run scripts\setup.ps1 to create .venv and install the gateway into it.'
        exit $EXIT_CONFIG
    }

    $loaded = Read-LcConfig -ConfigPath $Config -PythonExe $python
    if (-not $loaded.Ok) {
        Write-LcBanner
        Write-LcFailure -What $loaded.What -Detail $loaded.Detail -Fix $loaded.Hint
        exit $EXIT_CONFIG
    }
    $cfg = $loaded.Document

    $describedNetwork = [bool]$FactsFile
    if ($describedNetwork) {
        $facts = Read-LcNetworkFactsFile -Path $FactsFile
    } else {
        $facts = Get-LcNetworkFacts
    }
    $strictPlan = New-LcStrictLanPlan -Config $cfg -Facts $facts

    $firewallAvailable = Test-LcFirewallModuleAvailable

    <#
        Which LocalCanvas rules exist. Read from this machine, unless the
        -FactsFile description answered the question itself -- the same seam,
        for the same reason: it makes the "strict mode is already on" gate
        reachable without a rule existing anywhere. A description can never
        apply anything (the refusal below), so this cannot become a way to act
        on a machine that was never looked at.
    #>
    $describedRules = ($null -ne $facts.OwnedRules)
    $owned = $null
    if ($describedRules) {
        $owned = @($facts.OwnedRules)
    } elseif ($firewallAvailable) {
        $owned = Get-LcStrictLanRules
    }

    $state = if ($null -eq $owned) { 'unknown' } else { Get-LcStrictLanStateName -Plan $strictPlan -OwnedRules $owned }
    $stateDetail = ''
    if ($null -eq $owned) {
        $stateDetail = 'This machine''s firewall could not be read (the NetSecurity cmdlets are unavailable), so the state is not known.'
    } elseif ($describedRules) {
        # Never let a described state read as a report about this machine.
        $stateDetail = "These rules were read from the description in $($strictPlan.FactsSource), not from this machine."
    }

    # ------------------------------------------------------------------
    # status -- read-only
    # ------------------------------------------------------------------
    if ($Action -eq 'status') {
        if ($Json) {
            [pscustomobject]@{
                action = 'status'; state = $state; applied = $false
                owned_rules = @($owned); plan = $strictPlan
            } | ConvertTo-Json -Depth 8 -Compress
            exit $EXIT_OK
        }
        Write-LcBanner
        Write-LcInfo 'Strict LAN mode - status (read-only; nothing was changed)'
        Write-Host ''
        Write-Lines (Format-LcStrictLanState -Plan $strictPlan -OwnedRules @($owned) -State $state -Detail $stateDetail)
        Write-Host ''
        exit $EXIT_OK
    }

    # ------------------------------------------------------------------
    # verify -- both halves, and what it could not test
    # ------------------------------------------------------------------
    if ($Action -eq 'verify') {
        $endpoints = Get-LcEndpoints -Config $cfg
        $published = Get-LcPublishedEndpoint -Config $cfg -Endpoints $endpoints
        $lanHealthUrl = $published.Url.TrimEnd('/') + '/api/v1/info'

        if ($Plan) {
            if ($Json) {
                [pscustomobject]@{
                    action = 'verify'; planned = $true; applied = $false; state = $state
                    lan_probe = $lanHealthUrl
                    wan_probes = @($script:WanProbes | ForEach-Object { (Format-WanProbeTarget -Probe $_) })
                } | ConvertTo-Json -Depth 8 -Compress
                exit $EXIT_OK
            }
            Write-LcBanner
            Write-LcInfo 'Strict LAN mode - verify (plan only; nothing was probed and nothing was changed)'
            Write-Host ''
            Write-Lines @(
                'Half 1 - the LocalCanvas LAN path still works. It would request:',
                "  $lanHealthUrl",
                '  and require a LocalCanvas gateway to answer it.',
                '',
                'Half 2 - non-local connectivity is genuinely unavailable. It would attempt',
                'a TCP connection, sending nothing, to each of:'
            )
            foreach ($probe in $script:WanProbes) {
                Write-LcDetail "  $(Format-WanProbeTarget -Probe $probe) - $($probe.Label)"
            }
            Write-Lines @(
                '  and require every one of them to fail.',
                '',
                'Neither half alone is success: a mode that blocks the phone too is a failure,',
                'and a mode reporting "enabled" while the Internet still works is worse.'
            )
            Write-Host ''
            exit $EXIT_OK
        }

        if (-not $Json) { Write-LcBanner }
        Out-Report info 'Strict LAN mode - verify (read-only; nothing is changed by this)'
        Out-Report blank
        Out-Report detail "Strict LAN mode is currently: $($state.ToUpperInvariant())"
        if ($stateDetail) { Out-Report detail "  $stateDetail" }
        Out-Report blank

        $couldNotTest = @()

        # -- Half 1: the LocalCanvas LAN path ---------------------------
        Out-Report info "Half 1 of 2 - the LocalCanvas LAN path: $lanHealthUrl"
        $lanOk = $false
        if (-not $published.IsLan) {
            # T-0119: a loopback bind is not probed at all, so it can never be
            # reported as the LAN path working. T-0224: it says so for that
            # reason, not for a missing LAN address the machine may well have.
            if ($published.LocalOnlyReason -eq 'loopback-bind') {
                $bind = [string](Get-LcConfigValue -Document $cfg -Path 'gateway.host')
                $couldNotTest += "The LAN path could not be tested: gateway.host is $bind, so the gateway is bound to this machine only and a phone cannot reach it until gateway.host allows it."
                Out-Report fail "Not proven: gateway.host is $bind, so the gateway is bound to this machine only."
            } else {
                $couldNotTest += 'The LAN path could not be tested from a LAN address: no LAN address was detected on this machine, so only loopback was available. A phone cannot reach a loopback address.'
                Out-Report fail 'Not proven: this machine has no detected LAN address.'
            }
        } else {
            $probe = Invoke-LcProbe -Url $lanHealthUrl -TimeoutSeconds 5
            if (-not $probe.Ok) {
                Out-Report fail "Not proven: the gateway did not answer on the LAN address ($($probe.Error))."
                Out-Report detail 'Start LocalCanvas with scripts\start.ps1 and run verify again.'
            } elseif ((Test-LcGatewayIdentity -Body $probe.Body) -ne $true) {
                Out-Report fail 'Not proven: something answered on the LAN address, but it did not identify itself as a LocalCanvas gateway.'
            } else {
                $lanOk = $true
                Out-Report ok 'The LocalCanvas gateway answered on this machine''s LAN address.'
            }
            # T-0257: a claim about the probe, so only the branch that made one
            # makes it -- whatever the probe's outcome was.
            $couldNotTest += 'Half 1 was tested from this machine, to this machine''s own LAN address. It shows the gateway is listening and reachable on the LAN interface; it does not prove that a particular phone, on a particular access point, can reach it.'
        }
        Out-Report blank

        # -- Half 2: non-local connectivity ------------------------------
        Out-Report info 'Half 2 of 2 - non-local connectivity is unavailable'
        $reachable = @()
        $unreachable = @()
        foreach ($target in $script:WanProbes) {
            $result = Test-LcTcpReachable -Address $target.Address -Port $target.Port -TimeoutSeconds 3
            if ($result.Ok) {
                $reachable += (Format-WanProbeTarget -Probe $target)
                Out-Report fail "  REACHED $(Format-WanProbeTarget -Probe $target) - $($target.Label)"
            } else {
                $unreachable += (Format-WanProbeTarget -Probe $target)
                Out-Report detail "  blocked $(Format-WanProbeTarget -Probe $target) - $($target.Label) ($($result.Error))"
            }
        }
        $wanOk = ($reachable.Count -eq 0)
        if ($wanOk) {
            Out-Report ok 'No non-local address answered. Nothing left this machine on any probed path.'
        } else {
            Out-Report fail 'Non-local connectivity is still available. Strict LAN mode is not in force.'
        }

        $couldNotTest += ('Only outbound TCP was attempted, and only to these addresses: ' +
            ((@($script:WanProbes | ForEach-Object { Format-WanProbeTarget -Probe $_ })) -join ', ') +
            '. UDP, ICMP and every address not on that list were not tested.')
        $couldNotTest += 'A failed connection is consistent with strict LAN mode blocking it, and equally consistent with this machine simply having no Internet connection. These probes cannot tell the two apart.'
        $couldNotTest += 'Whatever the LAN itself forwards on this machine''s behalf -- a router answering a DNS query recursively, for instance -- is permitted by design and is not tested here.'
        $couldNotTest += 'This is a control on this machine only. It says nothing about the phone, the router, or any other device on this network.'
        $couldNotTest += 'It is not a check on third-party ComfyUI custom nodes. It shows that outbound access from this machine fails while strict mode is on; it is not, and cannot be, a statement about what any custom node would otherwise do.'
        if ($state -ne 'on') {
            $couldNotTest += "Strict LAN mode is $state, so half 2 proves nothing about strict LAN mode either way -- whatever these probes did, they did without it."
        }

        Out-Report blank
        Out-Report info 'What verify could NOT test'
        foreach ($item in $couldNotTest) { Out-Report detail "  - $item" }
        Out-Report blank

        $proven = ($lanOk -and $wanOk -and $state -eq 'on')
        if ($proven) {
            Out-Report ok 'Both halves proven: the LocalCanvas LAN path works, and non-local connectivity is unavailable.'
        } else {
            Out-Report fail 'NOT proven. Read the two halves above and the list of what could not be tested.'
        }
        Out-Report blank

        if ($Json) {
            [pscustomobject]@{
                action = 'verify'; applied = $false; state = $state
                lan_path_ok = $lanOk; wan_blocked = $wanOk; proven = $proven
                reachable = $reachable; unreachable = $unreachable
                could_not_test = $couldNotTest
            } | ConvertTo-Json -Depth 8 -Compress
        }
        exit $(if ($proven) { $EXIT_OK } else { $EXIT_NOT_PROVEN })
    }

    # ------------------------------------------------------------------
    # enable
    # ------------------------------------------------------------------
    if ($Action -eq 'enable') {
        if ($Json -and $Plan) {
            [pscustomobject]@{
                action = 'enable'; planned = $true; applied = $false
                state = $state; plan = $strictPlan
            } | ConvertTo-Json -Depth 8 -Compress
            exit $EXIT_OK
        }

        Write-LcBanner
        if ($Plan) {
            Write-LcInfo 'Strict LAN mode - enable (plan only; NOTHING has been changed)'
        } else {
            Write-LcInfo 'Strict LAN mode - enable'
        }
        Write-Host ''
        Write-LcDetail "Configuration: $([string](Get-LcConfigValue -Document $cfg -Path 'source'))"
        Write-LcDetail "Network facts: $($strictPlan.FactsSource)"
        Write-Host ''
        # The disclosure and then the rules themselves, in full, before
        # anything is applied. Not a summary, and never afterwards.
        Write-Lines (Format-LcStrictLanPlan -Plan $strictPlan -IncludeDisclosure)
        Write-Host ''

        if ($Plan) {
            Write-LcOk 'Plan only. No firewall rule was created, removed or changed.'
            Write-Host ''
            exit $EXIT_OK
        }

        if (-not $firewallAvailable) {
            Write-LcFailure -What 'Refused: this machine''s firewall cannot be reached' `
                -Detail @('The NetSecurity cmdlets (New-NetFirewallRule) are not available here.',
                'Nothing has been changed.')
            exit $EXIT_REFUSED
        }

        if (@($owned).Count -gt 0) {
            Write-LcFailure -What "Refused: LocalCanvas already owns $(@($owned).Count) rule(s) in group '$($strictPlan.Group)'" `
                -Detail @('Strict LAN mode is already on, or was left partly applied. Nothing has been changed.') `
                -Fix 'Run: scripts\strict-lan.ps1 disable   (then enable again if you want a fresh rule set).'
            exit $EXIT_REFUSED
        }

        if ($describedNetwork) {
            Write-LcFailure -What 'Refused: this plan was computed from a described network, not from this machine' `
                -Detail @("Facts came from: $($strictPlan.FactsSource)",
                'Applying a rule set derived from a network nobody checked against this machine is how a machine loses its own LAN.') `
                -Fix 'Run the same command without -FactsFile to plan and apply against this machine.'
            exit $EXIT_REFUSED
        }

        if (-not (Test-LcElevated)) {
            Write-LcFailure -What 'Refused: changing firewall policy requires Administrator privileges' `
                -Detail @('This session is not elevated, so NOTHING has been applied - not one rule.',
                'The plan above is exactly what would be applied by an elevated run.') `
                -Fix 'Start PowerShell 7 (pwsh) as Administrator and run this command again.'
            exit $EXIT_REFUSED
        }

        if (-not $Yes) {
            $answer = $null
            try {
                Write-Host ''
                $answer = Read-Host 'Apply the rules above and cut this PC off from the Internet? Type ENABLE to confirm'
            } catch {
                $answer = $null
            }
            if ($answer -ne 'ENABLE') {
                Write-LcFailure -What 'Refused: not confirmed' `
                    -Detail @('Nothing has been applied.') `
                    -Fix 'Re-run and type ENABLE at the prompt, or pass -Yes to skip the prompt.'
                exit $EXIT_REFUSED
            }
        }

        Write-Host ''
        Write-LcInfo "Applying $($strictPlan.Rules.Count) rules..."
        $result = Invoke-LcStrictLanApply -Plan $strictPlan
        foreach ($name in $result.Created) { Write-LcOk "  created $name" }
        if (-not $result.Ok) {
            Write-LcFailure -What "Strict LAN mode was only partly applied - stopped at $($result.Failed)" `
                -Detail @($result.Error, "Created so far: $(@($result.Created).Count) of $($strictPlan.Rules.Count).") `
                -Fix 'Run: scripts\strict-lan.ps1 disable   to remove what was created and return to the prior state.'
            exit $EXIT_UNEXPECTED
        }
        Write-Host ''
        Write-LcOk 'Strict LAN mode is ON.'
        Write-LcDetail 'Every application on this PC has lost Internet access, as described above.'
        Write-LcDetail 'Prove it with: scripts\strict-lan.ps1 verify'
        Write-LcDetail 'Undo it with:  scripts\strict-lan.ps1 disable'
        Write-Host ''
        exit $EXIT_OK
    }

    # ------------------------------------------------------------------
    # disable
    # ------------------------------------------------------------------
    if ($Action -eq 'disable') {
        $names = @(@($owned) | ForEach-Object { $_.Name })

        <#
            Which of those names removal will refuse, asked with the same
            function removal itself uses. It is asked here only so that what is
            PRINTED and what is ENFORCED cannot drift apart: the report below
            promises the rules are all LocalCanvas's own, and it may only say
            so when it is true of the list in front of it.
        #>
        $refused = @()
        foreach ($rule in @($owned)) {
            $reason = Test-LcStrictLanRemovableName -Name $rule.Name
            if ($reason) {
                $refused += [pscustomobject]@{ Name = $rule.Name; Reason = $reason }
            }
        }

        if ($Json -and $Plan) {
            [pscustomobject]@{
                action = 'disable'; planned = $true; applied = $false
                state = $state; removes = $names; refused = $refused
                group = $strictPlan.Group
            } | ConvertTo-Json -Depth 8 -Compress
            exit $EXIT_OK
        }

        Write-LcBanner
        if ($Plan) {
            Write-LcInfo 'Strict LAN mode - disable (plan only; NOTHING has been changed)'
        } else {
            Write-LcInfo 'Strict LAN mode - disable'
        }
        Write-Host ''

        if ($null -eq $owned) {
            Write-LcFailure -What 'This machine''s firewall could not be read' `
                -Detail @('The NetSecurity cmdlets are not available here. Nothing has been changed.')
            exit $EXIT_REFUSED
        }

        if ($refused.Count -gt 0) {
            # The promise is not made about a list it is not true of.
            Write-LcDetail ("Rules to remove -- and $($refused.Count) name(s) below that removal will " +
                "REFUSE, because only rules LocalCanvas created may be removed:")
        } else {
            Write-LcDetail "Rules to remove, all of them in group '$($strictPlan.Group)' and created by LocalCanvas:"
        }
        if ($names.Count -eq 0) {
            Write-LcDetail '  (none)'
        } else {
            foreach ($rule in @($owned)) {
                $reason = Test-LcStrictLanRemovableName -Name $rule.Name
                $verdict = if ($reason) { "   <-- REFUSED: $reason" } else { '' }
                Write-LcDetail "  $($rule.Name)  [$($rule.Direction) $($rule.Action), enabled: $($rule.Enabled)]$verdict"
            }
        }
        Write-Host ''
        # Said whether or not there is anything to remove: what `disable` will
        # NOT touch is the reversibility promise, and a user deserves to read
        # it before they need it.
        Write-LcDetail 'Nothing outside that group is read, changed or removed. No firewall profile''s default'
        Write-LcDetail 'inbound or outbound action is touched, so the policy you had before strict LAN mode'
        Write-LcDetail 'returns as it was.'
        Write-Host ''

        <#
            The mirror of `enable`'s described-network refusal, and the half of
            this that matters most. -FactsFile describes a machine that is not
            this one, and its owned_rules are arbitrary strings out of a file:
            acting on them would remove rules from a firewall nobody looked at.
            A description plans; it never changes anything, in either direction.

            -Plan is still allowed through, because that is what -FactsFile is
            for: it prints what would happen elsewhere and touches nothing.
        #>
        if ($describedNetwork -and -not $Plan) {
            Write-LcFailure -What 'Refused: this removal list was computed from a described network, not from this machine' `
                -Detail @("Facts came from: $($strictPlan.FactsSource)",
                'Nothing has been removed. Removing rules named by a document, against a machine',
                'nobody read, is how a firewall loses policy that cannot be put back.') `
                -Fix 'Run the same command without -FactsFile to remove what this machine actually carries, or add -Plan to see what would be removed elsewhere.'
            exit $EXIT_REFUSED
        }

        if ($names.Count -eq 0) {
            Write-LcOk 'Strict LAN mode is already off. LocalCanvas owns no firewall rule on this machine.'
            Write-Host ''
            exit $EXIT_OK
        }

        if ($Plan) {
            Write-LcOk 'Plan only. No firewall rule was removed.'
            Write-Host ''
            exit $EXIT_OK
        }

        if (-not (Test-LcElevated)) {
            Write-LcFailure -What 'Refused: changing firewall policy requires Administrator privileges' `
                -Detail @('This session is not elevated, so NOTHING has been removed - not one rule.',
                'The rules listed above are exactly what an elevated run would remove.') `
                -Fix 'Start PowerShell 7 (pwsh) as Administrator and run this command again.'
            exit $EXIT_REFUSED
        }

        $result = Invoke-LcStrictLanRemove -Names $names
        foreach ($name in $result.Removed) { Write-LcOk "  removed $name" }
        # Reported, never dropped: a name removal would not touch is the one
        # thing about this run a user most needs to be told.
        foreach ($skip in @($result.Skipped)) {
            Write-LcWarn "  refused $($skip.Name) - $($skip.Reason)"
        }
        if (-not $result.Ok) {
            Write-LcFailure -What "Strict LAN mode was only partly removed - stopped at $($result.Failed)" `
                -Detail @($result.Error, "Removed so far: $(@($result.Removed).Count) of $($names.Count).") `
                -Fix 'Run this command again; removal is idempotent and only ever touches LocalCanvas''s own group.'
            exit $EXIT_UNEXPECTED
        }
        if (@($result.Skipped).Count -gt 0) {
            Write-LcFailure -What "Refused $(@($result.Skipped).Count) name(s) that are not rules LocalCanvas created" `
                -Detail @(("Removal only ever touches a rule whose name starts with '$(Get-LcStrictLanRulePrefix)' and contains no wildcard character."),
                ("Removed: $(@($result.Removed).Count) of $($names.Count). Nothing outside LocalCanvas's own group was read or changed.")) `
                -Fix 'Run: scripts\strict-lan.ps1 status   to see what LocalCanvas still owns on this machine.'
            exit $EXIT_REFUSED
        }
        Write-Host ''
        Write-LcOk 'Strict LAN mode is OFF. The prior firewall policy is back, untouched.'
        Write-Host ''
        exit $EXIT_OK
    }

    exit $EXIT_OK
} catch {
    if (Test-LcSeamFailure -ErrorRecord $_) {
        $lines = Get-LcSeamFailureLines -ErrorRecord $_
        Write-LcFailure -What $lines[0] -Detail @($lines | Select-Object -Skip 1)
        exit $EXIT_CONFIG
    }
    if (Test-LcFactsFailure -ErrorRecord $_) {
        $lines = Get-LcFactsFailureLines -ErrorRecord $_
        Write-LcFailure -What 'The network description could not be used' -Detail $lines `
            -Fix 'Correct the -FactsFile document, or omit it to plan against this machine.'
        exit $EXIT_CONFIG
    }
    Write-LcFailure -What "Strict LAN mode '$Action' could not be completed" `
        -Detail @("$($_.Exception.Message)", 'No firewall rule was created or removed by this failure.')
    exit $EXIT_UNEXPECTED
}
