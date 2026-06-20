#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_dir/deploy/kate/codex-wrapper.sh"
tmp_home="$(mktemp -d)"
trap 'rm -rf -- "$tmp_home"' EXIT

export HOME="$tmp_home"
export CODEX_WRAPPER_PATH="$HOME/.local/bin/codex"
export CODEX_PROXY_ENV="$HOME/.hermes/codex-proxy.env"
export CODEX_NVM_ROOT="$HOME/.nvm/versions/node"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

make_real_codex() {
  local version="$1"
  local label="$2"
  local target="$CODEX_NVM_ROOT/$version/bin/codex"
  mkdir -p "$(dirname "$target")"
  cat > "$target" <<EOF
#!/usr/bin/env bash
set -euo pipefail
case "\${1:-}" in
  --version) printf '%s\n' "$label" ;;
  env-check) printf '%s\n' "\${KISA_PROXY_TEST:-missing}" ;;
  *) printf '%s\n' "$label" ;;
esac
EOF
  chmod +x "$target"
}

backup_count() {
  find "$HOME/.local/bin" -maxdepth 1 -name 'codex.backup-*' 2>/dev/null | wc -l
}

expect_doctor_fail() {
  if bash "$script" doctor >/tmp/kisa-wrapper-doctor.out 2>&1; then
    cat /tmp/kisa-wrapper-doctor.out >&2
    fail "doctor unexpectedly succeeded"
  fi
}

mkdir -p "$HOME/.hermes"
printf 'KISA_PROXY_TEST=loaded\r\n' > "$CODEX_PROXY_ENV"
chmod 600 "$CODEX_PROXY_ENV"
make_real_codex "v20.0.0" "codex-old"
make_real_codex "v24.14.1" "codex-new"

bash "$script" repair
[ -f "$CODEX_WRAPPER_PATH" ] || fail "wrapper was not created"
[ ! -L "$CODEX_WRAPPER_PATH" ] || fail "wrapper must not be a symlink"
[ "$(stat -c '%a' "$CODEX_WRAPPER_PATH")" = "700" ] || fail "wrapper mode must be 700"
[ "$("$CODEX_WRAPPER_PATH" --version)" = "codex-new" ] || fail "wrapper must select latest NVM Codex"
[ "$("$CODEX_WRAPPER_PATH" env-check)" = "loaded" ] || fail "wrapper must load CRLF proxy env"
bash "$script" doctor

before="$(backup_count)"
bash "$script" repair
after="$(backup_count)"
[ "$before" -eq "$after" ] || fail "idempotent repair must not create backup"

ln -sf "$CODEX_NVM_ROOT/v20.0.0/bin/codex" "$CODEX_WRAPPER_PATH"
bash "$script" repair
find "$HOME/.local/bin" -maxdepth 1 -name 'codex.backup-*' | grep -q . ||
  fail "repair must back up replaced symlink"
bash "$script" doctor

printf '#!/usr/bin/env bash\nexit 0\n' > "$CODEX_WRAPPER_PATH"
chmod 755 "$CODEX_WRAPPER_PATH"
bash "$script" repair
[ "$(backup_count)" -ge 2 ] || fail "repair must back up replaced launcher"

rm -f "$CODEX_WRAPPER_PATH"
expect_doctor_fail

ln -sf "$CODEX_NVM_ROOT/v24.14.1/bin/codex" "$CODEX_WRAPPER_PATH"
expect_doctor_fail

rm -f "$CODEX_WRAPPER_PATH"
printf '#!/usr/bin/env bash\nexec true\n' > "$CODEX_WRAPPER_PATH"
chmod 700 "$CODEX_WRAPPER_PATH"
expect_doctor_fail

bash "$script" repair
chmod 755 "$CODEX_WRAPPER_PATH"
expect_doctor_fail
chmod 700 "$CODEX_WRAPPER_PATH"

saved_real="$CODEX_NVM_ROOT/v24.14.1/bin/codex.real"
mv "$CODEX_NVM_ROOT/v24.14.1/bin/codex" "$saved_real"
ln -sf "$CODEX_WRAPPER_PATH" "$CODEX_NVM_ROOT/v24.14.1/bin/codex"
mv "$CODEX_NVM_ROOT/v20.0.0/bin/codex" "$CODEX_NVM_ROOT/v20.0.0/bin/codex.real"
if "$CODEX_WRAPPER_PATH" --version >/tmp/kisa-wrapper-recursion.out 2>&1; then
  cat /tmp/kisa-wrapper-recursion.out >&2
  fail "wrapper must not recurse into itself"
fi
mv "$CODEX_NVM_ROOT/v20.0.0/bin/codex.real" "$CODEX_NVM_ROOT/v20.0.0/bin/codex"
rm -f "$CODEX_NVM_ROOT/v24.14.1/bin/codex"
mv "$saved_real" "$CODEX_NVM_ROOT/v24.14.1/bin/codex"

bash "$script" repair
bash "$script" doctor

echo "Codex proxy wrapper tests passed."
