# 从零开始：5分钟运行你的第一个 vhttpd 应用

在第一篇文章中，我们了解了 vhttpd 是什么，以及它能解决什么问题。现在，让我们动手实践，从编译安装开始，一步步运行你的第一个 vhttpd 应用。我们将使用 vjsx executor，这样可以最少依赖，最快上手！

---

## 前置准备

在开始之前，请确保你的开发环境满足以下要求：

- Unix-like 系统（Linux 或 macOS）
- V 语言编译器
- Git

没错，就这么简单！不需要 PHP、不需要 Node.js，我们将使用 vhttpd 内置的 vjsx executor 来运行 TypeScript/JavaScript 代码。

---

## 第一步：获取代码

首先，让我们获取 vhttpd 的源代码：

```bash
git clone https://github.com/your-org/vhttpd.git
cd vhttpd
```

---

## 第二步：安装依赖和编译

vhttpd 使用 Makefile 来管理构建过程。让我们先安装核心依赖：

```bash
make deps-core
make doctor
```

`make doctor` 会检查你的系统环境是否满足要求。如果一切正常，我们就可以开始编译了：

```bash
make vhttpd
```

这个命令会：
1. 准备构建源代码
2. 使用 V 语言编译器编译 vhttpd
3. 生成一个独立的二进制文件 `vhttpd`

如果你想构建生产版本，可以使用：

```bash
make prod
```

---

## 第三步：运行 Hello World

项目已经为我们准备好了一个简单的 vjsx 示例应用，让我们直接运行它：

```bash
./vhttpd --config config/vhttpd.vjsx.example.toml
```

