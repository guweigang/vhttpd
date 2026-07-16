# Normalized Command Draft

## Goal

This document proposes the next internal command contract between workers and
`vhttpd`.

It is designed to replace the current flat mixed-shape command model with a
small number of explicit command kinds plus typed payloads.

The draft is intentionally practical:

- preserve current use cases
- reduce ambiguity
- support gradual compatibility
- make provider-specific behavior live below the contract, not inside it

Related inventory:

- [COMMAND_CONTRACT_INVENTORY.md](./COMMAND_CONTRACT_INVENTORY.md)

## Design Principles

### 1. Command kind should express intent first

The top-level `kind` should answer:

- what action is being requested?

Not:

- which provider happens to consume it?

### 2. Provider should be a field, not a namespace prefix

Bad:

- `feishu.message.send`
- `codex.rpc.send`
- `ollama.message.send`

Better:

- `kind=provider.message.send`, `provider=feishu`
- `kind=provider.rpc.call`, `provider=codex`

### 3. Correlation should not carry hidden behavior

IDs like `stream_id`, `thread_id`, `turn_id`, `message_id` should help route,
trace, and recover. They should not implicitly change command semantics.

### 4. Stream behavior should be a first-class concept

Appending a chunk and finishing a stream are not Feishu-only concepts.

The contract should say:

- append
- replace
- finish
- fail

`vhttpd` can then decide whether Feishu needs:

- patch buffer
- flush
- full replace

### 5. Metadata should be optional, not semantic core

If a field changes behavior, it should not live in `metadata`.

Bad examples:

- `metadata.mode=append`
- `metadata.mode=finish`
- `metadata.thread_id`
- `metadata.cwd`

These should become typed fields.

## Proposed Envelope

```json
{
  "version": "1",
  "kind": "provider.message.send",
  "provider": "feishu",
  "correlation": {
    "stream_id": "codex:task_001",
    "task_id": "task_001",
    "thread_id": "thread_001",
    "turn_id": "turn_001",
    "request_id": "req_001"
  },
  "target": {
    "id": "oc_xxx",
    "type": "chat_id"
  },
  "payload": {
    "message_type": "text",
    "body": {
      "text": "hello"
    }
  },
  "meta": {
    "source": "codexbot-app"
  }
}
```

## Top-Level Fields

### `version`

Protocol version for the command shape.

Initial value:

- `"1"`

### `kind`

Normalized action type.

Examples:

- `provider.rpc.call`
- `provider.rpc.reply`
- `provider.message.send`
- `provider.message.update`
- `stream.append`
- `stream.finish`
- `stream.fail`
- `session.bind`
- `session.clear`

### `provider`

The provider adapter that should interpret the command.

Examples:

- `feishu`
- `codex`
- `ollama`
- `discord`

May be empty only for provider-independent commands such as:

- `control.log`

### `correlation`

Optional correlation keys for tracing and recovery.

Fields:

- `stream_id`
- `task_id`
- `thread_id`
- `turn_id`
- `request_id`
- `session_id`

Rule:

- these fields must never be required to infer command kind

### `target`

Resolved or partially resolved command destination.

Fields:

- `id`
- `type`

Examples:

```json
{ "id": "oc_xxx", "type": "chat_id" }
```

```json
{ "id": "om_xxx", "type": "message_id" }
```

```json
{ "id": "thread_001", "type": "thread_id" }
```

### `payload`

Kind-specific structured body.

This must be the only place for action-specific fields.

### `meta`

Non-semantic annotations:

- source app name
- debug labels
- metrics hints

Rule:

- changing `meta` must not change command behavior

## Command Kinds

## 1. `provider.rpc.call`

Send a protocol call to an upstream provider.

Payload fields:

- `method`
- `params`

Example: start a Codex thread

```json
{
  "version": "1",
  "kind": "provider.rpc.call",
  "provider": "codex",
  "correlation": {
    "stream_id": "codex:task_001",
    "task_id": "task_001"
  },
  "payload": {
    "method": "thread/start",
    "params": {
      "cwd": "/tmp/demo",
      "model": "gpt-5.3-codex",
      "approvalPolicy": "never",
      "sandbox": "workspace-write"
    }
  }
}
```

Example: resume a Codex thread

```json
{
  "version": "1",
  "kind": "provider.rpc.call",
  "provider": "codex",
  "correlation": {
    "stream_id": "codex:task_002",
    "thread_id": "thread_123"
  },
  "payload": {
    "method": "thread/resume",
    "params": {
      "threadId": "thread_123"
    }
  }
}
```

Example: request Codex thread list

```json
{
  "version": "1",
  "kind": "provider.rpc.call",
  "provider": "codex",
  "correlation": {
    "stream_id": "codex:list_001"
  },
  "payload": {
    "method": "thread/list",
    "params": {
      "cwd": "/tmp/demo",
      "limit": 10
    }
  }
}
```

