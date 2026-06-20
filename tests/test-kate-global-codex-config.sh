#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_dir/deploy/kate/codex-global-config.sh"
rollback="$repo_dir/deploy/kate/rollback.sh"
tmp_home="$(mktemp -d)"
trap 'rm -rf -- "$tmp_home"' EXIT

export HOME="$tmp_home"
export CODEX_NVM_ROOT="$HOME/.nvm/versions/node"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

expect_fail() {
  local output="$tmp_home/expected-failure.out"
  if "$@" > "$output" 2>&1; then
    cat "$output" >&2
    fail "command unexpectedly succeeded: $*"
  fi
}

backup_count() {
  local target="$1"
  find "$(dirname -- "$target")" -maxdepth 1 \
    -name "$(basename -- "$target").backup-*" 2>/dev/null | wc -l
}

render_hermes_config() {
  mkdir -p "$HOME/.hermes"
  TEMPLATE_SOURCE="$repo_dir/deploy/kate/templates/hermes-config.yaml" \
  TEMPLATE_TARGET="$HOME/.hermes/config.yaml" \
  TEMPLATE_HOME="$HOME" \
  python3 - <<'PY'
import os
from pathlib import Path

source = Path(os.environ["TEMPLATE_SOURCE"])
target = Path(os.environ["TEMPLATE_TARGET"])
text = source.read_text(encoding="utf-8")
replacements = {
    "__HOME__": os.environ["TEMPLATE_HOME"],
    "__TELEGRAM_BOT_TOKEN__": "TEST_TOKEN",
    "__TELEGRAM_OWNER_ID__": "100",
    "__TELEGRAM_GROUP_ID__": "-100",
    "__TELEGRAM_ENABLED__": "false",
}
for key, value in replacements.items():
    text = text.replace(key, value)
target.write_text(text, encoding="utf-8")
PY
  chmod 600 "$HOME/.hermes/config.yaml"
}

make_real_codex() {
  local target="$CODEX_NVM_ROOT/v24.14.1/bin/codex"
  mkdir -p "$(dirname -- "$target")"
  cat > "$target" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  env-check)
    printf 'HTTP_PROXY=%s\n' "${HTTP_PROXY:-missing}"
    printf 'http_proxy=%s\n' "${http_proxy:-missing}"
    printf 'NO_PROXY=%s\n' "${NO_PROXY:-missing}"
    ;;
  *) printf 'codex-hermes-test\n' ;;
esac
EOF
  chmod +x "$target"
}

write_proxy_envs() {
  mkdir -p "$HOME/.hermes"
  {
    printf 'HTTP_PROXY=http://codex-secret@example.test:8080\r\n'
    printf 'HTTPS_PROXY=https://codex-secret@example.test:8443\r\n'
    printf 'ALL_PROXY=socks5://codex-secret@example.test:1080\r\n'
    printf 'NO_PROXY=codex.local\r\n'
  } > "$HOME/.hermes/codex-proxy.env"
  chmod 600 "$HOME/.hermes/codex-proxy.env"

  {
    printf 'HTTP_PROXY=http://hermes-secret@example.test:8080\r\n'
    printf 'HTTPS_PROXY=https://hermes-secret@example.test:8443\r\n'
    printf 'ALL_PROXY=socks5://hermes-secret@example.test:1080\r\n'
    printf 'NO_PROXY=hermes.local\r\n'
  } > "$HOME/.hermes/hermes-proxy.env"
  chmod 600 "$HOME/.hermes/hermes-proxy.env"
}

assert_no_secret_output() {
  local file="$1"
  if grep -Eq 'codex-secret|hermes-secret' "$file"; then
    cat "$file" >&2
    fail "workflow output must not print proxy values"
  fi
}

dry_home="$(mktemp -d)"
original_home="$HOME"
HOME="$dry_home"
export HOME
bash "$script" install --dry-run > "$tmp_home/dry-run.out"
[ ! -e "$HOME/.codex" ] || fail "dry-run must not create ~/.codex"
[ ! -e "$HOME/.local/bin/codex-hermes-proxy" ] ||
  fail "dry-run must not create Hermes launcher"
HOME="$original_home"
export HOME
rm -rf -- "$dry_home"

make_real_codex
write_proxy_envs
render_hermes_config

bash "$script" install > "$tmp_home/install.out"
assert_no_secret_output "$tmp_home/install.out"

[ -f "$HOME/.codex/AGENTS.md" ] || fail "AGENTS was not installed"
[ -f "$HOME/.codex/hooks.json" ] || fail "hooks.json was not installed"
[ -f "$HOME/.local/bin/codex-hermes-proxy" ] || fail "Hermes launcher missing"
[ ! -L "$HOME/.local/bin/codex-hermes-proxy" ] || fail "Hermes launcher must not be symlink"
[ "$(stat -c '%a' "$HOME/.local/bin/codex-hermes-proxy")" = "700" ] ||
  fail "Hermes launcher mode must be 700"
