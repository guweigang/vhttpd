---
kind: build_system
name: V 语言构建与多平台产物打包体系
category: build_system
scope:
    - '**'
source_files:
    - Makefile
    - v.mod
    - .github/workflows/vhttpd-binaries.yml
    - scripts/install_deps.sh
    - scripts/install_ubuntu_from_source.sh
    - scripts/bundle_runtime_libs.sh
    - scripts/doctor.sh
    - deploy/systemd/vhttpd@.service
    - deploy/launchd/io.guweigang.vhttpd.plist
---

## 构建系统概览

vhttpd 使用 V 语言作为核心编译目标，通过 Makefile + Bash 脚本组合实现从源码到可执行文件的完整构建流程，并借助 GitHub Actions 在多平台上产出带运行时依赖的自包含二进制包。

### 1. 构建工具链与模块管理
- 编译器: V 语言 (v)，由 scripts/install_ubuntu_from_source.sh 或 CI 自行从 guweigang/vlang fork 构建，默认分支为 local-dev。
- 模块声明: 根目录 v.mod 定义模块名 vhttpd、源码基路径 src/、版本 0.0.1，无外部依赖声明，全部以本地子目录形式组织。
- C 后端: 通过 V_CC 环境变量指定 C 编译器（Linux 用 gcc，macOS 用 clang），Makefile 中统一透传给 v -cc。

### 2. 构建选项与特性开关
- WITH_DB: 是否启用数据库支持（SQLite/MySQL/PQ），默认 1
- VPHP_V_GC: PHP 运行时 GC 后端：boehm / none / auto，默认 auto（检测 bdw-gc）
- V_TLS_BACKEND: TLS 后端：openssl 或内置 mbedtls，默认 openssl
- VJSX_DIR: vjsx 模块路径，优先查找上游 ../vjsx，否则回退到 ~/.vmodules/vjsx
- VJS_QUICKJS_PATH: QuickJS 源码路径，由 vjsx/scripts/ensure-quickjs.sh 下载/定位

构建时通过 -d enable_db、-d build_quickjs、-gc boehm、-d use_openssl 等 V 编译期标志控制功能裁剪。

### 3. 构建阶段与产物
prepare-build-src: 将 src/ 拷贝到 tmp/vbuildsrc，剔除 *_test.v、*_test_support.v、inproc_vjsx_executor_codexbot_helpers.v 等测试文件
build / prod: 调用 v -cc $(V_CC) -o vhttpd [flags] tmp/vbuildsrc

开发构建 (make build): 开启调试信息，不启用 -prod 优化。
生产构建 (make prod): 加上 -prod -nocache，GC 强制 boehm，TLS 走 OpenSSL。
产物: 根目录 ./vhttpd 单文件二进制；CI 再经 scripts/bundle_runtime_libs.sh 抽取 libmysqlclient/libpq/libssl/libgc 等动态库至 runtime/libs/，并用 install_name_tool (macOS) / patchelf --set-rpath '$ORIGIN/runtime/libs' (Linux) 重写链接路径，形成自包含 tar.gz 包。

### 4. 依赖安装与快速上手
make deps-core: 仅安装系统库（libgc、libpq、mysql-client、sqlite、openssl、pkg-config）。
make deps-vjsx / deps-full: 额外克隆 guigetang/vjsx 到 ~/.vmodules/vjsx，并通过其 scripts/ensure-quickjs.sh 拉取 QuickJS 源码。
make doctor: 运行 scripts/doctor.sh 诊断环境。
scripts/install_ubuntu_from_source.sh: 一键式 Ubuntu 安装器，按顺序完成 apt 依赖 → 自建 V 编译器 → 克隆 vjsx → 确保 QuickJS → make prod → install 到 $HOME/.local/bin。

### 5. 测试体系
test-fast: src/*_test.v 排除 inproc/db，逐文件 + 子模块目录并行扫描
test-php: php/package/tests/*_test.php，直接 php 执行 PHPUnit 风格测试
test-inproc: inproc_*_test.v 非 codexbot，启动内嵌 VJSX 运行时的集成测试
test-codexbot / test-codexbot-fast / test-codexbot-lifecycle: codexbot 相关 inproc 测试，按生命周期拆分便于 CI 分片
test-e2e: tests/e2e/run.sh，冒烟 + 配置接受度测试
test-all: v test src/，全量测试（含慢速）

支持按文件名过滤：make test-fast src/dispatch/pipeline_test.v 只跑单个测试文件。

### 6. CI 流水线 (.github/workflows/vhttpd-binaries.yml)
触发: push/main、PR（仅监听 src/dbsrc/Makefile/v.mod/workflow 变更）
矩阵: ubuntu-latest (linux-amd64)、macos-15-intel (macos-amd64)、macos-15 (macos-arm64)
步骤:
1. 安装平台特定依赖（apt / brew）
2. 从 guigetang/vlang 自建 V 编译器
3. 克隆 vjsx 到 /usr/local/share/vhttpd/vjsx 并建立 ~/.vmodules/vjsx 软链
4. 运行 make test-fast
5. make prod VPHP_VGC=boehm WITH_DB=1 构建
6. make test-e2e + ./vhttpd --help 冒烟
7. scripts/bundle_runtime_libs.sh 打包依赖，生成 vhttpd-${target}.tar.gz 上传 artifact

### 7. 部署与服务单元
deploy/systemd/vhttpd@.service: systemd 模板，支持 vhttpd@instance.service 多实例
deploy/launchd/io.guweigang.vhttpd.plist: macOS launchd 服务描述
examples/config/*.toml: 覆盖 Hello、WebSocket、AI 流式、MCP、Relay V2、Paseo、Symfony/Laravel/WordPress 等场景的配置模板

### 8. 开发者约定
新增 V 测试文件后无需修改 Makefile，find 会自动发现 *_test.v
需要 DB 功能的测试应放在 db_* 命名下，默认 test-fast 会跳过
在进程内启动 VJSX 的 inproc 测试统一以 inproc_* 前缀命名，避免污染快速测试集
跨平台构建必须通过 VPHP_VGC 显式指定 GC 后端，CI 固定为 boehm
发布产物需同时包含 vhttpd 二进制与 runtime/libs/ 下的动态库，且 rpath/loader_path 已正确重写