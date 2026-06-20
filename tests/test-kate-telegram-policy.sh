#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
template="$repo_dir/deploy/kate/templates/hermes-config.yaml"
readme="$repo_dir/deploy/kate/README.md"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

contains() {
  grep -Fq -- "$2" "$1"
}

contains "$template" 'dm_policy: "allowlist"' || fail "DM policy must be allowlist"
contains "$template" 'dm_allow_from:' || fail "owner DM allowlist is missing"
contains "$template" 'group_policy: "allowlist"' || fail "group policy must be allowlist"
contains "$template" 'allowed_chats:' || fail "response chat gate is missing"
contains "$template" 'group_allowed_chats:' || fail "group-wide authorization is missing"
contains "$template" '- "__TELEGRAM_GROUP_ID__"' || fail "Telegram group placeholder is missing"
contains "$template" 'require_mention: true' || fail "group mention gate must be enabled"

contains "$readme" "Telegram DMs are allowlisted to one owner user ID." ||
  fail "README must document owner-only DMs"
contains "$readme" "membership in that group is" ||
  fail "README must document group-membership authorization"
contains "$readme" "another member of the approved group" ||
  fail "README acceptance must cover another approved-group member"
contains "$readme" "Mention the bot from another group. Hermes must ignore it." ||
  fail "README acceptance must reject other groups"

echo "Kate Telegram access policy contract tests passed."
