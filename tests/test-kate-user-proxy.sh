#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_dir/deploy/kate/user-proxy.sh"
rollback="$repo_dir/deploy/kate/rollback.sh"
tmp_home="$(mktemp -d)"
stub_bin="$(mktemp -d)"
trap 'rm -rf -- "$tmp_home" "$stub_bin"' EXIT

export HOME="$tmp_home"
export PATH="$stub_bin:$PATH"
export KATE_TEST_SYSTEMD_ENV="$tmp_home/systemd-user-env"
export KATE_TEST_DBUS_ENV="$tmp_home/dbus-env"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

expect_fail() {
  local output="$tmp_home/expected-failure.out"
  if "$@" > "$output" 2>&1; then
    cat "$output" >&2
    fail "command unexpectedly succeeded: $*"
  fi
}

marker_count() {
  local file="$1"
  grep -Fxc -- '# >>> Kate Codex proxy startup >>>' "$file"
}

legacy_count() {
  local file="$1"
  grep -Fxc -- '# Kate Codex proxy environment' "$file"
}

legacy_startup_block() {
  cat <<'EOF'
# Kate Codex proxy environment
if [ -n "${BASH_VERSION:-}" ] && [ -r "$HOME/.config/kate-proxy/load-codex-proxy.bash" ]; then
  . "$HOME/.config/kate-proxy/load-codex-proxy.bash"
fi
EOF
}

backup_count() {
  local file="$1"
  find "$HOME" -maxdepth 1 -name "$(basename "$file").kate-proxy-backup-*" | wc -l
}

write_systemd_stubs() {
  cat > "$stub_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "--user" ] && [ "${2:-}" = "import-environment" ]; then
  shift 2
  : > "$KATE_TEST_SYSTEMD_ENV"
  for key in "$@"; do
    printf '%s=%s\n' "$key" "${!key-}" >> "$KATE_TEST_SYSTEMD_ENV"
  done
  exit 0
fi

if [ "${1:-}" = "--user" ] && [ "${2:-}" = "show-environment" ]; then
  cat "$KATE_TEST_SYSTEMD_ENV"
  exit 0
fi

exit 1
EOF
  chmod +x "$stub_bin/systemctl"

  cat > "$stub_bin/dbus-update-activation-environment" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$KATE_TEST_DBUS_ENV"
EOF
  chmod +x "$stub_bin/dbus-update-activation-environment"
}

write_codex_source() {
  mkdir -p "$HOME/.hermes"
  {
    printf '%s\r\n' 'export HTTP_PROXY="http://user:codex-secret@example.test:8080/path with space?token=\$dollar\\slash\"quote'\''single"'
    printf "HTTPS_PROXY='https://user:codex-secret@example.test:8443/single quoted'\r\n"
    printf 'ALL_PROXY="socks5://user:codex-secret@example.test:1080"\r\n'
    printf 'NO_PROXY="localhost,127.0.0.1,.example.test"\r\n'
    printf 'IGNORED_SECRET="codex-secret-ignored"\r\n'
  } > "$HOME/.hermes/codex-proxy.env"
  chmod 600 "$HOME/.hermes/codex-proxy.env"
}

write_hermes_isolation() {
  mkdir -p "$HOME/.config/systemd/user/hermes.service.d" "$HOME/.hermes"
  {
    printf '[Service]\n'
    printf 'EnvironmentFile=%s/.hermes/hermes-proxy.env\n' "$HOME"
    printf 'EnvironmentFile=%s/.hermes/gateway-policy.env\n' "$HOME"
  } > "$HOME/.config/systemd/user/hermes.service.d/proxy.conf"
  {
    printf 'HTTP_PROXY="http://hermes.example.test:8080"\n'
    printf 'HTTPS_PROXY="https://hermes.example.test:8443"\n'
    printf 'ALL_PROXY="socks5://hermes.example.test:1080"\n'
    printf 'NO_PROXY="localhost,127.0.0.1"\n'
  } > "$HOME/.hermes/hermes-proxy.env"
  chmod 600 "$HOME/.hermes/hermes-proxy.env"
}

write_existing_startup_files() {
  printf 'profile before\n' > "$HOME/.profile"
  printf 'bashrc before\n' > "$HOME/.bashrc"
  chmod 600 "$HOME/.profile" "$HOME/.bashrc"
}

write_legacy_startup_files() {
  {
    printf 'profile before legacy\n\n'
    legacy_startup_block
  } > "$HOME/.profile"
  {
    printf 'bashrc before legacy\n\n'
    legacy_startup_block
  } > "$HOME/.bashrc"
  chmod 600 "$HOME/.profile" "$HOME/.bashrc"
}

