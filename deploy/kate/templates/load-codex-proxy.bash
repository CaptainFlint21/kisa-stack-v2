# Kate Codex user proxy loader.
# Source this file from shell startup files; it exports only proxy variables.

_kate_proxy_env="${CODEX_PROXY_ENV:-$HOME/.hermes/codex-proxy.env}"

_kate_trim_ws() {
  local value="$1"
  value="${value#"${value%%[!$' \t']*}"}"
  value="${value%"${value##*[!$' \t']}"}"
  printf '%s' "$value"
}

_kate_ltrim_ws() {
  local value="$1"
  value="${value#"${value%%[!$' \t']*}"}"
  printf '%s' "$value"
}

_kate_parse_env_value() {
  local raw="$1"
  local quote=""
  local index=0
  local char=""
  local next=""
  KATE_PARSED_VALUE=""

  raw="$(_kate_ltrim_ws "$raw")"
  quote="${raw:0:1}"

  if [ "$quote" = "'" ]; then
    index=1
    while [ "$index" -lt "${#raw}" ]; do
      char="${raw:index:1}"
      [ "$char" != "'" ] || return 0
      KATE_PARSED_VALUE+="$char"
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
      if [ "$char" = '\' ] && [ $((index + 1)) -lt "${#raw}" ]; then
        next="${raw:index+1:1}"
        case "$next" in
          '$'|'`'|'"'|'\'|$'\n')
            KATE_PARSED_VALUE+="$next"
            index=$((index + 2))
            continue
            ;;
        esac
      fi
      KATE_PARSED_VALUE+="$char"
      index=$((index + 1))
    done
    return 1
  fi

  KATE_PARSED_VALUE="$(_kate_trim_ws "$raw")"
  return 0
}

_kate_proxy_export_line() {
  local line="$1"
  local name=""
  local raw=""

  line="${line%$'\r'}"
  line="$(_kate_ltrim_ws "$line")"
  [ -n "$line" ] || return 0
  [ "${line:0:1}" != "#" ] || return 0

  if [[ "$line" =~ ^export[[:space:]]+(.+) ]]; then
    line="${BASH_REMATCH[1]}"
  fi

  [ "$line" != "${line#*=}" ] || return 0
  name="$(_kate_trim_ws "${line%%=*}")"
  raw="${line#*=}"

  [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 0
  case "$name" in
    HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY|http_proxy|https_proxy|all_proxy|no_proxy) ;;
    *) return 0 ;;
  esac

  _kate_parse_env_value "$raw" || return 0
  export "$name=$KATE_PARSED_VALUE"
}

if [ -f "$_kate_proxy_env" ] && [ ! -L "$_kate_proxy_env" ]; then
  while IFS= read -r _kate_line || [ -n "$_kate_line" ]; do
    _kate_proxy_export_line "$_kate_line"
  done < "$_kate_proxy_env"
fi

unset _kate_proxy_env _kate_line
unset -f _kate_trim_ws _kate_ltrim_ws _kate_parse_env_value _kate_proxy_export_line
unset KATE_PARSED_VALUE
