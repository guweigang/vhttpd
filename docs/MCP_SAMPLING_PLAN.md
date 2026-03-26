# MCP Sampling Plan for `vhttpd`

这页只讨论 `sampling` 在 `vhttpd` 里的正确边界，不直接实现业务层 agent loop。

## Why Sampling Matters

MCP `sampling` 允许 server 通过 client 发起模型采样请求，而不是自己直接持有模型 API key。

按当前官方规范，这条链大致是：

1. server 发送 `sampling/createMessage`
2. client 审核/修改请求
3. client 调用模型
4. client 返回 `CreateMessageResult`

这意味着 `sampling` 的本质不是普通 tool call，而是：

- server -> client 的反向能力请求
- 带用户审阅的模型调用

## Official Shape

按当前官方文档，关键点是：

- method:
  - `sampling/createMessage`
- capability:
  - client 需要声明 `sampling`
  - 如果支持 tool-enabled sampling，还要声明 `sampling.tools`
- params 里核心字段通常包括：
  - `messages`
  - `modelPreferences`
  - `systemPrompt`
  - `temperature`
  - `maxTokens`
  - 可选 `tools`
  - 可选 `toolChoice`

所以 `sampling` 不是 `vhttpd` 去本地跑一个模型，而是 transport/runtime 要能安全转运这类请求。

## Recommended Boundary

对 `vhttpd` 来说，最合理的边界是：

- `vhttpd`
  - 承接 Streamable HTTP MCP transport
  - 管 session / SSE / POST
  - 负责 request/response relay
  - 暴露 runtime observability
- php-worker
  - 决定什么时候发起 `sampling/createMessage`
  - 处理 client 返回的 sampling 结果
- client
  - 真正执行模型采样
  - 审核请求
  - 审核结果

不建议让 `vhttpd` 负责：

- 本地直接接 OpenAI / Ollama 作为 MCP sampling executor
- 替 client 决策 model/provider
- 绕过 user review

这类能力会让 `sampling` 偏离 MCP 原本的 trust model。

## What `vhttpd` Should Implement

如果后续要在 `vhttpd` 里支持 `sampling`，更合理的形态是：

### Phase D1: Relay Contract

`php-worker` 可以在 `mcp` 结果里返回 queued MCP messages，其中一条就是：

- `sampling/createMessage`

`vhttpd` 只负责：

- 把它排进对应 session 的 outbound queue
- 通过 `GET /mcp` 的 SSE 发给 client

随后 client 的响应仍然通过：

- `POST /mcp`

再回到同一个 session，由 PHP handler 继续处理。

也就是说，`sampling` 对 `vhttpd` 来说首先只是：

- 一种特殊但标准的 JSON-RPC method relay

### Phase D2: Helper API

在 PHP helper 层补一个更顺手的 builder，例如：

```php
App::samplingRequest(
    id: 'sample-1',
    messages: [...],
    maxTokens: 512,
    systemPrompt: '...',
);
```

再配合：

```php
App::notify(
    $request['id'] ?? null,
    'sampling/createMessage',
    [...],
    $sessionId,
    $protocolVersion,
    ['queued' => true],
);
```

这样 userland 不必手工拼 JSON-RPC payload。

### Phase D3: Runtime Visibility

`/admin/runtime/mcp` 可以继续补：

- active sampling requests
- sampling queued total
- sampling responses total
- sampling timeouts / expirations

这层属于 runtime observability，而不是 provider logic。

## What `vhttpd` Should Not Implement

至少当前阶段不建议做：

- `vhttpd` 内建 LLM client 去执行 sampling
- `vhttpd` 内建 provider-specific sampling adapters
- `sampling` 和 `UpstreamPlan` 混成一层

原因是：

- `sampling` 的控制权本来属于 MCP client
- `UpstreamPlan` 属于 server-side upstream execution
- 两者心智不同，混起来容易把 trust boundary 搞乱

一句话说：

- `UpstreamPlan` 是 server 直接调上游
- `sampling` 是 server 请求 client 帮忙调模型

这两件事不要混。

## Practical Recommendation

建议顺序：

1. 先把 `sampling` 当作标准 MCP method relay
2. 先补 PHP helper builder
3. 再补 `/admin/runtime/mcp` 的 sampling counters
4. 暂时不做 `vhttpd` 本地 sampling executor

这样既符合 MCP 的边界，也不会让 `vhttpd` 变成另一个 provider SDK 集合。
