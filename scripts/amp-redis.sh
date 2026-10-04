#!/bin/bash
# ============================================================================
# amp-redis.sh — the in-cluster Redis used by the API Platform gateway
# policies, on a running AMP install.
#
# Two policy families can use it:
#
#   semantic-cache        REQUIRES a vector store (REDIS or MILVUS). Its Redis
#                         provider creates a vector index (FT.CREATE … VECTOR)
#                         and runs KNN queries (FT.SEARCH), so it needs the
#                         Redis Query Engine. Redis 8 ships it in the standard
#                         image; redis:7 and Valkey fail at index creation.
#   *-ratelimit           OPTIONAL. backend defaults to memory, which is exact
#                         for a single gateway-runtime replica. Redis is only
#                         needed to share counters across replicas.
#
# Milvus would also satisfy semantic-cache, but brings etcd and MinIO with it;
# Redis is one small pod.
#
# Plain manifests rather than a chart, as for the container registry: nothing
# here needs templating, and no third-party chart repo or image location is
# pulled in. The cache is ephemeral by design — no persistence, and LRU
# eviction once maxmemory is reached.
# ============================================================================
set -euo pipefail

usage() {
    cat <<'HELPEOF'
amp-redis.sh — in-cluster Redis 8 for the gateway policies (semantic cache, rate limits)

USAGE
  ./scripts/amp-redis.sh status                  show what is deployed and reachable
  ./scripts/amp-redis.sh install                 deploy or update Redis (idempotent)
  ./scripts/amp-redis.sh uninstall               delete it (cached entries are lost)
  ./scripts/amp-redis.sh <verb> --yes            skip the confirmation prompt
  ./scripts/amp-redis.sh <verb> --reason "CHG-1234: semantic cache"
                                                 why — recorded in the audit trail
  ./scripts/amp-redis.sh --help                  this message

SETTINGS (environment)
  REDIS_NS          namespace                    default amp-redis
  REDIS_IMAGE       image (needs the Redis       default redis:8.10.2
                    Query Engine: Redis 8+)
  REDIS_MAXMEMORY   cache size before eviction   default 512mb

CONNECTING
  Host      redis.<REDIS_NS>.svc.cluster.local     Port 6379
  Password  Secret redis (key: password) in REDIS_NS — generated on first
            install and kept across re-installs.

  ./scripts/amp-guardrails.sh configure offers this Redis as the semantic
  guardrails vector database and copies the password into the gateway's
  amp-guardrails Secret — no need to type it.

AUDIT TRAIL
  install and uninstall write an immutable record — read it with
  ./scripts/amp-audit.sh. The password is never recorded.
HELPEOF
}

ACTION=""
ASSUME_YES=0
AUDIT_REASON="${AMP_AUDIT_REASON:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        status|install|uninstall) ACTION="$1" ;;
        --yes|-y)                 ASSUME_YES=1 ;;
        --reason)                 [ $# -ge 2 ] || { echo "--reason needs a value" >&2; exit 1; }
                                  AUDIT_REASON="$2"; shift ;;
        -h|--help)                usage; exit 0 ;;
        *)                        echo "Unknown argument: $1" >&2; echo >&2; usage >&2; exit 1 ;;
    esac
    shift
