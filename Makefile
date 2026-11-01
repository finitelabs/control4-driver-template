# The template repo's own tasks. Driver repos get theirs from template/Makefile.jinja.

# An interpreter with copier, and so PyYAML, in it.
PYTHON ?= uvx --from copier python

.PHONY: help renders snapshots

help: ## Show this help
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | sed 's/:.*## /\t/'

snapshots: ## Rewrite tests/renders/*.files from fresh renders of the working tree
	$(PYTHON) tests/renders.py update

renders: ## Make and check every test render, and check every invalid combination fails
	$(PYTHON) tests/renders.py
