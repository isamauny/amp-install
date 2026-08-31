# Agent Manager Installer for Rancher Desktop

Rancher desktop allows you to easily run a 1-node Kubernetes cluster for local testing. This guide helps you install Agent Manager on an existing cluster using a shell script which installs the pre-requisiites and the product itself. 

## Rancher Desktop installation 

Following steps have been tested on MacOS and installation was done using brew : `brew install rancher` - If you use a different platform, refer to the documentation here: https://docs.rancherdesktop.io/getting-started/installation/

Installing Rancher desktop also provisions kubectl, helm as well as some docker commands which are all required to install Agent Manager 

> [!IMPORTANT]
>
> Once Rancher Desktop is installed, start a *new* terminal to execute the script, so that your PATH is updated - The script checks for prereqs and if they can't be found, it is most likely because you're executing from a shell that was opened before Rancher was installed.

> [!WARNING]
>
> Agent Manager requires **Helm v3.12+**, but recent Rancher Desktop versions bundle **Helm 4** as `helm` on PATH. Helm 4's hook lifecycle (used by cert-manager's `startupapicheck`, the Agent Sandbox Module, and others installed here) has been observed to hang indefinitely on this setup — confirmed by re-running the exact same chart install with Helm 3, which succeeded in seconds every time Helm 4 hung. The installer checks for this and exits early with a fix if it detects Helm 4+. To install Helm 3 alongside Rancher Desktop's Helm 4: `brew install helm@3`, then put it ahead on PATH: `export PATH="/opt/homebrew/opt/helm@3/bin:$PATH"` (it's keg-only, so this won't disturb the existing `helm` link).

## Cluster Configuration

When you start Rancher Desktop, it provisions a Kubernetes cluster automatically. However we need to edit some preferences before installing. A window will pop up where you can set a few options. 

- Select Kubernetes version to be `v1.32.x` or `v1.33.13`(which is what Agent Manager supports) - Later versions could be problematic due to CRDs versions installed by default.
- Select dockerd (moby)
- You can configure the path changes yourself or let the installer do it. Either way, make sure you open a new shell !

![Rancher_first_window](./images/Rancher_first_window.png)

Let the cluster start properly, then open Rancher Desktop Preferences.

1.Disable Traefik

![pref_disable_traefik](./images/pref_disable_traefik.png)

2.CPU and Memory- Give it as much as you can. Minimum configuration is 8Gb memory and 4 CPUs.

![prefs_set_cpu_mem](./images/pref_cpu_mem.png)

3.Apply changes. This restarts the cluster. 

You are ready to install!

## Agent Manager installation

The script mirrors the official instructions at https://wso2.github.io/agent-manager/docs/v1.0.0-rc2/guides/on-your-environment/ and tracks the **v1.0.0-rc2** pre-release. Where it departs from the docs, the reason is written in a comment at that point in the script — most of the departures exist because the docs assume a cloud cluster where each plane owns its own LoadBalancer, whereas a single-node k3s shares one host.

> [!IMPORTANT]
>
> **The OpenChoreo planes are installed at 1.2.1, not the 1.1.1 the RC2 guide pins.**  Its platform-resources extension creates `ProjectType` and `ProjectReleaseBinding` resources, and those CRDs do not exist before OpenChoreo **1.2.0** .
### Profiles

The script has two profiles, selected with the `PROFILE` environment variable. They cannot be mixed on one cluster: Thunder's issuer and the API gateway's registered vhost are written once at first install and are never reconciled afterwards, so switching means discarding Thunder's data (and, with it, Agent Manager's tenant data).

| | `PROFILE=local` (default) | `PROFILE=cloud` |
|---|---|---|
| Target | Rancher Desktop / k3s | Any cluster with real DNS (EKS, GKE, AKS, DigitalOcean…) |
| Base domain | `local.apis.coach` | `amp.apis.coach` |
| Scheme | plain HTTP | HTTPS |
| Control-plane gateway | 8080 / 8443 | 80 / 443 |
| Data-plane gateway | 19080 / 19443 | 80 / 443 |
| Observability gateway | 11080 / 11085 | 80 / 443 |
| DNS | `/etc/hosts` + a CoreDNS rewrite | published DNS records |
| Works offline | **yes** | no |
| Registry | CNCF Distribution, deployed in-cluster | bring your own |

Override the domain with `BASE_DOMAIN=…` if you want something other than the defaults.

### Offline operation

The `local` profile is designed to work with **no Internet connection** once installed. (The install itself still needs the network — Helm charts come from ghcr.io, quay.io and GitHub.)

This is why it does not use `nip.io`, which the earlier alpha1 version of this script relied on: `nip.io` is a public DNS service and resolves nothing when you are offline. Instead, two resolvers are configured for the same real hostnames:

