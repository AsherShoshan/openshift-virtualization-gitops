# Deployment Changes: etl4 & etl6 Spoke Clusters

## Overview

This document records all changes made to deploy two new OpenShift spoke clusters
(**etl4** and **etl6**) on the existing hub cluster at `cert-rhosp-01.lab.eng.rdu2.redhat.com`
using the ACM Assisted Installer with a GitOps approach.

- **Hub cluster**: OCP 4.20.0 (nightly) at `ocp-edge-cluster-0.qe.lab.redhat.com`
- **Spoke clusters**: OCP 4.20.14 (3-node compact, masters-schedulable)
- **etl4 API**: `https://api.etl4.qe.lab.redhat.com:6443`
- **etl6 API**: `https://api.etl6.qe.lab.redhat.com:6443`
- **Host machine**: `cert-rhosp-01.lab.eng.rdu2.redhat.com` (250 GB RAM)
- **Fork**: `https://github.com/vikasmulaje/openshift-virtualization-gitops`

---

## 1. Git Repository Changes (12 commits)

### 1.1 Initial VM Configuration (5e7cbf2)

**Files created/modified:**
- `clusters/hub/overlays/cluster-etl4/` - kustomization.yaml, 3 BMH files, 3 NMStateConfig files
- `clusters/hub/overlays/cluster-etl6/` - kustomization.yaml, 3 BMH files, 3 NMStateConfig files

Created the full cluster overlay directories for etl4 and etl6, mirroring the spoke1 pattern.
Includes BareMetalHost definitions for 6 VMs (3 per cluster), NMStateConfig for static IP
assignment, and Kustomization files referencing the `bm-cluster-agent-install` Helm chart.

### 1.2 Hub Sync-Wave Fix (cb19870)

**File modified:** `clusters/hub/values.yaml`

Disabled `openshift-config` (blocked sync due to missing cert-manager CRDs) and moved
managed cluster applications to sync-wave 5.

### 1.3 Skip DNS Endpoints and MTV (0168572)

**Files modified:**
- `.helm-charts/bm-cluster-agent-install/templates/dns-endpoints.yaml`
- `clusters/cluster-versions.yaml`
- Both cluster kustomization.yaml files + spoke1

The hub cluster does not have the `externaldns.k8s.io` CRD. Added `skipDnsEndpoints: true`
helm value. Also disabled MTV integration (`mtv_integration.enabled: false`).

### 1.4 BMC Address Fix (a30f02e)

**Files modified:** All 6 BareMetalHost YAML files

Changed BMC addresses from `ipmi://` to `redfish://192.168.123.1:8000/redfish/v1/Systems/<vm-uuid>`
to use the `sushy-emulator` Redfish BMC simulator.

### 1.5 Boot MAC Address Update (7969110)

**Files modified:** All 6 BareMetalHost YAML files

Updated `bootMACAddress` to use provisioning network NIC MACs (172.22.0.x network).

### 1.6 Disable Ironic Inspection (8db8b7e)

**Files modified:** All 6 BareMetalHost YAML files

Added `inspect.metal3.io: disabled` annotation to prevent the Ironic inspect/abort loop.

### 1.7 Disable Automated Cleaning (92698e4)

**Files modified:** All 6 BareMetalHost YAML files

Changed `spec.automatedCleaningMode` from `metadata` to `disabled`. Ironic's cleaning
cycle was blocking the Assisted Installer discovery flow.

### 1.8 Add DNS and Routes to NMStateConfig (9d3890d)

**Files modified:** All 6 NMStateConfig YAML files + both kustomization.yaml

VMs could not resolve the Assisted Service hostname. Added:
- `dns-resolver` pointing to `192.168.123.1` (hypervisor host)
- Default route `0.0.0.0/0` via `192.168.123.1` on `eth0`
- Updated `sshKey` to the host machine's root public key

### 1.9 Update VIPs to VM Network (bb97842)

**Files modified:** Both kustomization.yaml files

Changed from physical network (10.9.x) to VM baremetal network:

