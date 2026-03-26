# PHP Package Role Map

这份文档不按业务主题来介绍 `vhttpd/php/package`，而是按“类在系统里扮演什么角色”来归类。

目标是解决一个现在已经比较明显的问题：

- 目录看起来像在表达领域
- 但很多类的真实职责其实是 model / runtime / app / integration 中的另一种

## Role Taxonomy

这里先用 4 类角色来审视 package：

1. `Model`
   纯数据形态、typed object、view object、value object
2. `Runtime`
   宿主、transport、worker、admin、gateway、connection、host-facing client
3. `App`
   应用组织方式、handler contract、app adapter、developer-facing app shape
4. `Integration`
   把一个系统接进另一个系统的 glue / registrar / facade / factory

判断方法尽量简单：

- 如果核心工作是“表示一个东西”，它更像 `Model`
- 如果核心工作是“和宿主/连接/worker 打交道”，它更像 `Runtime`
- 如果核心工作是“开发者怎么写 app”，它更像 `App`
- 如果核心工作是“把 A 接到 B 上”，它更像 `Integration`

## Current Classification

### `Model`

- `VPhp\VHttpd\Upstream\Plan`
- `VPhp\VHttpd\Upstream\WebSocket\Feishu\Command`
- `VPhp\VHttpd\Upstream\WebSocket\Feishu\Command\AbstractCommand`
- `VPhp\VHttpd\Upstream\WebSocket\Feishu\Command\SendCommand`
- `VPhp\VHttpd\Upstream\WebSocket\Feishu\Command\UpdateCommand`
- `VPhp\VHttpd\Upstream\WebSocket\Feishu\Event`
- `VPhp\VHttpd\Upstream\WebSocket\Feishu\Event\AbstractEvent`
- `VPhp\VHttpd\Upstream\WebSocket\Feishu\Event\CardActionEvent`
- `VPhp\VHttpd\Upstream\WebSocket\Feishu\Message`
- `VPhp\VHttpd\Upstream\WebSocket\Feishu\Message\AbstractMessage`
- `VPhp\VHttpd\Upstream\WebSocket\Feishu\Message\TextMessage`
- `VPhp\VHttpd\Upstream\WebSocket\Feishu\Message\ImageMessage`
- `VPhp\VHttpd\Upstream\WebSocket\Feishu\Message\PostMessage`
- `VPhp\VHttpd\Upstream\WebSocket\Feishu\Message\FileMessage`
- `VPhp\VHttpd\Upstream\WebSocket\Feishu\Message\AudioMessage`
- `VPhp\VHttpd\Upstream\WebSocket\Feishu\Message\MediaMessage`
- `VPhp\VHttpd\Upstream\WebSocket\Feishu\Message\StickerMessage`
- `VPhp\VHttpd\Upstream\WebSocket\Feishu\Content\*`

这些类主要是在表达协议对象或平台对象，本身不负责 app 注册或 runtime orchestration。

### `Runtime`

- `VPhp\VHttpd\Manager`
- `VPhp\VHttpd\VHttpd`
- `VPhp\VHttpd\AdminClient`
- `VPhp\VHttpd\GatewayClient`
- `VPhp\VHttpd\PhpWorker\Server`
- `VPhp\VHttpd\PhpWorker\Client`
- `VPhp\VHttpd\PhpWorker\StreamResponse`
- `VPhp\VHttpd\PhpWorker\WebSocket\Connection`
- `VPhp\VHttpd\PhpWorker\WebSocket\CommandSink`
- `VPhp\VHttpd\PhpWorker\WebSocket\CommandBuffer`

这些类的核心是“怎么跑起来”和“怎么和宿主边界说话”。

这里还多了一层显式语义：

- `VPhp\VHttpd\Attribute\Dispatchable`
  - 它不是 runtime primitive
  - 但它定义了“哪些类是 PhpWorker 直接可识别的 dispatch surface”

### `App`

- `VPhp\VSlim\App\Feishu\BotApp`
- `VPhp\VSlim\App\Feishu\BotHandler`
- `VPhp\VSlim\App\Feishu\AbstractBotHandler`
- `VPhp\VSlim\App\Feishu\BotAdapter`
- `VPhp\VSlim\WebSocket\App`
- `VPhp\VSlim\Mcp\App`

这组类定义的是开发者面向 worker dispatch 时可用的 app shape。

这里特别注意：

- `BotAdapter` 虽然名字里有 `Adapter`
- 但它不是 package-level integration glue
- 它更像 app-facing parsing helper / app adapter

所以当前放在 `VSlim\App\Feishu` 是合理的。

- `WebSocket\App`
  - 是 websocket dispatch shape
  - 会被 `PhpWorker\Server` 直接识别和调度
