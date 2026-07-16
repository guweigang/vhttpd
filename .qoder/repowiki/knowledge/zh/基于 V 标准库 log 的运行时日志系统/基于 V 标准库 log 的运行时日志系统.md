---
kind: logging_system
name: 基于 V 标准库 log 的运行时日志系统
category: logging_system
scope:
    - '**'
source_files:
    - src/logging/runtime_logger.v
    - src/server.v
---

## 系统概述
vhttpd 使用 V 语言标准库 `log` 作为唯一日志框架，通过 `src/logging/runtime_logger.v` 中的 `RuntimeLogger` 模块在进程启动时完成全局配置。该实现是轻量级的：仅设置日志级别与本地时间戳，输出目标为默认 stderr，未引入第三方结构化日志库或自定义 sink。

## 关键文件与入口
- `src/logging/runtime_logger.v` — 日志级别解析、默认值策略、全局 logger 初始化
- `src/server.v:351` — 调用 `logging.RuntimeLogger.configure()` 完成启动期配置
- `deploy/systemd/vhttpd@.service` / `deploy/launchd/io.guweigang.vhttpd.plist` — 通过环境变量注入默认日志级别
- `README.md` — 文档说明 `VHTTPD_LOG_LEVEL` 用法

## 架构与约定
- **单例全局 Logger**：`RuntimeLogger.configure()` 创建 `&log.Log{}` 实例，设置级别后通过 `log.set_logger()` 替换全局 logger，所有后续 `log.debug/info/warn/error/fatal` 调用均走此实例。
- **日志级别来源优先级**：
  1. 环境变量 `VHTTPD_LOG_LEVEL`（支持 `debug|info|warn|warning|error|fatal`）
  2. 编译期 `prod` 标志：生产构建默认为 `warn`，开发构建默认为 `info`
- **时间格式**：启用本地时间戳（`set_local_time(true)`），不使用时区信息。
- **结构化字段现状**：当前所有业务日志均为自由文本字符串，大量使用 emoji 前缀（如 `[codex] 🚨 DETERMINISTIC ERROR:`），尚未实现 JSON 模式；文档中已规划 `VHTTPD_LOG_FORMAT=json` 与按模块级别控制（`VHTTPD_LOG_LEVEL_codex=debug`）作为重构项。
- **Sink 策略**：无自定义输出目标，全部写入 stderr；NDJSON 事件流由上层组件自行输出，不属于本日志子系统职责。

## 开发者应遵循的规则
1. **统一入口**：通过 `import logging` 后调用 `logging.RuntimeLogger.configure()` 完成初始化（已在 server 启动流程中自动执行，应用代码无需重复调用）。
2. **级别选择**：调试路径用 `log.debug`，常规运行信息用 `log.info`，可恢复异常用 `log.warn`，不可恢复错误用 `log.error`，致命错误用 `log.fatal`。
3. **避免硬编码级别**：不要直接修改 `log.Log` 实例，始终通过 `RuntimeLogger.effective_level()` 判断是否应记录某条日志。
4. **预留扩展点**：未来若启用 `VHTTPD_LOG_FORMAT=json`，需移除消息中的 emoji 并改用结构化字段（`provider`、`event`、`instance` 等），以便下游采集器过滤。
5. **模块级级别覆盖**：待实现 `VHTTPD_LOG_LEVEL_<module>=<level>` 后，建议将各 Provider 名称作为模块标识传入，便于精细化调优。