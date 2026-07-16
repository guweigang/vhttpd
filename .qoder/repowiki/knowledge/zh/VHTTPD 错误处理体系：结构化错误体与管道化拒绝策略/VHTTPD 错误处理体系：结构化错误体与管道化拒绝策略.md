---
kind: error_handling
name: VHTTPD 错误处理体系：结构化错误体与管道化拒绝策略
category: error_handling
scope:
    - '**'
source_files:
    - src/dispatch/exchange.v
    - src/admin/types.v
    - src/api/openai/types_runtime.v
    - src/executor/inproc_vjsx_error.v
    - src/openai_http_runtime_helpers.v
---

## 1. 采用的错误模型

vhttpd 在 V 语言中采用“返回 IError + 结构化响应体”的双轨模式，而非 panic/recover 或全局错误码枚举。核心思路是：
- 调用侧错误：通过 `!` 返回的 `IError` 向上冒泡，由上层统一捕获并转换为 HTTP/JSON 错误响应；
- 协议层错误：通过统一的 JSON 结构体（如 `AdminErrorResponse`、`OpenAIErrorResponse`、`dispatch.ErrorPayload`）表达业务错误语义，便于跨进程/跨协议传递。

代码中未发现 `recover()` 的使用，也未见 `panic(...)` 出现在生产路径（仅测试用例中出现），说明项目有意避免使用 panic 作为控制流。

## 2. 关键文件与类型

- `src/dispatch/exchange.v`：定义 `ExchangeKind.error`、`ErrorPayload`、`TransformAction.reject_action(status, error, error_class)`，是分发内核的错误载体
- `src/admin/types.v`：定义 `AdminErrorResponse`、`WorkerAdminErrorResponse`、`InternalAdminResponse.error/bad_request` 等 Admin API 错误响应体
- `src/api/openai/types_runtime.v`：定义 `OpenAIErrorBody`、`OpenAIErrorResponse`，用于 OpenAI 兼容接口的错误体
- `src/executor/inproc_vjsx_error.v`：In-Process VJSX 执行器的错误封装，提供 `normalize_message`、`not_ready`、`should_retry_dispatch` 等工具
- `src/openai_http_runtime_helpers.v`：`OpenAIErrorResponseWriter`，将内部错误写入 OpenAI 风格响应

## 3. 架构与约定

### 3.1 分发内核中的错误传播
- 请求经路由匹配后进入 pipeline，transformer 可通过 `reject_action(status, error, error_class)` 主动拒绝，产生 `ExchangeKind.error` 事件；
- `ErrorPayload` 携带 `message`、`error_class`、`status` 三个字段，贯穿整个交换生命周期；
- 各协议接入层（HTTP/WS/MCP/OpenAI）将 `ErrorPayload` 映射为各自协议的错误响应格式。

### 3.2 Admin API 的错误响应
- 所有 Admin 接口失败时统一返回 `{ "error": "<message>" }` 结构；
- 通过 `admin_data_plane_json` / `admin_plane_json_response` 辅助函数包装状态码与错误体；
- 支持 400/403/404/422/500 等标准 HTTP 状态码。

### 3.3 OpenAI 兼容错误
- `OpenAIErrorBody` 包含 `message`、`type`、`code` 三字段，遵循 OpenAI 官方错误体规范；
- `OpenAIErrorResponse` 以 `{ "error": <OpenAIErrorBody> }` 包裹。

### 3.4 In-Process VJSX 错误
- 从 JS 运行时捕获异常，优先提取 `ctx.js_exception().msg()`，其次尝试 `json_stringify()` 原始值；
- 对特定前缀错误（`inproc_vjsx_executor_runtime_create_failed:`）标记为可重试；
- 未就绪操作通过 `not_ready(op)` 返回带上下文的前缀错误。

## 4. 开发者应遵循的规则

1. 不要使用 panic：生产代码中禁止使用 `panic(...)`，仅在测试中用于快速失败；
2. 不要使用 recover：当前代码库中未见 recover 使用，不应引入；
3. 返回 IError：底层 I/O、配置解析、外部调用等可能失败的函数应返回 `!` 错误，由上层统一处理；
4. 使用结构化错误体：对外暴露的 API（Admin/OpenAI/Dispatch）必须使用对应的错误结构体，不要直接返回裸字符串；
5. 区分 error_class：在 `TransformAction.reject_action` 和 `ErrorPayload` 中使用 `error_class` 字段对错误进行分类，便于客户端差异化处理；
6. 标准化消息：使用 `InProcVjsxError.normalize_message` 等工具函数清理错误消息，避免泄露内部实现细节；
7. HTTP 状态码一致性：400 表示参数错误，403 鉴权失败，404 资源不存在，422 校验失败，500 内部错误。