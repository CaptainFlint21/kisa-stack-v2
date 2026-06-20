#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
kate_dir="$repo_dir/deploy/kate"

action="${1:-}"
usage() {
  cat >&2 <<'EOF'
Usage:
  bash deploy/kate/codex-global-config.sh install [--dry-run]
  bash deploy/kate/codex-global-config.sh sync [--dry-run]
  bash deploy/kate/codex-global-config.sh doctor

Installs, syncs, and validates Kate's global Codex config:
  ~/.codex/AGENTS.md
  ~/.codex/hooks.json
  ~/.local/bin/codex-hermes-proxy

The Hermes MCP launcher uses ~/.hermes/hermes-proxy.env and never prints proxy
values.
EOF
}

[ -n "$action" ] || {
  usage
  exit 2
}
shift || true

dry_run=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

case "$action" in
  install|sync|doctor) ;;
  -h|--help) usage; exit 0 ;;
  *) echo "Unknown action: $action" >&2; exit 2 ;;
esac

log() { printf '%s\n' "$*"; }

agents_target="$HOME/.codex/AGENTS.md"
hooks_target="$HOME/.codex/hooks.json"
state_dir="$HOME/.codex/.kisa-managed"
launcher_path="${CODEX_HERMES_PROXY_PATH:-$HOME/.local/bin/codex-hermes-proxy}"
hermes_proxy_env="${CODEX_HERMES_PROXY_ENV:-$HOME/.hermes/hermes-proxy.env}"
hermes_config="$HOME/.hermes/config.yaml"
nvm_root="${CODEX_NVM_ROOT:-$HOME/.nvm/versions/node}"

timestamp="$(date +%Y%m%d-%H%M%S)"

run() {
  if [ "$dry_run" -eq 1 ]; then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

backup_path() {
  local target="$1"
  local base="$target.backup-$timestamp"
  local candidate="$base"
  local index=1
  while [ -e "$candidate" ] || [ -L "$candidate" ]; do
    candidate="$base-$index"
    index=$((index + 1))
  done
  printf '%s\n' "$candidate"
}

state_path_for() {
  local name="$1"
  printf '%s/%s.sha256' "$state_dir" "$name"
}

sha_file() {
  sha256sum "$1" | awk '{print $1}'
}

write_state() {
  local name="$1"
  local desired="$2"
  local state_path
  state_path="$(state_path_for "$name")"
  run mkdir -p "$state_dir"
  if [ "$dry_run" -eq 1 ]; then
    log "[dry-run] record managed state: $state_path"
  else
    sha_file "$desired" > "$state_path"
    chmod 600 "$state_path"
  fi
}

is_managed() {
  local name="$1"
  local target="$2"
  local state_path
  state_path="$(state_path_for "$name")"
  [ -f "$state_path" ] || return 1
  [ -e "$target" ] || return 0
  return 0
}

normalize_agents_template() {
  awk '
    BEGIN { seen_rtk = 0 }
    /^@~\/\.codex\/RTK\.md$/ || /^@\/home\/kate\/\.codex\/RTK\.md$/ {
      if (seen_rtk == 0) {
        print "@~/.codex/RTK.md"
        seen_rtk = 1
      }
      next
    }
    { print }
  ' "$kate_dir/templates/AGENTS.md"
}

render_hooks_template() {
  TEMPLATE_SOURCE="$kate_dir/templates/codex-hooks.json" \
  TEMPLATE_HOME="$HOME" \
  python3 - <<'PY'
import os
from pathlib import Path

source = Path(os.environ["TEMPLATE_SOURCE"])
text = source.read_text(encoding="utf-8")
print(text.replace("__HOME__", os.environ["TEMPLATE_HOME"]), end="")
PY
}

launcher_content() {
  cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

proxy_env="${CODEX_HERMES_PROXY_ENV:-$HOME/.hermes/hermes-proxy.env}"
[ -f "$proxy_env" ] || {
  echo "Hermes proxy env not found" >&2
  exit 126
}

unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy
set -a
# shellcheck disable=SC1090
source <(sed 's/\r$//' "$proxy_env")
set +a

for key in HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY; do
  lower="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
  if [ -n "${!key+x}" ]; then
    export "$lower=${!key}"
  elif [ -n "${!lower+x}" ]; then
    export "$key=${!lower}"
  else
    unset "$key" "$lower"
  fi
done

wrapper_real="$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s\n' "${BASH_SOURCE[0]}")"
nvm_root="${CODEX_NVM_ROOT:-$HOME/.nvm/versions/node}"
real_codex=""

if [ -d "$nvm_root" ]; then
  while IFS= read -r candidate; do
    [ -x "$candidate" ] || continue
    candidate_real="$(readlink -f -- "$candidate" 2>/dev/null || printf '%s\n' "$candidate")"
    [ "$candidate_real" != "$wrapper_real" ] || continue
    real_codex="$candidate"
  done < <(find "$nvm_root" \( -path '*/bin/codex' -type f -o -path '*/bin/codex' -type l \) | sort -V)
fi

[ -n "$real_codex" ] || {
  echo "Real Codex CLI not found under NVM" >&2
  exit 127
}

exec "$real_codex" "$@"
EOF
}

make_desired_file() {
  local name="$1"
  local tmp="$2"
  case "$name" in
    agents) normalize_agents_template > "$tmp" ;;
    hooks) render_hooks_template > "$tmp" ;;
    launcher) launcher_content > "$tmp" ;;
    *) return 1 ;;
  esac
}

