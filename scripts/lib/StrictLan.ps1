<#
.SYNOPSIS
    Strict LAN mode: the rule set, computed.

.DESCRIPTION
    docs/privacy-security.md, "Strict LAN mode". This file is deliberately
    split in two, and the split is the safety property of the whole feature:

      * THE PURE HALF -- everything above the "machine adapter" banner. Given
        a configuration document and a description of the network, it computes
        the exact set of firewall rules strict LAN mode consists of, and
        renders them for a human. It reads nothing, writes nothing, and calls
        no cmdlet that touches this machine, so it can be unit-tested
        exhaustively against invented networks without a rule ever existing.

      * THE MACHINE ADAPTER -- everything below that banner. Collecting the
        network facts (read-only), reading which of our rules exist
        (read-only), and the thin shim that hands the plan's own parameter
        sets to New-NetFirewallRule / removes those rules by name. That shim
        adds no decisions of its own: everything it applies was decided,
        printed and reviewed above it.

    Rules the whole file is written to:

      * Reversible. Every rule is created under one identifiable group,
        '<LocalCanvas Strict LAN>'. Nothing here edits, disables or deletes a
        rule it did not create, and nothing here changes a profile's default
        inbound or outbound action -- so `disable` restores the prior state by
        removing an overlay, not by rebuilding a policy it never recorded.

      * Never silent. The rules are printed before they are applied, as rules,
        not as a summary afterwards.

      * Honest. The permitted local infrastructure is named with the reason it
        is permitted, and the machine-wide collateral effect is disclosed in
        the same breath -- see Format-LcStrictLanDisclosure.
#>

Set-StrictMode -Version Latest

# The one identity every rule this feature creates carries. `disable` removes
# precisely this group and nothing else; `status` counts precisely this group.
$script:LcStrictLanGroup = 'LocalCanvas Strict LAN'
$script:LcStrictLanRulePrefix = 'LocalCanvas-StrictLAN-'
$script:LcStrictLanPlanVersion = 1

# Marks a malformed network-facts document, so a caller can tell a user's bad
# input from an unexpected error.
$script:LcFactsFailureMarker = 'LOCALCANVAS_FACTS_ERROR'

function Get-LcStrictLanGroup { return $script:LcStrictLanGroup }
function Get-LcStrictLanRulePrefix { return $script:LcStrictLanRulePrefix }

function New-LcFactsFailure {
    param([Parameter(Mandatory)][string]$Message)
    throw ($script:LcFactsFailureMarker + "`n" + $Message)
}

function Test-LcFactsFailure {
    param([Parameter(Mandatory)]$ErrorRecord)
    return ("$($ErrorRecord.Exception.Message)".StartsWith($script:LcFactsFailureMarker))
}

function Get-LcFactsFailureLines {
    param([Parameter(Mandatory)]$ErrorRecord)
    $text = "$($ErrorRecord.Exception.Message)".Substring($script:LcFactsFailureMarker.Length)
    return @($text -split "`r?`n" | Where-Object { $_.Trim() })
}

# ==========================================================================
# THE PURE HALF
# ==========================================================================

# --------------------------------------------------------------------------
# Address arithmetic
# --------------------------------------------------------------------------
#
# Ranges are half-open nowhere: every range here is inclusive [Start, End] over
# the integer value of an address, because that is the form Windows Firewall's
# RemoteAddress accepts ("a.b.c.d-e.f.g.h") and the form a complement is easy
# to compute in. IPv6 needs 128 bits, so the arithmetic is [bigint] throughout
# and IPv4 rides along in the same code path rather than in a second one.

function Get-LcAddressFamily {
    param([Parameter(Mandatory)][string]$Address)
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$parsed)) {
        New-LcFactsFailure "'$Address' is not an IP address."
    }
    if ($parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) { return 'IPv4' }
    if ($parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) { return 'IPv6' }
    New-LcFactsFailure "'$Address' is neither IPv4 nor IPv6."
}

function Get-LcFamilyBits {
    param([Parameter(Mandatory)][ValidateSet('IPv4', 'IPv6')][string]$Family)
    if ($Family -eq 'IPv4') { return 32 }
    return 128
}

function Get-LcFamilyMaximum {
    param([Parameter(Mandatory)][ValidateSet('IPv4', 'IPv6')][string]$Family)
    return ([bigint]::Pow(2, (Get-LcFamilyBits -Family $Family)) - [bigint]::One)
}

function ConvertTo-LcIpNumber {
    param([Parameter(Mandatory)][string]$Address)
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$parsed)) {
        New-LcFactsFailure "'$Address' is not an IP address."
    }
    $number = [bigint]::Zero
    foreach ($byte in $parsed.GetAddressBytes()) {
        $number = $number * [bigint]256 + [bigint][int]$byte
    }
    return $number
}

function ConvertFrom-LcIpNumber {
    param(
        [Parameter(Mandatory)][bigint]$Number,
        [Parameter(Mandatory)][ValidateSet('IPv4', 'IPv6')][string]$Family
    )
    $count = if ($Family -eq 'IPv4') { 4 } else { 16 }
    $bytes = New-Object byte[] $count
    $rest = $Number
    for ($index = $count - 1; $index -ge 0; $index--) {
        $bytes[$index] = [byte]($rest % [bigint]256)
        $rest = [bigint]::Divide($rest, [bigint]256)
    }
    return ([System.Net.IPAddress]::new($bytes)).ToString()
}

function New-LcIpRange {
    param(
        [Parameter(Mandatory)][ValidateSet('IPv4', 'IPv6')][string]$Family,
        [Parameter(Mandatory)][bigint]$Start,
        [Parameter(Mandatory)][bigint]$End
    )
    if ($End -lt $Start) { New-LcFactsFailure "An address range ends before it starts." }
    return [pscustomobject]@{ Family = $Family; Start = $Start; End = $End }
}

