# istio-in-practice-part4

Companion repository for *Istio, Hands-On, Part 4*: reading the configuration
Envoy actually received.

Every Istio resource becomes Envoy configuration, and when traffic does
something unexpected the answer is in what the proxy received, not in the
YAML that was applied. A request crosses four layers of that configuration,
listener, route, cluster and endpoint, and each failure of Parts 1 to 3
lives in one of them. This lab reads each layer with `istioctl proxy-config`,
breaks each one on purpose, and checks the diagnosis with numbers: names of
listeners, routes and clusters, endpoint counts, xDS sync states, access log
flags, Envoy stats and HTTP codes. Everything runs on a local `kind` cluster,
at zero cost.

The story continues on the payments platform of Parts 1 to 3: `payments-api`
calls `fraud-check` (two versions behind one Service), which calls
`risk-score`; an ingress Gateway in front; the same services in an ambient
namespace with a waypoint.

One script per step, in the order of the article:

1. cluster, Istio 1.31.2 and the workloads; every proxy in sync with istiod;
2. follow one request through the sidecar: 15001, listener, route, cluster, endpoints, 15006;
3. translation: what each Istio resource changes in the Envoy configuration;
4. broken on purpose, diagnosed by layer: NR, UH, routes that land nowhere, PassthroughCluster vs BlackHoleCluster;
5. proxy-status: SYNCED, STALE and ERROR (a configuration Envoy rejects), and what a rejection freezes;
6. logs and stats: log levels at runtime, the access log format, per-cluster stats, the admin port;
7. EnvoyFilter as the last resort: a local rate limit, and the ways the same patch fails silently;
8. ambient: ztunnel is not Envoy (`ztunnel-config`), the waypoint is (`proxy-config`).

## Pinned versions

| Component | Version |
|---|---|
| Istio | 1.31.2, `ambient` profile (istiod + istio-cni + ztunnel); Envoy 1.39 inside the proxy image |
| Gateway API CRDs | v1.6.3, standard channel (`standard-install.yaml`) |
| kind | v0.33.0 (downloaded into `./bin`), node image `kindest/node:v1.37.0` pinned by digest |
| kubectl | v1.37.1 (downloaded into `./bin`) |
| yq | v4.54.1 (mikefarah/yq, downloaded into `./bin`) |
| Demo images | `fortio/fortio:1.76.0` (fraud-check, risk-score, payments-api server), `curlimages/curl:8.23.0` (callers) |

Every binary in `./bin` is checked against the SHA-256 published with its release.

## Prerequisites

- Docker with about 3 CPUs and 4 GB available (Docker Desktop, Colima or Linux).
- `jq`, `curl`, `tar`, `shasum` or `sha256sum`; `shellcheck` and `kubeconform` for `validate.sh`.
- macOS or Linux, arm64 or amd64, with Internet access: images, release
  manifests, and steps 03 and 04 send a few requests to `api.github.com` and
  `example.com` from inside the cluster.
- `istioctl`, `kubectl`, `kind` and `yq` are downloaded by `tools/install-cli.sh`
  into `./bin`. Every script passes `--context kind-istio-p4` and refuses to run
  if that context does not point at a local kind API server: the lab never uses
  your current kubectl context.

## The workloads

- **payments-api** (`payments`, sidecar): its `app` container is curl, standing
  in for the service code that makes outbound calls; its `load` container is a
  fortio echo server on 9080, the backend of the ingress Gateway (Service port
  8080 -> container port 9080). Its proxy records the stats of the fraud-check
  clusters (`proxyStatsMatcher`, step 06).
