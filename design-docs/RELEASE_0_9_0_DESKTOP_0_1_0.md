---
title: vhttpd 0.9.0 与 Desktop 0.1.0 联合发布清单
description: 2026-11-02 至 11-08 发布范围、实现状态、验收证据、阻断项及执行顺序。
tags: [release, vhttpd, desktop, acceptance]
status: in-progress
updated: 2026-11-02
---
# vhttpd 0.9.0 / Desktop 0.1.0 发布清单

目标窗口：2026-11-02 至 2026-11-08（Asia/Shanghai）。来源：本次发布筹备会话中维护者提出的六项要求。日期不代替质量门禁；未关闭阻断项时顺延。本文是工作清单，不是已发布功能声明。

## 使用规则与优先级

- **已实现**：有实现或文档证据；实现勾选不代表发行包验收通过。
- **待验收**：实现存在，但缺少本次候选提交、平台和安装包对应的有效证据。
- **缺失**：文档明确尚未支持，或当前未找到交付物；“未找到”不等于证明没有代码，须继续核对。
- **P0**：稳定性、数据完整性、凭据与操作边界，阻断全部正式发布。
- **P1**：本次承诺功能、平台、示例、官网或发行交付缺口，阻断联合发布；范围变更须维护者明确决定，不能自行降级。
- **P2**：承诺范围外的体验改进，可在明确记录后延期。

每个未勾选项关闭时追加：候选 commit、依赖版本、平台/架构、包 SHA256、命令、退出码、原始日志和结论。修复影响的验收必须在最终候选包上重跑。历史文档中的通过记录仅作为基线，不能自动核销本次发布；历史来源见[重构验收记录](./REFACTOR_PHASE_REMAINING_WORK.md)。

## P0-01 候选源码与版本可追溯

- [x] 已实现：运行时版本声明与 Desktop 独立版本入口存在，见 [v.mod](../v.mod)、[Desktop 版本](../desktop/version.txt)、[版本解析](../desktop/workbench_version.py)。
- [ ] 待验收：冻结 vhttpd 0.9.0 / Desktop 0.1.0 候选提交、依赖提交和构建参数；当前工作区含未提交修改，不能作为已冻结候选。
- [ ] 待验收：记录所有发行包摘要、实际版本、源码提交和测试输入，下载页与附件一致。
- [ ] 待验收：全部正式包均由对应候选源码构建；禁止用开发机旧二进制替代发行包。
- [ ] 待验收：运行时及 Desktop 独立标签路径、重跑行为、已公开版本防覆盖全部通过。

实现入口：[构建流程](../.github/workflows/vhttpd-binaries.yml)、[开发版交付流程](../.github/workflows/development-release.yml)、[Mac 发布流程](../.github/workflows/workbench-macos-runtime.yml)。

## P0-02 GC、内存与资源生命周期

- [x] 已实现：GC 构建门禁及实际二进制检查，见 [GC 构建回归](../scripts/ci/test_build_gc.py)和[实际 GC 检查](../scripts/ci/verify_gc_runtime.py)。
- [ ] 待验收：每份发行包的 --build-info 证明启用 Boehm GC；启用 GC 不能替代泄漏检查。
- [ ] 缺失（尚未找到发布级证据）：为最终候选包建立至少 24 小时稳定性记录，覆盖 HTTP、WebSocket/Relay、数据库、Provider、取消与超时。
- [ ] 缺失（尚未找到统一门禁）：固定负载、预热/采样/冷却时长和各资源预算；在运行前记录判定阈值，不能看到结果后调整。
- [ ] 待验收：重复连接/断开、应用启停/重载、Provider 创建/销毁后，RSS/私有内存、句柄或 FD、线程、队列和连接池均无未解释的持续增长。
- [ ] 待验收：结合平台适用诊断工具检查原生和 JS 资源；保存分配/释放证据，区分 GC 高水位与真实泄漏。
- [ ] 待验收：停止流量后资源收敛，慢客户端、断线、超时和异常路径均能释放。
- [ ] 待验收：零崩溃、零未解释死锁、无持续恶化的错误率或延迟；出现问题必须复现、修复并重验。

