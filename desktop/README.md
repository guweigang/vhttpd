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

兼容构建目标为 Apple Silicon（arm64）、**macOS 15.0（Sequoia）及以上**。宿主、运行程序及包内每个动态库均按实际 Mach-O 最低版本检查，超过 15.0 的候选包会被拒绝，App 声明同步写入 `LSMinimumSystemVersion`。同一份 CI 源码构建候选包已在 GitHub 的 macOS 15.7.9 和 26.6.2 arm64 runner 上通过解压、搬移、新建、失败重试、配置发布、重启生效及恢复回归，见[目标系统运行证据](./ci/results/39132490236/verification.json)。这是两个真实目标系统虚拟机上的自动化运行验证；Finder、GUI 控件和浏览器交互尚未完成目标系统验收，本机 macOS 27 的原生手动验收也不能替代这些环节。两个目标系统的 Gatekeeper 策略评估均拒绝当前 ad-hoc 包；当前沿用 aidatastudio 的 unsigned 预览交付方式，不要求 Apple 证书，不将此策略拒绝混同为运行失败或自动放行。Intel Mac、实体 Mac 默认设置下的首次安装尚未验证；macOS 14 及以下不在当前目标范围。实现见[依赖封装](./package_macos.py)与[安装包检查](./verify_macos_release.py)。

1. 解压 `vhttpd-workbench-macos-arm64-0.1.0.zip`，得到 `vhttpd-workbench.app` 和 `安装说明.txt`。
2. 把整个 `.app` 拖入“应用程序”或自己的“应用程序”目录；保留完整包，不要只复制其中的可执行文件。建议先放到固定位置，再创建或导入项目。
3. 在 Finder 中打开应用。无需运行安装脚本、构建命令或先打开终端。包内包含 vhttpd、Admin UI、品牌素材和所需非系统动态库；内置两个 vjsx script 模板不要求安装 V、Node、npm、Homebrew 或 Xcode。导入使用其他执行器、原生扩展或外部服务的项目，仍需其对应依赖。
4. 打开后按下文“第一次使用”创建项目；源码保存到自己选择的可写目录，与 `.app` 分开。

**系统首次打开限制：** 当前包仅有 ad-hoc 签名，没有 Developer ID 签名和 Apple 公证。下载隔离检查可能阻止打开，因此“无开发环境依赖”不等于“已保证所有 Mac 下载后直接放行”。本机系统分发评估显示安全检查已关闭，不能用于证明 Gatekeeper 放行；未修改系统安全设置，也未清除下载隔离标记。正式面向其他用户分发仍需签名、公证，并在另一台保持默认安全设置的干净 Mac 上验证真实下载后的首次打开。不建议为使用预览版关闭系统安全检查。

## CI 构建与目标系统验收

交付候选包由[GitHub Actions 源码构建流程](../.github/workflows/workbench-macos-runtime.yml)生成：macOS 15 arm64 构建完整 `.app` 与 zip，记录 SHA256 后保存为 CI 构建产物；macOS 15 和 26 的独立 runner 下载同一候选包，再执行[系统工具验收脚本](./ci/verify_installed_macos.sh)。不将开发机的 App 或 zip 提交到源码仓库。

构建阶段使用[固定工具链提交](./ci/toolchain.env)和[兼容补丁](./ci/prepare_toolchain.sh)，测试阶段使用全新 HOME、仅系统 PATH，并禁止验收进程读取原用户目录、源码 checkout、Homebrew 或执行编译工具。目标系统运行失败时保留该 runner 的环境记录及日志。Finder 打开、GUI 控件、浏览器交互与 Gatekeeper 下载放行单独记录，不以 CLI 回归代替。

**当前无需 Apple 配置，直接使用默认 `release_mode=unsigned`。** 在成功运行的 Actions 页面下载 `workbench-macos-arm64-unsigned-verified`：它只在 macOS 15/26 两个系统均通过后生成，包含原始安装 zip、SHA256SUMS、acceptance.json 和验收说明.txt，保留 14 天。`workbench-macos-arm64-candidate` 是供 CI 验收使用的中间产物。可在下载目录执行 `shasum -a 256 -c SHA256SUMS` 核对安装 zip，再按上述步骤解压完整应用。

如系统阻止首次打开，先核对来源和校验值，再由用户本人决定是否在“系统设置 → 隐私与安全性”针对本应用选择“仍要打开”；受管理设备可能不允许。无需安装开发环境，不提供关闭全局安全检查或清除隔离标记的安装步骤。Finder、目标系统 GUI 与浏览器操作尚未由 CI 自动化验收。

