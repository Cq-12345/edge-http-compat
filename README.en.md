# Edge HTTP Compat

[中文完整说明](README.md) · [MIT license](LICENSE)

A Windows PowerShell helper for legacy HTTP sites affected by Microsoft Edge's automatic HTTPS upgrades. It uses documented Microsoft policies and supports diagnosis, persistent configuration, per-site exceptions, backups, and conflict-aware restoration.

**The default browser is Stable Edge. The default action is read-only `Status`.**

## Requirements and compatibility

- Windows desktop; Windows PowerShell 5.1 or PowerShell 7. No third-party modules.
- `DisableUpgrade`: Edge **136+**, using `HttpsUpgradesEnabled = DWORD 0`.
- `AllowHttp`: Edge **123+**, using `HttpAllowlist`.
- `Status` has no policy version gate. `Restore` does not require Edge to remain installed.
- `HttpsOnlyMode` (Windows Edge 140+) is reported when locally configured, but is not changed.
- The obsolete `AutomaticHttpsDefault` policy is not used as an older-version fallback.

Sources: [HTTPS upgrades](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/HttpsUpgradesEnabled), [HTTP allowlist](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/HttpAllowlist), [HTTPS-Only mode](https://learn.microsoft.com/en-us/deployedge/microsoft-edge-policies/HttpsOnlyMode), [policy migration](https://learn.microsoft.com/en-us/microsoft-edge/web-platform/site-impacting-changes). Reviewed November 1, 2026.

Locally tested with PowerShell 5.1.26100.9549 and 7.6.5. A real network comparison used Edge Beta 152.0.4191.19 in an isolated browser session. Stable 130.0.2849.80 was available for detection and is below the global-disable policy's minimum version. Support for other versions/channels follows the documented policy range; it is **not** a claim that every browser version has been tested.

## Quick start

Clone/download this repository and open PowerShell in its directory:

```powershell
.\EdgeHttpCompat.ps1
.\EdgeHttpCompat.ps1 -Action DisableUpgrade -WhatIf
.\EdgeHttpCompat.ps1 -Action DisableUpgrade -Elevate
```

Keep the printed `BackupFile`. Open `edge://policy` in the browser you actually use, reload policies, and check that `HttpsUpgradesEnabled` is `false` with a successful status. Restart Edge if necessary and test the original navigation. A successful registry write alone is not proof that a website is reachable.

For only a few affected sites, use a persistent allowlist instead:

```powershell
.\EdgeHttpCompat.ps1 -Action AllowHttp -Hostname 'legacy.example.org' -Elevate
.\EdgeHttpCompat.ps1 -Action AllowHttp -Hostname 'legacy.example.org', '[*.]example.net' -Elevate
```

Supply hostnames, not URLs, ports, or paths. The script lowercases names, removes a trailing dot, converts IDNs to ASCII A-labels, de-duplicates entries, and appends using unused numeric registry value names. Blanket `*` / `[*]` wildcards are rejected.

## Beta, Dev, Canary, custom installations

```powershell
.\EdgeHttpCompat.ps1 -Channel Beta
.\EdgeHttpCompat.ps1 -Action DisableUpgrade -Channel Beta -Elevate
.\EdgeHttpCompat.ps1 -Channel Dev
.\EdgeHttpCompat.ps1 -Channel Canary
.\EdgeHttpCompat.ps1 -EdgePath 'D:\Browsers\Edge\Application\msedge.exe'
```

Standard locations are searched under `ProgramFiles(x86)`, `ProgramFiles`, and `LOCALAPPDATA`, with the `Microsoft\Edge`, `Edge Beta`, `Edge Dev`, or `Edge SxS` application directory. No user's home path or SID is hardcoded.

**Channel selection changes executable discovery and version checking, not policy isolation.** The documented policy path is `Software\Policies\Microsoft\Edge`. This tool does not invent an `Edge Beta` policy path. Supported channels in the same Windows user/device scope may consume the same policy. Use separate Windows accounts or test devices if different channel policies are required.

## Scope, elevation, backups

`-Scope CurrentUser` is the default. It may still require elevation because `HKCU\Software\Policies` can be protected. `-Elevate` requests Windows UAC consent when an actual write is needed. It preserves the original user's SID and backup directory, addressing the original user through `HKEY_USERS` even if another administrator account supplies consent.

`-Scope LocalMachine` explicitly applies to all users and requires appropriate rights. Machine, domain, MDM, or cloud policy may take precedence. `Status` reports **local registry values**, not the browser's complete effective-policy state; check `edge://policy` and coordinate with the device administrator.

Backups and elevation logs default to `%LOCALAPPDATA%\EdgeHttpCompat\Backups`. Override with `-BackupDirectory`. Backups contain only this operation's touched values and their before/after states, not browser profiles or a full registry export.

```powershell
.\EdgeHttpCompat.ps1 -Action Restore -BackupFile 'D:\backups\operation.json' -WhatIf
.\EdgeHttpCompat.ps1 -Action Restore -BackupFile 'D:\backups\operation.json' -Elevate
# For a backup originally made in machine scope:
.\EdgeHttpCompat.ps1 -Action Restore -Scope LocalMachine -BackupFile 'D:\backups\machine.json' -Elevate
```

Restoration preserves original types and values, removes a value only if it was originally absent, and refuses to overwrite subsequent changes. Existing allowlist entries and unrelated policies are preserved. Empty keys may remain; shared Edge policy keys are never recursively removed. Restore from the original user and scope. Keep backups private: they may contain a SID, domain names, or local paths.

## What this fixes, and what it does not

Automatic HTTPS upgrading and HTTPS-Only mode are separate mechanisms. The latter being off does not establish that automatic upgrades are off. The HTTP and HTTPS services for one host can also behave differently.

In the real browser comparison, the initial page requests changed from `HTTPS -> HTTP` to just `HTTP`, and the legacy login page loaded. The clean test session could fall back before the change; this does not claim to reproduce every failure in the original personal profile.

This tool does not override HSTS, bypass certificate warnings, rewrite explicit HTTPS URLs, disable extensions, change proxies, clear history/cookies, or repair a server. HTTPS-Only settings, saved HTTPS suggestions, redirects, network failures, and managed policy can still affect navigation. `HttpAllowlist` explicitly does not exempt HSTS upgrades.

## Common issues

| Problem | Next step |
|---|---|
| Access denied | Rerun with `-Elevate`; use Windows consent or ask the administrator. |
| Edge not found | Choose the intended `-Channel` or supply `-EdgePath`. |
| Version gate rejects the operation | Check the minimum version; do not bypass the check to claim unsupported compatibility. |
| Policy missing or overridden | Reload `edge://policy`, check scope/source, and restart if needed. |
| HTTPS still enforced | Check HTTPS-Only mode, HSTS, redirects, extensions, and selected history suggestions. |
| HTTP also fails | Diagnose the server, DNS, intranet access, or proxy separately. |
| Restore conflict | Keep the backup and inspect the later change; restoration deliberately does not force overwrite. |

If script execution is restricted, inspect the code, unblock the downloaded files, and use a process-specific `RemoteSigned` policy if permitted. Do not override organization-managed execution policy. See the detailed Chinese README for commands and additional diagnosis.

## Parameters

`-Action Status|DisableUpgrade|AllowHttp|Restore`, `-Channel Stable|Beta|Dev|Canary`, `-Scope CurrentUser|LocalMachine`, `-Hostname`, `-EdgePath`, `-BackupDirectory`, `-BackupFile`, `-Elevate`, `-WhatIf`, `-Confirm`, `-Json`.

`-TargetUserSid` is an advanced parameter primarily used to preserve identity across elevation; ordinary use should omit it. `-Json` is best consumed without `-Elevate`, whose parent also reports the child operation's log. Exit code 0 means command success/no-op/preview, not guaranteed website access; 1 indicates failure.

## Tests and changes

```powershell
powershell.exe -NoProfile -File .\tests\Run-Tests.ps1
pwsh.exe -NoProfile -File .\tests\Run-Tests.ps1
```

Tests use a random `HKCU\Software\EdgeHttpCompat.Tests` subkey and `.test-artifacts`, clean up afterwards, and do not alter actual Edge policy or access websites. CI covers both PowerShell engines. Coverage includes version gates, normalization, backups, restoration conflicts, malicious backup targets, idempotency, failure rollback, dry runs, parameter serialization, and the default Stable read-only CLI.

Use parameters before editing code. To extend installation detection, update `Get-EhcEdgeInstallation`. To add policies, update version validation, plan creation, backup validation, restoration, tests, and documentation together. Do not execute arbitrary registry paths from a backup. Read [CONTRIBUTING.md](CONTRIBUTING.md) before reporting issues or submitting changes.

MIT licensed. Community project; not an official Microsoft product.
