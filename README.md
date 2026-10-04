# k8s-upgrade-check

A single Bash script that audits any Kubernetes cluster and produces a compact, dark-themed HTML readiness report before you upgrade.

```
./k8s-upgrade-check.sh <target_version>
```

---

## What it checks

| Check | What is caught |
|---|---|
| **Version skew** | `kubectl` client too far from server (supported ±1 minor) |
| **Node health** | `NotReady` nodes, kubelet version lag behind API server |
| **Resource pressure** | CPU / Memory % — eviction risk during node drain |
| **Deprecated APIs** | `policy/v1beta1`, `batch/v1beta1`, `autoscaling/v2beta2`, etc. |
| **Admission webhooks** | `Fail`-policy webhooks that block deployments |
| **Stuck pods** | `ImagePullBackOff`, `CrashLoopBackOff` across all namespaces |
| **CRD storage versions** | Beta storage versions that break object deserialization |
| **PodSecurityPolicy** | Detects PSP still in use (removed in K8s 1.25) |
| **Platform availability** | IKS: confirms target version is published on the platform |

### Scoring

| Score | Decision |
|---|---|
| 90 – 100 | ✅ **APPROVED** |
| 75 – 89 | 🟡 **CONDITIONAL** |
| 50 – 74 | 🔶 **HIGH RISK** |
| 0 – 49 | 🔴 **NOT RECOMMENDED** |

Each Critical issue deducts 25 pts · High deducts 10 pts · Warning deducts 3 pts.

---

## Requirements

- `bash` 4+
- `kubectl` configured and pointing at the target cluster
- `python3` (standard on macOS / most Linux distros — used for JSON parsing)
- Platform CLI — only needed for the platform-specific availability check:
  - **IKS** → `ibmcloud` CLI with `ks` plugin
  - **EKS** → `aws` CLI
  - **AKS** → `az` CLI

---

## Quick start

```bash
# Clone or copy the script
git clone <this-repo>
cd k8s-upgrade-check

chmod +x k8s-upgrade-check.sh

# Point kubectl at your cluster, then run:
./k8s-upgrade-check.sh 1.37
```

The script prints live results to the terminal and writes a timestamped HTML report:

```
k8s-upgrade-report-20260110-142530.html
```

The report opens automatically in your default browser on macOS and Linux (via `open` / `xdg-open`).

---

## Platform guides

### IBM Kubernetes Service (IKS)

**1. Log in and target your cluster**

```bash
ibmcloud login --sso
ibmcloud ks init
ibmcloud ks cluster config --cluster <CLUSTER_NAME_OR_ID>
```

**2. Confirm the target version is available on IKS**

```bash
ibmcloud ks versions
```

Only proceed if your target version appears in the output. IBM controls release cadence — versions are typically available 2–4 weeks after upstream.

**3. Run the assessment**

```bash
./k8s-upgrade-check.sh 1.37
```

The script automatically detects IKS (via the `+IKS` suffix in the node version string) and calls `ibmcloud ks versions` to verify platform availability.

**4. Upgrade (after all checks pass)**

```bash
# Upgrade control plane
ibmcloud ks cluster master update --cluster <CLUSTER_ID> --version 1.37

# Then upgrade worker nodes
ibmcloud ks worker update --cluster <CLUSTER_ID> --worker all
```

> **IKS note:** Calico, CoreDNS, Konnectivity, ALB, and VPC CSI are IBM-managed add-ons. IBM upgrades them automatically alongside the cluster — no manual intervention needed.

---

### Amazon Elastic Kubernetes Service (EKS)

**1. Log in and target your cluster**

```bash
aws configure          # or: export AWS_PROFILE=<profile>

aws eks update-kubeconfig \
  --region <REGION> \
  --name <CLUSTER_NAME>
```

**2. Confirm the target version is available on EKS**

```bash
aws eks describe-addon-versions \
  --kubernetes-version <TARGET> \
  --query 'addons[0].addonVersions[0]' 2>/dev/null || true

# List supported K8s versions:
aws eks describe-cluster \
  --name <CLUSTER_NAME> \
  --query 'cluster.version'
```

**3. Run the assessment**

```bash
./k8s-upgrade-check.sh 1.32
```

**4. Key EKS pre-upgrade steps**

