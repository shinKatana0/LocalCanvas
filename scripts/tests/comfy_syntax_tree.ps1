<#
    The syntax-tree half of the bootstrap layer's choke-point lint (T-0197).

    Parses each file it is given with PowerShell's own parser and prints, as
    one line of JSON, the constructs a regular expression over the text cannot
    judge:

      call-target     a command whose command element is not a literal name:
                      `& $var`, `& (expr)`, `. $var`, `& { }`
      computed-member a member whose name is not a literal, and whether it is
                      invoked, assigned or read (T-0255):
                      `$x.$m()`, `[T]::$m()`, `$x.($m)()`, `$x."$m"()`,
                      `$x.$m = 1`, `$x.$m++`, `$v = $x.$m`
      quoted-member   a member whose name is a string constant written in
                      quotes, with that constant, and whether it is invoked,
                      assigned or read (T-0255): `[T]::'Name'()`, `$x."Name"()`,
                      `$x.'Name' = 1`. A bare name is the regex pass's to read;
                      a quoted one is invisible to it, because it blanks
                      string literals.
      static-target   `::` applied to something that is not a type literal:
                      `$t::CreateDirectory()`, `([type]'T')::X`

    It judges nothing. It has no allow-list and never will: what is allowed is
    decided in scripts/tests/run_tests.py against the allow-lists that already
    live there, so there is exactly one copy of that vocabulary.

    It reads the files and writes nothing. The JSON is ASCII (every other
    character is a \u escape), so what Python reads does not depend on either
    shell's console encoding, and nothing here has to change one.

    Runs under PowerShell 7 and Windows PowerShell 5.1, and the suite exercises
    both. It needs 5.0 at least: `[System.Text.StringBuilder]::new()` below is
    the `::new()` syntax 5.0 introduced. `host` in the output says which one
    ran it.
#>
param(
    [Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LcTreeEnclosingFunction {
    param([Parameter(Mandatory)]$Ast)
    $parent = $Ast.Parent
    while ($null -ne $parent) {
        if ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            return $parent.Name
        }
        $parent = $parent.Parent
    }
    return ''
}

function Get-LcTreeMemberRole {
    <#
        'invoke', 'assign' or 'read' for a member expression.

        'assign' is the member being the thing an assignment or an increment
        writes: the left side of `=`, `+=` and the rest, reached through a
        cast (`[int]$x.$m = 1`), a list (`$a, $x.$m = 1, 2`) or parentheses
        (`($x.$m) = 1`), or the operand of `++`/`--`. Everything else is a
        read. `[ref]$x.$m` is a read: measured under both shells, a write to
        that reference does not reach the member.
    #>
    param([Parameter(Mandatory)]$Member)
    if ($Member -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
        return 'invoke'
    }
    $child = $Member
    $parent = $Member.Parent
    while ($parent -is [System.Management.Automation.Language.AttributedExpressionAst] -or
            $parent -is [System.Management.Automation.Language.ArrayLiteralAst] -or
            $parent -is [System.Management.Automation.Language.ParenExpressionAst] -or
            $parent -is [System.Management.Automation.Language.PipelineAst] -or
            $parent -is [System.Management.Automation.Language.CommandExpressionAst]) {
        $child = $parent
        $parent = $parent.Parent
    }
    if ($parent -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            [object]::ReferenceEquals($parent.Left, $child)) {
        return 'assign'
    }
    if ($parent -is [System.Management.Automation.Language.UnaryExpressionAst] -and
            @('PlusPlus', 'MinusMinus', 'PostfixPlusPlus', 'PostfixMinusMinus') -contains
                [string]$parent.TokenKind) {
        return 'assign'
    }
    return 'read'
}

function New-LcTreeFinding {
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)]$Ast,
        [Parameter(Mandatory)]$Subject,
        [string]$Operator = '',
        [string]$Role = '',
        [string]$Name = '',
        [string]$Target = ''
    )
    $variable = ''
    if ($Subject -is [System.Management.Automation.Language.VariableExpressionAst]) {
        $variable = '$' + $Subject.VariablePath.UserPath
    }
    return [ordered]@{
        kind     = $Kind
        line     = $Ast.Extent.StartLineNumber
        function = (Get-LcTreeEnclosingFunction -Ast $Ast)
        operator = $Operator
        node     = $Subject.GetType().Name
        variable = $variable
        text     = $Subject.Extent.Text
        role     = $Role
        name     = $Name
        target   = $Target
    }
}

$files = @(foreach ($file in $Path) {
    $resolved = (Resolve-Path -LiteralPath $file).ProviderPath
    $tokens = $null
    $errors = $null
    $tree = [System.Management.Automation.Language.Parser]::ParseFile(
        $resolved, [ref]$tokens, [ref]$errors)

    $findings = @()
    foreach ($command in $tree.FindAll(
            { param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $first = $command.CommandElements[0]
        if ($first -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            continue
        }
        $findings += New-LcTreeFinding -Kind 'call-target' -Ast $command -Subject $first `
            -Operator $command.InvocationOperator.ToString()
    }
    foreach ($member in $tree.FindAll(
            { param($node) $node -is [System.Management.Automation.Language.MemberExpressionAst] }, $true)) {
        $onType = $member.Expression -is [System.Management.Automation.Language.TypeExpressionAst]
        $how = $(if ($member.Static) { '::' } else { '.' })
        if ($member.Member -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
            $findings += New-LcTreeFinding -Kind 'computed-member' -Ast $member -Subject $member.Member `
                -Operator $how -Role (Get-LcTreeMemberRole -Member $member) `
                -Target $member.Expression.Extent.Text
        } elseif ($member.Member.StringConstantType -ne 'BareWord' -and
                ($onType -or -not $member.Static)) {
            # `$t::'Name'` is already a static-target finding below, exactly as
            # `$t::Name` is, so it is not reported twice.
            $findings += New-LcTreeFinding -Kind 'quoted-member' -Ast $member -Subject $member.Member `
                -Operator $how -Role (Get-LcTreeMemberRole -Member $member) `
                -Name $member.Member.Value -Target $member.Expression.Extent.Text
        }
        if ($member.Static -and -not $onType) {
            $findings += New-LcTreeFinding -Kind 'static-target' -Ast $member -Subject $member.Expression
        }
    }

    [ordered]@{
        path     = $resolved
        errors   = @(foreach ($problem in $errors) {
            [ordered]@{ line = $problem.Extent.StartLineNumber; message = $problem.Message }
        })
        findings = $findings
    }
})

$report = [ordered]@{
    host  = [ordered]@{
        edition = $(if ($PSVersionTable.ContainsKey('PSEdition')) { $PSVersionTable.PSEdition } else { 'Desktop' })
        version = $PSVersionTable.PSVersion.ToString()
    }
    files = $files
}

$json = ConvertTo-Json -InputObject $report -Depth 8 -Compress
$ascii = [System.Text.StringBuilder]::new()
foreach ($character in $json.ToCharArray()) {
    if ([int]$character -gt 126) {
        [void]$ascii.Append(('\u{0:x4}' -f [int]$character))
    } else {
        [void]$ascii.Append($character)
    }
}
Write-Output $ascii.ToString()
