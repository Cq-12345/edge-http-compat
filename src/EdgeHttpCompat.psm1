#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-EhcCurrentSid {
    [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Test-EhcAdministrator {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function New-EhcElevationCommand {
    param([string]$ScriptFile, [hashtable]$Parameters, [string]$LogFile)
    # Serialize data instead of interpolating hostnames, paths, or SIDs as code.
    $request = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $Parameters -Compress)))
    $quotedScript = $ScriptFile.Replace("'", "''")
    $quotedLog = $LogFile.Replace("'", "''")
    $code = @"
`$ErrorActionPreference = 'Stop'
`$payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$request')) | ConvertFrom-Json
`$invoke = @{}
foreach (`$property in `$payload.PSObject.Properties) { `$invoke[`$property.Name] = `$property.Value }
& '$quotedScript' @invoke *> '$quotedLog'
exit `$LASTEXITCODE
"@
    [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
}

function New-EhcContext {
    param(
        [ValidateSet('CurrentUser', 'LocalMachine')][string]$Scope = 'CurrentUser',
        [string]$TargetUserSid = (Get-EhcCurrentSid)
    )
    if ($TargetUserSid -notmatch '^S-1-\d+(?:-\d+)+$') { throw 'Invalid Windows user SID.' }
    if ($Scope -eq 'CurrentUser') {
        return [pscustomobject]@{
            Scope = $Scope; UserSid = $TargetUserSid; Hive = 'Users'
            SubKey = "$TargetUserSid\Software\Policies\Microsoft\Edge"
        }
    }
    [pscustomobject]@{
        Scope = $Scope; UserSid = ''; Hive = 'LocalMachine'
        SubKey = 'Software\Policies\Microsoft\Edge'
    }
}

function Open-EhcBaseKey {
    param($Context)
    # Policy keys must use the native registry view, including from 32-bit PowerShell.
    $view = [Microsoft.Win32.RegistryView]::Registry32
    if ([Environment]::Is64BitOperatingSystem) { $view = [Microsoft.Win32.RegistryView]::Registry64 }
    [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]$Context.Hive, $view)
}

function Get-EhcKeyPath {
    param($Context, [string]$RelativeKey = '')
    if ($RelativeKey) { return "$($Context.SubKey)\$RelativeKey" }
    $Context.SubKey
}

function Get-EhcValueState {
    param($Context, [string]$RelativeKey = '', [Parameter(Mandatory)][string]$Name)
    $base = Open-EhcBaseKey $Context
    $key = $null
    try {
        $key = $base.OpenSubKey((Get-EhcKeyPath $Context $RelativeKey), $false)
        if ($null -eq $key -or $key.GetValueNames() -notcontains $Name) {
            return [pscustomobject]@{ Exists = $false; Kind = $null; Value = $null }
        }
        [pscustomobject]@{
            Exists = $true
            Kind = $key.GetValueKind($Name).ToString()
            Value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        }
    } finally {
        if ($null -ne $key) { $key.Dispose() }
        $base.Dispose()
    }
}

function Get-EhcValueNames {
    param($Context, [string]$RelativeKey = '')
    $base = Open-EhcBaseKey $Context
    $key = $null
    try {
        $key = $base.OpenSubKey((Get-EhcKeyPath $Context $RelativeKey), $false)
        if ($null -ne $key) { $key.GetValueNames() }
    } finally {
        if ($null -ne $key) { $key.Dispose() }
        $base.Dispose()
    }
}

function Test-EhcStateEqual {
    param($Left, $Right)
    if ([bool]$Left.Exists -ne [bool]$Right.Exists) { return $false }
    if (-not $Left.Exists) { return $true }
    if ($Left.Kind -cne $Right.Kind) { return $false }
    $a = ConvertTo-Json -InputObject $Left.Value -Compress -Depth 5
    $b = ConvertTo-Json -InputObject $Right.Value -Compress -Depth 5
    $a -ceq $b
}

function Set-EhcValueState {
    param($Context, [string]$RelativeKey = '', [string]$Name, $State)
    $base = Open-EhcBaseKey $Context
    $key = $null
    try {
        if ($State.Exists) {
            $key = $base.CreateSubKey((Get-EhcKeyPath $Context $RelativeKey))
            $kind = [Microsoft.Win32.RegistryValueKind]$State.Kind
            $value = $State.Value
            switch ($kind.ToString()) {
                'DWord' { $value = [int]$value }
                'QWord' { $value = [long]$value }
                'Binary' { $value = [byte[]]$value }
                'MultiString' { $value = [string[]]$value }
                'String' { $value = [string]$value }
                'ExpandString' { $value = [string]$value }
                default { throw "Unsupported registry value kind: $kind" }
            }
            $key.SetValue($Name, $value, $kind)
        } else {
            $key = $base.OpenSubKey((Get-EhcKeyPath $Context $RelativeKey), $true)
            if ($null -ne $key) { $key.DeleteValue($Name, $false) }
        }
    } finally {
        if ($null -ne $key) { $key.Dispose() }
        $base.Dispose()
    }
}

function ConvertTo-EhcHostname {
    param([Parameter(Mandatory)][string]$Hostname)
    $hostText = $Hostname.Trim().TrimEnd('.')
    $wildcard = ''
    if ($hostText.StartsWith('[*.]')) {
        $wildcard = '[*.]'
        $hostText = $hostText.Substring(4)
    }
    if (-not $hostText -or $hostText -match '[\s/:\\?#@*\[\]]') {
        throw "Use a hostname or [*.]example.org, without scheme, port, path, or a blanket wildcard: $Hostname"
    }
    try {
        $ascii = (New-Object System.Globalization.IdnMapping).GetAscii($hostText).ToLowerInvariant()
    } catch { throw "Invalid internationalized hostname: $Hostname" }
    if ($ascii.Length -gt 253) { throw "Hostname exceeds 253 characters: $Hostname" }
    foreach ($label in $ascii.Split('.')) {
        if ($label -notmatch '^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$') {
            throw "Invalid DNS label in hostname: $Hostname"
        }
    }
    "$wildcard$ascii"
}

function Get-EhcEdgeInstallation {
    param(
        [ValidateSet('Stable', 'Beta', 'Dev', 'Canary')][string]$Channel = 'Stable',
        [string]$EdgePath
    )
    $folder = @{ Stable = 'Edge'; Beta = 'Edge Beta'; Dev = 'Edge Dev'; Canary = 'Edge SxS' }[$Channel]
    $candidates = @()
    if ($EdgePath) {
        $candidates = @([IO.Path]::GetFullPath($EdgePath))
    } else {
        foreach ($root in @(${env:ProgramFiles(x86)}, $env:ProgramFiles, $env:LOCALAPPDATA)) {
            if ($root) { $candidates += Join-Path $root "Microsoft\$folder\Application\msedge.exe" }
        }
    }
    foreach ($path in ($candidates | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($path)
            $match = [regex]::Match([string]$info.ProductVersion, '^\d+\.\d+\.\d+\.\d+')
            if ($info.ProductName -notlike '*Microsoft Edge*' -or -not $match.Success) {
                throw "The selected file is not a recognized Microsoft Edge executable: $path"
            }
            $version = [version]$match.Value
            return [pscustomobject]@{
                Found = $true; Channel = $Channel; Path = $path
                Version = $version.ToString(); Major = $version.Major
                SupportsDisableUpgrade = ($version.Major -ge 136)
                SupportsHttpAllowlist = ($version.Major -ge 123)
            }
        }
    }
    if ($EdgePath) { throw "Edge executable not found: $EdgePath" }
    [pscustomobject]@{
        Found = $false; Channel = $Channel; Path = $null; Version = $null
        Major = 0; SupportsDisableUpgrade = $false; SupportsHttpAllowlist = $false
    }
}

function Assert-EhcSupportedVersion {
    param($Installation, [ValidateSet('DisableUpgrade', 'AllowHttp')][string]$Action)
    $minimum = 136
    if ($Action -eq 'AllowHttp') { $minimum = 123 }
    if (-not $Installation.Found) {
        throw "Edge $($Installation.Channel) was not found. Select -Channel Beta/Dev/Canary or supply -EdgePath."
    }
    if ($Installation.Major -lt $minimum) {
        throw "$Action requires Edge $minimum or later; selected $($Installation.Channel) is $($Installation.Version). No changes made."
    }
}

function Get-EhcPolicySnapshot {
    param($Context)
    $entries = @()
    foreach ($name in @(Get-EhcValueNames $Context 'HttpAllowlist')) {
        $entries += [pscustomobject]@{
            Name = $name; State = Get-EhcValueState $Context 'HttpAllowlist' $name
        }
    }
    [pscustomobject]@{
        Scope = $Context.Scope
        RegistryPath = "$($Context.Hive)\$($Context.SubKey)"
        HttpsUpgradesEnabled = Get-EhcValueState $Context '' 'HttpsUpgradesEnabled'
        HttpsOnlyMode = Get-EhcValueState $Context '' 'HttpsOnlyMode'
        HttpAllowlist = $entries
    }
}

function Get-EhcStatus {
    param($Installation, [string]$TargetUserSid = (Get-EhcCurrentSid))
    [pscustomobject]@{
        Tool = 'edge-http-compat'; Version = '0.1.0'
        Edge = $Installation
        IsAdministrator = Test-EhcAdministrator
        CurrentUser = Get-EhcPolicySnapshot (New-EhcContext CurrentUser $TargetUserSid)
        LocalMachine = Get-EhcPolicySnapshot (New-EhcContext LocalMachine $TargetUserSid)
        Note = 'Local registry configuration, not a complete report of effective browser/cloud policy. Check edge://policy. Channel selects detection; browser policies are shared across channels.'
    }
}

function New-EhcPlan {
    param(
        $Context,
        [ValidateSet('DisableUpgrade', 'AllowHttp')][string]$Action,
        [string[]]$Hostname
    )
    if ($Action -eq 'DisableUpgrade') {
        $before = Get-EhcValueState $Context '' 'HttpsUpgradesEnabled'
        $after = [pscustomobject]@{ Exists = $true; Kind = 'DWord'; Value = 0 }
        if (-not (Test-EhcStateEqual $before $after)) {
            [pscustomobject]@{ RelativeKey = ''; Name = 'HttpsUpgradesEnabled'; Before = $before; After = $after }
        }
        return
    }
    if (-not $Hostname -or $Hostname.Count -eq 0) { throw 'AllowHttp requires -Hostname.' }
    $normalized = @($Hostname | ForEach-Object { ConvertTo-EhcHostname $_ } | Select-Object -Unique)
    $names = @(Get-EhcValueNames $Context 'HttpAllowlist')
    $existing = @()
    foreach ($name in $names) {
        $state = Get-EhcValueState $Context 'HttpAllowlist' $name
        if ($state.Kind -eq 'String') { $existing += [string]$state.Value }
    }
    foreach ($hostText in $normalized) {
        if ($existing -contains $hostText) { continue }
        $number = 1
        while ($names -contains [string]$number) { $number++ }
        $name = [string]$number
        $names += $name
        $existing += $hostText
        [pscustomobject]@{
            RelativeKey = 'HttpAllowlist'; Name = $name
            Before = [pscustomobject]@{ Exists = $false; Kind = $null; Value = $null }
            After = [pscustomobject]@{ Exists = $true; Kind = 'String'; Value = $hostText }
        }
    }
}

function Save-EhcBackup {
    param($Context, [object[]]$Plan, [string]$BackupDirectory, [string]$Action)
    $directory = [IO.Path]::GetFullPath($BackupDirectory)
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $file = Join-Path $directory ('edge-http-{0}-{1}.json' -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'), [guid]::NewGuid().ToString('N'))
    $manifest = [ordered]@{
        Tool = 'edge-http-compat'; SchemaVersion = 1
        CreatedUtc = [DateTime]::UtcNow.ToString('o'); Action = $Action
        Scope = $Context.Scope; UserSid = $Context.UserSid
        Changes = @($Plan)
    }
    $json = ConvertTo-Json $manifest -Depth 12
    $encoding = New-Object Text.UTF8Encoding($false)
    if ($encoding.GetByteCount($json) -gt 1MB) { throw 'Backup would exceed the supported size. Split the operation.' }
    $stream = New-Object IO.FileStream($file, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = $encoding.GetBytes($json)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally { $stream.Dispose() }
    $file
}

function Invoke-EhcApply {
    [CmdletBinding(SupportsShouldProcess)]
    param($Context, [object[]]$Plan, [string]$BackupDirectory, [string]$Action)
    if (-not $Plan -or $Plan.Count -eq 0) {
        return [pscustomobject]@{ Changed = 0; BackupFile = $null; Message = 'Already configured; no changes.' }
    }
    if ($Plan.Count -gt 1000) { throw 'At most 1000 policy changes are supported per operation.' }
    foreach ($change in $Plan) {
        Assert-EhcBackupState $change.Before
        Assert-EhcBackupState $change.After
        $current = Get-EhcValueState $Context $change.RelativeKey $change.Name
        if (-not (Test-EhcStateEqual $current $change.Before)) { throw 'Policy changed while planning. Run again.' }
    }
    if (-not $PSCmdlet.ShouldProcess("$($Context.Scope) Edge policy (all channels)", $Action)) { return }
    $backup = Save-EhcBackup $Context $Plan $BackupDirectory $Action
    $written = @()
    try {
        foreach ($change in $Plan) {
            # Recheck just before each write as well as during the initial preflight.
            $current = Get-EhcValueState $Context $change.RelativeKey $change.Name
            if (-not (Test-EhcStateEqual $current $change.Before)) { throw 'Policy changed before write.' }
            Set-EhcValueState $Context $change.RelativeKey $change.Name $change.After
            $written += $change
            if (-not (Test-EhcStateEqual (Get-EhcValueState $Context $change.RelativeKey $change.Name) $change.After)) {
                throw "Read-back verification failed for $($change.Name)."
            }
        }
    } catch {
        $originalError = $_
        $rollbackErrors = @()
        [array]::Reverse($written)
        foreach ($change in $written) {
            try {
                $current = Get-EhcValueState $Context $change.RelativeKey $change.Name
                if (Test-EhcStateEqual $current $change.After) {
                    Set-EhcValueState $Context $change.RelativeKey $change.Name $change.Before
                } else { $rollbackErrors += "Concurrent change: $($change.Name)" }
            } catch { $rollbackErrors += $_.Exception.Message }
        }
        throw "Apply failed: $($originalError.Exception.Message) Backup: $backup. Rollback issues: $($rollbackErrors -join '; '). If access was denied, rerun with -Elevate."
    }
    [pscustomobject]@{ Changed = $written.Count; BackupFile = $backup; Message = 'Policy written and read back. Reload edge://policy or restart Edge to verify the effective policy.' }
}

function Assert-EhcBackupState {
    param($State)
    if ($null -eq $State -or $State.Exists -isnot [bool]) { throw 'Invalid backup value state.' }
    if ($State.Exists) {
        if ($State.Kind -notin @('DWord', 'QWord', 'Binary', 'MultiString', 'String', 'ExpandString')) {
            throw 'Invalid backup registry type.'
        }
        # Validate conversions before any restoration starts.
        switch ($State.Kind) {
            'DWord' { $null = [int]$State.Value }
            'QWord' { $null = [long]$State.Value }
            'Binary' { $null = [byte[]]$State.Value }
            'MultiString' { $null = [string[]]$State.Value }
        }
    }
}

function Read-EhcBackup {
    param([string]$BackupFile, $Context)
    $file = Get-Item -LiteralPath $BackupFile
    if ($file.Length -gt 1MB) { throw 'Backup is unexpectedly large.' }
    $backup = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($backup.Tool -cne 'edge-http-compat' -or $backup.SchemaVersion -ne 1) { throw 'Unknown backup format.' }
    if ($backup.Scope -cne $Context.Scope -or $backup.UserSid -cne $Context.UserSid) {
        throw 'Backup belongs to a different scope or Windows user. Select the original scope/account explicitly.'
    }
    if ($backup.Action -notin @('DisableUpgrade', 'AllowHttp')) { throw 'Unknown backup operation.' }
    $seen = @{}
    $changes = @($backup.Changes)
    if ($changes.Count -eq 0 -or $changes.Count -gt 1000) { throw 'Invalid number of backup changes.' }
    foreach ($change in $changes) {
        $isUpgrade = $backup.Action -eq 'DisableUpgrade' -and $change.RelativeKey -ceq '' -and $change.Name -ceq 'HttpsUpgradesEnabled'
        $isHost = $backup.Action -eq 'AllowHttp' -and $change.RelativeKey -ceq 'HttpAllowlist' -and $change.Name -match '^[1-9][0-9]{0,8}$'
        if (-not ($isUpgrade -or $isHost)) { throw 'Backup contains an unexpected registry target.' }
        $identity = "$($change.RelativeKey)\$($change.Name)"
        if ($seen.ContainsKey($identity)) { throw 'Duplicate backup target.' }
        $seen[$identity] = $true
        Assert-EhcBackupState $change.Before
        Assert-EhcBackupState $change.After
        if ($isUpgrade -and (-not $change.After.Exists -or $change.After.Kind -cne 'DWord' -or $change.After.Value -ne 0)) {
            throw 'Unexpected automatic-upgrade value in backup.'
        }
        if ($isHost) {
            if ($change.Before.Exists -or -not $change.After.Exists -or $change.After.Kind -cne 'String') {
                throw 'Unexpected allowlist change in backup.'
            }
            $normalized = ConvertTo-EhcHostname ([string]$change.After.Value)
            if ($normalized -cne $change.After.Value) { throw 'Non-canonical hostname in backup.' }
        }
    }
    $backup
}

function Invoke-EhcRestore {
    [CmdletBinding(SupportsShouldProcess)]
    param($Context, [string]$BackupFile)
    $backup = Read-EhcBackup $BackupFile $Context
    $pending = @()
    foreach ($change in $backup.Changes) {
        $current = Get-EhcValueState $Context $change.RelativeKey $change.Name
        if (Test-EhcStateEqual $current $change.Before) { continue }
        if (-not (Test-EhcStateEqual $current $change.After)) {
            throw "Restore conflict at $($change.RelativeKey)\$($change.Name). Another change occurred; nothing was restored."
        }
        $pending += $change
    }
    if (-not $pending.Count) { return [pscustomobject]@{ Restored = 0; Message = 'Already restored.' } }
    if (-not $PSCmdlet.ShouldProcess("$($Context.Scope) Edge policy (all channels)", 'Restore saved values')) { return }
    foreach ($change in $pending) {
        $current = Get-EhcValueState $Context $change.RelativeKey $change.Name
        if (-not (Test-EhcStateEqual $current $change.After)) { throw 'Concurrent change during restore. Stop and review the backup.' }
        Set-EhcValueState $Context $change.RelativeKey $change.Name $change.Before
        if (-not (Test-EhcStateEqual (Get-EhcValueState $Context $change.RelativeKey $change.Name) $change.Before)) {
            throw "Restore read-back failed for $($change.Name). Keep the backup and inspect edge://policy."
        }
    }
    [pscustomobject]@{ Restored = $pending.Count; Message = 'Original values restored. Reload edge://policy or restart Edge.' }
}

Export-ModuleMember -Function *-Ehc*
