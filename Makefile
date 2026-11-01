# The template repo's own tasks. Driver repos get theirs from template/Makefile.jinja.

# CI's runner has pipx and no uv: there python3 has copier, and pipx runs the formatters.
ifneq ($(shell command -v uvx 2>/dev/null),)
  # An interpreter with copier, and so PyYAML, in it.
  PYTHON   ?= uvx --from copier python
  BLACK    ?= uvx black
  MDFORMAT ?= uvx --with mdformat-gfm mdformat
else
  PYTHON   ?= python3
  BLACK    ?= pipx run black
  MDFORMAT ?= pipx run --spec mdformat --spec mdformat-gfm mdformat
endif

# CI's render and build legs each check one render: tests/template-renders/$(NAME).yml.
NAME ?= default
# Outside this checkout, since copier renders the working tree, untracked files included.
RENDER ?= $(or $(TMPDIR),/tmp)/template-render-$(NAME)
# Absolute, since some steps cd into it.
override RENDER := $(abspath $(RENDER))
RENDER_LUA_PATH = $(RENDER)/test/?.lua;$(RENDER)/src/?.lua;$(RENDER)/src/?/init.lua;$(RENDER)/vendor/?.lua;$(RENDER)/vendor/?/init.lua;;
STYLUA_ARGS := --indent-type Spaces --column-width 120 --line-endings Unix \
  --indent-width 2 --quote-style AutoPreferDouble

# The legs' steps run in order.
.NOTPARALLEL:

.PHONY: help snapshots template-renders invalid-combinations
.PHONY: render render-snapshot render-lib-loads render-crypto render-formatted render-checks
.PHONY: render-example build-idempotent build-readme-images build-encrypted build-cloud-monitoring build-checks

help: ## Show this help
	@grep -E '^[a-z%-]+:.*## ' $(MAKEFILE_LIST) | sed 's/:.*## /\t/'

snapshots: ## Rewrite tests/template-renders/*.files from fresh renders of the working tree
	$(PYTHON) tests/template_renders.py update

template-renders: ## Make and check every template render, and check every invalid combination fails
	$(PYTHON) tests/template_renders.py

invalid-combinations: ## Check every combination in tests/template-renders/invalid fails to render
	$(PYTHON) tests/template_renders.py invalid

# ─── One render: NAME=<tests/template-renders name>, in RENDER ─────────────────

render: ## Render NAME into RENDER, replacing an earlier render there
	$(PYTHON) tests/template_renders.py render $(NAME) "$(RENDER)"

in-render-%: ## Run a make target in the render: in-render-test is `make test` there
	$(MAKE) -C "$(RENDER)" $*

render-snapshot: ## Check the render against its .files snapshot and its answers
	$(PYTHON) tests/template_renders.py check $(NAME) "$(RENDER)"

render-lib-loads: ## Check every src/lib module in the render loads
	cd "$(RENDER)" && LUA_PATH="$(RENDER_LUA_PATH)" luajit "$(CURDIR)/tests/lib_modules_load.lua"

render-crypto: ## Check the render's c4_shim resolves its FFI crypto backend
	cd "$(RENDER)" && LUA_PATH="$(RENDER_LUA_PATH)" luajit "$(CURDIR)/tests/ffi_crypto_backend.lua"

# The render has no .venv (that needs make init), so formatters run standalone.
render-formatted: ## Check the render's Lua, Python and Markdown are formatted
	cd "$(RENDER)" && stylua --check $(STYLUA_ARGS) src test tools vendor
	cd "$(RENDER)" && $(BLACK) --check tools
	cd "$(RENDER)" && $(MDFORMAT) --check --wrap 80 *.md

render-checks: render render-snapshot render-lib-loads render-crypto in-render-test render-formatted ## CI's render leg for NAME

# ─── The example driver built in one render ───────────────────────────────────

render-example: ## Add the example driver to the render
	$(PYTHON) tests/template_renders.py example $(NAME) "$(RENDER)"

build-idempotent: ## In the render: build, commit, build again, and check nothing changed
	$(PYTHON) tests/build_checks.py idempotent "$(RENDER)"

build-readme-images: ## In the built render: every image README.md links exists
	$(PYTHON) tests/build_checks.py readme-images "$(RENDER)"

build-encrypted: ## In the render: a build that substitutes a secret is encrypted
	$(PYTHON) tests/build_checks.py encrypted "$(RENDER)"

build-cloud-monitoring: ## In the render: Cloud Monitoring reaches only the DriverCentral build
	$(PYTHON) tests/build_checks.py cloud-monitoring "$(RENDER)"

build-checks: render render-example in-render-init in-render-check in-render-test build-idempotent build-readme-images build-encrypted build-cloud-monitoring ## CI's build leg for NAME
