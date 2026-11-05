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

## vhttpd 与 Desktop 的能力覆盖设计

Agent 需要能发现目标版本提供的能力，查到使用契约，并在授权范围内完成配置、执行、验证和恢复。能力清单按实际入口维护。vhttpd 的 schema、运行时注册表和 Admin 操作描述运行时能力，Desktop 的 Host/Worker 操作描述工作区和主机管理能力。下面的状态按仓库当前 MCP 工具登记核对，区分工具已存在和工作流已验收。

| 能力域 | 已有 MCP 入口 | 需要补齐 |
| --- | --- | --- |
| 工作区、应用与模板 | `context_get`、模板发现与创建、`application_install_prepare/apply`、文件 revision 变更和 Desktop 应用绑定 | 任意源码工作区与已安装应用解耦。工作区、应用和管理会话已分别执行授权检查 |
| vhttpd 配置与数据面 | 停机或实时 `schema_get` 覆盖九个配置域，应用变更校验与业务 HTTP 请求，远端 `target_request` | 流式 HTTP、WebSocket 和应用业务 MCP 的协议级验证工具。共享配置当前只支持 pipeline 的精确匹配路径 |
| 应用脚本、兼容库与集成 | vjsx 参考，pipeline、微信云开发兼容、Codex Bot 模板和独立 `guidance_get` 主题，三个已安装的 DSH Skills | 微信真实登录、数据库及存储、已有云函数迁移和公网专项验收仍需补齐 |
| Desktop 主机和环境管理 | 主机登记、连接、断开，环境发现与身份校验接入，以及环境创建、实例启停均已有 MCP 工具，并通过当前 Desktop 与 DSH 隔离环境验收 | 密码认证仍须在 Desktop 完成，首次主机指纹确认继续由 Desktop 管理；工具不接收私钥路径或密码 |
| 运行包与发布 | 本地启停，远端应用发布及回滚、运行时升级及回滚；官方运行包发现、下载、安装、本机选择及恢复已通过当前 Desktop 与 DSH 验收；配置兼容性预检、应用安装与历史查询、共享 pipeline 路径变更及恢复 | 超出 pipeline 精确路径的共享配置变更 |
| Relay 与流量接管 | 公网 MCP Relay 发布与回收、账号接管与释放；普通 Relay 连接库、配置、启停和恢复；手工 Relay 的字段编辑、Hub/Agent 转换、字段删除、多 include 来源变更及精确恢复；MySQL 专项探针，均有实际 Desktop 与 DSH 验收 | 非 WebSocket 载体、任意嵌套 options 修改及业务表、迁移和具体应用数据的专项验证 |
| 运维诊断与恢复 | 本机和远端运行图、worker、provider、Relay、进程级 WebSocket 统计；远端应用日志、事件、安装身份、发布及升级历史、业务 GET/HEAD 验证 | 配置历史恢复、流式 HTTP 与 WebSocket 业务协议探针，以及更完整的受控运行计划替换 |

### MCP、指引与 Skills 的分工

- MCP 是发现和执行入口。扩展 `context_get` 绑定上下文，并提供可按能力域查询的目录。每项返回稳定 ID、目标版本、schema 或指引入口、所需授权、对应工具、当前可用性和原因。目录区分运行时支持、Desktop 支持、已对当前会话开放三个状态。运行中的数据以目标实时能力为准，离线时使用对应运行包并注明来源。
- 配置型能力优先复用 schema、变更集和通用验证。主机连接、运行包操作、远端发布、共享配置变更、Relay 和接管使用有类型的工具，复用 Desktop Host/Worker 或 vhttpd Admin 的既有实现。写操作使用明确目标、预检、可查询的操作记录，并声明恢复方式。凭据、授权授予和可见的交互确认由 Desktop 提供，Agent 能查询所缺的授权和完成后的状态。
- Skills 说明如何选择和组合工具。现有三个 Skill 保持稳定入口，`vhttpd-develop` 根据项目形态读取开发契约，`vhttpd-deploy` 按应用发布、环境配置、运行包或 Relay 选择操作，`vhttpd-debug` 按配置、应用、协议和远端流量定位问题。主题指引随运行包或 Desktop 版本发布，由 `guidance_get` 提供同源内容。项目 `AGENTS.md` 记录实际入口、约束、目标和验证命令。
- 公网 Relay 与本机 MCP 使用同一能力模型，按工作区、运行目标和操作授予权限。应用编辑会话与平台管理会话分别授权。能力目录显示当前可用范围，Worker 执行时再次校验授权和绑定代次。

### 按项目形态验收

| 项目起点 | Agent 要完成的工作 |
| --- | --- |
| 空工作区 | 从能力目录选择模板，创建源码和绑定，校验、启动、请求验证并发布 |
| 已有 vhttpd 应用 | 发现入口、profile 和现有能力，修改并验证，发布更新并恢复 |
| 微信云开发兼容应用 | 分别验证从模板新建和已有云函数接入，调用实际云函数，验证所用兼容库能力并发布 |
| Codex Bot 应用组件 | 用仓库现有组件接入，识别其组件配置、vjsx 和 provider 依赖，校验、安装并验证业务入口 |
| 纯配置 | 从 TOML 定义 listener、pipeline 和 adapter，核对匹配和未匹配请求。应用级配置走组件发布与回滚。共享环境配置走单独的配置预检、应用与恢复 |

### 实施与覆盖判定

1. 建立可检查的能力清单，按源码注册项与 Desktop 操作逐条登记。为每项记录发现入口、schema 或指引、执行工具、授权、验证和恢复，以及首个支持版本。注册项新增而目录缺失时由测试报出。
2. 补齐项目入口和 Skill 路由，先覆盖纯 TOML pipeline、微信兼容应用、Codex Bot 和现有 vjsx。验收包含从空工作区启动和从已有源码接入，并以运行请求证明结果。
3. 补齐共享环境配置、主机与实例、运行包、普通及共享 Relay、运维诊断。优先接通已有 Host/Worker 或 Admin 能力。对运行时注册表中不能复用通用流程的协议与资源逐项增加契约和验证工具。
4. 每批使用 DSH 或 WorkBuddy 验证发现、指引读取、实际调用和恢复。公网验收另验证凭据范围和目标绑定，发布验收以测试目标的实际业务结果为准。只有执行与验收都有记录的项目才标记为完成。

本节是后续覆盖范围与验收契约。下文保留已实现工具和既有验收记录。

第一批已实现只读 `capabilities_list`。Desktop 目录从工具注册规格生成，返回能力域、权限、会话可用性和不可用原因。传入 `include_runtime: true` 时，通过现有 `schema_get` 路径返回目标实时或随包 schema，无法读取时仍返回 Desktop 目录并附上原因。`desktop/devmcp/server_test.v` 将目录中的可用项与实际 `tools/list` 比对，覆盖工作区、已绑定管理会话和只读 Relay。使用支持 Relay 的 0.9.0 测试运行包通过了该测试文件，包括停机 schema、应用切换和实际 Relay 编辑回归。`vhttpd-develop` 已加入能力发现步骤。运行时注册表以外的操作与上表未接入的 Desktop 能力仍按后续批次实施。

DSH 客户端验收通过安装包内的 `dsh-mcp-client`，在隔离工作区使用 Streamable HTTP 实际完成工具注册、`capabilities_list`、`project_create` 和带 `include_runtime` 的目录查询。目录版本为 1，共 37 项，当前可用 20 项，与 DSH 注册结果一致。未授权应用发布显示 `management_session_required`。vhttpd 0.9.0 停机时从 `runtime_package` 读取了 listeners、resources、engines、adapters、transforms、policies、providers、pipelines、relays 九个域。重建测试运行包后，在独立的已绑定管理会话复验。DSH 实际注册 35 项，与目录可用项一致。应用发布可见，`project_create` 返回 `workspace_session_required`。`guidance_get(develop)` 从新构建的 0.9.0 运行包返回包含 `capabilities_list` 步骤的指引。本轮证据覆盖 DSH 客户端连接器层，模型对话因模型路由不可用未通过。

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

公网 MCP 经过两段连接。Web Agent 使用 HTTPS Streamable HTTP 访问远端 vhttpd Hub 的 MCP 入口，bodytest 单端口部署使用 `/mcp`。Relay 两端都运行 vhttpd。本机 Desktop 管理的 vhttpd Relay Agent 主动连接远端 Hub 的 `/vhttpd/relay/desktop-mcp`，建立全双工 WebSocket 长连接。Hub 沿这条已建立的连接把请求交给本机 Agent，由 `mcp-upstream` 转到 loopback 上的 Desktop MCP `/mcp`，响应沿同一连接返回。远端向本机发送请求时复用这条长连接。用户在 Desktop 选定应用后，选择可信 Relay 并开启「通过 Relay 发布」，为当前绑定发布有期限的路由。界面提供 URL、客户端认证配置、到期时间及撤销入口。 [Relay Hub 示例](../examples/config/mcp-relay-public-v2.toml) · [Relay Agent 与 MCP 上游示例](../examples/config/mcp-relay-local-upstream-v2.toml)

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
| 复用并补充结果 | `runtime_status`、`runtime_start`、`runtime_stop`、`logs_query`、`application_request` | 状态和启停结果报告作用范围。经 Relay 启动或重启时先返回受理，轮询 `runtime_status.readiness` 为 `ready` 后调用 `application_request`。本机直连启动等待就绪。日志尽可能返回应用标识及请求关联信息。业务验证只调用选定应用的业务监听器 |

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

每个 Skill 的 `SKILL.md` 放触发条件、操作顺序、失败分支和验收标准。`vhttpd-deploy` 和 `vhttpd-debug` 已提供当前可执行的工作流。查询、预检、提交和恢复使用本机管理 MCP。Desktop 展示需要用户确认的远端操作。2026-11-04 18:07（上海时间）在 DSH 实际加载了两份 Skill，并调用目标查询、历史操作查询和本机状态及日志工具。应用发布、运行时升级及各自的回滚已通过下文的 DSH 验收，远端接管的启动、释放及业务流量验证也已通过。 [vhttpd-deploy](../desktop/skills/vhttpd-deploy/SKILL.md) · [vhttpd-debug](../desktop/skills/vhttpd-debug/SKILL.md)API 签名、配置字段、允许的 import 和示例由与运行包匹配的开发契约维护。第一阶段发布一个可安装的 `vhttpd-develop` Skill，MCP 从同一份发布内容提供工作流。ChatGPT 网页通过工具按主题读取；支持本地 Skills 的客户端可加载同一版本。首批契约覆盖模板实际使用的入口、请求和响应 API、模块边界，以及一条 HTTP 和一条 JSON API 示例。 [vjsx Facade Reference](./VJSX_FACADE_REFERENCE.md)

