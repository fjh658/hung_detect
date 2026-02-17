SHELL := /bin/bash

VERSION_FILE := Sources/hung_detect/Version.swift
VERSION := $(strip $(shell sed -nE 's/^[[:space:]]*let[[:space:]]+toolVersion[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$(VERSION_FILE)" | head -n1))
ifeq ($(VERSION),)
$(error Failed to parse toolVersion from $(VERSION_FILE))
endif

BIN := hung_detect
SRC := Sources/hung_detect/main.swift $(VERSION_FILE)
SWIFT ?= swift
BUILD_DIR := .build/macos-universal
DIST_DIR := dist
DIST_TARBALL := $(DIST_DIR)/hung-detect-$(VERSION)-macos-universal.tar.gz
FORMULA_TEMPLATE := Formula/hung-detect.rb.tmpl
FORMULA_FILE := Formula/hung-detect.rb
SWIFTPM_STATE_DIR := $(CURDIR)/.swiftpm
SWIFTPM_CACHE_DIR := $(SWIFTPM_STATE_DIR)/cache
SWIFTPM_CONFIG_DIR := $(SWIFTPM_STATE_DIR)/configuration
SWIFTPM_SECURITY_DIR := $(SWIFTPM_STATE_DIR)/security
SWIFTPM_SCRATCH_DIR := $(CURDIR)/.build/swiftpm-scratch
SWIFTPM_MODULE_CACHE := $(SWIFTPM_STATE_DIR)/module-cache
SWIFTPM_UNIVERSAL_SCRATCH := $(BUILD_DIR)/swiftpm-universal
SWIFT_TEST_FLAGS ?=

.PHONY: all build package formula run test check clean help

all: build

build: $(BIN)

package: build $(DIST_TARBALL) formula

$(DIST_DIR):
	mkdir -p "$(DIST_DIR)"

$(DIST_TARBALL): $(BIN) | $(DIST_DIR)
	tar -czf "$@" "$(BIN)"
	@echo "Packaged: $(abspath $(DIST_TARBALL))"
	@shasum -a 256 "$(DIST_TARBALL)"

formula: $(FORMULA_FILE)

$(FORMULA_FILE): $(FORMULA_TEMPLATE) $(DIST_TARBALL)
	@sha="$$(shasum -a 256 "$(DIST_TARBALL)" | awk '{print $$1}')"; \
	sed -e 's|__VERSION__|$(VERSION)|g' -e "s|__SHA256__|$$sha|g" "$(FORMULA_TEMPLATE)" > "$(FORMULA_FILE)"
	@echo "Updated: $(abspath $(FORMULA_FILE))"

$(BUILD_DIR):
	mkdir -p \
		"$(BUILD_DIR)" \
		"$(SWIFTPM_CACHE_DIR)" \
		"$(SWIFTPM_CONFIG_DIR)" \
		"$(SWIFTPM_SECURITY_DIR)" \
		"$(SWIFTPM_MODULE_CACHE)"

$(BIN): Package.swift $(SRC) | $(BUILD_DIR)
	mkdir -p "$(SWIFTPM_UNIVERSAL_SCRATCH)"
	HOME="$(SWIFTPM_STATE_DIR)" \
	CLANG_MODULE_CACHE_PATH="$(SWIFTPM_MODULE_CACHE)" \
	SWIFTPM_MODULECACHE_OVERRIDE="$(SWIFTPM_MODULE_CACHE)" \
	$(SWIFT) build -c release \
		--product "$(BIN)" \
		--arch arm64 \
		--arch x86_64 \
		--disable-sandbox \
		--cache-path "$(SWIFTPM_CACHE_DIR)" \
		--config-path "$(SWIFTPM_CONFIG_DIR)" \
		--security-path "$(SWIFTPM_SECURITY_DIR)" \
		--scratch-path "$(SWIFTPM_UNIVERSAL_SCRATCH)"
	cp "$(SWIFTPM_UNIVERSAL_SCRATCH)/apple/Products/Release/$(BIN)" "$@"
	@echo "Built: $(abspath $(BIN))"

run: build
	./$(BIN)

test: build
	mkdir -p \
		"$(SWIFTPM_CACHE_DIR)" \
		"$(SWIFTPM_CONFIG_DIR)" \
		"$(SWIFTPM_SECURITY_DIR)" \
		"$(SWIFTPM_SCRATCH_DIR)" \
		"$(SWIFTPM_MODULE_CACHE)"
	HOME="$(SWIFTPM_STATE_DIR)" \
	CLANG_MODULE_CACHE_PATH="$(SWIFTPM_MODULE_CACHE)" \
	SWIFTPM_MODULECACHE_OVERRIDE="$(SWIFTPM_MODULE_CACHE)" \
	swift test $(SWIFT_TEST_FLAGS) \
		--disable-sandbox \
		--cache-path "$(SWIFTPM_CACHE_DIR)" \
		--config-path "$(SWIFTPM_CONFIG_DIR)" \
		--security-path "$(SWIFTPM_SECURITY_DIR)" \
		--scratch-path "$(SWIFTPM_SCRATCH_DIR)"

check: $(BIN)
	file ./$(BIN)
	xcrun vtool -show-build ./$(BIN)

clean:
	rm -rf ./.build ./.swiftpm ./$(BIN)

help:
	@echo "Targets:"
	@echo "  make build                    Build universal binary (SwiftPM --arch arm64 --arch x86_64)"
	@echo "  make package                  Build tarball + refresh Formula/hung-detect.rb (version from $(VERSION_FILE))"
	@echo "  make run                      Build and run detector"
	@echo "  make test                     Run CLI unit tests"
	@echo "  make check                    Show architecture/minos metadata"
	@echo "  make clean                    Remove build artifacts and binary"
