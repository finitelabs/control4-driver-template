# The template repo's own tasks. Driver repos get theirs from template/Makefile.jinja.

# An interpreter with copier, and so PyYAML, in it.
PYTHON ?= uvx --from copier python

.PHONY: help snapshots variants

help: ## Show this help
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | sed 's/:.*## /\t/'

snapshots: ## Rewrite tests/variants/*.files from fresh renders of the working tree
	$(PYTHON) tests/variants.py update

variants: ## Render and check every variant, and check every invalid combination fails
	$(PYTHON) tests/variants.py
