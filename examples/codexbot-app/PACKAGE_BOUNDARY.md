# Codex Bot Package Boundary

## Goal

这份文档回答一个很具体的问题：

- 哪些能力应该进入 `vhttpd/php/package`
- 哪些能力应该继续留在 `vhttpd/examples/codexbot-app`
- 下一轮重构时，应该优先迁哪些，暂时不要碰哪些

判断标准只看一件事：

- 这个能力是不是“脱离 codexbot 自己的项目表 / 任务表 / 文案 / 命令语义”之后，依然成立

如果答案是：

- `是`
  更适合进 package
- `不是`
  更适合留 app

## Current Split

现在已经明确进入 package 的，是 websocket upstream 的 normalized contract：

- `VPhp\VHttpd\Upstream\WebSocket\Command`
- `VPhp\VHttpd\Upstream\WebSocket\CommandFactory`
- `VPhp\VHttpd\Upstream\WebSocket\CommandBatch`
- `VPhp\VHttpd\Upstream\WebSocket\CommandBus`
- `VPhp\VHttpd\Upstream\WebSocket\Event`
- `VPhp\VHttpd\Upstream\WebSocket\EventHandler`
- `VPhp\VHttpd\Upstream\WebSocket\EventRouter`
- `VPhp\VHttpd\Upstream\WebSocket\Feishu\*`

这层边界是对的，因为它们表达的是 provider-neutral 或 provider-facing contract，
不依赖 codexbot 的业务表结构。

## Stay In App

下面这些类现在应该继续留在 `codexbot-app`。

### 0. app composition root

- `AppRuntime`
- `UpstreamGraphFactory`

原因：

- `AppRuntime` 负责这个 app 的入口分流、默认 HTTP 响应、websocket_upstream 接入方式
- `UpstreamGraphFactory` 负责把 codexbot 自己的 repository / service / router / handler 装成一张运行时对象图
- 它们描述的是这个 app 的启动方式，不是 websocket upstream package 的通用能力

例子：

- `AppRuntime` 决定 `/health` 返回什么、未知 path 如何回 404
- 当前 graph 里会绑定 `ProjectRepository`、`TaskRepository`、`FeishuCommandRouter`
- 如果以后 `codexbot-app` 增加新的 provider-specific router，应该改这里，而不是改 package

### 1. 直接绑定 app 状态模型的类

- `BotContextHelper`
- `ThreadViewHelper`

原因：

- 依赖 `tasks` / `projects` 表的当前设计
- 依赖 `project_key`、`current_thread_id`、`pending_bind` 这些 codexbot 语义
- 里面的“选线程”和“展示线程”规则不是通用 websocket upstream 规则

例子：

- `preferredThreadId(...)`
  是 codexbot 的会话恢复策略，不是 package 的通用策略
- `createPendingThreadSelection(...)`
  依赖 `use_thread`、`pending_bind` 这样的任务类型设计
- `renderThreadLatest(...)`
  依赖当前中文文案、当前任务历史展示格式

### 2. 直接绑定 app 命令语义的类

- `FeishuCommandRouter`
- `FeishuInboundRouter`
- `RpcResultProjector`
- `RpcResponseRouter`
- `CodexNotificationRouter`
- `NotificationLifecycleRouter`
- `ProviderEventRouter`

原因：

- 它们不只是“路由 upstream event”
- 它们还定义了 codexbot 自己的产品行为

例子：

- `/bind`、`/switch`、`/use latest`、`/thread recent`
  都是 app 命令，不是 package contract
- `thread not found` 时清空当前线程
  是 codexbot 的恢复策略，不是所有 app 都该这么做
- `rateLimits/updated` 时输出“额度已耗尽”
  是 codexbot 的用户提示策略，不是 package 的基础职责

### 3. 明显是 app copy / app UX 的类

- `BotErrorHelper`

原因：

- 它包含大量用户可见文案
- 文案完全围绕 codexbot 的产品体验设计

例子：

- “请发送 /new 重置会话”
- “先发送 /threads 查看可用线程”
- “如果刚才连续跑了很多任务，这类限制通常会自动恢复”

这些都不是 package 应该替 app 决定的内容。

## Good Package Candidates

下面这些能力值得逐步沉到 package，但建议先抽象 API，再迁代码。

### 1. `BotJsonHelper`

当前状态：

- 已经是纯技术 helper
- 不依赖数据库
- 不依赖 codexbot 业务表
- 只做“宽容解码 + 嵌套字符串 JSON 展开 + stderr 诊断”

为什么值得进 package：

- `Event::fromDispatchRequest(...)`
- Feishu content parsing
- provider rpc raw payload parsing

这些场景在别的 app 里也会重复出现。

更合适的 package 名字：

- `VPhp\VHttpd\Upstream\Support\JsonDecoder`
- `VPhp\VHttpd\Upstream\Support\NestedJsonDecoder`

好的 package API 例子：

```php
$decoder = new NestedJsonDecoder();
$payload = $decoder->decode($raw, 'codex.raw_response');
```

