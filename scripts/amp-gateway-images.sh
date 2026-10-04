#!/bin/bash
# ============================================================================
# amp-gateway-images.sh — swap the API Platform gateway images on a running
# AMP install, without re-running amp-install-rancher.sh.
#
# Adding a policy to the gateway means building a new image, so this is the
# frequent path. Three things have to move together, and the operator moves
# only the first by itself:
#
#   1. gateway-operator's gateway.values.*   — what the operator hands to every
#                                              gateway it creates FROM NOW ON
#   2. each existing <apigateway>-gw release — the operator never re-renders
#                                              these when its values change
#   3. the pods, when the tag is reused      — a rebuild under the same tag
#                                              changes no Helm value, so Helm
#                                              rolls nothing; the pods keep the
#                                              old image until restarted
# ============================================================================
set -euo pipefail

usage() {
    cat <<'HELPEOF'
amp-gateway-images.sh — point the API Platform gateways at new images

USAGE
  ./scripts/amp-gateway-images.sh status             show what is configured and running
  ./scripts/amp-gateway-images.sh apply              roll the target images out
  ./scripts/amp-gateway-images.sh apply --dry-run    show the plan, change nothing
  ./scripts/amp-gateway-images.sh apply --yes        skip the confirmation prompt
  ./scripts/amp-gateway-images.sh apply --reason "CHG-1234: add jev policies"
                                                     why — recorded in the audit trail
  ./scripts/amp-gateway-images.sh --help             this message

  --allow-build-mismatch   roll out a controller and runtime from different
                           builds (refused by default: the controller would
                           advertise policies the runtime cannot run)

TARGET IMAGES (environment)
  GATEWAY_CONTROLLER_IMAGE   GATEWAY_CONTROLLER_TAG
  GATEWAY_RUNTIME_IMAGE      GATEWAY_RUNTIME_TAG

  Any variable left unset keeps the value gateway-operator currently has, so
  rebuilding only the runtime needs only the runtime variables. These are the
  same variables amp-install-rancher.sh reads.

  GATEWAY_POLICIES_PATH      where the controller reads policy definitions.
                             Unset: ./policies when the target controller image
                             has /app/policies (gateway-builder output, which
                             includes the custom policies), else the chart
                             default ./default-policies (upstream set only).

  Prefer a new tag per build (1.2.1-p1, 1.2.1-p2 …): it shows up in every
  image listing and `helm rollback` can return to it. Re-using a tag works —
  the pods are restarted when the local image no longer matches what they run,
  and the outgoing build is preserved under a -prev- tag (see below) — but the
  pod listings and Helm history can no longer tell the builds apart.

LOCAL IMAGES
  Rancher Desktop's Kubernetes runs on the same dockerd as the host `docker`
  CLI, so `docker build` puts the image where the kubelet looks, and the
  installer's IfNotPresent pull policy uses it without a registry. Never use
  :latest — Kubernetes always pulls :latest, and a local-only image cannot be
  pulled.

POLICY DIFF
  The plan compares the policy set of the build each gateway runs with the
  build about to roll out (/app/build-manifest.yaml in the images) and warns
  on removed or downgraded policies — an API still using one breaks.

PRESERVED BUILDS
  A rebuild under the same tag leaves the running build untagged, where
  `docker image prune` would delete it. Before rolling out, the outgoing build
  is tagged <tag>-prev-<image id>, so it stays readable for the diff and can be
  rolled back to. Remove those tags with `docker rmi` once no longer needed.

AUDIT TRAIL
  Every apply writes an immutable record (who, when, why, what changed, how to
  roll back) — read it with ./scripts/amp-audit.sh. AMP_AUDIT_REQUIRE_REASON=1
  makes --reason mandatory.

ROLLBACK
  `apply` prints, and records, the commands that undo it.
HELPEOF
}

ACTION=""
DRY_RUN=0
ASSUME_YES=0
ALLOW_BUILD_MISMATCH=0
AUDIT_REASON="${AMP_AUDIT_REASON:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        status|apply)           ACTION="$1" ;;
        --dry-run)              DRY_RUN=1 ;;
        --yes|-y)               ASSUME_YES=1 ;;
        --allow-build-mismatch) ALLOW_BUILD_MISMATCH=1 ;;
        --reason)               [ $# -ge 2 ] || { echo "--reason needs a value" >&2; exit 1; }
                                AUDIT_REASON="$2"; shift ;;
        -h|--help)              usage; exit 0 ;;
        *)                      echo "Unknown argument: $1" >&2; echo >&2; usage >&2; exit 1 ;;
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

DATA_PLANE_NS="openchoreo-data-plane"
OPERATOR_RELEASE="gateway-operator"
OPERATOR_CHART="oci://ghcr.io/wso2/api-platform/helm-charts/gateway-operator"

# Reads one dotted key out of a JSON document on stdin; empty when absent.
json_get() {
    python3 -c '
import sys, json
d = json.load(sys.stdin) or {}
for k in sys.argv[1].split("."):
    d = d.get(k) if isinstance(d, dict) else None
print("" if d is None else d)' "$1"
}

# The image ID the local dockerd holds for repo:tag, or empty when absent.
local_image_id() {
    command -v docker &>/dev/null || return 0
    docker image inspect --format '{{.Id}}' "$1" 2>/dev/null || true
}

# The sha256 a container status reports, whatever the runtime's prefix
# (docker-pullable://repo@sha256:…, docker://sha256:…, repo@sha256:…).
sha_of() { echo "$1" | grep -oE 'sha256:[0-9a-f]{64}' | head -1; }

