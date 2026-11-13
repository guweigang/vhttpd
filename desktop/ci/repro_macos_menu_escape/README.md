# Mac 菜单 Esc 复现与 Linux 快捷键验收

验收日期：2026-10-30。工作分支 `feature/desktop-workbench`，基线提交
`09fbc2e2c09721e7d82e49ef9be0ba67d850e730`，包含尚未提交的 Desktop 改动。
本记录不代表 macOS 菜单 Esc 已修复。

## Mac：当前环境仍未通过

- macOS 27.0.1，build `26A434`。
- ui2 固定于 `548acc257c56172d357fd14f8b4d9f2d5da82c1c`，`.deps/ui2` 无源码改动。
- 在工作台新建表单中输入测试值，展开原生项目菜单，按 Esc：菜单保持展开，
  底层表单却被取消。最小 ui2 程序也复现；用户手动操作确认相同结果。
- **纯 AppKit 对照程序完全不使用 V、ui2 或工作台的按键处理，也无法用 Esc
  关闭其 Project 菜单**；自动化和用户手动操作均确认。因此不能将
  “原生菜单无法关闭”单独归因于 ui2，也不能推断其他 macOS 版本同样受影响。

### 已确认的事件路径

ui2 的 `appkit/ui_macos_darwin.v` 中，`ui2_window_perform_key_equiv`
在原生 key-equivalent 处理前调用 `dispatch_typed_key_event`；工作台的
`workbench_physical_key` 消费 Esc 并取消表单。当前环境下，依赖菜单 tracking
通知、高亮项或 delegate 回调的宿主保护不能识别屏幕上仍展开的菜单。

临时诊断观察到 `menuWillOpen` / `menuDidClose` 在同一个原生事件中成对出现，
但屏幕菜单仍展开；Esc 到达窗口时，tracking 集合和高亮项均为空。
这些回调不能直接作为当前系统中菜单可见状态的可靠依据。

Apple 将 [menuWillOpen](https://developer.apple.com/documentation/appkit/nsmenudelegate/menuwillopen(_:))
定义为菜单即将展开时的回调，
[didEndTrackingNotification](https://developer.apple.com/documentation/appkit/nsmenu/didendtrackingnotification)
定义为菜单 tracking 结束时发出的通知。本轮实测说明不能只按这些回调维护
一个开关后便宣称问题已解决；尚未确定当前系统行为的最终根因。

### 处置边界

未将运行时替换 NSWindow / delegate 类的实验适配合入工作台：其原型虽阻止
底层表单被取消，但未可靠关闭菜单，且影响普通表单的 Esc 取消。
没有禁用全局 Esc，没有修改 `.deps/ui2`，没有将实验原型当作修复交付。
当前可用鼠标关闭菜单，再点击表单“取消”。

需要在其他 macOS 版本或干净登录会话重跑两个对照程序，再决定宿主兼容方案
或是否向 ui2 提交问题；本记录没有假定问题已获得上游确认。

### 构建最小复现

在 macOS 仓库根目录运行：

```sh
bash desktop/ci/repro_macos_menu_escape/build.sh
```

脚本只在临时目录构建两个 `.app`，不启动它们，不替换正式 App，不访问项目数据。
ui2 仍使用项目锁定提交，既有构建补丁仅应用于临时模块副本。

1. 打开输出的 `ui2-menu-probe.app`，按 ⌘N，确认 `FORM OPEN`；
   用鼠标展开 Project，按 Esc，观察菜单和底下表单。
2. 打开 `cocoa-menu-control.app`，用鼠标展开 Project，按 Esc，观察菜单。
3. 两个程序只包含固定字符串 `fixture`，无需 SSH、远端实例、运行包或认证信息。

## Linux：验收环境与结果

OrbStack `ubuntu` VM：Ubuntu 26.04 LTS / aarch64，Xvfb + Openbox + x11vnc + noVNC。
这次是本机 VM 的 GUI 验收，不替代 Ubuntu 24.04 amd64/arm64 CI。

- 使用隔离的 `/home/guweigang/vhttpd-ui2-v-d13ccdd/v`，V `d13ccdd`，GCC、`-gc none`。
- 用户 `/home/guweigang/v` 仍为干净的 `local-dev` / `e21021d`，没有升级或切分支。
- 测试进程、项目登记和运行日志均位于 `/tmp`；未操作实际远端应用。
- 重建桌面工具控制会话后恢复既有 VNC 标签，没有暴露新的 VNC 端口或调整认证。
- 验收通过 noVNC 的 Ctrl 修饰键、Tab、Esc 控件发送到真实 Linux 窗口，
  不是只验证 V 函数或菜单数据。

已验证：Ctrl+N 新建、禁用时再次 Ctrl+N 保留测试值、Ctrl+O 文件选择及取消、
Ctrl+, 运行环境、Ctrl+A 全选、Ctrl+X 剪切、Ctrl+C 复制、Ctrl+V 恢复、Tab 切换输入框。
复制验收使用 `z → 复制 → 替换为 b → 粘贴得到 bz`，确认使用 Linux 原生剪贴板，
而非浏览器自动化工具的虚拟剪贴板。
展开 Project 后第一次 Esc 只关闭菜单，第二次 Esc 才取消表单。

补查发现并在宿主修复：新表单渲染前调用 ui2.focus 会被立即渲染后端忽略。
宿主保留尚未完成的表单聚焦请求，在后续 UI 渲染帧检查目标仍在当前页面后重试，
成功后立即清除；不修改 ui2.focus，也不从后台线程操纵焦点。

修复后的 Linux 完整 Desktop 构建通过；Mac 上 `desktop/menus_test.v` 编译并执行通过。
两个 Mac 最小复现应用均由 `build.sh` 成功构建。当前 `.deps/ui2` 保持干净。

### 反向 Tab 的传输对照

自动化直接发送 Shift+Tab 时，临时 X11 专用窗口记录到：Shift 按下 → Shift 松开 →
Tab 按下（`state=0`）→ Shift 按下 → Tab 松开（`ISO_Left_Tab`）。
也就是 Tab 按下时没有 Shift 修饰键，不能将该次自动化观察归为宿主反向遍历失败。
该探针只接收自身窗口的测试按键，不监听其他窗口；验收后关闭。

人工补查：用户在同一个 noVNC / 内嵌浏览器中点击目录输入框后，实体键盘
Shift+Tab 也未返回项目名称。因此 **Shift+Tab 在该 VNC 环境仍未通过**，
不能将它记为已修复或验收通过。自动化的 X11 记录能证明其发送路径有修饰键问题，
但没有采集用户这次手动操作的原生事件，故尚不能断定人工失败与自动化完全同因，
也不能排除后端问题。原生 Linux 物理桌面对照与其他浏览器对照未完成。
本次没有为了绕过该现象修改 ui2 或 Sokol。
