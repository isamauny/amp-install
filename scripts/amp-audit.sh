#!/bin/bash
# ============================================================================
# amp-audit.sh — audit trail of the changes the amp-* maintenance scripts make
# to a running install (gateway images, guardrail settings, …).
#
# Two roles:
#   * SOURCED by amp-gateway-images.sh and amp-guardrails.sh, it provides the
#     audit_* functions they record with.
#   * EXECUTED, it reads the trail back: list, show, export.
#
# Each change is one record, stored as an IMMUTABLE ConfigMap in the
# ${AMP_AUDIT_NS:-amp-audit} namespace: who ran it (OS user, git identity,
# kube context), why (--reason, e.g. a ticket), with what (script, its
# sha256 and the repo commit), what changed (before → after), the Helm
# revisions to roll back to, and the outcome. A run that dies part-way still
# writes its record, marked failed, from the EXIT trap.
#
# Immutable means a record cannot be edited, only deleted — this is a
# documentation trail, not tamper-proof evidence. Where that matters, ship
# the records off the cluster (`export --format json`) to your log store.
#
# Secrets are never recorded: only the names of the keys that changed.
# If the cluster write fails, the record is kept under ~/.amp-audit/ so the
# change is never undocumented.
# ============================================================================

AUDIT_NS="${AMP_AUDIT_NS:-amp-audit}"
AUDIT_PART_OF="amp-audit"
AUDIT_FALLBACK_DIR="${AMP_AUDIT_FALLBACK_DIR:-${HOME}/.amp-audit}"

# ── Library ──────────────────────────────────────────────────────────────────
# The calling script's info/success/warning are used when present.
_audit_say()  { if declare -F success >/dev/null; then success "$1"; else echo "  ✓ $1"; fi; }
_audit_warn() { if declare -F warning >/dev/null; then warning "$1"; else echo "  ⚠ $1" >&2; fi; }

# audit_begin <slug> <script-path> — start collecting a record. Call it only
# once the change is confirmed and about to happen; dry runs record nothing.
# AUDIT_STARTED_AT_OVERRIDE / AUDIT_FINISHED_AT_OVERRIDE / AUDIT_TOOLING_LABEL
# exist for backfilling changes made outside these scripts.
audit_begin() {
    AUDIT_SLUG="$1"
    AUDIT_SCRIPT="$2"
    AUDIT_STARTED_AT="${AUDIT_STARTED_AT_OVERRIDE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    AUDIT_DIR=$(mktemp -d)
    AUDIT_ACTIVE=1
    AUDIT_COMMITTED=0
}

# audit_reason — make sure AUDIT_REASON is set: from --reason / AMP_AUDIT_REASON,
# else asked for on a terminal. AMP_AUDIT_REQUIRE_REASON=1 makes it mandatory,
# which is what a controlled environment wants.
audit_reason() {
    AUDIT_REASON="${AUDIT_REASON:-${AMP_AUDIT_REASON:-}}"
    if [ -z "${AUDIT_REASON}" ] && [ -t 0 ]; then
        printf '\n  Reason for this change (ticket, notes — recorded in the audit trail): '
        IFS= read -r AUDIT_REASON </dev/tty || AUDIT_REASON=""
    fi
    if [ -z "${AUDIT_REASON}" ] && [ "${AMP_AUDIT_REQUIRE_REASON:-0}" = "1" ]; then
        echo "  ✗ AMP_AUDIT_REQUIRE_REASON=1 — pass --reason \"…\"" >&2
        exit 1
    fi
    return 0
}

# audit_change <target> <what> <before> <after> — one row of the change table.
audit_change() {
    [ "${AUDIT_ACTIVE:-0}" = "1" ] || return 0
    python3 -c 'import json,sys;print(json.dumps(dict(zip(("target","what","before","after"),sys.argv[1:5]))))' \
        "$1" "$2" "$3" "$4" >> "${AUDIT_DIR}/changes.jsonl"
}

