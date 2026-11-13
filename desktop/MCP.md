---
title: Desktop MCP 开发服务
description: 本机模型开发服务的连接、工具流程、文件边界和验证方式。
tags:
  - desktop
  - mcp
  - development
---
# Desktop MCP 开发服务

Desktop 使用 V 官方 `vlib/mcp` 提供本机 Streamable HTTP 服务。开发对象是当前运行环境中的应用，源码位置由 Desktop 定位，用户无需选择开发目录。

## 创建应用

应用页提供“新建应用”和“安装已有应用”。新建时填写应用标识、选择 HTTP / JSON API 模板和业务端口（0 表示自动选择），点击预览，再确认安装。Desktop 自动生成源码与 component.toml，复用独立应用安装的完整校验、冲突检查和失败恢复。本机和已连接的远端环境使用同一安装流程。实现见[模板生成](./host/application_creation.v)与[安装页面](./component_installation.v)。

“新建运行环境（独立进程）”仍用于创建 vhttpd 进程、管理入口和环境配置；一个运行环境可以承载多个应用。它与应用页的新建应用是不同操作。

## 开启和切换

1. 选择本机运行环境，从“管理 → 模型开发 · MCP…”进入。
2. 在应用下拉框选择开发对象。默认使用当前应用，应用列表也支持在环境停止时读取。
3. 开启 MCP，将页面显示的 URL 和 Authorization Bearer 凭据填入受信任的 MCP 客户端。
4. 在 MCP 页面切换应用即可继续开发；没有每应用的开发按钮。正在执行的操作先完成，排队的旧上下文请求会被拒绝，旧预览失效。URL、凭据与 MCP 会话保持稳定。
5. 跨运行环境切换时，可使用“切换到当前环境”；若原环境仍有运行进程，需先停止。页面始终显示 MCP 当前绑定的运行环境和应用。

关闭 MCP 或退出 Desktop 后连接失效。重新开启生成新端口与凭据。服务默认关闭，仅监听 127.0.0.1，拒绝带 Origin 的网站请求。本版 MCP 开发只支持本机应用；远端应用可在应用页新建、安装，尚无远端源码编辑工具或 stdio 桥接。

## Relay 接入测试

在本机 MCP 页面确认项目目录后，可以签发单独的 Relay 只读或编辑授权。授权有效期为一小时，绑定切换、关闭 MCP 或手动撤销会使它失效。只读授权只开放只读工具，编辑授权包含对整个选定运行环境的启停。Relay 调用先执行 `context_get`，后续应用调用带上返回的 `binding_revision`。

当前可手动使用 [Hub 示例](../examples/config/mcp-relay-public-v2.toml) 和 [Agent 上游示例](../examples/config/mcp-relay-local-upstream-v2.toml) 联调。Agent 和 Desktop 运行在同一主机，Agent 的 MCP 上游 URL 填 Desktop 显示的 Relay loopback URL，Web Agent 的 URL 填受信任的 HTTPS 入口，认证使用 Relay 授权的 Bearer。公网联调还需要在入口配置 TLS、请求限流与授权策略。Desktop 页面目前签发和撤销本机授权，Hub 路由仍需单独配置。

## 模型开发流程

模型先用 context_get 读取当前应用与环境，再使用 files_list、files_read 获取应用相对路径、内容和 revision。changes_prepare 创建预览，changes_validate 对整个环境及跨 include 配置进行校验；随后 runtime_stop、changes_apply、runtime_start，最后用 application_request 验证业务响应。

源码错误通过真实启动发现，配置校验通过不等于业务通过。失败时查询 logs_query，停止后修改或用 changes_restore 恢复；changes_discard 可释放不再需要的预览与恢复记录。运行中的 schema_get 返回当前运行包的真实配置 schema。启停与重启影响环境中的全部应用。

应用绑定模式不会向模型提供 project_create/project_select；创建和选择开发对象由 Desktop 负责。已有工程型应用在配置有明确源码归属时也可以选择；多个应用共用同一源码目录的情况需要先整理为独立应用。

## 范围和恢复

- 文件路径相对于所选应用。拒绝目录穿越、符号链接、私有文件和其他应用源码；应用配置不能覆盖共享环境设置、管理入口和凭据。旧工程的环境 include 同样受到保护。
- application_request 只访问所选应用的本机业务监听器，不访问 Admin，也不跟随重定向。写请求可能改变业务数据。运行中的日志查询使用应用日志。
- 最多扫描 4096 个文本文件、16 层目录；单文件最多 1 MiB。每个变更集最多 32 个文件，前后内容合计最多 4 MiB，每次 Desktop 会话最多保留 16 个预览或恢复记录。
- 预览后文件变化需重新准备。恢复前检查已应用的内容，遇到外部修改会报告冲突。恢复材料仅在内存中，不覆盖 Desktop 或系统崩溃恢复，也不回滚数据库。
- 已知凭据在返回内容中脱敏，编辑时保留 vhttpd-secret 占位符。此能力不识别任意业务数据中的敏感信息；应用执行也不属于操作系统沙箱。

## 实现与验证

MCP 与 GUI 共用[同一个 Worker](./host/worker.v)，使用独立回复通道。应用发现、绑定和切换见[应用上下文](./host/development_application.v)，HTTP 接入见[MCP 服务](./devmcp/server.v)，写入边界见[文件变更](./host/development_files.v)。

针对性测试覆盖[模板安装与作用域](./host/application_creation_test.v)、[真实 HTTP 切换](./devmcp/server_test.v)、[MCP 页面](./development_mcp_test.v)和[新建表单](./component_installation_test.v)。运行包与工具链继续按[固定提交](./ci/toolchain.env)管理。
