.PHONY: build vhttpd prod build-prod demo-vslim demo-ai demo-symfony demo-laravel demo-wordpress psr-matrix

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

build:
	v $(V_FLAGS) $(V_GC_FLAG) -o $(VHTTPD_BIN) $(SRC_DIR)

vhttpd:
	v $(V_FLAGS) $(V_GC_FLAG) -o $(VHTTPD_BIN) $(SRC_DIR)

prod:
	v $(V_FLAGS) $(V_GC_FLAG) $(V_PROD_FLAGS) $(V_NOCACHE_FLAGS) -o $(VHTTPD_BIN) $(SRC_DIR)

build-prod: prod

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
