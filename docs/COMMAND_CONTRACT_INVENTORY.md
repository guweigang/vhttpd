# Command Contract Inventory

## Goal

This document catalogs the command families currently flowing from PHP workers
into `vhttpd`, highlights the main design problems, and proposes a migration
map toward a smaller normalized command contract.

It is intentionally inventory-first:

- what command shapes exist today
- which runtime consumes them
- which fields are actually meaningful
- how they should map into the next contract

The companion design draft is:

- [NORMALIZED_COMMAND_DRAFT.md](./NORMALIZED_COMMAND_DRAFT.md)

## Current Reality

Today, worker-returned commands are carried by one broad structure:

- `WorkerWebSocketUpstreamCommand`

That structure mixes several concerns:

- provider transport commands
- provider RPC control commands
- stream rendering commands
- runtime/session correlation fields
- provider-specific target fields

As a result, the current `type` namespace is not one clean taxonomy. It is a
blend of:

- action names
- provider names
- runtime control verbs
- implementation details

## Current Command Families

### 1. Codex Control Commands

These are not generic provider messaging commands. They directly drive the
Codex runtime state machine.

Observed commands:

- `codex.rpc.send`
- `codex.rpc.reply`
- `codex.turn.start`

Examples:

```json
{
  "type": "codex.rpc.send",
  "method": "thread/start",
  "params": "{\"cwd\":\"/tmp/demo\",\"model\":\"gpt-5.3-codex\"}",
  "stream_id": "codex:task_001"
}
```

```json
{
  "type": "codex.turn.start",
  "stream_id": "codex:task_001",
  "task_type": "ask",
  "prompt": "请帮我分析这个 bug",
  "metadata": {
    "thread_id": "thread_123",
    "cwd": "/tmp/demo"
  }
}
```

Problems:

- `codex.turn.start` is a runtime orchestration command, not a provider RPC.
- `metadata.thread_id` and `metadata.cwd` are semantically important, but not
  represented as first-class typed fields.
- `stream_id` is overloaded as both correlation key and runtime route key.

### 2. Feishu Message Commands

These commands target a concrete external platform and are partly declarative,
partly imperative.

Observed commands:

- `feishu.message.send`
- `feishu.message.update`
- `feishu.message.patch`
- `feishu.message.flush`

Examples:

```json
{
  "type": "feishu.message.send",
  "target_type": "chat_id",
  "target": "oc_xxx",
  "message_type": "interactive",
  "content": "{\"elements\":[{\"tag\":\"markdown\",\"content\":\"任务已启动\"}]}",
  "stream_id": "codex:task_001"
}
```

```json
{
  "type": "feishu.message.patch",
  "target": "om_xxx",
  "stream_id": "codex:task_001",
  "text": "第一段增量输出",
  "metadata": {
    "mode": "append"
  }
}
```

```json
{
  "type": "feishu.message.flush",
  "target": "om_xxx",
  "stream_id": "codex:task_001",
  "message_type": "interactive",
  "content": "{\"elements\":[{\"tag\":\"markdown\",\"content\":\"{{content}}\"}]}",
  "metadata": {
    "mode": "finish",
    "status": "completed"
  }
}
```

Problems:

- `patch` and `flush` are stream lifecycle operations disguised as provider
  message commands.
- `target` is sometimes explicit, sometimes inferred later from `stream_id`.
- `metadata.mode=append|finish` is behavior, not metadata.

### 3. Generic Provider Message Commands

Some providers are effectively handled by the generic upstream message path.

Observed shape:

- `*.message.send`
- `*.message.update`

Known example family:

- `ollama.message.send`

Example:

```json
{
  "type": "ollama.message.send",
  "target": "session_001",
  "message_type": "text",
  "content": "{\"text\":\"hello\"}"
}
```

Problems:

- `ollama` is currently named like a message platform, but semantically it may
  be closer to an upstream protocol provider.