assert_installed_shape() {
  [ -d "$HOME/.config/kate-proxy" ] || fail "proxy config directory missing"
  [ "$(stat -c '%a' "$HOME/.config/kate-proxy")" = "700" ] ||
    fail "proxy config directory mode must be 700"
  [ -f "$HOME/.config/kate-proxy/load-codex-proxy.bash" ] ||
    fail "loader missing"
  [ "$(stat -c '%a' "$HOME/.config/kate-proxy/load-codex-proxy.bash")" = "600" ] ||
    fail "loader mode must be 600"
  [ -f "$HOME/.config/kate-proxy/sync-codex-proxy-env.bash" ] ||
    fail "sync script missing"
  [ "$(stat -c '%a' "$HOME/.config/kate-proxy/sync-codex-proxy-env.bash")" = "700" ] ||
    fail "sync script mode must be 700"
  [ -f "$HOME/.config/environment.d/90-codex-proxy.conf" ] ||
    fail "systemd environment cache missing"
  [ ! -L "$HOME/.config/environment.d/90-codex-proxy.conf" ] ||
    fail "systemd environment cache must not be a symlink"
  [ "$(stat -c '%a' "$HOME/.config/environment.d/90-codex-proxy.conf")" = "600" ] ||
    fail "systemd environment cache mode must be 600"
  grep -q '^HTTP_PROXY=' "$HOME/.config/environment.d/90-codex-proxy.conf" ||
    fail "cache must include uppercase proxy variables"
  grep -q '^http_proxy=' "$HOME/.config/environment.d/90-codex-proxy.conf" ||
    fail "cache must include lowercase proxy variables"
}