- **Pods** resolve them through a `coredns-custom` ConfigMap the installer applies, which rewrites each domain onto the right gateway `Service`. This is the same mechanism the upstream k3d layout uses. It matters for agents' OTLP exporters, the API gateway and env-Thunder, all of which dial these names from inside the cluster.
- **Your Mac** resolves them through `/etc/hosts`, pointing at `127.0.0.1` — Rancher Desktop's ssh forwarder binds every LoadBalancer port on the host, so this reaches each plane gateway on its own port and, unlike the VM's IP address, does not change when the VM restarts.

`.localhost` is not an option for either side, which is worth knowing if you are tempted: macOS does not resolve multi-label `.localhost` names (`getaddrinfo("console.amp.localhost")` and `curl` both fail), and Go and Python resolvers inside pods do not special-case it either.

> [!NOTE]
>
> **One endpoint is HTTPS even on the local profile.** The per-environment Thunder validates its trusted-issuer JWKS URL at config load and rejects plain HTTP unless the host is `localhost`:
>
> ```
> trusted_issuer.jwks_url must use https (got http://…); http is only allowed for localhost
> ```
>
> That crash-loops the chart's pre-install setup Job until it hits its backoff limit, at which point the Job **deletes its pod** — so `kubectl logs` is empty and the only visible symptom is `failed pre-install: job … BackoffLimitExceeded`.
>
> The installer therefore points env-Thunder at the control-plane gateway's HTTPS listener (`https://thunder.<base>:8443/oauth2/jwks`), which already exists with the wildcard certificate and is otherwise unused, and mounts the CA from the `openchoreo-ca-secret` in `cert-manager`. Nothing else changes: the trusted **issuer** stays plain HTTP, because it has to match the `iss` claim platform Thunder actually stamps into tokens, and every human-facing URL stays on `:8080`.

Manage the host entries with the helper:

```shell
scripts/amp-hosts.sh print              # show the block, change nothing
scripts/amp-hosts.sh add                # append/refresh it (needs sudo)
scripts/amp-hosts.sh add myproject      # ... plus a host for a project you created
scripts/amp-hosts.sh remove             # delete it
```

`/etc/hosts` has no wildcards, so each project you create needs its own line — agent invoke hostnames are `<org>-<project>.agents.<base-domain>`.

### Running it

Make it executable and run it:

```shell
./scripts/amp-install-rancher.sh                    # local profile
PROFILE=cloud TLS_MODE=acme-dns01 \
  ACME_EMAIL=you@example.com \
  TLS_ACME_SOLVER_FILE=./solver.yaml \
  ./scripts/amp-install-rancher.sh                  # cloud profile
```

The script runs in phases — prerequisites, OpenChoreo, then Agent Manager — with validation embedded in each step. Be patient: some steps take several minutes depending on the memory and CPU allotted to the VM, and the observability plane alone can take 25.

If all goes well you should see something like this at the end:

```shell
Pod Status:
  ✓ openchoreo-control-plane: 6/6 pods Running
  ✓ openchoreo-data-plane: 6/6 pods Running
  ✓ openchoreo-workflow-plane: 2/2 pods Running
  ✓ openchoreo-observability-plane: 17/17 pods Running
  ✓ wso2-amp: 3/3 pods Running
  ✓ amp-thunder: 2/2 pods Running
  ✓ amp-thunder-default-default: 1/1 pods Running

Gateway registration (write-once):
  ✓ vhost: http://default-default.agents.local.apis.coach:19080

Access URLs:
  Console:      http://console.local.apis.coach:8080
  API:          http://api-amp.local.apis.coach:8080
  Thunder:      http://thunder.local.apis.coach:8080
  Observer:     http://traces.local.apis.coach:11080
  Agents:       http://<org>-<project>.agents.local.apis.coach:19080
  OTLP ingest:  http://default-default.agents.local.apis.coach:19080/otel
  env-Thunder:  http://default-idp.local.apis.coach:8080

Credentials:
  Console admin:  admin / <generated>

✓ Installation completed successfully!
```

> [!IMPORTANT]
>
> The console password is **not** `admin/admin`. It is generated at install time into the `amp-admin-credentials` Secret and printed in the summary above. Retrieve it later with:
> ```shell
> kubectl get secret amp-admin-credentials -n amp-thunder -o jsonpath='{.data.password}' | base64 -d
> ```

> [!IMPORTANT]
>
> The gateway's registered **vhost is write-once**. The bootstrap job writes it into Agent Manager at first registration; every later run finds the gateway already present, logs `already exists`, and exits without reconciling. A `helm upgrade` with corrected values changes nothing and reports no error — the console just keeps showing whatever was registered first. The summary checks this explicitly. If it shows a `.localhost` host, the only fix is to delete the gateway registration and re-register.

> [!NOTE]
>
> Execution of the script is idempotent. You can run it multiple times, even if for some reason it fails to execute at some point.

### TLS modes

Set with `TLS_MODE`. RC2 requires **wildcard** certificates (`*.<base>` and `*.agents.<base>`), because per-environment Thunder hostnames are created after install with unguessable handles and are reachable only through the wildcard. That rules out HTTP-01 entirely.