# audit_add <list> <value> — append to a named list (backups, rollback, notes, warnings).
audit_add() {
    [ "${AUDIT_ACTIVE:-0}" = "1" ] || return 0
    printf '%s\n' "$2" >> "${AUDIT_DIR}/list-$1.txt"
}

# audit_json <name> — store a JSON document from stdin under details.<name>.
# Lists of objects (e.g. per-gateway policy diffs) append: one JSON per call.
audit_json() {
    [ "${AUDIT_ACTIVE:-0}" = "1" ] || { cat >/dev/null; return 0; }
    { cat; echo; } >> "${AUDIT_DIR}/json-$1.jsonl"
}

# audit_text <name> — store free text from stdin (e.g. a config diff).
audit_text() {
    [ "${AUDIT_ACTIVE:-0}" = "1" ] || { cat >/dev/null; return 0; }
    cat > "${AUDIT_DIR}/text-$1.txt"
}

# audit_commit <outcome> <summary> — write the record. Safe to call twice and
# from an EXIT trap; never changes the caller's exit status.
audit_commit() {
    [ "${AUDIT_ACTIVE:-0}" = "1" ] || return 0
    [ "${AUDIT_COMMITTED:-0}" = "1" ] && return 0
    AUDIT_COMMITTED=1
    local outcome="$1" summary="$2"
    local rand id repo_dir
    rand=$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')
    # The id carries the start time, so `list` and kubectl both sort by it.
    id="amp-audit-$(echo "${AUDIT_STARTED_AT}" | tr -d ':-' | sed -E 's/^([0-9]{8})T([0-9]{6})Z$/\1-\2/')-${AUDIT_SLUG}-${rand}"
    repo_dir="$(cd "$(dirname "${AUDIT_SCRIPT}")/.." 2>/dev/null && pwd)"

    AUDIT_ID="${id}" AUDIT_OUTCOME="${outcome}" AUDIT_SUMMARY="${summary}" \
    AUDIT_FINISHED_AT="${AUDIT_FINISHED_AT_OVERRIDE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" \
    AUDIT_STARTED_AT="${AUDIT_STARTED_AT}" AUDIT_SLUG="${AUDIT_SLUG}" \
    AUDIT_REASON="${AUDIT_REASON:-}" AUDIT_NS="${AUDIT_NS}" AUDIT_PART_OF="${AUDIT_PART_OF}" \
    AUDIT_ACTOR_USER="${USER:-$(id -un)}" AUDIT_ACTOR_HOST="$(hostname -s 2>/dev/null || hostname)" \
    AUDIT_GIT_NAME="$(git -C "${repo_dir}" config user.name 2>/dev/null || true)" \
    AUDIT_GIT_EMAIL="$(git -C "${repo_dir}" config user.email 2>/dev/null || true)" \
    AUDIT_CONTEXT="$(kubectl config current-context 2>/dev/null || true)" \
    AUDIT_SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)" \
    AUDIT_SCRIPT_NAME="${AUDIT_TOOLING_LABEL:-$(basename "${AUDIT_SCRIPT}")}" \
    AUDIT_SCRIPT_SHA="$([ -n "${AUDIT_TOOLING_LABEL:-}" ] || shasum -a 256 "${AUDIT_SCRIPT}" 2>/dev/null | cut -d' ' -f1)" \
    AUDIT_REPO_COMMIT="$(git -C "${repo_dir}" rev-parse --short HEAD 2>/dev/null || true)" \
    AUDIT_REPO_DIRTY="$(git -C "${repo_dir}" status --porcelain -- scripts 2>/dev/null | head -1)" \
    python3 - "${AUDIT_DIR}" > "${AUDIT_DIR}/configmap.json" <<'PYEOF'
import glob, json, os, sys
d, e = sys.argv[1], os.environ
details, texts = {}, {}
p = os.path.join(d, "changes.jsonl")
if os.path.exists(p):
    details["changes"] = [json.loads(l) for l in open(p) if l.strip()]
