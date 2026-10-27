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
- `.github/workflows/release.yml`: tagged GitHub releases. The updater offers a
  release only when its tag's date is later than the installed driver's version,
  so give each release a later date than the last. A suffixed tag such as
  `v20260918-rc1` publishes as a pre-release, which only drivers on the
  Prerelease update channel pick up. Title the pull request that dates the
  changelog `release: vYYYYMMDD` (case and the colon don't matter):
  `.github/workflows/label-release-pr.yml` then labels it `skip-release-notes`,
  which `.github/release.yml` leaves out of the generated release notes. It
  labels a template update the same way: a title like
  `chore: copier update to template vX.Y.Z`, or any pull request opened with a
  change to `_commit` in `.copier-answers.yml`. So keep a template update in a
  pull request of its own, or the changes riding along with it drop out of the
  notes too; if one does ride along, remove the label and it stays off. Adding
  that label by hand leaves any other pull request out of the notes too
- `.github/workflows/stale.yml`: pings inactive issues, then closes them (see
  [Stale Issues](#stale-issues))

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
- `drivers-common-public/`: Control4's official shared libraries
- `xml/`: XML parser (xml2lua)
- `cloud-client-byte.lua`: DriverCentral cloud licensing
- `version.lua`: semver comparison (used by github-updater)
- `bitn.lua`: bit manipulation library
- `crypto.lua`: cryptographic primitives (core build; requires `bitn`)
- `bthome.lua`: BTHome protocol support
- `noiseprotocol.lua`: Noise Protocol encryption
- `protobuf.lua`: Protocol Buffers

**Tools (`tools/`):**

- `preprocess.py`: C-style `#ifdef`/`#ifndef` preprocessor for Lua, XML, and
  Markdown
- `docs.py`: documentation generation (Markdown -> HTML -> PDF, plus README) and
  the Markdown formatting `make fmt` runs
- `package.py`: packaging helpers (driver.xml stamping, zip bundling)
- `deps.py`: build preflight, checks the `.venv` against `requirements.txt`
- `gen-squishy.lua`: auto-generates squishy files from driver.c4zproj
- `github-markdown.css`: vendored stylesheet for the rendered docs
- `github-setup`: checks the GitHub repo against the standard settings and
  prints the drift; `--apply` fixes it
- `test_preprocess.py`: tests for `preprocess.py`'s `#embed` directive

**Other:**

- `.gitignore`, `LICENSE`, `CONTRIBUTING.md`
- `requirements.txt`, the build-time Python dependency list
- `test/testlib.lua`, `test/c4_fixtures.lua`, `test/c4_shim.lua`,
  `test/run_test.sh`, and the `test/test_*.lua` suites covering shared code
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
- `test/` suites written for this driver, and the local support files they
  require (`test/c4_local.lua`, `test/<prefix>_fixtures.lua`)

`README.md` is in neither list: it is **generated**. `make build` rewrites it
from the driver's `www/documentation/index.md`, so edit the source doc, not the
README.

Driver docs can use GitHub's alerts: a quote whose first line is `[!NOTE]`,
`[!TIP]`, `[!IMPORTANT]`, `[!WARNING]` or `[!CAUTION]`. The README, the HTML doc
and the PDF all show them as GitHub does. The marker goes alone on its line, and
the quote must not sit inside a list or another quote; otherwise it stays a
plain quote that shows the marker.

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

## Stale Issues

`.github/workflows/stale.yml` pings an issue that has gone quiet, then closes
it, unless an exempt author opened it. Four copier questions control it:

- `stale_issues`: turns it on. When false, neither the workflow nor this section
  is rendered.
- `stale_exempt_authors` (default empty): space-separated GitHub logins whose
  issues are left alone. Empty exempts no one, and a bot that is not listed is
  treated like anyone else. List a GitHub App as `name[bot]`, the form the issue
  event and the REST API give. `gh issue list --json author` shows the same app
  as `app/name` and GraphQL as `name`, and neither matches.
- `stale_days` (default 30): days without activity before the ping.
- `stale_close_days` (default 14): days after the ping, still without activity,
  before the issue is closed as not planned.

To change one, run `uvx copier update --trust --data '<question>=<value>'`.

When an issue is opened or reopened and its author is not on the list, the
workflow labels it `external`, creating the label if the repo lacks it. A daily
run of `actions/stale` looks only at issues with that label: after `stale_days`
it labels the issue `Stale` and comments, and `stale_close_days` later it closes
it. A comment or any other update removes `Stale` and restarts the clock. Pull
requests are never touched. An issue opened with a workflow's `GITHUB_TOKEN`
starts no workflow, so it is never labelled.

The list is checked only when an issue is opened or reopened. Changing it leaves
existing labels as they are, and issues opened before the workflow was turned on
have none. Add or remove `external` by hand to put an issue on the clock or take
it off; reopening the issue checks the list again.

GitHub disables scheduled workflows in a public repository after 60 days without
activity in it. Re-enable this one from the Actions tab.

In this repo:

- Ping after 30 days without activity
- Close 14 days after the ping
- Exempt authors:
  - `derek-miller`
  - `svc-finitelabs[bot]`

## Build System

This project uses `make` for build orchestration. All tooling is Python (in a
local `.venv`) plus a few standalone binaries, with no Node/npm. A repo that
adds Node tooling of its own pins the version in `.node-version`, which nodenv
reads locally and the Build workflow sets up in CI.

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
make test          # Run the Lua test suite (test/test_*.lua) and tools/test_*.py
make fmt           # Format all code (Lua, Python, Markdown)
make check         # Assert formatting without rewriting; this is what CI runs
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
1. **Zip**: bundle the c4z and docs folders per distribution

The driver.xml step stamps today's date as the version unless `DRIVER_VERSION`
is set. On a tag build CI sets it to the tag's date, so the tag must be
`vYYYYMMDD` or `vYYYYMMDD-suffix` or the build fails.

Each distribution's outputs are grouped by type under `dist/<distribution>/`:
`c4z/` (packaged drivers), `docs/` (generated PDFs) and `source/` (the squished
per-driver Lua). `<repo>.zip` sits alongside them and contains `c4z/` and
`docs/` only: `source/` is the driver's unencrypted Lua, which an encrypted
driver must not ship.

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

## Writing Tests

A test is a plain Lua script in `test/`, named `test_*.lua`, run by `make test`
or `./test/run_test.sh test_something.lua`. There is one convention, and every
suite in this repo follows it.

```lua
local T = require("testlib")

T.section("What is under test")
T.eq("the name of the case", got, want)

T.finish()
```

Three shared modules, split by what they depend on:

- **`testlib.lua`** is the harness: assertions, grouping, and the pass/fail
  pipeline. Plain Lua, no Control4 in it. Always required.
- **`c4_shim.lua`** mocks the Control4 `C4:*` environment. `make test` and
  `run_test.sh` preload it, so a suite that drives driver code gets it for free.
- **`c4_fixtures.lua`** holds the reusable C4 seams built on the shim. Require
  it only when you need one.

### Assertions

Assertions accumulate rather than throw, so one run reports every failure
instead of stopping at the first. Each takes the case name first.

| Call                                     | Passes when                                           |
| ---------------------------------------- | ----------------------------------------------------- |
| `T.check(name, ok, detail)`              | `ok` is truthy; the base the others build on          |
| `T.eq(name, got, want)`                  | `got` equals `want`, comparing tables by value        |
| `T.neq(name, got, unwanted)`             | `got` differs from `unwanted`                         |
| `T.truthy(name, v)` / `T.falsy(name, v)` | `v` is / is not truthy                                |
| `T.contains(name, haystack, needle)`     | `needle` occurs in `haystack`                         |
| `T.excludes(name, haystack, needle)`     | `needle` does not occur                               |
| `T.raises(name, fn, expected)`           | `fn` throws, and the message holds `expected`         |
| `T.raisesAt(name, fn)`                   | `fn` throws with the error blamed on the calling file |

`T.excludes` is the one to reach for when the point is that a secret never
reaches the output, because it reports the offending text on failure.

Supporting calls: `T.section(name)` starts a numbered group, `T.capture(fn)`
runs `fn` with `print` collected and returns `ok, err, output`, and
`T.unload(pattern, ...)` drops matching `package.loaded` entries so the next
`require` rebuilds whatever the module caches.

### Ending a test

`T.finish()` prints the summary and sets the exit code. Do not keep your own
`pass`/`fail` counters, print your own summary, or call `os.exit` yourself.

### C4 fixtures

`c4_fixtures.lua` carries the seams that need the shim:

- `F.withShim(opts, body)` reloads the shim with luasocket forced present or
  absent and restores every global afterwards. With `{ luasocket = true }`,
  `body` gets a clock whose `advance(seconds)` moves time forward and fires
  whatever came due. Returns `ok, err`.
- `F.captureTcpClient()` swaps in a `C4:CreateTCPClient` that records every
  write and completes the connect synchronously. Read `.writes`, then
  `.restore()`.

### Persisted values

As on a controller, a `C4:PersistSetValue` reads back only once it lands, about
50 ms after the call, and until then `C4:PersistGetValue` answers what the store
held. A delete reads back at once, and a write still waiting lands after it. A
value written encrypted reads back only with the encrypted flag, so a suite that
seeds or reads such a key passes the flag the driver does.

The shim lands a write when it moves time on: `ShimFireTimers` lands every write
made before it, `C4:ProcessTimers` each one 50 ms old by its clock, and
`ShimUpdateDriver` and `ShimRestartDirector` all of them. A suite that calls
into the driver itself calls `ShimPersistLand()` where one call ends and the
next begins, such as before a reload, and before it reads what was stored. A
suite that needs a write read back at once calls `ShimPersistLater(false)`.

### Driver-local test support

Support code specific to this driver stays in this repo. Two files mirror the
shared pair above, split by what the code is *about*:

- **`test/c4_local.lua`** for environment seams: a `C4:*` method, or a bare
  global the driver code calls, that the shim does not provide. Reach for this
  instead of adding to `c4_shim.lua`, which the template owns, so anything local
  in there becomes merge surface on every `copier update`.
- **`test/<prefix>_fixtures.lua`** for domain fixtures: mocks shaped like this
  driver's own protocol or API, parallel to `c4_fixtures.lua`. Use a short
  prefix taken from the driver name.

Both `require("c4_shim")` and build on the C4 environment rather than replacing
it. Neither runner needs telling about them: `make test` collects only
`test_*.lua`, and both put `test/` on `LUA_PATH`, so `require("c4_local")`
resolves on its own.

Promote either one into the template only once a second driver needs it.

### Tools tests

`make test` also runs each `tools/test_*.py` with `python3`. These test the
Python tools in `tools/` with the standard library's `unittest` and need no
`.venv`.

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
the generated documentation, and `<!-- #embed <path> -->`, which splices the
file at `<path>`, relative to the file holding the directive. Both run as a
pre-pass, so directives inside the spliced text are still honored. A missing
`<path>`, or an `#embed` inside an embedded file, fails the build.

### Variant Expansion

Drivers can define variants via a `variants.json` file. The preprocessor expands
these into multiple driver directories with substituted values, generating one
.c4z per variant combination. Variants can be listed flat or given as
`dimensions`, in which case the cross-product is expanded.

Substitute a variant value with `__NAME__`, or with `%%NAME%%` in Markdown,
where `__NAME__` would render as bold instead. In `.c4zproj` files,
`--#variant-filenames <template>` emits one filename line per generated variant.

`readme_driver_slug` may name a generated variant, e.g. `<driver>_<suffix>`.
`make build` takes the README and its images from the build output, where only
the generated variants exist.

### Build Secrets

Values that must not live in the repository, such as a cloud API's OAuth client
secret, are substituted into the build tree at preprocess time. Each one is a
`__NAME__` placeholder in source (`%%NAME%%` in Markdown), the same syntax as a
variant value:

```lua
API_CLIENT_SECRET = "__EXAMPLE_CLIENT_SECRET__"
```

`.env.default`, committed at the repository root, declares every name, one
`NAME=` line each, with a comment saying what it is and where to get it. A repo
without it has no build secrets. `tools/preprocess.py` reads only the declared
names, and takes each value from, in order:

1. the process environment
1. `.env`, gitignored: for a local build, `cp .env.default .env` and fill it in

In CI, the Build workflow writes `.env` from the repository's GitHub Actions
secrets (add each name under Settings > Secrets and variables > Actions) in a
step of its own, copying only the names `.env.default` declares, so `make build`
and the tools it runs never see any other secret. Each value is a single line.

A name with no value builds as an empty string with a warning, so a pull request
from a fork, which gets no secrets, still builds. A tag build sets
`REQUIRE_SECRETS`, and a missing value fails it, so a release never ships
without them. The build log says only whether each name was set.

When a build substitutes any placeholder, every driver in it is packaged
encrypted (`encryption="2"` on its `<script>`, set in the build copy of
`driver.xml`), and `make package` deletes the plain-text squished Lua in
`dist/<build>/source`, so neither the `.c4z` nor a CI artifact carries the value
in the clear. Only `build/` keeps it, and that is gitignored and never uploaded.
Keep placeholders out of documentation: a PDF is not encrypted.
