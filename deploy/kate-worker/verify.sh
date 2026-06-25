#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"

bash -n \
  "$script_dir/bootstrap.sh" \
  "$script_dir/doctor.sh" \
  "$script_dir/kisa-worker.sh" \
  "$script_dir/verify.sh"

node --check "$repo_root/deploy/codex-stack/kisa.mjs"
node --check "$repo_root/deploy/codex-stack/hooks/wiki-hook.mjs"
node --check "$repo_root/tests/test-codex-stack.mjs"
node "$repo_root/tests/test-codex-stack.mjs"
"$script_dir/doctor.sh"

printf 'All Kate worker verification checks passed.\n'