- the taxonomy does not tell us whether a provider is message-oriented,
  RPC-oriented, or stream-oriented.

### 4. Worker Result Envelope

These are not commands themselves, but they are part of the interaction model:

- `handled`
- `error`
- `error_class`
- `commands[]`

Example:

```json
{
  "handled": true,
  "error": "",
  "commands": [
    {
      "type": "feishu.message.send",
      "target_type": "chat_id",
      "target": "oc_xxx",
      "message_type": "text",
      "content": "{\"text\":\"ok\"}"
    }
  ]
}
```

Problems:

- command success/failure and worker-dispatch success/failure are adjacent, but
  not clearly separated as protocol layers.

### 5. MCP Session Output

MCP is currently adjacent to this system, but not properly part of the same
command taxonomy.

MCP is mostly session/message queue oriented:

- queue pending messages
- flush via SSE
- manage session ids

Why this matters:

- MCP should probably reuse the normalized envelope model later.
- MCP should not be forced into the same provider-specific naming style as
  `feishu.message.*`.

## Missing But Implied Command Categories

The current system already needs several command categories that are only
represented indirectly today:

### Runtime Session Binding

Examples of behavior that exist today but do not have explicit commands:

- bind `stream_id -> thread_id`
- bind `stream_id -> response_message_id`
- clear invalid bound thread after recovery failure
- resolve target by stream

These are currently implemented through:

- runtime side effects
- DB lookups
- `metadata`
- fallback resolution logic

### Stream Lifecycle

Examples of behavior that exist today but are encoded as Feishu internals:

- append token chunk
- replace preview content
- finish stream successfully
- finish stream with error card

These should be first-class commands, not hidden behind:

- `feishu.message.patch`
- `feishu.message.flush`
- `feishu.message.update`

### Provider RPC Lifecycle

Examples:

- send protocol request
- send protocol reply
- cancel pending request
- acknowledge server request

Today only part of this exists explicitly through:

- `codex.rpc.send`
- `codex.rpc.reply`

## Why The Current Model Feels Messy

The main issue is not naming style alone. The real problem is that three
different abstraction layers are mixed into a single `type` field:

### Layer A. Domain / Runtime Control

Examples:

- `codex.turn.start`
- implicit stream/thread binding

### Layer B. Provider Protocol

Examples:

- `codex.rpc.send`
- `codex.rpc.reply`

### Layer C. Platform Delivery / Rendering

Examples:

- `feishu.message.send`
- `feishu.message.patch`
- `feishu.message.flush`

When one field carries all three layers:

- command routing becomes guessy
- metadata becomes a semantic escape hatch
- provider handlers accumulate special cases
- stream recovery logic leaks into app code

## Proposed Next Taxonomy

The next contract should stop using provider-prefixed type strings as the top
level taxonomy. The first split should be by action intent:

- `control.*`
- `provider.rpc.*`
- `provider.message.*`
- `stream.*`
- `session.*`

Examples:

- `codex.rpc.send` -> `provider.rpc.call`
- `codex.rpc.reply` -> `provider.rpc.reply`
- `feishu.message.send` -> `provider.message.send`
- `feishu.message.update` -> `provider.message.update`
- `feishu.message.patch` -> `stream.append`
- `feishu.message.flush` -> `stream.finish`
- implicit stream/thread bind -> `session.bind_thread`

## Mapping Table

| Current command | Problem | Proposed normalized kind |
| --- | --- | --- |
| `codex.rpc.send` | provider name embedded in type | `provider.rpc.call` |
| `codex.rpc.reply` | provider name embedded in type | `provider.rpc.reply` |
| `codex.turn.start` | runtime control mixed with provider namespace | `provider.rpc.call` plus explicit `session.bind_thread` or `session.use_thread` context |
| `feishu.message.send` | provider-specific top-level taxonomy | `provider.message.send` |
| `feishu.message.update` | provider-specific top-level taxonomy | `provider.message.update` |
| `feishu.message.patch` | stream operation hidden as message operation | `stream.append` |
| `feishu.message.flush` | stream lifecycle hidden as message lifecycle | `stream.finish` |
| `ollama.message.send` | unclear whether message or RPC | either `provider.message.send` or `provider.rpc.call` after provider review |

