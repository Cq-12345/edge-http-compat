#requires -Version 5.1
<#
.SYNOPSIS
Diagnose and configure Microsoft Edge automatic HTTPS upgrades on Windows.
.DESCRIPTION
Defaults to read-only Status and Stable Edge. Policy changes are shared across
Edge channels in the chosen scope. See README.md before applying changes.
.EXAMPLE
.\EdgeHttpCompat.ps1
.EXAMPLE
.\EdgeHttpCompat.ps1 -Action DisableUpgrade -WhatIf
.EXAMPLE
.\EdgeHttpCompat.ps1 -Action DisableUpgrade -Elevate
.EXAMPLE
.\EdgeHttpCompat.ps1 -Action AllowHttp -Hostname 'legacy.example.org' -Elevate
.EXAMPLE
.\EdgeHttpCompat.ps1 -Action DisableUpgrade -Channel Beta -Elevate
.EXAMPLE
.\EdgeHttpCompat.ps1 -Action Restore -BackupFile 'C:\backups\edge-http.json' -Elevate
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Status', 'DisableUpgrade', 'AllowHttp', 'Restore')][string]$Action = 'Status',
    [ValidateSet('Stable', 'Beta', 'Dev', 'Canary')][string]$Channel = 'Stable',
    [ValidateSet('CurrentUser', 'LocalMachine')][string]$Scope = 'CurrentUser',
    [string[]]$Hostname,
    [string]$EdgePath,
    [string]$BackupDirectory,
    [string]$BackupFile,
    [switch]$Elevate,
    [switch]$Json,
    [string]$TargetUserSid
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'This script supports Windows only.' }
    Import-Module (Join-Path $PSScriptRoot 'src\EdgeHttpCompat.psm1') -Force
    if (-not $TargetUserSid) { $TargetUserSid = Get-EhcCurrentSid }
    if (-not $BackupDirectory) { $BackupDirectory = Join-Path $env:LOCALAPPDATA 'EdgeHttpCompat\Backups' }
    $BackupDirectory = [IO.Path]::GetFullPath($BackupDirectory)
    if ($BackupFile) { $BackupFile = (Get-Item -LiteralPath $BackupFile).FullName }
    if ($EdgePath) { $EdgePath = [IO.Path]::GetFullPath($EdgePath) }
    if ($Hostname -and $Action -ne 'AllowHttp') { throw '-Hostname is only valid with -Action AllowHttp.' }
    if ($Action -eq 'Restore' -and -not $BackupFile) { throw 'Restore requires -BackupFile.' }
    if ($BackupFile -and $Action -ne 'Restore') { throw '-BackupFile is only valid with -Action Restore.' }

    $context = New-EhcContext $Scope $TargetUserSid
    $installation = $null
    if ($Action -ne 'Restore') { $installation = Get-EhcEdgeInstallation $Channel $EdgePath }
    if ($Action -eq 'Status') {
        $status = Get-EhcStatus $installation $TargetUserSid
        if ($Json) { $status | ConvertTo-Json -Depth 12 }
        else {
            Write-Host ('Edge HTTP compatibility helper 0.1.0 | Channel: {0}' -f $Channel)
            if ($installation.Found) { Write-Host "Detected: $($installation.Version) at $($installation.Path)" }
            else { Write-Host 'Selected Edge channel was not found.' }
            Write-Host 'Local policy values (Exists=false means unconfigured):'
            $status.CurrentUser, $status.LocalMachine | ConvertTo-Json -Depth 10
            Write-Host $status.Note
        }
        exit 0
    }

    $plan = @()
    if ($Action -eq 'Restore') {
        $null = Read-EhcBackup $BackupFile $context
    } else {
        Assert-EhcSupportedVersion $installation $Action
        $plan = @(New-EhcPlan $context $Action $Hostname)
        if (-not $plan.Count) {
            $unchanged = [pscustomobject]@{ Changed = 0; BackupFile = $null; Message = 'Already configured; no changes and no elevation required.' }
            if ($Json) { $unchanged | ConvertTo-Json } else { $unchanged | Format-List }
            exit 0
        }
    }

    # Build the full plan before elevation. Never turn -WhatIf into a real write.
    if ($Elevate -and -not (Test-EhcAdministrator) -and -not $WhatIfPreference) {
        if (-not $PSCmdlet.ShouldProcess("$Scope Edge policy (all channels)", "$Action with Windows administrator consent")) { exit 0 }
        $forward = @{
            Action = $Action; Channel = $Channel; Scope = $Scope
            TargetUserSid = $TargetUserSid; BackupDirectory = $BackupDirectory
        }
        if ($Hostname) { $forward.Hostname = @($Hostname) }
        if ($EdgePath) { $forward.EdgePath = $EdgePath }
        if ($BackupFile) { $forward.BackupFile = $BackupFile }
        if ($Json) { $forward.Json = $true }
        [IO.Directory]::CreateDirectory($BackupDirectory) | Out-Null
        $elevationLog = Join-Path $BackupDirectory ('elevation-{0}.log' -f [guid]::NewGuid().ToString('N'))
        $encoded = New-EhcElevationCommand -ScriptFile $PSCommandPath -Parameters $forward -LogFile $elevationLog
        $engine = Join-Path $PSHOME 'powershell.exe'
        if ($PSVersionTable.PSEdition -eq 'Core') { $engine = Join-Path $PSHOME 'pwsh.exe' }
        Write-Host 'Windows will request administrator consent. The original user SID and backup folder are preserved.'
        $engineArguments = @('-NoProfile')
        $processPolicy = Get-ExecutionPolicy -Scope Process
        if ($processPolicy -ne 'Undefined') { $engineArguments += @('-ExecutionPolicy', [string]$processPolicy) }
        $engineArguments += @('-EncodedCommand', $encoded)
        $process = Start-Process -FilePath $engine -ArgumentList $engineArguments -Verb RunAs -WindowStyle Hidden -Wait -PassThru
        if (Test-Path -LiteralPath $elevationLog) { Write-Output (Get-Content -LiteralPath $elevationLog -Raw) }
        if ($process.ExitCode -ne 0) { throw "Elevated operation exited with code $($process.ExitCode). Details: $elevationLog" }
        Write-Output 'Elevated operation completed. Run Status, then check edge://policy in the browser.'
        exit 0
    }

    if ($Scope -eq 'CurrentUser') {
        $machine = Get-EhcPolicySnapshot (New-EhcContext LocalMachine $TargetUserSid)
        if ($machine.HttpsUpgradesEnabled.Exists -or $machine.HttpsOnlyMode.Exists -or $machine.HttpAllowlist.Count) {
            Write-Warning 'Machine-level Edge policies exist. They may take precedence; verify edge://policy or contact your administrator.'
        }
    }
    if ($Action -eq 'Restore') {
        if (-not $PSCmdlet.ShouldProcess("$Scope Edge policy (all channels)", 'Restore saved values')) { exit 0 }
        $result = Invoke-EhcRestore -Context $context -BackupFile $BackupFile -Confirm:$false
    } else {
        if (-not $PSCmdlet.ShouldProcess("$Scope Edge policy (all channels)", "$Action ($($plan.Count) value(s))")) { exit 0 }
        $result = Invoke-EhcApply -Context $context -Plan $plan -BackupDirectory $BackupDirectory -Action $Action -Confirm:$false
    }
    if ($null -ne $result) {
        if ($Json) { $result | ConvertTo-Json -Depth 8 } else { $result | Format-List }
    }
    exit 0
} catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}