### 微信云开发兼容项目

这类应用以 `examples/wechat-cloud-functions` 为参考，云函数和业务接口由 vhttpd 运行。现有示例包含 `lib/cloud` 服务端兼容库和小程序 `utils/vhttpd.js` 客户端。开发入口按项目现状区分。

- 空工作区用 `project_create` 的 `environment` 模板创建环境。通过 `application_templates_list` 发现 `wechat-cloud-functions`，再用 `application_install_prepare` 和 `application_install_apply` 生成并安装最小可运行组件。模板复用示例中的兼容库与客户端，提供应用入口、vhttpd 配置、最小云函数和验证请求。基础库随模板和应用制品交付，并记录版本。
- 已有项目先调用 `context_get`，检查应用入口、`cloudfunctions/` 和现有兼容库。保留业务代码与目录结构，按缺少的依赖生成变更，经 diff 和校验后应用。已绑定应用的公网会话继续操作绑定范围内的文件。
- `vhttpd-develop` 增加微信云开发兼容项目的触发条件与操作步骤。先识别项目是初始化还是接入，再查与运行包及兼容库版本匹配的开发契约。契约通过 `guidance_get` 的独立主题提供给 Web Agent，覆盖 `wx-server-sdk` 兼容接口、身份上下文、函数互调、数据库和存储、客户端接入、已支持的选项及错误行为。项目 `AGENTS.md` 只记录该应用实际使用的入口、库版本和验证方式。
- 本地验证沿用文件 revision、变更校验、启动和 `application_request`。发布沿用 `vhttpd-deploy` 与应用发布工具，预检确认制品包含应用入口、云函数和服务端兼容库。业务验证调用真实云函数入口并检查返回，失败时用 `vhttpd-debug` 查应用日志，按变更或发布记录恢复。

验收在测试环境覆盖两条路径。用 DSH 或 WorkBuddy 从模板创建新项目，再接入一份已有云函数项目，确认原有文件得到保留。客户端通过公网 MCP 读取兼容契约、修改云函数、校验并运行，验证客户端请求契约和至少一种实际使用的基础库能力。随后发布到测试目标，验证远端调用并回滚。本批已完成模板创建、工作区安装和独立应用绑定。微信真实登录、数据库和存储链路、已有云函数迁移与公网 Relay 专项验收继续单独跟踪。

### 三类组件的 DSH 验收

DSH 安装包内的 `dsh-mcp-client` 通过本机 Streamable HTTP 调用 `application_templates_list`、`application_install_prepare` 和 `application_install_apply`。切到应用绑定管理会话后，通过 MCP 发布基线、更新同一安装 ID、回滚并轮询到完成。每次都在隔离 Ubuntu 目标验证真实业务响应。

| 组件 | 本机验证 | Ubuntu 基线 → 更新 → 回滚 |
| --- | --- | --- |
| 纯 TOML pipeline | GET /healthz 返回 200 和 pipeline-ok，未匹配路径返回 404 | c58f21587b2aeea7541b8018 → 945363a3650d935a3c892496 → 0c2be5883d03f150398bb860 |
| 微信云开发兼容 | GET /healthz 经兼容 SDK 调用 hello，未配置登录返回 503 | 6d2728ae60e0c433d0d6bdbf → 01b4865af7e74386889b91c9 → 5bb30a5e09ad1e187f741215 |
| Codex Bot | GET / 返回应用 JSON，默认关闭外部 provider 启动 | 61b0433618d894b68e0112ac → a2a50c61821534ad36e08c40 → f1f8be21efab590f08f77a48 |

`vhttpd-develop`、`vhttpd-deploy` 和 `vhttpd-debug` 增加三类项目的操作与验证流程。自动测试验证模板安装、无脚本组件可绑定、私有文件排除和跨会话安装计划拒绝。此次验收在 DSH 客户端连接器层执行，远端业务请求直接由 Ubuntu 测试监听器响应。测试实例已停止。

### 本机运行包与运行时诊断

- `runtime_package_get` 返回所选本机运行包的版本、来源和可用性。文件系统路径留在 Desktop。远端运行包继续通过 `target_status` 查询。
- `runtime_diagnostics_get` 从运行中的本机 Admin 读取 `graph`、`workers`、`providers`、`relay` 四类状态，使用固定查询和受限字段。诊断面覆盖整个本机环境，所以需要本机 MCP 会话。停机时可以查询运行包和 schema。
- `vhttpd-debug` 按运行图、worker、provider 和 Relay 状态给出排查顺序。`vhttpd-deploy` 说明如何区分本机复现所用的包与远端包。
- DSH 安装包内的 MCP 客户端通过 Streamable HTTP 实测。停机时读到运行包 0.9.0，诊断调用返回 `runtime_not_running`。启动后运行图返回 5 个节点、3 条边，另三类接口均返回结构化状态。测试环境未配置独立 worker、provider 实例或 Relay Agent，三类列表均为空。随后默认 Desktop MCP 自动回归通过。真实 Relay 的历史回归曾在长连接握手成功后遇到运行时启动请求 HTTP 504，根因和修复后的公网验收见下文。任意 Admin 路径作为 topic 被拒绝，测试实例已停止。

### 2026-11-05 Relay 模式转换、字段删除与多文件编辑验收

本批扩展既有 5 个编辑工具，绑定管理会话仍列出 93 个工具。实现见 [Relay 源编辑器](../desktop/host/mcp_relay_edit.v)、[执行与多文件恢复](../desktop/host/mcp_relays.v)、[本机停机恢复](../desktop/host/mcp_relays_local.v)、[工具参数与确认](../desktop/devmcp/ordinary_relays.v) 和 [运行时 include 合并](../src/config/runtime_plan_loader.v)。公开应用 Relay 不因此获得管理权限。

| 入口 | 本批新增契约 |
| --- | --- |
| relay_config_get | 返回 sources 和 field_sources，定位同一 Relay 在多个 include 中各字段的物理来源；凭据和完整载体 URL 不返回。 |
| relay_config_edit_prepare | updates 增加 mode 和 carrier；remove_fields 删除已有标量赋值，不用空值模拟删除。已有字段在原文件编辑，新字段进入 mode 所在文件；无 mode 时使用首次声明源。计划列出全部改变的 sources、自动删除字段及安全前后值。 |
| relay_config_edit_preflight | 使用同一个 Admin changeset 预检完整多文件候选，固定完整源 revision、boot、目标和凭据引用；未预检不能应用。 |
| relay_config_edit_apply / restore | 确认后先受理，再查询 relay_operation_get。发布、重启、生效检查及精确恢复覆盖全部改变的文件；本机和受管远端均支持运行时已停止时恢复。 |

agent → hub 要有有效监听引用和认证，使用 WebSocket carrier，自动移除 url、autostart、reconnect_delay_ms。hub → agent 必须提供匹配 Relay ID 的已保存 connection_id，私下复制 Token 和 Agent URL，自动移除 listener、path、auth；按目标连接意图选择 autostart。只支持运行时已有的 hub/agent 角色与 WebSocket 载体，没有新增其他传输协议。数据库导出、接管或管线对角色的约束仍由完整预检检查。

remove_fields 支持 mode、carrier、node_id、path、listener、autostart、max_channels、channel_buffer、reconnect_delay_ms、token、url、auth。删除与更新同一字段、重复删除、字段不存在及原始凭据/URL 输入均拒绝。必填字段删除仍须通过整环境校验。auth 认证引用参与安全预览，凭据只展示存在与否。普通表、带引号表名、inline 与 dotted 赋值的编辑/删除均用完整 TOML 语义比对约束；保留未编辑内容与注释。任意嵌套 options 修改、创建/删除物理文件及环境目录外来源不在工具范围。

原运行时按 Relay ID 拒绝任何重复声明，不能读取字段分散的配置。本批增加字段来源记录，允许不同 include 贡献同一个 Relay 的不同顶层字段；重复字段即使值相等也拒绝，false/zero 不因默认值丢失。其他命名配置仍沿用原重复 ID 检查。Desktop 验证器与目标运行包均须包含该支持，旧包不能直接读取这种配置。运行包版本号仍为开发中的 0.9.0，验收以具体二进制摘要区分。

多文件候选通过既有 Admin changeset 校验与发布。停机本机恢复复用 FileStore 的全量暂存、原文复查及普通失败补偿；远端恢复在核对全部成员、路径、完整 revision 和原文后先暂存全部文件，再替换，普通失败回退已替换文件。它们不声明跨文件崩溃原子性或 Desktop 重启后的恢复能力。计划和恢复记录仍限当前 Desktop 会话；全部应用和恢复会重启整个目标环境。

实际验收使用更新后的 Workbench Update QA.app，界面绑定原 pipeqa 并签发管理连接；已安装 DSH 的真实 dsh-mcp-client 经 Streamable HTTP 执行写流程。DSH 桌面对话另实际调用 skill 重新加载新版 [vhttpd-deploy](../desktop/skills/vhttpd-deploy/SKILL.md) 与 [vhttpd-debug](../desktop/skills/vhttpd-debug/SKILL.md)，正确解释转换条件、自动删除、来源定位、冲突、旧包兼容性和恢复，并给出不含凭据的示例。完整写流程属于连接器验收，不将它记为模型自主执行全部写操作。

