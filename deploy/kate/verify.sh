#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
offline=0
[ "${1:-}" = "--offline" ] && offline=1

failures=0
check() {
  local label="$1"
  shift
  if "$@"; then
    echo "OK   $label"
  else
    echo "FAIL $label" >&2
    failures=$((failures + 1))
  fi
}

check "install.sh syntax" bash -n "$repo_dir/install.sh"
check "codex-wrapper syntax" bash -n "$repo_dir/deploy/kate/codex-wrapper.sh"
check "user-proxy syntax" bash -n "$repo_dir/deploy/kate/user-proxy.sh"
check "user-proxy loader syntax" bash -n "$repo_dir/deploy/kate/templates/load-codex-proxy.bash"
check "bootstrap syntax" bash -n "$repo_dir/deploy/kate/bootstrap.sh"
check "rollback syntax" bash -n "$repo_dir/deploy/kate/rollback.sh"
check "installer regression test" bash "$repo_dir/tests/test-install.sh"
check "codex-delegator compatibility contract" bash "$repo_dir/tests/test-codex-delegator-contract.sh"
check "Codex proxy wrapper regression test" bash "$repo_dir/tests/test-codex-wrapper.sh"
check "Kate user proxy regression test" bash "$repo_dir/tests/test-kate-user-proxy.sh"
check "Telegram access policy contract" bash "$repo_dir/tests/test-kate-telegram-policy.sh"

for hook in "$repo_dir"/deploy/kate/hooks/*.sh; do
  check "hook syntax: $(basename "$hook")" bash -n "$hook"
done

if command -v shellcheck >/dev/null 2>&1; then
  check "ShellCheck" shellcheck \
    "$repo_dir/install.sh" \
    "$repo_dir/tests/test-install.sh" \
    "$repo_dir/tests/test-codex-delegator-contract.sh" \
    "$repo_dir/tests/test-codex-wrapper.sh" \
    "$repo_dir/tests/test-kate-user-proxy.sh" \
    "$repo_dir/tests/test-kate-telegram-policy.sh" \
    "$repo_dir/deploy/kate/bootstrap.sh" \
    "$repo_dir/deploy/kate/codex-wrapper.sh" \
    "$repo_dir/deploy/kate/user-proxy.sh" \
    "$repo_dir/deploy/kate/templates/load-codex-proxy.bash" \
    "$repo_dir/deploy/kate/rollback.sh" \
    "$repo_dir/deploy/kate/verify.sh" \
    "$repo_dir"/deploy/kate/hooks/*.sh
else
  echo "WARN ShellCheck is not installed; static shell lint skipped."
fi

check "core installed for Codex" bash "$repo_dir/install.sh" doctor core --codex
check "core installed for Hermes" bash "$repo_dir/install.sh" doctor core --hermes
check "Codex proxy wrapper doctor" bash "$repo_dir/deploy/kate/codex-wrapper.sh" doctor
check "Codex CLI available" codex --version
check "RTK available" rtk --version

if [ "$offline" -eq 0 ]; then
  check "Hermes doctor" hermes doctor
  check "Hermes hooks doctor" hermes hooks doctor
  check "Codex MCP connection" hermes mcp test codex
else
  echo "WARN Offline mode: Hermes runtime checks skipped."
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures verification check(s) failed." >&2
  exit 1
fi

echo "All requested verification checks passed."
