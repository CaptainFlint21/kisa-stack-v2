#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
kate_dir="$repo_dir/deploy/kate"

source_env="${CODEX_PROXY_ENV:-$HOME/.hermes/codex-proxy.env}"
proxy_dir="$HOME/.config/kate-proxy"
loader_path="$proxy_dir/load-codex-proxy.bash"
sync_path="$proxy_dir/sync-codex-proxy-env.bash"
cache_path="$HOME/.config/environment.d/90-codex-proxy.conf"
loader_template="$kate_dir/templates/load-codex-proxy.bash"
startup_files=("$HOME/.profile" "$HOME/.bashrc")

start_marker="# >>> Kate Codex proxy startup >>>"
end_marker="# <<< Kate Codex proxy startup <<<"
legacy_marker="# Kate Codex proxy environment"

dry_run=0
declare -A PARSED_ENV=()
declare -A CACHE_ENV=()
declare -A HERMES_ENV=()

usage() {
  cat >&2 <<'EOF'
Usage:
  bash deploy/kate/user-proxy.sh install [--dry-run]
  bash deploy/kate/user-proxy.sh sync [--dry-run]
  bash deploy/kate/user-proxy.sh doctor

Installs and validates Kate's user proxy environment flow:
  ~/.hermes/codex-proxy.env -> ~/.config/environment.d/90-codex-proxy.conf

Proxy values are never printed.
EOF
}

log() {
  printf '%s\n' "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

action="${1:-}"
[ -n "$action" ] || { usage; exit 2; }
shift || true

for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

case "$action" in
  install|sync|doctor) ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac

trim_ws() {
  local value="$1"
  value="${value#"${value%%[!$' \t']*}"}"
  value="${value%"${value##*[!$' \t']}"}"
  printf '%s' "$value"
}

ltrim_ws() {
  local value="$1"
  value="${value#"${value%%[!$' \t']*}"}"
  printf '%s' "$value"
}

lower_key() {
  local key="$1"
  printf '%s' "$key" | tr '[:upper:]' '[:lower:]'
}

parse_env_value() {
  local raw="$1"
  local quote=""
  local index=0
  local char=""
  local next=""
  PARSED_VALUE=""

  raw="$(ltrim_ws "$raw")"
  quote="${raw:0:1}"

  if [ "$quote" = "'" ]; then
    index=1
    while [ "$index" -lt "${#raw}" ]; do
      char="${raw:index:1}"
      [ "$char" != "'" ] || return 0
      PARSED_VALUE+="$char"
      index=$((index + 1))
    done
    return 1
  fi

  if [ "$quote" = '"' ]; then
    index=1
    while [ "$index" -lt "${#raw}" ]; do
      char="${raw:index:1}"
      if [ "$char" = '"' ]; then
        return 0
      fi
      if [ "$char" = "\\" ] && [ $((index + 1)) -lt "${#raw}" ]; then
        next="${raw:index+1:1}"
        case "$next" in
          '$'|'`'|'"'|\\|$'\n')
            PARSED_VALUE+="$next"
            index=$((index + 2))
            continue
            ;;
        esac
      fi
      PARSED_VALUE+="$char"
      index=$((index + 1))
    done
    return 1
  fi

  PARSED_VALUE="$(trim_ws "$raw")"
  return 0
}

parse_env_file() {
  local file="$1"
  local array_name="$2"
  local line=""
  local name=""
  local raw=""
  # shellcheck disable=SC2178 # out is a nameref to the caller's associative array.
  local -n out="$array_name"

  # shellcheck disable=SC2034 # out is a nameref to the caller's associative array.
  out=()
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="$(ltrim_ws "$line")"
    [ -n "$line" ] || continue
    [ "${line:0:1}" != "#" ] || continue

    if [[ "$line" =~ ^export[[:space:]]+(.+) ]]; then
      line="${BASH_REMATCH[1]}"
    fi

    [ "$line" != "${line#*=}" ] || continue
    name="$(trim_ws "${line%%=*}")"
    raw="${line#*=}"

    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    case "$name" in
      HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY|http_proxy|https_proxy|all_proxy|no_proxy) ;;
      *) continue ;;
    esac

    parse_env_value "$raw" || continue
    # shellcheck disable=SC2034 # out is a nameref to the caller's associative array.
    out["$name"]="$PARSED_VALUE"
  done < "$file"
}

