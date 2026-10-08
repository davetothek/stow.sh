# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen
#
# stow.sh is pure Bash: there is nothing to compile. Run `make` for the list
# of targets, `make vars` for the resolved install paths.

.DEFAULT_GOAL := help

# ── Install layout ──────────────────────────────────────────────────────────
# Root installs to /usr/local, everyone else to ~/.local. XDG_BIN_HOME is a
# non-standard convenience override for bindir (the XDG spec does not define it).

PROJECT := stow.sh
PREFIX  ?= $(if $(filter 0,$(shell id -u)),/usr/local,$(HOME)/.local)
bindir  ?= $(or $(strip $(XDG_BIN_HOME)),$(PREFIX)/bin)
datadir ?= $(PREFIX)/share/$(PROJECT)
BINDIR  := $(DESTDIR)$(bindir)
DATADIR := $(DESTDIR)$(datadir)

INSTALL ?= install
RM      ?= rm -f
RMDIR   ?= rm -rf

# ── Sources ─────────────────────────────────────────────────────────────────
# shfmt formats only *.sh files, so .editorconfig applies. Git hooks have no
# extension (shfmt would default them to tabs): shellcheck lints them, shfmt
# skips them.

SHELL_SOURCES := $(wildcard src/*.sh bin/*.sh conditions.d/*.sh scripts/*.sh)
HOOK_SOURCES  := $(wildcard hooks/*)
DIST          := dist
BUNDLE        := $(DIST)/stow.sh

# $(call require,tool,hint) — abort with a clear message when a tool is missing.
require = @command -v $(1) >/dev/null 2>&1 || { echo >&2 "ERROR: $(1) not found. $(2)"; exit 1; }

.PHONY: help all install uninstall hooks lint fmt test bundle toc clean release vars print-vars

help: ## Show this help
	@echo "Usage: make <target> [PREFIX=... DESTDIR=...]"
	@echo
	@awk 'BEGIN {FS = ":.*## "} /^[a-z-]+:.*## / {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

all: help

# ── Install ─────────────────────────────────────────────────────────────────

install: ## Install (~/.local, or /usr/local as root)
	@echo "Installing $(PROJECT) → bin: $(BINDIR)  data: $(DATADIR)"
	$(INSTALL) -d "$(BINDIR)" "$(DATADIR)/src" "$(DATADIR)/conditions.d"
	$(INSTALL) -m 755 src/main.sh "$(DATADIR)/src/"
	$(INSTALL) -m 644 $(filter-out src/main.sh,$(wildcard src/*.sh)) "$(DATADIR)/src/"
	$(INSTALL) -m 644 conditions.d/*.sh "$(DATADIR)/conditions.d/"
	@printf '#!/usr/bin/env bash\nexport STOW_ROOT="%s"\nexec "$$STOW_ROOT/src/main.sh" "$$@"\n' \
		"$(datadir)" > "$(BINDIR)/$(PROJECT)"
	chmod 755 "$(BINDIR)/$(PROJECT)"

uninstall: ## Remove an installed copy
	$(RM) "$(BINDIR)/$(PROJECT)"
	$(RMDIR) "$(DATADIR)"

vars: ## Print the resolved install paths
	@printf '%-8s = %s\n' PREFIX "$(PREFIX)" bindir "$(bindir)" datadir "$(datadir)" \
		DESTDIR "$(DESTDIR)" BINDIR "$(BINDIR)" DATADIR "$(DATADIR)"

print-vars: vars

# ── Develop ─────────────────────────────────────────────────────────────────

hooks: ## Install git hooks (commit-msg format, pre-commit lint + test)
	@$(INSTALL) -m 755 hooks/* .git/hooks/
	@echo "Git hooks installed."

lint: ## shellcheck (required) + shfmt diff (advisory)
	$(call require,shellcheck,Install shellcheck.)
	shellcheck $(SHELL_SOURCES) $(HOOK_SOURCES)
	@# The tree is not yet fully shfmt-clean, so a diff is a hint, not a failure.
	@if command -v shfmt >/dev/null 2>&1; then shfmt -d $(SHELL_SOURCES) || true; \
	else echo "shfmt not found — skipping format check."; fi

fmt: ## Format shell sources in place with shfmt
	$(call require,shfmt,Install shfmt.)
	shfmt -w $(SHELL_SOURCES)

test: ## Run the bats test suite
	$(call require,bats,Install bats-core.)
	@bats --verbose-run test/

# ── Build & release ─────────────────────────────────────────────────────────

bundle: ## Build the single-file executable into dist/
	@scripts/bundle.sh "$(BUNDLE)"

toc: ## Regenerate the README table of contents
	@scripts/update_toc.sh README.md

clean: ## Remove build output
	$(RMDIR) "$(DIST)"

release: ## Clean tree → hooks → lint → test → cz bump → changelog → tag
	$(call require,cz,Install commitizen.)
	@test -z "$$(git status --porcelain)" || { echo >&2 "ERROR: working tree is not clean."; exit 1; }
	@$(MAKE) --no-print-directory hooks lint test
	@cz bump
	@cz changelog
	@ver=$$(git tag --sort=-creatordate | head -1); \
	git add CHANGELOG.md && git commit --amend --no-edit && \
	git tag -d "$$ver" && git tag "$$ver" && \
	printf '\nRelease %s ready. Push with:\n  git push && git push --tags\n' "$$ver"
