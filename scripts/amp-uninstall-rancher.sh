#!/bin/bash
# ============================================================================
# WSO2 Agent Manager - Automated Uninstall Script
# Target: Rancher Desktop (k3s) on macOS
# Reverses everything amp-install-rancher.sh installs, so the cluster is
# left clean and ready for a fresh install (e.g. a different version).
# ============================================================================
set -uo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================
AMP_NS="wso2-amp"
THUNDER_NS="amp-thunder"
OBSERVABILITY_NS="openchoreo-observability-plane"
WORKFLOW_NS="openchoreo-workflow-plane"
DATA_PLANE_NS="openchoreo-data-plane"
CONTROL_PLANE_NS="openchoreo-control-plane"
OPENBAO_NS="openbao"
EXTERNAL_SECRETS_NS="external-secrets"
CERT_MANAGER_NS="cert-manager"
DEFAULT_NS="default"

NAMESPACES=(
    "${AMP_NS}" "${THUNDER_NS}" "${OBSERVABILITY_NS}" "${WORKFLOW_NS}" \
    "${DATA_PLANE_NS}" "${CONTROL_PLANE_NS}" "${OPENBAO_NS}" \
    "${EXTERNAL_SECRETS_NS}" "${CERT_MANAGER_NS}"
)

# Helm releases as "name:namespace" pairs
HELM_RELEASES=(
    "amp:${AMP_NS}"
    "api-platform-default-default:${DATA_PLANE_NS}"
    "amp-thunder-extension:${THUNDER_NS}"
    "amp-observability-traces:${OBSERVABILITY_NS}"
    "amp-evaluation-extension:${WORKFLOW_NS}"
    "amp-platform-resources:${DEFAULT_NS}"
    "gateway-operator:${DATA_PLANE_NS}"
    "observability-logs-opensearch:${OBSERVABILITY_NS}"
    "observability-metrics-prometheus:${OBSERVABILITY_NS}"
    "observability-traces-opensearch:${OBSERVABILITY_NS}"
    "openchoreo-observability-plane:${OBSERVABILITY_NS}"
    "openchoreo-workflow-plane:${WORKFLOW_NS}"
    "openchoreo-data-plane:${DATA_PLANE_NS}"
    "openchoreo-control-plane:${CONTROL_PLANE_NS}"
    "openbao:${OPENBAO_NS}"
    "external-secrets:${EXTERNAL_SECRETS_NS}"
    "cert-manager:${CERT_MANAGER_NS}"
)

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

# ============================================================================
# ARGS
# ============================================================================
ASSUME_YES=false
for arg in "$@"; do
    case "${arg}" in
        -y|--yes) ASSUME_YES=true ;;
        *) echo "Unknown option: ${arg}"; echo "Usage: $0 [-y|--yes]"; exit 1 ;;
    esac
done

echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     WSO2 Agent Manager — Automated Uninstaller                 ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

CURRENT_CTX=$(kubectl config current-context 2>/dev/null || echo "unknown")
warning "This will delete Agent Manager, OpenChoreo, and all supporting"
warning "releases/namespaces from the current kubectl context: ${BOLD}${CURRENT_CTX}${NC}"
echo ""
info "Namespaces to be deleted: ${NAMESPACES[*]}"
echo ""

if [ "${ASSUME_YES}" != true ]; then
    read -r -p "Type 'yes' to continue: " CONFIRM
    if [ "${CONFIRM}" != "yes" ]; then
        echo "Aborted."
        exit 1
    fi
fi

# ============================================================================
# STEP 1 — Stop local port-forwards
# ============================================================================
step "Stopping local port-forwards"
if pkill -f "kubectl port-forward" 2>/dev/null; then
    success "Stopped running kubectl port-forward processes"
else
    info "No kubectl port-forward processes were running"
fi

# ============================================================================
# STEP 2 — Delete plane registrations
# ============================================================================
step "Deleting plane registrations"
kubectl delete clusterdataplane default -n default --ignore-not-found --timeout=60s \
    && success "ClusterDataPlane deleted" || warning "ClusterDataPlane delete reported an issue (may already be gone)"
