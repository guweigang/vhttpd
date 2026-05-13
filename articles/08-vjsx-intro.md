# vjsx 入门：用 TypeScript 快速扩展 vhttpd

在前面的文章中，我们已经使用 vjsx executor 作为入门示例。现在，让我们深入了解 vjsx 的完整能力，看看如何用 TypeScript/JavaScript 快速构建强大的 vhttpd 扩展。

---

## 什么是 vjsx？

vjsx 是 vhttpd 内置的 **嵌入式 TypeScript/JavaScript 执行器**，它：

- **内置于 vhttpd** - 无需 Node.js，使用 QuickJS 引擎
- **TypeScript 支持** - 使用 `.mts` 文件，享受类型检查
- **零外部依赖** - 只需要 vhttpd 二进制文件
- **高性能** - 多线程执行，支持并行处理

### 技术原理

```
vhttpd → TypeScript (.mts) → QuickJS → V 代码
         ↓
      Transpile
```

vjsx 使用 vjsx 编译器将 TypeScript 转译为 JavaScript，然后在 QuickJS 虚拟机中执行。

---

## vjsx vs PHP：何时选择？

| 场景 | 推荐选择 | 原因 |
|------|----------|------|
| 快速原型开发 | **vjsx** | 简洁、无需编译 |
| 轻量级网关/中间件 | **vjsx** | 低开销、快速响应 |
| 协议粘合代码 | **vjsx** | TypeScript 表达力强 |
| 复杂业务逻辑 | **PHP** | 成熟生态、丰富库 |
| AI 流式处理 | **PHP** | 支持完整 stream API |
| MCP 工具开发 | **PHP** | 完整 MCP 支持 |
| 数据库密集型 | **PHP** | PDO/Laravel ORM |
| 长期运行任务 | **PHP** | Worker 生命周期控制 |

**简单来说**：vjsx 适合**薄**逻辑层，PHP 适合**厚**业务层。

---

## 第一步：理解 vjsx 配置

