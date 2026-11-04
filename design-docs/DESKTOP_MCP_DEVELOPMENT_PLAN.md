---
title: Desktop MCP 应用开发与远端运维设计
description: 定义项目目录与运行目标绑定、MCP 工具增量、项目与平台指引，以及第一阶段的 ChatGPT 验收。
tags:
  - desktop
  - mcp
  - vjsx
  - development
status: draft
---
# Desktop MCP 应用开发与远端运维设计

ChatGPT 负责理解需求、编辑应用和根据运行证据迭代。Desktop 掌管工作区授权、主机连接、配置校验和运行时操作。第一阶段的交付标准是，用户在 Desktop 选定应用后，ChatGPT 网页能独立完成一次 vjsx 应用修改、业务验证和失败恢复，其他 Web Agent 能通过公网 Relay 直接调用同一个 Desktop MCP。

## 现有实现

Desktop 的开发 MCP 默认关闭，开启后在本机提供带 Bearer 凭据的 Streamable HTTP。应用绑定模式由 Desktop 选定本地运行环境和应用，再从配置推导应用源码目录。MCP 和 GUI 共用 Worker，应用切换会递增选择代次并清空预览。源码修改已有基于 revision 的预览、配置校验、停机应用及会话内恢复；`schema_get` 在运行时使用 Admin 查询并返回 `source: live_admin`。停止时通过所选运行包的 `vhttpd --schema` 读取同一份目录，返回 `source: runtime_package` 和运行包版本。旧运行包缺少该命令时返回 `runtime_schema_unavailable`。配置校验和业务验证是两个独立步骤。 [Desktop MCP 开发服务](../desktop/MCP.md) · [应用上下文实现](../desktop/host/development_application.v) · [Worker 开发入口](../desktop/host/development.v)

本文规划的是 Desktop 的开发与运维工具。应用自身通过 vhttpd 提供的业务 MCP 属于另一条接口。 [vhttpd MCP](./MCP.md)

## 项目目录与运行目标

**源码工作区**是授权读写的应用目录，**运行目标**是执行校验、启停、请求或发布的环境和应用。第一阶段只支持两者与现有本地应用一一对应，数据模型保留两个独立对象，后续可从同一份本地源码发布到多个目标。

| 对象 | Desktop 保存或解析的字段 | MCP 返回的字段 |
| --- | --- | --- |
| 源码工作区 | `workspace_id`、规范化根目录、应用标识、应用配置路径、入口与组件清单路径（如存在） | 工作区 ID、显示名、应用标识及应用相对路径 |
| 运行目标 | `target_id`、本地或远端、环境标识、应用标识、运行包版本及包标识 | 目标 ID、环境与应用名、实际运行包版本、状态、允许操作和重启影响范围 |
| 当前绑定 | `workspace_id`、`target_id`、`binding_revision`、授权生命周期 | 相同的 ID 和代次，用于拒绝过期调用 |

Desktop 提供「绑定项目目录」入口。已有应用从环境与应用选择器进入，预填当前实现推导出的目录，展示目录、入口、目标和影响范围，用户确认后开启 MCP。目录选择器只接受与应用源码归属校验结果一致的根。新应用在 Desktop 选择目录并用现有 HTTP 或 JSON API 模板创建或安装，完成后进入同一绑定流程。目录归属冲突时，界面要求整理为独立应用后再绑定。第一阶段的自选目录通过应用创建或安装接入；任意 Git 工作区与已安装应用解耦留到发布阶段。

每个服务实例只有一个当前绑定。切换由 Desktop 发起，已开始的操作完成后更新代次并清空旧预览。模型每次读取应用上下文后，在后续绑定相关调用中显式提交 `binding_revision`。Worker 在实际执行时比对代次；过期调用返回 `binding_changed`，客户端重新取上下文并确认目标。仅在入队时捕获 Desktop 当前选择，无法识别切换之后到达的旧对话调用。为兼容已配置的本地客户端，可保留现有本地配置；面向 ChatGPT 的配置要求显式代次。

每次文件操作仍经现有边界检查。只接受应用相对路径，拒绝目录穿越、符号链接、其他应用、凭据和共享环境配置。预览记录绑定工作区、目标和文件 revision，应用时再次校验。Desktop 关闭服务后撤销访问；持久化的绑定配置只用于重新选择，用户重新开启服务后获得新会话凭据。

