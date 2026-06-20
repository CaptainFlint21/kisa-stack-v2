#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
skills_dir="$repo_dir/skills"
profiles_dir="$repo_dir/profiles"

usage() {
  cat >&2 <<'EOF'
Usage:
  ./install.sh <install|sync|doctor> <skill-name|profile|all> [runtime flags] [--dry-run]
  ./install.sh <skill-name|all> [runtime flags] [--dry-run]  # legacy install form

Runtime flags:
  --claude   Install into ~/.claude/skills
  --codex    Install into ~/.agents/skills (override with CODEX_SKILLS_DIR)
  --hermes   Install into ${HERMES_HOME:-~/.hermes}/skills

Without runtime flags, Claude + Codex are selected for backward compatibility.
Profiles are text files in profiles/*.txt (one skill name per line).
EOF

  echo "" >&2
  echo "Available profiles:" >&2
  if [ -d "$profiles_dir" ]; then
    for profile in "$profiles_dir"/*.txt; do
      [ -f "$profile" ] || continue
      echo "  - $(basename "$profile" .txt)" >&2
    done
  fi

  echo "Available skills:" >&2
  for skill in "$skills_dir"/*/; do
    [ -d "$skill" ] || continue
    echo "  - $(basename "$skill")" >&2
  done
}