有限时长测试不构成“绝无泄漏”的证明。放行结论必须限定负载、时长和平台。

## P0-03 部署、升级、接管的恢复与隔离

- [x] 已实现：运行包升级、应用安装及恢复基础，见[工作台说明](../desktop/README.md)与[独立应用安装](../desktop/APP-INSTALLATION.md)。
- [x] 已实现：请求接管相关实现和 E2E 入口存在，见[接管宿主](../desktop/host/takeover.v)、[接管注册表](../src/takeover/registry.v)及[接管测试](../tests/relay-takeover/e2e.py)。
- [ ] 待验收：安装/升级/部署预检失败时原应用持续可用；预览后输入变化必须拒绝提交。
- [ ] 待验收：新版本启动失败、业务未就绪、跨 include 未生效时恢复原版本及配置；外部修改冲突不得覆盖。
- [ ] 待验收：SSH 断开或 Desktop 退出后，远端事务继续，重连能恢复准确状态。
- [ ] 待验收：接管成功、鉴权失败、失联、取消和退出接管，路由与远端处理恢复符合预期。
- [ ] 待验收：只影响目标应用；同进程其他应用、凭据、数据库和未托管文件不被误改。
- [ ] 待验收：日志、MCP 返回值、部署包及发布附件不泄露凭据，不能误杀外部进程。

## P1-01 三平台实际交付

以下为待确认的支持矩阵，不能仅由已有 CI 配置推导为正式支持承诺。参考[运行时矩阵](../.github/workflows/vhttpd-binaries.yml)、[Windows 运行时](../.github/workflows/vhttpd-windows.yml)、[Linux Desktop](../.github/workflows/workbench-linux-runtime.yml)、[Windows Desktop](../.github/workflows/workbench-windows-build.yml)及[Mac Desktop 说明](../desktop/README.md)。

| 产品 | 平台/架构 | 实现状态 | 正式包验收 |
| --- | --- | --- | --- |
| vhttpd | macOS arm64 / amd64 | 构建流程已实现 | 待验收 |
| vhttpd | Linux arm64 / amd64 | 构建流程已实现 | 待验收 |
| vhttpd | Windows amd64 | 独立流程已实现 | 待验收 |
| Desktop | macOS arm64 | 已有交付路径 | 待验收 |
| Desktop | Linux arm64 / amd64 | 已有构建/验证流程 | 待验收 |
| Desktop | Windows amd64 | 已有构建/验证流程 | 待验收 |

- [ ] 待验收：明确每平台最低 OS、Linux libc、支持架构、外部依赖和安装方式。
- [ ] 待验收：各平台干净环境解压/安装、含空格路径、搬移、首次启动、升级及退出资源清理。
- [ ] 待验收：Desktop 原生窗口、输入、菜单、中文与关键业务流程，不能仅用 CLI 替代 GUI 验收。
- [ ] 缺失/待核对：Linux/Windows 正式 Release 附件汇总、校验与下载入口是否完整；已有 artifact 不自动算正式发布。
- [ ] 待验收：Mac 下载隔离首次打开及签名策略；现有文档记录 ad-hoc/Gatekeeper 限制，不能标为已完成正式签名公证。
- [ ] 待验收：更新仍采用旧边界口径的 Desktop 文档，使实现、平台矩阵及官网承诺一致。

## P1-02 本地与远端运行时管理

- [x] 已实现：运行包安装、多版本选择、SSH 远端初始化及升级入口，见[工作台说明](../desktop/README.md)。
- [ ] 待验收：本地运行时部署、版本识别、启停、升级与恢复。
- [ ] 待验收：空远端通过 SSH 安装、启动、管理、升级、失败回退及重新连接。
- [ ] 待验收：验证声明支持的远端 OS/架构；当前说明主路径为 Linux SSH，不能声称已支持远端 macOS/Windows。
- [ ] 待验收：本机 Desktop 平台与远端目标平台分别记录，不混为同一支持矩阵。

