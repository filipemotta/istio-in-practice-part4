#!/usr/bin/env bash
# After a rollout, check that a caller's sidecar received the route you meant
# to change, for CI. Read-only: it only runs istioctl proxy-config route.
#
#   bash ci/route-assert.sh --context <kube context> [--wait 30] \
#     <namespace> <pod | deployment/name> <host:port> <route name> <cluster>
#
# Checking that the host is in the caller's route configuration is not enough:
# fraud-check.payments.svc.cluster.local:8080 is there from the Service alone,
# with Istio's route "default", whether or not a VirtualService changed it
# (broken/03-vs-wrong-host.yaml). This checks the content instead: the virtual
# host <host:port> must hold a route named <route name> (the "name" of the
# VirtualService's HTTP route) that sends to <cluster>, either alone or as one
# of its weighted clusters. It retries for --wait seconds (default 30) while
# istiod pushes the change.
#
# Example, for the canary of translation/20-virtualservice-canary.yaml:
#   bash ci/route-assert.sh --context staging payments deployment/payments-api \
#     fraud-check.payments.svc.cluster.local:8080 canary \
#     'outbound|8080|v2|fraud-check.payments.svc.cluster.local'
#
# Exit 0 when the route is there, 1 when it is not (the routes the virtual host
# does hold are printed), 2 on usage or tool errors.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${REPO_ROOT}/bin:${PATH}"

usage() { sed -n '5,6p' "${BASH_SOURCE[0]}" | sed 's/^# *//' >&2; exit 2; }
CONTEXT=""
WAIT=30
while [ "$#" -gt 0 ]; do
  case "$1" in
    --context) CONTEXT="${2:-}"; shift 2 ;;
    --wait) WAIT="${2:-}"; shift 2 ;;
    -*) usage ;;
    *) break ;;
  esac
done
# The context is required: a CI job must say which cluster it reads.
[ -n "${CONTEXT}" ] && [ "$#" -eq 5 ] && [[ "${WAIT}" =~ ^[0-9]+$ ]] || usage
NS="$1" TARGET="$2" VHOST="$3" ROUTE="$4" CLUSTER="$5"
for t in istioctl jq; do
  command -v "${t}" >/dev/null || { echo "missing tool: ${t} (run tools/install-cli.sh)" >&2; exit 2; }
done

# "<route name> -> <cluster[,cluster...]>" for every route of the virtual host,
# in the order Envoy evaluates them; empty when the virtual host is absent.
vhost_routes() {
  istioctl --context "${CONTEXT}" proxy-config route "${TARGET}.${NS}" -o json 2>/dev/null \
    | jq -r --arg v "${VHOST}" '
        .[].virtualHosts[]? | select(.name == $v) | .routes[]?
        | "\(.name // "-") -> \(.route.cluster // ([.route.weightedClusters.clusters[]?.name] | join(",")) // "-")"'
}

deadline=$((SECONDS + WAIT))
while :; do
  routes="$(vhost_routes)"
  if awk -F' -> ' -v r="${ROUTE}" -v c="${CLUSTER}" '
       $1 == r { n = split($2, a, ","); for (i = 1; i <= n; i++) if (a[i] == c) found = 1 }
       END { exit !found }' <<< "${routes}"; then
    echo "route-assert: OK ${TARGET}.${NS} ${VHOST}: route ${ROUTE} -> ${CLUSTER}"
    exit 0
  fi
  [ "${SECONDS}" -lt "${deadline}" ] || break
  sleep 2
done

if [ -z "${routes}" ]; then
  echo "route-assert: FAIL ${TARGET}.${NS} has no virtual host ${VHOST}"
else
  echo "route-assert: FAIL ${TARGET}.${NS} ${VHOST}: no route ${ROUTE} -> ${CLUSTER} after ${WAIT}s; the virtual host holds:"
  awk '{ print "  " $0 }' <<< "${routes}"
fi
exit 1
