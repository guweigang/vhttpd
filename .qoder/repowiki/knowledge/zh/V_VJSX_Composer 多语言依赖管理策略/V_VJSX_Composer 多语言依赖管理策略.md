---
kind: dependency_management
name: V/VJSX/Composer 多语言依赖管理策略
category: dependency_management
scope:
    - '**'
source_files:
    - v.mod
    - Makefile
    - scripts/install_deps.sh
    - scripts/doctor.sh
    - scripts/runtime_doctor.sh
    - php/package/composer.json
    - examples/codexbot-app/composer.json
---

本仓库采用 V 原生模块 + VJSX 外部源码 + Composer PHP 包三层混合的依赖管理模式，核心运行时由 V 语言编写，通过 v.mod 声明单模块，第三方 C 库与系统工具通过脚本安装，VJSX 引擎以 git clone 到 ~/.vmodules/vjsx 的方式拉取，PHP 侧则使用 composer.json 发布为独立包。

1. 使用的系统与工具
- V 语言：根目录 v.mod 定义模块名、版本与 base_url；构建入口 Makefile 调用 v -cc $(V_CC) ... 编译，支持 -gc boehm/none、TLS 后端 openssl/mbedtls 等编译期开关。
- 系统级依赖：scripts/install_deps.sh 按 OS（Darwin/Linux）分别用 brew/apt 安装 bdw-gc、libpq、mysql-client、openssl@3、sqlite3、pkg-config、git、curl、unzip 等 C 依赖。
- VJSX 引擎：install_deps.sh 将 guweigang/vjsx 克隆至 $HOME/.vmodules/vjsx，并自动检测本地 ../quickjs 或调用 vjsx/scripts/ensure-quickjs.sh 下载 QuickJS 源码，Makefile 通过 VJS_QUICKJS_PATH 注入路径。
- PHP 包：php/package/composer.json 发布 vphp/runtime 库，提供 PSR-4 autoload 与 bin/vphp-worker、bin/vphp-worker-client；示例应用 examples/codexbot-app 使用 pestphp/pest 作为 dev 依赖并通过 scripts/post-install-cmd 禁用 mutate 插件。

2. 关键文件与位置
- v.mod：V 模块元数据（name/base_url/version）。
- Makefile：构建目标、GC/TLS 开关、测试发现、vjsx/quickjs 路径探测。
- scripts/install_deps.sh：core/vjsx/db/full 四种模式一键安装系统依赖与 vjsx/quickjs。
- scripts/doctor.sh / runtime_doctor.sh：环境诊断，提示 legacy ~/.vmodules/vjsx symlink 不再需要。
- php/package/composer.json：vphp/runtime 包定义与 PSR-4 映射。
- examples/*/composer.json：示例应用的 dev 依赖与脚本钩子。

3. 架构与约定
- 无 vendor 锁定：V 与 VJSX 不生成 lockfile，依赖版本由 v.mod 与 git clone --depth=1 决定；C 库版本由系统包管理器控制。
- 可插拔 GC/TLS：通过 V_GC_FLAG 与 V_TLS_FLAGS 在构建时切换 Boehm GC 与 OpenSSL/MbedTLS，默认 auto 探测 bdw-gc。
- vjsx 源码嵌入：QuickJS 源码经 ensure-quickjs.sh 下载到工作区，Makefile 以 -d build_quickjs 编译进二进制，避免运行时再拉取。
- PHP 运行时分发：vhttpd.toml 配置 [executor.kind="php"] 及 [php] 段指定 worker_entry/app_entry/extensions，由主进程 fork 多个 vphp-worker 子进程执行用户 PHP 代码。

4. 开发者应遵循的规则
- 新增 C 依赖：在 install_deps.sh 的 core/db/full 模式中补充 brew/apt 安装条目，并在 Makefile 对应 -d 开关处暴露编译选项。
- 升级 VJSX/QuickJS：修改 install_deps.sh 中 vjsx 仓库地址或 ensure-quickjs.sh 参数，确保本地 ../quickjs 检出能被识别。
- 发布/更新 PHP 包：仅维护 php/package/composer.json，不要提交 vendor/；示例项目自行维护其 composer.lock。
- 构建产物：vhttpd 二进制由 Makefile 输出到根目录，tmp/vbuildsrc 为清理后的构建阶段目录，不应纳入版本控制。