install_managed_file() {
  local name="$1"
  local target="$2"
  local mode="$3"
  local dir=""
  local tmp=""
  local backup=""

  dir="$(dirname -- "$target")"
  if [ "$dry_run" -eq 1 ]; then
    log "[dry-run] $action $target"
    return 0
  fi

  if [ "$action" = "sync" ] && ! is_managed "$name" "$target"; then
    log "FAIL refusing to sync unmanaged file: $target"
    return 1
  fi

  mkdir -p "$dir"
  tmp="$(mktemp "$dir/.kisa-$(basename -- "$target").XXXXXX")"
  make_desired_file "$name" "$tmp"
  chmod "$mode" "$tmp"

  if [ -f "$target" ] && [ ! -L "$target" ] && cmp -s "$tmp" "$target"; then
    chmod "$mode" "$target"
    write_state "$name" "$tmp"
    rm -f -- "$tmp"
    log "Unchanged: $target"
    return 0
  fi

  if [ -e "$target" ] || [ -L "$target" ]; then
    backup="$(backup_path "$target")"
    mv -T -- "$target" "$backup"
    log "Backed up: $target -> $backup"
  fi

  mv -fT -- "$tmp" "$target"
  chmod "$mode" "$target"
  write_state "$name" "$target"
  log "Installed: $target"
}

