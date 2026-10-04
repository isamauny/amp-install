#!/bin/bash
# ============================================================================
# amp-guardrails.sh — configure the gateway-level settings of the console's
# "Tier 2" guardrails and unlock them in the Agent Manager console.
#
# The console hides five groups of guardrail policies unless a capability flag
# is set (console/…/hooks/guardrails.ts, CAPABILITY_POLICY_MAP), because each
# needs settings that live on the GATEWAY, not on the policy attachment:
#
#   awsBedrock          aws-bedrock-guardrail
#   azureContentSafety  azure-content-safety-content-moderation
#   graniteGuardian     granite-guardian-prompt-injection
#   nemoGuard           nvidia-nemoguard-content-safety
#   semanticGuardrails  semantic-prompt-guard, semantic-cache
#                       (also used by semantic-tool-filtering, which the
#                       console always shows)
#
# It also configures custom policies the console always shows, whatever their
# gateway settings — the TypeSafe Jev policies, which read
# [policy_configurations.typesafe_jev_v0] (and _tool_filtering_v0): attached
# without an API key there, they fail at runtime.
#
# Turning a flag on without the gateway settings offers a policy that fails
# when attached, so this script does both, in that order:
#
#   1. gateway settings — the wso2-amp-api-platform-gateway-extension chart's
#      apiGateway.config.config_toml (root-level TOML keys the policies read
#      as ${config.<key>}) and apiGateway.config.systemExtraEnv (env vars,
#      from a Kubernetes Secret, behind every secret value). The chart renders
#      these into each gateway's configRef ConfigMap; gateway-operator rolls
#      them into the gateway's own <name>-gw release.
#   2. console flags — console.config.guardrailCapabilities.* on the
#      wso2-agent-manager chart (release `amp`).
#
# Secrets never touch a ConfigMap, Helm values or this machine's disk: they
# are typed hidden, written straight into the Secret `amp-guardrails` in each
# gateway namespace, and referenced from config.toml as '{{ env "VAR" }}',
# which the gateway resolves when it loads its configuration.
# ============================================================================
set -euo pipefail

usage() {
    cat <<'HELPEOF'
amp-guardrails.sh — gateway settings + console flags for the Tier 2 guardrails

USAGE
  ./scripts/amp-guardrails.sh status             what is configured, deployed and enabled
  ./scripts/amp-guardrails.sh configure          prompt for settings, store secrets, then offer to apply
  ./scripts/amp-guardrails.sh apply              push the stored settings to every gateway + the console
  ./scripts/amp-guardrails.sh apply --dry-run    show the rendered config and flags, change nothing
  ./scripts/amp-guardrails.sh apply --yes        skip the confirmation prompt
  ./scripts/amp-guardrails.sh apply --reason "CHG-1234: enable Azure Content Safety"
                                                 why — recorded in the audit trail
  ./scripts/amp-guardrails.sh --help             this message

PROVIDERS
  awsBedrock          AWS Bedrock Guardrail
  azureContentSafety  Azure AI Content Safety
  graniteGuardian     IBM Granite Guardian (OpenAI-compatible endpoint)
  nemoGuard           NVIDIA NeMo Guard (OpenAI-compatible endpoint)
  semanticGuardrails  embedding provider + vector database
                      (semantic-prompt-guard, semantic-cache, semantic-tool-filtering)
                      With vector database REDIS, the in-cluster Redis from
                      ./scripts/amp-redis.sh is the default host, and Enter at
                      the password prompt copies its password.
  typesafeJev         TypeSafe Jev (custom gateway-builder policies: content
                      safety, model routing, tool filtering, MCP tool intent
                      verification, MCP tool result screening). No console
                      flag — the console always lists them; this supplies the
                      API key they need. Rendered as
                      [policy_configurations.typesafe_jev_v0] tables; empty
                      optional settings are left out so the policy defaults
                      apply.

  Before applying, the plan predicts each gateway's resulting config.toml and
  parses it, so a table that collides with one the charts emit is refused
  instead of crash-looping the gateway.

WHERE THINGS ARE KEPT
  Non-secret answers   scripts/guardrails.conf (gitignored; override with
                       GUARDRAILS_CONF=…), so re-running `configure` starts from
                       the previous answers.
  Secrets              Kubernetes Secret amp-guardrails, one per gateway
                       namespace. Never written to disk or Helm values.

AUDIT TRAIL
  Every apply, and every secret update in configure, writes an immutable record
  (who, when, why, the config diff, flag changes, how to roll back) — read it
  with ./scripts/amp-audit.sh. Secret values are never recorded, only key names.
  AMP_AUDIT_REQUIRE_REASON=1 makes --reason mandatory.

  `apply` always renders ALL enabled providers: config_toml and systemExtraEnv
  are replaced wholesale on every upgrade, so a partial render would silently
  drop the providers it left out.
HELPEOF
}

ACTION=""
DRY_RUN=0
ASSUME_YES=0
AUDIT_REASON="${AMP_AUDIT_REASON:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        status|configure|apply) ACTION="$1" ;;
        --dry-run)              DRY_RUN=1 ;;
        --yes|-y)               ASSUME_YES=1 ;;
        --reason)               [ $# -ge 2 ] || { echo "--reason needs a value" >&2; exit 1; }
                                AUDIT_REASON="$2"; shift ;;
        -h|--help)              usage; exit 0 ;;
        *)                      echo "Unknown argument: $1" >&2; echo >&2; usage >&2; exit 1 ;;
    esac
    shift
done
[ -z "${ACTION}" ] && { usage; exit 0; }

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=amp-audit.sh
source "${SCRIPT_DIR}/amp-audit.sh"
GUARDRAILS_CONF="${GUARDRAILS_CONF:-${SCRIPT_DIR}/guardrails.conf}"
HELM_CHART_REGISTRY="ghcr.io/wso2"
AMP_NS="wso2-amp"
AMP_RELEASE="amp"
DATA_PLANE_NS="openchoreo-data-plane"
SECRET_NAME="${GUARDRAILS_SECRET:-amp-guardrails}"
ENV_PREFIX="APIP_GW_"
# First line of every config_toml this script writes. A config_toml without it
# was written by someone else, and apply refuses to overwrite it.
TOML_MARKER="# managed by amp-guardrails.sh - edit with ./scripts/amp-guardrails.sh configure"
# How long the operator gets to redeploy a gateway from its updated ConfigMap
# before the script upgrades the gateway release itself.
OPERATOR_WAIT_SECONDS="${OPERATOR_WAIT_SECONDS:-120}"