function ConvertTo-LcIpRange {
    <#
        One CIDR block, one bare address, or one explicit "start-end" pair,
        as a range. The prefix is applied to the address rather than assumed
        to be already aligned: 192.0.2.23/24 is the 192.0.2.0/24 network,
        which is exactly what a machine's own address plus prefix describes.
    #>
    param([Parameter(Mandatory)][string]$Text)
    $value = $Text.Trim()
    if ($value -match '^(?<a>[^-]+)-(?<b>.+)$' -and $value -notmatch '^[0-9a-fA-F:]+$') {
        $family = Get-LcAddressFamily -Address $Matches['a'].Trim()
        $other = Get-LcAddressFamily -Address $Matches['b'].Trim()
        if ($family -ne $other) { New-LcFactsFailure "'$value' mixes IPv4 and IPv6." }
        return New-LcIpRange -Family $family `
            -Start (ConvertTo-LcIpNumber -Address $Matches['a'].Trim()) `
            -End (ConvertTo-LcIpNumber -Address $Matches['b'].Trim())
    }
    if ($value -match '^(?<addr>.+)/(?<len>\d+)$') {
        $address = $Matches['addr'].Trim()
        $length = [int]$Matches['len']
        $family = Get-LcAddressFamily -Address $address
        $bits = Get-LcFamilyBits -Family $family
        if ($length -lt 0 -or $length -gt $bits) {
            New-LcFactsFailure "'$value' has a prefix length outside 0..$bits."
        }
        $number = ConvertTo-LcIpNumber -Address $address
        $size = [bigint]::Pow(2, $bits - $length)
        $start = $number - ($number % $size)
        return New-LcIpRange -Family $family -Start $start -End ($start + $size - [bigint]::One)
    }
    $family = Get-LcAddressFamily -Address $value
    $number = ConvertTo-LcIpNumber -Address $value
    return New-LcIpRange -Family $family -Start $number -End $number
}

function Format-LcIpRange {
    param([Parameter(Mandatory)]$Range)
    $start = ConvertFrom-LcIpNumber -Number $Range.Start -Family $Range.Family
    if ($Range.Start -eq $Range.End) { return $start }
    $end = ConvertFrom-LcIpNumber -Number $Range.End -Family $Range.Family
    return "$start-$end"
}

function Merge-LcIpRanges {
    <#
        Sorted, non-overlapping, and with touching ranges joined -- so the
        printed rule reads as few ranges as the network actually has, and so
        the complement below is a single pass.
    #>
    param([object[]]$Ranges = @())
    $ordered = @($Ranges | Sort-Object -Property @{ Expression = { $_.Start } }, @{ Expression = { $_.End } })
    $merged = @()
    foreach ($range in $ordered) {
        if ($merged.Count -eq 0) {
            $merged += (New-LcIpRange -Family $range.Family -Start $range.Start -End $range.End)
            continue
        }
        $last = $merged[$merged.Count - 1]
        if ($range.Start -le ($last.End + [bigint]::One)) {
            if ($range.End -gt $last.End) { $last.End = $range.End }
            continue
        }
        $merged += (New-LcIpRange -Family $range.Family -Start $range.Start -End $range.End)
    }
    return , $merged
}

function Get-LcComplementRanges {
    <#
        Everything in the family that the given ranges do not cover.

        This is the whole of "block non-local traffic": Windows Firewall's
        RemoteAddress cannot express "not these addresses", so the negation is
        computed here and written out as the explicit ranges that remain.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('IPv4', 'IPv6')][string]$Family,
        [object[]]$Ranges = @()
    )
    $merged = Merge-LcIpRanges -Ranges @($Ranges | Where-Object { $_.Family -eq $Family })
    $maximum = Get-LcFamilyMaximum -Family $Family
    $result = @()
    $cursor = [bigint]::Zero
    foreach ($range in $merged) {
        if ($range.Start -gt $cursor) {
            $result += (New-LcIpRange -Family $Family -Start $cursor -End ($range.Start - [bigint]::One))
        }
        if (($range.End + [bigint]::One) -gt $cursor) { $cursor = $range.End + [bigint]::One }
    }
    if ($cursor -le $maximum) {
        $result += (New-LcIpRange -Family $Family -Start $cursor -End $maximum)
    }
    return , $result
}

# --------------------------------------------------------------------------
# Network facts
# --------------------------------------------------------------------------
#
# What the plan needs to know about the machine, as data. Collected by the
# machine adapter below, or read from a file for planning against a network
# that is not this one -- either way it arrives here and is validated in one
# place, so the pure computation never sees a half-formed document.

function Get-LcFactField {
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    try {
        $property = $Object.PSObject.Properties[$Name]
    } catch {
        return $null
    }
    if ($null -eq $property) { return $null }
    return $property.Value
}

function ConvertTo-LcNetworkFacts {
    <#
        Normalize and validate a facts document. Pure: it parses, checks and
        reshapes, and asks the machine nothing.
    #>
    param([Parameter(Mandatory)]$Raw, [string]$Source = 'this machine')

    $interfaces = @()
    foreach ($item in @(Get-LcFactField -Object $Raw -Name 'interfaces')) {
        if ($null -eq $item) { continue }
        $address = [string](Get-LcFactField -Object $item -Name 'address')
        if (-not $address) { New-LcFactsFailure "interfaces: an entry has no 'address'." }
        $family = Get-LcAddressFamily -Address $address
        $prefixRaw = Get-LcFactField -Object $item -Name 'prefix_length'
        if ($null -eq $prefixRaw) { New-LcFactsFailure "interfaces: '$address' has no 'prefix_length'." }
        $prefix = [int]$prefixRaw
        $bits = Get-LcFamilyBits -Family $family
        if ($prefix -lt 0 -or $prefix -gt $bits) {
            New-LcFactsFailure "interfaces: '$address' has prefix_length $prefix, outside 0..$bits."
        }
        $interfaces += [pscustomobject]@{
            Name         = [string](Get-LcFactField -Object $item -Name 'name')
            Profile      = [string](Get-LcFactField -Object $item -Name 'profile')
            Family       = $family
            Address      = $address
            PrefixLength = $prefix
        }
    }

    $gateways = @()
    foreach ($item in @(Get-LcFactField -Object $Raw -Name 'default_gateways')) {
        if ($null -eq $item) { continue }
        $address = if ($item -is [string]) { $item } else { [string](Get-LcFactField -Object $item -Name 'address') }
        if (-not $address) { continue }
        $gateways += [pscustomobject]@{ Address = $address; Family = (Get-LcAddressFamily -Address $address) }
    }

    $resolvers = @()
    foreach ($item in @(Get-LcFactField -Object $Raw -Name 'dns_servers')) {
        if ($null -eq $item) { continue }
        $address = if ($item -is [string]) { $item } else { [string](Get-LcFactField -Object $item -Name 'address') }
        if (-not $address) { continue }
        $resolvers += [pscustomobject]@{ Address = $address; Family = (Get-LcAddressFamily -Address $address) }
    }

    $notes = @()
    foreach ($note in @(Get-LcFactField -Object $Raw -Name 'notes')) {
        if ($note) { $notes += [string]$note }
    }

    <#
        A description of a machine may also describe the LocalCanvas rules that
        machine already carries. The distinction that matters is between the
        key being ABSENT -- "ask the real machine" -- and being present but
        empty, which is an answer: "it carries none". So the presence of the
        property is what is tested, never the emptiness of its value; `-ne
        $null` against an empty array filters rather than compares, and would
        collapse the two cases into one.
    #>
    $ownedProperty = $null
    if ($null -ne $Raw) {
        try { $ownedProperty = $Raw.PSObject.Properties['owned_rules'] } catch { $ownedProperty = $null }
    }
    $ownedRules = $null
    if ($null -ne $ownedProperty) {
        $ownedRules = @()
        foreach ($item in @($ownedProperty.Value)) {
            if ($null -eq $item) { continue }
            $name = [string](Get-LcFactField -Object $item -Name 'Name')
            if (-not $name) { New-LcFactsFailure "owned_rules: an entry has no 'Name'." }
            $ownedRules += [pscustomobject]@{
                Name        = $name
                DisplayName = [string](Get-LcFactField -Object $item -Name 'DisplayName')
                Direction   = [string](Get-LcFactField -Object $item -Name 'Direction')
                Action      = [string](Get-LcFactField -Object $item -Name 'Action')
                Enabled     = [string](Get-LcFactField -Object $item -Name 'Enabled')
            }
        }
    }

    return [pscustomobject]@{
        Source          = $Source
        Interfaces      = $interfaces
        DefaultGateways = $gateways
        DnsServers      = $resolvers
        Notes           = $notes
        # $null means "not described; read them from the machine".
        OwnedRules      = $ownedRules
    }
}

