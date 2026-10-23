#!/usr/bin/env bash
# Tests for ci/envoyfilter-lint.sh, offline (no cluster): the working filter
# passes clean; every manifest in envoyfilter/silent-errors/ fails with
# exactly the error codes of its own mistake; the fixtures in ci/testdata/
# give warnings only; files without EnvoyFilters are ignored.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash "${REPO_ROOT}/tools/install-cli.sh" >/dev/null
export PATH="${REPO_ROOT}/bin:${PATH}"
LINT="${REPO_ROOT}/ci/envoyfilter-lint.sh"
SE="${REPO_ROOT}/envoyfilter/silent-errors"
TD="${REPO_ROOT}/ci/testdata"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); printf '    [PASS] %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf '    [FAIL] %s\n' "$1"; }

# lint_case <description> <expected exit> <expected ERROR codes, sorted, comma-separated or "-">
#           <expected WARN codes, sorted, comma-separated or "-"> <files...>
lint_case() {
  local desc="$1" want_rc="$2" want_err="$3" want_warn="$4" out rc errs warns; shift 4
  out="$(bash "${LINT}" "$@" 2>&1)"; rc=$?
  errs="$(awk '$1 == "ERROR" { print $2 }' <<< "${out}" | sort -u | paste -sd, -)"
  warns="$(awk '$1 == "WARN" { print ($2 == "ANALYZE" ? $6 : $2) }' <<< "${out}" | tr -d '[]' | sort -u | paste -sd, -)"
  if [ "${rc}" = "${want_rc}" ] && [ "${errs:--}" = "${want_err}" ] && [ "${warns:--}" = "${want_warn}" ]; then
    pass "${desc} (exit ${rc}, errors ${errs:--}, warnings ${warns:--})"
  else
    fail "${desc} (expected exit ${want_rc} errors ${want_err} warnings ${want_warn}; got exit ${rc} errors ${errs:--} warnings ${warns:--})"
    printf '%s\n' "${out}" | sed 's/^/        /'
  fi
}

echo "==> the working filter"
lint_case "envoyfilter/fraud-check-local-ratelimit.yaml passes clean" 0 - - \
  "${REPO_ROOT}/envoyfilter/fraud-check-local-ratelimit.yaml"

echo "==> silent errors: each fails with its own code"
lint_case "01 wrong context (SIDECAR_OUTBOUND)" 1 EF007 - "${SE}/01-wrong-context.yaml"
lint_case "02 portNumber 15006" 1 EF005 - "${SE}/02-wrong-port-15006.yaml"
lint_case "03 deprecated filter name (istiod also warns IST0133)" 1 EF003 IST0133 "${SE}/03-deprecated-filter-name.yaml"
lint_case "04 INSERT_AFTER the router" 1 EF004 - "${SE}/04-after-router.yaml"
lint_case "05 root namespace, no selector, no context" 1 EF001,EF002,EF006 EF101,IST0151 "${SE}/05-root-namespace-no-selector.yaml"
lint_case "06 local_ratelimit never enabled" 1 EF006 - "${SE}/06-not-enabled.yaml"

echo "==> warnings only"
lint_case "official task filter: TypedStruct, no priority, no subFilter" 0 - EF101,EF102,EF103,IST0151 \
  "${TD}/ef-official-task-local-ratelimit.yaml"
lint_case "namespace-wide on purpose, with the opt-out annotation" 0 - - "${TD}/ef-wide-scope-allowed.yaml"
yq 'del(.metadata.annotations)' "${TD}/ef-wide-scope-allowed.yaml" > "${TMP}/no-annotation.yaml"
lint_case "the same without the annotation" 1 EF001 - "${TMP}/no-annotation.yaml"

echo "==> a typo in a field name (max_tokenz)"
lint_case "proto type: istiod's unknown-field warning becomes EF008" 1 EF008 - "${TD}/ef-typo-direct.yaml"
lint_case "TypedStruct: nothing sees the typo, only the TypedStruct warning" 0 - EF102 "${TD}/ef-typo-typedstruct.yaml"

echo "==> inputs"
lint_case "a file without EnvoyFilters is ignored" 0 - - "${REPO_ROOT}/apps/payments-sidecar.yaml"
out="$(bash "${LINT}" "${REPO_ROOT}/envoyfilter" 2>&1)"; rc=$?
if [ "${rc}" = 1 ] && grep -q '^envoyfilter-lint: 7 EnvoyFilter(s) checked' <<< "${out}"; then
  pass "a directory is walked: 7 EnvoyFilters in envoyfilter/, exit 1"
else
  fail "directory walk (exit ${rc}: $(tail -1 <<< "${out}"))"
fi
bash "${LINT}" >/dev/null 2>&1; rc=$?
if [ "${rc}" = 2 ]; then pass "no arguments: usage, exit 2"; else fail "no arguments (exit ${rc})"; fi

printf '\n    result: %s passed, %s failed\n' "${PASSED}" "${FAILED}"
[ "${FAILED}" -eq 0 ]
