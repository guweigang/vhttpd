# vhttpd Refactor Action Plan

This plan turns the prioritized findings in [`CODE_REVIEW_2026_08_06.md`](CODE_REVIEW_2026_08_06.md) §4 into a concrete, sequenced work list. Each milestone lists its scope, the files it touches, the verification signal, and the rollback strategy.

Track this file as milestones complete; cross-link any deviation back to the review.

---

## Milestone 0 — Preparation (½ day)

**Goal:** baseline the current state so we can measure each milestone.

- [ ] Record current `vhttpd` binary size and build time on each platform from CI artifact logs.
- [ ] Capture `make test-fast` baseline wall-clock and pass/fail counts.
- [ ] Run `make prod` locally; record binary size, RSS at idle, and a single-request p50/p99.
- [ ] Tag the current commit as `pre-refactor-baseline`.

**Files touched:** none (read-only).

**Verification:** baseline numbers checked into a `docs/perf-baseline.md`.

---

## Milestone 1 — Replace `unsafe { voidptr(&app) }` bridge (2–3 days)

**Goal:** delete `executor_bridge.v` and remove the V-codegen-bug workaround.

**Scope:** the entire `executor.AppFacade` interface in `src/executor/`.

**Plan:**

1. Read every `AppFacade` method in `src/executor/app_facade*.v`. Catalog the fields of `App` it transitively reads.
2. Replace each method's signature with concrete-value arguments (e.g. `runtime_config_json string`, `plan_json string`, `read_timeout_ms_for_kind fn(string) int`).
3. Move the call sites that build the `AppFacade` to pass those values directly. Most call sites live in `src/app_runtime_builder.v` and `src/executor/`.
4. Delete `src/executor_bridge.v` and its 194 lines of `unsafe { &App(w.app_ptr) }` blocks.
5. Add a `grep -r "voidptr(&app)\|unsafe { &App" src/` check in `scripts/lint_safety.sh` so the pattern cannot reappear unnoticed.

**Files touched (estimate):** `src/executor/app_facade*.v`, `src/app_runtime_builder.v`, `src/executor_bridge.v` (delete), `scripts/lint_safety.sh` (new).

**Verification:**

- `make prod` succeeds on linux-amd64 + macos-arm64.
- `make test-fast` passes with no new failures.
- `grep -r "unsafe { &App\|voidptr(&app)" src/` returns nothing.
- `worker_backend_dispatch_*` integration tests pass (they go through the AppFacade).

**Rollback:** revert the merge commit. The bridge is isolated to one file so the revert should be clean.

**Risk:** HIGH (touches the interface used by hot paths). Mitigation: keep the change behind a single feature branch; merge only after `test-all` passes locally and CI is green for both platforms.

---

## Milestone 2 — `App` decomposition: `ExecutorHost` + `worker_backend` (1 week)

**Goal:** break the circular dependency that blocks Phase 2.1 of `TODO_REFACTOR.md`.

**Scope:** `src/executor/`, `src/worker/`, `src/worker_backend_*.v`.

**Plan:**

1. Define `ExecutorHost` interface in `src/executor/host.v`:
   - methods that today read `app.engines.*`, `app.protocols.*`, etc.
   - this is the seam the `unsafe` bridge currently fakes.
2. Change `LogicExecutor` interface methods from `fn (mut app App)` to `fn (mut host ExecutorHost)`.
3. For `worker_backend_*.v`: introduce `WorkerState` struct holding `pool / queue / lifecycle / drain` fields. Move methods from `App` to `WorkerState` where they don't need other subsystems.
4. Add `WorkerState` as a `&mut` field on `App` (one transitional step before Milestone 3 removes it from `App` entirely).
5. Run `make test-fast` after each file move; commit green.

**Files touched (estimate):** ~15 files. `src/executor/host.v` (new), `src/worker/connection.v`, `src/worker_backend_*.v` (12 files), `src/command_*.v` (interface call sites).

**Verification:**

- `make test-fast` green.
- `grep -c "fn (mut app App)" src/worker_backend_*.v` drops by at least 50%.
- `wc -l src/main.v` should not increase.

**Rollback:** revert merge. The interface extraction is additive — old `App` methods can stay until the new path is fully wired.

**Risk:** MED. Mostly mechanical; the hard part is keeping the lock order in `src/server.v:4-24` intact.

