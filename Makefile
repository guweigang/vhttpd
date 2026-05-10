.PHONY: build vhttpd prod build-prod build-db prepare-build-src deps-core deps-vjsx deps-db deps-full doctor demo-vslim demo-ai demo-symfony demo-laravel demo-wordpress psr-matrix test test-fast test-inproc test-codexbot test-codexbot-fast test-codexbot-lifecycle test-profile-codexbot test-all

ROOT := $(CURDIR)
SRC_DIR := $(ROOT)/src
VHTTPD_BIN ?= $(ROOT)/vhttpd
V_CC ?= cc
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
WITH_DB ?= 1

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
		rsync -a --exclude='*_test_helpers.v' --exclude='test_*.v' $(SRC_DIR)/ $(BUILD_STAGE_DIR)/; \
	else \
		cp -R $(SRC_DIR)/. $(BUILD_STAGE_DIR)/; \
		find $(BUILD_STAGE_DIR) -name '*_test_helpers.v' -delete; \
		find $(BUILD_STAGE_DIR) -name 'test_*.v' -delete; \
	fi
ifeq ($(WITH_DB),1)
	@cp $(DB_IMPL_DIR)/*.v $(BUILD_STAGE_DIR)/
endif

build: prepare-build-src
	v -cc $(V_CC) $(V_FLAGS) $(V_DB_FLAGS) $(V_GC_FLAG) -o $(VHTTPD_BIN) $(BUILD_STAGE_DIR)

vhttpd: build

prod: prepare-build-src
	v -cc $(V_CC) $(V_FLAGS) $(V_DB_FLAGS) $(V_GC_FLAG) $(V_PROD_FLAGS) $(V_NOCACHE_FLAGS) -o $(VHTTPD_BIN) $(BUILD_STAGE_DIR)

build-prod: prod

build-db:
	$(MAKE) build WITH_DB=1

deps-core:
	@./scripts/install_deps.sh core

deps-vjsx:
	@./scripts/install_deps.sh vjsx

deps-db:
	@./scripts/install_deps.sh db

deps-full:
	@./scripts/install_deps.sh full

doctor:
	@./scripts/doctor.sh

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
	v -cc $(V_CC) test $(FAST_TEST_FILES)

test-inproc:
	v -cc $(V_CC) test $(INPROC_TEST_FILES)

test-codexbot:
	v -cc $(V_CC) test $(CODEXBOT_TEST_FILES)

test-codexbot-fast:
	v -cc $(V_CC) test $(CODEXBOT_FAST_TEST_FILES)

test-codexbot-lifecycle:
	v -cc $(V_CC) test $(CODEXBOT_LIFECYCLE_TEST_FILES)

test-profile-codexbot:
	@/bin/zsh $(ROOT)/tools/profile_codexbot_tests.sh $(ROOT)

test-all:
	v -cc $(V_CC) test $(SRC_DIR)