手动 `release_mode=signed` 及 `macos-release` Environment 保留为后续可选路径，当前不执行或要求配置。未来需要签名公证时再参照[Mac 签名与公证配置](../docs/管理功能/Mac签名与公证配置.md)。

## 按 tag 发布 Mac 下载包

[发布工作流](../.github/workflows/workbench-macos-runtime.yml)监听 `v` 开头的 SemVer tag，例如 `v1.2.3` 或 `v1.2.3-rc.1`。先把这些构建与发布改动合入准备发布的分支并提交，确认当前提交就是要交付的源码；未提交的工作区修改不会进入 tag 或安装包。再创建并推送实际版本 tag，以下版本号只是示例：

```bash
release_tag=v1.2.3
git tag -a "$release_tag" -m "vhttpd $release_tag"
git push origin "refs/tags/$release_tag"
```

CI 从该 tag 的源码构建 unsigned 包，包名、App 内版本与离线安装说明使用同一版本号；带预发布后缀的 tag 自动生成 GitHub Pre-release。App 的系统版本字段采用数字部分，完整版本另存 `VHTTPDReleaseVersion`。流程不需要 Apple Secrets，也不需要新增发布 PAT，只有最后的发布任务具有内置 `GITHUB_TOKEN` 的 `contents: write` 权限。普通分支、PR 和手动验收不会公开 Release。

macOS 15/26 下载同一 zip 并完成隔离运行验收后，才允许准备 Release 附件。发布阶段还会核对包 SHA256、验收源码提交、App 版本和安装说明，并在上传前及公开前再次核对远端 tag 未被移动。先创建 Draft，上传成功后再公开；中断后可重跑同源码 tag 的本流程 Draft，已公开版本和无关 Draft 不覆盖。需要修正已公开版本时使用新 tag。

以 `v1.2.3` 为例，Release 包含：

- `vhttpd-workbench-macos-arm64-1.2.3.zip`：两版本实际验收过的原始安装包，不在发布阶段重新构建。
- `vhttpd-workbench-macos-arm64-1.2.3-INSTALL-zh.txt`：可在打开 App 前阅读的安装和首次使用说明，zip 内也有中文说明。
- `vhttpd-workbench-macos-arm64-1.2.3-SHA256SUMS.txt`：覆盖 zip、安装说明及验收附件。
- 同前缀的 `acceptance.json` 和 `ACCEPTANCE-zh.txt`：源码、系统版本、通过范围与 Gatekeeper 限制。

从 Releases 下载 zip、安装说明和校验文件到同一目录。可用下面的命令校验已下载的附件，确认输出中包含安装 zip 的 `OK`；若 zip、说明和两份验收附件均已下载，可去掉 `--ignore-missing` 做完整校验：

```bash
shasum -a 256 -c vhttpd-workbench-macos-arm64-1.2.3-SHA256SUMS.txt --ignore-missing
```

公开 Release 使用 GitHub 的常规 Release 资产下载入口；CI Artifact 仍保留 14 天供预览。公开发布不改变 unsigned 包的系统首次打开限制，详见上述安装说明。实现见[版本解析](./workbench_version.py)、[发布门禁与附件](./ci/macos_release.py)和[失败场景回归](./ci/test_macos_release.py)。

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

## 远端服务器与运行环境

左侧“远端服务器 · SSH”登记服务器，只填写 SSH 主机、用户、端口和认证方式，不要求预先部署 vhttpd，也不要求 Admin Token。密码和首次主机指纹确认沿用下文的 SSH 连接规则；密码仅用于本次认证，不落盘。服务器登记独立保存在本机权限保护的 `remote-servers.json`，与实例连接、共享 Relay 分开。实现见[服务器会话与安装](./host/remote_servers.v)和[原生界面](./remote_servers.v)。

