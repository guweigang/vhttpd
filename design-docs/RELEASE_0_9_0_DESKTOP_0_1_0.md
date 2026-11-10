---
title: vhttpd 0.9.0 与 Desktop 0.1.0 联合发布清单
description: 2026-11-02 至 11-10 发布范围、实现状态、验收证据、阻断项及执行顺序。
tags: [ release, vhttpd, desktop, acceptance ]
status: in-progress
updated: 2026-11-10
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

### 当前收尾清单（2026-11-10，优先于下方历史进度）

本轮按维护者授权推进：冻结已有候选，先验证真实应用兼容，再通过升级流程替换 bodytest，恢复连续观察，最后启动独立 24 小时压力与冷却。不再以追加零散优化替代发布验收，也不把“降低分配”写成“内存泄漏已解决”。下方历史“不切换/不启动”仅描述当时轮次，不限制本次授权。

- [x] 已实现并验证：上游 GC 源码/策略恢复，GC 编译单元使用已对照的 GCC O2；响应体交接与 per-worker writer Context 优化通过定向 macOS/Linux 回归。vjsx 未因本轮修改。见[源码及回归](./release-evidence/2026-11-10/context-lifetime/finding.json)。
- [x] 已实现并验证：Linux amd64/Boehm 候选二进制 SHA256 为 dca8844f0725b08e22d3a6ce5adf63ed51c9aaaceb5ce3360aaaba1dc9c61d9d；整包短测每 HTTP 请求少分配约 7968 字节。冷却匿名内存旧/新约 27.7/28.7 MiB，尚未证实驻留改善。见[整包证据](./release-evidence/2026-11-10/context-pool-package/finding.json)。
- [x] 已验收 A：核对相同 SHA、实际 Boehm 与构建来源；bodytest 副本在独立网络/文件系统内通过 applicationInfo 根目录/入口断言与原样应用预热，健康、业务路由及配置 revision 一致，未访问真实数据库/云服务。初次夹具缺少新增 MCP include，未计为候选失败；补齐后两项通过。见[API 断言](./release-evidence/2026-11-10/release-closeout/validation-application-info.json)、[原样应用](./release-evidence/2026-11-10/release-closeout/validation-original-app.json)。
- [x] 已验收 B：14:45（北京时间）升级助手完成 bodytest 切换，新 PID 1974907、start_ticks 71602815，实际二进制为上述 dca8844f 候选；安装归档 SHA256 为 c72f262d578b0567d74265815f74628b88d912c796e0533bdccc82fc3b60ed93。三个健康检查 200、业务路由通过，四个监听端口和配置 revision 保持；原包与私有回滚操作记录保留，未归档凭据。见[切换结果](./release-evidence/2026-11-10/release-closeout/bodytest-switch.json)。
- [x] 已实现并启动 C：新连续监测 vhttpd-bodytest-memory-observer-20261110.service 已绑定新 PID/启动标识及准确二进制 SHA；先验证对应符号布局再读取 RSS、匿名内存、Boehm 堆/空闲和回收轮次。只读采样不发送健康请求、不注入 GC。启动快照不代表长期改善；业务观察与独立负载分开统计。见[监测身份](./release-evidence/2026-11-10/release-closeout/business-identity.json)、[计数预检](./release-evidence/2026-11-10/release-closeout/business-counter-preflight.json)、[监测脚本](./release-evidence/2026-11-10/release-closeout/observe.py)。
- [x] 已启动 D（尚未完成验收）：独立控制器先完成短流程，HTTP 1213、Paseo 15，零错误/OOM，自然进入冷却并退出。主机六次 MemAvailable 为约 980.5–994.2 MiB，均高于 640 MiB 启动门槛；随后在全新目录/单元启动同一 SHA 的完整长测。单元 vhttpd-soak-dca8844f-full24-20261110.service、运行时 PID 1979291/start_ticks 71633275，实际 Boehm 与 SHA 已核验。10 分钟基线 + 完整 24 小时 HTTP/Paseo 加压 + 10 分钟自然冷却，预计 11 月 10 日 15:00 开始加压、11 月 11 日 15:10 冷却结束。实际单元限制核对为 256 MiB、30% CPU、无 swap、独立网络；保留 512 MiB 主机保护，只终止独立任务。使用合成四运行时扫描拓扑，不能冒充真实业务或数据库负载。见[短流程结果](./release-evidence/2026-11-10/release-closeout/harness-smoke/result.json)、[长测元数据及脚本摘要](./release-evidence/2026-11-10/release-closeout/full24/metadata.json)、[实际单元属性](./release-evidence/2026-11-10/release-closeout/full24/active-unit-properties.txt)。
- [ ] 待验收 E：自然结束后归档完整曲线、错误/OOM、FD/线程、GC 堆/空闲、加压是否误触发空闲回收及冷却残留。既有 Linux HTTP/Paseo 门槛保持 RSS 残留不超过 16 MiB、压力 RSS 不超过 256 MiB、FD 增量不超过 8；达到数值门槛也不能掩盖未解释的持续增长。
- [ ] 缺失/待补齐：最终发行包在数据库、Provider、取消/超时、连接断开和应用启停/重载上的生命周期证据，以及其他目标平台的对应验证。Linux 单轮长测通过不能自动关闭这些项目。

**关闭条件：** A–E 及原 P0-02 全部适用验收项有最终候选证据后才能关闭；没有要求所有空闲页立即归还操作系统，但必须区分可复用高水位与真实泄漏。若发现持续增长，记录具体负载、分配/保留路径和复现方式后修复重验。当前状态仍为阻断，不能预先勾选“完整 24 小时通过”。

**14:53 收尾核验：** bodytest PID 1974907 与独立长测 PID 1979291 的实际二进制 SHA 均匹配；业务 ready、配置 revision 一致、三个健康检查 200，新监测和长测单元均 active。业务当时匿名内存约 29.8 MiB、映射 GC 堆约 13.9 MiB，主机可用约 933 MiB；这是切换后初期快照，不与旧进程长期高水位直接比较，也不代表长测通过。长测处于基线，尚未产生加压请求。见[启动后核验](./release-evidence/2026-11-10/release-closeout/post-launch-check.json)及[归档文件摘要](./release-evidence/2026-11-10/release-closeout/artifact-sha256.json)。

### 历史进度与基线

**bodytest 切换与 fixed7 新长测（11 月 4 日 14:40，北京时间）**。按维护者指令主动结束此前 fixed7 轮次，约 3 小时 17 分加压，HTTP 471731 次、Paseo 5752 轮，零错误、零 OOM。首末 10 分钟匿名内存中位数 53.01 → 51.02 MiB，无冷却样本，不能作为完整 24 小时验收。bodytest 已通过工作台切换至带 GC 修复和 applicationInfo 的候选，实际 PID 2287326，Admin、健康及应用路由验证通过。原定次日切换的定时任务已删除。新一轮独立 fixed7 使用原压测二进制，PID 2287646，10 分钟基线、24 小时加压、10 分钟冷却，预计 11 月 5 日 15:01 完成。保留原资源限制和主机余量保护，压测采样与业务 PID 解耦。[旧轮汇总](./release-evidence/2026-11-04/fixed7-post-bodytest-switch/previous-summary.json) · [业务切换验证](./release-evidence/2026-11-04/fixed7-post-bodytest-switch/bodytest-switch.json) · [新长测](./release-evidence/2026-11-04/fixed7-post-bodytest-switch/metadata.json)

**bodytest 兼容候选通过隔离验证（11 月 4 日 14:02，北京时间）**。在 fixed7 冻结源码上仅加入 `applicationInfo()` 的宿主 API 注册与实现，沿用已核对的 GCC/Boehm 工具链和 vjsx。候选二进制 SHA256 为 `789c29cffdee25c1950b8505710a1575c36e5490fbe98679ec8e0c5afa4aba18`。在独立网络及文件系统、虚拟凭据和隔离数据库端点下，先断言源码入口和根目录，再启动未插入探针的应用副本。两次 Admin 均就绪，HTTP 健康与业务应用路由均返回预期结果。业务 PID 2134650 与 fixed7 压测 PID 2134953 保持运行。因长测绑定并观察业务 PID，安排 11 月 5 日 11:40 复核自然完成状态后按工作台升级流程切换，预热失败自动回滚。业务切换与完整验收仍待结果。[构建来源](./release-evidence/2026-11-04/bodytest-fixed7-candidate/provenance.json) · [API 断言](./release-evidence/2026-11-04/bodytest-fixed7-candidate/candidate.json) · [原样应用验证](./release-evidence/2026-11-04/bodytest-fixed7-candidate/candidate-original.json)

**业务兼容性与 fixed7 重跑（11 月 4 日 11:12，北京时间）**。归档已停止的 Desktop E2E 应用，保留有历史部署引用的运行时包。fixed6 通过 bodytest 配置预检，实际启动时业务模块调用 `vhttpdHost.applicationInfo()` 失败，工作台完成自动回滚。原包重新启动后 Admin 就绪，三个本地监听端口的健康检查均返回 200。fixed6 业务替换仍受宿主 API 兼容性阻断。主机恢复约 998–1002 MiB 可用内存后，独立启动已验证 SHA 的 fixed7 重跑，PID 2134953，10 分钟基线、24 小时加压、10 分钟冷却，沿用 256 MiB、30% CPU 和 512 MiB 主机余量保护，预计 11 月 5 日 11:33 完成。[业务回滚](./release-evidence/2026-11-04/fixed7-retry/bodytest-rollback.json) · [新长测元数据](./release-evidence/2026-11-04/fixed7-retry/metadata.json)

**fixed6 完整长测结果（11 月 4 日 10:59，北京时间）**。自然完成 24 小时加压及 10 分钟冷却，HTTP 3,449,515 次，Paseo 42,067 轮，零错误、零 OOM。按各阶段末一分钟中位数，匿名内存从空闲基线 32.5 MiB 升到加压末 56.3 MiB，冷却末 56.0 MiB，回落 0.28 MiB，仍比空闲基线高 23.6 MiB。既有门槛按首三个加压样本和末三个冷却样本计算，RSS 残留 +4.56 MiB（限 16 MiB），加压峰值 76.6 MiB（限 256 MiB），FD 增量 5（限 8），本轮通过既有门槛。匿名内存残留继续作为诊断发现跟踪。fixed7 上一轮触发主机余量保护，尚待完整验收。fixed6 完成后主机可用内存约 470 MiB，低于 fixed7 启动门槛 640 MiB。P0-02 保持待验收。[结果](./release-evidence/2026-11-04/fixed6-full24/result.json)

**双长测检查（2026-11-03 17:55，北京时间）**：fixed7 已运行约 1 小时 45 分，其中加压约 1 小时 35 分（24 小时压力阶段约 6.6%），尚未进入冷却。加压最初/最近 10 分钟 RSS 中位数为 77786/77476 KiB，匿名内存为 50382/50072 KiB，均下降 310 KiB；连续 15 分钟压力窗口 RSS 中位数 77808/77812/77792/77658/77548/77514 KiB（末尾不足一窗口 77464 KiB），目前未观察到持续增长。累计 HTTP 227475 次、Paseo 2774 轮，错误/OOM 为 0。原 fixed6 已运行约 7 小时 16 分，其中加压约 7 小时 6 分，HTTP 1020923 次、Paseo 12449 轮，错误/OOM 为 0；其最初/最近 10 分钟匿名内存中位数从 37608 增至 53560 KiB（+15952 KiB），仍有缓慢增长。旧包同期 RSS 从 64852 降至 63748 KiB，RSS 与匿名内存差额显著缩小，因此不能把总 RSS 下降当作匿名内存增长已消失。两轮 FD/线程中位数均为 22，服务 active/running、NRestarts=0；新运行时 PID 1037583、旧运行时 PID 697847 与业务 PID 9303 的启动身份均保持，未停止或重启。新任务 cgroup 内存约 158 MiB，其中匿名约 69 MiB、文件页约 83 MiB；这与进程 RSS/匿名内存口径不同，不能直接视为堆泄漏。主机仍有约 711 MiB 可用内存，高于 512 MiB 保护线。新包预计 11 月 4 日 16:31 左右完成冷却；本次仅为中途观察，P0-02 不关闭。见[双长测窗口分析与原始计数](./release-evidence/2026-11-03/fixed7-full24/progress-20261103-1755.json)、[新包样本](./release-evidence/2026-11-03/fixed7-full24/full24/samples.ndjson)及[服务身份检查](./release-evidence/2026-11-03/fixed7-full24/checkpoint.json)。

**fixed7 独立完整长测启动（2026-11-03 16:11，北京时间）**：按维护者要求另起 `vhttpd-soak-fixed7-independent-24h-20261103.service`，运行时 PID 1037583/start_ticks 11632512；独立复制的新包 SHA256 为 `aaa1475c97b9bd003986c8d4f81ae10f7315ec3c544580085139f990151bf4a6`，实际 0.9.0、Boehm GC 启用。计划为 600 秒基线 + 86400 秒混合 HTTP/Paseo 加压 + 600 秒冷却，总计 87600 秒；基线实际约 11 月 3 日 16:10:37 开始，预计 16:20:37 加压、11 月 4 日 16:20:37 冷却、16:30:37 完成。沿用独立对照的 40 HTTP RPS/4 并发、Paseo 每 2 秒一轮、独立签名范围，256 MiB 内存上限、30% CPU、无 swap，降低优先级；连续三次采样主机可用内存低于 512 MiB 时仅终止新任务。每 10 秒采样 RSS、匿名内存、FD、线程、主机余量、cgroup/OOM 和错误计数，每 30 秒更新按小时趋势及首末 60 秒窗口，完成后自动生成冷却回收对比与原有门禁结论。未注入 GC 或附加跟踪器。本次已核验新任务 active/running、基线采样正常且无 OOM；原长测 PID 697847/start_ticks 9646788 与业务 PID 9303/start_ticks 601054 未变，原长测 active/running、NRestarts=0，不操作原长测。完整结果尚未产生，P0-02 保持待验收。见[新长测元数据](./release-evidence/2026-11-03/fixed7-full24/metadata.json)、[启动状态](./release-evidence/2026-11-03/fixed7-full24/full24/state.json)、[内存观察汇总](./release-evidence/2026-11-03/fixed7-full24/full24/memory-analysis.json)、[观察控制器](./release-evidence/2026-11-03/fixed7-full24/full24/run.py)及[双长测服务核验](./release-evidence/2026-11-03/fixed7-full24/checkpoint.json)。仓库证据为检查时快照；服务持续写入远端同名文件，后续检查同步。

