# The template repo's own tasks. Driver repos get theirs from template/Makefile.jinja.

# An interpreter with copier, and so PyYAML, in it.
PYTHON ?= uvx --from copier python

.PHONY: help snapshots template-renders

help: ## Show this help
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | sed 's/:.*## /\t/'

snapshots: ## Rewrite tests/template-renders/*.files from fresh renders of the working tree
	$(PYTHON) tests/template_renders.py update

template-renders: ## Make and check every template render, and check every invalid combination fails
	$(PYTHON) tests/template_renders.py