for p in sorted(glob.glob(os.path.join(d, "list-*.txt"))):
    details[os.path.basename(p)[5:-4]] = [l.rstrip("\n") for l in open(p) if l.strip()]
for p in sorted(glob.glob(os.path.join(d, "json-*.jsonl"))):
    details[os.path.basename(p)[5:-6]] = [json.loads(l) for l in open(p) if l.strip()]
for p in sorted(glob.glob(os.path.join(d, "text-*.txt"))):
    texts[os.path.basename(p)[5:-4]] = open(p).read()
record = {
    "schema": 1,
    "id": e["AUDIT_ID"],
    "action": e["AUDIT_SLUG"],
    "startedAt": e["AUDIT_STARTED_AT"],
    "finishedAt": e["AUDIT_FINISHED_AT"],
    "outcome": e["AUDIT_OUTCOME"],
    "summary": e["AUDIT_SUMMARY"],
    "reason": e["AUDIT_REASON"],
    "actor": {"user": e["AUDIT_ACTOR_USER"], "host": e["AUDIT_ACTOR_HOST"],
              "gitName": e["AUDIT_GIT_NAME"], "gitEmail": e["AUDIT_GIT_EMAIL"]},
    "cluster": {"context": e["AUDIT_CONTEXT"], "server": e["AUDIT_SERVER"]},
    "tooling": {"script": e["AUDIT_SCRIPT_NAME"], "scriptSha256": e["AUDIT_SCRIPT_SHA"],
                "repoCommit": e["AUDIT_REPO_COMMIT"],
                "repoScriptsModified": bool(e["AUDIT_REPO_DIRTY"])},
    "details": details,
    "texts": texts,
}
open(os.path.join(d, "record.json"), "w").write(json.dumps(record, indent=2))
trim = lambda s, n: s if len(s) <= n else s[: n - 1] + "…"
print(json.dumps({
    "apiVersion": "v1", "kind": "ConfigMap", "immutable": True,
    "metadata": {
        "name": e["AUDIT_ID"], "namespace": e["AUDIT_NS"],
        "labels": {"app.kubernetes.io/part-of": e["AUDIT_PART_OF"],
                   "amp-audit/action": e["AUDIT_SLUG"],
                   "amp-audit/outcome": e["AUDIT_OUTCOME"]},
        "annotations": {"amp-audit/summary": trim(e["AUDIT_SUMMARY"], 250),
                        "amp-audit/reason": trim(e["AUDIT_REASON"], 250),
                        "amp-audit/actor": e["AUDIT_GIT_EMAIL"] or e["AUDIT_ACTOR_USER"]},
    },
    "data": {"record.json": json.dumps(record, indent=2)},
}))
PYEOF

    kubectl get namespace "${AUDIT_NS}" >/dev/null 2>&1 \
        || kubectl create namespace "${AUDIT_NS}" >/dev/null 2>&1 || true
    if kubectl create -f "${AUDIT_DIR}/configmap.json" >/dev/null 2>&1; then
        _audit_say "Audit record ${id} — ./scripts/amp-audit.sh show ${id}"
    else
        mkdir -p "${AUDIT_FALLBACK_DIR}"
        cp "${AUDIT_DIR}/record.json" "${AUDIT_FALLBACK_DIR}/${id}.json"
        _audit_warn "Could not write the audit record to the cluster — kept at ${AUDIT_FALLBACK_DIR}/${id}.json"
    fi
    rm -rf "${AUDIT_DIR}"
    return 0
}

# audit_on_exit <status> — for the caller's EXIT trap: a run that dies after
# audit_begin still leaves a record, marked failed.
audit_on_exit() {
    local status="$1"
    if [ "${AUDIT_ACTIVE:-0}" = "1" ] && [ "${AUDIT_COMMITTED:-0}" != "1" ]; then
        audit_add notes "Run ended unexpectedly with exit status ${status} before it finished."
        audit_commit "failed" "${AUDIT_SUMMARY_SO_FAR:-interrupted} (exit ${status})"
    fi
    return 0
}