- 复用本机原隔离环境与 Ubuntu 已有 mcp-shared-config-qa 实例，没有新建 VM、远端实例或独立 Hub 进程，没有改动 bodytest。两端 legacyedit 都预置为手工 mode.toml + options.toml，不带 MCP 标记。Relay 载体仍由本机 vhttpd 主动连接远端 55311 WebSocket；SSH 只用于 Desktop 管理。
- DSH 经正常运行包预检、升级和回滚流程，在同一远端实例临时选择本批 Linux Boehm 构建。基线 HTTP → 远端 Hub → WebSocket → 本机 pipeqa 返回 200 / pipeline-ok。
- 一次远端计划修改 mode.toml 中 path、options.toml 中 node_id，并删除 max_channels，发布后旧 Agent 流量失效。一次本机计划更新私有连接引用与 node_id/reconnect_delay_ms，并删除 channel_buffer；两个来源同计划发布，注册及 200 / pipeline-ok 恢复。读取确认两个字段的赋值均已删除。
- 本机 Agent 转成 Hub 后，远端业务不再返回 200；对新本机路径执行非注册式认证 WebSocket 探测成功。再将 Hub 转回 Agent，恢复 registered 和真实业务 200。嵌套转换计划按逆序恢复，并核对相应角色及业务状态。
- 重复提交返回同一操作 ID。旧多源计划在另一计划修改 node_id 后执行失败，temporary 值没有被覆盖。12 项拒绝用例覆盖未预检应用、非法模式/载体、原始 Token/URL、更新与删除冲突、未知或不存在字段、重复删除、小数数值、未知监听和来源路径注入。
- 分别停止本机与远端运行时后，通过 MCP 恢复原多文件计划。完整 source_revision 都回到各自基线，Relay 业务和两端其他业务监听恢复。独立字节比对确认四个原 TOML 文件（含注释、凭据）完全一致；所有 MCP 结果中均未出现测试载体凭据。

macOS 编辑、普通 Relay、片段合并与原有 include 覆盖测试通过；HTTP MCP 集成在允许本机监听的环境通过。Ubuntu 编辑、普通 Relay、片段合并与 include 覆盖四套测试通过，使用 /home/guweigang/v/v 0.5.2 d13ccdd、local-dev、GCC、gc none 和 -nocache。Linux 原 /usr/local/share/vhttpd/vjsx 版本与当前锁定提交不同，未修改它；复用已有干净的 /home/guweigang/vhttpd-db-probe-qa/vjsx 259620f 和原生 Linux QuickJS。Linux 交付验收包另以 GCC、Boehm 构建并通过 GC 校验。两份 Skill 格式检查和 DSH 实际加载通过。

Desktop 主程序、内置运行时和两份 Skills 已更新，更新前包保留为 Workbench Before Structural Relay Edit.app。收尾通过 DSH 回滚远端原包并停止两端隔离运行时，恢复原根配置和连接库、移除测试 include，测试包保留在安装目录之外。临时 MCP、测试 SSH 与 Relay 监听回收后恢复原 default 环境。详见 [结构编辑验收证据](release-evidence/desktop-mcp-relay-structural-edit-2026-11-05.json)。

### 2026-11-05 已有手工 Relay 编辑与恢复验收

本批新增 5 个本机管理 MCP 工具，当前绑定应用会话可列出 93 个工具。已有 Relay 不再要求 MCP 归属标记。实现见 [已有 Relay 编辑](../desktop/host/mcp_relay_edit.v)、[MCP 契约与确认](../desktop/devmcp/ordinary_relays.v)、[统一执行与恢复](../desktop/host/mcp_relays.v) 和 [本机恢复](../desktop/host/mcp_relays_local.v)。

| 工具 | 契约 |
| --- | --- |
| `relay_config_get` | 发现 Relay ID、相对源文件、可编辑字段和安全值。省略 relay_id 列出全部定义；不返回 Token 或完整载体 URL。 |
| `relay_config_edit_prepare` | 对已有定义预览字段补丁，返回安全的前后值、全环境源 revision、目标、五分钟计划及重启范围。定位其真实源文件，不迁移到根文件，也不添加归属标记。 |
| `relay_config_edit_preflight` | 对同一计划执行运行时 Admin 全配置预检，复查源 revision 和 boot identity。尚未预检的计划不能应用。 |
| `relay_config_edit_apply` | Desktop 确认后先返回受理，查询 relay_operation_get 到终态；发布并重启整个已有环境，核对磁盘与生效版本。重复提交返回同一操作 ID。 |
| `relay_config_edit_restore` | 在完整当前源仍匹配时恢复原始字节并验证生效。受管实例停止后也能恢复经过边界检查的 include 源，不需要先删除手工配置。 |

本批支持 node_id、path、listener、autostart、max_channels、channel_buffer 和 reconnect_delay_ms。凭据与 Agent URL 只能通过匹配 Relay ID 的已保存 native connection_id 引用更新；源凭据默认原样保留。预检和应用会复查引用，防止批准后连接库变化导致使用错误凭据。该批结束时，模式转换、字段删除及同一 Relay 的多源定义尚不支持；这三项已由上方后续结构编辑批次完成。环境目录外源文件仍拒绝，整体 coverage 仍为 partial。

编辑采用 TOML 标量位置替换，并用完整解析结果核对选定字段以外的配置保持一致。普通表、带引号的表名、inline 和 dotted 写法均有验证；缺少的允许字段会在对应作用域插入。保留注释、空白、私有值和其他配置。恢复保留整个原文件字节，并固定全环境版本，避免覆盖并发修改。应用、恢复和既有启停一样会重启环境中的全部应用；公开应用 Relay 不获得这些管理权限。

已更新并安装 [vhttpd-deploy](../desktop/skills/vhttpd-deploy/SKILL.md) 和 [vhttpd-debug](../desktop/skills/vhttpd-debug/SKILL.md)。DSH 桌面对话实际重新调用 skill 工具加载两份文案，正确识别无需 MCP 标记、include 来源、独立预检门槛、凭据引用、并发冲突和停机恢复，并列出结构变更限制。Skill 格式验证与 DSH 安装包实际加载器检查均通过；Desktop guidance_get(deploy) 返回同源新流程。

实际工具验收使用更新后的 Workbench Update QA.app 界面绑定 pipeqa 并签发的管理连接，由已安装 DSH 的 dsh-mcp-client 经 Streamable HTTP 执行。该部分记录为 DSH 连接器执行，模型对话另验证 Skill，不将全部写流程记为模型自主完成。测试脚本预置手工配置，不通过 MCP 创建或标记待编辑 Relay。

- 复用本机内置运行包和 Ubuntu 的 mcp-shared-config-qa 实例。两端 Relay legacyedit 均定义在 qa-relay-edit/relay.toml，由根配置 include 引入，没有 MCP 标记。远端临时使用 55311 监听，本机主动建立 WebSocket 长连接。复用上轮已验证的 Linux Boehm 测试包，通过 DSH 临时选择，结束后回滚原包；没有新建 VM、实例或独立 Hub 进程，没有改动 bodytest。
- 基线经远端 HTTP → WebSocket Relay → 本机 pipeqa 返回 HTTP 200 和 pipeline-ok。修改 Hub 的 node_id、path 并新增 max_channels 后，旧 Agent 失联且转发不再返回 200。再通过已保存连接引用更新 Agent 的私有 URL，并编辑 node_id、reconnect_delay_ms、补充 max_channels，重新注册后恢复 HTTP 200 和 pipeline-ok。
- 相同 Agent 计划重复提交返回同一操作 ID。12 个拒绝用例覆盖未预检应用、原始 Token/URL、模式转换、错误布尔类型、无效数值/路径、未解析监听引用、未知 Relay/计划、旧绑定及任意来源路径注入。
- 并发测试先预检一个旧计划，再应用另一个计划修改 node_id。旧计划执行失败，当前值仍为 temporary，未被覆盖；恢复临时计划后回到 local-after。
- 先停止本机运行时，再通过 MCP 恢复原 Agent include；先停止远端实例，再通过 MCP 恢复原 Hub include。两端完整 source_revision 均回到最初值，原 Relay 业务及两端其他业务监听恢复正常。独立文件比对确认注释与凭据逐字节一致。
- 真实 DSH 调用发现通用 JSON 解码器将整数表示为浮点数的问题，已修正为只接受范围内的数学整数并编码为 TOML 整数；新增真实 JSON 解码回归，继续拒绝小数、巨大值和负值。macOS 编辑、普通 Relay、HTTP MCP 三个套件通过；修正后编辑与 HTTP MCP 再次通过。Ubuntu 编辑及普通 Relay 两套件通过，最终 dotted 和 JSON 数字回归也重新通过。Linux 使用既有 /home/guweigang/v/v 0.5.2 d13ccdd、local-dev、GCC 与 gc none，没有更改编译器或原依赖工作区。

当前 Desktop 主程序和随包 Skills 已更新，内置运行时复用上一批构建。原应用备份为 Workbench Before Existing Relay Edit.app。收尾恢复原 default 环境并在界面确认运行中；隔离环境恢复原运行包、根配置，验证后移除临时 include 和连接引用，关闭临时 MCP、测试 SSH 与 Relay 监听。测试包重新保留在已安装目录之外。见 [已有 Relay 结构化验收证据](release-evidence/desktop-mcp-existing-relay-edit-2026-11-05.json)。

### 2026-11-05 数据库 Relay 专项探针验收

本批新增两个本机管理 MCP 工具，当前绑定会话共 88 个工具。实现见 [数据库 Relay 编排](../desktop/host/mcp_database_relays.v)、[工具契约](../desktop/devmcp/ordinary_relays.v)、[专用 Admin 入口](../src/admin_relay_database.v) 和 [固定查询结果校验](../src/relaydb/probe.v)。

| 工具 | 契约 |
| --- | --- |
| `relay_database_resources_list` | 读取运行中的生效配置，列出数据库 Relay 客户端资源及 Hub 的 db-resource 导出。返回资源、Relay、路由、远端资源和导出访问模式，不返回数据库地址或凭据。 |
| `relay_database_probe` | 只接受 resource_id 和目标绑定，通过已有 vhttpd Agent 载体执行固定 SELECT 1 AS relay_probe，验证 MySQL 常量结果。拒绝任意 SQL、URL、Token 和旧绑定。 |

专项探针复用本机主动建立的全双工 WebSocket 连接，不注册第二个 Agent。查询与临时数据库客户端的关闭固定在同一载体代次；已发送的查询不自动重放，不修改配置、不重启。运行时只允许 Admin Token 认证访问 POST /admin/runtime/relay/database/probe，拒绝额外参数；未经认证的实际请求返回 403。原始驱动错误、SQL 和凭据不进入 MCP 结果。