update_hermes_mcp_command() {
  local tmp=""
  local backup=""
  local mode=""
  local dir=""
  local rc=0

  if [ "$dry_run" -eq 1 ]; then
    log "[dry-run] canonicalize Hermes Codex MCP command in $hermes_config"
    return 0
  fi

  if [ ! -e "$hermes_config" ]; then
    log "SKIP Hermes config not found: $hermes_config"
    return 0
  fi
  if [ -L "$hermes_config" ] || [ ! -f "$hermes_config" ]; then
    log "FAIL Hermes config is not a regular file: $hermes_config"
    return 1
  fi

  dir="$(dirname -- "$hermes_config")"
  tmp="$(mktemp "$dir/.config.yaml.kisa-mcp.XXXXXX")"

  set +e
  HERMES_CONFIG="$hermes_config" \
  HERMES_CONFIG_OUT="$tmp" \
  KISA_CANONICAL_CODEX_MCP="$HOME/.local/bin/codex-hermes-proxy" \
  python3 - <<'PY'
import os
import re
import sys
from pathlib import Path

path = Path(os.environ["HERMES_CONFIG"])
out_path = Path(os.environ["HERMES_CONFIG_OUT"])
canonical = os.environ["KISA_CANONICAL_CODEX_MCP"]
text = path.read_text(encoding="utf-8")
lines = text.splitlines(keepends=True)
newline = "\n"
if lines:
    newline = "\r\n" if lines[0].endswith("\r\n") else "\n"


def indent(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def is_blank_or_comment(line: str) -> bool:
    stripped = line.strip()
    return stripped == "" or stripped.startswith("#")


def key_at(line: str, key: str) -> bool:
    return re.match(rf"^\s*{re.escape(key)}\s*:\s*(?:#.*)?$", line) is not None


def command_line(spaces: int) -> str:
    return f'{" " * spaces}command: "{canonical}"{newline}'


def minimal_codex_block(spaces: int) -> list[str]:
    child = spaces + 2
    return [
        f'{" " * spaces}codex:{newline}',
        command_line(child),
        f'{" " * child}args: ["mcp-server"]{newline}',
        f'{" " * child}timeout: 900{newline}',
        f'{" " * child}connect_timeout: 60{newline}',
        f'{" " * child}supports_parallel_tool_calls: false{newline}',
    ]


def block_end(start: int, parent_indent: int) -> int:
    index = start + 1
    while index < len(lines):
        line = lines[index]
        if not is_blank_or_comment(line) and indent(line) <= parent_indent:
            break
        index += 1
    return index


mcp_start = None
for index, line in enumerate(lines):
    if not is_blank_or_comment(line) and indent(line) == 0 and key_at(line, "mcp_servers"):
        mcp_start = index
        break

changed = False

if mcp_start is None:
    if lines and not lines[-1].endswith(("\n", "\r")):
        lines[-1] = lines[-1] + newline
    if lines and lines[-1].strip() != "":
        lines.append(newline)
    lines.extend(["mcp_servers:" + newline, *minimal_codex_block(2)])
    changed = True
else:
    mcp_indent = indent(lines[mcp_start])
    mcp_end = block_end(mcp_start, mcp_indent)
    child_indent = mcp_indent + 2
    for index in range(mcp_start + 1, mcp_end):
        if not is_blank_or_comment(lines[index]) and indent(lines[index]) > mcp_indent:
            child_indent = indent(lines[index])
            break

    codex_start = None
    for index in range(mcp_start + 1, mcp_end):
        if not is_blank_or_comment(lines[index]) and indent(lines[index]) == child_indent and key_at(lines[index], "codex"):
            codex_start = index
            break

    if codex_start is None:
        insert_at = mcp_end
        lines[insert_at:insert_at] = minimal_codex_block(child_indent)
        changed = True
    else:
        codex_indent = indent(lines[codex_start])
        codex_end = block_end(codex_start, codex_indent)
        command_index = None
        command_indent = codex_indent + 2
        for index in range(codex_start + 1, codex_end):
            line = lines[index]
            if not is_blank_or_comment(line) and indent(line) > codex_indent:
                if re.match(r"^\s*command\s*:", line):
                    command_index = index
                    command_indent = indent(line)
                    break
                command_indent = indent(line)
        desired = command_line(command_indent)
        if command_index is None:
            lines[codex_start + 1:codex_start + 1] = [desired]
            changed = True
        elif lines[command_index] != desired:
            lines[command_index] = desired
            changed = True

out_path.write_text("".join(lines), encoding="utf-8")
sys.exit(0 if changed else 10)
PY
  rc="$?"
  set -e

  case "$rc" in
    0)
      mode="$(stat -c '%a' "$hermes_config")"
      backup="$(backup_path "$hermes_config")"
      cp -a -- "$hermes_config" "$backup"
      chmod "$mode" "$tmp"
      mv -fT -- "$tmp" "$hermes_config"
      chmod "$mode" "$hermes_config"
      log "Backed up: $hermes_config -> $backup"
      log "Updated Hermes Codex MCP command: $hermes_config"
      ;;
    10)
      rm -f -- "$tmp"
      log "Unchanged: $hermes_config"
      ;;
    *)
      rm -f -- "$tmp"
      log "FAIL unable to canonicalize Hermes Codex MCP command: $hermes_config"
      return 1
      ;;
  esac
}