## P1-03 应用创建、部署、管理与接管

- [x] 已实现：本地与 SSH 远端应用模板创建、独立组件安装，见[应用安装说明](../desktop/APP-INSTALLATION.md)。
- [ ] 待验收：本地新建 → 修改 → 校验 → 部署远端 → 请求验证 → 更新 → 恢复的完整流程。
- [ ] 待验收：通过 Desktop 发起远端应用请求接管，验证实际请求流向、隔离和退出恢复。
- [ ] 缺失（当前文档明确）：独立应用更新/卸载入口；须核对最新代码并补齐，不以旧整工程部署替代单应用管理。
- [ ] 待验收：明确“管理”的操作集合及多应用共用进程时的影响范围。

## P1-04 Agent 与 MCP 操作覆盖

- [x] 已实现：本机应用上下文、文件读写、变更预览、校验、恢复、运行时启停、日志与业务请求，见[Desktop MCP](../desktop/MCP.md)和[工具注册](../desktop/devmcp/server.v)。
- [ ] 待验收：使用真实 MCP 客户端完成一次开发闭环：读取上下文 → 编写 API → 校验 → 启动 → 发请求 → 修复错误 → 恢复。
- [ ] 缺失（当前文档明确）：远端应用源码开发与编辑工具。
- [ ] 缺失/待核对：运行时部署升级、远端应用部署管理、请求接管是否都有 MCP 工具；形成 GUI ↔ MCP 操作对应表并补缺。
- [ ] 待验收：应用切换、过期 revision、鉴权失败、越界路径、私有文件、共享环境配置保护。
- [ ] 待验收：Agent 操作依然使用 GUI 的事务和恢复逻辑，不引入绕过检查的第二条路径。

## P1-05 三个官方示例

三个目录均已有实现与说明；本次发布仍须用正式候选包从零验收：

- [x] 已实现：[微信云函数兼容方案](../examples/wechat-cloud-functions/README.md)。
- [x] 已实现：[Paseo Relay](../examples/paseo-relay/README.md)。
- [x] 已实现：[Codexbot TS](../examples/codexbot-app-ts/README.md)，本次以 TS 目录作为拟定官方入口，旧 PHP 示例定位待统一。
- [ ] 待验收：每例统一提供依赖、安装、最小配置、启动、业务验证、Desktop 部署、升级与排障。
- [ ] 待验收：微信方案覆盖真实登录、双用户隔离、MySQL/PostgreSQL CRUD/事务、存储和重启持久化；本地身份替身不替代平台联调。
- [ ] 待验收：Paseo 覆盖真实客户端连接、重连、文本/二进制转发、慢连接/背压和状态清理；把 skeleton 说明更新为准确交付口径。
- [ ] 待验收：Codexbot 覆盖实例配置、消息输入、流式输出、取消、失败恢复与重启持久化。
- [ ] 待验收：移除教程中的开发机绝对路径；敏感配置仅提供占位符。
- [ ] 待验收：微信方案明确“自托管兼容层”的支持范围，不宣传为完整 CloudBase 替代。

## P1-06 官网与版本文档

- [x] 已实现：MkDocs 配置与部署流程，见[站点配置](../mkdocs.yml)和[文档部署](../.github/workflows/mkdocs.yml)。
- [ ] 缺失/待核对：正式产品首页，覆盖六项承诺及明确边界。
- [ ] 待验收：下载页按产品、OS、架构展示实际附件、版本、SHA256、安装说明。
- [ ] 待验收：托管快速开始、三示例、Desktop 运行时/应用/接管及 MCP 文档；站内链接与命令全部可用。
- [ ] 待验收：区分稳定版文档与开发中内容，提供 0.9.0 / Desktop 0.1.0 版本入口和升级说明。
- [ ] 待验收：正式域名、HTTPS、部署结果和下载链接；构建成功不等于线上已验收。

