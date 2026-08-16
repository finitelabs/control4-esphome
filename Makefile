# Control4 Driver Build System
# Run `make help` for available targets.

DISTRIBUTIONS := drivercentral oss
README_DRIVER := esphome
README_BUILD  := oss

# Paths
VENV       := .venv
VENV_PY    := $(VENV)/bin/python3
VENV_BLACK := $(VENV)/bin/black
VENV_STAMP := $(VENV)/.requirements-installed
PACKAGER   := dist/driverpackager/dp3/driverpackager.py

# OpenSSL detection (cross-platform)
OPENSSL_PREFIX := $(or \
  $(shell pkg-config --variable=prefix openssl 2>/dev/null), \
  $(shell brew --prefix openssl 2>/dev/null))

# Only set paths if we found OpenSSL outside standard locations
ifneq ($(OPENSSL_PREFIX),)
  export LDFLAGS  := -L$(OPENSSL_PREFIX)/lib
  export CFLAGS   := -I$(OPENSSL_PREFIX)/include -DPRAGMA_IGNORE_UNUSED_LABEL= -DPRAGMA_WARN_STRICT_PROTOTYPES=
  export SWIG_FEATURES := -cpperraswarn -I$(OPENSSL_PREFIX)/include
else
  export CFLAGS   := -DPRAGMA_IGNORE_UNUSED_LABEL= -DPRAGMA_WARN_STRICT_PROTOTYPES=
endif

# WeasyPrint (docs PDF) links GObject/Pango/Cairo native libs at runtime. On
# macOS these are Homebrew-installed outside the default dyld search path, so
# point WeasyPrint at them. On Linux (incl. CI) the libs are on the standard
# loader path and no override is needed.
ifeq ($(shell uname -s),Darwin)
  WEASYPRINT_ENV := DYLD_FALLBACK_LIBRARY_PATH=$(shell brew --prefix 2>/dev/null)/lib
else
  WEASYPRINT_ENV :=
endif

# ─── Help ─────────────────────────────────────────────────────────────────────

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# ─── Init ─────────────────────────────────────────────────────────────────────

.PHONY: init check-deps
init: $(VENV_STAMP) $(PACKAGER) ## One-time setup: install all dependencies

# The stamp, not $(VENV), is what everything depends on. A bare `$(VENV):` rule
# is satisfied the moment the directory exists, so packages added by a later
# template release were never installed in an existing checkout -- `make init`
# just said "Nothing to be done" and the build failed later with a bare
# ImportError. Keying the stamp on requirements.txt means a changed dependency
# list re-runs the install. The stamp lives inside $(VENV) so clean-all takes it.
#
# The requirements install is deliberately not --upgrade: it adds what is
# missing and leaves working packages alone, so `make init` cannot drag in a
# breaking upstream release. Version needs belong in requirements.txt as
# constraints, which pip honors either way. Bootstrap tooling (pip, setuptools,
# wheel) is upgraded only when the venv is first created, for the same reason --
# setuptools is M2Crypto's build dependency, and a dependency-list change is no
# reason to bump it underneath a working build.
$(VENV_STAMP): requirements.txt
	@test -x $(VENV_PY) || { \
		python3 -m venv $(VENV) && \
		$(VENV_PY) -m pip install --upgrade pip setuptools wheel; \
	}
	$(VENV_PY) -m pip install -r requirements.txt
	@touch $@

# Safety net for drift the stamp cannot see (hand-removed package, interrupted
# install). Cheap: no network, stdlib only. Installs first if the stamp is
# stale, so this is "make the venv correct and prove it", not a pure read.
check-deps: $(VENV_STAMP) ## Install if needed, then verify the venv satisfies requirements.txt
	@$(VENV_PY) tools/deps.py check requirements.txt $(VENV_STAMP)

$(PACKAGER):
	rm -rf dist/driverpackager
	git clone https://github.com/finitelabs/drivers-driverpackager.git dist/driverpackager

# ─── Format ───────────────────────────────────────────────────────────────────

.PHONY: fmt fmt-lua fmt-py fmt-md
fmt: fmt-lua fmt-py fmt-md ## Format all code