失败以 configuration、carrier、transport、database、response、runtime 分层。database 表示数据库连接、认证或执行失败的安全合并类别，不能仅凭此类别断言密码错误。transport 表示路由、远端导出、载体变化或超时等未完成交付，结果不明时先检查运行事件。固定查询成功证明链路和驱动能够执行常量查询，不代表应用表结构、迁移、其他语句权限或业务数据正确。

已更新 [vhttpd-deploy](../desktop/skills/vhttpd-deploy/SKILL.md) 与 [vhttpd-debug](../desktop/skills/vhttpd-debug/SKILL.md)，并安装到 DSH。DSH 桌面对话实际调用 skill 工具重新加载两份文案，正确说明固定查询、载体复用、临时客户端关闭、六层诊断及业务验证边界。两份 Skill 格式校验与 DSH 安装包的实际 Skill 加载器均通过，Desktop guidance_get(debug) 也返回新流程。

实际 MCP 验收使用更新后的 Workbench Update QA.app 界面绑定隔离 pipeqa 并签发的连接，DSH 安装包内真实 dsh-mcp-client 经 Streamable HTTP 调用工具。该部分属于连接器执行，模型对话另验收 Skills，不将全部写流程记作模型自主完成。测试配置由受控脚本预置。

- 复用本机既有工作流和 Ubuntu 的 mcp-shared-config-qa，没有新建 VM、远端实例或独立 Hub 进程，没有修改 bodytest。远端临时 Relay 监听 55311，本机主动连接 /vhttpd/relay。数据库使用一次性 MySQL 8 容器，仅绑定 OrbStack 私有网卡，测试用户只有 SELECT 权限。
- 实际发现 4 个本机 Relay 数据库资源及 2 个远端导出。正常资源返回 ok=true、stage=query；MySQL 自身的语句统计确认 SELECT ? AS relay_probe 共执行 3 次。
- 错误数据库凭据返回 database；错误路由、未导出的远端资源返回 transport；未知本机资源返回 configuration。停止 Agent 后返回 carrier，重新启动同一环境并注册后查询再次成功。SQL、Token、URL 参数和旧绑定共 4 项拒绝用例通过。
- 两端原业务监听仍返回 HTTP 200，本机响应包含 pipeline-ok。查询与启停恢复均通过，最后由 DSH 停止两端隔离运行时。
- 远端旧 0.9.1 测试包缺少专用 Admin 入口，实际返回 runtime_probe_endpoint_unavailable_upgrade_required。测试中还观察到其路由及载体标识异常，未将当时的传输失败误记为数据库认证失败。通过 DSH 的运行包预检、切换和回滚工具，在同一个实例临时切换到当前源码的 Linux Boehm 构建完成全部验收，随后回滚原包。当前源码版本字符串为 0.9.0，隔离包标签为 v0.9.0-dev.g0e984283；这是测试构建，不是新的官方发布。支持与否以专用入口实际响应判断。
- macOS 四个 relaydb 测试套件通过，MCP HTTP 服务套件因 loopback 沙箱限制重跑后通过。Ubuntu 五个套件、完整运行时类型检查通过；MySQL 启用的 Linux 与 macOS 运行包均验证 Boehm GC。Linux 使用 /home/guweigang/v/v 0.5.2 d13ccdd、local-dev 与 GCC；独立原生依赖副本固定到项目要求的 vjsx 提交，未改变 VM 原有 V/vjsx 工作区。

当前 Desktop 的生产主程序、内置运行时与 Skills 已更新，旧应用备份为 Workbench Before Database Relay.app。最终恢复原 default 环境并在界面确认运行中；远端运行包标记及配置摘要恢复原值，两端临时端口关闭，MySQL 容器、测试 SSH 入口及临时 MCP 凭据已回收。新增 Linux 测试包保留在已安装目录之外。详见 [数据库 Relay 结构化验收证据](release-evidence/desktop-mcp-database-relay-2026-11-05.json)。

### 2026-11-05 普通 Relay 连接库、配置与启停验收

本批新增 12 个本机管理 MCP 工具，已绑定会话当前提供 86 个工具。实现见 [普通 Relay 工具契约](../desktop/devmcp/ordinary_relays.v)、[Host 编排](../desktop/host/mcp_relays.v)、[配置生成](../desktop/host/mcp_relays_config.v) 和 [本机 Worker](../desktop/host/mcp_relays_local.v)。

| 流程 | MCP 工具 |
| --- | --- |
| 连接库创建、更新与删除 | `relay_connection_save_prepare/apply`、`relay_connection_delete_prepare/apply` |
| 临时认证探测 | `relay_connection_probe` |
| Hub / Agent 配置与恢复 | `relay_config_prepare`、`relay_config_apply`、`relay_config_restore` |
| Agent 启停 | `relay_agent_control_prepare`、`relay_agent_control_apply` |
| 运行状态与异步操作 | `relay_runtime_status`、`relay_operation_get` |

连接库支持本机与已连接主机的共享目录。保存凭据只能引用已验证环境中的 Hub 或已有本机连接 ID；工具不接受 Token 明文、任意端点 URL。保存、临时认证探测、配置副本和已注册 Agent 分别验证。目录删除不改变已部署副本。Hub 使用现有环境中的一个 HTTP/WebSocket 监听器，默认只开放载体端点；只有显式指定 verify_path 时才增加 HTTP 业务转发路径。Agent 默认不自动连接，由本机 vhttpd 主动向远端 vhttpd 发起全双工 WebSocket 长连接；载体不使用 SSH 转发。

预检编译整个环境并固定配置 revision、boot identity、目标和授权代次。配置与启停需要 Desktop 确认，先返回 accepted，再查询操作终态。当前运行包没有单 Agent 的 Admin 启停接口，因此工具持久化 autostart 并重启整个既有环境，影响其中全部应用。该批创建和启停工具只编辑带 MCP 归属标记的配置块；已有人工配置现可使用上方新增的独立编辑、预检、应用与恢复流程。配置恢复保留精确原始字节，要求当前完整源 revision 与预期一致；两端均支持托管实例停机后的受保护恢复。首次提交前计划有效五分钟，每个会话最多 64 个计划、128 条操作；重启 Desktop 后需重新对账。

实际验收使用更新后的 Workbench Update QA.app，由界面绑定隔离 pipeqa 应用并签发连接配置。已安装 DSH 的 dsh-mcp-client 通过 Streamable HTTP 执行完整写流程；模型对话另外实际调用 skill 工具重新加载了新版 [vhttpd-deploy](../desktop/skills/vhttpd-deploy/SKILL.md) 和 [vhttpd-debug](../desktop/skills/vhttpd-debug/SKILL.md)，核对工具组合、主动连接方向、环境重启、凭据引用和恢复要求。本轮写流程证据属于 DSH 客户端连接器层，不将其描述为模型自主执行全部写操作。

- 复用本机既有 0.9.0 运行包和 Ubuntu 既有 mcp-shared-config-qa 0.9.1 实例。未新建 VM、Hub 进程或远端实例，也未改动 bodytest。远端临时增加 55311 单端口，WebSocket 路径 /vhttpd/relay，HTTP 验证路径 /__relay/ordinaryqa。
- DSH 创建并更新本机连接记录、复制到远端共享连接库；正确凭据探测通过，错误凭据被拒绝。创建 Agent 配置后验证未注册；启动后验证 registered；远端 HTTP 请求经过 WebSocket Relay 到本机 pipeqa，返回 HTTP 200 和 pipeline-ok。活跃连接期间再次探测，没有替换业务载体。
- 停止 Agent 后，远端请求不再到达本机。先停止本机运行时再恢复 Agent 配置；先停止远端实例再恢复 Hub 配置。两端原业务响应均恢复，目录记录回收，完整源基线恢复。
- 11 个拒绝用例涵盖错误认证、缺少凭据引用、Token/URL 输入、未知连接、非法标识、端口冲突、未知 Agent/计划、无效恢复和过期绑定。首轮实际 Desktop 探测曾短暂返回网络不可达，后续同地址探测及完整重跑通过；未将其误归因为认证或协议修复。
- macOS 的 Relay 编排、共享连接库、远端目标和 MCP 服务四个测试套件通过，另补默认不创建 HTTP 转发路径的回归用例；Ubuntu Relay 编排和共享连接库两个套件通过，新增默认不暴露 HTTP 转发路径用例也已在 Ubuntu 复验。两份 Skill 的格式校验和已安装 DSH 加载通过。归属块保护、端口冲突、配置编译及启停后精确恢复均有单测。

当前 Desktop 已更新为此生产构建，原包备份为 Workbench Before Ordinary Relay.app。部署 Skill 同时安装到 DSH 并由其实际加载。验收结束后已关闭临时 MCP，恢复原 default 0.9.0 环境并在界面确认运行中；隔离远端实例与测试 SSH 管理入口已停止，本机临时监听和远端 55311 监听均已关闭。结构化证据见 [普通 Relay 验收](release-evidence/desktop-mcp-ordinary-relay-2026-11-05.json)。该批次结束时数据库 Relay 专项探针尚未完成，其后续验收见上方记录；已有非 MCP 配置的字段编辑与恢复已由上方后续批次验收，模式转换、标量字段删除和分散 include 定义的后续验收见上方结构编辑记录，整体能力目录因其他未覆盖项保持 partial。

### 2026-11-05 运行包下载、安装与选择验收

本批新增 7 个本机管理 MCP 工具，当前绑定会话列出 74 个工具。运行包能力域的 coverage.remaining 已清空，整体能力覆盖仍为 partial。实现见 [运行包操作](../desktop/host/mcp_packages.v) 和 [MCP 工具契约](../desktop/devmcp/packages.v)。

| 工具 | 契约 |
| --- | --- |
| `runtime_download_prepare/apply` | 固定官方发布标签与平台，复用官方 GitHub 元数据、资产地址约束和 SHA256 校验；返回异步操作 ID，完成后取得不含路径的 download_id。不接收任意 URL |
| `runtime_install_prepare/apply` | 以 download_id 安装。本机省略 host_id；远端须连接已保存、平台匹配的主机。复用现有归档、签名或架构、完整性及版本检查，保留当前选择和实例绑定 |
| `runtime_package_select_prepare/apply` | 选择已知本机 package_id，预检整个绑定配置并固定配置版本和二进制摘要；执行时要求本机运行时停止。更新 Desktop 选择和 MCP 上下文，清除旧变更预览并递增绑定代次 |
| `runtime_package_operation_get` | 查询下载、安装或选择的异步结果；选择后先重新 context_get，再用新 binding_revision 查询完成状态 |

