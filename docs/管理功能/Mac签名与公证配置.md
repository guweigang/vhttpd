---
title: Mac 签名与公证配置
description: 当前采用 unsigned CI 预览交付；本页保留后续可选 Developer ID 签名、公证配置。
date: 2026-10-19
status: optional-signing
tags:
  - desktop
  - macos
  - ci
  - signing
---
# Mac 签名与公证配置

**当前交付采用无 Apple 证书的 unsigned 开发者预览，不需要配置本页的 Apple Secrets。** 用户已确认 aidatastudio 同样没有 Apple 证书；本轮以其 unsigned CI 方式构建并验收下载包，不以签名、公证作为预览交付的前提。

[源码构建工作流](../../.github/workflows/workbench-macos-runtime.yml)默认使用 `release_mode=unsigned`。源码构建后，macOS 15/26 独立 runner 下载同一个 zip，检查解压搬移、新建、失败重试、跨 include 发布、重启生效及恢复；两者均通过才生成 `workbench-macos-arm64-unsigned-verified` 下载产物。包旁附 SHA256SUMS、acceptance.json 和验收说明.txt，记录真实目标系统版本、源码提交及 Gatekeeper 输出。见[使用说明](../../desktop/README.md)与[第一版验收](./Mac工作台第一版验收.md)。

无证书包仍有 ad-hoc 签名，运行验收通过不代表 Gatekeeper 下载自动放行；Finder、目标系统窗口与浏览器首次打开单独记录。工作流保留手动 `release_mode=signed` 作为后续可选路径，Apple 凭据仅传入 `macos-release` Environment 的签名步骤，当前没有执行或要求准备该路径。实现见[签名与公证脚本](../../desktop/ci/sign_notarize_macos.py)。

## 需要准备的配置

在拥有 Developer ID 签名资格的 Apple 开发者团队下，准备一份有效的 **Developer ID Application** 证书。需从持有对应私钥的 Mac 导出 `.p12`，仅有 `.cer` 文件不足以完成此脚本的签名。aidatastudio 当前也没有该证书。如未来购买并配置 Apple 开发者签名，需自行准备有效证书和私钥；GitHub 无法从另一仓库读取 Secret 的明文。

建议全部填入 `guweigang/vhttpd → Settings → Environments → macos-release → Environment secrets`，不把证书、私钥或密码发到聊天、提交到仓库或写入日志。

| Secret 名称 | 内容与取得方式 |
| --- | --- |
| `APPLE_CERTIFICATE` | Developer ID Application 的证书及私钥 `.p12` 文件的 Base64 内容。在 Keychain Access 选中带私钥的该证书后导出；执行下方 Base64 命令。 |
| `APPLE_CERTIFICATE_PASSWORD` | 导出 `.p12` 时设置的密码。 |
| `APPLE_SIGNING_IDENTITY` | 完整名称，例如 `Developer ID Application: Your Company (ABCDEFGHIJ)`；可用 `security find-identity -v -p codesigning` 查看。 |
| `APPLE_TEAM_ID` | 对应 Apple 开发者团队的 10 位 Team ID，必须与签名证书一致。 |

仅在自己的 Mac 上执行，把结果粘贴到对应的 GitHub Secret：

```bash
base64 -i DeveloperID.p12 | pbcopy
```

公证认证二选一。推荐 App Store Connect 的 **Team API Key**，本脚本要求以下三项同时提供：

| Secret 名称 | 内容 |
| --- | --- |
| `APPLE_API_KEY` | Key ID；沿用 aidatastudio 的命名，这里不是私钥内容。 |
| `APPLE_API_ISSUER` | 该 Team API Key 的 Issuer ID。 |
| `APPLE_API_KEY_P8` | 下载的 `AuthKey_*.p8` 文件完整多行原文，包含 BEGIN/END PRIVATE KEY 行；不是文件路径，也不是 Base64。 |