**独立对照完成（2026-11-03 16:05，北京时间）**：fixed6/fixed7 各完成 10 分钟基线、20 分钟相同混合压力与 2 分钟冷却，控制器和两组任务正常退出，未替换原长测。以各阶段首/末 60 秒的六个样本中位数比较：旧包加压 RSS 从 73536 KiB 增至 77616 KiB（+4080 KiB），冷却末为 77200 KiB，较加压初期仍高 3664 KiB、较空闲基线高 5744 KiB；新包加压从 80050 KiB 到 80004 KiB（-46 KiB），冷却末为 75448 KiB，较加压初期低 4602 KiB、较空闲基线低 4044 KiB。新包四个连续五分钟压力窗口的 RSS 中位数为 80054/80014/80016/80002 KiB，匿名内存也保持平稳，本轮未观察到旧包的持续增长趋势。旧/新包分别完成 HTTP 47839/47844 次、Paseo 均 584 轮，错误与 OOM 均为 0，冷却 FD 均为 22。既有门禁按前三个加压样本与末三个冷却样本计算，两组均通过 16 MiB 残留预算；通过该宽松门禁本身不能证明无泄漏。此轮结果支持 GC 编译修复有效，仍需新包完整 24 小时与其他平台验收，P0-02 不关闭。原长测 PID 697847/start_ticks 9646788、业务 PID 9303/start_ticks 601054 核验未变，长测 NRestarts=0；原长测已运行约 5 小时 26 分，HTTP 756228 次、Paseo 9221 轮，错误为 0。见[逐阶段内存分析](./release-evidence/2026-11-03/fixed7-comparison/memory-analysis.json)、[对照汇总](./release-evidence/2026-11-03/fixed7-comparison/comparison.json)、[旧包样本](./release-evidence/2026-11-03/fixed7-comparison/fixed6/samples.ndjson)、[新包样本](./release-evidence/2026-11-03/fixed7-comparison/fixed7/samples.ndjson)及[原长测身份检查](./release-evidence/2026-11-03/fixed7-comparison/checkpoint.json)。

**新包独立对照（2026-11-03 15:30，北京时间）**：fixed7 已用修复后的工具链完成构建，实际 `--build-info` 为 0.9.0、Boehm GC 启用，二进制 SHA256 为 `aaa1475c97b9bd003986c8d4f81ae10f7315ec3c544580085139f990151bf4a6`。此前仍处于构建阶段，并无新包压力结果。现已启动两个全新实例：fixed6/PID 981231 与 fixed7/PID 982002，使用相同冻结运行时源码、SDK、测试资产和混合负载；每个实例 256 MiB、30% CPU，错开一分钟启动，10 分钟基线、20 分钟压力、2 分钟冷却，预计约 16:03 完成。目前仅进入基线采样，不能判定修复后是否仍增长。保护器只会停止独立对照实例；原长测 PID 697847/start_ticks 9646788、业务 PID 9303/start_ticks 601054 均核验未变，长测重启次数为 0。见[构建记录](./release-evidence/2026-11-03/fixed7-comparison/build.txt)、[构建来源](./release-evidence/2026-11-03/fixed7-comparison/provenance.json)、[对照状态](./release-evidence/2026-11-03/fixed7-comparison/comparison.json)及[身份检查](./release-evidence/2026-11-03/fixed7-comparison/checkpoint.json)。本记录不是通过结论，P0-02 保持待验收。

**当前进展（2026-11-03 14:53，北京时间）**：延长对照已完成，HTTP 47786 次、Paseo 582 轮零错误，冷却 RSS 从 72560 KiB 降至 66792 KiB。剩余增长已缩小到随 V 打包的 Boehm GC 在 GCC `-O3`、并发 GC 与短线程创建/退出组合下的不可回收小对象块滞留；精确生产 GC 对象和最小程序可复现。已按维护者授权在 vlang GC 源码中为优化的 GCC 构建固定该编译单元为 `-O2`，生成的 V 代码及其他 C 辅助文件保持原优化；Linux 生产负例、修复后冷/暖缓存、shared 与 4096 次真实握手，以及 macOS Clang shared 回归已核对。vjsx 未改。当前远端长测仍为原第六包/PID 697847，未停止、暂停或重启，业务 PID 9303 保持；本次修复未部署到该实例。新候选运行时及完整 24 小时、其他平台与完整工具链放行仍待验收，P0-02 不关闭。见[延长对照结果](./release-evidence/2026-11-03/remaining-growth/20261103-fixed6-gc-extended/mixed/result.json)、[优化路径与修复证据](./release-evidence/2026-11-03/remaining-growth/gc-optimization/finding.json)和[服务身份核验](./release-evidence/2026-11-03/remaining-growth/20261103-fixed6-gc-extended/final-process-verification.json)。

- [x] 已实现：GC 构建门禁及实际二进制检查，见 [GC 构建回归](../scripts/ci/test_build_gc.py)和[实际 GC 检查](../scripts/ci/verify_gc_runtime.py)。
- [ ] 待验收：每份发行包的 --build-info 证明启用 Boehm GC；启用 GC 不能替代泄漏检查。
- [ ] 缺失（尚未找到发布级证据）：为最终候选包建立至少 24 小时稳定性记录，覆盖 HTTP、WebSocket/Relay、数据库、Provider、取消与超时。
- [x] 已实现（Linux HTTP/Paseo 范围）：[隔离长测脚本](../scripts/ci/remote_soak.py)和[阶段门禁](../scripts/ci/remote_soak_sequence.py)固定负载、预热/采样/冷却时长及资源预算；16 MiB 冷却增长、256 MiB 压力 RSS、FD 增量 8 的门槛在第五包运行前已固定，超标不启动长测。
- [ ] 待验收：为数据库、Provider、取消/超时及其他平台补齐对应负载、资源预算和最终候选包证据。
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

### 路由查询回归已通过，第二个修复包构建中

- [x] actor/affinity 查询复用 JS 帧持有的 runtime，[修复位置](../src/executor/inproc_vjsx_websocket_lane_query_runtime.v)。同一 1024 轮查询对照，旧实现 GC 后 V 堆保留从 950272 字节增长至 11362304 字节而失败；新实现 3 个测试全部通过，覆盖帧 runtime 身份、事件构造及真实 actor/affinity 查询的内存和路由返回值。见[旧实现原始测试结果](./release-evidence/2026-11-02/fixed-soak/query-before-test.txt)、[修复后原始测试结果](./release-evidence/2026-11-02/fixed-soak/query-after-test.txt)及[回归摘要](./release-evidence/2026-11-02/fixed-soak/query-regression.json)。
- [x] 将下一轮阶段验证的冷却后 RSS 增长预算收紧为 **16 MiB**，保留负载峰值 256 MiB 和 FD 增长 8 的限制；加入首个补丁仍增长约 30 MiB 的拒绝用例，6 项门槛测试通过。此前首个包的原始记录仍保留当时 32 MiB 门槛。
- [x] 第二个 Linux amd64 生产修复包构建成功，实际 Boehm GC enabled、27 个运行库已打包，二进制 SHA256 为 de8d8ea1a3aa2fd82b81124ef39f1947ec91525e8cc7553a1674b39abe083c7e；[构建日志](./release-evidence/2026-11-02/fixed-soak/build-fixed2.txt)、[源码补丁摘要](./release-evidence/2026-11-02/fixed-soak/fixed2-provenance.json)、[输入对照](./release-evidence/2026-11-02/fixed-soak/fixed2-snapshot-check.json)。远端[35 个文件及运行依赖校验](./release-evidence/2026-11-02/fixed-soak/fixed2-remote-verification.json)通过，已在 /root/vhttpd-release-tests/20261102-fixed2 启动新一轮阶段验证。

### 第二个修复包：短跑 RSS 门槛未过，继续分配保留诊断

- [ ] 第二个包的 Paseo 78 轮零错误，但冷却后 RSS 从 49068 KiB 增至 79332 KiB，未通过 16 MiB 门槛；阶段脚本正确停止，24 小时服务未启动。见[原始判定](./release-evidence/2026-11-02/fixed-soak/second-validation/20261102-fixed2/sequence.json)。
- [x] 诊断基线：Boehm 堆约 9.6 MiB、空闲约 6.4 MiB；malloc_stats 显示分配器 arena 共约 98 MiB，其中在用约 4.7 MiB，说明 RSS 包含明显的分配器保留，不能将全部增长等同于存活对象泄漏。
- [x] 一次 GDB 函数注入被 Boehm 线程信号打断，诊断进程随后栈错误退出；该次诊断有调试干扰，不用于稳定性验收，也不能归因为自然业务崩溃。原 bodytest PID 9303 继续运行。见[诊断退出结果](./release-evidence/2026-11-02/fixed-soak/second-validation/20261102-fixed2-paseo-diagnosis/result.json)和[调试器输出](./release-evidence/2026-11-02/fixed-soak/second-validation/20261102-fixed2-paseo-diagnosis/load-js-usage-gdb.txt)。
- [ ] 已重开无函数注入的独立 15 分钟 Paseo 观察，目录 /root/vhttpd-release-tests/20261102-fixed2-paseo-observe；继续区分预热/分配器保留和持续增长，再决定后续修复或长测放行。

### 剩余增长定位：hub/kernel 上下文的原生闭包

第二个修复包的[15 分钟观察](./release-evidence/2026-11-02/fixed-soak/second-long-observe/result.json)完成 293 轮 Paseo、零错误，但冷却后 RSS 仍为 179980 KiB。被动统计在 69 轮时显示 QuickJS 分配约 1.8 MiB，Boehm 堆约 33.9 MiB、空闲约 3.7 MiB；到 156 轮，GC 已继续运行，Boehm 堆约 59.2 MiB、空闲约 10.1 MiB。见[中途堆统计](./release-evidence/2026-11-02/fixed-soak/second-long-observe/passive-heaps-middle.txt)、[GC 计数及原生函数创建观察](./release-evidence/2026-11-02/fixed-soak/second-long-observe/native-cfunction-hit.txt)。这不能仅以 QuickJS 存活对象或初始预热解释。

- [ ] 已实现、待回归：将[hub/kernel 上下文](../src/websocket_runtime.v)从每次连接/命令新建捕获闭包，改为普通 GC 对象接口持有；[连接派发对象](../src/ws/types.v)同样持有原始 kernel 对象，避免按连接产生新的原生函数 trampoline。显式函数字段仍优先，保留已有注入/覆盖行为。
- [ ] 待验收：[512 次上下文构造与命令派发内存回归](../src/websocket_context_memory_test.v)，以及连接关闭、广播、日志与 multi-RPC 代际隔离测试；第三个 Linux 包同时构建中，见[补丁摘要](./release-evidence/2026-11-02/fixed-soak/fixed3-provenance.json)。
- [ ] 待验收：第三个包重新执行阶段验证，全部通过才启动全新 24 小时任务。此前任何短跑、失败及调试运行均不累计到长测时长。

### hub/kernel 对象接口修复：本机回归通过

- [x] 修复前后同一 512 次上下文构造/命令派发内存回归：旧实现 GC 后保留从 548864 字节增到 4255744 字节，超过 1 MiB 预算而失败；新实现通过。见[旧实现原始输出](./release-evidence/2026-11-02/fixed-soak/context-before-final-test.txt)、[修复后组合套件原始输出](./release-evidence/2026-11-02/fixed-soak/context-suite-final-test.txt)及[回归摘要](./release-evidence/2026-11-02/fixed-soak/context-regression.json)。
- [x] 同一组合套件覆盖上下文内存、连接关闭/回收、广播目标及关闭所有权、日志和 multi-RPC 原始代际隔离，全部通过；[输入文件摘要](./release-evidence/2026-11-02/fixed-soak/context-suite-inputs.json)可对应仓库中的六个测试文件。
- [ ] 第三个 Linux 生产包仍在构建，远端分阶段验证及新的 24 小时长测尚未启动。

### 第三个修复包：已构建并进入远端阶段验证

- [x] Linux amd64 生产构建退出码 0，实际 Boehm GC enabled，27 个依赖已打包；二进制 SHA256 为 cc0d22074332ef3027d299d1c4efea3550f6b40a17f04bcca56b1c2964bf7580。见[构建日志](./release-evidence/2026-11-02/fixed-soak/build-fixed3.txt)、[构建信息](./release-evidence/2026-11-02/fixed-soak/fixed3-build-info.json)、[补丁溯源](./release-evidence/2026-11-02/fixed-soak/fixed3-provenance.json)和[上传清单](./release-evidence/2026-11-02/fixed-soak/fixed3-upload-manifest.json)。七个运行时补丁文件与构建快照摘要一致。
- [x] 本机 41 项组合回归及格式检查通过；[远端 35 文件/GC/动态库校验](./release-evidence/2026-11-02/fixed-soak/fixed3-remote-verification.json)通过，原 bodytest PID 9303/启动标识 601054 保持。
- [ ] 已启动 vhttpd-soak-fixed3-validation-20261102，目录 /root/vhttpd-release-tests/20261102-fixed3；按原顺序执行 Paseo、HTTP、混合负载，保留 16 MiB 冷却后增长门槛。全部通过后才启动 vhttpd-soak-fixed3-24h-20261102。

### 握手 client holder 持有问题：修复前后真实握手回归通过

第三个包的[阶段判定](./release-evidence/2026-11-02/fixed-soak/third-validation/sequence.json)仍未通过，未启动 24 小时任务。继续定位到[握手捕获回调](../src/ws/ingress_owner.c.v)：每次 managed_server 创建捕获 HandshakeClient 的原生闭包，握手结束后 holder 仍持有已关闭 client，连同其缓冲区和回调引用被全局 trampoline 保留。