下载、安装与选择分离，原 Desktop 界面的“下载安装并选择”行为保持原样。MCP 安装调用复用相同安装校验，但不会自动选择。远端实例选择包继续使用已有 runtime_upgrade_prepare/apply/rollback，保留环境级升级与回滚的影响预览。

包计划有效期五分钟，新预检替换旧包计划；相同当前执行计划幂等返回同一操作 ID。成功的本机选择将该计划和操作记录更新到新绑定代次。下载 ID 属于当前开发授权，缓存有效期一小时，每个会话最多四个下载；操作记录最多 128 条。正常退出清理会话下载缓存，已安装运行包保留。工具不公开缓存路径或接受本机归档路径。仅本机管理 MCP 提供这些写入口，公网应用 Relay 不扩展管理权限。

本轮实际发现并修正两项恢复问题：本机 context_get 若排在运行包选择后执行，可读取最新代次，旧公网授权仍受固定代次检查；会话保留先前由 Desktop 授权的运行包引用，避免原内置或外部包在切换后从清单消失而无法恢复。当前 Desktop 的运行包显示也随 MCP 选择更新。

验收使用当前安装、实际运行的 Desktop 界面签发的本机连接，DSH 安装包内真实 MCP 插件经 Streamable HTTP 完成调用，不以测试程序替代 Desktop 服务，也不将连接器流程记为模型会话自动执行全部写操作。DSH 桌面会话另实际调用 skill 工具重新加载 vhttpd-deploy 与 vhttpd-debug，正确说明安装不切换、选择后刷新上下文、本机恢复和远端升级/回滚的区别。两份 Skill 的格式验证及 DSH 实际加载器检查通过。

- 官方发布标签为 v0.1.0-dev.g4aac0fb950d8，实际下载 macos-arm64 Workbench ZIP 与 linux-arm64 TAR.GZ。两个文件均通过发布的 SHA256 校验。重复下载和选择提交返回原操作 ID。
- 本机隔离测试应用为纯 TOML pipeline，监听 55302，GET /healthz 返回 pipeline-ok。安装后原包仍为当前选择；切换官方包、刷新上下文、启动并验证业务成功，随后停止、恢复原包、再次验证同样响应，最后停止。本机新包版本显示为 0.1.0，恢复后显示 QA 基线 0.9.0。
- 远端复用 OrbStack Ubuntu 及已有 mcp-shared-config-qa。安装官方 Linux 包后，所有既有实例运行包绑定不变；MCP 在安装前后请求 55172 /shared-before 均得到 HTTP 200。没有新建 VM、Hub 或远端实例，没有改动 bodytest。远端安装按归档摘要命名，同包重复安装保留已有目录。
- 下载执行期间，本机 runtime_status 实测响应约 17 毫秒，未阻塞于下载 Worker。
- 9 个拒绝用例通过：任意第三方地址作为标签、不支持的平台、未知下载 ID、平台不匹配、注入归档路径、未知 package_id、未预检计划、未知操作 ID、旧绑定代次。真实归档的额外回归验证安装不改选择、错误 SHA256 不替换选择，以及切换后原包仍可发现。
- macOS 五项基础检查通过，覆盖包操作、原有安装、官方目录、能力清单与 HTTP MCP 的权限隔离；恢复问题修正后，包恢复与 HTTP MCP 检查重新通过。Ubuntu 使用 /home/guweigang/v/v 0.5.2 d13ccdd、local-dev 分支、GCC 与 gc none 原生验证 Linux 官方包安装保留原选择，并拒绝错误校验值。复用既有 Linux 运行环境，没有替换 VM 编译器或重新构建其运行时。

当前 Desktop 已安装此生产构建，原包保留为 Workbench Before Runtime Packages.app。验收收尾恢复原 default 运行环境，停止隔离测试进程，关闭临时 MCP 和 SSH 入口。结果见 [结构化验收证据](release-evidence/desktop-mcp-runtime-packages-2026-11-05.json)，详细日志位于本机 /private/tmp/vhttpd-package-qa/desktop-dsh-result.log、tests.log、package-recovery-tests-final.log、recovery-tests.log 和 linux-tests.log。

### 2026-11-05 主机登记、环境接入与断开验收

本批补齐 5 个本机管理 MCP 工具，当前绑定会话可列出 67 个工具。实现沿用 [主机登记与身份校验](../desktop/host/mcp_host_registry.v) 和 [MCP 生命周期分发](../desktop/devmcp/lifecycle.v)，公网应用 Relay 不增加这些管理权限。

| 工具 | 操作与边界 |
| --- | --- |
| `host_register` | Desktop 确认后保存密钥认证主机记录，不自动连接或授予信任。可使用本机 SSH 配置，或以 credential_host_id 引用已保存主机的密钥；不接受私钥路径或密码。同样的名称、地址、用户、端口和密钥引用重复登记返回同一主机 ID；冲突设置不覆盖原记录 |
| `environment_discover` | 刷新受管目录及运行进程发现的环境，返回候选 ID、名称、运行包与缓存标记，省略配置路径和凭据。沿用 Desktop 自动缓存行为；cached 不等于已验证真实 Admin 身份 |
| `environment_adopt_prepare` | 对候选环境验证正在运行、已认证且就绪的 Admin，核对配置路径并固定配置版本和启动身份，生成五分钟计划 |
| `environment_adopt_apply` | Desktop 确认后复查计划并保存连接目标，返回受理操作 ID，由 host_operation_get 查询完成；相同当前计划幂等返回原操作 ID |
| `host_disconnect` | Desktop 确认后关闭指定主机的 SSH 管理连接，清除未提交计划；拒绝正在处理的操作、未完成发布或升级，以及断开另一已连接主机。已断开时重复调用安全返回；远端实例不停止 |

“接入”仅验证并登记连接目标，不改写远端配置、不添加所有权标记、不重启，也不将外部管理的进程转换为 Desktop 受管实例。停止状态或不兼容的 Admin 不能跳过身份校验。新主机登记会刷新当前 Desktop 的主机清单。发现结果现已使用本机保存的稳定目标 ID，修复同一物理实例通过另一主机记录发现时，候选 ID 与后续目标查询不一致的问题。

实际验收使用当前安装并运行的 Desktop 界面签发的连接配置，DSH 安装包内的实际 MCP 插件经本机 Streamable HTTP 完成调用；不是以测试程序代替 Desktop 提供服务。本记录不将连接器验证记为模型会话执行全部写操作。复用 OrbStack Ubuntu 和已有 `mcp-shared-config-qa` 实例，没有新建 VM、运行环境或 Relay Hub，没有改动 bodytest。

- 通过 MCP 登记测试主机记录 `MCP Host Registration QA`，重复登记返回相同 ID；随后实际连接新记录并发现已有环境。
- 接入预检与执行完成，重复提交返回相同操作 ID，业务请求 `GET /shared-before` 返回 HTTP 200。
- 断开后主机清单显示未连接，环境发现被拒绝；独立 Ubuntu 探针确认业务仍返回 HTTP 200，且进程 PID 与启动时间完全一致。重复断开安全返回。重连后目标 ID 一致，MCP 业务探针再次返回 HTTP 200。
- 9 项拒绝用例通过：SSH 选项注入、password 参数、私钥路径参数、未知密钥来源、未知候选环境、未预检计划、错误绑定代次、未知主机，以及断开后的发现请求。
- 四项自动检查通过：主机登记与断开、生命周期、远端目标、官方 HTTP MCP 的权限和撤销集成。DSH 实际 Skill 加载器成功读取已安装 Skill；部署与调试 Skill 的官方格式验证器均通过。
- DSH 桌面现有验收会话实际调用 skill 工具重新加载新版 vhttpd-deploy 和 vhttpd-debug，正确识别登记与信任的区别、cached 与身份校验接入的区别、接入不转换进程所有权，以及主机断开不停止业务的约束。包内 guidance_get(deploy) 也返回新版流程。

当前 Desktop 已更新，原包保留为 Workbench Before Host Registry.app。收尾恢复原 default 环境，隔离业务实例停止，临时本机 MCP 和测试 SSH 入口关闭。结果见 [结构化验收证据](release-evidence/desktop-mcp-host-registry-2026-11-05.json)；详细日志保留在本机 /private/tmp/vhttpd-host-registry-qa/desktop-dsh-result.log、tests.log 和 skills-result.log。密码认证和首次指纹信任仍须在 Desktop 完成。

### 2026-11-05 主机连接、环境创建与实例启停验收

本批新增 9 个有类型的本机管理 MCP 工具，复用 Desktop 已保存主机、SSH 会话、运行包目录和 ServerWorker，不接收任意命令、私钥或密码。公网应用 Relay 不暴露这些管理写工具。

| 工具 | 契约 |
| --- | --- |
| `host_connect` | 连接已保存的密钥认证主机，Desktop 确认后返回受理 ID；首次指纹仍由 Desktop 信任界面处理。密码认证主机须先在 Desktop 登录 |
| `host_operation_get` | 查询主机连接、环境创建和实例启停的异步结果，仅返回当前绑定代次的操作 |
| `instance_status` | 经主机会话校验 Desktop 实例标识、运行包和真实进程，Admin 停止时仍可查询；running 仅表示进程存在 |
| `environment_create_prepare/apply` | 预检保存主机、已安装运行包、模板、未占用名称和端口；创建并登记环境后复用安全启动流程，拒绝接管已有目录 |
| `instance_start_prepare/apply` | 固定配置版本和进程身份，执行前复查，启动已有受管实例 |
| `instance_stop_prepare/apply` | 固定相同身份，使用 Linux pidfd 对核对后的确切进程发送 SIGTERM；不升级为强制终止 |