```bash
# Update aws-node (VPC CNI) before upgrading
aws eks update-addon \
  --cluster-name <CLUSTER_NAME> \
  --addon-name vpc-cni \
  --resolve-conflicts OVERWRITE

# Update kube-proxy and CoreDNS
aws eks update-addon --cluster-name <CLUSTER_NAME> --addon-name kube-proxy
aws eks update-addon --cluster-name <CLUSTER_NAME> --addon-name coredns
```

**5. Upgrade (after all checks pass)**

```bash
# Upgrade control plane
aws eks update-cluster-version \
  --name <CLUSTER_NAME> \
  --kubernetes-version <TARGET>

# Watch progress
aws eks describe-cluster \
  --name <CLUSTER_NAME> \
  --query 'cluster.status'

# Upgrade managed node groups
aws eks update-nodegroup-version \
  --cluster-name <CLUSTER_NAME> \
  --nodegroup-name <NODEGROUP_NAME> \
  --kubernetes-version <TARGET>
```

> **EKS note:** EKS only supports upgrading **one minor version at a time** (e.g. 1.29 → 1.30, not 1.29 → 1.31). Run the script for each hop.

---

### Azure Kubernetes Service (AKS)

**1. Log in and target your cluster**

```bash
az login

az aks get-credentials \
  --resource-group <RESOURCE_GROUP> \
  --name <CLUSTER_NAME> \
  --overwrite-existing
```

**2. Confirm the target version is available on AKS**

```bash
az aks get-upgrades \
  --resource-group <RESOURCE_GROUP> \
  --name <CLUSTER_NAME> \
  --output table
```

This shows exactly which versions your cluster can upgrade to right now.

**3. Run the assessment**

```bash
./k8s-upgrade-check.sh 1.32
```

**4. Upgrade (after all checks pass)**

```bash
# Upgrade control plane only first
az aks upgrade \
  --resource-group <RESOURCE_GROUP> \
  --name <CLUSTER_NAME> \
  --kubernetes-version <TARGET> \
  --control-plane-only

# Then upgrade each node pool
az aks nodepool upgrade \
  --resource-group <RESOURCE_GROUP> \
  --cluster-name <CLUSTER_NAME> \
  --name <NODEPOOL_NAME> \
  --kubernetes-version <TARGET>
```

> **AKS note:** AKS also only supports **one minor version at a time**. Use `az aks get-upgrades` to get the exact allowed target versions — attempting an unsupported hop will fail.

---

## Multi-hop upgrades

EKS and AKS require upgrading one minor version at a time. Run the script at each hop:

```bash
# Example: 1.29 → 1.32 on EKS or AKS
./k8s-upgrade-check.sh 1.30   # fix any issues, upgrade to 1.30
./k8s-upgrade-check.sh 1.31   # fix any issues, upgrade to 1.31
./k8s-upgrade-check.sh 1.32   # fix any issues, upgrade to 1.32
```

IKS supports multi-minor upgrades but running the script at each hop is still recommended.

---

## Output files

| File | Description |
|---|---|
| `k8s-upgrade-report-<timestamp>.html` | Self-contained HTML report — shareable, no dependencies |

Reports are written to the current working directory. Each run produces a new timestamped file so previous reports are preserved.

---

## Extending the script

The script is structured around simple functions. To add a new check:

```bash
# 1. Add your check block (anywhere after the setup section)
log "Checking my custom thing..."
if <condition>; then
  add_issue "MY CHECK" "Short title" "Detail and remediation steps"
  fail "message for terminal"
else
  add_pass "My Check" "All good"
  ok "My check passed"
fi
```

Severity helpers:
- `add_issue` → **Critical** (−25 pts)
- `add_high` → **High** (−10 pts)
- `add_warn` → **Warning** (−3 pts)
- `add_pass` → **Passed** (no deduction)

---

## Files

```
k8s-upgrade-check.sh          # main script
README.md                     # this file
k8s-upgrade-report-*.html     # generated reports (gitignored)
```

---

<img width="720" height="879" alt="Screenshot 2026-10-04 at 10 51 16 PM" src="https://github.com/user-attachments/assets/99d84aa6-ae05-4944-9a48-d8e63bbe6d22" />

<img width="1044" height="1024" alt="K8s AI cluster upgrade" src="https://github.com/user-attachments/assets/c2f32886-aa8e-448a-a096-076bc401fc9c" />


