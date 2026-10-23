#!/usr/bin/env bash
# Offline test (no cluster) of what istioctl validate says about a typo in an
# EnvoyFilter field (max_tokenz instead of max_tokens), written two ways:
#   ci/testdata/ef-typo-direct.yaml       typed_config is the proto type
#   ci/testdata/ef-typo-typedstruct.yaml  typed_config is a udpa TypedStruct
# Measured on istioctl 1.31.2: both are valid (exit 0); the proto form gets a
# warning naming the unknown field, the TypedStruct form gets none. The same
# check against the API server (kubectl apply --dry-run=server) is in
# scripts/by-hand-check.sh.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash "${REPO_ROOT}/tools/install-cli.sh" >/dev/null
export PATH="${REPO_ROOT}/bin:${PATH}"
TD="${REPO_ROOT}/ci/testdata"

PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); printf '    [PASS] %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf '    [FAIL] %s\n' "$1"; }
expect_eq() { if [ "$2" = "$3" ]; then pass "$1 (got $3)"; else fail "$1 (expected $2, got $3)"; fi; }

for form in direct typedstruct; do
  out="$(istioctl validate -f "${TD}/ef-typo-${form}.yaml" 2>&1)"; rc=$?
  printf '    istioctl validate -f ci/testdata/ef-typo-%s.yaml (exit %s)\n' "${form}" "${rc}"
  printf '%s\n' "${out}" | sed 's/^/      /'
  expect_eq "${form}: accepted (exit 0)" "0" "${rc}"
  n="$(grep -c 'unknown field "max_tokenz"' <<< "${out}" || true)"
  if [ "${form}" = direct ]; then
    expect_eq "direct: one warning names the unknown field max_tokenz" "1" "${n}"
  else
    expect_eq "typedstruct: no warning mentions max_tokenz" "0" "${n}"
  fi
done

printf '\n    result: %s passed, %s failed\n' "${PASSED}" "${FAILED}"
[ "${FAILED}" -eq 0 ]
