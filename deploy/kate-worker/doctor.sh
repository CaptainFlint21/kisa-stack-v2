#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"
expected_branch="${KISA_EXPECTED_BRANCH:-codex/desktop-kate-stack}"
failed=0

check() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'OK %s\n' "$description"
  else
    printf 'FAIL %s\n' "$description" >&2
    failed=1
  fi
}

check "Linux host" test "$(uname -s)" = "Linux"
check "ordinary user" test "$(id -u)" -ne 0
check "git available" command -v git
check "node available" command -v node
check "codex available" command -v codex
check "Codex CLI starts" codex --version
check "Codex login present" codex login status
check "expected Git branch" test "$(git -C "$repo_root" branch --show-current)" = "$expected_branch"
check "Git worktree clean" test -z "$(git -C "$repo_root" status --porcelain)"
check "KISA worker profile" "$script_dir/kisa-worker.sh" doctor

[ "$failed" -eq 0 ] || {
  printf 'ERROR: Kate worker doctor failed\n' >&2
  exit 1
}

printf 'OK Kate worker\n'
