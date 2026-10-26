#!/usr/bin/env bash
# Tests for ci/vs-host-lint.sh, offline (no cluster): the canary of step 03
# passes against the lab's Services; the host typo of step 04 fails with VS001;
# short names, wildcards, gateway-only VirtualServices and a registry dumped
# with kubectl (kind: List) behave as the lint's header says.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash "${REPO_ROOT}/tools/install-cli.sh" >/dev/null
export PATH="${REPO_ROOT}/bin:${PATH}"
LINT="${REPO_ROOT}/ci/vs-host-lint.sh"
TD="${REPO_ROOT}/ci/testdata"
APPS="${REPO_ROOT}/apps"

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
  warns="$(awk '$1 == "WARN" { print $2 }' <<< "${out}" | sort -u | paste -sd, -)"
  if [ "${rc}" = "${want_rc}" ] && [ "${errs:--}" = "${want_err}" ] && [ "${warns:--}" = "${want_warn}" ]; then
    pass "${desc} (exit ${rc}, errors ${errs:--}, warnings ${warns:--})"
  else
    fail "${desc} (expected exit ${want_rc} errors ${want_err} warnings ${want_warn}; got exit ${rc} errors ${errs:--} warnings ${warns:--})"
  fi
  printf '%s\n' "${out}" | sed 's/^/        /'
}

echo "==> the lab's VirtualServices against the lab's Services (apps/)"
lint_case "translation/20-virtualservice-canary.yaml passes" 0 - - \
  "${APPS}" "${REPO_ROOT}/translation/20-virtualservice-canary.yaml"
lint_case "broken/03-vs-wrong-host.yaml fails: payment, not payments" 1 VS001 - \
  "${APPS}" "${REPO_ROOT}/broken/03-vs-wrong-host.yaml"
lint_case "broken/04-vs-gateway-drops-mesh.yaml is skipped (gateways only)" 0 - - \
  "${APPS}" "${REPO_ROOT}/broken/04-vs-gateway-drops-mesh.yaml"
lint_case "without the Services, the canary's host is unknown too" 1 VS001 - \
  "${REPO_ROOT}/translation/20-virtualservice-canary.yaml"

echo "==> host resolution"
out="$(bash "${LINT}" "${APPS}" "${TD}/vs-short-name.yaml" 2>&1)"; rc=$?
printf '%s\n' "${out}" | sed 's/^/        /'
if [ "${rc}" = 1 ] \
  && grep -q '^WARN  VS101 .* payments/fraud-check-short: .*fraud-check.payments.svc.cluster.local' <<< "${out}" \
  && grep -q '^ERROR VS001 .* payments-ingress/fraud-check-short: .*fraud-check.payments-ingress.svc.cluster.local' <<< "${out}" \
  && [ "$(grep -c '^ERROR' <<< "${out}")" = 1 ]; then
  pass "a short name resolves in the VirtualService's namespace: found in payments, VS001 in payments-ingress"
else
  fail "a short name resolves in the VirtualService's namespace"
fi
lint_case "a wildcard host passes when a ServiceEntry host matches it" 0 - - \
  "${REPO_ROOT}/translation/30-serviceentry-github.yaml" "${TD}/vs-wildcard.yaml"
lint_case "the same wildcard fails with no ServiceEntry" 1 VS001 - "${TD}/vs-wildcard.yaml"
lint_case "--domain changes the suffix of Service hosts" 1 VS001 - \
  --domain corp.internal "${APPS}" "${REPO_ROOT}/translation/20-virtualservice-canary.yaml"

echo "==> a registry dumped with kubectl get -o yaml (kind: List)"
lint_case "the canary passes against the dump" 0 - - \
  "${TD}/registry-list.yaml" "${REPO_ROOT}/translation/20-virtualservice-canary.yaml"
lint_case "the typo fails against the dump" 1 VS001 - \
  "${TD}/registry-list.yaml" "${REPO_ROOT}/broken/03-vs-wrong-host.yaml"

echo "==> inputs"
lint_case "files without VirtualServices check nothing" 0 - - "${APPS}" "${REPO_ROOT}/envoyfilter"
bash "${LINT}" >/dev/null 2>&1; rc=$?
if [ "${rc}" = 2 ]; then pass "no arguments: usage, exit 2"; else fail "no arguments: expected exit 2, got ${rc}"; fi

printf '\n    result: %s passed, %s failed\n' "${PASSED}" "${FAILED}"
[ "${FAILED}" -eq 0 ]