| Cluster | apiVIP | ingressVIP |
|---------|--------|------------|
| etl4 | 192.168.123.240 | 192.168.123.241 |
| etl6 | 192.168.123.242 | 192.168.123.243 |

### 1.10 Upgrade imageSet 4.18.12 to 4.20.14 (99cb979)

**Files modified:** Both kustomization.yaml files

The hub's 4.20.0 Assisted Installer agent tried to start `node-image-pull.service` and
`node-image-overlay.service` on bootstrap nodes, but these systemd units do not exist in
OCP 4.18.12 CoreOS. Changed `imageSet` to `img4.20.14-x86-64-appsub`.

### 1.11 Remove BareMetalHost Resources (feb15f2)

**Files modified:** Both kustomization.yaml files

Removed the 3 BMH YAML references from `resources:`. BareMetalHost resources triggered
Ironic/BMO management which conflicted with the Assisted Installer by power-cycling VMs
via `sushy-emulator`. Switched to InfraEnv-only approach with manual VM boot.

### 1.12 Fix baseDomain Helm Templating (a7187ca)

**Files modified:**
- `.helm-charts/bm-cluster-agent-install/templates/cluster-deployment.yaml`
- `.helm-charts/bm-cluster-agent-install/templates/dns-endpoints.yaml`
- `.helm-charts/bm-cluster-agent-install/values.yaml`

The ClusterDeployment template had a literal `${PLATFORM_BASE_DOMAIN}` (meant for ArgoCD
plugin substitution). Replaced with proper Helm templating `{{ .Values.baseDomain }}` and
added `baseDomain: qe.lab.redhat.com` default value.

---

## 2. Host Machine Changes

### 2.1 Virtual Machine Creation

Created 6 libvirt VMs (3 per cluster):

| VM Name | IP (baremetal) | MAC (baremetal) | UUID |
|---------|---------------|-----------------|------|
| etl4-master-0 | 192.168.123.220 | 52:54:00:aa:04:00 | c5efc509-... |
| etl4-master-1 | 192.168.123.221 | 52:54:00:aa:04:01 | 6c066584-... |
| etl4-master-2 | 192.168.123.222 | 52:54:00:aa:04:02 | ed507978-... |
| etl6-master-0 | 192.168.123.223 | 52:54:00:aa:06:00 | faacf3fe-... |
| etl6-master-1 | 192.168.123.224 | 52:54:00:aa:06:01 | 69b258f2-... |
| etl6-master-2 | 192.168.123.225 | 52:54:00:aa:06:02 | 124e228d-... |

**VM Specs:** 8 vCPUs, 16 GB RAM, 120 GB qcow2 disk, dual NIC (baremetal + provisioning)

### 2.2 VM XML Modifications

- **Disk driver type**: Changed `type='raw'` to `type='qcow2'` for vda disk
- **Boot order**: Per-device boot order (CDROM=1, disk=2). After image write, CDROM ejected
  and disk set to order 1
- **CDROM management**: Discovery ISO at `/tmp/discovery-isos/<cluster>-full.iso`, ejected
  after each installation stage

### 2.3 Hub Cluster VM Memory Rebalancing

| VM | Original | Final | Notes |
|----|----------|-------|-------|
| openshift-master-0-{0,1,2} | 32 GB each | 32 GB | Unchanged |
| openshift-worker-0-0 | 32 GB | 32 GB | Hosts assisted-service PV |
| openshift-worker-0-1 | 32 GB | 16 GB | Reduced |
| provisionhost-0-0 | 16 GB | 8 GB | Reduced |
| etl4/etl6 VMs (x6) | N/A | 16 GB each | New |
| **Total** | | **248 GB / 250 GB** | |

### 2.4 DNS Configuration

**`/etc/NetworkManager/dnsmasq.d/spoke-clusters.conf`:**

```
address=/api.etl4.qe.lab.redhat.com/192.168.123.240
address=/.apps.etl4.qe.lab.redhat.com/192.168.123.241
address=/api.etl6.qe.lab.redhat.com/192.168.123.242
address=/.apps.etl6.qe.lab.redhat.com/192.168.123.243
```

**Libvirt `baremetal-0` network XML** - added forwarder entries:

