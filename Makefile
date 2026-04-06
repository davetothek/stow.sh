# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

PREFIX ?= $(if $(XDG_BIN_HOME),$(XDG_BIN_HOME),$(HOME)/.local/bin)
BINDIR := $(PREFIX)
DATADIR ?= $(if $(XDG_DATA_HOME),$(XDG_DATA_HOME),$(HOME)/.local/share)/stow.sh
TARGET := bin/stow.sh
LINK := stow.sh

install:
	@echo "Installing $(LINK) to $(BINDIR)"
	install -d "$(BINDIR)"
	chmod +x $(TARGET)
	ln -sf "$(abspath $(TARGET))" "$(BINDIR)/$(LINK)"
	@echo "Installing built-in conditions to $(DATADIR)/conditions.d"
	install -d "$(DATADIR)/conditions.d"
	install -m 644 conditions.d/*.sh "$(DATADIR)/conditions.d/"
	@echo "Done. Make sure '$(BINDIR)' is in your PATH."

uninstall:
	@echo "Removing $(LINK) from $(BINDIR)"
	rm -f "$(BINDIR)/$(LINK)"
	@echo "Removing data from $(DATADIR)"
	rm -rf "$(DATADIR)"

hooks:
	@echo "Installing git hooks..."
	@install -m 755 hooks/* .git/hooks/
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

.PHONY: install uninstall hooks test release
