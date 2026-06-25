#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"
expected_branch="${KISA_EXPECTED_BRANCH:-codex/desktop-kate-stack}"

[ "$(uname -s)" = "Linux" ] || {
  printf 'ERROR: Kate worker requires Linux\n' >&2
  exit 1
}

for command_name in git node codex; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'ERROR: required command missing: %s\n' "$command_name" >&2
    exit 1
  }
done

current_branch="$(git -C "$repo_root" branch --show-current)"
[ "$current_branch" = "$expected_branch" ] || {
  printf 'ERROR: expected branch %s, got %s\n' "$expected_branch" "$current_branch" >&2
  exit 1
}

"$script_dir/kisa-worker.sh" install "$@"
