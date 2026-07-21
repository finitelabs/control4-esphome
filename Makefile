# Control4 Driver Build System
# Run `make help` for available targets.

DISTRIBUTIONS := drivercentral oss
README_DRIVER := esphome
README_BUILD  := oss

# Paths
VENV       := .venv
VENV_PY    := $(VENV)/bin/python3
VENV_BLACK := $(VENV)/bin/black
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

.PHONY: init
init: $(VENV) $(PACKAGER) ## One-time setup: install all dependencies

# M2Crypto + lxml are required by the driverpackager (dist/driverpackager).
# Everything else is our own tooling: docs (weasyprint + markdown-it-py +
# mdit-py-plugins + pygments) and formatters (black for Python, mdformat for
# Markdown). Lua formatting uses the stylua binary (see fmt-lua).
$(VENV):
	python3 -m venv $(VENV)
	$(VENV_PY) -m pip install --upgrade pip setuptools wheel \
		M2Crypto lxml \
		weasyprint markdown-it-py[linkify] mdit-py-plugins pygments \
		black mdformat mdformat-gfm

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

fmt-py: $(VENV)
	$(VENV_BLACK) tools/*.py

fmt-md: $(VENV)
	@files=""; for g in ./drivers/*/www/documentation/*.md documentation/*.md *.md; do \
		[ -e "$$g" ] && files="$$files $$g"; \
	done; \
	[ -z "$$files" ] || $(VENV_PY) -m mdformat --wrap 80 $$files

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

update-xml-version:
	@for build in $(DISTRIBUTIONS); do \
		for driver_dir in build/$$build/drivers/*/; do \
			$(VENV_PY) tools/package.py xml-set \
				"$${driver_dir}driver.xml" version "$$(date +'%Y%m%d')"; \
		done; \
	done

update-xml-modified:
	@for build in $(DISTRIBUTIONS); do \
		for driver_dir in build/$$build/drivers/*/; do \
			$(VENV_PY) tools/package.py xml-set \
				"$${driver_dir}driver.xml" modified "$$(date +'%m/%d/%Y %I:%M %p')"; \
		done; \
	done

# ─── Docs ─────────────────────────────────────────────────────────────────────

.PHONY: docs docs-html docs-pdf docs-readme
docs: docs-readme docs-html docs-pdf ## Generate all documentation


docs-readme: preprocess $(VENV)
	rm -rf ./images
	@if [ -d drivers/$(README_DRIVER)/www/documentation/images ]; then cp -r drivers/$(README_DRIVER)/www/documentation/images .; fi
	$(VENV_PY) tools/docs.py readme \
		build/$(README_BUILD)/drivers/$(README_DRIVER)/www/documentation/index.md README.md


docs-html: $(VENV)
	@for build in $(DISTRIBUTIONS); do \
		for driver_dir in build/$$build/drivers/*/; do \
			$(VENV_PY) tools/docs.py md2html \
				"$${driver_dir}www/documentation/index.md" \
				"$${driver_dir}www/documentation"; \
		done; \
	done

docs-pdf: $(VENV)
	@for build in $(DISTRIBUTIONS); do \
		mkdir -p "dist/$$build"; \
		for driver_dir in build/$$build/drivers/*/; do \
			if [ -f "$${driver_dir}.variant_pdf" ]; then \
				driver_display_name=$$(cat "$${driver_dir}.variant_pdf"); \
			else \
				driver_display_name=$$($(VENV_PY) tools/package.py xml-get-name "$${driver_dir}driver.xml"); \
			fi; \
			pdf_output="dist/$$build/$$driver_display_name Documentation.pdf"; \
			if [ -f "$$pdf_output" ]; then continue; fi; \
			$(WEASYPRINT_ENV) $(VENV_PY) tools/docs.py html2pdf \
				"$$(pwd)/$${driver_dir}www/documentation/index.html" \
				"$$pdf_output" || exit 1; \
		done; \
	done

# ─── Package ──────────────────────────────────────────────────────────────────

.PHONY: package
package: $(PACKAGER) ## Create .c4z driver packages
	@for build in $(DISTRIBUTIONS); do \
		for driver_dir in build/$$build/drivers/*/; do \
			dir=$$(basename "$$driver_dir"); \
			pwd_saved="$$(pwd)"; \
			cd "build/$$build/drivers/$$dir" && \
			"$$pwd_saved/$(VENV_PY)" "$$pwd_saved/$(PACKAGER)" . "$$pwd_saved/dist/$$build" driver.c4zproj && \
			cd "$$pwd_saved"; \
		done; \
	done

.PHONY: zip
zip: $(VENV) ## Zip .c4z and .pdf files per distribution
	@repo="$$(basename "$$(pwd)")"; \
	for build in $(DISTRIBUTIONS); do \
		(cd "dist/$$build" && \
			"$(CURDIR)/$(VENV_PY)" "$(CURDIR)/tools/package.py" zip \
				"$$repo.zip" *.c4z *.pdf); \
	done

# ─── Build ────────────────────────────────────────────────────────────────────

.PHONY: build build-nodocs
build: clean-build fmt preprocess gen-squishy update-xml docs package zip ## Full build

build-nodocs: clean-build fmt preprocess gen-squishy update-xml package ## Build without docs

# ─── Clean ────────────────────────────────────────────────────────────────────

.PHONY: clean-build clean clean-all
clean-build: ## Remove build artifacts
	rm -rf build
	@for build in $(DISTRIBUTIONS); do rm -rf "dist/$$build"; done

clean: clean-build ## Remove build artifacts and dist
	rm -rf dist

clean-all: clean ## Remove everything (build, dist, deps, venv)
	rm -rf $(VENV)