function Test-LcAddressInRanges {
    param(
        [Parameter(Mandatory)][string]$Address,
        [object[]]$Ranges = @()
    )
    $family = Get-LcAddressFamily -Address $Address
    $number = ConvertTo-LcIpNumber -Address $Address
    foreach ($range in $Ranges) {
        if ($range.Family -ne $family) { continue }
        if ($number -ge $range.Start -and $number -le $range.End) { return $true }
    }
    return $false
}

# --------------------------------------------------------------------------
# The rule set
# --------------------------------------------------------------------------

function New-LcStrictLanRule {
    param(
        [Parameter(Mandatory)][string]$Slug,
        [Parameter(Mandatory)][string]$Summary,
        [Parameter(Mandatory)][ValidateSet('Inbound', 'Outbound')][string]$Direction,
        [Parameter(Mandatory)][ValidateSet('Allow', 'Block')][string]$Action,
        [Parameter(Mandatory)][string]$Protocol,
        [string]$LocalPort = '',
        [string]$RemotePort = '',
        [string[]]$RemoteAddress = @('Any'),
        [string]$Profile = 'Any',
        [string]$IcmpType = '',
        [Parameter(Mandatory)][string]$Reason
    )
    return [pscustomobject]@{
        Name          = $script:LcStrictLanRulePrefix + $Slug
        DisplayName   = "LocalCanvas Strict LAN - $Summary"
        Group         = $script:LcStrictLanGroup
        Direction     = $Direction
        Action        = $Action
        Protocol      = $Protocol
        LocalPort     = $LocalPort
        RemotePort    = $RemotePort
        RemoteAddress = @($RemoteAddress)
        Profile       = $Profile
        IcmpType      = $IcmpType
        Reason        = $Reason
    }
}

function Add-LcPermittedScope {
    <#
        Record one permitted scope: the label and the reason a human will read,
        and the address ranges the complement below is computed against. The
        two must never drift apart, which is why they are appended together and
        in one place.
    #>
    param(
        [Parameter(Mandatory)][ref]$Permitted,
        [Parameter(Mandatory)][ref]$Ranges,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Reason,
        [Parameter(Mandatory)][string[]]$Texts
    )
    if ($Texts.Count -eq 0) { return }
    $parsed = @()
    foreach ($text in $Texts) { $parsed += (ConvertTo-LcIpRange -Text $text) }
    $Permitted.Value = @($Permitted.Value) + @([pscustomobject]@{
            Label  = $Label
            Reason = $Reason
            Ranges = @($Texts)
        })
    $Ranges.Value = @($Ranges.Value) + $parsed
}