## 执行顺序和时间窗口

| 顺序 | 日期目标 | 操作 | 退出条件 |
| --- | --- | --- | --- |
| 1 | 11/2 | 版本/GC/发布门禁预检，建立证据记录 | 预检有真实日志，失败项进入 P0 |
| 2 | 11/2–3 | 冻结候选和三平台包，启动长稳 | 输入可追溯，资源阈值固定 |
| 3 | 11/3–4 | 部署、升级、接管故障恢复 | P0-03 全部通过 |
| 4 | 11/4–5 | 三平台 GUI、应用管理、MCP 补缺与闭环 | P1-01 至 P1-04 关闭 |
| 5 | 11/4–6 | 三例教程、官网、版本文档 | P1-05 / P1-06 关闭 |
| 6 | 11/6–8 | RC 回归、最终放行 | P0/P1 无未关闭项 |

可独立的文档工作可同步进行；稳定性失败修复后，重新确认受影响的长稳和功能验收。

## 正式放行

- [ ] P0、P1 全部关闭，任何延期范围均有维护者明确决定与公开说明。
- [ ] 最终候选提交、依赖、实际发行包、验收记录完全对应。
- [ ] 发布说明列出功能、兼容变化、已知限制、安装与升级恢复方法。
- [ ] 所有平台附件、校验值、官网和文档就绪。
- [ ] 最终发布核对完成后创建并推送正式标签；本清单落地不等于已发布。

## 推进记录：2026-11-02 第一轮 P0 预检

本轮基于本机 macOS arm64 的未冻结工作区执行，不代表 CI 或最终候选包通过。运行时基线 HEAD 为 b35c572ddb9401fc59411920f914c08e4ef52d70，分支 feature/desktop-workbench；完整命令、退出码和日志摘要见[本地预检记录](./release-evidence/2026-11-02/preflight.json)。

- [x] P0-01 局部：运行时声明版本 0.9.0、Desktop 声明版本 0.1.0 已核对；候选提交和安装包仍未冻结。
- [x] P0-02 局部：GC 构建门禁回归 5/5，通过（含禁止关闭 GC 和编译器静默遗漏 GC 的拒绝路径），见[原始日志](./release-evidence/2026-11-02/01-test_build_gc.txt)。
- [x] P0-02 局部：所有权静态检查通过，见[原始日志](./release-evidence/2026-11-02/02-lint_safety.txt)。
- [x] P0-01 局部：Mac 验收记录汇总回归 4/4、正式发布门禁回归 11/11、开发版发布门禁回归 11/11，通过；均为夹具测试，不是实际发布。见[验收元数据日志](./release-evidence/2026-11-02/03-test_macos_acceptance.txt)、[正式发布门禁日志](./release-evidence/2026-11-02/04-test_macos_release.txt)、[开发发布门禁日志](./release-evidence/2026-11-02/05-test_development_release.txt)。
- [x] P0-02 局部：识别并隔离不合格验收输入。根目录已有 ./vhttpd 不支持 --build-info，返回 unknown option、退出码 2，不能用作 GC 验收，见[原始日志](./release-evidence/2026-11-02/06-build-info.txt)。原文件保持不变，已另行构建并验证隔离程序，结果见下方。
- [ ] P1-06 追加缺口：给仓库首页增加发布清单入口时，链接检查发现其既有开发机绝对路径链接无法在知识库中解析；后续需核对迁移后的文档位置并修复，不将新发布清单的零死链结果扩展为整个站点通过。

下一步顺序：隔离生产构建并核验实际 GC → 冻结输入、设计长稳负载和阈值 → P0-03 故障恢复回归。长稳、三平台发行包及真实 MCP/平台联调均未核销。

### 隔离生产构建结果

