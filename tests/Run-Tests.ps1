#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$module = Import-Module (Join-Path $projectRoot 'src\EdgeHttpCompat.psm1') -Force -PassThru
$runId = [guid]::NewGuid().ToString('N')
$testRoot = Join-Path $projectRoot '.test-artifacts'
$runDirectory = Join-Path $testRoot $runId
$context = [pscustomobject]@{
    Scope = 'CurrentUser'; UserSid = Get-EhcCurrentSid
    Hive = 'CurrentUser'; SubKey = "Software\EdgeHttpCompat.Tests\$runId"
}
$script:passed = 0

function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Assert-Equal { param($Actual, $Expected, [string]$Message) if ($Actual -cne $Expected) { throw "$Message (expected '$Expected', got '$Actual')" } }
function Assert-Throws {
    param([scriptblock]$Body, [string]$Pattern)
    $caught = $null
    try { & $Body | Out-Null } catch { $caught = $_.Exception.Message }
    Assert-True ($null -ne $caught) 'Expected an exception.'
    if ($Pattern) { Assert-True ($caught -match $Pattern) "Unexpected error: $caught" }
}
function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    & $Body
    $script:passed++
    Write-Output "PASS $Name"
}
function New-State { param([string]$Kind, $Value) [pscustomobject]@{ Exists = $true; Kind = $Kind; Value = $Value } }
function Reset-Sandbox {
    $base = Open-EhcBaseKey $context
    try {
        if ($context.SubKey -notmatch '^Software\\EdgeHttpCompat\.Tests\\[a-f0-9]{32}$') { throw 'Unsafe test key.' }
        $base.DeleteSubKeyTree($context.SubKey, $false)
    } finally { $base.Dispose() }
}

