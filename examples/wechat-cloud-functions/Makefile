VJSX_BIN ?= $(if $(wildcard ../../../vjsx/bin/vjsx),$(abspath ../../../vjsx/bin/vjsx),vjsx)
VHTTPD_BIN ?= $(abspath ../../vhttpd)
EXAMPLE_ROOT := $(CURDIR)
export VJSX_BIN VHTTPD_BIN
export WCF_EXAMPLE_ROOT := $(EXAMPLE_ROOT)
.PHONY: test test-e2e test-e2e-mysql dev-local

test:
	cd ../.. && "$(VJSX_BIN)" "$(EXAMPLE_ROOT)/tests/run.mjs"

test-e2e:
	bash tests/e2e.sh

test-e2e-mysql:
	bash tests/mysql-e2e.sh

dev-local:
	bash tests/dev-local.sh
