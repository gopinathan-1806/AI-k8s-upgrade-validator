#!/usr/bin/env bash
# =============================================================================
#  k8s-upgrade-check.sh
#  Kubernetes Upgrade Readiness Assessment
#  Usage: ./k8s-upgrade-check.sh <target_version>
#  Example: ./k8s-upgrade-check.sh 1.37
# =============================================================================
set -euo pipefail

TARGET_VERSION="${1:-}"
if [[ -z "$TARGET_VERSION" ]]; then
  echo "Usage: $0 <target_version>  (e.g. $0 1.37)"
  exit 1
fi

REPORT_FILE="k8s-upgrade-report-$(date +%Y%m%d-%H%M%S).html"
ISSUES=()      # "CRITICAL|title|detail"
HIGH=()
WARNINGS=()
PASSES=()

# ── colours for terminal ─────────────────────────────────────────────────────
RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'
BLU='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${BLU}▶${NC} $*"; }
ok()   { echo -e "${GRN}✔${NC} $*"; }
warn() { echo -e "${YEL}⚠${NC} $*"; }
fail() { echo -e "${RED}✖${NC} $*"; }

# ── helpers ──────────────────────────────────────────────────────────────────
add_issue()   { ISSUES+=("$1|$2|$3"); }
add_high()    { HIGH+=("$1|$2|$3"); }
add_warn()    { WARNINGS+=("$1|$2|$3"); }
add_pass()    { PASSES+=("$1|$2"); }

kubectl_safe() { kubectl "$@" 2>/dev/null || true; }

# ── json helpers ─────────────────────────────────────────────────────────────
jq_installed() { command -v jq &>/dev/null; }

# =============================================================================
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Kubernetes Upgrade Readiness Assessment            ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

# ── STEP 1: Cluster Info ─────────────────────────────────────────────────────
log "Collecting cluster information..."

SERVER_VERSION=$(kubectl version -o json 2>/dev/null | python3 -c "import sys,json; v=json.load(sys.stdin)['serverVersion']; print(v['major']+'.'+v['minor'].rstrip('+IKS').rstrip('+'))" 2>/dev/null || kubectl version --short 2>/dev/null | grep Server | awk '{print $3}' | tr -d 'v+IKS' || echo "unknown")
CLIENT_VERSION=$(kubectl version -o json 2>/dev/null | python3 -c "import sys,json; v=json.load(sys.stdin)['clientVersion']; print(v['major']+'.'+v['minor'])" 2>/dev/null || echo "unknown")
RAW_SERVER=$(kubectl version 2>/dev/null | grep "Server Version" | awk '{print $3}' || echo "unknown")
RAW_CLIENT=$(kubectl version 2>/dev/null | grep "Client Version" | awk '{print $3}' || echo "unknown")

PLATFORM=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' 2>/dev/null || echo "unknown")
IS_IKS=false; [[ "$PLATFORM" == *"IKS"* ]] && IS_IKS=true

NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
NODES_READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo "0")
OS_IMAGE=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.osImage}' 2>/dev/null || echo "unknown")
RUNTIME=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.containerRuntimeVersion}' 2>/dev/null || echo "unknown")
NS_COUNT=$(kubectl get ns --no-headers 2>/dev/null | wc -l | tr -d ' ')
CRD_COUNT=$(kubectl get crd --no-headers 2>/dev/null | wc -l | tr -d ' ')

ok "Server: $RAW_SERVER  |  Client: $RAW_CLIENT  |  Nodes: $NODE_COUNT  |  CRDs: $CRD_COUNT"

# ── STEP 2: Version Skew ─────────────────────────────────────────────────────
log "Checking version skew..."

