# tls-fix-erp-updater

A small PowerShell utility that works around ERP updaters which silently downgrade Windows TLS settings for the current user during execution.

This repo is a sanitized portfolio version of a real production fix: I identified that a legacy updater was rewriting `SecureProtocols` under `HKCU`, forcing older protocol negotiation and breaking NF-e / NFC-e communication with modern fiscal endpoints. The vendor team had a legacy behavior enabled and did not yet have a clean switch to disable it, so I built a targeted mitigation and documented the root cause for them.

---

## Problem

The symptom was intermittent failure in fiscal communication after running the ERP updater.

The application itself was not obviously broken, but after update execution the machine would negotiate TLS incorrectly for services that require TLS 1.2, which caused NF-e / NFC-e flows to fail.

---

## Root Cause

The updater process rewrote this registry value for the current user:

```text
HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\SecureProtocols
```

That value controls which protocol bitmask WinInet-based applications may use.

In the observed behavior, the updater replaced a valid TLS 1.2 configuration with a legacy mask that re-enabled outdated protocols. The downgrade happened as a side effect of the updater routine, not as an intentional configuration change the team was aware of.

For reference:

| Value | Meaning |
|---|---|
| `0x0008` | TLS 1.0 |
| `0x0020` | TLS 1.1 |
| `0x0800` | TLS 1.2 |
| `2048` | Decimal form of `0x0800` |

---

## How The Fix Works

The script applies a narrow workaround around the updater lifecycle:

1. Sets `SecureProtocols` to `2048` (`0x0800`, TLS 1.2 only).
2. Applies a temporary `Deny` ACL for `SetValue` on the key, blocking the updater from overwriting it.
3. Launches the updater and waits for it to finish.
4. Always removes the temporary ACL in a `finally` block, restoring normal access even if the updater fails.

This keeps the system stable while the product team removes the legacy write from the updater itself.

---

## Usage

Run the script and point it at the updater executable:

```powershell
powershell -ExecutionPolicy Bypass -File .\fix-tls-override.ps1 `
  -UpdaterPath "C:\YourProduct\Atu_Sistema.exe"
```

The script self-elevates when needed.

---

## Why This Approach

- Minimal surface area: no permanent service, agent, or scheduled task.
- Deterministic cleanup: the ACL is removed in `finally`, even on failure.
- Parameterized and reusable: one script replaces multiple product-specific launchers.
- Operationally practical: it buys time while the real vendor-side fix is implemented.

---

## Notes

- This is a workaround, not the ideal long-term solution.
- The correct permanent fix is to remove or change the legacy `SecureProtocols` write in the updater itself.
- The script assumes the updater process lifetime matches the period during which the registry override happens.
- Tested for user-scoped (`HKCU`) TLS settings on Windows machines running WinInet-based business software.