# Whether a local image contains a path — read from a created, never-started
# container, so it works on distroless images with no shell or ls.
image_has_path() {
    command -v docker &>/dev/null || return 1
    local cid rc=0
    cid=$(docker create "$1" 2>/dev/null) || return 1
    docker cp "${cid}:$2" - >/dev/null 2>&1 || rc=1
    docker rm "${cid}" >/dev/null 2>&1 || true
    return ${rc}
}

# "<namespace> <name>" per APIGateway.
list_gateways() {
    kubectl get apigateway -A -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' 2>/dev/null
}

# Images a release's pods run, as "<container image> <sha>" lines.
running_images() {
    pod_images "app.kubernetes.io/instance=$2" "$1" | sort -u
}

# "<image> <sha>" of one component (controller | gateway-runtime) of a release.
component_image() {
    pod_images "app.kubernetes.io/instance=$2,app.kubernetes.io/component=$3" "$1" | sort -u | head -1
}

# "<image> <sha>" per running container: the image as written in the pod spec,
# the ID from its status. Not status.image: dockerd reports the first tag on
# the image ID, so two names for one build show whichever was tagged first.
pod_images() {
    kubectl get pods -n "$2" -l "$1" -o json 2>/dev/null | python3 -c '
import json, sys
for pod in json.load(sys.stdin).get("items", []):
    spec = {c["name"]: c["image"] for c in pod["spec"].get("containers", [])}
    for s in pod.get("status", {}).get("containerStatuses") or []:
        if s.get("imageID"):
            print(spec.get(s["name"], s["image"]), s["imageID"])' \
        | while read -r img id; do echo "${img} $(sha_of "${id}")"; done
}

# The policy set of a build — "name version" lines from /app/build-manifest.yaml,
# read by image ref or image ID (an untagged build is still readable by ID).
# Cached per ref; returns 1 when the image or its manifest is not available.
MANIFEST_CACHE=$(mktemp -d)
image_policies() {
    local f="${MANIFEST_CACHE}/$(echo "$1" | tr '/:@' '___')"
    if [ ! -e "${f}" ]; then
        local cid
        command -v docker &>/dev/null || return 1
        cid=$(docker create "$1" 2>/dev/null) || { : > "${f}.missing"; touch "${f}"; return 1; }
        docker cp "${cid}:/app/build-manifest.yaml" - 2>/dev/null | tar -xO 2>/dev/null \
            | python3 -c '
import sys, yaml
try:
    m = yaml.safe_load(sys.stdin) or {}
except Exception:
    sys.exit(1)
for p in m.get("policies") or []:
    print(p.get("name", ""), p.get("version", ""))' 2>/dev/null | sort > "${f}" || true
        docker rm "${cid}" >/dev/null 2>&1 || true
        [ -s "${f}" ] || : > "${f}.missing"
    fi
    [ -e "${f}.missing" ] && return 1
    cat "${f}"
}

# Diff of two policy sets (files of "name version" lines) as JSON:
# {"count", "added", "removed", "changed" (with "downgrade" flags)}.
policy_diff_json() {
    python3 - "$1" "$2" "$3" <<'PYEOF'
import json, re, sys
def load(p):
    return dict(l.split(None, 1) for l in open(p).read().splitlines() if l.strip())
def key(v):
    return [int(x) if x.isdigit() else x for x in re.split(r"[.\-+]", v.lstrip("vV"))]
before, after, target = load(sys.argv[1]), load(sys.argv[2]), sys.argv[3]
changed = []
for n in sorted(set(before) & set(after)):
    if before[n] != after[n]:
        try:
            down = key(after[n]) < key(before[n])
        except TypeError:
            down = after[n] < before[n]
        changed.append({"name": n, "from": before[n], "to": after[n], "downgrade": down})
print(json.dumps({
    "target": target, "count": len(after),
    "added":   [{"name": n, "version": after[n]}  for n in sorted(set(after) - set(before))],
    "removed": [{"name": n, "version": before[n]} for n in sorted(set(before) - set(after))],
    "changed": changed,
}))
PYEOF
}

