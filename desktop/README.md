---
title: Mac 本地工作台使用与验收
description: ui2 Mac 工作台第一版的运行、配置发布、失败恢复与验收方式。
tags:
  - desktop
  - ui2
  - macos
  - acceptance
---
# Mac 本地工作台（第一版开发者预览）

宿主使用 V/ui2 原生窗口，负责项目、进程、日志和配置版本；浏览器 Admin UI 负责编辑、校验、发布和运行观测。第一版以 macOS 本地开发者预览交付，职责见[工作台设计](../docs/管理功能/本地开发工作台设计.md)。

## 下载、安装与首次打开

兼容构建目标为 Apple Silicon（arm64）、**macOS 15.0（Sequoia）及以上**。宿主、运行程序及包内每个动态库均按实际 Mach-O 最低版本检查，超过 15.0 的候选包会被拒绝，App 声明同步写入 `LSMinimumSystemVersion`。同一份 CI 源码构建候选包已在 GitHub 的 macOS 15.7.9 和 26.6.2 arm64 runner 上通过解压、搬移、新建、失败重试、配置发布、重启生效及恢复回归，见[目标系统运行证据](./ci/results/39132490236/verification.json)。这是两个真实目标系统虚拟机上的自动化运行验证；Finder、GUI 控件和浏览器交互尚未完成目标系统验收，本机 macOS 27 的原生手动验收也不能替代这些环节。两个目标系统的 Gatekeeper 策略评估均拒绝当前 ad-hoc 包，仍需 Developer ID 签名和公证。Intel Mac、实体 Mac 默认设置下的首次安装尚未验证；macOS 14 及以下不在当前目标范围。实现见[依赖封装](./package_macos.py)与[安装包检查](./verify_macos_release.py)。

1. 解压 `vhttpd-workbench-macos-arm64-0.1.0.zip`，得到 `vhttpd-workbench.app` 和 `安装说明.txt`。
2. 把整个 `.app` 拖入“应用程序”或自己的“应用程序”目录；保留完整包，不要只复制其中的可执行文件。建议先放到固定位置，再创建或导入项目。
3. 在 Finder 中打开应用。无需运行安装脚本、构建命令或先打开终端。包内包含 vhttpd、Admin UI、品牌素材和所需非系统动态库；内置两个 vjsx script 模板不要求安装 V、Node、npm、Homebrew 或 Xcode。导入使用其他执行器、原生扩展或外部服务的项目，仍需其对应依赖。
4. 打开后按下文“第一次使用”创建项目；源码保存到自己选择的可写目录，与 `.app` 分开。

**系统首次打开限制：** 当前包仅有 ad-hoc 签名，没有 Developer ID 签名和 Apple 公证。下载隔离检查可能阻止打开，因此“无开发环境依赖”不等于“已保证所有 Mac 下载后直接放行”。本机系统分发评估显示安全检查已关闭，不能用于证明 Gatekeeper 放行；未修改系统安全设置，也未清除下载隔离标记。正式面向其他用户分发仍需签名、公证，并在另一台保持默认安全设置的干净 Mac 上验证真实下载后的首次打开。不建议为使用预览版关闭系统安全检查。

## CI 构建与目标系统验收

交付候选包由[GitHub Actions 源码构建流程](../.github/workflows/workbench-macos-runtime.yml)生成：macOS 15 arm64 构建完整 `.app` 与 zip，记录 SHA256 后保存为 CI 构建产物；macOS 15 和 26 的独立 runner 下载同一候选包，再执行[系统工具验收脚本](./ci/verify_installed_macos.sh)。不将开发机的 App 或 zip 提交到源码仓库。

构建阶段使用[固定工具链提交](./ci/toolchain.env)和[兼容补丁](./ci/prepare_toolchain.sh)，测试阶段使用全新 HOME、仅系统 PATH，并禁止验收进程读取原用户目录、源码 checkout、Homebrew 或执行编译工具。目标系统运行失败时保留该 runner 的环境记录及日志。Finder 打开、GUI 控件、浏览器交互与 Gatekeeper 下载放行单独记录，不以 CLI 回归代替。

