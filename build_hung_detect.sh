#!/bin/bash
# Wrapper: delegate build/check to Makefile to keep a single build source of truth.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

make -C "${ROOT_DIR}" build
make -C "${ROOT_DIR}" check
