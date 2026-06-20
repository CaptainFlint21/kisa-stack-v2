#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_home="$(mktemp -d)"
trap 'rm -rf -- "$tmp_home"' EXIT

export HOME="$tmp_home"
export CODEX_SKILLS_DIR="$HOME/.agents/skills"
export HERMES_HOME="$HOME/.hermes"

mkdir -p "$HOME/.hermes" "$HOME/.nvm/versions/node/v24.14.1/bin"
printf 'KISA_PROXY_TEST=installer\r\n' > "$HOME/.hermes/codex-proxy.env"
chmod 600 "$HOME/.hermes/codex-proxy.env"
cat > "$HOME/.nvm/versions/node/v24.14.1/bin/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'codex-test\n'
EOF
chmod +x "$HOME/.nvm/versions/node/v24.14.1/bin/codex"

bash "$repo_dir/install.sh" install core --codex --hermes --dry-run
[ ! -e "$CODEX_SKILLS_DIR" ]
[ ! -e "$HERMES_HOME/skills" ]

bash "$repo_dir/install.sh" install core --codex --hermes
bash "$repo_dir/deploy/kate/codex-wrapper.sh" doctor
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
