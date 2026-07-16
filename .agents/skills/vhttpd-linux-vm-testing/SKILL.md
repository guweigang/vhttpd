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

Linux V is a local dependency of vhttpd validation. Treat `/home/guweigang/v` branch
`local-dev` as the expected V baseline unless the user explicitly asks to test another V commit.
Do not replace it with system packages or a host-mounted macOS compiler.

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
orb -m ubuntu bash -lc 'cd /home/guweigang/v && git status --short --branch && git branch --show-current && ./v version'
```

Stop if the VM shows tracked changes you did not make. Untracked `.codex/` or `.opencode/`
directories from the host are common; ignore them unless the task concerns those paths. Do not
run `git reset`, `git checkout --`, or `git clean` without explicit user approval.

If `/home/guweigang/v` is not on `local-dev`, stop and report it unless the user explicitly asked
to validate a different V branch or commit. Do not silently move the V dependency.

### 3. Install Linux build dependencies

Use the GitHub workflow as the dependency baseline. If sqlite, MySQL/MariaDB client headers,
PostgreSQL headers, OpenSSL, Boehm GC, or packaging tools are missing, install them in the VM
instead of skipping tests:

```bash
orb -m ubuntu bash -lc 'sudo apt-get update && sudo apt-get install -y --no-install-recommends \
  build-essential \
  ca-certificates \
  default-libmysqlclient-dev \
  libpq-dev \
  libsqlite3-dev \
  libgc-dev \
  patchelf \
  pkg-config \
  libssl-dev'
```

For PHP or Node based tests, install the missing runtime too:

```bash
orb -m ubuntu bash -lc 'sudo apt-get update && sudo apt-get install -y --no-install-recommends \
  php-cli \
  nodejs \
  npm'
```

After installing, verify the toolchain:

```bash
orb -m ubuntu bash -lc 'cc --version || gcc --version; pkg-config --modversion openssl sqlite3; pkg-config --exists mysqlclient || pkg-config --exists mariadb; pkg-config --exists libpq'
```

Only report a dependency as unavailable after the install attempt fails.

### 4. Mirror the workflow vjsx setup on native Linux storage

The GitHub workflow installs vjsx as a single module checkout and links only
`$HOME/.vmodules/vjsx`:

```bash
VHTTPD_VJSX_ROOT=/usr/local/share/vhttpd/vjsx
```

In the VM, keep the same shape unless intentionally testing a workflow change. vjsx and
QuickJS must live on native Linux storage, not under the macOS-mounted `/Users/...` tree. Orb can
translate macOS file access, but compiled objects and C library probes must be produced from
Linux-native paths to reproduce workflow behavior.

```bash
orb -m ubuntu bash -lc 'set -euo pipefail
  VHTTPD_VJSX_ROOT=/usr/local/share/vhttpd/vjsx
  VHTTPD_QUICKJS_WORK_ROOT=/home/guweigang/vhttpd-linux-deps
  sudo mkdir -p "$(dirname "$VHTTPD_VJSX_ROOT")"
  sudo chown "$USER" "$(dirname "$VHTTPD_VJSX_ROOT")"
  if [ ! -d "$VHTTPD_VJSX_ROOT/.git" ]; then
    git clone https://github.com/guweigang/vjsx "$VHTTPD_VJSX_ROOT"
  fi
  mkdir -p "$VHTTPD_QUICKJS_WORK_ROOT"
  mkdir -p "$HOME/.vmodules"
  rm -rf "$HOME/.vmodules/vjsx"
  ln -s "$VHTTPD_VJSX_ROOT" "$HOME/.vmodules/vjsx"
  quickjs_path="$(VJS_QUICKJS_WORK_ROOT="$VHTTPD_QUICKJS_WORK_ROOT" "$VHTTPD_VJSX_ROOT/scripts/ensure-quickjs.sh")"
  echo "VJS_QUICKJS_PATH=$quickjs_path"'
```

Do not add extra module links, such as `$HOME/.vmodules/runtimejs`, when reproducing CI.
If vhttpd requires such a link, treat that as a workflow/code contract mismatch and fix the
contract explicitly instead of hiding it in the VM.

### 5. Make sure the Linux compiler is usable

Use the VM compiler:

```bash
orb -m ubuntu bash -lc 'cd /home/guweigang/v && git branch --show-current && ./v version'
```

If the compiler is stale or broken, rebuild it inside the VM:

```bash
orb -m ubuntu bash -lc 'cd /home/guweigang/v && make CC=gcc'
```

Do not fetch or change branches in `/home/guweigang/v` unless the user asked to validate against
a specific V compiler commit.

### 6. Run Linux vhttpd unit tests

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

Run PHP package tests after installing PHP when PHP coverage is relevant:

```bash
orb -m ubuntu bash -lc 'cd /Users/guweigang/Source/vhttpd && \
  export PATH="/home/guweigang/v:$PATH" V_CC=gcc VPHP_V_GC=none && \
  make test-php'
```

If `php` or `node` is missing, install it first. If installation fails, report the exact failed
install command and error.

### 7. Run Linux E2E tests

Run E2E after a Linux build exists. This exercises startup, config acceptance, WebSocket dispatch,
provider runtime, relay, WordPress smoke paths, and runtime diagnostics:

```bash
orb -m ubuntu bash -lc 'cd /Users/guweigang/Source/vhttpd && \
  export PATH="/home/guweigang/v:$PATH" V_CC=gcc VPHP_V_GC=none && \
  make build WITH_DB=1 && \
  make test-e2e'
```

Live DB/installed WordPress scenarios are opt-in. Only enable them when the user has requested
that coverage and the VM has the required services/paths. Install the client/build dependencies
yourself; only the actual DB service and WordPress root are environment-specific:

```bash
VHTTPD_E2E_DB_LIVE=1
VHTTPD_E2E_WP_ROOT=/path/to/wordpress
```

### 8. Reproduce CI packaging when needed

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

### 9. Restore and report state

Because the VM uses the mounted host checkout, do not switch branches in the mounted vhttpd tree
unless explicitly requested. At the end, report:

- host commit and branch tested
- VM vhttpd path and branch state
- Linux V compiler path and version
- Linux V compiler branch, normally `local-dev`
- vjsx root and commit used, normally matching the GitHub workflow checkout shape
- dependency install or verification commands
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