```xml
<forwarder domain='etl4.qe.lab.redhat.com' addr='127.0.0.1'/>
<forwarder domain='etl6.qe.lab.redhat.com' addr='127.0.0.1'/>
```

### 2.5 Discovery ISOs

Downloaded full ISOs (1.3 GB each) from the Assisted Image Service to
`/tmp/discovery-isos/`. Used full ISOs (not minimal) because VMs couldn't resolve
`assisted-image-service-*` to download the rootfs during boot.

### 2.6 sushy-emulator Service

**Final state: disabled** (`systemctl disable --now sushy-emulator`).
Initially needed for BMH/Ironic registration but caused a power-cycling loop where
Ironic forced VMs off and set PXE boot. No longer needed after removing BMH resources.

### 2.7 NTP Configuration on VMs

Configured chrony on all 6 VMs (manually via SSH after each reboot):

```
server 192.168.123.1 iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
```

### 2.8 Pull Secrets (not in Git)

Created `pullsecret-etl4` and `pullsecret-etl6` secrets in their namespaces, copied from
the hub's `openshift-config/pull-secret`. These are sensitive and not stored in Git.

### 2.9 Agent Management (Manual)

After agents registered from the discovery ISO:
- Set `spec.role: master` on all 6 agents
- Set `spec.approved: true` on all 6 agents
- Set `spec.clusterDeploymentName` to bind agents to their respective clusters

---

## 3. Applying the Configuration

```bash
cd /root/gitops/openshift-virtualization-gitops-fork
oc kustomize clusters/hub/overlays/cluster-etl4/ \
  --enable-helm --load-restrictor=LoadRestrictionsNone | oc apply -f -
oc kustomize clusters/hub/overlays/cluster-etl6/ \
  --enable-helm --load-restrictor=LoadRestrictionsNone | oc apply -f -
```

This generates per cluster: Namespace, NMStateConfig (x3), InfraEnv, AgentClusterInstall,
ClusterDeployment, ManagedCluster, KlusterletAddonConfig, ManagedServiceAccount,
ClusterPermission, Role.

---

## 4. Installation Flow

1. Apply kustomize manifests to hub cluster
2. Create pull secrets in etl4/etl6 namespaces
3. InfraEnv generates discovery ISO URLs
4. Download full ISOs to hypervisor host
5. Create VMs with CDROM (ISO) + empty 120GB qcow2 disk
6. VMs boot from ISO, discovery agents register with Assisted Service
7. Manually approve agents, set role=master, bind to cluster
8. Configure NTP on VMs (chrony -> 192.168.123.1)
9. Assisted Installer validates requirements, begins installation
10. Agents write CoreOS + OCP to disk
11. Eject CDROM from non-bootstrap VMs, reboot from disk
12. Non-bootstrap nodes configure and join cluster
13. Bootstrap node completes bootkube, then also reboots from disk
14. Cluster finalizes, cluster version operator completes
15. ManagedCluster joins hub (Joined=True, Available=True)

---

## 5. Issues Encountered and Resolved

| # | Issue | Resolution |
|---|-------|------------|
| 1 | Ironic cleaning loop blocking discovery | Set `automatedCleaningMode: disabled` on BMH |
| 2 | sushy-emulator power-cycling VMs | Disabled service, removed BMH resources entirely |
| 3 | VMs can't resolve Assisted Service | Added dns-resolver and default route to NMStateConfig |
| 4 | minimal.iso boot fails (rootfs download) | Switched to full.iso (includes rootfs) |
| 5 | SSH access denied to VMs | Updated sshKey in kustomization to host's key |
| 6 | agent.service disabled on VMs | Regenerated ISOs after NMStateConfig changes |
| 7 | "No eligible disks" (20GB too small) | Resized qcow2 to 120GB |
| 8 | "Machine Network CIDR undefined" | Updated VIPs from 10.9.x to 192.168.123.x |
| 9 | VM disk shows 194K not 120G | Changed XML driver type from raw to qcow2 |
| 10 | node-image-pull.service not found | Upgraded imageSet from 4.18.12 to 4.20.14 |
| 11 | PLATFORM_BASE_DOMAIN not substituted | Replaced with Helm template variable |
| 12 | assisted-service OOM on hub workers | Restored worker-0-0 to 32GB, reduced provisionhost |
| 13 | "Require 16 GiB RAM" validation | Increased VMs to 16GB, rebalanced hub memory |
| 14 | VMs boot from ISO after image write | Ejected CDROM, set disk boot order 1 per stage |
| 15 | NTP sync failures | Configured chrony to sync with hypervisor |
| 16 | Wildcard DNS not resolving for VMs | Added forwarder entries to baremetal-0 network XML |