- [x] P0-02 局部：make prod WITH_DB=1 VPHP_V_GC=boehm 隔离构建成功；VHTTPD_BIN 与 BUILD_STAGE_ROOT 均指向 .runtime/release-090-preflight，不覆盖根目录旧二进制。
- [x] P0-02 局部：新程序 --build-info 返回 version=0.9.0、gc=boehm、gc_enabled=true，退出码 0。二进制 SHA256 为 c23137f5fe27ec58acdfa001b340c89d1a74ddce041384295cb975ad5cebb60a。
- [x] P0-01 局部：记录 547 个暂存源码文件摘要，检查时与当前 src 一致；V 编译器为 0.5.2 d13ccdd，vjsx 为 259620f1981a3573777ec8cda72883b1866404a7，vjsx 工作区干净。

证据：[生产构建结果](./release-evidence/2026-11-02/isolated-build.json)、[构建日志](./release-evidence/2026-11-02/07-isolated-prod-build.txt)、[源码与依赖输入摘要](./release-evidence/2026-11-02/build-inputs.json)。仅验证本机生产程序可以构建且实际启用 GC，不核销发行包、Linux/Windows 或 24 小时长稳。

### 当前接续点

1. P0-01：将功能改动收敛到可冻结候选，生成完整依赖与发行包清单。
2. P0-02：基于候选包建立资源采样/阈值和长稳负载，先短跑验证采样，再执行 24 小时验收。
3. P0-03：执行部署/升级/接管恢复测试，特别检查多应用隔离与断线后的处理状态。
4. P1：按前述编号补齐承诺功能和交付，不将文档明确缺失项直接改为“待验收”。

## 推进记录：远端 Ubuntu 长稳准备

维护者授权使用 bullsoft.org 的 Ubuntu 服务器进行 24 小时压力测试及内存问题排查。以下为 SSH 实际观察汇总，见[远端压测启动记录](./release-evidence/2026-11-02/remote-soak-launch.json)；原始采样和日志仍保留在远端专用测试目录，连接恢复后取回归档。

- [x] P0-02 局部：确认 Ubuntu 24.04.5 x86_64、2 核、实际可见内存 1676 MiB、无 Swap。现有 bodytest 实例 PID 9303 保留运行，不修改其配置或业务数据。
- [x] P0-02 局部：被测已安装包实际返回 0.9.0、Boehm GC enabled；包清单源码提交为 d260cecd415a8640fb655819efd52caee32e5fc2，二进制 SHA256 为 f35c819beee5d426695603d38404548b4fc3bbc20190c3f3aab7c5afa4e8e720。这不是当前工作区最终候选版，不据此核销最终发版验收。
- [x] P0-02 局部：[独立压测脚本](../scripts/ci/remote_soak.py)已实现并完成 60 秒远端预检：1214 次 HTTP、15 轮 Paseo 文本/二进制/连接回收验证，均零错误；cgroup 无 OOM。部分请求超过 1 秒，最高约 4.96 秒，需要在长测中继续观察，不能仅凭零错误判为性能合格。
- [x] P0-02 局部：systemd/cgroup 内存上限 512 MiB、CPU 上限 1 核、TasksMax=128；整机可用内存连续三次低于 256 MiB 则停止测试。只监听独立回环端口，不向现有业务发压力请求。
- [x] P0-02 局部：记录 RSS/匿名内存、CPU ticks、线程、FD、cgroup 内存/OOM、现有实例资源和响应延迟；最终脚本增加日志轮转与每增长 64 MiB 的映射/匿名内存快照。增长触发诊断不自动判定泄漏。
- [x] P0-02 局部：最终脚本 30 秒短跑完成，551 次 HTTP、7 轮 Paseo 验证均零错误，systemd Result=success；见[最终短跑结果](./release-evidence/2026-11-02/remote-final-smoke-result.json)。
- [x] P0-02 局部：SSH 中断已恢复。维护者反馈曾断网；重连后确认现有实例仍在运行，并已启动长测，见[长测运行证据](./release-evidence/2026-11-02/remote-soak-running.json)。
- [ ] P0-02 待验收：计划持续负载 86400 秒，另加前后各 600 秒采样，总计 87600 秒。范围仅含独立 HTTP/JSON 与 Paseo WebSocket，不包含数据库、真实微信/Codex Provider 或 Desktop GUI。
- [ ] P0-02 待验收：当前发行包没有 DWARF 调试段；资源趋势和快照可用于缩小问题范围，精确到分配点仍可能需要相同源码/依赖的带符号构建和可复现负载。