- [x] 已实现：使用静态 accept 回调，managed_handshake 在同步调用期间以线程本地指针提供 holder，结束时恢复先前指针、清空 client；保持 holder 对 Boehm 可达。线程本地实现采用仓库既有的 MSVC/GCC/Clang 兼容方式，见[头文件](../src/ws/handshake_callback_scope.h)和[实现](../src/ws/handshake_callback_scope.c)。
- [x] [真实握手回归](../src/ws/handshake_memory_test.v)：旧实现 256 次握手后 GC 保留从 466944 字节增至 4395008 字节，同时 client 清空断言失败；新实现两个测试通过，覆盖 101 升级响应、正常关闭、client 释放及并行捕获隔离。见[旧输出](./release-evidence/2026-11-02/fixed-soak/handshake-before-final-test.txt)、[新输出](./release-evidence/2026-11-02/fixed-soak/handshake-after-final-test.txt)及[摘要](./release-evidence/2026-11-02/fixed-soak/handshake-regression.json)。
- [ ] 入站生命周期回归及第四个 Linux 生产包构建中；见[完整补丁摘要](./release-evidence/2026-11-02/fixed-soak/fixed4-provenance.json)。完成后重新从 Paseo 分离阶段开始验证，仍不放宽资源或增长门槛。

- [x] 握手修复后的入站生命周期 5 项回归通过，包含失败升级清理、停止前拒绝升级、连接回收和真实 SIGTERM/SIGINT 信号下会话收尾；信号子进程运行的是本次测试可执行文件。见[生命周期原始输出](./release-evidence/2026-11-02/fixed-soak/handshake-inbound-lifecycle-test.txt)。
- [x] 第四包十个运行时补丁文件摘要与工作区一致；握手 V 文件格式检查通过。

### 第四个修复包已进入远端验证

- [x] Linux amd64 生产构建退出码 0、实际 Boehm GC enabled，27 个运行库打包完成；二进制 SHA256 为 b26060c5aaf1eaa2ce505a4eb8b60f97808fae95daf216c5bb1153280437bb50。见[构建日志](./release-evidence/2026-11-02/fixed-soak/build-fixed4.txt)、[构建信息](./release-evidence/2026-11-02/fixed-soak/fixed4-build-info.json)、[十文件补丁摘要](./release-evidence/2026-11-02/fixed-soak/fixed4-provenance.json)。
- [x] [上传清单](./release-evidence/2026-11-02/fixed-soak/fixed4-upload-manifest.json)及[远端文件/运行依赖校验](./release-evidence/2026-11-02/fixed-soak/fixed4-remote-verification.json)通过。原 bodytest PID 9303/启动标识 601054 仍保持。
- [ ] vhttpd-soak-fixed4-validation-20261102 已启动，目录 /root/vhttpd-release-tests/20261102-fixed4；使用与前轮相同负载和 16 MiB 冷却后增长门槛。通过后自动启动 vhttpd-soak-fixed4-24h-20261102，不累计前轮时长。

### 第四包混合负载阻断与原生 TLS 释放修复

- [x] 第四包 Paseo 78 轮、HTTP 6390 次分别零错误并通过阶段内存门槛；混合负载冷却后 RSS 从 64376 KiB 增至 86704 KiB，超过 16 MiB 门槛，已阻断 24 小时任务。见[阶段原始判定](./release-evidence/2026-11-02/fixed-soak/fourth-validation/sequence.json)。
- [x] 在独立诊断进程通过 heaptrack 定位：779 轮 Paseo、零业务错误，关闭连接时 `Client.reset_state()` 创建的 `SSL_new`/`SSL_CTX_new` 对象保留。该路径即使 `ws://` 也会分配；`close()` 保留重连状态，终止所有者需调用已有的 `dispose()`。见[原生分配堆栈](./release-evidence/2026-11-02/fixed-soak/heaptrack/leaks.txt)、[诊断运行结果](./release-evidence/2026-11-02/fixed-soak/heaptrack/result.json)。诊断运行不计入验收或长测时长。
- [x] 已修复：[managed_handshake](../src/ws/ingress_owner.c.v) 收尾调用 `client.dispose()`，释放为重连创建的原生 TLS 对象。本机[握手回归](./release-evidence/2026-11-02/fixed-soak/tls-dispose-handshake-test.txt)和[入站生命周期回归](./release-evidence/2026-11-02/fixed-soak/tls-dispose-inbound-test.txt)通过。
- [ ] Linux 原生分配器回归、第五个 Linux 生产包正在构建/验证；通过后在新目录重新执行 Paseo、HTTP、混合负载，全部通过才自动启动完整 24 小时有效压力。此前测试时长不累计；原 bodytest 保持运行。

- [x] Linux amd64 原生分配器回归完成：同一 256 次真实握手，旧实现原生在用内存从 721488 增到 6344496 字节而失败，`dispose()` 修复后同一测试通过；同时检查 GC 保留、holder 释放和并行线程隔离。见[旧实现输出](./release-evidence/2026-11-02/fixed-soak/linux-tls-before-handshake-test.txt)、[修复输出](./release-evidence/2026-11-02/fixed-soak/linux-fixed5-handshake-test.txt)、[回归摘要](./release-evidence/2026-11-02/fixed-soak/tls-dispose-linux-regression.json)。该检查通过 glibc `mallinfo2()` 覆盖 GC 统计之外的原生分配；其他平台返回 0，不能作为其原生内存验收结论。

### 第五个修复包：构建完成、隔离阶段验证已启动

- [x] Linux amd64 生产构建完成，退出码 0，实际 Boehm GC enabled、27 个运行库已打包。二进制 SHA256 为 `36884c13ad7c03ea66d70e8a561e5a865986e6b34df8dcbaa85ac1ced0ec0080`；十个运行时补丁文件与构建快照摘要一致。见[构建日志](./release-evidence/2026-11-02/fixed-soak/build-fixed5.txt)、[构建信息](./release-evidence/2026-11-02/fixed-soak/fixed5-build-info.json)、[补丁摘要](./release-evidence/2026-11-02/fixed-soak/fixed5-provenance.json)。
- [x] [上传清单](./release-evidence/2026-11-02/fixed-soak/fixed5-upload-manifest.json)与[远端 35 文件/GC/动态库校验](./release-evidence/2026-11-02/fixed-soak/fixed5-remote-verification.json)通过，原 bodytest PID 9303/启动标识 601054 保持。远端测试目录 `/root/vhttpd-release-tests/20261102-fixed5`。
- [ ] 北京时间 2026-11-02 22:24:15 启动 `vhttpd-soak-fixed5-validation-20261102.service`：依次执行 Paseo 240 秒、HTTP 240 秒和混合负载 900 秒，使用原有 16 MiB 冷却后增长门槛。全部通过后自动启动 `vhttpd-soak-fixed5-24h-20261102.service`；内存限制 512 MiB、CPU 1 核、无 swap。完整压力阶段尚未开始。

- [x] 第五包 Paseo 78 轮零错误，RSS 基线 62124 KiB、冷却后 62568 KiB，增长 444 KiB；HTTP 6392 次零错误，基线 49940 KiB、冷却后 49804 KiB。两项均通过原门槛，见[阶段判定](./release-evidence/2026-11-02/fixed-soak/fifth-validation/sequence.json)。
- [ ] 混合负载 900 秒正在执行；原先阻断长测的这一阶段尚未验收，24 小时服务仍未启动。

### 第五包验收通过，完整长测已重新启动（北京时间 2026-11-02 22:47）

- [x] Paseo、HTTP、混合负载三项全部通过既定门槛，所有业务错误数为 0；混合阶段 23961 次 HTTP、293 轮 Paseo，RSS 基线 83276 KiB、冷却后 79440 KiB、压力采样峰值 83464 KiB。见[完整阶段判定](./release-evidence/2026-11-02/fixed-soak/fifth-validation/sequence.json)、[混合运行结果](./release-evidence/2026-11-02/fixed-soak/fifth-validation/mixed/result.json)及[混合采样](./release-evidence/2026-11-02/fixed-soak/fifth-validation/mixed/samples.ndjson)。
- [x] `vhttpd-soak-fixed5-24h-20261102.service` 实际为 active/running，独立运行进程 PID 108824，当前处于前置基线阶段；二进制为上述第五包。见[启动时刻及预计时间](./release-evidence/2026-11-02/fixed-soak/fifth-validation/launch.json)、[systemd 原始状态](./release-evidence/2026-11-02/fixed-soak/fifth-validation/launch-unit-status.txt)、[长测初始状态](./release-evidence/2026-11-02/fixed-soak/fifth-validation/full24/state.json)和[初始采样](./release-evidence/2026-11-02/fixed-soak/fifth-validation/full24/samples.ndjson)。本地文件是启动快照，实时状态以服务器目录为准。
- [x] 资源限制保持 MemoryMax 512 MiB、MemorySwapMax 0、CPUQuota 100%、TasksMax 128；原 bodytest PID 9303/启动标识 601054 保持运行。测试由 systemd 托管，SSH 断开不停止任务。
- [ ] 待验收：完整 24 小时有效压力及资源稳定性。前置基线 22:47:27–22:57:27，压力 2026-11-02 22:57:27 至 2026-11-03 22:57:27，冷却结束预计 2026-11-03 23:07:27（全部北京时间）。此前任何测试时长均未累计。完成后需核对全量 RSS/FD/线程、错误率、延迟、OOM/退出及冷却收敛，不能因服务已启动而关闭 P0-02。

实时结果目录：`/root/vhttpd-release-tests/20261102-fixed5/full24`，状态为 `state.json`，采样为 `samples.ndjson`，结束结果为 `result.json`。本轮范围是 Ubuntu amd64、隔离 HTTP JSON 与 Paseo 重连/文本/二进制；数据库、Provider、应用重载、其他操作系统及最终正式候选包仍需单独验收。

### 长测中途检查：2026-11-03 07:13（北京时间）

- [x] 服务仍 active/running，进程 PID 108824，已运行约 8 小时 25 分钟（有效压力约 8 小时 15 分钟）；累计约 118.5 万次 HTTP、1.45 万轮 Paseo，错误数均为 0，无 OOM。原 bodytest PID 9303/启动标识 601054 保持。
- [ ] 内存稳定性仍为发布阻断：RSS 从压力初期 65560 KiB 上升至约 167248 KiB，前八个小时约增加 13 MiB/小时，最近一段出现回落，尚不能证明已经收敛，也不能仅凭 RSS 判断具体泄漏来源。当前 FD 22、线程 22。见[本次原始状态与逐小时趋势](./release-evidence/2026-11-02/fixed-soak/fifth-validation/checkpoint-20261103-0713.json)。
- [ ] 继续原有资源限制下的长测，不重启、不累计其他测试时长；预计仍于今日 23:07 完成含冷却的全过程。24 小时结束后需结合原生/GC 分配、全量趋势和冷却结果判定，不因零业务错误放行。

### 剩余增长定位：vlang `shared` 包装对象不可回收（2026-11-03）

- [x] 长测保持原服务、PID 108824/启动标识 5375404 继续运行；只读 `/proc` 获取 GC 计数/标记，没有挂接调试器、暂停进程或注入函数调用。统计对象布局已用实际二进制反汇编核对；这是运行中的非原子样本。约 5.4 万份共享状态，与累计连接数量相符，GC kind 2 为不可回收分配；[对象大小与容器统计](./release-evidence/2026-11-03/shared-gc/20261103-fixed5-profiles/long-passive-object-hist.json)。
- [x] 分离诊断：加速纯 Paseo 复现增长；独立 HTTP 42565 次、零错误，RSS 基本持平。Paseo 堆跟踪有 3 次诊断超时，且旧包路径校验导致收尾信号未发出，随后仅对核验过的诊断 PID 发出 SIGTERM；这些运行只用于定位，不能计作稳定性验收。见[分项诊断元数据](./release-evidence/2026-11-03/shared-gc/20261103-fixed5-profiles/paseo/profiling.json)、[收尾说明](./release-evidence/2026-11-03/shared-gc/20261103-fixed5-profiles/paseo/intervention.json)、[HTTP 结果](./release-evidence/2026-11-03/shared-gc/20261103-fixed5-profiles/http/result.json)。
- [x] 根因：V 的 `shared_dup_fns` 用 `malloc_uncollectable` 创建共享包装对象。WebSocket 每连接的 ClientState、WriteLock 和 ServerState 因此成为永久 GC 根，连带保留状态内的容器等对象。最小复现 4096 个失去引用的共享对象，完整 GC 后从 53248 字节增到 4415488 字节并失败，见[修复前原始输出](./release-evidence/2026-11-03/shared-gc/shared-gc-before.txt)。
- [x] 已按维护者明确授权修改本地 vlang 仓库 `/Users/guweigang/local/v`：常规共享包装对象改用可回收、会扫描引用的 `memdup`；保留原预分配分支。已 `./v self` 重建。新增内存、共享别名/持锁 GC、只有工作线程持有引用时的 GC 回归，macOS 三项通过。见[完整编译器补丁](./release-evidence/2026-11-03/shared-gc/vlang-shared-gc.patch.txt)、[重建输出](./release-evidence/2026-11-03/shared-gc/v-shared-self-build.txt)、[修复后原始输出](./release-evidence/2026-11-03/shared-gc/shared-gc-after-final.txt)及[溯源摘要](./release-evidence/2026-11-03/shared-gc/finding.json)。本项未修改 vjsx。
- [ ] 待验收：Linux amd64 修复前后对照、4096 次真实 WebSocket 握手回归及编译器测试。当前长测仍用原第五包，不会自动替换或重启；新工具链/新包验证通过后，再另行安排修复版长测。

- [x] 真实握手回归已扩大到 4096 次，保持原 1 MiB GC、2 MiB 原生 malloc 门槛。macOS 旧编译器完整 GC 后从 253952 字节增至 5853184 字节而失败，修复工具链通过；Linux 旧编译器同样从 249856 字节增至 4075520 字节而失败。见[macOS 旧输出](./release-evidence/2026-11-03/shared-gc/shared-handshake-mac-before-final.txt)、[macOS 修复后输出](./release-evidence/2026-11-03/shared-gc/shared-handshake-mac-after-final.txt)。Linux 修复后仍在验证，不提前勾选。
- [x] vlang 定向[锁代码生成回归](./release-evidence/2026-11-03/shared-gc/v-shared-lock-codegen-test.txt)通过。
- [ ] 全量编译器和完整 C 生成套件尚未完成：本机 16 GiB 内存、约 6.5 GiB swap 已在使用，结束了本任务重叠启动的两个广泛测试进程组，保留定向验证与原始输出。见[具体测试进程与原因](./release-evidence/2026-11-03/shared-gc/broad-suite-intervention.json)。这不是正式工具链放行记录，广泛回归仍待补齐。

### `shared` 修复定向验证完成，原长测保持运行

