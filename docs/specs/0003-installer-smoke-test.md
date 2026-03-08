# 0003 — Installer smoke test

- **Status:** pending

---

## Background

After building and flashing a new installer ISO, there is currently no
structured way to verify that the live system booted correctly and that all
critical services are functional. Verification is done ad hoc via the serial
console and SSH, with no record of what passed or failed.

This spec defines a `bin/killy-smoke-test` script that runs a fixed set of
checks against the live installer, produces a human-readable report, and exits
with a non-zero status if any check failed. The script is designed to be run
from the build host immediately after killy reboots from the installer USB.

---

## Goals

- Check serial console reachability (ttyUSB0).
- Check SSH reachability and key-based authentication.
- Check the status of all critical systemd services on the live installer.
- Check that the age install key was successfully unwrapped and written to
  `/run/age-install-key`.
- Check that `SOPS_AGE_KEY` is exported correctly in a login shell.
- Check that WiFi has a default route (network is up).
- Run all checks independently — a failure in one check does not prevent the
  others from running.
- Print a final report summarising pass/fail for each check.
- Exit 0 if all checks passed, non-zero otherwise.

---

## Non-goals

- Automated remediation (the script only reports, never fixes).
- Checking the installed system (only the live installer environment).
- Continuous monitoring or looping until success.

---

## Specification

### Script location and invocation

`bin/killy-smoke-test` — available on `PATH` inside `nix-shell`.

```bash
killy-smoke-test [ip]
```

`ip` — IPv4 address of the live installer (default: `192.168.42.86`).

The script runs all checks sequentially, collects results, then prints the
report and exits.

### Checks

| ID | Name | Method | Pass condition |
|----|------|--------|----------------|
| C1 | Serial console reachable | `killy-serial` sends `echo smoke-test-ping` and reads response | Response contains `smoke-test-ping` |
| C2 | SSH reachable | `ssh -o ConnectTimeout=10 nixos@<ip> true` | Exit code 0 |
| C3 | `yk-unwrap.service` active | SSH: `systemctl is-active yk-unwrap` | Output is `active` |
| C4 | `installer-authorized-keys.service` active | SSH: `systemctl is-active installer-authorized-keys` | Output is `active` |
| C5 | `installer-network.service` active | SSH: `systemctl is-active installer-network` | Output is `active` |
| C6 | Age key present | SSH: `test -s /run/age-install-key` | Exit code 0 |
| C7 | `SOPS_AGE_KEY` in login shell | SSH: `bash -lc 'echo ${SOPS_AGE_KEY:+set}'` | Output is `set` |
| C8 | Default route present | SSH: `ip route show default` | Output is non-empty |

### Serial check (C1)

Uses `killy-serial` (which manages the background reader). If the FT232
adapter is not present or the reader cannot be started, C1 is marked FAIL with
a descriptive message; remaining checks continue.

The check restarts the reader first (`killy-serial -r`) to flush stale buffer
content from before the reboot.

### SSH checks (C2–C8)

All SSH checks use a single `ControlMaster` connection opened at the start of
the SSH phase. If C2 fails (SSH unreachable), checks C3–C8 are all marked SKIP
(not FAIL) with the note "SSH unavailable".

SSH options used:
- `StrictHostKeyChecking=accept-new` — accept a new host key silently (expected
  after each ISO flash).
- `ConnectTimeout=10` — fail fast rather than hanging.
- `ControlMaster=auto`, `ControlPath=/tmp/killy-smoke-%%r@%%h:%%p`,
  `ControlPersist=30` — multiplexed connection for all subsequent checks.

### Report format

```
killy smoke test — 2026-03-08 14:32:01
---------------------------------------
C1  serial console reachable          PASS
C2  SSH reachable                     PASS
C3  yk-unwrap.service active          PASS
C4  installer-authorized-keys active  PASS
C5  installer-network.service active  PASS
C6  age key present                   PASS
C7  SOPS_AGE_KEY in login shell       PASS
C8  default route present             PASS
---------------------------------------
All 8 checks passed.
```

Or on failure:

```
killy smoke test — 2026-03-08 14:32:01
---------------------------------------
C1  serial console reachable          PASS
C2  SSH reachable                     FAIL  Connection timed out
C3  yk-unwrap.service active          SKIP  SSH unavailable
...
---------------------------------------
3 of 8 checks failed.
```

### Exit code

- `0` — all checks passed.
- `1` — one or more checks failed.

---

## Implementation notes

- Written in bash, using only tools available in the `nix-shell` dev
  environment (`ssh`, `killy-serial`, `date`).
- Each check is implemented as a function `check_<id>` that sets a result
  variable and an optional detail string; results are collected in an array
  and printed at the end.
- The script must not use `set -e` at the top level (individual check failures
  must not abort the script). Each check function uses a local subshell or
  explicit `|| true` where needed.