### 2. `FeishuMessageParser`

当前状态：

- 处理的是 Feishu provider payload
- 不依赖 codexbot 项目表 / 任务表
- 逻辑本质是“把 Feishu message 归一化成可读文本”

为什么值得进 package：

- 任何 Feishu bot app 都可能需要
- 和当前 package 里已有的 `Feishu\Message\*` 很接近

更合适的 package 方向：

- 不一定叫 `Parser`
- 更像 `Feishu\MessageTextExtractor`
- 或者给现有 `Feishu\Message\*` 增加 `plainText()` / `summaryText()` 能力

好的 package API 例子：

```php
$message = VPhp\VHttpd\Upstream\WebSocket\Feishu\Message\Factory::fromPayload($payload);
$text = $message->plainText();
```

再举几个适合的例子：

- `text` message 取 `content.text`
- `post` message 展平标题与段落
- `image` / `file` / `audio` message 输出安全的占位文本

### 3. `BotResponseHelper`

当前状态：

- 已经没有业务依赖
- 只是把 `array command` 与 `CommandBus` 之间做了一层轻量桥接

它是否应该进 package：

- `可能要`
- 但优先级没有 `BotJsonHelper` 和 `FeishuMessageParser` 高

原因：

- package 里已经有 `CommandBus`
- `BotResponseHelper` 本质上是在补 “response envelope ergonomics”

更好的 package 落法不是原样搬过去，而是升级成更明确的 API。

好的 package API 例子：

```php
$reply = new CommandResponder();

return $reply->one(
    CommandFactory::providerMessageSend('feishu', [...]),
);
```

再举几个可能的 API：

- `CommandResponder::one(Command|array $command): array`
- `CommandResponder::many(iterable $commands): array`
- `CommandResponder::append(?array $response, CommandBus $bus): bool`

## Bad Package Candidates

下面这些“看起来像 helper”，但现在不应该急着进 package。

### 1. `BotContextHelper`

为什么不该急着迁：

- 它不是 generic context
- 它是“codexbot 任务库 + 线程恢复策略”的封装

如果以后真的想迁，前置条件应该是先抽出 package-level contract：

- `ThreadSelectionStore`
- `RecoveryContextStore`
- `TaskStateStore`

没有这些接口之前，直接把它搬去 package，只是把 app 逻辑搬了个位置。

### 2. `BotErrorHelper`

为什么不该急着迁：

- 判断条件里混着 provider error taxonomy
- 输出里混着 app 文案和操作建议

如果以后要沉 package，正确拆法应该是先拆成两层：

- package:
  provider-neutral `ErrorClassifier`
- app:
  `CodexBotErrorPresenter`

更具体一点：

- package 负责告诉你 “这像 thread-not-found / rate-limit / system-error”
- app 决定“给用户看什么卡片、推荐发 `/new` 还是 `/threads`”

### 3. `RpcResponseRouter` / `CodexNotificationRouter`

为什么不该急着迁：

- 名字像 infrastructure
- 实际上里面包含大量 codexbot 的行为决策

例子：

- `thread/read` 成功后要不要 resolve pending bind
- `thread not found` 后要不要自动清空当前线程
- `rateLimits/updated` 要不要变成飞书卡片
- `item/completed` 完成后要不要自动 `stream.finish`

这些都不是 package 应该替所有 app 统一规定的。

## Recommended Next Package Moves

如果下一轮要继续把能力沉到 `php/package`，建议顺序如下：

1. `BotJsonHelper`
2. `FeishuMessageParser`
3. `BotResponseHelper`

这个顺序的原因是：

- 依赖最少
- 风险最低
- 迁完能让多个 app 立即复用
- 不会过早把 codexbot 的业务语义塞进 package

## Recommended App Cleanup

即使暂时不迁 package，app 侧也还有一件值得做的事：

- 不再在各个 router 里 `new BotResponseHelper()` / `new BotJsonHelper()` / `new BotErrorHelper()`
- 改成在构造器里显式注入

这样好处有三个：

- 依赖图更清晰
- 测试替身更容易做
- 以后真的迁 package 时，改动面更小

例子：

```php
new RpcResultProjector(
    $taskRepo,
    $streamRepo,
    $projectRepo,
    $sessionService,
    $taskStateService,
    new BotJsonHelper(),
    new BotResponseHelper(),
    new ThreadViewHelper(),
);
```

再进一步的方向：

- 把 provider-facing helper 注入到 router
- 把 app state helper 注入到 projector / notification router
- 让 “new 某 helper” 只出现在 bootstrap

## Short Conclusion

一句话总结当前边界：

- package 负责 normalized upstream contract、provider payload model、可复用 parsing/building primitive
- app 负责项目状态、线程恢复策略、命令语义、用户文案、任务生命周期决策

一句话总结下一步：

- 先迁 `BotJsonHelper`
- 再迁 `FeishuMessageParser`
- 最后再决定 `BotResponseHelper` 是不是值得升级成 package 级 responder