API Key 需具有该团队的公证提交权限。在 App Store Connect 的用户与访问 / 集成 / API 密钥中由有权限的团队成员准备。参考流程中的 `APPLE_API_KEY_PATH` 在本流程由 runner 临时生成，不需要用户提供路径。

如果采用 Apple ID 认证，留空全部三项 API Key Secrets，改填：

| Secret 名称 | 内容 |
| --- | --- |
| `APPLE_ID` | 有该团队公证权限的 Apple 账号邮箱。 |
| `APPLE_PASSWORD` | 为 CI 生成的 app-specific password；不是日常登录密码。 |

Apple ID 方式仍需上表的 `APPLE_TEAM_ID`。配置了部分 API Key 时会直接报缺项，不自动切换到 Apple ID。本流程不接收 Tauri 更新密钥、Developer ID Installer 证书或 provisioning profile；临时 Keychain 密码也由 runner 随机生成，无需另配 Secret。

## GitHub 设置和触发方式

1. 创建 `macos-release` Environment，按团队策略设置 required reviewer，并将允许签名的 deployment branch 限制为已审查的 main / 发布分支。测试签名分支也应明确允许并经过审查。
2. 将证书与上述任意一组公证认证填入 Environment secrets。保留 Secrets 的原始多行格式；不要只填写 `.p8` 在本机的路径。
3. 工作流合并并启用后，在 Actions 的 `Build and verify Mac workbench` 中选择对应源码 ref，手动运行，选择 `release_mode=signed`。
4. 等待源码构建、未签名运行回归、签名公证及两个系统的 signed 验收任务全部通过后，再使用 `workbench-macos-arm64-signed-notarized-candidate` 中的 `*-signed-notarized.zip`。候选产物和证据保留 7 天；当前流程不自动发布正式 Release。

代码依赖：[工具链准备](../../desktop/ci/prepare_toolchain.sh)、[封装和归档](../../desktop/package_macos.py)、[目标系统验收](../../desktop/ci/verify_installed_macos.sh)。

## CI 的通过条件

先固定源码构建，独立回归通过后才进行签名；运行时动态库先封装、修正相对路径，再从内到外签名 dylib、vhttpd 和 App。每个对象检查 Developer ID、同一 Team ID、Hardened Runtime 和时间戳；不添加 JIT、关闭库校验或调试权限例外。

公证提交必须同时得到成功退出码和 `Accepted`。之后对 App 装订并验证票据，重新校验代码签名与系统策略，再从带票据的 App 生成最终 zip 和 SHA256。ZIP 本身不装订票据。归档使用 macOS `ditto` 保留票据及元数据，不能在装订之后又用旧 zip 分发。

macOS 15/26 的独立 runner 下载同一最终包，添加下载隔离标记，要求票据校验、`spctl` 的 `Notarized Developer ID` 来源和系统 distribution 检查均成功，然后在无开发环境访问条件下执行创建、启动、发布、重启生效和恢复回归。安全检查关闭的 override 不能算通过；任何失败都不生成可视为已验收的正式分发结论。

证书和 `.p8` 只写入受限临时目录；临时 Keychain 在成功、失败路径均清理，不修改用户默认 Keychain。诊断产物只收集公证状态和失败日志，不收集凭据。

签名配置缺失、公证拒绝、Team ID 不符、装订失败或系统策略拒绝都会失败退出，不降级为 unsigned 包。签名失败时可检查 `workbench-macos-notarization-status`；配置缺失时仅列出 Secret 名称。

## 仍需真实验收

本轮可运行不使用真实 Apple 凭据的发布链路契约测试；这不等于已经获得 Developer ID 签名或 Apple 公证。用户完成配置后，必须执行一次真实 signed CI，并确认两个目标系统的 signed 门禁通过。

CI 中带隔离标记的策略检查仍不替代实体 Mac 上用浏览器真实下载、解压、拖入应用程序、Finder 打开、显示工作台窗口和自动登录浏览器的完整人工验收。该流程通过后才能确认“默认安全设置下下载后正常打开”；当前不作提前保证。
