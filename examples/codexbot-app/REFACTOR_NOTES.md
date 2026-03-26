# Codex Bot Refactor Notes

## Current State

`vhttpd/examples/codexbot-app.php` 现在已经基本收缩成入口导出文件：

- 初始化 `AppRuntime`
- 导出 `http` / `websocket_upstream` handlers

原先堆在入口文件里的 helper，已经拆到 `lib/Upstream/`：

- `BotContextHelper`
- `BotErrorHelper`
- `BotJsonHelper`
- `BotResponseHelper`
- `FeishuMessageParser`
- `ThreadViewHelper`
- `FeishuCommandRouter`
- `FeishuInboundRouter`
- `RpcResponseRouter`
- `RpcResultProjector`
- `NotificationLifecycleRouter`
- `CodexNotificationRouter`
- `ProviderEventRouter`

## What Is Already In Package

当前已经沉到 `vhttpd/php/package` 的，是 normalized websocket upstream contract：

- `Command`
- `CommandFactory`
- `CommandBatch`
- `CommandBus`
- `Event`
- `EventHandler`
- `EventRouter`
- `Feishu\*` provider-facing message / command / content classes

这层 package 边界目前是健康的。

## What This Refactor Achieved

- 入口文件不再承担命令路由、通知恢复、错误展示、线程上下文恢复
- 入口和测试不再各自维护一份 upstream 对象图，改由 `UpstreamGraphFactory` 统一装配
- `AppRuntime` 接管了入口 handler 的 websocket_upstream 分发与默认 HTTP 响应
- 大部分高风险逻辑已经有命名类，不再靠匿名函数和散落的全局 helper
- 测试不再只依赖大流程，也覆盖了 helper 边界：
  - context helper
  - error helper
  - response helper
  - json helper
  - app runtime http fallback
- 测试入口统一走 Pest，不再额外维护独立 smoke script

## Current Tests

已验证：

- `composer test`

当前基线：

- `47` tests
- `262` assertions

## Boundary Review

更系统的 package/app 边界分析见：

- [`PACKAGE_BOUNDARY.md`](/Users/guweigang/Source/vhttpd/examples/codexbot-app/PACKAGE_BOUNDARY.md)

一句话总结：

- package 负责 normalized contract 和可复用 primitive
- app 负责项目状态、线程恢复策略、命令语义、用户文案、任务生命周期决策

## Recommended Next Moves

如果继续重构，建议按这个顺序推进：

1. 先做依赖注入清理
2. 再决定是否把 `BotJsonHelper` 迁到 package
3. 再评估 `FeishuMessageParser`
4. 最后再决定 `BotResponseHelper` 是否值得升级成 package responder

现在不建议立刻迁的类：

- `BotContextHelper`
- `BotErrorHelper`
- `FeishuCommandRouter`
- `RpcResponseRouter`
- `CodexNotificationRouter`

原因不是“它们不够通用”，而是“它们还绑定 codexbot 自己的业务语义太深”。