正式签名候选包通过手动 `release_mode=signed` 进入 `macos-release` Environment，完成 Developer ID 签名、Apple 公证、App 票据装订及两个系统的下载策略检查。所需证书、Team ID、API Key 或 Apple ID Secrets，以及当前未完成项见[Mac 签名与公证配置](../docs/管理功能/Mac签名与公证配置.md)。没有凭据时不会降级生成已公证包。

## 从源码构建（仅开发者）

安装预编译包不需要以下步骤。开发构建需要 PATH 中可用的 V 和仓库编译依赖；脚本以 `-prod` 构建运行程序和宿主，使 `$embed_file` 资源实际进入二进制，最后生成带安装说明的 zip。运行程序使用隔离的临时源码目录，不覆盖仓库根目录已有的 vhttpd：

```bash
./desktop/build.sh
./desktop/run.sh
```

ui2 固定到 [ui2.commit](./ui2.commit) 中的版本。已有依赖 checkout 的版本不符或含源码修改时，构建会拒绝覆盖。构建先完成新包，再替换旧包，不原地截断正在运行的可执行文件。

[兼容依赖锁](./macos-dependencies.json)记录 macOS 15 arm64 的官方 Homebrew bottle URL 与 SHA256；[隔离依赖工具](./macos_dependencies.py)下载、核验到项目 `.deps/macos-sequoia`，不会安装、升级或替换系统 Homebrew。构建首次需要联网，后续复用校验通过的缓存。编译器显式设置部署目标并重定向依赖搜索路径；生产包仍带齐所需动态库，用户无需执行这些开发步骤。

## 第一次使用

1. 打开后点击“新建 vjsx 项目”，选择 HTTP 入门或 JSON API 模板、项目名称与存放目录。保留“创建后立即启动，并打开浏览器 Admin UI”即可一次完成创建与启动。
2. 宿主等待管理认证和业务监听就绪，随后打开默认浏览器自动登录；无需复制 token，token 不进入 URL。可点击“访问业务服务”验证真实响应。
3. 在 Admin UI 的“项目配置”修改常用表单；高级选项使用来源 TOML。先“保存并校验”，通过后“发布配置”。修改覆盖主配置及全部 include 的整项目校验。
4. 宿主自动显示“待重启生效”。查看差异，或点击“重启并生效”；宿主完成后自动检查整个项目，并打开默认浏览器重新登录 Admin UI。重启仍会轮换实例凭据，无需复制 token。
5. 总览查看监听、路由、执行器和近期请求；慢请求明细可关联宿主完成日志及配置来源。宿主关闭时停止自己启动的实例，关闭浏览器不会停止服务。
6. “版本历史”可查看脱敏差异、预览并恢复所选已生效版本；项目未运行时也可恢复。恢复后继续整项目校验与生效检查，需要重启时会明确提示。

入口与行为见[宿主界面](./main.v)、[新建项目](./create_project.v)、[浏览器交接](./host/browser_login.v)、[生效状态](./host/config_status.v)、[配置恢复](./host/config_rollback.v)和[Admin UI](../admin/ui/common-config-ui.js)。

项目登记默认保存在 `~/Library/Application Support/vhttpd-workbench/projects.json`，版本历史保存在同目录的 `recovery/`。升级时可迁移当前开发 checkout 的旧登记，不移动项目源码。历史按本机文件权限保存，包含恢复所需的原始配置内容，不加密；界面差异对敏感字段脱敏。需保管好本地文件。实现见[登记](./host/project.v)与[历史存储](./host/recovery_store.v)。

## 升级、移除与数据位置

升级前先退出工作台，再替换整个 `.app`；无需移动项目目录或重新安装开发工具。安装包旁的 `安装说明.txt` 同时保存在应用的 `Contents/Resources/` 中，可离线查看。第一版不自动更新。

源码位于创建时选择的目录，登记与历史位于上文 Application Support 目录；替换或移除 `.app` 不会自动删除这些数据。需要彻底移除时，先确认项目和恢复历史已经备份，再由自己决定是否删除数据目录。历史包含原始敏感配置，不能仅依据界面脱敏就把数据文件公开分享。

