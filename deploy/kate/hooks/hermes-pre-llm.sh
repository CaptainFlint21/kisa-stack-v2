#!/usr/bin/env bash
set -euo pipefail

hook_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
input="$(cat)"

parsed="$(printf '%s' "$input" | python3 -c 'import json,sys; d=json.load(sys.stdin); e=d.get("extra", {}); print(d.get("session_id", "unknown")); print("1" if e.get("is_first_turn", d.get("is_first_turn", False)) else "0")' 2>/dev/null || printf 'unknown\n0\n')"
session_id="$(printf '%s\n' "$parsed" | sed -n '1p')"
is_first="$(printf '%s\n' "$parsed" | sed -n '2p')"
key="$(printf '%s' "$session_id" | sha256sum | cut -d' ' -f1)"
state_dir="${XDG_RUNTIME_DIR:-/tmp}"
state_file="$state_dir/kisa-hermes-wiki-$key"

count=0
if [ -f "$state_file" ]; then
  read -r count < "$state_file" || count=0
fi
case "$count" in
  ''|*[!0-9]*) count=0 ;;
esac
count=$((count + 1))
printf '%s\n' "$count" > "$state_file"

if [ "$is_first" != "1" ] && [ $((count % 3)) -ne 0 ]; then
  exit 0
fi

context="$($hook_dir/wiki-context.sh hermes)"
WIKI_CONTEXT="$context" python3 - <<'PY'
import json
import os

print(json.dumps({"context": os.environ["WIKI_CONTEXT"]}, ensure_ascii=False))
PY
