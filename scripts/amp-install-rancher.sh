#!/bin/bash
# ============================================================================
# WSO2 Agent Manager v1.0.0-rc3 - Automated Installation Script
#
# Mirrors https://wso2.github.io/agent-manager/docs/v1.0.0-rc3/guides/on-your-environment/
# (source: documentation/docs/guides/on-your-environment.mdx plus the Phase 2
#  partial _partials/_amp-installation.mdx, on branch amp-1.0.0-rc3)
#
# Two profiles:
#   local  Rancher Desktop (k3s) on macOS, fully usable with no Internet
#          connection after install. HTTPS on high ports (8443/19443/11085)
#          behind a self-signed CA — the consoles need a secure context, see
#          the profile block below. Hostnames resolve via /etc/hosts on the Mac
#          and a coredns-custom rewrite in-cluster.
#   cloud  A real cluster with real DNS and TLS (EKS/GKE/AKS/DigitalOcean).
#          Follows the RC3 main flow.
#
# The two cannot share one deployment: Thunder's issuer and the API gateway's
# vhost are written once at first install and are never reconciled afterwards,
# so a cluster installed under one profile cannot be migrated to the other
# without discarding Thunder's data. Pick before the first run.
# ============================================================================
set -euo pipefail

# ============================================================================
# ARGUMENTS
# ============================================================================
# Configuration is by environment variable, not flags — but the script has to
# answer --help, and it has to reject anything it does not understand. Without
# this, `./amp-install-rancher.sh --help` silently begins a 40-minute install
# of a full platform, which is exactly what someone types first.
usage() {
    # Delimiter is HELPEOF, not USAGE: "USAGE" is a section heading in the body
    # below, and bash would end the heredoc there and parse the rest as code.
    cat <<'HELPEOF'
amp-install-rancher.sh — install WSO2 Agent Manager v1.0.0-rc3

USAGE
  ./scripts/amp-install-rancher.sh install       run the install
  ./scripts/amp-install-rancher.sh install --yes skip the confirmation prompt
  ./scripts/amp-install-rancher.sh --help        this message
  ./scripts/amp-install-rancher.sh               this message

  The `install` verb is required: a bare invocation prints this help rather
  than installing, so nothing starts by accident against the wrong cluster.
  After pre-flight the installer shows the target context and waits for
  confirmation; --yes skips that, and is required when stdin is not a terminal.

  Everything else is configured through the environment variables below. The
  script is idempotent: re-running it after a failure resumes rather than
  starting over.

PROFILE
  PROFILE=local                 (default, and the only supported profile)
                                Rancher Desktop / k3s on macOS. HTTPS on high
                                ports behind a self-signed CA. Works offline
                                once installed.
  PROFILE=cloud                 NOT SUPPORTED — never verified end to end.
                                Refuses to run without ALLOW_UNTESTED_CLOUD=1.

COMMON
  BASE_DOMAIN                   default amp.test (local) / amp.apis.coach (cloud)
  TLS_MODE                      selfsigned (default) | acme-dns01 | existing
  OPENCHOREO_VERSION            default 1.2.1

TLS (when TLS_MODE is not selfsigned)
  TLS_ISSUER_NAME               ClusterIssuer name for TLS_MODE=existing
  TLS_ACME_SOLVER_FILE          DNS-01 solver stanza for TLS_MODE=acme-dns01
  ACME_EMAIL                    contact address for Let's Encrypt

REGISTRY
  DEPLOY_REGISTRY               true on local, false on cloud
  REGISTRY_ENDPOINT             host:port builds push to; required on cloud
  REGISTRY_HOST / REGISTRY_PORT components of the default endpoint
  REGISTRY_TLS_VERIFY           false on local, true on cloud

PRE-FLIGHT
  SKIP_LB_PROBE=1               skip the LoadBalancer provisioning check
  LB_PROBE_TIMEOUT              default 180s

ESCAPE HATCHES (each disables a guard — read the message it prints first)
  ALLOW_UNTESTED_CLOUD=1        run the unverified cloud profile
  ALLOW_SELFSIGNED_CLOUD=1      allow a self-signed CA on the cloud profile

EXAMPLES
  ./scripts/amp-install-rancher.sh install
  BASE_DOMAIN=amp.example.com ./scripts/amp-install-rancher.sh install
  TLS_MODE=acme-dns01 ACME_EMAIL=you@example.com \
    TLS_ACME_SOLVER_FILE=./solver.yaml ./scripts/amp-install-rancher.sh install

SEE ALSO
  scripts/amp-hosts.sh              /etc/hosts entries for the local profile
  scripts/amp-uninstall-rancher.sh  full teardown (destroys OpenBao data)
  README.md                         profiles, TLS options, known issues
HELPEOF
}

# Installing requires the explicit `install` verb. A bare invocation prints the
# help and exits 0 — it must not begin a 40-minute install of a full platform
# into whatever cluster the current kubeconfig happens to point at. The verb is
# the first of two deliberate actions; the second is the confirmation after
# pre-flight, which is where the target cluster is actually shown.
ASSUME_YES=0
ACTION=""
while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h|help) usage; exit 0 ;;
        --yes|-y)       ASSUME_YES=1 ;;
        install)        ACTION="install" ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "" >&2
            echo "This installer takes no flags beyond --yes — it is configured with" >&2
            echo "environment variables. Run with --help to see them." >&2
            exit 1
            ;;
    esac
    shift
done
if [ -z "${ACTION}" ]; then
    usage
    exit 0
fi

# ============================================================================
# CONFIGURATION
# ============================================================================
export PROFILE="${PROFILE:-local}"
export VERSION="1.0.0-rc3"
export HELM_CHART_REGISTRY="ghcr.io/wso2"

# OpenChoreo plane charts (control / data / workflow / observability).
#
# DELIBERATELY NOT 1.1.1, which is what the RC2 install guide pins. That guide
# is internally inconsistent: the RC2 platform-resources extension creates
# ProjectType and ProjectReleaseBinding CRs, and those CRDs do not exist until
# openchoreo 1.2.0 — 1.1.1 ships 32 CRDs with neither, 1.2.x ships 36 with
# both. Installing against 1.1.1 fails at the Platform Resources step with:
#
#   no matches for kind "ProjectReleaseBinding" in version "openchoreo.dev/v1alpha1"
#   no matches for kind "ProjectType" in version "openchoreo.dev/v1alpha1"
#
# The extension chart states the requirement itself ("OpenChoreo 1.2.0+ makes
# Project.spec.type a required reference to a (Cluster)ProjectType"), and RC2's
# own values-op.yaml carries "OpenChoreo 1.2.0+" comments — so 1.2.x is the
# intended target and the guide's 1.1.1 is stale. There is no way to opt out:
# the chart exposes only displayName/description for projectType, and the name
# is "deliberately not configurable — a contract with the service".
#
# 1.2.1 rather than 1.2.0 or the newest (1.2.3) because it is the version the
# OpenChoreo k3d single-cluster quick-start runs, i.e. an exercised pairing.
# Every value this script sets was checked against 1.2.1 and still exists.
export OPENCHOREO_VERSION="${OPENCHOREO_VERSION:-1.2.1}"
export AMP_NS="wso2-amp"
export BUILD_CI_NS="openchoreo-workflow-plane"
export OBSERVABILITY_NS="openchoreo-observability-plane"
export DEFAULT_NS="default"
export DATA_PLANE_NS="openchoreo-data-plane"
export THUNDER_NS="amp-thunder"

# How the wildcard certificates for *.${BASE_DOMAIN} and *.${AGENTS_DOMAIN}
# are issued. RC2 requires wildcards (per-environment Thunder hostnames are
# created after install with unguessable handles and are reachable only
# through *.${BASE_DOMAIN}), which rules out HTTP-01 entirely.
#
#   selfsigned   cert-manager self-signed CA chain under the name
#                'openchoreo-ca'. No DNS credentials, works anywhere, browsers
#                warn on every hostname.
#   acme-dns01   Let's Encrypt via DNS-01. Provider-agnostic: supply the
#                solver stanza yourself in ${TLS_ACME_SOLVER_FILE} (see
#                README) plus ${ACME_EMAIL}. Deliberately not tied to any one
#                DNS provider — apis.coach is hosted on GoDaddy, for which
#                cert-manager ships no built-in solver, so the workable routes
#                are a delegated subdomain or an acme-dns CNAME.
#   existing     Use a ClusterIssuer you created yourself, named by
#                ${TLS_ISSUER_NAME}. Escape hatch for a corporate CA.
export TLS_MODE="${TLS_MODE:-selfsigned}"
export TLS_ISSUER_NAME="${TLS_ISSUER_NAME:-openchoreo-ca}"
export TLS_ACME_SOLVER_FILE="${TLS_ACME_SOLVER_FILE:-}"
export ACME_EMAIL="${ACME_EMAIL:-}"

case "${PROFILE}" in
  local)
    # ---- Rancher Desktop / k3s, offline-capable -----------------------------
    # HTTPS, on non-standard ports.
    #
    # HTTPS is not cosmetic here. Two browser APIs the consoles depend on are
    # gated to secure contexts and are therefore simply absent over plain HTTP
    # on a non-localhost origin:
    #   SubtleCrypto    the Thunder console verifies the ID token's signature
    #                   with crypto.subtle.verify. Without it a valid token is
    #                   discarded and sign-in redirects in a silent loop while
    #                   every server-side request returns 200.
    #   Clipboard API   navigator.clipboard.writeText backs every copy button
    #                   in the AMP console. Without it they do nothing.
    # Both failures are invisible server-side, which makes them expensive to
    # diagnose. (The AMP console survives the first one only because it sets
    # tokenValidation.idToken.validate=false; it cannot dodge the second.)
    #
    # The PORT is irrelevant to a secure context — only the https scheme is —
    # so all three planes keep their high ports and nothing has to bind 80/443
    # on the Mac. values-dp.yaml and values-op.yaml pin the data plane to
    # 19080/19443 and the observability plane to 11080/11085; the control plane
    # takes 8080/8443.
    #
    # The one component that does assume TLS means 443 is env-Thunder:
    # thunder_issuer() in RC2's thunder-naming.sh emits https://<host> with no
    # port, and add-environment-thunder.sh pins gate_client_port=443 to match.
    # Neither is overridable, so Step 22 patches both in the copies it
    # downloads — see PATCH_RC2_THUNDER_PORT there.
    #
    # Certificates come from the self-signed openchoreo-ca chain, so that CA
    # must be trusted on this Mac. The summary prints the command.
    # amp.test, not a domain anyone owns. `.test` is reserved by RFC 2606 and
    # RFC 6761 and is guaranteed never to be delegated in the global DNS, so it
    # cannot collide with a real name and nobody has to register anything. This
    # profile resolves it entirely locally — /etc/hosts on the Mac, a
    # coredns-custom rewrite in the cluster — so a domain that does not exist in
    # public DNS costs nothing here.
    #
    # The trade-off is certificates: Let's Encrypt cannot issue for .test (there
    # is no zone to run a DNS-01 challenge in), so this profile is self-signed
    # only and the CA has to be trusted once per machine. To get publicly
    # trusted certs locally, override with a domain you actually control:
    #   BASE_DOMAIN=local.example.com TLS_MODE=acme-dns01 ...
    #
    # Avoid .local (mDNS/Bonjour on macOS) and .localhost (macOS does not
    # resolve multi-label .localhost names at all — see the README).
    export BASE_DOMAIN="${BASE_DOMAIN:-amp.test}"
    export SCHEME="https"
    export TLS_ENABLED_FLAG="true"
    export CP_GW_HTTP_PORT=8080
    export CP_GW_HTTPS_PORT=8443
    export DP_GW_HTTP_PORT=19080
    export DP_GW_HTTPS_PORT=19443
    export OBS_GW_HTTP_PORT=11080
    export OBS_GW_HTTPS_PORT=11085
    # Deploy CNCF Distribution in-cluster: this cluster has no registry, and
    # RC2's chart default (host.k3d.internal:10082) does not resolve here.
    export DEPLOY_REGISTRY="${DEPLOY_REGISTRY:-true}"
    ;;
  cloud)
    # ---- Real cluster, real DNS, real TLS ------------------------------------
    #
    # NOT YET TESTED — this profile refuses to run.
    #
    # Everything below is kept and maintained, but no end-to-end install has
    # ever completed on a managed cluster, so it is disabled rather than
    # offered. The gap is not cosmetic: this profile changes the base domain,
    # all six gateway ports, the TLS issuer, the registry and the secret
    # generation, and a half-working run reconfigures a cluster in place rather
    # than failing cleanly. Enable it only against a cluster you can discard.
    #
    #   ALLOW_UNTESTED_CLOUD=1 PROFILE=cloud ./amp-install-rancher.sh
    #
    # Remove this block once a full run has been verified end to end.
    if [ "${ALLOW_UNTESTED_CLOUD:-0}" != "1" ]; then
        echo "" >&2
        echo "PROFILE=cloud is not supported yet — it has never been verified end to end." >&2
        echo "" >&2
        echo "  This installer is currently proven on the 'local' profile only" >&2
        echo "  (Rancher Desktop / k3s on macOS), which is the default:" >&2
        echo "" >&2
        echo "      ./scripts/amp-install-rancher.sh" >&2
        echo "" >&2
        echo "  The cloud path is written but untested. It rewrites hostnames, all six" >&2
        echo "  gateway ports, TLS and the registry, so a partial run leaves a cluster" >&2
        echo "  in a mixed state rather than stopping cleanly. To try it anyway, on a" >&2
        echo "  cluster you are willing to throw away:" >&2
        echo "" >&2
        echo "      ALLOW_UNTESTED_CLOUD=1 PROFILE=cloud ./scripts/amp-install-rancher.sh" >&2
        echo "" >&2
        exit 1
    fi
    echo "WARNING: PROFILE=cloud is untested. Proceeding because ALLOW_UNTESTED_CLOUD=1." >&2
    echo "         Do not run this against a cluster you cannot discard." >&2
    #
    # Each plane gets its own LoadBalancer address, so every gateway owns the
    # standard ports. RC2 is explicit that the httpPort/httpsPort overrides
    # below are REQUIRED here: values-dp.yaml/values-op.yaml otherwise leave
    # the k3d ports in place and every published URL points at a port with
    # nothing behind it, with no error anywhere.
    export BASE_DOMAIN="${BASE_DOMAIN:-amp.apis.coach}"
    export SCHEME="https"
    export TLS_ENABLED_FLAG="true"
    export CP_GW_HTTP_PORT=80
    export CP_GW_HTTPS_PORT=443
    export DP_GW_HTTP_PORT=80
    export DP_GW_HTTPS_PORT=443
    export OBS_GW_HTTP_PORT=80
    export OBS_GW_HTTPS_PORT=443
    export DEPLOY_REGISTRY="${DEPLOY_REGISTRY:-false}"
    ;;
  *)
    echo "Unknown PROFILE '${PROFILE}' — expected 'local' or 'cloud'" >&2
    exit 1
    ;;
esac

# Hostnames. RC2's certificates are single-level wildcards (*.${BASE_DOMAIN}),
# so every management hostname must sit DIRECTLY under the base domain — no
# second-level names like api.amp.<base>.
export CONSOLE_PUBLIC_HOST="console.${BASE_DOMAIN}"
export API_PUBLIC_HOST="api-amp.${BASE_DOMAIN}"
export THUNDER_PUBLIC_HOST="thunder.${BASE_DOMAIN}"
export CP_GW_PUBLIC_HOST="cp.${BASE_DOMAIN}"
export OBS_API_PUBLIC_HOST="traces.${BASE_DOMAIN}"
export AGENTS_DOMAIN="agents.${BASE_DOMAIN}"

# port_suffix PORT -> ":PORT", or "" when it is the default for ${SCHEME}.
# Keeps https://console.amp.apis.coach clean while still producing
# http://console.amp.test:8080 for the local profile.
port_suffix() {
    local p="$1"
    if { [ "${SCHEME}" = "https" ] && [ "${p}" = "443" ]; } \
    || { [ "${SCHEME}" = "http" ]  && [ "${p}" = "80"  ]; }; then
        printf ''
    else
        printf ':%s' "${p}"
    fi
}
CP_PORT="$(port_suffix "$([ "${SCHEME}" = "https" ] && echo "${CP_GW_HTTPS_PORT}" || echo "${CP_GW_HTTP_PORT}")")"
OBS_PORT="$(port_suffix "$([ "${SCHEME}" = "https" ] && echo "${OBS_GW_HTTPS_PORT}" || echo "${OBS_GW_HTTP_PORT}")")"
DP_PORT="$(port_suffix "$([ "${SCHEME}" = "https" ] && echo "${DP_GW_HTTPS_PORT}" || echo "${DP_GW_HTTP_PORT}")")"

export CONSOLE_PUBLIC_URL="${SCHEME}://${CONSOLE_PUBLIC_HOST}${CP_PORT}"
export API_PUBLIC_URL="${SCHEME}://${API_PUBLIC_HOST}${CP_PORT}"
export THUNDER_PUBLIC_URL="${SCHEME}://${THUNDER_PUBLIC_HOST}${CP_PORT}"
export CP_GW_PUBLIC_URL="${SCHEME}://${CP_GW_PUBLIC_HOST}${CP_PORT}"
export OBS_API_PUBLIC_URL="${SCHEME}://${OBS_API_PUBLIC_HOST}${OBS_PORT}"

# In-cluster URL backend services use for Thunder JWKS/token calls. Always
# plain HTTP against the Service — never routed through a gateway, so it is
# unaffected by the TLS mode.
export THUNDER_INTERNAL_URL="http://amp-thunder-extension-service.${THUNDER_NS}.svc.cluster.local:8090"

# OpenChoreo API, likewise in-cluster.
export OPENCHOREO_API_URL="http://openchoreo-api.openchoreo-control-plane.svc.cluster.local:8080"
export OPENCHOREO_API_HOST="openchoreo-api.openchoreo-control-plane.svc.cluster.local"

# Trace-export endpoint shown to agent developers. The API Platform Gateway
# extension's own <release>-otel-restapi already serves /otel on the gateway's
# registered hostname, so no extra HTTPRoute is needed — this simply has to
# match the gateway.hostname/vhost registered in the gateway extension step.
export AGENTS_GW_HOST="default-default.${AGENTS_DOMAIN}"
export INSTRUMENTATION_URL="${SCHEME}://${AGENTS_GW_HOST}${DP_PORT}/otel"

# Container registry used by build workflows to push agent images. RC2
# requires a registry that creates repositories on push (each build pushes a
# uniquely-named <workflow-run>-image) and that uses static credentials —
# which rules out ECR. CNCF Distribution satisfies both.
#
# THE ENDPOINT HAS TO WORK FROM TWO DIFFERENT PLACES, and it is a single
# string baked into the image reference, so it cannot differ between them:
#
#   * the build pod, which PUSHES. Resolves via CoreDNS.
#   * the node's container runtime, which PULLS. On Rancher Desktop that is
#     dockerd, which does NOT use CoreDNS — a *.svc.cluster.local endpoint is
#     NXDOMAIN there, so the pull fails on DNS before TLS is ever considered.
#
# Hence a NodePort whose Service port and nodePort are the SAME number, under
# a hostname resolved differently on each side: CoreDNS sends pods to the
# Service, and the VM's /etc/hosts sends the node to 127.0.0.1.
#
# The registry serves plain HTTP, so dockerd must also be told the endpoint is
# insecure. Pointing the name at 127.0.0.1 is NOT sufficient on its own — that
# was tested and rejected: docker matches insecure-registries on the hostname
# string rather than on the resolved address, so a name resolving into
# 127.0.0.0/8 still gets "http: server gave HTTP response to HTTPS client".
# The entry has to be in /etc/docker/daemon.json — but it does NOT require a
# restart, because insecure-registries is one of the options dockerd
# live-reloads on SIGHUP (verified: docker info lists it and the pull switches
# to HTTP immediately).
#
# (k3s's /etc/rancher/k3s/registries.yaml is deliberately NOT used: that
# configures containerd, and this node runs docker as its CRI — confirmed via
# node .status.nodeInfo.containerRuntimeVersion — so the file is never read.)
export REGISTRY_NS="${BUILD_CI_NS}"
export REGISTRY_PORT="${REGISTRY_PORT:-30500}"
export REGISTRY_HOST="${REGISTRY_HOST:-registry.${BASE_DOMAIN}}"
export REGISTRY_ENDPOINT="${REGISTRY_ENDPOINT:-${REGISTRY_HOST}:${REGISTRY_PORT}}"

# tlsVerify=false suits the in-cluster evaluation registry (plain HTTP, no auth)
# and is wrong for anything real, so the cloud profile flips the default. Both
# stay overridable.
if [ "${PROFILE}" = "cloud" ]; then
    export REGISTRY_TLS_VERIFY="${REGISTRY_TLS_VERIFY:-true}"
else
    export REGISTRY_TLS_VERIFY="${REGISTRY_TLS_VERIFY:-false}"
fi

# ---- Platform secrets --------------------------------------------------------
# RC2 generates real secrets for the platform's internal OAuth clients, which
# assumes a sealed OpenBao seeded explicitly. Step 5 now runs exactly that (see
# scripts/openbao-values.yaml), so both profiles seed and then READ BACK from
# OpenBao — whatever is already stored wins.
#
# That read-back is what keeps the two sides consistent. Thunder is configured
# with these values in Step 7 while every other consumer reads them from
# OpenBao at runtime, so if a re-install were to generate fresh secrets while
# OpenBao kept the originals, the mismatch would stay invisible until the first
# agent build, which fails at workload-publish with a 401 invalid_client that
# never reaches the build log.
#
# local: fixed placeholders. Nothing here is reachable from outside the laptop,
#        and stable values make a reinstall reproducible and the logs readable.
# cloud: generated per install.
#
# The local profile could now generate real secrets too — the reason it did not
# (dev-mode OpenBao forgot them on every restart) no longer applies. Left as
# placeholders deliberately, so this change is about durability alone.
if [ "${PROFILE}" = "cloud" ]; then
    export AMP_API_CLIENT_SECRET="${AMP_API_CLIENT_SECRET:-$(openssl rand -hex 32)}"
    export AMP_SYSTEM_CLIENT_SECRET="${AMP_SYSTEM_CLIENT_SECRET:-$(openssl rand -hex 32)}"
    export AMP_PUBLISHER_CLIENT_SECRET="${AMP_PUBLISHER_CLIENT_SECRET:-$(openssl rand -hex 32)}"
    export AM_OBSERVER_CLIENT_SECRET="${AM_OBSERVER_CLIENT_SECRET:-$(openssl rand -hex 32)}"
    export WORKFLOW_PUBLISHER_SECRET="${WORKFLOW_PUBLISHER_SECRET:-$(openssl rand -hex 32)}"
    export OBSERVER_READER_SECRET="${OBSERVER_READER_SECRET:-$(openssl rand -hex 32)}"
    export OPENSEARCH_USERNAME="${OPENSEARCH_USERNAME:-admin}"
    export OPENSEARCH_PASSWORD="${OPENSEARCH_PASSWORD:-$(openssl rand -base64 24)}"