长测由 vhttpd-soak-24h-20261102.service 托管，SSH 断开后继续运行。测试目录为 /root/vhttpd-release-tests/20261102-soak；结束后取回 state/result、samples、诊断与 systemd 退出/OOM 状态。不得因任务存活或 GC 已启用而直接判定无泄漏。

### 24 小时压力任务启动记录（首轮已因 OOM 提前失败）

- [x] 启动并验证 systemd ActiveState=active、SubState=running；测试实例 PID 29230，原 bodytest PID 9303 及进程启动标识未改变。
- [x] 核对短跑与正式长测四个脚本/资产的 SHA256 一致，防止未经短跑验证的脚本进入长测。
- [x] 确认 cgroup MemoryMax=536870912、CPUQuota=1 核、TasksMax=128 生效，初始整机可用内存约 803 MiB。
- [ ] 等待完整持续负载及冷却阶段完成，再审核资源收敛、延迟、错误与 OOM 记录；当前仍未核销 P0-02 长稳验收。

北京时间 2026-11-02 16:11:18 启动，先进行约 10 分钟基线采样，再进行约 24 小时负载和 10 分钟冷却；预计 2026-11-03 16:31 左右结束。HTTP 目标上限 40 RPS、并发 4，每轮新建连接；另每约 2 秒完成一轮 Paseo 连接与文本/二进制验证。资源上限可能限制实际速率，必须按实际计数与延迟评估，不把目标速率当作实测吞吐。

证据：[启动及资源限制](./release-evidence/2026-11-02/remote-soak-running.json)、[初始采样](./release-evidence/2026-11-02/remote-soak-initial-samples.ndjson)、[首轮预检](./release-evidence/2026-11-02/remote-preflight-result.json)、[最终脚本短跑](./release-evidence/2026-11-02/remote-final-smoke-result.json)。压力请求只发往本次新增的回环监听器，不修改现有应用配置、数据库或外部服务。

### 2026-11-02 17:22 检查：首轮长测失败，阻断发布

- [ ] **P0-02 未通过**：任务于北京时间 16:30:45 发生 cgroup OOM，16:30:53 结束；总运行约 19 分 30 秒，其中前 10 分钟为基线，实际压力约 9 分 30 秒，未完成 24 小时。见[最终结果](./release-evidence/2026-11-02/remote-soak-failure/result.json)和[systemd 状态](./release-evidence/2026-11-02/remote-soak-failure/systemd-status.txt)。
- [x] 已确认终止对象：内核记录 CONSTRAINT_MEMCG，杀死本次测试 vhttpd PID 29230。触发的是测试组 512 MiB 上限，不是整机 OOM；原 bodytest PID 9303 仍存活。见[内核 OOM 证据](./release-evidence/2026-11-02/remote-soak-failure/kernel-oom.txt)。
- [x] 已归档 117 次采样：负载开始 RSS 66600 KiB，最后采样 358544 KiB；最后采样历史峰值 534028 KiB，内核终止记录匿名 RSS 508956 KiB、文件 RSS 25216 KiB。线程维持约 21–22、FD 约 22–24，增长主要表现为匿名内存，不是已证实的句柄或线程数量增长。见[完整采样](./release-evidence/2026-11-02/remote-soak-failure/samples.ndjson)。
- [x] 负载计数归档：HTTP 成功 18500 次、Paseo 成功 223 轮；终止结果累计 HTTP 错误 4、Paseo 错误 1。终止前最后采样错误计数仍为零，不能把最终连接中断错误直接认定为独立业务错误。见[最终结果](./release-evidence/2026-11-02/remote-soak-failure/result.json)和[日志尾部](./release-evidence/2026-11-02/remote-soak-failure/runtime-tail.txt)。
- [ ] 根因尚未确定：目前证明此负载和资源上限下出现不可接受的内存增长及 OOM；仍须区分持续泄漏、GC/分配峰值、缓存保留及组合负载影响。不得提高上限后直接核销失败。
- [x] 修正诊断脚本的提前失败盲区：原脚本等待负载开始后再过 10 分钟才设置增长基线，首轮在此前 OOM，未产生 growth 快照。现改为第一个负载采样建立基线；仅为诊断改进，不是运行时内存修复，尚未部署重跑。
- [ ] 后续顺序：保持失败现场 → 分别运行 HTTP-only 与 Paseo-only 有界复现 → 对增长路径使用匹配源码与依赖的诊断构建定位 → 修复后回归 → 重新开始完整 24 小时。

