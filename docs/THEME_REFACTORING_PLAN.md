# vhttpd Theme-Based Reorganization Plan

This document describes the planned reorganization of vhttpd from an implementation-centric structure to a theme-centric structure. It is a companion to [ARCHITECTURE_REFACTOR_BASELINE.md](ARCHITECTURE_REFACTOR_BASELINE.md).

## Motivation

vhttpd is an AI-era gateway. Its natural organizational axes are **roles** (plugin, executor, upstream, worker, api), not **implementations** (openai, vjsx, php, codex, feishu).

Current problems with implementation-centric organization:

1. A single implementation (e.g. openai) spans multiple roles (API protocol + upstream protocol), scattering related code
2. Adding a new implementation (e.g. python executor) requires touching multiple unrelated directories
3. Same-role implementations are hard to compare horizontally (finding all plugins requires looking in vjsx/, feishu/, codex/, etc.)

## Design Principles

1. **Organize by theme (role)**, not by implementation (language/protocol)
2. **Physical split** when one implementation plays multiple roles (e.g. vjsx as both plugin and executor)
3. **Shared base** gets its own module when multiple roles need it (e.g. vjsx/core)
4. **Symmetry** between api (outbound to clients) and upstream (inbound from backends) — same protocol can appear on both sides
5. **Minimal disruption** — existing V implementations stay working; reorganization is structural, not behavioral

## Theme Definitions

| Theme | Definition | Examples |
|-------|-----------|----------|
| **api** | Protocol endpoints vhttpd exposes to clients | openai, websocket, mcp |
| **upstream** | Connections vhttpd makes to backends | openai, ollama, codex, feishu, paseo, mcp |
| **plugin** | Lifecycle hooks embedded in vhttpd's request processing | vjsx |
| **executor** | Independent execution engines | php, vjsx |
| **worker** | General worker process management (includes executor process pools) | php-fpm pool, generic workers |
| **provider** | Provider registration framework | spec, instance, context |

### Plugin vs Executor Boundary

- **Plugin**: participates in vhttpd's request handling lifecycle. Called at various stages (on_request, on_upstream_response, on_response). Has deep access to vhttpd's internal context (request, response, upstream connections).
- **Executor**: independent execution engine. Receives an execution request, returns a result. Does not care about vhttpd's request lifecycle. Only needs input/output.

### api vs upstream Symmetry

The same protocol can appear on both sides:

| Protocol | api (exposed to clients) | upstream (connect to backends) |
|----------|--------------------------|-------------------------------|
| openai | `/v1/chat/completions` endpoint | Connect to OpenAI-compatible API |
| websocket | WebSocket endpoint for clients | Connect to upstream WebSocket service |
| mcp | MCP endpoint for clients to call tools | Connect to upstream MCP server for tools |
| ollama | (not exposed directly) | Connect to local Ollama server |

## Target Directory Structure

```
api/                              # Protocol endpoints exposed to clients
  openai/
    runtime.v                     # Current src/openai_runtime.v
    protocol/                     # Current src/openai/ (shared protocol utilities)
      types.v
      chunk.v
      frame_mapper.v
      plan_builder.v
      response_builder.v
      registry.v
      helpers.v
      path.v
  websocket/                      # Future: WebSocket API endpoint
  mcp/                            # Future: MCP API endpoint

upstream/                         # Connections to backends
  transport/                      # How to connect (transport layer)
    websocket/                    # Current src/transport/ (websocket parts)
    stream/
    http/
    stdio/                        # For MCP
  provider/                       # What to connect to (business protocol layer)
    openai/                       # OpenAI HTTP backend (if specific code needed)
    ollama/                       # Ollama backend
      provider.v                  # Current OllamaProvider (from provider_registry.v)
      types.v                     # Current OllamaNdjsonRow (from upstream/types.v)
    codex/                        # Current src/codex/
      types.v
      runtime.v
      rpc.v
      state.v
    feishu/                       # Current src/feishu/
      api.v
      bridge.v
      helpers.v
      http.v
      state.v
      types.v
    paseo/                        # Future
    mcp/                          # MCP as upstream provider
  ndjson_streamer.v               # Current upstream/streamer.v (renamed, generic logic)
                                  # ExecState, Io stay here; OllamaNdjsonRow moves to ollama/

plugin/                           # Lifecycle hooks
  vjsx/                           # vjsx plugin implementation

executor/                         # Execution engines
  php/
  vjsx/

worker/                           # General worker process management
                                  # Current src/worker/ + worker_backend_*.v

provider/                         # Provider registration framework (unchanged)
  spec.v
  instance.v
  context.v
  config.v
  types.v
  runtime_dispatch.v

vjsx/                             # vjsx language layer
  core/                           # Shared base: parser, compiler, runtime foundation
                                  # Used by plugin/vjsx and executor/vjsx

plugins/                          # Future: vjsx-implemented plugins/providers
  codex.vjsx                      # vjsx implementation of codex protocol
  feishu.vjsx                     # vjsx implementation of feishu protocol
  paseo.vjsx                      # vjsx implementation of paseo protocol
```

