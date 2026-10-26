#!/usr/bin/env bash
# Offline check that every host of a VirtualService exists, for CI. No cluster
# needed.
#
#   bash ci/vs-host-lint.sh [--domain cluster.local] <file or directory>...
#
# The API server accepts a VirtualService whose host is a Service that does not
# exist (broken/03-vs-wrong-host.yaml: "payment" instead of "payments"), and
# istioctl analyze has no message for it. istiod still pushes it, as a virtual
# host of its own that no request matches, so the routes you meant to change
# stay as they were. This lint resolves each host the way the VirtualService
# reference describes and looks it up among the Services and ServiceEntries of
# the files given. To check against a live registry, dump it first:
#
#   kubectl get service,serviceentry -A -o yaml > registry.yaml
#   bash ci/vs-host-lint.sh registry.yaml deploy/
#
# Host resolution:
#   a name without dots ("fraud-check") is a short name, interpreted in the
#   namespace of the VirtualService: fraud-check.<namespace>.svc.<domain>.
#   Anything with a dot is taken as written.
#   A wildcard host ("*.example.com") passes when a known host matches it.
#   VirtualServices bound only to gateways (no "mesh" in gateways) are skipped:
#   their hosts are the names clients use at the edge, not registry entries.
#
# Errors (exit 1):
#   VS001  a host with no Service or ServiceEntry behind it
# Warnings (reported, exit 0):
#   VS101  a short name: valid, but the reference recommends FQDNs, and the
#          namespace it resolves to is the VirtualService's, not the Service's
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${REPO_ROOT}/bin:${PATH}"

DOMAIN="cluster.local"
if [ "${1:-}" = "--domain" ]; then DOMAIN="${2:?--domain needs a value}"; shift 2; fi
[ "$#" -gt 0 ] || { echo "usage: $0 [--domain cluster.local] <file or directory>..." >&2; exit 2; }
for t in yq jq; do
  command -v "${t}" >/dev/null || { echo "missing tool: ${t} (run tools/install-cli.sh)" >&2; exit 2; }
done

files=()
for a in "$@"; do
  if [ -d "${a}" ]; then
    while IFS= read -r f; do files+=("${f}"); done < <(find "${a}" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)
  else
    [ -f "${a}" ] || { echo "not a file: ${a}" >&2; exit 2; }
    files+=("${a}")
  fi
done

# Every document of every file as one JSON line, with "kind: List" (the output
# of kubectl get -o yaml) flattened into its items and the file kept in .__file.
objects=""
for f in "${files[@]}"; do
  docs="$(yq -o=json -I=0 '.' "${f}" 2>/dev/null)" || { echo "ERROR VS000 ${f} -: not valid YAML"; exit 1; }
  objects+="$(jq -c --arg f "${f}" 'select(. != null) | if .kind == "List" then .items[] else . end | . + {__file: $f}' <<< "${docs}")"$'\n'
done

# The registry: <name>.<namespace>.svc.<domain> for each Service, and the hosts
# of each ServiceEntry.
known="$(jq -sc --arg d "${DOMAIN}" '
  [ .[] | select(. != null)
    | if .kind == "Service" then "\(.metadata.name).\(.metadata.namespace // "default").svc.\($d)"
      elif .kind == "ServiceEntry" then (.spec.hosts // [])[]
      else empty end ] | unique' <<< "${objects}")"

# One "<code>\t<file>\t<ns/name>\t<message>" line per finding.
# shellcheck disable=SC2016 # a jq program: $vars are jq variables
CHECK='
def glob($h): "^" + ($h | gsub("\\."; "\\.") | gsub("\\*"; ".*")) + "$";
select(.kind == "VirtualService")
| (.metadata.namespace // "default") as $ns
| "\($ns)/\(.metadata.name)" as $res
| .__file as $f
| select((.spec.gateways // ["mesh"]) | index("mesh"))
| (.spec.hosts // [])[]
| . as $h
| (if ($h | contains(".") or startswith("*")) then $h else "\($h).\($ns).svc.\($d)" end) as $fqdn
| (if ($h | startswith("*")) then ($known | any(test(glob($h))))
   else ($known | index($fqdn)) != null end) as $found
| (if ($h | contains(".") or startswith("*")) then empty
   else "VS101\t\($f)\t\($res)\tshort name \"\($h)\" resolves to \($fqdn) (the namespace of the VirtualService)" end),
  (if $found then empty
   else "VS001\t\($f)\t\($res)\thost \"\($h)\"" + (if $h != $fqdn then " (\($fqdn))" else "" end)
        + ": no Service or ServiceEntry; istiod gives it a virtual host of its own and no request reaches its routes" end)
'

ERRORS=0
WARNINGS=0
CHECKED="$(jq -s '[.[] | select(. != null and .kind == "VirtualService")] | length' <<< "${objects}")"
while IFS=$'\t' read -r code f res msg; do
  [ -n "${code}" ] || continue
  if [[ "${code}" == VS1* ]]; then
    printf 'WARN  %s %s %s: %s\n' "${code}" "${f}" "${res}" "${msg}"; WARNINGS=$((WARNINGS + 1))
  else
    printf 'ERROR %s %s %s: %s\n' "${code}" "${f}" "${res}" "${msg}"; ERRORS=$((ERRORS + 1))
  fi
done < <(jq -r --argjson known "${known}" --arg d "${DOMAIN}" "${CHECK}" <<< "${objects}")

echo "vs-host-lint: ${CHECKED} VirtualService(s) checked against $(jq length <<< "${known}") known host(s), ${ERRORS} error(s), ${WARNINGS} warning(s)"
[ "${ERRORS}" -eq 0 ]