# stylua is a standalone binary (brew install stylua / stylua-action in CI).
fmt-lua:
	@dirs=""; for d in ./drivers ./src ./test ./tools ./vendor; do \
		[ -d "$$d" ] && dirs="$$dirs $$d"; \
	done; \
	[ -z "$$dirs" ] || stylua \
		--indent-type Spaces --column-width 120 --line-endings Unix \
		--indent-width 2 --quote-style AutoPreferDouble \
		-g '*.lua' -v $$dirs

fmt-py: $(VENV_STAMP)
	$(VENV_BLACK) tools/*.py

fmt-md: $(VENV_STAMP)
	@files=""; for g in ./drivers/*/www/documentation/*.md documentation/*.md *.md; do \
		[ -e "$$g" ] && files="$$files $$g"; \
	done; \
	[ -z "$$files" ] || $(VENV_PY) -m mdformat --wrap 80 $$files

# ─── Check ──────────────────────────────────────────────────────────────────
# Assert-only mirror of fmt (--check, no rewrite); this is what CI runs.

.PHONY: check check-lua check-py check-md
check: check-lua check-py check-md ## Assert all code is formatted (no rewrite)

check-lua:
	@dirs=""; for d in ./drivers ./src ./test ./tools ./vendor; do \
		[ -d "$$d" ] && dirs="$$dirs $$d"; \
	done; \
	[ -z "$$dirs" ] || stylua --check \
		--indent-type Spaces --column-width 120 --line-endings Unix \
		--indent-width 2 --quote-style AutoPreferDouble \
		-g '*.lua' $$dirs

check-py: $(VENV_STAMP)
	$(VENV_BLACK) --check tools/*.py

check-md: $(VENV_STAMP)
	@files=""; for g in ./drivers/*/www/documentation/*.md documentation/*.md *.md; do \
		[ -e "$$g" ] && files="$$files $$g"; \
	done; \
	[ -z "$$files" ] || $(VENV_PY) -m mdformat --check --wrap 80 $$files

# ─── Preprocess ───────────────────────────────────────────────────────────────

.PHONY: preprocess
preprocess: ## Run preprocessor for all distributions
	@for build in $(DISTRIBUTIONS); do \
		./tools/preprocess.py --$$build || exit 1; \
	done

# ─── Squishy ──────────────────────────────────────────────────────────────────

.PHONY: gen-squishy
gen-squishy: ## Auto-generate squishy files from .c4zproj
	@for build in $(DISTRIBUTIONS); do \
		for driver_dir in build/$$build/drivers/*/; do \
			(cd "$$driver_dir" && luajit ../../../../tools/gen-squishy.lua) || exit 1; \
		done; \
	done

# ─── Driver XML ───────────────────────────────────────────────────────────────

.PHONY: update-xml update-xml-version update-xml-modified
update-xml: update-xml-version update-xml-modified ## Stamp version + modified in driver.xml

update-xml-version: $(VENV_STAMP)
	@for build in $(DISTRIBUTIONS); do \
		for driver_dir in build/$$build/drivers/*/; do \
			$(VENV_PY) tools/package.py xml-set \
				"$${driver_dir}driver.xml" version "$$(date +'%Y%m%d')"; \
		done; \
	done

update-xml-modified: $(VENV_STAMP)
	@for build in $(DISTRIBUTIONS); do \
		for driver_dir in build/$$build/drivers/*/; do \
			$(VENV_PY) tools/package.py xml-set \
				"$${driver_dir}driver.xml" modified "$$(date +'%m/%d/%Y %I:%M %p')"; \
		done; \
	done

# ─── Docs ─────────────────────────────────────────────────────────────────────

.PHONY: docs docs-html docs-pdf docs-readme
docs: docs-readme docs-html docs-pdf ## Generate all documentation


docs-readme: preprocess $(VENV_STAMP)
	rm -rf ./images
	@if [ -d drivers/$(README_DRIVER)/www/documentation/images ]; then cp -r drivers/$(README_DRIVER)/www/documentation/images .; fi
	$(VENV_PY) tools/docs.py readme \
		build/$(README_BUILD)/drivers/$(README_DRIVER)/www/documentation/index.md README.md


