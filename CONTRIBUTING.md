# Contributing to control4-esphome

## Project Structure

This project uses [Copier](https://copier.readthedocs.io/) to manage shared
infrastructure across multiple Control4 driver repositories. Shared code lives
in a [template repo](https://github.com/finitelabs/control4-driver-template) and
is synced into each driver project.

### What's Managed by the Template

These files are owned by the template and **should not be edited directly** in
this repo. Change them in the
[template repo](https://github.com/finitelabs/control4-driver-template) instead,
then pull the change in with `copier update`.

**Build tooling:**

- `Makefile`: build, format, docs, package, and clean targets
- `.github/workflows/build.yml`: CI build and packaging
- `.github/workflows/release.yml`: tagged GitHub releases

**Common libraries (`src/lib/`):**

- `bindings.lua`: binding management
- `conditionals.lua`: conditional/programming UI management
- `events.lua`: event firing and management
- `http.lua`: HTTP client wrapper
- `logging.lua`: structured logging with configurable levels
- `lru.lua`: LRU cache utility
- `persist.lua`: persistent storage abstraction
- `utils.lua`: general utilities (XML, device queries, table helpers, type
  coercion)
- `values.lua`: value parsing, coercion, and formatting
- `github-updater.lua`: GitHub Releases self-updater (non-DriverCentral builds)

**Vendor libraries (`vendor/`):**

- `JSON.lua`: JSON encoder/decoder
- `deferred.lua`: promises/deferred implementation
- `cloud-client-byte.lua`: DriverCentral cloud licensing
- `version.lua`: semver comparison (used by github-updater)
- `drivers-common-public/`: Control4's official shared libraries
- `xml/`: XML parser (xml2lua)
- `bitn.lua`: bit manipulation library
- `crypto.lua`: cryptographic primitives (core build; requires `bitn`)
- `bthome.lua`: BTHome protocol support
- `noiseprotocol.lua`: Noise Protocol encryption
- `protobuf.lua`: Protocol Buffers

**Tools (`tools/`):**

- `preprocess.py`: C-style `#ifdef`/`#ifndef` preprocessor for Lua, XML, and
  Markdown
- `docs.py`: documentation generation (Markdown -> HTML -> PDF, plus README)
- `package.py`: packaging helpers (driver.xml stamping, zip bundling)
- `deps.py`: build preflight, checks the `.venv` against `requirements.txt`
- `gen-squishy.lua`: auto-generates squishy files from driver.c4zproj
- `github-markdown.css`: vendored stylesheet for the rendered docs
- `github-setup`: checks the GitHub repo against the standard settings and
  prints the drift; `--apply` fixes it

**Other:**

- `.gitignore`, `LICENSE`, `CONTRIBUTING.md`
- `requirements.txt`, the build-time Python dependency list
- `test/c4_shim.lua`, `test/run_test.sh`
- `.copier-answers.yml`, which Copier maintains; never edit it by hand

### What's Driver-Specific (Yours to Edit)

- `src/constants.lua`: driver-specific constants
- `drivers/*/driver.lua`: main driver logic
- `drivers/*/driver.xml`: driver XML configuration
- `drivers/*/driver.c4zproj`: driver packaging manifest
- `drivers/*/www/`: documentation and icons
- `CHANGELOG.md`, seeded by the template on first render and left alone after
  that
- Any additional `src/` modules specific to this driver
- Any additional `vendor/` libraries specific to this driver

`README.md` is in neither list: it is **generated**. `make build` rewrites it
from the driver's `www/documentation/index.md`, so edit the source doc, not the
README.

## Updating Shared Code

Copier is only needed for this occasional sync. It is **not** a build dependency
and is intentionally not installed by `make init`, so run it without installing
anything:

```bash
uvx copier update --trust        # using uv (https://docs.astral.sh/uv/)
# or:
pipx run copier update --trust   # using pipx
```

Copier shows diffs for any files that changed and lets you resolve conflicts. It
tracks which template version you're on via the `.copier-answers.yml` file
(committed to the repo). To update every driver repo, run the same command in
each one.

## Build System

This project uses `make` for build orchestration. All tooling is Python (in a
local `.venv`) plus a few standalone binaries, with no Node/npm.

### Prerequisites

- Python 3.9+ (docs, formatters, preprocess, and driverpackager)
- Git, since `make init` clones the driverpackager into `dist/`
- [LuaJIT](https://luajit.org/) (`brew install luajit`) to run
  `tools/gen-squishy.lua` and the tests
- [stylua](https://github.com/JohnnyMorganz/StyLua) (`brew install stylua`), the
  Lua formatter
- [Pango](https://gtk.org/) (`brew install pango`), WeasyPrint's PDF rendering
  engine
- `swig` and OpenSSL headers (`brew install swig openssl`), which M2Crypto
  compiles against

`make init` creates the `.venv`, installs everything in `requirements.txt`
(WeasyPrint, markdown-it-py, mdit-py-plugins, Pygments, mdformat, black, and the
driverpackager's M2Crypto + lxml), and clones the driverpackager into
`dist/driverpackager`. It is safe (and cheap) to re-run: the install is keyed on
`requirements.txt`, so a template update that adds a dependency reinstalls on
the next `make init` or `make build` rather than leaving the existing `.venv`
stale.

### Common Commands

```bash
make help          # List every pipeline step, plus init/build/fmt/clean
make init          # Install all dependencies (safe to re-run)
make check-deps    # Install if needed, then verify .venv matches requirements.txt
make build         # Full build, from clean through zip (see Build Pipeline)
make build-nodocs  # Build without generating docs
make fmt           # Format all code (Lua, Python, Markdown)
make clean         # Remove build artifacts and dist/ (including driverpackager)
make clean-all     # Remove everything (build artifacts, dist, deps, venv)
```

Every step in the pipeline below is also a target of its own, and `make help`
lists them all. The sub-targets those steps delegate to (`fmt-lua`, `fmt-py`,
`fmt-md`, `docs-html`, `docs-pdf`, `docs-readme`, `update-xml-version`,
`update-xml-modified`) are real targets too, but carry no `##` annotation, so
`make help` does not print them. Note that the later steps read `build/`:
`make docs` pulls in `preprocess` itself, but `make package` and `make zip` fail
on a clean tree until something has populated `build/`.

### Build Pipeline

`make build` runs these in order, starting from a cleaned `build/`:

1. **Format**: stylua (Lua), black (Python), mdformat (Markdown)
1. **Preprocess**: resolve `#ifdef`/`#ifndef` directives per distribution
1. **Generate squishy**: create squish manifests from .c4zproj files
1. **Update driver.xml**: stamp version date and modified timestamp
1. **Generate docs**: Markdown -> HTML -> PDF, plus README
1. **Package**: run driverpackager to create .c4z files
1. **Zip**: bundle .c4z and .pdf files per distribution

Step 1 rewrites tracked files in place. Formatting covers `tools/*.py`, all Lua
under `drivers/`, `src/`, `test/`, `tools/` and `vendor/`, and every Markdown
file at the repo root, under `documentation/`, and under
`drivers/*/www/documentation/`, so it reformats this file, the driver docs you
author, and the generated `README.md` too. CI fails the build if it finishes
with a dirty tree, so build on a clean checkout and commit whatever the
formatter changes.

### Distributions

Builds are configured for these distributions: `drivercentral oss`

Each one produces its own set of .c4z driver files, with code paths selected by
`#ifdef` directives (for example `#ifdef DRIVERCENTRAL` vs `#ifdef OSS`). The
preprocessor recognizes three distributions: `drivercentral` and
`drivercentral-dev` (which both define `DRIVERCENTRAL`, the latter also
`DRIVERCENTRAL_DEV`) and `oss` (which defines `OSS`). Any other token in the
answers file fails the build.

## Preprocessor Directives

The `tools/preprocess.py` script supports C-style conditional compilation. It
walks every file in the build tree and matches four comment styles: Lua (`--#`),
XML and Markdown (`<!-- # -->`), C and JavaScript (`// #`), and bare `#`
directives with no comment prefix.

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

It also resolves `<!-- #embed-changelog -->`, which splices `CHANGELOG.md` into
the generated documentation. That runs as a pre-pass, so directives inside the
changelog are still honored.

### Variant Expansion

Drivers can define variants via a `variants.json` file. The preprocessor expands
these into multiple driver directories with substituted values, generating one
.c4z per variant combination. Variants can be listed flat or given as
`dimensions`, in which case the cross-product is expanded.

Substitute a variant value with `__NAME__`, or with `%%NAME%%` in Markdown,
where `__NAME__` would render as bold instead. In `.c4zproj` files,
`--#variant-filenames <template>` emits one filename line per generated variant.
