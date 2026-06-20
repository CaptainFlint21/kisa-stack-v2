#!/usr/bin/env bash
set -euo pipefail

hook_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
context="$("$hook_dir/wiki-context.sh" codex)"

WIKI_CONTEXT="$context" python3 - <<'PY'
import json
import os

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": os.environ["WIKI_CONTEXT"],
    }
}, ensure_ascii=False))
PY