log() {
  printf '%s\n' "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

run() {
  if [ "$dry_run" -eq 1 ]; then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

require_safe_target() {
  local target_root="$1"
  local target_dir="$2"
  case "$target_dir" in
    "$target_root"/*) ;;
    *) fail "Refusing to modify path outside target root: $target_dir" ;;
  esac
  [ "$target_dir" != "/" ] || fail "Refusing to modify /"
  [ "$target_dir" != "$HOME" ] || fail "Refusing to modify HOME directly"
}

same_tree() {
  local source_dir="$1"
  local target_dir="$2"
  [ -d "$target_dir" ] || return 1
  diff -qr --exclude='.env' --exclude='node_modules' --exclude='__pycache__' \
    "$source_dir" "$target_dir" >/dev/null 2>&1
}

selection_includes() {
  local wanted="$1"
  local name
  for name in "${names[@]}"; do
    [ "$name" = "$wanted" ] && return 0
  done
  return 1
}

maintain_kate_codex_wrapper() {
  [ "$want_codex" -eq 1 ] || return 0
  selection_includes "codex-delegator" || return 0

  local wrapper_script="$repo_dir/deploy/kate/codex-wrapper.sh"
  [ -f "$wrapper_script" ] || return 0

  case "$action" in
    doctor)
      bash "$wrapper_script" doctor
      ;;
    install|sync)
      if [ "$dry_run" -eq 1 ]; then
        bash "$wrapper_script" repair --dry-run
      else
        bash "$wrapper_script" repair
      fi
      ;;
  esac
}

resolve_selection() {
  local selection="$1"
  local profile_file="$profiles_dir/$selection.txt"

  names=()
  if [ "$selection" = "all" ]; then
    for skill in "$skills_dir"/*/; do
      [ -d "$skill" ] || continue
      names+=("$(basename "$skill")")
    done
  elif [ -f "$profile_file" ]; then
    while IFS= read -r name || [ -n "$name" ]; do
      name="${name%%#*}"
      name="${name//[[:space:]]/}"
      [ -n "$name" ] || continue
      names+=("$name")
    done < "$profile_file"
  else
    names=("$selection")
  fi

  [ "${#names[@]}" -gt 0 ] || fail "Selection resolved to zero skills: $selection"

  local name
  for name in "${names[@]}"; do
    [ -f "$skills_dir/$name/SKILL.md" ] || fail "Skill not found: $name"
  done
}

install_one() {
  local name="$1"
  local target_root="$2"
  local source_dir="$skills_dir/$name"
  local target_dir="$target_root/$name"
  local backup_dir=""

  require_safe_target "$target_root" "$target_dir"

  if same_tree "$source_dir" "$target_dir"; then
    log "Unchanged: $name -> $target_dir"
    return 0
  fi

  run mkdir -p "$target_root"

  if [ -e "$target_dir" ]; then
    backup_dir="${target_dir}.backup-$(date +%Y%m%d-%H%M%S)"
    run mv "$target_dir" "$backup_dir"
    log "Backed up: $target_dir -> $backup_dir"
  fi

  run mkdir -p "$target_dir"
  run cp -a "$source_dir/." "$target_dir/"

  # Local secrets survive syncs but are never copied from the repository source.
  if [ -n "$backup_dir" ] && [ -f "$backup_dir/.env" ]; then
    run cp -p "$backup_dir/.env" "$target_dir/.env"
  elif [ -f "$target_dir/.env" ]; then
    run rm -f "$target_dir/.env"
  fi

  if [ -d "$target_dir/scripts" ]; then
    if [ "$dry_run" -eq 1 ]; then
      log "[dry-run] chmod +x scripts under $target_dir"
    else
      find "$target_dir/scripts" -type f \
        \( -name '*.sh' -o -name '*.py' -o -name '*.js' \) -exec chmod +x {} +
    fi
  fi

  log "${action^}: $name -> $target_dir"
}

doctor_one() {
  local name="$1"
  local target_root="$2"
  local source_dir="$skills_dir/$name"
  local target_dir="$target_root/$name"
  local failed=0

  if [ ! -f "$source_dir/SKILL.md" ]; then
    log "FAIL source missing: $source_dir/SKILL.md"
    return 1
  fi
  if [ ! -f "$target_dir/SKILL.md" ]; then
    log "FAIL not installed: $target_dir/SKILL.md"
    return 1
  fi
  if ! same_tree "$source_dir" "$target_dir"; then
    log "FAIL drift detected: $target_dir"
    failed=1
  fi
  if [[ "$target_root" == *".agents/skills"* ]] && [ ! -f "$target_dir/agents/openai.yaml" ]; then
    log "FAIL Codex metadata missing: $target_dir/agents/openai.yaml"
    failed=1
  fi
  if [ "$failed" -eq 0 ]; then
    log "OK: $name -> $target_dir"
  fi
  return "$failed"
}

[ "$#" -ge 1 ] || { usage; exit 2; }

case "$1" in
  install|sync|doctor)
    action="$1"
    shift
    [ "$#" -ge 1 ] || { usage; exit 2; }
    selection="$1"
    shift
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    action="install"
    selection="$1"
    shift
    ;;
esac

want_claude=0
want_codex=0
want_hermes=0
dry_run=0

for arg in "$@"; do
  case "$arg" in
    --claude) want_claude=1 ;;
    --codex) want_codex=1 ;;
    --hermes) want_hermes=1 ;;
    --dry-run) dry_run=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

if [ "$want_claude" -eq 0 ] && [ "$want_codex" -eq 0 ] && [ "$want_hermes" -eq 0 ]; then
  want_claude=1
  want_codex=1
fi

targets=()
[ "$want_claude" -eq 1 ] && targets+=("${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}")
[ "$want_codex" -eq 1 ] && targets+=("${CODEX_SKILLS_DIR:-$HOME/.agents/skills}")
[ "$want_hermes" -eq 1 ] && targets+=("${HERMES_HOME:-$HOME/.hermes}/skills")

resolve_selection "$selection"

maintain_kate_codex_wrapper

status=0
for target_root in "${targets[@]}"; do
  target_root="${target_root%/}"
  for name in "${names[@]}"; do
    if [ "$action" = "doctor" ]; then
      doctor_one "$name" "$target_root" || status=1
    else
      install_one "$name" "$target_root"
    fi
  done
done

if [ "$action" = "doctor" ]; then
  [ "$status" -eq 0 ] || fail "Doctor found installation drift"
  log "Doctor completed successfully."
else
  log "Done. Restart the selected runtimes so they reload the skill index."
fi