- [x] Linux amd64 工具链已完成自举，三项 `shared` 回归通过；4096 次真实握手的旧工具链 GC 保留从 249856 增至 4075520 字节而失败，修复后通过原 GC 和原生 malloc 门槛。见[Linux 旧握手输出](./release-evidence/2026-11-03/shared-gc/linux-shared-handshake-before.txt)、[新握手输出](./release-evidence/2026-11-03/shared-gc/linux-shared-handshake-after.txt)、[工具链重建](./release-evidence/2026-11-03/shared-gc/linux-shared-self.txt)。
- [x] 生产优化模式也已校验：`-prod` 会删除断言，最初把通道接收写在断言内的测试因此自行互等；只结束该本机测试，改为显式同步和 `panic` 校验。旧编译器在生产模式仍因同一泄漏失败，修复后的 macOS/Linux 普通和生产模式三项均通过。见[旧生产模式负例](./release-evidence/2026-11-03/shared-gc/shared-gc-before-prod-final.txt)、[macOS 生产模式](./release-evidence/2026-11-03/shared-gc/shared-gc-after-prod-final.txt)、[Linux 普通模式](./release-evidence/2026-11-03/shared-gc/linux-shared-strict-after.txt)、[Linux 生产模式](./release-evidence/2026-11-03/shared-gc/linux-shared-prod-strict-after.txt)及[最终测试源码](./release-evidence/2026-11-03/shared-gc/shared-gc-memory-test-source.txt)。
- [x] 编译器错误诊断回归完成：1876 项通过、1 项跳过，见[完整诊断输出](./release-evidence/2026-11-03/shared-gc/v-shared-compiler-errors-test.txt)；锁代码生成定向回归也通过。上述不是完整编译器套件放行。
- [x] vlang 共修改三个文件：`vlib/v/gen/c/struct.v`、`vlib/v/compiler_tests/lock_codegen_test.v`、`vlib/v/tests/concurrency/shared_gc_memory_test.v`；完整[补丁](./release-evidence/2026-11-03/shared-gc/vlang-shared-gc.patch.txt)和[摘要](./release-evidence/2026-11-03/shared-gc/finding.json)已刷新。vjsx 未修改，仍为 `259620f1981a3573777ec8cda72883b1866404a7`。
- [x] 原长测服务/PID 108824/启动标识 5375404 均保持，最近检查约 155.7 万次 HTTP、1.9 万轮 Paseo，零错误、无 OOM，原业务进程 PID 9303 保持运行。见[检查快照](./release-evidence/2026-11-03/shared-gc/latest-fixed5-status.txt)。当前跑的是原第五包，尚未部署新工具链构建的运行时。
- [ ] 待验收：Windows、完整编译器/C 生成套件、合并前性能核对，以及新工具链构建候选包后的分项和完整长测。本轮原第五包长测继续至既定结束时间，不能计作修复版的稳定性证明；P0-02 不关闭。

补充诊断局限：独立 GC 快照辅助线程的 `sleep()` 被 Boehm 信号提前唤醒，三份对象快照都位于基线阶段，因此未用作压力后保留量对比。根因证据采用实际长测只读标记统计及独立修复前后回归；没有为补采快照暂停或修改原长测。

### 上游版本核对与第六包替换（2026-11-03）

- [x] 核对官方最新 master `d126ca3fd329aa7be68efcc2f61d074f8b5dfd3f` 与维护者 fork 最新 `01a8af98dc66c2f19194a516de43acfadc289681`：新后端的 `shared_dup_fns` 仍生成 `malloc_uncollectable`。fork 的提交修复的是共享载荷可被 GC 扫描，不代表包装对象能被回收。官方最新正式版 0.5.2 的旧后端 `Gen.write_shareds` 原本使用可回收 `builtin__memdup`，须与当前新后端区分。核对时间、固定源码 URL 和结论见[核对元数据](./release-evidence/2026-11-03/runtime-replacement/upstream-verification.json)，原始函数逐行摘录及完整源文件摘要见[上游源码摘录](./release-evidence/2026-11-03/runtime-replacement/upstream-source-excerpts.json)。
- [x] 已修复工具链继续通过上游已有的共享载荷 GC 可见性回归，见[定向回归输出](./release-evidence/2026-11-03/runtime-replacement/shared-upstream-visibility-test.txt)。新包保持已验证的 `d13ccdd` 加本地补丁，不在本次替换中切换整套后端。隔离尝试官方 0.5.2 二进制时，当前 macOS 的 vtest 自举编译未成功并派生诊断助手，已停止该测试树；不计作兼容性通过，见[旧正式版运行测试局限](./release-evidence/2026-11-03/runtime-replacement/upstream-stable-runtime-intervention.json)。
- [x] 第六包 Linux amd64 生产构建完成：版本 0.9.0、实际 Boehm GC enabled、27 个运行库，二进制 SHA256 `dd079b74542580f7ed7acdbdeb372b671c006c9c687b5158e908fa63dabf5c7d`。十个运行时补丁文件与第五包快照相同，变化集中于修复后的编译器。见[包与工具链溯源](./release-evidence/2026-11-03/runtime-replacement/fixed6-provenance.json)、[上传清单](./release-evidence/2026-11-03/runtime-replacement/fixed6-upload-manifest.json)、[远端摘要/GC/动态库校验](./release-evidence/2026-11-03/runtime-replacement/fixed6-remote-verification.json)。这是诊断候选包，不是已冻结正式发行包。
- [x] 新包 60 秒混合冒烟完成，HTTP 1600 次、Paseo 20 轮，零错误，见[冒烟结果](./release-evidence/2026-11-03/runtime-replacement/smoke/result.json)。按维护者本次明确要求，核对旧测试 PID/启动标识/二进制摘要/cgroup 后，于北京时间 10:16 停止第五包测试服务。旧运行由操作员换包中止，结果中的 SIGTERM 不当作自然崩溃；旧时长不计入新 24 小时。原业务 PID 9303/启动标识 601054 保持，见[替换控制记录](./release-evidence/2026-11-03/runtime-replacement/replacement.json)、[旧运行结束结果](./release-evidence/2026-11-03/runtime-replacement/old-after-stop-result.json)和[控制脚本](./release-evidence/2026-11-03/runtime-replacement/replacement-controller-source.txt)。本条取代前文“原长测不替换、按原时间结束”的当前执行安排，历史检查记录保留。
- [x] 第六包 Paseo 240 秒、HTTP 240 秒、混合 900 秒门禁全部通过，保持冷却 RSS 增长 16 MiB、压力 RSS 256 MiB、FD 增量 8、零业务错误的原门槛。Paseo 78 轮、HTTP 6392 次、混合 HTTP 23961 次/Paseo 293 轮均零错误；混合 RSS 基线 69412 KiB、冷却 68740 KiB、压力采样峰值 69864 KiB。见[阶段记录](./release-evidence/2026-11-03/runtime-replacement/sequence.json)、[混合结果](./release-evidence/2026-11-03/runtime-replacement/mixed/result.json)和[原始采样](./release-evidence/2026-11-03/runtime-replacement/mixed/samples.ndjson)。
- [x] 新 24 小时服务实际 active/running，PID 697847，已核对 `/proc/PID/exe`、二进制 SHA256、资源限制和原业务启动标识。北京时间 2026-11-03 10:39:20 启动，基线至 10:49:20，有效压力至 2026-11-04 10:49:20，冷却预计 10:59:20 结束。见[启动核验与时间表](./release-evidence/2026-11-03/runtime-replacement/launch-verification.json)、[systemd 快照](./release-evidence/2026-11-03/runtime-replacement/units.txt)及[长测状态快照](./release-evidence/2026-11-03/runtime-replacement/full24/state.json)。快照不代表后续实时状态。
- [ ] 待验收：第六包完整 24 小时有效压力、冷却收敛、全量 RSS/FD/线程趋势、错误与延迟、OOM/退出结果。任务已启动不等于稳定性验收通过，P0-02 不关闭。

远端新目录：`/root/vhttpd-release-tests/20261103-fixed6`；预检服务 `vhttpd-soak-fixed6-validation-20261103.service`，通过后启动 `vhttpd-soak-fixed6-24h-20261103.service`。24 小时有效压力前后各有 600 秒基线/冷却，总时长 87600 秒。服务使用 512 MiB、1 核、无 swap 限制，由 systemd 托管，不依赖 SSH 会话。P0-02 保持未关闭；数据库、Provider、其他平台和最终正式候选包的证据仍需补齐。

第六包首轮检查（北京时间 2026-11-03 11:24）：PID 697847 保持，已运行约 45 分钟，实际压力约 35 分钟；HTTP 83066 次、Paseo 1013 轮，零错误、无 OOM，RSS 69904 KiB、FD 22、线程 22。原业务启动标识 601054 保持。见[长测状态快照](./release-evidence/2026-11-03/runtime-replacement/full24/state.json)及[采样](./release-evidence/2026-11-03/runtime-replacement/full24/samples.ndjson)。这是早期观察，仍待完整 24 小时与冷却结果。

### 第六包剩余增长：不中断长测的分项定位（2026-11-03 13:36，北京时间）

- [x] 长测原服务、PID 697847/启动标识 9646788 保持，原业务 PID 9303/启动标识 601054 保持；没有挂接调试器、暂停、注入调用或重启长测。累计 HTTP 399717 次、Paseo 4874 轮，零错误、无 OOM，RSS 77072 KiB、FD 22、线程 22。只读诊断及结论边界见[本轮调查摘要](./release-evidence/2026-11-03/remaining-growth/finding.json)。
- [x] 独立堆追踪完成：Paseo 764 轮、原生 HTTP 4793 次、JSON HTTP 4792 次均零错误。按分配/释放事件比较跟踪时间 30 秒与 170 秒的原生在用字节：Paseo 净增 11672 字节，原生 HTTP 为 0，JSON HTTP 净增 20320 字节且后续检查点持平。见[Paseo 原生变化与堆栈](./release-evidence/2026-11-03/remaining-growth/20261103-fixed6-diagnosis/paseo/native-live-delta.json)、[原生 HTTP](./release-evidence/2026-11-03/remaining-growth/20261103-fixed6-diagnosis/http-native/native-live-delta.json)、[JSON HTTP](./release-evidence/2026-11-03/remaining-growth/20261103-fixed6-diagnosis/http-json/native-live-delta.json)。这限定于独立短跑，不证明长时间原生零泄漏；heaptrack 不覆盖 Boehm 小对象及 mmap。SIGTERM 后的最终未释放总数含仍存活的启动运行时，不能直接当作每请求泄漏。
- [x] 精确二进制反汇编核对 GC 计数地址后，只读读取 `/proc/PID/mem`。原 80 字节不可回收共享包装的大量积累不再出现，样本仅 6 个常驻槽；长期样本新增的主要标记集中在 16 字节类，其中绝大部分内容是指向相邻槽的链表指针。标记包含空闲槽、采样非原子，因此不能将这一数量直接当作未释放业务对象，更不能据此盲改所有者。只读脚本见[采样实现](./release-evidence/2026-11-03/remaining-growth/passive-fixed6.py.txt)。
- [x] 发现独立的 GC 统计缺陷：不可回收小对象分配的空闲表为空时，回退分支漏增在用字节计数，释放分支仍扣减，`GC_get_non_gc_bytes` 可下溢。独立串行/并行、批量分配/释放及 V 线程创建/退出均可复现；批量程序的堆仍返回完全空闲的固定 196608 字节，线程测试的堆也收敛。因此下溢本身不是已证实的 RSS 增长根因，未对 vlang 再作修改。见[源代码摘录](./release-evidence/2026-11-03/remaining-growth/gc-accounting-source-excerpts.txt)、[批量复现输出](./release-evidence/2026-11-03/remaining-growth/gc-uncollectable-batch.log.txt)和[线程复现输出](./release-evidence/2026-11-03/remaining-growth/thread-gc-churn.log.txt)。
- [x] Paseo、JSON、加速混合及与长测同连接节奏的短对照已补采基线/压力/冷却 GC 样本，均未在短时窗口复现原长测规模的 16 字节槽位积累。大体积分配原始数据保留在服务器，路径与 SHA256 见[原始记录清单](./release-evidence/2026-11-03/remaining-growth/remote-large-profile-manifest.json)。本轮没有新增修改 vhttpd、vlang 或 vjsx 源码，未部署任何新包。
- [ ] 待定位：剩余持续增长的精确保留者。已启动独立 `vhttpd-fixed6-gc-extended-20261103.service`，保持与长测相同的 40 RPS HTTP、每 2 秒一轮 Paseo，使用 600 秒基线、1200 秒压力、120 秒冷却并只读采样 GC；最多 256 MiB、30% CPU。额外守护在主机可用内存连续三次低于 512 MiB 时只停止该诊断服务，绝不停止长测或业务。见[延长诊断元数据](./release-evidence/2026-11-03/remaining-growth/20261103-fixed6-gc-extended/metadata.json)和[守护实现](./release-evidence/2026-11-03/remaining-growth/guard-fixed6-diagnosis.py.txt)。诊断不计入 24 小时验收，不因短跑收敛关闭 P0-02。

### 延长对照完成，定位到 GCC 生产优化下的 GC 空闲块滞留