assert_loader_parses_source() {
  unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy
  # shellcheck source=/dev/null
  . "$HOME/.config/kate-proxy/load-codex-proxy.bash"
  [ "$HTTP_PROXY" = 'http://user:codex-secret@example.test:8080/path with space?token=$dollar\slash"quote'\''single' ] ||
    fail "loader did not parse double-quoted CRLF value"
  [ "$HTTPS_PROXY" = "https://user:codex-secret@example.test:8443/single quoted" ] ||
    fail "loader did not parse single-quoted CRLF value"
  [ "$ALL_PROXY" = "socks5://user:codex-secret@example.test:1080" ] ||
    fail "loader did not parse ALL_PROXY"
  [ "$NO_PROXY" = "localhost,127.0.0.1,.example.test" ] ||
    fail "loader did not parse NO_PROXY"
}

systemd_env_unescape() {
  local raw="$1"
  local index=0
  local char=""
  local next=""
  local rest=""
  local name=""
  SYSTEMD_TEST_VALUE=""

  while [ "$index" -lt "${#raw}" ]; do
    char="${raw:index:1}"
    if [ "$char" = "$" ] && [ $((index + 1)) -lt "${#raw}" ]; then
      next="${raw:index+1:1}"
      if [ "$next" = "$" ]; then
        SYSTEMD_TEST_VALUE+="$"
        index=$((index + 2))
        continue
      fi
      rest="${raw:index+1}"
      if [[ "$rest" =~ ^([A-Za-z_][A-Za-z0-9_]*) ]]; then
        name="${BASH_REMATCH[1]}"
        SYSTEMD_TEST_VALUE+="${!name-}"
        index=$((index + ${#name} + 1))
        continue
      fi
    fi
    SYSTEMD_TEST_VALUE+="$char"
    index=$((index + 1))
  done
}

assert_cache_systemd_content() {
  local cache="$HOME/.config/environment.d/90-codex-proxy.conf"
  local line=""
  local name=""
  local raw=""
  local expected_http='http://user:codex-secret@example.test:8080/path with space?token=$dollar\slash"quote'\''single'
  local expected_http_raw='HTTP_PROXY=http://user:codex-secret@example.test:8080/path with space?token=$$dollar\slash"quote'\''single'
  declare -A parsed_cache=()

  if grep -Eq "^(${expected_http_raw%%=*}|HTTPS_PROXY|ALL_PROXY|NO_PROXY|http_proxy|https_proxy|all_proxy|no_proxy)=['\"]" "$cache"; then
    fail "cache values must not use shell quote wrapping"
  fi
  grep -Fxq "$expected_http_raw" "$cache" ||
    fail "cache must escape literal dollar signs using systemd environment.d syntax"

  while IFS= read -r line || [ -n "$line" ]; do
    [ "$line" != "${line#*=}" ] || continue
    name="${line%%=*}"
    raw="${line#*=}"
    systemd_env_unescape "$raw"
    parsed_cache["$name"]="$SYSTEMD_TEST_VALUE"
  done < "$cache"

  [ "${parsed_cache[HTTP_PROXY]}" = "$expected_http" ] ||
    fail "systemd-style cache parser did not recover HTTP_PROXY"
  [ "${parsed_cache[http_proxy]}" = "$expected_http" ] ||
    fail "systemd-style cache parser did not recover http_proxy"
}

assert_managed_startup_guard() {
  local file="$1"
  awk '
    $0 == "# >>> Kate Codex proxy startup >>>" { in_block = 1; next }
    $0 == "# <<< Kate Codex proxy startup <<<" { in_block = 0; done = 1; next }
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
  ' "$file" || fail "managed startup block must guard Bash-only loader"
}

write_systemd_stubs
write_codex_source
write_hermes_isolation
write_existing_startup_files

original_home="$HOME"
dry_home="$(mktemp -d)"
HOME="$dry_home"
export HOME
bash "$script" install --dry-run
bash "$script" sync --dry-run
[ ! -e "$HOME/.config/kate-proxy" ] || fail "dry-run must not create proxy directory"
[ ! -e "$HOME/.config/environment.d/90-codex-proxy.conf" ] ||
  fail "dry-run must not create cache"
HOME="$original_home"
export HOME
rm -rf -- "$dry_home"

unsafe_home="$(mktemp -d)"
HOME="$unsafe_home"
export HOME
write_codex_source
unsafe_config_target="$(mktemp -d)"
ln -s "$unsafe_config_target" "$HOME/.config"
expect_fail bash "$script" sync
HOME="$original_home"
export HOME
rm -f -- "$unsafe_home/.config"
rm -f -- "$unsafe_home/.hermes/codex-proxy.env"
rmdir "$unsafe_home/.hermes" "$unsafe_home" "$unsafe_config_target"

unsafe_home="$(mktemp -d)"
HOME="$unsafe_home"
export HOME
write_codex_source
mkdir -p "$HOME/.config"
unsafe_environment_target="$(mktemp -d)"
ln -s "$unsafe_environment_target" "$HOME/.config/environment.d"
expect_fail bash "$script" sync
HOME="$original_home"
export HOME
rm -f -- "$unsafe_home/.config/environment.d"
rm -f -- "$unsafe_home/.hermes/codex-proxy.env"
rmdir "$unsafe_home/.config" "$unsafe_home/.hermes" "$unsafe_home" "$unsafe_environment_target"

unsafe_home="$(mktemp -d)"
HOME="$unsafe_home"
export HOME
write_codex_source
write_existing_startup_files
mkdir -p "$HOME/.config"
unsafe_proxy_target="$(mktemp -d)"
ln -s "$unsafe_proxy_target" "$HOME/.config/kate-proxy"
expect_fail bash "$script" install
HOME="$original_home"
export HOME
rm -f -- "$unsafe_home/.config/kate-proxy"
rm -f -- "$unsafe_home/.hermes/codex-proxy.env" "$unsafe_home/.profile" "$unsafe_home/.bashrc"
rmdir "$unsafe_home/.config" "$unsafe_home/.hermes" "$unsafe_home" "$unsafe_proxy_target"

bash "$script" install
assert_installed_shape
assert_loader_parses_source
assert_cache_systemd_content
assert_managed_startup_guard "$HOME/.profile"
assert_managed_startup_guard "$HOME/.bashrc"
[ -s "$KATE_TEST_SYSTEMD_ENV" ] || fail "systemd stub was not updated"
[ -s "$KATE_TEST_DBUS_ENV" ] || fail "DBus stub was not updated"
[ "$(backup_count "$HOME/.profile")" -eq 1 ] || fail "profile backup missing"
[ "$(backup_count "$HOME/.bashrc")" -eq 1 ] || fail "bashrc backup missing"
[ "$(marker_count "$HOME/.profile")" -eq 1 ] || fail "profile startup block duplicated"
[ "$(marker_count "$HOME/.bashrc")" -eq 1 ] || fail "bashrc startup block duplicated"

doctor_out="$tmp_home/doctor.out"
bash "$script" doctor > "$doctor_out"
grep -Fq "OK Kate Codex user proxy" "$doctor_out" ||
  fail "doctor success output missing"
if grep -Fq "codex-secret" "$doctor_out"; then
  cat "$doctor_out" >&2
  fail "doctor output must not print proxy values"
fi

cache="$HOME/.config/environment.d/90-codex-proxy.conf"
bad_cache="$cache.bad"
while IFS= read -r line || [ -n "$line" ]; do
  line="${line//\$\$dollar/__KATE_UNESCAPED_DOLLAR__}"
  line="${line//__KATE_UNESCAPED_DOLLAR__/\$dollar}"
  printf '%s\n' "$line"
done < "$cache" > "$bad_cache"
mv -f -- "$bad_cache" "$cache"
expect_fail env -u dollar bash "$script" doctor
bash "$script" sync

cat > "$HOME/.profile" <<'EOF'
# >>> Kate Codex proxy startup >>>
if [ -r "$HOME/.config/kate-proxy/load-codex-proxy.bash" ]; then
  . "$HOME/.config/kate-proxy/load-codex-proxy.bash"
fi
# <<< Kate Codex proxy startup <<<
EOF
expect_fail bash "$script" doctor
write_existing_startup_files
bash "$script" install

write_legacy_startup_files
[ "$(marker_count "$HOME/.profile")" -eq 0 ] || fail "legacy profile must not have managed marker"
[ "$(legacy_count "$HOME/.profile")" -eq 1 ] || fail "legacy profile block missing"
bash "$script" doctor > "$tmp_home/legacy-doctor.out"
grep -Fq "OK Kate Codex user proxy" "$tmp_home/legacy-doctor.out" ||
  fail "doctor must accept exactly one compatible legacy startup block"
if grep -Fq "codex-secret" "$tmp_home/legacy-doctor.out"; then
  cat "$tmp_home/legacy-doctor.out" >&2
  fail "legacy doctor output must not print proxy values"
fi

bash "$script" install
[ "$(marker_count "$HOME/.profile")" -eq 1 ] || fail "install must normalize legacy profile to managed block"
[ "$(marker_count "$HOME/.bashrc")" -eq 1 ] || fail "install must normalize legacy bashrc to managed block"
assert_managed_startup_guard "$HOME/.profile"
assert_managed_startup_guard "$HOME/.bashrc"
[ "$(legacy_count "$HOME/.profile")" -eq 0 ] || fail "install must remove legacy profile block"
[ "$(legacy_count "$HOME/.bashrc")" -eq 0 ] || fail "install must remove legacy bashrc block"

legacy_startup_block >> "$HOME/.profile"
expect_fail bash "$script" doctor
bash "$script" install
[ "$(marker_count "$HOME/.profile")" -eq 1 ] || fail "install must keep one managed profile block after duplicate"
[ "$(legacy_count "$HOME/.profile")" -eq 0 ] || fail "install must remove duplicate legacy profile block"

profile_backups_before="$(backup_count "$HOME/.profile")"
bash "$script" install
[ "$(backup_count "$HOME/.profile")" -eq "$profile_backups_before" ] ||
  fail "idempotent install must not create extra startup backups"
[ "$(marker_count "$HOME/.profile")" -eq 1 ] || fail "profile block duplicated after repeat install"
[ "$(marker_count "$HOME/.bashrc")" -eq 1 ] || fail "bashrc block duplicated after repeat install"

cache_state_before="$(stat -c '%i:%Y:%s' "$HOME/.config/environment.d/90-codex-proxy.conf")"
sleep 1
bash "$script" sync
cache_state_after="$(stat -c '%i:%Y:%s' "$HOME/.config/environment.d/90-codex-proxy.conf")"
[ "$cache_state_before" = "$cache_state_after" ] ||
  fail "unchanged sync must not rewrite cache"

rm -f "$HOME/.config/environment.d/90-codex-proxy.conf"
ln -s "$HOME/.hermes/codex-proxy.env" "$HOME/.config/environment.d/90-codex-proxy.conf"
bash "$script" sync
[ -f "$HOME/.config/environment.d/90-codex-proxy.conf" ] ||
  fail "sync must recreate cache as a file"
[ ! -L "$HOME/.config/environment.d/90-codex-proxy.conf" ] ||
  fail "sync must replace cache symlink with regular file"

leftover_temps="$(find "$HOME/.config/environment.d" -maxdepth 1 -name '.90-codex-proxy.conf.*' | wc -l)"
[ "$leftover_temps" -eq 0 ] || fail "sync left temporary files behind"

chmod 644 "$HOME/.config/environment.d/90-codex-proxy.conf"
expect_fail bash "$script" doctor
bash "$script" sync
bash "$script" doctor > /dev/null

rm -f "$HOME/.config/systemd/user/hermes.service.d/proxy.conf"
cp "$HOME/.hermes/codex-proxy.env" "$HOME/.hermes/hermes-proxy.env"
bash "$script" doctor > "$tmp_home/no-hermes-dropin-doctor.out"
grep -Fq "SKIP Hermes proxy drop-in not found" "$tmp_home/no-hermes-dropin-doctor.out" ||
  fail "doctor must skip Hermes hash checks when no drop-ins exist"
if grep -Fq "codex-secret" "$tmp_home/no-hermes-dropin-doctor.out"; then
  fail "no-dropin doctor output must not print proxy values"
fi

rm -f "$HOME/.hermes/hermes-proxy.env"
ln -s "$HOME/.hermes/codex-proxy.env" "$HOME/.hermes/hermes-proxy.env"
expect_fail bash "$script" doctor
rm -f "$HOME/.hermes/hermes-proxy.env"
write_hermes_isolation

cp "$HOME/.hermes/codex-proxy.env" "$HOME/.hermes/hermes-proxy.env"
expect_fail bash "$script" doctor
write_hermes_isolation

rm -f "$HOME/.hermes/hermes-proxy.env"
ln -s "$HOME/.hermes/codex-proxy.env" "$HOME/.hermes/hermes-proxy.env"
expect_fail bash "$script" doctor
rm -f "$HOME/.hermes/hermes-proxy.env"
expect_fail bash "$script" doctor
write_hermes_isolation

printf '[Service]\nEnvironmentFile=%s/.hermes/codex-proxy.env\n' "$HOME" \
  > "$HOME/.config/systemd/user/hermes.service.d/proxy.conf"
expect_fail bash "$script" doctor
write_hermes_isolation

mkdir -p "$HOME/.config/systemd/user/hermes-gateway.service.d"
printf '[Service]\nEnvironmentFile=%s/.hermes/codex-proxy.env\n' "$HOME" \
  > "$HOME/.config/systemd/user/hermes-gateway.service.d/proxy.conf"
expect_fail bash "$script" doctor
rm -f "$HOME/.config/systemd/user/hermes-gateway.service.d/proxy.conf"

mkdir -p "$HOME/.config/systemd/user/hermes-gateway@default.service.d"
printf '[Service]\nEnvironmentFile=%s/.hermes/gateway-policy.env\n' "$HOME" \
  > "$HOME/.config/systemd/user/hermes-gateway@default.service.d/proxy.conf"
expect_fail bash "$script" doctor
rm -f "$HOME/.config/systemd/user/hermes-gateway@default.service.d/proxy.conf"

custom_dropin="$HOME/custom-hermes-dropin.conf"
printf '[Service]\nEnvironmentFile=%s/.hermes/codex-proxy.env\n' "$HOME" > "$custom_dropin"
(
  export KATE_HERMES_PROXY_DROPIN="$custom_dropin"
  expect_fail bash "$script" doctor
)
rm -f "$custom_dropin"

bash "$script" doctor > /dev/null

backup_root="$HOME/.kisa-backups/test-user-proxy"
mkdir -p "$backup_root/present" "$backup_root/absent/.config/environment.d" "$backup_root/absent/.config"
printf 'original profile\n' > "$backup_root/present/.profile"
printf 'original bashrc\n' > "$backup_root/present/.bashrc"
: > "$backup_root/absent/.config/kate-proxy"
: > "$backup_root/absent/.config/environment.d/90-codex-proxy.conf"
bash "$rollback" "$backup_root" > "$tmp_home/rollback.out"
[ ! -e "$HOME/.config/kate-proxy" ] || fail "rollback must remove proxy directory from absent snapshot"
[ ! -e "$HOME/.config/environment.d/90-codex-proxy.conf" ] ||
  fail "rollback must remove generated cache from absent snapshot"
grep -Fxq 'original profile' "$HOME/.profile" ||
  fail "rollback must restore profile snapshot"
grep -Fxq 'original bashrc' "$HOME/.bashrc" ||
  fail "rollback must restore bashrc snapshot"

if rg -n 'git config|npm config|pnpm config|sudoers|NOPASSWD' "$script" >/tmp/kisa-user-proxy-forbidden.out; then
  cat /tmp/kisa-user-proxy-forbidden.out >&2
  fail "user proxy workflow must not modify Git/npm/pnpm proxy config or sudoers"
fi

echo "Kate user proxy tests passed."