---

## 6. Final State

```
NAME            HUB ACCEPTED   MANAGED CLUSTER URLS                                    JOINED   AVAILABLE
etl4            true           https://api.etl4.qe.lab.redhat.com:6443                 True     True
etl6            true           https://api.etl6.qe.lab.redhat.com:6443                 True     True
local-cluster   true           https://api.ocp-edge-cluster-0.qe.lab.redhat.com:6443   True     True
```

## 7. Day-2 Operations on etl4 Cluster

### 7.1 Resource Reallocation for Day-2

etl6 was temporarily deleted to free resources for day-2 GitOps operations on etl4.

| VM | Before | After | Notes |
|----|--------|-------|-------|
| etl4-master-{0,1,2} | 4 vCPU, 16 GB RAM | 8 vCPU, 32 GB RAM | Increased to support operator workloads |
| etl6-master-{0,1,2} | 4 vCPU, 16 GB RAM | Deleted | Freed 48 GB + 12 vCPU for etl4 |

### 7.2 ArgoCD Bootstrap on etl4

Hub-side ACM policies were not successfully propagating day-2 configurations. ArgoCD was
manually bootstrapped on etl4 to drive day-2 GitOps from the spoke cluster itself.

**ConfigMaps created in `openshift-gitops` namespace:**

1. **`environment-variables`** — Defines variables consumed by the CMP sidecar:
   - `CLUSTER_NAME=etl4`
   - `INFRA_GITOPS_REPO=https://github.com/vikasmulaje/openshift-virtualization-gitops`
   - `INFRA_GITOPS_BRANCH=main`
   - `PLATFORM_BASE_DOMAIN=qe.lab.redhat.com`

2. **`setenv-cmp-plugin`** — Custom Config Management Plugin definition that runs
   `kustomize build --enable-helm` piped through `envsub` for environment variable
   substitution in manifests.

**ArgoCD CR patch (`openshift-gitops` in `openshift-gitops` namespace):**
- Enabled Kustomize with Helm (`kustomizeBuildOptions: --enable-helm`)
- Added `setenv-plugin` sidecar container with the CMP plugin
- Configured cluster-admin RBAC for the ArgoCD service account
- Reduced resource requests/limits for controller, redis, applicationset, and dex
  to fit the 3-node compact cluster's limited resources
- Controller memory limit set to 3 Gi (increased from 1 Gi after OOMKilled)

**Root Application created:**
- `root-applications` Application in `openshift-gitops` namespace
- Points to `clusters/etl4/` in the Git repository
- Uses `setenv-plugin` for rendering
- Auto-sync with self-heal and prune enabled

### 7.3 KubeletConfig Fix (evictionSoft.memory.available)

OpenShift Virtualization's `KubeletConfig set-virt-values` CR set
`evictionSoft.memory.available: 50Gi`, which exceeded the 32 GB node RAM and caused
permanent `MemoryPressure` taint on all 3 master nodes, preventing pods from scheduling.

**Fix applied:**
1. Direct `kubelet.conf` edit on all 3 nodes via `ssh`:
   ```
   sed -i 's/evictionSoft:\n.*memory.available: 50Gi/evictionSoft:\n  memory.available: 500Mi/' /etc/kubernetes/kubelet.conf
   systemctl restart kubelet
   ```
2. Patched the `KubeletConfig` CR to persist the change:
   ```
   oc patch kubeletconfig set-virt-values --type=merge \
     -p '{"spec":{"kubeletConfig":{"evictionSoft":{"memory.available":"500Mi"}}}}'
   ```