- [x] 延长对照于北京时间 2026-11-03 14:06:41 完成：600 秒基线、1200 秒压力、120 秒冷却，HTTP 47786 次、Paseo 582 轮，零错误。压力初期三点 RSS 中位数 72560 KiB，冷却末期三点 66792 KiB，压力峰值 72956 KiB，短时资源可收敛。见[结束结果](./release-evidence/2026-11-03/remaining-growth/20261103-fixed6-gc-extended/mixed/result.json)及[采样](./release-evidence/2026-11-03/remaining-growth/20261103-fixed6-gc-extended/mixed/samples.ndjson)。这不替代正式 24 小时记录。
- [x] 进一步使用限定 PID 的短时 uprobes 计数：独立对照 90 秒内小对象分配 1637 次、匹配释放 1636 次；原长测 60 秒观察中分配 1241 次、匹配释放 1240 次，剩余项对应尚未结束的唤醒任务。原长测另一段 90 秒指针代际检查分配 1954 次、匹配释放 1951 次，未观测到重复释放或活跃指针被复用。没有 ptrace、暂停信号、进程内函数注入或强制 GC，压力流量继续；本条补充前一阶段纯 `/proc` 采样方式。见[独立配对摘要](./release-evidence/2026-11-03/remaining-growth/20261103-fixed6-gc-extended/bpf-gc-small-summary.json)、[长测分配/释放计数](./release-evidence/2026-11-03/remaining-growth/20261103-fixed6-gc-extended/long-gc-events.txt)和[指针代际记录](./release-evidence/2026-11-03/remaining-growth/20261103-fixed6-gc-extended/long-gc-pairing.txt)。最初的 ustack 在优化二进制中展开不可靠，未用于调用者归因，改读入口返回地址并按精确 ELF 符号解析。
- [x] 新申请的 GC 小对象堆块未全部在观察窗口中归还：独立对照 120 秒申请 37 块、归还 3 块；原长测 60 秒申请 3 块、归还 0 块。只读队列检查显示 1119 个 16 字节类堆块、共 4583424 字节，其中大部分呈空闲链表形态，却不在当前全局空闲链或待回收队列。内容形态本身不能证明逻辑所有权，但与对象释放计数和后续最小复现共同缩小到了 GC 回收/复用路径。见[队列实测与局限](./release-evidence/2026-11-03/remaining-growth/20261103-fixed6-gc-extended/long-free-pool-state.json)。
- [x] 将实际长测构建容器中的 GC 对象与 ELF 函数尺寸及 SHA256 对齐，确认生产优化对象摘要 `c5709472d124a835010545e0f40ce2561dae4d4ae3d207bac337760e95d4b53e`。此前使用同源未优化缓存对象的最小程序能收敛，不能据此排除生产路径。精确对象和重编译 `-O3` 均可复现：并发 GC 加 6000 次短线程创建/退出，完整 GC 后仍保留 6115328 字节；同源 `-O2` 保留 73728 字节，`-O1` 保留 24576 字节。`-fno-strict-aliasing` 没有修复该问题。见[对照摘要和溯源](./release-evidence/2026-11-03/remaining-growth/gc-optimization/finding.json)、[O3 原始输出](./release-evidence/2026-11-03/remaining-growth/gc-optimization/gc-detached-baseline.log.txt)、[O2 输出](./release-evidence/2026-11-03/remaining-growth/gc-optimization/gc-detached-O2.log.txt)。这里已证实构建条件，尚未进一步断定是上游 C 实现还是 GCC 某个优化步骤的缺陷。
- [x] 按已有授权修改 vlang：`thirdparty/libgc/gc.c` 为启用优化的 GCC 编译使用该文件内的 `push_options/optimize("O2")/pop_options`，不改变生成的 V 代码或其他 C 辅助文件的优化级别；Clang/MSVC 不应用该保护。源文件内容变化进入既有依赖摘要，避免继续使用旧 GC 缓存对象。新增 `vlib/builtin/gc_uncollectable_reclaim_test.v` 与同名 `.c.h`，保留生产模式下的真实并发回收检查。见[GC 补丁](./release-evidence/2026-11-03/remaining-growth/gc-optimization/vlang-gc-optimization.patch.txt)与[测试源码](./release-evidence/2026-11-03/remaining-growth/gc-optimization/gc_uncollectable_reclaim_test.v.txt)。这是经过定向验证的构建规避修复；此前 GC 在用字节计数下溢问题未一并修改，不能用该计数判定泄漏。
- [x] 生产参数负例有效：必须匹配 `-prod -parallel-cc`，旧工具链在完整 GC 后额外保留 4386816 字节，超过原定 2 MiB 门槛而失败。最初未带并行生产参数的测试旧版通过，已保留且不计作负例。修复后同一回归的冷缓存、暖缓存均通过，macOS/Linux 编译器均已自举。见[生产负例](./release-evidence/2026-11-03/remaining-growth/gc-optimization/gc-o2-regression-before.log.txt)、[修复后](./release-evidence/2026-11-03/remaining-growth/gc-optimization/gc-o2-regression-after.log.txt)、[暖缓存](./release-evidence/2026-11-03/remaining-growth/gc-optimization/gc-o2-regression-warm.log.txt)。
- [x] Linux 生产 shared 和 4096 次真实握手回归通过，macOS Clang 生产 shared 回归通过。验证镜像携带过期 shared 测试，通道接收仍在 `assert` 内，导致生产模式互等及自动重试；只清理本地隔离验证容器，刷新为已验证的严格源码后重跑通过，未计旧运行通过，见[本地测试收尾说明](./release-evidence/2026-11-03/remaining-growth/gc-optimization/gc-o2-stale-fixture-intervention.json)。同时修正 vhttpd [握手测试](../src/ws/handshake_memory_test.v)：用显式同步和 `panic` 保留生产模式中的原 1 MiB GC/2 MiB 原生门槛，不改运行时行为。见[最终 shared 输出](./release-evidence/2026-11-03/remaining-growth/gc-optimization/gc-o2-shared-regression-final.log.txt)、[握手输出](./release-evidence/2026-11-03/remaining-growth/gc-optimization/gc-o2-handshake-regression.log.txt)、[macOS 输出](./release-evidence/2026-11-03/remaining-growth/gc-optimization/gc-o2-host-shared.log.txt)。
- [x] 已保存本地 Linux 工具链镜像 `vhttpd-gc-o2-toolchain:20261103`，镜像 ID `sha256:f3795a8c5067f58da6c2cad071ccbb7394196df15b249e325c995382d120ef58`；[工具链版本与源码摘要](./release-evidence/2026-11-03/remaining-growth/gc-optimization/toolchain-verification.txt)。本轮 vjsx 未改。所有短时探针及延长对照均已结束，原长测服务 active/running、NRestarts 0，PID/启动标识与业务 PID 均保持，见[最终服务核验](./release-evidence/2026-11-03/remaining-growth/20261103-fixed6-gc-extended/final-process-verification.json)。
- [ ] 待验收：用已验证工具链构建最终候选运行时并完成独立负载检查、完整 24 小时及跨平台放行。依维护者要求，本轮正在运行的第六包不停止、不替换；它仍包含原 GCC O3 GC 编译路径，不能计作本次新规避修复的稳定性证明。P0-02 保持阻断。

### bodytest 剩余驻留归因（2026-11-09，当前业务包）

- [x] 真实业务 PID 3730524、启动标识 39645663、包 SHA256 `0890d93135156b2ad77ae25e1bc6ac833cd5b09cc226ff15145aaed1c6288baa` 保持；诊断后匿名内存 126.3 MiB，三个健康检查均为 200。未重启、换包、修改配置或主动触发 GC。诊断包含数值元数据只读快照、临时低频函数边界探针和 CPU 采样，不能称为完全无观测开销。见[归因结论与身份核验](./release-evidence/2026-11-09/body-attribution/finding.json)。
- [x] 驻留分类：Boehm 对象堆约 90.3 MiB、glibc arena 27.9 MiB、可确认线程栈 3.4 MiB、其余 4.7 MiB。自然 GC 后 Boehm 整块空闲页约 76.7 MiB、标记对象约 5.35 MiB；glibc 另有约 15.7 MiB 空闲 top 区仍驻留。其余页面中约 2.7 MiB 含已验证的 GC 元数据；各层计数和逻辑对象量口径不同，不可重复相加。见[自然 GC 快照](./release-evidence/2026-11-09/body-attribution/natural-gc-census.ndjson)、[分配区与运行时计数](./release-evidence/2026-11-09/body-attribution/layers-3-quickjs.json)。
- [x] 当前分配热点定位：约 30 分钟请求活动计数不变，但后台累计分配约 5.5 GiB，匿名驻留基本不变。20 秒内四个线程执行源码探测 796 次、完整签名扫描 78 次；扫描函数时间区间并集覆盖同期 99.85% 的全局 GC 分配增量。该比例是时间覆盖，不能当作每笔分配的独占调用者归属。四个匹配的 QuickJS 运行时合计逻辑记账约 8.02 MiB，短时三次复测不变。见[函数范围计数及局限](./release-evidence/2026-11-09/body-attribution/scope-analysis.json)、[QuickJS 复测](./release-evidence/2026-11-09/body-attribution/quickjs-repeat.ndjson)。
- [ ] 待验收：以贴近真实四运行时的源码规模独立验证已有低分配扫描候选，比较驻留峰值、持续请求、冷却和延迟，再安排业务替换；本轮不替换 bodytest，不把先前候选的修复效果计入当前业务。约 1 MiB 其他驻留页及剩余原生分配的精确所有者尚未完全明确；一次后续快照因一致性检查失败已排除。尚无全业务无泄漏或正式 24 小时放行结论，P0-02 保持阻断。

### 源码检测四运行时对照完成，新增复用增量撤回（2026-11-09）

本节更新上文独立对照的执行状态；业务替换和正式内存放行仍未完成。

- [x] 按真实元数据建立两个源码目录，复现四个 QuickJS 运行时及四个扫描线程。实际旧包后台分配约 3.16–3.22 MiB/秒，接近 bodytest 的约 3.10 MiB/秒。源码内容和请求处理器为合成夹具，没有重放数据库、云服务及真实业务依赖。主对照按旧→新→新→旧自然跑完，另串行跑一轮上一版缓存包控制；每轮 60 秒基线、240 秒压力、300 秒冷却，并单独验证长请求及恢复加压。全部保持 256 MiB、30% CPU、无 swap、640 MiB 启动门槛与 512 MiB 主机保护。见[结论与完整身份核验](./release-evidence/2026-11-09/source-four-runtime/finding.json)。
- [x] 测试了目录成员与排序列表复用。相同编译器的四配置微基准指纹全部一致；相对上一版缓存额外减少约 3.25% 分配，但未获得驻留改善，因此已仅撤回本轮新增复用代码，恢复扫描器摘要 `041e8955`。保留等数量路径重命名、排序与根目录删除回归。最终源码的 macOS/Linux 扫描与签名两模块回归均通过；本轮没有新增 vlang/vjsx 修改。见[增量决策](./release-evidence/2026-11-09/source-four-runtime/increment-decision.json)、[微基准](./release-evidence/2026-11-09/source-four-runtime/bench-summary.json)、[最终验证范围](./release-evidence/2026-11-09/source-four-runtime/validation-summary.json)。
- [x] 五轮累计 HTTP 95577 次、Paseo 577 轮，零校验错误、无 OOM；新候选与缓存控制在持续压力期间没有增加空闲 GC 或编译器 allocator maintenance 尝试。压力、冷却均采用末 60 秒中位数；主对照每种包两次，增量控制只有一次，不能作统计放行。见[逐轮统计与口径](./release-evidence/2026-11-09/source-four-runtime/analysis.json)和[全量曲线](./release-evidence/2026-11-09/source-four-runtime/comparison.png)。

| 包 | 后台分配 MiB/秒 | 压力匿名内存 MiB | 冷却匿名内存 MiB |
| --- | ---: | ---: | ---: |
| 当前业务旧包 `0890d931`，两轮 | 3.16–3.22 | 40.4–43.5 | 32.9–33.2 |
| 本轮试验包 `767456d2`，两轮，已拒绝该增量 | 0.075 | 59.9–67.4 | 34.6–41.7 |
| 上一版缓存包 `323cb5af`，单轮控制 | 0.080 | 50.0 | 30.2 |

- [x] bodytest PID 3730524/启动标识 39645663、包 SHA 保持，匿名内存 126.3 MiB、三个健康检查均为 200，连续监测 active；两个有效对照单元自然退出。最早两个脚本预检及七扫描线程的配置预检均单独排除，未计入以上结果。见[最终业务核验](./release-evidence/2026-11-09/source-four-runtime/final-business-check.json)与[排除记录](./release-evidence/2026-11-09/source-four-runtime/excluded-preflights.json)。
- [ ] P0-02 保持阻断：已证明降低后台分配，不代表压力驻留改善。整包比较还包含既有 HTTP 观察与空闲 GC 改动，不能把所有 RSS 差异归因于源码检测；单次增量控制也未确证更大保留量的具体根因。下一步应固定扫描器，拆开这些继承改动与 GC/glibc 池保留路径。基线与冷却差额包含请求历史、缓存及堆几何变化，不能直接称作泄漏。本轮未切换业务、未启动新的 24 小时验收，也未获得全业务或 Windows 放行。

### 固定扫描器的 GC/HTTP 拆分完成：增量主要在 GC 池驻留（2026-11-09）

本节完成上节提出的拆分；没有切换 bodytest，也没有将诊断结果计作正式长测放行。

- [x] 四组均固定扫描器 `041e8955`、SDK `259620f1` 和相同 Boehm 对象 `d59d73ed`。G 因素是新增空闲回收协调器及请求活动接入，H 因素是五文件 HTTP 观察改动；**G 关闭时仍启用正常 Boehm GC**。冻结源码基点 `9c155bf7`，不能将结果说成已验证当前工作区全部改动。见[完整溯源与结论](./release-evidence/2026-11-09/gc-http-factorial/finding.json)、[源码摘要](./release-evidence/2026-11-09/gc-http-factorial/source-manifest.json)、[公共构建源码](./release-evidence/2026-11-09/gc-http-factorial/frozen-common-source.tar.gz)、[G 差异](./release-evidence/2026-11-09/gc-http-factorial/gc-factor.patch.txt)和[H 差异](./release-evidence/2026-11-09/gc-http-factorial/http-factor.patch.txt)。
- [x] 四组加相同 SHA 新候选复跑，共五轮完整 60 秒基线、240 秒混合压力、300 秒自然冷却；两个源码根、四个预热运行时，HTTP 80 RPS、Paseo 每 2 秒一轮。合计 HTTP 95685 次、Paseo 577 轮，零意外校验错误、无 OOM；HTTP 夹具含预期 503，不能称为零错误状态码。持续压力和 35 秒长请求保护均未误触发空闲强制回收。保持 256 MiB、30% CPU、无 swap、640 MiB 稳定启动门槛与 512 MiB 主机保护，逐轮结束后串行启动。见[逐轮统计](./release-evidence/2026-11-09/gc-http-factorial/analysis.json)、[运行校验与采样局限](./release-evidence/2026-11-09/gc-http-factorial/census-validation.json)及[完整自然曲线](./release-evidence/2026-11-09/gc-http-factorial/comparison.png)。

