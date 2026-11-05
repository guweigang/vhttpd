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
| 工作区、应用与模板 | `context_get`、`templates_list`、`project_create`、`project_select`、文件读取及 revision 变更；应用绑定由 Desktop 选择 | 工作区授权后的模板创建与已有项目接入、独立应用创建与绑定、可发现的模板依赖和版本。区分工作区授权、应用授权和目标环境授权 |
| vhttpd 配置与数据面 | `schema_get`、配置校验、启动和业务 HTTP 请求 | 让 Agent 发现目标版本支持的 listener、ingress、pipeline、adapter、transform、policy、engine、provider 和资源类型。提供按能力的例子与验证契约，覆盖 HTTP、流式请求、WebSocket、Relay 和应用业务 MCP |
| 应用脚本、兼容库与集成 | vjsx 指引和 HTTP/JSON 模板 | 按 profile 交付标准库、宿主 API、可用模块、版本限制和验证样例。纳入微信云开发兼容库、仓库中的 Codex Bot 应用组件和纯 TOML pipeline |
| Desktop 主机和环境管理 | `targets_list`、`target_status` | 主机登记与连接状态、远端实例发现和接入、环境创建和实例生命周期；连接凭据由 Desktop 管理。明确区分正在管理的实例、已发现实例和当前源码绑定 |
| 运行包与发布 | 本地启停、远端应用发布与回滚、运行时升级与回滚、`operation_get` | 运行包发现、下载与安装、版本选择和兼容性查询；应用安装清单和历史查询；共享环境配置的 diff、预检、应用与恢复 |
| Relay 与流量接管 | 公网 MCP Relay 创建、状态、撤销；接管预检、启动、状态、释放 | 普通 Relay、共享 Relay、数据库 Relay 和链路探测的发现与诊断；按具体操作开放配置及生命周期管理，保留现有发布与接管工具 |
| 运维诊断与恢复 | 本地运行状态、日志、业务请求、会话内源码恢复 | 运行图、配置与发布历史、远端应用日志和事件、worker 和 provider 状态、协议级探测。已有 Admin 配置变更与运行计划替换通过明确的受控操作接入，并报告适用版本和影响范围 |

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
- DSH 安装包内的 MCP 客户端通过 Streamable HTTP 实测。停机时读到运行包 0.9.0，诊断调用返回 `runtime_not_running`。启动后运行图返回 5 个节点、3 条边，另三类接口均返回结构化状态。测试环境未配置独立 worker、provider 实例或 Relay Agent，三类列表均为空。任意 Admin 路径作为 topic 被拒绝，测试实例已停止。

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
| 公网客户端验收 | DSH 已在 bodytest 单端口部署上经公网 HTTPS Streamable HTTP 实际调用 `context_get` 和 `files_list`。此前还验证了运行时停止时查询 `engines/vjsx` schema。WorkBuddy 桌面端已通过公网 Relay 验证编辑和恢复，详见下文。独立网络出口未验收，ChatGPT 网页本轮按用户回复跳过。 |

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
### WorkBuddy 公网开发验收

按用户选择使用 WorkBuddy 5.9.3。WorkBuddy 桌面端在本机通过公网 HTTPS Streamable HTTP 连接 `mcp.bullsoft.org/mcp`，由 Relay 转发到 Desktop 绑定的隔离应用 `releaseqa`。确认信任自定义连接器后，WorkBuddy 实际调用 `context_get`、`guidance_get`（`develop` 和 `vjsx`）、`files_read`，并用文件 revision 完成变更 `21abaa0ebbc334dba86d1f3b` 的预检、校验、应用和启动。新接口 `GET /api/public-qa` 返回 HTTP 200 和 `{"message":"public-relay-ok"}`，首页仍返回 `{"release":"B2"}`。

WorkBuddy 停止运行时并执行 `changes_restore`，重启后首页和测试路径都返回基线 `{"release":"B2"}`，最后再次停止运行时。独立文件比较确认源码与验收前逐字节一致。启用编辑授权期间，无凭据的初始化返回 HTTP 401。撤销后使用旧凭据重新初始化返回 HTTP 503，临时 WorkBuddy 连接已移除。

此次覆盖 WorkBuddy 桌面客户端的公网 Relay 写入和恢复。ChatGPT 网页按用户回复跳过。独立网络出口仍未验收，WorkBuddy 和 Desktop 运行在同一台 Mac。