try {
    Test-Case 'Hostnames: lowercase, wildcard, trailing dot, IDN' {
        Assert-Equal (ConvertTo-EhcHostname 'LEGACY.Example.Org.') 'legacy.example.org' 'Canonical host'
        Assert-Equal (ConvertTo-EhcHostname '[*.]EXAMPLE.org') '[*.]example.org' 'Wildcard'
        $unicodeHost = ([string][char]0x4f8b) + [char]0x5b50 + '.com'
        Assert-Equal (ConvertTo-EhcHostname $unicodeHost) 'xn--fsqu00a.com' 'IDN A-label'
    }
    Test-Case 'Reject URLs, ports, paths, credentials, wildcard-all and malformed labels' {
        foreach ($bad in @('http://example.org', 'example.org:8080', 'example.org/a', '*', '[*]', '[*.]*', 'user@example.org', 'a..org', '-a.org', 'a-.org', 'a b.org')) {
            Assert-Throws { ConvertTo-EhcHostname $bad }
        }
    }
    Test-Case 'Policy version gates: 136 and 123; absent channels fail' {
        $edge = [pscustomobject]@{ Found = $true; Major = 135; Version = '135.0.0.0'; Channel = 'Stable' }
        Assert-Throws { Assert-EhcSupportedVersion $edge DisableUpgrade } '136'
        $edge.Major = 136
        Assert-EhcSupportedVersion $edge DisableUpgrade
        $edge.Major = 122
        Assert-Throws { Assert-EhcSupportedVersion $edge AllowHttp } '123'
        $edge.Major = 123
        Assert-EhcSupportedVersion $edge AllowHttp
        $edge.Found = $false
        Assert-Throws { Assert-EhcSupportedVersion $edge AllowHttp } 'not found'
    }
    Test-Case 'Apply, read-back, backup before mutation, no-op repeat, exact absent restore' {
        Reset-Sandbox
        $plan = @(New-EhcPlan $context DisableUpgrade)
        Assert-Equal $plan.Count 1 'Initial plan'
        $result = Invoke-EhcApply $context $plan $runDirectory DisableUpgrade -Confirm:$false
        Assert-True (Test-Path -LiteralPath $result.BackupFile) 'Missing backup'
        Assert-Equal (Get-EhcValueState $context '' HttpsUpgradesEnabled).Value 0 'Disabled'
        Assert-Equal @(New-EhcPlan $context DisableUpgrade).Count 0 'Idempotency'
        $restored = Invoke-EhcRestore $context $result.BackupFile -Confirm:$false
        Assert-Equal $restored.Restored 1 'Restore count'
        Assert-True (-not (Get-EhcValueState $context '' HttpsUpgradesEnabled).Exists) 'Original absence'
        Assert-Equal (Invoke-EhcRestore $context $result.BackupFile -Confirm:$false).Restored 0 'Repeated restore'
    }
    Test-Case 'Restore original value and type; preserve unrelated policy' {
        Reset-Sandbox
        Set-EhcValueState $context '' HttpsUpgradesEnabled (New-State String 'previous-nonstandard-value')
        Set-EhcValueState $context '' UnrelatedPolicy (New-State DWord 42)
        $result = Invoke-EhcApply $context @(New-EhcPlan $context DisableUpgrade) $runDirectory DisableUpgrade -Confirm:$false
        $null = Invoke-EhcRestore $context $result.BackupFile -Confirm:$false
        $state = Get-EhcValueState $context '' HttpsUpgradesEnabled
        Assert-Equal $state.Kind 'String' 'Original type'
        Assert-Equal $state.Value 'previous-nonstandard-value' 'Original value'
        Assert-Equal (Get-EhcValueState $context '' UnrelatedPolicy).Value 42 'Unrelated value'
    }
    Test-Case 'Unrestorable original type is rejected before mutation' {
        Reset-Sandbox
        $base = Open-EhcBaseKey $context
        $key = $base.CreateSubKey($context.SubKey)
        try { $key.SetValue('HttpsUpgradesEnabled', [byte[]]@(1, 2), [Microsoft.Win32.RegistryValueKind]::None) }
        finally { $key.Dispose(); $base.Dispose() }
        Assert-Throws { Invoke-EhcApply $context @(New-EhcPlan $context DisableUpgrade) $runDirectory DisableUpgrade -Confirm:$false } 'registry type'
        Assert-Equal (Get-EhcValueState $context '' HttpsUpgradesEnabled).Kind 'None' 'Original type untouched'
    }
    Test-Case 'Append allowlist without collisions; de-duplicate; preserve later entries' {
        Reset-Sandbox
        Set-EhcValueState $context HttpAllowlist '1' (New-State String 'existing.example.org')
        Set-EhcValueState $context HttpAllowlist '3' (New-State String 'another.example.org')
        $plan = @(New-EhcPlan $context AllowHttp @('NEW.example.org', 'new.example.org', '[*.]legacy.example.org'))
        Assert-Equal $plan.Count 2 'Unique hosts'
        Assert-Equal $plan[0].Name '2' 'Free slot'
        Assert-Equal $plan[1].Name '4' 'Next free slot'
        $result = Invoke-EhcApply $context $plan $runDirectory AllowHttp -Confirm:$false
        Assert-Equal @(New-EhcPlan $context AllowHttp @('new.example.org')).Count 0 'Existing host no-op'
        Set-EhcValueState $context HttpAllowlist '5' (New-State String 'later.example.org')
        $null = Invoke-EhcRestore $context $result.BackupFile -Confirm:$false
        Assert-Equal (Get-EhcValueState $context HttpAllowlist '1').Value 'existing.example.org' 'Existing host preserved'
        Assert-Equal (Get-EhcValueState $context HttpAllowlist '5').Value 'later.example.org' 'Later host preserved'
        Assert-True (-not (Get-EhcValueState $context HttpAllowlist '2').Exists) 'Own host removed'
    }
    Test-Case 'Restore conflict preflight prevents partial restoration' {
        Reset-Sandbox
        $plan = @(New-EhcPlan $context AllowHttp @('one.example.org', 'two.example.org'))
        $result = Invoke-EhcApply $context $plan $runDirectory AllowHttp -Confirm:$false
        Set-EhcValueState $context HttpAllowlist '2' (New-State String 'changed.example.org')
        Assert-Throws { Invoke-EhcRestore $context $result.BackupFile -Confirm:$false } 'conflict'
        Assert-Equal (Get-EhcValueState $context HttpAllowlist '1').Value 'one.example.org' 'First entry untouched'
        Assert-Equal (Get-EhcValueState $context HttpAllowlist '2').Value 'changed.example.org' 'Third-party change untouched'
    }
    Test-Case 'Reject backup path injection, wrong scope, unexpected values and duplicate targets' {
        Reset-Sandbox
        $result = Invoke-EhcApply $context @(New-EhcPlan $context DisableUpgrade) $runDirectory DisableUpgrade -Confirm:$false
        $original = Get-Content -LiteralPath $result.BackupFile -Raw | ConvertFrom-Json
        $badFile = Join-Path $runDirectory 'invalid.json'
        foreach ($case in @('path', 'scope', 'value', 'duplicate', 'type')) {
            $bad = $original | ConvertTo-Json -Depth 12 | ConvertFrom-Json
            switch ($case) {
                'path' { $bad.Changes[0].RelativeKey = '..\OtherPolicy' }
                'scope' { $bad.Scope = 'LocalMachine' }
                'value' { $bad.Changes[0].After.Value = 1 }
                'duplicate' { $bad.Changes = @($bad.Changes[0], $bad.Changes[0]) }
                'type' { $bad.Changes[0].Before = [pscustomobject]@{Exists=$true;Kind='DWord';Value='not-a-number'} }
            }
            $bad | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $badFile -Encoding UTF8
            Assert-Throws { Invoke-EhcRestore $context $badFile -Confirm:$false }
            Assert-Equal (Get-EhcValueState $context '' HttpsUpgradesEnabled).Value 0 'No writes from bad backup'
        }
    }
    Test-Case 'WhatIf creates neither registry values nor backups; restore WhatIf preserves state' {
        Reset-Sandbox
        $dryRunDir = Join-Path $runDirectory 'dry-run'
        $null = Invoke-EhcApply $context @(New-EhcPlan $context DisableUpgrade) $dryRunDir DisableUpgrade -WhatIf
        Assert-True (-not (Test-Path -LiteralPath $dryRunDir)) 'WhatIf wrote a backup'
        Assert-True (-not (Get-EhcValueState $context '' HttpsUpgradesEnabled).Exists) 'WhatIf wrote a policy'
        $result = Invoke-EhcApply $context @(New-EhcPlan $context DisableUpgrade) $runDirectory DisableUpgrade -Confirm:$false
        $null = Invoke-EhcRestore $context $result.BackupFile -WhatIf
        Assert-Equal (Get-EhcValueState $context '' HttpsUpgradesEnabled).Value 0 'Restore WhatIf changed policy'
    }
    Test-Case 'Mid-apply failure rolls back completed writes and keeps backup' {
        Reset-Sandbox
        $plan = @(New-EhcPlan $context AllowHttp @('one.example.org', 'two.example.org'))
        & $module {
            $script:originalWriter = (Get-Item Function:\Set-EhcValueState).ScriptBlock
            function script:Set-EhcValueState {
                param($Context, [string]$RelativeKey = '', [string]$Name, $State)
                if ($Name -eq '2' -and $State.Exists) { throw 'Injected write failure' }
                & $script:originalWriter $Context $RelativeKey $Name $State
            }
        }
        try {
            Assert-Throws { Invoke-EhcApply $context $plan $runDirectory AllowHttp -Confirm:$false } 'Injected write failure'
        } finally { & $module { Set-Item Function:\Set-EhcValueState $script:originalWriter } }
        Assert-True (-not (Get-EhcValueState $context HttpAllowlist '1').Exists) 'First write was not rolled back'
        Assert-True (-not (Get-EhcValueState $context HttpAllowlist '2').Exists) 'Second write unexpectedly succeeded'
    }
    Test-Case 'Elevation serialization preserves arrays, SID and paths with quotes and spaces' {
        $fixture = Join-Path $runDirectory "quoted ' script.ps1"
        $log = Join-Path $runDirectory "quoted ' log.txt"
        @'
param([string[]]$Hostname, [string]$TargetUserSid, [string]$BackupDirectory)
@{ Hostname = $Hostname; TargetUserSid = $TargetUserSid; BackupDirectory = $BackupDirectory } | ConvertTo-Json -Compress
exit 0
'@ | Set-Content -LiteralPath $fixture -Encoding UTF8
        $parameters = @{ Hostname = @('a.example.org', '[*.]b.example.org'); TargetUserSid = 'S-1-5-21-1-2-3-1001'; BackupDirectory = "C:\space & quote ' directory" }
        $encoded = New-EhcElevationCommand $fixture $parameters $log
        $engine = Join-Path $PSHOME 'powershell.exe'
        if ($PSVersionTable.PSEdition -eq 'Core') { $engine = Join-Path $PSHOME 'pwsh.exe' }
        & $engine -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded
        Assert-Equal $LASTEXITCODE 0 'Encoded child execution'
        $actual = Get-Content -LiteralPath $log -Raw | ConvertFrom-Json
        Assert-Equal $actual.BackupDirectory $parameters.BackupDirectory 'Path round trip'
        Assert-Equal $actual.TargetUserSid $parameters.TargetUserSid 'Original user preserved'
        Assert-Equal $actual.Hostname.Count 2 'Array round trip'
        Assert-Equal $actual.Hostname[1] '[*.]b.example.org' 'Wildcard round trip'
    }
    Test-Case 'Public entry point defaults to read-only Stable status' {
        $engine = Join-Path $PSHOME 'powershell.exe'
        if ($PSVersionTable.PSEdition -eq 'Core') { $engine = Join-Path $PSHOME 'pwsh.exe' }
        $output = & $engine -NoProfile -ExecutionPolicy Bypass -File (Join-Path $projectRoot 'EdgeHttpCompat.ps1') -Json
        Assert-Equal $LASTEXITCODE 0 'Status exit code'
        $status = $output | Out-String | ConvertFrom-Json
        Assert-Equal $status.Edge.Channel 'Stable' 'Default channel'
        Assert-Equal $status.Tool 'edge-http-compat' 'Status schema'
    }
    Write-Output "All $script:passed tests passed on PowerShell $($PSVersionTable.PSVersion)."
} finally {
    Reset-Sandbox
    if (Test-Path -LiteralPath $runDirectory) {
        $resolved = [IO.Path]::GetFullPath($runDirectory)
        $allowed = [IO.Path]::GetFullPath($testRoot).TrimEnd('\') + '\'
        if (-not $resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test directory cleanup.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
