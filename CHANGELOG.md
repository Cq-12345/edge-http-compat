# Changelog

## 0.1.0 — 2026-11-01

- Default to read-only diagnosis of Stable Edge.
- Detect Stable, Beta, Dev, Canary, or an explicitly supplied executable.
- Validate policy version requirements before changes.
- Support disabling automatic HTTPS upgrades and appending hostname exceptions.
- Preserve the initiating user's identity across optional Windows elevation.
- Back up original registry value types and contents; restore with conflict checks.
- Support `WhatIf`, confirmation, repeated no-op operations, and failure rollback.
- Add Chinese and English documentation and Windows PowerShell 5.1 / 7 tests.

The real browser comparison used Edge Beta 152.0.4191.19. The documented version
support matrix is broader than the set of browsers actually tested.