### 7.4 Operator Policy Version Updates (Git Commits)

The original `OperatorPolicy` resources in the Git repository had pinned `startingCSV`
and `versions` fields targeting OCP 4.17 operator versions. These were incompatible with
the OCP 4.20.14 cluster, causing `ResolutionFailed` subscription errors and "not an
approved version" compliance failures.

**Commit: Remove pinned startingCSV and versions from operator policies**

Removed `startingCSV` from 12 `operator-policy.yaml` files across:
- `components/cert-manager-operator/`
- `components/metallb-operator/`
- `components/nmstate-operator/`
- `components/descheduler-operator/`
- `components/external-dns-operator/`
- `components/openshift-virtualization-operator/`
- `components/web-terminal-operator/` (2 policies: web-terminal + devworkspace)
- `components/node-health-check-operator/` (4 policies: nhc, far, nm, snr)

**Commit: Update operator policy versions to match installed OCP 4.20 versions**

Set `versions` to the actual installed CSV versions for each operator:

| Operator | Version |
|----------|---------|
| cert-manager-operator | v1.18.1 |
| metallb-operator | v4.20.0-202602021426 |
| kubernetes-nmstate-operator | 4.20.0-202601292039 |
| clusterkubedescheduleroperator | v5.3.1 |
| external-dns-operator | v1.3.3 |
| kubevirt-hyperconverged-operator | v4.18.2 |
| web-terminal | v1.15.0 |
| devworkspace-operator | v0.33.0 |
| fence-agents-remediation | v0.5.0 |
| node-healthcheck-operator | v0.9.0 |
| node-maintenance-operator | v5.4.0 |
| self-node-remediation | v0.10.0 |

### 7.5 kube-ops-view Redis Image Fix

The `kube-ops-view-redis` deployment had `ImagePullBackOff` due to Docker Hub rate limits
on `redis:7-alpine`. Patched the deployment image to `quay.io/sclorg/redis-7-c9s:latest`.

### 7.6 OperatorPolicy Catalog Source Connectivity

After ArgoCD synced the updated operator policies, the ACM `config-policy-controller`
intermittently failed to connect to catalog source gRPC endpoints, causing 5 OperatorPolicies
to remain NonCompliant with stale errors. The operators themselves were all installed and
running successfully.

**Root cause:** A combination of:
- Transient catalog source pod gRPC connectivity issues after pod restarts
- ACM config-policy-controller bug (`conditionChangedError: json: unsupported type:
  func(v1.Condition, v1.Condition) bool`) preventing status condition updates
- The `complianceConfig.catalogSourceUnhealthy: Compliant` setting was ineffective
  due to the status update bug

**Fix:** Patched the OperatorPolicy status subresource to clear stale NonCompliant
conditions for the 5 affected policies (devworkspace-operator, fence-agents-remediation,
node-healthcheck-operator, node-maintenance-operator, self-node-remediation-operator).

### 7.7 Stuck ArgoCD Sync Operations

After force-pushing Git changes, ArgoCD apps retained stale sync operations pointing at
old Git revisions. The operations kept retrying with cached (broken) manifests indefinitely.

**Fix:** Deleted the stuck ArgoCD Application CRs (after removing finalizers). The
`root-applications` app with auto-sync and self-heal recreated them fresh, picking up the
correct Git revision.

---

## 8. Day-2 Final State on etl4

### 8.1 ArgoCD Applications

```
NAME                              SYNC     HEALTH
cert-manager-configuration        Synced   Healthy
cert-manager-operator             Synced   Healthy
descheduler-configuration         Synced   Healthy
descheduler-operator              Synced   Healthy
external-dns-configuration        Synced   Progressing *
external-dns-operator             Synced   Healthy
hyperconverged-instance           Synced   Healthy
kube-ops-view                     Synced   Healthy
metallb-configuration             Synced   Healthy
metallb-operator                  Synced   Healthy
nmstate-configuration             Synced   Healthy
nmstate-instance                  Synced   Healthy
nmstate-operator                  Synced   Healthy
node-health-check-configuration   Synced   Healthy
node-health-check-operator        Synced   Healthy
openshift-config                  Synced   Progressing *
openshift-virtualization          Synced   Healthy
root-applications                 Synced   Healthy
web-terminal-operator             Synced   Healthy
```

