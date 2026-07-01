#!/bin/bash
# ============================================================================
# WSO2 Agent Manager v0.17.0 - Automated Installation Script
# Target: Rancher Desktop (k3s) on macOS
# ============================================================================
set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================
export VERSION="0.17.0"
export HELM_CHART_REGISTRY="ghcr.io/wso2"
export AMP_NS="wso2-amp"
export BUILD_CI_NS="openchoreo-workflow-plane"
export OBSERVABILITY_NS="openchoreo-observability-plane"
export DEFAULT_NS="default"
export DATA_PLANE_NS="openchoreo-data-plane"
export THUNDER_NS="amp-thunder"

# Thunder URLs (port-forward mode for local dev)
export THUNDER_PUBLIC_URL="http://localhost:8090"
export THUNDER_INTERNAL_URL="http://amp-thunder-extension-service.${THUNDER_NS}.svc.cluster.local:8090"

# Console URLs (port-forward mode for local dev)
export CONSOLE_PUBLIC_URL="http://localhost:3000"
export API_PUBLIC_URL="http://localhost:9000"
export OBS_API_PUBLIC_URL="http://localhost:9098"
export INSTRUMENTATION_URL="http://localhost:22893/otel"

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
    if helm status "${name}" -n "${ns}" &>/dev/null; then
        warning "Helm release '${name}' already exists in namespace '${ns}' — skipping install"
        return 0
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

# ============================================================================
# PRE-FLIGHT CHECKS
# ============================================================================
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     WSO2 Agent Manager v${VERSION} — Automated Installer      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

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
success "helm found"

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

# check for traefik (must be removed)
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
    helm upgrade --install kgateway-crds oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds \
        --create-namespace \
        --namespace openchoreo-control-plane \
        --version v2.2.1
fi
if ! check_helm_release kgateway openchoreo-control-plane; then
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
step "OpenBao secrets store (v0.25.6)"
if ! check_helm_release openbao openbao; then
    helm upgrade --install openbao oci://ghcr.io/openbao/charts/openbao \
        --namespace openbao \
        --create-namespace \
        --version 0.25.6 \
        --values https://raw.githubusercontent.com/wso2/agent-manager/amp/v${VERSION}/deployments/single-cluster/values-openbao.yaml \
        --timeout 180s
fi
wait_for "OpenBao pod" \
    kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=openbao -n openbao --timeout=120s
verify_pods openbao

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

# ── Step 6: TLS Setup ────────────────────────────────────────────────────────
step "TLS — self-signed CA chain"
kubectl apply -f - <<'EOF'
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
  name: openchoreo-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: openchoreo-ca
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
  name: openchoreo-ca
spec:
  ca:
    secretName: openchoreo-ca-secret
EOF
wait_for "CA certificate" \
    kubectl wait --for=condition=Ready certificate/openchoreo-ca -n cert-manager --timeout=60s
success "TLS CA chain ready"

# ── Step 7: Thunder (Identity Provider) ──────────────────────────────────────
step "Thunder Identity Provider (v${VERSION})"
if ! check_helm_release amp-thunder-extension "${THUNDER_NS}"; then
    helm install amp-thunder-extension \
        oci://${HELM_CHART_REGISTRY}/wso2-amp-thunder-extension \
        --version ${VERSION} \
        --namespace ${THUNDER_NS} \
        --create-namespace \
        --set thunder.configuration.server.publicUrl="${THUNDER_PUBLIC_URL}" \
        --set thunder.configuration.jwt.issuer="${THUNDER_PUBLIC_URL}" \
        --set thunder.configuration.gateClient.hostname="localhost" \
        --set thunder.configuration.gateClient.port=8090 \
        --timeout 1800s
fi
wait_for "Thunder deployment" \
    kubectl wait --for=condition=Available \
        deployment -l app.kubernetes.io/instance=amp-thunder-extension \
        -n ${THUNDER_NS} --timeout=300s
