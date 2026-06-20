#!/usr/bin/env bash
set -euo pipefail
umask 077

hook_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
input="$(cat)"

session_id="$(printf '%s' "$input" | python3 -c 'import json,sys; data=json.load(sys.stdin); print(data.get("session_id", "unknown"))' 2>/dev/null || printf unknown)"
key="$(printf '%s' "$session_id" | sha256sum | cut -d' ' -f1)"
state_dir="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/kisa-hooks-$UID"
mkdir -p "$state_dir"
chmod 700 "$state_dir"
state_file="$state_dir/codex-wiki-$key"

count=0
if [ -f "$state_file" ]; then
  read -r count < "$state_file" || count=0
fi
case "$count" in
  ''|*[!0-9]*) count=0 ;;
esac
count=$((count + 1))
printf '%s\n' "$count" > "$state_file"

if [ $((count % 3)) -ne 0 ]; then
  exit 0
fi

context="$("$hook_dir/wiki-context.sh" codex)"
WIKI_CONTEXT="$context" python3 - <<'PY'
import json
import os

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": os.environ["WIKI_CONTEXT"],
    }
}, ensure_ascii=False))
PY
