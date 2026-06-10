# Phase 2: Domain-Driven Restructuring Analysis

## Current State (Post-Phase 1)

Phase 1 successfully reduced `main.v` from ~18,000 to 924 lines by extracting technical layers.
However, domain logic remains fragmented across technical boundaries.

## Problem Diagnosis

### 1. Domain Knowledge Fragmentation

| Domain | Protocol Types (submodule) | Business Logic (main) | Lines Split |
|--------|---------------------------|----------------------|-------------|
| feishu | feishu/types.v, state.v, http.v, helpers.v (~47KB) | feishu_runtime.v (1,265 lines) | 1,229 logic + 36 routes |
| codex | codex/types.v, state.v, rpc.v, runtime.v (~20KB) | codex_runtime.v (1,033 lines) | 1,033 logic + 0 routes |
| openai | openai/types.v, chunk.v, frame_mapper.v (~29KB) | openai_runtime.v (1,536 lines) | 1,536 logic + 0 routes |
| mcp | mcp_protocol/types.v, state.v, helpers.v (~13KB) | mcp_runtime.v (492 lines) | ~460 logic + 3 routes |

**Root Cause**: Submodules contain only types/utilities; actual business logic stays in main.

### 2. vjsx Identity Conflict

```
executor/inproc_vjsx_executor.v  (173.8KB)  → vjsx as "executor engine"
plugin/runtime.v                   (2.2KB)   → vjsx as "plugin runtime"
```

vjsx is BOTH executor engine AND plugin runtime. Splitting by technical layer creates identity confusion.

### 3. Correct DDD Organization

```
src/
  main.v                          → Pure orchestration (routes + startup)

  domain/
    feishu/                       → Complete Feishu domain
      protocol/                   → Types, state, HTTP helpers
      runtime.v                   → Business logic (from feishu_runtime.v)
      card_bridge.v               → Card bridge (from feishu_card_bridge.v)
      handler.v                   → Command handlers
      upstream.v                  → WebSocket upstream

    codex/                        → Complete Codex domain
    openai/                       → Complete OpenAI domain
    mcp/                          → Complete MCP domain
    db/                           → Complete DB domain

  infra/
    vjsx/                         → Unified vjsx runtime (executor + plugin)
    executor/                     → Logic executor abstractions
    transport/                    → Generic transport protocols
    upstream/                     → Stream abstraction
    ws/                           → WebSocket generic
    worker/                       → Worker backend
    plugin/                       → Plugin framework (thin)
    admin/                        → Admin runtime context
    dispatch/                     → Dispatch factories
    server_lifecycle/             → Server lifecycle

  app/
    main.v                        → Thin route wrappers calling domain/
```

## Implementation Plan

### Phase 2.1: Feishu Domain Migration (First Phase)
- Extract feishu_runtime.v business logic (1,229 lines) to feishu/domain_runtime.v
- Keep routes in main as thin wrappers
- Move feishu_card_bridge.v into feishu/card_bridge.v
- Move handler logic into feishu/handler.v

### Phase 2.2: Codex Domain Migration
- Extract codex_runtime.v (1,033 lines) to codex/runtime.v
- Move test files into codex/

### Phase 2.3: OpenAI Domain Migration
- Extract openai_runtime.v (1,536 lines) to openai/runtime.v
- Move gateway integration into openai/

### Phase 2.4: MCP Domain Migration
- Extract mcp_runtime.v (492 lines) to mcp/runtime.v

### Phase 2.5: vjsx Identity Unification
- Merge executor/inproc_vjsx_executor.v + plugin/runtime.v into infra/vjsx/

### Phase 2.6: Final Cleanup
- Remove *_runtime.v from main
- Ensure all routes are thin wrappers
- Verify build passes
