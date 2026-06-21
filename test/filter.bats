#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

setup_file() {
  # Must be exported: bats runs setup_file in a separate shell from setup()
  # and the tests, so a non-exported var would be empty there.
  export TEST_REPO
  TEST_REPO=$(mktemp -d)
  cd "$TEST_REPO"

  git init -q
  cat >.gitignore <<EOF
# Dotfiles
.*
!.zshrc

# Systemd services
!.config/
!.config/systemd/
!.config/systemd/user/
.config/systemd/user/*
!.config/systemd/user/gammastep@.service

# Local binaries
.local/
.local/bin/
.local/bin/*

# Temporary and cache files
*.bak
*.tmp
.cache/
logs/
*.log

# Env files
.env
!*.sample

# Kitty themes
!.config/
!.config/kitty/
!.config/kitty/themes/
.config/kitty/themes/*
!.config/kitty/themes/gammastep.conf
EOF

  mkdir -p \
    .local/bin \
    logs/archive \
    .config/kitty/themes \
    .config/systemd/user \
    data

  touch \
    .local/bin/1password.sh \
    logs/debug.log \
    logs/archive/debug.log \
    .config/kitty/themes/kanagawa_dragon.conf \
    .zshrc \
    .env \
    .gitignore \
    .config/systemd/user/fcitx.service \
    .config/systemd/user/gammastep@.service \
    data/file.txt

  git add .
  git commit -qm "Initial test content"
}

teardown_file() {
  rm -rf "$TEST_REPO"
}

teardown() {
  if [[ "$status" -ne 0 ]]; then
    echo "\n\n--- TEST FAILED ---"
    echo "At: $BATS_TEST_FILENAME:$BATS_TEST_LINE_NUMBER ($BATS_TEST_NAME)"
    echo "PWD: $(pwd)"
    echo "Contents of test repo:"
    find . | sort
    echo "\n--- .gitignore ---"
    cat .gitignore
    echo "\n--- End ---\n"
  fi
}

setup() {
  cd "$TEST_REPO"
  source "$BATS_TEST_DIRNAME/../src/filter.sh"
}

@test "stow_sh::match_glob_ignore returns true" {
  run bash -c "source '$BATS_TEST_DIRNAME/../src/filter.sh'; declare -a _stow_sh_ignore=(); declare -a _stow_sh_ignore_glob=(\"*.tmp\"); stow_sh::match_glob_ignore 'foo.tmp'"
  [ "$status" -eq 0 ]
}

@test "stow_sh::match_glob_ignore returns false" {
  run bash -c "source '$BATS_TEST_DIRNAME/../src/filter.sh'; declare -a _stow_sh_ignore=(); declare -a _stow_sh_ignore_glob=(\"*.tmp\"); stow_sh::match_glob_ignore 'bar.txt'"
  [ "$status" -eq 1 ]
}

@test "stow_sh::match_regex_ignore returns true" {
  run bash -c "source '$BATS_TEST_DIRNAME/../src/filter.sh'; declare -a _stow_sh_ignore=(\"^build/\"); declare -a _stow_sh_ignore_glob=(); stow_sh::match_regex_ignore 'build/output.o'"
  [ "$status" -eq 0 ]
}

@test "stow_sh::match_regex_ignore returns false" {
  run bash -c "source '$BATS_TEST_DIRNAME/../src/filter.sh'; declare -a _stow_sh_ignore=(\"^build/\"); declare -a _stow_sh_ignore_glob=(); stow_sh::match_regex_ignore 'src/build/output.o'"
  [ "$status" -eq 1 ]
}

@test "stow_sh::git_should_ignore returns 0 for ignored file" {
  relpath="."
  run stow_sh::git_should_ignore "$relpath" ".env"
  [ "$status" -eq 0 ]
}

@test "stow_sh::git_should_ignore returns 1 for re-included file" {
  relpath="."
  run stow_sh::git_should_ignore "$relpath" ".zshrc"
  [ "$status" -eq 1 ]
}

@test "stow_sh::git_should_ignore returns 1 for unlisted file" {
  relpath="."
  run stow_sh::git_should_ignore "$relpath" "data/file.txt"
  [ "$status" -eq 1 ]
}

@test "stow_sh::git_should_ignore returns 1 when check-ignore fails" {
  relpath="."
  run stow_sh::git_should_ignore "$relpath" "notfound/unknown.txt"
  [ "$status" -eq 1 ]
}

@test "stow_sh::filter_candidates passes through unfiltered paths" {
  input=$'foo.txt\nbar.sh'
  run bash -c "source '$BATS_TEST_DIRNAME/../src/log.sh'; source '$BATS_TEST_DIRNAME/../src/filter.sh'; declare -a _stow_sh_ignore=(); declare -a _stow_sh_ignore_glob=(); _stow_sh_git_mode=false; stow_sh::filter_candidates <<< \"$input\""
  [ "$status" -eq 0 ]
  [ "$output" = $'foo.txt\nbar.sh' ]
}

@test "stow_sh::filter_candidates respects .gitignore" {
  input=$'.local/bin/1password.sh\nlogs/debug.log\nlogs/archive/debug.log\ndata/file.txt\n.config/kitty/themes/kanagawa_dragon.conf\n.zshrc\n.config/systemd/user/gammastep@.service'
  run bash -c "source '$BATS_TEST_DIRNAME/../src/log.sh'; source '$BATS_TEST_DIRNAME/../src/filter.sh'; declare -a _stow_sh_ignore=(); declare -a _stow_sh_ignore_glob=(); _stow_sh_git_mode=true; stow_sh::filter_candidates <<< \"$input\""
  [ "$status" -eq 0 ]
  result="$output"
  [[ "$result" != *"logs/debug.log"* ]]
  [[ "$result" != *"logs/archive/debug.log"* ]]
  [[ "$result" != *"kanagawa_dragon.conf"* ]]
  [[ "$result" == *".zshrc"* ]]
  [[ "$result" == *"gammastep@.service"* ]]
  [[ "$result" == *"data/file.txt"* ]]
  [[ "$result" != *".local/bin/1password.sh"* ]]
}

@test "stow_sh::filter_candidates handles glob ignore" {
  input=$'foo.tmp\nbar.txt'
  run bash -c "source '$BATS_TEST_DIRNAME/../src/log.sh'; source '$BATS_TEST_DIRNAME/../src/filter.sh'; declare -a _stow_sh_ignore=(); declare -a _stow_sh_ignore_glob=(\"*.tmp\"); _stow_sh_git_mode=false; stow_sh::filter_candidates <<< \"$input\""
  [ "$status" -eq 0 ]
  [ "$output" = "bar.txt" ]
}

@test "stow_sh::filter_candidates handles regex ignore" {
  input=$'build/output.o\nsrc/build/output.o'
  run bash -c "source '$BATS_TEST_DIRNAME/../src/log.sh'; source '$BATS_TEST_DIRNAME/../src/filter.sh'; declare -a _stow_sh_ignore=(\"^build/.*\"); declare -a _stow_sh_ignore_glob=(); _stow_sh_git_mode=false; stow_sh::filter_candidates <<< \"$input\""
  [ "$status" -eq 0 ]
  [ "$output" = "src/build/output.o" ]
}

@test "stow_sh::filter_candidates excludes parent dir even if child is re-included" {
  echo '!parent/child.txt' >.gitignore
  echo 'parent/' >>.gitignore

  mkdir -p parent
  touch parent/child.txt
  git add . && git commit -m "test negation edge"

  relpath="."
  run stow_sh::git_should_ignore "$relpath" "parent/child.txt"
  [ "$status" -eq 0 ]
}

@test "stow_sh::filter_candidates always ignores .git/ dir" {
  relpath="."
  mkdir -p .git/hooks
  touch .git/hooks/pre-commit

  run stow_sh::git_should_ignore "$relpath" ".git/hooks/pre-commit"
  [ "$status" -eq 0 ]
}

# ============================================================
# .stowignore tests
# ============================================================

@test "stow_sh::match_stowignore always excludes .stowignore itself" {
  source "$BATS_TEST_DIRNAME/../src/log.sh"
  source "$BATS_TEST_DIRNAME/../src/filter.sh"
  _stow_sh_stowignore_glob=()

  run stow_sh::match_stowignore ".stowignore"
  [ "$status" -eq 0 ]
}

@test "stow_sh::match_stowignore excludes nested .stowignore" {
  source "$BATS_TEST_DIRNAME/../src/log.sh"
  source "$BATS_TEST_DIRNAME/../src/filter.sh"
  _stow_sh_stowignore_glob=()

  run stow_sh::match_stowignore "subdir/.stowignore"
  [ "$status" -eq 0 ]
}

@test "stow_sh::match_stowignore matches loaded glob patterns" {
  source "$BATS_TEST_DIRNAME/../src/log.sh"
  source "$BATS_TEST_DIRNAME/../src/filter.sh"
  _stow_sh_stowignore_glob=("*.bak" "LICENSE")

  run stow_sh::match_stowignore "file.bak"
  [ "$status" -eq 0 ]

  run stow_sh::match_stowignore "LICENSE"
  [ "$status" -eq 0 ]

  run stow_sh::match_stowignore ".bashrc"
  [ "$status" -eq 1 ]
}

@test "stow_sh::load_stowignore loads patterns from file" {
  source "$BATS_TEST_DIRNAME/../src/log.sh"
  source "$BATS_TEST_DIRNAME/../src/filter.sh"
  stow_sh::reset_stowignore

  local tmpdir
  tmpdir="$(mktemp -d)"
  cat > "$tmpdir/.stowignore" <<'EOF'
# Ignore project management files
*.baseline
.pre-commit-config.yaml

# Ignore build artifacts
Makefile
EOF

  stow_sh::load_stowignore "$tmpdir/.stowignore"

  run stow_sh::match_stowignore "secrets.baseline"
  [ "$status" -eq 0 ]

  run stow_sh::match_stowignore ".pre-commit-config.yaml"
  [ "$status" -eq 0 ]

  run stow_sh::match_stowignore "Makefile"
  [ "$status" -eq 0 ]

  run stow_sh::match_stowignore ".bashrc"
  [ "$status" -eq 1 ]

  rm -rf "$tmpdir"
}

@test "stow_sh::load_stowignore skips blank lines and comments" {
  source "$BATS_TEST_DIRNAME/../src/log.sh"
  source "$BATS_TEST_DIRNAME/../src/filter.sh"
  stow_sh::reset_stowignore

  local tmpdir
  tmpdir="$(mktemp -d)"
  cat > "$tmpdir/.stowignore" <<'EOF'

# comment line
   # indented comment

*.log

EOF

  stow_sh::load_stowignore "$tmpdir/.stowignore"

  # Should only have one pattern: *.log
  [ "${#_stow_sh_stowignore_glob[@]}" -eq 1 ]
  [ "${_stow_sh_stowignore_glob[0]}" = "*.log" ]

  rm -rf "$tmpdir"
}

@test "stow_sh::load_stowignore is a no-op when file does not exist" {
  source "$BATS_TEST_DIRNAME/../src/log.sh"
  source "$BATS_TEST_DIRNAME/../src/filter.sh"
  stow_sh::reset_stowignore

  run stow_sh::load_stowignore "/nonexistent/.stowignore"
  [ "$status" -eq 0 ]
  [ "${#_stow_sh_stowignore_glob[@]}" -eq 0 ]
}

@test "stow_sh::reset_stowignore clears patterns" {
  source "$BATS_TEST_DIRNAME/../src/log.sh"
  source "$BATS_TEST_DIRNAME/../src/filter.sh"
  _stow_sh_stowignore_glob=("*.bak" "LICENSE")

  stow_sh::reset_stowignore
  [ "${#_stow_sh_stowignore_glob[@]}" -eq 0 ]
}

@test "stow_sh::filter_candidates excludes .stowignore patterns" {
  source "$BATS_TEST_DIRNAME/../src/log.sh"
  source "$BATS_TEST_DIRNAME/../src/filter.sh"
  _stow_sh_stowignore_glob=("*.baseline" ".pre-commit-config.yaml")
  _stow_sh_ignore=()
  _stow_sh_ignore_glob=()
  _stow_sh_git_mode=false

  local input=$'.bashrc\nsecrets.baseline\n.pre-commit-config.yaml\n.config/nvim/init.lua'
  local -a result
  mapfile -t result < <(stow_sh::filter_candidates <<< "$input")

  [ "${#result[@]}" -eq 2 ]
  [ "${result[0]}" = ".bashrc" ]
  [ "${result[1]}" = ".config/nvim/init.lua" ]
}

@test "stow_sh::match_stowignore leading / anchors to root (strips slash)" {
  source "$BATS_TEST_DIRNAME/../src/log.sh"
  source "$BATS_TEST_DIRNAME/../src/filter.sh"
  _stow_sh_stowignore_glob=("/AGENTS.md")

  # Root file matches
  run stow_sh::match_stowignore "AGENTS.md"
  [ "$status" -eq 0 ]

  # Nested copies do NOT match
  run stow_sh::match_stowignore ".pi/agent/AGENTS.md"
  [ "$status" -eq 1 ]

  run stow_sh::match_stowignore ".config/nvim/AGENTS.md"
  [ "$status" -eq 1 ]
}

@test "stow_sh::match_stowignore leading / with directory pattern" {
  source "$BATS_TEST_DIRNAME/../src/log.sh"
  source "$BATS_TEST_DIRNAME/../src/filter.sh"
  _stow_sh_stowignore_glob=("/build")

  # Root dir matches
  run stow_sh::match_stowignore "build"
  [ "$status" -eq 0 ]

  # Descendants match
  run stow_sh::match_stowignore "build/output.o"
  [ "$status" -eq 0 ]

  # Nested 'build' does NOT match
  run stow_sh::match_stowignore "src/build"
  [ "$status" -eq 1 ]

  run stow_sh::match_stowignore "src/build/output.o"
  [ "$status" -eq 1 ]
}

@test "stow_sh::match_stowignore leading / with glob" {
  source "$BATS_TEST_DIRNAME/../src/log.sh"
  source "$BATS_TEST_DIRNAME/../src/filter.sh"
  _stow_sh_stowignore_glob=("/*.md")

  # Root markdown matches
  run stow_sh::match_stowignore "README.md"
  [ "$status" -eq 0 ]

  run stow_sh::match_stowignore "AGENTS.md"
  [ "$status" -eq 0 ]

  # Nested markdown does NOT match
  run stow_sh::match_stowignore "docs/README.md"
  [ "$status" -eq 1 ]
}

@test "stow_sh::filter_candidates with leading-/ stowignore pattern" {
  source "$BATS_TEST_DIRNAME/../src/log.sh"
  source "$BATS_TEST_DIRNAME/../src/filter.sh"
  _stow_sh_stowignore_glob=("/AGENTS.md")
  _stow_sh_ignore=()
  _stow_sh_ignore_glob=()
  _stow_sh_git_mode=false

  local input=$'AGENTS.md\n.pi/agent/AGENTS.md\n.bashrc'
  local -a result
  mapfile -t result < <(stow_sh::filter_candidates <<< "$input")

  [ "${#result[@]}" -eq 2 ]
  [ "${result[0]}" = ".pi/agent/AGENTS.md" ]
  [ "${result[1]}" = ".bashrc" ]
}

@test "stow_sh::match_stowignore anchors patterns containing / to package root" {
  source "$BATS_TEST_DIRNAME/../src/log.sh"
  source "$BATS_TEST_DIRNAME/../src/filter.sh"
  _stow_sh_stowignore_glob=("src/lib")

  # Anchored pattern matches exact path
  run stow_sh::match_stowignore "src/lib"
  [ "$status" -eq 0 ]

  # Anchored pattern matches descendants
  run stow_sh::match_stowignore "src/lib/utils.sh"
  [ "$status" -eq 0 ]

  # Does NOT match basename-only (unanchored would match "lib" anywhere)
  run stow_sh::match_stowignore "other/lib"
  [ "$status" -eq 1 ]

  # Does NOT match bare basename
  run stow_sh::match_stowignore "lib"
  [ "$status" -eq 1 ]
}

@test "stow_sh::match_stowignore anchored pattern with glob" {
  source "$BATS_TEST_DIRNAME/../src/log.sh"
  source "$BATS_TEST_DIRNAME/../src/filter.sh"
  _stow_sh_stowignore_glob=("src/*.test.sh")

  # Matches file at anchored path
  run stow_sh::match_stowignore "src/foo.test.sh"
  [ "$status" -eq 0 ]

  # Does NOT match same basename elsewhere
  run stow_sh::match_stowignore "other/foo.test.sh"
  [ "$status" -eq 1 ]

  # Does NOT match bare basename
  run stow_sh::match_stowignore "foo.test.sh"
  [ "$status" -eq 1 ]
}

@test "stow_sh::match_stowignore unanchored pattern still matches anywhere" {
  source "$BATS_TEST_DIRNAME/../src/log.sh"
  source "$BATS_TEST_DIRNAME/../src/filter.sh"
  _stow_sh_stowignore_glob=("Makefile")

  # Matches at root
  run stow_sh::match_stowignore "Makefile"
  [ "$status" -eq 0 ]

  # Matches nested (basename match)
  run stow_sh::match_stowignore "src/Makefile"
  [ "$status" -eq 0 ]

  run stow_sh::match_stowignore "a/b/Makefile"
  [ "$status" -eq 0 ]
}

@test "stow_sh::filter_candidates with anchored stowignore pattern" {
  source "$BATS_TEST_DIRNAME/../src/log.sh"
  source "$BATS_TEST_DIRNAME/../src/filter.sh"
  _stow_sh_stowignore_glob=("src/test")
  _stow_sh_ignore=()
  _stow_sh_ignore_glob=()
  _stow_sh_git_mode=false

  local input=$'src/main.sh\nsrc/test/unit.sh\nsrc/test/integration.sh\nother/test/foo.sh\n.bashrc'
  local -a result
  mapfile -t result < <(stow_sh::filter_candidates <<< "$input")

  [ "${#result[@]}" -eq 3 ]
  [ "${result[0]}" = "src/main.sh" ]
  [ "${result[1]}" = "other/test/foo.sh" ]
  [ "${result[2]}" = ".bashrc" ]
}

@test "stow_sh::match_stowignore matches directory pattern against descendant paths" {
  source "$BATS_TEST_DIRNAME/../src/log.sh"
  source "$BATS_TEST_DIRNAME/../src/filter.sh"
  _stow_sh_stowignore_glob=(".github")

  # Direct match
  run stow_sh::match_stowignore ".github"
  [ "$status" -eq 0 ]

  # Descendant files — ancestor segment matches
  run stow_sh::match_stowignore ".github/CODEOWNERS"
  [ "$status" -eq 0 ]

  run stow_sh::match_stowignore ".github/workflows/ci.yml"
  [ "$status" -eq 0 ]

  # Non-matching paths
  run stow_sh::match_stowignore ".config/github"
  [ "$status" -eq 1 ]

  run stow_sh::match_stowignore ".bashrc"
  [ "$status" -eq 1 ]
}

@test "stow_sh::filter_candidates excludes directory pattern and all children" {
  source "$BATS_TEST_DIRNAME/../src/log.sh"
  source "$BATS_TEST_DIRNAME/../src/filter.sh"
  _stow_sh_stowignore_glob=(".github" "bootstrap")
  _stow_sh_ignore=()
  _stow_sh_ignore_glob=()
  _stow_sh_git_mode=false

  local input=$'.bashrc\n.github/CODEOWNERS\n.github/workflows/ci.yml\nbootstrap/install.sh\n.config/nvim/init.lua'
  local -a result
  mapfile -t result < <(stow_sh::filter_candidates <<< "$input")

  [ "${#result[@]}" -eq 2 ]
  [ "${result[0]}" = ".bashrc" ]
  [ "${result[1]}" = ".config/nvim/init.lua" ]
}