- **`selfsigned`** (default) — a cert-manager self-signed CA chain named `openchoreo-ca`. No DNS credentials, works anywhere, browsers warn on every hostname. This is what the `local` profile uses, where nothing is served over TLS anyway.
- **`acme-dns01`** — Let's Encrypt via DNS-01. Deliberately **not** tied to any one provider: supply the solver stanza yourself.
  ```shell
  export ACME_EMAIL=you@example.com
  export TLS_ACME_SOLVER_FILE=./solver.yaml   # the list entries that go under solvers:
  ```
  `apis.coach` is hosted on **GoDaddy**, for which cert-manager ships **no built-in solver**. Two routes work:
  1. *Delegate a subdomain.* Add NS records at GoDaddy delegating `amp.apis.coach` to a provider cert-manager supports natively (Cloudflare, Route53, AzureDNS, Google Cloud DNS, DigitalOcean), then use that provider's solver stanza. This is the shape the RC2 docs themselves recommend.
  2. *Use acme-dns.* cert-manager has a built-in `acmeDNS` solver. Add a one-time `CNAME _acme-challenge.amp.apis.coach` at GoDaddy pointing at an acme-dns server — no provider API credentials at all.
- **`existing`** — use a `ClusterIssuer` you created yourself, named by `TLS_ISSUER_NAME` (default `openchoreo-ca`). The escape hatch for a corporate CA or any solver not modelled here.

### Container registry

RC2 makes registry configuration load-bearing: build workflows push each agent image, and the chart default (`host.k3d.internal:10082`) does not resolve on Rancher Desktop. The failure surfaces only on the first agent build, long after the platform installs and verifies cleanly.

The `local` profile deploys **CNCF Distribution** in-cluster and points the platform at it. Distribution satisfies both of RC2's requirements: it creates repositories on push (each build pushes a uniquely-named `<workflow-run>-image`, so they cannot be pre-created — this is why ECR cannot be used), and it needs no rotating credentials. The installer also writes `/etc/rancher/k3s/registries.yaml` inside the Lima VM via `rdctl` so kubelet will pull over plain HTTP.

It ships with **no authentication**. That is fine *only* for a cluster-local evaluation registry. To use your own registry instead:

```shell
DEPLOY_REGISTRY=false 
REGISTRY_ENDPOINT=registry.example.com:5000 
REGISTRY_TLS_VERIFY=true \
  ./scripts/amp-install-rancher.sh
```

## Sample agent

[samples/langchain-chat-agent/](samples/langchain-chat-agent/) is a minimal LangChain chat agent for verifying an install end to end — build, image push, deploy, invoke, and trace export. It builds with buildpacks (no Dockerfile), exposes `POST /chat`, and ships an `openapi.yaml` so the console's try-out renders a form. See its README for the endpoint and environment-variable configuration.

## Uninstalling Agent Manager

To remove everything the installer set up (for example, to reinstall a different version), run `scripts/amp-uninstall-rancher.sh`. It reverses the install script's steps: it removes the plane registrations, uninstalls all the Helm releases, and deletes the namespaces used by Agent Manager and OpenChoreo.

```shell
./scripts/amp-uninstall-rancher.sh
```

It also cleans up the cluster-scoped resources the installer creates via raw `kubectl apply` — a `ClusterSecretStore`, two `ClusterIssuer`s, a `ClusterRole`/`ClusterRoleBinding`, the Agent Sandbox CRDs and RBAC, the env-Thunder `HTTPRoute` (which lives in the control-plane namespace, because the shared gateway only admits routes from its own namespace), and the `coredns-custom` ConfigMap. None of these are part of a Helm release or of the namespaces being deleted, so they would otherwise survive uninstall unnoticed.

`/etc/hosts` is outside the cluster and is left alone — the entries point at `127.0.0.1` and are harmless across a reinstall onto the same base domain. The script reports if they are still present; remove them with `scripts/amp-hosts.sh remove`.

It asks for confirmation before touching the cluster (pass `-y`/`--yes` to skip the prompt), and finishes with a validation pass confirming no matching Helm releases, namespaces, plane registrations, or cluster-scoped extras remain, plus a check for any `PersistentVolume`s still referencing the deleted namespaces (worth a look if your StorageClass's reclaim policy is `Retain` rather than `Delete`).

Cluster-scoped CRDs (Gateway API, cert-manager) are intentionally left in place — they're shared infrastructure, not part of the Agent Manager release, and the installer already handles re-applying them safely on the next run.

> [!NOTE]
>
> A namespace can occasionally get stuck in `Terminating`. This happens when a custom resource inside it (e.g. a `RestAPI` from gateway-operator, or an `ExternalSecret`) still has a finalizer set, but the operator that owns that finalizer was already removed by the Helm uninstall step — so nothing is left to clear it. The script detects this automatically and force-clears any leftover finalizers on stuck namespaces so deletion can complete; if it still doesn't resolve, inspect the namespace's conditions for the specific resource holding it up:
>
> ```shell
> kubectl get namespace <ns> -o json | jq '.status.conditions'
> ```