## MCP 公网接入

首期支持三种入口。桌面客户端直连本机 MCP。ChatGPT 可经 Secure MCP Tunnel 接入，也可在工作区支持相应认证方式时走公网入口。其他 Web Agent 可直接配置 Relay 提供的 HTTPS Streamable HTTP URL 和客户端凭据。Desktop 到远端运行目标的主机连接独立于这三种入口。 [OpenAI Secure MCP Tunnel](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels) · [Desktop 主机管理](../desktop/host/remote_servers.v)

公网路径为 `Web Agent → HTTPS MCP 入口 /mcp/<route_id> → Relay Hub → Desktop 侧 Relay Agent → 本机 Desktop MCP /mcp`。用户在 Desktop 的 MCP 页面选定应用后，选择已有可信 Relay，并单独开启「通过 Relay 发布」。Desktop 侧主动连接 Hub，只为当前绑定发布一条有期限的路由，界面提供可复制的 URL、客户端认证配置、到期时间及撤销入口。Desktop MCP 继续监听 loopback。可复用现有 Hub/Agent、`relay-delivery` 和 `mcp-upstream`，但现有示例仅展示本机监听以及 POST/DELETE 转发，公网 TLS、客户端认证、路由生命周期和 Desktop 端到端兼容性需要实现与实测。 [Relay Hub 示例](../examples/config/mcp-relay-public-v2.toml) · [Relay Agent 与 MCP 上游示例](../examples/config/mcp-relay-local-upstream-v2.toml)

- **身份与范围**。Hub 对客户端认证并执行路由级限流。Relay 连接凭据、Web Agent 凭据和本机 MCP 凭据分别管理。首期支持 HTTPS 下的短期、可撤销 Bearer 凭据，按路由和权限签发，默认只读。开启编辑时在 Desktop 明确授权源码写入、启动和停止的范围。Desktop 在 Worker 执行前再次检查路由授权、工具权限和绑定代次。客户端凭据、Relay Token 和本机 MCP Token 不写入工具结果或日志。只接受 OAuth 的客户端需另行适配。
- **转发与会话**。只开放登记的 MCP 路径，目的地固定为该 Desktop 实例的 loopback MCP。转发初始化、POST 和会话终止所需的头、状态与响应；按 Desktop 宣告的能力处理 SSE，若未提供 GET 事件流则保留正确的 HTTP 语义。路由、客户端身份与 MCP 会话关联。断线时返回可识别的不可用状态，重新连接后允许重新初始化，变更调用由客户端先查状态再决定是否重试。
- **撤销**。绑定切换、凭据撤销、路由到期或关闭 MCP 后，旧路由拒绝新调用。Hub 发现 Desktop 离线时停止转发；Desktop 也独立拒绝失效授权。重新发布签发新路由和客户端凭据。公网接入复用现有工作区文件边界及共享运行时保护。

### Relay 创建也由 MCP 编排

新增 `relay_create_prepare`、`relay_create_apply`、`relay_status` 和 `relay_revoke`。用户先在 Desktop 连接远端主机、选择环境，并授权这次操作。工具从现有主机连接和 Worker 执行，不接收 SSH 地址、密码、私钥、任意命令或任意上游 URL。客户端失联时可从 Desktop 继续查询或撤销。

- `relay_create_prepare` 接收已授权的目标 ID、当前绑定代次和只读或编辑模式。校验环境、端口和路由冲突，返回计划 ID、HTTPS 回源端口、MCP 路径、WSS carrier 路径及部署影响。
- `relay_create_apply` 执行短期计划，使用已有运行包启动专用 Hub 或配置已有 Hub，并启动本机出站 Agent。默认用独立进程隔离现有业务监听；需要改动共享进程时在计划中显式列出影响。重复调用返回同一个操作结果。
- `relay_status` 分别报告 Hub 就绪、等待域名、Agent 已连接、MCP 握手可用及已撤销。域名和 TLS 配置仍可由用户在远端网关完成。凭据由 Desktop 保存并通过专用界面交给用户，工具结果只返回可复制的非凭据连接信息。
- `relay_revoke` 先使本机授权失效并断开出站 Agent，再回收该发布创建的远端专用路由或进程。共享 Hub 的其他路由保持运行。