# Prints a policy diff for the plan and sets DIFF_WARNINGS to the number of
# removed or downgraded policies — the changes that can break a live API.
print_policy_diff() {  # diff-json indent
    local out
    out=$(printf '%s' "$1" | python3 -c '
import json, sys
d, ind = json.load(sys.stdin), sys.argv[1]
w = 0
if not (d["added"] or d["removed"] or d["changed"]):
    print(ind + "policies unchanged (" + str(d["count"]) + ")")
for p in d["added"]:
    print(ind + "+ " + p["name"] + " " + p["version"])
for p in d["changed"]:
    w += p["downgrade"]
    print(ind + "~ " + p["name"] + " " + p["from"] + " -> " + p["to"] + ("   ⚠ downgrade" if p["downgrade"] else ""))
for p in d["removed"]:
    w += 1
    print(ind + "- " + p["name"] + " " + p["version"] + "   ⚠ removed: APIs still using it will fail")
print("#W " + str(w))' "$2")
    printf '%s\n' "${out}" | grep -v '^#W '
    DIFF_WARNINGS=$(printf '%s\n' "${out}" | sed -n 's/^#W //p')
}

trap 'rm -rf "${MANIFEST_CACHE}"; audit_on_exit $?' EXIT

# ── Pre-flight ───────────────────────────────────────────────────────────────
step "Pre-flight checks"
command -v kubectl &>/dev/null || die "kubectl not found"
command -v helm &>/dev/null    || die "helm not found"
command -v python3 &>/dev/null || die "python3 not found"
# Same constraint as the installer: Helm 4's hook lifecycle hangs here.
[ "$(helm version --short 2>/dev/null | sed -E 's/^v([0-9]+)\..*/\1/')" = "3" ] \
    || die "Helm $(helm version --short 2>/dev/null) found — Helm v3 is required (brew install helm@3)"
kubectl cluster-info &>/dev/null || die "Cannot connect to the Kubernetes cluster"
success "kubectl, helm 3 and cluster reachable ($(kubectl config current-context))"

OPERATOR_JSON=$(helm list -n "${DATA_PLANE_NS}" -f "^${OPERATOR_RELEASE}\$" -o json 2>/dev/null || echo "[]")
OPERATOR_CHART_VERSION=$(echo "${OPERATOR_JSON}" | python3 -c 'import sys,json;r=json.load(sys.stdin);print(r[0]["chart"].rsplit("-",1)[1] if r else "")')
[ -n "${OPERATOR_CHART_VERSION}" ] \
    || die "${OPERATOR_RELEASE} is not installed in ${DATA_PLANE_NS} — run amp-install-rancher.sh first"
OPERATOR_REVISION=$(echo "${OPERATOR_JSON}" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["revision"])')
OPERATOR_VALUES=$(helm get values "${OPERATOR_RELEASE}" -n "${DATA_PLANE_NS}" -o json)
success "${OPERATOR_RELEASE} chart ${OPERATOR_CHART_VERSION} (revision ${OPERATOR_REVISION})"

# The chart the operator deploys gateways from. Read from its own config so a
# future operator upgrade that moves it is followed rather than contradicted.
GATEWAY_CHART=$(kubectl get cm gateway-operator-config -n "${DATA_PLANE_NS}" \
    -o jsonpath='{.data.config\.yaml}' 2>/dev/null \
    | sed -nE 's/^ *helm_chart_name: *"?([^"]+)"?.*/\1/p' | head -1)
GATEWAY_CHART="${GATEWAY_CHART:-oci://ghcr.io/wso2/api-platform/helm-charts/gateway}"

CUR_CTRL_IMAGE=$(echo "${OPERATOR_VALUES}" | json_get gateway.values.gateway.controller.image.repository)
CUR_CTRL_TAG=$(echo "${OPERATOR_VALUES}" | json_get gateway.values.gateway.controller.image.tag)
CUR_RT_IMAGE=$(echo "${OPERATOR_VALUES}" | json_get gateway.values.gateway.gatewayRuntime.image.repository)
CUR_RT_TAG=$(echo "${OPERATOR_VALUES}" | json_get gateway.values.gateway.gatewayRuntime.image.tag)

GATEWAY_CONTROLLER_IMAGE="${GATEWAY_CONTROLLER_IMAGE:-${CUR_CTRL_IMAGE}}"
GATEWAY_CONTROLLER_TAG="${GATEWAY_CONTROLLER_TAG:-${CUR_CTRL_TAG}}"
GATEWAY_RUNTIME_IMAGE="${GATEWAY_RUNTIME_IMAGE:-${CUR_RT_IMAGE}}"
GATEWAY_RUNTIME_TAG="${GATEWAY_RUNTIME_TAG:-${CUR_RT_TAG}}"

TARGET_CTRL="${GATEWAY_CONTROLLER_IMAGE}:${GATEWAY_CONTROLLER_TAG}"
TARGET_RT="${GATEWAY_RUNTIME_IMAGE}:${GATEWAY_RUNTIME_TAG}"

# The policy definitions path. The gateway builder writes the full set
# (upstream + custom, at the versions compiled into the runtime) to
# /app/policies and leaves the upstream /app/default-policies in place, while
# the chart points the controller at the latter. Left there, a custom image
# loads, advertises and shows in Agent Manager none of its custom policies —
# with no error anywhere. Derived from the TARGET image rather than kept from
# the operator, so moving back to upstream images moves the path back too.
CHART_DEFAULT_POLICIES_PATH="./default-policies"
CUR_POL_PATH=$(echo "${OPERATOR_VALUES}" | json_get gateway.values.gateway.config.controller.policies.definitions_path)
CUR_POL_PATH="${CUR_POL_PATH:-${CHART_DEFAULT_POLICIES_PATH}}"
POL_PATH_SOURCE="GATEWAY_POLICIES_PATH"
if [ -z "${GATEWAY_POLICIES_PATH:-}" ]; then
    if [ "${ACTION}" = "apply" ] && image_has_path "${TARGET_CTRL}" /app/policies; then
        GATEWAY_POLICIES_PATH="./policies"
        POL_PATH_SOURCE="detected: image has /app/policies"
    else
        GATEWAY_POLICIES_PATH="${CHART_DEFAULT_POLICIES_PATH}"
        POL_PATH_SOURCE="chart default"
    fi
fi

# ── Status (both actions) ────────────────────────────────────────────────────
step "Gateways"
info "Operator configured:  ${CUR_CTRL_IMAGE}:${CUR_CTRL_TAG}"
info "                      ${CUR_RT_IMAGE}:${CUR_RT_TAG}"
info "                      policies ${CUR_POL_PATH}"

GATEWAYS=$(list_gateways)
[ -n "${GATEWAYS}" ] || warning "No APIGateway resources found — only the operator will be updated"

# Per-release state, kept in parallel lists (bash 3.2 has no associative arrays).
GW_NS=(); GW_REL=(); GW_REV=(); GW_CHART_VER=(); GW_VALUES_CHANGE=()
while read -r ns name; do
    [ -z "${ns}" ] && continue
    rel="${name}-gw"
    rel_json=$(helm list -n "${ns}" -f "^${rel}\$" -o json 2>/dev/null || echo "[]")
    chart_ver=$(echo "${rel_json}" | python3 -c 'import sys,json;r=json.load(sys.stdin);print(r[0]["chart"].rsplit("-",1)[1] if r else "")')
    if [ -z "${chart_ver}" ]; then
        warning "${ns}/${name}: no Helm release ${rel} — skipped"
        continue
    fi
    rev=$(echo "${rel_json}" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["revision"])')
    vals=$(helm get values "${rel}" -n "${ns}" -o json)
    rel_ctrl="$(echo "${vals}" | json_get gateway.controller.image.repository):$(echo "${vals}" | json_get gateway.controller.image.tag)"
    rel_rt="$(echo "${vals}" | json_get gateway.gatewayRuntime.image.repository):$(echo "${vals}" | json_get gateway.gatewayRuntime.image.tag)"
    # --all: the path is usually a chart default, absent from user-supplied values.
    rel_pol=$(helm get values "${rel}" -n "${ns}" --all -o json | json_get gateway.config.controller.policies.definitions_path)
    rel_pol="${rel_pol:-${CHART_DEFAULT_POLICIES_PATH}}"

    echo -e "\n  ${BOLD}${ns}/${name}${NC}  release ${rel}, chart ${chart_ver}, revision ${rev}"
    echo "    release values:  ${rel_ctrl}"
    echo "                     ${rel_rt}"
    echo "                     policies ${rel_pol}"
    running_images "${ns}" "${rel}" | while read -r img sha; do
        echo "    running:         ${img}  ${sha:0:19}"
    done

    GW_NS+=("${ns}"); GW_REL+=("${rel}"); GW_REV+=("${rev}"); GW_CHART_VER+=("${chart_ver}")
    if [ "${rel_ctrl}" = "${TARGET_CTRL}" ] && [ "${rel_rt}" = "${TARGET_RT}" ] \
            && [ "${rel_pol}" = "${GATEWAY_POLICIES_PATH}" ]; then
        GW_VALUES_CHANGE+=("0")
    else
        GW_VALUES_CHANGE+=("1")
    fi
done <<< "${GATEWAYS}"

[ "${ACTION}" = "status" ] && exit 0

# ── Plan ─────────────────────────────────────────────────────────────────────
step "Plan"
info "Target controller:  ${TARGET_CTRL}"
info "Target runtime:     ${TARGET_RT}"
info "Policies path:      ${GATEWAY_POLICIES_PATH} (${POL_PATH_SOURCE})"

for t in GATEWAY_CONTROLLER_TAG GATEWAY_RUNTIME_TAG; do
    [ "${!t}" = "latest" ] && die "${t}=latest — Kubernetes always pulls :latest, so a local image would never be used. Use a real tag."
done

# A local-only image must already be in the node's store: with nothing to pull
# from, a missing image is an ImagePullBackOff on a gateway that was working.
CTRL_LOCAL_ID=$(local_image_id "${TARGET_CTRL}")
RT_LOCAL_ID=$(local_image_id "${TARGET_RT}")
for pair in "${TARGET_CTRL}|${CTRL_LOCAL_ID}" "${TARGET_RT}|${RT_LOCAL_ID}"; do
    img="${pair%%|*}"; id="${pair#*|}"
    if [ -n "${id}" ]; then
        success "${img} is in the local image store (${id:0:19})"
    elif [[ "${img}" == localhost/* ]]; then
        die "${img} is not in the local image store and cannot be pulled — build it first (docker context: $(docker context show 2>/dev/null || echo unknown))"
    else
        warning "${img} is not local — the node will pull it from its registry"
    fi
done

# The controller advertises policies, the runtime executes them. A pair that
# disagrees makes the console offer policies the runtime cannot run — refuse
# it unless overridden.
#
# The controller's /app/build-manifest.yaml is the policy list it advertises.
# The runtime's copy is NOT evidence of anything: it is the base image's file,
# left unchanged by the build (identical in upstream gateway-runtime:1.2.1 and
# in custom builds). What the runtime can run is what was compiled into it:
# the Go module list embedded in /app/policy-engine, and the Python policy
# packages installed under /app/python-libs (<name>_v<major>-<version>.dist-info).
runtime_mismatches() {  # controller-image runtime-image → one line per problem; 3 = cannot check
    local cid tmp="${MANIFEST_CACHE}/rt-$$"
    command -v docker &>/dev/null || return 3
    mkdir -p "${tmp}"
    cid=$(docker create "$1" 2>/dev/null) || return 3
    docker cp "${cid}:/app/build-manifest.yaml" - 2>/dev/null | tar -xO > "${tmp}/manifest.yaml" 2>/dev/null || true
    docker rm "${cid}" >/dev/null 2>&1 || true
    cid=$(docker create "$2" 2>/dev/null) || return 3
    docker cp "${cid}:/app/policy-engine" - 2>/dev/null | tar -xO > "${tmp}/policy-engine" 2>/dev/null || true
    docker cp "${cid}:/app/python-libs" - 2>/dev/null | tar -t 2>/dev/null > "${tmp}/python-libs" || true
    docker rm "${cid}" >/dev/null 2>&1 || true
    python3 - "${tmp}/manifest.yaml" "${tmp}/policy-engine" "${tmp}/python-libs" <<'PYEOF'
import re, sys, yaml
try:
    policies = (yaml.safe_load(open(sys.argv[1])) or {}).get("policies") or []
    binary = open(sys.argv[2], "rb").read()
except Exception:
    sys.exit(3)
if not policies or not binary:
    sys.exit(3)
# Go build info: "dep\t<module>\t<version>", followed by "=>\t…" when replaced.
go = {}
for kind, path, ver in re.findall(rb"\n(dep|=>)\t([^\t\n]+)\t([^\t\n]+)", binary):
    if kind == b"dep":
        last = path.decode(); go[last] = ver.decode()
    else:
        go[last] = "replaced"
py = {}
for line in open(sys.argv[3]):
    m = re.match(r"(?:python-libs/)?([^/]+)_v\d+-(\d[^/]*)\.dist-info/$", line.strip())
    if m:
        py[m.group(1)] = "v" + m.group(2)
problems = 0
for p in policies:
    name, ver = p.get("name", ""), p.get("version", "")
    if p.get("gomodule"):
        have = go.get(p["gomodule"].split("@")[0])
    elif p.get("pipPackage"):
        have = py.get(name.replace("-", "_"))
    else:
        continue
    if have == "replaced":
        print(f"#N {name}: built from a local replace — version not verifiable")
    elif have != ver:
        print(f"{name} {ver}: runtime has {have or 'nothing'}")
        problems += 1
print(f"#C {len(policies)}")
sys.exit(1 if problems else 0)
PYEOF
}

PLAN_TMP="${MANIFEST_CACHE}/plan"; mkdir -p "${PLAN_TMP}"
PLAN_WARNINGS=()
# The target controller's policy list, for the per-gateway policy diff below.
image_policies "${TARGET_CTRL}" > "${PLAN_TMP}/target-ctrl" 2>/dev/null || : > "${PLAN_TMP}/target-ctrl"
ctrl_ts=$(docker image inspect --format '{{ index .Config.Labels "build.timestamp" }}' "${TARGET_CTRL}" 2>/dev/null || true)
rt_ts=$(docker image inspect --format '{{ index .Config.Labels "build.timestamp" }}' "${TARGET_RT}" 2>/dev/null || true)
check_rc=0
check_out=$(runtime_mismatches "${TARGET_CTRL}" "${TARGET_RT}") || check_rc=$?
if [ "${check_rc}" = "3" ]; then
    info "Controller manifest or runtime binary not readable — controller/runtime consistency not checked"
else
    echo "${check_out}" | sed -n 's/^#N /  ℹ /p'
    mismatch=""
    [ "${check_rc}" = "0" ] || mismatch="$(echo "${check_out}" | grep -vc '^#') policies differ: $(echo "${check_out}" | grep -v '^#' | head -5 | tr '\n' ';' | sed 's/;$//; s/;/; /g')"
    # A differing timestamp alone is a warning: the content check above is
    # what matters, and a builder may stamp each image separately.
    if [ -n "${ctrl_ts}" ] && [ -n "${rt_ts}" ] && [ "${ctrl_ts}" != "${rt_ts}" ]; then
        warning "build.timestamp differs (${ctrl_ts} vs ${rt_ts}) — not the same builder run"
        PLAN_WARNINGS+=("Controller and runtime build.timestamp differ (${ctrl_ts} vs ${rt_ts})")
    fi
    if [ -z "${mismatch}" ]; then
        success "Runtime has every policy the controller advertises, same versions ($(echo "${check_out}" | sed -n 's/^#C //p') policies${ctrl_ts:+, built ${ctrl_ts}})"
    elif [ "${ALLOW_BUILD_MISMATCH}" = "1" ]; then
        warning "Controller and runtime disagree (${mismatch}) — allowed by --allow-build-mismatch"
        PLAN_WARNINGS+=("Controller and runtime disagree (${mismatch}); rolled out with --allow-build-mismatch")
    else
        die "Controller and runtime disagree (${mismatch}) — the console would offer policies the runtime cannot run. Rebuild both, or pass --allow-build-mismatch"
    fi
fi

OPERATOR_CHANGE=0
[ "${CUR_CTRL_IMAGE}:${CUR_CTRL_TAG}" != "${TARGET_CTRL}" ] && OPERATOR_CHANGE=1
[ "${CUR_RT_IMAGE}:${CUR_RT_TAG}" != "${TARGET_RT}" ] && OPERATOR_CHANGE=1
[ "${CUR_POL_PATH}" != "${GATEWAY_POLICIES_PATH}" ] && OPERATOR_CHANGE=1
if [ "${OPERATOR_CHANGE}" = "1" ]; then
    info "${OPERATOR_RELEASE}: helm upgrade (values change; its pod restarts on the values checksum)"
else
    info "${OPERATOR_RELEASE}: already configured with the target images and path — unchanged"
fi

# What each gateway needs: a values upgrade, a restart onto a rebuilt tag, or
# nothing. The rebuilt-tag case compares the image ID the pod started from
# with the ID the local store now holds for the same tag.
GW_ACTION=()
GW_OUT_CTRL=(); GW_OUT_RT=()   # outgoing "<image> <sha>" per gateway, for backups and the record
for i in ${GW_REL[@]+"${!GW_REL[@]}"}; do
    ns="${GW_NS[$i]}"; rel="${GW_REL[$i]}"
    out_ctrl=$(component_image "${ns}" "${rel}" controller)
    out_rt=$(component_image "${ns}" "${rel}" gateway-runtime)
    GW_OUT_CTRL+=("${out_ctrl}"); GW_OUT_RT+=("${out_rt}")

    # Policy diff: the build the controller runs now (read by image ID, so it
    # works for an untagged build too) against the target controller build.
    out_sha="${out_ctrl#* }"
    if [ -s "${PLAN_TMP}/target-ctrl" ] && [ -n "${out_sha}" ] \
            && image_policies "${out_sha}" > "${PLAN_TMP}/running-${i}" 2>/dev/null; then
        policy_diff_json "${PLAN_TMP}/running-${i}" "${PLAN_TMP}/target-ctrl" "${ns}/${rel}" \
            > "${PLAN_TMP}/diff-${i}.json"
        if [ "${out_sha}" != "${CTRL_LOCAL_ID}" ]; then
            info "${ns}/${rel}: policies, running build → target build:"
            print_policy_diff "$(cat "${PLAN_TMP}/diff-${i}.json")" "        "
            if [ "${DIFF_WARNINGS:-0}" -gt 0 ]; then
                PLAN_WARNINGS+=("${ns}/${rel}: ${DIFF_WARNINGS} policy removal(s)/downgrade(s) — see the policy diff")
            fi
        fi
    elif [ -n "${out_sha}" ] && [ "${out_sha}" != "${CTRL_LOCAL_ID}" ]; then
        info "${ns}/${rel}: policy diff unavailable — the running build ${out_sha:7:12} is not in the local image store or has no build manifest"
    fi

    if [ "${GW_VALUES_CHANGE[$i]}" = "1" ]; then
        GW_ACTION+=("upgrade")
        info "${ns}/${rel}: helm upgrade to the target images and path"
        continue
    fi
    stale=""
    while read -r img sha; do
        [ -z "${img}" ] && continue
        want=""
        [ "${img}" = "${TARGET_CTRL}" ] && want="${CTRL_LOCAL_ID}"
        [ "${img}" = "${TARGET_RT}" ] && want="${RT_LOCAL_ID}"
        [ -n "${want}" ] && [ -n "${sha}" ] && [ "${sha}" != "${want}" ] && stale="${stale} ${img##*/}"
    done <<< "$(running_images "${ns}" "${rel}")"
    if [ -n "${stale}" ]; then
        GW_ACTION+=("restart")
        info "${ns}/${rel}: same tag, rebuilt image —${stale} — rollout restart"
    else
        GW_ACTION+=("none")
        info "${ns}/${rel}: already running the target images — unchanged"
    fi
done

NOTHING_TO_DO=1
[ "${OPERATOR_CHANGE}" = "1" ] && NOTHING_TO_DO=0
for a in ${GW_ACTION[@]+"${GW_ACTION[@]}"}; do [ "${a}" != "none" ] && NOTHING_TO_DO=0; done
if [ "${NOTHING_TO_DO}" = "1" ]; then
    echo; success "Everything already runs the target images — nothing to do"; exit 0
fi
for w in ${PLAN_WARNINGS[@]+"${PLAN_WARNINGS[@]}"}; do warning "${w}"; done
[ "${DRY_RUN}" = "1" ] && { echo; info "Dry run — nothing changed"; exit 0; }

audit_reason
if [ "${ASSUME_YES}" != "1" ]; then
    [ -t 0 ] || die "stdin is not a terminal — re-run with --yes to apply without confirmation"
    printf '\n  Apply to context %s? [y/N] ' "$(kubectl config current-context)"
    read -r answer </dev/tty || answer=""
    case "${answer}" in [Yy]*) ;; *) info "Aborted — nothing changed"; exit 0 ;; esac