find_real_codex() {
  local wrapper_real=""
  local candidate=""
  local candidate_real=""
  local found=""

  if [ -e "$launcher_path" ]; then
    wrapper_real="$(readlink -f -- "$launcher_path" 2>/dev/null || printf '%s\n' "$launcher_path")"
  fi

  [ -d "$nvm_root" ] || return 1
  while IFS= read -r candidate; do
    [ -x "$candidate" ] || continue
    candidate_real="$(readlink -f -- "$candidate" 2>/dev/null || printf '%s\n' "$candidate")"
    [ -z "$wrapper_real" ] || [ "$candidate_real" != "$wrapper_real" ] || continue
    found="$candidate"
  done < <(find "$nvm_root" \( -path '*/bin/codex' -type f -o -path '*/bin/codex' -type l \) | sort -V)

  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

doctor_file_matches() {
  local label="$1"
  local name="$2"
  local target="$3"
  local expected_mode="$4"
  local tmp=""
  local mode=""
  local failed=0

  if [ ! -e "$target" ]; then
    log "FAIL $label missing: $target"
    return 1
  fi
  if [ -L "$target" ]; then
    log "FAIL $label is a symlink: $target"
    return 1
  fi
  if [ ! -f "$target" ]; then
    log "FAIL $label is not a regular file: $target"
    return 1
  fi

  mode="$(stat -c '%a' "$target")"
  if [ "$mode" != "$expected_mode" ]; then
    log "FAIL $label mode is $mode, expected $expected_mode"
    failed=1
  fi

  tmp="$(mktemp)"
  make_desired_file "$name" "$tmp"
  if ! cmp -s "$tmp" "$target"; then
    log "FAIL $label drift detected: $target"
    failed=1
  fi
  rm -f -- "$tmp"

  [ "$failed" -ne 0 ] || log "OK $label"
  return "$failed"
}

doctor_launcher_runtime() {
  local failed=0

  doctor_file_matches "Hermes Codex MCP launcher" launcher "$launcher_path" 700 || failed=1
  if [ -f "$launcher_path" ]; then
    if ! grep -Fq '.hermes/hermes-proxy.env' "$launcher_path"; then
      log "FAIL Hermes launcher does not reference ~/.hermes/hermes-proxy.env"
      failed=1
    fi
    if grep -Fq '.hermes/codex-proxy.env' "$launcher_path"; then
      log "FAIL Hermes launcher references common Codex proxy env"
      failed=1
    fi
    if ! grep -Fq "sed 's/\\r$//'" "$launcher_path"; then
      log "FAIL Hermes launcher does not normalize CRLF proxy env"
      failed=1
    fi
  fi

  if [ -e "$hermes_proxy_env" ]; then
    if [ -L "$hermes_proxy_env" ]; then
      log "FAIL Hermes proxy env is a symlink: $hermes_proxy_env"
      failed=1
    elif [ ! -f "$hermes_proxy_env" ]; then
      log "FAIL Hermes proxy env is not a regular file: $hermes_proxy_env"
      failed=1
    elif [ "$(stat -c '%a' "$hermes_proxy_env")" != "600" ]; then
      log "FAIL Hermes proxy env mode is $(stat -c '%a' "$hermes_proxy_env"), expected 600"
      failed=1
    fi
  else
    log "FAIL Hermes proxy env missing: $hermes_proxy_env"
    failed=1
  fi

  if ! find_real_codex >/dev/null; then
    log "FAIL real Codex CLI not found under NVM"
    failed=1
  fi

  return "$failed"
}

doctor_hermes_mcp_command() {
  local expected_template='command: "__HOME__/.local/bin/codex-hermes-proxy"'
  local failed=0

  if grep -Fq "$expected_template" "$kate_dir/templates/hermes-config.yaml"; then
    log "OK Hermes config template uses canonical Codex MCP launcher"
  else
    log "FAIL Hermes config template does not use canonical Codex MCP launcher"
    failed=1
  fi

  if [ -f "$hermes_config" ]; then
    if HERMES_CONFIG="$hermes_config" \
      KISA_CANONICAL_CODEX_MCP="$HOME/.local/bin/codex-hermes-proxy" \
      python3 - <<'PY'
import os
import re
import sys
from pathlib import Path

lines = Path(os.environ["HERMES_CONFIG"]).read_text(encoding="utf-8").splitlines()
canonical = os.environ["KISA_CANONICAL_CODEX_MCP"]


def indent(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def is_blank_or_comment(line: str) -> bool:
    stripped = line.strip()
    return stripped == "" or stripped.startswith("#")


def key_at(line: str, key: str) -> bool:
    return re.match(rf"^\s*{re.escape(key)}\s*:\s*(?:#.*)?$", line) is not None


def block_end(start: int, parent_indent: int) -> int:
    index = start + 1
    while index < len(lines):
        line = lines[index]
        if not is_blank_or_comment(line) and indent(line) <= parent_indent:
            break
        index += 1
    return index


mcp_start = None
for index, line in enumerate(lines):
    if not is_blank_or_comment(line) and indent(line) == 0 and key_at(line, "mcp_servers"):
        mcp_start = index
        break
if mcp_start is None:
    sys.exit(1)

mcp_indent = indent(lines[mcp_start])
mcp_end = block_end(mcp_start, mcp_indent)
child_indent = mcp_indent + 2
for index in range(mcp_start + 1, mcp_end):
    if not is_blank_or_comment(lines[index]) and indent(lines[index]) > mcp_indent:
        child_indent = indent(lines[index])
        break

codex_start = None
for index in range(mcp_start + 1, mcp_end):
    if not is_blank_or_comment(lines[index]) and indent(lines[index]) == child_indent and key_at(lines[index], "codex"):
        codex_start = index
        break
if codex_start is None:
    sys.exit(1)

codex_indent = indent(lines[codex_start])
codex_end = block_end(codex_start, codex_indent)
for index in range(codex_start + 1, codex_end):
    line = lines[index]
    if not is_blank_or_comment(line) and re.match(r"^\s*command\s*:", line):
        value = line.split(":", 1)[1].strip().strip('"').strip("'")
        sys.exit(0 if value == canonical else 1)
sys.exit(1)
PY
    then
      log "OK Hermes config uses canonical Codex MCP launcher"
    else
      log "FAIL Hermes config does not use canonical Codex MCP launcher: $hermes_config"
      failed=1
    fi
  else
    log "FAIL Hermes config not found: $hermes_config"
    failed=1
  fi

  return "$failed"
}

install_or_sync() {
  local failed=0
  install_managed_file agents "$agents_target" 600 || failed=1
  install_managed_file hooks "$hooks_target" 600 || failed=1
  install_managed_file launcher "$launcher_path" 700 || failed=1
  update_hermes_mcp_command || failed=1
  return "$failed"
}

doctor() {
  local failed=0
  doctor_file_matches "global Codex AGENTS" agents "$agents_target" 600 || failed=1
  doctor_file_matches "global Codex hooks" hooks "$hooks_target" 600 || failed=1
  doctor_launcher_runtime || failed=1
  doctor_hermes_mcp_command || failed=1
  if [ "$failed" -eq 0 ]; then
    log "OK global Codex config"
  fi
  return "$failed"
}

case "$action" in
  install|sync) install_or_sync ;;
  doctor) doctor ;;
esac
