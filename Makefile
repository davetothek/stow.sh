# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

INSTALL ?= install
RM      ?= rm -f
RMDIR   ?= rm -rf

PROJECT  := stow.sh
BIN_NAME := stow.sh

UID := $(shell id -u)

# Non-standard convenience override (XDG does not define XDG_BIN_HOME)
XDG_BIN_HOME ?=

ifeq ($(UID),0)
  PREFIX ?= /usr/local
else
  PREFIX ?= $(HOME)/.local
endif

ifneq ($(strip $(XDG_BIN_HOME)),)
  bindir ?= $(XDG_BIN_HOME)
else
  bindir ?= $(PREFIX)/bin
endif

datadir ?= $(PREFIX)/share/$(PROJECT)

DESTDIR ?=

BINDIR  := $(DESTDIR)$(bindir)
DATADIR := $(DESTDIR)$(datadir)

.PHONY: all install uninstall hooks test release print-vars

all:
	@echo "Nothing to build for $(PROJECT) (pure shell)."

install:
	@echo "Installing $(PROJECT)"
	@echo "  bindir : $(BINDIR)"
	@echo "  datadir: $(DATADIR)"
	$(INSTALL) -d "$(BINDIR)"
	$(INSTALL) -d "$(DATADIR)/src"
	$(INSTALL) -d "$(DATADIR)/conditions.d"
	$(INSTALL) -m 755 src/main.sh "$(DATADIR)/src/"
	$(INSTALL) -m 644 $(filter-out src/main.sh,$(wildcard src/*.sh)) "$(DATADIR)/src/"
	$(INSTALL) -m 644 conditions.d/*.sh "$(DATADIR)/conditions.d/"
	@printf '#!/usr/bin/env bash\nexport STOW_ROOT="%s"\nexec "$$STOW_ROOT/src/main.sh" "$$@"\n' "$(datadir)" > "$(BINDIR)/$(BIN_NAME)"
	chmod 755 "$(BINDIR)/$(BIN_NAME)"
	@echo "Install complete."

uninstall:
	@echo "Uninstalling $(PROJECT)"
	$(RM) "$(BINDIR)/$(BIN_NAME)"
	$(RMDIR) "$(DATADIR)"
	@echo "Uninstall complete."

hooks:
	@echo "Installing git hooks..."
	@$(INSTALL) -m 755 hooks/* .git/hooks/
	@echo "Done. Conventional commit format is now enforced."

test:
	@echo "Running tests..."
	@command -v bats >/dev/null 2>&1 || { echo >&2 "ERROR: bats not found. Please install bats-core."; exit 1; }
	@bats --verbose-run test/

release:
	@command -v cz  >/dev/null 2>&1 || { echo >&2 "ERROR: commitizen (cz) not found."; exit 1; }
	@# Ensure clean working tree
	@if [ -n "$$(git status --porcelain)" ]; then \
		echo >&2 "ERROR: working tree is not clean. Commit or stash changes first."; \
		exit 1; \
	fi
	@# Ensure hooks are installed
	@$(MAKE) --no-print-directory hooks
	@# Run tests first
	@echo "Running tests..."
	@bats --verbose-run test/ || { echo >&2 "ERROR: tests failed. Fix before releasing."; exit 1; }
	@# Bump version (creates commit + tag)
	@echo ""
	@cz bump || { echo >&2 "ERROR: cz bump failed."; exit 1; }
	@# Update changelog
	@cz changelog
	@NEW_VER=$$(git tag --sort=-creatordate | head -1); \
	git add CHANGELOG.md && git commit --amend --no-edit && \
	git tag -d "$$NEW_VER" && git tag "$$NEW_VER" && \
	echo "" && \
	echo "Release $$NEW_VER ready. Push with:" && \
	echo "  git push && git push --tags"

print-vars:
	@echo "UID          = $(UID)"
	@echo "PREFIX       = $(PREFIX)"
	@echo "XDG_BIN_HOME = $(XDG_BIN_HOME)"
	@echo "bindir       = $(bindir)"
	@echo "datadir      = $(datadir)"
	@echo "DESTDIR      = $(DESTDIR)"
	@echo "BINDIR       = $(BINDIR)"
	@echo "DATADIR      = $(DATADIR)"