创建工具通过本机管理会话提供，或者通过另外已授权的管理入口提供。公开的应用开发端点只承载其绑定范围内的开发工具，避免公网客户端利用开发凭据开通更多路由。

## 第一阶段的 MCP 工具

| 改动 | 工具 | 契约 |
| --- | --- | --- |
| 扩展 | `context_get` | 返回结构化绑定、代次、运行包与脚本 profile、能力、影响范围、指引目录和可用模板。以应用相对路径代替本机绝对路径 |
| 新增 | `guidance_get` | 按主题读取项目指引、开发工作流和版本化 API 参考。返回来源、版本及正文。未知版本或主题返回明确错误 |
| 扩展 | `schema_get` | 运行中读取目标实时 schema。停止时可读取与目标包匹配的随包 schema，并标明来源。包内缺失时明确返回不可用 |
| 复用 | `templates_list`、`files_list`、`files_read` | 返回模板和应用范围内的内容与 revision。模板带适用版本或 profile，限制与当前行为一致 |
| 复用并加固 | `changes_prepare`、`changes_validate`、`changes_apply`、`changes_restore`、`changes_discard` | diff、配置校验、应用和恢复沿用现有流程；对预览和变更检查绑定与 revision，冲突时重新读取并预览 |
| 复用并补充结果 | `runtime_status`、`runtime_start`、`runtime_stop`、`logs_query`、`application_request` | 状态和启停结果报告作用范围。日志尽可能返回应用标识及请求关联信息。业务验证只调用选定应用的业务监听器 |

启动、停止及源码写入遵循 Desktop 授权。第一阶段验收使用专用本地测试环境。若环境承载多个应用，执行停机前必须按该环境的授权策略核对影响范围。保留已知凭据脱敏与占位符检查。恢复使用现有会话内记录，其覆盖范围是应用文件，Desktop 退出后恢复记录失效。

## 项目指引与平台 Skills

### 应用根目录的 `AGENTS.md`

由应用模板生成，已有应用可维护自己的版本。写入入口、应用清单和允许编辑的目录、目标兼容范围、生成文件、可重复运行的验收请求及预期响应、适用 Skill。可以记录应用特有的业务规则与测试数据约定。运行目标、实时状态和实际能力以 `context_get` 为准。项目指引只作为开发上下文，授权由 Desktop 及 Worker 执行。MCP 通过 `guidance_get` 的项目主题返回该文件；缺失时返回空状态及适用的平台工作流。

### 平台 Skills

| Skill | 编写内容 | 交付阶段 |
| --- | --- | --- |
| `vhttpd-develop` | 根据目标包和 profile 查支持的 API；选择模板，核对入口、模块、import 和宿主能力；按 revision 编辑、校验、启动并用业务请求验证；查日志和恢复 | 第一阶段 |
| `vhttpd-deploy` | Desktop 主机连接和目标选择；应用组件构建、预检、发布、验证与回滚；运行时升级的兼容检查和重启影响 | 远端发布及运行时升级阶段 |
| `vhttpd-debug` | 按应用与请求查日志、本地复现；检查远端现场；接管预检、验证流量归属、释放并确认远端恢复 | 远端诊断及接管阶段 |

每个 Skill 的 `SKILL.md` 放触发条件、操作顺序、失败分支和验收标准。API 签名、配置字段、允许的 import 和示例由与运行包匹配的开发契约维护。第一阶段发布一个可安装的 `vhttpd-develop` Skill，MCP 从同一份发布内容提供工作流。ChatGPT 网页通过工具按主题读取；支持本地 Skills 的客户端可加载同一版本。首批契约覆盖模板实际使用的入口、请求和响应 API、模块边界，以及一条 HTTP 和一条 JSON API 示例。 [vjsx Facade Reference](./VJSX_FACADE_REFERENCE.md)

## 后续远端工具

下表中的名字是提案。各工具复用 Desktop 主机、组件安装和接管实现，由 Desktop 保管凭据与执行授权。