verify_pods "${THUNDER_NS}"

# Verify Thunder OIDC
info "Verifying Thunder OIDC endpoint..."
THUNDER_ISSUER=$(kubectl exec -n ${THUNDER_NS} deploy/amp-thunder-extension-deployment -- \
    wget -qO- http://localhost:8090/.well-known/openid-configuration 2>/dev/null \
    | grep -o '"issuer":"[^"]*"' || echo "")
if echo "${THUNDER_ISSUER}" | grep -q "localhost:8090"; then
    success "Thunder OIDC issuer verified: ${THUNDER_ISSUER}"
else
    warning "Thunder OIDC issuer unexpected: ${THUNDER_ISSUER}"
fi

# ── Step 8: Control Plane ────────────────────────────────────────────────────
step "OpenChoreo Control Plane (v1.1.1)"
info "Installing with placeholder hostnames first..."
if ! check_helm_release openchoreo-control-plane openchoreo-control-plane; then
    helm upgrade --install openchoreo-control-plane \
        oci://ghcr.io/openchoreo/helm-charts/openchoreo-control-plane \
        --version 1.1.1 \
        --namespace openchoreo-control-plane \
        --create-namespace \
        --values - <<'EOF'
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
fi

# Handle webhook race condition
# Wait for all deployments to be available first, then retry helm upgrade
# to create the ClusterAuthzRoleBinding resources that require the webhook
info "Waiting for Control Plane deployments to be ready..."
kubectl wait --for=condition=Available deployment --all \
    -n openchoreo-control-plane --timeout=300s 2>/dev/null || true

RETRY=0
until [ $RETRY -ge 5 ]; do
    RETRY=$((RETRY+1))
    info "Applying ClusterAuthzRoleBindings via helm upgrade (attempt ${RETRY}/5)..."
    if helm upgrade openchoreo-control-plane \
        oci://ghcr.io/openchoreo/helm-charts/openchoreo-control-plane \
        --version 1.1.1 \
        --namespace openchoreo-control-plane \
        --reuse-values 2>/dev/null; then
        success "Control Plane helm upgrade succeeded"
        break
    fi
    warning "Webhook not ready yet, waiting 15s before retry..."
    sleep 15
    # Re-wait for deployments in case something restarted
    kubectl wait --for=condition=Available deployment --all \
        -n openchoreo-control-plane --timeout=120s 2>/dev/null || true
done

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

export CP_BASE_DOMAIN="openchoreo.${CP_LB_IP//./-}.nip.io"
success "Control Plane LB IP: ${CP_LB_IP}"
success "Control Plane domain: ${CP_BASE_DOMAIN}"

# Wildcard TLS cert
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: cp-gateway-tls
  namespace: openchoreo-control-plane
spec:
  secretName: cp-gateway-tls
  issuerRef:
    name: openchoreo-ca
    kind: ClusterIssuer
  dnsNames:
    - "*.${CP_BASE_DOMAIN}"
    - "${CP_BASE_DOMAIN}"
  privateKey:
    rotationPolicy: Always
EOF
wait_for "CP TLS certificate" \
    kubectl wait --for=condition=Ready certificate/cp-gateway-tls \
    -n openchoreo-control-plane --timeout=60s

# Reconfigure with real hostnames
info "Reconfiguring Control Plane with real hostnames and TLS..."
helm upgrade openchoreo-control-plane \
    oci://ghcr.io/openchoreo/helm-charts/openchoreo-control-plane \
    --version 1.1.1 \
    --namespace openchoreo-control-plane \
    --reuse-values \
    --values - <<EOF
openchoreoApi:
  config:
    server:
      publicUrl: "https://api.${CP_BASE_DOMAIN}"
    security:
      authentication:
        jwt:
          jwks:
            skip_tls_verify: true
  http:
    hostnames:
      - "api.${CP_BASE_DOMAIN}"
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
  tls:
    enabled: true
    hostname: "*.${CP_BASE_DOMAIN}"
    certificateRefs:
      - name: cp-gateway-tls