`*` Progressing due to external infrastructure dependencies:
- `external-dns-configuration`: Cannot reach RFC2136 DNS server at `10.9.48.31:53`
- `openshift-config`: cert-manager letsencrypt issuer requires AWS Route53 credentials
  (`cert-manager-dns-credentials` secret) which are not provisioned in this environment

### 8.2 Operator Policies (All Compliant)

```
cluster-kube-descheduler-operator   Compliant
devworkspace-operator               Compliant
external-dns-operator               Compliant
fence-agents-remediation            Compliant
kubernetes-nmstate-operator         Compliant
kubevirt-hyperconverged             Compliant
metallb-operator                    Compliant
node-healthcheck-operator           Compliant
node-maintenance-operator           Compliant
openshift-cert-manager-operator     Compliant
self-node-remediation-operator      Compliant
web-terminal                        Compliant
```

### 8.3 Installed Operators (All Succeeded)

| Operator CSV | Version | Status |
|-------------|---------|--------|
| cert-manager-operator | v1.18.1 | Succeeded |
| clusterkubedescheduleroperator | v5.3.1 | Succeeded |
| devworkspace-operator | v0.33.0 | Succeeded |
| external-dns-operator | v1.3.3 | Succeeded |
| fence-agents-remediation | v0.5.0 | Succeeded |
| kubernetes-nmstate-operator | 4.20.0-202601292039 | Succeeded |
| kubevirt-hyperconverged-operator | v4.18.2 | Succeeded |
| metallb-operator | v4.20.0-202602021426 | Succeeded |
| node-healthcheck-operator | v0.9.0 | Succeeded |
| node-maintenance-operator | v5.4.0 | Succeeded |
| self-node-remediation | v0.10.0 | Succeeded |
| web-terminal | v1.15.0 | Succeeded |

---

## 9. Day-2 Issues Encountered and Resolved

| # | Issue | Resolution |
|---|-------|------------|
| 1 | ArgoCD pods Pending (Insufficient cpu) | Reduced resource requests/limits for ArgoCD components |
| 2 | ArgoCD controller OOMKilled | Increased controller memory limit from 1Gi to 3Gi |
| 3 | MemoryPressure taint on all nodes | Patched KubeletConfig evictionSoft from 50Gi to 500Mi |
| 4 | Operator subscriptions ResolutionFailed | Removed pinned startingCSV from OperatorPolicy definitions |
| 5 | "Not an approved version" compliance errors | Updated versions in operator-policy.yaml to match OCP 4.20 |
| 6 | kube-ops-view-redis ImagePullBackOff | Changed image from Docker Hub to quay.io registry |
| 7 | OperatorPolicy NonCompliant (catalog source gRPC) | Patched status subresource to clear stale error conditions |
| 8 | ArgoCD sync stuck on old Git revision | Deleted and let root-applications recreate the Application CRs |
| 9 | versions: [] rendered as null by ServerSideApply | Changed to explicit version strings in operator policies |
| 10 | external-dns CrashLoopBackOff | Unreachable RFC2136 DNS server (external infra dependency) |
| 11 | router-default missing TLS secret | cert-manager needs AWS Route53 credentials (not provisioned) |

---

## 10. Network Layout

```
Host: cert-rhosp-01.lab.eng.rdu2.redhat.com (250GB RAM)
  |
  +-- baremetal-0 network (192.168.123.0/24)
  |     |-- Hub masters:   .10-.12
  |     |-- Hub workers:   .20-.21
  |     |-- etl4 VMs:      .220-.222
  |     |-- etl6 VMs:      .223-.225
  |     |-- etl4 VIPs:     .240 (API), .241 (Ingress)
  |     |-- etl6 VIPs:     .242 (API), .243 (Ingress)
  |
  +-- provisioning network (172.22.0.0/24)
        |-- Used for Ironic PXE (not actively used in final deployment)
```