原始 [systemd 日志](./release-evidence/2026-11-02/remote-soak-failure/systemd-journal.txt)已保存。此前预计 11/3 16:31 的结束时间已失效；当前没有正在继续的 24 小时任务。

### 分离负载定位与修复（2026-11-02，远端修复包验证待完成）

先前“HTTP/JS 路径增长”的结论需要细分。测试脚本把 state.json 等报告写在默认源码签名目录，源码签名包含 JSON；限制监视范围后，同一运行包、同一 HTTP 负载的增长消失。签名规则见[源码签名实现](../src/executor/vjsx_host_signature.v)。这修正的是测试工况，不能用来宣称运行时热重载的所有生命周期问题已经解决。

| 对照（修复前运行包） | 成功请求/轮次 | 初始 RSS → 最后 RSS | 结果 |
| --- | --- | --- | --- |
| HTTP，报告仍在监视范围 | 5549 次 | 54.7 → 201.1 MiB | 存在监视干扰 |
| 最小 JS，报告仍在监视范围 | 4119 次 | 45.3 → 177.8 MiB | 同样存在监视干扰 |
| 原生固定响应，无 JS 引擎 | 4788 次 | 45.5 → 55.5 MiB | 基本稳定 |
| HTTP，仅监视应用源码 | 6392 次 | 54.0 → 52.0 MiB | 4 分钟对照稳定 |
| Paseo，仅监视应用源码 | 78 轮 | 59.7 → 97.7 MiB | 排除监视干扰后仍增长 |

原始结果与采样见[六组对照汇总](./release-evidence/2026-11-02/split-load/summary.json)。这些短跑不替代 24 小时验收。

定位到 WebSocket 帧的构造会先创建原生 runtime（包含每事件的新原生回调），随后 JS frame 工厂又创建自己的 runtime；前者未被帧使用，却留下被原生回调持有的事件上下文/元数据。现在优先从 JS frame 取得它实际持有的 runtime，仅在旧兼容路径回退时构造原生 runtime。见[修复位置](../src/executor/inproc_vjsx_websocket_callback_runtime.v)。

- [x] 已实现：修正[压测脚本](../scripts/ci/remote_soak.py)，支持 HTTP/Paseo 分离、原生/最小 JS 对照，默认限制源码监视范围，不把报告更新混入请求长稳负载；保留 churn 模式供单独热重载诊断。
- [x] 已实现：移除正常 WebSocket 帧路径中未使用的原生 runtime/回调构造，保持兼容回退路径。
- [x] 本机修复前后回归：同一 1024 帧测试，旧实现 V 堆保留从 401408 字节增到 5394432 字节，超过 1 MiB 增长预算而失败；新实现两个测试均通过，JS 对象数量也有上限检查。见[回归测试](../src/executor/websocket_payload_memory_test.v)及[本机观测记录](./release-evidence/2026-11-02/split-load/host-regression.json)。
- [x] 最小复现对照：脱离 HTTP 服务及热重载，6 批各 1000 次纯 JS facade 调用后，V 堆保留 299008 字节、QuickJS 保留 326409 字节、对象数 216，批次间不增长。不能把之前混合负载的 RSS 曲线直接解释成 JSON 序列化泄漏。
- [x] 已构建：与服务器匹配的 d260cecd 基础源码加 WebSocket 补丁，使用固定工具链/SDK 和标准生产参数构建 Linux amd64 修复包；构建容器退出码 0，实际 Boehm GC enabled，27 个运行库已打包。见[构建日志](./release-evidence/2026-11-02/fixed-soak/build.txt)、[构建信息](./release-evidence/2026-11-02/fixed-soak/build-info.json)、[补丁溯源](./release-evidence/2026-11-02/fixed-soak/provenance.json)和[文件摘要](./release-evidence/2026-11-02/fixed-soak/upload-manifest.json)。验证包不是公开发行附件，不替换 bodytest。
- [ ] 待验收：修复包重复 Paseo/HTTP/混合负载，核对错误、资源趋势及原实例存活。
- [ ] 待验收：只有上述修复验证通过后，重新从零开始完整 24 小时压力；首轮失败的时长不累计。