| 空闲协调器 | HTTP 观察 | 压力匿名 MiB | 自然冷却匿名 MiB | 冷却后额外 GC/unmap 的匿名 MiB |
| --- | --- | ---: | ---: | ---: |
| 关 | 旧 | 39.26 | 38.98 | 25.59 |
| 关 | 新 | 50.29 | 50.23 | 26.64 |
| 开 | 旧 | 53.68 | 32.34 | 26.54 |
| 开 | 新，首轮 | 58.75 | 33.27 | 27.40 |
| 开 | 新，同 SHA 复跑 | 50.55 | 33.36 | 27.68 |

压力与自然冷却列均为末 60 秒中位数。最后一列来自自然阶段结束后的独立诊断干预：完整 GC、两次 GC/unmap，再单独 libc trim；**不是自然回收验收数据**。调试器和辅助库会扰动根及原生分配，因此不能将诊断下限当作真实业务承诺。

- [x] **大部分增量已定位到 GC 对象堆驻留。** 关闭协调器的一对样本中，冷却差额 11.25 MiB，GC 区域实际驻留差额 11.08 MiB，堆外只差 0.18 MiB；完整 GC/unmap 后差额缩为 1.05 MiB。单做完整 GC 可增加可复用整块，但匿名内存不降；解除空闲页映射才回落。五轮完整 GC 后标记对象仅 5.41–5.51 MiB，libc 在用块约 8.56–8.61 MiB，额外 trim 均没有再降匿名内存。因此尚无“新观察代码多保留十几 MiB 必须存活对象”的证据。
- [x] **为什么没有立即归还：空闲页年龄和回收触发条件。** 在 G 开/H 旧及完整新包复跑中，32 份有效只读样本最多见到约 21.75 MiB 已驻留空闲页，均未达到配置的 7 轮 GC 年龄；这里是 GC 轮次，不是秒。停止请求后后台约 0.08 MiB/秒分配使正常 GC 变慢。空闲协调器在安静 30 秒后回收，随后受 16 MiB 最小堆、8 MiB 增长和 60 秒冷却门槛约束，出现缓慢回升后再回落的周期。它改善自然冷却，不控制压力期间的池高水位。见[空闲页年龄](./release-evidence/2026-11-09/gc-http-factorial/age-analysis.json)和[固定 GC 实现摘录](./release-evidence/2026-11-09/gc-http-factorial/gc-collector-policy-excerpts.txt)。
- [x] 回收后的 GC 实际驻留仍约 10.0–11.5 MiB，而标记对象约 5.4–5.5 MiB，整块空闲只余 0–32 KiB。差额与仍分配给对象大小类别的块、块内空槽及保守标记/收集器缓存相符；这些不等同于可整页归还的空闲块，精确槽位所有者尚未逐一证明。所有数字不能重复相加，堆容量也不能当作物理驻留量。
- [x] H 开时全进程压力分配约 11.27–11.41 MiB/秒，H 关约 13.87–14.02，下降约 18–19%；但同 SHA 压力驻留相差约 8.2 MiB，不能根据每格单轮结果将压力池增大唯一归因到某一 HTTP 子改动。完整 GC 后标记量接近，比单看 RSS 更支持“池与回收节奏变化”的解释；保守可达仍不等于精确业务存活。
- [x] macOS/Linux 扫描与签名两模块回归、空闲策略 C 并发/取消/门槛回归均通过。本次拆分没有新增 vlang/vjsx 修改，也没有将独立因素回退写入主工作区运行时代码。bodytest PID 3730524/启动标识 39645663、包 SHA `0890d931` 保持，匿名 126.3 MiB、三个健康检查 200、连续监测 active；主机 MemAvailable 879.2 MiB，五轮自然阶段均跑完，测试进程按协议收尾退出。见[最终业务与收尾核验](./release-evidence/2026-11-09/gc-http-factorial/final-business-check.json)。
- [ ] **P0-02 继续阻断。** 本轮解释了这批驻留增量的位置和大块未归还机制，未证明长期全业务无泄漏，也未验证最终候选 24 小时或 Windows。下一优先项是在固定扫描器、保留已验证空闲门禁的基础上，继续拆解压力期约 11 MiB/秒的短命分配与 GC 块占用，降低压力池高水位；HTTP 子改动的精确峰值贡献仍需更充分重复/分配归因。不能仅凭本轮数据全局下调 GC 参数或切换业务。

原始采样、阶段诊断、构建审计、复现脚本和源码已归档，[文件摘要清单](./release-evidence/2026-11-09/gc-http-factorial/artifact-sha256.json)可核对完整性。

### 线程级分配归因与首处复制修复（2026-11-09）

- [x] 使用相同 `684281b1` 包，改做 20 秒基线、40 秒 HTTP、40 秒 Paseo、45 秒冷却的短诊断，不再构建整包或追加长测。按同一线程的函数进入/退出，将分配 API 请求字节归到函数范围；有效基线、HTTP、Paseo 记录窗口分别约 0.91、2.01、4.00 秒，全部零丢事件、零嵌套错序。范围外事件另按直接返回地址归因，不能称为已覆盖全部高层路径。见[结论与验证范围](./release-evidence/2026-11-09/gc-alloc-attribution/finding.json)及[线程级统计](./release-evidence/2026-11-09/gc-alloc-attribution/runs/08-scope-short/scope-analysis.json)。
- [x] HTTP 窗口记录 70441 次分配请求、约 8.99 MiB；分发函数范围含嵌套调用约占 26.16%，响应转换约 7.31%，应用请求日志链约 10.18%。这些包含关系不能相加。直接调用地址还确认了 veb 路由中两份约 8 KiB 上下文，以及响应转换、发送、保留阶段的约 7.4 KiB 响应体复制；它们属于明确的分配工作量，不是已证实的泄漏。
- [x] **修复一处确定可消除的复制：** `src/http_observation_runtime.v` 的 `complete_http_observation` 将同步只读参数改成 `&Context`。旧包调用点每次请求分配 8168 字节，窗口内 81 次、661608 字节，约占全部已记录请求量 7.02%。旧生产 C 会对按值传入的 Context 做 `memdup` 堆装箱；修改后生产 C 参数为指针，该 Context 复制消失。见[生成代码检查](./release-evidence/2026-11-09/gc-alloc-attribution/context-codegen-check.json)、[旧代码](./release-evidence/2026-11-09/gc-alloc-attribution/context-codegen-before.txt)、[新代码](./release-evidence/2026-11-09/gc-alloc-attribution/context-codegen-after.txt)和[补丁](./release-evidence/2026-11-09/gc-alloc-attribution/context-reference.patch.txt)。尚未构建或部署修复包，不能据此宣称 RSS 已降低。
- [x] Paseo 窗口记录 33521 次分配请求、约 3.73 MiB；`InProcVjsxHostApi.config_lookup` 27 次调用累计 2063043 字节，占 52.76%。源码每次 getter 都 `json2.decode[json2.Any]` 整份配置，然后沿路径查找；这是下一处明确的重复解析热点。不能用无界全局缓存处理，后续需按运行时/配置版本限定缓存和失效。该处本轮尚未改动。
- [x] 完整 GC/unmap 后，atomic 的 16、32 字节两类块合计驻留约 3.03 MiB，标记对象仅约 0.30 MiB，但零标记块数为 0。它们是稀疏的非空对象块，不能按整块空闲页归还。标记可能包含收集器缓存或保守假根，尚未证明每个保留引用的所有者，不能把标记量全部认作业务存活。见[回收后大小类别与驻留](./release-evidence/2026-11-09/gc-alloc-attribution/runs/08-scope-short/03-unmap-twice-blocks.json)。
- [x] 本轮仅修改上述 vhttpd 只读参数，未改 vlang/vjsx。macOS V 0.5.2 d13ccdd/cc 定向观察回归通过；Ubuntu VM 的 `/home/guweigang/v/v`、local-dev、相同 V 版本、GCC、`gc none` 定向回归通过，使用原生冻结 SDK/QuickJS，未切换或覆盖依赖。源码变更很小，但整体 `make test` 先被已有 `src/ws/hub_runtime.v` 回调 nil 默认值安全检查阻断；因此另行运行了实际定向测试，未声称全仓门禁通过。见[macOS 输出](./release-evidence/2026-11-09/gc-alloc-attribution/macos-observation-test.txt)和[Linux 输出](./release-evidence/2026-11-09/gc-alloc-attribution/linux-observation-test.txt)。
- [x] 明确保留失败记录：首次全栈流超过 128 MiB 文件预算并丢事件，仅用有效栈作路径线索，未用其计算占比；第二次因 perf 自动增加返回事件后缀，在压力前失败，未计入结论。有效运行校验实际事件名称，改用轻量事件后完成；所有本任务探针已清理。见[首轮失败](./release-evidence/2026-11-09/gc-alloc-attribution/runs/06-profile-short/driver-state.json)、[事件命名失败](./release-evidence/2026-11-09/gc-alloc-attribution/runs/07-scope-short/driver-state.json)和[有效运行](./release-evidence/2026-11-09/gc-alloc-attribution/runs/08-scope-short/driver-state.json)。这些诊断都保持原资源和主机保护限制，未中断业务。
- [x] bodytest PID 3730524/启动标识 39645663、包 SHA `0890d931` 保持，匿名内存 126.3 MiB、三个健康检查均为 200、连续监测 active。见[最终业务核验](./release-evidence/2026-11-09/gc-alloc-attribution/runs/08-scope-short/final-business-check.json)。
- [ ] P0-02 仍未关闭：分配 API 请求字节包含 realloc 的目标容量，不是净新增或保留内存；剖析也会影响吞吐。本轮没有逐对象代际到 GC 根的完整所有权证明，也没有修复包的 RSS/24 小时验收。接下来优先处理配置 getter 的重复解析，并按生命周期验证 veb 剩余复制；有具体分配改善后再构建候选包。

原始事件文本、符号表、脚本、源码与排除记录已归档；原始 perf 二进制在[远端数据摘要](./release-evidence/2026-11-09/gc-alloc-attribution/runs/raw-manifest.json)所列位置保留，[归档摘要](./release-evidence/2026-11-09/gc-alloc-attribution/artifact-sha256.json)可核验完整性。

### 配置 getter 有界缓存完成（2026-11-09）

本节推进上一节的重复解析热点；此前 HTTP Context 引用修复保留，业务仍未换包。

- [x] 已实现每个运行时独立的配置 getter 缓存：按原始配置内容变化失效，包含缺失键的缓存结果；最多 32 项、键和值合计 64 KiB，快照最多 256 KiB、路径最多 1 KiB，超限走原解析逻辑。只保留有界序列化字符串，不保留解析树或 JS Value。lane 销毁、构建失败时显式清空，关闭后不得重新保留数据；请求作用域检查仍先于缓存读取。正常 HTTP/Paseo 共用的持久 host.config 已接入，原生 WebSocket 回退解析路径仍不缓存。见[实现与验证范围](./release-evidence/2026-11-09/config-cache/finding.json)和[完整补丁](./release-evidence/2026-11-09/config-cache/changes.patch.txt)。
- [x] macOS 与 Ubuntu VM 的缓存边界及真实 JS 回调测试均通过，覆盖配置更新、负缓存失效、无效输入、运行时隔离、请求到期拒绝读取、并发读取及销毁清空。既有 embedded 请求回归在 macOS 通过。V 0.5.2 d13ccdd；Linux 使用 local-dev/GCC/gc none 与冻结原生 SDK/QuickJS。本轮未改 vlang/vjsx，未声称既有全仓门禁阻断已解除。见[macOS 输出](./release-evidence/2026-11-09/config-cache/macos-final-tests.txt)、[Linux 输出](./release-evidence/2026-11-09/config-cache/linux-tests.txt)、[既有请求回归](./release-evidence/2026-11-09/config-cache/macos-embedded-regression.txt)。
- [x] 三次独立进程微基准：13,222 字节配置、四条预热路径（含缺失键）、每组 1000 次读取。旧解析路径累计 GC 分配约 120,618,064–120,620,592 字节，新缓存路径 19,952–22,960 字节，减少约 99.98%，结果校验一致。测量的是预热重复 getter 的累计分配，不是净存活量、全 Paseo 吞吐或 RSS；冷读取仍解析并增加有界缓存负载。见[基准源码](./release-evidence/2026-11-09/config-cache/bench.v)和[三轮结果](./release-evidence/2026-11-09/config-cache/bench-results.json)。
- [x] bodytest PID 3730524、启动标识 39645663、包 SHA `0890d931` 保持；匿名内存 126.3 MiB、RSS 135.1 MiB、swap 为零，三个健康检查均为 200、连续监测 active。本轮仅做身份、状态与健康只读核验，未重启、换包或注入调试器。见[最终业务核验](./release-evidence/2026-11-09/config-cache/final-business-check.json)。
- [ ] **P0-02 继续阻断：** 尚未构建包含 Context 引用和 getter 缓存两处修复的整包，未验证实际压力驻留或冷却改善。下一步固定扫描器与工具链构建候选，先短测 HTTP/Paseo 的分配、RSS、匿名内存、GC 堆及自然冷却；之后再决定业务替换与正式 24 小时验收。本轮没有启动新长测，也未获得全业务或 Windows 放行。

[归档文件摘要](./release-evidence/2026-11-09/config-cache/artifact-sha256.json)包含源码、补丁、测试输出与基准结果。

### 两处分配修复整包对照完成（2026-11-10）

本节完成上一节的整包构建和独立短测；不将微基准的 99.98% 改善外推到整包或真实业务。

