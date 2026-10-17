# Installing AMP 1.0.0 on DigitalOcean (DOKS) — checklist

A step-by-step checklist for running `scripts/amp-install-rancher.sh` with `PROFILE=cloud` on a DigitalOcean Kubernetes cluster. Work through it top to bottom; the boxes are there to tick as you go.

> **The cloud profile has never completed a verified end-to-end install.** The script refuses to run it without `ALLOW_UNTESTED_CLOUD=1`. Use a cluster you are willing to throw away, and expect to find things this list does not cover yet — add them here when you do.

Placeholders used throughout: `<cluster>` (DOKS cluster name), `<region>` (e.g. `fra1`), `<registry>` (DOCR registry name), `<you@example.com>` (ACME contact). The base domain is `amp.apis.coach` — the local Rancher cluster uses `local.apis.coach`, so the two never collide.

---

## 1. Create the cluster

- [ ] Create a DOKS cluster. DOKS nodes are **amd64 only** — nothing built on the Mac runs there unless it was built for `linux/amd64`.
  ```bash
  doctl kubernetes cluster create <cluster> --region <region> \
    --node-pool "name=amp;size=s-4vcpu-8gb;count=3"
  ```
  Sizing: 3 × 4 vCPU / 8 GB, or 2 × 8 vCPU / 16 GB. Prefer at least 3 nodes: DO caps how many block-storage volumes a single node can attach (7, as far as I know), and this stack creates a lot of PVCs.
- [ ] Save the kubeconfig and note the context name (`do-<region>-<cluster>`):
  ```bash
  doctl kubernetes cluster kubeconfig save <cluster>
  kubectl config current-context
  ```
- [ ] Check there is a default StorageClass (`do-block-storage`): `kubectl get storageclass`
- [ ] Budget for **3 DO Load Balancers** (one per plane gateway) plus the volumes. The pre-flight probe creates a 4th briefly and deletes it.

> From here on both clusters are in your kubeconfig. Check `kubectl config current-context` before every `amp-*` script — especially `amp-uninstall-rancher.sh`.

## 2. Move the DNS zone to DigitalOcean

GoDaddy has no cert-manager solver; DigitalOcean has a built-in one. Delegating just the `amp` subdomain keeps the rest of `apis.coach` at GoDaddy.

- [ ] In DO → Networking → Domains, add the domain `amp.apis.coach`.
- [ ] At GoDaddy, in the `apis.coach` zone, add three **NS** records with host `amp`: `ns1.digitalocean.com`, `ns2.digitalocean.com`, `ns3.digitalocean.com`.
- [ ] Wait for delegation, then verify:
  ```bash
  dig NS amp.apis.coach +short     # should list the three DO nameservers
  ```
- [ ] Create a DO API token with write access to Domains (used by cert-manager for DNS-01).

## 3. TLS: Let's Encrypt via DNS-01

The guide needs wildcard certificates (`*.amp.apis.coach`, `*.agents.amp.apis.coach`), so HTTP-01 is not an option.

