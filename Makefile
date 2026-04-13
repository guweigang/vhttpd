.PHONY: build vhttpd prod build-prod build-db prepare-build-src demo-vslim demo-ai demo-symfony demo-laravel demo-wordpress psr-matrix test test-fast test-inproc test-codexbot test-codexbot-fast test-codexbot-lifecycle test-profile-codexbot test-all

ROOT := $(CURDIR)
SRC_DIR := $(ROOT)/src
VHTTPD_BIN ?= $(ROOT)/vhttpd
VPHP_V_GC ?= auto
VPHP_V_GC_STRIPPED := $(strip $(VPHP_V_GC))
RESOLVED_VPHP_V_GC := $(shell if [ -n "$(VPHP_V_GC_STRIPPED)" ] && [ "$(VPHP_V_GC_STRIPPED)" != "auto" ]; then printf "%s" "$(VPHP_V_GC_STRIPPED)"; elif pkg-config --exists bdw-gc 2>/dev/null; then printf boehm; else printf none; fi)
V_GC_FLAG := -gc $(RESOLVED_VPHP_V_GC)
V_TLS_BACKEND ?= openssl
ifeq ($(V_TLS_BACKEND),openssl)
V_TLS_FLAGS := -d use_openssl
else
V_TLS_FLAGS := -d mbedtls_client_read_timeout_ms=120000
endif
V_FLAGS ?= $(V_TLS_FLAGS)
V_PROD_FLAGS ?= -prod
V_NOCACHE_FLAGS ?= -nocache
WITH_DB ?= 0

DB_IMPL_DIR := $(ROOT)/dbsrc
BUILD_STAGE_ROOT := $(ROOT)/tmp/vbuildsrc
BUILD_STAGE_DIR := $(BUILD_STAGE_ROOT)

ifeq ($(WITH_DB),1)
V_DB_FLAGS := -d enable_db
else
V_DB_FLAGS :=
endif

FAST_TEST_FILES := \
	$(SRC_DIR)/codex_runtime_test.v \
	$(SRC_DIR)/command_executor_test.v \
	$(SRC_DIR)/command_test.v \
	$(SRC_DIR)/feishu_runtime_test.v \
	$(SRC_DIR)/json_utils_test.v \
	$(SRC_DIR)/kernel_dispatch_test.v \
	$(SRC_DIR)/logic_executor_test.v \
	$(SRC_DIR)/provider_bootstrap_test.v \
	$(SRC_DIR)/provider_registry_test.v \
	$(SRC_DIR)/server_logic_test.v \
	$(SRC_DIR)/websocket_upstream_runtime_test.v \
	$(SRC_DIR)/worker_backend_runtime_test.v

INPROC_TEST_FILES := \
	$(SRC_DIR)/inproc_vjsx_executor_test.v \
	$(SRC_DIR)/inproc_vjsx_host_api_test.v \
	$(SRC_DIR)/inproc_vjsx_startup_sequence_test.v \
	$(SRC_DIR)/inproc_vjsx_warmup_test.v

CODEXBOT_TEST_FILES := \
	$(SRC_DIR)/inproc_vjsx_executor_codexbot_core_test.v \
	$(SRC_DIR)/inproc_vjsx_executor_codexbot_lifecycle_test.v \
	$(SRC_DIR)/inproc_vjsx_executor_codexbot_projects_test.v \
	$(SRC_DIR)/inproc_vjsx_executor_codexbot_read_rpc_test.v \
	$(SRC_DIR)/inproc_vjsx_executor_codexbot_semantics_test.v \
	$(SRC_DIR)/inproc_vjsx_executor_codexbot_threads_test.v

CODEXBOT_LIFECYCLE_TEST_FILES := \
	$(SRC_DIR)/inproc_vjsx_executor_codexbot_lifecycle_test.v

CODEXBOT_FAST_TEST_FILES := \
	$(SRC_DIR)/inproc_vjsx_executor_codexbot_core_test.v \
	$(SRC_DIR)/inproc_vjsx_executor_codexbot_projects_test.v \
	$(SRC_DIR)/inproc_vjsx_executor_codexbot_read_rpc_test.v \
	$(SRC_DIR)/inproc_vjsx_executor_codexbot_semantics_test.v \
	$(SRC_DIR)/inproc_vjsx_executor_codexbot_threads_test.v

prepare-build-src:
	@rm -rf $(BUILD_STAGE_ROOT)
	@mkdir -p $(BUILD_STAGE_DIR)
	@if command -v rsync >/dev/null 2>&1; then \
		rsync -a $(SRC_DIR)/ $(BUILD_STAGE_DIR)/; \
	else \
		cp -R $(SRC_DIR)/. $(BUILD_STAGE_DIR)/; \
	fi
ifeq ($(WITH_DB),1)
	@cp $(DB_IMPL_DIR)/*.v $(BUILD_STAGE_DIR)/
endif

build: prepare-build-src
	v $(V_FLAGS) $(V_DB_FLAGS) $(V_GC_FLAG) -o $(VHTTPD_BIN) $(BUILD_STAGE_DIR)

vhttpd: build

prod: prepare-build-src
	v $(V_FLAGS) $(V_DB_FLAGS) $(V_GC_FLAG) $(V_PROD_FLAGS) $(V_NOCACHE_FLAGS) -o $(VHTTPD_BIN) $(BUILD_STAGE_DIR)

build-prod: prod

build-db:
	$(MAKE) build WITH_DB=1

demo-vslim:
	@$(ROOT)/examples/run_demo.sh vslim

demo-ai:
	@$(ROOT)/examples/run_demo.sh ai

demo-symfony:
	@$(ROOT)/examples/run_demo.sh symfony

demo-laravel:
	@$(ROOT)/examples/run_demo.sh laravel

demo-wordpress:
	@$(ROOT)/examples/run_demo.sh wordpress

psr-matrix:
	@$(MAKE) -C $(ROOT)/../vphpx/vslim psr-matrix

test: test-fast

test-fast:
	v test $(FAST_TEST_FILES)

test-inproc:
	v test $(INPROC_TEST_FILES)

test-codexbot:
	v test $(CODEXBOT_TEST_FILES)

test-codexbot-fast:
	v test $(CODEXBOT_FAST_TEST_FILES)

test-codexbot-lifecycle:
	v test $(CODEXBOT_LIFECYCLE_TEST_FILES)

test-profile-codexbot:
	@/bin/zsh $(ROOT)/tools/profile_codexbot_tests.sh $(ROOT)

test-all:
	v test $(SRC_DIR)