done
[ -z "${ACTION}" ] && { usage; exit 0; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=amp-audit.sh
source "${SCRIPT_DIR}/amp-audit.sh"

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
BOLD='\033[1m'
NC='\033[0m'

STEP=0
ERRORS=0
step()    { STEP=$((STEP+1)); echo -e "\n${BLUE}${BOLD}[Step ${STEP}]${NC} ${BOLD}$1${NC}"; }
info()    { echo -e "  ℹ $1"; }
success() { echo -e "  ${GREEN}✓${NC} $1"; }
warning() { echo -e "  ${YELLOW}⚠${NC} $1"; }
error()   { echo -e "  ${RED}✗${NC} $1"; ERRORS=$((ERRORS+1)); }
die()     { echo -e "  ${RED}✗${NC} $1"; exit 1; }

REDIS_NS="${REDIS_NS:-amp-redis}"
REDIS_IMAGE="${REDIS_IMAGE:-redis:8.10.2}"
REDIS_MAXMEMORY="${REDIS_MAXMEMORY:-512mb}"
REDIS_HOST="redis.${REDIS_NS}.svc.cluster.local"
REDIS_PORT=6379
DATA_PLANE_NS="openchoreo-data-plane"

trap 'audit_on_exit $?' EXIT

# Runs redis-cli inside the Redis pod. The password reaches redis-cli through
# REDISCLI_AUTH, read from the container's own environment — never via argv.
redis_cli() {
    kubectl exec -n "${REDIS_NS}" deploy/redis -c redis -- \
        sh -c 'REDISCLI_AUTH="${REDIS_PASSWORD}" redis-cli "$@"' redis-cli "$@"
}

deployed_image() {
    kubectl get deploy redis -n "${REDIS_NS}" \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true
}

# One-shot pod in a gateway namespace: proves the network path (and DNS) the
# gateway runtime will use. An unauthenticated PING is enough — Redis answers
# NOAUTH, which only a reachable server can do — so no secret leaves REDIS_NS.
probe_from() {
    local ns="$1" out
    out=$(kubectl run "redis-probe-$$" -n "${ns}" --rm -i --restart=Never --quiet \
        --image="${REDIS_IMAGE}" --image-pull-policy=IfNotPresent \
        --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":999}}}' \
        --command -- redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" PING 2>&1 || true)
    echo "${out}" | grep -qE 'NOAUTH|PONG'
}

# ── Pre-flight ───────────────────────────────────────────────────────────────
step "Pre-flight checks"
command -v kubectl &>/dev/null || die "kubectl not found"
kubectl cluster-info &>/dev/null || die "Cannot connect to the Kubernetes cluster"
success "Cluster reachable ($(kubectl config current-context))"

CURRENT_IMAGE=$(deployed_image)
HAVE_SECRET=0
kubectl get secret redis -n "${REDIS_NS}" &>/dev/null && HAVE_SECRET=1

# ── Status ───────────────────────────────────────────────────────────────────
if [ "${ACTION}" = "status" ]; then
    step "Status"
    if [ -z "${CURRENT_IMAGE}" ]; then
        info "Not deployed — ./scripts/amp-redis.sh install"
        exit 0
    fi
    echo "  Endpoint:   ${REDIS_HOST}:${REDIS_PORT}"
    echo "  Image:      ${CURRENT_IMAGE}"
    echo "  Password:   $([ "${HAVE_SECRET}" = "1" ] && echo "Secret ${REDIS_NS}/redis" || echo "MISSING")"
    ready=$(kubectl get deploy redis -n "${REDIS_NS}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
    echo "  Ready:      ${ready:-0}/1"
    if [ "${ready:-0}" = "1" ]; then
        mods=$(redis_cli MODULE LIST 2>/dev/null | awk 'prev=="name"{print} {prev=$0}' | tr '\n' ' ')
        echo "  Modules:    ${mods:-none}"
        echo "  Indexes:    $(redis_cli FT._LIST 2>/dev/null | tr '\n' ' ' || true)"
        echo "  Memory:     $(redis_cli INFO memory 2>/dev/null | sed -nE 's/^used_memory_human:(.*)\r?$/\1/p' | tr -d '\r') of ${REDIS_MAXMEMORY}"
        echo "  Keys:       $(redis_cli DBSIZE 2>/dev/null | tr -d '\r')"
    fi
    exit 0
fi

# ── Uninstall ────────────────────────────────────────────────────────────────
if [ "${ACTION}" = "uninstall" ]; then
    if [ -z "${CURRENT_IMAGE}" ] && ! kubectl get ns "${REDIS_NS}" &>/dev/null; then
        info "Nothing to remove"; exit 0
    fi
    warning "Deletes namespace ${REDIS_NS}: every cached entry and the password Secret."
    warning "semantic-cache policies (and rate limits with backend redis) stop working until it is reinstalled."
    audit_reason
    if [ "${ASSUME_YES}" != "1" ]; then
        [ -t 0 ] || die "stdin is not a terminal — re-run with --yes"
        printf '\n  Uninstall from context %s? [y/N] ' "$(kubectl config current-context)"
        read -r answer </dev/tty || answer=""
        case "${answer}" in [Yy]*) ;; *) info "Aborted — nothing changed"; exit 0 ;; esac
    fi
    audit_begin "redis" "${BASH_SOURCE[0]}"
    AUDIT_SUMMARY_SO_FAR="redis uninstall"
    step "Uninstall"
    kubectl delete namespace "${REDIS_NS}" --wait=true
    success "Namespace ${REDIS_NS} deleted"
    audit_change "${REDIS_NS}/redis" "deployment" "${CURRENT_IMAGE:-—}" "—"
    audit_add notes "The gateway copy of the password (amp-guardrails Secret, key vector_db_provider_password) was left in place."
    audit_add rollback "./scripts/amp-redis.sh install   (a new password is generated — re-run ./scripts/amp-guardrails.sh configure, then apply)"
    audit_commit "success" "redis uninstalled (${CURRENT_IMAGE:-not running})"
    exit 0
