---
kind: configuration_system
name: vhttpd 配置系统：V1/V2 双版本 TOML + 运行时计划编译
category: configuration_system
scope:
    - '**'
source_files:
    - src/config/args.v
    - src/config/config.v
    - src/config/v2_config.v
    - src/config/runtime_plan_loader.v
    - src/config/v2_plan_compiler.v
    - config/vhttpd.example.toml
    - vhttpd.toml
---

## 一、总体方案

vhttpd 的运行时配置采用 **TOML 文件 + 环境变量/变量替换**，并支持 **V1（扁平结构）与 V2（声明式计划）** 两套配置模型。启动时根据 `version` 字段自动选择解析路径，最终统一编译为统一的 `runtime_plan.RuntimePlan` 供上层运行时装配。

- 配置文件来源优先级：**命令行参数 `--config` > 环境变量 `VHTTPD_CONFIG` > 非 `--` 开头的 `.toml` 参数**。
- 变量替换：`${paths.xxx}`、`${env.VAR:-default}` 等语法在加载阶段展开。
- 多文件组合：V2 通过 `include` 列表递归合并子配置，禁止循环引用。

## 二、核心文件与职责

- `src/config/args.v` — CLI 参数解析工具（`CliArgs.*`），用于定位配置文件路径。
- `src/config/config.v` — V1 配置模型定义与解析器（`ServerConfig`、`SiteConfig`、`WorkerConfig`、`PhpConfig`、`FeishuConfig`、`OpenAIConfig`、`DbConfig`、`CacheConfig` 等），提供 `load_vhttpd_config(args)`。
- `src/config/v2_config.v` — V2 配置模型定义（`V2Config`、`V2EngineSpec`、`V2AdapterSpec`、`V2PolicySpecs`、`V2PipelineSpec`、`V2RelaySpec` 等）。
- `src/config/runtime_plan_loader.v` — 版本探测、V2 include 合并、严格键校验、变量与路径展开、以及 `load_runtime_plan_file/text` 入口。
- `src/config/v2_plan_compiler.v` — 将 `V2Config` 编译为 `runtime_plan.RuntimePlan`，含资源/引擎/适配器/策略/管道/中继的引用校验与语义检查。
- `src/config/v1_plan_compat.v` / `v2_config_test.v` / `v2_plan_compiler_test.v` / `runtime_plan_loader_test.v` — 兼容层与测试。
- `config/vhttpd.example.toml`、`examples/config/*.toml`、`vhttpd.toml` — 示例与默认配置。

## 三、架构与约定

### 3.1 版本路由与兼容性

- `detect_config_version(text)` 读取顶层 `version` 字段；未设置则视为 legacy v1。
- V1 路径：`load_vhttpd_config()` → `compile_v1_runtime_plan()`（由兼容模块实现）。
- V2 路径：`decode_v2_config_strict()` → `apply_*_extension_options()` → `compile_v2_runtime_plan()`。
- 运行时可通过 `compatibility=true` 放宽部分 V2 校验以兼容旧行为。

### 3.2 V2 配置分层与合并

- `include: []string` 指定相对或绝对路径的子 TOML 文件。
- 合并策略：同名 map 项按 domain 合并，重复 id 报错；pipeline 数组按 id 去重追加。
- 变量与路径展开：`resolve_v2_config_variables_and_paths()` 注入 `config.dir`、`paths.root` 及 `os.environ()`，并对所有路径型字段做 `resolve_config_path(base_dir, value)` 绝对化。

### 3.3 严格键校验与扩展选项

- `validate_*_specs()` 对每个顶层表与命名集合进行白名单校验，未知字段直接报错，错误信息包含完整路径如 `adapters.${id}.unknown_key`。
- 针对 adapter/transform 的 `int_options`、`bool_options`、`list_options`、`map_options`、`record_options` 五类扩展选项，通过 `apply_v2_extension_options` 在解码后二次填充，避免 TOML 类型限制。

### 3.4 Provider 动态发现

- 若主配置不含 `[providers]` 表，但源码目录存在 `providers/<id>/...` 文件，`provider_ids_from_v2_text` 会扫描 `[providers.<id>]` 片段，自动生成对应 `V2ProviderSpec`，再与显式声明合并。
- 编译期 `compile_provider_action_adapter_provider_plans` 会将 `adapter.kind == 'provider-action'` 的条目反向注入到目标 provider 的 capabilities 中。

### 3.5 运行时计划（Runtime Plan）

V2 配置最终被编译为 `runtime_plan.RuntimePlan`，包含：
- `listeners`、`resources(db/cache/storage/secret)`、`engines`、`adapters`、`transforms`、`policies(cache/limits/security/response/retry/concurrency)`、`providers`、`pipelines`、`relays`、`control`、`observability`。
- 引用校验：`validate_runtime_plan_references` 确保所有 `${domain/id}` 引用存在且域匹配。
- 语义校验：如 engine 必须提供 entry/app、adapter 必须提供 storage/root、listener 必须有 pipeline/relay/control 覆盖等。

## 四、开发者规则

1. **新增配置字段**
   - V1：在 `config.v` 对应 struct 添加字段，并在 `decode_*_config_map` 中处理。
   - V2：在 `v2_config.v` 对应 spec struct 添加字段，并在 `validate_*_specs` 白名单中加入，必要时在 `compile_v2_*` 中映射到 `RuntimePlan`。

2. **使用变量与路径**
   - 路径字段优先用 `${paths.xxx}` 或 `${config.dir}/...`；敏感值用 `${env.VAR:-default}`。
   - 所有路径在加载阶段会被 `resolve_config_path` 转为绝对路径，避免运行期歧义。

3. **多环境拆分**
   - 使用 V2 `include` 拆分 `server.toml`、`engine.toml`、`policy.toml` 等，并通过 CI 脚本生成最终合并文件。
   - 禁止 include 循环；重复 id 会在合并时报错，便于快速定位。

4. **Provider 与 Adapter 扩展**
   - 通过 `int_options`/`bool_options`/`list_options`/`map_options`/`record_options` 传递任意类型选项，无需修改 TOML schema。
   - 使用 `provider-action` adapter 动态增强 provider capability，避免在 providers 表中硬编码。

5. **向后兼容**
   - 迁移到 V2 时保持 `version = 2`；如需保留旧行为，调用 `compile_v2_runtime_plan(cfg, source_path, compatibility=true)`。
   - V1 配置仍受支持，但不再新增功能。

6. **错误诊断**
   - 所有校验失败均返回带完整路径的错误字符串（如 `v2_config_unknown_field:adapters.foo.unknown_key`、`runtime_plan_unresolved_ref:engine/myapp`），应据此修正配置而非捕获忽略。