- **fraud-check** (`payments`, sidecar): fortio echo server on 8080, two
  Deployments behind one Service, `version: v1` (2 pods) and `version: v2`
  (1 pod), for the DestinationRule subsets. Port 8090 is fraud-check calling
  `risk-score` (fortio's `-M` proxy), through its own sidecar.
- **risk-score** (`payments`, sidecar): fortio echo server.
- **payments-ingress/payments-gateway**: a Gateway API Gateway
  (`gatewayClassName: istio`), deployed by istiod as `payments-gateway-istio`
  with a ClusterIP Service (kind has no load balancer).
- **payments-ambient**: payments-api and fraud-check in ambient mode, and a
  waypoint the namespace uses for L7.

## Layout

```
tools/install-cli.sh            pinned istioctl, kubectl, kind and yq into ./bin (SHA-256 checked)
kind/cluster.yaml               1 control plane + 1 worker
istio/install.yaml              IstioOperator: ambient profile, access log provider diag-log (key=value fields)
istio/registry-only.yaml        overlay: outboundTrafficPolicy REGISTRY_ONLY (step 04)
observability/access-log.yaml   Telemetry API: mesh-wide access logs with diag-log
apps/                           the workloads above (sidecar and ambient namespaces)
ingress/                        Gateway and HTTPRoute to payments-api
translation/                    one resource per file, applied one at a time in step 03
broken/                         routing broken on purpose (step 04)
proxy-status/                   the DENY policy step 05 uses to see a frozen listener
envoyfilter/fraud-check-local-ratelimit.yaml   the EnvoyFilter of step 07
envoyfilter/silent-errors/      the same patch gone wrong: accepted by the API server, each one wrong in its own way
ambient/                        waypoint, an HTTPRoute and an L7 policy for fraud-check
scripts/01-cluster.sh .. 08-ambient.sh   one step of the article each, with assertions
scripts/test-all.sh             runs the offline tests in ci/, then 01..08 and by-hand-check; non-zero exit on any failure
scripts/teardown.sh             deletes the kind cluster
ci/envoyfilter-lint.sh          offline checks for EnvoyFilters (static rules + istioctl analyze)
ci/test-envoyfilter-lint.sh     tests for the lint: the working filter passes, each silent error fails with its own code
ci/testdata/                    lint fixtures (the official task's filter verbatim, a namespace-wide filter on purpose,
                                the step 07 filter with max_tokens misspelled, as proto and as TypedStruct)
ci/test-typedstruct.sh          istioctl validate on a field typo, proto form vs TypedStruct form
ci/test-context-guard.sh        every lab step refuses a context that is not a local kind cluster
scripts/by-hand-check.sh        runs the "By hand" blocks of this README as printed and checks their output
.github/workflows/envoyfilter-lint.yml   GitHub Actions example running the offline tests
validate.sh                     static checks: bash -n, shellcheck, kubeconform
```

## Running

```bash
bash tools/install-cli.sh        # optional, the scripts call it
bash scripts/test-all.sh         # offline tests first, then steps 01..08; about 13 minutes from no cluster
```

Or one step at a time, in the order of the article:

```bash
bash scripts/01-cluster.sh           # kind, Gateway API CRDs, Istio, workloads, proxy-status
bash scripts/02-follow-request.sh    # one request, layer by layer (read-only)
bash scripts/03-translation.sh       # DR, VS, SE, PA, AP: what each changes in Envoy
bash scripts/04-broken-by-layer.sh   # NR, UH, routes that land nowhere, Passthrough vs BlackHole
bash scripts/05-proxy-status.sh      # SYNCED, STALE, ERROR (NACK) and what a rejection freezes
bash scripts/06-logs-stats.sh        # log levels, access log format, cluster stats, admin port
bash scripts/07-envoyfilter.sh       # local rate limit, and its silent errors
bash scripts/08-ambient.sh           # ztunnel-config and the waypoint's Envoy
```

Steps 02 to 08 can be re-run on their own: each one starts by removing the
policies of the namespace it uses.

## By hand

The commands of the article's POC, as printed there. `scripts/by-hand-check.sh`
runs every line of these blocks, extracted from this section, against
`kind-istio-p4` after steps 01 to 08, and checks the outputs the article
describes (`scripts/test-all.sh` runs it last).

After step 01, follow one request yourself, reading the layers in order:

```bash
export PATH="$PWD/bin:$PATH"
POD=$(kubectl --context kind-istio-p4 -n payments get pod -l app=payments-api -o jsonpath='{.items[0].metadata.name}')
istioctl --context kind-istio-p4 proxy-config listener "$POD.payments" --port 15001
istioctl --context kind-istio-p4 proxy-config listener "$POD.payments" --port 8080
istioctl --context kind-istio-p4 proxy-config route "$POD.payments" --name 8080
istioctl --context kind-istio-p4 proxy-config cluster "$POD.payments" --fqdn fraud-check.payments.svc.cluster.local
istioctl --context kind-istio-p4 proxy-config endpoint "$POD.payments" --cluster "outbound|8080||fraud-check.payments.svc.cluster.local"
```

The listener on 8080 shows its HTTP chain loading `Route: 8080`; the last
command prints the three `HEALTHY` endpoints. Add `-o json` to any of them for
the full objects.

At rest, every Envoy shows each xDS type it subscribes to as `SYNCED`
(during step 05, LDS shows `ERROR` on the three fraud-check pods):

```bash
istioctl --context kind-istio-p4 proxy-status -v 1
```

Try the rate limit: apply the filter, wait a few seconds, then send eight
requests to the v2 pod:

```bash
kubectl --context kind-istio-p4 apply -f envoyfilter/fraud-check-local-ratelimit.yaml
FC=$(kubectl --context kind-istio-p4 -n payments get pod -l app=fraud-check,version=v2 -o jsonpath='{.items[0].status.podIP}')
kubectl --context kind-istio-p4 -n payments exec deploy/payments-api -c app -- \
  sh -c "for i in 1 2 3 4 5 6 7 8; do curl -s -o /dev/null -w '%{http_code}\n' http://$FC:8080/; done"
```

Expect five 200s and three 429s. Six and two means one request rode a
connection opened before the push, still on the old filter chain (see the
draining note under "Logs, stats and the admin port"). Delete the filter:

```bash
kubectl --context kind-istio-p4 delete -f envoyfilter/fraud-check-local-ratelimit.yaml
```

Run it all at once and clean up:

```bash
bash scripts/test-all.sh         # offline tests first, then steps 01..08; about 13 minutes from no cluster
bash scripts/teardown.sh         # deletes the kind cluster istio-p4
```

## What the lab measured

Outputs below are from full runs from no cluster (`scripts/teardown.sh` then
`scripts/test-all.sh`) on macOS arm64, Docker Desktop with 5 CPUs and 8 GB,
on 2026-10-16. Pod names, IPs, serial numbers and timestamps change on every
run; names of Envoy objects, flags, details, counts and messages do not.

### Cluster and sync (step 01)

Istio 1.31.2 deploys distroless images by default (`pilot:1.31.2-distroless`,
`proxyv2:1.31.2-distroless`): there is no shell in `istio-proxy`, only
`pilot-agent`. The sidecar's Envoy reports
`8c7d15f0482424f4eea86580c745976377633b34/1.39.5-dev/Clean/RELEASE/BoringSSL`.

```
$ istioctl proxy-status
NAME                                                     CLUSTER     ISTIOD                   VERSION   SUBSCRIBED TYPES
fraud-check-c44b65c89-d9nnf.payments                     Kubernetes  istiod-779854df95-892r2  1.31.2    5 (CDS,LDS,EDS,RDS,WDS)
...
payments-gateway-istio-6c7785949-5hppc.payments-ingress  Kubernetes  istiod-779854df95-892r2  1.31.2    5 (CDS,LDS,EDS,RDS,WDS)
waypoint-9884b6c86-fmhvf.payments-ambient                Kubernetes  istiod-779854df95-892r2  1.31.2    4 (CDS,LDS,EDS,WDS)
ztunnel-b8zd7.istio-system                               Kubernetes  istiod-779854df95-892r2  1.31.2    2 (WADS,WDS)
```

- 9 proxies connected: 5 sidecars, the gateway, the waypoint (no RDS: its
  routes are inline) and one ztunnel per node (workload types only).
- The default table no longer shows a sync state per type; `-v 1` does
  (`SYNCED (25s)`, `STALE`, `ERROR`, `IGNORED` for types not subscribed).
- istioctl 1.31.2 verifies the istiod certificate: with
  `--authority not-istiod.example` it fails with `transport: authentication
  handshake failed: tls: failed to verify ...`.

### One request, layer by layer (step 02), payments-api -> fraud-check:8080

```
listener 15001  virtualOutbound, useOriginalDst true
                chains: virtualOutbound-blackhole (destination port 15001) -> BlackHoleCluster
                        virtualOutbound-catchall-tcp -> PassthroughCluster
listener        0.0.0.0_8080: Trans: raw_buffer; App: http/1.1,h2c -> Route: 8080 | ALL -> PassthroughCluster
route config    8080, virtual host fraud-check.payments.svc.cluster.local:8080
                domains include fraud-check and fraud-check.payments.svc.cluster.local
                1 route: default, prefix / -> outbound|8080||fraud-check.payments.svc.cluster.local
cluster         outbound|8080||fraud-check.payments.svc.cluster.local, type EDS
endpoints       3 x HEALTHY (the v1 and v2 pod IPs, port 8080)
receiver        virtualInbound (0.0.0.0:15006); chains for port 8080: raw_buffer and tls,
                both named 0.0.0.0_8080, both -> inbound|8080||
                HTTP filters: istio.metadata_exchange, envoy.filters.http.grpc_stats,
                envoy.filters.http.fault, envoy.filters.http.cors, istio.stats, envoy.filters.http.router

caller log    "GET /r17921953105748 HTTP/1.1" 200 flags=- details=via_upstream
              cluster=outbound|8080||fraud-check.payments.svc.cluster.local
              statname=outbound|8080||fraud-check.payments.svc.cluster.local; route=default
              upstream=10.244.1.8:8080 dst=<fraud-check ClusterIP>:8080
receiver log  ... 200 flags=- details=via_upstream cluster=inbound|8080|| route=default
              sni=outbound_.8080_._.fraud-check.payments.svc.cluster.local dst=10.244.1.8:8080
```

`%UPSTREAM_CLUSTER%` ends in `;`: it prints the cluster's `alt_stat_name`,
which istiod sets to the cluster name plus `;` on every cluster. The real
name is `%UPSTREAM_CLUSTER_RAW%` (what Istio's default log format uses), so
this lab logs both, as `cluster=` and `statname=`. Envoy stats use the same
name: `cluster.outbound|8080||fraud-check.payments.svc.cluster.local;.upstream_rq_200`.

### Translation (step 03), objects added (+) and removed (-) in the proxy

```
DestinationRule subsets v1/v2   payments-api  +4 -0  clusters outbound|8080|v1|..., |8080|v2|, |8090|v1|, |8090|v2|
                                              subset v1: 2 endpoints, v2: 1; the route still targets outbound|8080||... (no routing change)
VirtualService canary/stable    payments-api  +2 -1  route 8080 vhost fraud-check...:8080: canary -> |v2|, stable -> |v1| (replaces default)
                                              canary matches header x-canary exact "true"; access log route=canary cluster=...|v2|...
ServiceEntry api.github.com     payments-api  +3 -0  listener 0.0.0.0_443, chain serverNames [api.github.com], cluster outbound|443||api.github.com STRICT_DNS
PeerAuthentication STRICT       fraud-check   +2 -7  inbound chains for 8080 go from 2 (1 plain text) to 1 (tls);
                                                     the plain-text and passthrough chains of virtualInbound disappear
AuthorizationPolicy ALLOW       fraud-check   +3 -3  envoy.filters.http.rbac inserted after istio.metadata_exchange, before the router,
                                                     in virtualInbound and main_internal; policy key ns[payments]-policy[fraud-check-allow]-rule[0]
```

Without a port in the VirtualService, the same canary/stable routes are also
generated for port 8090 and for route config `80` (pointing to
`outbound|80|v1|...`, a cluster that does not exist), and `istioctl analyze`
reports IST0112 (multiple ports, destination without port). The manifest in
`translation/` sets `port: 8080` in the match and the destination.

### Broken by layer (step 04)

```
VS without default route   404, access log: flags=NR details=route_not_found cluster=- ; no fraud-check sidecar saw it
subset v3 (no pods)        cluster outbound|8080|v3|... exists, 0 endpoints
                           503 "no healthy upstream", flags=UH details=no_healthy_upstream route=v3-rollout
                           istioctl x describe pod: "Matching subsets: v1 (Non-matching subsets v2,v3)",
                             "WARNING: No destinations match pod subsets (checked 1 HTTP routes)", "Route to non-matching subset v3 for (Match:)"
                           istioctl analyze: IST0173 "The Subset v3 defined in the DestinationRule does not select any pods.
                             Which may lead to 503 UH (NoHealthyUpstream)."
VS host typo (payment)     accepted and pushed: route config 80, vhost fraud-check.payment.svc.cluster.local:80,
                           all-to-v2 -> outbound|80|v2|... (no such cluster); route config 8080 untouched;
                           12 requests: all route=default, cluster outbound|8080||...; istioctl analyze: nothing about the host
VS with gateways only      in no route config of payments-api nor of the ingress gateway
                           istioctl analyze: IST0101 Referenced gateway not found: "payments-ingress/payments-gateway",
                             IST0132 host not found in Gateway
ALLOW_ANY                  http://example.com -> route=allow_any cluster=PassthroughCluster
REGISTRY_ONLY              catch-all virtual host becomes block_all
                           http://example.com -> 502, flags=- details=direct_response route=block_all cluster=- (no cluster at all)
                           https://www.example.com -> curl exit 35; TCP log flags=UH cluster=BlackHoleCluster sni=www.example.com
                           https://api.github.com/zen (ServiceEntry) -> 200
```

### proxy-status: STALE and ERROR (step 05)

STALE, reproduced by pausing payments-api's Envoy for 60 s (SIGSTOP from an
ephemeral busybox container that targets `istio-proxy`; the image is
distroless) and applying a DestinationRule:

```
$ istioctl proxy-status -v 1      (paused proxy)
CDS STALE (0s)   ECDS IGNORED   EDS STALE (0s)   LDS STALE (0s)   RDS STALE (0s)   WADS IGNORED   WDS IGNORED   WDS SYNCED (9s)
```

Every other proxy acknowledged the same push (SYNCED); after the pause CDS
returned to SYNCED and the subset clusters (2 and 1 endpoints) were there.

ERROR, with `envoyfilter/silent-errors/04-after-router.yaml` (a filter
INSERT_AFTER the router), accepted by the API server and by istiod:

```
LDS ERROR on the 3 fraud-check proxies (CDS, EDS, RDS SYNCED); payments-api LDS SYNCED
errorState.details: Error adding/updating listener(s) virtualInbound: Error: terminal filter named
  envoy.filters.http.router of type envoy.filters.http.router must be the last filter in a http filter chain.
istiod log: warn delta ADS:LDS: ACK ERROR fraud-check-v2-....payments-3 Internal:Error adding/updating listener(s) virtualInbound: ...
pilot_total_xds_rejects{type="lds"}: +3 (one per proxy); Envoy listener_manager.lds.update_rejected: +1
```

- The proxy keeps its previous inbound listener (identical config dump) and
  keeps serving with it.
- While the rejection lasts, a DENY policy applied afterwards never arrives:
  kubectl lists it, `GET /blocked` keeps returning 200, LDS stays ERROR, and
  `istioctl proxy-status <pod>` prints `Clusters Match` / `Listeners Don't Match`.
- After deleting the EnvoyFilter: LDS SYNCED and `GET /blocked` 403.

### Logs, stats and the admin port (step 06)

```
istioctl proxy-config log <pod> --level rbac:debug   rbac: warning -> debug (http stays warning); pod not restarted
debug log   enforced denied, matched policy ns[payments]-policy[fraud-check-deny-blocked]-rule[0]
access log  403 flags=- details=rbac_access_denied_matched_policy[ns[payments]-policy[fraud-check-deny-blocked]-rule[0]] cluster=inbound|8080|| route=default
-r          rbac back to warning

stats (payments-api, proxyStatsMatcher .*fraud-check.*)
  cluster.outbound|8080||fraud-check.payments.svc.cluster.local;.upstream_rq_200: +10 after 10 requests
  cluster.outbound|8080||fraud-check.payments.svc.cluster.local;.membership_healthy: 3   membership_total: 3
  cluster.outbound|8080||risk-score...: no stat at all (not in the matcher); /clusters still lists its host with health_flags
  /clusters for fraud-check: health_flags healthy x3

admin       bootstrap admin address 127.0.0.1:15000; pilot-agent request GET ready -> LIVE
            payments-api -> <fraud-check pod IP>:15000/stats -> 503
            curl: upstream connect error or disconnect/reset before headers. retried and the latest reset reason: remote connection failure
            fraud-check inbound log: 503 flags=URX,UF cluster=InboundPassthroughCluster
              details=upstream_reset_before_response_started{remote_connection_failure|delayed_connect_error:_Connection_refused}
```

After each policy push, connections opened before it keep the replaced
filter chain until Envoy drains it (`listener_manager.total_filter_chains_draining`
> 0). A single request right after the push can still meet the old policy;
the steps wait for that gauge to return to 0 before asserting.

### EnvoyFilter (step 07)

```
no CRD mentions rate limit (Istio 1.31 has no native API for it)
kubectl warns on every EnvoyFilter: "EnvoyFilter exposes internal implementation details that may change at any time. ..."
inbound HTTP filters, port 8080: istio.metadata_exchange, envoy.filters.http.grpc_stats, envoy.filters.http.fault,
  envoy.filters.http.cors, istio.stats, envoy.filters.http.local_ratelimit, envoy.filters.http.router
  (in all 3 fraud-check proxies; not in the 8090 chains; not in outbound listeners)
8 requests to fraud-check v2:8080     200=5 429=3
429                                   header x-local-rate-limit: true, body local_rate_limited
access log                            429 flags=RL details=local_rate_limited cluster=inbound|8080||
stats for 10 requests                 enabled +10, ok +5, rate_limited +5, enforced +5
port 8090                             200=8
```

A typo in a field, `max_tokenz` for `max_tokens` (`ci/testdata/ef-typo-*.yaml`):

```
                       proto type in typed_config                 udpa TypedStruct
istioctl validate      exit 0, warning: can't unmarshal Any       exit 0, only the generic
                       nested proto ...LocalRateLimit: unknown    EnvoyFilter warning
                       field "max_tokenz" in envoy.type.v3.TokenBucket
kubectl apply          created (server dry run), same warning     created (server dry run), no warning
  --dry-run=server     printed by the API server                  about the field
pushed and ACKed       yes, LDS SYNCED on the 3 fraud-check       yes, LDS SYNCED on the 3 fraud-check
token bucket in Envoy  {"tokensPerFill":5,"fillInterval":"60s"}   {"fill_interval":"60s","tokens_per_fill":5}
                       (istiod dropped the field)                 (Envoy ignored it)
Envoy side             nothing: server.dynamic_unknown_fields +0  warning "Unknown field: type ...LocalRateLimit
                                                                  ... no such field: 'max_tokenz'",
                                                                  server.dynamic_unknown_fields +2 (one per chain)
8 requests             429=8                                      429=8
```

Neither form is rejected anywhere. The difference is the warning at
admission: only the proto form names the typo before it ships, which is why
the lab writes typed_config as the proto type and the lint turns that
warning into an error (`EF008`). Either way, a misspelled `max_tokens` leaves
a bucket with no tokens and the filter refuses every request.

### Ambient (step 08)

```
istioctl proxy-config listener <ztunnel pod>
  Error: listener dump: config dump has no configuration type type.googleapis.com/envoy.admin.v3.ListenersConfigDump
ztunnel-config workloads   payments-ambient pods: HBONE; the waypoint: TCP; sidecar pods of payments: HBONE too
                           (their pods carry networking.istio.io/tunnel=http: the sidecar accepts HBONE)
ztunnel-config services    fraud-check  WAYPOINT waypoint  ENDPOINTS 1/1
ztunnel-config certificates   Leaf + Root for the ambient identities of the node, and also for the sidecar
                              identities on that node (payments/fraud-check, payments-api, risk-score)
ztunnel-config policies    empty: the L7 policy (targetRefs Service) is the waypoint's
ztunnel-config connections fraud-check  Inbound  from waypoint-...:<port>  HBONE (a pooled connection);
                           the caller's ztunnel listed no outbound connection, even with a request in flight
waypoint listeners         connect_terminate main_internal connect_originate inner_connect_originate
                           outer_connect_originate 0.0.0.0_15090 0.0.0.0_15021
waypoint                   RBAC filter with ns[payments-ambient]-policy[fraud-check-l7]-rule[0];
                           route with request header x-served-by=waypoint-route (the HTTPRoute);
                           cluster inbound-vip|8080|http|fraud-check.payments-ambient.svc.cluster.local
waypoint access log        GET 200 via_upstream; POST 403 rbac_access_denied_matched_policy[none]
```

### By hand (scripts/by-hand-check.sh)

Run last by `scripts/test-all.sh`, on the lab as steps 01..08 leave it:

```
listener 15001   0.0.0.0 15001 ALL PassthroughCluster | 0.0.0.0 15001 Addr: *:15001 Non-HTTP/Non-TCP
listener 8080    0.0.0.0 8080 Trans: raw_buffer; App: http/1.1,h2c Route: 8080 | 0.0.0.0 8080 ALL PassthroughCluster
route 8080       4 virtual hosts: fraud-check.payments-ambient..., fraud-check.payments..., payments-api..., risk-score... (:8080)
                 fraud-check's: the single route default -> outbound|8080||fraud-check.payments.svc.cluster.local
cluster          fraud-check.payments.svc.cluster.local 8080 and 8090, outbound, EDS, no subset
endpoint         3 x HEALTHY OK outbound|8080||fraud-check.payments.svc.cluster.local
proxy-status -v 1  9 proxies, no STALE/ERROR/NOT SENT; SYNCED types: 5 per sidecar and gateway, 4 waypoint, 2 per ztunnel
rate limit       200 200 200 200 200 429 429 429 (limiter stats: enabled +8, ok +5, enforced +3)
delete           envoyfilter.networking.istio.io "fraud-check-local-ratelimit" deleted from payments namespace
```

While developing the check, re-running the by-hand rate limit within about
three minutes of a previous apply and delete of the same filter gave
`200=7 429=1` twice, with the limiter counting all eight requests
(`enabled +8, ok +7, enforced +1`), so not the draining case. On a fresh
apply it gave `200=5 429=3` every time it was measured.

### Totals

Final run from no cluster (the "By hand" final block: `bash scripts/test-all.sh`
then `bash scripts/teardown.sh`), all steps passed: 43 offline assertions
(`ci/`) + 227 in the lab and by hand = 270, in 750 seconds (step 07 is the
longest, 332 s: it waits for old filter chains to drain before each burst).

## The silent errors

Each one is accepted by the API server and does something other than what it
appears to do; each is reproduced live by step 07 (step 05 for the filter
after the router) and fails `ci/envoyfilter-lint.sh` with its own code.

1. `envoyfilter/silent-errors/01-wrong-context.yaml` (`SIDECAR_OUTBOUND`):
   fraud-check's inbound listener is unchanged and its callers get `200=8`;
   the filter lands in fraud-check's outbound listener `0.0.0.0_8080`, so
   fraud-check's own calls to risk-score:8080 are limited (`200=5 429=3`
   through its 8090 proxy). Lint: `EF007`.