查看 [`vhttpd.vjsx.example.toml`](file:///workspace/config/vhttpd.vjsx.example.toml)：

```toml
[paths]
root = ".."
vjsx_app = "examples/vjsx/hello-handler.mts"
vjsx_root = "examples/vjsx"
web_root = "examples/public"

[server]
host = "127.0.0.1"
port = 19882

[files]
pid_file = "tmp/vhttpd_vjsx_${server.port}.pid"
event_log = "tmp/vhttpd_vjsx_${server.port}.events.ndjson"

[runtime]
timezone = "Asia/Shanghai"

[executor]
kind = "vjsx"

[vjsx]
app_entry = "${paths.vjsx_app}"
module_root = "${paths.vjsx_root}"
runtime_profile = "node"
thread_count = 2

[admin]
host = "127.0.0.1"
port = 19982
token = "change-me"
```

关键配置说明：

| 配置项 | 说明 | 推荐值 |
|--------|------|--------|
| `[executor].kind` | 执行器类型 | `vjsx` |
| `[vjsx].app_entry` | 入口文件路径 | 相对或绝对路径 |
| `[vjsx].module_root` | 模块解析根目录 | 便于模块导入 |
| `[vjsx].runtime_profile` | 运行时配置 | `node` 或 `script` |
| `[vjsx].thread_count` | 执行线程数 | CPU 核心数 |

---

## 第二步：编写第一个 vjsx Handler

### 基础 Handler

查看 [`hello-handler.mts`](file:///workspace/examples/vjsx/hello-handler.mts)：

```typescript
function handle(ctx) {
  return ctx.json({
    ok: true,
    provider: ctx.runtime.provider,
    executor: ctx.runtime.executor,
    laneId: ctx.runtime.laneId,
    requestId: ctx.runtime.requestId,
    traceId: ctx.runtime.traceId,
    method: ctx.method,
    path: ctx.path,
    name: ctx.queryParam("name", "world"),
  }, 200);
}

export default handle;
```

这个简单的示例展示了 vjsx 的核心概念：

1. **导出默认函数** - `export default handle`
2. **接收上下文对象** - `ctx` 包含所有请求信息
3. **返回响应** - 使用 `ctx.json()` 返回 JSON

### API 详解

#### 请求上下文 (`ctx`)

**核心属性**：

```typescript
ctx.method         // HTTP 方法: "GET", "POST", "PUT", "DELETE"
ctx.path           // 请求路径: "/api/users"
ctx.query          // 查询参数对象: { name: "codex", page: "1" }
ctx.headers        // 请求头: { "content-type": "application/json" }
ctx.body           // 请求体原始字符串
ctx.ip             // 客户端 IP 地址
ctx.requestId      // 请求唯一 ID
ctx.traceId        // 追踪 ID
```

**请求帮助方法**：

```typescript
// 获取查询参数
ctx.queryParam("name", "default")       // string
ctx.queryInt("page", 1)                 // number
ctx.queryBool("debug", false)           // boolean

// 获取请求头
ctx.getHeader("Authorization")
ctx.headerInt("Content-Length", 0)

// 检查请求类型
ctx.is("POST")                          // boolean
ctx.isJson()                            // boolean
ctx.isHtml()                            // boolean

// 获取请求体
ctx.jsonBody({})                        // 自动解析 JSON
ctx.bodyText("")                         // 获取原始文本
```

**响应帮助方法**：

```typescript
// 基础响应
ctx.json({ ok: true }, 200)            // JSON 响应
ctx.text("Hello", 200)                  // 文本响应
ctx.html("<h1>Hello</h1>", 200)        // HTML 响应
ctx.send(buffer, 200)                   // 二进制响应

// 语义化响应
ctx.ok({ data: [] })                   // 200 OK
ctx.created({ id: 1 })                 // 201 Created
ctx.accepted({ queued: true })          // 202 Accepted
ctx.noContent()                         // 204 No Content
ctx.badRequest({ error: "invalid" })     // 400 Bad Request
ctx.notFound({ error: "not found" })    // 404 Not Found
ctx.unauthorized()                      // 401 Unauthorized
ctx.problem(409, "Conflict", "详细描述") // RFC 7807 Problem Details

// 响应头操作
ctx.setHeader("X-Custom", "value")
ctx.getHeader("Content-Type")
ctx.hasHeader("Cache-Control")
ctx.removeHeader("X-Debug")

// 状态码
ctx.status(201)
ctx.code(201)  // 别名
ctx.type("application/json")           // 设置 Content-Type
```

#### 运行时 API (`ctx.runtime`)

```typescript
// 基础信息
ctx.runtime.provider                  // "vjsx"
ctx.runtime.executor                  // "vjsx"
ctx.runtime.laneId                   // 当前线程 ID
ctx.runtime.requestId                // 请求 ID
ctx.runtime.traceId                  // 追踪 ID

// 日志记录
ctx.runtime.log("info message")
ctx.runtime.warn("warning message")
ctx.runtime.error("error message")

// 事件发射
ctx.runtime.emit("custom.event", {
  userId: "123",
  action: "login"
})

// 快照（获取运行时状态）
const snapshot = ctx.runtime.snapshot()
/*
{
  worker_pool_size: 0,
  http_requests_total: 100,
  active_websockets: 2,
  ...
}
*/

// 文件读取
const config = ctx.runtime.readTextFile("/path/to/config.json", "{}")

// HTTP 请求（发起外部请求）
const response = ctx.runtime.httpFetch({
  url: "https://api.example.com/data",
  method: "GET",
  headers: { "Authorization": "Bearer xxx" }
})
```

---

## 第三步：构建 API 路由系统

vjsx 没有内置路由，但我们可以轻松实现：

```typescript
type Handler = (ctx: any) => any;

const routes: Record<string, Handler> = {
  '/': handleHome,
  '/users': handleUsers,
  '/users/:id': handleUserById,
  '/posts': handlePosts,
};

// 动态路由匹配
function matchRoute(path: string): { handler: Handler; params: Record<string, string> } | null {
  for (const [pattern, handler] of Object.entries(routes)) {
    const params: Record<string, string> = {};
    const patternParts = pattern.split('/');
    const pathParts = path.split('/');

    if (patternParts.length !== pathParts.length) {
      continue;
    }

    let match = true;
    for (let i = 0; i < patternParts.length; i++) {
      if (patternParts[i].startsWith(':')) {
        params[patternParts[i].slice(1)] = pathParts[i];
      } else if (patternParts[i] !== pathParts[i]) {
        match = false;
        break;
      }
    }

    if (match) {
      return { handler, params };
    }
  }
  return null;
}

function handleHome(ctx: any) {
  return ctx.json({ message: "Welcome to vjsx API" });
}

function handleUsers(ctx: any) {
  const users = [
    { id: 1, name: "Alice" },
    { id: 2, name: "Bob" },
  ];
  return ctx.ok({ users, total: users.length });
}

function handleUserById(ctx: any) {
  const routeMatch = matchRoute(ctx.path);
  if (!routeMatch) {
    return ctx.notFound({ error: "User not found" });
  }
  return ctx.ok({ userId: routeMatch.params.id });
}

function handlePosts(ctx: any) {
  if (ctx.is("POST")) {
    const body = ctx.jsonBody({});
    return ctx.created({ post: body, id: Date.now() });
  }
  if (ctx.is("GET")) {
    return ctx.ok({ posts: [] });
  }
  return ctx.badRequest({ error: "Method not allowed" });
}

function handle(ctx: any) {
  const route = matchRoute(ctx.path);
  if (!route) {
    return ctx.notFound({ error: `Route not found: ${ctx.path}` });
  }
  return route.handler(ctx);
}

export default handle;
```

---

## 第四步：中间件系统

实现类似 Express 的中间件机制：

```typescript
type Middleware = (ctx: any, next: () => any) => any;

const middlewares: Middleware[] = [
  // 请求日志
  async (ctx, next) => {
    const start = Date.now();
    ctx.runtime.log(`[${ctx.method}] ${ctx.path}`);
    const result = await next();
    const duration = Date.now() - start;
    ctx.runtime.log(`[${ctx.method}] ${ctx.path} - ${duration}ms`);
    return result;
  },

  // 认证检查
  async (ctx, next) => {
    const token = ctx.getHeader("Authorization")?.replace("Bearer ", "");
    if (!token && ctx.path !== "/health") {
      return ctx.unauthorized({ error: "Missing authorization token" });
    }
    ctx.userId = token ? parseUserId(token) : null;
    return next();
  },

  // CORS
  async (ctx, next) => {
    ctx.setHeader("Access-Control-Allow-Origin", "*");
    ctx.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
    ctx.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");

    if (ctx.method === "OPTIONS") {
      return ctx.noContent();
    }
    return next();
  },
];

// 简单的路由系统
const handlers: Record<string, (ctx: any) => any> = {
  "/health": (ctx) => ctx.ok({ status: "ok" }),
  "/api/users": (ctx) => ctx.ok({ users: [] }),
};

async function handle(ctx: any): Promise<any> {
  // 组合中间件
  let index = 0;

  async function dispatch(): Promise<any> {
    if (index >= middlewares.length) {
      const handler = handlers[ctx.path];
      if (!handler) {
        return ctx.notFound({ error: "Not found" });
      }
      return handler(ctx);
    }
    const middleware = middlewares[index++];
    return middleware(ctx, dispatch);
  }

  return dispatch();
}

export default handle;
```

---

## 第五步：WebSocket 支持

vjsx 还支持 WebSocket 处理。查看 [`bot-entry.mts`](file:///workspace/examples/vjsx/bot-entry.mts)：

```typescript
const bot = {
  http(ctx: any) {
    return ctx.json(
      {
        ok: true,
        kind: "http",
        dispatchKind: ctx.runtime.dispatchKind,
        path: ctx.path,
      },
      200,
    );
  },

  websocket_upstream(frame: any) {
    const payload = frame.payloadJson({});
    const prompt =
      typeof payload.text === "string" && payload.text.trim() !== ""
        ? payload.text
        : "empty";

    return {
      handled: true,
      commands: [
        {
          type: "provider.message.send",
          provider: frame.provider,
          instance: frame.instance,
          target: frame.target,
          target_type: frame.targetType || "chat_id",
          message_type: "text",
          text: `received: ${prompt}`,
          metadata: {
            event_type: frame.eventType,
            dispatch_kind: frame.runtime.dispatchKind,
          },
        },
      ],
    };
  },
};

export default bot;
```

**WebSocket Upstream Frame 属性**：

```typescript
frame.mode              // 帧模式
frame.event             // 事件类型
frame.provider          // 提供商（如 "feishu"）
frame.instance          // 实例名称
frame.eventType         // 事件类型
frame.messageId         // 消息 ID
frame.target            // 目标（chat_id）
frame.targetType        // 目标类型
frame.payload           // 原始载荷
frame.payloadText()     // 获取文本载荷
frame.payloadJson({})   // 解析 JSON 载荷
frame.runtime           // 运行时信息
```

**返回值**：

```typescript
// 不处理
return false;

// 处理但不发送命令
return true;

// 处理并发送命令
return {
  handled: true,
  commands: [
    {
      type: "provider.message.send",
      provider: "feishu",
      instance: "main",
      target: "chat_id",
      message_type: "text",
      text: "Hello!",
    },
  ],
};
```

---

## 第六步：OpenAI 插件示例

查看 [`openai-executor-app.mts`](file:///workspace/examples/vjsx/openai-executor-app.mts)：

```typescript
type PluginRequest = {
  op: string;
  payload: string;
};

function payload(req: PluginRequest): Record<string, any> {
  return JSON.parse(req.payload || "{}");
}

async function* streamFrames(prompt: string) {
  yield { content: "executor: ", done: false };
  yield { content: prompt || "ok", done: false };
  yield {
    usage: {
      prompt_tokens: Math.max(1, prompt.length),
      completion_tokens: 2,
      total_tokens: Math.max(1, prompt.length) + 2,
    },
    done: true,
  };
}

export async function openai(req: PluginRequest) {
  if (req.op !== "chat.execute" && req.op !== "responses.execute") {
    return { not_handled: true };
  }

  const p = payload(req);
  const body = JSON.parse(p.body || "{}");
  const prompt = (body.messages || []).map((m: any) => m.content).join("\n");

  if (req.op === "responses.execute") {
    if (p.stream) {
      return streamFrames(prompt);
    }

    return {
      id: "resp_vhttpd_executor",
      object: "response",
      status: "completed",
      model: p.model,
      output: [{
        id: "msg_vhttpd_executor",
        type: "message",
        status: "completed",
        role: "assistant",
        content: [{
          type: "output_text",
          text: `executor: ${prompt || "ok"}`,
          annotations: [],
        }],
      }],
    };
  }

  // 流式响应
  if (p.stream) {
    return streamFrames(prompt);
  }

  return {
    content: `executor: ${prompt || "ok"}`,
    usage: {
      prompt_tokens: Math.max(1, prompt.length),
      completion_tokens: 2,
      total_tokens: Math.max(1, prompt.length) + 2,
    },
    done: true,
  };
}
```

---

## 第七步：最佳实践

### 1. 类型安全

```typescript
// 使用 TypeScript 接口
interface User {
  id: number;
  name: string;
  email: string;
}

function handleUsers(ctx: any): Promise<any> {
  // 返回类型明确的响应
  return ctx.ok({
    users: [] as User[],
    total: 0,
  });
}
```

### 2. 错误处理

```typescript
function handle(ctx: any) {
  try {
    // 业务逻辑
    const userId = parseInt(ctx.path.split('/').pop() || '0');
    if (isNaN(userId)) {
      return ctx.badRequest({ error: "Invalid user ID" });
    }
    return ctx.ok({ userId });
  } catch (error: any) {
    ctx.runtime.error(`Error: ${error.message}`);
    return ctx.problem(500, "Internal Error", error.message);
  }
}
```

### 3. 性能优化

```typescript
// 使用缓存
const cache = new Map<string, { data: any; expires: number }>();

function handleWithCache(ctx: any) {
  const cacheKey = `${ctx.path}:${JSON.stringify(ctx.query)}`;
  const cached = cache.get(cacheKey);

  if (cached && cached.expires > Date.now()) {
    return ctx.json(cached.data);
  }

  // 计算新数据
  const data = computeExpensiveData(ctx);

  // 缓存 5 分钟
  cache.set(cacheKey, { data, expires: Date.now() + 5 * 60 * 1000 });

  return ctx.json(data);
}
```

### 4. 日志和监控

```typescript
function handle(ctx: any) {
  ctx.runtime.emit("request.start", {
    path: ctx.path,
    method: ctx.method,
    requestId: ctx.requestId,
  });

  const start = Date.now();
  try {
    const result = processRequest(ctx);
    const duration = Date.now() - start;

    ctx.runtime.emit("request.complete", {
      path: ctx.path,
      duration,
      status: "success",
    });

    return ctx.ok(result);
  } catch (error: any) {
    const duration = Date.now() - start;

    ctx.runtime.emit("request.error", {
      path: ctx.path,
      duration,
      error: error.message,
    });

    return ctx.problem(500, "Error", error.message);
  }
}
```

---

## 第八步：vjsx 与 PHP 的协作模式

### 模式 1：vjsx 前端 + PHP 后端

```typescript
// vjsx: API 网关
function handle(ctx: any) {
  // 认证和请求验证
  const token = ctx.getHeader("Authorization");
  if (!token) {
    return ctx.unauthorized({ error: "Missing token" });
  }

  // 路由到 PHP 后端
  const backendResponse = ctx.runtime.httpFetch({
    url: `http://localhost:19883${ctx.path}`,
    method: ctx.method,
    headers: {
      "Authorization": token,
      "X-Forwarded-For": ctx.ip,
    },
    body: ctx.body,
  });

  return ctx.json(backendResponse);
}

export default handle;
```

### 模式 2：PHP 前端 + vjsx 中间件

```php
// PHP: 业务逻辑
$app->get('/api/data', function($req) {
    $data = $this->processData($req);
    return $this->ok($data);
});

// vjsx: 中间件（在 vhttpd 层处理）
const authMiddleware = async (ctx, next) => {
  const token = ctx.getHeader("Authorization");
  if (!validateToken(token)) {
    return ctx.unauthorized();
  }
  return next();
};
```

---

## 常见问题

**Q: vjsx 支持 npm 包吗？**
A: 当前版本不支持 npm 包导入。vjsx 主要用于轻量级逻辑，复杂依赖建议使用 PHP。

**Q: 如何调试 vjsx 代码？**
A: 使用 `ctx.runtime.log/warn/error` 记录日志，查看 Admin Plane 的 event log。

**Q: vjsx 支持 async/await 吗？**
A: 支持！vjsx 完全支持 async/await 语法。

**Q: 如何处理文件上传？**
A: 使用 `ctx.body` 获取原始请求体，然后手动解析 multipart 数据。

---

## 下一步

恭喜你！已经掌握了 vjsx 的核心能力。在下一篇文章中，我们将通过 **codexbot 案例** 深入了解如何构建一个完整的 AI 编程助手，包括 Codex 协议集成和实时协作功能。

如果你想继续探索，可以：
- 查看 [`api-demo-handler.mts`](file:///workspace/examples/vjsx/api-demo-handler.mts) 了解完整的 API 演示
- 探索 [`openai-gateway-plugin.mts`](file:///workspace/examples/vjsx/openai-gateway-plugin.mts) 了解 OpenAI 兼容网关
- 阅读 [`VJSX_FACADE_REFERENCE.md`](file:///workspace/docs/VJSX_FACADE_REFERENCE.md) 了解完整的 API 参考

---

## 相关资源

- [vjsx 示例](file:///workspace/examples/vjsx/)
- [vjsx 配置文件](file:///workspace/config/vhttpd.vjsx.example.toml)
- [vjsx API 参考](file:///workspace/docs/VJSX_FACADE_REFERENCE.md)
- [执行器模式文档](file:///workspace/docs/EXECUTOR_MODES.md)
- [In-Proc vjsx Runbook](file:///workspace/docs/INPROC_VJSX_RUNBOOK.md)
