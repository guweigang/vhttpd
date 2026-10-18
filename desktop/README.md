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

## 打开应用

构建结果是 `desktop/bin/vhttpd-workbench.app`，可以在 Finder 中打开，也可以复制整个 `.app` 到其他目录使用。包内包含 vhttpd、Admin UI 和所需的非系统动态库；新建模板使用 script 模式，不需要安装 V 或 Node。当前包是本机架构构建，使用 ad-hoc 签名，尚未进行 Developer ID 签名和 Apple 公证，不能据此声称已完成面向所有 Mac 的公开分发验证。打包实现见[构建脚本](./build.sh)、[依赖封装](./package_macos.py)与[运行环境路径](./host/environment.v)。

从源码构建时，需要 PATH 中可用的 V，以及仓库根目录已构建的 vhttpd：

```bash
./desktop/build.sh
./desktop/run.sh
```

ui2 固定到 [ui2.commit](./ui2.commit) 中的版本。已有依赖 checkout 的版本不符或含源码修改时，构建会拒绝覆盖。构建先完成新包，再替换旧包，不原地截断正在运行的可执行文件。

## 第一次使用

1. 打开后点击“新建 vjsx 项目”，选择 HTTP 入门或 JSON API 模板、项目名称与存放目录。保留“创建后立即启动，并打开浏览器 Admin UI”即可一次完成创建与启动。
2. 宿主等待管理认证和业务监听就绪，随后打开默认浏览器自动登录；无需复制 token，token 不进入 URL。可点击“访问业务服务”验证真实响应。
3. 在 Admin UI 的“项目配置”修改常用表单；高级选项使用来源 TOML。先“保存并校验”，通过后“发布配置”。修改覆盖主配置及全部 include 的整项目校验。
4. 宿主自动显示“待重启生效”。查看差异，或点击“重启并生效”；宿主完成后自动检查整个项目，并打开默认浏览器重新登录 Admin UI。重启仍会轮换实例凭据，无需复制 token。
5. 总览查看监听、路由、执行器和近期请求；慢请求明细可关联宿主完成日志及配置来源。宿主关闭时停止自己启动的实例，关闭浏览器不会停止服务。
6. “版本历史”可查看脱敏差异、预览并恢复所选已生效版本；项目未运行时也可恢复。恢复后继续整项目校验与生效检查，需要重启时会明确提示。

入口与行为见[宿主界面](./main.v)、[新建项目](./create_project.v)、[浏览器交接](./host/browser_login.v)、[生效状态](./host/config_status.v)、[配置恢复](./host/config_rollback.v)和[Admin UI](../admin/ui/common-config-ui.js)。

项目登记默认保存在 `~/Library/Application Support/vhttpd-workbench/projects.json`，版本历史保存在同目录的 `recovery/`。升级时可迁移当前开发 checkout 的旧登记，不移动项目源码。历史按本机文件权限保存，包含恢复所需的原始配置内容，不加密；界面差异对敏感字段脱敏。需保管好本地文件。实现见[登记](./host/project.v)与[历史存储](./host/recovery_store.v)。

## 遇到失败

- 名称非法、目录存在或不可写：按表单提示更换名称或目录。已有项目文件不会覆盖；文件已创建但登记失败时，保留目录并通过“导入已有项目”重新登记。
- 运行程序缺失：使用左侧“选择 vhttpd…”；项目目录被移动时重新导入。正常独立包已包含运行程序。
- 端口占用：停止由自己管理的占用服务，或在配置中改端口后重试；工作台不会接管或结束其他进程。
- 启动失败：查看项目下方日志。冷启动等待上限为 90 秒；停止超时后提供需确认的“强制停止”，仅针对本次进程组。
- 校验不通过：修正提示后再次校验，发布按钮不会提前启用。发布失败应先重新读取并核对外部修改；不会以接口失败推断配置已生效。
- 浏览器登录失效或自动打开失败：从宿主“打开浏览器”重新建立自动登录；不需要寻找或复制运行 token。正常重启完成后宿主会自动打开并登录 Admin UI。

失败与清理逻辑见[进程管理](./host/manager.v)、[后台循环](./host/worker.v)和[模板生成](./host/templates.v)。

## 验证

使用构建好的应用直接执行真实主流程检查：

```bash
desktop/bin/vhttpd-workbench.app/Contents/MacOS/vhttpd-workbench --smoke
desktop/bin/vhttpd-workbench.app/Contents/MacOS/vhttpd-workbench --persistent-status-smoke
```

第一项验证两个模板的创建、登记、认证就绪、业务响应、Admin UI、正常停止与端口释放；第二项验证跨 include 发布、待生效、重启检查、脱敏版本比较、重新创建宿主管理器后的离线恢复与历史记录。夹具使用规范化的临时路径并清理自己启动的实例，支持在仓库外的完整包副本上执行。见[主流程回归](./smoke.v)与[发布恢复回归](./status_smoke.v)。

```bash
v -enable-globals -path "$PWD/desktop|$PWD/src|@vlib|@vmodules" test desktop/host
v -enable-globals -path "$PWD/desktop|$PWD/src|$PWD/.deps|@vlib|@vmodules" test desktop/ui_state_test.v
node --test tests/admin-ui/*.test.cjs
```

[界面回归](./ui_state_test.v)直接验证 ui2 元素树，覆盖空列表、新建、运行、待生效、失败、历史、恢复以及重启返回工作台；防止重复元素标识导致白屏或状态冻结。详细验收见[Mac 第一版验收记录](../docs/管理功能/Mac工作台第一版验收.md)。

## 第一版边界

同时管理一个本地实例；不接管外部服务。第一版主路径为 vjsx HTTP 项目与本机 HTTP 管理监听。常用配置表单之外保留源码编辑。近期指标和慢请求样本有内存保留上限；内嵌 vjsx 的独立执行超时尚未采集，不能把未采集显示为零。Windows/Linux、WebView、自动更新、后台常驻和崩溃后接管不属于本版验收范围。