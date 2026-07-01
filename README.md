# Agent Manager Installer for Rancher Desktop

Rancher desktop allows you to easily run a 1-node Kubernetes cluster for local testing. This guide helps you install Agent Manager on an existing cluster using a shell script which installs the pre-requisiites and the product itself. 

## Rancher Desktop installation 

Following steps have been tested on MacOS and installation was done using brew : `brew install rancher` - If you use a different platform, refer to the documentation here: https://docs.rancherdesktop.io/getting-started/installation/

Installing Rancher desktop also provisions kubectl, helm as well as some docker commands which are all required to install Agent Manager 

> [!IMPORTANT]
>
> Once Rancher Desktop is installed, start a *new* terminal to execute the script, so that your PATH is updated - The script checks for prereqs and if they can't be found, it is most likely because you're executing from a shell that was opened before Rancher was installed.

## Cluster Configuration

When you start Rancher Desktop, it provisions a Kubernetes cluster automatically. However we need to edit some preferences before installing. A window will pop up where you can set a few options. 

- Select Kubernetes version to be `v1.32.x` (which is what Agent Manager supports) - Later versions could be problematic due to CRDs versions installed by default.
- Select dockerd (moby)
- You can configure the path changes yourself or let the installer do it. Either way, make sure you open a new shell !

![Rancher_first_window](./images/Rancher_first_window.png)

Let the cluster start properly, then open Rancher Desktop Preferences.

1. Disable Traefik

![pref_disable_traefik](./images/pref_disable_traefik.png)

2. CPU and Memory- Give it as much as you can. Minimal will be 8Gb memory and 4 CPUs.

![prefs_set_cpu_mem](./images/pref_cpu_mem.png)

3. Apply changes. This restarts the cluster. 

You are ready to install!

## Agent Manager installation

The script provided in this project is mirroring instructions provided here: https://wso2.github.io/agent-manager/docs/v0.17.x/getting-started/on-your-environment/. 

Simply make it executable and run it. The script is split in 3 parts:

1. Checking prerequisites
2. Installing OpenChoreo
3. Installing Agent Manager

Each step has validation to ensure we are ready to move to the next one. 

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

Be patient as some steps can take several minutes to run depending on the memoty / CPU you have set for the VM.



> [!NOTE]
>
> Execution of the script is idempotent. You can run it multiple times, even if for some reason it fails to execute at some point.