- [x] 已构建 amd64/Boehm 候选 `60da360c10cc76bc5f37c609b95dc275bec98f88c256f31cf7c491c31ef43faf`，对照包为 `684281b1`。在既有冻结 g1h1 源码上，仅加入 Context 引用、有界配置 getter 缓存及其测试；扫描器 `041e8955`、SDK `259620f1`、GC 对象 `d59d73ed` 和参数不变，不包含当前工作区其他并行变更。Linux VM 使用既有 local-dev/V 0.5.2 d13ccdd、原生 GCC 13 交叉工具链、O2/Boehm；本轮未新增 vlang/vjsx 补丁，已有 veb 活动钩子摘要与基线一致。见[结论和构建命令](./release-evidence/2026-11-10/hotpath-pair/finding.json)、[完整链接审计](./release-evidence/2026-11-10/hotpath-pair/packages/after/cross-audit.json)、[源码摘要](./release-evidence/2026-11-10/hotpath-pair/source-manifest.json)和[冻结候选源码](./release-evidence/2026-11-10/hotpath-pair/frozen-candidate-source.tar.gz)。
- [x] 沿用此前验证的两源码根、四运行时配置夹具，按旧→新→新→旧串行自然跑完，每轮全新进程和目录：预热后 30 秒基线、60 秒 HTTP、60 秒 Paseo、120 秒混合加压、180 秒自然冷却。夹具源码和请求为合成数据，未重放真实业务依赖。累计 HTTP 57452 次、Paseo 350 轮，零校验失败、无 OOM；HTTP 包含预期且校验通过的 503，不能称为所有响应均为 2xx。保持 256 MiB、30% CPU、无 swap、独立网络、640 MiB 稳定启动门槛及 512 MiB 主机保护；采样中主机余量最低约 765.2 MiB。四轮压力期间空闲回收尝试增量均为零；冷却中各自然触发两次。本轮没有调试器、注入辅助库或强制 GC。见[协议](./release-evidence/2026-11-10/hotpath-pair/manifest.json)、[逐轮统计](./release-evidence/2026-11-10/hotpath-pair/analysis.json)和[控制器完成状态](./release-evidence/2026-11-10/hotpath-pair/runs/controller-state.json)。
- [x] **分配改善可重复：** 两次均值中，HTTP 从 9.842 降到 9.210 MiB/秒（减少 6.43%），Paseo 从 1.727 降到 0.802（53.60%），混合从 11.396 降到 9.921（12.94%）。累计分配是工作量，不是净新增或保留内存；未把两个修复包的 RSS 差额全部归到某一函数。见[分配汇总及解释](./release-evidence/2026-11-10/hotpath-pair/finding.json)。

以下压力值取混合阶段末 30 秒中位数，冷却值取自然冷却末 30 秒中位数；完整各阶段、峰值和 GC 堆/空闲量在逐轮统计中保留。

| 包与轮次 | 混合分配 MiB/秒 | 压力 RSS MiB | 压力匿名 MiB | 冷却 RSS MiB | 冷却匿名 MiB |
| --- | ---: | ---: | ---: | ---: | ---: |
| 旧包 01 | 11.403 | 76.90 | 55.56 | 58.43 | 37.08 |
| 新包 02 | 9.938 | 73.37 | 46.25 | 62.96 | 35.83 |
| 新包 03 | 9.904 | 66.24 | 38.95 | 54.70 | 27.41 |
| 旧包 04 | 11.389 | 70.74 | 43.62 | 55.01 | 27.89 |

- [x] **驻留改善需限定：** 相邻 AB/BA 配对中新包压力匿名内存较低，但四轮区间有交叉；新包首轮甚至高于末轮旧包，不能保证每次 RSS 都更低。冷却匿名差额只有约 0.48–1.25 MiB；旧包压力到冷却回落 15.73–18.48 MiB，新包回落 10.41–11.54 MiB，回落量较小也包含压力起点较低的影响。压力末 GC 映射堆由旧包约 27.0–30.1 MiB 降至新包 21.0–22.4 MiB，冷却后均约 10.7–11.8 MiB；空闲量在持续分配和 GC 轮次中反复变化，堆得以复用。冷却中仍出现堆增长到门槛后再自然回落的周期；短测不能证明长期无泄漏。见[完整自然曲线](./release-evidence/2026-11-10/hotpath-pair/comparison.png)及[逐轮数据](./release-evidence/2026-11-10/hotpath-pair/analysis.json)。
- [x] **总 RSS 与匿名内存分开核对：** 自然结束时，首轮旧包文件页 21,860 KiB，末轮同 SHA 旧包 27,776 KiB；新包两轮为 27,772/27,944 KiB。独立进程 smaps 显示可执行文件与共享库的干净文件页；两包 text 段仅相差 2816 字节、rodata 反而减少 8928 字节。首轮约 5.8 MiB 文件页差额的具体触发因素尚未确认，不能称作匿名泄漏或代码膨胀。映射快照有各自采样时刻，不能代替尾段中位数。见[ELF 段大小](./release-evidence/2026-11-10/hotpath-pair/elf-sections.json)、[新包冷却映射](./release-evidence/2026-11-10/hotpath-pair/runs/03-after/cool-mapping.json)和[旧包冷却映射](./release-evidence/2026-11-10/hotpath-pair/runs/04-before/cool-mapping.json)。
- [x] bodytest PID 3730524、启动标识 39645663、业务包 `0890d931` 保持，匿名内存 126.3 MiB、swap 为零、三个健康检查均为 200，连续监测 active；最终主机余量约 855.5 MiB。四个测试进程全部退出，测试单元自然结束、exit 0、inactive。未替换、重启或调试业务，也未将候选效果计入当前业务。见[最终业务和收尾核验](./release-evidence/2026-11-10/hotpath-pair/final-business-check.json)。
- [ ] **P0-02 继续阻断：** 保留两处分配修复；下一优先项是已测得的剩余 HTTP Context/响应体复制，以源码、生成代码和短验证逐项推进。最终候选的真实业务内存收益、完整 24 小时与 Windows 验收仍缺失。本轮没有切换业务或启动新长测，也没有声称全仓门禁通过；此前 macOS/Linux 定向测试范围仍按上一节记录。

[文件摘要清单](./release-evidence/2026-11-10/hotpath-pair/artifact-sha256.json)可核对源码、构建/运行脚本、原始曲线和测试输出；原始 .log 归档为 .txt，转换关系保留在[日志文件名映射](./release-evidence/2026-11-10/hotpath-pair/log-name-map.json)。

### veb 响应体交接优化与生命周期验证（2026-11-10）

- [x] 本轮修改 vlang/veb 的 context.v、veb.v、veb_fasthttp.v、controller.v 四个生产文件及五处私有调用，新增两份回归测试。未修改 vjsx 或 GC 策略参数，也未改变 bodytest。保留调用者到响应的第一次复制；普通 Boehm 构建在交给 writer 时复用已知响应缓冲，消除第二次 body clone。见[补丁](./release-evidence/2026-11-10/response-handoff/owner-final.patch.txt)、[源码摘要](./release-evidence/2026-11-10/response-handoff/owner-source-manifest.json)与[结论及边界](./release-evidence/2026-11-10/response-handoff/finding.json)。
- [x] 生命周期采用真实强 owner 指针保留原缓冲到交接，防止直接替换 body 后地址复用误判；交接后清除源与 writer 的 owner 字段，源 body 及应用保留的别名继续有效。共享缓冲由 GC 管理，writer 不手动释放；未匹配原缓冲地址的 body（包括测试中的替换和偏移切片）走复制；同一缓冲起点的视图可继续共享 GC 缓冲。非 GC、prealloc、autofree、ownership 保留原复制分支。已撤回无条件移动和仅地址标记方案，不将中间版本结果算作最终验收。见[生成 C 摘录](./release-evidence/2026-11-10/response-handoff/owner-codegen-after.txt)、[生成代码核验](./release-evidence/2026-11-10/response-handoff/owner-codegen-proof.json)、[交接回归](./release-evidence/2026-11-10/response-handoff/response_writer_transfer_test.v)和[排除的实验](./release-evidence/2026-11-10/response-handoff/excluded-attempts.json)。
- [x] macOS/Boehm/OpenSSL 与 Ubuntu local-dev/GCC/gc none/OpenSSL 各五份定向测试通过，覆盖既有响应、中间件生命周期和静态 controller 回归；Linux 另以最终源码独立构建并运行 Boehm 交接及真实 fasthttp append 测试，运行限时 30 秒，编译前后源码摘要一致，退出均为零。append 测试覆盖 keep-alive/close、NUL body、重复 cookie 与保留别名的写后有效性。见[macOS 输出](./release-evidence/2026-11-10/response-handoff/macos-owner-final.txt)、[Linux 输出](./release-evidence/2026-11-10/response-handoff/linux-owner-final.txt)、[Linux Boehm 身份和结果](./release-evidence/2026-11-10/response-handoff/linux-owner-boehm-results.json)及[写出测试](./release-evidence/2026-11-10/response-handoff/response_writer_append_test.v)。
- [x] 三次独立进程、每种 body 每组 256 次交接的微基准中，8 KiB/64 KiB 响应每次约少分配同等大小的缓冲；基础 Context 实测从 7976 增至 7984 字节，仅增加一个指针，没有单独 owner 对象。指标为 GC_get_total_bytes 累计分配（含分配器取整），不是存活量、RSS 或自然冷却回收；两次 Context 分配、JS 到 V 字符串转换和网络序列化仍存在。见[原始结果](./release-evidence/2026-11-10/response-handoff/owner-bench-results.json)、[统计与限制](./release-evidence/2026-11-10/response-handoff/owner-bench-summary.json)、[基准源码](./release-evidence/2026-11-10/response-handoff/response_writer_allocation_test.v)和[复跑脚本](./release-evidence/2026-11-10/response-handoff/reproduce_benchmark.py)。
- [ ] autofree 尚未验收：测试启动器实验中止；直接运行既有中间件生命周期测试出现 Invalid header key，隔离的未修改基线也复现同类错误。根因未确认，不能据此宣称最终候选在 autofree 下无独立回归。见[基线对照](./release-evidence/2026-11-10/response-handoff/autofree-baseline-comparison.json)、[基线运行输出](./release-evidence/2026-11-10/response-handoff/autofree-baseline-path-run.txt)与[复现命令](./release-evidence/2026-11-10/response-handoff/commands.json)。
- [x] 北京时间 12:05 只读核验：bodytest PID 3730524、启动标识 39645663、业务包 SHA 0890d931 保持；匿名内存 129344 KiB（126.3 MiB）、RSS 138204 KiB、swap 为零，三个健康检查均为 200，监测 active。未换包、重启、调试或对业务加压。临时基准文件已清理，正式补丁和测试保留。见[业务核验](./release-evidence/2026-11-10/response-handoff/final-business-check.json)、[本地状态](./release-evidence/2026-11-10/response-handoff/final-local-state.json)和[Linux 工具链状态](./release-evidence/2026-11-10/response-handoff/final-linux-state.txt)。
- [ ] **P0-02 继续阻断：** 此补丁尚未构建成 vhttpd 整包，未获得整包匿名内存、冷却、真实业务、完整 24 小时及 Windows 验收。下一步在冻结候选中加入本补丁，先做独立短对照，确认兼容与驻留改善，再决定业务与长测。此次没有启动新长测，不能称为泄漏已经解决。

[本轮归档摘要](./release-evidence/2026-11-10/response-handoff/artifact-sha256.json)可核对最终补丁、测试和原始结果。

### 恢复上游 GC 源码与响应体优化整包验证（2026-11-10）

- [x] 按维护者建议恢复冻结 V d13ccdd 的上游 GC 源码：撤回 thirdparty/libgc/gc.c 的 GCC O2 pragma，gc.c 与该上游基线逐字节一致（SHA 71133692…），GC 启动代码也未修改。保留 shared 对象生命周期正确性修复和上一节四个 veb 文件的响应体交接优化；vjsx 未改。此前称“GC 策略调整”不够准确：实际源码改动是编译规避，脚本覆盖的三个值 1/7/0 恰好与上游 V/Boehm 的有效默认值一致。本轮删除全部 GC_* 环境覆盖，并只读核验独立进程的真实值仍为 1/7/0。Boehm C 初始 divisor=3 会被上游 V 初始化改为 1，不能只看 C 默认值。见[源码一致性](./release-evidence/2026-11-10/upstream-gc-handoff/upstream-source-check.json)、[撤回补丁](./release-evidence/2026-11-10/upstream-gc-handoff/gc-rollback.patch.txt)和[实际参数核验](./release-evidence/2026-11-10/upstream-gc-handoff/runtime-policy-probe.json)。
- [x] 新候选 SHA f6144d0928fd5bcea4b75277f018ce4dedad62259d41c6888ecf820b80fd4fc9 已构建并独立运行，实际 build-info 为 0.9.0/Boehm。沿用冻结 V、SDK、扫描器和 vhttpd 源码，加入上一节 veb 补丁；上游 gc.c 以原生 GCC 13 显式 O2 重建，没有复用旧 GC 缓存。未变更的 QuickJS 等原生对象复用且记录摘要。源码恢复不等于取消构建条件：本轮并未放行此前复现滞留的无保护 O3 构建。见[构建及链接审计](./release-evidence/2026-11-10/upstream-gc-handoff/packages/after/cross-audit.json)、[源码溯源](./release-evidence/2026-11-10/upstream-gc-handoff/source-provenance.json)、[候选元数据](./release-evidence/2026-11-10/upstream-gc-handoff/after-package-info.json)和[生成代码核验](./release-evidence/2026-11-10/upstream-gc-handoff/codegen-proof.json)。
- [x] 为分离 GC 重建与复制优化，另外用旧候选主程序对象链接与新候选完全相同的 GC 对象（7592c15d…），得到控制包 249bf929…。四轮顺序为旧主程序/旧 GC → 新候选 → 新候选 → 旧主程序/新 GC 控制包；**不是重复旧控制的 ABBA**，同 GC 控制仅一轮。首轮旧包 60da360c…单独保留，不能把它与新包的差额全部归于复制。见[控制包审计](./release-evidence/2026-11-10/upstream-gc-handoff/packages/control/cross-audit.json)和[协议修订](./release-evidence/2026-11-10/upstream-gc-handoff/protocol-amendment.json)。
- [x] 每轮自然完成预热后 30 秒基线、60 秒 HTTP、60 秒 Paseo、120 秒混合加压和 180 秒冷却；合成两源码根、四运行时拓扑，不是业务流量重放。累计 HTTP 57491 次、Paseo 352 轮，零校验错误、零 OOM；HTTP 包含按协议验证的 503。四轮压力期间空闲回收尝试均未增加，冷却中各自然触发两次；没有外部强制 GC 或调试器。保持 256 MiB、30% CPU、无 swap、独立网络、640 MiB 稳定启动门槛与 512 MiB 主机保护，采样主机余量最低 768.5 MiB。初次错误断言 divisor=3 的尝试在加压前退出，已排除并保留原始失败记录。见[逐轮统计](./release-evidence/2026-11-10/upstream-gc-handoff/analysis.json)、[运行协议](./release-evidence/2026-11-10/upstream-gc-handoff/manifest.json)、[启动参数](./release-evidence/2026-11-10/upstream-gc-handoff/launch-r2.json)和[断言更正](./release-evidence/2026-11-10/upstream-gc-handoff/default-value-correction.json)。
- [x] **分配收益可重复：** 同 GC 控制包 HTTP 为 9.221 MiB/秒，新包两轮均约 8.506–8.507，均值减少 7.75%；混合为 9.930 → 9.200–9.207，均值减少 7.31%。Paseo 仅约 0.61% 差异，不能宣称有显著收益。指标是累计 GC 分配量，不是存活或泄漏字节；也不能称为恢复默认参数的收益。见[结论与对照统计](./release-evidence/2026-11-10/upstream-gc-handoff/finding.json)。