kubectl delete clusterworkflowplane default -n default --ignore-not-found --timeout=60s \
    && success "ClusterWorkflowPlane deleted" || warning "ClusterWorkflowPlane delete reported an issue (may already be gone)"
kubectl delete observabilityplane default -n default --ignore-not-found --timeout=60s \
    && success "ObservabilityPlane deleted" || warning "ObservabilityPlane delete reported an issue (may already be gone)"

# ============================================================================
# STEP 3 — Uninstall Helm releases
# ============================================================================
step "Uninstalling Helm releases"
for entry in "${HELM_RELEASES[@]}"; do
    NAME="${entry%%:*}"
    NS="${entry##*:}"
    if helm status "${NAME}" -n "${NS}" &>/dev/null; then
        if helm uninstall "${NAME}" -n "${NS}" --wait --timeout 180s &>/dev/null; then
            success "Uninstalled ${NAME} (${NS})"
        else
            error "Failed to uninstall ${NAME} (${NS})"
        fi
    else
        info "${NAME} (${NS}) not installed — skipping"
    fi
done

# ============================================================================
# STEP 4 — Delete cluster-scoped extras
# ============================================================================
# These were created via raw `kubectl apply` in the installer, not as part of
# any Helm release, and aren't namespaced — so neither helm uninstall nor
# namespace deletion removes them.
step "Deleting cluster-scoped extras"
kubectl delete clustersecretstore default --ignore-not-found \
    && success "ClusterSecretStore/default deleted" || warning "ClusterSecretStore/default delete reported an issue"
kubectl delete clusterissuer selfsigned-bootstrap openchoreo-ca --ignore-not-found \
    && success "ClusterIssuers deleted" || warning "ClusterIssuer delete reported an issue"
kubectl delete clusterrolebinding wso2-api-platform-gateway-module --ignore-not-found \
    && success "ClusterRoleBinding/wso2-api-platform-gateway-module deleted" || warning "ClusterRoleBinding delete reported an issue"
kubectl delete clusterrole wso2-api-platform-gateway-module --ignore-not-found \
    && success "ClusterRole/wso2-api-platform-gateway-module deleted" || warning "ClusterRole delete reported an issue"

# ============================================================================
# STEP 5 — Delete namespaces
# ============================================================================
# Custom resources owned by the operators we just uninstalled in Step 3 (e.g.
# gateway-operator's RestAPIs, external-secrets' ExternalSecrets) carry
# finalizers that only their controller can clear. With the controller gone,
# those finalizers never get removed and the namespace hangs in
# "Terminating" forever. strip_stuck_finalizers force-clears finalizers on
# whatever's left so namespace deletion can complete.
strip_stuck_finalizers() {
    local ns="$1"
    local kinds
    kinds=$(kubectl api-resources --verbs=list --namespaced -o name 2>/dev/null)
    while IFS= read -r kind; do
        [ -z "${kind}" ] && continue
        while IFS= read -r name; do
            [ -z "${name}" ] && continue
            kubectl patch "${kind}" "${name}" -n "${ns}" --type=merge -p '{"metadata":{"finalizers":[]}}' &>/dev/null \
                && warning "Cleared stuck finalizer(s) on ${kind}/${name} (${ns})"
        done < <(kubectl get "${kind}" -n "${ns}" -o name 2>/dev/null | cut -d/ -f2)
    done <<< "${kinds}"
}

step "Deleting namespaces"
kubectl delete namespace "${NAMESPACES[@]}" --ignore-not-found --timeout=120s || true