[ "$(grep -Fc '@~/.codex/RTK.md' "$HOME/.codex/AGENTS.md")" -eq 1 ] ||
  fail "AGENTS must contain exactly one RTK include"
grep -Fq 'approval-policy: never' "$HOME/.codex/AGENTS.md" ||
  fail "AGENTS must document delegated approval-policy never"
grep -Fq 'Hermes владеет Git orchestration' "$HOME/.codex/AGENTS.md" ||
  fail "AGENTS must document Hermes-owned Git orchestration"
grep -Fq "command: \"$HOME/.local/bin/codex-hermes-proxy\"" "$HOME/.hermes/config.yaml" ||
  fail "Hermes config must use absolute Codex MCP launcher"

env \
  HTTP_PROXY=http://codex-secret-parent.example.test:8080 \
  http_proxy=http://codex-secret-parent.example.test:8080 \
  "$HOME/.local/bin/codex-hermes-proxy" env-check > "$tmp_home/launcher-env.out"
grep -Fq 'HTTP_PROXY=http://hermes-secret@example.test:8080' "$tmp_home/launcher-env.out" ||
  fail "Hermes launcher must load Hermes proxy env"
grep -Fq 'http_proxy=http://hermes-secret@example.test:8080' "$tmp_home/launcher-env.out" ||
  fail "Hermes launcher must override inherited lowercase Codex proxy"
grep -Fq 'NO_PROXY=hermes.local' "$tmp_home/launcher-env.out" ||
  fail "Hermes launcher must parse CRLF Hermes proxy env"

bash "$script" doctor > "$tmp_home/doctor-ok.out"
grep -Fq "OK global Codex config" "$tmp_home/doctor-ok.out" ||
  fail "doctor success output missing"
assert_no_secret_output "$tmp_home/doctor-ok.out"

config_backups_before="$(backup_count "$HOME/.hermes/config.yaml")"
cat > "$HOME/.hermes/config.yaml" <<'EOF'
model:
  provider: "openai-codex"

mcp_servers:
  codex:
    command: "codex"
    args: ["mcp-server"]
    timeout: 123
    connect_timeout: 77
    supports_parallel_tool_calls: true
  other:
    command: "other-tool"

telegram:
  token: "hermes-secret-preserved"
  allowed_chats:
    - "-100"
EOF
expect_fail bash "$script" doctor
bash "$script" sync > "$tmp_home/config-command-repair.out"
assert_no_secret_output "$tmp_home/config-command-repair.out"
[ "$(backup_count "$HOME/.hermes/config.yaml")" -gt "$config_backups_before" ] ||
  fail "sync must back up Hermes config before MCP command repair"
grep -Fq "command: \"$HOME/.local/bin/codex-hermes-proxy\"" "$HOME/.hermes/config.yaml" ||
  fail "sync must repair Hermes MCP command"
grep -Fq 'args: ["mcp-server"]' "$HOME/.hermes/config.yaml" ||
  fail "sync must preserve existing MCP args"
grep -Fq 'timeout: 123' "$HOME/.hermes/config.yaml" ||
  fail "sync must preserve existing MCP timeout"
grep -Fq 'connect_timeout: 77' "$HOME/.hermes/config.yaml" ||
  fail "sync must preserve existing MCP connect_timeout"
grep -Fq 'supports_parallel_tool_calls: true' "$HOME/.hermes/config.yaml" ||
  fail "sync must preserve existing MCP parallel-call setting"
grep -Fq 'token: "hermes-secret-preserved"' "$HOME/.hermes/config.yaml" ||
  fail "sync must preserve unrelated secret-like fields"
bash "$script" doctor > "$tmp_home/doctor-after-config-repair.out"
assert_no_secret_output "$tmp_home/doctor-after-config-repair.out"

config_backups_before="$(backup_count "$HOME/.hermes/config.yaml")"
cat > "$HOME/.hermes/config.yaml" <<'EOF'
model:
  provider: "openai-codex"

mcp_servers:
  other:
    command: "other-tool"
    args: ["serve"]

telegram:
  token: "hermes-secret-missing-codex"
EOF
expect_fail bash "$script" doctor
bash "$script" sync > "$tmp_home/config-codex-add.out"
assert_no_secret_output "$tmp_home/config-codex-add.out"
[ "$(backup_count "$HOME/.hermes/config.yaml")" -gt "$config_backups_before" ] ||
  fail "sync must back up Hermes config before adding missing Codex server"
grep -Fq '  codex:' "$HOME/.hermes/config.yaml" ||
  fail "sync must add missing Codex MCP server"
grep -Fq "command: \"$HOME/.local/bin/codex-hermes-proxy\"" "$HOME/.hermes/config.yaml" ||
  fail "sync must add canonical Codex MCP command"