1. 点击“添加服务器”，选择密码或密钥，保存并连接；首次连接核对工作台展示的指纹。
2. 点击“管理此服务器运行环境”，或在“管理运行环境”选择本机 Mac / 已登记服务器。连接成功后显示远端 Linux 架构、实际运行版本和安装目录。
3. 尚未安装时，可下载官方 Release 完整包；没有正式 Release 或该架构附件时，可选择官方 GitHub CI 的 `vhttpd-linux-amd64.tar.gz` / `vhttpd-linux-arm64.tar.gz`，同名 `.sha256` 放在旁边。CI Artifact 外层 zip 需先解压。安装前在本机校验 SHA256、归档路径和文件类型，上传后再次校验；运行程序实际可执行且 Admin UI 完整才提交安装。运行包由[CI 构建](../.github/workflows/vhttpd-binaries.yml)，不上传开发机构建包。
4. 安装位置固定为 SSH 用户的 `~/.local/share/vhttpd-workbench/runtime`；使用用户权限，无需 sudo、V、Node、Python 或编译工具。远端需有 OpenSSH/scp、POSIX shell、tar、base64、sha256sum 等基础系统工具，并兼容构建包的 Linux/glibc；架构正确不代表任意发行版都兼容。第一版不覆盖升级已安装运行包。
5. 选择内置 vjsx 模板、实例名称和不同的业务/Admin 端口，点击“创建、启动并打开 Admin UI”。项目位于同一目录下的 `instances/<名称>`；自动生成并保存 Admin Token，使用 `--manual-restart` 脱离 SSH 启动，再通过 SSH 回环转发自动登录和检查整个项目的生效状态。初始业务与 Admin 均只监听远端 127.0.0.1，不自动对公网开放。失败时保留项目与私有实例记录；排除端口占用后用原名称和端口重试，不覆盖配置。

服务器连接复用本次已认证的 SSH 会话；断开或退出 Desktop 会释放本机转发，远端实例继续运行。重新打开后可先连接服务器，再从“已运行实例”选中实例，复用服务器会话打开 Admin UI。当前同时连接一台服务器和一个实例；Windows/Linux Desktop、systemd、Docker/Compose、远端升级适配不在本次范围。

[隔离 Linux 部署验收记录](./ci/results/remote-deploy-20261024/verification.json)覆盖空 HOME、完整 ELF 依赖、运行包校验、vjsx 创建启动、浏览器一次性登录、两份 include 校验发布、手工重启、整项目生效、SSH 会话复用、首次指纹取消/确认、指纹变化拦截，以及真实端口冲突后原实例重试。该记录来自本机 Mac 管理器连接 OrbStack ARM64 Linux，与公开 Release 或 GitHub CI 运行记录分别对待；本次没有触发 GitHub CI，也没有公开上传本机构建包。复验入口为[部署驱动](./ci/verify_remote_deploy_linux_vm.py)和[宿主测试](./host/remote_servers_test.v)，给驱动传入 Linux 完整运行程序、私有 sshd 工具路径及已编译的 Mac host 测试。

## 通过 SSH 管理远端实例

“远端服务器”页中的“已运行实例”继续支持连接自行部署的 vhttpd；手动添加这种实例时才需要已有的 Admin 端口和 Token。Desktop 自动创建的实例已保存这两项。连接另一个实例会关闭旧转发，远端进程继续运行。当前支持 Mac Desktop + 系统 OpenSSH + 手工进程重启；Windows/Linux Desktop、systemd、Docker/Compose 保留后续适配边界。

1. 远端使用包含工作台管理 API 的 vhttpd，配置独立的回环 Admin 监听和非空 Token；若允许 Desktop 重启，在原启动命令增加 `--manual-restart`。未启用时仍可连接并编辑配置，重启按钮明确禁用。已有旧进程需要由所有者先以此方式启动一次，Desktop 不替换程序或猜测原启动命令。
2. 在 Desktop 添加实例，选择“密码登录”或“密钥 / SSH 配置”。支持已有 SSH Host 别名、用户、端口、可选私钥和系统 ssh-agent；用户名和 SSH 端口留空时沿用 SSH 配置。首次遇到未知主机，工作台会展示主机、密钥类型和 SHA256 指纹；通过服务器管理员或可信渠道核对后，点击“信任此主机并连接”继续，由系统 SSH 保存信任记录，取消则不保存。不需要先到终端确认指纹。已有记录发生指纹变化时显示红色提示并阻止连接，不发送密码、不自动覆盖原记录；需先通过可信渠道核对变更原因。交互式 MFA 暂不支持，带口令的私钥需预先解锁到系统 ssh-agent。
3. 填写远端 Admin 端口和 Token，点击“保存并连接”。隧道只绑定本机 127.0.0.1，访问的是远端 127.0.0.1 的管理端口；不要求将管理端口公开到网络。界面显示远端实际版本、平台、项目主配置来源、业务就绪状态和配置是否待生效。
4. 点击“打开 Admin UI”自动登录。Desktop 的本机代理使用独立的一次性 POST 票据和 HttpOnly 会话，浏览器登录交接不包含管理 Token，Token 不进入登录 HTML、URL 或跳转地址；代理在转发请求时添加认证头。授权后的项目配置编辑仍沿用原有敏感字段处理。代理检查 Host、Origin 和会话，并禁止浏览器调用远端进程重启 API。
5. 在原 Admin UI 编辑、整项目校验并发布，可同时修改多个 include。回到 Desktop 查看“配置已发布，待远端重启后生效”，点击“重启并检查生效”。远端先重新校验完整项目和目标文件摘要，再执行显式启用的手工重启；新进程需业务就绪、启动标识变化，已加载版本与整个项目磁盘版本同时匹配，且现有整项目运行计划对比确认无待生效变更，才报告生效。
6. 断开连接、切换连接或退出 Desktop，只关闭隧道和本机浏览器入口，远端继续运行。重新连接后查询实际状态，不依赖浏览器 Cookie 或本地项目路径。