# ── CLI ──────────────────────────────────────────────────────────────────────
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0
set -euo pipefail

usage() {
    cat <<'HELPEOF'
amp-audit.sh — read the audit trail of changes made by the amp-* scripts

USAGE
  ./scripts/amp-audit.sh list [--limit N] [--action A]   newest first
  ./scripts/amp-audit.sh show <id|latest>               one record, readable
  ./scripts/amp-audit.sh show <id|latest> --json        one record, raw JSON
  ./scripts/amp-audit.sh export [--format md|json]       every record, oldest first
  ./scripts/amp-audit.sh --help

  Records live as immutable ConfigMaps in the namespace ${AMP_AUDIT_NS:-amp-audit}.
  Records that could not be written to the cluster are under ~/.amp-audit/.

EXAMPLES
  ./scripts/amp-audit.sh export > docs/change-log.md
  ./scripts/amp-audit.sh export --format json | your-log-shipper
HELPEOF
}

CMD="${1:-}"; [ -n "${CMD}" ] && shift || true
LIMIT=20; ACTION_FILTER=""; FORMAT="md"; AS_JSON=0; TARGET=""
while [ $# -gt 0 ]; do
    case "$1" in
        --limit)  LIMIT="$2"; shift 2 ;;
        --action) ACTION_FILTER="$2"; shift 2 ;;
        --format) FORMAT="$2"; shift 2 ;;
        --json)   AS_JSON=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *)        TARGET="$1"; shift ;;
    esac
done

# All records as a JSON list, oldest first: the cluster's plus any fallback files.
all_records() {
    {
        kubectl get configmap -n "${AUDIT_NS}" -l "app.kubernetes.io/part-of=${AUDIT_PART_OF}" -o json 2>/dev/null \
            || echo '{"items":[]}'
    } | python3 -c '
import glob, json, os, sys
items = json.load(sys.stdin).get("items", [])
recs = [json.loads(i["data"]["record.json"]) for i in items if "record.json" in (i.get("data") or {})]
for p in glob.glob(os.path.join(sys.argv[1], "*.json")):
    r = json.load(open(p)); r["_storedLocally"] = p; recs.append(r)
recs.sort(key=lambda r: r.get("startedAt", ""))
print(json.dumps(recs))' "${AUDIT_FALLBACK_DIR}"
}