---

## Milestone 3 — `App` decomposition: `command` and `feishu` (1 week)

**Goal:** continue Phase 2.1 modularization; bring `command_handlers.v` off `App`.

**Scope:** `src/command/`, `src/feishu/`, `src/feishu_card_bridge_*.v`.

**Plan:**

1. Define `CommandContext` and `FeishuState` structs that bundle the state `command_handlers.v` and `feishu_card_bridge_*.v` read off `App`.
2. Replace `app &App = unsafe { nil }` global in `src/command_handlers.v` with explicit injection.
3. Replace the `unsafe { nil }` placeholders in `src/feishu_card_bridge_*.v` (5+ sites) with struct fields initialized through a builder.
4. After both done: drop the `unsafe { nil }` pattern from `src/engine_runtime.v:9` (the `emit_fn` global) — give `EngineRuntime` an explicit callback field.

**Files touched (estimate):** ~12 files.

**Verification:**

- `grep -rn "unsafe { nil }" src/` shrinks by at least 8 sites.
- `make test-codexbot-fast` green (the integration tests cover feishu + command paths).
- `make test-fast` green.

**Rollback:** revert merge; the `unsafe { nil }` global pattern remains functional.

**Risk:** MED. The lock order doc in `server.v` is the safety net — keep it updated as fields move.

---

## Milestone 4 — Consolidate logging (½ day)

**Goal:** merge `runtime_trace` (`src/main.v:33`) and `app.emit` (`src/app_composition_runtime.v:74`) into a single log path. Fixes finding 2.4 and 2.8 in one move.

**Scope:** `src/main.v`, `src/app_composition_runtime.v`, `src/logging/`.

**Plan:**

1. Add a `runtime_trace_path` config field (optional). When unset, trace events flow through `app.emit` only.
2. Delete the `runtime_trace` function in `src/main.v` and its 4 hardcoded labels. Replace each call site with `app.emit('runtime.trace', fields)`.
3. Extend `app.emit` to handle trace events (`server.started`, `admin.started`, etc.) by writing them to `control.event_log` instead of `/tmp/vhttpd_runtime_trace.log`.
4. Document the new log path in `docs/OVERVIEW.md` (fixes 2.10).
5. Add a `VHTTPD_LOG_FORMAT=json` flag (also addresses Phase 4 of `TODO_REFACTOR.md`).

**Files touched:** `src/main.v`, `src/app_composition_runtime.v`, `src/config/runtime_config.v`, `docs/OVERVIEW.md`.

**Verification:**

- `grep -n "/tmp/vhttpd_runtime_trace" src/` returns nothing.
- Boot the binary, hit a few endpoints, confirm `control.event_log` contains the same event names that `runtime_trace` used to log.
- `make test-fast` green.

**Rollback:** revert merge; the original two-path system still works.

**Risk:** LOW. The only behavioral change is where trace events land; both paths remain functional during the transition.

---

## Milestone 5 — CI: e2e + inproc on every PR (½ day)

**Goal:** catch e2e regressions on PR instead of waiting for a manual run.

**Scope:** `.github/workflows/vhttpd-binaries.yml`, `tests/e2e/run.sh`, `Makefile`.

**Plan:**

1. Add a `test-inproc-fast` job to the CI matrix that runs `make test-codexbot-fast V_CC=cc` (skip the 1103-line lifecycle test for PR, run it nightly).
2. Add a `test-e2e` job that runs `make test-e2e` after `make prod`. Use the built binary, not `vhttpd` already on PATH.
3. Add a nightly `nightly-full` workflow on `schedule: cron: '0 3 * * *'` that runs `make test-all` and `make test-codexbot-lifecycle`.
4. Update `sync-vphp-package.yml` trigger to include `php/app/**` (or document the deliberate exclusion).

**Files touched:** `.github/workflows/vhttpd-binaries.yml` (add jobs), `.github/workflows/nightly-full.yml` (new), `.github/workflows/sync-vphp-package.yml` (paths).

**Verification:**

- Open a throwaway PR; observe both new jobs run.
- Nightly job fires at 03:00 UTC and produces artifacts.
- `make test-all` exits 0 in the nightly job.

**Rollback:** disable the workflow files via `gh workflow disable`.

**Risk:** LOW. CI-only changes; no production surface affected.

