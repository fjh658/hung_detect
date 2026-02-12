SHELL := /bin/bash

MIN_MACOS ?= 12.0
BIN := hung_detect
SRC := hung_detect.swift
SWIFTC ?= swiftc
SDK := $(shell xcrun --show-sdk-path --sdk macosx)
BUILD_DIR := .build/macos$(MIN_MACOS)
MODULE_CACHE_DIR := $(BUILD_DIR)/module-cache
ARM64_BIN := $(BUILD_DIR)/$(BIN).arm64
X86_64_BIN := $(BUILD_DIR)/$(BIN).x86_64

.PHONY: all build run check clean help

all: build

build: $(BIN)

$(BUILD_DIR):
	mkdir -p "$(BUILD_DIR)" "$(MODULE_CACHE_DIR)"

$(ARM64_BIN): $(SRC) | $(BUILD_DIR)
	$(SWIFTC) -O \
		-module-cache-path "$(MODULE_CACHE_DIR)" \
		-target "arm64-apple-macos$(MIN_MACOS)" \
		-sdk "$(SDK)" \
		-framework IOKit \
		-o "$@" \
		"$(SRC)"

$(X86_64_BIN): $(SRC) | $(BUILD_DIR)
	$(SWIFTC) -O \
		-module-cache-path "$(MODULE_CACHE_DIR)" \
		-target "x86_64-apple-macos$(MIN_MACOS)" \
		-sdk "$(SDK)" \
		-framework IOKit \
		-o "$@" \
		"$(SRC)"

$(BIN): $(ARM64_BIN) $(X86_64_BIN)
	lipo -create \
		-output "$@" \
		"$(ARM64_BIN)" \
		"$(X86_64_BIN)"
	@echo "Built: $(abspath $(BIN))"

run: build
	./$(BIN)

check: $(BIN)
	file ./$(BIN)
	xcrun vtool -show-build ./$(BIN)

clean:
	rm -rf ./.build ./$(BIN)

help:
	@echo "Targets:"
	@echo "  make build [MIN_MACOS=12.0]  Compile arm64/x86_64 and lipo into universal binary"
	@echo "  make run                      Build and run detector"
	@echo "  make check                    Show architecture/minos metadata"
	@echo "  make clean                    Remove build artifacts and binary"
