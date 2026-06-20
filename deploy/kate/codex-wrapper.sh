#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  bash deploy/kate/codex-wrapper.sh repair [--dry-run]
  bash deploy/kate/codex-wrapper.sh doctor

Repairs and validates Kate's ~/.local/bin/codex proxy wrapper. The wrapper keeps
Hermes/Codex MCP traffic on the local proxy after npm updates replace the Codex
CLI launcher. It never prints proxy environment values.
EOF
}

log() {
  printf '%s\n' "$*"
}

action="${1:-}"
[ -n "$action" ] || { usage; exit 2; }
shift || true

dry_run=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

case "$action" in
  repair|doctor) ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac

wrapper_path="${CODEX_WRAPPER_PATH:-$HOME/.local/bin/codex}"
proxy_env="${CODEX_PROXY_ENV:-$HOME/.hermes/codex-proxy.env}"
nvm_root="${CODEX_NVM_ROOT:-$HOME/.nvm/versions/node}"

wrapper_content() {
  cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

proxy_env="${CODEX_PROXY_ENV:-$HOME/.hermes/codex-proxy.env}"
[ -f "$proxy_env" ] || {
  echo "Codex proxy env not found" >&2
  exit 126
}

set -a
# shellcheck disable=SC1090
source <(sed 's/\r$//' "$proxy_env")
set +a

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

find_real_codex() {
  local wrapper_real=""
  local candidate=""
  local candidate_real=""
  local found=""

  if [ -e "$wrapper_path" ]; then
    wrapper_real="$(readlink -f -- "$wrapper_path" 2>/dev/null || printf '%s\n' "$wrapper_path")"
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

desired_matches() {
  local tmp="$1"
  [ -f "$wrapper_path" ] || return 1
  [ ! -L "$wrapper_path" ] || return 1
  cmp -s "$tmp" "$wrapper_path"
}

next_backup_path() {
  local base="$wrapper_path.backup-$(date +%Y%m%d-%H%M%S)"
  local candidate="$base"
  local index=1
  while [ -e "$candidate" ] || [ -L "$candidate" ]; do
    candidate="$base-$index"
    index=$((index + 1))
  done
  printf '%s\n' "$candidate"
}

repair() {
  local dir
  local tmp
  local backup
  dir="$(dirname -- "$wrapper_path")"

  if [ "$dry_run" -eq 1 ]; then
    log "[dry-run] repair Codex proxy wrapper at $wrapper_path"
    return 0
  fi

  mkdir -p "$dir"
  tmp="$(mktemp "$dir/.codex-wrapper.XXXXXX")"
  wrapper_content > "$tmp"
  chmod 700 "$tmp"

  if desired_matches "$tmp"; then
    chmod 700 "$wrapper_path"
    rm -f -- "$tmp"
    log "Codex proxy wrapper unchanged: $wrapper_path"
    return 0
  fi

  if [ -e "$wrapper_path" ] || [ -L "$wrapper_path" ]; then
    backup="$(next_backup_path)"
    mv -T -- "$wrapper_path" "$backup"
    log "Backed up Codex launcher: $backup"
  fi

  mv -f -- "$tmp" "$wrapper_path"
  chmod 700 "$wrapper_path"
  log "Installed Codex proxy wrapper: $wrapper_path"
}

doctor() {
  local failed=0
  local mode=""

  if [ ! -e "$wrapper_path" ] && [ ! -L "$wrapper_path" ]; then
    log "FAIL Codex proxy wrapper missing: $wrapper_path"
    failed=1
  elif [ -L "$wrapper_path" ]; then
    log "FAIL Codex proxy wrapper is a symlink: $wrapper_path"
    failed=1
  elif [ ! -f "$wrapper_path" ]; then
    log "FAIL Codex proxy wrapper is not a regular file: $wrapper_path"
    failed=1
  else
    mode="$(stat -c '%a' "$wrapper_path")"
    if [ "$mode" != "700" ]; then
      log "FAIL Codex proxy wrapper mode is $mode, expected 700"
      failed=1
    fi
    if ! grep -Fq '.hermes/codex-proxy.env' "$wrapper_path"; then
      log "FAIL Codex proxy wrapper does not reference ~/.hermes/codex-proxy.env"
      failed=1
    fi
    if ! grep -Fq "sed 's/\\r$//'" "$wrapper_path"; then
      log "FAIL Codex proxy wrapper does not normalize CRLF proxy env"
      failed=1
    fi
  fi

  if [ ! -f "$proxy_env" ]; then
    log "FAIL Codex proxy env missing: $proxy_env"
    failed=1
  else
    mode="$(stat -c '%a' "$proxy_env")"
    if [ "$mode" != "600" ]; then
      log "FAIL Codex proxy env mode is $mode, expected 600"
      failed=1
    fi
  fi

  if ! find_real_codex >/dev/null; then
    log "FAIL real Codex CLI not found under NVM"
    failed=1
  fi

  if [ "$failed" -eq 0 ]; then
    log "OK Codex proxy wrapper"
  fi
  return "$failed"
}

case "$action" in
  repair) repair ;;
  doctor) doctor ;;
esac