以下均为各阶段末 30 秒中位数；短基线包含预热遗留，不能把冷却低于基线解释成“负残留”。

| 轮次 | 混合 RSS MiB | 混合匿名 MiB | 冷却 RSS MiB | 冷却匿名 MiB | 压力到冷却匿名回落 MiB |
| --- | ---: | ---: | ---: | ---: | ---: |
| 旧主程序/旧 GC | 75.57 | 48.75 | 55.40 | 28.58 | 20.17 |
| 新候选 1 | 62.89 | 36.21 | 52.35 | 25.68 | 10.54 |
| 新候选 2 | 83.46 | 56.69 | 55.05 | 28.28 | 28.41 |
| 旧主程序/同一上游 GC 控制 | 75.49 | 48.65 | 62.10 | 35.26 | 13.39 |

- [x] **驻留改善仍需限定：** 两轮新包的压力匿名区间跨过控制包，第二轮甚至高于控制，不能保证每轮 RSS 更低。第二轮较高的堆在加压期间由普通 GC 缩小，空闲块反复复用，冷却后大部分回落；其具体预热/驻留差异尚未完成归因，不能定性为泄漏或已确认的保守根问题。两轮新包冷却值较同 GC 控制低约 6.98–9.58 MiB，但只有一个控制样本，首轮旧 GC 包冷却也只有 28.58 MiB；因此保留分配优化，不把全部冷却差额算成确定收益。Boehm 映射堆不是驻留内存，不能直接从匿名内存相减就认定“堆外增长”。见[完整曲线](./release-evidence/2026-11-10/upstream-gc-handoff/comparison.png)和[逐轮原始数据与结束状态](./release-evidence/2026-11-10/upstream-gc-handoff/runs/controller-state.json)。
- [x] 13:01 只读收尾：四个独立测试进程均已退出，控制器 completed；journal 确认单元自然成功退出。成功的 transient 单元卸载后，systemctl show 返回默认限制，不能把它当作运行时限制；启动参数和运行时 memory.max 断言另存。bodytest PID 3730524/启动标识 39645663、包 SHA 0890d931 保持；匿名内存 129344 KiB（126.3 MiB）、RSS 140228 KiB、swap 为零，三个健康检查均为 200，连续监测 active，主机余量约 875.7 MiB。业务未换包、重启或接受本轮压力。见[业务及收尾核验](./release-evidence/2026-11-10/upstream-gc-handoff/final-business-check.json)、[单元日志](./release-evidence/2026-11-10/upstream-gc-handoff/unit-journal.txt)、[本地状态](./release-evidence/2026-11-10/upstream-gc-handoff/final-local-state.json)和[Linux 工具链状态](./release-evidence/2026-11-10/upstream-gc-handoff/final-linux-state.txt)。
- [ ] **P0-02 继续阻断：** 响应体优化已完成整包短测；当前仅证明分配收益与短期可回收性。两次约 8 KiB 的 Context 分配及驻留波动仍待定位，真实业务收益、完整 24 小时、Windows 与最终构建链路尚未验收；上一节 autofree 问题也未关闭。本轮未部署业务或启动新 24 小时，不以调 GC 参数替代生命周期与分配问题的定位。

[本轮证据摘要](./release-evidence/2026-11-10/upstream-gc-handoff/artifact-sha256.json)包含源码、编译/运行脚本、原始曲线与日志；[日志文件名映射](./release-evidence/2026-11-10/upstream-gc-handoff/log-name-map.json)记录 .log 到 .txt 的归档转换。

### Context 分配优化、业务映射归因与整包验证（2026-11-10）

- [x] 两个约 8 KiB 对象承担不同职责：应用 Context 可以被 handler 保留，writer 需要独立响应快照，不能直接合并或复用应用 Context。本轮仅改 vlang 的 veb_fasthttp.v，新增 response_writer_state_test.v：普通 Boehm fasthttp 路径用已有 make_state 钩子为每 worker 分配私有 writer 存储，应用 Context 仍每请求独立分配。正常、错误、接管及展开返回后清空存储的全部字节，避免长期保留请求引用；忙状态回退到独立分配。controller 保守禁用复用，TLS、render_request、nil state 及门控不允许的模式保留原 Context 构造式。所有权以 voidptr 地址身份判断，避免 V 对结构指针执行深比较。GC 策略及 vjsx 未改。见[源码与边界](./release-evidence/2026-11-10/context-lifetime/finding.json)、[最小补丁](./release-evidence/2026-11-10/context-lifetime/veb-state.patch.txt)、[回归源码](./release-evidence/2026-11-10/context-lifetime/response_writer_state_test.v)及[生成 C 核验](./release-evidence/2026-11-10/context-lifetime/codegen-proof.json)。
- [x] macOS/Boehm/OpenSSL 与 Ubuntu local-dev/GCC/gc none/OpenSSL 各六份定向测试通过：新状态生命周期、原响应体别名、中间件、controller/static、panic，以及真实持久连接和 reusable takeover。Linux 另以最终源码运行 Boehm 状态/并发与真实连接专项，运行各限时 30 秒，退出为零。覆盖保留整个应用 Context、32 次连续复用、四线程隔离、解析错误、独立错误 Context、文件路径、接管和忙状态。初版夹具返回栈上 routes 地址、对清零 map 调用 len 等失败未计入通过；对应生成 C 和排除记录保留。见[macOS 最终输出](./release-evidence/2026-11-10/context-lifetime/macos-final-regressions.txt)、[Linux 最终输出](./release-evidence/2026-11-10/context-lifetime/linux-final-regressions.txt)、[Linux Boehm 输出](./release-evidence/2026-11-10/context-lifetime/linux-final-boehm.txt)和[排除的实验](./release-evidence/2026-11-10/context-lifetime/excluded-attempts.json)。
- [x] 同补丁内 nil state 兼容分配路径与复用路径的最小 append 基准，三次独立进程按 AB/BA/AB 顺序，每种响应每组 256 次。0、1 KiB、8 KiB body 每请求少分配 7931–8053 字节，与少一份 7984 字节 Context 相符；每 worker 固定状态为 7992 字节。初始化/输出缓冲在测量外，局部基准在每组前执行 GC；这是累计分配（含取整），不是自然冷却或 RSS。临时基准源已从 V 树清理，正式测试保留。见[原始三轮](./release-evidence/2026-11-10/context-lifetime/final-bench-results.json)、[统计边界](./release-evidence/2026-11-10/context-lifetime/final-bench-summary.json)、[复跑脚本](./release-evidence/2026-11-10/context-lifetime/reproduce_benchmark.py)与[最终 V 状态](./release-evidence/2026-11-10/context-lifetime/final-vlang-state.json)。

#### bodytest 真实进程的只读映射定位

- [x] 13:39 快照：仍为业务包 0890d931/PID 3730524，匿名内存 126.3 MiB。编译同源、同宏的 GC 布局探针，只读取业务 GC 段表及 smaps/pagemap；22 段大小之和必须等于 collector heapsize，段表、轮次和计数保持稳定。混合匿名映射逐页只统计 present/anonymous 位，不提取或保存 PFN；分页总数须精确匹配 smaps，才接受分区。得到 **GC 管理段匿名驻留 90.3 MiB、段外匿名驻留 36.0 MiB**，不是用匿名内存减映射堆估算。段外包含原生堆、栈、GC 元数据、QuickJS 和库数据，尚不能全部称为 glibc 在用块，更不能直接归因 vjsx。见[原始映射及一致性校验](./release-evidence/2026-11-10/context-lifetime/body-mapping.json)、[布局探针](./release-evidence/2026-11-10/context-lifetime/gc_layout_probe.c)、[偏移和编译命令](./release-evidence/2026-11-10/context-lifetime/gc-layout.json)。
- [x] 同次一致快照中，GC 已映射堆 105.5 MiB、记录为空闲的已映射空间 33.9 MiB；按“非空闲映射最多全部驻留”保守估算，约 18.7 MiB 的 GC 驻留页已被记为空闲，但仍驻留。此前空闲为 87.1 MiB，而匿名内存同为 126.3 MiB，支持已有管理空间正被消耗复用。非空闲计数包含未收集垃圾等，不能当作业务存活量；这仍不是分配栈或保留根归因。监测脚本只读审计未发现 HTTP 健康轮询；业务未暴露新候选同名 idle_state，另有旧 last_activity/last_attempt 符号，未据此推断业务无空闲回收。未停止、重启、注入或触发业务 GC。见[内存分区解释和空闲估算](./release-evidence/2026-11-10/context-lifetime/body-memory-summary.json)、[此前快照](./release-evidence/2026-11-10/context-lifetime/body-mapping-earlier-pagemap.json)、[监测审计](./release-evidence/2026-11-10/context-lifetime/observer-read-audit.json)。

#### 完整候选的独立短测

- [x] 已构建 amd64/Boehm 候选 dca8844f0725b08e22d3a6ce5adf63ed51c9aaaceb5ce3360aaaba1dc9c61d9d，对照为 f6144d09…。vhttpd 冻结源码、SDK、扫描器、编译器及原生对象不变，仅加入上述 veb 优化；两包链接完全相同的上游 O2 GC 对象 7592c15d…。生成 C 另确认 App/AdminApp 实际注册并启用状态工厂。见[候选元数据](./release-evidence/2026-11-10/context-pool-package/after-package-info.json)、[链接审计](./release-evidence/2026-11-10/context-pool-package/packages/after/cross-audit.json)、[源码一致性](./release-evidence/2026-11-10/context-pool-package/source-manifest.json)和[工厂核验](./release-evidence/2026-11-10/context-pool-package/codegen-check.json)。
- [x] 单次旧→新串行对照自然结束，每轮 30 秒基线、60 秒 HTTP、60 秒 Paseo、120 秒混合、180 秒冷却，仍是合成四运行时拓扑，未重放业务依赖。累计 HTTP 28849 次、Paseo 176 轮，零校验错误、零 OOM；压力期间空闲回收尝试均为零，冷却各自然触发两次。保持 256 MiB、30% CPU、无 swap、独立网络、640 MiB 启动门槛及 512 MiB 主机保护；采样主机余量最低 788.9 MiB。新增阶段末只读映射采样有时间开销，不以本轮计数推断吞吐提升。见[逐轮统计](./release-evidence/2026-11-10/context-pool-package/analysis.json)、[协议](./release-evidence/2026-11-10/context-pool-package/manifest.json)、[运行中限制](./release-evidence/2026-11-10/context-pool-package/active-unit-properties.json)和[自然退出日志](./release-evidence/2026-11-10/context-pool-package/unit-journal.txt)。
- [x] **整包分配下降得到验证：** HTTP 累计分配速率约 8.486→7.800 MiB/秒，混合约 9.175→8.574（下降 6.55%）。考虑采样开销，在同一首末计数区间按已完成 HTTP 请求数归一化，约 111705→103737 字节/请求，减少约 7968 字节（7.13%），与微基准和生成代码相互印证。Paseo 仅约 1.07% 速率差异，不宣称显著收益。见[分配量、匹配计数区间和映射汇总](./release-evidence/2026-11-10/context-pool-package/finding.json)。

以下是各阶段末 30 秒中位数；基线在预热之后，尚不是充分稳定的空闲基线。

| 包 | 基线匿名 MiB | 混合 RSS MiB | 混合匿名 MiB | 冷却 RSS MiB | 冷却匿名 MiB |
| --- | ---: | ---: | ---: | ---: | ---: |
| f6144d09 对照 | 52.46 | 65.56 | 38.55 | 54.69 | 27.68 |
| dca8844f 候选 | 65.88 | 78.93 | 51.97 | 55.68 | 28.72 |

- [ ] **未证明驻留改善：** 新包本轮加压匿名内存反而更高，压力到冷却回落 23.25 MiB，旧包回落 10.88 MiB；冷却末仅相差约 1.04 MiB。阶段末精确分区显示，混合时 GC 管理段匿名驻留约 21.32→36.11 MiB，段外约 17.25→15.86；新包起始 GC 驻留也更大（约 35.75→51.27）。这将主要差额定位到 GC 段，而不是额外原生段增长，但尚不能认定由复用、启动垃圾或保守根中的哪一项造成。候选与对照冷却曲线接近，单对样本也不能证明长期无泄漏。见[完整曲线](./release-evidence/2026-11-10/context-pool-package/comparison.png)、[阶段映射](./release-evidence/2026-11-10/context-pool-package/runs/02-after/mixed-gc-mapping.json)及[GC 触发计数观察](./release-evidence/2026-11-10/context-pool-package/gc-trigger-comparison.json)；映射快照为阶段末单点，与上表中位数口径不同。
- [x] 14:19 收尾核验：两个测试进程均退出，单元自然成功结束；bodytest 包、PID/启动标识保持，匿名内存仍 126.3 MiB、swap 为零，三个健康检查 200，连续监测 active，主机可用约 879.8 MiB。业务没有换包、重启或承受本轮压力。见[最终业务及任务状态](./release-evidence/2026-11-10/context-pool-package/final-business-check.json)。
- [ ] **P0-02 保持阻断：** 每请求 writer 分配已降为每 worker 固定开销，分配收益通过整包校验；RSS 收益、真实业务候选运行、完整 24 小时、Windows 及完整门禁仍未验收。此处为 14:19 收尾的历史短测，当时未切换业务或启动 24 小时。之后已按本页 P0-02「当前收尾清单」完成候选应用验证和业务切换，并启动独立长测；完整结果仍待验收。

[源码与业务映射证据摘要](./release-evidence/2026-11-10/context-lifetime/artifact-sha256.json)和[整包证据摘要](./release-evidence/2026-11-10/context-pool-package/artifact-sha256.json)保留补丁、最终测试、生成代码、脚本、曲线与原始快照。