- `VSlim\Mcp\App`
  - 是 MCP dispatch shape
  - 同样直接参与 worker dispatch contract

### `Integration`

- `VPhp\VHttpd\Upstream\WebSocket\Feishu\McpToolset`
- `VPhp\VHttpd\Upstream\WebSocket\Feishu\Command\Factory`
- `VPhp\VHttpd\Upstream\WebSocket\Feishu\Event\Factory`
- `VPhp\VHttpd\Upstream\WebSocket\Feishu\Message\Factory`
- `VPhp\VHttpd\Psr7Adapter`
- `VPhp\VSlim\Psr7Adapter`
- `VPhp\VSlim\Stream\Factory`
- `VPhp\VSlim\Stream\OllamaClient`
- `VPhp\VSlim\DbGateway\PDO`
- `VPhp\VSlim\DbGateway\PDOStatement`

这组类的共同点是：

- 它们不是单纯 model
- 也不是宿主 runtime 自身
- 它们在做“把一套能力接到另一套能力上”的工作

其中最典型的是：

- `McpToolset`
  - 把 Feishu 能力注册进 `VSlim\Mcp\App`
- `Psr7Adapter`
  - 把 envelope / request / response 接到 PSR 世界
- `VSlim\Stream\Factory`
  - 把 VSlim app-facing stream 写法接到 worker/upstream 能力

## Current Mismatch Hotspots

下面这些类即使现在目录已经比以前清楚，角色表达上仍然值得再收敛。

### `VPhp\VSlim\Mcp\App`

现状：

- 在 `VSlim` 目录下
- 但它不只是 transport helper
- 它实际上是一个 protocol-app builder / registrar host

它现在放在 `VSlim` 是合理的，因为它表达的是一类 app shape，同时 worker dispatch 会直接消费它。
但从角色上说，它也不是典型的 transport primitive，而是一个 protocol-app builder / registrar host。

### `VPhp\VSlim\WebSocket\App`

现状：

- 也放在 `VSlim` 目录下
- 但它表达的是 websocket handler/app shape，而不是 websocket transport primitive

这个类和 `VSlim\Mcp\App` 是同一类问题：

- 应该保留在 `VSlim`
- 但应和 `Connection` / `CommandSink` / `CommandBuffer` 这种 transport contract 分层看待

### `VPhp\VHttpd\Upstream\WebSocket\Feishu\McpToolset`

现状：

- 目录比放在 `PhpWorker` 时对了很多
- 但类名 `McpToolset` 仍然偏弱

它真实在做的是：

- 依赖 `VSlim\Mcp\App`
- 向 `VSlim\Mcp\App` 注册 Feishu tool definitions

所以它更像：

- `Registrar`
- `Integration`
- `App Toolset`

如果后面还要继续收敛命名，这个类最值得继续推敲。

### `VPhp\VSlim\Stream\Factory`

现状：

- 名字叫 `Factory`
- 实际上混合了：
  - response builder
  - stream dispatch builder
  - upstream plan builder
  - ollama integration entry

也就是说，它现在不只是一个简单 factory，而是一个“stream integration facade”。

如果未来继续拆分，可能要把：

- 本地 stream response builder
- dispatch builder
- upstream plan builder

分成更清楚的角色。

### `VPhp\VHttpd\GatewayClient`

现状：

- 名字是通用 `GatewayClient`
- 实际 provider path 里已经内置了 Feishu 语义

它现在是：

- runtime client
- 但也带有 provider-specific convenience methods

这意味着它同时承担了：

- generic gateway transport
- Feishu convenience facade

后面如果 provider 增多，这里可能会继续变混。

## Recommended Next Pass

如果下一轮要继续清理，我建议优先看这 3 个方向：

1. `McpToolset`
   要不要从 `Toolset` 进一步命名成 `Registrar` 一类
2. `VSlim\Stream\Factory`
   要不要拆成更明确的 app helper / upstream helper / dispatch helper
3. `PhpWorker`
   要不要在目录或文档层面继续明确区分 transport primitives 和 dispatch shapes

## Practical Rule

后面给 package 新增类时，建议先问 2 个问题：

1. 这个类是在“表示一个东西”，还是在“连接两套系统”？
2. 这个类主要服务的是“runtime”，还是“app 开发者”？

如果这两个问题先答清楚，目录和命名通常就不会走偏太远。

对于 `PhpWorker` 这条线，再多问一个问题：

3. 这个类是否需要被 `PhpWorker\Server` 直接识别和调度？

如果答案是“是”，那它应该：

- 要么是已有内建 dispatchable
- 要么显式加上 `VPhp\VHttpd\Attribute\Dispatchable`