EOF
wait_for "Control Plane reconfigured" \
    kubectl wait --for=condition=Available deployment --all \
    -n openchoreo-control-plane --timeout=300s
verify_pods openchoreo-control-plane

# ── Step 9: Data Plane ───────────────────────────────────────────────────────
step "OpenChoreo Data Plane (v1.1.1)"
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

if ! check_helm_release openchoreo-data-plane openchoreo-data-plane; then
    helm install openchoreo-data-plane \
        oci://ghcr.io/openchoreo/helm-charts/openchoreo-data-plane \
        --version 1.1.1 \
        --namespace openchoreo-data-plane \
        --create-namespace \
        --set gateway.tls.enabled=false \
        --set clusterAgent.tls.generateCerts=true \
        --values https://raw.githubusercontent.com/wso2/agent-manager/amp/v${VERSION}/deployments/single-cluster/values-dp.yaml
fi

info "Waiting for Data Plane LoadBalancer IP..."
ELAPSED=0
DP_LB_IP=""
until [ -n "${DP_LB_IP}" ] || [ $ELAPSED -ge 120 ]; do
    DP_LB_IP=$(kubectl get svc gateway-default -n openchoreo-data-plane \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [ -z "${DP_LB_IP}" ]; then
        DP_LB_HOSTNAME=$(kubectl get svc gateway-default -n openchoreo-data-plane \
            -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
        [ -n "${DP_LB_HOSTNAME}" ] && DP_LB_IP=$(dig +short "${DP_LB_HOSTNAME}" | head -1) || true
    fi
    [ -z "${DP_LB_IP}" ] && sleep 5 && ELAPSED=$((ELAPSED+5))
done

if [ -z "${DP_LB_IP}" ]; then
    error "Data Plane LoadBalancer IP not available"
    exit 1
fi

export DP_DOMAIN="apps.openchoreo.${DP_LB_IP//./-}.nip.io"
success "Data Plane domain: ${DP_DOMAIN}"

kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: dp-gateway-tls
  namespace: openchoreo-data-plane
spec:
  secretName: dp-gateway-tls
  issuerRef:
    name: openchoreo-ca
    kind: ClusterIssuer
  dnsNames:
    - "*.${DP_DOMAIN}"
    - "${DP_DOMAIN}"
  privateKey:
    rotationPolicy: Always
EOF
wait_for "DP TLS certificate" \
    kubectl wait --for=condition=Ready certificate/dp-gateway-tls \
    -n openchoreo-data-plane --timeout=60s

helm upgrade openchoreo-data-plane \
    oci://ghcr.io/openchoreo/helm-charts/openchoreo-data-plane \
    --version 1.1.1 \
    --namespace openchoreo-data-plane \
    --reuse-values \
    --values - <<EOF
gateway:
  tls:
    enabled: true
    hostname: "*.${DP_DOMAIN}"
    certificateRefs:
      - name: dp-gateway-tls
EOF
wait_for "Data Plane deployments" \
    kubectl wait --for=condition=Available deployment --all \
    -n openchoreo-data-plane --timeout=600s

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
          host: "${DP_DOMAIN}"
          listenerName: http
          port: 80
        https:
          host: "${DP_DOMAIN}"
          listenerName: https
          port: 443
  secretStoreRef:
    name: default
EOF
success "Data Plane registered"
verify_pods openchoreo-data-plane

# ── Step 10: Workflow Plane ──────────────────────────────────────────────────
step "OpenChoreo Workflow Plane (v1.1.1)"
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
        --version 1.1.1 \
        --namespace openchoreo-workflow-plane \
        --create-namespace \
        --set clusterAgent.tls.generateCerts=true \
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
step "OpenChoreo Observability Plane (v1.1.1) — ~25 min"
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

if ! check_helm_release openchoreo-observability-plane openchoreo-observability-plane; then
    helm install openchoreo-observability-plane \
        oci://ghcr.io/openchoreo/helm-charts/openchoreo-observability-plane \
        --version 1.1.1 \
        --namespace openchoreo-observability-plane \
        --create-namespace \
        --set gateway.tls.enabled=false \
        --set clusterAgent.tls.generateCerts=true \
        --set observer.controlPlaneApiUrl="http://openchoreo-api.openchoreo-control-plane.svc.cluster.local:8080" \
        --set observer.extraEnv.AUTH_SERVER_BASE_URL="${THUNDER_PUBLIC_URL}" \
        --set security.oidc.jwksUrl="${THUNDER_INTERNAL_URL}/oauth2/jwks" \
        --set security.oidc.tokenUrl="${THUNDER_INTERNAL_URL}/oauth2/token" \
        --set-string security.oidc.jwksUrlTlsInsecureSkipVerify=true \
        --values https://raw.githubusercontent.com/wso2/agent-manager/amp/v${VERSION}/deployments/single-cluster/values-op.yaml \
        --timeout 25m
fi

wait_for "Observability Plane deployments" \
    kubectl wait --for=condition=Available deployment --all \
    -n openchoreo-observability-plane --timeout=900s

for sts in $(kubectl get statefulset -n openchoreo-observability-plane -o name 2>/dev/null); do
    kubectl rollout status "${sts}" -n openchoreo-observability-plane --timeout=900s
done

# Observability modules
info "Installing observability modules (logs, metrics, traces)..."
helm upgrade --install observability-logs-opensearch \
    oci://ghcr.io/openchoreo/helm-charts/observability-logs-opensearch \
    --create-namespace --namespace openchoreo-observability-plane \
    --version 0.4.1 \
    --set openSearchSetup.openSearchSecretName="opensearch-admin-credentials" \
    --set adapter.openSearchSecretName="opensearch-admin-credentials" \
    --timeout 10m

helm upgrade observability-logs-opensearch \
    oci://ghcr.io/openchoreo/helm-charts/observability-logs-opensearch \
    --namespace openchoreo-observability-plane --version 0.4.1 \
    --reuse-values --set fluent-bit.enabled=true --timeout 10m

helm upgrade --install observability-metrics-prometheus \
    oci://ghcr.io/openchoreo/helm-charts/observability-metrics-prometheus \
    --create-namespace --namespace openchoreo-observability-plane \
    --version 0.6.1 --timeout 10m

helm upgrade --install observability-traces-opensearch \
    oci://ghcr.io/openchoreo/helm-charts/observability-tracing-opensearch \
    --create-namespace --namespace openchoreo-observability-plane \
    --version 0.4.1 \
    --set openSearch.enabled=false \
    --set openSearchSetup.openSearchSecretName="opensearch-admin-credentials" \
    --set opentelemetry-collector.configMap.existingName="amp-opentelemetry-collector-config" \
    --timeout 10m

success "Observability modules installed"

# Observability TLS
info "Waiting for Observability Plane LoadBalancer IP..."
ELAPSED=0; OBS_LB_IP=""
until [ -n "${OBS_LB_IP}" ] || [ $ELAPSED -ge 120 ]; do
    OBS_LB_IP=$(kubectl get svc gateway-default -n openchoreo-observability-plane \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    [ -z "${OBS_LB_IP}" ] && sleep 5 && ELAPSED=$((ELAPSED+5))
done

if [ -n "${OBS_LB_IP}" ]; then
    export OBS_DOMAIN="observer.${OBS_LB_IP//./-}.nip.io"
    kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: obs-gateway-tls
  namespace: openchoreo-observability-plane
spec:
  secretName: obs-gateway-tls
  issuerRef:
    name: openchoreo-ca
    kind: ClusterIssuer
  dnsNames:
    - "*.${OBS_LB_IP//./-}.nip.io"
    - "${OBS_DOMAIN}"
  privateKey:
    rotationPolicy: Always
EOF
    kubectl wait --for=condition=Ready certificate/obs-gateway-tls \
        -n openchoreo-observability-plane --timeout=60s 2>/dev/null || true
    helm upgrade openchoreo-observability-plane \
        oci://ghcr.io/openchoreo/helm-charts/openchoreo-observability-plane \
        --version 1.1.1 --namespace openchoreo-observability-plane \
        --reuse-values \
        --set gateway.tls.enabled=true \
        --set "gateway.tls.hostname=*.${OBS_LB_IP//./-}.nip.io" \
        --set "gateway.tls.certificateRefs[0].name=obs-gateway-tls" \
        --timeout 10m
    success "Observability Plane domain: ${OBS_DOMAIN}"
fi

OP_CA_CERT=$(kubectl get secret cluster-agent-tls \
    -n openchoreo-observability-plane -o jsonpath='{.data.ca\.crt}' | base64 -d)
kubectl apply -f - <<EOF
apiVersion: openchoreo.dev/v1alpha1
kind: ObservabilityPlane
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
kubectl get clusterdataplane,clusterworkflowplane,observabilityplane -n default 2>/dev/null || true

# ============================================================================
# PHASE 2 — AGENT MANAGER
# ============================================================================
echo -e "\n${BOLD}════════════════════════════════════════${NC}"
echo -e "${BOLD} Phase 2: Agent Manager                 ${NC}"
echo -e "${BOLD}════════════════════════════════════════${NC}"

# ── Step 13: Gateway Operator ────────────────────────────────────────────────
step "Gateway Operator (v0.6.0)"
if ! check_helm_release gateway-operator "${DATA_PLANE_NS}"; then
    helm install gateway-operator \
        oci://ghcr.io/wso2/api-platform/helm-charts/gateway-operator \
        --version 0.6.0 \
        --namespace ${DATA_PLANE_NS} \
        --set logging.level=debug \
        --set gatewayApi.installStandardCRDs=false \
        --set gateway.helm.chartVersion=1.1.1 \
        --timeout 600s
fi
wait_for "Gateway Operator" \
    kubectl wait --for=condition=Available \
    deployment -l app.kubernetes.io/name=gateway-operator \
    -n ${DATA_PLANE_NS} --timeout=300s

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

# ── Step 14: Agent Manager Core ──────────────────────────────────────────────
step "Agent Manager (API + Console + PostgreSQL) v${VERSION}"
if ! check_helm_release amp "${AMP_NS}"; then
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
        --set console.config.obsApiBaseUrl="${OBS_API_PUBLIC_URL}" \
        --set agentManagerService.config.keyManager.issuer="${THUNDER_PUBLIC_URL}" \
        --set agentManagerService.config.keyManager.jwksUrl="${THUNDER_INTERNAL_URL}/oauth2/jwks" \
        --set agentManagerService.config.oidc.tokenUrl="${THUNDER_INTERNAL_URL}/oauth2/token" \
        --set agentManagerService.config.openChoreo.baseURL="http://openchoreo-api.openchoreo-control-plane.svc.cluster.local:8080" \
        --timeout 1800s
fi

wait_for "PostgreSQL" \
    kubectl wait --for=jsonpath='{.status.readyReplicas}'=1 \
    statefulset/amp-postgresql -n ${AMP_NS} --timeout=600s
wait_for "AMP API" \
    kubectl wait --for=condition=Available deployment/amp-api -n ${AMP_NS} --timeout=600s
wait_for "AMP Console" \
    kubectl wait --for=condition=Available deployment/amp-console -n ${AMP_NS} --timeout=600s
verify_pods "${AMP_NS}"

# ── Step 15: Platform Resources ──────────────────────────────────────────────
step "Platform Resources (v${VERSION})"
if ! check_helm_release amp-platform-resources "${DEFAULT_NS}"; then
    helm install amp-platform-resources \
        oci://${HELM_CHART_REGISTRY}/wso2-amp-platform-resources-extension \
        --version ${VERSION} \
        --namespace ${DEFAULT_NS} \
        --timeout 1800s
fi
success "Platform Resources installed"

# ── Step 16: Observability Extension ─────────────────────────────────────────
step "Observability Extension — Traces Observer (v${VERSION})"
if ! check_helm_release amp-observability-traces "${OBSERVABILITY_NS}"; then
    helm install amp-observability-traces \
        oci://${HELM_CHART_REGISTRY}/wso2-amp-observability-extension \
        --version ${VERSION} \
        --namespace ${OBSERVABILITY_NS} \
        --timeout 1800s
fi
wait_for "Traces Observer" \
    kubectl wait --for=condition=Available deployment/amp-traces-observer \
    -n ${OBSERVABILITY_NS} --timeout=600s

# ── Step 17: Evaluation Extension ────────────────────────────────────────────
step "Evaluation Extension (v${VERSION})"
if ! check_helm_release amp-evaluation-extension "${BUILD_CI_NS}"; then
    helm install amp-evaluation-extension \
        oci://${HELM_CHART_REGISTRY}/wso2-amp-evaluation-extension \
        --version ${VERSION} \
        --namespace ${BUILD_CI_NS} \
        --timeout 1800s
fi
success "Evaluation Extension installed"

# ── Step 18: API Platform Gateway Extension ───────────────────────────────────
step "API Platform Gateway Extension (v${VERSION})"
if ! check_helm_release api-platform-default-default "${DATA_PLANE_NS}"; then
    helm install api-platform-default-default \
        oci://${HELM_CHART_REGISTRY}/wso2-amp-api-platform-gateway-extension \
        --version ${VERSION} \
        --namespace ${DATA_PLANE_NS} \
        --set agentManager.orgName=default \
        --set gateway.environment=default \
        --timeout 1800s
fi
wait_for "API Platform bootstrap job" \
    kubectl wait --for=condition=complete job/api-platform-default-default-bootstrap \
    -n ${DATA_PLANE_NS} --timeout=300s

kubectl apply -f https://raw.githubusercontent.com/wso2/agent-manager/amp/v${VERSION}/deployments/values/otel-collector-rest-api.yaml
success "OTel collector RestApi applied"

# Verify gateway status
GW_STATUS=$(kubectl get apigateway api-platform-default-default \
    -n ${DATA_PLANE_NS} -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' \
    2>/dev/null || echo "Unknown")
if [ "${GW_STATUS}" = "True" ]; then
    success "API Gateway status: Programmed"
else
    warning "API Gateway status: ${GW_STATUS} (may still be initializing)"
fi

# ── Step 19: Rancher Desktop cgroup fix ──────────────────────────────────────
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

# ============================================================================
# FINAL SUMMARY
# ============================================================================
echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} Installation Summary                                           ${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${BOLD}Helm Releases:${NC}"
helm list -A | grep -E 'openchoreo|amp|gateway|openbao|cert-manager|external-secrets' || true

echo ""
echo -e "${BOLD}Plane Registrations:${NC}"
kubectl get clusterdataplane,clusterworkflowplane,observabilityplane -n default 2>/dev/null || true

echo ""
echo -e "${BOLD}Pod Status:${NC}"
for ns in openchoreo-control-plane openchoreo-data-plane openchoreo-workflow-plane \
          openchoreo-observability-plane wso2-amp amp-thunder; do
    NOT_READY=$(kubectl get pods -n "${ns}" --no-headers 2>/dev/null \
        | { grep -v -E 'Running|Completed' || true; } | wc -l | tr -d ' ')
    TOTAL=$(kubectl get pods -n "${ns}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "${NOT_READY}" -eq 0 ]; then
        success "${ns}: ${TOTAL}/${TOTAL} pods Running"
    else
        warning "${ns}: $((TOTAL-NOT_READY))/${TOTAL} pods Running"
    fi
done

echo ""
echo -e "${BOLD}Domains:${NC}"
echo -e "  OpenChoreo API: https://api.${CP_BASE_DOMAIN}"
echo -e "  Data Plane:     ${DP_DOMAIN}"

echo ""
if [ ${ERRORS} -eq 0 ]; then
    echo -e "${GREEN}${BOLD}✓ Installation completed successfully!${NC}"
else
    echo -e "${YELLOW}${BOLD}⚠ Installation completed with ${ERRORS} warning(s) — review output above${NC}"
fi

# ============================================================================
# START PORT-FORWARDS
# ============================================================================
echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} Starting Port-Forwards                                         ${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════════════${NC}"

# Kill any existing port-forwards to avoid conflicts
pkill -f "kubectl port-forward" 2>/dev/null || true
sleep 1

start_portforward() {
    local desc="$1" ns="$2" svc="$3" ports="$4"
    kubectl port-forward -n "${ns}" "svc/${svc}" "${ports}" \
        > "/tmp/pf-${svc}.log" 2>&1 &
    local PID=$!
    sleep 1
    if kill -0 "${PID}" 2>/dev/null; then
        success "${desc} -> localhost:${ports%%:*}"
    else
        error "${desc} port-forward failed (check /tmp/pf-${svc}.log)"
    fi
}

start_portforward "Console"         wso2-amp                           amp-console                                                  3000:3000
start_portforward "API"             wso2-amp                           amp-api                                                      9000:9000
start_portforward "Thunder"         amp-thunder                        amp-thunder-extension-service                                8090:8090
start_portforward "Traces Observer" openchoreo-observability-plane     amp-traces-observer                                          9098:9098
start_portforward "OTel Gateway"    openchoreo-data-plane              api-platform-default-default-gateway-gateway-runtime         22893:22893

# Save a helper script for future sessions
cat > ~/amp-portforward.sh << 'EOF'
#!/bin/bash
# AMP Port-Forward Helper - run this after every Rancher Desktop restart
pkill -f "kubectl port-forward" 2>/dev/null || true
sleep 1
kubectl port-forward -n wso2-amp svc/amp-console 3000:3000 > /tmp/pf-console.log 2>&1 &
kubectl port-forward -n wso2-amp svc/amp-api 9000:9000 > /tmp/pf-api.log 2>&1 &
kubectl port-forward -n amp-thunder svc/amp-thunder-extension-service 8090:8090 > /tmp/pf-thunder.log 2>&1 &
kubectl port-forward -n openchoreo-observability-plane svc/amp-traces-observer 9098:9098 > /tmp/pf-traces.log 2>&1 &
kubectl port-forward -n openchoreo-data-plane svc/api-platform-default-default-gateway-gateway-runtime 22893:22893 > /tmp/pf-otel.log 2>&1 &
echo "AMP port-forwards started"
echo "  Console:  http://localhost:3000  (admin / admin)"
echo "  API:      http://localhost:9000"
echo "  Thunder:  http://localhost:8090"
echo "  Traces:   http://localhost:9098"
echo "  OTel:     http://localhost:22893/otel"
EOF
chmod +x ~/amp-portforward.sh
success "Port-forward helper saved -> ~/amp-portforward.sh"

echo ""
echo -e "${BOLD}Access URLs:${NC}"
echo -e "  Console:  ${GREEN}http://localhost:3000${NC}  (admin / admin)"
echo -e "  API:      http://localhost:9000"
echo -e "  Thunder:  http://localhost:8090"
echo -e "  Traces:   http://localhost:9098"
echo -e "  OTel:     http://localhost:22893/otel"
echo ""
echo -e "${BOLD}After future restarts run:${NC} ~/amp-portforward.sh"
