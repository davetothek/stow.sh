## v0.15.0 (2026-06-21)

### BREAKING CHANGE

- a conflict now aborts the entire run instead of applying
what it can; --force no longer overwrites real directories; --defer and
--override are removed.

### Feat

- **hooks**: add pre-commit hook running shellcheck and tests
- **cli**: atomic conflict pre-flight, harden --force, drop dead flags

### Refactor

- make shell sources shellcheck-clean

## v0.14.1 (2026-05-11)

### Fix

- **filter**: strip leading / in stowignore patterns for root-anchored matching

## v0.14.0 (2026-05-11)

### Feat

- **filter**: support path-anchored patterns in .stowignore

## v0.13.0 (2026-05-07)

### Feat

- **args**: add mutual exclusion checks for --force/--adopt and -g/-G

## v0.12.2 (2026-05-07)

### Fix

- **args**: -D/-R without packages auto-discovers subdirs instead of defaulting to self-stow

## v0.12.1 (2026-04-22)

## v0.12.0 (2026-04-22)

### Feat

- **conditions**: add laptop and desktop condition plugins

## v0.11.1 (2026-04-22)

### Fix

- **ci**: configure git identity and remove environment-dependent test conditions

## v0.11.0 (2026-04-22)

### Fix

- sync .cz.toml version and fix tag format to v-prefix

## v0.10.2 (2026-04-06)

## v0.10.1 (2026-04-06)

### Refactor

- **stow**: demote already-stowed report to debug-only

## v0.10.0 (2026-04-06)

### Feat

- add .stowignore, report output, ancestor fold detection, -S/-D/-R defaults

## v0.9.1 (2026-04-06)

## v0.9.0 (2026-04-03)

### Refactor

- **stow**: demote auto-unfold log messages to debug level