| 能力 | 拟补工具 | 行为 |
| --- | --- | --- |
| 主机发现与诊断 | `targets_list`、`target_status` | 枚举已授权主机、环境、版本、应用和连通状态。首次主机信任与连接在 Desktop 完成 |
| 应用发布 | `application_release_prepare`、`application_release_apply`、`application_release_rollback` | 从明确的源码 revision 生成组件产物，预检目标与冲突，报告配置、迁移及验证结果 |
| 运行时升级 | `runtime_upgrade_prepare`、`runtime_upgrade_apply`、`runtime_upgrade_rollback` | 固定运行包及目标，列出受影响应用、重启范围和恢复版本 |
| 远端接管 | `takeover_status`、`takeover_prepare`、`takeover_start`、`takeover_release` | 记录远端来源、本地接收端、应用和期限，验证流量归属；释放后验证远端重新接流量 |
| 长操作 | `operation_get` | 用 `operation_id` 查询阶段、结果和可恢复性；客户端断线后可重新查询 |

远端写操作使用带期限的 `plan_id`，绑定目标、产物或包版本、基线状态和授权范围。执行前重新比对基线，重试通过操作记录返回原执行结果。远端诊断与应用发布优先，运行时升级和流量接管随后开放。远端源码就地编辑独立评估。 [组件安装](../desktop/host/component_installation.v) · [运行时升级](../src/runtime_upgrade/deployment.v) · [接管实现](../desktop/host/takeover.v)

## 第一阶段验收

在具备写工具权限的 ChatGPT 网页工作区运行以下用例，并从独立网络使用一个支持 HTTPS MCP 和 Bearer 认证的非 ChatGPT Web Agent 验证公网 Relay。保留脱敏后的 Desktop 版本、运行包标识、绑定 ID、工具记录和实际响应。

| 用例 | 操作 | 通过标准 |
| --- | --- | --- |
| 连接与绑定 | Desktop 从 JSON API 模板创建应用，在专用环境绑定源码目录。通过私有隧道连接 ChatGPT | `context_get` 显示正确的工作区、目标、版本、代次和影响范围；凭据与绝对路径未出现在模型结果中 |
| 指引可用 | 只告诉 ChatGPT 业务目标「增加 `GET /api/hello`，返回 `{"message":"hello"}`」，由模型获取指引和源码 | 调用记录显示模型能取得目标版本的 API 参考、项目指引和文件 revision，所用 API 与目标 profile 一致 |
| 完成修改 | ChatGPT 预览、校验、按状态停机并应用、启动，再发业务请求 | 返回 HTTP 200 和约定 JSON；重复请求通过；保留 diff、启动及业务验证证据 |
| 启动失败与恢复 | 保存上述可运行基线，再通过 MCP 引入一个能通过配置校验但无法启动的源码错误 | 启动报告失败，日志支持定位；同一 Desktop 会话内恢复后重新启动，业务响应与基线一致 |
| 边界与冲突 | 尝试越界路径、符号链接、访问另一应用或共享配置；预览后外部修改文件；切换绑定后重用旧代次和预览 | 全部请求被拒绝，原文件与其他应用保持原样；模型能按错误提示重读上下文或重新预览 |
| 会话撤销 | 关闭 Desktop MCP，再用原连接发起调用 | 原连接无法继续访问；重新开启后可在新会话重新获取绑定 |
| Relay 公网直连 | 开启 Relay 发布，从独立网络让 Web Agent 通过公开 HTTPS URL 初始化、列出工具并调用 `context_get`。在专用测试环境显式开启编辑后执行一次修改及业务验证 | 只读凭据调用写工具被拒绝，编辑授权可跑通同一开发闭环；凭据缺失、失效或属于另一条路由时拒绝访问；会话头和所用响应模式正常传递 |
| Relay 断开与撤销 | 暂断 Desktop 到 Hub 的连接，重连后重新初始化。随后切换绑定或撤销路由 | 离线时返回明确的不可用状态，恢复后可重新连接。撤销后旧 URL、凭据和会话无法调用，也无法访问新绑定 |

第一阶段交付包括 Desktop 绑定入口、Relay 公网发布与撤销、工具契约增量、版本化开发参考、模板 `AGENTS.md`、`vhttpd-develop` Skill 和上述验收记录。远端发布、运行时升级与接管采用后续阶段各自的验收。