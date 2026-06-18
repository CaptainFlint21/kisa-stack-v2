#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_home="$(mktemp -d)"
trap 'rm -rf -- "$tmp_home"' EXIT

export HOME="$tmp_home"
export CODEX_SKILLS_DIR="$HOME/.agents/skills"
export HERMES_HOME="$HOME/.hermes"

bash "$repo_dir/install.sh" install core --codex --hermes --dry-run
[ ! -e "$CODEX_SKILLS_DIR" ]
[ ! -e "$HERMES_HOME/skills" ]

bash "$repo_dir/install.sh" install core --codex --hermes
bash "$repo_dir/install.sh" doctor core --codex --hermes

for skill in researcher gamer-signal stream-timecodes elevenlabs-living-voice emotional-support telegram-chat-wiki codex-delegator; do
  [ -f "$CODEX_SKILLS_DIR/$skill/SKILL.md" ]
  [ -f "$CODEX_SKILLS_DIR/$skill/agents/openai.yaml" ]
  [ -f "$HERMES_HOME/skills/$skill/SKILL.md" ]
done

before_backups="$(find "$CODEX_SKILLS_DIR" -maxdepth 1 -name '*.backup-*' | wc -l)"
bash "$repo_dir/install.sh" sync core --codex --hermes
after_backups="$(find "$CODEX_SKILLS_DIR" -maxdepth 1 -name '*.backup-*' | wc -l)"
[ "$before_backups" -eq "$after_backups" ]

printf '\nlocal drift\n' >> "$CODEX_SKILLS_DIR/researcher/SKILL.md"
bash "$repo_dir/install.sh" sync core --codex
find "$CODEX_SKILLS_DIR" -maxdepth 1 -name 'researcher.backup-*' | grep -q .
bash "$repo_dir/install.sh" doctor core --codex

line_count="$(python3 "$repo_dir/skills/stream-timecodes/scripts/process_vtt.py" \
  "$repo_dir/tests/fixtures/sample.vtt" | wc -l)"
[ "$line_count" -eq 18 ]

echo "Installer and core smoke tests passed."
