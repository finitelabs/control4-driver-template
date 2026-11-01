# The template repo's own tasks. Driver repos get theirs from template/Makefile.jinja.
# Run `make help` for available targets.

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
NAME   ?= default
# Outside this checkout, since copier renders the working tree, untracked files included.
RENDER ?= $(or $(TMPDIR),/tmp)/template-render-$(NAME)
# Absolute, since some steps cd into it.
override RENDER := $(abspath $(RENDER))

# A leg's steps run in order.
.NOTPARALLEL:

# ─── Help ─────────────────────────────────────────────────────────────────────

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z%_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2}'

# ─── Template renders ─────────────────────────────────────────────────────────

.PHONY: template-renders snapshots invalid-combinations
template-renders: ## Make and check every template render, and check every invalid combination fails
	$(PYTHON) tests/template_renders.py

snapshots: ## Rewrite tests/template-renders/*.files from fresh renders of the working tree
	$(PYTHON) tests/template_renders.py update

invalid-combinations: ## Check every combination in tests/template-renders/invalid fails to render
	$(PYTHON) tests/template_renders.py invalid

# ─── Render leg ───────────────────────────────────────────────────────────────
# Each target is one step of CI's render leg, on the render of NAME in RENDER.

.PHONY: render render-snapshot render-lib-loads render-crypto render-formatted render-checks
render: ## Render NAME into RENDER, replacing an earlier render there
	$(PYTHON) tests/template_renders.py render $(NAME) "$(RENDER)"

in-render-%: ## Run a make target in the render: in-render-test is `make test` there
	$(MAKE) -C "$(RENDER)" $*

render-snapshot: ## Check the render against its .files snapshot and its answers
	$(PYTHON) tests/template_renders.py check $(NAME) "$(RENDER)"

render-lib-loads: ## Check every src/lib module in the render loads
	"$(RENDER)/test/run_test.sh" "$(CURDIR)/tests/lib_modules_load.lua"

render-crypto: ## Check the render's c4_shim resolves its FFI crypto backend
	"$(RENDER)/test/run_test.sh" "$(CURDIR)/tests/ffi_crypto_backend.lua"

# The render has no .venv (that needs make init), so black and mdformat run standalone.
render-formatted: ## Check the render's Lua, Python and Markdown are formatted
	$(MAKE) -C "$(RENDER)" check-lua
	cd "$(RENDER)" && $(BLACK) --check tools
	cd "$(RENDER)" && $(MDFORMAT) --check --wrap 80 *.md

RENDER_LEG := render render-snapshot render-lib-loads render-crypto in-render-test render-formatted
render-checks: $(RENDER_LEG) ## Run CI's render leg for NAME

# ─── Build leg ────────────────────────────────────────────────────────────────
# Each target is one step of CI's build leg: the example driver, built in the render.

.PHONY: render-example build-idempotent build-readme-images build-encrypted build-cloud-monitoring build-checks
render-example: ## Add the example driver to the render
	$(PYTHON) tests/template_renders.py example $(NAME) "$(RENDER)"

build-idempotent: ## Check a second make build in the render changes nothing
	$(PYTHON) tests/build_checks.py idempotent "$(RENDER)"

build-readme-images: ## Check every image the built README.md links exists
	$(PYTHON) tests/build_checks.py readme-images "$(RENDER)"

build-encrypted: ## Check a build that substitutes a secret is encrypted
	$(PYTHON) tests/build_checks.py encrypted "$(RENDER)"

build-cloud-monitoring: ## Check Cloud Monitoring reaches only the DriverCentral build
	$(PYTHON) tests/build_checks.py cloud-monitoring "$(RENDER)"

BUILD_LEG := render render-example in-render-init in-render-check in-render-test \
  build-idempotent build-readme-images build-encrypted build-cloud-monitoring
build-checks: $(BUILD_LEG) ## Run CI's build leg for NAME