fi

# ── Install ──────────────────────────────────────────────────────────────────
step "Plan"
if [ -z "${CURRENT_IMAGE}" ]; then
    info "Deploy ${REDIS_IMAGE} in ${REDIS_NS} (maxmemory ${REDIS_MAXMEMORY}, no persistence)"
elif [ "${CURRENT_IMAGE}" != "${REDIS_IMAGE}" ]; then
    info "Update ${CURRENT_IMAGE} → ${REDIS_IMAGE} — the cache is emptied by the restart"
else
    info "${REDIS_IMAGE} already deployed — manifests re-applied, no restart unless they changed"
fi
if [ "${HAVE_SECRET}" = "1" ]; then
    info "Password: kept (Secret ${REDIS_NS}/redis)"
else
    info "Password: generated into Secret ${REDIS_NS}/redis"
fi

audit_reason
if [ "${ASSUME_YES}" != "1" ]; then
    [ -t 0 ] || die "stdin is not a terminal — re-run with --yes"
    printf '\n  Apply to context %s? [y/N] ' "$(kubectl config current-context)"
    read -r answer </dev/tty || answer=""
    case "${answer}" in [Yy]*) ;; *) info "Aborted — nothing changed"; exit 0 ;; esac
fi

audit_begin "redis" "${BASH_SOURCE[0]}"
AUDIT_SUMMARY_SO_FAR="redis install ${REDIS_IMAGE}"
audit_add settings "REDIS_NS=${REDIS_NS}"
audit_add settings "REDIS_IMAGE=${REDIS_IMAGE}"
audit_add settings "REDIS_MAXMEMORY=${REDIS_MAXMEMORY}"
audit_add settings "endpoint=${REDIS_HOST}:${REDIS_PORT}"

step "Deploy"
kubectl create namespace "${REDIS_NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
if [ "${HAVE_SECRET}" != "1" ]; then
    # Generated straight into the Secret: the value never lands in argv or a file.
    python3 -c 'import secrets,json; print(json.dumps({
        "apiVersion": "v1", "kind": "Secret", "type": "Opaque",
        "metadata": {"name": "redis", "namespace": "'"${REDIS_NS}"'",
                     "labels": {"app.kubernetes.io/managed-by": "amp-redis.sh"}},
        "stringData": {"password": secrets.token_urlsafe(24)}}))' \
        | kubectl apply -f - >/dev/null
    success "Password generated into Secret ${REDIS_NS}/redis"
    audit_change "${REDIS_NS}/redis" "secret" "—" "password generated (value not recorded)"
fi

kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: ${REDIS_NS}
  labels: { app: redis, app.kubernetes.io/managed-by: amp-redis.sh }