else
    # The same placeholder values RC2's own values-openbao.yaml uses. Kept
    # identical so this profile stays comparable with the upstream quick-start;
    # Step 5 seeds them and reads them back, so these are only the defaults for
    # a store that does not have them yet.
    export AMP_API_CLIENT_SECRET="amp-api-client-secret"
    export AMP_SYSTEM_CLIENT_SECRET="amp-system-client-secret"
    export AMP_PUBLISHER_CLIENT_SECRET="amp-publisher-client-secret"
    export AM_OBSERVER_CLIENT_SECRET="am-observer-client-secret"
    export WORKFLOW_PUBLISHER_SECRET="openchoreo-workload-publisher-secret"
    export OBSERVER_READER_SECRET="openchoreo-observer-resource-reader-client-secret"
    export OPENSEARCH_USERNAME="admin"
    export OPENSEARCH_PASSWORD=""   # read back from OpenBao after it starts
fi
# ============================================================================
# COLORS & HELPERS
# ============================================================================
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

# The DNS records a cloud install has to publish, with the LoadBalancer address
# each one points at, read live from the three plane gateways.
#
# A function rather than inline in the summary because it is needed at THREE
# points and the summary is the least useful of them: the cloud profile cannot
# reach the summary until env-Thunder has been provisioned, and that step
# hard-exits when the hostnames do not resolve. Printing this only at the end
# meant a first cloud run died telling the operator to publish records it had
# never shown them the addresses for.
#
# Safe to call before the addresses exist — an unprovisioned gateway prints
# <pending> rather than failing.
print_dns_records() {
    echo ""
    echo -e "${BOLD}DNS records to publish:${NC}"
    local entry ns rec addr
    for entry in "openchoreo-control-plane|*.${BASE_DOMAIN}" \
                 "openchoreo-observability-plane|${OBS_API_PUBLIC_HOST}" \
                 "openchoreo-data-plane|${AGENTS_DOMAIN} and *.${AGENTS_DOMAIN}"; do
        ns="${entry%%|*}"; rec="${entry#*|}"
        addr=$(kubectl get svc gateway-default -n "${ns}" \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
        printf '  %-40s -> %s\n' "${rec}" "${addr:-<pending>}"
    done
    echo "  The *.${BASE_DOMAIN} wildcard is required, not a convenience: per-environment"
    echo "  Thunder hostnames are created after install and are reachable only through it."
}

wait_for() {
    local desc="$1"; shift
    info "Waiting for: ${desc}..."
    # Retry up to 3 times to handle cases where pods haven't been scheduled yet
    local attempt=0
    while [ $attempt -lt 3 ]; do
        if "$@" 2>/dev/null; then
            success "${desc} — Ready"
            return 0
        fi
        attempt=$((attempt + 1))
        [ $attempt -lt 3 ] && { warning "Not ready yet, retrying (${attempt}/3)..."; sleep 5; }
    done
    error "${desc} — FAILED (check with: kubectl get pods -A)"
    return 1
}

check_helm_release() {
    local name="$1" ns="$2"
    local status
    status=$(helm status "${name}" -n "${ns}" -o json 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("info",{}).get("status",""))' 2>/dev/null || echo "")
    if [ "${status}" = "deployed" ]; then
        warning "Helm release '${name}' already deployed in namespace '${ns}' — skipping install"
        return 0
    elif [ -n "${status}" ]; then
        warning "Helm release '${name}' exists in namespace '${ns}' with status '${status}' — retrying install"
        return 1
    fi
    return 1
}

verify_pods() {
    local ns="$1"
    local not_ready
    not_ready=$(kubectl get pods -n "${ns}" --no-headers 2>/dev/null         | { grep -v -E 'Running|Completed' || true; } | wc -l | tr -d ' ')
    if [ "${not_ready}" -eq 0 ]; then
        success "All pods in ${ns} are Running/Completed"
    else
        warning "${not_ready} pod(s) in ${ns} not yet Running:"
        kubectl get pods -n "${ns}" --no-headers | { grep -v -E 'Running|Completed' || true; }
    fi
}

# Retries a helm command that can transiently fail while the Control Plane's
# own admission webhook (controller-manager-webhook-service) has no endpoints
# yet — e.g. "failed calling webhook ... no endpoints available for service".
# The chart applies webhook-validated CRs (ClusterAuthzRoleBinding) in the same
# apply as the controller-manager Deployment, so the very first apply can race
# the webhook's pod becoming ready. Retrying a few times, with a wait for
# deployments in between, gives it time to catch up.
retry_helm() {
    local desc="$1"; shift
    local attempt=0
    local max_attempts=6
    local err_log
    err_log=$(mktemp)
    until "$@" 2>"${err_log}"; do
        attempt=$((attempt+1))
        if [ ${attempt} -ge ${max_attempts} ]; then
            error "${desc} — FAILED after ${max_attempts} attempts"
            cat "${err_log}" >&2
            rm -f "${err_log}"
            return 1
        fi
        if grep -q "no endpoints available for service" "${err_log}"; then
            warning "${desc}: Control Plane webhook not ready yet — retrying in 15s (attempt ${attempt}/${max_attempts})..."
        else
            warning "${desc}: helm command failed — retrying in 15s (attempt ${attempt}/${max_attempts})..."
        fi
        sleep 15
        kubectl wait --for=condition=Available deployment --all \
            -n openchoreo-control-plane --timeout=120s 2>/dev/null || true
    done
    rm -f "${err_log}"
    success "${desc} succeeded"
}

# Generic retry wrapper for commands that can fail while some other resource
# is still propagating/syncing elsewhere in the cluster (e.g. a newly created
# Environment CR that OpenChoreo/Agent Manager hasn't picked up yet). Unlike
# retry_helm, this doesn't assume anything about the Control Plane namespace.
retry_cmd() {
    local desc="$1" max_attempts="$2" delay="$3"; shift 3
    local attempt=0
    local err_log
    err_log=$(mktemp)
    until "$@" 2>"${err_log}"; do
        attempt=$((attempt+1))
        if [ ${attempt} -ge ${max_attempts} ]; then
            error "${desc} — FAILED after ${max_attempts} attempts"
            cat "${err_log}" >&2
            rm -f "${err_log}"
            return 1
        fi
        warning "${desc}: failed (attempt ${attempt}/${max_attempts}) — retrying in ${delay}s..."
        sleep "${delay}"
    done
    rm -f "${err_log}"
    success "${desc} succeeded"
}

# ============================================================================
# PRE-FLIGHT CHECKS
# ============================================================================
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     WSO2 Agent Manager v${VERSION} — Automated Installer        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  Profile:     ${BOLD}${PROFILE}${NC}"
echo -e "  Base domain: ${BOLD}${BASE_DOMAIN}${NC}"
echo -e "  TLS mode:    ${BOLD}${TLS_MODE}${NC}"
echo -e "  Context:     ${BOLD}$(kubectl config current-context 2>/dev/null || echo 'unknown')${NC}"
echo ""

step "Pre-flight checks"

# kubectl
if ! kubectl version --client &>/dev/null; then
    error "kubectl not found"; exit 1
fi
success "kubectl found"

# helm
if ! helm version &>/dev/null; then
    error "helm not found"; exit 1
fi
HELM_MAJOR_VERSION=$(helm version --short 2>/dev/null | sed -E 's/^v([0-9]+)\..*/\1/')
if [ "${HELM_MAJOR_VERSION}" != "3" ]; then
    echo ""
    echo -e "${RED}${BOLD}✗ Helm $(helm version --short 2>/dev/null) found — this installer requires Helm v3.12+${NC}"
    echo ""
    echo "  The RC2 prerequisites state this outright: \"Helm v3.12+ (Helm 4 not"
    echo "  supported)\". It matches what was observed here first-hand:"
    echo ""
    echo "  Helm 4's hook lifecycle (used by cert-manager's startupapicheck, the"
    echo "  agent-sandbox chart, and others installed here) has been observed to"
    echo "  hang indefinitely on this environment — confirmed by installing the"
    echo "  same chart with Helm 3, which succeeded in seconds every time Helm 4"
    echo "  hung. Rancher Desktop currently bundles Helm 4 as \`helm\` on PATH."
    echo ""
    echo -e "  ${BOLD}Fix: brew install helm@3${NC}, then put it ahead of Rancher Desktop's"
    echo -e "  helm on PATH: ${BOLD}export PATH=\"/opt/homebrew/opt/helm@3/bin:\$PATH\"${NC}"
    echo "  (helm@3 is keg-only, so it won't overwrite the existing helm@4 link)"
    echo ""
    exit 1
fi
success "helm found ($(helm version --short 2>/dev/null))"

# docker-credential-osxkeychain (required for OCI Helm chart pulls)
if ! which docker-credential-osxkeychain &>/dev/null; then
    echo ""
    echo -e "${RED}${BOLD}✗ docker-credential-osxkeychain not found in PATH${NC}"
    echo ""
    echo "  This is required for Helm to pull OCI charts from ghcr.io and other registries."
    echo "  It is installed by Rancher Desktop but your current shell was opened before"
    echo "  Rancher Desktop was installed, so PATH has not been updated."
    echo ""
    echo -e "  ${BOLD}Fix: open a new terminal window and re-run this script.${NC}"
    echo ""
    exit 1
fi
success "docker-credential-osxkeychain found"

# cluster connectivity
if ! kubectl cluster-info &>/dev/null; then
    error "Cannot connect to Kubernetes cluster"; exit 1
fi
K8S_VERSION=$(kubectl version -o json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['serverVersion']['gitVersion'])" 2>/dev/null || echo "unknown")
success "Cluster connected — ${K8S_VERSION}"

# node count & resources
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
info "Nodes: ${NODE_COUNT}"

# storageclass
if ! kubectl get storageclass 2>/dev/null | grep -q '(default)'; then
    warning "No default StorageClass found — some PVCs may not bind"
else
    success "Default StorageClass present"
fi

# LoadBalancer provisioning
#
# Every plane gateway is a type=LoadBalancer Service. On a cluster that cannot
# provision one, the Service sits at <pending> forever and the failure does not
# surface until "Waiting for Control Plane LoadBalancer IP" — an hour in, with
# CRDs, cert-manager, OpenBao and Thunder already installed and a teardown
# needed to retry. RC3's guide recommends this same probe as a prerequisite.
#
# Costs ~15s on Rancher Desktop, where k3s ServiceLB answers with the node IP.
# Set SKIP_LB_PROBE=1 to skip it (e.g. re-running against a cluster already
# known good, or an air-gapped host that cannot pull nginx).
if [ "${SKIP_LB_PROBE:-0}" = "1" ]; then
    warning "Skipping LoadBalancer probe (SKIP_LB_PROBE=1)"
else
    info "Verifying LoadBalancer provisioning..."
    lb_probe_cleanup() {
        kubectl delete svc lbtest-preflight --ignore-not-found >/dev/null 2>&1 || true
        kubectl delete deploy lbtest-preflight --ignore-not-found >/dev/null 2>&1 || true
    }
    # Clean up first as well as after: a previous interrupted run can leave the
    # Service behind, and `kubectl wait` would then pass on that stale object.
    lb_probe_cleanup
    kubectl create deployment lbtest-preflight --image=nginx >/dev/null 2>&1 || true
    kubectl expose deployment lbtest-preflight --port=80 --type=LoadBalancer >/dev/null 2>&1 || true
    if kubectl wait --for=jsonpath='{.status.loadBalancer.ingress}' \
        svc/lbtest-preflight --timeout="${LB_PROBE_TIMEOUT:-180s}" >/dev/null 2>&1; then
        LB_PROBE_ADDR=$(kubectl get svc lbtest-preflight \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
        lb_probe_cleanup
        success "LoadBalancer provisioning works (${LB_PROBE_ADDR:-address assigned})"
    else
        lb_probe_cleanup
        echo ""
        echo -e "${RED}${BOLD}✗ LoadBalancer Services are not being provisioned${NC}"
        echo ""
        echo "  A test Service stayed <pending> for ${LB_PROBE_TIMEOUT:-180s}. Every OpenChoreo"
        echo "  plane gateway needs one, so the install would fail an hour from now"
        echo "  instead of here."
        echo ""
        echo "  On Rancher Desktop: check that the VM is running and that Traefik is"
        echo "  either disabled or free of ports 80/443 (this script removes it later,"
        echo "  but ServiceLB must be working now)."
        echo "  On a cloud cluster: check the LB controller and its IAM permissions."
        echo ""
        echo -e "  Re-run with ${BOLD}SKIP_LB_PROBE=1${NC} to bypass this check."
        echo ""
        exit 1
    fi
fi

# Container registry — cloud must supply one.
#
# DEPLOY_REGISTRY is false on this profile, so nothing is installed, yet
# REGISTRY_ENDPOINT still falls back to registry.${BASE_DOMAIN}:30500 — a host
# that will not exist and a NodePort that is not published. That value is handed
# to platform-resources as global.registry.endpoint, so agent builds are
# configured against it and fail at push, long after the install reports success.
# Fail here instead, where the fix is one export.
if [ "${PROFILE}" = "cloud" ] && [ "${DEPLOY_REGISTRY}" != "true" ]; then
    # "Still the placeholder" is the test: REGISTRY_ENDPOINT is always set by
    # then, so its value has to be compared against the default it would have
    # taken, rather than checked for emptiness.
    if [ "${REGISTRY_ENDPOINT}" = "${REGISTRY_HOST}:${REGISTRY_PORT}" ]; then
        echo ""
        echo -e "${RED}${BOLD}✗ The cloud profile needs a container registry${NC}"
        echo ""
        echo "  No registry is deployed on this profile, and the default endpoint"
        echo -e "  (${BOLD}${REGISTRY_ENDPOINT}${NC}) is a local-profile placeholder that will not"
        echo "  resolve. Agent builds would be configured against it and fail at push,"
        echo "  after the install has already reported success."
        echo ""
        echo -e "  ${BOLD}Point it at a real registry:${NC}"
        echo -e "    export REGISTRY_ENDPOINT=registry.digitalocean.com/<your-registry>"
        echo -e "    export REGISTRY_ENDPOINT=<account>.dkr.ecr.<region>.amazonaws.com"
        echo ""
        echo "  The builder must already be able to authenticate to it — this"
        echo "  installer configures no pull/push credentials."
        echo ""
        echo -e "  To deploy the in-cluster evaluation registry instead:"
        echo -e "    ${BOLD}DEPLOY_REGISTRY=true${NC}   (plain HTTP, no auth — not for shared clusters)"
        echo ""
        exit 1
    fi
fi
if [ "${PROFILE}" = "cloud" ]; then
    success "Registry: ${REGISTRY_ENDPOINT} (tlsVerify=${REGISTRY_TLS_VERIFY})"
fi

# TLS mode sanity — fail before anything is installed, not 20 minutes in.
case "${TLS_MODE}" in
    selfsigned)
        # TLS_MODE defaults to selfsigned, which is right for a laptop and wrong
        # for a real domain: browsers reject every hostname, and the trust-the-CA
        # instructions in the summary are printed for the local profile only. A
        # cloud install would therefore come up unreachable with nothing in the
        # output explaining why. Blocking rather than warning because the
        # certificate hostnames are baked in at install time.
        if [ "${PROFILE}" = "cloud" ] && [ "${ALLOW_SELFSIGNED_CLOUD:-0}" != "1" ]; then
            echo ""
            echo -e "${RED}${BOLD}✗ TLS_MODE=selfsigned on the cloud profile${NC}"
            echo ""
            echo "  Certificates would be issued by a self-signed CA for real public"
            echo "  hostnames under ${BASE_DOMAIN}, so every browser rejects them and"
            echo "  the console never loads."
            echo ""
            echo -e "  ${BOLD}Use Let's Encrypt:${NC}"
            echo -e "    export TLS_MODE=acme-dns01"
            echo -e "    export ACME_EMAIL=you@example.com"
            echo -e "    export TLS_ACME_SOLVER_FILE=/path/to/solver.yaml"
            echo ""
            echo -e "  ${BOLD}Or a CA you already run:${NC}"
            echo -e "    export TLS_MODE=existing TLS_ISSUER_NAME=<clusterissuer>"
            echo ""
            echo -e "  To proceed anyway (internal-only cluster, CA distributed by"
            echo -e "  other means): ${BOLD}ALLOW_SELFSIGNED_CLOUD=1${NC}"
            echo ""
            exit 1
        fi
        success "TLS mode: self-signed openchoreo-ca chain"
        ;;
    existing)
        if ! kubectl get clusterissuer "${TLS_ISSUER_NAME}" &>/dev/null; then
            error "TLS_MODE=existing but ClusterIssuer '${TLS_ISSUER_NAME}' does not exist"
            exit 1
        fi
        success "TLS mode: existing ClusterIssuer '${TLS_ISSUER_NAME}'"
        ;;
    acme-dns01)
        if [ -z "${TLS_ACME_SOLVER_FILE}" ] || [ ! -f "${TLS_ACME_SOLVER_FILE}" ]; then
            echo ""
            echo -e "${RED}${BOLD}✗ TLS_MODE=acme-dns01 needs a DNS-01 solver stanza${NC}"
            echo ""
            echo "  RC2 requires wildcard certificates (*.${BASE_DOMAIN} and"
            echo "  *.${AGENTS_DOMAIN}), so HTTP-01 cannot be used. Supply the solver"
            echo "  for whichever provider hosts your zone:"
            echo ""
            echo -e "    ${BOLD}export ACME_EMAIL=you@example.com${NC}"
            echo -e "    ${BOLD}export TLS_ACME_SOLVER_FILE=/path/to/solver.yaml${NC}"
            echo ""
            echo "  The file holds just the list entry under solvers:, e.g."
            echo "      - dns01:"
            echo "          cloudflare:"
            echo "            apiTokenSecretRef: { name: cloudflare-token, key: token }"
            echo ""
            echo "  See the README — apis.coach is hosted on GoDaddy, for which"
            echo "  cert-manager ships no built-in solver, so use either a delegated"
            echo "  subdomain or the built-in acmeDNS solver."
            echo ""
            exit 1
        fi
        if [ -z "${ACME_EMAIL}" ]; then
            error "TLS_MODE=acme-dns01 requires ACME_EMAIL"
            exit 1
        fi
        success "TLS mode: Let's Encrypt DNS-01 (solver from ${TLS_ACME_SOLVER_FILE})"
        ;;
    *)
        error "Unknown TLS_MODE '${TLS_MODE}' — expected selfsigned, acme-dns01 or existing"
        exit 1
        ;;
esac

# ============================================================================
# CONFIRMATION — last point before anything is written
# ============================================================================
# Everything above only reads. The Traefik uninstall immediately below is the
# first mutation, so this is where the operator gets to see what they are about
# to change and stop.
#
# The value here is the CONTEXT line: every check so far can pass against a
# perfectly healthy cluster that simply is not the one intended. kubectl's
# current context is ambient state — set by another terminal, another project,
# hours ago — and nothing else in the output makes it visible.
CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "<unknown>")
CURRENT_SERVER=$(kubectl config view --minify \
    -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "<unknown>")

echo ""
echo -e "${BOLD}────────────────────────────────────────────────────────────────${NC}"
echo -e "${BOLD} About to install WSO2 Agent Manager v${VERSION}${NC}"
echo -e "${BOLD}────────────────────────────────────────────────────────────────${NC}"
echo -e "  Context:      ${BOLD}${CURRENT_CONTEXT}${NC}"
echo -e "  Cluster:      ${CURRENT_SERVER}"
echo -e "  Profile:      ${PROFILE}"
echo -e "  Base domain:  ${BASE_DOMAIN}"
echo -e "  TLS mode:     ${TLS_MODE}"
echo -e "  Namespaces:   wso2-amp, openchoreo-{control,data,workflow,observability}-plane,"
echo -e "                amp-thunder, openbao, cert-manager, external-secrets"
echo ""
echo -e "  Takes roughly 40 minutes and modifies the cluster above."
if helm status traefik -n kube-system &>/dev/null; then
    echo -e "  ${YELLOW}Traefik is installed here and will be REMOVED${NC} (it conflicts with kgateway)."
fi
echo ""

if [ "${ASSUME_YES}" = "1" ]; then
    info "Proceeding (--yes)"
elif [ ! -t 0 ]; then
    # Piped or run from CI: there is no one to answer, and defaulting to "yes"
    # is how an unattended job installs into the wrong cluster.
    error "Not a terminal — cannot ask for confirmation."
    info "Re-run with --yes to install non-interactively."
    exit 1
else
    printf '  Proceed? [y/N] '
    CONFIRM=""
    read -r CONFIRM || true
    case "${CONFIRM}" in
        [yY]|[yY][eE][sS]) echo "" ;;
        *) echo ""; info "Aborted — nothing was changed."; exit 0 ;;
    esac
fi

# check for traefik (must be removed)
# k3s ships Traefik bound to host ports 80/443, which collides with
# OpenChoreo's kgateway. RC2's Rancher appendix also notes that removing the
# traefik-crd chart can take the Gateway API CRDs with it — this runs BEFORE
# the Gateway API CRD step below, so they are (re-)applied afterwards either way.
if helm status traefik -n kube-system &>/dev/null; then
    warning "Traefik detected — removing (conflicts with kgateway)..."
    helm uninstall traefik -n kube-system 2>/dev/null || true
    helm uninstall traefik-crd -n kube-system 2>/dev/null || true
    success "Traefik removed"
else
    success "Traefik not present"
fi

# ============================================================================
# PHASE 1 — OPENCHOREO PLATFORM
# ============================================================================
echo -e "\n${BOLD}════════════════════════════════════════${NC}"
echo -e "${BOLD} Phase 1: OpenChoreo Platform           ${NC}"
echo -e "${BOLD}════════════════════════════════════════${NC}"