当前仍未核销 P0-02。源码监视导致的重复热重载应作为独立生命周期工况保留，不混入日常请求负载的内存结论。

### 修复包验证门槛与执行状态（2026-11-02）

- [x] 已实现：[分阶段验证脚本](../scripts/ci/remote_soak_sequence.py)按 Paseo 240 秒、HTTP 240 秒、混合 900 秒依次运行；冷却后 RSS 相对负载初期增长不超过 32 MiB、负载期 RSS 不超过 256 MiB、FD 增长不超过 8，要求实际产生流量且零请求错误。任一条件失败则保存结果并停止，不启动长测。
- [x] 已验证：[阶段门槛测试](../scripts/ci/test_remote_soak_sequence.py)的 5 项测试通过，覆盖正常收敛、旧 Paseo 增长、错误/空流量、采样不足及 RSS/FD 超限；Python 编译检查通过。
- [x] Linux amd64 生产修复包于 2026-11-02 18:31:52（北京时间）完成构建，容器退出码 0。19:23 后 Docker/SSH 执行恢复，远端 35 个文件摘要、Boehm GC、动态库完整性及原 bodytest PID/启动标识校验通过，见[远端包校验](./release-evidence/2026-11-02/fixed-soak/remote-package-verification.json)。独立服务 vhttpd-soak-fixed-validation-20261102 已启动分阶段验证。
- [ ] 远端修复包分阶段验证尚未完成，新的 24 小时任务尚未启动；P0-02 保持阻断。通过全部阶段后才创建全新长测服务，总时长 87600 秒，包含完整 24 小时负载及前后采样。

当前状态与接续步骤见[验证状态记录](./release-evidence/2026-11-02/split-load/verification-state.json)。源代码修复与本机回归已完成，远端修复后稳定性仍待实测，不把脚本已实现当作验收通过。

### 修复包首轮验证：继续补齐路由查询路径

- [x] 首个修复包远端 HTTP：6392 次请求，零错误，负载初期 RSS 中位 50252 KiB、冷却后 50036 KiB，基本稳定。
- [x] 首个修复包远端 Paseo：78 轮、零错误；负载初期 RSS 中位 59124 KiB、冷却后 89740 KiB，仍保留 30616 KiB 增长。虽低于短跑阶段 32 MiB 门槛，但接近上限，不能据此核销长稳。
- [x] 主动停止 vhttpd-soak-fixed-validation-20261102，保留[原始阶段结果](./release-evidence/2026-11-02/fixed-soak/first-validation/sequence.json)与[停止原因](./release-evidence/2026-11-02/fixed-soak/first-validation/intervention.json)；24 小时服务尚未创建，原 bodytest PID 9303 继续运行。
- [ ] 补齐 actor/affinity 查询路径：该路径仍为每次查询构造原生 runtime 回调。已改为复用 JS 帧的 runtime，正在进行 1024 轮真实路由查询的修复前后内存及返回值回归；测试通过后重建 Linux 包并重新执行完整阶段验证。