grep -Fq '    args: ["mcp-server"]' "$HOME/.hermes/config.yaml" ||
  fail "sync must add minimal Codex MCP args"
grep -Fq '    timeout: 900' "$HOME/.hermes/config.yaml" ||
  fail "sync must add minimal Codex MCP timeout"
grep -Fq '    connect_timeout: 60' "$HOME/.hermes/config.yaml" ||
  fail "sync must add minimal Codex MCP connect_timeout"
grep -Fq '    supports_parallel_tool_calls: false' "$HOME/.hermes/config.yaml" ||
  fail "sync must add minimal Codex MCP parallel-call setting"
grep -Fq '  other:' "$HOME/.hermes/config.yaml" ||
  fail "sync must preserve unrelated MCP servers"
grep -Fq 'token: "hermes-secret-missing-codex"' "$HOME/.hermes/config.yaml" ||
  fail "sync must preserve unrelated fields when adding Codex server"
bash "$script" doctor > "$tmp_home/doctor-after-codex-add.out"
assert_no_secret_output "$tmp_home/doctor-after-codex-add.out"

agents_backups_before="$(backup_count "$HOME/.codex/AGENTS.md")"
hooks_backups_before="$(backup_count "$HOME/.codex/hooks.json")"
launcher_backups_before="$(backup_count "$HOME/.local/bin/codex-hermes-proxy")"
bash "$script" sync > "$tmp_home/sync-idempotent.out"
[ "$(backup_count "$HOME/.codex/AGENTS.md")" -eq "$agents_backups_before" ] ||
  fail "idempotent sync must not back up AGENTS"
[ "$(backup_count "$HOME/.codex/hooks.json")" -eq "$hooks_backups_before" ] ||
  fail "idempotent sync must not back up hooks"
[ "$(backup_count "$HOME/.local/bin/codex-hermes-proxy")" -eq "$launcher_backups_before" ] ||
  fail "idempotent sync must not back up launcher"

{
  printf '@~/.codex/RTK.md\n'
  printf '@/home/kate/.codex/RTK.md\n'
  cat "$HOME/.codex/AGENTS.md"
} > "$HOME/.codex/AGENTS.md.drift"
mv -f "$HOME/.codex/AGENTS.md.drift" "$HOME/.codex/AGENTS.md"
printf '{"drift":true}\n' > "$HOME/.codex/hooks.json"
printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME/.local/bin/codex-hermes-proxy"
chmod 755 "$HOME/.local/bin/codex-hermes-proxy"

expect_fail bash "$script" doctor
bash "$script" sync > "$tmp_home/sync-drift.out"
assert_no_secret_output "$tmp_home/sync-drift.out"
[ "$(backup_count "$HOME/.codex/AGENTS.md")" -gt "$agents_backups_before" ] ||
  fail "sync must back up drifted AGENTS"
[ "$(backup_count "$HOME/.codex/hooks.json")" -gt "$hooks_backups_before" ] ||
  fail "sync must back up drifted hooks"
[ "$(backup_count "$HOME/.local/bin/codex-hermes-proxy")" -gt "$launcher_backups_before" ] ||
  fail "sync must back up drifted launcher"
[ "$(grep -Fc '@~/.codex/RTK.md' "$HOME/.codex/AGENTS.md")" -eq 1 ] ||
  fail "sync must normalize duplicate RTK includes"
bash "$script" doctor > /dev/null

unmanaged_home="$(mktemp -d)"
HOME="$unmanaged_home"
export HOME
mkdir -p "$HOME/.codex"
printf 'user AGENTS\n' > "$HOME/.codex/AGENTS.md"
expect_fail bash "$script" sync
HOME="$original_home"
export HOME
rm -rf -- "$unmanaged_home"

backup_root="$HOME/.kisa-backups/test-global-codex"
mkdir -p \
  "$backup_root/present/.codex" \
  "$backup_root/present/.local/bin" \
  "$backup_root/absent/.codex"
printf 'original agents\n' > "$backup_root/present/.codex/AGENTS.md"
printf 'original hooks\n' > "$backup_root/present/.codex/hooks.json"
printf 'original launcher\n' > "$backup_root/present/.local/bin/codex-hermes-proxy"
: > "$backup_root/absent/.codex/.kisa-managed"
bash "$rollback" "$backup_root" > "$tmp_home/rollback.out"
grep -Fxq 'original agents' "$HOME/.codex/AGENTS.md" ||
  fail "rollback must restore AGENTS"
grep -Fxq 'original hooks' "$HOME/.codex/hooks.json" ||
  fail "rollback must restore hooks"
grep -Fxq 'original launcher' "$HOME/.local/bin/codex-hermes-proxy" ||
  fail "rollback must restore Hermes launcher"
[ ! -e "$HOME/.codex/.kisa-managed" ] ||
  fail "rollback must remove generated managed state"

echo "Kate global Codex config tests passed."