2. `02-wrong-port-15006.yaml` (`portNumber: 15006`): matches nothing, inbound
   listener byte-for-byte unchanged, `200=8`. Lint: `EF005`.
3. `03-deprecated-filter-name.yaml` (`envoy.http_connection_manager`): the API
   server only warns (`using deprecated filter name "envoy.http_connection_manager";
   use "envoy.filters.network.http_connection_manager" instead`); matches
   nothing, `200=8`. Lint: `EF003`.
4. `06-not-enabled.yaml` (no `filter_enabled`/`filter_enforced`): the filter is
   in all 3 proxies, right before the router, and limits nothing (`200=8`).
   Lint: `EF006`.
5. `05-root-namespace-no-selector.yaml` (istio-system, no selector, no
   context): 6 of the 7 Envoys got it, every sidecar and the ingress gateway;
   it patched 17 HTTP connection managers in each fraud-check proxy, 14 in
   payments-api and risk-score, 1 in the gateway, 0 in the waypoint (waypoints
   take EnvoyFilters through `targetRefs` only). Lint: `EF001`, `EF002`, `EF006`.

Not silent at the proxy, silent at the API server:
`04-after-router.yaml` (INSERT_AFTER the router) is accepted by the API server
and by istiod, and rejected by Envoy (NACK, proxy-status `ERROR`). The proxy
keeps its old listener and rejects every later version of it, so policies
applied afterwards never arrive (step 05). Lint: `EF004`.

