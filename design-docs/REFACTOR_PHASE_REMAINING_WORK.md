---
title: Refactor Phase Remaining Work
tags:
  - refactor
  - runtime
  - v2-config
  - validation
status: draft
updated: 2026-10-23
---
# Refactor Phase Remaining Work

**最新验收候选为 `dc3767ca1d7d27cc4f9752ddc4827610cc060b46`（2026-10-24），远端仍未通过。** 已推送 [PR #21](https://github.com/guweigang/vhttpd/pull/21)，源码 tree `baa65922b72f1c2b495b9166b73aefe9af70e0fa`。[三平台 PR 检查](https://github.com/guweigang/vhttpd/actions/runs/39994907193) 与 [nightly 同构全量矩阵](https://github.com/guweigang/vhttpd/actions/runs/39994901630) 绑定同一新提交，独立重新执行全部 9+3 任务。最终仍须完整绿测及 15 份原始 artifact ZIP 的来源、摘要和测试计数核验，不拼接旧提交结果。

前一提交 `3323e0ee` 的 ARM PR 主任务及六项独立回归通过，但 Intel 全量在 TLS sender 夹具失败：端口文件已存在却尚未写入，读到空字符串，`wss://127.0.0.1:` 因而连接默认 443。两轮已取消，原失败日志与全部 13 份 ZIP 已保存并核验摘要，记录 `failure-3323-intel-full.log`、`attempt-3323-artifacts-proof.json`。现仅将该 Python 夹具的端口和帧结果改为同目录临时文件写完后原子替换。Mac 注入 150ms 写入延迟：原夹具复现同一 443 panic，修复后原 sender 回归通过，连接生命周期组 6/6、完整生产 E2E 配置 207/0 与 CLI 4/0、全部前置检查通过。超时和原断言不变，V/生产源码 824 文件及生产二进制均与 Mac334 快照一致；改动夹具的独立验证见 `tls-publication-validation.json`，新提交绑定见 `tls-publication-commit-binding.json`。

**本机 macOS ARM64 收尾通过记录（2026-10-23；远端最新状态见上方）。** 验收输入为批准的 V2/M4 基线 `ab6cd850d7d1743b00b5ee5af8021ba41b863694` 加本轮五个本地修复文件，补丁 SHA-256 `38e7f2ac1e21b248265eabc1962ebe0f37b775afd96e7b0e9726b8564c7e3a4d`；V 固定 `e21021d`，禁用旧编译器回退，依赖使用固定 vjsx/QuickJS 与仓库补丁。最终独立 `make test-all` **334/334、零失败、零跳过、退出码 0**，逐文件集合与预期 334 文件完全一致，覆盖 inproc 6、CodexBot fast 6 与 lifecycle 1。使用同一编译器及冻结生产源码的生产构建、完整生产 E2E **配置 207/0、CLI 4/0、全部前置检查**、PHP 包 **10/10**、Pest **79 项/557 断言**均通过。最终生产二进制 SHA-256 `3d1732db0b27cdc0cd50c46af5ad22c9d5fe36aa0599f2901df03feb6c344ddd`，824 个源码文件及 481 个暂存生产文件校验无漂移。

本轮修复：JS 回调捕获本地接口值，避免工厂返回后访问临时接口地址；插件退休映射缺失键显式解锁返回；worker 批次测试工厂显式返回 `&worker.WorkerState`，原断言保持。首次全量 259 项通过后遇到夹具编译失败的原日志及后续 75/75 排查结果均保留，最终 334/334 来自独立整轮，未拼接。完整证据及原始日志摘要见 `tmp/m5-remote-validation/mac-acceptance-complete.json`、`mac-final-inputs.json`、`mac-test-all.log` 与 `mac-production-e2e-final.log`。

**覆盖范围与剩余验收：** 本机主工作区在验收期间另有数据库/异步 fetch 并行改动，未纳入冻结候选；差异清单记录于 `mac-concurrent-workspace-differences.json`，本轮五文件修复已同步回工作区，其余并行工作保持原状。本次结果不能表述为当前整个主工作区已通过。Live DB 与安装态 WordPress opt-in 未启用；本机 PHP/Node 在长时间验收期间更新过，因此最终将 PHP 8.5.12 ZTS、Node 26.12.1、Python 3.15.0 与 Composer 2.9.2 固定到实际文件路径和摘要，重新执行 PHP、Pest 及完整生产 E2E，全部退出码为 0，执行文件摘要前后不变；记录见 `mac-native-runtime-exit.json`。未宣称这些原生运行时与远端环境完全相同。2026-10-24 用户已授权提交并恢复远端，初始五文件修复保留在 `3323e0ee`；TLS 夹具原子发布修复已推送为 `dc3767ca`，该新提交的 PR 与全量矩阵正在独立重跑。完整远端验收及自动 cron 观察仍未完成，M5 保持未关闭。

**前轮 cfda 记录（已因非本地类型方法定义失败取消）：** [本轮 PR 矩阵](https://github.com/guweigang/vhttpd/actions/runs/39944133414) 与 [本轮全量矩阵](https://github.com/guweigang/vhttpd/actions/runs/39944137424) 绑定同一提交。V/VC 仍固定为 `e21021d1`/`7ba7d3e`。前一候选已在 Linux 完成自举，随后首次两个全量测试编译失败：`config` 解析为标准库 `config.LoadOptions`，而非项目配置类型。原日志 `failure-c565-linux-full.log` 保留。现为所有 Make 编译入口明确指定模块路径：测试优先 `src`，生产优先移除测试辅助文件后的暂存源码树，再搜索 `@vlib`、`@vmodules`。Make dry-run 已核对两类入口的路径，实际编译仍以本轮矩阵为准；未恢复本机重型编译。

**前轮 c565 记录（已因配置模块解析失败取消）：** V 固定为包含三个已合并 PR 的 `e21021d1`，VC 更新至官方快照 `7ba7d3e44009617d70c849764f89415b1a517690`，其生成源 `ffc38ada` 是目标 V 的祖先；保留原 TCC 固定值和 vjsx 补丁，移除已由上游覆盖的 V 补丁。[新 PR 矩阵](https://github.com/guweigang/vhttpd/actions/runs/39942392144) 与 [新全量矩阵](https://github.com/guweigang/vhttpd/actions/runs/39942405068) 绑定同一提交。旧 VC 的 Linux 自举失败原日志及 10 份 ZIP 已保留并核验摘要。新 VC 的本地 bootstrap 因主机负载超过 400 而主动终止，只停止本任务编译，不记录为通过或编译器失败；以干净 runner 验证自举兼容性及完整矩阵。

**首轮恢复记录（c4e6，已失败并取消）：** 已核对 V #31046/#31047/#31048 全部合并；固定 V 到 `e21021d10433ad9fa7fd45fd63e2dee79ec612ef`，移除已覆盖的 V 本地补丁，保留 vjsx 补丁。候选 `c4e6d1c0f8081801d4b2652127060af3bce358c5` 的 [PR 检查](https://github.com/guweigang/vhttpd/actions/runs/39938948778) 与 [全量检查](https://github.com/guweigang/vhttpd/actions/runs/39938943526) 已重新启动；bootstrap、相关回归及最终矩阵结果仍待完成，不核销 M5。下方暂停记录与旧候选结果仅作历史证据。

This document records the remaining acceptance work after the v2 runtime/config refactor. The code refactor stages are treated as complete when the automated test matrix is green. The whole refactor goal is complete only after the product-level checklist below passes.

## 当前收尾验收（2026-10-22）

本轮 M5 CI 配置与本地验证已完成：PR 新增 Ubuntu 24.04、macOS 15 Intel/ARM 的 inproc/CodexBot fast 检查；nightly 于 03:00 UTC 执行三平台 V 全量（含 lifecycle）、PHP package/Pest、生产构建与完整 E2E，保存失败日志与工具链版本。V/vjsx/VC/TCC/QuickJS 固定提交并携带已验收补丁，action 固定 SHA，Node/Python/Composer 固定完整版本，PHP 固定 8.4 系列；PHP 实际补丁和 apt/Homebrew 库版本记录在 artifacts，未宣称完全密封构建。

本地 actionlint/shellcheck、YAML/触发/矩阵及安全检查通过；远端重新获取并构建固定工具链后 inproc 6/6、CodexBot fast 6/6 通过，PHP package 10/10、Pest 79 项/557 断言通过。证据 `tmp/m5-ci-validation/`。本地运行时与 CI 配置不同，Make 仅确认全量 334 个 V 测试包含 lifecycle，本轮未重跑整个全量或生产 E2E。**M5 的当前同提交完整远端矩阵尚未收齐，自动 cron 仍未观察，不核销远端验收；配置实现缺口已关闭。** Linux VM 仍因既存跟踪修改仅只读检查，M7 仍待处理；未扩展局部审查。

远端验收正在 [PR #21](https://github.com/guweigang/vhttpd/pull/21) 执行，用户已批准包含必要 V2/M4 基线。当前源码提交为 `f799afb43cff5de80dafda0c05792d97c187b787`，[PR 三平台矩阵](https://github.com/guweigang/vhttpd/actions/runs/39878141715) 与 [nightly 同构全量矩阵](https://github.com/guweigang/vhttpd/actions/runs/39878136180) 均已按用户要求取消，监视进程已停止；验收暂停，不核销。取消前五项独立回归通过，主 fast/全量/生产 E2E 未完成；快照及 artifacts 保存于 `tmp/m5-remote-validation/paused-acceptance.json` 和 `paused-f799-artifacts/`。恢复时先核对用户提交的 V 上游 [#31046](https://github.com/vlang/v/pull/31046)、[#31047](https://github.com/vlang/v/pull/31047)、[#31048](https://github.com/vlang/v/pull/31048) 的落地版本与现有补丁，重新冻结候选后再执行完整矩阵；由用户后续指令恢复。前一提交 `0ba72922` 两轮均因 Linux 队列生产 E2E 失败，原日志与全部 14 份 ZIP 已保留并核对；其 Linux fast 320/320、全量 334/334 零跳过、PHP 10/Pest 79、macOS 两平台及六项独立回归通过。修复只拆分成功与 2500ms 超时夹具、增加 hold 握手：注入 3 秒客户端延迟可复现原失败，修复后队列 29/29，完整本地生产 E2E 配置 207/0、CLI 4/0 及全部前置检查通过。新增两项用于确认独立超时 runtime 就绪及配置，生产超时默认值不变；新提交仍须完整远端矩阵通过。已处理真实验收失败：平台 TCC/GC、runner ripgrep、QuickJS 原生线程交接的 stack top、Linux `struct ucred` 特性可见性、固定编译器禁用非固定回退、PHP worker 基线遗漏及干净 Composer loader/auth 初始化；失败原日志/artifact 均保留。发布版与工作区选定的 1,433 个源码/配置一致，原二进制保留；干净发布目录 PHP 10/10 通过，具体证据与历史尝试见行动计划及 `tmp/m5-remote-validation/`。自动 cron 尚未进入默认分支，本轮手动调用相同 reusable 矩阵，不冒称已经观察到定时触发；M7 未启动。

以下保留前轮 M4 与候选 E 的验收记录：

V2 配置和运行时主体的既有验收结果保留在下方历史状态中。候选 E 的前轮 macOS 全量 332/332、PHP 与生产 E2E 通过证据继续保留。本轮（2026-10-22）已完成 M4 日志统一：移除硬编码 trace 文件与 emit 双写，保持原事件字段、统计和默认文本/WARN 契约，新增可选 stderr JSON、早期配置失败日志及写失败诊断。logging/ws 15/15、相关运行时 4/4、生产模式日志回归 1/1 及完整生产 E2E（新增日志契约 3 项、配置 205/0、CLI 4/0）通过。**V2 整体验收仍未关闭，剩余 Linux 与 M5/M7；M4 实现及本轮 macOS 验收已核销。** 详见 [重构行动计划](REFACTOR_ACTION_PLAN.md)。

M4 最终证据为 `tmp/m4-logging-validation/`，输入清单 SHA-256 `b3bd410575557e93b99e632dfc3eb4eaac856a8c273bb55e8d6a7916001bcedf`；生产源码/二进制及 V 回归输入相同，最终仅修正新 E2E 对 stdout/stderr 的测试通道假设（`production-equivalence.json`）。源码、工作区与冻结依赖校验无漂移，原二进制保留。曾有一次外部创建凭证请求超时，原样独立回归及完整生产 E2E 复跑通过，原因未确认，原超时和断言未放宽。前轮 E 的完整矩阵证据位于 `tmp/v2-closeout-acceptance-validation/`，不作为本轮重跑全矩阵的声明。Linux 只读预检仍有既存跟踪修改，按技能停止规则未构建或测试；M5 CI 扩展与 M7 V1 弃用/默认配置仍待完成或明确调整范围。Live DB/安装态 WordPress 与长期负载未在本轮验收中启用。

## 历史状态（2026-07-04）

- Stage 7 runtime isolation and module closure: code-complete.
- Automated test matrix: green as of 2026-07-04. Re-verified `make test`, `make test-inproc`, `make test-codexbot-fast`, `make test-codexbot-lifecycle`, and `make test-e2e` after the provider hook observability and acceptance-status updates.
- Latest acceptance verification: `bash tests/e2e/config_acceptance_test.sh` passed on 2026-07-04 with 194 config-acceptance checks green; `VHTTPD_E2E_DB_LIVE=1 VHTTPD_E2E_DB_PASSWORD=... VHTTPD_E2E_WP_ROOT=/Users/guweigang/wwwroot/wordpress bash tests/e2e/config_acceptance_test.sh` passed on 2026-07-04 with 215 checks green against local MySQL plus the installed WordPress/WooCommerce site, including provider websocket hook admin visibility.
- Product-level acceptance: complete for the current refactor acceptance scope.
- Completed acceptance slice: automated config smoke now covers V1 basic compatibility, V2 simple pipeline dispatch, V2 missing-reference diagnostics, multi-site listener/pipeline routing with admin plan visibility, WordPress V2 worker/static/security/REST OPTIONS routing with response-cache cookie behavior, HTTP protocol transform dispatch through native/vjsx implementations with transformer snapshots, hot replacement, and replacement event visibility, relay happy path/reconnect/fail-fast behavior with runtime/admin visibility, V2 WebSocket dispatch startup/probe/admin/log visibility, installed WordPress wp-admin/admin-bar static asset routing, V2 provider runtime/admin visibility for Codex and Feishu, provider-action dispatch through configurable vjsx provider runtime with hot replacement, provider event ingress pipelines for externally pushed provider events, provider instance add/update through admin APIs, MCP runtime/admin snapshots, DB/cache runtime snapshots on independent admin port plus data-plane admin modes, live MySQL query smoke, real PHP cache socket operations, upload-completed and generic event pipeline dispatch, PHP worker stream-dispatch SSE, and controlled worker busy/queue/full/timeout/release-cleanup visibility.

Validated automated commands:

- `make build`
- `make test`
- `make test-inproc`
- `make test-codexbot-fast`
- `make test-codexbot-lifecycle`
- `make test-e2e`
- `bash tests/e2e/config_acceptance_test.sh`

## Completed Baseline

The following refactor tracks are covered by code changes and automated tests:

- Baseline and v1 compatibility coverage.
- V2 config model: resources, adapters, transforms, pipelines, listener binding, and runtime-plan projection.
- Pipeline/route/adapter projection and capability diagnostics.
- Relay descriptors, sessions, channels, carriers, agents, inbound/outbound delivery, and wire behavior.
- Native and vjsx transformer runtime paths.
- Provider registry, provider bootstrap, command executor, worker backend, Codex runtime, Feishu runtime, and in-proc vjsx runtime.
- Runtime isolation: module-owned constructors, runtime hubs, split runtime replacement, and domain-specific startup runtime.

## Unified Remaining Acceptance Checklist

Run this checklist before declaring the whole refactor goal complete.

Progress markers:

- Completed: the acceptance item is covered by automated smoke and the remaining checks are either done or tracked elsewhere.
- Partial: the first automated slice passes, but listed checks still remain.
- Pending: no product-level smoke has passed yet.

### 1. V1 Compatibility Smoke

Purpose: prove compatibility paths still work while v2 adoption is rolling out.

Progress: Completed for the current smoke scope. `tests/e2e/config_acceptance_test.sh` now starts a generated v1 config, serves a vjsx request, and verifies `server.started`. Compatibility-only fallback ownership is documented below.

Checks:

- Start one legacy/v1 config successfully.
- Serve a basic HTTP request.
- Confirm compatibility-only fallbacks are documented with owner and removal condition.

Compatibility fallback owner and removal condition:

- Owner: `src/config/v1_plan_compat.v` owns legacy-to-V2 projection for `[worker]`, `[executor]`, `[[routes]]`, legacy assets, DB/cache, and upload-completed compatibility.
- Boundary: runtime modules consume the compiled `RuntimePlan`; they must not branch on legacy config shape.
- Removal condition: remove the fallback only after shipped examples and downstream deployments have migrated to `version = 2` resources/adapters/transforms/pipelines, and after a release note names the last supported legacy config version.

Related stages: Stage 1, Stage 2.

Acceptance signal:

- `src/config/v1_plan_compat_test.v` passes.
- One legacy config starts and serves a request.

### 2. V2 Simple Site Smoke

Purpose: prove the new config model works without compatibility fallback.

Progress: Completed for the current smoke scope. `tests/e2e/config_acceptance_test.sh` now starts a generated v2 config and verifies basic pipeline dispatch plus trace-id propagation. It also verifies missing adapter, transform, listener, and resource references fail startup with a non-zero CLI exit and emit clear `runtime_plan_unresolved_ref` diagnostics. `src/config/runtime_plan_loader_test.v` also scans repository V2 example TOML files, rejects legacy v1-only sections such as `[worker]`, `[executor]`, and `[[routes]]`, and verifies the examples load without compatibility fallback.

Checks:

- Start one simple v2 TOML config.
- Confirm resources, adapters, transforms, pipelines, and listener binding load as expected.
- Confirm diagnostics are clear when a pipeline references a missing adapter, transform, resource, or listener.
- Audit example config style so it does not mix v1/v2 concepts like a patch stack.

Related stages: Stage 2, Stage 3.

Acceptance signal:

- Real v2 TOML loads without compatibility fallback.
- Basic HTTP pipeline dispatch succeeds.
- Missing-reference diagnostics identify the unresolved resource ref.
- Admin/runtime diagnostics expose the selected pipeline and resources.

### 3. WordPress V2 Smoke

Purpose: validate the real showcase workload against v2 config and runtime boundaries.

Progress: Completed for the current smoke scope. `tests/e2e/config_acceptance_test.sh` now starts a generated WordPress-shaped V2 config against a temporary WordPress root, runs a real PHP worker through `examples/wordpress/app.php`, verifies `/meta` framework metadata and missing-`wp-config.php` install detection without DB, serves `wp-content` and `wp-includes` assets through static pipelines, applies asset cache-control, denies core PHP files through the security pipeline, verifies REST OPTIONS/CORS response headers through a fixed-response pipeline, verifies the front page reaches the worker redirect path, checks admin plan visibility for WordPress pipelines, preserves trace IDs for worker/static requests, and validates response-cache behavior for anonymous requests, `wordpress_test_cookie` ignore, and `wordpress_logged_in_*` bypass. With `VHTTPD_E2E_DB_LIVE=1` and the installed WordPress/WooCommerce root, the live smoke verifies forwarded HTTPS scheme handling for worker-generated URLs, canonical redirects for home/cart/checkout/REST, static routing for core, wp-admin, and admin-bar assets, cache bypass headers/event visibility for WooCommerce cart cookies, and set-cookie cache bypass headers for installed worker responses. Deeper browser UI walkthroughs are tracked as follow-up product validation rather than blockers for this automated refactor acceptance slice.

Checks:

- Start the WordPress-shaped example using v2 config without requiring a real database.
- Verify HTTPS scheme in PHP/worker-generated URLs.
- Verify logged-in admin bar assets, static assets, cart, checkout, and REST API loopback.
- Verify response cache headers and logged-in cookie bypass behavior.
- Confirm WordPress-specific behavior stays in config or `VHttpd\WordPress`, not generic runtime modules.

Related stages: Stage 2, Stage 3, Stage 6, Stage 7.

Acceptance signal:

- Generated WordPress V2 smoke passes, and installed WordPress pages/admin flows work under v2 config.
- No generic vhttpd runtime module contains WordPress-specific compatibility logic.

### 4. Multi-Site Smoke

Purpose: prove pipeline is the site-level composition unit and multiple sites bind correctly.

Progress: Completed for the current smoke scope. `tests/e2e/config_acceptance_test.sh` now starts one vhttpd process with two HTTP listeners, verifies each listener selects its own pipeline, checks `x-vhttpd-pipeline`, confirms per-site trace IDs appear in the event log, verifies the admin plan exposes the expected pipeline/listener state, and verifies `/admin/runtime` on the independent admin port aggregates listener plus pipeline route summaries for both listener-bound apps.

Checks:

- Start one vhttpd process with two listeners or site bindings.
- Verify each site resolves the correct pipeline/resources.
- Verify trace IDs identify the correct listener/site path.
- Verify admin/runtime snapshots expose site/listener/pipeline state clearly.

Related stages: Stage 2, Stage 3, Stage 7.

Acceptance signal:

- Two sites serve different configured behavior from one process.
- Logs/events make the selected listener, site, and pipeline clear.

### 5. Relay Smoke

Purpose: prove configured relay works in a real two-process topology.

Progress: Completed for the current smoke scope. `tests/e2e/config_acceptance_test.sh` now starts public relay and local agent processes, verifies a request reaches the local agent and returns, checks public relay runtime descriptor/carrier visibility, checks the agent admin plan exposes the relay pipeline, verifies disconnected-agent requests fail fast with 503 plus `relay_carrier_unavailable` response headers while preserving trace/error observations, verifies successful and reconnect relay requests preserve trace IDs in the public event log, restarts the agent, and verifies public relay delivery recovers after reconnect.

Checks:

- Start public relay and local server processes.
- Verify a request flows through relay and returns to the caller.
- Stop/restart the local server and verify reconnect behavior.
- Verify backpressure behavior under interrupted or slow local server.
- Verify relay delivery includes trace IDs and useful admin snapshots.

Related stages: Stage 3, Stage 4.

Acceptance signal:

- A request reaches the local server through relay and returns.
- Relay admin/runtime snapshots show carrier, agent, channel, and session state correctly.

### 6. Protocol Conversion Smoke

Purpose: prove transforms are configurable protocol/runtime units, not hardcoded paths.

Progress: Completed for the current smoke scope. `tests/e2e/config_acceptance_test.sh` now validates the same HTTP `/convert` ingress through native and vjsx transform implementations by TOML-only selection. It also verifies vjsx transform failure status, `x-vhttpd-error-class`, thrown-handler failure reporting as `502`, thrown-handler `transport_error` headers, trace-id propagation for both failed and thrown transforms, failed-transform error-class event visibility, admin transformer snapshots, event-log handler failure observations, admin plan visibility for transform pipelines, and replacement observability through `runtime.plan.replaced` plus post-replacement trace IDs. The smoke also starts a V2 WebSocket listener/pipeline using `websocket_dispatch`, verifies a Node WebSocket probe receives `sync` then `pong`, confirms `/admin/runtime/websockets` exposes the closed connection state, and checks service-log trace/listener completion visibility. Relay ingress is covered by the relay smoke; timeout/invalid-output failure cases remain tracked as broader protocol coverage, not blockers for the current HTTP/WebSocket conversion smoke.

Checks:

- Configure HTTP/WebSocket or relay ingress through a transform pipeline.
- Run once with native transform and once with vjsx transform.
- Switch transform implementation by TOML only.
- Validate failure reporting for transform errors, timeouts, and invalid output shape.

Related stages: Stage 3, Stage 5.

Acceptance signal:

- Same ingress request succeeds with native transform and vjsx transform by config-only switch.
- Failed transform emits actionable error and keeps trace/request IDs.

### 7. Event and Upload Completion Pipeline Smoke

Purpose: prove non-request/response ingress paths use the same pipeline model.

Progress: Completed for the current smoke scope. `tests/e2e/config_acceptance_test.sh` now starts a V2 upload route with `adapter:upload`, routes `upload.completed` through an event pipeline with a vjsx transform, verifies upload acceptance, verifies `upload.completed.dispatch`, records the transform id, and preserves trace IDs. It also dispatches a generic `inventory.changed` event through `/admin/runtime/events`, selects the configured event pipeline, runs the vjsx transform, records transform metadata, and preserves trace IDs. PHP worker stream-dispatch also has unit coverage and e2e verification through worker `open`/`next`.

Checks:

- Trigger an upload-completed event pipeline.
- Trigger at least one generic event ingress pipeline.
- Confirm the event can dispatch to native/vjsx logic as configured.
- Confirm trace IDs are preserved from event creation through dispatch.

Related stages: Stage 3, Stage 5, Stage 6.

Acceptance signal:

- Event pipeline dispatch succeeds without legacy handler fallback.
- Logs/events show upload/event id, pipeline id, engine/transform id, and trace id.

### 8. Provider and Worker Runtime Smoke

Purpose: prove runtime providers and worker dispatch behave under real startup/load conditions.

Progress: Completed for the current smoke scope. `tests/e2e/config_acceptance_test.sh` now starts a V2 config with configured Codex and Feishu adapters, verifies provider registration through `/admin/providers` and `/admin/providers/specs`, verifies the Codex runtime snapshot through `/admin/runtime/codex`, verifies the Feishu runtime snapshot through `/admin/runtime/feishu` on both independent admin port and data-plane admin modes, verifies provider runtime visibility through `/admin/providers/runtimes`, confirms both provider pipelines appear in `/admin/runtime/plan`, upserts and updates a dynamic Codex provider instance through `/admin/runtime/provider-instances`, verifies the instance snapshot, confirms the snapshot reflects desired-state updates, and preserves trace IDs for provider baseline/upsert/update requests. It also verifies provider-action dispatch through a configured vjsx provider runtime, confirms the configured capability reaches the runtime, exposes provider runtime entities in `/admin/runtime/plan`, previews provider runtime reloads, applies lightweight runtime-plan replacement, verifies provider-action trace events, and verifies the replaced provider runtime handles subsequent requests. Provider-pushed event ingress is now represented as `provider:<name>` pipeline ingress; the smoke verifies `provider:feishu` event dispatch selects the provider pipeline, runs the configured transform, preserves trace IDs, and exposes configured websocket protocol plus hook methods through `/admin/providers/runtimes`. The same script also starts MCP-enabled, DB-enabled, and cache-enabled configs; verifies `/admin/runtime/mcp` exposes max sessions, pending-message limit, session TTL, invalid sampling-policy normalization, and data-plane admin visibility; verifies `/admin/runtime/plan` exposes MCP sampling-policy diagnostics; verifies MCP HTTP DELETE without `Mcp-Session-Id` returns the `missing_session_id` error class after allowed-origin validation; verifies `/admin/runtime/db` exposes enabled state, socket, driver, and idle ping on both independent admin port and data-plane admin modes without requiring a live database query; verifies `/admin/runtime/cache` exposes enabled/started state, socket, and key count on both admin modes; and runs the PHP cache client through real `ping/set/get/exists/keys/delete` operations against the vhttpd cache socket. It also starts a real PHP worker pool, verifies a baseline request, observes an in-flight busy worker through `/admin/workers`, verifies queue capacity/timeout in `/admin/runtime`, and confirms trace-id preservation for the busy request. `src/worker_backend_runtime_test.v` now covers the deterministic queued-selector timeout path, including wait/timeout counters and queue-depth cleanup. A dedicated controlled-worker fixture now covers true-concurrent queue success, queue-full rejection, queue-timeout response, error-class headers, timeout counters, release-time queue-depth cleanup, served-request visibility, and trace/event-log observations. Live DB query smoke passed again behind `VHTTPD_E2E_DB_LIVE=1` against local MySQL on 2026-07-04 as part of the 215-check live acceptance run, verifying the DB socket serves a real query and `/admin/runtime/db` records query count plus trace ID.

Checks:

- Run real provider startup with configured Codex, Feishu, and DB/cache where available.
- Verify provider instance add/update paths through admin/runtime APIs.
- Confirm worker queue behavior under busy workers and request bursts.
- Confirm no request is dispatched to a busy worker incorrectly.

Related stages: Stage 6, Stage 7.

Acceptance signal:

- Provider instances appear in admin snapshots with correct source/static/dynamic state.
- Busy workers queue, timeout, or reject according to configuration.

### 9. Observability Smoke

Purpose: prove the runtime is inspectable as a generic gateway.

Progress: Completed for the current smoke scope. The automated config smoke checks trace-id propagation across V2 HTTP dispatch, multi-site listener/pipeline routing, WordPress worker/static requests, native/vjsx transform dispatch, relay, WebSocket dispatch service logs, provider runtime baseline dispatch, provider-action dispatch/replacement, provider instance admin upsert/update, upload-completed event dispatch, PHP worker stream dispatch, and worker busy-state handling. It also verifies admin plan visibility for multi-site/protocol/relay/provider/WordPress pipelines, admin WebSocket closed-connection state, admin transformer snapshots for native/vjsx transforms, relay runtime descriptor/carrier visibility, provider runtime snapshots for Codex and Feishu, provider ingress event pipeline/transform trace observations, DB/cache runtime snapshots on both independent admin port and data-plane admin modes, provider instance snapshots and update trace events, MCP missing-session DELETE error-class headers, upload event transform dispatch metadata, response-cache store/hit/bypass observations with bypass reasons including installed set-cookie bypasses, cache socket operation counters, and worker runtime queue/busy snapshots. Controlled worker queue-full and queue-timeout failures are now observable through error-class headers, admin runtime counters, trace IDs, and event-log entries. Broader protocol/relay backpressure coverage remains useful follow-up work, but it is outside the current HTTP/WebSocket-focused refactor acceptance smoke.

Checks:

- For every smoke scenario above, confirm logs/events include `trace_id`.
- Confirm request, provider, pipeline, listener/site, relay, worker, and transform identifiers are present where relevant.
- Confirm admin snapshots expose runtime state without source-code knowledge.

Related stages: all stages.

Acceptance signal:

- A user can follow one request/event from ingress to egress using trace id and runtime snapshots.

### 10. Boundary and Documentation Cleanup

Purpose: prevent the refactor from regressing into App-level or product-specific coupling.

Progress: Completed for the current refactor scope. `src/refactor_contract_test.v` passes and guards the key boundaries: generic runtime builders do not special-case WordPress, `app_runtime_builder.v` constructs runtime hubs through module-owned constructors, startup is split by domain runtime, runtime-plan replacement uses projection builders, and legacy upload/provider fallbacks are compatibility-only. Configuration concepts are documented in `docs/CONFIGURATION_MODEL_V2.md` and `docs/PROTOCOL_PIPELINE_RELAY_ARCHITECTURE.md`, including resources, listeners, adapters, transforms, relays, policies, pipelines, multi-site listener binding, and the rule that native V and VJSX transforms are interchangeable implementations behind the same pipeline boundary.

Checks:

- Keep opportunistic cleanup only when it creates a real module boundary; avoid thin wrappers that merely rename `app.providers.x` access.
- Review test fixtures for repeated hand-built internals, but do not block acceptance on fixture cleanup.
- Keep guardrails focused on behavior and ownership, not naming preferences.
- Tighten docs so users understand resources vs pipeline vs listener/site binding.

Related stages: Stage 2, Stage 7.

Acceptance signal:

- `src/refactor_contract_test.v` passes.
- Production code paths use runtime builders/hubs for construction and plan projection.
- No new catch-all App hook or mixed runtime file replaces split modules.
- Config concept docs describe entity resources separately from the site-level pipeline composition.

## Definition of Done

The refactor is fully done only when:

- The automated test matrix is green.
- The unified acceptance checklist above passes.
- Example configs are updated to idiomatic v2 concepts.
- Compatibility-only fallbacks are documented with owner and removal condition.
- No product-specific logic leaks into generic vhttpd runtime modules except through configuration or product-specific package code.