fi

# ── Audit record ─────────────────────────────────────────────────────────────
# Started only now that the change is confirmed. From here on the EXIT trap
# guarantees a record, marked failed if the run does not reach the end.
audit_begin "gateway-images" "${BASH_SOURCE[0]}"
AUDIT_SUMMARY_SO_FAR="gateways → ${TARGET_CTRL##*/} + ${TARGET_RT##*/}"
for w in ${PLAN_WARNINGS[@]+"${PLAN_WARNINGS[@]}"}; do audit_add warnings "${w}"; done
for i in ${GW_REL[@]+"${!GW_REL[@]}"}; do
    [ -s "${PLAN_TMP}/diff-${i}.json" ] && audit_json policies < "${PLAN_TMP}/diff-${i}.json"
done

# ── Preserve outgoing builds ─────────────────────────────────────────────────
# After a same-tag rebuild the running build has no tag left, so a prune would
# delete it — and with it the only way back. Tag it <tag>-prev-<id> first.
# A build that still has a tag (new-tag rollouts) needs nothing.
ROLLBACK_CTRL=""; ROLLBACK_RT=""
for i in ${GW_REL[@]+"${!GW_REL[@]}"}; do
    for comp in ctrl rt; do
        if [ "${comp}" = "ctrl" ]; then out="${GW_OUT_CTRL[$i]}"; want="${CTRL_LOCAL_ID}"
        else                             out="${GW_OUT_RT[$i]}";   want="${RT_LOCAL_ID}"; fi
        img="${out% *}"; sha="${out#* }"
        [ -n "${out}" ] && [ -n "${sha}" ] || continue
        restore="${img}"
        if [ "${sha}" != "${want}" ]; then
            ntags=$(docker image inspect --format '{{len .RepoTags}}' "${sha}" 2>/dev/null || echo "missing")
            if [ "${ntags}" = "missing" ]; then
                warning "Outgoing build ${img} (${sha:7:12}) is not in the local image store — it cannot be preserved"
                audit_add warnings "Outgoing build ${img} (${sha}) was not in the local image store and could not be preserved"
            elif [ "${ntags}" = "0" ]; then
                backup="${img%:*}:${img##*:}-prev-${sha:7:12}"
                docker tag "${sha}" "${backup}"
                success "Preserved outgoing build as ${backup}"
                audit_add backups "${backup} = ${sha}"
                restore="${backup}"
            fi
        fi
        if [ "${comp}" = "ctrl" ]; then ROLLBACK_CTRL="${ROLLBACK_CTRL:-${restore}}"
        else                             ROLLBACK_RT="${ROLLBACK_RT:-${restore}}"; fi
    done
