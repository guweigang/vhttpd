# feishu_cb-app-ts

一个最小的 `vjsx` 示例应用，用来单独处理 Feishu `card.action.trigger`，并把点击事件通过宿主桥能力转发回本地。

它的定位不是完整 bot，而是把“卡片点击处理”从主业务 app 里拆出来，便于后续接远端/本地桥。

当前能力：

- `GET /healthz`
- `POST /callbacks/feishu-card`
- Feishu 签名校验
- Feishu 加密 payload 解密
- `challenge` 回应
- 处理 `provider=feishu` 且 `eventType=card.action.trigger` 的 `websocket_upstream`
- 通过 `ctx.runtime.bridgeDispatch(...)` 把卡片点击事件交给宿主桥
- 返回一张最小交互响应卡，证明点击事件已被收到、解析并继续转发

适合用法：

- 作为远端 `vhttpd` 上的 Feishu callback 专用 app
- 作为远端/本地桥接链里的 card-action 专用 app
- 作为调试 Feishu callback / bridge / action payload 的最小基线

最小部署：

- 远端 `vhttpd` 用 [remote.example.toml](/Users/guweigang/Source/vhttpd/examples/feishu_cb-app-ts/remote.example.toml)
- 本地 `vhttpd` 用 [local.example.toml](/Users/guweigang/Source/vhttpd/examples/feishu_cb-app-ts/local.example.toml)
- 远端负责：
  - 对外暴露 `POST /callbacks/feishu-card`
  - 提供 `GET /bridge/ws`
  - `feishu.bridge` 配置里设置 `target_id = "local-main"`
- 本地负责：
  - 在 `[feishu.bridge]` 里配置 `ws_url`
  - 主动回连远端 `/bridge/ws`
  - 用 `client_id = "local-main"` 接收卡片点击桥接请求

本地双 `vhttpd` 模拟：

- 先启动“远端模拟”：
  - `vhttpd --config examples/feishu_cb-app-ts/remote.example.toml`
- 再启动“本地模拟”：
  - `vhttpd --config examples/feishu_cb-app-ts/local.example.toml`
- 这时本地实例会自动连接：
  - `ws://127.0.0.1:19884/bridge/ws`
- 远端模拟继续负责：
  - `POST /callbacks/feishu-card`
- 本地模拟继续负责：
  - codexbot 审批和 `provider.rpc.reply`

如果只是验证桥有没有通，可以先直接 POST 一条卡片点击 payload 到远端的 `/callbacks/feishu-card`，看本地 codexbot/logical app 有没有收到对应 `card.action.trigger`。

不包含：

- Codex 审批业务编排
- 项目/线程状态持久化

这些应该由上层 app 或已有 codexbot 模块继续接入。