info "Waiting for namespaces to fully terminate..."
ELAPSED=0
STUCK=()
while [ ${ELAPSED} -lt 180 ]; do
    STUCK=()
    for ns in "${NAMESPACES[@]}"; do
        if kubectl get namespace "${ns}" &>/dev/null; then
            STUCK+=("${ns}")
        fi
    done
    [ ${#STUCK[@]} -eq 0 ] && break
    if [ ${ELAPSED} -eq 30 ]; then
        info "Some namespaces are still terminating — checking for orphaned finalizers..."
        for ns in "${STUCK[@]}"; do
            strip_stuck_finalizers "${ns}"
        done
    fi
    sleep 5
    ELAPSED=$((ELAPSED+5))
done

if [ ${#STUCK[@]} -eq 0 ]; then
    success "All namespaces terminated"
else
    warning "Still terminating after ${ELAPSED}s: ${STUCK[*]}"
    warning "If a namespace is stuck in 'Terminating', check for finalizers:"
    warning "  kubectl get namespace <ns> -o json | jq '.spec.finalizers,.status.conditions'"
fi

# ============================================================================
# STEP 6 — Validate clean state
# ============================================================================
step "Validating clean state"
echo ""

CLEAN=true

info "Checking Helm releases..."
for entry in "${HELM_RELEASES[@]}"; do
    NAME="${entry%%:*}"
    NS="${entry##*:}"
    if helm status "${NAME}" -n "${NS}" &>/dev/null; then
        error "Helm release still present: ${NAME} (${NS})"
        CLEAN=false
    fi
done
[ "${CLEAN}" = true ] && success "No Agent Manager / OpenChoreo Helm releases remain"

info "Checking namespaces..."
NS_LEFT=()
for ns in "${NAMESPACES[@]}"; do
    kubectl get namespace "${ns}" &>/dev/null && NS_LEFT+=("${ns}")
done
if [ ${#NS_LEFT[@]} -eq 0 ]; then
    success "No target namespaces remain"
else
    error "Namespaces still present: ${NS_LEFT[*]}"
    CLEAN=false
fi

info "Checking plane registrations..."
PLANES=$(kubectl get clusterdataplane,clusterworkflowplane,observabilityplane -n default --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "${PLANES}" -eq 0 ]; then
    success "No plane registrations remain"
else
    error "Plane registrations still present:"
    kubectl get clusterdataplane,clusterworkflowplane,observabilityplane -n default 2>/dev/null || true
    CLEAN=false
fi

info "Checking cluster-scoped extras..."
EXTRAS_LEFT=$(kubectl get clustersecretstore/default clusterissuer/selfsigned-bootstrap \
    clusterissuer/openchoreo-ca clusterrole/wso2-api-platform-gateway-module \
    clusterrolebinding/wso2-api-platform-gateway-module --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "${EXTRAS_LEFT}" -eq 0 ]; then
    success "No leftover ClusterSecretStore/ClusterIssuer/ClusterRole(Binding) remain"
else
    error "Cluster-scoped extras still present:"
    kubectl get clustersecretstore/default clusterissuer/selfsigned-bootstrap \
        clusterissuer/openchoreo-ca clusterrole/wso2-api-platform-gateway-module \
        clusterrolebinding/wso2-api-platform-gateway-module 2>/dev/null || true
    CLEAN=false
fi

info "Checking for orphaned PersistentVolumes..."
RELEASED_PVS=$(kubectl get pv --no-headers 2>/dev/null \
    | { grep -E "($(IFS='|'; echo "${NAMESPACES[*]}"))" || true; })
if [ -z "${RELEASED_PVS}" ]; then
    success "No PersistentVolumes referencing the deleted namespaces remain"
else
    warning "PersistentVolume(s) still reference deleted namespaces (check reclaim policy):"
    echo "${RELEASED_PVS}"
fi

echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
if [ "${CLEAN}" = true ] && [ ${ERRORS} -eq 0 ]; then
    echo -e "${GREEN}${BOLD}✓ Cluster is clean — ready for a fresh install.${NC}"
else
    echo -e "${YELLOW}${BOLD}⚠ Cleanup completed with issues — review the output above before reinstalling.${NC}"
fi
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"

info "Note: cluster-scoped CRDs (Gateway API, cert-manager) are not removed by this script and"
info "are safe to leave installed for the next install. Namespaced extras that aren't tracked"
info "as their own Helm releases here (kgateway, kgateway-crds, the observability-* modules)"
info "were removed along with the namespace they lived in."
