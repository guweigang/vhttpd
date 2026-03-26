# WebSocket Upstream Plan

## Why This Is An Upstream

`vhttpd` 之前的 `stream upstream` 本质上是：

- `vhttpd` 主动连出到远端服务
- `vhttpd` 持有远端会话生命周期
- `vhttpd` 在本地 runtime 内做协议消费、转发、观测和错误处理

飞书长连接机器人也满足这三个条件。

区别不在于“是不是 upstream”，而在于 transport：

- `stream upstream`
  - 远端 transport 是 HTTP streaming / NDJSON
- `websocket upstream`
  - 远端 transport 是 WebSocket

所以这里更合适的抽象不是“飞书网关”，而是：

- `upstream`
  - `http stream upstream`
  - `websocket upstream`

飞书只是 `websocket upstream` 的第一个 provider。

## Layering

推荐分三层：

1. `upstream runtime`
   - 负责统一的 upstream 语义
   - 生命周期
   - 状态观测
   - admin/runtime 快照

2. `websocket upstream runtime`
   - 建连 / 重连
   - WebSocket client 生命周期
   - ping/pong
   - frame 收发循环
   - provider 分发

3. `provider adapter`
   - provider 专属鉴权和 bootstrap
   - provider frame 编解码
   - provider ack 语义
   - provider 专属发送 API

## Provider Boundary

`websocket upstream runtime` 不应该知道：

- 飞书的 endpoint 拉取接口
- 飞书 protobuf frame 格式
- 飞书的 ack header 约定
- 飞书 tenant access token

这些都应该在 provider adapter。

`websocket upstream runtime` 只应该知道：

- 当前 provider 是谁
- 如何拿到连接 URL
- 收到 binary/text frame 后交给谁处理
- 连接成功/失败/断开时如何记状态

## Current MVP Scope

这次代码先落到以下最小边界：

- 新增通用 `websocket_upstream_runtime.v`
- 由它负责 websocket client loop
- 飞书文件只保留 provider 协议和 REST send 行为
- provider instance 可以按命名配置并行运行，例如 `feishu.main` / `feishu.openclaw`
- admin 视角同时提供：
  - 通用 `GET /admin/runtime/upstreams/websocket`
  - provider 视角 `GET /admin/runtime/feishu`

## Next Steps

下一阶段建议继续往下拆：

1. 把 provider 分发从 `match provider` 提升成更清晰的 provider contract
2. 给 `websocket upstream` 引入统一 session id / name / meta
3. 定义 provider -> worker 的事件桥接协议
4. 再把飞书事件消费从“记录 + ack”升级成“桥接到业务处理器”