done

IMAGE_SETS_OPERATOR=(
    --set gateway.values.gateway.controller.image.repository="${GATEWAY_CONTROLLER_IMAGE}"
    --set-string gateway.values.gateway.controller.image.tag="${GATEWAY_CONTROLLER_TAG}"
    --set gateway.values.gateway.gatewayRuntime.image.repository="${GATEWAY_RUNTIME_IMAGE}"
    --set-string gateway.values.gateway.gatewayRuntime.image.tag="${GATEWAY_RUNTIME_TAG}"
    --set gateway.values.gateway.config.controller.policies.definitions_path="${GATEWAY_POLICIES_PATH}"
)
# The per-gateway chart takes the same keys without the operator's
# gateway.values. passthrough prefix.
IMAGE_SETS_GATEWAY=(
    --set gateway.controller.image.repository="${GATEWAY_CONTROLLER_IMAGE}"
    --set-string gateway.controller.image.tag="${GATEWAY_CONTROLLER_TAG}"
    --set gateway.gatewayRuntime.image.repository="${GATEWAY_RUNTIME_IMAGE}"
    --set-string gateway.gatewayRuntime.image.tag="${GATEWAY_RUNTIME_TAG}"
    --set gateway.config.controller.policies.definitions_path="${GATEWAY_POLICIES_PATH}"
)
ROLLBACKS=()