手工重启助手由远端当前可执行文件启动，继承原进程的工作目录、参数和环境，脱离原终端，等待旧进程完成清理；不通过历史 PID 杀进程。新进程日志写入项目旁私有的 `.var/vhttpd/workbench/` 目录，操作记录和短暂存在的启动描述文件使用当前用户权限保护；启动描述可能包含原命令行参数，使用后删除，不加密。日志仍需由实例所有者按项目的保密要求保管。

重启使用操作编号避免重复执行。SSH 中断或等待超时后显示结果待确认或无法确认，继续查询，不自动再次重启；重新连接后可核对实际配置版本。若修改了远端 Admin Token 或管理监听端口，应更新此处连接后再检查。启动失败、预热未完成或配置再次变化不会报告成功。当前不提供 SSH 终端、远端文件浏览器、远端日志流及本地恢复历史；这些不影响 Admin UI 原有配置来源编辑、整项目校验和发布。如果重启后的进程直接退出或管理端口不可达，需要实例所有者到远端终端修复并启动，再重新连接；第一版不从完全失联状态重新拉起服务。

连接记录保存在本机 `remote-instances.json`，文件权限为 0600，Token 不加密，输入隐藏；请勿公开分享数据目录。SSH 私钥只记录路径，不复制内容。SSH 密码仅在当前连接流程中经私有内存通道交给系统 SSH，不写入连接记录、命令行、环境变量或诊断日志；提交连接、切换认证方式或取消时清空输入，重连需重新输入。主机确认和密码 helper 都使用 App 自带的同一个可执行程序。包使用 macOS 自带 SSH，不新增 V、Node、Python 或 Homebrew 等最终用户依赖。

实现见[远端连接与状态](./host/remote_instances.v)、[本机认证代理](./host/remote_proxy.v)、[原生界面](./remote_instances.v)、[远端手工重启](../src/admin_remote_control.v)和[回归](./host/remote_instances_test.v)。

本次开发验收（2026-10-24）：

- macOS 27 上用系统 OpenSSH 客户端及独立回环测试端点跑通密钥、密码认证、首次指纹取消/确认、信任记录保存、重连不重复确认和指纹变化拦截。密码测试端点使用仅测试依赖 Paramiko，最终用户不需要安装。确认前、指纹变化拦截后都未发送密码，取消或变化时不改写信任记录；使用的都是测试专用 known_hosts，未改动系统或用户的 SSH 配置。同时通过一次性登录、两份 include 一起发布、远端手工重启、整个项目运行计划与文件版本确认、业务响应变化、重复操作编号保护、重连和错误 Token。[主机指纹验收记录](./ci/results/ssh-host-key-20261024/verification.json)保存本次范围与限制。
- 完整 Mac 包通过解压搬移、签名和库路径检查、新建与启动失败重试、配置发布与恢复、运行包安装，以及全新 HOME、仅系统 PATH、禁止读取开发目录和执行编译器的沙箱验收。最低系统声明及所有二进制的构建目标仍为 macOS 15.0；不等于本次新增 SSH 功能已在 macOS 15/26 实际运行。
- [SSH 验收脚本](./ci/verify_remote_ssh_macos.py)已接入 Mac CI 的构建阶段，针对包内的运行程序执行；本次尚未触发新版源码的 GitHub CI。开发者可先编译上述 host 回归文件，再给脚本传入 `--runtime` 和 `--host-test` 执行。
- Linux VM 已按用户要求对齐 CI：V `890d55b`、bootstrap `bcfdc7f`、vjsx `eabab0f`，使用仓库版本化补丁及固定 QuickJS。旧 V 完整保存在 `/home/guweigang/v-local-dev-20261024-6b0886a`，原 `local-dev` 的 10 个本地提交保留；旧 vjsx checkout 也保留。GCC、`gc none`、禁用缓存的 `build` 和 `prod` 完整服务构建及真实 SSH 验收通过；4 组进程测试、4 项配置/重启回归和超时终态竞争回归通过。Mac 管理器通过远端工作区 API 读取配置，未把 Linux 路径当本地文件；两份 include 发布后，新启动标识、整个项目版本与运行计划同时确认生效，断开 SSH 后同一个新进程继续服务，实际 vjsx 请求也通过。见[验收证据](./ci/results/linux-ssh-20261024/verification.json)和[Linux SSH 验收驱动](./ci/verify_remote_ssh_linux_vm.py)。