SERVER_MINOR=$(echo "$RAW_SERVER" | sed 's/v//' | cut -d. -f2 | tr -d '+IKS')
CLIENT_MINOR=$(echo "$RAW_CLIENT" | sed 's/v//' | cut -d. -f2 | tr -d '+IKS')
NODE_VERSION=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' 2>/dev/null | sed 's/v//' | cut -d. -f2 | tr -d '+IKS')
SKEW=$(( CLIENT_MINOR - SERVER_MINOR )); SKEW=${SKEW#-}
NODE_SKEW=$(( SERVER_MINOR - NODE_VERSION )); NODE_SKEW=${NODE_SKEW#-}

if [[ "$SKEW" -gt 1 ]]; then
  add_high "VERSION SKEW" "kubectl client is $SKEW minor versions from server" \
    "Client: $RAW_CLIENT | Server: $RAW_SERVER. Supported skew is ±1. Upgrade kubectl to v${TARGET_VERSION}.x"
  warn "kubectl skew: $SKEW minor versions (exceeds ±1)"
else
  add_pass "Version Skew" "kubectl skew within supported range (${SKEW} minor)"
  ok "kubectl skew OK ($SKEW)"
fi

if [[ "$NODE_SKEW" -gt 0 ]]; then
  add_high "NODE VERSION LAG" "Worker nodes are behind the API server" \
    "Node kubelet version is behind API server. Run: ibmcloud ks worker update (IKS) or kubeadm upgrade node"
  warn "Nodes behind API server by $NODE_SKEW patch/minor versions"
else
  add_pass "Node Versions" "Nodes at same version as API server"
  ok "Node versions aligned"
fi

# ── STEP 3: Node Health ───────────────────────────────────────────────────────
log "Checking node health..."

NOT_READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -c "NotReady" || true); NOT_READY=${NOT_READY:-0}
TAINTED=$(kubectl get nodes -o jsonpath='{range .items[?(@.spec.taints)]}{.metadata.name}{"\n"}{end}' 2>/dev/null | wc -l | tr -d ' ')

if [[ "$NOT_READY" -gt 0 ]]; then
  add_issue "NODES NOT READY" "$NOT_READY node(s) are not Ready" \
    "Upgrade cannot proceed safely with unhealthy nodes. Fix node issues first."
  fail "$NOT_READY nodes NOT READY"
else
  add_pass "Node Health" "All $NODE_COUNT nodes are Ready"
  ok "All $NODE_COUNT nodes Ready"
fi

# ── STEP 4: Resource Pressure ─────────────────────────────────────────────────
log "Checking resource pressure..."

MAX_CPU_PCT=0; MAX_MEM_PCT=0
while IFS= read -r line; do
  CPU=$(echo "$line" | awk '{print $3}' | tr -d '%')
  MEM=$(echo "$line" | awk '{print $5}' | tr -d '%')
  [[ "$CPU" =~ ^[0-9]+$ ]] && [[ "$CPU" -gt "$MAX_CPU_PCT" ]] && MAX_CPU_PCT=$CPU
  [[ "$MEM" =~ ^[0-9]+$ ]] && [[ "$MEM" -gt "$MAX_MEM_PCT" ]] && MAX_MEM_PCT=$MEM
done < <(kubectl top nodes 2>/dev/null | tail -n +2 || echo "")

if [[ "$MAX_MEM_PCT" -gt 80 ]]; then
  add_issue "MEMORY PRESSURE" "Max node memory at ${MAX_MEM_PCT}%" \
    "High memory usage risks OOMKills during upgrade drain. Scale down non-critical workloads first."
  fail "Memory pressure: ${MAX_MEM_PCT}%"
elif [[ "$MAX_MEM_PCT" -gt 60 ]]; then
  add_warn "MEMORY" "Node memory at ${MAX_MEM_PCT}% — monitor during upgrade" \
    "Memory usage is elevated. Watch for OOMKills during node drain."
  warn "Memory at ${MAX_MEM_PCT}%"
else
  add_pass "Resource Pressure" "CPU max ${MAX_CPU_PCT}%, Memory max ${MAX_MEM_PCT}% — healthy"
  ok "Resources: CPU ${MAX_CPU_PCT}%  Memory ${MAX_MEM_PCT}%"
fi

# ── STEP 5: Deprecated / Removed API Check ────────────────────────────────────
log "Scanning for deprecated/removed APIs..."

DEPRECATED_APIS=(
  "policy/v1beta1"
  "batch/v1beta1"
  "autoscaling/v2beta2"
  "autoscaling/v2beta1"
  "networking.k8s.io/v1beta1"
  "admissionregistration.k8s.io/v1beta1"
  "flowcontrol.apiserver.k8s.io/v1beta3"
  "flowcontrol.apiserver.k8s.io/v1beta2"
  "extensions/v1beta1"
  "rbac.authorization.k8s.io/v1alpha1"
)

API_VERSIONS_IN_USE=$(kubectl api-versions 2>/dev/null || echo "")
DEPRECATED_FOUND=()
for api in "${DEPRECATED_APIS[@]}"; do
  if echo "$API_VERSIONS_IN_USE" | grep -q "^${api}$"; then
    DEPRECATED_FOUND+=("$api")
  fi
done

if [[ ${#DEPRECATED_FOUND[@]} -gt 0 ]]; then
  FOUND_LIST=$(IFS=', '; echo "${DEPRECATED_FOUND[*]}")
  add_issue "DEPRECATED APIs" "Deprecated APIs still served: $FOUND_LIST" \
    "These APIs may be removed in target version. Migrate all resources to stable API versions before upgrade."
  fail "Deprecated APIs in use: $FOUND_LIST"
else
  add_pass "API Versions" "No deprecated/removed APIs detected in active use"
  ok "API versions clean — only stable APIs served"
fi

# ── STEP 6: Admission Webhooks ────────────────────────────────────────────────
log "Checking admission webhooks..."

VALIDATING=$(kubectl get validatingwebhookconfigurations --no-headers 2>/dev/null | wc -l | tr -d ' ')
MUTATING=$(kubectl get mutatingwebhookconfigurations --no-headers 2>/dev/null | wc -l | tr -d ' ')
TOTAL_WEBHOOKS=$(( VALIDATING + MUTATING ))

if [[ "$TOTAL_WEBHOOKS" -gt 0 ]]; then
  # Check for Fail policy webhooks
  FAIL_POLICY=$(kubectl get validatingwebhookconfigurations -o json 2>/dev/null | \
    python3 -c "import sys,json; d=json.load(sys.stdin); hooks=[w['name'] for cfg in d['items'] for w in cfg.get('webhooks',[]) if w.get('failurePolicy')=='Fail']; print('\n'.join(hooks))" 2>/dev/null || echo "")
  if [[ -n "$FAIL_POLICY" ]]; then
    add_high "WEBHOOKS (Fail policy)" "$VALIDATING validating + $MUTATING mutating webhooks — some set to Fail" \
      "Webhooks with failurePolicy:Fail will block deployments if the webhook service is unreachable post-upgrade. Verify all webhook services are healthy."
    warn "$TOTAL_WEBHOOKS webhooks — some with failurePolicy:Fail"
  else
    add_warn "WEBHOOKS" "$VALIDATING validating + $MUTATING mutating webhooks registered" \
      "Webhook services must remain reachable during and after upgrade. Verify TLS certs are valid."
    warn "$TOTAL_WEBHOOKS webhooks registered — verify availability"
  fi
else
  add_pass "Admission Webhooks" "No webhooks registered — zero webhook failure risk"
  ok "No admission webhooks"
fi

# ── STEP 7: Stuck / Failed Workloads ─────────────────────────────────────────
log "Scanning for stuck or failing workloads..."

IMAGEPULL=$(kubectl get pods -A --no-headers 2>/dev/null | grep -c "ImagePullBackOff\|ErrImagePull" || true); IMAGEPULL=${IMAGEPULL:-0}
CRASHLOOP=$(kubectl get pods -A --no-headers 2>/dev/null | grep -c "CrashLoopBackOff" || true); CRASHLOOP=${CRASHLOOP:-0}
PENDING=$(kubectl get pods -A --no-headers 2>/dev/null | grep -c "Pending" || true); PENDING=${PENDING:-0}
FAILED=$(kubectl get pods -A --no-headers 2>/dev/null | grep -c "Failed" || true); FAILED=${FAILED:-0}

if [[ "$IMAGEPULL" -gt 0 ]]; then
  PULL_PODS=$(kubectl get pods -A --no-headers 2>/dev/null | grep "ImagePullBackOff\|ErrImagePull" | awk '{print $1"/"$2}' | tr '\n' ' ')
  add_issue "IMAGE PULL FAILURES" "$IMAGEPULL pod(s) in ImagePullBackOff" \
    "Pods: $PULL_PODS — Fix image registry access before upgrade. These pods will not recover post-upgrade."
  fail "$IMAGEPULL pod(s) ImagePullBackOff: $PULL_PODS"
fi
if [[ "$CRASHLOOP" -gt 0 ]]; then
  add_high "CRASHLOOP PODS" "$CRASHLOOP pod(s) in CrashLoopBackOff" \
    "Crashing pods will persist post-upgrade. Investigate and fix before upgrade."
  warn "$CRASHLOOP pod(s) CrashLoopBackOff"
fi
if [[ "$IMAGEPULL" -eq 0 && "$CRASHLOOP" -eq 0 ]]; then
  add_pass "Workload Health" "No ImagePullBackOff or CrashLoopBackOff pods"
  ok "All pods healthy (no crash/pull failures)"
fi

# ── STEP 8: CRD Storage Versions ─────────────────────────────────────────────
log "Checking CRD storage versions..."

BETA_STORAGE=$(kubectl get crds -o json 2>/dev/null | \
  python3 -c "
import sys, json
d = json.load(sys.stdin)
bad = []
for crd in d['items']:
  name = crd['metadata']['name']
  for v in crd['spec'].get('versions', []):
    if v.get('storage') and 'beta' in v.get('name','').lower():
      bad.append(name + ' (' + v['name'] + ')')
print('\n'.join(bad))
" 2>/dev/null || echo "")

if [[ -n "$BETA_STORAGE" ]]; then
  COUNT=$(echo "$BETA_STORAGE" | wc -l | tr -d ' ')
  add_high "CRD BETA STORAGE" "$COUNT CRD(s) using beta storage version" \
    "$BETA_STORAGE — Objects stored in beta versions may fail to deserialize post-upgrade. Run CRD migration."
  warn "$COUNT CRDs with beta storage version"
else
  add_pass "CRD Storage Versions" "All CRDs use stable (v1) storage versions"
  ok "CRD storage versions — all stable"
fi

# ── STEP 9: PodSecurityPolicy ─────────────────────────────────────────────────
log "Checking PodSecurityPolicy (removed in 1.25)..."

PSP_CHECK=$(kubectl get psp 2>&1 || true)
if echo "$PSP_CHECK" | grep -q "No resources found"; then
  add_pass "PodSecurityPolicy" "PSP resources exist but are empty"
  ok "PSP: no policies in use"
elif echo "$PSP_CHECK" | grep -q "doesn't have a resource type"; then
  add_pass "PodSecurityPolicy" "PSP API removed — already clean"
  ok "PSP API removed (cluster is on 1.25+)"
else
  add_issue "POD SECURITY POLICY" "PodSecurityPolicies still present" \
    "PSP was removed in K8s 1.25. Migrate to Pod Security Admission (PSA) labels immediately."
  fail "PodSecurityPolicies still in use!"
fi

# ── STEP 10: IKS-specific checks ─────────────────────────────────────────────
if $IS_IKS; then
  log "Running IKS-specific checks..."

  IKS_VERSIONS=$(ibmcloud ks versions 2>/dev/null | grep "^${TARGET_VERSION}" || echo "")
  if [[ -z "$IKS_VERSIONS" ]]; then
    add_issue "IKS VERSION NOT AVAILABLE" "v${TARGET_VERSION} not found in ibmcloud ks versions" \
      "Run: ibmcloud ks versions — IBM controls version availability. Wait for IKS to publish v${TARGET_VERSION}."
    fail "IKS v${TARGET_VERSION} not yet available on platform"
  else
    add_pass "IKS Version Availability" "v${TARGET_VERSION} is available on IBM IKS"
    ok "IKS v${TARGET_VERSION} is available"
  fi
fi

# ── SCORE CALCULATION ─────────────────────────────────────────────────────────
CRITICAL_COUNT=${#ISSUES[@]}
HIGH_COUNT=${#HIGH[@]}
WARN_COUNT=${#WARNINGS[@]}
PASS_COUNT=${#PASSES[@]}

SCORE=100
SCORE=$(( SCORE - CRITICAL_COUNT * 25 ))
SCORE=$(( SCORE - HIGH_COUNT * 10 ))
SCORE=$(( SCORE - WARN_COUNT * 3 ))
[[ $SCORE -lt 0 ]] && SCORE=0

if [[ $SCORE -ge 90 ]]; then
  DECISION="APPROVED"; DECISION_COLOR="#16a34a"
elif [[ $SCORE -ge 75 ]]; then
  DECISION="CONDITIONAL"; DECISION_COLOR="#d97706"
elif [[ $SCORE -ge 50 ]]; then
  DECISION="HIGH RISK"; DECISION_COLOR="#ea580c"
else
  DECISION="NOT RECOMMENDED"; DECISION_COLOR="#b91c1c"
fi

echo ""
echo -e "${BOLD}────────────────────────────────────────────────────────${NC}"
echo -e "  Decision:  ${BOLD}$DECISION${NC}   Score: ${BOLD}$SCORE/100${NC}"
echo -e "  Critical: ${RED}$CRITICAL_COUNT${NC}  High: ${YEL}$HIGH_COUNT${NC}  Warnings: ${YEL}$WARN_COUNT${NC}  Passed: ${GRN}$PASS_COUNT${NC}"
echo -e "${BOLD}────────────────────────────────────────────────────────${NC}"
echo ""

# =============================================================================
# HTML REPORT GENERATION
# =============================================================================
log "Generating HTML report → $REPORT_FILE"

# Build issue rows JSON-like strings for embedding in HTML
build_issues_html() {
  local arr_name="$1"
  local color="$2"
  local label="$3"
  local html=""
  eval "local items=(\"\${${arr_name}[@]}\")"
  for item in "${items[@]}"; do
    IFS='|' read -r sev title detail <<< "$item"
    html+="<div class='card ${color}'>"
    html+="<div class='card-head'><span class='badge b-${color}'>${label}</span><span class='card-title'>${title}</span></div>"
    html+="<div class='card-body'>${detail}</div>"
    html+="</div>"
  done
  echo "$html"
}

build_pass_html() {
  local html=""
  for item in "${PASSES[@]}"; do
    IFS='|' read -r title detail <<< "$item"
    html+="<div class='pass-row'><span class='pass-icon'>✓</span><div><strong>${title}</strong> — ${detail}</div></div>"
  done
  echo "$html"
}

ISSUES_HTML=$(build_issues_html "ISSUES" "crit" "CRITICAL")
HIGH_HTML=$(build_issues_html "HIGH" "high" "HIGH")
WARN_HTML=$(build_issues_html "WARNINGS" "warn" "WARNING")
PASS_HTML=$(build_pass_html)

# Score ring fill (stroke-dashoffset: circumference*(1-score/100), circ=283)
RING_OFFSET=$(python3 -c "print(round(283*(1-${SCORE}/100)))" 2>/dev/null || echo "85")

cat > "$REPORT_FILE" << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>K8s Upgrade Report — ${RAW_SERVER} → v${TARGET_VERSION}</title>
<style>
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,"Segoe UI",system-ui,sans-serif;background:#0f1117;color:#e2e8f0;font-size:14px;line-height:1.6}
a{color:#60a5fa}
.wrap{max-width:860px;margin:0 auto;padding:32px 20px 60px}

/* ── Header ── */
.hdr{display:flex;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:16px;margin-bottom:28px}
.hdr-left h1{font-size:18px;font-weight:700;color:#f1f5f9}
.hdr-left p{font-size:12px;color:#64748b;margin-top:3px}
.ver-pill{display:inline-flex;align-items:center;gap:8px;background:#1e293b;border:1px solid #334155;border-radius:20px;padding:6px 14px;font-size:13px;font-weight:600}
.ver-pill .arrow{color:#475569}
.ver-from{color:#94a3b8}
.ver-to{color:#38bdf8}

/* ── Score + Decision row ── */
.top-row{display:grid;grid-template-columns:auto 1fr auto auto;gap:16px;align-items:center;background:#1e293b;border:1px solid #334155;border-radius:12px;padding:20px 24px;margin-bottom:20px}
.ring-wrap{position:relative;width:80px;height:80px}
.ring-wrap svg{transform:rotate(-90deg)}
.ring-bg{fill:none;stroke:#334155;stroke-width:8}
.ring-fg{fill:none;stroke-width:8;stroke-linecap:round;stroke-dasharray:283;stroke-dashoffset:${RING_OFFSET};transition:stroke-dashoffset 1s ease}
.ring-label{position:absolute;top:50%;left:50%;transform:translate(-50%,-50%);text-align:center}
.ring-label .num{font-size:20px;font-weight:800;line-height:1}
.ring-label .den{font-size:10px;color:#64748b}
.decision-box{text-align:center}
.decision-text{font-size:22px;font-weight:800;letter-spacing:-0.5px}
.decision-sub{font-size:11px;color:#64748b;margin-top:2px}
.stat-box{text-align:center;min-width:52px}
.stat-num{font-size:24px;font-weight:800;line-height:1}
.stat-lbl{font-size:10px;color:#64748b;text-transform:uppercase;letter-spacing:.5px;margin-top:2px}

/* ── Cluster info strip ── */
.info-strip{display:flex;flex-wrap:wrap;gap:10px;margin-bottom:20px}
.info-chip{background:#1e293b;border:1px solid #334155;border-radius:8px;padding:8px 14px;font-size:12px}
.info-chip .lbl{color:#64748b;font-size:10px;text-transform:uppercase;letter-spacing:.5px;margin-bottom:2px}
.info-chip .val{color:#e2e8f0;font-weight:600}

/* ── Section ── */
.section{margin-bottom:16px}
.sec-title{font-size:11px;font-weight:700;text-transform:uppercase;letter-spacing:1px;color:#64748b;margin-bottom:8px;display:flex;align-items:center;gap:8px}
.sec-title::after{content:'';flex:1;height:1px;background:#1e293b}

/* ── Cards ── */
.card{border-radius:10px;padding:14px 16px;margin-bottom:8px;border-left:3px solid;display:flex;flex-direction:column;gap:6px}
.card.crit{background:#1a0a0a;border-color:#ef4444}
.card.high{background:#1a0f00;border-color:#f97316}
.card.warn{background:#1a1500;border-color:#eab308}
.card-head{display:flex;align-items:center;gap:10px}
.card-title{font-size:13px;font-weight:700;color:#f1f5f9}
.card-body{font-size:12px;color:#94a3b8;line-height:1.5;padding-left:2px}
.badge{display:inline-block;padding:2px 8px;border-radius:6px;font-size:10px;font-weight:800;letter-spacing:.5px;flex-shrink:0}
.b-crit{background:#7f1d1d;color:#fca5a5}
.b-high{background:#7c2d12;color:#fdba74}
.b-warn{background:#713f12;color:#fde68a}

/* ── Pass rows ── */
.pass-section{background:#0d1f17;border:1px solid #14532d;border-radius:10px;padding:12px 16px}
.pass-row{display:flex;align-items:flex-start;gap:10px;padding:5px 0;border-bottom:1px solid #14532d22;font-size:12px;color:#86efac}
.pass-row:last-child{border-bottom:none}
.pass-icon{color:#22c55e;font-weight:700;flex-shrink:0;margin-top:1px}
.pass-row strong{color:#dcfce7}

/* ── Footer ── */
footer{text-align:center;font-size:11px;color:#374151;margin-top:40px;padding-top:14px;border-top:1px solid #1e293b}
code{background:#1e293b;padding:1px 5px;border-radius:4px;font-size:11px;font-family:monospace;color:#7dd3fc}
</style>
</head>
<body>
<div class="wrap">

<div class="hdr">
  <div class="hdr-left">
    <h1>Kubernetes Upgrade Readiness</h1>
    <p>Generated $(date '+%Y-%m-%d %H:%M:%S %Z') &nbsp;·&nbsp; $(kubectl config current-context 2>/dev/null || echo "current-context")</p>
  </div>
  <div class="ver-pill">
    <span class="ver-from">${RAW_SERVER}</span>
    <span class="arrow">→</span>
    <span class="ver-to">v${TARGET_VERSION}</span>
  </div>
</div>

<div class="top-row">
  <div class="ring-wrap">
    <svg width="80" height="80" viewBox="0 0 100 100">
      <circle class="ring-bg" cx="50" cy="50" r="45"/>
      <circle class="ring-fg" cx="50" cy="50" r="45" style="stroke:${DECISION_COLOR}"/>
    </svg>
    <div class="ring-label">
      <div class="num" style="color:${DECISION_COLOR}">${SCORE}</div>
      <div class="den">/100</div>
    </div>
  </div>

  <div class="decision-box">
    <div class="decision-text" style="color:${DECISION_COLOR}">${DECISION}</div>
    <div class="decision-sub">Upgrade Decision</div>
  </div>

  <div class="stat-box">
    <div class="stat-num" style="color:#ef4444">${CRITICAL_COUNT}</div>
    <div class="stat-lbl">Critical</div>
  </div>
  <div class="stat-box">
    <div class="stat-num" style="color:#f97316">${HIGH_COUNT}</div>
    <div class="stat-lbl">High</div>
  </div>
  <div class="stat-box">
    <div class="stat-num" style="color:#eab308">${WARN_COUNT}</div>
    <div class="stat-lbl">Warnings</div>
  </div>
  <div class="stat-box">
    <div class="stat-num" style="color:#22c55e">${PASS_COUNT}</div>
    <div class="stat-lbl">Passed</div>
  </div>
</div>

<div class="info-strip">
  <div class="info-chip"><div class="lbl">Platform</div><div class="val">$( $IS_IKS && echo "IBM IKS (Managed)" || echo "Self-managed")</div></div>
  <div class="info-chip"><div class="lbl">Server</div><div class="val">${RAW_SERVER}</div></div>
  <div class="info-chip"><div class="lbl">Nodes</div><div class="val">${NODES_READY}/${NODE_COUNT} Ready</div></div>
  <div class="info-chip"><div class="lbl">OS</div><div class="val">${OS_IMAGE}</div></div>
  <div class="info-chip"><div class="lbl">Runtime</div><div class="val">${RUNTIME}</div></div>
  <div class="info-chip"><div class="lbl">CRDs</div><div class="val">${CRD_COUNT} installed</div></div>
  <div class="info-chip"><div class="lbl">Namespaces</div><div class="val">${NS_COUNT}</div></div>
  <div class="info-chip"><div class="lbl">Webhooks</div><div class="val">${TOTAL_WEBHOOKS} registered</div></div>
  <div class="info-chip"><div class="lbl">CPU max</div><div class="val">${MAX_CPU_PCT}%</div></div>
  <div class="info-chip"><div class="lbl">Memory max</div><div class="val">${MAX_MEM_PCT}%</div></div>
</div>

$( [[ ${#ISSUES[@]} -gt 0 ]] && echo '<div class="section"><div class="sec-title">🚨 Critical — Must Fix Before Upgrade</div>'"${ISSUES_HTML}"'</div>' )
$( [[ ${#HIGH[@]} -gt 0 ]] && echo '<div class="section"><div class="sec-title">🔶 High Risk</div>'"${HIGH_HTML}"'</div>' )
$( [[ ${#WARNINGS[@]} -gt 0 ]] && echo '<div class="section"><div class="sec-title">⚠ Warnings</div>'"${WARN_HTML}"'</div>' )

$( [[ ${#PASSES[@]} -gt 0 ]] && echo '<div class="section"><div class="sec-title">✅ Checks Passed</div><div class="pass-section">'"${PASS_HTML}"'</div></div>' )

</div>
<footer>Made with IBM Bob &nbsp;·&nbsp; k8s-upgrade-check.sh</footer>
</body>
</html>
HTMLEOF

echo ""
ok "Report saved → ${BOLD}$REPORT_FILE${NC}"

# Auto-open if on macOS
if command -v open &>/dev/null; then
  open "$REPORT_FILE"
elif command -v xdg-open &>/dev/null; then
  xdg-open "$REPORT_FILE" &
fi