# ── 1. Operator ──────────────────────────────────────────────────────────────
# First, so that a gateway created while this runs already gets the new images.
# --version is the installed chart version: this script changes images, never
# the operator itself. --reuse-values keeps everything the installer set
# (chart version pin, encryption key, pull policies).
step "gateway-operator"
if [ "${OPERATOR_CHANGE}" = "1" ]; then
    helm upgrade "${OPERATOR_RELEASE}" "${OPERATOR_CHART}" \
        --version "${OPERATOR_CHART_VERSION}" \
        --namespace "${DATA_PLANE_NS}" \
        --reuse-values \
        "${IMAGE_SETS_OPERATOR[@]}" \
        --wait --timeout 300s >/dev/null
    success "${OPERATOR_RELEASE} upgraded"
    ROLLBACKS+=("helm rollback ${OPERATOR_RELEASE} ${OPERATOR_REVISION} -n ${DATA_PLANE_NS}")
    [ "${CUR_CTRL_IMAGE}:${CUR_CTRL_TAG}" != "${TARGET_CTRL}" ] \
        && audit_change "${OPERATOR_RELEASE}" "controller image" "${CUR_CTRL_IMAGE}:${CUR_CTRL_TAG}" "${TARGET_CTRL}"
    [ "${CUR_RT_IMAGE}:${CUR_RT_TAG}" != "${TARGET_RT}" ] \
        && audit_change "${OPERATOR_RELEASE}" "runtime image" "${CUR_RT_IMAGE}:${CUR_RT_TAG}" "${TARGET_RT}"
    [ "${CUR_POL_PATH}" != "${GATEWAY_POLICIES_PATH}" ] \
        && audit_change "${OPERATOR_RELEASE}" "policies path" "${CUR_POL_PATH}" "${GATEWAY_POLICIES_PATH}"
    audit_change "${OPERATOR_RELEASE}" "helm revision" "${OPERATOR_REVISION}" \
        "$(helm history "${OPERATOR_RELEASE}" -n "${DATA_PLANE_NS}" --max 1 -o json | python3 -c 'import sys,json;print(json.load(sys.stdin)[-1]["revision"])')"
