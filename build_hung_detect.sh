#!/bin/bash
# Wrapper: delegate build/check to Makefile to keep a single build source of truth.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIN_MACOS="${1:-12.0}"

make -C "${ROOT_DIR}" build MIN_MACOS="${MIN_MACOS}"
make -C "${ROOT_DIR}" check
