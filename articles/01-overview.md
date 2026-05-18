# vhttpd: 面向 PHP / TypeScript / AI 应用的高性能 Transport Runtime

过去很多年里，我们理解 Web 应用运行时的方式都比较固定。

PHP 应用通常交给 `nginx + PHP-FPM`。
Node 应用通常自己监听 HTTP。
实时通信交给 WebSocket server。
AI token streaming 再额外写一层 SSE gateway。
MCP、Bot、OpenAI Gateway、Ollama Proxy、飞书长连接，又各自变成一套独立服务。

这些方案都能工作，但它们带来一个共同问题：

> 协议入口越来越多，运行时越来越碎。

一个现代应用可能同时需要：

- 普通 HTTP request / response
- SSE 或 text stream
- WebSocket
- 上游 token stream
- MCP Streamable HTTP
- 飞书这类长连接或事件入口
- PHP 业务系统
- TypeScript 写的协议适配和插件逻辑
- 可观测的 worker pool、queue、timeout、runtime stats

如果这些能力分散在不同进程、不同语言、不同代理和不同框架里，开发和运维都会变得很重。

`vhttpd` 想解决的，就是这个问题。

## vhttpd 是什么？

一句话说：

> vhttpd 是面向 PHP / TypeScript / AI 应用的高性能 transport runtime。

它不是传统意义上的业务框架，也不只是一个反向代理。

更准确地说，`vhttpd` 是一个运行在协议层和业务逻辑之间的 runtime gateway：

- 它终止 HTTP / WebSocket / stream 连接。
- 它管理 worker、executor 和插件宿主。
- 它承载 SSE、MCP、上游 token stream 等现代协议形态。
- 它把 PHP、TypeScript、WebSocket upstream、AI gateway 放到统一 runtime 里调度。
- 它通过 admin plane 暴露 runtime state、stats、worker queue 和 active sessions。

传统 Web server 更关心“请求怎么转发”。

`vhttpd` 更关心：

> 连接、流、worker、插件、上游协议和运行时状态，如何被统一管理。

## 为什么基于 V？

`vhttpd` 基于 V 语言和 `veb` 构建。

这带来几个很实际的优势。

第一，`vhttpd` 可以作为单独的 CLI binary 运行。部署时不需要一整套语言运行环境来承载核心 server。

第二，V 的性能和编译型特性适合做 runtime 层。HTTP ingress、worker 调度、stream 转发、WebSocket 管理、admin stats 这些能力，都适合放在一个轻量、稳定、可控的核心里。

第三，`vhttpd` 尽量贴近 `veb` 和 V 标准 HTTP 能力。它不试图重新发明一个庞大的 Web 框架，而是把重点放在 transport、worker orchestration、stream lifecycle 和 observability 上。

这也是 `vhttpd` 的设计边界：

> 业务逻辑交给 executor / worker / plugin，vhttpd core 专注 runtime。

## PHP：让成熟生态获得现代 runtime 能力

PHP 仍然是非常重要的业务语言。

Laravel、Symfony、WordPress，以及大量存量系统，都已经承载了真实业务。问题不在于 PHP 不能写业务，而在于传统 PHP 运行模型对某些现代场景并不友好。

比如：

- SSE token streaming 容易受到 buffering、timeout、proxy 配置影响。
- WebSocket 和长连接不是 PHP-FPM 的自然形态。
- AI gateway 需要稳定处理上游流和下游流。
- Bot / Feishu 这类事件入口通常需要额外服务承载。
- worker 生命周期、queue、restart、runtime stats 分散在不同组件里。

`vhttpd` 的 PHP 支持不是“能跑 PHP 文件”这么简单。

它通过 `php-worker` 模型，让 PHP 应用继续负责业务逻辑，而 `vhttpd` 负责更底层的 runtime 问题：

- worker pool
- request dispatch
- timeout
- restart / backoff
- stream frame
- SSE / text stream
- admin stats
- runtime visibility

这意味着 PHP 应用可以获得更现代的 transport 能力，同时保留原有生态。

`vhttpd` 已经提供了 Laravel、Symfony、WordPress 示例，也有 Feishu PHP example，用来证明它不只是 hello world，而可以承载真实的应用集成场景。

一句话说：

> vhttpd 不是替代 PHP，而是补齐 PHP 在现代 runtime 场景里的短板。

## vjsx：TypeScript Plugin Layer

除了 PHP worker，`vhttpd` 还支持 `vjsx`。

`vjsx` 可以理解为 `vhttpd` 的 embedded executor，也可以理解为 TypeScript / JavaScript plugin layer。

这非常重要。

因为很多协议适配和 gateway 逻辑变化很快。比如：

- OpenAI-compatible gateway
- Ollama proxy
- DashScope coding plugin
- Feishu event adapter
- Bot command logic
- Paseo relay
- webhook glue code
- 轻量 API handler

这些逻辑如果全部写进 core，会让 runtime 变重。如果全部拆成外部服务，又会增加部署和通信成本。