这条命令会：
1. 加载配置文件 [`vhttpd.vjsx.example.toml`](file:///workspace/config/vhttpd.vjsx.example.toml)
2. 启动 vhttpd 服务
3. 初始化 vjsx executor（嵌入式执行器）
4. 开始监听端口

你应该会看到类似这样的输出：

```
vhttpd starting...
http://127.0.0.1:19882/
admin plane listening on http://127.0.0.1:19982/admin
```

注意：没有 PHP worker 启动！我们正在使用纯内存的嵌入式 vjsx executor。

---

## 第四步：测试应用

现在让我们测试一下我们的应用是否正常工作。打开另一个终端窗口，运行：

```bash
curl --noproxy '*' -i "http://127.0.0.1:19882/hello?name=codex"
```

你应该会看到：

```
HTTP/1.1 200 OK
Content-Type: application/json; charset=utf-8
Date: ...

{
  "ok": true,
  "provider": "vjsx",
  "executor": "vjsx",
  "laneId": 0,
  "requestId": "...",
  "traceId": "...",
  "method": "GET",
  "path": "/hello",
  "name": "codex"
}
```

太棒了！我们的第一个 vhttpd + vjsx 应用已经成功运行了！

---

## 第五步：探索更多功能

让我们查看更丰富的示例。修改配置文件，使用 [`api-demo-handler.mts`](file:///workspace/examples/vjsx/api-demo-handler.mts)，或者创建一个新的配置文件：

```toml
[paths]
root = "."
vjsx_app = "examples/vjsx/api-demo-handler.mts"
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

现在让我们测试各种功能：

### 1. 基础 API 调用

```bash
curl --noproxy '*' -i "http://127.0.0.1:19882/?name=vhttpd"
```

### 2. HTML 响应

```bash
curl --noproxy '*' -i "http://127.0.0.1:19882/?mode=html&name=vhttpd"
```

### 3. POST 数据

```bash
curl --noproxy '*' -i -X POST \
  -H "Content-Type: application/json" \
  -d '{"foo":"bar"}' \
  "http://127.0.0.1:19882/"
```

### 4. 语义化响应

```bash
# Accepted 响应
curl --noproxy '*' -i "http://127.0.0.1:19882/?mode=accepted"

# Problem 响应
curl --noproxy '*' -i "http://127.0.0.1:19882/?mode=problem"
```

---

## 第六步：探索 Admin Plane

vhttpd 的一个强大特性是它的 Admin Plane（管理平面）。让我们访问它：

```bash
curl --noproxy '*' \
  -H 'x-vhttpd-admin-token: change-me' \
  "http://127.0.0.1:19982/admin/runtime" | jq .
```

你会看到类似这样的输出：

```json
{
  "worker_pool_size": 0,
  "http_requests_total": 5,
  "active_websockets": 0,
  "active_upstreams": 0,
  "stream_dispatch": false,
  "websocket_dispatch": false,
  "mcp_dispatch": false
}
```

注意：`worker_pool_size` 是 0，因为我们在使用 vjsx 嵌入式 executor，不需要 worker 进程！

你也可以查看所有可用的 executor：

```bash
curl --noproxy '*' \
  -H 'x-vhttpd-admin-token: change-me' \
  "http://127.0.0.1:19982/admin/executors" | jq .
```

---

## 理解 vjsx 配置

让我们看一下 [`vhttpd.vjsx.example.toml`](file:///workspace/config/vhttpd.vjsx.example.toml)：

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
kind = "vjsx"  # 这里指定使用 vjsx executor

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

关键配置：
- `[executor].kind = "vjsx"` - 告诉 vhttpd 使用嵌入式 vjsx 执行器
- `[vjsx].app_entry` - TypeScript/JavaScript 入口文件
- `[vjsx].module_root` - 模块解析根目录
- `[vjsx].thread_count` - 嵌入式执行线程数量（并行处理能力）
- 没有 `[worker]` 部分！因为我们不需要 worker 进程

---

## 理解 vjsx 代码

让我们看一下 [`hello-handler.mts`](file:///workspace/examples/vjsx/hello-handler.mts)：

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

这个简单的示例展示了 vjsx 的基本用法：
1. 导出一个默认函数作为 handler
2. 接收 `ctx` 上下文对象
3. 使用 `ctx.runtime` 获取运行时信息
4. 使用 `ctx.json()` 返回 JSON 响应

---

## vjsx API 快速概览

### 请求上下文 (`ctx`)

核心属性：
- `ctx.method` - HTTP 方法
- `ctx.path` - 请求路径
- `ctx.query` - 查询参数对象
- `ctx.headers` - 请求头
- `ctx.body` - 请求体

请求帮助方法：
- `ctx.queryParam(name, fallback)` - 获取查询参数
- `ctx.jsonBody(fallback)` - 解析 JSON 请求体
- `ctx.isJson()` - 检查是否是 JSON 请求
- `ctx.wantsJson()` - 检查客户端是否想要 JSON 响应

响应帮助方法：
- `ctx.json(value, status?)` - 返回 JSON 响应
- `ctx.text(body, status?)` - 返回文本响应
- `ctx.html(body, status?)` - 返回 HTML 响应

语义化响应：
- `ctx.ok(value)` - 200 OK
- `ctx.created(value?)` - 201 Created
- `ctx.accepted(value?)` - 202 Accepted
- `ctx.noContent()` - 204 No Content
- `ctx.notFound(value?)` - 404 Not Found
- `ctx.badRequest(value?)` - 400 Bad Request
- `ctx.problem(status, title, detail, extra?)` - Problem Details (RFC 7807)

运行时 API (`ctx.runtime`)：
- `ctx.runtime.provider` - 运行时提供者（通常是 "vjsx"）
- `ctx.runtime.executor` - 执行器类型
- `ctx.runtime.laneId` - 执行线程 ID
- `ctx.runtime.requestId` - 请求 ID
- `ctx.runtime.traceId` - 追踪 ID
- `ctx.runtime.emit(kind, fields)` - 发出事件
- `ctx.runtime.snapshot()` - 获取运行时快照
- `ctx.runtime.log/warn/error(...)` - 日志记录

详细的 API 参考请见 [`VJSX_FACADE_REFERENCE.md`](file:///workspace/docs/VJSX_FACADE_REFERENCE.md)。

---

## 创建你自己的 vjsx 应用

让我们创建一个简单的待办事项 API 作为练习。创建文件 `examples/vjsx/todo-app.mts`：

```typescript
let todos = [
  { id: 1, title: "Learn vhttpd", done: false },
  { id: 2, title: "Build cool stuff", done: false },
];

function handle(ctx) {
  // 获取所有 todo
  if (ctx.is("GET") && ctx.path === "/todos") {
    return ctx.ok({ todos });
  }

  // 创建 todo
  if (ctx.is("POST") && ctx.path === "/todos") {
    if (!ctx.isJson()) {
      return ctx.badRequest({ error: "expected_json" });
    }
    const body = ctx.jsonBody({});
    const newTodo = {
      id: todos.length + 1,
      title: body.title || "Untitled",
      done: false,
    };
    todos.push(newTodo);
    return ctx.created(newTodo);
  }

  // 切换 todo 状态
  if (ctx.is("PUT") && ctx.path.startsWith("/todos/")) {
    const id = parseInt(ctx.path.replace("/todos/", ""));
    const todo = todos.find(t => t.id === id);
    if (!todo) {
      return ctx.notFound({ error: "todo_not_found" });
    }
    todo.done = !todo.done;
    return ctx.ok(todo);
  }

  // 默认返回 404
  return ctx.notFound({ error: "not_found" });
}

export default handle;
```

创建配置文件 `config/todo-app.toml`：

```toml
[paths]
root = ".."
vjsx_app = "examples/vjsx/todo-app.mts"
vjsx_root = "examples/vjsx"

[server]
host = "127.0.0.1"
port = 19890

[executor]
kind = "vjsx"

[vjsx]
app_entry = "${paths.vjsx_app}"
module_root = "${paths.vjsx_root}"
runtime_profile = "node"
thread_count = 2

[admin]
host = "127.0.0.1"
port = 19990
token = "change-me"
```

启动并测试：

```bash
./vhttpd --config config/todo-app.toml

# 另一个终端
curl --noproxy '*' "http://127.0.0.1:19890/todos"
curl --noproxy '*' -X POST -H "Content-Type: application/json" -d '{"title":"New Todo"}' "http://127.0.0.1:19890/todos"
curl --noproxy '*' -X PUT "http://127.0.0.1:19890/todos/1"
```

---

## 对比：vjsx vs PHP

| 特性 | vjsx (嵌入式) | PHP (Worker) |
|------|--------------|-------------|
| 依赖 | 仅 vhttpd 二进制 | PHP + vslim.so + php-worker |
| 启动速度 | 极快（内存内） | 需要启动 worker 进程 |
| 内存占用 | 更低（共享进程） | 更高（每个 worker 独立） |
| HTTP 处理 | ✅ 支持 | ✅ 支持 |
| SSE/流式 | 暂不支持 | ✅ 支持 |
| WebSocket | ✅ 支持 | ✅ 支持 |
| MCP | 暂不支持 | ✅ 支持 |
| 推荐场景 | 快速原型、网关、插件 | PHP 应用、AI 流、MCP |

---

## 下一步

恭喜你！你已经成功运行了你的第一个 vhttpd + vjsx 应用。在第三篇文章中，我们将探索如何在 vhttpd 上运行 PHP 应用，包括 Laravel、Symfony 和 WordPress。

如果你想继续探索，可以：
- 尝试 [`api-demo-handler.mts`](file:///workspace/examples/vjsx/api-demo-handler.mts) 的更多功能
- 探索 WebSocket 集成
- 阅读 [`VJSX_FACADE_REFERENCE.md`](file:///workspace/docs/VJSX_FACADE_REFERENCE.md) 了解完整 API

---

## 常见问题

**Q: vjsx 需要 Node.js 吗？**
A: 不需要！vjsx 使用嵌入式 QuickJS 引擎，完全内置在 vhttpd 中。

**Q: 可以使用 npm 包吗？**
A: 当前 vjsx 主要用于轻量级逻辑。对于复杂依赖，建议使用 PHP executor。

**Q: 如何停止 vhttpd？**
A: 在运行 vhttpd 的终端按 `Ctrl+C`。

**Q: vjsx 能处理高并发吗？**
A: 可以！使用 `[vjsx].thread_count` 配置多个执行线程。

---

## 相关资源

- [vjsx 示例](file:///workspace/examples/vjsx/)
- [配置文件参考](file:///workspace/config/vhttpd.vjsx.example.toml)
- [vjsx API 参考](file:///workspace/docs/VJSX_FACADE_REFERENCE.md)
- [执行器模式文档](file:///workspace/docs/EXECUTOR_MODES.md)
- [架构概述](file:///workspace/docs/OVERVIEW.md)