else
    info "unchanged"
fi

# ── 2. Each gateway ──────────────────────────────────────────────────────────
# --version is the release's own chart version, not the operator's current
# pin, so an image swap never doubles as an unreviewed chart upgrade.
for i in ${GW_REL[@]+"${!GW_REL[@]}"}; do
    ns="${GW_NS[$i]}"; rel="${GW_REL[$i]}"
    step "${ns}/${rel}"
    out_ctrl="${GW_OUT_CTRL[$i]}"; out_rt="${GW_OUT_RT[$i]}"
    case "${GW_ACTION[$i]}" in
        upgrade)
            if helm upgrade "${rel}" "${GATEWAY_CHART}" \
                    --version "${GW_CHART_VER[$i]}" \
                    --namespace "${ns}" \
                    --reuse-values \
                    "${IMAGE_SETS_GATEWAY[@]}" \
                    --wait --timeout 300s >/dev/null; then
                success "upgraded"
                ROLLBACKS+=("helm rollback ${rel} ${GW_REV[$i]} -n ${ns}")
                audit_change "${ns}/${rel}" "controller" "${out_ctrl% *} @${out_ctrl#* }" "${TARGET_CTRL} @${CTRL_LOCAL_ID}"
                audit_change "${ns}/${rel}" "runtime" "${out_rt% *} @${out_rt#* }" "${TARGET_RT} @${RT_LOCAL_ID}"
                audit_change "${ns}/${rel}" "helm revision" "${GW_REV[$i]}" \
                    "$(helm history "${rel}" -n "${ns}" --max 1 -o json | python3 -c 'import sys,json;print(json.load(sys.stdin)[-1]["revision"])')"
            else
                error "helm upgrade failed — kubectl get pods -n ${ns} -l app.kubernetes.io/instance=${rel}"
            fi
            ;;
        restart)
            kubectl rollout restart deployment -n "${ns}" -l "app.kubernetes.io/instance=${rel}" >/dev/null
            [ "${out_ctrl#* }" != "${CTRL_LOCAL_ID}" ] \
                && audit_change "${ns}/${rel}" "controller build (same tag, restarted)" "${out_ctrl% *} @${out_ctrl#* }" "${TARGET_CTRL} @${CTRL_LOCAL_ID}"
            [ "${out_rt#* }" != "${RT_LOCAL_ID}" ] \
                && audit_change "${ns}/${rel}" "runtime build (same tag, restarted)" "${out_rt% *} @${out_rt#* }" "${TARGET_RT} @${RT_LOCAL_ID}"
            for d in $(kubectl get deploy -n "${ns}" -l "app.kubernetes.io/instance=${rel}" -o name); do
                kubectl rollout status "${d}" -n "${ns}" --timeout=300s >/dev/null \
                    && success "${d#deployment.apps/} restarted" \
                    || error "${d#deployment.apps/} did not finish rolling out"
            done
            ;;
        none)
            info "unchanged"
            ;;
    esac