预检计划有效期五分钟，绑定当前开发授权、主机和操作类型；新预检替换旧计划。执行先返回 accepted 和 operation_id，再在 Worker 处理远端任务。同一当前计划重复执行返回同一操作 ID。操作记录最多 128 条，仅保留在该 Desktop 会话，重启后通过主机清单和实时实例状态重新核对。停止超时不宣称已停止，应再次查询状态。

修正了原环境创建脚本在重试时重复启动进程的问题，创建后的启动统一使用已有 start.sh。实际 Desktop 验收还发现预检回复早于 UI 接收主机快照的问题，已将主机快照处理移到 MCP 请求处理之前，复验通过。

验收复用 OrbStack Ubuntu 的隔离主机 Release QA Ubuntu，没有新建 VM 或 Relay Hub，也没有改动 bodytest。新增隔离环境 `mcp-desktop-lifecycle-1105`，目标 ID `3e9196aac428d51981294d5c`，使用已安装的 legacy 运行包、vjsx-http 模板、Admin 55183 和业务 55184。

- 已安装 DSH 的 Streamable HTTP MCP 插件实际连接当前运行 Desktop 界面签发的本机连接，而非以测试程序代替 Desktop 启动服务；列出 62 个工具，调用主机连接、创建预检与执行、操作状态、实例状态、停止及再启动预检与执行。此处是 DSH 安装包内真实连接器验收，不将其记为模型会话自动执行全部写流程。
- 创建 completed 后验证进程 running 及业务 HTTP 200；停止 completed 后验证 stopped 且业务探针失败；再启动 completed 后有界等待业务恢复 HTTP 200，最后再次停止并确认 stopped。重复提交创建计划返回原操作 ID。
- 7 个拒绝用例通过：已有名称、目录穿越名称、已占端口、未预检计划、错误绑定代次、未知操作 ID，以及试图传入 password 参数。错误信息不回显凭据。
- DSH 桌面现有验收会话实际调用 skill 工具重新加载最新安装的 vhttpd-deploy 和 vhttpd-debug，识别新增工具、accepted 后的轮询、进程与业务就绪区别，以及密码和首次指纹留在 Desktop 的约束。包内 guidance_get(deploy) 也读取到了新流程。
- 四项 V 检查通过：生命周期、远端诊断、远端目标及官方 HTTP MCP 集成。HTTP 集成因沙箱禁止监听本机端口，已在允许网络的环境重跑通过。Python 语法及创建脚本 shell 语法检查通过。

当前 Desktop 已安装包含这些能力的生产构建；原应用包保留为 Workbench Before Lifecycle.app。测试环境文件保留，实例最终停止。验收证据见本机 `/private/tmp/vhttpd-lifecycle-qa/desktop-dsh-final.log`、`tests.log`、`network-tests.log` 和 `skills-result.log`。该批验收时主机登记、发现环境接入和主机断开尚未完成；这三项的后续验收见本次主机登记与环境接入记录。密码认证仍由 Desktop 界面处理。

### 2026-11-05 能力核对与诊断入口验收

本批新增 11 个 MCP 工具。管理工具沿用已登记目标、当前 Desktop 主机连接和绑定代次。已安装的 Desktop 生产构建包含这些入口，旧应用包已保留供回退。

| 入口 | 可执行行为与范围 |
| --- | --- |
| `host_inventory_get` | 查询登记主机的连接快照、发现环境和已安装运行包，标明环境是否已经登记 |
| `runtime_packages_list`、`runtime_releases_list`、`runtime_package_probe` | 查询本机已安装包 ID、官方完整版本及校验文件，再以目标包校验整个绑定环境。预检核对返回协议、版本和配置 revision |
| `target_applications_list` | 查询远端实时应用、安装身份、版本和业务监听 ID |
| `target_request` | 对配置中确定的远端业务 HTTP 监听发 GET 或 HEAD 请求，限制响应大小并保留重定向状态。拒绝管理监听和 Admin 路径 |
| `target_diagnostics_get` | 查询远端 graph、workers、providers、relay 和 websocket 五类状态，投影受限字段 |
| `target_logs_query` | 按实时应用 ID 查询日志，支持数量、搜索和游标。验证应用归属，脱敏目标配置中的已知凭据，排除存储路径 |
| `target_events_query` | 查询有数量上限的运行事件，只返回标识、状态和请求关联字段 |
| `target_history_list` | 查询当前主机已发现的应用发布及运行时升级记录，与 `operation_get` 配合使用 |
| `relay_connections_list` | 读取本机连接库，或通过现有主机连接刷新远端连接库，返回连接标识、协议与认证是否已配置 |

`capabilities_list` 新增 `coverage_version`、`coverage_status` 和逐域 `coverage`。目录给出该域工具、指引主题和仍缺少的操作，整体状态当前为 `partial`。工具可调用与工作流验收分别记录。测试检查每个注册工具均归属已知能力域，并遍历 `tools/list` 的全部分页与会话可用项比对。

`guidance_get` 新增 `workflow`、`pipeline`、`wechat-cloud-functions`、`codexbot`、`deploy`、`debug`。这些主题来自 Desktop 生产构建，返回 `source: desktop_package`、Desktop 版本、指引版本和目标运行包版本。空工作区也能读取新主题。原有 `develop`、`vjsx` 继续由目标运行包提供版本化 API。三个 DSH Skills 已更新，其中开发 Skill增加三份项目契约，并要求在 Relay 启动受理后查询就绪。

DSH 安装包内的 MCP 客户端使用实际新版 Desktop 界面签发的本机管理配置进行验收，注册全部 53 个会话可用工具，与能力目录完全一致。复用隔离 Ubuntu 环境 `mcp-shared-config-qa` 和应用 `qa`，得到以下结果。

- 六个 Desktop 指引主题均可读取，来源与版本字段可核对。DSH 的 filesystem provider 从实际已安装目录发现三份 Skill，使用 DSH `skill` 工具逐一加载成功。
- 运行包预检返回兼容，官方版本查询返回两个完整 Linux amd64 版本。主机、已安装运行包和本机及远端 Relay 连接库查询成功，测试连接的 Token 和 URL 未出现在结果中。
- 业务探针分别返回 HTTP 200 和 404。应用日志返回 14 条同属 `qa` 的记录，游标续读通过；运行事件返回 2 条。五类诊断均返回结构化结果。历史查询读取到 1 条已有操作，并通过 `operation_get` 核对终态。
- 7 个拒绝用例通过，覆盖任意 Admin topic、管理监听、越界 URL、通配及未知应用日志、未知主机和未知运行包。
- 三组 V 测试通过，覆盖日志归属、字段投影、能力目录、HTTP 会话、分页、指引、绑定切换和授权隔离。六份 Skill 及项目参考的 OpenKnowledge lint 均为零错误、零警告。

验收后关闭临时 MCP 并清除客户端凭据，停止隔离 Ubuntu 实例和测试管理监听。更新后的 Desktop 已回到原数据目录，原 `default` 实例恢复运行。

仍待完成的范围以本节上方能力清单和 MCP 的 `coverage.remaining` 为准。该批次结束时普通 Relay 写入与数据库链路探针尚未完成，后续验收见上方对应记录。当前仍待补齐更广的共享配置变更、配置历史恢复和流式协议探针。主机与实例、本机运行包下载、安装及选择的后续验收见上方记录；密码认证和首次指纹确认仍由 Desktop 提供。微信真实账号、数据库及存储与已有项目迁移属于待完成的专项验收。

### 远端共享环境配置

通过本机 Desktop 管理会话对已登记、支持手工重启的远端环境操作。本批支持共享 HTTP pipeline 的单行 `match.paths` 精确路径修改。组件源码仍走应用发布流程。

1. `shared_config_diff` 返回配置相对路径、pipeline、原匹配路径、新匹配路径及计划 ID。预览不会改写配置。
2. `shared_config_preflight` 使用远端 Admin changeset 校验完整项目。应用前再次核对目标、绑定、配置原文和整项目版本。
3. `shared_config_apply` 经 Desktop 确认后发布并重启远端实例，等待新实例的磁盘与生效版本一致。
4. `shared_config_rollback` 在同一管理会话中用计划 ID 恢复原文，再重启并核对版本。若目标配置已被其他操作修改，则拒绝覆盖。

DSH 安装包内的 MCP 客户端在隔离 Ubuntu 实例 `mcp-shared-config-qa` 依次完成 `preview`、`prepared`、`applied` 和 `rolled_back`，计划 ID 为 `4b0979d3fe445cdff824ecf7`。对 `qa.shared` 直接发起业务请求。预检前后，`/shared-before` 与 `/shared-after` 分别返回 HTTP 200、404。应用后为 404、200。回滚后恢复 200、404。部署与调试 Skills 已补上对应流程。

## 后续远端工具

下表中的名字是提案。各工具复用 Desktop 主机、组件安装和接管实现，由 Desktop 保管凭据与执行授权。

| 能力 | 拟补工具 | 行为 |
| --- | --- | --- |
| 主机发现与诊断 | `targets_list`、`target_status` | 已实现本机管理 MCP 的只读查询。枚举 Desktop 登记的主机和环境，状态取自匹配目标的当前快照。版本和应用清单仅在已知时返回。2026-11-04 17:57（上海时间）在 DSH 实际列出 bullsoft 及其环境，按 ID 查询 bodytest 的未连接状态，并验证未知 ID 返回 `unknown_target`。后续用 DSH 在同一管理连接下查询已连接的 bodytest，确认主机、运行时及应用清单均可读取，运行版本为 0.9.0，应用为 `paseo`、`public`、`wechat`。 |
| 应用发布 | `application_release_prepare`、`application_release_apply`、`application_release_rollback` | 已实现，仅本机管理 MCP 提供。使用绑定的独立应用、已登记并连接的环境、安装槽和可选安装 ID 生成预检；Desktop 确认后发布或回滚，`operation_get` 查询终态。已在隔离 Ubuntu 实例通过 DSH 实测。 |
| 运行时升级 | `runtime_upgrade_prepare`、`runtime_upgrade_apply`、`runtime_upgrade_rollback` | 已实现，仅本机管理 MCP 提供。预检固定目标实例和运行包，列出受影响应用、重启范围和原版本。Desktop 确认后提交，由 `operation_get` 查询终态。已在 DSH 对同一测试实例实测升级和回滚。 |
| 远端接管 | `takeover_status`、`takeover_prepare`、`takeover_start`、`takeover_release` | 已实现，仅本机管理 MCP 提供。通过已绑定的应用安装和认证账号预检，Desktop 确认后启动，按租约 ID 释放。在 DSH 实测原业务地址的流量切到本机并恢复到远端。 |
| 长操作 | `operation_get` | 已实现本机管理 MCP 的只读查询。通过 `target_status` 发现已知的操作 ID，再查询阶段、终态和恢复状态。重连原主机后使用远端 Worker 重新发现的记录。DSH 实际查到 bodytest 一条应用发布和一条运行时升级均为 `completed`，未知 ID 返回 `unknown_operation`。 |