### Linux VM 复验方式

当前 VM 的活动编译器为 `/home/guweigang/v/v`，处于 CI 固定提交的 detached HEAD；Git 中的修改仅为 CI 的 WebSocket 补丁。vjsx 模块指向原生 Linux 磁盘中的固定 checkout，并应用同一兼容补丁。兼容补丁回移植了上游 `d76f52c` 加入的 `RuntimeHostAsyncCompletionPort.timeout()` 公开接口；它复用已有超时终态与首个完成仲裁机制。该方法在开发机的新 vjsx 中已经存在，此前固定快照缺少这个接口，并非源代码丢失。

开发验收使用 GCC、`-gc none` 和 `-nocache`；Linux ARM VM 的此项结果不作为 Boehm GC 或 Windows/Linux Desktop 的验收。完整构建命令记录在上述 JSON 证据中。V 在更换目录后需于最终安装路径重新自举，避免标准库仍指向临时目录；后置工具也显式使用相同 GC/缓存设置。

Mac 端先编译 host 测试，再运行 Linux VM 验收驱动：

```bash
VJS_QUICKJS_PATH="$PWD/.deps/quickjs" v -w -d build_quickjs -enable-globals \
  -path "$PWD/desktop|$PWD/src|$PWD/.deps|@vlib|@vmodules" \
  -o /tmp/vhttpd-remote-host-test desktop/host/remote_instances_test.v
python3 desktop/ci/verify_remote_ssh_linux_vm.py \
  --runtime /home/guweigang/vhttpd-linux-e2e/vhttpd \
  --sshd-tools /home/guweigang/vhttpd-ssh-test-tools-20261024/root \
  --host-test /tmp/vhttpd-remote-host-test
```

Linux 测试程序旁按正常运行包布局放置 `admin/ui/`，从独立临时项目目录启动，而不是以源码仓库作为工作目录；production 重启后的原工作目录和环境变量保留均通过。源码中的 Admin UI 资源不应被误当成项目目录必备文件。

测试服务端来自 Ubuntu 官方 `openssh-server`、`libwrap0` 包的私有解压目录，不安装或启用系统 SSH 服务。驱动生成私有主机密钥和客户端密钥，仅监听 VM 的 127.0.0.1，通过已有 Orb SSH 命令传输连接到独立的 Linux OpenSSH；实际认证和端口转发由 Linux OpenSSH 执行。结束后清理自己启动的 sshd、vhttpd 和临时项目，用户 SSH 配置保持原样。

## 共享远端 Relay 连接

左侧“远端 Relay”维护可跨项目复用的连接库。新建连接时填写名称、Hub 的 WebSocket 地址、远端 Relay ID 和 Token。Relay ID 必须与远端 Hub 配置一致；Token 独立填写，地址不接受认证信息或查询参数。Token 输入隐藏，本地 `shared-relays.json` 使用仅当前用户可读写的权限保存，不加密；请勿公开分享数据目录。

“测试连接”依次检查网络、TLS（wss）、WebSocket 升级和 Relay 认证，显示失败阶段与耗时。探测使用独立的认证 ping/pong，既不注册业务 Agent，也不替换已有连接；远端需要包含安全探测支持的 vhttpd。旧版服务等待超时会显示认证或协议不匹配提示，不回退到普通注册。测试通过只代表本次探测成功，不表示项目已连接。