RENDER_MD='
import json, sys
def md(r):
    out = []
    a, c, t = r.get("actor", {}), r.get("cluster", {}), r.get("tooling", {})
    who = a.get("gitName") or a.get("user", "")
    if a.get("gitEmail"): who += " <" + a["gitEmail"] + ">"
    out.append("## " + r["startedAt"].replace("T", " ").replace("Z", " UTC") + " — " + r["action"] + " — " + r["outcome"].upper())
    out.append("")
    out.append("- **Summary:** " + (r.get("summary") or ""))
    out.append("- **Reason:** " + (r.get("reason") or "_not given_"))
    out.append("- **By:** " + who + " (" + a.get("user", "") + "@" + a.get("host", "") + ")")
    out.append("- **Cluster:** " + c.get("context", "") + " (" + c.get("server", "") + ")")
    tool = t.get("script", "")
    if t.get("scriptSha256"): tool += ", sha256 " + t["scriptSha256"][:12]
    tool += ", repo " + (t.get("repoCommit") or "?")
    if t.get("repoScriptsModified"): tool += " (with uncommitted script changes)"
    out.append("- **Tooling:** " + tool)
    out.append("- **Record:** `" + r["id"] + "`" + (" (stored locally: " + r["_storedLocally"] + ")" if r.get("_storedLocally") else ""))
    d = r.get("details", {})
    if d.get("changes"):
        out += ["", "| Target | Change | Before | After |", "|---|---|---|---|"]
        for ch in d["changes"]:
            cell = lambda s: (s or "—").replace("|", "\\|")
            out.append("| " + " | ".join(cell(ch.get(k)) for k in ("target", "what", "before", "after")) + " |")
    for pd in d.get("policies", []):
        if not (pd.get("added") or pd.get("removed") or pd.get("changed")):
            out += ["", "**Policies, " + pd.get("target", "") + ":** unchanged (" + str(pd.get("count", "?")) + ")"]
            continue
        out += ["", "**Policies, " + pd.get("target", "") + ":**"]
        out += ["- added `" + p["name"] + " " + p["version"] + "`" for p in pd.get("added", [])]
        out += ["- removed `" + p["name"] + " " + p["version"] + "`" for p in pd.get("removed", [])]
        out += ["- changed `" + p["name"] + "` " + p["from"] + " → " + p["to"] for p in pd.get("changed", [])]
    for key, title in (("settings", "Settings"), ("warnings", "Warnings"), ("backups", "Preserved images"), ("notes", "Notes")):
        if d.get(key):
            out += ["", "**" + title + ":**"] + ["- " + x for x in d[key]]
    if d.get("rollback"):
        out += ["", "**Roll back with:**", "```bash"] + d["rollback"] + ["```"]
    for name, body in (r.get("texts") or {}).items():
        out += ["", "**" + name + ":**", "```diff" if name.endswith(".diff") else "```", body.rstrip("\n"), "```"]
    return "\n".join(out)
'

case "${CMD}" in
    list)
        all_records | python3 -c '
import json, sys
recs = json.load(sys.stdin)[::-1]
flt, limit = sys.argv[1], int(sys.argv[2])
recs = [r for r in recs if not flt or r["action"] == flt][:limit]
if not recs:
    print("  no audit records"); sys.exit()
print("  {:<20} {:<20} {:<8} {:<24} {}".format("WHEN (UTC)", "ACTION", "OUTCOME", "BY", "SUMMARY / REASON"))
for r in recs:
    a = r.get("actor", {})
    by = a.get("gitEmail") or a.get("user", "")
    line = "  {:<20} {:<20} {:<8} {:<24} {}".format(r["startedAt"].replace("T", " ")[:19], r["action"][:20], r["outcome"], by[:24], r.get("summary", ""))
    print(line)
    if r.get("reason"): print(" " * 76 + "↳ " + r["reason"])
    print(" " * 76 + "  " + r["id"])' "${ACTION_FILTER}" "${LIMIT}"
        ;;
    show)
        [ -n "${TARGET}" ] || { echo "show needs a record id, or 'latest'" >&2; exit 1; }
        all_records | python3 -c "
${RENDER_MD}
recs = json.load(sys.stdin)
target, as_json = sys.argv[1], sys.argv[2] == '1'
r = recs[-1] if target == 'latest' and recs else next((x for x in recs if x['id'] == target), None)
if r is None:
    print('no such record: ' + target, file=sys.stderr); sys.exit(1)
print(json.dumps(r, indent=2) if as_json else md(r))" "${TARGET}" "${AS_JSON}"
        ;;
    export)
        case "${FORMAT}" in
            json) all_records | python3 -c 'import json,sys;[print(json.dumps(r)) for r in json.load(sys.stdin)]' ;;
            md)   all_records | python3 -c "
${RENDER_MD}
recs = json.load(sys.stdin)
print('# Change log — AMP gateway and guardrail updates')
print()
print('Generated from the amp-audit trail; one section per change, oldest first.')
for r in recs:
    print(); print(md(r))" ;;
            *)    echo "unknown format: ${FORMAT} (md or json)" >&2; exit 1 ;;
        esac
        ;;
    ""|-h|--help) usage ;;
    *) echo "Unknown command: ${CMD}" >&2; usage >&2; exit 1 ;;
esac
