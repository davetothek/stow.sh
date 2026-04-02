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

test:
	@echo "Running tests..."
	@command -v bats >/dev/null 2>&1 || { echo >&2 "ERROR: bats not found. Please install bats-core."; exit 1; }
	@bats --verbose-run test/

.PHONY: install uninstall test
