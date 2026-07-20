# Contributing to control4-esphome

## Project Structure

This project uses [Copier](https://copier.readthedocs.io/) to manage shared
infrastructure across multiple Control4 driver repositories. Shared code lives
in a [template repo](https://github.com/finitelabs/control4-driver-template) and
is synced into each driver project.

### What's Managed by the Template

The following files are maintained via the template and **should not be edited
directly** in this repo. Changes to these files should be made in the
[template repo](https://github.com/finitelabs/control4-driver-template) and
synced with `copier update`.

**Build tooling:**

- `Makefile` — build, format, docs, package, and clean targets
- `package.json` — npm dependency declarations only (no scripts)

**Common libraries (`src/lib/`):**

- `bindings.lua` — binding management
- `conditionals.lua` — conditional/programming UI management
- `events.lua` — event firing and management
- `http.lua` — HTTP client wrapper
- `logging.lua` — structured logging with configurable levels
- `lru.lua` — LRU cache utility
- `persist.lua` — persistent storage abstraction
- `utils.lua` — general utilities (XML, device queries, table helpers, type
  coercion)
- `values.lua` — value parsing, coercion, and formatting
- `github-updater.lua` — GitHub Releases self-updater (non-DriverCentral builds)

**Vendor libraries (`vendor/`):**

- `JSON.lua` — JSON encoder/decoder
- `deferred.lua` — promises/deferred implementation
- `cloud-client-byte.lua` — DriverCentral cloud licensing
- `version.lua` — semver comparison (used by github-updater)
- `drivers-common-public/` — Control4's official shared libraries
- `xml/` — XML parser (xml2lua)
- `bitn.lua` — bit manipulation library
- `crypto.lua` — cryptographic primitives (core build; requires `bitn`)
- `bthome.lua` — BTHome protocol support
- `noiseprotocol.lua` — Noise Protocol encryption
- `protobuf.lua` — Protocol Buffers

**Tools (`tools/`):**

- `preprocess` — C-style `#ifdef`/`#ifndef` preprocessor for Lua, XML, and
  Markdown
- `gen-squishy.lua` — auto-generates squishy files from driver.c4zproj
- `pandoc-remove-style.lua` — Pandoc filter for README generation

**Other:**

- `.gitignore`, `LICENSE`, `CONTRIBUTING.md`
- `test/c4_shim.lua`, `test/run_test.sh`

### What's Driver-Specific (Yours to Edit)

- `src/constants.lua` — driver-specific constants
- `drivers/*/driver.lua` — main driver logic
- `drivers/*/driver.xml` — driver XML configuration
- `drivers/*/driver.c4zproj` — driver packaging manifest
- `drivers/*/www/` — documentation and icons
- `CHANGELOG.md`, `README.md`
- Any additional `src/` modules specific to this driver
- Any additional `vendor/` libraries specific to this driver

## Updating Shared Code

When the template is updated, sync changes into this repo:

```bash
copier update --trust
```

Copier will show diffs for any files that changed and let you resolve conflicts.
It tracks which template version you're on via the `.copier-answers.yml` file
(committed to the repo).

To update shared code for **all** driver repos, run `copier update` in each one.

## Build System

This project uses `make` for build orchestration and `npm` only for JavaScript
dependency management.

### Prerequisites

- Python 3.9+ (for preprocess and driverpackager)
- Node.js / npm (for formatter and doc dependencies)
- [xmlstarlet](https://xmlstarlet.sourceforge.net/) (`brew install xmlstarlet`)
- [LuaJIT](https://luajit.org/) (`brew install luajit`) — for squish and tests
- [Pandoc](https://pandoc.org/) (`brew install pandoc`) — for README generation

### Common Commands

```bash
make init          # One-time setup: install all dependencies
make build         # Full build: format, preprocess, docs, package, zip
make build-nodocs  # Build without generating docs
make fmt           # Format all code (Lua, Python, Markdown)
make clean         # Remove build artifacts
make clean-all     # Remove everything (build artifacts, deps, venv)
```

### Build Pipeline

1. **Format** — stylua (Lua), black (Python), prettier (Markdown)
2. **Preprocess** — resolve `#ifdef`/`#ifndef` directives per distribution
3. **Generate squishy** — create squish manifests from .c4zproj files
4. **Update driver.xml** — stamp version date and modified timestamp
5. **Generate docs** — Markdown -> HTML -> PDF, plus README
6. **Package** — run driverpackager to create .c4z files
7. **Zip** — bundle .c4z and .pdf files per distribution

### Distributions

Builds are configured for these distributions: `drivercentral oss`

Each distribution produces its own set of .c4z driver files with
distribution-specific code paths controlled by `#ifdef` directives (e.g.,
`#ifdef DRIVERCENTRAL` vs `#ifdef OSS`).

## Preprocessor Directives

The `tools/preprocess` script supports C-style conditional compilation in Lua,
XML, and Markdown:

```lua
--#ifdef DRIVERCENTRAL
DC_PID = 1234
DC_FILENAME = "driver.c4z"
--#else
DRIVER_GITHUB_REPO = "finitelabs/control4-esphome"
--#endif
```

```xml
<!-- #ifdef DRIVERCENTRAL -->
<Driver type="c4z" name="driver_dc" squishLua="true">
<!-- #else -->
<Driver type="c4z" name="driver" squishLua="true">
<!-- #endif -->
```

### Variant Expansion

Drivers can define variants via a `variants.json` file. The preprocessor expands
these into multiple driver directories with substituted values, generating one
.c4z per variant combination.