docs-html: $(VENV_STAMP)
	@for build in $(DISTRIBUTIONS); do \
		for driver_dir in build/$$build/drivers/*/; do \
			$(VENV_PY) tools/docs.py md2html \
				"$${driver_dir}www/documentation/index.md" \
				"$${driver_dir}www/documentation"; \
		done; \
	done

docs-pdf: $(VENV_STAMP)
	@for build in $(DISTRIBUTIONS); do \
		mkdir -p "dist/$$build/docs"; \
		for driver_dir in build/$$build/drivers/*/; do \
			if [ -f "$${driver_dir}.variant_pdf" ]; then \
				driver_display_name=$$(cat "$${driver_dir}.variant_pdf"); \
			else \
				driver_display_name=$$($(VENV_PY) tools/package.py xml-get-name "$${driver_dir}driver.xml"); \
			fi; \
			pdf_output="dist/$$build/docs/$$driver_display_name Documentation.pdf"; \
			if [ -f "$$pdf_output" ]; then continue; fi; \
			$(WEASYPRINT_ENV) $(VENV_PY) tools/docs.py html2pdf \
				"$$(pwd)/$${driver_dir}www/documentation/index.html" \
				"$$pdf_output" || exit 1; \
		done; \
	done

# ─── Package ──────────────────────────────────────────────────────────────────

.PHONY: package
# The packager writes the .c4z into the output dir passed here (c4z/); the
# squished .lua goes to source/ via the squishy Output path (see gen-squishy.lua),
# so both subfolders are created up front.
package: $(VENV_STAMP) $(PACKAGER) ## Create .c4z driver packages
	@for build in $(DISTRIBUTIONS); do \
		mkdir -p "dist/$$build/c4z" "dist/$$build/source"; \
		for driver_dir in build/$$build/drivers/*/; do \
			dir=$$(basename "$$driver_dir"); \
			pwd_saved="$$(pwd)"; \
			cd "build/$$build/drivers/$$dir" && \
			"$$pwd_saved/$(VENV_PY)" "$$pwd_saved/$(PACKAGER)" . "$$pwd_saved/dist/$$build/c4z" driver.c4zproj && \
			cd "$$pwd_saved"; \
		done; \
	done

.PHONY: zip
zip: $(VENV_STAMP) ## Zip the c4z/, docs/, and source/ subfolders per distribution
	@repo="$$(basename "$$(pwd)")"; \
	for build in $(DISTRIBUTIONS); do \
		(cd "dist/$$build" && \
			"$(CURDIR)/$(VENV_PY)" "$(CURDIR)/tools/package.py" zip \
				"$$repo.zip" c4z docs source); \
	done

# ─── Test ─────────────────────────────────────────────────────────────────────

.PHONY: test
# test/ is on LUA_PATH and c4_shim is preloaded, matching the environment
# test/run_test.sh sets up. Existing suites are written against that shim and
# fail on a bare `luajit <file>` with "attempt to index global 'C4'". A test that
# defines its own C4 still wins, since it assigns after the preload has run.
test: ## Run the Lua test suite (test/test_*.lua)
	@found=0; \
	for f in test/test_*.lua; do \
		[ -e "$$f" ] || continue; \
		found=1; \
		echo "==> $$f"; \
		LUA_PATH="$(CURDIR)/test/?.lua;$(CURDIR)/src/?.lua;$(CURDIR)/src/?/init.lua;$(CURDIR)/vendor/?.lua;$(CURDIR)/vendor/?/init.lua;;" \
			luajit -e "require('c4_shim')" "$$f" || exit 1; \
	done; \
	if [ "$$found" = "0" ]; then echo "No test/test_*.lua files found; nothing to run."; fi

# ─── Build ────────────────────────────────────────────────────────────────────

.PHONY: build build-nodocs
build: check-deps clean-build fmt preprocess gen-squishy update-xml docs package zip ## Full build

build-nodocs: check-deps clean-build fmt preprocess gen-squishy update-xml package ## Build without docs

# ─── Clean ────────────────────────────────────────────────────────────────────

.PHONY: clean-build clean clean-all
clean-build: ## Remove build artifacts
	rm -rf build
	@for build in $(DISTRIBUTIONS); do rm -rf "dist/$$build"; done

clean: clean-build ## Remove build artifacts and dist
	rm -rf dist

clean-all: clean ## Remove everything (build, dist, deps, venv)
	rm -rf $(VENV)
