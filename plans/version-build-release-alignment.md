# Version / Build / Release Alignment for hung_detect

**Status: Completed (2026-02-17)**

## Context

Recent iterations introduced SwiftPM tests, source layout changes, and new diagnosis flags.
This round focused on removing version drift and release friction:

1. `--version` was missing initially.
2. Version value was duplicated across Makefile / formula / runtime output.
3. Formula maintenance (`version`, artifact name, sha256) was manual and error-prone.
4. Build path had become inconsistent (manual fallback logic and old docs).

Goal: establish one clear version source and deterministic packaging flow.

## Final Decisions

1. **Single source of truth for runtime/app version**
   Use `Sources/hung_detect/Version.swift`:
   ```swift
   let toolVersion = "0.4.0"
   ```

2. **Runtime `--version` comes from code, not Makefile**
   `hung_detect --version` / `-v` prints `toolVersion`.

3. **Makefile reads version from `Version.swift`**
   Makefile no longer owns a hard-coded `VERSION ?= ...`.
   It parses `toolVersion` and uses it for tarball naming.

4. **Formula file is generated from template during packaging**
   `Formula/hung-detect.rb.tmpl` contains placeholders:
   - `__VERSION__`
   - `__SHA256__`

   `make package` renders `Formula/hung-detect.rb` with:
   - version parsed from `Version.swift`
   - sha256 from freshly built tarball

5. **Keep build path simple**
   `make build` uses SwiftPM multi-arch only:
   `swift build --arch arm64 --arch x86_64`

## Changes Made

### Source / Package Layout

- Migrated runtime source path to SwiftPM standard:
  - from `hung_detect.swift`
  - to `Sources/hung_detect/main.swift`
- Added `Sources/hung_detect/Version.swift` as the version source.
- `Package.swift` executable target compiles:
  - `main.swift`
  - `Version.swift`

### CLI

- Added `-v, --version` option in parser and help output.
- Added runtime version printing in `main()`.

### Build / Release Automation

- Simplified `Makefile`:
  - removed hard-coded top-level version variable
  - parse version from `Sources/hung_detect/Version.swift`
  - `make package` now runs:
    1. build
    2. tarball
    3. formula generation from template
  - packaging mode:
    - default `make package` includes binary only
    - `make package INCLUDE_DSYM=1` includes binary + `.dSYM`

- Added formula template:
  - `Formula/hung-detect.rb.tmpl`

- Generated output:
  - `Formula/hung-detect.rb` (auto-filled version + sha256)

### Tests

- Migrated tests to Swift XCTest (SwiftPM).
- Added/updated version tests:
  - `--version`
  - `-v`
- Test expected version is parsed from `Sources/hung_detect/Version.swift` (not Makefile).

### Docs

- Updated README / README.zh-CN to include `--version`.
- Updated packaging docs to use `make package` (no manual `VERSION=...` input).
- Clarified that formula is refreshed during packaging.

## Validation

Executed and passed:

1. `make build`
2. `make test` (all XCTest cases pass)
3. `./hung_detect --version`
4. `./hung_detect -v`
5. `make package`
6. `ruby -c Formula/hung-detect.rb`

## Operational Workflow (Now)

For a new release:

1. Update `Sources/hung_detect/Version.swift`
2. Run `make package` (or `make package INCLUDE_DSYM=1` when release artifact should include `.dSYM`)
3. Commit:
   - source changes
   - `dist/hung-detect-<version>-macos-universal.tar.gz`
   - generated `Formula/hung-detect.rb`
4. Push/tag/release

This keeps runtime version, tarball name, and formula metadata synchronized.
