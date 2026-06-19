#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
skill="$repo_dir/skills/codex-delegator/SKILL.md"
metadata="$repo_dir/skills/codex-delegator/agents/openai.yaml"
profile="$repo_dir/profiles/core.txt"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

contains() {
  local file="$1"
  local needle="$2"
  grep -Fq -- "$needle" "$file"
}

rejects() {
  local file="$1"
  local needle="$2"
  if contains "$file" "$needle"; then
    fail "forbidden text found in $(realpath --relative-to="$repo_dir" "$file"): $needle"
  fi
}

contains "$profile" "codex-delegator" || fail "core profile must include codex-delegator"

contains "$skill" "sandbox: workspace-write" || fail "skill must require workspace-write sandbox"
contains "$skill" "approval-policy: never" || fail "skill must require approval-policy never"
contains "$skill" 'Never select `danger-full-access`' ||
  fail "skill must preserve the danger-full-access prohibition"
contains "$skill" "the initial \`codex\` call must use" ||
  fail "skill must apply sandbox and approval policy to the initial codex call"
contains "$skill" "\`codex-reply\` accepts \`threadId\` and \`prompt\`" ||
  fail "skill must describe the actual codex-reply schema"
contains "$skill" "inherits the initial thread's sandbox and approval policy" ||
  fail "skill must state codex-reply inherits initial settings"
contains "$skill" "Do not pass \`sandbox\` or \`approval-policy\` to \`codex-reply\`" ||
  fail "skill must not claim codex-reply receives sandbox or approval-policy fields"
contains "$skill" "Codex's delegated authority is limited to" ||
  fail "skill must define delegated Codex authority"
contains "$skill" "editing files inside the absolute \`cwd\`" ||
  fail "skill must limit edits to the absolute cwd"
contains "$skill" "running local verification commands" ||
  fail "skill must allow local verification"
contains "$skill" "Codex must not perform Git orchestration through MCP" ||
  fail "skill must keep Git orchestration out of delegated Codex"
contains "$skill" "Hermes owns Git orchestration" ||
  fail "skill must assign Git orchestration to Hermes"
contains "$skill" "prepare a feature branch before delegation" ||
  fail "skill must require Hermes to prepare the feature branch"
contains "$skill" "commit intentional changes only after user authorization" ||
  fail "skill must require user authorization before commit"
contains "$skill" "push the feature branch only after user authorization" ||
  fail "skill must require user authorization before push"
contains "$skill" "open a draft pull request only after user authorization" ||
  fail "skill must require user authorization before draft PR"
contains "$skill" "Required sudo, network, or outside-workspace write: report a blocker" ||
  fail "skill must block sudo, network, and outside-workspace writes"
contains "$skill" "Approval required, elicitation unsupported, or approval-related error" ||
  fail "skill must identify approval and elicitation failures"
contains "$skill" "Do not retry and do not wait the normal" ||
  fail "skill must forbid retrying approval/elicitation failures"
contains "$skill" "Codex returns an incomplete result: continue through \`codex-reply\`" ||
  fail "skill must keep normal incomplete work on codex-reply"

contains "$metadata" "approval-policy never" ||
  fail "OpenAI metadata prompt must request approval-policy never"
contains "$metadata" "codex-reply using only that threadId plus a prompt" ||
  fail "OpenAI metadata prompt must describe codex-reply schema"
contains "$metadata" "codex-reply inherits the initial thread's sandbox and approval policy" ||
  fail "OpenAI metadata prompt must describe inherited codex-reply contract"
contains "$metadata" "Hermes owns branch, commit, push, and draft PR orchestration" ||
  fail "OpenAI metadata prompt must keep Git orchestration with Hermes"
contains "$metadata" "sudo, network, outside-cwd writes" ||
  fail "OpenAI metadata prompt must describe blocker scope"

rejects "$skill" "approval-policy: on-request"
rejects "$metadata" "on-request approval"
rejects "$metadata" "approval-policy on-request"
rejects "$skill" "sandbox: danger-full-access"
rejects "$skill" "every \`codex\` and \`codex-reply\` call must use"
rejects "$skill" "The same \`sandbox\` and \`approval-policy\` values apply to every \`codex-reply\`"
rejects "$metadata" "codex-reply using the same compatibility contract"

echo "Codex delegator compatibility contract tests passed."