## Migration Mapping

| Current Location | Target Location | Notes |
|-----------------|-----------------|-------|
| `src/openai/` | `api/openai/protocol/` | Shared OpenAI protocol utilities |
| `src/openai_runtime.v` | `api/openai/runtime.v` | OpenAI API endpoint handler |
| `src/codex/` | `upstream/provider/codex/` | Codex upstream provider |
| `src/feishu/` | `upstream/provider/feishu/` | Feishu upstream provider |
| `OllamaProvider` (in `provider_registry.v:215`) | `upstream/provider/ollama/provider.v` | Extract from provider_registry |
| `OllamaNdjsonRow` etc. (in `upstream/types.v`) | `upstream/provider/ollama/types.v` | ollama-specific types |
| `upstream/streamer.v` | `upstream/ndjson_streamer.v` | Rename; keep generic NDJSON logic |
| `upstream/types.v` (ExecState, Io) | `upstream/ndjson_streamer.v` | Merge; these are generic |
| `src/transport/` | `upstream/transport/` | Transport layer |
| `src/provider/` | `provider/` | Provider framework (unchanged) |
| `src/worker/` + `worker_backend_*.v` | `worker/` | Worker process management |

## Key Decisions

### 1. vjsx Physical Split

vjsx plays two roles (plugin + executor), so it is physically split:

```
vjsx/core/          # Shared base (parser, compiler, runtime)
plugin/vjsx/        # vjsx as lifecycle hook
executor/vjsx/      # vjsx as execution engine
```

`vjsx/core/` is shared between `plugin/vjsx` and `executor/vjsx`. Currently `api/vjsx` does not exist, so no other consumers.

### 2. openai/ Module Placement

The `openai/` module is used by both:
- `api/openai/` (API endpoint) — for request parsing, response formatting
- `upstream/provider/ollama/` (and future openai provider) — for protocol conversion

Decision: place it under `api/openai/protocol/`. It is fundamentally the "OpenAI API protocol" layer. Upstream providers import it as `api.openai.protocol` for protocol conversion.

### 3. NDJSON Streamer

`upstream/streamer.v` contains generic NDJSON stream processing logic (line parsing, field extraction, SSE output). Despite ollama-specific naming (`OllamaNdjsonRow`), the implementation is generic.

Decision:
- Rename to `upstream/ndjson_streamer.v`
- Keep generic types (`ExecState`, `Io`) in this file
- Move ollama-specific types (`OllamaNdjsonRow`, `OllamaNdjsonMessage`) to `upstream/provider/ollama/types.v`

### 4. vjsx-Implemented Providers (Future)

codex/feishu/paseo business protocols are currently implemented in V. Future plan: implement them in vjsx (like paseo).

Decision: vjsx implementations go in `plugins/` directory, loaded at runtime. They are separate from the V implementations in `upstream/provider/`.

### 5. MCP Dual Role

MCP appears on both sides:
- `upstream/provider/mcp/` — vhttpd connects to upstream MCP servers for tools
- `api/mcp/` — vhttpd exposes MCP endpoint for clients

These are independent implementations with different concerns.

## Open Questions