spec:
  replicas: 1
  # One instance: the vector index and the counters live in its memory.
  strategy: { type: Recreate }
  selector:
    matchLabels: { app: redis }
  template:
    metadata:
      labels: { app: redis }
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 999
        runAsGroup: 999
        fsGroup: 999
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: redis
          image: ${REDIS_IMAGE}
          imagePullPolicy: IfNotPresent
          # The password is fed as config on stdin ("redis-server -"), so it
          # is not in argv, where ps and the pod spec would show it. A heredoc
          # rather than a pipe: exec then makes redis-server PID 1, and it gets
          # SIGTERM directly instead of waiting out the grace period. Through
          # the image's docker-entrypoint.sh, because that is what adds the
          # --loadmodule flags (search, ReJSON, …); calling redis-server
          # directly starts it without the Query Engine.
          # No persistence: this is a cache, and rate-limit windows are
          # short-lived. allkeys-lru keeps it bounded.
          command: ["sh", "-c"]
          args:
            - |
              exec docker-entrypoint.sh redis-server - --save '' --appendonly no \
                --maxmemory ${REDIS_MAXMEMORY} --maxmemory-policy allkeys-lru \
                --protected-mode no <<CONF
              requirepass \${REDIS_PASSWORD}
              CONF
          env:
            - name: REDIS_PASSWORD
              valueFrom:
                secretKeyRef: { name: redis, key: password }
          ports:
            - { name: redis, containerPort: 6379 }
          readinessProbe:
            exec:
              command: ["sh", "-c", 'REDISCLI_AUTH="\${REDIS_PASSWORD}" redis-cli PING | grep -q PONG']
            initialDelaySeconds: 3
            periodSeconds: 10
          livenessProbe:
            exec:
              command: ["sh", "-c", 'REDISCLI_AUTH="\${REDIS_PASSWORD}" redis-cli PING | grep -q PONG']
            initialDelaySeconds: 15
            periodSeconds: 20
          resources:
            requests: { cpu: 50m, memory: 128Mi }
            limits: { memory: 1Gi }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          volumeMounts:
            - { name: data, mountPath: /data }
            - { name: tmp, mountPath: /tmp }
      volumes:
        - name: data
          emptyDir: {}
        - name: tmp
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: ${REDIS_NS}
  labels: { app: redis, app.kubernetes.io/managed-by: amp-redis.sh }
spec:
  selector: { app: redis }
  ports:
    - { name: redis, port: ${REDIS_PORT}, targetPort: redis }
EOF
kubectl rollout status deployment/redis -n "${REDIS_NS}" --timeout=300s
NEW_IMAGE=$(deployed_image)
audit_change "${REDIS_NS}/redis" "deployment" "${CURRENT_IMAGE:-—}" "${NEW_IMAGE}"

step "Verify"
if redis_cli MODULE LIST 2>/dev/null | grep -qx search; then
    success "Redis Query Engine loaded (vector search available)"
else
    error "Redis Query Engine ('search' module) not loaded from ${NEW_IMAGE} — semantic-cache will fail at FT.CREATE (needs Redis 8+, started through its entrypoint)"
fi
# The same calls semantic-cache makes, on a throwaway index.
probe_idx="amp-redis-probe-$$"
if redis_cli FT.CREATE "${probe_idx}" ON HASH PREFIX 1 "${probe_idx}:" \
        SCHEMA v VECTOR HNSW 6 TYPE FLOAT32 DIM 2 DISTANCE_METRIC COSINE 2>&1 | grep -q '^OK'; then
    success "Vector index create/drop works"
else
    error "FT.CREATE with a VECTOR field failed"
fi
redis_cli FT.DROPINDEX "${probe_idx}" >/dev/null 2>&1 || true

for ns in $(kubectl get apigateway -A -o jsonpath='{.items[*].metadata.namespace}' 2>/dev/null | tr ' ' '\n' | sort -u); do
    if probe_from "${ns}"; then
        success "Reachable from gateway namespace ${ns}"
        audit_add notes "Reachable from gateway namespace ${ns}"
    else
        error "Not reachable from gateway namespace ${ns} — check NetworkPolicies and DNS"
    fi
done

audit_add rollback "./scripts/amp-redis.sh uninstall --reason \"…\""
[ -n "${CURRENT_IMAGE}" ] && [ "${CURRENT_IMAGE}" != "${NEW_IMAGE}" ] \
    && audit_add rollback "REDIS_IMAGE=${CURRENT_IMAGE} ./scripts/amp-redis.sh install --reason \"…\""

echo
echo -e "  ${BOLD}Endpoint:${NC}  ${REDIS_HOST}:${REDIS_PORT}"
echo -e "  ${BOLD}Password:${NC}  Secret ${REDIS_NS}/redis, key password"
echo -e "  Semantic cache: ${BOLD}./scripts/amp-guardrails.sh configure${NC} → Semantic guardrails → vector database REDIS"

if [ "${ERRORS}" -gt 0 ]; then
    audit_commit "with-errors" "redis ${NEW_IMAGE} at ${REDIS_HOST} — ${ERRORS} problem(s)"
    exit 1
fi
audit_commit "success" "redis ${NEW_IMAGE} at ${REDIS_HOST}"