## 2. `provider.rpc.reply`

Reply to an upstream server-initiated request.

Payload fields:

- `id`
- `result`

Example:

```json
{
  "version": "1",
  "kind": "provider.rpc.reply",
  "provider": "codex",
  "payload": {
    "id": "rpc_991",
    "result": {
      "approved": true
    }
  }
}
```

## 3. `provider.message.send`

Send a provider-native message.

Payload fields:

- `message_type`
- `body`

Example: Feishu plain text

```json
{
  "version": "1",
  "kind": "provider.message.send",
  "provider": "feishu",
  "target": {
    "id": "oc_xxx",
    "type": "chat_id"
  },
  "payload": {
    "message_type": "text",
    "body": {
      "text": "任务已启动"
    }
  }
}
```

Example: Feishu interactive card

```json
{
  "version": "1",
  "kind": "provider.message.send",
  "provider": "feishu",
  "correlation": {
    "stream_id": "codex:task_001"
  },
  "target": {
    "id": "oc_xxx",
    "type": "chat_id"
  },
  "payload": {
    "message_type": "interactive",
    "body": {
      "elements": [
        {
          "tag": "markdown",
          "content": "⚙️ **任务已启动**"
        }
      ]
    }
  }
}
```

Example: future Discord message

```json
{
  "version": "1",
  "kind": "provider.message.send",
  "provider": "discord",
  "target": {
    "id": "channel_001",
    "type": "channel_id"
  },
  "payload": {
    "message_type": "text",
    "body": {
      "text": "hello from worker"
    }
  }
}
```

## 4. `provider.message.update`

Replace or update an existing provider-native message.

Payload fields:

- `message_type`
- `body`

Example: replace a Feishu card with error content

```json
{
  "version": "1",
  "kind": "provider.message.update",
  "provider": "feishu",
  "target": {
    "id": "om_xxx",
    "type": "message_id"
  },
  "correlation": {
    "stream_id": "codex:task_001"
  },
  "payload": {
    "message_type": "interactive",
    "body": {
      "elements": [
        {
          "tag": "markdown",
          "content": "❌ **任务失败**"
        }
      ]
    }
  }
}
```

## 5. `stream.append`

Append incremental output to an active logical stream.

Payload fields:

- `format`
- `chunk`

Example: text chunk

```json
{
  "version": "1",
  "kind": "stream.append",
  "provider": "feishu",
  "correlation": {
    "stream_id": "codex:task_001",
    "thread_id": "thread_001",
    "turn_id": "turn_001"
  },
  "target": {
    "id": "om_xxx",
    "type": "message_id"
  },
  "payload": {
    "format": "text",
    "chunk": "第一段内容"
  }
}
```

Example: markdown chunk

```json
{
  "version": "1",
  "kind": "stream.append",
  "provider": "feishu",
  "correlation": {
    "stream_id": "codex:task_002"
  },
  "payload": {
    "format": "markdown",
    "chunk": "\n- 新增列表项"
  }
}
```

Example: structured partial output for a future rich client

```json
{
  "version": "1",
  "kind": "stream.append",
  "provider": "websocket",
  "correlation": {
    "stream_id": "stream_ui_001"
  },
  "payload": {
    "format": "json_patch",
    "chunk": {
      "op": "add",
      "path": "/items/-",
      "value": {
        "text": "token"
      }
    }
  }
}
```

## 6. `stream.finish`

Mark a stream as complete and optionally provide final render instructions.

Payload fields:

- `status`
- `render`

Example: finish Feishu card with preserved streamed content

```json
{
  "version": "1",
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
      "template": {
        "elements": [
          {
            "tag": "markdown",
            "content": "{{content}}"
          },
          {
            "tag": "note",
            "elements": [
              {
                "tag": "plain_text",
                "content": "已完成"
              }
            ]
          }
        ]
      }
    }
  }
}
```

Example: finish without explicit target because target can be resolved by stream

```json
{
  "version": "1",
  "kind": "stream.finish",
  "provider": "feishu",
  "correlation": {
    "stream_id": "codex:task_003"
  },
  "payload": {
    "status": "completed"
  }
}
```

## 7. `stream.fail`

Terminate a stream with a failure state.

Payload fields:

- `code`
- `message`
- `user_visible`
- `render`

Example: thread missing

```json
{
  "version": "1",
  "kind": "stream.fail",
  "provider": "feishu",
  "correlation": {
    "stream_id": "codex:task_004",
    "thread_id": "thread_missing_001"
  },
  "payload": {
    "code": "thread_not_found",
    "message": "thread not found: thread_missing_001",
    "user_visible": true
  }
}
```

Example: rate limit