## Example Migration Cases

### Case 1. Start a New Codex Thread

Current:

1. `feishu.message.send`
2. `codex.rpc.send(method=thread/start)`
3. `codex.turn.start`

Proposed:

1. `provider.message.send(provider=feishu)`
2. `provider.rpc.call(provider=codex, method=thread/start)`
3. `provider.rpc.call(provider=codex, method=turn/start)`

Additional context should move into explicit fields:

- `thread_id`
- `cwd`
- `stream_id`

### Case 2. Append a Token Chunk to the Current Feishu Card

Current:

```json
{
  "type": "feishu.message.patch",
  "target": "om_xxx",
  "stream_id": "codex:task_001",
  "text": "hello",
  "metadata": {
    "mode": "append"
  }
}
```

Proposed:

```json
{
  "kind": "stream.append",
  "provider": "feishu",
  "correlation": {
    "stream_id": "codex:task_001"
  },
  "target": {
    "id": "om_xxx",
    "type": "message_id"
  },
  "payload": {
    "format": "text",
    "chunk": "hello"
  }
}
```

### Case 3. Finish a Stream Successfully

Current:

```json
{
  "type": "feishu.message.flush",
  "target": "om_xxx",
  "stream_id": "codex:task_001",
  "message_type": "interactive",
  "content": "{\"elements\":[{\"tag\":\"markdown\",\"content\":\"{{content}}\"}]}",
  "metadata": {
    "mode": "finish",
    "status": "completed"
  }
}
```

Proposed:

```json
{
  "kind": "stream.finish",
  "provider": "feishu",
  "correlation": {
    "stream_id": "codex:task_001"
  },
  "target": {
    "id": "om_xxx",
    "type": "message_id"
  },
  "payload": {
    "status": "completed",
    "render": {
      "message_type": "interactive",
      "template": "{\"elements\":[{\"tag\":\"markdown\",\"content\":\"{{content}}\"}]}"
    }
  }
}
```

### Case 4. Fail a Stream With a Friendly Error Message

Current:

- often expressed as `feishu.message.update`
- sometimes recovered through runtime fallback logic

Proposed:

```json
{
  "kind": "stream.fail",
  "provider": "feishu",
  "correlation": {
    "stream_id": "codex:task_001",
    "thread_id": "thread_123"
  },
  "payload": {
    "code": "thread_not_found",
    "message": "thread not found: thread_123",
    "user_visible": true
  }
}
```

### Case 5. Send a Plain Text Chat Reply Without Streaming

Current:

```json
{
  "type": "feishu.message.send",
  "target_type": "chat_id",
  "target": "oc_xxx",
  "message_type": "text",
  "content": "{\"text\":\"你好\"}"
}
```

Proposed:

```json
{
  "kind": "provider.message.send",
  "provider": "feishu",
  "target": {
    "id": "oc_xxx",
    "type": "chat_id"
  },
  "payload": {
    "message_type": "text",
    "body": {
      "text": "你好"
    }
  }
}
```

## Recommended Refactor Order

1. Freeze a normalized schema in docs first.
2. Add an internal `NormalizedCommand` in `vhttpd`.
3. Build adapters:
   - old worker command -> normalized command
   - normalized command -> provider/runtime handler
4. Move PHP command builders to the normalized model.
5. Remove direct app-side emission of `feishu.message.patch/flush`.

## Non-Goals For The First Refactor

- do not redesign MCP session protocol yet
- do not remove current commands immediately
- do not force all providers to look identical at runtime

The first goal is smaller and safer:

- make command intent explicit
- reduce metadata-driven semantics
- stop leaking Feishu stream internals into PHP worker apps
