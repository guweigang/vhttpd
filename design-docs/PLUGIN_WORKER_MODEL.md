# Plugin / Worker Model

这页回答的是下一阶段架构问题，不是当前配置怎么写：

- `vjsx` 在 `vhttpd` 里到底算 `executor`、`plugin`，还是 `worker`？
- 后面如果既要可编程插件能力，又要保留独立执行形态，边界应该怎么切？

结论先放前面：

- **在产品定位上，`vjsx` 更像 plugin runtime**
- **在当前实现上，`vjsx` 仍然以 builtin executor 形态接入**
- **未来 worker 形态应该是补充，不应该替代 plugin 形态**

## 1. 当前现实

今天 `vhttpd` 的 built-in executor catalog 里只有两类：

- `php`
- `vjsx`

它们都通过 executor 入口进入 server/runtime 组装流程。

也就是说，从当前代码看：

- `vjsx` 是 executor
- `php-worker` 是 worker-style executor backend

但如果从“你希望它长期承担什么角色”来看，这个定义还不够。

## 2. 为什么说 `vjsx` 更像 plugin runtime

`vjsx` 在 codexbot 场景里承担的并不只是“处理一个 HTTP 请求”：

- 它要补充 `vhttpd` 自身能力
- 它要消费 runtime snapshot / emit / provider runtime
- 它要做 bot / card / codex / feishu 这类编排逻辑
- 它天然更接近“可编程宿主扩展层”

这类能力更像：

- host plugin
- runtime extension
- programmable control/app layer

而不只是“另一个语言 executor”。

所以长期上更准确的理解应该是：

- `php` 主要是 app executor
- `vjsx` 主要是 programmable plugin/runtime layer

## 3. 为什么当前不直接把 `vjsx` 改成 plugin-only

因为现在它已经承担了一个很现实的职责：

- 作为内建 embedded executor，直接接住 HTTP dispatch

这个能力非常有价值：

- 零 worker 进程
- 适合轻量 app / bot / glue logic
- 对 codexbot 这种例子非常顺手

如果现在强行把它改成 plugin-only，会丢掉一部分已经很好用的入口。

所以更合理的路线不是“替换”，而是“分层”：

- 短期：保留 `vjsx` executor
- 中期：把 `vjsx` 背后的 host/runtime 能力抽出来，形成 plugin seam
- 长期：允许同一套 `vjsx` runtime 既能当 executor，也能当 plugin

## 4. 推荐的三层模型

建议把后续模型拆成 3 层：

### A. Executor

职责：

- 接受 data plane dispatch
- 产出 HTTP / stream / websocket_upstream 等执行结果

典型例子：

- `php`
- `vjsx`
- future `lua`

### B. Worker Backend

职责：

- 管理独立执行单元
- 负责生命周期、调度、并发、重启、队列

典型例子：

- `php-worker`
- future `vjsx-worker`
- future external sidecar

重点：

- worker backend 不等于 executor
- 它是“执行承载方式”，不是“业务语义种类”

### C. Plugin Runtime

职责：

- 扩展 `vhttpd` runtime 能力
- 订阅 runtime / provider / session / admin surface
- 暴露宿主可编程逻辑

典型例子：

- `vjsx plugin`
- future internal automation / routing / bot plugins

## 5. 这三层之间的关系

推荐关系是：

- executor 决定“请求由谁处理”
- worker backend 决定“这个 executor 跑在哪”
- plugin runtime 决定“宿主能力如何被扩展”

所以未来可以出现这些组合：

### 组合 1

- executor = `php`
- worker backend = `php-worker`
- plugin runtime = none

### 组合 2

- executor = `vjsx`
- worker backend = in-process
- plugin runtime = `vjsx`

### 组合 3

- executor = `vjsx`
- worker backend = `vjsx-worker`
- plugin runtime = `vjsx`

### 组合 4

- executor = `php`
- worker backend = `php-worker`
- plugin runtime = `vjsx`

最后这个组合其实很重要，因为它说明：

- `vjsx plugin` 不必和 `vjsx executor` 绑定
- 它完全可以作为 PHP app 前面的可编程插件层存在

## 6. 对 codexbot 的直接含义

在 codexbot 项目里，更合适的定位是：

- **今天**：`vjsx` 以 executor 形态跑 codexbot app
- **长期**：codexbot 更接近一个 `vjsx plugin app`

也就是说，今天这样做没有错，但长期目标不应只停在 executor。

## 7. 推荐实施顺序

建议按下面顺序推进，而不是一次性大重构：

### Phase 1

完成的基础：

- multi-listener
- multi-site config DSL

这一步已经把“一个进程服务多个项目”打通了。

### Phase 2

把 **plugin seam** 先抽出来。

目标不是马上支持复杂 marketplace，而是先明确：

- plugin 能拿到哪些 host API
- plugin 生命周期是什么
- plugin 和 provider/runtime/admin 的边界在哪

这是现在最值得做的一步。

### Phase 3

再看 **worker backend 抽象**。

也就是把：

- `php-worker`

从“唯一 worker 形态”提升成：

- generic worker backend interface

这样以后 `vjsx-worker` 才有自然位置。

### Phase 4

如果确实有场景需要：

- 长耗时 JS/TS 执行
- 隔离内存/崩溃域
- 独立热更新

再引入 `vjsx-worker`。

## 8. 为什么 plugin 要先于 vjsx-worker

因为 `vjsx-worker` 解决的是“承载方式”问题：

- 隔离
- 并发
- 重启
- 资源边界

而你当前真正更缺的是“角色边界”问题：

- `vjsx` 到底是 app executor 还是 host extension？

这个问题不先解决，直接上 `vjsx-worker` 很容易把模型越做越混。

## 9. 下一步落点

下一步最合适的不是直接写 `vjsx-worker`，而是先定义一层最小 plugin contract，比如：

- `plugin.kind`
- `plugin.lifecycle.start/stop`
- `plugin.capabilities`
- `plugin.host_api`

然后先让 `vjsx` 作为第一种 plugin runtime 落进去。

这样后面：

- executor 继续稳定
- worker backend 继续稳定
- plugin 也有自己独立演进空间

这是三条线都比较干净的路线。