```json
{
  "version": "1",
  "kind": "stream.fail",
  "provider": "feishu",
  "correlation": {
    "stream_id": "codex:task_005"
  },
  "payload": {
    "code": "rate_limit",
    "message": "usage limit exceeded",
    "user_visible": true
  }
}
```

Example: system error with explicit render

```json
{
  "version": "1",
  "kind": "stream.fail",
  "provider": "feishu",
  "target": {
    "id": "om_xxx",
    "type": "message_id"
  },
  "payload": {
    "code": "system_error",
    "message": "service unavailable",
    "user_visible": true,
    "render": {
      "message_type": "interactive",
      "body": {
        "elements": [
          {
            "tag": "markdown",
            "content": "⚠️ **Codex 服务暂时异常**"
          }
        ]
      }
    }
  }
}
```

## 8. `session.bind`

Persist or declare a session/runtime binding that is currently implicit.

Payload fields:

- `binding`
- `value`

Examples:

### Bind stream to thread

```json
{
  "version": "1",
  "kind": "session.bind",
  "provider": "codex",
  "correlation": {
    "stream_id": "codex:task_001"
  },
  "payload": {
    "binding": "thread",
    "value": "thread_001"
  }
}
```

### Bind stream to response message

```json
{
  "version": "1",
  "kind": "session.bind",
  "provider": "feishu",
  "correlation": {
    "stream_id": "codex:task_001"
  },
  "payload": {
    "binding": "response_message",
    "value": "om_xxx"
  }
}
```

### Bind stream to turn

```json
{
  "version": "1",
  "kind": "session.bind",
  "provider": "codex",
  "correlation": {
    "stream_id": "codex:task_001"
  },
  "payload": {
    "binding": "turn",
    "value": "turn_001"
  }
}
```

## 9. `session.clear`

Clear broken or obsolete runtime/session bindings.

Example:

```json
{
  "version": "1",
  "kind": "session.clear",
  "provider": "codex",
  "correlation": {
    "thread_id": "thread_001",
    "stream_id": "codex:task_001"
  },
  "payload": {
    "binding": "thread",
    "reason": "thread_not_found"
  }
}
```

## Compatibility Strategy

The first implementation should not break current workers.

Recommended path:

1. Introduce internal `NormalizedCommand`.
2. Parse current `WorkerWebSocketUpstreamCommand` into `NormalizedCommand`.
3. Route only normalized commands in handlers.
4. Add PHP-side builders for new commands.
5. Remove legacy direct emitters later.

## Legacy To Normalized Examples

### Legacy Feishu send

Legacy:

```json
{
  "type": "feishu.message.send",
  "target_type": "chat_id",
  "target": "oc_xxx",
  "message_type": "text",
  "content": "{\"text\":\"hello\"}"
}
```

Normalized:

```json
{
  "version": "1",
  "kind": "provider.message.send",
  "provider": "feishu",
  "target": {
    "id": "oc_xxx",
    "type": "chat_id"
  },
  "payload": {
    "message_type": "text",
    "body": {
      "text": "hello"
    }
  }
}
```

### Legacy Feishu patch

Legacy:

```json
{
  "type": "feishu.message.patch",
  "target": "om_xxx",
  "stream_id": "codex:task_001",
  "text": "chunk"
}
```

Normalized:

```json
{
  "version": "1",
  "kind": "stream.append",
  "provider": "feishu",
  "target": {
    "id": "om_xxx",
    "type": "message_id"
  },
  "correlation": {
    "stream_id": "codex:task_001"
  },
  "payload": {
    "format": "text",
    "chunk": "chunk"
  }
}
```

### Legacy Codex RPC send

Legacy:

```json
{
  "type": "codex.rpc.send",
  "method": "thread/read",
  "params": "{\"threadId\":\"thread_001\"}",
  "stream_id": "codex:task_001"
}
```

Normalized:

```json
{
  "version": "1",
  "kind": "provider.rpc.call",
  "provider": "codex",
  "correlation": {
    "stream_id": "codex:task_001",
    "thread_id": "thread_001"
  },
  "payload": {
    "method": "thread/read",
    "params": {
      "threadId": "thread_001"
    }
  }
}
```

## Open Questions

These should be resolved before implementation starts:

1. Should `session.bind` be worker-emitted, runtime-internal, or both?
2. Should `ollama` be treated as `provider.rpc.*` instead of `provider.message.*`?
3. Should `target` allow unresolved references like:
   - `{ "type": "stream_target", "id": "codex:task_001" }`
4. Should `provider.message.update` and `stream.finish` both be allowed to
   render final cards, or should final rendering belong only to stream kinds?
5. Should MCP adopt this envelope later, or remain a separate session protocol?

## Suggested First Implementation Scope

Keep phase 1 small:

- normalize existing `codex.*`
- normalize existing `feishu.message.*`
- map `patch/flush` into internal `stream.append/finish`
- do not migrate MCP yet
- keep `ollama` compatibility via generic adapter