远端写操作使用带期限的 `plan_id`，绑定目标、产物或包版本、基线状态和授权范围。执行前重新比对基线，重试通过操作记录返回原执行结果。远端诊断与应用发布优先，运行时升级和流量接管随后开放。远端源码就地编辑独立评估。 [组件安装](../desktop/host/component_installation.v) · [运行时升级](../src/runtime_upgrade/deployment.v) · [接管实现](../desktop/host/takeover.v)

### 应用发布与回滚契约

- 本机管理 MCP 的应用必须来自 Desktop 绑定的独立源码目录，并具备 `app.json`。使用 `context_get` 获取当前 `binding_revision`，用 `targets_list` 选择已连接的 SSH 手工环境。公开 Relay 即使允许编辑，也不提供这三个管理工具。
- `application_release_prepare` 接受 `target_id` 和 `component`。首次安装省略 `installation_id`，更新沿用首次预检返回的安装 ID。预检返回文件变化、目标版本、计划和操作 ID，计划有效期五分钟。发布前重新验证本机包指纹，远端助手核对目标运行包、启动代次、配置和受影响文件。
- 用同一计划调用 `application_release_apply`。Desktop 对话框显示目标、安装槽、版本和操作 ID，并明确整个环境短暂重启。按 `operation_get` 跟踪远端状态；`submitted` 只表示已提交，`completed` 表示远端运行已通过生效检查。同一活动计划的重复提交沿用操作 ID。
- 显式回滚先调用 `application_release_prepare`，将当前已生效的发布操作 ID 传入 `rollback_from`，不传 `installation_id`；再用返回的计划调用 `application_release_rollback` 并在 Desktop 确认。回滚复用发布事务，从远端上一个成功产物生成新操作，保留安装 ID、监听设置和环境数据。首次安装、旧版本未保留产物、当前发布不匹配或历史产物损坏时拒绝回滚。它不撤销数据库迁移或业务数据写入。

### 2026-11-04 DSH 远端发布验收

在 DSH 桌面端通过本机 Streamable HTTP 管理连接 `vhttpd_release_qa`，对 OrbStack Ubuntu 的隔离实例 `release-qa` 实际调用预检、发布、回滚和 `operation_get`。首次发布 1.0.0 返回 `{"release":"A"}`。第一次尝试回滚发现旧助手会删除临时包，修复后重新执行下列流程：

| 步骤 | DSH 操作 ID | 终态与业务响应 |
| --- | --- | --- |
| 发布 1.2.0 | `ee74f67fc3fae8a757c9e3bc` | `completed`，HTTP 返回 `{"release":"A2"}` |
| 发布 1.3.0 | `d0a981d56c5083b4ca654b56` | `completed`，HTTP 返回 `{"release":"B2"}` |
| 回滚至 1.2.0 | `890293b9b62d95ba9a4504ab` | `completed`，HTTP 恢复为 `{"release":"A2"}` |

三次 Desktop 确认均核对了隔离目标。独立 HTTP 请求证实应用实际生效；安装 ID 和环境数据校验通过，发布助手清理临时包后保留的独立产物仍可用于回滚。未改动 bodytest。macOS Desktop MCP 集成测试验证新工具只在本机管理会话列出；回滚产物测试验证清理后仍可重放，以及拒绝过期操作 ID、错误应用身份和损坏产物。运行时升级的 DSH 验收见下文。

### 运行时升级与回滚契约

- 用 `context_get` 获取绑定代次，再用 `target_status` 查询目标和主机已安装运行包的 ID、版本与发布标签。调用 `runtime_upgrade_prepare` 时传 `target_id` 和 `target_runtime_id`。目标包须支持升级协议并通过整份配置校验。
- 预检返回原包、目标包、受影响应用和整实例重启范围。计划有效期五分钟。调用 `runtime_upgrade_apply` 时使用同一计划，Desktop 显示目标、版本和影响范围并请求确认。提交前重新核对实例启动代次、生效配置和目标二进制校验值。远端助手执行切换和就绪验证，启动失败时尝试恢复原包。
- 显式回滚时，`runtime_upgrade_prepare` 改传 `rollback_from`，引用该目标最新且仍对应当前运行包的成功升级操作。预检从该记录取原包，原包须仍在运行包库。使用返回的计划调用 `runtime_upgrade_rollback`，经 Desktop 确认后提交。同一个活动计划沿用操作 ID，使用 `operation_get` 跟踪终态。公网 Relay 不提供这些管理工具。

### 2026-11-04 DSH 运行时升级验收

使用 DSH 桌面端的本机 Streamable HTTP 管理连接 `vhttpd_release_qa`，在 OrbStack Ubuntu 上复用已有 `release-qa` 实例。预检列出受影响应用 `releaseqa`，升级和回滚均经 Desktop 确认。

| 步骤 | DSH 操作 ID | 结果 |
| --- | --- | --- |
| `0.9.0` 升级至 `0.9.1` 测试构建 | `d3443262c74a83380828c1e4` | `completed`，管理端报告 `0.9.1` 就绪，业务 HTTP 返回 `{"release":"A2"}` |
| 从 `0.9.1` 显式回滚至原包 `0.9.0` | `d2e115c7789a01f3817e8d21` | `completed`，管理端报告 `0.9.0` 就绪，业务 HTTP 返回 `{"release":"A2"}` |

独立探针确认实例 ID 一致，两次切换后的配置、应用文件、安装记录和测试数据均通过基线校验。Desktop MCP 集成测试验证本机工具注册和公开 Relay 的隔离。测试目标包是在 Ubuntu 用 GCC 构建的 `0.9.1` 验收包。

### 远端接管契约

- 在 Desktop 绑定本机源码与已登记的远端安装，并启动配置了认证 Relay Agent 和 `debug/http` 的本机接收端。远端导出 `debug/control`，Relay Hub 和目标应用的业务监听须由同一个运行时所有者处理。将 Hub 的 WebSocket 路径挂在业务监听上即可满足这一条件。
- `takeover_status` 按绑定代次、目标及安装查询租约。`takeover_prepare` 检查应用绑定、接收引擎、配置生效状态、Relay 连通和当前租约，固定认证应用与单个账号。预检计划五分钟内有效。
- `takeover_start` 通过 Desktop 确认后复查本地配置和绑定，远端核对应用与安装身份。成功返回当前租约，最长 15 分钟。`takeover_release` 校验该会话创建的确切租约，并再次查询远端状态。公网 Relay 不提供这些管理工具。
- MCP 的 `state` 表示租约状态。端到端验收还需向原业务地址发已认证请求，检查实际执行位置和未接管账号的行为。关闭连接或租约到期时，由现有运行时恢复新请求的远端执行。

### 2026-11-04 DSH 远端接管验收

DSH 通过本机 `vhttpd_release_qa` MCP 对 OrbStack Ubuntu 上已有的 `release-qa` 实例调用了四个接管工具。预检计划为 `d1f3288f94cae8a1f83dcf17`，Desktop 确认后发放租约 `ebd58c4a1de854487539be73a22f6dbf`。在原业务监听的 `POST /functions/probe` 上独立探测：

| 阶段 | DSH 租约状态 | `qa-alice` | `qa-bob` | 未认证 |
| --- | --- | --- | --- | --- |
| 接管前 | `remote` | Ubuntu | — | — |
| 启动后 | `local` | Mac，含 `x-vhttpd-execution: local` | Ubuntu | HTTP 403 |
| 释放后 | `remote`，租约清空 | Ubuntu | Ubuntu | HTTP 403 |

旧测试包曾出现 Relay 连接标识损坏，验收使用当前源码在 Ubuntu 以 GCC 和 Boehm GC 构建的测试包。初次配置把 Hub 放在独立监听器所有者，租约存在但业务仍在远端。释放诊断租约后，将 Hub 挂回业务监听并重跑才通过。Desktop MCP 集成测试验证本机工具注册和公网 Relay 隔离。

### DSH 应用开发闭环

在 Desktop 绑定隔离的本机 `releaseqa` 应用后，DSH 实际加载 `vhttpd-develop`。开发任务只给出业务要求：增加 `GET /api/hello`，返回 HTTP 200 和 `{"message":"hello"}`，保留原首页。DSH 通过本机 MCP 读取项目指引、版本化 vjsx API、schema、模板和带 revision 的源文件，然后执行 `changes_prepare`、`changes_validate`、`changes_apply` 和 `runtime_start`。变更 `516f6c4465953e89346d07ea` 生效后，`application_request` 验证新路径返回 HTTP 200 和预期 JSON，首页仍返回 HTTP 200 和 `{"release":"B2"}`。开发步骤通过 MCP 执行。随后 DSH 应用临时变更 `04328b2f2eec5147cfd486c1` 注入入口异常。配置校验通过，运行时启动失败，`logs_query` 返回 `qa_startup_failure`。恢复该变更并重启后，`/api/hello` 再次返回 HTTP 200 和预期 JSON。最后恢复初始变更，核对首页基线并停止测试运行时。

`vhttpd-deploy` 和 `vhttpd-debug` 已更新为对应 MCP 工作流，DSH 实际加载两份新版并核对了升级回滚与接管释放工具。Unix、Windows 和 macOS Desktop 的打包配置已纳入三份 Skill。Desktop 负责创建或绑定源码及确认需要授权的远端操作。

## 第一阶段验收

每批新增的 MCP 工具和平台 Skill 都须安装到 DSH 或 WorkBuddy，并从该客户端实际调用或加载。验收记录写明客户端、工具或 Skill 名称、目标、操作结果及未覆盖项。构建检查与服务端测试可作为补充证据。

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

