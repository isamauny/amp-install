#!/bin/bash
# ============================================================================
# /etc/hosts entries for a local (offline) WSO2 Agent Manager install
#
#   amp-hosts.sh print            show the block, change nothing
#   amp-hosts.sh add              append/refresh it (needs sudo)
#   amp-hosts.sh remove           delete it (needs sudo)
#   amp-hosts.sh add <project>…   same as add, plus a host per project
#
# Why 127.0.0.1 and not the Rancher Desktop VM IP: Rancher Desktop's ssh port
# forwarder binds every LoadBalancer port on the host, so 127.0.0.1 reaches
# each plane gateway on its own port — and unlike the VM address, it does not
# change when the VM restarts.
#
# Pods resolve these same names through the coredns-custom rewrite the
# installer applies; this file is only for the Mac (browser, curl, amctl).
# ============================================================================
set -euo pipefail

BASE_DOMAIN="${BASE_DOMAIN:-local.apis.coach}"
AGENTS_DOMAIN="agents.${BASE_DOMAIN}"
MARKER_BEGIN="# >>> wso2 agent manager (${BASE_DOMAIN}) >>>"
MARKER_END="# <<< wso2 agent manager (${BASE_DOMAIN}) <<<"
HOSTS_FILE="${HOSTS_FILE:-/etc/hosts}"

ACTION="${1:-print}"
shift || true

build_block() {
    printf '%s\n' "${MARKER_BEGIN}"
    printf '127.0.0.1 %s\n' \
        "console.${BASE_DOMAIN}" \
        "api-amp.${BASE_DOMAIN}" \
        "thunder.${BASE_DOMAIN}" \
        "cp.${BASE_DOMAIN}" \
        "traces.${BASE_DOMAIN}" \
        "default-idp.${BASE_DOMAIN}" \
        "default-default.${AGENTS_DOMAIN}"
    # Agent invoke hostnames are <org>-<project>.<agents-domain>. /etc/hosts
    # cannot wildcard, so each additional project needs its own line.
    for project in "$@"; do
        printf '127.0.0.1 default-%s.%s\n' "${project}" "${AGENTS_DOMAIN}"
    done
    printf '%s\n' "${MARKER_END}"
}

strip_block() {
    sed "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/d" "${HOSTS_FILE}"
}

case "${ACTION}" in
    print)
        build_block "$@"
        ;;
    add)
        TMP="$(mktemp)"
        { strip_block; build_block "$@"; } > "${TMP}"
        sudo cp "${TMP}" "${HOSTS_FILE}"
        rm -f "${TMP}"
        echo "Updated ${HOSTS_FILE} for ${BASE_DOMAIN}"
        ;;
    remove)
        TMP="$(mktemp)"
        strip_block > "${TMP}"
        sudo cp "${TMP}" "${HOSTS_FILE}"
        rm -f "${TMP}"
        echo "Removed ${BASE_DOMAIN} entries from ${HOSTS_FILE}"
        ;;
    *)
        echo "Usage: $0 {print|add|remove} [project ...]" >&2
        exit 1
        ;;
esac