---

## Milestone 6 — Non-blocking backoff (1 day)

**Goal:** replace `time.sleep` in request/connection paths with non-blocking backoff. Addresses finding 2.6.

**Scope:** 10 files listed in the review.

**Plan:**

1. Convert each `time.sleep(N seconds)` in `feishu_card_bridge_client_runtime.v:112` and `:161` to a 5-step backoff with a check for shutdown in between.
2. Convert `feishu_provider_connection_runtime.v:31` to `select { <-time.after(...) }` if V's stdlib supports it, otherwise a poll loop that respects a `done chan`.
3. For the small (200ms–500ms) sleeps in `codex_provider_websocket_runtime.v`, `mcp_session_stream_runtime.v`, etc.: keep `time.sleep` but add a comment that they're bounded polling and verify the total worst-case latency is acceptable.

**Files touched:** ~10 files.

**Verification:**

- `make test-codexbot-fast` green.
- Manual: open a feishu card bridge, kill the upstream, observe the reconnect loop without freezing the websocket send path for > 1s at a time.

**Rollback:** revert merge; the time.sleep calls revert.

**Risk:** LOW. Behavior change is bounded.

---

## Milestone 7 — v1 config deprecation (½ day)

**Goal:** surface the v1 → v2 path so users have a timeline.

**Scope:** `src/config/v1_plan_compat.v`, `vhttpd.toml`, README.

**Plan:**

1. Mark every v1 field that gets translated to v2 in `v1_plan_compat.v` with `@[deprecated: 'use v2 plan; v1 fields will be removed 2027-02']`.
2. Add a "Deprecation Timeline" section to `README.md` listing which keys are deprecated and the removal date.
3. Move `src/config/v1_plan_compat.v` and `src/config/v1_plan_compat_test.v` into `src/config/compat/v1/` so the v2 path is the primary layout.
4. Update `vhttpd.toml` to use v2 syntax; keep the file at `examples/v1-vhttpd.toml` for reference.

**Files touched:** `src/config/v1_plan_compat.v`, `vhttpd.toml`, `README.md`, directory moves.

**Verification:**

- `make test-fast` green (compat tests still pass).
- README deprecation section renders correctly in `mkdocs serve`.

**Rollback:** revert merge.

**Risk:** LOW. Pure documentation + file moves; runtime unchanged.

---

## Sequencing

| Order | Milestone | Depends on | Owner signal |
|---|---|---|---|
| 0 | Preparation | — | baseline docs in `docs/perf-baseline.md` |
| 1 | Drop unsafe bridge | M0 | no `unsafe { &App(` in src |
| 2 | ExecutorHost + worker_backend | M1 | `grep -c "fn (mut app App)" src/worker_backend_*.v` ↓ 50% |
| 3 | command + feishu decomposition | M1, M2 | `grep -rn "unsafe { nil }" src/` ↓ 8 sites |
| 4 | Logging consolidation | — | no `/tmp/vhttpd_runtime_trace.log` |
| 5 | CI e2e + inproc | — | new jobs in CI matrix |
| 6 | Non-blocking backoff | — | no `time.sleep` ≥ 1s in hot paths |
| 7 | v1 deprecation | — | `@[deprecated]` markers + README section |

**Independent tracks:** M4, M5, M6, M7 can run in parallel. M1 → M2 → M3 must be sequential because they each remove a layer of `App` coupling.

**Target end state:**

- `App` struct holds only `DataPlaneRuntime` + `ControlPlaneRuntime` + `veb` boilerplate; sub-runtimes are separate structs.
- No `unsafe { &App(` in production code.
- No `unsafe { nil }` in `src/command_handlers.v` or `src/admin_server.v`.
- No hardcoded `/tmp` paths.
- One log path through `app.emit`.
- v1 deprecation public; v2 is the default config example.

---

## Cross-References

- `TODO_REFACTOR.md` Phase 2.2 — `App` decomposition (M2, M3)
- `TODO_REFACTOR.md` Phase 3 — memory safety (M1, M3)
- `TODO_REFACTOR.md` Phase 4 — JSON structured log (M4)
- `TODO_REFACTOR.md` Phase 5 — Makefile modularization (out of scope here)
- `CODE_REVIEW_2026_08_06.md` — the diagnostic that produced this plan