# ── Providers and their settings ─────────────────────────────────────────────
# flag|display name|policies it unlocks|console flag
#   console flag: "flag" when the console hides the policies behind
#   console.config.guardrailCapabilities.<flag>; "-" when it always shows them
#   (custom policies, which are in neither of its hard-coded lists).
PROVIDERS="awsBedrock|AWS Bedrock Guardrail|aws-bedrock-guardrail|flag
azureContentSafety|Azure AI Content Safety|azure-content-safety-content-moderation|flag
graniteGuardian|IBM Granite Guardian|granite-guardian-prompt-injection|flag
nemoGuard|NVIDIA NeMo Guard|nvidia-nemoguard-content-safety|flag
semanticGuardrails|Semantic guardrails (embeddings + vector DB)|semantic-prompt-guard, semantic-cache, semantic-tool-filtering|flag
typesafeJev|TypeSafe Jev|typesafe-jev-content-safety, -model-routing, -tool-filtering, -mcp-tool-intent-verification, -mcp-tool-result-screening|-"

# flag|name|type|req/opt|default|prompt|config.toml path
#   name: shell variable, guardrails.conf entry and Secret key (unique)
#   type: str, url, int, list (comma-separated → TOML array), secret,
#         enum:A/B/C
#   config.toml path: empty for a root key named <name> — read by the policy
#         as ${config.<name>}. Otherwise <table>.<key>, read as
#         ${config.<table>.<key>}: rendered under a [<table>] section after
#         every root key, integers bare. An optional table key left empty is
#         not rendered at all, so the policy falls back to its schema default
#         (the policy engine skips a missing optional ${config} key).
# Keys, requiredness and defaults are taken from the policy definitions'
# systemParameters (gateway-controller policies/, builder 1.2.1). The AWS
# region and guardrail ID are optional in the schema — an attachment may
# supply them — but a gateway-wide value is what makes the policy usable as
# picked from the console, so they are asked for as required here.
PARAMS="awsBedrock|awsbedrock_guardrail_region|str|req|us-east-1|AWS region of the Bedrock guardrail
awsBedrock|awsbedrock_guardrail_id|str|req||Bedrock guardrail ID
awsBedrock|awsbedrock_guardrail_version|str|req|DRAFT|Guardrail version (DRAFT or a version number)
awsBedrock|awsbedrock_access_key_id|secret|opt||AWS access key ID (empty: role or default credential chain)
awsBedrock|awsbedrock_secret_access_key|secret|opt||AWS secret access key
awsBedrock|awsbedrock_session_token|secret|opt||AWS session token (temporary credentials only)
awsBedrock|awsbedrock_role_arn|str|opt||IAM role ARN to assume (empty: no role)
awsBedrock|awsbedrock_role_region|str|opt||Region for the role assumption (required with a role ARN)
awsBedrock|awsbedrock_role_external_id|str|opt||External ID for the role assumption
awsBedrock|awsbedrock_allowed_regions|list|opt||Allowed regions, comma-separated, * suffix allowed (empty: any)
awsBedrock|awsbedrock_allowed_guardrail_ids|list|opt||Allowed guardrail IDs, comma-separated (empty: any)
awsBedrock|awsbedrock_allowed_role_arns|list|opt||Allowed role ARNs, comma-separated, * suffix allowed (empty: any)
awsBedrock|awsbedrock_allowed_auth_types|list|opt||Allowed authentication types, comma-separated (empty: any)
azureContentSafety|azurecontentsafety_endpoint|url|req||Endpoint, no trailing slash (https://<resource>.cognitiveservices.azure.com)
azureContentSafety|azurecontentsafety_key|secret|req||Subscription key
graniteGuardian|granite_guardian_endpoint|url|req||OpenAI-compatible endpoint (e.g. http://granite-guardian:8000)
graniteGuardian|granite_guardian_api_key|secret|opt||Bearer token (empty if the endpoint needs none)
graniteGuardian|granite_guardian_model|str|req|ibm-granite/granite-guardian-3.3-8b|Model name
graniteGuardian|granite_guardian_timeout|int|req|10|Request timeout, seconds
nemoGuard|nemoguard_endpoint|url|req||OpenAI-compatible endpoint (e.g. http://nemoguard:8101)
nemoGuard|nemoguard_api_key|secret|opt||Bearer token (empty if the endpoint needs none)
nemoGuard|nemoguard_model|str|req|nemoguard|Model name (must match the vLLM --lora-modules alias)
nemoGuard|nemoguard_timeout|int|req|30|Request timeout, seconds
semanticGuardrails|embedding_provider|enum:OPENAI/MISTRAL/AZURE_OPENAI|req|OPENAI|Embedding provider
semanticGuardrails|embedding_provider_endpoint|url|req||Embedding endpoint (OpenAI: https://api.openai.com/v1/embeddings)
semanticGuardrails|embedding_provider_model|str|opt|text-embedding-3-small|Embedding model (not used with AZURE_OPENAI)
semanticGuardrails|embedding_provider_dimension|int|req|1536|Embedding dimension (OpenAI 1536, Mistral 1024)
semanticGuardrails|embedding_provider_api_key|secret|req||Embedding provider API key
semanticGuardrails|vector_db_provider|enum:REDIS/MILVUS|req|REDIS|Vector database (semantic-cache)
semanticGuardrails|vector_db_provider_host|str|req||Vector database host
semanticGuardrails|vector_db_provider_port|int|req|6379|Vector database port
semanticGuardrails|vector_db_provider_username|str|opt||Vector database username
semanticGuardrails|vector_db_provider_password|secret|opt||Vector database password
semanticGuardrails|vector_db_provider_database|str|opt||Vector database name
semanticGuardrails|vector_db_provider_ttl|int|opt|3600|Cache entry TTL, seconds
typesafeJev|jev_api_key|secret|req||TypeSafe AI API key (https://typesafe.ai)|policy_configurations.typesafe_jev_v0.api_key
typesafeJev|jev_base_url|url|opt||Jev API base URL (empty: the policy default; override for testing only)|policy_configurations.typesafe_jev_v0.base_url
typesafeJev|jev_model|str|opt||Jev model identifier (empty: the policy default)|policy_configurations.typesafe_jev_v0.model
typesafeJev|jev_max_tools|int|opt||Tool filtering: largest tools array evaluated (empty: 200)|policy_configurations.typesafe_jev_tool_filtering_v0.max_tools
typesafeJev|jev_max_tool_bytes|int|opt||Tool filtering: max metadata bytes per tool (empty: 4096)|policy_configurations.typesafe_jev_tool_filtering_v0.max_tool_bytes
typesafeJev|jev_max_total_bytes|int|opt||Tool filtering: max metadata bytes per request (empty: 131072)|policy_configurations.typesafe_jev_tool_filtering_v0.max_total_bytes"

provider_flags() { echo "${PROVIDERS}" | cut -d'|' -f1; }
has_console_flag() { [ "$(provider_field "$1" 4)" = "flag" ]; }
flagged_providers() { for f in $(provider_flags); do has_console_flag "${f}" && echo "${f}"; done; true; }
param_path() { echo "${PARAMS}" | awk -F'|' -v k="$1" '$2==k {print $7}'; }
provider_field() { echo "${PROVIDERS}" | awk -F'|' -v f="$1" -v n="$2" '$1==f {print $n}'; }
provider_params() { echo "${PARAMS}" | awk -F'|' -v f="$1" '$1==f'; }
env_name() { echo "${ENV_PREFIX}$(echo "$1" | tr '[:lower:]' '[:upper:]')"; }
enabled() { local v="ENABLED_$1"; [ "${!v:-0}" = "1" ]; }

# ── Pre-flight ───────────────────────────────────────────────────────────────
step "Pre-flight checks"
command -v kubectl &>/dev/null || die "kubectl not found"
command -v helm &>/dev/null    || die "helm not found"
command -v python3 &>/dev/null || die "python3 not found"
# Same constraint as the installer: Helm 4's hook lifecycle hangs here, and the
# extension chart's upgrade runs a bootstrap hook.
[ "$(helm version --short 2>/dev/null | sed -E 's/^v([0-9]+)\..*/\1/')" = "3" ] \
    || die "Helm $(helm version --short 2>/dev/null) found — Helm v3 is required (brew install helm@3)"
kubectl cluster-info &>/dev/null || die "Cannot connect to the Kubernetes cluster"
success "kubectl, helm 3 and cluster reachable ($(kubectl config current-context))"

chart_version_of() {  # release namespace → installed chart version, or empty
    helm list -n "$2" -f "^$1\$" -o json 2>/dev/null \
        | python3 -c 'import sys,json;r=json.load(sys.stdin);print(r[0]["chart"].rsplit("-",1)[1] if r else "")'
}
revision_of() {
    helm list -n "$2" -f "^$1\$" -o json 2>/dev/null \
        | python3 -c 'import sys,json;r=json.load(sys.stdin);print(r[0]["revision"] if r else 0)'
}

AMP_CHART_VERSION=$(chart_version_of "${AMP_RELEASE}" "${AMP_NS}")
[ -n "${AMP_CHART_VERSION}" ] || die "Release ${AMP_RELEASE} not found in ${AMP_NS} — run amp-install-rancher.sh first"

# One entry per APIGateway: its namespace, the extension release that owns it
# (and its configRef ConfigMap), and the <name>-gw release the operator made.
GW_NS=(); GW_NAME=(); GW_EXT_REL=(); GW_CONFIGMAP=()
while read -r ns name rel cm; do
    [ -z "${ns}" ] && continue
    if [ -z "${rel}" ] || [ "${rel}" = "<none>" ]; then
        warning "${ns}/${name}: not created by a Helm release — skipped"
        continue
    fi
    GW_NS+=("${ns}"); GW_NAME+=("${name}"); GW_EXT_REL+=("${rel}"); GW_CONFIGMAP+=("${cm}")
done <<< "$(kubectl get apigateway -A -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name} {.metadata.annotations.meta\.helm\.sh/release-name} {.spec.configRef.name}{"\n"}{end}' 2>/dev/null)"
[ "${#GW_NS[@]}" -gt 0 ] || die "No APIGateway resources found"
success "Gateways: $(for i in "${!GW_NS[@]}"; do printf '%s/%s ' "${GW_NS[$i]}" "${GW_NAME[$i]}"; done)"

GATEWAY_CHART=$(kubectl get cm gateway-operator-config -n "${DATA_PLANE_NS}" \
    -o jsonpath='{.data.config\.yaml}' 2>/dev/null \
    | sed -nE 's/^ *helm_chart_name: *"?([^"]+)"?.*/\1/p' | head -1)
GATEWAY_CHART="${GATEWAY_CHART:-oci://ghcr.io/wso2/api-platform/helm-charts/gateway}"

# ── Stored answers ───────────────────────────────────────────────────────────
# Written by this script with printf %q, so sourcing it is safe.
# shellcheck disable=SC1090
[ -f "${GUARDRAILS_CONF}" ] && source "${GUARDRAILS_CONF}"

secret_has_key() {  # namespace key
    [ -n "$(kubectl get secret "${SECRET_NAME}" -n "$1" -o jsonpath="{.data.$2}" 2>/dev/null)" ]
}
missing_secrets() {  # flag namespace → " key key" of required secrets not in the Secret
    local missing=""
    while IFS='|' read -r _ key type req _ _; do
        [ "${type}" = "secret" ] && [ "${req}" = "req" ] || continue
        secret_has_key "$2" "${key}" || missing="${missing} ${key}"
    done <<< "$(provider_params "$1")"
    echo "${missing}"
}

# The in-cluster Redis from amp-redis.sh, offered as the semantic guardrails
# vector database: its host as the default, its password copied on Enter.
REDIS_NS="${REDIS_NS:-amp-redis}"
INCLUSTER_REDIS_HOST=""
if kubectl get svc redis -n "${REDIS_NS}" &>/dev/null && kubectl get secret redis -n "${REDIS_NS}" &>/dev/null; then
    INCLUSTER_REDIS_HOST="redis.${REDIS_NS}.svc.cluster.local"
fi

console_flag() {
    kubectl get cm amp-console -n "${AMP_NS}" -o jsonpath="{.data.$1}" 2>/dev/null
}
flag_env() {  # awsBedrock → GUARDRAIL_CAP_AWS_BEDROCK
    echo "GUARDRAIL_CAP_$(echo "$1" | sed -E 's/([a-z])([A-Z])/\1_\2/g' | tr '[:lower:]' '[:upper:]')"
}

# ── Status ───────────────────────────────────────────────────────────────────
show_status() {
    step "Status"
    for flag in $(provider_flags); do
        local name; name=$(provider_field "${flag}" 2)
        local ui=""
        has_console_flag "${flag}" && ui=$(console_flag "$(flag_env "${flag}")")
        echo -e "\n  ${BOLD}${name}${NC}  (${flag})"
        echo "    stored settings:  $(enabled "${flag}" && echo enabled || echo "not configured")"
        if has_console_flag "${flag}"; then
            echo "    console flag:     ${ui:-unknown}"
        else
            echo "    console flag:     none — the console always shows these policies"
        fi
        # Deployed = the provider's first setting is in the gateway's config:
        # its root key, or the [table] header of a table key.
        local first_name first_path probe
        first_name=$(provider_params "${flag}" | head -1 | cut -d'|' -f2)
        first_path=$(param_path "${first_name}")
        if [ -n "${first_path}" ]; then
            probe="^\[$(echo "${first_path%.*}" | sed 's/\./\\./g')\]"
        else
            probe="^${first_name} *="
        fi
        for i in "${!GW_NS[@]}"; do
            local ns="${GW_NS[$i]}" rel="${GW_NAME[$i]}-gw"
            local toml; toml=$(kubectl get cm "${rel}-gateway-config" -n "${ns}" -o jsonpath='{.data.config\.toml}' 2>/dev/null || true)
            local deployed="no"
            echo "${toml}" | grep -qE "${probe}" && deployed="yes"
            local missing; missing=$(missing_secrets "${flag}" "${ns}")
            printf '    %-24s gateway config: %s' "${ns}:" "${deployed}"
            if enabled "${flag}" && [ -n "${missing}" ]; then printf ', missing secrets:%s' "${missing}"; fi
            echo
            if { [ "${ui}" = "true" ] || ! has_console_flag "${flag}"; } && [ "${deployed}" = "no" ]; then
                warning "console offers ${flag} policies but ${ns}/${GW_NAME[$i]} has no settings for them — they will fail when attached"
            fi
        done
    done
}

if [ "${ACTION}" = "status" ]; then show_status; exit 0; fi

# ── Configure ────────────────────────────────────────────────────────────────
# Prompts write into shell variables named after the config.toml keys; secret
# answers go to files in a private temp dir and from there straight into the
# Secret — never into a variable that is written out, never into argv.
SECRET_TMP=""
cleanup() { [ -n "${SECRET_TMP}" ] && rm -rf "${SECRET_TMP}"; return 0; }
trap 'rc=$?; cleanup; audit_on_exit ${rc}' EXIT

validate() {  # type value → 0 if acceptable (non-empty values only)
    local type="$1" value="$2"
    case "${type}" in
        url)    [[ "${value}" =~ ^https?://[^[:space:]]+$ ]] && [[ "${value}" != */ ]] ;;
        int)    [[ "${value}" =~ ^[0-9]+$ ]] ;;
        enum:*) local opts="${type#enum:}"; [[ "/${opts}/" == */"${value}"/* ]] ;;
        *)      return 0 ;;
    esac
}

prompt_param() {  # flag key type req default label
    local flag="$1" key="$2" type="$3" req="$4" default="$5" label="$6"
    local current="${!key:-}" answer
    [ -z "${current}" ] && current="${default}"
    if [ "${key}" = "vector_db_provider_host" ] && [ -z "${!key:-}" ] && [ -n "${INCLUSTER_REDIS_HOST}" ] \
        && [ "${vector_db_provider:-}" = "REDIS" ]; then
        current="${INCLUSTER_REDIS_HOST}"
    fi
    local hint=""
    [ "${req}" = "req" ] && hint=" (required)"
    case "${type}" in
        enum:*) hint="${hint} [${type#enum:}]" ;;
    esac

    if [ "${type}" = "secret" ]; then
        local primary_ns="${GW_NS[0]}" have="" incluster=0
        secret_has_key "${primary_ns}" "${key}" && have=" [Enter keeps the stored value]"
        # Pointing at the in-cluster Redis: Enter copies its current password,
        # which also picks up a new one after amp-redis.sh reinstalled it.
        if [ "${key}" = "vector_db_provider_password" ] && [ -n "${INCLUSTER_REDIS_HOST}" ] \
            && [ "${vector_db_provider_host:-}" = "${INCLUSTER_REDIS_HOST}" ]; then
            incluster=1; have=" [Enter uses the in-cluster Redis password]"
        fi
        while true; do
            printf '    %s%s%s: ' "${label}" "${hint}" "${have}"
            IFS= read -rs answer </dev/tty || answer=""
            echo
            if [ -n "${answer}" ]; then
                printf '%s' "${answer}" > "${SECRET_TMP}/${key}"
                return 0
            fi
            if [ "${incluster}" = "1" ]; then
                kubectl get secret redis -n "${REDIS_NS}" -o jsonpath='{.data.password}' \
                    | base64 -d > "${SECRET_TMP}/${key}"
                [ -s "${SECRET_TMP}/${key}" ] && return 0
                rm -f "${SECRET_TMP}/${key}"
                echo "      could not read Secret ${REDIS_NS}/redis — type the password"
                incluster=0; have=""; continue
            fi
            [ -n "${have}" ] && return 0
            [ "${req}" = "opt" ] && return 0
            echo "      a value is required"
        done
    fi

    while true; do
        printf '    %s%s [%s]: ' "${label}" "${hint}" "${current}"
        IFS= read -r answer </dev/tty || answer=""
        [ -z "${answer}" ] && answer="${current}"
        if [ "${answer}" = "-" ]; then answer=""; fi
        if [ -z "${answer}" ]; then
            [ "${req}" = "opt" ] && { printf -v "${key}" '%s' ""; return 0; }
            echo "      a value is required"; continue
        fi
        if ! validate "${type}" "${answer}"; then
            case "${type}" in
                url)    echo "      must be an http(s):// URL without a trailing slash" ;;
                int)    echo "      must be a whole number" ;;
                enum:*) echo "      must be one of: ${type#enum:}" ;;
            esac
            continue
        fi
        printf -v "${key}" '%s' "${answer}"
        return 0
    done
}

write_conf() {
    {
        echo "# Written by amp-guardrails.sh — non-secret settings only. Secrets live in the"
        echo "# Kubernetes Secret ${SECRET_NAME} in each gateway namespace."
        for flag in $(provider_flags); do
            local v="ENABLED_${flag}"
            printf 'ENABLED_%s=%q\n' "${flag}" "${!v:-0}"
            while IFS='|' read -r _ key type _ _ _; do
                [ "${type}" = "secret" ] && continue
                printf '%s=%q\n' "${key}" "${!key:-}"
            done <<< "$(provider_params "${flag}")"
        done
    } > "${GUARDRAILS_CONF}.tmp"
    mv "${GUARDRAILS_CONF}.tmp" "${GUARDRAILS_CONF}"
}

# Merges the answered secret keys into ${SECRET_NAME} in every gateway
# namespace. Keys present in the first namespace's Secret but missing from
# another are copied across, so a gateway added later is brought level. The
# manifest is built in the private temp dir and applied from there.
store_secrets() {
    local primary_ns="${GW_NS[0]}"
    local primary_json
    primary_json=$(kubectl get secret "${SECRET_NAME}" -n "${primary_ns}" -o json 2>/dev/null || echo '{}')
    for ns in "${GW_NS[@]}"; do
        local existing_json
        existing_json=$(kubectl get secret "${SECRET_NAME}" -n "${ns}" -o json 2>/dev/null || echo '{}')
        PRIMARY_JSON="${primary_json}" EXISTING_JSON="${existing_json}" \
        python3 - "${SECRET_TMP}" "${ns}" "${SECRET_NAME}" > "${SECRET_TMP}/manifest-${ns}.json" <<'PYEOF'
import base64, json, os, sys
tmp, ns, name = sys.argv[1], sys.argv[2], sys.argv[3]
data = dict((json.loads(os.environ["PRIMARY_JSON"]) or {}).get("data") or {})
data.update((json.loads(os.environ["EXISTING_JSON"]) or {}).get("data") or {})
for f in os.listdir(tmp):
    if f.startswith("manifest-"):
        continue
    with open(os.path.join(tmp, f), "rb") as fh:
        data[f] = base64.b64encode(fh.read()).decode()
print(json.dumps({
    "apiVersion": "v1", "kind": "Secret", "type": "Opaque",
    "metadata": {"name": name, "namespace": ns,
                 "labels": {"app.kubernetes.io/managed-by": "amp-guardrails.sh"}},
    "data": data,
}))
PYEOF
        kubectl apply -f "${SECRET_TMP}/manifest-${ns}.json" >/dev/null
        success "Secret ${ns}/${SECRET_NAME} updated"
        audit_change "${ns}/${SECRET_NAME}" "secret keys set (values not recorded)" "" \
            "$(ls "${SECRET_TMP}" | grep -v '^manifest-' | tr '\n' ' ' | sed 's/ $//')"
    done
}

if [ "${ACTION}" = "configure" ]; then
    [ -t 0 ] || die "configure is interactive — run it from a terminal"
    SECRET_TMP=$(mktemp -d)
    chmod 700 "${SECRET_TMP}"

    step "Configure providers"
    info "Enter keeps the value in [brackets]; '-' clears an optional value."
    for flag in $(provider_flags); do
        name=$(provider_field "${flag}" 2)
        echo -e "\n  ${BOLD}${name}${NC}  unlocks: $(provider_field "${flag}" 3)"
        missing=$(missing_secrets "${flag}" "${GW_NS[0]}")
        if enabled "${flag}" && [ -n "${missing}" ]; then
            # e.g. after a cluster reset: the settings file survived, the
            # Secret did not. Keeping it as-is would only fail at apply.
            warning "Enabled, but ${GW_NS[0]}/${SECRET_NAME} lacks:${missing} — editing"
        elif enabled "${flag}"; then
            printf '    Enabled. Keep it enabled? [Y/n/e=edit] '
            read -r ans </dev/tty || ans=""
            case "${ans}" in
                [Nn]*) printf -v "ENABLED_${flag}" '%s' 0; continue ;;
                [Ee]*) ;;
                *)     continue ;;
            esac
        else
            printf '    Enable? [y/N] '
            read -r ans </dev/tty || ans=""
            case "${ans}" in [Yy]*) ;; *) continue ;; esac
        fi
        while IFS='|' read -r f key type req default label _; do
            prompt_param "${f}" "${key}" "${type}" "${req}" "${default}" "${label}"
        done <<< "$(provider_params "${flag}")"
        printf -v "ENABLED_${flag}" '%s' 1
    done

    step "Save"
    write_conf
    success "Settings saved to ${GUARDRAILS_CONF}"
    if [ -n "$(ls "${SECRET_TMP}")" ]; then
        audit_reason
        audit_begin "guardrails-secrets" "${BASH_SOURCE[0]}"
        AUDIT_SUMMARY_SO_FAR="guardrail secrets updated"
        store_secrets
        audit_commit "success" "guardrail secrets updated: $(ls "${SECRET_TMP}" | grep -v '^manifest-' | tr '\n' ' ' | sed 's/ $//')"
    else
        info "No secret values entered — Secrets unchanged"
    fi
    rm -rf "${SECRET_TMP}"; SECRET_TMP=""

    printf '\n  Apply to the gateways and console now? [Y/n] '
    read -r ans </dev/tty || ans=""
    case "${ans}" in [Nn]*) info "Run ./scripts/amp-guardrails.sh apply when ready"; exit 0 ;; esac
    AMP_AUDIT_REASON="${AUDIT_REASON:-}" exec "$0" apply
fi

# ── Apply ────────────────────────────────────────────────────────────────────
[ -f "${GUARDRAILS_CONF}" ] || die "No settings yet — run ./scripts/amp-guardrails.sh configure first"

toml_string() {  # value → TOML literal string, or basic string when it holds a quote
    python3 -c '
import json, sys
v, q = sys.argv[1], chr(39)
print(q + v + q if q not in v and "\n" not in v else json.dumps(v))' "$1"
}
toml_list() {  # "a, b" → ["a", "b"]
    python3 -c 'import json,sys;print(json.dumps([s.strip() for s in sys.argv[1].split(",") if s.strip()]))' "$1"
}

# Renders config_toml and the env list for one gateway namespace. Prints the
# TOML, and records the env vars to inject in RENDER_ENV (space-separated) —
# only for secrets that exist in that namespace's Secret. An optional secret
# with no stored value renders as "" rather than an env token whose variable
# would not exist.
render_for_ns() {
    local ns="$1"
    RENDER_ENV=""
    RENDER_MISSING=""
    local any=0
    echo "${TOML_MARKER}"
    # Root keys first: TOML assigns a bare key to the most recent [table], so
    # none may follow a table header.
    for flag in $(provider_flags); do
        enabled "${flag}" || continue
        any=1
        provider_params "${flag}" | awk -F'|' '$7==""' | grep -q . || continue
        echo
        echo "# $(provider_field "${flag}" 2) - $(provider_field "${flag}" 3)"
        while IFS='|' read -r _ key type req _ _ path; do
            [ -z "${path}" ] || continue
            if [ "${type}" = "secret" ]; then
                if secret_has_key "${ns}" "${key}"; then
                    local var; var=$(env_name "${key}")
                    echo "${key} = '{{ env \"${var}\" }}'"
                    RENDER_ENV="${RENDER_ENV} ${key}"
                else
                    [ "${req}" = "req" ] && RENDER_MISSING="${RENDER_MISSING} ${key}"
                    echo "${key} = \"\""
                fi
                continue
            fi
            local value="${!key:-}"
            case "${type}" in
                list) echo "${key} = $(toml_list "${value}")" ;;
                # Numbers are written as strings, as in the extension chart's
                # own config_toml example for these same keys.
                *)    echo "${key} = $(toml_string "${value}")" ;;
            esac
        done <<< "$(provider_params "${flag}")"
    done
    # Then one [table] per table path, in the order they first appear. The
    # extension chart emits its own [policy_configurations.*] tables below
    # this text; a table name it also emits would be a duplicate, which TOML
    # rejects — the plan checks for that before anything is applied.
    local table current="" current_flag=""
    for flag in $(provider_flags); do
        enabled "${flag}" || continue
        while IFS='|' read -r _ key type req _ _ path; do
            [ -n "${path}" ] || continue
            table="${path%.*}"
            local tkey="${path##*.}" line=""
            if [ "${type}" = "secret" ]; then
                if secret_has_key "${ns}" "${key}"; then
                    line="${tkey} = '{{ env \"$(env_name "${key}")\" }}'"
                    RENDER_ENV="${RENDER_ENV} ${key}"
                else
                    [ "${req}" = "req" ] && RENDER_MISSING="${RENDER_MISSING} ${key}"
                fi
            else
                local value="${!key:-}"
                if [ -n "${value}" ]; then
                    case "${type}" in
                        int)  line="${tkey} = ${value}" ;;
                        list) line="${tkey} = $(toml_list "${value}")" ;;
                        *)    line="${tkey} = $(toml_string "${value}")" ;;
                    esac
                fi
            fi
            [ -n "${line}" ] || continue   # unset optional: the policy default applies
            if [ "${table}" != "${current}" ]; then
                echo
                [ "${flag}" != "${current_flag}" ] && echo "# $(provider_field "${flag}" 2) - $(provider_field "${flag}" 3)"
                echo "[${table}]"
                current="${table}"; current_flag="${flag}"
            fi
            echo "${line}"
        done <<< "$(provider_params "${flag}")"
    done
    [ "${any}" = "1" ] || RENDER_EMPTY=1
}

# Predicts the gateway's config.toml after apply — the new config_toml in place
# of the current one, above everything the charts render — and parses it.
# Catches what would otherwise surface as a crash-looping gateway-runtime: a
# [table] the chart also emits, a root key stranded under a table. Prints the
# parse error; returns 2 when the prediction is impossible (config_toml not
# found at the top of the ConfigMap), so the caller can warn instead.
check_toml() {  # live-config.toml before.toml new.toml
    python3 - "$1" "$2" "$3" <<'PYEOF'
import sys, tomllib
live, before, new = (open(p).read() for p in sys.argv[1:4])
body, head = live.lstrip(), before.strip()
if head:
    if not body.startswith(head):
        sys.exit(2)
    body = body[len(head):]
try:
    tomllib.loads(new + "\n" + body)
except tomllib.TOMLDecodeError as e:
    print(e)
    sys.exit(1)
PYEOF
}

# Builds the Helm values overlay for one extension release as JSON (a valid
# values file): config_toml + systemExtraEnv, both always set, so a provider
# that was disabled is removed rather than left behind.
build_overlay() {  # ns tomlfile → overlay JSON on stdout
    python3 - "$2" "${SECRET_NAME}" "${ENV_PREFIX}" ${RENDER_ENV} <<'PYEOF'
import json, sys
toml_file, secret, prefix, keys = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
toml = open(toml_file).read()
env = [{"name": prefix + k.upper(),
        "valueFrom": {"secretKeyRef": {"name": secret, "key": k}}} for k in keys]
print(json.dumps({"apiGateway": {"config": {"config_toml": toml, "systemExtraEnv": env}}}, indent=2))
PYEOF
}

step "Plan"
APPLY_TMP=$(mktemp -d)
SECRET_TMP="${APPLY_TMP}"   # cleaned up by the EXIT trap; holds no secret values
for flag in $(provider_flags); do
    printf '  %-20s %s\n' "${flag}" "$(enabled "${flag}" && echo "enable  — $(provider_field "${flag}" 3)" || echo "disable")"
done

PLAN_FAIL=0
for i in "${!GW_NS[@]}"; do
    ns="${GW_NS[$i]}"; ext="${GW_EXT_REL[$i]}"
    RENDER_EMPTY=0
    render_for_ns "${ns}" > "${APPLY_TMP}/${ns}.toml"
    if [ "${RENDER_EMPTY}" = "1" ]; then : > "${APPLY_TMP}/${ns}.toml"; fi
    build_overlay "${ns}" "${APPLY_TMP}/${ns}.toml" > "${APPLY_TMP}/${ns}.overlay.json"
    if [ -n "${RENDER_MISSING}" ]; then
        error "${ns}: required secrets missing from ${SECRET_NAME}:${RENDER_MISSING} — run configure"
        PLAN_FAIL=1
    fi
    # Refuse to replace a config_toml this script did not write.
    current=$(helm get values "${ext}" -n "${ns}" -o json | python3 -c 'import sys,json;d=json.load(sys.stdin) or {};print(((d.get("apiGateway") or {}).get("config") or {}).get("config_toml") or "")')
    if [ -n "${current}" ]; then printf '%s\n' "${current}" > "${APPLY_TMP}/${ns}.before.toml"; else : > "${APPLY_TMP}/${ns}.before.toml"; fi
    if [ -n "${current}" ] && [ "$(echo "${current}" | head -1)" != "${TOML_MARKER}" ]; then
        error "${ns}/${ext}: apiGateway.config.config_toml was set by something else — not overwriting it"
        PLAN_FAIL=1
    fi
    info "${ns}/${ext}: config_toml $(wc -l < "${APPLY_TMP}/${ns}.toml" | tr -d ' ') lines, env vars:${RENDER_ENV:- none}"
    kubectl get cm "${GW_NAME[$i]}-gw-gateway-config" -n "${ns}" -o jsonpath='{.data.config\.toml}' \
        > "${APPLY_TMP}/${ns}.live.toml" 2>/dev/null || true
    toml_rc=0
    toml_err=$(check_toml "${APPLY_TMP}/${ns}.live.toml" "${APPLY_TMP}/${ns}.before.toml" "${APPLY_TMP}/${ns}.toml") || toml_rc=$?
    case "${toml_rc}" in
        0) success "${ns}: resulting gateway config.toml parses" ;;
        2) warning "${ns}: could not predict the resulting config.toml — check the gateway pods after apply" ;;
        *) error "${ns}: resulting gateway config.toml would not parse — ${toml_err}"
           PLAN_FAIL=1 ;;
    esac
done

if [ "${DRY_RUN}" = "1" ]; then
    echo
    info "Rendered config_toml for ${GW_NS[0]} (secrets appear only as env tokens):"
    sed 's/^/      /' "${APPLY_TMP}/${GW_NS[0]}.toml"
    echo
    info "Overlay for ${GW_EXT_REL[0]}:"
    sed 's/^/      /' "${APPLY_TMP}/${GW_NS[0]}.overlay.json"
    echo; info "Dry run — nothing changed"
    exit 0
fi
[ "${PLAN_FAIL}" = "0" ] || die "Fix the problems above, then re-run"

audit_reason
if [ "${ASSUME_YES}" != "1" ]; then
    [ -t 0 ] || die "stdin is not a terminal — re-run with --yes to apply without confirmation"
    printf '\n  Apply to context %s? [y/N] ' "$(kubectl config current-context)"
    read -r answer </dev/tty || answer=""
    case "${answer}" in [Yy]*) ;; *) info "Aborted — nothing changed"; exit 0 ;; esac
fi

ROLLBACKS=()

# ── Audit record ─────────────────────────────────────────────────────────────
# From here on the EXIT trap guarantees a record, marked failed if the run does
# not reach the end. config_toml holds no secret values (only env tokens), so
# its diff is safe to record.
audit_begin "guardrails" "${BASH_SOURCE[0]}"
ENABLED_LIST=$(for flag in $(provider_flags); do enabled "${flag}" && printf '%s ' "${flag}"; done; true)
AUDIT_SUMMARY_SO_FAR="guardrails: enabled ${ENABLED_LIST:-none}"
FLAGS_BEFORE=""
for flag in $(flagged_providers); do FLAGS_BEFORE="${FLAGS_BEFORE}${flag}=$(console_flag "$(flag_env "${flag}")") "; done
for i in "${!GW_NS[@]}"; do
    ns="${GW_NS[$i]}"
    python3 - "${APPLY_TMP}/${ns}.before.toml" "${APPLY_TMP}/${ns}.toml" <<'PYEOF' > "${APPLY_TMP}/${ns}.diff"
import difflib, sys
a, b = (open(p).read().splitlines() for p in sys.argv[1:3])
print("\n".join(difflib.unified_diff(a, b, "config_toml (before)", "config_toml (after)", lineterm="")))
PYEOF
    if [ -s "${APPLY_TMP}/${ns}.diff" ] && [ -n "$(tr -d '\n' < "${APPLY_TMP}/${ns}.diff")" ]; then
        audit_text "config_toml ${ns}.diff" < "${APPLY_TMP}/${ns}.diff"
    else
        audit_add notes "${ns}: gateway config_toml unchanged"
    fi
done

# ── 1. Gateways ──────────────────────────────────────────────────────────────
for i in "${!GW_NS[@]}"; do
    ns="${GW_NS[$i]}"; name="${GW_NAME[$i]}"; ext="${GW_EXT_REL[$i]}"; gw="${name}-gw"
    step "${ns}/${name}"

    ext_ver=$(chart_version_of "${ext}" "${ns}")
    ext_rev=$(revision_of "${ext}" "${ns}")
    gw_rev_before=$(revision_of "${gw}" "${ns}")

    # The extension upgrade re-runs its bootstrap hook; on an already-registered
    # gateway that finds the registration present and exits cleanly — the same
    # upgrade amp-install-rancher.sh performs when it registers env-Thunder.
    if ! helm upgrade "${ext}" "oci://${HELM_CHART_REGISTRY}/wso2-amp-api-platform-gateway-extension" \
            --version "${ext_ver}" --namespace "${ns}" --reuse-values \
            -f "${APPLY_TMP}/${ns}.overlay.json" --timeout 600s >/dev/null; then
        error "helm upgrade ${ext} failed — nothing further changed for this gateway"
        continue
    fi
    success "${ext} upgraded (configRef ${GW_CONFIGMAP[$i]})"
    ROLLBACKS+=("helm rollback ${ext} ${ext_rev} -n ${ns}")

    # gateway-operator watches ConfigMaps and redeploys the gateway from its
    # configRef. Give it OPERATOR_WAIT_SECONDS, then do it directly with the
    # same values the operator would have used.
    info "Waiting up to ${OPERATOR_WAIT_SECONDS}s for gateway-operator to redeploy ${gw}..."
    waited=0
    while [ "$(revision_of "${gw}" "${ns}")" = "${gw_rev_before}" ] && [ "${waited}" -lt "${OPERATOR_WAIT_SECONDS}" ]; do
        sleep 5; waited=$((waited+5))
    done
    if [ "$(revision_of "${gw}" "${ns}")" != "${gw_rev_before}" ]; then
        success "gateway-operator redeployed ${gw} (revision $(revision_of "${gw}" "${ns}"))"
        audit_add notes "${ns}/${gw}: redeployed by gateway-operator after ${waited}s"
    else
        warning "gateway-operator did not redeploy ${gw} — upgrading it directly"
        kubectl get cm "${GW_CONFIGMAP[$i]}" -n "${ns}" -o jsonpath='{.data.values\.yaml}' > "${APPLY_TMP}/${ns}.gw-values.yaml"
        if helm upgrade "${gw}" "${GATEWAY_CHART}" --version "$(chart_version_of "${gw}" "${ns}")" \
                --namespace "${ns}" --reuse-values -f "${APPLY_TMP}/${ns}.gw-values.yaml" \
                --wait --timeout 300s >/dev/null; then
            success "${gw} upgraded directly"
            audit_add notes "${ns}/${gw}: gateway-operator did not redeploy within ${OPERATOR_WAIT_SECONDS}s — upgraded directly"
        else
            error "helm upgrade ${gw} failed"
        fi
    fi
    ROLLBACKS+=("helm rollback ${gw} ${gw_rev_before} -n ${ns}")
    audit_change "${ns}/${ext}" "helm revision" "${ext_rev}" "$(revision_of "${ext}" "${ns}")"
    audit_change "${ns}/${gw}" "helm revision" "${gw_rev_before}" "$(revision_of "${gw}" "${ns}")"

    for d in $(kubectl get deploy -n "${ns}" -l "app.kubernetes.io/instance=${gw}" -o name); do
        if kubectl rollout status "${d}" -n "${ns}" --timeout=300s >/dev/null 2>&1; then
            success "${d#deployment.apps/} rolled out"
        else
            # A duplicate [table] in config_toml crash-loops the runtime; say so.
            error "${d#deployment.apps/} did not become ready — kubectl logs -n ${ns} ${d} --tail=50"
        fi
    done

    # Verify what the gateway actually received.
    toml=$(kubectl get cm "${gw}-gateway-config" -n "${ns}" -o jsonpath='{.data.config\.toml}' 2>/dev/null || true)
    if [ -s "${APPLY_TMP}/${ns}.toml" ]; then
        echo "${toml}" | grep -qF "${TOML_MARKER}" \
            && success "settings present in ${gw}-gateway-config" \
            || error "settings missing from ${gw}-gateway-config"
    fi
    for key in $(render_for_ns "${ns}" >/dev/null; echo "${RENDER_ENV}"); do
        var=$(env_name "${key}")
        for d in $(kubectl get deploy -n "${ns}" -l "app.kubernetes.io/instance=${gw}" -o name); do
            kubectl get "${d}" -n "${ns}" -o jsonpath='{.spec.template.spec.containers[*].env[*].name}' \
                | tr ' ' '\n' | grep -qx "${var}" \
                || error "${d#deployment.apps/} has no ${var}"
        done
    done
done

# ── 2. Console flags ─────────────────────────────────────────────────────────
# Every flag is set explicitly, so disabling a provider also hides its
# policies. The console pod restarts on its config checksum.
step "Console flags"
FLAG_SETS=()
for flag in $(flagged_providers); do
    FLAG_SETS+=(--set "console.config.guardrailCapabilities.${flag}=$(enabled "${flag}" && echo true || echo false)")
done
amp_rev=$(revision_of "${AMP_RELEASE}" "${AMP_NS}")
if [ "${ERRORS}" -gt 0 ]; then
    warning "Gateway errors above — leaving the console flags unchanged, so it does not offer policies the gateways cannot run"
    audit_add warnings "Console flags left unchanged because of gateway errors"
elif helm upgrade "${AMP_RELEASE}" "oci://${HELM_CHART_REGISTRY}/wso2-agent-manager" \
        --version "${AMP_CHART_VERSION}" --namespace "${AMP_NS}" --reuse-values \
        "${FLAG_SETS[@]}" --timeout 600s >/dev/null; then
    ROLLBACKS+=("helm rollback ${AMP_RELEASE} ${amp_rev} -n ${AMP_NS}")
    kubectl rollout status deployment/amp-console -n "${AMP_NS}" --timeout=300s >/dev/null 2>&1 \
        && success "amp-console restarted" || warning "amp-console rollout not complete yet"
    for flag in $(flagged_providers); do
        before=$(echo "${FLAGS_BEFORE}" | tr ' ' '\n' | sed -n "s/^${flag}=//p")
        after=$(console_flag "$(flag_env "${flag}")")
        [ "${before}" != "${after}" ] && audit_change "console" "guardrailCapabilities.${flag}" "${before}" "${after}"
    done
    audit_change "${AMP_NS}/${AMP_RELEASE}" "helm revision" "${amp_rev}" "$(revision_of "${AMP_RELEASE}" "${AMP_NS}")"
    for flag in $(flagged_providers); do
        printf '    %-20s %s\n' "${flag}" "$(console_flag "$(flag_env "${flag}")")"
    done
else
    error "helm upgrade ${AMP_RELEASE} failed"
fi

if [ "${#ROLLBACKS[@]}" -gt 0 ]; then
    echo; info "To roll back:"
    for r in "${ROLLBACKS[@]}"; do echo "      ${r}"; audit_add rollback "${r}"; done
fi

echo
if [ "${ERRORS}" -gt 0 ]; then
    audit_commit "failed" "guardrails: enabled ${ENABLED_LIST:-none} — ${ERRORS} problem(s)"
    echo -e "${RED}${BOLD}✗ ${ERRORS} problem(s) — see above${NC}"; exit 1
fi
audit_commit "success" "guardrails: enabled ${ENABLED_LIST:-none}"
echo -e "${GREEN}${BOLD}✓ Guardrail settings applied — reload the console to see the policies${NC}"
