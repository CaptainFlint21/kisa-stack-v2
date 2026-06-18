#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
kate_dir="$repo_dir/deploy/kate"
dry_run=0
install_dependencies=1
configure_telegram=1

usage() {
  cat <<'EOF'
Usage: bash deploy/kate/bootstrap.sh [options]

Options:
  --dry-run              Print actions without changing the machine
  --skip-dependencies    Do not install Hermes or RTK when missing
  --skip-telegram        Install with Telegram disabled and placeholder values
  -h, --help             Show this help

Environment overrides for non-interactive Telegram rendering:
  TELEGRAM_BOT_TOKEN
  TELEGRAM_OWNER_ID
  TELEGRAM_GROUP_ID
EOF
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    --skip-dependencies) install_dependencies=0 ;;
    --skip-telegram) configure_telegram=0 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

run() {
  if [ "$dry_run" -eq 1 ]; then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

export PATH="$HOME/.local/bin:$PATH"

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_root="$HOME/.kisa-backups/$timestamp"

snapshot_path() {
  local relative="$1"
  local source="$HOME/$relative"
  local present="$backup_root/present/$relative"
  local absent="$backup_root/absent/$relative"

  if [ -e "$source" ]; then
    run mkdir -p "$(dirname "$present")"
    run cp -a "$source" "$present"
  else
    run mkdir -p "$(dirname "$absent")"
    if [ "$dry_run" -eq 1 ]; then
      log "[dry-run] mark absent: $relative"
    else
      : > "$absent"
    fi
  fi
}

install_remote_script() {
  local name="$1"
  local url="$2"
  local tmp_dir
  tmp_dir="$(mktemp -d)"

  log "Installing $name from its official installer..."
  if [ "$dry_run" -eq 1 ]; then
    run curl -fsSL "$url" -o "$tmp_dir/install.sh"
    run bash "$tmp_dir/install.sh"
  else
    if ! curl -fsSL "$url" -o "$tmp_dir/install.sh"; then
      rm -rf -- "$tmp_dir"
      fail "Failed to download the $name installer"
    fi
    if ! bash "$tmp_dir/install.sh"; then
      rm -rf -- "$tmp_dir"
      fail "$name installer failed"
    fi
  fi
  rm -rf -- "$tmp_dir"
}

seed_page() {
  local runtime="$1"
  local page="$2"
  local title="$3"
  local target="$HOME/LLM Wiki/$runtime/pages/$page.md"

  [ -e "$target" ] && return 0
  run mkdir -p "$(dirname "$target")"
  if [ "$dry_run" -eq 1 ]; then
    log "[dry-run] create Wiki page: $target"
    return 0
  fi

  cat > "$target" <<EOF
# $title

Status: bootstrap stub

This page belongs to the canonical KISA Wiki space for **$runtime** on Kate.
Replace this stub with reviewed, durable knowledge. Verify live repository and
system facts before relying on historical notes.

## Current baseline

- Host: Kate (Linux)
- KISA repository: ~/src/kisa-stack-v2
- Wiki root: ~/LLM Wiki
- Codex skills: ~/.agents/skills
- Hermes skills: ~/.hermes/skills
- Hermes delegates coding work through the Codex MCP server.
EOF
}

render_template() {
  local source="$1"
  local target="$2"
  local bot_token="$3"
  local owner_id="$4"
  local group_id="$5"
  local telegram_enabled="$6"

  run mkdir -p "$(dirname "$target")"
  if [ "$dry_run" -eq 1 ]; then
    log "[dry-run] render $source -> $target"
    return 0
  fi

  TEMPLATE_SOURCE="$source" TEMPLATE_TARGET="$target" \
  KISA_HOME="$HOME" TELEGRAM_BOT_TOKEN="$bot_token" \
  TELEGRAM_OWNER_ID="$owner_id" TELEGRAM_GROUP_ID="$group_id" \
  TELEGRAM_ENABLED="$telegram_enabled" \
  python3 - <<'PY'
import os
from pathlib import Path

source = Path(os.environ["TEMPLATE_SOURCE"])
target = Path(os.environ["TEMPLATE_TARGET"])
text = source.read_text(encoding="utf-8")
replacements = {
    "__HOME__": os.environ["KISA_HOME"],
    "__TELEGRAM_BOT_TOKEN__": os.environ["TELEGRAM_BOT_TOKEN"],
    "__TELEGRAM_OWNER_ID__": os.environ["TELEGRAM_OWNER_ID"],
    "__TELEGRAM_GROUP_ID__": os.environ["TELEGRAM_GROUP_ID"],
    "__TELEGRAM_ENABLED__": os.environ["TELEGRAM_ENABLED"],
}
for key, value in replacements.items():
    text = text.replace(key, value)
target.write_text(text, encoding="utf-8")
PY
  chmod 600 "$target"
}

for command in git curl python3 sha256sum; do
  command -v "$command" >/dev/null 2>&1 || fail "Required command not found: $command"
done

[ -f "$repo_dir/install.sh" ] || fail "Run this script from a kisa-stack-v2 checkout"

if ! command -v codex >/dev/null 2>&1; then
  fail "Codex CLI is not installed or not in PATH on Kate"
fi

if ! command -v hermes >/dev/null 2>&1; then
  [ "$install_dependencies" -eq 1 ] || fail "Hermes is missing and dependency installation is disabled"
  install_remote_script "Hermes" "https://hermes-agent.nousresearch.com/install.sh"
  export PATH="$HOME/.local/bin:$PATH"
  if [ "$dry_run" -eq 0 ]; then
    command -v hermes >/dev/null 2>&1 || fail "Hermes installed but is not available in PATH"
  fi
fi

if ! command -v rtk >/dev/null 2>&1; then
  [ "$install_dependencies" -eq 1 ] || fail "RTK is missing and dependency installation is disabled"
  install_remote_script "RTK" "https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh"
  export PATH="$HOME/.local/bin:$PATH"
  if [ "$dry_run" -eq 0 ]; then
    command -v rtk >/dev/null 2>&1 || fail "RTK installed but is not available in PATH"
  fi
fi

core_skills=(
  researcher
  gamer-signal
  stream-timecodes
  elevenlabs-living-voice
  emotional-support
  telegram-chat-wiki
  codex-delegator
)

snapshot_path ".codex/AGENTS.md"
snapshot_path ".codex/hooks.json"
snapshot_path ".codex/hooks"
snapshot_path ".hermes/config.yaml"
snapshot_path ".hermes/hooks"
for skill in "${core_skills[@]}"; do
  snapshot_path ".agents/skills/$skill"
  snapshot_path ".hermes/skills/$skill"
done

run mkdir -p "$HOME/.codex" "$HOME/.hermes" "$HOME/.agents/skills"
run cp "$kate_dir/templates/AGENTS.md" "$HOME/.codex/AGENTS.md"
run chmod 600 "$HOME/.codex/AGENTS.md"

run mkdir -p "$HOME/.codex/hooks" "$HOME/.hermes/hooks"
for hook in wiki-context.sh codex-session-start.sh codex-user-prompt.sh; do
  run cp "$kate_dir/hooks/$hook" "$HOME/.codex/hooks/$hook"
done
for hook in wiki-context.sh hermes-pre-llm.sh; do
  run cp "$kate_dir/hooks/$hook" "$HOME/.hermes/hooks/$hook"
done
if [ "$dry_run" -eq 0 ]; then
  chmod +x "$HOME/.codex/hooks/"*.sh "$HOME/.hermes/hooks/"*.sh
fi

render_template "$kate_dir/templates/codex-hooks.json" "$HOME/.codex/hooks.json" \
  "" "" "" "false"

bot_token="${TELEGRAM_BOT_TOKEN:-}"
owner_id="${TELEGRAM_OWNER_ID:-}"
group_id="${TELEGRAM_GROUP_ID:-}"
telegram_enabled="true"

if [ "$configure_telegram" -eq 1 ] && [ "$dry_run" -eq 0 ]; then
  if [ -z "$bot_token" ]; then
    read -r -s -p "Telegram bot token: " bot_token
    printf '\n'
  fi
  if [ -z "$owner_id" ]; then
    read -r -p "Telegram owner user ID: " owner_id
  fi
  if [ -z "$group_id" ]; then
    read -r -p "Allowed private group chat ID: " group_id
  fi
fi

if [ "$configure_telegram" -eq 0 ]; then
  telegram_enabled="false"
  bot_token="${bot_token:-DISABLED}"
  owner_id="${owner_id:-0}"
  group_id="${group_id:-0}"
elif [ "$dry_run" -eq 1 ]; then
  bot_token="${bot_token:-SET_WITH_TELEGRAM_BOT_TOKEN}"
  owner_id="${owner_id:-SET_WITH_TELEGRAM_OWNER_ID}"
  group_id="${group_id:-SET_WITH_TELEGRAM_GROUP_ID}"
else
  [ -n "$bot_token" ] || fail "Telegram bot token is required"
  [[ "$owner_id" =~ ^[0-9]+$ ]] || fail "Telegram owner ID must be a positive integer"
  [[ "$group_id" =~ ^-?[0-9]+$ ]] || fail "Telegram group ID must be an integer"
fi

render_template "$kate_dir/templates/hermes-config.yaml" "$HOME/.hermes/config.yaml" \
  "$bot_token" "$owner_id" "$group_id" "$telegram_enabled"

for runtime in codex hermes; do
  seed_page "$runtime" overview "Overview"
  seed_page "$runtime" components "Components"
  seed_page "$runtime" workflows "Workflows"
  seed_page "$runtime" architecture "Architecture"
  seed_page "$runtime" goals-and-roadmap "Goals and roadmap"
done

install_args=(sync core --codex --hermes)
[ "$dry_run" -eq 1 ] && install_args+=(--dry-run)
bash "$repo_dir/install.sh" "${install_args[@]}"

run rtk init -g --codex
run rtk init --agent hermes

if [ "$dry_run" -eq 0 ]; then
  printf '%s\n' "$backup_root" > "$HOME/.kisa-backups/latest"
  chmod 600 "$HOME/.kisa-backups/latest"
fi

cat <<EOF

Bootstrap files are prepared.
Backup snapshot: $backup_root

Manual authentication and activation are intentionally separate:
  1. hermes auth add openai-codex --type oauth --no-browser --manual-paste
  2. hermes model
  3. hermes --accept-hooks -z "Reply with OK. Do not use tools."
  4. hermes hooks doctor
  5. hermes mcp test codex
  6. hermes gateway install
  7. hermes gateway start
  8. hermes gateway status --deep

Keep the Telegram bot in the single approved private group. The config accepts
commands only from the owner ID and requires a mention/reply in groups.
EOF