required_source_ready() {
  local failed=0
  local mode=""
  local key=""

  if [ ! -e "$source_env" ]; then
    log "FAIL Codex proxy source missing: $source_env"
    return 1
  fi
  if [ -L "$source_env" ]; then
    log "FAIL Codex proxy source is a symlink: $source_env"
    return 1
  fi
  if [ ! -f "$source_env" ]; then
    log "FAIL Codex proxy source is not a regular file: $source_env"
    return 1
  fi

  mode="$(stat -c '%a' "$source_env")"
  if [ "$mode" != "600" ]; then
    log "FAIL Codex proxy source mode is $mode, expected 600"
    failed=1
  fi

  parse_env_file "$source_env" PARSED_ENV
  for key in HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY; do
    if [ -z "${PARSED_ENV[$key]+set}" ] || [ -z "${PARSED_ENV[$key]}" ]; then
      log "FAIL Codex proxy source missing required key: $key"
      failed=1
    fi
  done

  return "$failed"
}

systemd_env_value() {
  local value="$1"
  printf '%s' "${value//\$/\$\$}"
}

desired_cache_content() {
  local key=""
  local lower=""
  for key in HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY; do
    printf '%s=' "$key"
    systemd_env_value "${PARSED_ENV[$key]}"
    printf '\n'
  done
  for key in HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY; do
    lower="$(lower_key "$key")"
    printf '%s=' "$lower"
    systemd_env_value "${PARSED_ENV[$key]}"
    printf '\n'
  done
}

systemd_lookup_env_value() {
  local name="$1"
  local array_name="$2"
  local -n values="$array_name"

  if [ "${values[$name]+set}" = "set" ]; then
    SYSTEMD_LOOKUP_VALUE="${values[$name]}"
  elif [ "${!name+x}" ]; then
    SYSTEMD_LOOKUP_VALUE="${!name}"
  else
    SYSTEMD_LOOKUP_VALUE=""
  fi
}