function New-LcStrictLanPlan {
    <#
        THE pure function of this feature.

        In: the configuration document (across the seam -- never a second YAML
        reader) and a validated facts object. Out: the complete rule set, the
        permitted scopes with the reason each is permitted, the warnings the
        network itself provoked, and the collateral effect. Nothing is read
        from the machine here and nothing is applied; the same inputs always
        produce the same plan, which is what makes it testable at all.
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Facts
    )

    $gatewayPort = [int](Get-LcConfigValue -Document $Config -Path 'gateway.port')
    $comfyHost = [string](Get-LcConfigValue -Document $Config -Path 'comfy.host')
    $comfyPort = [int](Get-LcConfigValue -Document $Config -Path 'comfy.port')

    $warnings = @()
    $permitted = @()
    $allRanges = @()

    Add-LcPermittedScope ([ref]$permitted) ([ref]$allRanges) `
        'Loopback and the unspecified address (127.0.0.0/8, ::1, 0.0.0.0, ::)' `
        'this machine talking to itself. ComfyUI listens on loopback, and the gateway reaches it there. 0.0.0.0 and :: are the "no address" placeholders -- nothing can be reached at them, and naming them here keeps the blocked list to addresses that actually exist.' `
        @('127.0.0.0/8', '::1/128', '0.0.0.0/32', '::/128')

    Add-LcPermittedScope ([ref]$permitted) ([ref]$allRanges) `
        'Link-local (169.254.0.0/16, fe80::/10)' `
        'the addresses a machine gives itself when no DHCP lease has arrived yet, and the IPv6 addresses every LAN neighbour is reached at.' `
        @('169.254.0.0/16', 'fe80::/10')

    Add-LcPermittedScope ([ref]$permitted) ([ref]$allRanges) `
        'Local multicast and broadcast (224.0.0.0/4, ff00::/8, 255.255.255.255)' `
        'mDNS / DNS-SD discovery, so the app can find this PC, and the broadcasts DHCP needs.' `
        @('224.0.0.0/4', 'ff00::/8', '255.255.255.255/32')

    # The subnets this machine is actually on. A permitted scope, not a
    # guessed one: it comes from the addresses the adapters hold.
    $subnetTexts = @()
    $subnetLabels = @()
    $publicNetworks = @()
    foreach ($nic in $Facts.Interfaces) {
        if ($nic.Family -eq 'IPv4' -and ($nic.Address -like '127.*' -or $nic.Address -like '169.254.*')) { continue }
        if ($nic.Family -eq 'IPv6' -and ($nic.Address -eq '::1' -or $nic.Address -like 'fe80:*')) { continue }
        $cidr = "$($nic.Address)/$($nic.PrefixLength)"
        $range = ConvertTo-LcIpRange -Text $cidr
        $network = (ConvertFrom-LcIpNumber -Number $range.Start -Family $range.Family) + '/' + $nic.PrefixLength
        if ($subnetTexts -notcontains $network) {
            $subnetTexts += $network
            $subnetLabels += "$network (via $($nic.Name))"
        }
        if ($nic.Profile -eq 'Public' -and $publicNetworks -notcontains $nic.Name) {
            $publicNetworks += $nic.Name
        }
    }
    if ($publicNetworks.Count -gt 0) {
        $warnings += ("These networks are classified Public: " + ($publicNetworks -join ', ') +
            ". Windows treats a Public network as untrusted, and the inbound rule for the gateway is written for the Private profile only (docs/privacy-security.md: the gateway port is allowed on Private networks, never on Public). The phone will not reach LocalCanvas over a network left on Public.")
    }
    if ($subnetTexts.Count -gt 0) {
        Add-LcPermittedScope ([ref]$permitted) ([ref]$allRanges) `
            ('LAN subnets: ' + ($subnetLabels -join ', ')) `
            'the local network itself -- this is the path between the phone and the gateway.' `
            $subnetTexts
    } else {
        $warnings += 'No LAN subnet was detected on this machine. Strict LAN mode would permit loopback and link-local traffic only, and no phone would reach the gateway.'
    }

    # Infrastructure the machine cannot function without, named one by one.
    $gatewayTexts = @($Facts.DefaultGateways | ForEach-Object { $_.Address })
    if ($gatewayTexts.Count -gt 0) {
        Add-LcPermittedScope ([ref]$permitted) ([ref]$allRanges) `
            ('Default gateway: ' + ($gatewayTexts -join ', ')) `
            'the router itself. Without it this machine cannot renew a lease, resolve a name through the router, or reach anything on another local segment.' `
            $gatewayTexts
        $warnings += 'Permitting the default gateway permits traffic addressed TO the router. It does not permit traffic THROUGH it -- anything beyond the router is blocked by address -- but whatever the router itself chooses to forward on this machine''s behalf, such as a DNS lookup it answers recursively, is by definition still permitted.'
    } else {
        $warnings += 'No default gateway was detected. If this machine has one, name it in the facts before applying, or DHCP renewal and LAN DNS may stop working while strict mode is on.'
    }

    # A resolver on the LAN is permitted. A public resolver is NOT quietly
    # permitted -- that would be a hole in the middle of the feature -- so it
    # is named as the breakage it will cause instead.
    $localSoFar = @($allRanges)
    $resolverTexts = @()
    $offLanResolvers = @()
    foreach ($resolver in $Facts.DnsServers) {
        if (Test-LcAddressInRanges -Address $resolver.Address -Ranges $localSoFar) {
            if ($resolverTexts -notcontains $resolver.Address) { $resolverTexts += $resolver.Address }
        } elseif ($offLanResolvers -notcontains $resolver.Address) {
            $offLanResolvers += $resolver.Address
        }
    }
    if ($offLanResolvers.Count -gt 0) {
        $warnings += ('These DNS resolvers are not on this LAN and are NOT permitted: ' +
            ($offLanResolvers -join ', ') +
            '. Name resolution through them will fail while strict mode is on. Point this machine at the resolver on your LAN (usually the router) before enabling, or expect names not to resolve.')
    }
    if ($resolverTexts.Count -gt 0) {
        Add-LcPermittedScope ([ref]$permitted) ([ref]$allRanges) `
            ('LAN DNS resolvers: ' + ($resolverTexts -join ', ')) `
            'name resolution. These are already inside the permitted local scopes; they are listed because DNS is the traffic users are most surprised to find permitted.' `
            $resolverTexts
    }

    $blockedV4 = Get-LcComplementRanges -Family 'IPv4' -Ranges $allRanges
    $blockedV6 = Get-LcComplementRanges -Family 'IPv6' -Ranges $allRanges
    $permittedV4 = Merge-LcIpRanges -Ranges @($allRanges | Where-Object { $_.Family -eq 'IPv4' })
    $permittedV6 = Merge-LcIpRanges -Ranges @($allRanges | Where-Object { $_.Family -eq 'IPv6' })

    $lanTexts = if ($subnetTexts.Count -gt 0) { $subnetTexts } else { @('LocalSubnet') }

    $rules = @()

    $rules += New-LcStrictLanRule -Slug 'Allow-Gateway-Inbound' -Summary "gateway port $gatewayPort from the LAN" `
        -Direction 'Inbound' -Action 'Allow' -Protocol 'TCP' -LocalPort ([string]$gatewayPort) `
        -RemoteAddress $lanTexts -Profile 'Private' `
        -Reason "the phone reaches the LocalCanvas gateway here. This is the LAN path strict mode exists to preserve."

    $rules += New-LcStrictLanRule -Slug 'Allow-mDNS-Outbound' -Summary 'mDNS discovery out' `
        -Direction 'Outbound' -Action 'Allow' -Protocol 'UDP' -RemotePort '5353' `
        -RemoteAddress @('224.0.0.251', 'ff02::fb') -Profile 'Any' `
        -Reason 'DNS-SD announcements, so the app finds this PC without being told an address.'

    $rules += New-LcStrictLanRule -Slug 'Allow-mDNS-Inbound' -Summary 'mDNS discovery in' `
        -Direction 'Inbound' -Action 'Allow' -Protocol 'UDP' -LocalPort '5353' `
        -RemoteAddress $lanTexts -Profile 'Private' `
        -Reason 'the queries a phone on this LAN sends while looking for the gateway.'

    $rules += New-LcStrictLanRule -Slug 'Allow-DHCP' -Summary 'DHCP client' `
        -Direction 'Outbound' -Action 'Allow' -Protocol 'UDP' -LocalPort '68' -RemotePort '67' `
        -RemoteAddress @('Any') -Profile 'Any' `
        -Reason 'without it this machine loses its network address when the lease expires. DHCP is broadcast before an address exists, so it cannot be restricted by address.'

    if ($resolverTexts.Count -gt 0) {
        $rules += New-LcStrictLanRule -Slug 'Allow-DNS-UDP' -Summary 'LAN DNS (UDP)' `
            -Direction 'Outbound' -Action 'Allow' -Protocol 'UDP' -RemotePort '53' `
            -RemoteAddress $resolverTexts -Profile 'Any' `
            -Reason 'name resolution through the resolver this machine is configured to use, which is on the LAN.'
        $rules += New-LcStrictLanRule -Slug 'Allow-DNS-TCP' -Summary 'LAN DNS (TCP)' `
            -Direction 'Outbound' -Action 'Allow' -Protocol 'TCP' -RemotePort '53' `
            -RemoteAddress $resolverTexts -Profile 'Any' `
            -Reason 'the same resolver, for answers too large for UDP.'
    }

    if ($gatewayTexts.Count -gt 0) {
        $rules += New-LcStrictLanRule -Slug 'Allow-Default-Gateway' -Summary 'the router itself' `
            -Direction 'Outbound' -Action 'Allow' -Protocol 'Any' `
            -RemoteAddress $gatewayTexts -Profile 'Any' `
            -Reason 'the default gateway must stay reachable at its own address. Traffic beyond it is still blocked by address.'
    }

    $rules += New-LcStrictLanRule -Slug 'Allow-NDP-Outbound' -Summary 'IPv6 neighbour discovery out' `
        -Direction 'Outbound' -Action 'Allow' -Protocol 'ICMPv6' -IcmpType '133,134,135,136,137' `
        -RemoteAddress @('fe80::/10', 'ff00::/8') -Profile 'Any' `
        -Reason 'router and neighbour solicitation: the IPv6 equivalent of ARP. Without it IPv6 on the LAN stops.'

    $rules += New-LcStrictLanRule -Slug 'Allow-NDP-Inbound' -Summary 'IPv6 neighbour discovery in' `
        -Direction 'Inbound' -Action 'Allow' -Protocol 'ICMPv6' -IcmpType '133,134,135,136,137' `
        -RemoteAddress @('fe80::/10', 'ff00::/8') -Profile 'Any' `
        -Reason 'the other half of neighbour discovery. ARP itself is below the Windows Firewall and is never filtered by it -- there is no rule to write for ARP.'

    # A rule that names no address blocks nothing, so an empty complement
    # produces no rule and a warning instead of a rule that looks like a block
    # and is not one. (It happens: a /0 on an interface makes the whole
    # Internet "local", and saying so is better than pretending otherwise.)
    $blockedV4Text = @($blockedV4 | ForEach-Object { Format-LcIpRange -Range $_ })
    $blockedV6Text = @($blockedV6 | ForEach-Object { Format-LcIpRange -Range $_ })

    if ($blockedV4Text.Count -gt 0) {
        $rules += New-LcStrictLanRule -Slug 'Block-Outbound-IPv4' -Summary 'every non-local IPv4 address, outbound' `
            -Direction 'Outbound' -Action 'Block' -Protocol 'Any' `
            -RemoteAddress $blockedV4Text -Profile 'Any' `
            -Reason 'this is the block. Everything outside the permitted scopes above, for every application on this machine.'
        $rules += New-LcStrictLanRule -Slug 'Block-Inbound-IPv4' -Summary 'every non-local IPv4 address, inbound' `
            -Direction 'Inbound' -Action 'Block' -Protocol 'Any' `
            -RemoteAddress $blockedV4Text -Profile 'Any' `
            -Reason 'unsolicited inbound is already blocked by default on Windows; this states it rather than relying on a default the user may have changed.'
    } else {
        $warnings += 'No IPv4 address is outside the permitted scopes, so strict LAN mode would block no IPv4 traffic at all. Check the prefix lengths on this machine''s interfaces: an interface claiming a very short prefix makes the whole Internet look local.'
    }

    if ($blockedV6Text.Count -gt 0) {
        $rules += New-LcStrictLanRule -Slug 'Block-Outbound-IPv6' -Summary 'every non-local IPv6 address, outbound' `
            -Direction 'Outbound' -Action 'Block' -Protocol 'Any' `
            -RemoteAddress $blockedV6Text -Profile 'Any' `
            -Reason 'the same block for IPv6, which a machine will otherwise happily use instead.'
        $rules += New-LcStrictLanRule -Slug 'Block-Inbound-IPv6' -Summary 'every non-local IPv6 address, inbound' `
            -Direction 'Inbound' -Action 'Block' -Protocol 'Any' `
            -RemoteAddress $blockedV6Text -Profile 'Any' `
            -Reason 'the same, for IPv6.'
    } else {
        $warnings += 'No IPv6 address is outside the permitted scopes, so strict LAN mode would block no IPv6 traffic at all.'
    }

    if ($comfyHost -notin @('127.0.0.1', 'localhost', '::1')) {
        $warnings += "ComfyUI is configured at '$comfyHost', not on localhost. Strict LAN mode does not change that: ComfyUI stays reachable from the whole LAN, without authentication. See docs/privacy-security.md."
    }

    $collateral = @(
        'Strict LAN mode is a MACHINE-level control, not a LocalCanvas-level one. While it is on, every application on this PC loses Internet access: the browser, Windows Update, e-mail, the app store, ComfyUI''s own model downloads, and any custom node that tries to reach the Internet. That is what it is for.',
        'It does not inspect or sandbox code. A custom node still runs with whatever access the firewall leaves open, and anything the LAN requires is by definition permitted.',
        'It governs THIS machine only. It says nothing about the phone, the router, or any other device on this network.',
        'It is not a substitute for disconnecting the uplink. Strict mode blocks egress from inside; unplugging removes the path. Both are documented in docs/privacy-security.md and neither is presented as the other.',
        'scripts\strict-lan.ps1 disable removes exactly these rules and gives Internet access back.'
    )

    return [pscustomobject]@{
        PlanVersion  = $script:LcStrictLanPlanVersion
        Group        = $script:LcStrictLanGroup
        FactsSource  = $Facts.Source
        FactsNotes   = @($Facts.Notes)
        GatewayPort  = $gatewayPort
        ComfyHost    = $comfyHost
        ComfyPort    = $comfyPort
        LanSubnets   = @($subnetTexts)
        Permitted    = $permitted
        PermittedV4  = @($permittedV4 | ForEach-Object { Format-LcIpRange -Range $_ })
        PermittedV6  = @($permittedV6 | ForEach-Object { Format-LcIpRange -Range $_ })
        BlockedV4    = @($blockedV4 | ForEach-Object { Format-LcIpRange -Range $_ })
        BlockedV6    = @($blockedV6 | ForEach-Object { Format-LcIpRange -Range $_ })
        Rules        = $rules
        # The exact parameter sets the apply shim splats into
        # New-NetFirewallRule. Carried in the plan so that what would be
        # applied is reviewable, and so that what IS applied is what was
        # reviewed rather than a second translation made at the last moment.
        Apply        = @($rules | ForEach-Object { ConvertTo-LcFirewallRuleParameters -Rule $_ })
        Warnings     = @($warnings)
        Collateral   = $collateral
    }
}

# --------------------------------------------------------------------------
# Rendering -- "never silent" lives here
# --------------------------------------------------------------------------

function ConvertTo-LcFirewallRuleParameters {
    <#
        The plan's own vocabulary translated into New-NetFirewallRule's, and
        nothing else. Pure, and part of the plan itself, so the exact parameter
        set that would be applied can be read -- by a person or by a test --
        without a rule existing. The apply shim splats precisely these.

        Every set carries the LocalCanvas group. That is what makes the rules
        findable and removable afterwards, and it is why it is set here, once,
        rather than at each of thirteen call sites.
    #>
    param([Parameter(Mandatory)]$Rule)
    $parameters = @{
        Name          = $Rule.Name
        DisplayName   = $Rule.DisplayName
        Group         = $Rule.Group
        Direction     = $Rule.Direction
        Action        = $Rule.Action
        Profile       = $Rule.Profile
        Protocol      = $Rule.Protocol
        RemoteAddress = @($Rule.RemoteAddress)
        Description   = $Rule.Reason
        Enabled       = 'True'
    }
    if ($Rule.LocalPort) { $parameters['LocalPort'] = $Rule.LocalPort }
    if ($Rule.RemotePort) { $parameters['RemotePort'] = $Rule.RemotePort }
    if ($Rule.IcmpType) { $parameters['IcmpType'] = $Rule.IcmpType }
    return $parameters
}

function Format-LcStrictLanRule {
    param([Parameter(Mandatory)]$Rule)
    $lines = @("$($Rule.Name)")
    $parts = @($Rule.Direction, $Rule.Action, $Rule.Protocol)
    if ($Rule.LocalPort) { $parts += "local port $($Rule.LocalPort)" }
    if ($Rule.RemotePort) { $parts += "remote port $($Rule.RemotePort)" }
    if ($Rule.IcmpType) { $parts += "ICMP types $($Rule.IcmpType)" }
    $lines += '  ' + ($parts -join '  ')
    $lines += '  remote address: ' + (@($Rule.RemoteAddress) -join ', ')
    $lines += "  profiles: $($Rule.Profile)   group: $($Rule.Group)"
    $lines += "  why: $($Rule.Reason)"
    return $lines
}

function Format-LcStrictLanDisclosure {
    <#
        The disclosure `enable` prints before it applies anything: what is
        permitted and why, and the collateral effect in the same breath. A
        feature whose rule is "never change anything without saying what it
        changed" cannot leave its most visible consequence unsaid.
    #>
    param([Parameter(Mandatory)]$Plan)
    $lines = @('PERMITTED while strict LAN mode is on, and why:')
    foreach ($scope in $Plan.Permitted) {
        $lines += "  - $($scope.Label)"
        $lines += "      $($scope.Reason)"
    }
    $lines += ''
    $lines += 'BLOCKED while strict LAN mode is on:'
    $lines += '  - every other IPv4 address, inbound and outbound, on every profile:'
    foreach ($range in $Plan.BlockedV4) { $lines += "      $range" }
    $lines += '  - every other IPv6 address, inbound and outbound, on every profile:'
    foreach ($range in $Plan.BlockedV6) { $lines += "      $range" }
    $lines += ''
    $lines += 'WHAT ELSE THIS DOES TO THIS PC:'
    foreach ($item in $Plan.Collateral) { $lines += "  - $item" }
    return $lines
}

function Format-LcStrictLanPlan {
    param([Parameter(Mandatory)]$Plan, [switch]$IncludeDisclosure)
    $lines = @()
    if ($IncludeDisclosure) {
        $lines += Format-LcStrictLanDisclosure -Plan $Plan
        $lines += ''
    }
    $lines += "THE RULES THEMSELVES ($($Plan.Rules.Count)), all in group '$($Plan.Group)':"
    foreach ($rule in $Plan.Rules) {
        $lines += ''
        $lines += (Format-LcStrictLanRule -Rule $rule)
    }
    if ($Plan.Warnings.Count -gt 0) {
        $lines += ''
        $lines += 'WARNINGS about this machine''s network:'
        foreach ($warning in $Plan.Warnings) { $lines += "  - $warning" }
    }
    if ($Plan.FactsNotes.Count -gt 0) {
        $lines += ''
        $lines += 'WHAT COULD NOT BE DETERMINED about this machine:'
        foreach ($note in $Plan.FactsNotes) { $lines += "  - $note" }
    }
    return $lines
}

function Format-LcStrictLanState {
    <#
        What `status` prints, rendered from data so it can be exercised
        without a rule ever existing: the state, the rules LocalCanvas owns,
        and what is permitted -- repeated, not assumed remembered.
    #>
    param(
        [Parameter(Mandatory)]$Plan,
        [object[]]$OwnedRules = @(),
        [Parameter(Mandatory)][ValidateSet('on', 'off', 'partial', 'unknown')][string]$State,
        [string]$Detail = ''
    )
    $lines = @()
    switch ($State) {
        'on' { $lines += 'Strict LAN mode: ON' }
        'off' { $lines += 'Strict LAN mode: OFF' }
        'partial' { $lines += 'Strict LAN mode: PARTIAL - some LocalCanvas rules are present and some are missing' }
        'unknown' { $lines += 'Strict LAN mode: UNKNOWN' }
    }
    if ($Detail) { $lines += "  $Detail" }
    $lines += "  Rules LocalCanvas owns in group '$($Plan.Group)': $(@($OwnedRules).Count) of $($Plan.Rules.Count) expected"
    foreach ($rule in @($OwnedRules)) {
        $enabled = if (Get-LcFactField -Object $rule -Name 'Enabled') { [string](Get-LcFactField -Object $rule -Name 'Enabled') } else { 'unknown' }
        $lines += "    $([string](Get-LcFactField -Object $rule -Name 'Name'))  (enabled: $enabled)"
    }
    if (@($OwnedRules).Count -eq 0) {
        $lines += '    (none - LocalCanvas has changed nothing in this machine''s firewall)'
    }
    $lines += ''
    $lines += (Format-LcStrictLanDisclosure -Plan $Plan)
    return $lines
}

function Get-LcStrictLanStateName {
    <#
        Pure: turn the set of rules found into the state reported. "Partial"
        is a real outcome and not an error -- a half-removed overlay must be
        visible, because leaving it unsaid is exactly the "half-applied
        policy" the contract forbids.
    #>
    param([Parameter(Mandatory)]$Plan, [object[]]$OwnedRules = @())
    $found = @($OwnedRules).Count
    $expected = @($Plan.Rules).Count
    if ($found -eq 0) { return 'off' }
    if ($found -ge $expected) { return 'on' }
    return 'partial'
}

# ==========================================================================
# THE MACHINE ADAPTER
# ==========================================================================
#
# Everything below reads or writes the machine. Nothing below decides
# anything: the plan it is handed was computed, printed and reviewed above.

function Test-LcElevated {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Get-LcNetworkFacts {
    <#
        Read-only. Asks Windows what addresses, routes, resolvers and network
        categories this machine has, and returns them as the facts document
        the pure half consumes. Changes no adapter, no route and no firewall.

        Anything it cannot determine becomes a note rather than a guess: the
        plan then says so out loud instead of quietly planning for a network
        that is not there.
    #>
    $notes = @()
    $interfaces = @()
    $gateways = @()
    $resolvers = @()

    $profiles = @{}
    try {
        if (Get-Command Get-NetConnectionProfile -ErrorAction SilentlyContinue) {
            $read = @(Invoke-LcBoundedSystemQuery -What 'a network category query' -Query {
                    Get-NetConnectionProfile -ErrorAction Stop | ForEach-Object {
                        [pscustomobject]@{ InterfaceIndex = [int]$_.InterfaceIndex; NetworkCategory = [string]$_.NetworkCategory }
                    }
                })
            foreach ($item in $read) {
                $profiles[[int]$item.InterfaceIndex] = [string]$item.NetworkCategory
            }
        }
    } catch {
        $notes += 'The network category (Private / Public / Domain) of this machine''s connections could not be read.'
    }

    try {
        if (Get-Command Get-NetIPAddress -ErrorAction SilentlyContinue) {
            $read = @(Invoke-LcBoundedSystemQuery -What 'a network address query' -Query {
                    Get-NetIPAddress -ErrorAction Stop | ForEach-Object {
                        [pscustomobject]@{
                            IPAddress      = [string]$_.IPAddress
                            InterfaceIndex = [int]$_.InterfaceIndex
                            InterfaceAlias = [string]$_.InterfaceAlias
                            PrefixLength   = [int]$_.PrefixLength
                        }
                    }
                })
            foreach ($item in $read) {
                $address = [string]$item.IPAddress
                # Get-NetIPAddress renders a scoped IPv6 address as fe80::1%12.
                if ($address -like '*%*') { $address = $address.Split('%')[0] }
                if (-not $address) { continue }
                $index = [int]$item.InterfaceIndex
                $interfaces += [pscustomobject]@{
                    name          = [string]$item.InterfaceAlias
                    profile       = $(if ($profiles.ContainsKey($index)) { $profiles[$index] } else { '' })
                    address       = $address
                    prefix_length = [int]$item.PrefixLength
                }
            }
        } else {
            $notes += 'Get-NetIPAddress is not available on this system, so no interface address could be read.'
        }
    } catch {
        $notes += "This machine's interface addresses could not be read: $($_.Exception.Message)"
    }

    try {
        if (Get-Command Get-NetRoute -ErrorAction SilentlyContinue) {
            $read = @(Invoke-LcBoundedSystemQuery -What 'a route table query' -Query {
                    foreach ($prefix in @('0.0.0.0/0', '::/0')) {
                        Get-NetRoute -DestinationPrefix $prefix -ErrorAction SilentlyContinue | ForEach-Object {
                            [pscustomobject]@{ NextHop = [string]$_.NextHop }
                        }
                    }
                })
            foreach ($route in $read) {
                $hop = [string]$route.NextHop
                if ($hop -like '*%*') { $hop = $hop.Split('%')[0] }
                if (-not $hop -or $hop -eq '0.0.0.0' -or $hop -eq '::') { continue }
                if ($gateways -notcontains $hop) { $gateways += $hop }
            }
        } else {
            $notes += 'Get-NetRoute is not available on this system, so the default gateway could not be read.'
        }
    } catch {
        $notes += "The default gateway could not be read: $($_.Exception.Message)"
    }

    try {
        if (Get-Command Get-DnsClientServerAddress -ErrorAction SilentlyContinue) {
            $read = @(Invoke-LcBoundedSystemQuery -What 'a DNS resolver query' -Query {
                    Get-DnsClientServerAddress -ErrorAction Stop | ForEach-Object {
                        [pscustomobject]@{ ServerAddresses = @($_.ServerAddresses | ForEach-Object { [string]$_ }) }
                    }
                })
            foreach ($entry in $read) {
                foreach ($address in @($entry.ServerAddresses)) {
                    $value = [string]$address
                    if ($value -like '*%*') { $value = $value.Split('%')[0] }
                    if ($value -and $resolvers -notcontains $value) { $resolvers += $value }
                }
            }
        } else {
            $notes += 'Get-DnsClientServerAddress is not available on this system, so the configured DNS resolvers could not be read.'
        }
    } catch {
        $notes += "The configured DNS resolvers could not be read: $($_.Exception.Message)"
    }

    $raw = [pscustomobject]@{
        interfaces       = $interfaces
        default_gateways = $gateways
        dns_servers      = $resolvers
        notes            = $notes
    }
    return ConvertTo-LcNetworkFacts -Raw $raw -Source 'this machine'
}

function Read-LcNetworkFactsFile {
    <#
        Plan for a network that is not this one. A planning aid only: the
        callers refuse to APPLY a plan computed from a described network,
        because applying a rule set derived from facts nobody checked against
        this machine is exactly how a machine loses its own LAN.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        New-LcFactsFailure "The network facts file '$Path' does not exist."
    }
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    try {
        $raw = $text | ConvertFrom-Json -ErrorAction Stop
    } catch {
        New-LcFactsFailure "The network facts file '$Path' is not valid JSON."
    }
    return ConvertTo-LcNetworkFacts -Raw $raw -Source (Resolve-Path -LiteralPath $Path).Path
}

function Test-LcFirewallModuleAvailable {
    return [bool](Get-Command Get-NetFirewallRule -ErrorAction SilentlyContinue)
}

function Get-LcStrictLanRules {
    <#
        Read-only: the rules LocalCanvas owns, and only those. It asks for one
        group by name and never enumerates, inspects or touches anything else
        in this machine's firewall.
    #>
    if (-not (Test-LcFirewallModuleAvailable)) { return $null }
    try {
        # Bounded (Invoke-LcBoundedSystemQuery), so the exception type is
        # decided where the exception is: in the query.
        $found = @(Invoke-LcBoundedSystemQuery -What 'a firewall query' -Arguments @{ Group = $script:LcStrictLanGroup } -Query {
                try {
                    Get-NetFirewallRule -Group $Group -ErrorAction Stop |
                        ForEach-Object {
                            [pscustomobject]@{
                                Name        = [string]$_.Name
                                DisplayName = [string]$_.DisplayName
                                Direction   = [string]$_.Direction
                                Action      = [string]$_.Action
                                Enabled     = [string]$_.Enabled
                            }
                        }
                } catch {
                    # Unreadable is NOT the same answer as "there are none", and
                    # the difference is the whole of `status` being honest: $null
                    # means the firewall could not be read, an empty array means
                    # it holds nothing of ours. Asking for a group that does not
                    # exist is the SECOND of those and Windows reports it as an
                    # error, so it is separated here by exception type rather
                    # than by matching a localized message.
                    if ($_.Exception.GetType().FullName -like '*CimJobException') { return }
                    throw
                }
            })
    } catch {
        # The firewall could not be read, or did not answer in time.
        return $null
    }
    return , $found
}

function Invoke-LcStrictLanApply {
    <#
        The apply shim. Deliberately the shortest function in this file: it
        creates the rules the plan already printed, in order, and stops at the
        first failure so that a partial application is reported as one rather
        than left to be discovered.

        It applies the plan's OWN parameter sets -- the ones `-Plan -Json`
        shows -- so what is applied is what was reviewed, not a second
        translation made at the last moment.

        It never edits or removes a rule it did not create, and it never
        changes a profile's default action -- the prior policy is not
        rewritten, it is overlaid.
    #>
    param([Parameter(Mandatory)]$Plan)
    $created = @()
    foreach ($parameters in $Plan.Apply) {
        try {
            New-NetFirewallRule @parameters -ErrorAction Stop | Out-Null
        } catch {
            return [pscustomobject]@{
                Ok      = $false
                Created = $created
                Failed  = $parameters['Name']
                Error   = $_.Exception.Message
            }
        }
        $created += $parameters['Name']
    }
    return [pscustomobject]@{ Ok = $true; Created = $created; Failed = ''; Error = '' }
}

function Test-LcStrictLanRemovableName {
    <#
        Is this string a rule LocalCanvas itself created? Returns the reason
        it is NOT removable, or '' when it is -- so the caller has something
        to print rather than a bare $false.

        Two independent refusals, because they fail in different ways and
        neither catches the other:

          * a name that does not carry LocalCanvas's own rule prefix names
            somebody else's rule. This feature overlays the user's firewall
            policy and never rewrites it, so a name outside the prefix is not
            ours to remove;

          * a name containing a wildcard character is not a name at all.
            Remove-NetFirewallRule MATCHES on -Name, so a single '*' asks
            Windows to delete every firewall rule on the machine -- and the
            prefix check alone would wave through 'LocalCanvas-StrictLAN-*',
            which carries the prefix and still matches far more than the
            caller named. '[' is included because it opens a character class,
            which is a wildcard even without a '*' after it.

        The check is deliberately about the STRING, not about what the
        firewall currently holds: a name that is not ours is refused whether
        or not a rule by that name exists, so the answer cannot change between
        the check and the removal.
    #>
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return 'the name is empty'
    }
    foreach ($character in @('*', '?', '[')) {
        if ($Name.Contains($character)) {
            return ("the name contains the wildcard character '$character', and " +
                'Remove-NetFirewallRule matches on -Name rather than comparing it')
        }
    }
    if (-not $Name.StartsWith($script:LcStrictLanRulePrefix, [System.StringComparison]::Ordinal)) {
        return ("the name does not start with '$($script:LcStrictLanRulePrefix)', " +
            'so it is not a rule LocalCanvas created')
    }
    return ''
}

function Invoke-LcStrictLanRemove {
    <#
        Removal by name, one rule at a time, and ONLY names LocalCanvas itself
        created.

        The check lives HERE, in the removal, and not in the one caller that
        happens to exist today. A name reaches this function from a -FactsFile
        description exactly as easily as from this machine's own group, and a
        guard placed in a caller is a guard the next caller does not have --
        which is precisely how `disable -FactsFile` came to hand arbitrary
        strings, wildcards included, to Remove-NetFirewallRule.

        A name that fails the check is skipped and RETURNED as a refusal, not
        silently dropped: "nothing happened" and "we refused to do it" are
        different answers, and the caller has to be able to print the second
        one. The rest of the list still runs, so one bad entry does not leave
        a half-removed overlay behind.
    #>
    param([string[]]$Names = @())
    $removed = @()
    $skipped = @()
    foreach ($name in $Names) {
        $reason = Test-LcStrictLanRemovableName -Name $name
        if ($reason) {
            $skipped += [pscustomobject]@{ Name = $name; Reason = $reason }
            continue
        }
        try {
            Remove-NetFirewallRule -Name $name -ErrorAction Stop
        } catch {
            return [pscustomobject]@{
                Ok      = $false
                Removed = $removed
                Skipped = $skipped
                Failed  = $name
                Error   = $_.Exception.Message
            }
        }
        $removed += $name
    }
    return [pscustomobject]@{
        Ok      = $true
        Removed = $removed
        Skipped = $skipped
        Failed  = ''
        Error   = ''
    }
}

