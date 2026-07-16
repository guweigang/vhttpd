# Feishu Runtime Naming Migration — Complete

This document records the `feishu_gateway → feishu_runtime` naming migration
and its final status.

## Goal

Converge all Feishu-related symbols to `feishu_runtime_*` / `FeishuRuntime*`
naming, consistent with the architecture principle that Feishu is an
application-layer provider running on the vhttpd runtime — not a "gateway."

## Final Status: ✅ Migration Complete

All three batches of the removal plan have been executed and verified:

1. **Batch 1** — 7 deprecated `feishu_gateway_*` wrapper functions deleted
2. **Batch 2** — 30 `feishu_gateway_*` App methods renamed to `feishu_runtime_*`
3. **Batch 3** — 22 `FeishuGateway*` structs, all free functions, all constants,
   and remaining references renamed to `feishu_runtime_*` / `FeishuRuntime*`

### Current symbol state

| Category | Old naming | New naming | Status |
|---|---|---|---|
| Struct types | `FeishuGateway*` | `FeishuRuntime*` | ✅ 0 old references |
| App methods | `feishu_gateway_*` | `feishu_runtime_*` | ✅ 0 old references |
| Free functions | `feishu_gateway_*` | `feishu_runtime_*` | ✅ 0 old references |
| Constants | `feishu_gateway_*` | `feishu_runtime_*` | ✅ 0 old references |
| File names | `feishu_gateway.v` | `feishu_runtime.v` | ✅ renamed |
| Test files | `feishu_gateway_test.v` | `feishu_runtime_test.v` | ✅ renamed |

### Remaining intentional compatibility shim

One backward-compatible alias remains by design:

```v
// admin_runtime.v
capabilities['feishu_gateway'] = feishu_runtime_ready
```

This keeps downstream clients that check `capabilities.feishu_gateway` working
until they migrate to `capabilities.feishu_runtime`.

**Removal criteria**: remove after one release cycle with `feishu_runtime`
available, and after confirming no downstream client still reads
`capabilities.feishu_gateway`.

## Admin API Surface (Unchanged)

The following admin endpoints are stable and unaffected by the rename:

- `GET /admin/runtime/feishu`
- `GET /admin/runtime/feishu/chats`
- `POST /admin/runtime/feishu/messages`
- `POST /gateway/feishu/messages`

These use `feishu` (the provider name), not `feishu_gateway` or
`feishu_runtime` — they were always correct.

## Execution Reference

For step-by-step removal batches and rollback checkpoints, see:

- [FEISHU_GATEWAY_REMOVAL_PLAN.md](/Users/guweigang/Source/vhttpd/docs/FEISHU_GATEWAY_REMOVAL_PLAN.md)