done

# ── 3. Verify ────────────────────────────────────────────────────────────────
# Matched on the image string AND, for local images, on the image ID — a pod
# still on an older build of the same tag passes the first check alone.
step "Verify"
for i in ${GW_REL[@]+"${!GW_REL[@]}"}; do
    ns="${GW_NS[$i]}"; rel="${GW_REL[$i]}"
    running=$(running_images "${ns}" "${rel}")
    for pair in "${TARGET_CTRL}|${CTRL_LOCAL_ID}" "${TARGET_RT}|${RT_LOCAL_ID}"; do
        img="${pair%%|*}"; id="${pair#*|}"
        line=$(echo "${running}" | awk -v i="${img}" '$1==i' | head -1)
        if [ -z "${line}" ]; then
            error "${ns}/${rel}: ${img} is not running"
        elif [ -n "${id}" ] && [ "$(echo "${line}" | awk '{print $2}')" != "${id}" ]; then
            error "${ns}/${rel}: ${img} is running an older build of that tag"
        else
            success "${ns}/${rel}: ${img}"
        fi
    done
    # What the controller actually loaded and reported to Agent Manager — the
    # only place a wrong policies path shows up. Its manifest push happens on
    # connect, so a controller that did not restart still shows its old counts.
    ctrl_log=$(kubectl logs -n "${ns}" -l "app.kubernetes.io/instance=${rel},app.kubernetes.io/component=controller" \
        --tail=3000 2>/dev/null || true)
    loaded=$(echo "${ctrl_log}" | grep 'Policy definitions loaded' | tail -1 | grep -oE '"count":[0-9]+' | cut -d: -f2)
    pushed=$(echo "${ctrl_log}" | grep 'Successfully pushed gateway manifest' | tail -1 | grep -oE '"policy_count":[0-9]+' | cut -d: -f2)
    if [ -n "${loaded}" ]; then
        info "${ns}/${rel}: controller loaded ${loaded} policy definitions from ${GATEWAY_POLICIES_PATH}, pushed ${pushed:-?} to Agent Manager"
        audit_add notes "${ns}/${rel}: controller loaded ${loaded} policy definitions from ${GATEWAY_POLICIES_PATH}, pushed ${pushed:-?} to Agent Manager"
    else
        warning "${ns}/${rel}: no 'Policy definitions loaded' line in the controller log yet"
    fi
done

# The operator flips an APIGateway's Programmed condition, not the pods, so a
# gateway can run the right images and still not be serving.
while read -r ns name; do
    [ -z "${ns}" ] && continue
    st=$(kubectl get apigateway "${name}" -n "${ns}" \
        -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "")
    [ "${st}" = "True" ] && success "${ns}/${name}: Programmed" \
        || warning "${ns}/${name}: Programmed=${st:-unknown}"
    audit_add notes "${ns}/${name}: Programmed=${st:-unknown}"
done <<< "${GATEWAYS}"

# The script-level rollback re-applies the outgoing builds (by their -prev-
# tag when one was made), which keeps operator and gateways consistent —
# preferable to per-release helm rollbacks, listed as the fallback.
if [ -n "${ROLLBACK_CTRL}" ] && [ -n "${ROLLBACK_RT}" ]; then
    ROLLBACKS=("GATEWAY_CONTROLLER_IMAGE=${ROLLBACK_CTRL%:*} GATEWAY_CONTROLLER_TAG=${ROLLBACK_CTRL##*:} GATEWAY_RUNTIME_IMAGE=${ROLLBACK_RT%:*} GATEWAY_RUNTIME_TAG=${ROLLBACK_RT##*:} GATEWAY_POLICIES_PATH=${CUR_POL_PATH} ./scripts/amp-gateway-images.sh apply --reason \"rollback\"" ${ROLLBACKS[@]+"${ROLLBACKS[@]}"})
fi
if [ "${#ROLLBACKS[@]}" -gt 0 ]; then
    echo; info "To roll back:"
    for r in "${ROLLBACKS[@]}"; do echo "      ${r}"; audit_add rollback "${r}"; done
fi

SUMMARY="gateways → ${TARGET_CTRL##*/} + ${TARGET_RT##*/}"
if [ -s "${PLAN_TMP}/diff-0.json" ]; then
    SUMMARY="${SUMMARY} ($(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print("policies +%d ~%d -%d, %d total" % (len(d["added"]),len(d["changed"]),len(d["removed"]),d["count"]))' "${PLAN_TMP}/diff-0.json"))"
fi
for a in ${GW_ACTION[@]+"${GW_ACTION[@]}"}; do
    [ "${a}" = "restart" ] && { SUMMARY="${SUMMARY}, same-tag rebuild"; break; }
done
echo
if [ "${ERRORS}" -gt 0 ]; then
    audit_commit "failed" "${SUMMARY} — ${ERRORS} problem(s)"
    echo -e "${RED}${BOLD}✗ ${ERRORS} problem(s) — see above${NC}"; exit 1
fi
audit_commit "success" "${SUMMARY}"
echo -e "${GREEN}${BOLD}✓ Gateways running ${TARGET_CTRL##*/} and ${TARGET_RT##*/}${NC}"