先保存连接、启动所选项目，再点击“在项目中使用”。Desktop 自动登录 Admin UI，交接的是尚未发布的独立草稿，项目源码此时不变。可在 Admin UI 选择主配置或 include 来源、绑定 Pipeline、启用自动连接，再保存校验和发布；继续使用整项目校验、宿主待重启提示、重启后的生效检查。每次交接生成独立 Node ID；项目已有同名 Relay 时提示编辑原配置。修改或删除连接库条目不会改动已有项目。

实现与回归见[连接库](./host/shared_relays.v)、[安全探测](./host/relay_probe.v)、[项目草稿交接](./host/shared_relay_import.v)、[Admin UI 导入](../admin/ui/relay-ui.js)和[跨 include 运行回归](./shared_relay_smoke.v)。

## 运行版本与运行包下载

侧栏显示当前所选 vhttpd 的实际程序版本和来源（App 内置、已下载或本地选择）；版本读取自该程序的 `--version`，与 Desktop 的 App 版本分别处理。“管理运行环境”显示完整路径，并提供下载、取消、重试、选择本地程序和切回 App 内置版本。项目运行期间不允许切换运行包。选择结果保存在本机 `runtime-selection.json`，重新打开工作台后仍使用该路径；路径失效时明确显示不可用，不悄悄退回开发 checkout。

官方下载安装复用 [tag 发布流程](../.github/workflows/workbench-macos-runtime.yml)的完整 Mac zip 与同版本 SHA256SUMS 文件，从 GitHub 最新正式 Release 下载，校验后仅安装其中的运行程序、Admin UI 和动态库到 Application Support 下的 `runtimes/`。用户无需 V、Node、Python、npm、Homebrew 或编译工具；下载、解压和检查使用 macOS 系统工具。安装前检查路径、符号链接、解压体积、arm64 架构、macOS 15.0 最低版本兼容性、代码签名及动态库相对依赖。架构、版本和依赖通过 V 原生 Mach-O 解析完成，不调用可能依赖 Xcode 的 lipo/otool。校验通过才提交新的选择，旧运行包保留。完整 App 已内置运行包，首次使用通常不需要下载。

新建或启动项目时如发现运行包缺失，会直接进入运行环境页；安装或选择有效运行包后继续启动该项目并打开 Admin UI。失败后可重试，项目源码保持不变。仓库尚未提供正式 Release 或网络不可达时会显示对应提示，保留本地选择入口；CI Artifact 不作为公开下载源，也不会在用户电脑上执行源码构建。官方包延续当前 unsigned 预览的系统首次打开限制，见上文安装说明。

实现见[版本与下载安装](./host/runtime_package.v)、[运行环境界面](./runtime_settings.v)和[安装后真实模板回归](./runtime_smoke.v)。Mac 安装包验收加入 `--runtime-smoke`，使用真实包检查安装、选择持久化、校验失败保护，并用安装到本机数据目录的运行程序执行两个 vjsx 模板与失败重试流程；目标系统验收继续使用全新 HOME、系统 PATH 和禁止开发目录/编译器的沙箱。

## 升级、移除与数据位置

升级前先退出工作台，再替换整个 `.app`；无需移动项目目录或重新安装开发工具。安装包旁的 `安装说明.txt` 同时保存在应用的 `Contents/Resources/` 中，可离线查看。第一版不自动更新。

源码位于创建时选择的目录，登记与历史位于上文 Application Support 目录；替换或移除 `.app` 不会自动删除这些数据。需要彻底移除时，先确认项目和恢复历史已经备份，再由自己决定是否删除数据目录。历史包含原始敏感配置，不能仅依据界面脱敏就把数据文件公开分享。

## 遇到失败

- 名称非法、目录存在或不可写：按表单提示更换名称或目录。已有项目文件不会覆盖；文件已创建但登记失败时，保留目录并通过“导入已有项目”重新登记。
- 运行程序缺失：使用左侧“安装 / 选择运行包”，下载安装官方完整运行包或选择已有 vhttpd；项目目录被移动时重新导入。正常独立包已包含运行程序。
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
desktop/bin/vhttpd-workbench.app/Contents/MacOS/vhttpd-workbench --shared-relay-smoke
desktop/bin/vhttpd-workbench.app/Contents/MacOS/vhttpd-workbench --runtime-smoke
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