## 遇到失败

- 名称非法、目录存在或不可写：按表单提示更换名称或目录。已有项目文件不会覆盖；文件已创建但登记失败时，保留目录并通过“导入已有项目”重新登记。
- 运行程序缺失：使用左侧“选择 vhttpd…”；项目目录被移动时重新导入。正常独立包已包含运行程序。
- 端口占用：停止由自己管理的占用服务，或在配置中改端口后重试；工作台不会接管或结束其他进程。
- 启动失败：查看项目下方日志。冷启动等待上限为 90 秒；停止超时后提供需确认的“强制停止”，仅针对本次进程组。
- 校验不通过：修正提示后再次校验，发布按钮不会提前启用。发布失败应先重新读取并核对外部修改；不会以接口失败推断配置已生效。
- 浏览器登录失效或自动打开失败：从宿主“打开浏览器”重新建立自动登录；不需要寻找或复制运行 token。正常重启完成后宿主会自动打开并登录 Admin UI。

失败与清理逻辑见[进程管理](./host/manager.v)、[后台循环](./host/worker.v)和[模板生成](./host/templates.v)。

## 验证

交付构建会先验证候选 zip，再替换上一份 `.app` 和 zip。也可独立复跑安装包检查：

```bash
python3 desktop/verify_macos_release.py desktop/bin/vhttpd-workbench-macos-arm64-0.1.0.zip
```

该检查从 zip 解压到仓库外含空格的目录，核对签名、arm64、动态库相对路径、最低系统版本与离线说明；随后使用全新 HOME、仅系统工具的 PATH，禁止读取开发目录、Homebrew 和 V 模块，并禁止执行 Xcode 编译工具，运行两个真实模板及启动失败后重试流程，执行跨 include 发布、待重启、重启生效及持久化恢复检查，并验证 32 个并发首次草稿请求不会因创建目录竞争而失败。它验证开发环境独立性，不模拟另一台 Mac，也不代表 Gatekeeper 已放行。见[安装包回归](./verify_macos_release.py)。

使用构建好的应用直接执行真实主流程检查：

```bash
desktop/bin/vhttpd-workbench.app/Contents/MacOS/vhttpd-workbench --smoke
desktop/bin/vhttpd-workbench.app/Contents/MacOS/vhttpd-workbench --persistent-status-smoke
```

第一项验证真实 vjsx 语法错误导致的初始化失败、失败实例回收及修正后同项目重试，并验证两个模板的创建、登记、认证就绪、业务响应、Admin UI、正常停止与端口释放；第二项验证跨 include 发布、待生效、重启检查、脱敏版本比较、重新创建宿主管理器后的离线恢复与历史记录。夹具使用规范化的临时路径并清理自己启动的实例，支持在仓库外的完整包副本上执行。见[主流程回归](./smoke.v)与[发布恢复回归](./status_smoke.v)。

```bash
v -enable-globals -path "$PWD/desktop|$PWD/src|@vlib|@vmodules" test desktop/host
v -enable-globals -path "$PWD/desktop|$PWD/src|$PWD/.deps|@vlib|@vmodules" test desktop/ui_state_test.v
node --test tests/admin-ui/*.test.cjs
```

[界面回归](./ui_state_test.v)直接验证 ui2 元素树，覆盖空列表、新建、运行、待生效、失败、历史、恢复以及重启返回工作台；防止重复元素标识导致白屏或状态冻结。详细验收见[Mac 第一版验收记录](../docs/管理功能/Mac工作台第一版验收.md)。

## 第一版边界

同时管理一个本地实例；不接管外部服务。第一版主路径为 vjsx HTTP 项目与本机 HTTP 管理监听。常用配置表单之外保留源码编辑。近期指标和慢请求样本有内存保留上限；内嵌 vjsx 的独立执行超时尚未采集，不能把未采集显示为零。Windows/Linux、WebView、自动更新、后台常驻和崩溃后接管不属于本版验收范围。