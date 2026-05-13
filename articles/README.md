# vhttpd 文章系列：AI 时代的基础设施

本目录包含用于介绍和推广 `vhttpd` 的公开文章。

## 核心定位

> vhttpd 是面向 PHP / TypeScript / AI 应用的高性能 transport runtime。

英文：

> vhttpd is a lightweight transport runtime for PHP, TypeScript, AI streaming,
> WebSocket, SSE, and MCP applications.

## 叙事主线

本系列应该避免将 `vhttpd` 呈现为"另一个 HTTP 服务器"。更有力的信息是：现代应用不再只是经典的请求/响应系统。它们往往需要在同一个产品中同时支持 HTTP、WebSocket、SSE、上游 token 流、MCP Streamable HTTP、机器人集成、PHP 业务逻辑和 TypeScript 协议粘合代码。

`vhttpd` 位于协议入口和应用逻辑之间：

- 它终止 HTTP、WebSocket、流和 MCP 连接。
- 通过外部 worker 运行 PHP 应用。
- 通过嵌入式 `vjsx` 执行器运行 TypeScript/JavaScript 逻辑。
- 可以用作面向插件的网关层，处理快速变化的协议和 AI 集成逻辑。
- 暴露管理/运行时界面，用于查看 worker 状态、队列状态、活跃上游、MCP 会话和相关运行时指标。

## 完整文章系列规划

### 第一部分：定位篇（已完成 1/1）

1. **[01-overview.md](01-overview.md)** ✅
   - 产品定义介绍
   - 解释为什么 vhttpd 是一个 transport runtime，而不仅仅是 HTTP 服务器
   - 介绍 PHP worker、vjsx 插件、WebSocket/stream/MCP 能力以及运行时可观测性

### 第二部分：实战入门篇（3/4 完成）

2. **[02-getting-started.md](02-getting-started.md)** ✅
   - 从零开始：5分钟运行你的第一个 vhttpd 应用
   - 编译安装步骤
   - 配置文件基础
   - Hello World 示例
   - Admin Plane 探索

3. **[03-php-apps.md](03-php-apps.md)** ✅
   - 让 PHP 应用重获新生：Laravel/Symfony/WordPress 迁移指南
   - Laravel 集成实战
   - Symfony 集成实战
   - WordPress 集成实战
   - 与传统 nginx + PHP-FPM 的对比

4. **04-ai-streaming.md** （待写）
   - AI 流式应用入门：从简单 SSE 到智能对话
   - 基础 AI token streaming
   - SSE vs text stream
   - 使用示例应用

### 第三部分：核心功能实战篇

5. **05-ollama-proxy.md** （待写）
   - 构建你的专属 AI Gateway：Ollama 代理实战
   - 理解 phase 3 upstream plan 架构
   - 本地和云端 Ollama 集成

6. **06-mcp-server.md** （待写）
   - MCP 服务端实践：构建可扩展的 AI 工具平台
   - MCP Streamable HTTP 介绍
   - 注册 tools/resources/prompts
   - 与 Cherry Studio 集成演示

7. **07-feishu-bot.md** （待写）
   - 飞书机器人实战：从简单回落到智能对话
   - 飞书长连接集成
   - 互动卡片开发
   - 与 AI 能力结合

### 第四部分：TypeScript 插件篇

8. **08-vjsx-intro.md** （待写）
   - vjsx 入门：用 TypeScript 快速扩展 vhttpd
   - vjsx 是什么
   - 第一个 vjsx handler
   - 与 PHP 的关系和分工

9. **09-codexbot.md** （待写）
   - 从零构建一个 AI 编程助手：codexbot 案例深度解析
   - codexbot 架构解析
   - Codex 协议集成
   - 实时协作功能

### 第五部分：架构与高级篇

10. **10-architecture.md** （待写）
    - 深入理解 vhttpd 架构：从协议层到运行时
    - 整体架构图解读
    - Worker 池和队列管理
    - Stream 执行的三个阶段
    - Provider 模型

11. **11-observability.md** （待写）
    - 可观测性实战：监控、调试和运维
    - Admin Plane 深入使用
    - Runtime stats 和 metrics
    - Event log 和故障排查

12. **12-advanced-patterns.md** （待写）
    - 高级模式：多监听器、数据库连接池、Paseo Relay
    - 多站点配置
    - DB 连接池托管
    - Paseo Relay 实战

### 第六部分：案例与未来篇

13. **13-real-world.md** （待写）
    - 真实案例：生产环境中的 vhttpd 应用
    - 整合多个案例
    - 性能对比数据

14. **14-future.md** （待写）
    - 展望未来：vhttpd 的演进路线和生态愿景
    - Roadmap 介绍
    - 如何参与贡献

## 市场定位

There are already mature adjacent products:

- FrankenPHP: modern PHP application server built on Caddy, with worker mode,
  Laravel/Symfony integrations, real-time features, metrics, HTTP/2, HTTP/3,
  and automatic HTTPS.
- RoadRunner: Go-based PHP application server and process manager with worker
  pools and a plugin ecosystem.
- Swoole/OpenSwoole: PHP extension-based async/coroutine networking runtime.
- Laravel Octane: Laravel integration layer for high-performance app servers
  such as FrankenPHP, RoadRunner, Swoole, and OpenSwoole.
- LiteLLM Proxy: OpenAI-compatible LLM gateway for many model providers.
- Envoy AI Gateway: cloud-native AI/MCP gateway built around Envoy and
  Kubernetes-style production traffic management.

The safer and stronger claim is not "nobody else does this".

The better claim:

> Existing products solve PHP worker runtimes, WebSocket, AI gateways, and MCP
> gateways separately. vhttpd's opportunity is to combine PHP workers,
> TypeScript plugins, WebSocket upstreams, SSE/MCP/AI streams, and runtime
> observability into one lightweight transport runtime.

## Proof Points To Add

Before publishing performance-heavy claims, collect real data:

- Plain HTTP RPS and latency.
- PHP worker RPS and latency.
- First-token latency for SSE or text streaming.
- WebSocket concurrent connection count.
- Worker pool queue behavior under pressure.
- Memory footprint.
- Binary size and startup time.

Prefer concrete tables over vague claims such as "very fast".