- [ ] Pre-create the namespace and the token secret (the installer's `helm --create-namespace` is happy with an existing namespace):
  ```bash
  kubectl create namespace cert-manager
  kubectl -n cert-manager create secret generic digitalocean-dns \
    --from-literal=access-token=<DO API token>
  ```
- [ ] Write the solver stanza (no secret in it — just a reference), e.g. `~/amp-do/do-solver.yaml`:
  ```yaml
  - dns01:
      digitalocean:
        tokenSecretRef:
          name: digitalocean-dns
          key: access-token
  ```

> **Rate limit:** the script always uses the Let's Encrypt **production** server (no staging override yet — see Known gaps). Let's Encrypt issues at most 5 identical certificates per week, so repeated reinstalls of a throwaway cluster can lock you out for days.

## 4. Container registry (DOCR)

Agent builds push their images here and the data plane pulls them from here.

- [ ] Create the registry. According to the guide, every build pushes to a **new, uniquely named repository**, and the custom gateway images add two more. Starter (1 repository) and Basic (5) will run out quickly — plan on **Professional**, and check DO's current tier limits.
  ```bash
  doctl registry create <registry> --subscription-tier professional --region <region>
  ```
- [ ] Give the cluster pull access:
  ```bash
  doctl kubernetes cluster registry add <cluster>
  ```
  The agent Deployments carry **no `imagePullSecrets`** in the chart, so pulls rely on DO adding the registry secret to the `default` ServiceAccount — including in the `dp-*` namespaces OpenChoreo creates later. **Verify on the first agent deploy** (step 9).
- [ ] Push credentials are a separate step **after** install (step 9) — the installer does not set them.

> **Do not use `DEPLOY_REGISTRY=true` on DOKS**, even though the script's error message suggests it. The node-side half of that setup is `rdctl` + `dockerd`-specific; DOKS nodes run containerd, so every image pull would fail.

## 5. Gateway images (amd64)

Every gateway image on the Mac is `linux/arm64`. The installer's effective default is the local `localhost/upgraded-ai-gateway-*` build (lines 167–170 of the script shadow the ghcr fallback at 249–252), which a DOKS node cannot pull. Pick one:

**Option A — upstream images (no custom policies).** Multi-arch, nodes pull the amd64 variant themselves:
- [ ] `GATEWAY_CONTROLLER_IMAGE=ghcr.io/wso2/api-platform/gateway-controller`, `GATEWAY_RUNTIME_IMAGE=ghcr.io/wso2/api-platform/gateway-runtime`, both tags `1.2.1`.

**Option B — the custom gateway build.**
- [ ] Run the gateway builder on an **amd64 host** (a small DO Droplet, or a GitHub Actions `ubuntu-latest` runner) rather than under emulation on the Mac. `ghcr.io/wso2/api-platform/gateway-builder:1.2.1` is published for `linux/amd64`.
- [ ] Push to DOCR with a tag that does **not** exist on the Mac (so pre-flight doesn't inspect the arm64 copy instead):
  ```bash
  doctl registry login
  REG=registry.digitalocean.com/<registry>
  docker tag <built-controller> $REG/gateway-controller:1.2.1-p1
  docker tag <built-runtime>    $REG/gateway-runtime:1.2.1-p1
  docker push $REG/gateway-controller:1.2.1-p1
  docker push $REG/gateway-runtime:1.2.1-p1
  ```
- [ ] Confirm the architecture: `docker buildx imagetools inspect $REG/gateway-runtime:1.2.1-p1` → `linux/amd64`
- [ ] Set **`GATEWAY_POLICIES_PATH=./policies` explicitly.** The script detects the path only from an image in your *local* Docker; when it can't find one it falls back to `./default-policies` and the custom policies disappear with no error.

## 6. Settings file

Keep every setting in one file so re-runs use exactly the same values — a re-run with a different `BASE_DOMAIN` is refused, and Thunder's issuer cannot change after the first install.

- [ ] Create `~/amp-do/do.env`:
  ```bash
  export ALLOW_UNTESTED_CLOUD=1
  export PROFILE=cloud
  export BASE_DOMAIN=amp.apis.coach

  export TLS_MODE=acme-dns01
  export ACME_EMAIL=<you@example.com>
  export TLS_ACME_SOLVER_FILE=$HOME/amp-do/do-solver.yaml

  export REGISTRY_ENDPOINT=registry.digitalocean.com/<registry>
  export DEPLOY_REDIS=true          # DO's managed cache is Valkey: no Redis Query Engine, so no semantic-cache

  # Option A
  export GATEWAY_CONTROLLER_IMAGE=ghcr.io/wso2/api-platform/gateway-controller GATEWAY_CONTROLLER_TAG=1.2.1
  export GATEWAY_RUNTIME_IMAGE=ghcr.io/wso2/api-platform/gateway-runtime       GATEWAY_RUNTIME_TAG=1.2.1
  # Option B (instead of A)
  # export GATEWAY_CONTROLLER_IMAGE=registry.digitalocean.com/<registry>/gateway-controller GATEWAY_CONTROLLER_TAG=1.2.1-p1
  # export GATEWAY_RUNTIME_IMAGE=registry.digitalocean.com/<registry>/gateway-runtime       GATEWAY_RUNTIME_TAG=1.2.1-p1
  # export GATEWAY_POLICIES_PATH=./policies
  ```
  Leave `TLS_MODE` off `selfsigned` — browsers would reject every hostname, and the script blocks it on this profile anyway.

## 7. First run — stops at DNS

- [ ] Use Helm 3, not Helm 4 (the script checks).
- [ ] Run:
  ```bash
  source ~/amp-do/do.env
  ./scripts/amp-install-rancher.sh install --reason "DOKS first install"
  ```
- [ ] At the confirmation prompt, check **Context** is the `do-…` one and **Profile** is `cloud`.
- [ ] Expect the run to **stop before env-Thunder** with `thunder.amp.apis.coach does not resolve` and a list of DNS records with the load-balancer IPs. That is the designed behaviour on the first run.

## 8. Publish the DNS records, then re-run

- [ ] Create the four records from the load-balancer IPs:
  ```bash
  ip() { kubectl get svc gateway-default -n "$1" -o jsonpath='{.status.loadBalancer.ingress[0].ip}'; }
  CP=$(ip openchoreo-control-plane); OBS=$(ip openchoreo-observability-plane); DP=$(ip openchoreo-data-plane)
  D=amp.apis.coach
  doctl compute domain records create $D --record-type A --record-name '*'        --record-data "$CP"  --record-ttl 300
  doctl compute domain records create $D --record-type A --record-name traces     --record-data "$OBS" --record-ttl 300
  doctl compute domain records create $D --record-type A --record-name agents     --record-data "$DP"  --record-ttl 300
  doctl compute domain records create $D --record-type A --record-name '*.agents' --record-data "$DP"  --record-ttl 300
  ```
  The `*.amp.apis.coach` wildcard is required: per-environment Thunder hostnames are generated after install and are only reachable through it.
- [ ] Verify: `dig +short thunder.amp.apis.coach`, `traces.amp.apis.coach`, `default-default.agents.amp.apis.coach`
- [ ] Re-run with the same settings — the script is idempotent and resumes:
  ```bash
  source ~/amp-do/do.env
  ./scripts/amp-install-rancher.sh install --reason "DOKS install, after DNS"
  ```
- [ ] Check the summary has no errors and the console loads at `https://console.amp.apis.coach` with a valid certificate.

## 9. After install

- [ ] **Store the registry push credentials in OpenBao.** Builds read them from `secret/registry-push-secret` (ExternalSecret with no `property`, so the whole KV entry becomes the `.dockerconfigjson`). The installer never writes this key.
  ```bash
  TOKEN=$(kubectl get secret openbao-root-token -n openbao -o jsonpath='{.data.root-token}' | base64 -d)
  doctl registry docker-config --read-write \
    | kubectl exec -i -n openbao openbao-0 -c openbao -- \
      sh -c "BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=$TOKEN bao kv put secret/registry-push-secret -"
  ```
  Not yet verified end to end — confirm on the first build that the generated secret looks like `{"auths":{"registry.digitalocean.com":…}}`:
  ```bash
  kubectl get externalsecret -A | grep registry-push
  ```
- [ ] **First agent build:** confirm the push to DOCR succeeds (a new repository appears in `doctl registry repository list-v2`).
- [ ] **First agent deploy:** confirm the pod pulls its image. On `ImagePullBackOff`, check that the `dp-*` namespace has the DOCR pull secret on its `default` ServiceAccount; re-run `doctl kubernetes cluster registry add <cluster>` if not.
- [ ] **Guardrails:** Redis was deployed by the installer (`DEPLOY_REDIS=true`); configure semantic guardrails with `scripts/amp-guardrails.sh configure`.
- [ ] **Traces:** the certificates are publicly trusted, so Python agents need no `OTEL_EXPORTER_OTLP_CERTIFICATE` here. The export endpoint is `https://default-default.agents.amp.apis.coach/otel`.
- [ ] `./scripts/amp-audit.sh list` — the install is recorded in the `amp-audit` namespace on this cluster.

## Known gaps in the script

Work around these by hand (as above) until the script is fixed:

1. **Gateway image default is the local `localhost/` build** on every profile, and the pre-flight "image present" check looks at the Mac's Docker, not at what a DOKS node can pull. → Set `GATEWAY_*_IMAGE` explicitly (step 5).
2. **Policies path detection needs the image locally.** → Set `GATEWAY_POLICIES_PATH=./policies` for a custom build.
3. **`DEPLOY_REGISTRY=true` is suggested by the cloud error message but cannot work on DOKS** (rdctl/dockerd only). → Use DOCR.
4. **`secret/registry-push-secret` is never seeded.** → Step 9.
5. **No Let's Encrypt staging option.** → Mind the rate limit (step 3).

## Teardown

- [ ] Delete the cluster together with the resources it created (load balancers, volumes):
  ```bash
  doctl kubernetes cluster delete <cluster> --dangerous
  ```
- [ ] Check DO → Networking → Load Balancers and Volumes for anything left over.
- [ ] Remove the four DNS records (or keep them for the next attempt — the IPs will change).
- [ ] Clean up old repositories in DOCR and run garbage collection if you keep the registry.
