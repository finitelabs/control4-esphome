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

# ─── Help ─────────────────────────────────────────────────────────────────────

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# ─── Init ─────────────────────────────────────────────────────────────────────

.PHONY: init
init: node_modules $(VENV) $(PACKAGER) ## One-time setup: install all dependencies

node_modules: package.json
	npm install
	@touch $@

$(VENV):
	python3 -m venv $(VENV)
	$(VENV_PY) -m pip install --upgrade pip setuptools wheel M2Crypto lxml black copier

$(PACKAGER):
	rm -rf dist/driverpackager
	git clone https://github.com/finitelabs/drivers-driverpackager.git dist/driverpackager

# ─── Format ───────────────────────────────────────────────────────────────────

.PHONY: fmt fmt-lua fmt-py fmt-md
fmt: fmt-lua fmt-py fmt-md ## Format all code

fmt-lua: node_modules
	npx stylua \
		--indent-type Spaces --column-width 120 --line-endings Unix \
		--indent-width 2 --quote-style AutoPreferDouble \
		-g '*.lua' -v ./drivers ./src ./test ./tools ./vendor

fmt-py:
	$(VENV_BLACK) tools/preprocess

fmt-md: node_modules
	npx prettier --prose-wrap always --write ./drivers/**/www/**/*.md *.md

# ─── Preprocess ───────────────────────────────────────────────────────────────

.PHONY: preprocess
preprocess: ## Run preprocessor for all distributions
	@for build in $(DISTRIBUTIONS); do \
		./tools/preprocess --$$build || exit 1; \
	done

# ─── Squishy ──────────────────────────────────────────────────────────────────

.PHONY: gen-squishy
gen-squishy: ## Auto-generate squishy files from .c4zproj
	@for build in $(DISTRIBUTIONS); do \
		for driver_dir in build/$$build/drivers/*/; do \
			(cd "$$driver_dir" && lua ../../../../tools/gen-squishy.lua) || exit 1; \
		done; \
	done

# ─── Driver XML ───────────────────────────────────────────────────────────────

.PHONY: update-xml update-xml-version update-xml-modified
update-xml: update-xml-version update-xml-modified ## Stamp version + modified in driver.xml

update-xml-version:
	@for build in $(DISTRIBUTIONS); do \
		for driver_dir in build/$$build/drivers/*/; do \
			xmlstarlet edit --inplace --omit-decl \
				--update '/devicedata/version' --value "$$(date +'%Y%m%d')" \
				"$${driver_dir}driver.xml"; \
		done; \
	done

update-xml-modified:
	@for build in $(DISTRIBUTIONS); do \
		for driver_dir in build/$$build/drivers/*/; do \
			xmlstarlet edit --inplace --omit-decl \
				--update '/devicedata/modified' --value "$$(date +'%m/%d/%Y %I:%M %p')" \
				"$${driver_dir}driver.xml"; \
		done; \
	done

# ─── Docs ─────────────────────────────────────────────────────────────────────

.PHONY: docs docs-html docs-pdf docs-readme
docs: docs-readme docs-html docs-pdf ## Generate all documentation


docs-readme:
	rm -rf ./images
	cp -r drivers/$(README_DRIVER)/www/documentation/images .
	pandoc build/$(README_BUILD)/drivers/$(README_DRIVER)/www/documentation/index.md \
		-f gfm -t gfm --lua-filter=tools/pandoc-remove-style.lua -o README.md


docs-html: node_modules
	@for build in $(DISTRIBUTIONS); do \
		for driver_dir in build/$$build/drivers/*/; do \
			npx generate-md --layout github \
				--input "$${driver_dir}www/documentation/index.md" \
				--output "$${driver_dir}www/documentation"; \
		done; \
	done

docs-pdf: node_modules
	@for build in $(DISTRIBUTIONS); do \
		mkdir -p "dist/$$build"; \
		for driver_dir in build/$$build/drivers/*/; do \
			if [ -f "$${driver_dir}.variant_pdf" ]; then \
				driver_display_name=$$(cat "$${driver_dir}.variant_pdf"); \
			else \
				driver_display_name=$$(xmlstarlet sel -t -v '/devicedata/name' "$${driver_dir}driver.xml"); \
			fi; \
			pdf_output="dist/$$build/$$driver_display_name Documentation.pdf"; \
			if [ -f "$$pdf_output" ]; then continue; fi; \
			npx electron-pdf --marginsType 0 \
				--input "$$(pwd)/$${driver_dir}www/documentation/index.html" \
				--output "$$pdf_output"; \
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
zip: ## Zip .c4z and .pdf files per distribution
	@for build in $(DISTRIBUTIONS); do \
		cd "dist/$$build" && \
		zip "$$(basename "$$(realpath "$$(pwd)/../../")").zip" *.c4z *.pdf && \
		cd ../../; \
	done

# ─── Build ────────────────────────────────────────────────────────────────────

.PHONY: build build-nodocs
build: clean-build preprocess gen-squishy update-xml docs fmt package zip ## Full build

build-nodocs: clean-build preprocess gen-squishy update-xml fmt package ## Build without docs

# ─── Clean ────────────────────────────────────────────────────────────────────

.PHONY: clean-build clean clean-all
clean-build: ## Remove build artifacts
	rm -rf build
	@for build in $(DISTRIBUTIONS); do rm -rf "dist/$$build"; done

clean: clean-build ## Remove build artifacts and dist
	rm -rf dist

clean-all: clean ## Remove everything (build, dist, deps, venv)
	rm -rf node_modules $(VENV)
