# The template repo's own tasks. Driver repos get theirs from template/Makefile.jinja.
# Run `make help` for available targets.

# An interpreter with copier, and so PyYAML, in it. CI's runner has no uv, and the
# workflow installs copier into its python3.
ifneq ($(shell command -v uvx 2>/dev/null),)
  PYTHON ?= uvx --from copier python
else
  PYTHON ?= python3
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
# CI's render leg is `make render-checks`; each of its steps is a target of its own.

.PHONY: render render-snapshot render-lib-loads render-crypto render-ui-js render-checks
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

render-ui-js: ## Check the render's lib/ui scripts under Node, each one the render ships
	@if [ -f "$(RENDER)/src/lib/ui/page.js" ]; then \
		for kit in page variables expressions expressions-demo; do \
			if [ -f "$(RENDER)/src/lib/ui/$$kit.js" ]; then \
				UI_DIR="$(RENDER)/src/lib/ui" node --test "tests/ui_$$(echo $$kit | tr - _)_js.test.mjs" || exit 1; \
			fi; \
		done; \
	else echo "This render has no lib/ui."; fi

RENDER_LEG := render render-snapshot render-lib-loads render-crypto render-ui-js in-render-test
render-checks: $(RENDER_LEG) ## Run CI's render leg for NAME

# ─── Build leg ────────────────────────────────────────────────────────────────
# CI's build leg is `make build-checks`: the example driver, built in the render.

.PHONY: build-driverless render-example build-doc-alerts build-idempotent build-readme-images build-encrypted build-cloud-monitoring build-ui-page build-checks
build-driverless: ## Check the render, before it has a driver, builds and verifies nothing
	$(PYTHON) tests/build_checks.py driverless "$(RENDER)"

render-example: ## Add the example driver to the render
	$(PYTHON) tests/template_renders.py example $(NAME) "$(RENDER)"

build-doc-alerts: ## Check the render's docs.py renders each GitHub alert
	$(PYTHON) tests/build_checks.py doc-alerts "$(RENDER)"

build-idempotent: ## Check a second make build in the render changes nothing
	$(PYTHON) tests/build_checks.py idempotent "$(RENDER)"

build-readme-images: ## Check every image the built README.md links exists
	$(PYTHON) tests/build_checks.py readme-images "$(RENDER)"

build-encrypted: ## Check a build that substitutes a secret is encrypted
	$(PYTHON) tests/build_checks.py encrypted "$(RENDER)"

build-cloud-monitoring: ## Check Cloud Monitoring reaches only the DriverCentral build
	$(PYTHON) tests/build_checks.py cloud-monitoring "$(RENDER)"

build-ui-page: ## Check a page that embeds lib/ui ships the kit inline
	$(PYTHON) tests/build_checks.py ui-page "$(RENDER)"

BUILD_LEG := render build-driverless render-example in-render-init build-doc-alerts in-render-check in-render-test \
  build-idempotent build-readme-images build-encrypted build-cloud-monitoring build-ui-page
build-checks: $(BUILD_LEG) ## Run CI's build leg for NAME
