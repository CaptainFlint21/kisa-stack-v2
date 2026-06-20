#!/usr/bin/env bash
set -euo pipefail

runtime="${1:-agent}"
vault="${WIKI_VAULT:-$HOME/LLM Wiki}"

cat <<EOF
## LLM Wiki — required analysis anchor
- Runtime: $runtime
- Canonical vault: $vault/
- Start with: $vault/$runtime/pages/overview.md and components.md.
- Read workflows.md, architecture.md, or goals-and-roadmap.md when relevant.
- Verify repository and live system facts directly; the Wiki is durable context, not a substitute for inspection.
- Do not write durable notes unless the user asks or the active workflow explicitly requires it.
- Reply in Russian unless the user requests another language.
EOF
