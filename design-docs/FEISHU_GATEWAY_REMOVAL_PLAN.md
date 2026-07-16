# Feishu Gateway Compatibility Removal Plan (3 Batches)

This plan removes `feishu_gateway_*` compatibility symbols safely in three
batches with explicit rollback checkpoints.

## Preconditions

Before starting Batch 1, ensure:

1. `grep "feishu_gateway_" src --include="*.v"` matches only
   `src/feishu_runtime.v` (already true at current state).
2. All runtime/admin callsites use `feishu_runtime_*` naming.
3. CI baseline is green:
   - `v -o vhttpd src`
   - `v test src/feishu_runtime_test.v`
   - `v test src/command_executor_test.v`
   - `make vhttpd`

---

## Batch 1 — Remove Deprecated Wrapper Functions ✅ COMPLETE

### Scope

Deleted 7 wrapper functions marked DEPRECATED in `src/feishu_runtime.v`:

- `feishu_gateway_json_field_string`
- `feishu_gateway_json_map_field`
- `feishu_gateway_build_message_content`
- `feishu_gateway_update_http_method`
- `feishu_gateway_delay_update_card_body`
- `feishu_gateway_event_summary`
- `feishu_gateway_callback_challenge`

### Verification

All passed at time of completion.

---

## Batch 2 — Rename Business Runtime Methods ✅ COMPLETE

### Scope

Renamed all 30 internal `feishu_gateway_*` App methods in `feishu_runtime.v`
to `feishu_runtime_*`, including ready/snapshot/send/update/buffer paths.

### Verification

All passed at time of completion.

---

## Batch 3 — Protocol Helper Namespace + Struct + Constant Rename ✅ COMPLETE

### What was done

Option B (strict naming) was chosen. All `feishu_gateway_*` symbols were renamed to
`feishu_runtime_*` across the entire codebase:

1. **22 struct types** renamed: `FeishuGateway*` → `FeishuRuntime*` (across 5 files)
2. **All free functions** renamed: `feishu_gateway_*` → `feishu_runtime_*`
3. **All constants** renamed: `feishu_gateway_*` → `feishu_runtime_*`
4. **1 App method** renamed: `admin_feishu_gateway_chats_snapshot` → `feishu_runtime_chats_snapshot`
5. **8 self-referencing alias wrappers** deleted (created by bulk rename)
6. **13 duplicate self-referencing constant aliases** deleted
7. **3 duplicate self-referencing wrapper functions** deleted
8. **1 stale comment** updated in `provider_registry.v`

### Remaining intentional compatibility shim

`capabilities['feishu_gateway']` in `admin_runtime.v` is kept as a backward-compatible
alias for downstream clients. Remove after downstream migration window closes.

### Verification

All passed:

- `make vhttpd` ✅
- `v test src/feishu_runtime_test.v` ✅
- `v test src/command_executor_test.v` ✅
- `grep feishu_gateway src/*.v` — only the intentional `capabilities['feishu_gateway']` alias remains ✅
- `grep FeishuGateway src/*.v` — 0 matches ✅

---

## Stop Conditions (Do Not Proceed If)

1. Any batch introduces behavior changes in runtime/admin outputs.
2. Build/test baseline fails and root cause is unclear.
3. Cross-file rename blast radius exceeds planned batch boundaries.

When stop condition triggers: revert current batch commit, regroup, and continue
with smaller slices.
