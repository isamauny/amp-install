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

- Select Kubernetes version to be `v1.32.x` (which is what Agent Manager supports) - Later versions could be problematic due to CRDs versions installed by default.
- Select dockerd (moby)
- You can configure the path changes yourself or let the installer do it. Either way, make sure you open a new shell !

![Rancher_first_window](./images/Rancher_first_window.png)

Let the cluster start properly, then open Rancher Desktop Preferences.

1. Disable Traefik

![pref_disable_traefik](./images/pref_disable_traefik.png)

2. CPU and Memory- Give it as much as you can. Minimum configuration is 8Gb memory and 4 CPUs.

![prefs_set_cpu_mem](./images/pref_cpu_mem.png)

3. Apply changes. This restarts the cluster. 

You are ready to install!

## Agent Manager installation

The script provided in this project is mirroring instructions provided here: https://wso2.github.io/agent-manager/docs/v1.0.0-alpha1/getting-started/on-your-environment/. This branch tracks the v1.0.0-alpha1 pre-release — expect rough edges, since some steps below are adapted from production/DNS-based instructions to this script's port-forward/nip.io-based local setup and haven't been fully validated yet.

Simply make it executable and run it. The script is split in 3 parts:

1. Checking prerequisites
2. Installing OpenChoreo
3. Installing Agent Manager

Each step has validation embedded, to ensure we are ready to move to the next one. 

If all goes well, you should see this at the end of the execution.

```shell
Pod Status:
  ✓ openchoreo-control-plane: 6/6 pods Running
  ✓ openchoreo-data-plane: 6/6 pods Running
  ✓ openchoreo-workflow-plane: 2/2 pods Running
  ✓ openchoreo-observability-plane: 17/17 pods Running
  ✓ wso2-amp: 3/3 pods Running
  ✓ amp-thunder: 2/2 pods Running

Domains:
  OpenChoreo API: https://api.openchoreo.192-168-64-4.nip.io
  Data Plane:     apps.openchoreo.192-168-64-4.nip.io

✓ Installation completed successfully!
```

Be patient as some steps can take several minutes to run depending on the memory / CPUs you have set for the VM.



> [!NOTE]
>
> Execution of the script is idempotent. You can run it multiple times, even if for some reason it fails to execute at some point.

## Uninstalling Agent Manager

To remove everything the installer set up (for example, to reinstall a different version), run `scripts/amp-uninstall-rancher.sh`. It reverses the install script's steps: it removes the plane registrations, uninstalls all the Helm releases, and deletes the namespaces used by Agent Manager and OpenChoreo.

```shell
./scripts/amp-uninstall-rancher.sh
```

It also cleans up the handful of cluster-scoped resources the installer creates via raw `kubectl apply` (a `ClusterSecretStore`, two `ClusterIssuer`s, and a `ClusterRole`/`ClusterRoleBinding`) — these aren't part of any Helm release or namespace, so they'd otherwise survive uninstall unnoticed.

It asks for confirmation before touching the cluster (pass `-y`/`--yes` to skip the prompt), and finishes with a validation pass confirming no matching Helm releases, namespaces, plane registrations, or cluster-scoped extras remain, plus a check for any `PersistentVolume`s still referencing the deleted namespaces (worth a look if your StorageClass's reclaim policy is `Retain` rather than `Delete`).

Cluster-scoped CRDs (Gateway API, cert-manager) are intentionally left in place — they're shared infrastructure, not part of the Agent Manager release, and the installer already handles re-applying them safely on the next run.

> [!NOTE]
>
> A namespace can occasionally get stuck in `Terminating`. This happens when a custom resource inside it (e.g. a `RestAPI` from gateway-operator, or an `ExternalSecret`) still has a finalizer set, but the operator that owns that finalizer was already removed by the Helm uninstall step — so nothing is left to clear it. The script detects this automatically and force-clears any leftover finalizers on stuck namespaces so deletion can complete; if it still doesn't resolve, inspect the namespace's conditions for the specific resource holding it up:
>
> ```shell
> kubectl get namespace <ns> -o json | jq '.status.conditions'
> ```