`vjsx` 提供了一个折中方案：

> vhttpd core 保持轻量稳定，变化快的扩展逻辑交给 TypeScript plugin。

PHP 适合承载成熟业务系统。
`vjsx` 适合写协议 glue code、AI gateway、Bot adapter 和快速变化的插件逻辑。

它们不是互相替代，而是共享同一个 `vhttpd` runtime。

## WebSocket、SSE、MCP 与上游流

现代应用越来越不像传统 request / response 应用。

AI 应用需要 token streaming。
Bot 应用需要接收上游事件。
协作应用需要 WebSocket relay。
Agent 应用需要 MCP Streamable HTTP。
Gateway 应用需要把上游模型流转成下游 SSE 或 text stream。

这些能力在 `vhttpd` 里不是零散功能，而是统一 transport runtime 的不同 surface：

- HTTP
- Stream
- WebSocket
- MCP
- WebSocket upstream

比如：

- Ollama proxy 可以走 upstream token stream。
- OpenAI Gateway 可以通过 `vjsx` plugin 做协议适配。
- Feishu 可以作为 outbound WebSocket upstream。
- MCP 可以通过 Streamable HTTP 承载。
- Paseo relay 可以用 WebSocket runtime 承载复杂连接编排。

这就是 `vhttpd` 和普通 Web server 最大的区别之一。

它不仅处理 HTTP 请求，还处理连接生命周期和流生命周期。

## 可观测和可运维

一个 runtime 要真正能用，不能只看功能，还要能观察和管理。

`vhttpd` 提供 admin plane，用于查看运行状态，例如：

- runtime summary
- worker stats
- worker queue
- active upstream sessions
- active MCP sessions
- WebSocket upstream events
- Feishu runtime state

它也支持 TOML-first config、pid file、event log、multi-listener、systemd、launchd 等生产部署相关能力。

这让 `vhttpd` 不只是一个开发 demo server，而是朝着可运维 runtime 的方向设计。

## 市面上已经有什么？

`vhttpd` 不是站在一个空白市场里。

相邻产品已经很多：

- FrankenPHP 是成熟的现代 PHP application server，支持 worker mode、Laravel/Symfony 集成、实时能力、metrics、HTTP/2、HTTP/3 和自动 HTTPS。
- RoadRunner 是 Go 写的 PHP application server / process manager，核心是 worker pool 和插件系统。
- Swoole / OpenSwoole 把异步、协程、HTTP/WebSocket/TCP runtime 带进 PHP 扩展层。
- Laravel Octane 是 Laravel 对 FrankenPHP、RoadRunner、Swoole、OpenSwoole 等高性能 app server 的集成层。
- LiteLLM Proxy 专注 OpenAI-compatible LLM gateway。
- Envoy AI Gateway 专注云原生 AI/MCP gateway、路由、安全、限流和可观测。

所以 `vhttpd` 的宣传不应该说“市面上没有类似产品”。

更准确的说法是：

> 已有产品分别解决了 PHP worker runtime、WebSocket、AI Gateway、MCP Gateway 等问题；vhttpd 的机会是把 PHP worker、TypeScript plugin、WebSocket upstream、SSE/MCP/AI stream 和 runtime observability 组合成一个轻量 transport runtime。

## vhttpd 适合谁？

如果你的应用只是普通 CRUD，传统 Web server 当然也能很好工作。

但如果你正在做下面这些事情，`vhttpd` 会变得很有价值：

- PHP 应用需要 SSE / AI token streaming。
- Laravel / Symfony / WordPress 项目想接入 AI Gateway。
- 需要用 PHP 或 TypeScript 写飞书机器人。
- 需要 OpenAI-compatible gateway 或 Ollama proxy。
- 需要 MCP Streamable HTTP。
- 需要 WebSocket relay 或实时连接编排。
- 希望用一个 runtime 同时承载 PHP worker 和 TypeScript plugin。
- 希望 runtime 层有 worker pool、queue、timeout、admin stats。

`vhttpd` 的目标不是替代所有 Web server。

它更像是为一类新型应用准备的运行时：

> 协议很多、流很多、worker 很多，但你不想把系统拆得很碎。

## 总结

`vhttpd` 的核心价值可以概括成三句话。

第一，`vhttpd` 是 transport runtime，不只是 HTTP server。

它统一承载 HTTP、WebSocket、SSE、MCP、upstream stream 等协议形态。

第二，`vhttpd` 让 PHP 获得现代 runtime 能力。

PHP 继续负责业务，`vhttpd` 负责 worker、stream、连接生命周期和可观测性。

第三，`vjsx` 让 `vhttpd` 拥有 TypeScript plugin layer。

变化快的 gateway、bot、协议适配和 glue code，可以用 TypeScript 快速扩展。

如果说传统 Web server 解决的是“请求如何进入应用”，那么 `vhttpd` 更关心的是：

> 现代应用的协议、连接、流、worker 和插件，如何在一个轻量 runtime 里协同工作。

这就是 `vhttpd` 要解决的问题。
