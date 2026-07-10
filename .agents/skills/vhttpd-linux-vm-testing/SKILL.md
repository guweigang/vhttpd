---
name: vhttpd-linux-vm-testing
description: >-
  Validate vhttpd changes in the OrbStack Ubuntu VM. Use for Linux CI reproduction,
  cross-platform runtime changes, WebSocket/relay/provider/network behavior, DB or
  OpenSSL build changes, packaging checks, and changes to vhttpd build/test tooling.
  Do not use as a default requirement for UI-only, documentation-only, or macOS-only
  workflow changes.
---

# vhttpd Linux VM Testing

Use the OrbStack VM named `ubuntu`.

Known paths:

- macOS host checkout: `/Users/guweigang/Source/vhttpd`
- Ubuntu VM checkout view: `/Users/guweigang/Source/vhttpd`
- Linux V compiler repo: `/home/guweigang/v`
- Linux V compiler binary: `/home/guweigang/v/v`

The macOS checkout is mounted into the VM. Never run host-built Mach-O binaries in Linux:

- Do not run the host `./vhttpd` inside Ubuntu.
- Do not run a host `v` binary inside Ubuntu.
- Build and test with the Linux V compiler from `/home/guweigang/v/v`, or install/build a
  Linux compiler inside the VM first.

## Scope Gate

Run Ubuntu VM validation when Linux behavior is relevant:

- Build, packaging, Makefile, dependency, OpenSSL, DB, QuickJS, or vjsx integration changes.
- Runtime code shared by Linux/macOS, especially listener, worker, WebSocket, relay, provider,
  MCP, stream, cache, DB, and routing paths.
- E2E or CI failures that reproduce only on Linux.
- PR validation where the requested or risky scope is cross-platform.

Do not run Ubuntu as a reflex for:

- Admin UI static asset changes only.
- Documentation-only changes.
- macOS-only local workflow changes.
- Tests that are explicitly host-only or browser-only.

For those, say Linux VM coverage is optional rather than required.

## Required Build Settings

Prefer GCC and disable Boehm GC for Linux VM test runs unless reproducing CI packaging exactly.
On ARM64 virtualization, Boehm GC can hang in signal/thread handling; `VPHP_V_GC=none` maps
through the vhttpd Makefile to `-gc none`.

Use these defaults:

```bash
export PATH="/home/guweigang/v:$PATH"
export V_CC=gcc
export VPHP_V_GC=none
```

For CI parity production packaging, run a separate explicit build with Boehm:

```bash
make prod V_CC=gcc VPHP_V_GC=boehm WITH_DB=1
```

Keep these exports in the same `orb` shell as the command. Environment changes do not persist
between separate `orb` invocations.

## Workflow

### 1. Validate macOS first

Run the smallest relevant host-side checks first. Linux is supplemental cross-platform coverage,
not a replacement for local macOS validation.

Examples:

```bash
make test-fast
make test-php
make test-e2e
```

For targeted tests:

```bash
make test src/config/runtime_plan_loader_test.v
make test src/executor/runtime_plan_bridge_test.v
```

### 2. Inspect the VM before running tests

Check the mounted VM view and the Linux compiler repo before doing anything that could mutate
state:

```bash
orb -m ubuntu bash -lc 'cd /Users/guweigang/Source/vhttpd && git status --short --branch'
orb -m ubuntu bash -lc 'cd /home/guweigang/v && git status --short --branch && ./v version'
```

Stop if the VM shows tracked changes you did not make. Untracked `.codex/` or `.opencode/`
directories from the host are common; ignore them unless the task concerns those paths. Do not
run `git reset`, `git checkout --`, or `git clean` without explicit user approval.

### 3. Make sure the Linux compiler is usable

Use the VM compiler:

```bash
orb -m ubuntu bash -lc 'cd /home/guweigang/v && ./v version'
```

If the compiler is stale or broken, rebuild it inside the VM:

```bash
orb -m ubuntu bash -lc 'cd /home/guweigang/v && make CC=gcc'
```

Do not fetch or change branches in `/home/guweigang/v` unless the user asked to validate against
a specific V compiler commit.

### 4. Run Linux vhttpd unit tests

Run from the mounted vhttpd checkout with Linux V first on the relevant target:

```bash
orb -m ubuntu bash -lc 'cd /Users/guweigang/Source/vhttpd && \
  export PATH="/home/guweigang/v:$PATH" V_CC=gcc VPHP_V_GC=none && \
  make test-fast'
```

For targeted V tests:

```bash
orb -m ubuntu bash -lc 'cd /Users/guweigang/Source/vhttpd && \
  export PATH="/home/guweigang/v:$PATH" V_CC=gcc VPHP_V_GC=none && \
  make test src/executor/runtime_plan_bridge_test.v'
```

Run PHP package tests only when PHP is available in the VM:

```bash
orb -m ubuntu bash -lc 'cd /Users/guweigang/Source/vhttpd && \
  export PATH="/home/guweigang/v:$PATH" V_CC=gcc VPHP_V_GC=none && \
  make test-php'
```

If `php` or `node` is missing, report the missing tool instead of silently skipping the suite.

### 5. Run Linux E2E tests

Run E2E after a Linux build exists. This exercises startup, config acceptance, WebSocket dispatch,
provider runtime, relay, WordPress smoke paths, and runtime diagnostics:

```bash
orb -m ubuntu bash -lc 'cd /Users/guweigang/Source/vhttpd && \
  export PATH="/home/guweigang/v:$PATH" V_CC=gcc VPHP_V_GC=none && \
  make build WITH_DB=1 && \
  make test-e2e'
```

Live DB/installed WordPress scenarios are opt-in. Only enable them when the user has requested
that coverage and the VM has the required services/paths:

```bash
VHTTPD_E2E_DB_LIVE=1
VHTTPD_E2E_WP_ROOT=/path/to/wordpress
```

### 6. Reproduce CI packaging when needed

For release, CI, or artifact regressions, match the GitHub workflow more closely:

```bash
orb -m ubuntu bash -lc 'cd /Users/guweigang/Source/vhttpd && \
  export PATH="/home/guweigang/v:$PATH" V_CC=gcc && \
  make test-fast V_CC=gcc && \
  make prod V_CC=gcc VPHP_V_GC=boehm WITH_DB=1 && \
  make test-e2e && \
  ./vhttpd --help >/dev/null'
```

Use `VPHP_V_GC=boehm` only for this CI-parity pass or when debugging Boehm-specific behavior.

### 7. Restore and report state

Because the VM uses the mounted host checkout, do not switch branches in the mounted vhttpd tree
unless explicitly requested. At the end, report:

- host commit and branch tested
- VM vhttpd path and branch state
- Linux V compiler path and version
- command list and results
- whether `VPHP_V_GC=none` or `boehm` was used
- skipped tests and exact reasons
- final `git status --short --branch` for vhttpd and `/home/guweigang/v`

Example final checks:

```bash
git status --short --branch
orb -m ubuntu bash -lc 'cd /Users/guweigang/Source/vhttpd && git status --short --branch'
orb -m ubuntu bash -lc 'cd /home/guweigang/v && git status --short --branch'
```

## Reporting Template

Use this structure in the final response:

```text
Linux VM validation:
- vhttpd commit: <sha> (<branch>)
- Linux V: /home/guweigang/v/v, <version>
- Commands:
  - <command>: passed/failed/skipped
- Skips:
  - <suite>: <reason>
- Final state:
  - host vhttpd: <status>
  - VM vhttpd: <status>
  - VM V compiler repo: <status>
```