### 1. Core/Kernel Naming

The vhttpd core engine (request handling, routing, lifecycle) needs a home. Options:
- `core/` — generic, clear
- `kernel/` — more specific, but "kernel" already appears in code (`kernel_dispatch.v`)
- `engine/` — another option

**TBD** — needs further discussion.

### 2. Config Directory

Configuration parsing needs a home. Options:
- `config/` — already exists at `src/config/`
- Keep at top level

**TBD** — likely keep current `config/`.

### 3. CLI Entry Point

Command-line entry point needs a home. Options:
- `cli/` — new top-level directory
- `cmd/` — Go-style
- Keep `main.v` at root

**TBD** — needs further discussion.

### 4. Shared Utilities

Logging, metrics, jsonutils, etc. Options:
- `common/` or `shared/` — top-level shared utilities
- Keep分散 in各模块 — each module has its own utils

**TBD** — current `src/jsonutils/`, `src/logging/`, `src/stats/` suggest some consolidation already happening.

### 5. codex_runtime.v, feishu_runtime.v Placement

These files at `src/` root contain runtime integration code. Options:
- Move into `upstream/provider/codex/runtime.v`
- Keep at root as integration glue
- Move to `provider/` as provider runtime adapters

**TBD** — needs analysis of their role.

## Migration Sequence

Suggested order (minimal disruption, each step independently testable):

### Phase 1: Upstream Provider Consolidation

1. Create `upstream/provider/ollama/` directory
2. Extract `OllamaProvider` from `provider_registry.v` into `upstream/provider/ollama/provider.v`
3. Move `OllamaNdjsonRow` etc. from `upstream/types.v` to `upstream/provider/ollama/types.v`
4. Rename `upstream/streamer.v` to `upstream/ndjson_streamer.v`
5. Merge `upstream/types.v` (ExecState, Io) into `upstream/ndjson_streamer.v`
6. Update imports across codebase
7. Test: all existing functionality works

### Phase 2: Provider Directory Migration

1. Create `upstream/provider/codex/` directory
2. Move `src/codex/*` to `upstream/provider/codex/`
3. Update module declaration from `module codex` to `module codex` (no change needed if V supports nested modules)
4. Update imports across codebase
5. Repeat for `feishu/`
6. Test: all existing functionality works

### Phase 3: API Reorganization

1. Create `api/openai/` directory
2. Move `src/openai_runtime.v` to `api/openai/runtime.v`
3. Move `src/openai/` to `api/openai/protocol/`
4. Update imports across codebase
5. Test: all existing functionality works

### Phase 4: Transport and Worker

1. Create `upstream/transport/` directory
2. Move relevant parts of `src/transport/` to `upstream/transport/`
3. Consolidate `worker_backend_*.v` into `worker/`
4. Test: all existing functionality works

### Phase 5: Plugin and Executor

1. Create `plugin/` and `executor/` directories
2. Identify vjsx-related code and split into `plugin/vjsx/` and `executor/vjsx/`
3. Create `vjsx/core/` for shared base
4. Test: all existing functionality works

### Phase 6: Core and Utilities

1. Decide on `core/` vs `kernel/` naming
2. Move core engine code
3. Consolidate shared utilities
4. Test: all existing functionality works

## Success Criteria

- [ ] Each theme directory contains only code relevant to that theme
- [ ] Adding a new provider (e.g. python) requires changes only in `upstream/provider/python/`
- [ ] Adding a new executor (e.g. python) requires changes only in `executor/python/`
- [ ] api and upstream are symmetric and independent
- [ ] vjsx code is split by role (plugin vs executor) with shared core
- [ ] All existing tests pass after each phase
- [ ] No behavioral changes — reorganization is structural only

## References

- [ARCHITECTURE_REFACTOR_BASELINE.md](ARCHITECTURE_REFACTOR_BASELINE.md) — current state and earlier refactor direction
- [TODO_REFACTOR.md](../TODO_REFACTOR.md) — outstanding refactor tasks
- [REPO_SPLIT_NOTES.md](../REPO_SPLIT_NOTES.md) — earlier repo split notes
