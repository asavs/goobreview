#!/usr/bin/env bash
# Optional local preflight: is this shell a plausible GNU/Linux host for
# goobreview shell work and fixture runs? Exit 0 when checks pass; non-zero
# with actionable stderr when not. Does not install packages or mutate state.
#
# Canonical validation still lives in CONTRIBUTING.md and
# .github/workflows/linux-validation.yml (Ubuntu). This script only answers
# "am I on the right kind of host?" before you burn time on fixtures.
set -euo pipefail

fail=0

note() { printf '%s\n' "$*"; }
bad() {
  printf 'FAIL: %s\n' "$*" >&2
  fail=1
}
ok() { printf 'ok - %s\n' "$*"; }

note "goobreview dev-env check (GNU/Linux target: Ubuntu daemon, CI, or WSL)"

if [ -n "${MSYSTEM:-}" ] || [ "${OSTYPE:-}" = "msys" ] || [ "${OSTYPE:-}" = "cygwin" ]; then
  bad "MSYS/Cygwin/Git Bash detected; use Ubuntu or WSL for shell validation"
else
  ok "not MSYS/Cygwin"
fi

if [ -z "${BASH_VERSION:-}" ]; then
  bad "must run under bash"
else
  ok "bash ${BASH_VERSION}"
fi

need_cmd() {
  if command -v "$1" >/dev/null 2>&1; then
    ok "command present: $1"
  else
    bad "missing command: $1"
  fi
}

need_cmd flock
need_cmd timeout
need_cmd jq
need_cmd git
need_cmd openssl
need_cmd gzip
need_cmd find
need_cmd sort
need_cmd sed
need_cmd stat

# GNU-only behaviors the daemon and fixtures rely on.
if sort -V </dev/null >/dev/null 2>&1; then
  ok "sort -V (GNU version sort)"
else
  bad "sort -V failed (need GNU coreutils)"
fi

if printf 'agy 1.0\n' | sed -E 's/^agy[[:space:]]+//I' 2>/dev/null | grep -qx '1.0'; then
  ok "sed -E with //I (GNU sed case-insensitive)"
else
  bad "sed -E //I failed (need GNU sed)"
fi

if stat -c '%Y' / >/dev/null 2>&1 || stat -f '%m' / >/dev/null 2>&1; then
  ok "stat mtime probe (GNU -c or BSD -f)"
else
  bad "stat cannot report mtime (-c or -f)"
fi

if find /dev/null -printf '%p\n' >/dev/null 2>&1; then
  ok "find -printf (GNU findutils)"
else
  bad "find -printf failed (need GNU findutils; used by transcript discovery)"
fi

if [ "$fail" -ne 0 ]; then
  printf '\nEnvironment is not ready for authoritative shell validation.\n' >&2
  printf 'Target: Ubuntu LTS (daemon VM), ubuntu-latest CI, or a WSL Ubuntu distro.\n' >&2
  printf 'Then run: bash scripts/reviewer/tests/run-fixtures.sh\n' >&2
  exit 1
fi

printf '\nEnvironment looks like a GNU/Linux host suitable for fixtures.\n'
printf 'Next: bash scripts/reviewer/tests/run-fixtures.sh\n'
exit 0
