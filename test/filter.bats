#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Copyright (c) 2025 David Kristiansen

setup_file() {
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