## 首期实施状态

| 交付项 | 状态与证据 |
| --- | --- |
| 应用绑定与项目指引 | Desktop 绑定应用源码根，公开会话要求 `binding_revision`。模板生成项目 `AGENTS.md`，集成用例覆盖项目主题、应用切换及旧代次、旧预览和越界路径拒绝。 |
| 随运行包发布的开发指引 | `vhttpd --development-guide develop` 和 `vhttpd --development-guide vjsx` 返回运行包版本、来源、profile 和正文。Desktop 的 `guidance_get` 从所选二进制读取，拒绝版本不匹配或缺少指引的包。macOS 生产构建 0.9.0 已验证两个主题及未知主题错误。 |
| `vhttpd-develop` Skill | 源码与发布包共用同一份 Skill 和 vjsx 参考。Unix 与 Windows 独立运行包放在 `skills/vhttpd-develop`，macOS Desktop 内置运行包放在 `Contents/Resources/runtime/skills/vhttpd-develop`。支持 Skills 的客户端可安装整个目录。已从本地测试归档核对 Markdown 与运行时嵌入内容逐字一致。2026-11-04 17:47（上海时间）在 DSH 安装并用 `skill` 工具加载该目录，随后实际调用公网 MCP `context_get` 和 `guidance_get`，确认 `hello-vjsx` 的 `develop` 指引来源为 `runtime_package`，版本为 0.9.0。 |
| 已有 Hub 的 Relay 发布和回收 | 本机绑定会话提供 `relay_create_prepare`、`relay_create_apply`、`relay_status` 和 `relay_revoke`。先在 Desktop 选择已有可信 WSS Relay 并填入 HTTPS MCP 地址。计划有效期五分钟，提交时由 Desktop 确认，授权有效期一小时。撤销需提交发布 ID，以防旧请求影响新发布。Bearer 只在 Desktop 展示。 |
| 远端专用 Hub | 已实现。先绑定本机应用，再切到已连接的远端环境，在 MCP 页面选择该环境作为 Hub 目标。回到本机 MCP 页面填写公网 HTTPS 地址。提交发布计划后，Desktop 使用目标环境的已安装运行包启动独立 Hub，返回两个远端 loopback 端口。网关将公开 MCP 路径代理到 `hub_http_port` 的 `/mcp`，并将 `/vhttpd/relay/desktop-mcp` 的 WebSocket Upgrade 转发到 `hub_carrier_port`。撤销先使本机授权失效，再回收本次 Hub。 |
| bodytest 单端口部署 | 复用 bodytest 现有 vhttpd 实例。网关把 HTTPS 和 WebSocket Upgrade 都回源到 `127.0.0.1:58595`。`/mcp` 由 `mcp_web` ingress 转发，`/vhttpd/relay/desktop-mcp` 在同一监听器建立 Relay WebSocket。`relays.edge.listener` 指向 `listener:mcp_web`。已移除 `56481` 监听。 |
| 公网客户端验收 | DSH 已在 bodytest 单端口部署上经公网 HTTPS Streamable HTTP 实际调用 `context_get` 和 `files_list`。还验证了运行时停止时查询 `engines/vjsx` schema，以及在启动耗时超过 30 秒时通过 `runtime_start` 受理、`runtime_status` 确认就绪并验证业务响应。WorkBuddy 桌面端已通过公网 Relay 验证编辑和恢复，详见下文。独立网络出口未验收，ChatGPT 网页本轮按用户回复跳过。 |

### 2026-11-04 本机与 Ubuntu 验收

macOS 和 OrbStack Ubuntu 均通过 Desktop MCP 集成测试。Ubuntu 使用 GCC 构建 Boehm GC 运行包，测试独立启动 Hub、Agent 和 Desktop MCP。

- Desktop MCP 集成测试通过。仅本机绑定会话列出四个 Relay 管理工具，公开授权会话不列出。用例覆盖拒绝授权、目标变更导致计划失效、同一计划重试保留原 Bearer、错误发布 ID 拒绝、重复撤销及凭据撤销。
- 在 macOS 用真实 vhttpd Hub、WebSocket Agent 与 Desktop MCP 测试 Streamable HTTP。带 Bearer 的初始化、工具调用、GET 响应语义和 DELETE 会话终止通过，无 Bearer 返回 HTTP 401。编辑通过 diff、校验、应用、启动及业务请求，随后停机恢复并确认原始源码。撤销后旧授权无法再次初始化。
- 停止运行时后，MCP 仍可读取 `engines/vjsx` 随包 schema、开发工作流和 vjsx API 指引。生产二进制报告 0.9.0，两个主题与归档内容一致，未知主题返回错误。
- 内置 `/mcp` HTTP 路由现在遵循已有的管道优先级。Hub 配置可将 GET、POST 和 DELETE 转给 Relay，未配置覆盖的请求继续使用内置 MCP。
- 专用 Hub 管理脚本在 Ubuntu 使用真实 vhttpd 启动两个独立 Hub。重复回收其中一个后，另一个的两个端口继续监听。专用进程最多运行一小时。
- `relay_status` 在后台用当前授权向已配置的 HTTPS 地址发送 Streamable HTTP `initialize`，校验证书且禁止重定向。识别 Desktop MCP 响应后结束探测会话。macOS 集成测试验证初始化、会话清理、工具调用和撤销。工具结果只包含握手状态和 HTTP 状态码等非凭据信息。
### 2026-11-04 bodytest 单端口公网验收

- 网关配置将整个域名代理到 `http://127.0.0.1:58595`，并传递 WebSocket Upgrade。公网客户端 POST 到 `/mcp`，Mac Relay Agent 则连接 `/vhttpd/relay/desktop-mcp`。bodytest 将 MCP 请求通过该 WebSocket 交给 Mac 上的 `mcp-upstream`，再由本机 Desktop MCP 处理。
- 远端 `ss` 确认 bodytest 的 `58595` 正在监听并有已建立连接，`56481` 无监听。公网 MCP 初始化此前已返回 HTTP 200。
- 17:44（上海时间），DSH 用只读凭据发起新一轮公网调用。`context_get` 返回 `binding_revision: 1` 和应用 `hello`，`files_list` 带同一代次调用成功，返回 `main.mts` 和 `vhttpd.toml`。
### 2026-11-05 Relay 运行时启动 504 修复

- 历史失败中的同一请求在 Mac Agent 侧约 30 秒触发 `mcp_upstream_fetch_failed`，原因是等待 Desktop MCP 响应时读取超时。Hub 的等待预算同为 30 秒，最终返回 HTTP 504 并记录 `relay_returned_frame_not_found`。当时 WebSocket 已完成握手，最后一个业务监听约 40 秒才启动。
- 经 Relay 的 `runtime_start` 和 `runtime_restart` 在 Desktop 接管启动进程后返回 `accepted: true` 和 `phase: starting`。客户端用相同的 `binding_revision` 轮询 `runtime_status`，确认完整环境就绪且磁盘版本与生效版本一致后，状态返回 `readiness: ready`。接着调用 `application_request` 验证业务响应。启动失败或停止时结束轮询。
- 公网验收复用 bodytest 的 `58595` 和 Mac 上已有的 vhttpd 运行包。Mac Agent 采用 bodytest 对应的 `edge` Relay 配置，主动连接公网 `/vhttpd/relay/desktop-mcp` 并建立全双工 WebSocket 长连接。DSH 安装包内的 MCP 客户端使用临时编辑 Bearer，从公网 HTTPS `/mcp` 走 Streamable HTTP 调用隔离测试应用。
- 在隔离应用启动前人为延迟 34 秒。DSH 在 115 毫秒收到受理，29 次查询返回等待状态，38.46 秒后确认 `running` 和 `ready`。`application_request` 请求 `/api/hello` 返回 HTTP 200。随后通过 DSH 停止运行时并确认 `stopped`。临时发布撤销后，公网入口在无已连接 Agent 时返回 HTTP 503。

- macOS 的 `desktop/devmcp/server_test.v` 通过。用本机 vhttpd Hub、Agent 和同样的 34 秒启动延迟验证了编辑、启动受理、就绪、业务响应、停止、源文件恢复和撤销。

- 当前安装的 `Workbench Update QA.app` 已替换为包含修复的生产构建，保留旧应用包供回退。通过实际 Desktop 界面绑定隔离应用 `relayqa`、加载 bodytest 的 `edge` Relay 并发布编辑授权。DSH 安装包内的 MCP 客户端使用界面刚签发的 Bearer，经公网 HTTPS Streamable HTTP 调用 `runtime_start`，170 毫秒收到受理，5 次等待查询后在 6.73 秒确认 `readiness: ready`，`/api/hello` 返回 HTTP 200。本轮使用实际 vhttpd 启动耗时。测试后停止隔离实例、在界面撤销临时发布并清除临时客户端凭据，重新打开更新后的 Desktop，恢复原 `default` 实例运行。

### WorkBuddy 公网开发验收

按用户选择使用 WorkBuddy 5.9.3。WorkBuddy 桌面端在本机通过公网 HTTPS Streamable HTTP 连接 `mcp.bullsoft.org/mcp`，由 Relay 转发到 Desktop 绑定的隔离应用 `releaseqa`。确认信任自定义连接器后，WorkBuddy 实际调用 `context_get`、`guidance_get`（`develop` 和 `vjsx`）、`files_read`，并用文件 revision 完成变更 `21abaa0ebbc334dba86d1f3b` 的预检、校验、应用和启动。新接口 `GET /api/public-qa` 返回 HTTP 200 和 `{"message":"public-relay-ok"}`，首页仍返回 `{"release":"B2"}`。

WorkBuddy 停止运行时并执行 `changes_restore`，重启后首页和测试路径都返回基线 `{"release":"B2"}`，最后再次停止运行时。独立文件比较确认源码与验收前逐字节一致。启用编辑授权期间，无凭据的初始化返回 HTTP 401。撤销后使用旧凭据重新初始化返回 HTTP 503，临时 WorkBuddy 连接已移除。

此次覆盖 WorkBuddy 桌面客户端的公网 Relay 写入和恢复。ChatGPT 网页按用户回复跳过。独立网络出口仍未验收，WorkBuddy 和 Desktop 运行在同一台 Mac。
