#!/usr/bin/env bash
# Runs the whole lab end to end, in the order of the article, then the "By
# hand" commands of README.md (scripts/by-hand-check.sh), and exits non-zero
# if any assertion fails. Leaves the lab running; scripts/teardown.sh removes it.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

start="$(date +%s)"
failed=()

# Offline checks first: they need no cluster (the EnvoyFilter lint and its
# tests, the context guard).
bash "${DIR}/../tools/install-cli.sh" >/dev/null
for t in test-envoyfilter-lint test-typedstruct test-context-guard; do
  printf '\n######## ci/%s ########\n' "${t}"
  if ! bash "${DIR}/../ci/${t}.sh"; then
    failed+=("ci/${t}")
  fi
done

for s in 01-cluster 02-follow-request 03-translation 04-broken-by-layer 05-proxy-status 06-logs-stats 07-envoyfilter 08-ambient by-hand-check; do
  printf '\n######## %s ########\n' "${s}"
  t0="$(date +%s)"
  if ! bash "${DIR}/${s}.sh"; then
    failed+=("${s}")
    # Every later step needs the cluster from step 1.
    [ "${s}" = "01-cluster" ] && break
  fi
  echo "step ${s}: $(( $(date +%s) - t0 ))s"
done

printf '\n######## summary ########\n'
echo "duration: $(( $(date +%s) - start ))s"
if [ "${#failed[@]}" -eq 0 ]; then
  echo "all steps passed"
else
  echo "failed steps: ${failed[*]}"
  exit 1
fi
