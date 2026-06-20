#!/usr/bin/env bash
set -euo pipefail

backup_root="${1:-}"
if [ -z "$backup_root" ]; then
  latest_file="$HOME/.kisa-backups/latest"
  [ -f "$latest_file" ] || {
    echo "Usage: bash deploy/kate/rollback.sh <backup-directory>" >&2
    exit 2
  }
  read -r backup_root < "$latest_file"
fi

case "$backup_root" in
  "$HOME/.kisa-backups/"*) ;;
  *) echo "Refusing backup path outside ~/.kisa-backups: $backup_root" >&2; exit 1 ;;
esac

[ -d "$backup_root" ] || { echo "Backup not found: $backup_root" >&2; exit 1; }

restore_relative() {
  local relative="$1"
  local target="$HOME/$relative"
  local present="$backup_root/present/$relative"
  local absent="$backup_root/absent/$relative"

  case "$target" in
    "$HOME"/*) ;;
    *) echo "Refusing target outside HOME: $target" >&2; exit 1 ;;
  esac

  if [ -e "$present" ]; then
    rm -rf -- "$target"
    mkdir -p "$(dirname "$target")"
    cp -a "$present" "$target"
    echo "Restored: $target"
  elif [ -e "$absent" ]; then
    rm -rf -- "$target"
    echo "Removed bootstrap-created path: $target"
  else
    echo "No snapshot entry, unchanged: $target"
  fi
}

restore_relative ".codex/AGENTS.md"
restore_relative ".codex/hooks.json"
restore_relative ".codex/hooks"
restore_relative ".config/kate-proxy"
restore_relative ".config/environment.d/90-codex-proxy.conf"
restore_relative ".profile"
restore_relative ".bashrc"
restore_relative ".hermes/config.yaml"
restore_relative ".hermes/hooks"

core_skills=(
  researcher
  gamer-signal
  stream-timecodes
  elevenlabs-living-voice
  emotional-support
  telegram-chat-wiki
  codex-delegator
)
for skill in "${core_skills[@]}"; do
  restore_relative ".agents/skills/$skill"
  restore_relative ".hermes/skills/$skill"
done

echo "Rollback complete from: $backup_root"
echo "Restart Codex and Hermes before further testing."