# ── Step 0: In-cluster DNS (local profile) ───────────────────────────────────
# On the local profile nothing resolves ${BASE_DOMAIN} publicly (that is the
# point — the platform must work with no Internet connection). Two resolvers
# need to answer for it:
#
#   * Pods. Agents' OTLP exporters, the API gateway and env-Thunder all dial
#     these names from inside the cluster. k3s CoreDNS imports
#     /etc/coredns/custom/*.override, so a coredns-custom ConfigMap can rewrite
#     each domain onto the right gateway Service. This is the same mechanism
#     the upstream k3d layout uses for *.openchoreo.localhost.
#
#     This is also why the base domain is a real name rather than *.localhost:
#     Go and Python resolvers inside pods do not special-case .localhost, and
#     macOS does not resolve multi-label .localhost either (getaddrinfo and
#     curl both fail on console.amp.localhost) — so .localhost cannot serve
#     either side.
#
#   * The Mac. Handled by /etc/hosts, printed at the end of this step —
#     Rancher Desktop's ssh forwarder binds every LoadBalancer port on
#     127.0.0.1, so the entries point there rather than at the VM IP and
#     survive the VM getting a new address across restarts.
#
# Rules are ordered most-specific first: CoreDNS evaluates rewrites in order,
# so (.+\.)?${BASE_DOMAIN} would otherwise swallow the agents and traces names.
if [ "${PROFILE}" = "local" ]; then
    step "In-cluster DNS for ${BASE_DOMAIN} (coredns-custom)"

    if ! kubectl get cm coredns -n kube-system -o jsonpath='{.data.Corefile}' 2>/dev/null \
        | grep -q 'import /etc/coredns/custom'; then
        warning "CoreDNS does not import /etc/coredns/custom — rewrites may not take effect"
    fi

    BASE_RE="${BASE_DOMAIN//./\\.}"
    AGENTS_RE="${AGENTS_DOMAIN//./\\.}"
    OBS_RE="${OBS_API_PUBLIC_HOST//./\\.}"
    REG_RE="${REGISTRY_HOST//./\\.}"

    kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  amp.override: |
    rewrite stop {
      name regex ${REG_RE} registry.${REGISTRY_NS}.svc.cluster.local
      answer auto
    }
    rewrite stop {
      name regex (.+\.)?${AGENTS_RE} gateway-default.openchoreo-data-plane.svc.cluster.local
      answer auto
    }
    rewrite stop {
      name regex ${OBS_RE} gateway-default.openchoreo-observability-plane.svc.cluster.local
      answer auto
    }
    rewrite stop {
      name regex (.+\.)?${BASE_RE} gateway-default.openchoreo-control-plane.svc.cluster.local
      answer auto
    }
EOF
    kubectl rollout restart deployment/coredns -n kube-system >/dev/null 2>&1 || true
    kubectl rollout status deployment/coredns -n kube-system --timeout=90s >/dev/null 2>&1 || true
    success "CoreDNS rewrites applied for *.${BASE_DOMAIN}"

    # Host-side resolution. /etc/hosts has no wildcards, so this covers the
    # fixed management hostnames plus the default org/env agent host; a line
    # has to be added per additional project. Written via scripts/amp-hosts.sh
    # so it can be re-run later without re-running the installer.
    #
    # NOT required for the rest of this install to succeed: every host-side
    # HTTP call the installer makes goes through a temporary port-forward
    # (see the env-Thunder step), and everything else is kubectl/helm against
    # the API server. These entries are what YOUR BROWSER and amctl need
    # afterwards, so a missing block is a to-do, not a failure — the install
    # continues either way.
    AMP_HOSTS_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/amp-hosts.sh"
    if [ -x "${AMP_HOSTS_SCRIPT}" ]; then
        if grep -q "${BASE_DOMAIN}" /etc/hosts 2>/dev/null; then
            success "/etc/hosts already has entries for ${BASE_DOMAIN}"
        elif [ -t 0 ]; then
            # Prompted rather than written silently: this needs sudo and edits
            # a file outside the cluster, which nothing else here touches.
            info "The installer does not need /etc/hosts, but your browser will."
            printf '  Add entries for %s now? (needs sudo) [Y/n] ' "${BASE_DOMAIN}"
            read -r ADD_HOSTS_ANSWER || ADD_HOSTS_ANSWER=""
            case "${ADD_HOSTS_ANSWER}" in
                [Nn]*) info "Skipped — run later with: ${AMP_HOSTS_SCRIPT} add" ;;
                *)     BASE_DOMAIN="${BASE_DOMAIN}" "${AMP_HOSTS_SCRIPT}" add \
                           && success "/etc/hosts updated" \
                           || warning "Could not update /etc/hosts — run later: ${AMP_HOSTS_SCRIPT} add" ;;
            esac
        else
            info "/etc/hosts has no entries for ${BASE_DOMAIN} — not needed to install,"
            info "but required before a browser can reach the console."
            info "Run afterwards (needs sudo):  ${AMP_HOSTS_SCRIPT} add"
        fi
    fi
fi

# ── Step 1: Gateway API CRDs ─────────────────────────────────────────────────
step "Gateway API CRDs (v1.4.1)"

GW_VERSION=$(kubectl get crd gateways.gateway.networking.k8s.io \
    -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}' 2>/dev/null || echo "")

if [ -n "${GW_VERSION}" ]; then
    info "Gateway API CRDs already installed (version: ${GW_VERSION})"
    # Try applying anyway with force-conflicts
    kubectl apply --server-side --force-conflicts \
        -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/experimental-install.yaml \
        2>/dev/null && success "Gateway API CRDs applied/updated" \
        || warning "Could not apply v1.4.1 CRDs (existing version ${GW_VERSION} may be newer — continuing)"
else
    kubectl apply --server-side --force-conflicts \
        -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/experimental-install.yaml
    success "Gateway API CRDs installed"
fi

CRD_COUNT=$(kubectl get crd 2>/dev/null | grep -c gateway.networking.k8s.io || echo 0)
info "Gateway CRDs present: ${CRD_COUNT}"

# ── Step 2: cert-manager ─────────────────────────────────────────────────────
step "cert-manager (v1.19.2)"
if ! check_helm_release cert-manager cert-manager; then
    retry_cmd "cert-manager install" 3 15 \
        helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
        --namespace cert-manager \
        --create-namespace \
        --version v1.19.2 \
        --set crds.enabled=true \
        --set startupapicheck.timeout=5m \
        --wait --timeout 360s
fi
wait_for "cert-manager pods" \
    kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=120s
verify_pods cert-manager

# ── Step 3: External Secrets Operator ────────────────────────────────────────
step "External Secrets Operator (v1.3.2)"
if ! check_helm_release external-secrets external-secrets; then
    retry_cmd "external-secrets install" 3 15 \
        helm upgrade --install external-secrets oci://ghcr.io/external-secrets/charts/external-secrets \
        --namespace external-secrets \
        --create-namespace \
        --version 1.3.2 \
        --set installCRDs=true \
        --wait --timeout 180s
fi
wait_for "external-secrets pods" \
    kubectl wait --for=condition=Available deployment --all -n external-secrets --timeout=120s
verify_pods external-secrets

# ── Step 4: kgateway ─────────────────────────────────────────────────────────
step "kgateway (v2.2.1)"
if ! check_helm_release kgateway-crds openchoreo-control-plane; then
    retry_cmd "kgateway-crds install" 3 15 \
        helm upgrade --install kgateway-crds oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds \
        --create-namespace \
        --namespace openchoreo-control-plane \
        --version v2.2.1
fi
if ! check_helm_release kgateway openchoreo-control-plane; then
    retry_cmd "kgateway install" 3 15 \
        helm upgrade --install kgateway oci://cr.kgateway.dev/kgateway-dev/charts/kgateway \
        --namespace openchoreo-control-plane \
        --create-namespace \
        --version v2.2.1 \
        --set controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true
fi
wait_for "kgateway pods" \
    kubectl wait --for=condition=Available deployment --all -n openchoreo-control-plane --timeout=180s
verify_pods openchoreo-control-plane

# ── Step 5: OpenBao ──────────────────────────────────────────────────────────
# NOT RC2's values-openbao.yaml. That runs `bao server -dev`, which keeps
# everything in memory: any interruption of the pod — a laptop sleep, an OOM, a
# VM restart — silently discards every secret written since install. The
# platform keeps working afterwards, because the dev-mode postStart hook
# re-seeds its own placeholder secrets on every start, while everything written
# at RUNTIME is gone. Agent creation then fails with a 500 whose text never
# names OpenBao:
#
#   failed to store secrets in KV: failed to upsert secret:
#   failed to check secret existence: unexpected error: status 501
#
# See scripts/openbao-values.yaml for the replacement and, importantly, for what
# its "sealed" actually buys (durability, not secrecy — the unseal key lives in
# a Secret beside it).
step "OpenBao secrets store (v0.25.6, persistent)"

OPENBAO_VALUES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/openbao-values.yaml"
if [ ! -f "${OPENBAO_VALUES}" ]; then
    error "Missing ${OPENBAO_VALUES} — it ships alongside this script"
    exit 1
fi

if ! check_helm_release openbao openbao; then
    retry_cmd "OpenBao install" 3 15 \
        helm upgrade --install openbao oci://ghcr.io/openbao/charts/openbao \
        --namespace openbao \
        --create-namespace \
        --version 0.25.6 \
        --values "${OPENBAO_VALUES}" \
        --timeout 180s
fi

# Wait for RUNNING, not Ready. A sealed server fails its readiness probe by
# design (the probe is `bao status`), so waiting for Ready here would time out
# before anything has had the chance to unseal it.
wait_for "OpenBao pod running" \
    kubectl wait --for=jsonpath='{.status.phase}'=Running pod/openbao-0 -n openbao --timeout=180s

bao_exec() { kubectl exec -n openbao openbao-0 -c openbao -- sh -c "export BAO_ADDR=http://127.0.0.1:8200; $1"; }

# ── Initialise (first install only) ──────────────────────────────────────────
# `bao status` exits 2 when sealed and 0 when unsealed, so its exit code cannot
# distinguish "uninitialised" from "sealed" — read the field instead.
OPENBAO_INITIALIZED=$(bao_exec 'bao status -format=json 2>/dev/null || true' \
    | tr -d ' \n' | grep -o '"initialized":[a-z]*' | cut -d: -f2 || echo "")