systemd_parse_env_value() {
  local raw="$1"
  local array_name="$2"
  local index=0
  local char=""
  local next=""
  local rest=""
  local expr=""
  local name=""
  local operator=""
  local word=""
  local expanded=""
  local prefix=""
  SYSTEMD_PARSED_VALUE=""

  while [ "$index" -lt "${#raw}" ]; do
    char="${raw:index:1}"
    if [ "$char" = "$" ] && [ $((index + 1)) -lt "${#raw}" ]; then
      next="${raw:index+1:1}"
      if [ "$next" = "$" ]; then
        SYSTEMD_PARSED_VALUE+="$"
        index=$((index + 2))
        continue
      fi
      if [ "$next" = "{" ]; then
        rest="${raw:index+2}"
        if [ "$rest" != "${rest#*\}}" ]; then
          expr="${rest%%\}*}"
          if [[ "$expr" =~ ^([A-Za-z_][A-Za-z0-9_]*)(:([-+])(.*))?$ ]]; then
            name="${BASH_REMATCH[1]}"
            operator="${BASH_REMATCH[3]}"
            word="${BASH_REMATCH[4]}"
            systemd_lookup_env_value "$name" "$array_name"
            case "$operator" in
              "")
                SYSTEMD_PARSED_VALUE+="$SYSTEMD_LOOKUP_VALUE"
                ;;
              "-")
                if [ -n "$SYSTEMD_LOOKUP_VALUE" ]; then
                  SYSTEMD_PARSED_VALUE+="$SYSTEMD_LOOKUP_VALUE"
                else
                  prefix="$SYSTEMD_PARSED_VALUE"
                  systemd_parse_env_value "$word" "$array_name"
                  expanded="$SYSTEMD_PARSED_VALUE"
                  SYSTEMD_PARSED_VALUE="$prefix$expanded"
                fi
                ;;
              "+")
                if [ -n "$SYSTEMD_LOOKUP_VALUE" ]; then
                  prefix="$SYSTEMD_PARSED_VALUE"
                  systemd_parse_env_value "$word" "$array_name"
                  expanded="$SYSTEMD_PARSED_VALUE"
                  SYSTEMD_PARSED_VALUE="$prefix$expanded"
                fi
                ;;
            esac
            index=$((index + ${#expr} + 3))
            continue
          fi
        fi
      fi
      rest="${raw:index+1}"
      if [[ "$rest" =~ ^([A-Za-z_][A-Za-z0-9_]*) ]]; then
        name="${BASH_REMATCH[1]}"
        systemd_lookup_env_value "$name" "$array_name"
        SYSTEMD_PARSED_VALUE+="$SYSTEMD_LOOKUP_VALUE"
        index=$((index + ${#name} + 1))
        continue
      fi
    fi
    SYSTEMD_PARSED_VALUE+="$char"
    index=$((index + 1))
  done
}

parse_systemd_env_file() {
  local file="$1"
  local array_name="$2"
  local line=""
  local name=""
  local raw=""
  local -n out="$array_name"

  # shellcheck disable=SC2034 # out is a nameref to the caller's associative array.
  out=()
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="$(ltrim_ws "$line")"
    [ -n "$line" ] || continue
    [ "${line:0:1}" != "#" ] || continue
    [ "$line" != "${line#*=}" ] || continue

    name="$(trim_ws "${line%%=*}")"
    raw="${line#*=}"

    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    case "$name" in
      HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY|http_proxy|https_proxy|all_proxy|no_proxy) ;;
      *) continue ;;
    esac

    systemd_parse_env_value "$raw" "$array_name"
    # shellcheck disable=SC2034 # out is a nameref to the caller's associative array.
    out["$name"]="$SYSTEMD_PARSED_VALUE"
  done < "$file"
}

reject_symlinked_dir_chain() {
  local label="$1"
  local dir="$2"
  local current="/"
  local part=""
  local rest=""
  local -a parts=()

  [[ "$dir" = /* ]] || fail "Internal error: non-absolute directory path for $label: $dir"
  rest="${dir#/}"
  IFS='/' read -r -a parts <<< "$rest"
  for part in "${parts[@]}"; do
    [ -n "$part" ] || continue
    current="${current%/}/$part"
    if [ -L "$current" ]; then
      log "FAIL $label directory path has symlink component: $current"
      return 1
    fi
  done
  return 0
}

ensure_safe_directory() {
  local label="$1"
  local dir="$2"
  local mode="$3"

  reject_symlinked_dir_chain "$label" "$dir" || return 1
  if [ -e "$dir" ] && [ ! -d "$dir" ]; then
    log "FAIL $label path is not a directory: $dir"
    return 1
  fi
  mkdir -p "$dir"
  chmod "$mode" "$dir"
}

atomic_write_cache() {
  local cache_dir=""
  local tmp=""

  cache_dir="$(dirname -- "$cache_path")"

  if [ "$dry_run" -eq 1 ]; then
    log "[dry-run] sync Codex proxy cache: $cache_path"
    log "[dry-run] source validation skipped; install/sync would require: $source_env"
    return 0
  fi

  required_source_ready || return 1
  ensure_safe_directory "systemd environment.d directory" "$cache_dir" 700 || return 1

  tmp="$(mktemp "$cache_dir/.90-codex-proxy.conf.XXXXXX")"
  desired_cache_content > "$tmp"
  chmod 600 "$tmp"

  if [ -f "$cache_path" ] && [ ! -L "$cache_path" ] && cmp -s "$tmp" "$cache_path"; then
    chmod 600 "$cache_path"
    rm -f -- "$tmp"
    log "Codex proxy cache unchanged: $cache_path"
    return 0
  fi

  mv -fT -- "$tmp" "$cache_path"
  chmod 600 "$cache_path"
  log "Synced Codex proxy cache: $cache_path"
}

export_proxy_environment() {
  local key=""
  local lower=""
  for key in HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY; do
    export "$key=${PARSED_ENV[$key]}"
  done
  for key in HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY; do
    lower="$(lower_key "$key")"
    export "$lower=${PARSED_ENV[$key]}"
  done
}

update_user_environments() {
  local keys=(HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy)

  [ "$dry_run" -eq 0 ] || {
    log "[dry-run] update systemd user and DBus activation proxy environment"
    return 0
  }

  export_proxy_environment

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl --user import-environment "${keys[@]}" >/dev/null 2>&1; then
      log "Updated systemd user proxy environment."
    else
      log "WARN systemd user environment update skipped."
    fi
  else
    log "WARN systemctl not found; systemd user environment update skipped."
  fi

  if command -v dbus-update-activation-environment >/dev/null 2>&1; then
    if dbus-update-activation-environment --systemd "${keys[@]}" >/dev/null 2>&1; then
      log "Updated DBus activation proxy environment."
    else
      log "WARN DBus activation environment update skipped."
    fi
  else
    log "WARN dbus-update-activation-environment not found; DBus update skipped."
  fi
}

install_file_atomically() {
  local source="$1"
  local target="$2"
  local mode="$3"
  local dir=""
  local tmp=""

  if [ "$dry_run" -eq 1 ]; then
    log "[dry-run] install $target"
    return 0
  fi

  dir="$(dirname -- "$target")"
  reject_symlinked_dir_chain "target directory" "$dir" || return 1
  mkdir -p "$dir"
  tmp="$(mktemp "$dir/.$(basename -- "$target").XXXXXX")"
  cp "$source" "$tmp"
  chmod "$mode" "$tmp"

  if [ -f "$target" ] && [ ! -L "$target" ] && cmp -s "$tmp" "$target"; then
    chmod "$mode" "$target"
    rm -f -- "$tmp"
    log "Unchanged: $target"
    return 0
  fi

  mv -fT -- "$tmp" "$target"
  chmod "$mode" "$target"
  log "Installed: $target"
}

next_backup_path() {
  local target="$1"
  local base=""
  base="$target.kate-proxy-backup-$(date +%Y%m%d-%H%M%S)"
  local candidate="$base"
  local index=1

  while [ -e "$candidate" ] || [ -L "$candidate" ]; do
    candidate="$base-$index"
    index=$((index + 1))
  done
  printf '%s\n' "$candidate"
}

startup_block() {
  cat <<'EOF'
# >>> Kate Codex proxy startup >>>
if [ -n "${BASH_VERSION:-}" ] && [ -r "$HOME/.config/kate-proxy/load-codex-proxy.bash" ]; then
  # shellcheck disable=SC1091
  . "$HOME/.config/kate-proxy/load-codex-proxy.bash"
fi
# <<< Kate Codex proxy startup <<<
EOF
}

write_startup_without_blocks() {
  local source="$1"
  if [ -f "$source" ]; then
    awk -v start="$start_marker" -v finish="$end_marker" -v legacy="$legacy_marker" '
      function reset_legacy() {
        legacy_block = ""
        legacy_has_loader = 0
      }
      function flush_legacy() {
        if (legacy_block != "" && legacy_has_loader != 1) {
          printf "%s", legacy_block
        }
        reset_legacy()
      }
      $0 == start { skip = 1; next }
      $0 == finish { skip = 0; next }
      skip == 1 { next }
      $0 == legacy {
        flush_legacy()
        legacy_block = $0 ORS
        legacy_has_loader = 0
        next
      }
      legacy_block != "" {
        legacy_block = legacy_block $0 ORS
        if (index($0, ".config/kate-proxy/load-codex-proxy.bash") > 0) {
          legacy_has_loader = 1
        }
        if ($0 ~ /^[[:space:]]*fi[[:space:]]*$/) {
          flush_legacy()
        }
        next
      }
      /^[[:space:]]*$/ { blanks = blanks $0 ORS; next }
      {
        printf "%s", blanks
        blanks = ""
        print
      }
      END {
        flush_legacy()
      }
    ' "$source"
  fi
}

install_startup_block() {
  local target="$1"
  local dir=""
  local tmp=""
  local backup=""

  if [ "$dry_run" -eq 1 ]; then
    log "[dry-run] install shell startup block in $target"
    return 0
  fi

  dir="$(dirname -- "$target")"
  reject_symlinked_dir_chain "shell startup directory" "$dir" || return 1
  mkdir -p "$dir"
  tmp="$(mktemp "$dir/.$(basename -- "$target").kate-proxy.XXXXXX")"
  write_startup_without_blocks "$target" > "$tmp"
  if [ -s "$tmp" ]; then
    printf '\n' >> "$tmp"
  fi
  startup_block >> "$tmp"
  chmod 600 "$tmp"

  if [ -f "$target" ] && [ ! -L "$target" ] && cmp -s "$tmp" "$target"; then
    chmod 600 "$target"
    rm -f -- "$tmp"
    log "Shell startup block unchanged: $target"
    return 0
  fi

  if [ -e "$target" ] || [ -L "$target" ]; then
    backup="$(next_backup_path "$target")"
    mv -T -- "$target" "$backup"
    log "Backed up shell startup file: $backup"
  fi

  mv -fT -- "$tmp" "$target"
  chmod 600 "$target"
  log "Installed shell startup block: $target"
}

install_user_proxy() {
  if [ "$dry_run" -eq 1 ]; then
    log "[dry-run] install Kate Codex user proxy architecture"
  fi

  if [ "$dry_run" -eq 0 ]; then
    ensure_safe_directory "Kate proxy config directory" "$proxy_dir" 700 || return 1
  fi

  install_file_atomically "$loader_template" "$loader_path" 600
  install_file_atomically "$kate_dir/user-proxy.sh" "$sync_path" 700

  local startup=""
  for startup in "${startup_files[@]}"; do
    install_startup_block "$startup"
  done

  sync_user_proxy
}

sync_user_proxy() {
  atomic_write_cache
  update_user_environments
}

hash_value() {
  local value="$1"
  printf '%s' "$value" | sha256sum | awk '{print substr($1, 1, 12)}'
}

mode_is_world_writable() {
  local mode="$1"
  [ $((8#$mode & 0002)) -ne 0 ]
}

doctor_path_regular_mode() {
  local label="$1"
  local path="$2"
  local expected_mode="$3"
  local failed=0
  local mode=""

  reject_symlinked_dir_chain "$label parent directory" "$(dirname -- "$path")" || return 1
  if [ ! -e "$path" ]; then
    log "FAIL $label missing: $path"
    return 1
  fi
  if [ -L "$path" ]; then
    log "FAIL $label is a symlink: $path"
    return 1
  fi
  if [ ! -f "$path" ]; then
    log "FAIL $label is not a regular file: $path"
    return 1
  fi

  mode="$(stat -c '%a' "$path")"
  if [ "$mode" != "$expected_mode" ]; then
    log "FAIL $label mode is $mode, expected $expected_mode"
    failed=1
  fi
  if mode_is_world_writable "$mode"; then
    log "FAIL $label is world-writable: $path"
    failed=1
  fi

  return "$failed"
}

doctor_directory_mode() {
  local label="$1"
  local path="$2"
  local expected_mode="$3"
  local mode=""

  reject_symlinked_dir_chain "$label directory" "$path" || return 1
  if [ ! -d "$path" ] || [ -L "$path" ]; then
    log "FAIL $label missing or unsafe: $path"
    return 1
  fi
  mode="$(stat -c '%a' "$path")"
  if [ "$mode" != "$expected_mode" ]; then
    log "FAIL $label mode is $mode, expected $expected_mode"
    return 1
  fi
  if mode_is_world_writable "$mode"; then
    log "FAIL $label is world-writable: $path"
    return 1
  fi
  return 0
}

doctor_cache_matches_source() {
  local key=""
  local lower=""
  local failed=0
  local hash=""

  doctor_path_regular_mode "Codex proxy cache" "$cache_path" 600 || return 1
  parse_systemd_env_file "$cache_path" CACHE_ENV

  for key in HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY; do
    lower="$(lower_key "$key")"
    if [ "${CACHE_ENV[$key]+set}" != "set" ] || [ "${CACHE_ENV[$key]}" != "${PARSED_ENV[$key]}" ]; then
      log "FAIL Codex proxy cache does not match source for $key"
      failed=1
    fi
    if [ "${CACHE_ENV[$lower]+set}" != "set" ] || [ "${CACHE_ENV[$lower]}" != "${PARSED_ENV[$key]}" ]; then
      log "FAIL Codex proxy cache does not match source for $lower"
      failed=1
    fi
  done

  if [ "$failed" -eq 0 ]; then
    hash="$(hash_value "${PARSED_ENV[HTTP_PROXY]}")"
    log "OK Codex proxy cache matches source (HTTP_PROXY sha256:$hash)"
  fi
  return "$failed"
}

count_marker() {
  local file="$1"
  local marker="$2"
  grep -Fxc -- "$marker" "$file" 2>/dev/null || true
}

startup_counts() {
  local file="$1"
  awk -v start="$start_marker" -v finish="$end_marker" -v legacy="$legacy_marker" '
    function reset_legacy() {
      legacy_block = 0
      legacy_has_loader = 0
    }
    function finish_legacy() {
      if (legacy_block == 1 && legacy_has_loader == 1) {
        legacy_count++
      }
      reset_legacy()
    }
    $0 == start { managed_starts++; next }
    $0 == finish { managed_ends++; next }
    $0 == legacy {
      finish_legacy()
      legacy_block = 1
      legacy_has_loader = 0
      next
    }
    legacy_block == 1 {
      if (index($0, ".config/kate-proxy/load-codex-proxy.bash") > 0) {
        legacy_has_loader = 1
      }
      if ($0 ~ /^[[:space:]]*fi[[:space:]]*$/) {
        finish_legacy()
      }
      next
    }
    END {
      finish_legacy()
      printf "%d %d %d\n", managed_starts, managed_ends, legacy_count
    }
  ' "$file"
}

managed_startup_block_is_safe() {
  local file="$1"
  awk -v start="$start_marker" -v finish="$end_marker" '
    $0 == start { in_block = 1; next }
    $0 == finish { in_block = 0; done = 1; next }
    in_block == 1 {
      if (index($0, "BASH_VERSION") > 0) {
        has_bash_guard = 1
      }
      if (index($0, "-r \"$HOME/.config/kate-proxy/load-codex-proxy.bash\"") > 0) {
        has_readable_loader_guard = 1
      }
      if (index($0, ". \"$HOME/.config/kate-proxy/load-codex-proxy.bash\"") > 0) {
        sources_loader = 1
      }
    }
    END {
      exit !(done == 1 && has_bash_guard == 1 && has_readable_loader_guard == 1 && sources_loader == 1)
    }
  ' "$file"
}

doctor_startup_blocks() {
  local file=""
  local starts=0
  local ends=0
  local legacy=0
  local total=0
  local failed=0

  for file in "${startup_files[@]}"; do
    if ! reject_symlinked_dir_chain "shell startup directory" "$(dirname -- "$file")"; then
      failed=1
      continue
    fi
    if [ ! -f "$file" ] || [ -L "$file" ]; then
      log "FAIL shell startup file missing or unsafe: $file"
      failed=1
      continue
    fi
    read -r starts ends legacy < <(startup_counts "$file")
    if [ "$starts" -ne "$ends" ]; then
      log "FAIL shell startup managed marker mismatch for $file: start=$starts end=$ends"
      failed=1
      continue
    fi
    total=$((starts + legacy))
    if [ "$total" -ne 1 ]; then
      log "FAIL shell startup loader block count for $file is managed=$starts legacy=$legacy, expected exactly 1"
      failed=1
    elif [ "$starts" -eq 1 ] && ! grep -Fq '.config/kate-proxy/load-codex-proxy.bash' "$file"; then
      log "FAIL shell startup block does not source Kate proxy loader: $file"
      failed=1
    elif [ "$starts" -eq 1 ] && ! managed_startup_block_is_safe "$file"; then
      log "FAIL shell startup block lacks Bash/readable-loader guard: $file"
      failed=1
    fi
  done

  [ "$failed" -ne 0 ] || log "OK shell startup loader blocks installed once"
  return "$failed"
}

doctor_user_manager_environment() {
  local tmp=""
  local key=""
  local line=""
  local name=""
  local value=""
  local failed=0
  declare -A manager_env=()

  if ! command -v systemctl >/dev/null 2>&1; then
    log "SKIP systemctl not found; user manager environment not checked"
    return 0
  fi

  tmp="$(mktemp)"
  if ! systemctl --user show-environment > "$tmp" 2>/dev/null; then
    rm -f -- "$tmp"
    log "SKIP systemd user manager environment unavailable"
    return 0
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    [ "$line" != "${line#*=}" ] || continue
    name="${line%%=*}"
    value="${line#*=}"
    manager_env["$name"]="$value"
  done < "$tmp"
  rm -f -- "$tmp"

  for key in HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY; do
    if [ "${manager_env[$key]+set}" != "set" ] || [ "${manager_env[$key]}" != "${PARSED_ENV[$key]}" ]; then
      log "FAIL systemd user manager environment does not match source for $key"
      failed=1
    fi
  done

  [ "$failed" -ne 0 ] || log "OK systemd user manager environment matches source"
  return "$failed"
}

doctor_hermes_isolation() {
  local candidate=""
  local dropin=""
  local dropin_references_hermes=0
  local hermes_env="$HOME/.hermes/hermes-proxy.env"
  local key=""
  local failed=0
  local codex_hash=""
  local hermes_hash=""
  local -a candidates=(
    "$HOME/.config/systemd/user/hermes.service.d/proxy.conf"
    "$HOME/.config/systemd/user/hermes-gateway.service.d/proxy.conf"
    "$HOME/.config/systemd/user/hermes-gateway@default.service.d/proxy.conf"
  )
  local -a dropins=()

  if [ -n "${KATE_HERMES_PROXY_DROPIN:-}" ]; then
    candidates+=("$KATE_HERMES_PROXY_DROPIN")
  fi

  for candidate in "${candidates[@]}"; do
    [ -f "$candidate" ] || continue
    for dropin in "${dropins[@]}"; do
      [ "$dropin" = "$candidate" ] && continue 2
    done
    dropins+=("$candidate")
  done

  if [ -L "$hermes_env" ]; then
    log "FAIL Hermes proxy env is a symlink: $hermes_env"
    failed=1
  fi

  if [ "${#dropins[@]}" -eq 0 ]; then
    if [ "$failed" -ne 0 ]; then
      return 1
    fi
    log "SKIP Hermes proxy drop-in not found"
    return 0
  fi

  for dropin in "${dropins[@]}"; do
    if grep -Fq '.hermes/hermes-proxy.env' "$dropin"; then
      dropin_references_hermes=1
    else
      log "FAIL Hermes proxy drop-in does not reference ~/.hermes/hermes-proxy.env: $dropin"
      failed=1
    fi
    if grep -Fq '.hermes/codex-proxy.env' "$dropin"; then
      log "FAIL Hermes proxy drop-in references Codex proxy source: $dropin"
      failed=1
    fi
  done

  if [ "$dropin_references_hermes" -eq 1 ]; then
    if doctor_path_regular_mode "Hermes proxy env" "$hermes_env" 600; then
      parse_env_file "$hermes_env" HERMES_ENV
      for key in HTTP_PROXY HTTPS_PROXY ALL_PROXY; do
        if [ "${HERMES_ENV[$key]+set}" != "set" ] || [ -z "${HERMES_ENV[$key]}" ]; then
          log "FAIL Hermes proxy env missing required key: $key"
          failed=1
          continue
        fi
        codex_hash="$(hash_value "${PARSED_ENV[$key]}")"
        hermes_hash="$(hash_value "${HERMES_ENV[$key]}")"
        if [ "$codex_hash" = "$hermes_hash" ]; then
          log "FAIL Hermes and Codex $key hashes match: sha256:$codex_hash"
          failed=1
        else
          log "OK Hermes and Codex $key hashes differ: codex=sha256:$codex_hash hermes=sha256:$hermes_hash"
        fi
      done
    else
      failed=1
    fi
  else
    log "FAIL Hermes proxy env hash separation cannot be checked without hermes-proxy.env drop-in reference"
    failed=1
  fi

  [ "$failed" -ne 0 ] || log "OK Hermes proxy drop-in keeps separate source"
  return "$failed"
}

doctor_user_proxy() {
  local failed=0

  required_source_ready || failed=1
  if [ "$failed" -eq 0 ]; then
    doctor_cache_matches_source || failed=1
  fi
  doctor_directory_mode "Kate proxy config directory" "$proxy_dir" 700 || failed=1
  doctor_path_regular_mode "Kate proxy loader" "$loader_path" 600 || failed=1
  doctor_path_regular_mode "Kate proxy sync script" "$sync_path" 700 || failed=1
  doctor_startup_blocks || failed=1
  if [ "$failed" -eq 0 ]; then
    doctor_user_manager_environment || failed=1
    doctor_hermes_isolation || failed=1
  fi

  if [ "$failed" -eq 0 ]; then
    log "OK Kate Codex user proxy"
  fi
  return "$failed"
}

case "$action" in
  install) install_user_proxy ;;
  sync) sync_user_proxy ;;
  doctor) doctor_user_proxy ;;
esac