## EnvoyFilter checks in CI (no cluster)

`ci/envoyfilter-lint.sh` runs a set of static checks on the EnvoyFilters in
the files or directories you give it, then `istioctl analyze
--use-kube=false` on the same files.

```bash
bash ci/envoyfilter-lint.sh envoyfilter/fraud-check-local-ratelimit.yaml
```

Errors (exit 1): `EF001` no workloadSelector or targetRefs (unless annotated
`envoyfilter-lint/allow-wide-scope: "true"`), `EF002` no `match.context`,
`EF003` a deprecated filter name, `EF004` a filter inserted after the router,
`EF005` `portNumber` 15001 or 15006 in a sidecar context, `EF006`
`local_ratelimit` without `filter_enabled`/`filter_enforced`, `EF007`
`local_ratelimit` in `SIDECAR_OUTBOUND`, `EF008` a field the proto does not
have (istiod's "unknown field" warning; visible only when `typed_config` is the
proto type). Warnings: `EF101` a relative
operation without `priority`, `EF102` a `TypedStruct` value, `EF103`
`INSERT_BEFORE`/`INSERT_AFTER` with no `subFilter`.

`ci/test-envoyfilter-lint.sh` proves the lint both ways: the filter of step
07 passes clean, and each file in `envoyfilter/silent-errors/` fails with
exactly its own codes. `ci/test-typedstruct.sh` records what `istioctl
validate` says about the same typo in both forms (below).

`istioctl analyze --use-kube=false` (1.31.2) on its own catches none of the
silent errors above: it repeats the API server warning for the deprecated
filter name (IST0133), and warns IST0151 (relative operation without
`priority`) for the root-namespace filter and for the official task's
filter. It emits IST0133 "EnvoyFilter exposes internal implementation
details" for every EnvoyFilter; the lint does not repeat that line.

For routing, `istioctl analyze -n payments` did flag IST0173 (a subset that
selects no pods), IST0101 and IST0132 (a VirtualService bound to a gateway
that is not an Istio Gateway), and IST0112 (a destination without port on a
multi-port Service); it said nothing about the VirtualService whose host has a
typo.

## Teardown

```bash
bash scripts/teardown.sh         # deletes the kind cluster istio-p4
```

Nothing else is created outside the cluster: the CLIs live in `./bin` and
the logs in `./out`, both gitignored.

## License

MIT, see `LICENSE`.