if [ "${OPENBAO_INITIALIZED}" = "false" ]; then
    info "Initialising OpenBao..."
    # One key share, threshold one. Splitting the key five ways only to store
    # all five shares in the same Secret is ceremony, not safety — see the
    # values file. Captured here and never written to disk on this machine.
    BAO_INIT_JSON=$(bao_exec 'bao operator init -key-shares=1 -key-threshold=1 -format=json')
    BAO_UNSEAL_KEY=$(printf '%s' "${BAO_INIT_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["unseal_keys_b64"][0])')
    BAO_ROOT_TOKEN=$(printf '%s' "${BAO_INIT_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["root_token"])')

    if [ -z "${BAO_UNSEAL_KEY}" ] || [ -z "${BAO_ROOT_TOKEN}" ]; then
        error "OpenBao init returned no keys — refusing to continue"
        exit 1
    fi

    # Store BEFORE unsealing: if the script dies between the two, the data is
    # still recoverable. The reverse order would strand a sealed store whose
    # key exists only in a dead shell's memory, and the only fix would be to
    # delete the PVC and start over.
    kubectl create secret generic openbao-unseal-key -n openbao \
        --from-literal=unseal-key="${BAO_UNSEAL_KEY}" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl create secret generic openbao-root-token -n openbao \
        --from-literal=root-token="${BAO_ROOT_TOKEN}" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    success "OpenBao initialised; unseal key and root token stored as Secrets in namespace openbao"

    # The sidecar would get there on its own once the kubelet projects the
    # Secret into its volume, but that can take a minute. Unseal directly so
    # the rest of the install proceeds immediately.
    bao_exec "bao operator unseal '${BAO_UNSEAL_KEY}'" >/dev/null
    success "OpenBao unsealed"
else
    info "OpenBao already initialised — reusing stored keys"
    BAO_UNSEAL_KEY=$(kubectl get secret openbao-unseal-key -n openbao \
        -o jsonpath='{.data.unseal-key}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    if [ -z "${BAO_UNSEAL_KEY}" ]; then
        error "OpenBao is initialised but Secret openbao-unseal-key is missing."
        error "Nothing can unseal it. Recover the key, or delete the release, the"
        error "PVC (data-openbao-0) and the namespace to start over."
        exit 1
    fi
    bao_exec "bao operator unseal '${BAO_UNSEAL_KEY}'" >/dev/null 2>&1 || true
fi

BAO_ROOT_TOKEN=$(kubectl get secret openbao-root-token -n openbao \
    -o jsonpath='{.data.root-token}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
if [ -z "${BAO_ROOT_TOKEN}" ]; then
    error "Secret openbao-root-token is missing — cannot configure OpenBao"
    exit 1
fi
export BAO_ROOT_TOKEN

wait_for "OpenBao pod ready" \
    kubectl wait --for=condition=Ready pod/openbao-0 -n openbao --timeout=180s
verify_pods openbao

# ── Bootstrap ────────────────────────────────────────────────────────────────
# The Kubernetes auth method, policies and roles RC2 configures from its
# postStart hook. That hook cannot be used outside dev mode: it runs while the
# server is still sealed, so every write in it fails. Doing it here also makes
# the failures visible instead of buried in a lifecycle hook.
#
# Every command is idempotent, so this re-runs safely on an existing store.
info "Configuring OpenBao auth, policies and roles..."
bao_exec "
set -e
export BAO_TOKEN='${BAO_ROOT_TOKEN}'

bao secrets enable -path=secret -version=2 kv 2>/dev/null || true
bao auth enable kubernetes 2>/dev/null || true
bao write auth/kubernetes/config \
  kubernetes_host=\"https://\${KUBERNETES_PORT_443_TCP_ADDR}:443\"

bao policy write openchoreo-secret-reader-policy - <<'POLICY'
path \"secret/data/*\" { capabilities = [\"read\"] }
path \"secret/metadata/*\" { capabilities = [\"list\", \"read\"] }
POLICY

bao policy write openchoreo-secret-writer-policy - <<'POLICY'
path \"secret/data/*\" { capabilities = [\"create\", \"read\", \"update\", \"delete\"] }
path \"secret/metadata/*\" { capabilities = [\"create\", \"read\", \"update\", \"delete\", \"list\"] }
POLICY

bao write auth/kubernetes/role/openchoreo-secret-reader-role \
  bound_service_account_names=default \
  bound_service_account_namespaces='dp*' \
  policies=openchoreo-secret-reader-policy ttl=20m

bao write auth/kubernetes/role/openchoreo-secret-writer-role \
  bound_service_account_names='*' \
  bound_service_account_namespaces='openbao,openchoreo-workflow-plane,wso2-amp' \
  policies=openchoreo-secret-writer-policy ttl=20m
" >/dev/null
success "OpenBao auth, policies and roles configured"

info "Configuring External Secrets ClusterSecretStore..."
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: external-secrets-openbao
  namespace: openbao
---
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: default
spec:
  provider:
    vault:
      server: "http://openbao.openbao.svc:8200"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "openchoreo-secret-writer-role"
          serviceAccountRef:
            name: "external-secrets-openbao"
            namespace: "openbao"
EOF
success "ClusterSecretStore configured"

# Seed the platform's own secrets.
#
# RC2 does this from the dev-mode postStart hook, which re-ran on every pod
# start. Nothing re-runs it now, so the installer owns it — and because the
# store is persistent, a re-run must NOT clobber values the platform is already
# using. Hence write-if-absent on the local profile: the values are fixed
# placeholders, so re-writing them is harmless, but keeping the read path
# identical on both profiles means one code path to reason about.
#
# ${OPENSEARCH_PASSWORD} is empty on the local profile at this point and is
# read back below, so the logs module is given the value OpenSearch is actually
# bootstrapped with rather than a second, conflicting one.
info "Seeding platform secrets into OpenBao..."
bao_seed() {
    # Only writes when the key is absent, so re-running the installer against a
    # live store never rotates a secret out from under a running component.
    bao_exec "export BAO_TOKEN='${BAO_ROOT_TOKEN}'
bao kv get -field=value secret/$1 >/dev/null 2>&1 || bao kv put secret/$1 value='$2' >/dev/null"
}
bao_seed workflow-plane-oauth-client-secret "${WORKFLOW_PUBLISHER_SECRET}"
bao_seed amp-publisher-client-secret        "${AMP_PUBLISHER_CLIENT_SECRET}"
bao_seed amp-system-client-secret           "${AMP_SYSTEM_CLIENT_SECRET}"
bao_seed observer-oauth-client-secret       "${OBSERVER_READER_SECRET}"
bao_seed opensearch-username                "${OPENSEARCH_USERNAME}"
bao_seed opensearch-password                "${OPENSEARCH_PASSWORD:-ThisIsTheOpenSearchPassword1}"
success "Platform secrets seeded into OpenBao"

# Read every value back, on BOTH profiles. Previously only the local profile
# did this; now that the store survives restarts, a re-install against an
# existing OpenBao must adopt the values already in it rather than the ones it
# just generated in memory — otherwise Thunder is reconfigured in Step 7 with
# fresh secrets while the consumers keep reading the originals, which surfaces
# much later as a 401 invalid_client at workload publish.
bao_read() { bao_exec "export BAO_TOKEN='${BAO_ROOT_TOKEN}'; bao kv get -field=value secret/$1" 2>/dev/null || echo ""; }
for pair in \
    "WORKFLOW_PUBLISHER_SECRET:workflow-plane-oauth-client-secret" \
    "AMP_PUBLISHER_CLIENT_SECRET:amp-publisher-client-secret" \
    "AMP_SYSTEM_CLIENT_SECRET:amp-system-client-secret" \
    "OBSERVER_READER_SECRET:observer-oauth-client-secret" \
    "OPENSEARCH_USERNAME:opensearch-username" \
    "OPENSEARCH_PASSWORD:opensearch-password"; do
    var="${pair%%:*}"; key="${pair#*:}"
    val="$(bao_read "${key}")"
    if [ -n "${val}" ]; then
        export "${var}=${val}"
    else
        warning "Could not read secret/${key} from OpenBao — using the in-memory value"
    fi
done
success "Platform secrets read back from OpenBao"

# ── Step 6: TLS Setup ────────────────────────────────────────────────────────
# Every Certificate below refers to a ClusterIssuer named ${TLS_ISSUER_NAME}
# (default 'openchoreo-ca'), so only the issuer's definition varies by mode —
# which is exactly the shape RC2 recommends ("copy-paste the issuer name across
# all cert resources").
step "TLS issuer (${TLS_MODE})"
case "${TLS_MODE}" in
  selfsigned)
    kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-bootstrap
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${TLS_ISSUER_NAME}
  namespace: cert-manager
spec:
  isCA: true
  commonName: ${TLS_ISSUER_NAME}
  secretName: openchoreo-ca-secret
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: selfsigned-bootstrap
    kind: ClusterIssuer
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${TLS_ISSUER_NAME}
spec:
  ca:
    secretName: openchoreo-ca-secret
EOF
    wait_for "CA certificate" \
        kubectl wait --for=condition=Ready "certificate/${TLS_ISSUER_NAME}" -n cert-manager --timeout=60s
    success "Self-signed TLS CA chain ready"
    ;;
  acme-dns01)
    # The solver stanza is supplied by the operator rather than hardcoded, so
    # this works with whichever provider hosts the zone. The file holds the
    # list entries that go under solvers:.
    {
        cat <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${TLS_ISSUER_NAME}
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${ACME_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-account-key
    solvers:
EOF
        sed 's/^/      /' "${TLS_ACME_SOLVER_FILE}"
    } | kubectl apply -f -
    wait_for "ACME account registration" \
        kubectl wait --for=condition=Ready "clusterissuer/${TLS_ISSUER_NAME}" --timeout=120s
    success "Let's Encrypt ClusterIssuer '${TLS_ISSUER_NAME}' ready"
    ;;
  existing)
    success "Using pre-existing ClusterIssuer '${TLS_ISSUER_NAME}'"
    ;;
esac

# ── Step 7: Thunder (Identity Provider) ──────────────────────────────────────
step "Thunder Identity Provider (v${VERSION})"
if ! check_helm_release amp-thunder-extension "${THUNDER_NS}"; then
    # ── EVERYTHING SET HERE IS FROZEN AT FIRST BOOT ──────────────────────────
    # Thunder writes its issuer URL, the console client's redirect URIs, the
    # MCP resource identifiers and every platform OAuth client into its
    # database from a pre-install hook that `helm upgrade` never re-runs.
    # Changing any of them later means uninstalling the chart AND discarding
    # its data (the SQLite PVC here) — and because Agent Manager keys its
    # tenant data on Thunder's organization identifier, that is a full
    # platform-data reset, not a component restart. Get them right now.
    #
    # ocIngress.https.enabled=false: the chart otherwise stands up a second,
    # dedicated Gateway plus a self-signed "AMP Local Dev CA" certificate on
    # port 8443, independent of the wildcard cert this script issues. Both
    # profiles route Thunder through the control-plane gateway instead, so
    # that extra Gateway is pure dead weight.
    #
    # agentManagerMcpBaseUrl/observerMcpBaseUrl become the OAuth
    # resource-server identifiers Thunder registers for the /mcp endpoints.
    # Thunder matches a requested resource EXACTLY, so these must be the same
    # values as agentManagerService.config.serverPublicURL and
    # amObserver.publicUrl in Phase 2 or MCP logins fail with invalid_target.
    #
    # All six bootstrap client secrets are passed: any client the chart is not
    # given keeps its shipped default. workloadPublisherClient and
    # observerResourceReaderClient are the easy ones to miss — their secrets
    # are also seeded into OpenBao, but seeding OpenBao only tells the
    # consumer; Thunder still registers the default unless it is told
    # otherwise, and the consumer then presents a secret Thunder does not
    # have. These are the values Step 5 read back out of OpenBao, so both
    # sides are given the same secret even on a re-install against a store
    # that already had one.
    helm install amp-thunder-extension \
        oci://${HELM_CHART_REGISTRY}/wso2-amp-thunder-extension \
        --version ${VERSION} \
        --namespace ${THUNDER_NS} \
        --create-namespace \
        --set thunder.ocIngress.hostname="${THUNDER_PUBLIC_HOST}" \
        --set thunder.ocIngress.https.enabled=false \
        --set thunder.configuration.server.publicUrl="${THUNDER_PUBLIC_URL}" \
        --set thunder.configuration.jwt.issuer="${THUNDER_PUBLIC_URL}" \
        --set thunder.configuration.gateClient.hostname="${THUNDER_PUBLIC_HOST}" \
        --set thunder.configuration.gateClient.scheme="${SCHEME}" \
        --set thunder.configuration.gateClient.port="$([ "${SCHEME}" = "https" ] && echo "${CP_GW_HTTPS_PORT}" || echo "${CP_GW_HTTP_PORT}")" \
        --set "thunder.configuration.cors.allowedOrigins={${CONSOLE_PUBLIC_URL}}" \
        --set "thunder.bootstrap.ampConsoleClient.redirectUris={${CONSOLE_PUBLIC_URL}/login}" \
        --set thunder.bootstrap.agentManagerMcpBaseUrl="${API_PUBLIC_URL}" \
        --set thunder.bootstrap.observerMcpBaseUrl="${OBS_API_PUBLIC_URL}" \
        --set thunder.bootstrap.ampApiClient.clientSecret="${AMP_API_CLIENT_SECRET}" \
        --set thunder.bootstrap.ampSystemClient.clientSecret="${AMP_SYSTEM_CLIENT_SECRET}" \
        --set thunder.bootstrap.ampPublisherClient.clientSecret="${AMP_PUBLISHER_CLIENT_SECRET}" \
        --set thunder.bootstrap.amObserverClient.clientSecret="${AM_OBSERVER_CLIENT_SECRET}" \
        --set thunder.bootstrap.workloadPublisherClient.clientSecret="${WORKFLOW_PUBLISHER_SECRET}" \
        --set thunder.bootstrap.observerResourceReaderClient.clientSecret="${OBSERVER_READER_SECRET}" \
        --timeout 1800s
fi
wait_for "Thunder deployment" \
    kubectl wait --for=condition=Available \
        deployment -l app.kubernetes.io/instance=amp-thunder-extension \
        -n ${THUNDER_NS} --timeout=300s
verify_pods "${THUNDER_NS}"

# Verify Thunder OIDC — the issuer it reports must match THUNDER_PUBLIC_URL
# exactly, because every consumer validates the `iss` claim against that same
# value. A mismatch here is the single cheapest thing to catch: it invalidates
# every token the platform will ever mint, and it cannot be fixed by upgrade.
info "Verifying Thunder OIDC endpoint..."
THUNDER_ISSUER=$(kubectl exec -n ${THUNDER_NS} deploy/amp-thunder-extension-deployment -- \
    wget -qO- http://localhost:8090/.well-known/openid-configuration 2>/dev/null \
    | grep -o '"issuer":"[^"]*"' || echo "")
if echo "${THUNDER_ISSUER}" | grep -qF "${THUNDER_PUBLIC_URL}"; then
    success "Thunder OIDC issuer verified: ${THUNDER_ISSUER}"
else
    error "Thunder OIDC issuer is ${THUNDER_ISSUER} — expected ${THUNDER_PUBLIC_URL}"
    warning "This is frozen; fixing it means uninstalling Thunder and discarding its data"
fi

# The console admin password is generated at install time — it is never
# admin/admin (that would be guessable from the chart's public source) and is
# not printed by the install command. Read it back for the summary.
AMP_ADMIN_PASSWORD=$(kubectl get secret amp-admin-credentials -n "${THUNDER_NS}" \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
export AMP_ADMIN_PASSWORD

# ── Step 8: Control Plane ────────────────────────────────────────────────────
step "OpenChoreo Control Plane (v${OPENCHOREO_VERSION})"

# Apply the CRDs explicitly before the chart. Helm only reads a chart's crds/
# directory on `helm install` — it NEVER installs or updates CRDs from there on
# `helm upgrade`. So on any cluster that already has an older release (e.g. an
# existing 1.1.1 install, or a re-run of this script after a partial failure),
# the four CRDs added in 1.2.0 — projecttypes, projectreleasebindings and
# friends — would silently never appear, and the failure would surface far
# later at the Platform Resources step as "no matches for kind ProjectType".
#
# The chart is pulled and its crds/ directory applied as a DIRECTORY. Do not be
# tempted by `helm show crds ... | kubectl apply -f -`: that subcommand
# concatenates the CRD files without emitting "---" document separators, so
# kubectl parses the 36 documents as one malformed stream and silently applies
# only the last of them. It exits 0 while installing a single CRD, which is a
# far worse failure than not trying at all.
#
# Server-side apply with --force-conflicts so this is safe to repeat and takes
# ownership cleanly from a previous release's field manager.
info "Applying OpenChoreo CRDs (helm upgrade does not do this)..."
CRD_DIR=$(mktemp -d)
if helm pull oci://ghcr.io/openchoreo/helm-charts/openchoreo-control-plane \
        --version "${OPENCHOREO_VERSION}" --untar --untardir "${CRD_DIR}" >/dev/null 2>&1 \
   && kubectl apply --server-side --force-conflicts \
        -f "${CRD_DIR}/openchoreo-control-plane/crds/" >/dev/null; then
    CRD_TOTAL=$(kubectl get crd -o name 2>/dev/null | grep -c 'openchoreo\.dev' || echo 0)
    success "OpenChoreo CRDs applied (${CRD_TOTAL} present)"
else
    error "Could not apply OpenChoreo CRDs"
fi
rm -rf "${CRD_DIR}"

# Assert the 1.2.0-era CRDs the Platform Resources step depends on. Failing
# here is cheap; failing at Platform Resources is ~15 minutes in.
for required in projecttypes.openchoreo.dev projectreleasebindings.openchoreo.dev; do
    if ! kubectl get crd "${required}" &>/dev/null; then
        error "CRD ${required} missing — Platform Resources would fail later"
        error "Check OPENCHOREO_VERSION (${OPENCHOREO_VERSION}); it must be >= 1.2.0"
        exit 1
    fi
done
success "ProjectType / ProjectReleaseBinding CRDs present"

info "Installing with placeholder hostnames first..."
CP_PLACEHOLDER_VALUES=$(mktemp)
cat > "${CP_PLACEHOLDER_VALUES}" <<'EOF'
openchoreoApi:
  http:
    hostnames:
      - "api.placeholder.tld"
backstage:
  enabled: false
  baseUrl: ""
  http:
    hostnames:
      - ""
security:
  oidc:
    issuer: "https://thunder.placeholder.tld"
gateway:
  tls:
    enabled: false
EOF
if ! check_helm_release openchoreo-control-plane openchoreo-control-plane; then
    retry_helm "Control Plane initial install" \
        helm upgrade --install openchoreo-control-plane \
        oci://ghcr.io/openchoreo/helm-charts/openchoreo-control-plane \
        --version ${OPENCHOREO_VERSION} \
        --namespace openchoreo-control-plane \
        --create-namespace \
        --set gateway.httpPort="${CP_GW_HTTP_PORT}" \
        --set gateway.httpsPort="${CP_GW_HTTPS_PORT}" \
        `# Agent Manager stores plane-scoped secrets THROUGH openchoreo-api's` \
        `# /api/v1alpha1/namespaces/{ns}/secrets endpoint, not by talking to` \
        `# OpenBao itself. That endpoint is behind this feature flag and the` \
        `# chart defaults it OFF, so it answers 501 Not Implemented and AMP` \
        `# reports the 501 verbatim, naming its own KV layer and never` \
        `# openchoreo-api:` \
        `#   failed to upsert secret: failed to check secret existence:` \
        `#   unexpected error: status 501` \
        `# Everything that stores a secret this way fails the same way —` \
        `# monitor creation (publisher + scheduler credentials) above all.` \
        `# The later control-plane upgrades all use --reuse-values, so setting` \
        `# it here carries through.` \
        --set features.secretManagement.enabled=true \
        --values "${CP_PLACEHOLDER_VALUES}"
fi
rm -f "${CP_PLACEHOLDER_VALUES}"

# Handle webhook race condition
# Wait for all deployments to be available first, then retry helm upgrade
# to create the ClusterAuthzRoleBinding resources that require the webhook
info "Waiting for Control Plane deployments to be ready..."
kubectl wait --for=condition=Available deployment --all \
    -n openchoreo-control-plane --timeout=300s 2>/dev/null || true

retry_helm "Control Plane ClusterAuthzRoleBindings" \
    helm upgrade openchoreo-control-plane \
    oci://ghcr.io/openchoreo/helm-charts/openchoreo-control-plane \
    --version ${OPENCHOREO_VERSION} \
    --namespace openchoreo-control-plane \
    --reuse-values

wait_for "Control Plane deployments" \
    kubectl wait --for=condition=Available deployment --all \
    -n openchoreo-control-plane --timeout=300s

# Get LoadBalancer IP
info "Waiting for Control Plane LoadBalancer IP..."
ELAPSED=0
CP_LB_IP=""
until [ -n "${CP_LB_IP}" ] || [ $ELAPSED -ge 120 ]; do
    CP_LB_IP=$(kubectl get svc gateway-default -n openchoreo-control-plane \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [ -z "${CP_LB_IP}" ]; then
        CP_LB_HOSTNAME=$(kubectl get svc gateway-default -n openchoreo-control-plane \
            -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
        [ -n "${CP_LB_HOSTNAME}" ] && CP_LB_IP=$(dig +short "${CP_LB_HOSTNAME}" | head -1) || true
    fi
    [ -z "${CP_LB_IP}" ] && sleep 5 && ELAPSED=$((ELAPSED+5))
done

if [ -z "${CP_LB_IP}" ]; then
    error "Control Plane LoadBalancer IP not available after 120s"
    info "Check: kubectl get svc gateway-default -n openchoreo-control-plane"
    exit 1
fi

# The base domain is fixed configuration now, not derived from the LB address:
# nip.io needs public DNS to resolve and so cannot be used offline, and RC2
# needs a stable hostname anyway because Thunder's issuer and the API
# gateway's vhost are both frozen at first install. The LB address is still
# waited on — it gates readiness, and on the cloud profile it is what gets
# published in DNS.
success "Control Plane LB address: ${CP_LB_IP}"
success "Control Plane domain: ${BASE_DOMAIN}"

# Wildcard TLS cert. RC2 requires the *.${BASE_DOMAIN} wildcard specifically —
# per-environment Thunder hostnames are minted after install with unguessable
# handles and are reachable only through it.
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: cp-gateway-tls
  namespace: openchoreo-control-plane
spec:
  secretName: cp-gateway-tls
  issuerRef:
    name: ${TLS_ISSUER_NAME}
    kind: ClusterIssuer
  dnsNames:
    - "*.${BASE_DOMAIN}"
    - "${BASE_DOMAIN}"
  privateKey:
    rotationPolicy: Always
EOF
wait_for "CP TLS certificate" \
    kubectl wait --for=condition=Ready certificate/cp-gateway-tls \
    -n openchoreo-control-plane --timeout=300s

# Reconfigure with real hostnames
info "Reconfiguring Control Plane with real hostnames and TLS..."

# RC2 keeps the OpenChoreo API in-cluster (http.enabled: false) rather than
# publishing it on the gateway — Agent Manager is the only client and reaches
# it over the Service. That also keeps api.${BASE_DOMAIN} free, so it cannot be
# confused with api-amp.${BASE_DOMAIN}, which is the Agent Manager API.
#
# skip_tls_verify only when the chain is self-signed: the API cannot otherwise
# verify Thunder's JWKS against an untrusted CA. It is scoped to the TLS mode
# rather than always-on so a real certificate is actually verified.
CP_JWKS_SKIP=""
if [ "${TLS_MODE}" = "selfsigned" ]; then
    CP_JWKS_SKIP=$(cat <<'YAML'
    security:
      authentication:
        jwt:
          jwks:
            skip_tls_verify: true
YAML
)
fi

CP_REAL_VALUES=$(mktemp)
cat > "${CP_REAL_VALUES}" <<EOF
openchoreoApi:
  config:
    server:
      publicUrl: "${OPENCHOREO_API_URL}"
${CP_JWKS_SKIP}
  http:
    enabled: false
    hostnames:
      - "api.${BASE_DOMAIN}"
backstage:
  enabled: false
  baseUrl: ""
  http:
    hostnames:
      - ""
security:
  oidc:
    issuer: "${THUNDER_PUBLIC_URL}"
    wellKnownEndpoint: "${THUNDER_INTERNAL_URL}/.well-known/openid-configuration"
    jwksUrl: "${THUNDER_INTERNAL_URL}/oauth2/jwks"
    authorizationUrl: "${THUNDER_PUBLIC_URL}/oauth2/authorize"
    tokenUrl: "${THUNDER_INTERNAL_URL}/oauth2/token"
gateway:
  httpPort: ${CP_GW_HTTP_PORT}
  httpsPort: ${CP_GW_HTTPS_PORT}
  tls:
    enabled: true
    hostname: "*.${BASE_DOMAIN}"
    certificateRefs:
      - name: cp-gateway-tls
EOF
retry_helm "Control Plane reconfigure (real hostnames)" \
    helm upgrade openchoreo-control-plane \
    oci://ghcr.io/openchoreo/helm-charts/openchoreo-control-plane \
    --version ${OPENCHOREO_VERSION} \
    --namespace openchoreo-control-plane \
    --reuse-values \
    --values "${CP_REAL_VALUES}"
rm -f "${CP_REAL_VALUES}"
wait_for "Control Plane reconfigured" \
    kubectl wait --for=condition=Available deployment --all \
    -n openchoreo-control-plane --timeout=300s
verify_pods openchoreo-control-plane

# Thunder >= 0.45 issues 'client_id' as the entitlement claim instead of
# 'sub' — new/required in v1.0.0-alpha1. Without this patch, every
# ClusterAuthzRoleBinding still matches on the old 'sub' claim and every API
# call gets silently unauthorized (this looks exactly like the v0.18.0
# authz bug diagnosed earlier: 403s / empty lists despite a correctly
# configured binding).
info "Patching openchoreo-api-config entitlement claim for Thunder >= 0.45..."
patched_yaml=$(kubectl get configmap openchoreo-api-config -n openchoreo-control-plane -o yaml \
    | sed -E "s/claim:[[:space:]]*['\"]?sub['\"]?/claim: client_id/g")
echo "$patched_yaml" | kubectl apply --server-side --field-manager=helm --force-conflicts -f -

kubectl rollout restart deployment/openchoreo-api -n openchoreo-control-plane
kubectl rollout status deployment/openchoreo-api -n openchoreo-control-plane --timeout=120s

for binding in $(kubectl get clusterauthzrolebindings.openchoreo.dev -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    claim=$(kubectl get clusterauthzrolebinding.openchoreo.dev "$binding" -o jsonpath='{.spec.entitlement.claim}' 2>/dev/null || echo "")
    if [ "$claim" = "sub" ]; then
        # --field-manager=helm (not the kubectl-patch default): this script
        # unconditionally re-applies these same CRs via `helm upgrade
        # --reuse-values` on every run (see "Control Plane
        # ClusterAuthzRoleBindings"/"reconfigure" above), as field manager
        # "helm". If this patch took ownership under the default
        # "kubectl-patch" manager instead, every later re-run's server-side
        # apply would conflict on this exact field with "Apply failed with 1
        # conflict: conflict with \"kubectl-patch\"".
        kubectl patch clusterauthzrolebinding.openchoreo.dev "$binding" --type=merge \
            --field-manager=helm \
            -p '{"spec":{"entitlement":{"claim":"client_id"}}}'
    fi
done
success "Entitlement claim patched to client_id"

# ── Step 9: Data Plane ───────────────────────────────────────────────────────
step "OpenChoreo Data Plane (v${OPENCHOREO_VERSION})"
kubectl create namespace openchoreo-data-plane --dry-run=client -o yaml | kubectl apply -f -

CA_CRT=$(kubectl get secret cluster-gateway-ca \
    -n openchoreo-control-plane -o jsonpath='{.data.ca\.crt}' | base64 -d)
kubectl create configmap cluster-gateway-ca \
    --from-literal=ca.crt="$CA_CRT" \
    -n openchoreo-data-plane --dry-run=client -o yaml | kubectl apply -f -

TLS_CRT=$(kubectl get secret cluster-gateway-ca \
    -n openchoreo-control-plane -o jsonpath='{.data.tls\.crt}' | base64 -d)
TLS_KEY=$(kubectl get secret cluster-gateway-ca \
    -n openchoreo-control-plane -o jsonpath='{.data.tls\.key}' | base64 -d)
kubectl create secret generic cluster-gateway-ca \
    --from-literal=tls.crt="$TLS_CRT" \
    --from-literal=tls.key="$TLS_KEY" \
    --from-literal=ca.crt="$CA_CRT" \
    -n openchoreo-data-plane --dry-run=client -o yaml | kubectl apply -f -
success "CA certificates copied to data plane"

# The agents domain is fixed configuration, so unlike the alpha1 flow there is
# no need to install first, discover a LoadBalancer IP, derive a nip.io name
# and then upgrade — the certificate can be issued up front and the plane
# installed once, the way RC2 does it.
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: dp-gateway-tls
  namespace: openchoreo-data-plane
spec:
  secretName: dp-gateway-tls
  issuerRef:
    name: ${TLS_ISSUER_NAME}
    kind: ClusterIssuer
  dnsNames:
    - "*.${AGENTS_DOMAIN}"
    - "${AGENTS_DOMAIN}"
  privateKey:
    rotationPolicy: Always
EOF
wait_for "DP TLS certificate" \
    kubectl wait --for=condition=Ready certificate/dp-gateway-tls \
    -n openchoreo-data-plane --timeout=300s

if ! check_helm_release openchoreo-data-plane openchoreo-data-plane; then
    # values-dp.yaml comes from the single-cluster k3d layout and pins the
    # gateway to 19080/19443, because there every plane shares one host load
    # balancer and they cannot all own 443. That is exactly the situation on
    # the local profile, so those ports are kept. On the cloud profile each
    # plane has its own LoadBalancer address and RC2 requires overriding them
    # back to 80/443 — without that, the install still looks completely
    # healthy (pods Running, certificates Ready, gateway PROGRAMMED=True)
    # while every published agent URL points at a port with nothing behind it
    # and fails with a connection timeout rather than a readable error.
    helm install openchoreo-data-plane \
        oci://ghcr.io/openchoreo/helm-charts/openchoreo-data-plane \
        --version ${OPENCHOREO_VERSION} \
        --namespace openchoreo-data-plane \
        --create-namespace \
        --set clusterAgent.tls.generateCerts=true \
        --set gateway.tls.enabled=true \
        --set "gateway.tls.hostname=*.${AGENTS_DOMAIN}" \
        --set "gateway.tls.certificateRefs[0].name=dp-gateway-tls" \
        --set gateway.httpPort="${DP_GW_HTTP_PORT}" \
        --set gateway.httpsPort="${DP_GW_HTTPS_PORT}" \
        --values https://raw.githubusercontent.com/wso2/agent-manager/amp/v${VERSION}/deployments/single-cluster/values-dp.yaml
fi

wait_for "Data Plane deployments" \
    kubectl wait --for=condition=Available deployment --all \
    -n openchoreo-data-plane --timeout=600s

DP_LB_IP=$(kubectl get svc gateway-default -n openchoreo-data-plane \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
DP_GW_PORTS=$(kubectl get svc gateway-default -n openchoreo-data-plane \
    -o jsonpath='{.spec.ports[*].port}' 2>/dev/null || echo "")
info "Data Plane gateway: ${DP_LB_IP:-<pending>} ports [${DP_GW_PORTS}]"
if ! echo " ${DP_GW_PORTS} " | grep -q " ${DP_GW_HTTP_PORT} "; then
    error "Data Plane gateway is not listening on ${DP_GW_HTTP_PORT} — agent URLs will time out"
fi
success "Agents domain: ${AGENTS_DOMAIN}"

CA_CERT=$(kubectl get secret cluster-agent-tls \
    -n openchoreo-data-plane -o jsonpath='{.data.ca\.crt}' | base64 -d)
kubectl apply -f - <<EOF
apiVersion: openchoreo.dev/v1alpha1
kind: ClusterDataPlane
metadata:
  name: default
  namespace: default
spec:
  planeID: default
  clusterAgent:
    clientCA:
      value: |
$(echo "$CA_CERT" | sed 's/^/        /')
  gateway:
    ingress:
      external:
        name: gateway-default
        namespace: openchoreo-data-plane
        http:
          host: "${AGENTS_DOMAIN}"
          listenerName: http
          port: ${DP_GW_HTTP_PORT}
        https:
          host: "${AGENTS_DOMAIN}"
          listenerName: https
          port: ${DP_GW_HTTPS_PORT}
  secretStoreRef:
    name: default
EOF
success "Data Plane registered"
verify_pods openchoreo-data-plane

# ── Step 10: Workflow Plane ──────────────────────────────────────────────────
step "OpenChoreo Workflow Plane (v${OPENCHOREO_VERSION})"
kubectl create namespace openchoreo-workflow-plane --dry-run=client -o yaml | kubectl apply -f -

CA_CRT=$(kubectl get secret cluster-gateway-ca \
    -n openchoreo-control-plane -o jsonpath='{.data.ca\.crt}' | base64 -d)
kubectl create configmap cluster-gateway-ca \
    --from-literal=ca.crt="$CA_CRT" \
    -n openchoreo-workflow-plane --dry-run=client -o yaml | kubectl apply -f -

TLS_CRT=$(kubectl get secret cluster-gateway-ca \
    -n openchoreo-control-plane -o jsonpath='{.data.tls\.crt}' | base64 -d)
TLS_KEY=$(kubectl get secret cluster-gateway-ca \
    -n openchoreo-control-plane -o jsonpath='{.data.tls\.key}' | base64 -d)
kubectl create secret generic cluster-gateway-ca \
    --from-literal=tls.crt="$TLS_CRT" \
    --from-literal=tls.key="$TLS_KEY" \
    --from-literal=ca.crt="$CA_CRT" \
    -n openchoreo-workflow-plane --dry-run=client -o yaml | kubectl apply -f -
success "CA certificates copied to workflow plane"

if ! check_helm_release openchoreo-workflow-plane openchoreo-workflow-plane; then
    helm install openchoreo-workflow-plane \
        oci://ghcr.io/openchoreo/helm-charts/openchoreo-workflow-plane \
        --version ${OPENCHOREO_VERSION} \
        --namespace openchoreo-workflow-plane \
        --create-namespace \
        --set clusterAgent.tls.generateCerts=true \
        `# The chart caps the Argo controller at cpu=50m/memory=64Mi, which is` \
        `# far too small for its 32 workflow workers and ~10 informers. The` \
        `# controller pins itself against both ceilings (measured: 47m/50m,` \
        `# 63Mi/64Mi), every API call queues for 20-40s ("Waited for K8S` \
        `# request"), and informer sync alone outlasts the liveness probe.` \
        `#` \
        `# It then self-destructs: Argo's /healthz returns 500 for any` \
        `# incomplete workflow older than HEALTHZ_AGE (default 5m), so a` \
        `# workflow the throttled controller cannot reach keeps the probe red` \
        `# and the probe keeps killing the controller. Observed at 97 restarts` \
        `# with two monitor workflows stuck at no status whatsoever.` \
        `#` \
        `# Nothing about this names CPU: agent builds and monitor analyses just` \
        `# sit "pending" forever while every pod reads Running or CrashLoopBackOff.` \
        `# Verified: with the limits below the same two workflows reconciled and` \
        `# succeeded in 11 seconds, and the controller idles at 1m CPU / 49Mi.` \
        --set argo-workflows.controller.resources.limits.cpu=500m \
        --set argo-workflows.controller.resources.limits.memory=256Mi \
        --set argo-workflows.controller.resources.requests.cpu=100m \
        --set argo-workflows.controller.resources.requests.memory=128Mi \
        --timeout 600s
fi
wait_for "Workflow Plane deployments" \
    kubectl wait --for=condition=Available deployment --all \
    -n openchoreo-workflow-plane --timeout=600s

BP_CA_CERT=$(kubectl get secret cluster-agent-tls \
    -n openchoreo-workflow-plane -o jsonpath='{.data.ca\.crt}' | base64 -d)
kubectl apply -f - <<EOF
apiVersion: openchoreo.dev/v1alpha1
kind: ClusterWorkflowPlane
metadata:
  name: default
  namespace: default
spec:
  planeID: default
  clusterAgent:
    clientCA:
      value: |
$(echo "$BP_CA_CERT" | sed 's/^/        /')
  secretStoreRef:
    name: default
EOF
success "Workflow Plane registered"
verify_pods openchoreo-workflow-plane

# ── Step 11: Observability Plane ─────────────────────────────────────────────
step "OpenChoreo Observability Plane (v${OPENCHOREO_VERSION}) — ~25 min"
kubectl create namespace openchoreo-observability-plane --dry-run=client -o yaml | kubectl apply -f -

CA_CRT=$(kubectl get secret cluster-gateway-ca \
    -n openchoreo-control-plane -o jsonpath='{.data.ca\.crt}' | base64 -d)
kubectl create configmap cluster-gateway-ca \
    --from-literal=ca.crt="$CA_CRT" \
    -n openchoreo-observability-plane --dry-run=client -o yaml | kubectl apply -f -

TLS_CRT=$(kubectl get secret cluster-gateway-ca \
    -n openchoreo-control-plane -o jsonpath='{.data.tls\.crt}' | base64 -d)
TLS_KEY=$(kubectl get secret cluster-gateway-ca \
    -n openchoreo-control-plane -o jsonpath='{.data.tls\.key}' | base64 -d)
kubectl create secret generic cluster-gateway-ca \
    --from-literal=tls.crt="$TLS_CRT" \
    --from-literal=tls.key="$TLS_KEY" \
    --from-literal=ca.crt="$CA_CRT" \
    -n openchoreo-observability-plane --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<'EOF'
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: opensearch-admin-credentials
  namespace: openchoreo-observability-plane
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: default
  target:
    name: opensearch-admin-credentials
  data:
  - secretKey: username
    remoteRef:
      key: opensearch-username
      property: value
  - secretKey: password
    remoteRef:
      key: opensearch-password
      property: value
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: observer-secret
  namespace: openchoreo-observability-plane
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: default
  target:
    name: observer-secret
  data:
  - secretKey: OPENSEARCH_USERNAME
    remoteRef:
      key: opensearch-username
      property: value
  - secretKey: OPENSEARCH_PASSWORD
    remoteRef:
      key: opensearch-password
      property: value
  - secretKey: UID_RESOLVER_OAUTH_CLIENT_SECRET
    remoteRef:
      key: observer-oauth-client-secret
      property: value
EOF
wait_for "ExternalSecrets sync" \
    kubectl wait -n openchoreo-observability-plane \
    --for=condition=Ready externalsecret/opensearch-admin-credentials \
    externalsecret/observer-secret --timeout=60s

kubectl apply -f https://raw.githubusercontent.com/wso2/agent-manager/amp/v${VERSION}/deployments/values/oc-collector-configmap.yaml \
    -n openchoreo-observability-plane

# Wildcard cert for the observability gateway. Issued before the install so
# the plane can come up with TLS in one pass, as RC2 does.
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: obs-gateway-tls
  namespace: openchoreo-observability-plane
spec:
  secretName: obs-gateway-tls
  issuerRef:
    name: ${TLS_ISSUER_NAME}
    kind: ClusterIssuer
  dnsNames:
    - "*.${BASE_DOMAIN}"
    - "${BASE_DOMAIN}"
  privateKey:
    rotationPolicy: Always
EOF
wait_for "OBS TLS certificate" \
    kubectl wait --for=condition=Ready certificate/obs-gateway-tls \
    -n openchoreo-observability-plane --timeout=300s

# security.oidc.issuer is set explicitly (RC2 leaves it to the chart default,
# which is a k3d hostname). jwksUrlTlsInsecureSkipVerify only when the chain
# is self-signed — RC2 moved it into its self-signed appendix.
OBS_TLS_SKIP=()
if [ "${TLS_MODE}" = "selfsigned" ]; then
    OBS_TLS_SKIP=(--set-string security.oidc.jwksUrlTlsInsecureSkipVerify=true)
fi

if ! check_helm_release openchoreo-observability-plane openchoreo-observability-plane; then
    # Same port story as the data plane: values-op.yaml pins 11080/11085 for
    # the shared-host k3d layout, which is right for the local profile and
    # wrong for a cloud one where this plane owns its own LoadBalancer.
    helm install openchoreo-observability-plane \
        oci://ghcr.io/openchoreo/helm-charts/openchoreo-observability-plane \
        --version ${OPENCHOREO_VERSION} \
        --namespace openchoreo-observability-plane \
        --create-namespace \
        --set clusterAgent.tls.generateCerts=true \
        --set gateway.tls.enabled=true \
        --set "gateway.tls.hostname=*.${BASE_DOMAIN}" \
        --set "gateway.tls.certificateRefs[0].name=obs-gateway-tls" \
        --set gateway.httpPort="${OBS_GW_HTTP_PORT}" \
        --set gateway.httpsPort="${OBS_GW_HTTPS_PORT}" \
        --set observer.controlPlaneApiUrl="${OPENCHOREO_API_URL}" \
        --set observer.extraEnv.AUTH_SERVER_BASE_URL="${THUNDER_PUBLIC_URL}" \
        --set security.oidc.issuer="${THUNDER_PUBLIC_URL}" \
        --set security.oidc.jwksUrl="${THUNDER_INTERNAL_URL}/oauth2/jwks" \
        --set security.oidc.tokenUrl="${THUNDER_INTERNAL_URL}/oauth2/token" \
        ${OBS_TLS_SKIP[@]+"${OBS_TLS_SKIP[@]}"} \
        --values https://raw.githubusercontent.com/wso2/agent-manager/amp/v${VERSION}/deployments/single-cluster/values-op.yaml \
        --timeout 25m
fi

wait_for "Observability Plane deployments" \
    kubectl wait --for=condition=Available deployment --all \
    -n openchoreo-observability-plane --timeout=900s

for sts in $(kubectl get statefulset -n openchoreo-observability-plane -o name 2>/dev/null); do
    kubectl rollout status "${sts}" -n openchoreo-observability-plane --timeout=900s
done

# Same Thunder >= 0.45 entitlement-claim fix as the Control Plane, applied to
# the Observability Plane's own "observer" deployment/ConfigMap (not to be
# confused with the AMP-specific Traces Observer extension installed later).
info "Patching observer-auth-config entitlement claim for Thunder >= 0.45..."
patched_yaml=$(kubectl get configmap observer-auth-config -n openchoreo-observability-plane -o yaml \
    | sed -E "s/claim:[[:space:]]*['\"]?sub['\"]?/claim: client_id/g")
echo "$patched_yaml" | kubectl apply --server-side --field-manager=helm --force-conflicts -f -

kubectl rollout restart deployment/observer -n openchoreo-observability-plane
kubectl rollout status deployment/observer -n openchoreo-observability-plane --timeout=120s

# Observability modules
info "Installing observability modules (logs, metrics, traces)..."

# OPENSEARCH_INITIAL_ADMIN_PASSWORD is what OpenSearch bootstraps its admin
# user with, and it has to be the same value the opensearch-admin-credentials
# ExternalSecret syncs out of OpenBao — otherwise the module installs fine and
# every query against it comes back 401.
OS_PW_ARGS=()
if [ -n "${OPENSEARCH_PASSWORD}" ]; then
    OS_PW_ARGS=(
        --set-string "openSearch.extraEnvs[0].name=OPENSEARCH_INITIAL_ADMIN_PASSWORD"
        --set-string "openSearch.extraEnvs[0].value=${OPENSEARCH_PASSWORD}"
    )
fi

helm upgrade --install observability-logs-opensearch \
    oci://ghcr.io/openchoreo/helm-charts/observability-logs-opensearch \
    --create-namespace --namespace openchoreo-observability-plane \
    --version 0.5.3 \
    --set openSearchSetup.openSearchSecretName="opensearch-admin-credentials" \
    --set adapter.openSearchSecretName="opensearch-admin-credentials" \
    ${OS_PW_ARGS[@]+"${OS_PW_ARGS[@]}"} \
    --timeout 10m

helm upgrade observability-logs-opensearch \
    oci://ghcr.io/openchoreo/helm-charts/observability-logs-opensearch \
    --namespace openchoreo-observability-plane --version 0.5.3 \
    --reuse-values --set fluent-bit.enabled=true --timeout 10m

# Same chart-default resource squeeze as the Argo controller (see the Workflow
# Plane step): prometheus-operator ships cpu=40m/memory=60Mi, and its liveness
# probe allows a 1-SECOND timeout on an HTTPS /healthz. A throttled operator
# cannot answer that in time, so the kubelet kills it — observed at 563
# restarts over three days, never once reaching Ready.
#
# The logs are actively misleading: the operator reports "received SIGTERM,
# exiting gracefully" followed by a wall of "client rate limiter Wait returned
# an error: context canceled" and a rejected ServiceMonitor, all of which are
# consequences of the kill, not causes. The give-away is in the pod events, not
# the logs: "Liveness probe failed: context deadline exceeded".
#
# Verified: with the limits below it reached Ready and stayed there.
helm upgrade --install observability-metrics-prometheus \
    oci://ghcr.io/openchoreo/helm-charts/observability-metrics-prometheus \
    --create-namespace --namespace openchoreo-observability-plane \
    --set kube-prometheus-stack.prometheusOperator.resources.limits.cpu=300m \
    --set kube-prometheus-stack.prometheusOperator.resources.limits.memory=256Mi \
    --set kube-prometheus-stack.prometheusOperator.resources.requests.cpu=50m \
    --set kube-prometheus-stack.prometheusOperator.resources.requests.memory=128Mi \
    --version 0.6.1 --timeout 10m

# 0.6.0, which RC3 now pins too — this script got here first, ahead of the
# guide, for the reason below. RC2 pinned 0.4.1. The 0.4.1 tracing adapter and
# the observer disagree on the shape of a span's `attributes`: the adapter
# returns an array, the observer unmarshals into a map, and every span details
# lookup fails with
#
#   json: cannot unmarshal array into Go struct field
#   TraceSpanDetailsResponse.attributes of type map[string]interface {}
#
# The damage is entirely on the READ path and is close to invisible. Ingest is
# unaffected — spans reach OpenSearch correctly attributed — but amp-observer
# fetches each trace's root span, gets a 500, skips the trace, and returns
# HTTP 200 with an empty list. The console shows "no traces" with no error
# anywhere, which reads exactly like a publishing failure and sends you to the
# gateway, the API key and the collector, all of which are fine.
#
# 0.6.0 fixes it. Verified on a live cluster: amp-observer went from
# "totalCount:0, returned:0" to "totalCount:4, returned:4" against unchanged
# data already in the index, with no errors in the observer log. The chart's
# value keys are unchanged between 0.4.1 and 0.6.0 (0.6.0 only adds
# global.imageRegistry and imagePullSecrets), so the three --set values below
# carry over as-is.
#
# The logs module above is a separate module and is not implicated in this. It
# tracks RC3's pin (0.5.3), raised from RC2's 0.4.1.
helm upgrade --install observability-traces-opensearch \
    oci://ghcr.io/openchoreo/helm-charts/observability-tracing-opensearch \
    --create-namespace --namespace openchoreo-observability-plane \
    --version 0.6.0 \
    --set openSearch.enabled=false \
    --set openSearchSetup.openSearchSecretName="opensearch-admin-credentials" \
    --set opentelemetry-collector.configMap.existingName="amp-opentelemetry-collector-config" \
    --timeout 10m

success "Observability modules installed"

OBS_LB_IP=$(kubectl get svc gateway-default -n openchoreo-observability-plane \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
info "Observability gateway: ${OBS_LB_IP:-<pending>} — ${OBS_API_PUBLIC_URL}"

# All three plane gateways now have their LoadBalancer addresses, so this is the
# earliest point a cloud operator can publish DNS — and they have to, because
# env-Thunder (later) refuses to run until the hostnames resolve. Printed here
# rather than only in the summary, which a first cloud run never reaches.
#
# Not a blocking prompt: DNS propagation is not something to hold a shell open
# for, and re-running the installer is the supported way to continue.
if [ "${PROFILE}" = "cloud" ]; then
    print_dns_records
    echo ""
    warning "Publish these now if you have not already."
    warning "env-Thunder provisioning below requires ${THUNDER_PUBLIC_HOST} to resolve"
    warning "and will stop the install if it does not. Re-run afterwards — it is idempotent."
fi

# Registered as ClusterObservabilityPlane, matching both the RC2 docs and the
# two `kubectl patch` calls below that reference it by that kind. (The alpha1
# script registered a plain `ObservabilityPlane` here, which did not match.)
OP_CA_CERT=$(kubectl get secret cluster-agent-tls \
    -n openchoreo-observability-plane -o jsonpath='{.data.ca\.crt}' | base64 -d)
kubectl apply -f - <<EOF
apiVersion: openchoreo.dev/v1alpha1
kind: ClusterObservabilityPlane
metadata:
  name: default
  namespace: default
spec:
  planeID: default
  clusterAgent:
    clientCA:
      value: |
$(echo "$OP_CA_CERT" | sed 's/^/        /')
  observerURL: http://observer.openchoreo-observability-plane.svc.cluster.local:8080
EOF

kubectl patch clusterdataplane default -n default --type merge \
    -p '{"spec":{"observabilityPlaneRef":{"kind":"ClusterObservabilityPlane","name":"default"}}}'
kubectl patch clusterworkflowplane default -n default --type merge \
    -p '{"spec":{"observabilityPlaneRef":{"kind":"ClusterObservabilityPlane","name":"default"}}}'
success "Observability Plane registered and linked"
verify_pods openchoreo-observability-plane

# ── Step 12: Verify Phase 1 ──────────────────────────────────────────────────
step "Verify OpenChoreo Installation"
echo ""
for ns in openchoreo-control-plane openchoreo-data-plane openchoreo-workflow-plane \
          openchoreo-observability-plane amp-thunder; do
    verify_pods "${ns}"
done
kubectl get clusterdataplane,clusterworkflowplane,clusterobservabilityplane -n default 2>/dev/null || true

# ============================================================================
# PHASE 2 — AGENT MANAGER
# ============================================================================
echo -e "\n${BOLD}════════════════════════════════════════${NC}"
echo -e "${BOLD} Phase 2: Agent Manager                 ${NC}"
echo -e "${BOLD}════════════════════════════════════════${NC}"

# ── Step 13: Gateway Operator ────────────────────────────────────────────────
step "Gateway Operator (v0.11.0)"

# The gateway controller encrypts stored credentials at rest and will not
# start without a key. It looks for one exact path —
# /app/data/aesgcm-keys/default-aesgcm256-v1.bin — so the Secret key must be
# named exactly that. Without it the controller crash-loops on "failed to
# initialize key manager: encryption key file not found for version
# aesgcm256-v1" and the gateway never programs, while the rest of the platform
# stays healthy; the only visible symptom is that agents cannot be invoked.
# Earlier gateway releases auto-generated a key in development mode; from
# 1.2.0-beta they do not, whatever developmentMode is set to.
#
# This key encrypts credentials the gateway holds. Losing it means those
# entries can no longer be decrypted — store it with the platform secrets.
if ! kubectl get secret gateway-encryption-keys -n "${DATA_PLANE_NS}" &>/dev/null; then
    GW_KEY_FILE=$(mktemp)
    openssl rand 32 > "${GW_KEY_FILE}"
    kubectl create secret generic gateway-encryption-keys \
        --namespace "${DATA_PLANE_NS}" \
        --from-file=default-aesgcm256-v1.bin="${GW_KEY_FILE}"
    rm -f "${GW_KEY_FILE}"
    success "Gateway encryption key created"
else
    info "Gateway encryption key already present — reusing"
fi

if ! check_helm_release gateway-operator "${DATA_PLANE_NS}"; then
    # gateway.helm.chartVersion is the ONLY thing that decides which gateway
    # chart the operator deploys — the APIGateway resource carries no chart
    # version. Inheriting the operator's default has historically produced a
    # chart whose templates never render the controller's control-plane
    # address, giving a gateway that installs, programs and serves traffic
    # while never registering with Agent Manager, so it never appears in the
    # gateway list.
    #
    # The image tags move independently of the chart: 1.2.2 is the newest
    # published gateway chart and its defaults point at 1.2.0 images, while
    # 1.2.1 controller and runtime images are published with no matching
    # chart. Pinning chartVersion alone would leave 1.2.0 images in place, so
    # all four image values below carry the runtime to 1.2.1. gateway.values is
    # the operator's passthrough into that chart — it is also how the
    # encryption key gets wired in.
    helm install gateway-operator \
        oci://ghcr.io/wso2/api-platform/helm-charts/gateway-operator \
        --version 0.11.0 \
        --namespace ${DATA_PLANE_NS} \
        --set logging.level=info \
        --set gatewayApi.installStandardCRDs=false \
        --set gateway.helm.chartVersion=1.2.2 \
        --set gateway.values.gateway.controller.image.repository=ghcr.io/wso2/api-platform/gateway-controller \
        --set gateway.values.gateway.controller.image.tag=1.2.1 \
        --set gateway.values.gateway.gatewayRuntime.image.repository=ghcr.io/wso2/api-platform/gateway-runtime \
        --set gateway.values.gateway.gatewayRuntime.image.tag=1.2.1 \
        --set gateway.values.gateway.controller.encryptionKeys.enabled=true \
        --set gateway.values.gateway.controller.encryptionKeys.secretName=gateway-encryption-keys \
        --timeout 600s
fi
wait_for "Gateway Operator" \
    kubectl wait --for=condition=Available \
    deployment -l app.kubernetes.io/name=gateway-operator \
    -n ${DATA_PLANE_NS} --timeout=300s

# The gateway pods only appear later (Step 20 creates the APIGateway), so this
# records what to check rather than checking now. RC2 is explicit that the
# chart version cannot be trusted here: the gateway chart stamps
# app.kubernetes.io/version=1.2.0 on pods whose images are 1.2.1, because the
# chart and the image tags move independently.
info "After Step 20, confirm the gateway images with:"
info "  kubectl get pods -n ${DATA_PLANE_NS} -o jsonpath='{..image}' | tr ' ' '\\n' | grep gateway-"

kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: wso2-api-platform-gateway-module
rules:
  - apiGroups: ["gateway.api-platform.wso2.com"]
    resources: ["restapis", "apigateways"]
    verbs: ["*"]
  - apiGroups: ["gateway.kgateway.dev"]
    resources: ["backends"]
    verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: wso2-api-platform-gateway-module
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: wso2-api-platform-gateway-module
subjects:
  - kind: ServiceAccount
    name: cluster-agent-dataplane
    namespace: ${DATA_PLANE_NS}
EOF
success "Gateway Operator RBAC configured"

# ── Step 14: Container registry ──────────────────────────────────────────────
# Build workflows push each agent image to this registry. RC2's chart default
# is host.k3d.internal:10082, which does not resolve on Rancher Desktop, and
# the failure surfaces only on the first agent build — long after the platform
# installs and verifies cleanly.
#
# RC2 requires two properties of whatever backs it: repositories must be
# created on push (each build pushes a uniquely-named <workflow-run>-image, so
# they cannot be pre-created — this is why ECR cannot be used), and the push
# credentials must be static (ECR's 12-hour tokens cannot be refreshed by
# anything in the pipeline). CNCF Distribution satisfies both.
#
# It ships with NO authentication. That is acceptable for a cluster-local
# evaluation registry reachable only from inside the cluster; put htpasswd in
# front of it before it carries anything real.
if [ "${DEPLOY_REGISTRY}" = "true" ]; then
    step "Container registry (CNCF Distribution)"
    # Deployed as plain manifests rather than a chart: Distribution needs no
    # templating here, and this avoids depending on a third-party chart repo
    # whose versioning and image locations are outside this project's control.
    kubectl create namespace "${REGISTRY_NS}" --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: registry-data
  namespace: ${REGISTRY_NS}
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 20Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: registry
  namespace: ${REGISTRY_NS}
  labels: { app: registry }
spec:
  replicas: 1
  selector:
    matchLabels: { app: registry }
  template:
    metadata:
      labels: { app: registry }
    spec:
      containers:
        - name: registry
          image: registry:3
          ports:
            - containerPort: 5000
          env:
            # Distribution creates repositories on push by default, which is
            # what the build pipeline needs — each run pushes a differently
            # named <workflow-run>-image.
            - name: REGISTRY_STORAGE_DELETE_ENABLED
              value: "true"
          volumeMounts:
            - name: data
              mountPath: /var/lib/registry
          readinessProbe:
            httpGet: { path: /v2/, port: 5000 }
            initialDelaySeconds: 5
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: registry-data
---
apiVersion: v1
kind: Service
metadata:
  name: registry
  namespace: ${REGISTRY_NS}
spec:
  type: NodePort
  selector: { app: registry }
  ports:
    # port and nodePort are deliberately the SAME number: pods reach this on
    # the ClusterIP at :${REGISTRY_PORT} and the node reaches it on
    # 127.0.0.1:${REGISTRY_PORT}, so one endpoint string works from both.
    - name: http
      port: ${REGISTRY_PORT}
      targetPort: 5000
      nodePort: ${REGISTRY_PORT}
EOF
    wait_for "Registry" \
        kubectl wait --for=condition=Available deployment/registry \
        -n "${REGISTRY_NS}" --timeout=300s

    # (a) Make the endpoint resolve on the NODE. Pods do not use this entry —
    # they resolve the same name through the coredns-custom rewrite from Step 0,
    # which points at the Service.
    REGISTRY_NODE_DNS_OK="false"
    if command -v rdctl &>/dev/null; then
        info "Pointing ${REGISTRY_HOST} at loopback inside the k3s VM..."
        if rdctl shell sudo sh -c \
            "grep -q ' ${REGISTRY_HOST}\$' /etc/hosts || echo '127.0.0.1 ${REGISTRY_HOST}' >> /etc/hosts" 2>/dev/null; then
            success "${REGISTRY_HOST} -> 127.0.0.1 in the VM's /etc/hosts"
            REGISTRY_NODE_DNS_OK="true"
        else
            warning "Could not edit the VM's /etc/hosts — agent image PULLS will fail to resolve ${REGISTRY_HOST}"
        fi

        # (b) Declare it insecure to dockerd and live-reload with SIGHUP. The
        # merge happens here rather than in the VM because the Alpine guest has
        # no python3/jq, and blindly overwriting daemon.json would discard
        # Rancher Desktop's own keys (seccomp-profile, containerd-snapshotter).
        CUR_DAEMON=$(rdctl shell sudo cat /etc/docker/daemon.json 2>/dev/null || echo '{}')
        NEW_DAEMON=$(printf '%s' "${CUR_DAEMON}" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
r=d.setdefault('insecure-registries',[])
if '${REGISTRY_ENDPOINT}' not in r: r.append('${REGISTRY_ENDPOINT}')
print(json.dumps(d, indent=2))
" 2>/dev/null || echo "")
        if [ -n "${NEW_DAEMON}" ] && rdctl shell sudo sh -c "cat > /etc/docker/daemon.json" <<<"${NEW_DAEMON}" 2>/dev/null; then
            rdctl shell sudo sh -c 'kill -HUP $(pidof dockerd)' 2>/dev/null || true
            sleep 5
            if rdctl shell sh -c "docker info 2>/dev/null | grep -q '${REGISTRY_ENDPOINT}'" 2>/dev/null; then
                success "dockerd reloaded via SIGHUP — ${REGISTRY_ENDPOINT} is an insecure registry (no restart needed)"
            else
                warning "dockerd did not pick up insecure-registries — restart Rancher Desktop before the first build"
            fi
        else
            warning "Could not update /etc/docker/daemon.json — image pulls will fail with"
            warning "  'http: server gave HTTP response to HTTPS client'"
        fi
    else
        warning "rdctl not found — configure the VM by hand:"
        warning "  echo '127.0.0.1 ${REGISTRY_HOST}' >> /etc/hosts"
        warning "  add ${REGISTRY_ENDPOINT} to insecure-registries in /etc/docker/daemon.json, then SIGHUP dockerd"
    fi

    # Prove the round trip now rather than at first build: the node must be
    # able to reach the registry API through the NodePort.
    if [ "${REGISTRY_NODE_DNS_OK}" = "true" ]; then
        if rdctl shell sh -c "wget -q -T5 -O- http://${REGISTRY_ENDPOINT}/v2/ >/dev/null 2>&1" 2>/dev/null; then
            success "Registry reachable from the node at ${REGISTRY_ENDPOINT}"
        else
            warning "Node cannot reach ${REGISTRY_ENDPOINT} yet — recheck before the first agent build"
        fi
    fi
fi
export REGISTRY_NODE_DNS_OK="${REGISTRY_NODE_DNS_OK:-false}"

# ── Step 15: Agent Manager Core ──────────────────────────────────────────────
step "Agent Manager (API + Console + PostgreSQL) v${VERSION}"
if ! check_helm_release amp "${AMP_NS}"; then
    # keyManager.issuer must be the PUBLIC Thunder URL (the chart default is a
    # k3d hostname): the authorization server the API advertises in its RFC
    # 9728 protected-resource metadata is derived from it.
    #
    # thunder.baseURL must also be the public URL, for a separate reason —
    # every admin identity call (users, roles, groups) requests a token scoped
    # to Thunder's System resource server via an RFC 8707 resource parameter
    # derived from this value, and Thunder only recognises the public URL as
    # that resource server's registered identifier. Anything else fails with
    # invalid_target. Since the API runs in-cluster and the public hostname
    # resolves there only via the CoreDNS rewrite (and not at all on some
    # clusters), thunder.resolveToHost says which address to actually dial
    # while still presenting thunder.baseURL on the wire.
    #
    # tlsEnabled selects between an Environment's http and https endpoint
    # variants when the API builds an agent's invoke URL. Left false on an
    # HTTPS platform the console publishes an http:// URL that the browser
    # then blocks as mixed content, with no error anywhere in the platform.
    helm install amp \
        oci://${HELM_CHART_REGISTRY}/wso2-agent-manager \
        --version ${VERSION} \
        --namespace ${AMP_NS} \
        --create-namespace \
        --set console.config.instrumentationUrl="${INSTRUMENTATION_URL}" \
        --set console.config.auth.baseUrl="${THUNDER_PUBLIC_URL}" \
        --set console.config.auth.signInRedirectURL="${CONSOLE_PUBLIC_URL}/login" \
        --set console.config.auth.signOutRedirectURL="${CONSOLE_PUBLIC_URL}/login" \
        --set console.config.apiBaseUrl="${API_PUBLIC_URL}" \
        --set console.ocIngress.hostname="${CONSOLE_PUBLIC_HOST}" \
        --set agentManagerService.ocIngress.hostname="${API_PUBLIC_HOST}" \
        --set agentManagerService.config.amObserverPublicURL="${OBS_API_PUBLIC_URL}" \
        --set agentManagerService.config.serverPublicURL="${API_PUBLIC_URL}" \
        --set agentManagerService.config.keyManager.issuer="${THUNDER_PUBLIC_URL}" \
        --set agentManagerService.config.keyManager.jwksUrl="${THUNDER_INTERNAL_URL}/oauth2/jwks" \
        --set agentManagerService.config.oidc.tokenUrl="${THUNDER_INTERNAL_URL}/oauth2/token" \
        --set agentManagerService.config.oidc.clientSecret="${AMP_API_CLIENT_SECRET}" \
        --set agentManagerService.config.thunder.baseURL="${THUNDER_PUBLIC_URL}" \
        --set agentManagerService.config.thunder.resolveToHost="${THUNDER_INTERNAL_URL#http://}" \
        --set agentManagerService.config.thunder.clientSecret="${AMP_SYSTEM_CLIENT_SECRET}" \
        --set agentManagerService.config.openChoreo.baseURL="${OPENCHOREO_API_URL}" \
        --set agentManagerService.config.tlsEnabled="${TLS_ENABLED_FLAG}" \
        --set-string console.config.tlsEnabled="${TLS_ENABLED_FLAG}" \
        `# Both chart defaults are the dev-mode root token "root", which does` \
        `# not exist once OpenBao is initialised for real. Without these the` \
        `# platform installs clean and then cannot store a single secret.` \
        --set-string agentManagerService.config.openbao.token="${BAO_ROOT_TOKEN}" \
        --set-string agentManagerService.config.workflowPlaneOpenbao.token="${BAO_ROOT_TOKEN}" \
        --timeout 1800s
fi

# NOTE: WORKFLOW_PLANE_OPENBAO_VERSION also has to be set on amp-api, but it is
# applied at the END of Step 21 rather than here. See the comment there.

wait_for "PostgreSQL" \
    kubectl wait --for=jsonpath='{.status.readyReplicas}'=1 \
    statefulset/amp-postgresql -n ${AMP_NS} --timeout=600s
wait_for "AMP API" \
    kubectl wait --for=condition=Available deployment/amp-api -n ${AMP_NS} --timeout=600s
wait_for "AMP Console" \
    kubectl wait --for=condition=Available deployment/amp-console -n ${AMP_NS} --timeout=600s
verify_pods "${AMP_NS}"

# ── Step 16: Agent Sandbox Module ────────────────────────────────────────────
# New in v1.0.0-alpha1 — provides the sandboxed-pod controller (isolation
# tiers) that deployed agents run in.
#
# Versions here are current as of 2026-08-31 and should NOT be chased upstream:
#
#   chart 0.1.1      the newest published; only 0.1.0 and 0.1.1 exist.
#   upstream v0.4.6  the chart's OWN default, not something stale RC2 pinned.
#                    kubernetes-sigs/agent-sandbox is already at v1.0.0
#                    (2026-08-28), but this cannot simply be bumped: the chart
#                    hardcodes its download URLs in
#                    templates/upstream-install.yaml as
#                    .../releases/download/<version>/manifest.yaml, and
#                    upstream RENAMED that asset. manifest.yaml exists in
#                    v0.4.6 and v0.5.0 and is gone from v0.5.4 onward,
#                    replaced by sandbox.yaml / sandbox-with-extensions.yaml.
#                    Setting upstream.version=v1.0.0 makes this chart's
#                    pre-install hook Job 404 fetching a file that no longer
#                    exists — and that hook is the one already prone to
#                    stalling on this Lima VM, so it is a nasty failure.
#
# The practical ceiling without patching the chart is v0.5.0. Unblocking a real
# bump needs a NEW agent-sandbox chart release that targets the new asset
# names, so the signal to watch is chart 0.1.2/0.2.0 appearing — then check
# whether its default upstream.version moved.
step "Agent Sandbox Module (v0.1.1)"
if ! check_helm_release agent-sandbox "${DATA_PLANE_NS}"; then
    # This chart's pre-install/pre-upgrade hook (a Job) both creates its own
    # RBAC/ServiceAccount AND does a live `kubectl apply` of the upstream
    # kubernetes-sigs/agent-sandbox manifest fetched from GitHub. Observed
    # hanging twice on this Lima VM before even the ServiceAccount is
    # created — same class of Helm/Lima-VM stall as cert-manager's
    # startupapicheck, just earlier in the hook lifecycle. Wrapped in
    # retry_cmd so a Ctrl+C'd/failed attempt self-heals on retry instead of
    # requiring a manual script restart.
    retry_cmd "Agent Sandbox Module install" 3 15 \
        helm upgrade --install agent-sandbox \
        oci://ghcr.io/openchoreo/helm-charts/agent-sandbox \
        --version 0.1.1 \
        --namespace ${DATA_PLANE_NS} \
        --create-namespace \
        --wait \
        --timeout 10m \
        --set namespace=openchoreo-control-plane \
        --set dataPlaneNamespace=${DATA_PLANE_NS} \
        --set dataPlaneServiceAccount=cluster-agent-dataplane \
        --set upstream.version=v0.4.6
fi
# `--for=condition=available` is not enough on its own here. A Deployment
# reports Available as soon as its minimum replicas are ready, and this chart's
# hook applies the upstream kubernetes-sigs manifest, which patches the
# controller Deployment AFTER it first comes up — so the wait is satisfied by
# the first pod while a second rollout is already starting, and verify_pods
# then reports "1 pod(s) not yet Running / ContainerCreating" for a controller
# that is actually fine. rollout status waits for the rollout itself to
# complete, which covers both generations.
wait_for "Agent Sandbox controller" \
    kubectl wait -n agent-sandbox-system \
    --for=condition=available --timeout=180s \
    deployment/agent-sandbox-controller
kubectl rollout status deployment/agent-sandbox-controller \
    -n agent-sandbox-system --timeout=300s >/dev/null 2>&1 \
    && success "Agent Sandbox controller rollout complete" \
    || warning "Agent Sandbox controller rollout still settling"
verify_pods agent-sandbox-system

# ── Step 17: Platform Resources ──────────────────────────────────────────────
step "Platform Resources (v${VERSION})"
if ! check_helm_release amp-platform-resources "${DEFAULT_NS}"; then
    # global.oauth.tokenUrl and global.apiServer.url both default to
    # http://host.k3d.internal:8080, which resolves on neither profile.
    # Nothing earlier in the install touches them, so a platform that installs
    # and verifies cleanly still cannot complete a single build: the
    # workflow's generate-workload step prints "Failed to get access token:"
    # with an empty body — a connection failure, not an authentication one —
    # and the build ends with "cannot save parameter
    # /mnt/vol/workload-cr.yaml". The hostHeader values go with them because
    # the in-cluster services route by Host header.
    #
    # apiPlatformGateway.namespace must match where Step 19 installs the
    # gateway extension (${DATA_PLANE_NS}, that chart's own default). Leaving
    # it empty derives the per-org-env convention <org>-<env> instead, and
    # nothing reports an error: the agent starts and serves requests while
    # every span batch fails inside it with "Failed to resolve
    # '…-gw-gateway-gateway-runtime.default-default'", so the Traces view
    # stays empty, and the backend agent routes forward to has no reachable
    # host.
    #
    # apiPlatformGatewayVhost is not mentioned in the RC2 docs, but its default
    # (gateway.localhost:19080) is another k3d placeholder — it is what the
    # externally reachable gateway URLs are built from, and add-environment.sh
    # prefixes "<env>-<org>." onto the host the same way gatewayBaseDomain
    # works. Pointed at the agents domain so those URLs match the gateway this
    # install actually registers.
    #
    # environment.gateway.*.port must be the port the matching listener
    # actually serves — 19080/19443 on the local profile, 80/443 in the cloud.
    # Putting 443 on the http variant is the trap: the console then publishes
    # http://<host>:443, an HTTP scheme on the TLS port, which a browser
    # refuses to call from an HTTPS console as mixed content, with nothing in
    # the platform reporting an error.
    helm install amp-platform-resources \
        oci://${HELM_CHART_REGISTRY}/wso2-amp-platform-resources-extension \
        --version ${VERSION} \
        --namespace ${DEFAULT_NS} \
        --set global.oauth.tokenUrl="${THUNDER_INTERNAL_URL}/oauth2/token" \
        --set global.oauth.hostHeader="amp-thunder-extension-service.${THUNDER_NS}.svc.cluster.local" \
        --set global.apiServer.url="${OPENCHOREO_API_URL}" \
        --set global.apiServer.hostHeader="${OPENCHOREO_API_HOST}" \
        --set apiPlatformGateway.namespace="${DATA_PLANE_NS}" \
        --set apiPlatformGatewayVhost.host="${AGENTS_DOMAIN}" \
        --set apiPlatformGatewayVhost.port="${DP_GW_HTTP_PORT}" \
        --set global.registry.endpoint="${REGISTRY_ENDPOINT}" \
        --set global.defaultResources.registry.tlsVerify="${REGISTRY_TLS_VERIFY}" \
        --set environment.gateway.http.host="${AGENTS_DOMAIN}" \
        --set environment.gateway.http.port="${DP_GW_HTTP_PORT}" \
        --set environment.gateway.https.host="${AGENTS_DOMAIN}" \
        --set environment.gateway.https.port="${DP_GW_HTTPS_PORT}" \
        --timeout 1800s
fi
success "Platform Resources installed"

# ── Step 18: Observability Extension ─────────────────────────────────────────
step "Observability Extension — Traces Observer (v${VERSION})"
if ! check_helm_release amp-observability-traces "${OBSERVABILITY_NS}"; then
    # v1.0.0-alpha1 renamed this chart's values from tracesObserver.* to
    # amObserver.* (and the deployment from amp-traces-observer to
    # amp-observer).
    #
    # ocIngress.hostname now carries a real hostname on both profiles, so the
    # route the chart renders is actually usable. (Under the old port-forward
    # setup this was deliberately skipped, since there was no public host to
    # pass and the chart default traces.amp.localhost resolved to 127.0.0.1
    # rather than to the observability-plane gateway.) publicUrl must match
    # how clients actually reach the service: it is the RFC 9728 resource
    # identifier echoed in WWW-Authenticate on 401s.
    #
    # auth.issuer must be the PUBLIC Thunder URL, not the in-cluster service
    # URL. The observer validates the same user token the console and amctl
    # send to the Agent Manager API, so its issuer has to match
    # agentManagerService.config.keyManager.issuer exactly — the two are set
    # from the same variable here for that reason. Leave it at the chart
    # default and the traces page stays empty while the observer logs "JWT
    # validation failed ... invalid issuer" on GET /api/v1/traces. This is the
    # retrieval leg only; publishing goes through the OTel gateway and is
    # unaffected.
    #
    # oauth.authorizationServers is derived from auth.issuer by the RC2 chart,
    # so setting it is redundant — kept explicit because the chart requires
    # the two to agree and this makes that visible.
    #
    # observer.idpClientSecret is the observer's own outbound identity for
    # calls to the OpenChoreo observer, and must match the am-observer-client
    # secret seeded into Thunder in Step 7.
    #
    # observer.baseUrl and observer.idpTokenUrl are left at their chart
    # defaults: both already point at the right in-cluster Services. (Note
    # there is no controlPlaneApiUrl/observabilityPlaneUrl value on this chart
    # — those belong to the openchoreo-observability-plane chart, not this one.)
    #
    # auth.audience needs no override: Thunder v0.45+ stamps the resource-server
    # identifier "amp" as the audience on scoped tokens, and the chart default
    # ("amp,amp-api-client") already covers that.
    helm install amp-observability-traces \
        oci://${HELM_CHART_REGISTRY}/wso2-amp-observability-extension \
        --version ${VERSION} \
        --namespace ${OBSERVABILITY_NS} \
        --set amObserver.ocIngress.hostname="${OBS_API_PUBLIC_HOST}" \
        --set amObserver.publicUrl="${OBS_API_PUBLIC_URL}" \
        --set amObserver.auth.issuer="${THUNDER_PUBLIC_URL}" \
        --set amObserver.oauth.authorizationServers="${THUNDER_PUBLIC_URL}" \
        --set amObserver.observer.idpClientSecret="${AM_OBSERVER_CLIENT_SECRET}" \
        --timeout 1800s
fi
wait_for "Traces Observer" \
    kubectl wait --for=condition=Available deployment/amp-observer \
    -n ${OBSERVABILITY_NS} --timeout=600s

# ── Step 19: Evaluation Extension ────────────────────────────────────────────
step "Evaluation Extension (v${VERSION})"
if ! check_helm_release amp-evaluation-extension "${BUILD_CI_NS}"; then
    helm install amp-evaluation-extension \
        oci://${HELM_CHART_REGISTRY}/wso2-amp-evaluation-extension \
        --version ${VERSION} \
        --namespace ${BUILD_CI_NS} \
        --timeout 1800s
fi
success "Evaluation Extension installed"

# ── Step 20: API Platform Gateway Extension ───────────────────────────────────
step "API Platform Gateway Extension (v${VERSION})"
# The bootstrap job authenticates to the Agent Manager API as amp-api-client.
# Passing the secret through a Secret reference keeps it out of Helm release
# history.
kubectl create secret generic gateway-idp-credentials \
    --namespace "${DATA_PLANE_NS}" \
    --from-literal=client-id=amp-api-client \
    --from-literal=client-secret="${AMP_API_CLIENT_SECRET}" \
    --dry-run=client -o yaml | kubectl apply -f -

if ! check_helm_release api-platform-default-default "${DATA_PLANE_NS}"; then
    # ── gateway.vhost AND gateway.hostname ARE WRITE-ONCE ────────────────────
    # The bootstrap job writes them into Agent Manager at first registration
    # only. On every later run it finds the gateway already present, logs
    # "already exists", and exits without reconciling the record. A `helm
    # upgrade` with corrected values changes nothing and reports no error —
    # the console simply keeps showing whatever was registered the first time,
    # which is what an operator would copy when wiring an external caller.
    # Correcting it afterwards means deleting the gateway registration and
    # re-registering. The chart defaults are the k3d addresses
    # (http://default-default.gateway.localhost:19080).
    #
    # gateway.type=BOTH registers this gateway for inbound and outbound
    # traffic, which is what a single-gateway environment needs. The role is
    # likewise written once at registration and never rewritten.
    #
    # developmentMode=false turns off the relaxed security checks the chart
    # enables by default; it depends on the encryption key created in Step 13
    # and fails immediately without one ("encryptionKeys must be enabled:
    # at-rest encryption is mandatory"). Set here rather than hardened
    # afterwards, so the gateway is never registered in a relaxed state.
    #
    # The chart's pre-install hook (bootstrap Job) looks up the 'default'
    # Environment via the Agent Manager API, which reads it from OpenChoreo.
    # That Environment CR was just created a couple of steps ago (Platform
    # Resources) and can take a little while to propagate through to the
    # API, so the bootstrap Job — and therefore this helm install — can fail
    # on the first try even though nothing is actually broken. Retry the
    # whole install (helm upgrade --install, so a failed release can be
    # retried) rather than requiring a manual re-run of the script.
    retry_cmd "API Platform Gateway Extension install" 4 20 \
        helm upgrade --install api-platform-default-default \
        oci://${HELM_CHART_REGISTRY}/wso2-amp-api-platform-gateway-extension \
        --version ${VERSION} \
        --namespace ${DATA_PLANE_NS} \
        --set agentManager.orgName=default \
        --set gateway.environment=default \
        --set gateway.type=BOTH \
        --set developmentMode=false \
        --set gateway.vhost="${SCHEME}://${AGENTS_GW_HOST}${DP_PORT}" \
        --set gateway.hostname="${AGENTS_GW_HOST}" \
        --set agentManager.idp.existingSecret=gateway-idp-credentials \
        --timeout 1800s
fi
wait_for "API Platform bootstrap job" \
    kubectl wait --for=condition=complete job/api-platform-default-default-bootstrap \
    -n ${DATA_PLANE_NS} --timeout=300s

# No extra HTTPRoute is needed for OTLP ingest. The extension renders its own
# <release>-otel-restapi in the data-plane namespace, serving /otel on the
# gateway hostname registered above — which is exactly what
# INSTRUMENTATION_URL points at. (The alpha1 script hand-rolled a separate
# 'otel-gateway-external' HTTPRoute because the registered hostname was the
# chart's .localhost placeholder and therefore unusable; with the hostname set
# correctly that workaround is obsolete.)
#
# The standalone otel-collector-rest-api.yaml manifest in the docs targets the
# per-environment <org>-<env> namespace, which does not exist until the first
# agent is deployed there — do not apply it for the default environment.
success "OTLP ingest served by the chart's own route at ${INSTRUMENTATION_URL}"

# Verify gateway status. Polled rather than read once: the bootstrap Job
# completing does not mean the controller has reconciled the APIGateway yet, so
# a single read right here reports Programmed=False on a gateway that becomes
# Ready seconds later.
info "Waiting for the API Gateway to be Programmed..."
GW_STATUS=""
GW_ELAPSED=0
while [ ${GW_ELAPSED} -lt 300 ]; do
    GW_STATUS=$(kubectl get apigateway api-platform-default-default \
        -n ${DATA_PLANE_NS} -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' \
        2>/dev/null || echo "")
    [ "${GW_STATUS}" = "True" ] && break
    sleep 10
    GW_ELAPSED=$((GW_ELAPSED+10))
done
if [ "${GW_STATUS}" = "True" ]; then
    success "API Gateway status: Programmed (after ${GW_ELAPSED}s)"
else
    warning "API Gateway not Programmed after ${GW_ELAPSED}s (status: ${GW_STATUS:-unknown})"
fi

# Verify the images actually running, not the chart version. The gateway chart
# labels its pods app.kubernetes.io/version=1.2.0 even when the images are
# 1.2.1, so the label is actively misleading — RC2 says to check the images.
GW_IMAGES=$(kubectl get pods -n "${DATA_PLANE_NS}" -o jsonpath='{..image}' 2>/dev/null \
    | tr ' ' '\n' | grep -E 'gateway-(controller|runtime)' | sort -u)
if [ -n "${GW_IMAGES}" ]; then
    if echo "${GW_IMAGES}" | grep -q ':1\.2\.1$'; then
        success "Gateway images pinned: $(echo "${GW_IMAGES}" | tr '\n' ' ')"
    else
        warning "Gateway images are NOT 1.2.1: $(echo "${GW_IMAGES}" | tr '\n' ' ')"
        warning "The chart default (1.2.0) won — check the four image.tag overrides in Step 13"
    fi
fi

# ── Step 21: Wire the remaining public endpoints ─────────────────────────────
# Two settings are not covered by the install steps above, plus the values
# that later Environments read when they are created.
step "Wiring public endpoints"

# The cp. hostname on the control-plane gateway route, so the console renders
# the right setup commands for external AI gateways.
# host.docker.internal is kept alongside the real hostname: it is what serves
# gateways started from the console's Docker quick start on this machine, and
# --set on a list replaces the whole thing rather than appending.
retry_cmd "Gateway management endpoint" 3 15 \
    helm upgrade amp oci://${HELM_CHART_REGISTRY}/wso2-agent-manager \
    --version ${VERSION} \
    --namespace ${AMP_NS} \
    --reuse-values \
    --set "agentManagerService.ocIngress.gatewayMgmt.hostnames={${CP_GW_PUBLIC_HOST},host.docker.internal}" \
    --set console.config.gatewayControlPlaneUrl="${CP_GW_PUBLIC_URL}"

# Point the default Environment's gateway at the agents domain. The
# Environment's gateway binding WHOLLY REPLACES the data plane's rather than
# merging with it, so both the http and https variants have to be given, each
# with the port its own listener serves.
retry_cmd "Default environment gateway endpoints" 3 15 \
    helm upgrade amp-platform-resources oci://${HELM_CHART_REGISTRY}/wso2-amp-platform-resources-extension \
    --version ${VERSION} \
    --namespace ${DEFAULT_NS} \
    --reuse-values \
    --set global.oauth.tokenUrl="${THUNDER_INTERNAL_URL}/oauth2/token" \
    --set environment.gateway.http.host="${AGENTS_DOMAIN}" \
    --set environment.gateway.http.port="${DP_GW_HTTP_PORT}" \
    --set environment.gateway.https.host="${AGENTS_DOMAIN}" \
    --set environment.gateway.https.port="${DP_GW_HTTPS_PORT}"

# Environments created LATER (via add-environment.sh or the console) read
# their hostnames from Agent Manager's own config, which otherwise still holds
# the chart's placeholder defaults. Record the same values there. Skipping
# this is invisible until a second environment exists, at which point its
# agents are published on am-gateway.localhost: the console shows an empty
# invoke URL and try-out returns 405 against its own host.
#
# The idpHostBaseDomain pair is what makes the API and Console agree that an
# environment's identity URL is <handle>.${BASE_DOMAIN} rather than the
# amp.localhost default.
#
# RENAMED IN RC3: this was thunderHostBaseDomain through RC2. The chart carries
# a values schema, so the old name is a hard failure, not a silently ignored
# key — "additional properties 'thunderHostBaseDomain' not allowed". Note the
# rename is confined to the Helm values: add-environment-thunder.sh still reads
# the environment variable THUNDER_HOST_BASE_DOMAIN (checked against the rc3
# copy of that script), so the export further down is NOT the same name and
# must not be changed with it.
#
# gatewayBaseDomain is what add-environment.sh prefixes "<env>-<org>." onto,
# so pointing it at ${AGENTS_DOMAIN} makes an added environment's gateway land
# on the same pattern as the default one (default-default.${AGENTS_DOMAIN}) —
# already covered by the data-plane wildcard certificate and, on the local
# profile, by the CoreDNS rewrite. RC2 suggests a separate otel.<base> domain
# here instead, which would need its own DNS record and certificate coverage.
#
# agentsHttpPort/agentsHttpsPort/gatewayVhostPort and console tlsEnabled are
# STRINGS in this chart (unlike agentManagerService.config.tlsEnabled, which is
# a bool), so they go through --set-string; a plain --set would coerce them to
# numbers/booleans and change how the templates render them.
retry_cmd "Agent Manager environment defaults" 3 15 \
    helm upgrade amp oci://${HELM_CHART_REGISTRY}/wso2-agent-manager \
    --version ${VERSION} \
    --namespace ${AMP_NS} \
    --reuse-values \
    --set agentManagerService.config.agentsBaseDomain="${AGENTS_DOMAIN}" \
    --set-string agentManagerService.config.agentsHttpPort="${DP_GW_HTTP_PORT}" \
    --set-string agentManagerService.config.agentsHttpsPort="${DP_GW_HTTPS_PORT}" \
    --set agentManagerService.config.gatewayBaseDomain="${AGENTS_DOMAIN}" \
    --set-string agentManagerService.config.gatewayVhostScheme="${SCHEME}" \
    --set-string agentManagerService.config.gatewayVhostPort="$([ "${SCHEME}" = "https" ] && echo "${DP_GW_HTTPS_PORT}" || echo "${DP_GW_HTTP_PORT}")" \
    --set agentManagerService.config.idpHostBaseDomain="${BASE_DOMAIN}" \
    --set agentManagerService.config.tlsEnabled="${TLS_ENABLED_FLAG}" \
    --set console.config.idpHostBaseDomain="${BASE_DOMAIN}" \
    --set-string console.config.tlsEnabled="${TLS_ENABLED_FLAG}"

# WORKFLOW_PLANE_OPENBAO_VERSION is not rendered by the RC2 chart: its
# `openbao` values block carries `version: v2` while `workflowPlaneOpenbao`
# has no version key at all, so the workflow-plane KV client runs without an
# explicit version where the platform-plane one gets v2.
#
# DO NOT credit this with fixing "unexpected error: status 501" — it does not.
# That 501 is openchoreo-api's, returned by its secrets endpoint when
# features.secretManagement is off (see Step 8), and it persisted verbatim
# with this variable set. Setting it here is precautionary version-pinning
# only. `strings` on the amp-api binary does not show this name at all, so it
# may well be read under a different key or not at all; it is kept because it
# is free and idempotent, not because it is known to do anything.
#
# THIS MUST STAY AFTER THE LAST `helm upgrade amp`. There is no chart value to
# set it through, so it goes on with `kubectl set env` — and every subsequent
# `helm upgrade` re-renders the pod template from the chart and silently drops
# it, even with --reuse-values (that flag reuses VALUES, not manual edits to
# the rendered objects).
#
# Applied unconditionally because `kubectl set env` is idempotent — it only
# triggers a rollout when the value actually changes. The wait below covers
# that rollout.
info "Setting WORKFLOW_PLANE_OPENBAO_VERSION (absent from the RC2 chart)..."
if kubectl set env deployment/amp-api -n "${AMP_NS}" WORKFLOW_PLANE_OPENBAO_VERSION=v2 >/dev/null 2>&1; then
    success "WORKFLOW_PLANE_OPENBAO_VERSION=v2 set on amp-api"
else
    warning "Could not set WORKFLOW_PLANE_OPENBAO_VERSION on amp-api (precautionary only)"
fi

wait_for "Agent Manager after endpoint wiring" \
    kubectl wait --for=condition=Available deployment/amp-api -n ${AMP_NS} --timeout=300s
# `kubectl wait ... Available` can pass on the OLD ReplicaSet while the env
# rollout is still starting, so wait on the rollout itself too.
wait_for "Agent Manager rollout" \
    kubectl rollout status deployment/amp-api -n ${AMP_NS} --timeout=300s

# ── Step 22: Provision env-Thunder for the default Environment ───────────────
# Every Environment needs its own dedicated Thunder instance, separate from the
# platform Thunder installed in Phase 1 (which only handles console and API
# login). This one issues each agent its own OAuth2 credential (AgentID) in
# that Environment. Without it agents can still be created but never get an
# AgentID, and Agent Manager keeps retrying and failing in the background with
# nothing surfaced in the UI.
step "Provisioning env-Thunder for the default Environment"

# Release name and namespace are both "<release>-<org>-<env>" and are fixed by
# thunder-naming.sh. Defined up front because the log watcher below needs the
# namespace before the chart creates it.
export ENV_THUNDER_RELEASE="amp-thunder-default-default"
ENV_THUNDER_RELEASE_NS="${ENV_THUNDER_RELEASE}"

ENV_THUNDER_DIR="$(mktemp -d)"
ADD_ENV_THUNDER="${ENV_THUNDER_DIR}/add-environment-thunder.sh"
SCRIPTS_BASE_URL="https://raw.githubusercontent.com/wso2/agent-manager/amp/v${VERSION}/deployments/scripts"

# On the cloud profile this step reaches platform Thunder over TLS by hostname
# (the openssl s_client below), so DNS has to be live before it runs. The local
# profile does not — its two HTTP calls go through the port-forwards started
# below, which is why a missing /etc/hosts block earlier was only a warning.
if [ "${PROFILE}" = "cloud" ]; then
    if ! dig +short "${THUNDER_PUBLIC_HOST}" | grep -q .; then
        error "${THUNDER_PUBLIC_HOST} does not resolve — publish the DNS records before this step"
        # Reprint with the live addresses. Exiting here skips the summary, so
        # without this the operator is told to publish records and never shown
        # what to point them at.
        print_dns_records
        echo ""
        info "Re-run the installer once DNS has propagated; it is idempotent."
        exit 1
    fi
    success "${THUNDER_PUBLIC_HOST} resolves"
fi

# thunder-naming.sh and ams-auth.sh are downloaded as SIBLINGS deliberately.
# The script prefers local siblings and otherwise falls back to fetching them
# from .../agent-manager/main/deployments/scripts — the main branch, not this
# release — so without this it could pair rc2's provisioning logic with a newer
# naming library and derive a different issuer than the one registered with the
# gateway two steps below. SCRIPT_BASE_URL is pinned as well, belt and braces.
if curl -fsSL "${SCRIPTS_BASE_URL}/add-environment-thunder.sh" -o "${ADD_ENV_THUNDER}" \
   && curl -fsSL "${SCRIPTS_BASE_URL}/thunder-naming.sh" -o "${ENV_THUNDER_DIR}/thunder-naming.sh" \
   && curl -fsSL "${SCRIPTS_BASE_URL}/ams-auth.sh" -o "${ENV_THUNDER_DIR}/ams-auth.sh"; then

    # ── PATCH_RC2_THUNDER_PORT ───────────────────────────────────────────────
    # RC2 equates "TLS" with "port 443". thunder_issuer() in thunder-naming.sh
    # emits https://<host> with no port, and add-environment-thunder.sh pins
    # gate_client_port=443 to match it. Neither is overridable by environment
    # variable, and smuggling the port through THUNDER_HOST_BASE_DOMAIN does not
    # work — the same value becomes the HTTPRoute hostname, which cannot carry
    # one. So patch both copies here, in the temp dir we just downloaded them to.
    #
    # Safe to do because SCRIPTS_BASE_URL is pinned to this exact release, and
    # each patch asserts its target was present: if upstream rewrites either
    # function the install stops here rather than minting an issuer on the wrong
    # port. That matters more than usual — the issuer is immutable once minted,
    # so getting it wrong costs a full reinstall, not an upgrade.
    if [ "${SCHEME}" = "https" ] && [ "${CP_GW_HTTPS_PORT}" != "443" ]; then
        ENV_THUNDER_NAMING="${ENV_THUNDER_DIR}/thunder-naming.sh"

        if grep -qF "printf 'https://%s' \"\$host\"" "${ENV_THUNDER_NAMING}"; then
            sed -i.bak \
                -e "s@printf 'https://%s' \"\$host\"@printf 'https://%s:${CP_GW_HTTPS_PORT}' \"\$host\"@" \
                "${ENV_THUNDER_NAMING}"
            success "thunder_issuer() patched to port ${CP_GW_HTTPS_PORT}"
        else
            error "thunder-naming.sh no longer contains the expected thunder_issuer() body"
            error "Refusing to continue: the env-Thunder issuer is immutable once minted."
            exit 1
        fi

        if grep -qE '^[[:space:]]*gate_client_port=443[[:space:]]*$' "${ADD_ENV_THUNDER}"; then
            sed -i.bak \
                -e "s@^\([[:space:]]*\)gate_client_port=443[[:space:]]*\$@\1gate_client_port=${CP_GW_HTTPS_PORT}@" \
                "${ADD_ENV_THUNDER}"
            success "gate_client_port patched to ${CP_GW_HTTPS_PORT}"
        else
            error "add-environment-thunder.sh no longer pins gate_client_port=443"
            error "Refusing to continue: sign-in links would point at the wrong port."
            exit 1
        fi
    fi

    # ── PLATFORM_THUNDER_JWKS_URL MUST BE https:// ───────────────────────────
    # env-Thunder validates this at config load and refuses anything else:
    #
    #   Failed to load configurations
    #   error="trusted_issuer.jwks_url must use https (got http://...);
    #          http is only allowed for localhost"
    #
    # ...which crash-loops the chart's pre-install setup Job until it hits its
    # backoff limit, at which point the Job DELETES its pod — so `kubectl logs`
    # comes back empty and the only visible symptom is
    # "failed pre-install: job ... BackoffLimitExceeded".
    #
    # So this is the PUBLIC url, not THUNDER_INTERNAL_URL: the in-cluster
    # Service is plain HTTP on 8090 and is rejected outright. On the local
    # profile that means the control-plane gateway's HTTPS listener, which
    # already exists (the wildcard cp-gateway-tls cert is bound to it) and is
    # simply unused while everything human-facing goes over plain HTTP.
    # Verified in-cluster: the CoreDNS rewrite resolves the hostname and the
    # endpoint returns a valid JWKS.
    #
    # Note this is only the jwks_url. trusted_issuer.issuer stays plain HTTP,
    # because it has to match the `iss` platform Thunder actually stamps into
    # tokens — which is frozen at THUNDER_PUBLIC_URL.
    if [ "${CP_GW_HTTPS_PORT}" = "443" ]; then
        ENV_THUNDER_JWKS_URL="https://${THUNDER_PUBLIC_HOST}/oauth2/jwks"
    else
        ENV_THUNDER_JWKS_URL="https://${THUNDER_PUBLIC_HOST}:${CP_GW_HTTPS_PORT}/oauth2/jwks"
    fi
    info "Platform Thunder JWKS for env-Thunder: ${ENV_THUNDER_JWKS_URL}"

    # The CA that signs that endpoint has to be trusted inside env-Thunder's
    # pod. Read straight from the cert-manager secret rather than RC2's
    # `openssl s_client` recipe: the secret works before /etc/hosts or public
    # DNS exists, and is the actual CA rather than whatever is being served.
    # (The script's own auto-detect looks for amp-local-root-ca-secret, a name
    # this installer never creates, so it has to be passed explicitly.)
    #
    # No CURL_CA_BUNDLE handling is needed: every call this script makes from
    # THIS machine goes to the plain-HTTP port-forwards below.
    ENV_THUNDER_CA_ARGS=()
    if [ "${TLS_MODE}" = "acme-dns01" ]; then
        ENV_THUNDER_CA_ARGS=(SKIP_CA_BUNDLE_TRUST=true)
    else
        PLATFORM_THUNDER_CA_PEM="$(kubectl get secret openchoreo-ca-secret -n cert-manager \
            -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d 2>/dev/null || echo "")"
        if [ -n "${PLATFORM_THUNDER_CA_PEM}" ]; then
            export PLATFORM_THUNDER_CA_PEM
            success "Platform CA read from openchoreo-ca-secret"
        else
            warning "Could not read openchoreo-ca-secret — env-Thunder may reject the JWKS certificate"
        fi
    fi

    # Capture the setup Job's logs. The Job deletes its pod on
    # BackoffLimitExceeded and setup.sh runs with SILENT_MODE=true, so without
    # this a failure leaves nothing to read. The bootstrap failure path does
    # `cat` its log unconditionally, so streaming the pod is enough to catch it.
    ENV_THUNDER_LOG=/tmp/env-thunder-setup.log
    : > "${ENV_THUNDER_LOG}"
    ( for _ in $(seq 1 400); do
        _p=$(kubectl get pods -n "${ENV_THUNDER_RELEASE_NS}" \
                -l job-name="${ENV_THUNDER_RELEASE_NS}-setup" -o name 2>/dev/null | head -1)
        [ -n "${_p}" ] && kubectl logs -n "${ENV_THUNDER_RELEASE_NS}" "${_p}" \
                -c setup -f >> "${ENV_THUNDER_LOG}" 2>&1
        sleep 2
      done ) &
    ENV_THUNDER_WATCHER=$!

    # Port-forwards are (re)established INSIDE each attempt. They are what the
    # script dials for AMP_API_URL/IDP_TOKEN_URL, and a dead one makes every
    # later attempt fail with "HTTP 000" — a connection error that masks the
    # real cause. Retrying without re-establishing them turns one legible
    # failure into three misleading ones.
    # ── THUNDER_HANDLE: pinned locally, server-generated in the cloud ─────────
    # The handle is the label the per-environment Thunder answers to,
    # "<handle>.${BASE_DOMAIN}", and RC2 treats it as UNGUESSABLE on purpose
    # (see thunder_host in thunder-naming.sh and agent-manager-service's
    # models/env_thunder_url.go): every environment's Thunder is reachable only
    # through the *.${BASE_DOMAIN} wildcard, so a predictable label is the one
    # thing standing between a public DNS name and an environment's IdP.
    #
    # local: pin 'default-idp'. Nothing is publicly resolvable — the name exists
    #        only in /etc/hosts and a CoreDNS rewrite — so unguessability buys
    #        nothing, while a fixed label keeps scripts/amp-hosts.sh able to
    #        write the entry without first querying the cluster.
    # cloud: leave it UNSET so agent-manager-service generates a 10-character
    #        handle. There the host really is published, and pinning it would
    #        quietly discard the protection the design intends.
    ENV_THUNDER_HANDLE_ARGS=()
    if [ "${PROFILE}" = "local" ]; then
        ENV_THUNDER_HANDLE_ARGS=(THUNDER_HANDLE=default-idp)
    fi

    # Capture the provisioning output: on the cloud profile the handle is not
    # knowable in advance, so the issuer has to be READ BACK from the script
    # that minted it rather than recomputed here. Registration is an idempotent
    # upsert, so a re-run reports the same stored handle.
    ENV_THUNDER_OUT=/tmp/env-thunder-provision.log
    : > "${ENV_THUNDER_OUT}"

    ENV_THUNDER_OK="false"
    for attempt in 1 2 3; do
        pkill -f "port-forward.*19000:9000" 2>/dev/null || true
        pkill -f "port-forward.*18090:8090" 2>/dev/null || true
        kubectl port-forward -n "${AMP_NS}" svc/amp-api 19000:9000 >/tmp/pf-envthunder-api.log 2>&1 &
        PF_API_PID=$!
        kubectl port-forward -n "${THUNDER_NS}" svc/amp-thunder-extension-service 18090:8090 >/tmp/pf-envthunder-thunder.log 2>&1 &
        PF_TH_PID=$!
        sleep 4
        if [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
                http://localhost:19000/api/v1/health 2>/dev/null)" = "000" ]; then
            warning "amp-api port-forward not answering (attempt ${attempt}/3)"
            sleep 10
            continue
        fi

        if env \
            ENV_NAME=default \
            DISPLAY_NAME="Default" \
            ORG_NAME=default \
            ${ENV_THUNDER_HANDLE_ARGS[@]+"${ENV_THUNDER_HANDLE_ARGS[@]}"} \
            WAIT_TIMEOUT=300s \
            AMP_API_URL="http://localhost:19000/api/v1" \
            IDP_TOKEN_URL="http://localhost:18090/oauth2/token" \
            IDP_CLIENT_ID=amp-api-client \
            IDP_CLIENT_SECRET="${AMP_API_CLIENT_SECRET}" \
            PLATFORM_THUNDER_ISSUER="${THUNDER_PUBLIC_URL}" \
            PLATFORM_THUNDER_JWKS_URL="${ENV_THUNDER_JWKS_URL}" \
            THUNDER_HOST_BASE_DOMAIN="${BASE_DOMAIN}" \
            TLS_ENABLED="${TLS_ENABLED_FLAG}" \
            SCRIPT_BASE_URL="${SCRIPTS_BASE_URL}" \
            ${ENV_THUNDER_CA_ARGS[@]+"${ENV_THUNDER_CA_ARGS[@]}"} \
            bash "${ADD_ENV_THUNDER}" 2>&1 | tee -a "${ENV_THUNDER_OUT}"; then
            ENV_THUNDER_OK="true"
            success "env-Thunder provisioned"
            break
        fi
        warning "env-Thunder provisioning failed (attempt ${attempt}/3)"
        [ "${attempt}" -lt 3 ] && sleep 20
    done

    kill "${ENV_THUNDER_WATCHER}" 2>/dev/null || true
    kill "${PF_API_PID}" "${PF_TH_PID}" 2>/dev/null || true
    rm -rf "${ENV_THUNDER_DIR}"

    if [ "${ENV_THUNDER_OK}" != "true" ]; then
        error "env-Thunder provisioning failed — agents will never receive an AgentID"
        if [ -s "${ENV_THUNDER_LOG}" ]; then
            warning "Setup container output (the Job deletes its pod, so this is the only copy):"
            grep -E 'level=ERROR|❌|Failed|error=' "${ENV_THUNDER_LOG}" | sort -u | head -10
            info "Full log: ${ENV_THUNDER_LOG}"
        fi
    fi
else
    error "Could not download add-environment-thunder.sh — agents will never receive an AgentID"
fi

# ── Resolve the env-Thunder issuer ───────────────────────────────────────────
# Prefer the value add-environment-thunder.sh printed. It is the one that was
# actually minted, and on the cloud profile it is the ONLY way to learn it: the
# handle is generated by agent-manager-service, so there is nothing to compute
# from. Whatever lands here is registered with the gateway two steps below, and
# the two disagreeing means every AgentID token fails validation with nothing
# in the logs pointing at the issuer as the cause.
ENV_THUNDER_ISSUER=""
if [ -s "${ENV_THUNDER_OUT:-/dev/null}" ]; then
    # The script's summary block prints "  Issuer:          <url>".
    ENV_THUNDER_ISSUER=$(grep -E '^[[:space:]]*Issuer:[[:space:]]+http' "${ENV_THUNDER_OUT}" \
        | tail -1 | awk '{print $2}' || echo "")
fi

if [ -n "${ENV_THUNDER_ISSUER}" ]; then
    success "env-Thunder issuer read back from provisioning output"
elif [ "${PROFILE}" = "local" ]; then
    # Local pins the handle, so the issuer is reconstructable. Must match
    # thunder_issuer() exactly, including the port PATCH_RC2_THUNDER_PORT
    # injected above; ${CP_PORT} is "" when CP_GW_HTTPS_PORT is 443.
    if [ "${SCHEME}" = "https" ]; then
        ENV_THUNDER_ISSUER="https://default-idp.${BASE_DOMAIN}${CP_PORT}"
    else
        ENV_THUNDER_ISSUER="http://default-idp.${BASE_DOMAIN}:8080"
    fi
    warning "Could not read the issuer from the provisioning output — falling back"
    warning "to the pinned handle: ${ENV_THUNDER_ISSUER}"
else
    # Cloud has a server-generated handle and therefore no fallback. Guessing
    # here would register a wrong issuer with the gateway, and the issuer is
    # immutable once minted — so stop rather than mint something unusable.
    error "Could not determine the env-Thunder issuer from the provisioning output."
    error "The handle is generated by agent-manager-service on this profile, so there"
    error "is nothing to fall back to. Recover it with:"
    error "  curl -X PUT \$AMP_API_URL/orgs/default/environments/default/thunder-url"
    error "Full provisioning output: ${ENV_THUNDER_OUT:-<not captured>}"
    exit 1
fi
export ENV_THUNDER_ISSUER
export ENV_THUNDER_JWKS="http://${ENV_THUNDER_RELEASE}-service.${ENV_THUNDER_RELEASE}.svc.cluster.local:8090/oauth2/jwks"

if kubectl get ns "${ENV_THUNDER_RELEASE}" &>/dev/null; then
    wait_for "env-Thunder pods" \
        kubectl wait --for=condition=Ready pod --all -n "${ENV_THUNDER_RELEASE}" --timeout=300s
    success "env-Thunder issuer: ${ENV_THUNDER_ISSUER}"
else
    error "Namespace ${ENV_THUNDER_RELEASE} not created — env-Thunder provisioning did not complete"
fi

# ── Step 23: Point the gateway at the Environment's Thunder ──────────────────
# The gateway extension was installed before this Environment's Thunder
# existed, so it has no way to validate the tokens Thunder issues. Skipping
# this leaves the gateway with only its internal key manager: agents still
# work with API keys, so the platform looks complete, but no agent endpoint
# can validate a Thunder-issued OAuth token and the console's gateway page
# shows "No identity providers configured" with nothing to explain why.
step "Registering env-Thunder with the gateway"
if kubectl get ns "${ENV_THUNDER_RELEASE}" &>/dev/null; then
    # BOTH key managers must be listed. Helm's --set on an indexed array
    # REPLACES the whole list, so re-stating keymanagers[0] is what keeps the
    # internal agent-manager-service entry that API-key authentication relies
    # on. Dropping it silently breaks every API key.
    retry_cmd "Gateway key manager registration" 3 20 \
        helm upgrade api-platform-default-default \
        oci://${HELM_CHART_REGISTRY}/wso2-amp-api-platform-gateway-extension \
        --version ${VERSION} \
        --namespace ${DATA_PLANE_NS} \
        --reuse-values \
        --set "apiGateway.config.policyConfigurations.jwtauth_v1.keymanagers[0].name=agent-manager-service" \
        --set "apiGateway.config.policyConfigurations.jwtauth_v1.keymanagers[0].issuer=agent-manager-service" \
        --set "apiGateway.config.policyConfigurations.jwtauth_v1.keymanagers[0].jwks.remote.uri=http://amp-api.${AMP_NS}.svc.cluster.local:9000/auth/external/jwks.json" \
        --set "apiGateway.config.policyConfigurations.jwtauth_v1.keymanagers[0].jwks.remote.skipTlsVerify=true" \
        --set "apiGateway.config.policyConfigurations.jwtauth_v1.keymanagers[1].name=ThunderKeyManager" \
        --set "apiGateway.config.policyConfigurations.jwtauth_v1.keymanagers[1].issuer=${ENV_THUNDER_ISSUER}" \
        --set "apiGateway.config.policyConfigurations.jwtauth_v1.keymanagers[1].jwks.remote.uri=${ENV_THUNDER_JWKS}" \
        --set "apiGateway.config.policyConfigurations.jwtauth_v1.keymanagers[1].jwks.remote.skipTlsVerify=false" \
        --set "bootstrap.identityProviders[0].name=ThunderKeyManager" \
        --set "bootstrap.identityProviders[0].issuer=${ENV_THUNDER_ISSUER}" \
        --set "bootstrap.identityProviders[0].jwksUri=${ENV_THUNDER_JWKS}" \
        --set "bootstrap.identityProviders[0].skipTlsVerify=false" \
        --timeout 900s

    # This upgrade rolls the gateway controller, whose data volume is
    # ReadWriteOnce. On a multi-node cluster the replacement pod can land on a
    # different node and block with "Multi-Attach error for volume", leaving
    # the APIGateway at Programmed=False indefinitely; deleting the old
    # controller pod releases the volume. Single-node clusters don't hit this.
    # Selector is name=gateway + component=controller. The deployment is named
    # <release>-gw-gateway-controller but its app.kubernetes.io/name label is
    # just "gateway" — selecting on name=gateway-controller matches nothing and
    # `rollout status` then exits 0 having waited for nothing ("No resources
    # found"), which looks like success.
    if kubectl get deploy -n "${DATA_PLANE_NS}" \
            -l app.kubernetes.io/name=gateway,app.kubernetes.io/component=controller \
            -o name 2>/dev/null | grep -q .; then
        kubectl rollout status deployment \
            -l app.kubernetes.io/name=gateway,app.kubernetes.io/component=controller \
            -n "${DATA_PLANE_NS}" --timeout=300s >/dev/null 2>&1 \
            && success "Gateway controller rollout complete" \
            || warning "Gateway controller rollout not complete — check for a Multi-Attach error on its PVC"
    else
        warning "No gateway controller deployment found to wait on"
    fi
else
    warning "Skipping gateway key-manager registration — env-Thunder is not present"
fi

# ── Step 24: Rancher Desktop cgroup fix ──────────────────────────────────────
#
# LOCAL PROFILE ONLY. This rewrites the build templates to force Podman onto
# cgroupfs with pids_limit=0, which is a workaround for Rancher Desktop's VM.
# A managed cluster (EKS/GKE/AKS/DOKS) runs systemd cgroup v2 correctly, so
# there the patch is not a no-op — it downgrades the cgroup driver and removes
# a pids guard on a cluster that may be shared. Nothing would report an error;
# builds would simply run unconstrained.
if [ "${PROFILE}" != "local" ]; then
    info "Skipping Rancher Desktop cgroup workaround (profile: ${PROFILE})"
else
step "Applying Rancher Desktop cgroup pids workaround"
info "Patching ClusterWorkflowTemplates for cgroup compatibility..."

for template in gcp-buildpacks-build publish-image amp-generate-workload; do
    if kubectl get clusterworkflowtemplate "${template}" &>/dev/null; then
        kubectl get clusterworkflowtemplate "${template}" -o json | \
        python3 -c "
import json, sys
data = json.load(sys.stdin)
script = data['spec']['templates'][0]['container']['args'][0]
fix = '''set -e

# Fix: disable cgroup management for Podman (Rancher Desktop cgroup pids workaround)
cat > /tmp/containers.conf <<CCONF
[engine]
cgroup_manager = \"cgroupfs\"
events_logger = \"file\"
[containers]
pids_limit = 0
CCONF
export CONTAINERS_CONF=/tmp/containers.conf

'''
if fix not in script:
    data['spec']['templates'][0]['container']['args'][0] = script.replace('set -e\n', fix, 1)
json.dump(data, sys.stdout)
" | kubectl apply -f - 2>/dev/null && success "Patched: ${template}" || warning "Could not patch: ${template}"
    else
        info "Template not found (may not be installed yet): ${template}"
    fi
done
fi   # end: local-profile-only cgroup workaround

# ============================================================================
# WAIT FOR ALL PODS TO BE READY
# ============================================================================
# The summary below and the port-forwards after it assume every pod in these
# namespaces is up. Without this wait, a pod that's still starting (e.g. a
# slow image pull or late-starting sidecar) can make a port-forward target a
# service with no ready endpoints yet, which fails silently later rather than
# at the point where it's actually diagnosable.
step "Waiting for all pods to be ready"
ALL_NS=(openchoreo-control-plane openchoreo-data-plane openchoreo-workflow-plane \
        openchoreo-observability-plane wso2-amp amp-thunder agent-sandbox-system \
        "${ENV_THUNDER_RELEASE}")
WAIT_ELAPSED=0
WAIT_MAX=300
NOT_READY_TOTAL=1
while [ ${WAIT_ELAPSED} -lt ${WAIT_MAX} ]; do
    NOT_READY_TOTAL=0
    for ns in "${ALL_NS[@]}"; do
        NOT_READY_TOTAL=$((NOT_READY_TOTAL + $(kubectl get pods -n "${ns}" --no-headers 2>/dev/null \
            | { grep -v -E 'Running|Completed' || true; } | wc -l | tr -d ' ')))
    done
    [ "${NOT_READY_TOTAL}" -eq 0 ] && break
    info "Waiting for ${NOT_READY_TOTAL} pod(s) across all namespaces to finish starting... (${WAIT_ELAPSED}s/${WAIT_MAX}s)"
    sleep 10
    WAIT_ELAPSED=$((WAIT_ELAPSED+10))
done
if [ "${NOT_READY_TOTAL}" -eq 0 ]; then
    success "All pods are Running/Completed"
else
    warning "Some pods still not Running after ${WAIT_MAX}s — see Pod Status below; affected port-forwards will be skipped"
fi

# ============================================================================
# FINAL SUMMARY
# ============================================================================
echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} Installation Summary                                           ${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${BOLD}Helm Releases:${NC}"
helm list -A | grep -E 'openchoreo|amp|gateway|openbao|cert-manager|external-secrets|agent-sandbox' || true

echo ""
echo -e "${BOLD}Plane Registrations:${NC}"
kubectl get clusterdataplane,clusterworkflowplane,clusterobservabilityplane -n default 2>/dev/null || true

echo ""
echo -e "${BOLD}Pod Status:${NC}"
for ns in "${ALL_NS[@]}"; do
    kubectl get ns "${ns}" &>/dev/null || continue
    NOT_READY=$(kubectl get pods -n "${ns}" --no-headers 2>/dev/null \
        | { grep -v -E 'Running|Completed' || true; } | wc -l | tr -d ' ')
    TOTAL=$(kubectl get pods -n "${ns}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "${NOT_READY}" -eq 0 ]; then
        success "${ns}: ${TOTAL}/${TOTAL} pods Running"
    else
        warning "${ns}: $((TOTAL-NOT_READY))/${TOTAL} pods Running"
    fi
done

# The registered gateway vhost is worth surfacing explicitly: it is written
# once and never reconciled, so if it still shows the chart's .localhost
# placeholder the only fix is to delete the registration and re-register.
#
# Read from the bootstrap Job's log, not from the APIGateway resource — the CR
# carries no .spec.vhost; the value lives in Agent Manager's database. The log
# distinguishes the two cases that matter: "Gateway registered with ID" means
# THIS run wrote the record, "already exists" means it found an earlier one and
# left it alone (so a corrected vhost was silently ignored).
echo ""
echo -e "${BOLD}Gateway registration (write-once):${NC}"
# Compare the vhost Agent Manager actually holds against the one intended,
# rather than keying on "already exists". That phrase is NOT a problem signal
# by itself: Step 23's helm upgrade re-runs this same pre-upgrade hook, which
# then legitimately finds the gateway registered by Step 20 moments earlier.
# What matters is only whether the stored value is right.
EXPECTED_VHOST="${SCHEME}://${AGENTS_GW_HOST}${DP_PORT}"
BOOTSTRAP_LOG=$(kubectl logs -n "${DATA_PLANE_NS}" \
    job/api-platform-default-default-bootstrap --tail=200 2>/dev/null || echo "")
ACTUAL_VHOST=$(echo "${BOOTSTRAP_LOG}" | grep -o '"vhost":"[^"]*"' | tail -1 | cut -d'"' -f4)
if [ -z "${ACTUAL_VHOST}" ]; then
    if echo "${BOOTSTRAP_LOG}" | grep -q 'Gateway registered with ID'; then
        success "Registered fresh this run — vhost sent: ${EXPECTED_VHOST}"
    else
        info "Could not read the registered vhost — check the console's gateway page"
    fi
elif [ "${ACTUAL_VHOST}" = "${EXPECTED_VHOST}" ]; then
    success "vhost registered correctly: ${ACTUAL_VHOST}"
else
    error "vhost is ${ACTUAL_VHOST}, expected ${EXPECTED_VHOST}"
    error "This is written once and never reconciled — delete the gateway registration and re-register."
fi

if [ "${PROFILE}" = "local" ]; then
    echo ""
    echo -e "${BOLD}Host DNS:${NC}"
    if grep -q "${BASE_DOMAIN}" /etc/hosts 2>/dev/null; then
        success "/etc/hosts has entries for ${BASE_DOMAIN}"
    else
        warning "/etc/hosts has no entries for ${BASE_DOMAIN} — run: scripts/amp-hosts.sh add"
    fi
else
    print_dns_records
fi

echo ""
if [ ${ERRORS} -eq 0 ]; then
    echo -e "${GREEN}${BOLD}✓ Installation completed successfully!${NC}"
else
    echo -e "${YELLOW}${BOLD}⚠ Installation completed with ${ERRORS} warning(s) — review output above${NC}"
fi

# ============================================================================
# START PORT-FORWARDS
# ============================================================================
# ============================================================================
# PORT-FORWARD FALLBACK
# ============================================================================
# Everything is hostname-routed through the plane gateways now, so
# port-forwards are no longer how the platform is reached — they are a
# debugging fallback for when the gateway or DNS is the thing being
# investigated. Note that the OAuth flow will NOT work through them: Thunder's
# redirect URIs are frozen to ${CONSOLE_PUBLIC_URL}, so a console opened on
# localhost:3000 bounces back to the real hostname on login.
echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} Port-Forward Fallback                                          ${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"

cat > ~/amp-portforward.sh << 'EOF'
#!/bin/bash
# AMP port-forward fallback — for debugging individual services directly.
#
# This is NOT the normal way in: the platform is reached through the plane
# gateway hostnames printed by the installer. Logging in through a port-forward
# does not work, because Thunder's redirect URIs are frozen to the real console
# hostname. Use these to poke a service that the gateway cannot reach.
pkill -f "kubectl port-forward" 2>/dev/null || true
sleep 1
kubectl port-forward -n wso2-amp svc/amp-console 3000:3000 > /tmp/pf-console.log 2>&1 &
kubectl port-forward -n wso2-amp svc/amp-api 9000:9000 > /tmp/pf-api.log 2>&1 &
kubectl port-forward -n amp-thunder svc/amp-thunder-extension-service 8090:8090 > /tmp/pf-thunder.log 2>&1 &
kubectl port-forward -n openchoreo-observability-plane svc/amp-observer 9098:9098 > /tmp/pf-traces.log 2>&1 &
echo "AMP debug port-forwards started"
echo "  Console:  http://localhost:3000   (login will redirect away — see above)"
echo "  API:      http://localhost:9000"
echo "  Thunder:  http://localhost:8090"
echo "  Observer: http://localhost:9098"
EOF
chmod +x ~/amp-portforward.sh
success "Debug port-forward helper saved -> ~/amp-portforward.sh (not started)"

if [ "${DEPLOY_REGISTRY}" = "true" ]; then
    echo ""
    echo -e "${BOLD}Container registry:${NC}"
    echo -e "  Endpoint:  ${REGISTRY_ENDPOINT}  (no auth — evaluation only)"
    if [ "${REGISTRY_NODE_DNS_OK}" = "true" ]; then
        success "Node resolution + dockerd insecure-registry configured — no restart needed"
    else
        warning "The VM's /etc/hosts entry is missing; agent image pulls will fail to resolve it:"
        warning "  rdctl shell sudo sh -c \"echo '127.0.0.1 ${REGISTRY_HOST}' >> /etc/hosts\""
    fi
    echo -e "  Both the VM's /etc/hosts and /etc/docker/daemon.json are managed by"
    echo -e "  Rancher Desktop and may be reset by a factory reset or upgrade. If agent"
    echo -e "  builds later fail to pull, re-run this installer — it is idempotent."
fi

echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} Trust the CA                                                   ${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo ""

# Everything above is served over HTTPS by the self-signed openchoreo-ca chain,
# so nothing is reachable in a browser until that CA is trusted. Printed rather
# than done: installing a trusted root is the user's call, not the installer's.
#
# This is also what makes the consoles work at all. Both depend on APIs that
# only exist in a secure context — crypto.subtle for the Thunder console's
# ID-token check, navigator.clipboard for the AMP console's copy buttons — and
# both fail silently over plain HTTP. See the profile block at the top.

# Keyed on TLS_MODE, not on the profile: a cloud install run with
# ALLOW_SELFSIGNED_CLOUD=1 needs this exactly as much as a laptop does, and
# gating it on PROFILE=local meant that operator got no guidance at all. Only
# the macOS trust command is local-specific — extracting the CA is not.
if [ "${TLS_MODE}" = "selfsigned" ]; then
    echo -e "${BOLD}Trust the CA (one time, REQUIRED or loading the console fails):${NC}"
    echo -e "  Browsers reject every hostname until the self-signed CA is trusted."
    echo -e "  ${BOLD}kubectl get secret openchoreo-ca-secret -n cert-manager \\\\${NC}"
    echo -e "  ${BOLD}    -o jsonpath='{.data.ca\\.crt}' | base64 -d > /tmp/openchoreo-ca.crt${NC}"
    if [ "${PROFILE}" = "local" ]; then
        echo -e "  ${BOLD}sudo security add-trusted-cert -d -r trustRoot \\\\${NC}"
        echo -e "  ${BOLD}    -k /Library/Keychains/System.keychain /tmp/openchoreo-ca.crt${NC}"
        echo -e "  Then quit and reopen the browser completely."
    else
        echo -e "  Then distribute /tmp/openchoreo-ca.crt to every machine and service"
        echo -e "  that talks to this install — browsers, CI runners, and any agent"
        echo -e "  calling the gateway. On a public domain prefer TLS_MODE=acme-dns01."
    fi
fi
echo ""

echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} Validate Console Access                                        ${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo ""

if [ "${PROFILE}" = "local" ]; then
    # Only ask for the hosts entries if they are actually missing — Step 2
    # already offers to write them, so repeating the instruction here on a
    # host that has them reads as "do it again".
    NEXT=1
    if ! grep -q "${BASE_DOMAIN}" /etc/hosts 2>/dev/null; then
        echo -e "  ${NEXT}. ${BOLD}scripts/amp-hosts.sh add${NC}   (needs sudo — not done yet)"
        NEXT=$((NEXT+1))
    fi
    echo ""
    echo -e "  ${NEXT}. Open ${GREEN}${CONSOLE_PUBLIC_URL}${NC}"
    NEXT=$((NEXT+1))
    echo -e "  ${NEXT}. Verify offline operation by disabling Wi-Fi and reloading the console"
else
    echo -e "  1. Publish the DNS records listed above"
    echo -e "  2. Open ${GREEN}${CONSOLE_PUBLIC_URL}${NC}"
fi


echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} Accessing Agent Manager                                        ${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${BOLD}Access URLs:${NC}"
echo -e "  Console:      ${GREEN}${CONSOLE_PUBLIC_URL}${NC}"
echo -e "  API:          ${API_PUBLIC_URL}"
echo -e "  Thunder:      ${THUNDER_PUBLIC_URL}"
echo -e "  Observer:     ${OBS_API_PUBLIC_URL}"
echo -e "  Gateway CP:   ${CP_GW_PUBLIC_URL}"
echo -e "  Agents:       ${SCHEME}://<org>-<project>.${AGENTS_DOMAIN}${DP_PORT}"
echo -e "  OTLP ingest:  ${INSTRUMENTATION_URL}"
echo -e "  env-Thunder:  ${ENV_THUNDER_ISSUER}"

echo ""
echo -e "${BOLD}Credentials:${NC}"
# Never admin/admin: the password is generated at install time and reused
# across reinstalls rather than rotated.
if [ -n "${AMP_ADMIN_PASSWORD}" ]; then
    echo -e "  Console admin:  ${BOLD}admin${NC} / ${BOLD}${AMP_ADMIN_PASSWORD}${NC}"
else
    echo -e "  Console admin:  admin / (kubectl get secret amp-admin-credentials -n ${THUNDER_NS} -o jsonpath='{.data.password}' | base64 -d)"
fi
ENV_ADMIN_PASSWORD=$(kubectl get secret "${ENV_THUNDER_RELEASE}-admin-credentials" \
    -n "${ENV_THUNDER_RELEASE}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
if [ -n "${ENV_ADMIN_PASSWORD}" ]; then
    echo -e "  env-Thunder:    ${BOLD}admin${NC} / ${BOLD}${ENV_ADMIN_PASSWORD}${NC}  (default Environment)"
fi

# Local profile only. /etc/hosts is how the Mac resolves these names, because it
# has no wildcard support and the local profile publishes no DNS. The cloud
# profile's equivalent is a wildcard DNS record, already covered by "Publish the
# DNS records listed above", so this section would send a cloud operator to edit
# a file that has nothing to do with their install.
if [ "${PROFILE}" = "local" ]; then
    echo ""
    echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD} Hosts File Configuration                                       ${NC}"
    echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "If you create a new environment, such as staging, from AMP console, you need to"
    echo -e "add a line in /etc/hosts per environment with: ${BOLD}scripts/amp-hosts.sh add <project>${NC}"
fi
