#!/usr/bin/env bash
# =============================================================================
# 시나리오 4 — EKS 보안 진단·하드닝·감사 증적 자동화 (AuditReady)
#   ./run.sh demo     : 인프라 생성 → Before 진단(kube-bench + 자체점검) → (N초 후) 단계별 개선 → 재진단 → 채점/보고서
#   ./run.sh upgrade  : (선택) 클러스터 버전 업그레이드 절차 실행 — Control Plane → 노드 → 애드온
#   ./run.sh down     : 전부 삭제
# =============================================================================
SCENARIO_ID="s4"
SCENARIO_TITLE="시나리오 4 · EKS 보안 진단·하드닝·감사 증적 자동화 (AuditReady)"
STACK="hannctl-s4-audit"
CLUSTER="hannctl-s4-audit"
DEV_CTX="hannctl-s4-developer"
# 시간당 예상 비용(보수적, 서울 온디맨드 기준): EKS 0.10 + 노드 1대 0.042 + NAT 0.059 + 공인IP 0.005 + 감사로그·디스크 ~0.004
HOURLY_USD="0.21"
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
K8S="$SCEN_DIR/k8s"
CHECKS="$SCEN_DIR/checks"

stack_param() { aws cloudformation describe-stacks --stack-name "$STACK" --query "Stacks[0].Parameters[?ParameterKey=='$1'].ParameterValue" --output text 2>/dev/null; }
stack_params() {
  # 사양 파라미터는 항상 명시 (aws cloudformation deploy 는 기존 스택의 이전 값을 재사용하기 때문)
  # 버전은 업그레이드 후 되돌아가지 않도록 현재 값을 유지, 감사 로그는 기준선(Before)=false
  local cv nv; cv=$(stack_param KubernetesVersion); nv=$(stack_param NodeKubernetesVersion)
  echo "ClusterName=$CLUSTER DeployerPrincipalArn=$(deployer_arn) EndpointAllowedCidr=$(my_ip_cidr)" \
       "NodeCapacityType=${HANNCTL_CAPACITY:-ON_DEMAND} NodeInstanceTypes=${HANNCTL_NODE_TYPES:-t4g.medium,t4g.large} NodeDesired=1 EnableAuditLog=false" \
       "KubernetesVersion=${cv:-1.35} NodeKubernetesVersion=${nv:-1.35}"
}
stack_set_params() { # stack_set_params K=V ... : 템플릿·태그는 그대로, 지정한 파라미터만 변경
  ensure_guard
  local args="" k kv v
  for k in $(aws cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].Parameters[].ParameterKey' --output text); do
    v=""; for kv in "$@"; do [ "${kv%%=*}" = "$k" ] && v="${kv#*=}"; done
    if [ -n "$v" ]; then args="$args ParameterKey=$k,ParameterValue=$v"; else args="$args ParameterKey=$k,UsePreviousValue=true"; fi
  done
  cmdline "aws cloudformation update-stack --stack-name $STACK --use-previous-template --parameters $* (나머지 유지)"
  local t0 wpid; t0=$(date +%s)
  # shellcheck disable=SC2086
  aws cloudformation update-stack --stack-name "$STACK" --use-previous-template --role-arn "$EXEC_ROLE_ARN" \
    --capabilities CAPABILITY_NAMED_IAM --parameters $args >/dev/null || die "스택 업데이트 실패"
  aws cloudformation wait stack-update-complete --stack-name "$STACK" >/dev/null 2>&1 &
  wpid=$!
  watch_stack_events "$STACK" "$t0" "$wpid"           # 변경되는 리소스를 실시간 표시
  wait "$wpid" || { stack_events_tail "$STACK"; die "스택 업데이트 실패"; }
  ok "스택 업데이트 완료 ($(( $(date +%s) - t0 ))s)"
}

scenario_up() {
  install_kyverno
  add_role_context "$DEV_CTX" "$(stack_output "$STACK" DeveloperRoleArn)"
  section "AuditReady 업무 서비스 + 승인된 점검 Namespace 배포"
  for ns in audit-app other-team; do
    k create namespace "$ns" --dry-run=client -o yaml | k apply -f - >/dev/null
    k -n "$ns" create configmap auditready-app --from-file="$SCEN_DIR/app/app.py" --dry-run=client -o yaml | k apply -f - >/dev/null
  done
  k apply -f "$K8S/base/" >/dev/null
  k apply -f "$K8S/audit/00-audit-namespace.yaml" >/dev/null
  for d in web api; do k -n audit-app rollout status "deploy/$d" --timeout=180s >/dev/null; done
  k -n other-team rollout status deploy/client --timeout=180s >/dev/null
  ok "audit-app(web→api), other-team(client), hannctl-audit(점검 전용) 준비"
}

# ----------------------------------------------------------------------------- BEFORE
scenario_before() {
  add_role_context "$DEV_CTX" "$(stack_output "$STACK" DeveloperRoleArn)"
  section "Before 상태로 되돌리기 (감사 로그 OFF · 과다 RBAC · 정책/네트워크 통제 없음 · 정기 점검 없음)"
  if [ "$(stack_param EnableAuditLog)" = "true" ]; then
    info "EKS 감사 로그 끄기 (CloudFormation 업데이트, 2~4분)"; stack_set_params EnableAuditLog=false
  fi
  k delete networkpolicy --all -n audit-app >/dev/null 2>&1
  k delete -f "$K8S/after/20-developer-rbac.yaml" --ignore-not-found >/dev/null 2>&1
  k delete -f "$K8S/after/50-kube-bench-cronjob.yaml" --ignore-not-found >/dev/null 2>&1
  k delete -f "$K8S/policies/kyverno-baseline.yaml" --ignore-not-found >/dev/null 2>&1
  k -n audit-app rollout status deploy/web --timeout=120s >/dev/null 2>&1; k -n audit-app rollout status deploy/api --timeout=120s >/dev/null 2>&1
  k -n other-team rollout status deploy/client --timeout=120s >/dev/null 2>&1
  for ns in audit-app other-team; do
    k label ns "$ns" pod-security.kubernetes.io/enforce- pod-security.kubernetes.io/enforce-version- hannctl.io/protected- >/dev/null 2>&1
  done
  k -n audit-app set serviceaccount deploy/web deploy/api default >/dev/null 2>&1      # 앱이 default SA 사용(레거시)
  k -n other-team set serviceaccount deploy/client default >/dev/null 2>&1
  k delete -f "$K8S/after/45-app-serviceaccounts.yaml" --ignore-not-found >/dev/null 2>&1
  for ns in $(k get ns -o jsonpath='{.items[*].metadata.name}'); do                       # default SA 토큰 자동마운트 원래대로
    k -n "$ns" patch sa default --type merge -p '{"automountServiceAccountToken":null}' >/dev/null 2>&1
  done
  k apply -f "$K8S/before/legacy-rbac.yaml" >/dev/null
  ok "Before 적용: 감사 로그 꺼짐, 개발자·앱 SA 에 cluster-admin, 네트워크/Pod 정책 없음"
  ev before 00-legacy-bindings -- kubectl --context "$CLUSTER" get clusterrolebinding -l hannctl.io/phase=before -o wide
}

# ----------------------------------------------------------------------------- 진단 A: kube-bench
run_kube_bench() { # run_kube_bench PHASE → KB_PASS KB_FAIL KB_WARN KB_SECS
  local p=$1 t0; t0=$(date +%s)
  k apply -f "$K8S/audit/00-audit-namespace.yaml" >/dev/null
  k -n hannctl-audit delete job hannctl-kube-bench --ignore-not-found --wait=true >/dev/null 2>&1
  cmdline "kubectl apply -f k8s/audit/kube-bench-job.yaml   # CIS EKS Benchmark v1.8.0"
  k apply -f "$K8S/audit/kube-bench-job.yaml" >/dev/null
  if ! k -n hannctl-audit wait --for=condition=complete job/hannctl-kube-bench --timeout=300s >/dev/null 2>&1; then
    warn "kube-bench Job 미완료"; k -n hannctl-audit describe job hannctl-kube-bench | tail -5 >&2
  fi
  k -n hannctl-audit logs job/hannctl-kube-bench > "$RUN_DIR/$p/kube-bench-raw.log" 2>&1
  k -n hannctl-audit delete job hannctl-kube-bench --wait=false >/dev/null 2>&1   # 점검 끝나면 특권 Pod 제거
  local out; out=$(python3 "$CHECKS/kube_bench.py" summarize "$RUN_DIR/$p/kube-bench-raw.log" "$RUN_DIR/$p" 2>/dev/null)
  if [ -n "$out" ]; then
    set -- $out; KB_PASS=$1 KB_FAIL=$2 KB_WARN=$3 KB_415=$5
  else
    KB_PASS=""; KB_FAIL=""; KB_WARN=""; KB_415=NA
  fi
  KB_SECS=$(( $(date +%s) - t0 ))
}

# ----------------------------------------------------------------------------- 진단 B: 자체 점검
run_selfcheck() { # run_selfcheck PHASE → SC_PASS SC_TOTAL SC_SECS
  local ph=$1 out; out=$(python3 "$CHECKS/cluster_checks.py" --context "$CLUSTER" --cluster "$CLUSTER" --out "$RUN_DIR/$ph")
  set -- $out; SC_PASS=${1:-0} SC_TOTAL=${2:-12} SC_SECS=${3:-0}
  sed -n '5,100p' "$RUN_DIR/$ph/selfcheck.md" | awk -F'|' '{printf "      %-9s %-12s %s\n",$2,$5,$4}'
}

cani() { local r; r=$(kubectl --context "$1" auth can-i "${@:2}" 2>/dev/null); echo "${r:-no}"; }

audit_events() { # audit_events PHASE RETRIES → AUDIT_RES(FOUND/NOT_FOUND), AUDIT_N, AUDIT_CODES
  # 이번 테스트에서 개발자가 보낸 secrets 요청(성공이든 거부든)이 감사 로그에 남았는지
  local p=$1 tries=$2 i n=0
  for i in $(seq 1 "$tries"); do
    aws logs filter-log-events --log-group-name "/aws/eks/$CLUSTER/cluster" --log-stream-name-prefix kube-apiserver-audit \
      --start-time "$AUDIT_SINCE" --filter-pattern '{ $.user.username = "developer" && $.objectRef.resource = "secrets" }' \
      --max-items 20 --output json > "$RUN_DIR/$p/audit-developer-secrets.json" 2>/dev/null
    set -- $(python3 -c 'import json,sys
try: ev=[json.loads(e["message"]) for e in json.load(open(sys.argv[1])).get("events",[])]
except Exception: ev=[]
codes=sorted({str(e.get("responseStatus",{}).get("code")) for e in ev})
print(len(ev), ",".join(codes) or "-")' "$RUN_DIR/$p/audit-developer-secrets.json")
    n=$1; AUDIT_CODES=$2
    [ "$n" != "0" ] && break
    [ "$i" -lt "$tries" ] && sleep 20
  done
  AUDIT_N=$n
  if [ "$n" != "0" ]; then AUDIT_RES=FOUND; else AUDIT_RES=NOT_FOUND; fi
}

scenario_tests() {
  local p=$1 risk=no allowed=DENIED cross=BLOCKED t0; t0=$(date +%s)
  [ "$p" = before ] && { risk=yes; allowed=ALLOWED; cross=200; }
  add_role_context "$DEV_CTX" "$(stack_output "$STACK" DeveloperRoleArn)"

  section "[$p] 진단 A) kube-bench — CIS Amazon EKS Benchmark v1.8.0 (승인된 점검 Job)"
  [ "$p" = before ] && lesson "kube-bench 는 공인 기준(CIS)으로 노드·RBAC·Pod 설정을 자동 점검한다. 점검 Pod 는 특권이 필요해 전용 Namespace 에서만 실행하고 끝나면 지운다."
  run_kube_bench "$p"
  record kb_run "$p" COMPLETED "$([ -n "$KB_PASS" ] && echo COMPLETED || echo FAILED)" "kube-bench 자동 점검 실행" \
    "PASS $KB_PASS / FAIL $KB_FAIL / WARN $KB_WARN, ${KB_SECS}s"
  record kb_4_1_5 "$p" "$([ "$p" = before ] && echo FAIL || echo PASS)" "$KB_415" "CIS 4.1.5 default SA 미사용"

  section "[$p] 진단 B) 자체 점검 DEMO-01~12 (회사 기준)"
  [ "$p" = before ] && lesson "CIS 에 없는 회사 기준(감사 로그, 정기 점검, 앱 정상 여부)은 직접 점검 스크립트로 만든다. 두 표는 합산하지 않는다."
  run_selfcheck "$p"
  local scExp=FINDINGS scObs=FINDINGS
  [ "$p" = after ] && scExp=ALL_PASS
  [ "$SC_PASS" = "$SC_TOTAL" ] && scObs=ALL_PASS
  record selfcheck "$p" "$scExp" "$scObs" "자체 점검 통과율" "$SC_PASS/$SC_TOTAL ($(( SC_PASS * 100 / SC_TOTAL ))%)"

  section "[$p] 위험 재현/차단 — 과다 권한 (개발자 IAM Role 로 실제 접속)"
  [ "$p" = before ] && lesson "개발자 그룹과 앱 ServiceAccount 가 cluster-admin → 계정 하나·Pod 하나만 탈취돼도 클러스터 전체가 넘어간다."
  record dev_list_pods "$p" yes "$(cani $DEV_CTX list pods -n audit-app)" "정상: 개발자 → 앱 Pod 조회"
  record dev_get_secrets "$p" "$risk" "$(cani $DEV_CTX get secrets -n audit-app)" "차단: 개발자 → Secret 조회"
  record dev_delete_deploy "$p" "$risk" "$(cani $DEV_CTX delete deployments -n audit-app)" "차단: 개발자 → 배포 삭제"
  record dev_create_crb "$p" "$risk" "$(cani $DEV_CTX create clusterrolebindings)" "차단: 개발자 → 권한 상승(CRB 생성)"
  record app_sa_secrets "$p" "$risk" "$(cani $CLUSTER list secrets -A --as=system:serviceaccount:audit-app:default)" "차단: 앱 SA 토큰 → 전체 Secret"
  AUDIT_SINCE=$(( ($(date +%s) - 30) * 1000 ))     # 감사 로그 조회 기준 시각(이번 요청 이후만)
  EV_LINES=4 ev "$p" developer-get-secrets -- kubectl --context "$DEV_CTX" get secrets -n audit-app

  section "[$p] 위험 재현/차단 — Pod 보안 (서버측 dry-run, 실제 생성 안 함)"
  [ "$p" = before ] && lesson "Namespace 에 보안 기준이 없으면 노드를 장악할 수 있는 Pod 도 그대로 만들어진다."
  local r
  r=$(admission_try audit-app "$RUN_DIR/$p/admission-privileged.txt" < "$K8S/attack/privileged-pod.yaml")
  record privileged "$p" "$allowed" "$r" "차단: privileged Pod"
  r=$(admission_try audit-app "$RUN_DIR/$p/admission-hostpath.txt" < "$K8S/attack/hostpath-pod.yaml")
  record hostpath "$p" "$allowed" "$r" "차단: hostPath(/) Pod"
  r=$(admission_try audit-app "$RUN_DIR/$p/admission-root.txt" < "$K8S/attack/root-pod.yaml")
  record root "$p" "$allowed" "$r" "차단: root 실행 Pod"

  section "[$p] 네트워크 · 정상 서비스"
  record cross_ns "$p" "$cross" "$(http_from_pod other-team client http://api.audit-app.svc.cluster.local/health)" "차단: 다른 팀 → 앱 api"
  record app_health "$p" 200 "$(http_from_pod audit-app web http://api.audit-app.svc.cluster.local/health)" "정상: 앱 web → api"

  section "[$p] 감사 로그 (EKS → CloudWatch Logs)"
  local logs; logs=$(aws eks describe-cluster --name "$CLUSTER" --query 'cluster.logging.clusterLogging[?enabled].types[]' --output text)
  record audit_log_enabled "$p" "$([ "$p" = before ] && echo DISABLED || echo ENABLED)" \
    "$(echo "$logs" | grep -qw audit && echo ENABLED || echo DISABLED)" "감사 로그 활성화" "${logs:-없음}"
  if [ "$p" = before ]; then
    lesson "감사 로그가 꺼져 있으면 방금 개발자가 Secret 을 조회한 사실이 어디에도 남지 않는다 = 사고가 나도 증명할 수 없다."
    audit_events "$p" 1
    record audit_events "$p" NOT_FOUND "$AUDIT_RES" "개발자 Secret 조회 기록" "흔적 ${AUDIT_N}건 = 사고 조사 불가"
  else
    info "방금 개발자의 Secret 조회 시도를 CloudWatch 감사 로그에서 검색 (수집 지연 최대 ~3분)"
    audit_events "$p" 9
    record audit_events "$p" FOUND "$AUDIT_RES" "개발자 Secret 조회 기록" "${AUDIT_N}건, HTTP $AUDIT_CODES"
  fi

  section "[$p] 재발 방지 · 인프라 · FinOps"
  local cj; cj=$(k get cronjob -n hannctl-audit -o name 2>/dev/null | wc -l | tr -d ' ')
  record cronjob "$p" "$([ "$p" = before ] && echo MISSING || echo PRESENT)" "$([ "$cj" -gt 0 ] && echo PRESENT || echo MISSING)" "kube-bench 정기 점검 등록"
  record cluster_ready "$p" ACTIVE "$(aws eks describe-cluster --name "$CLUSTER" --query cluster.status --output text)" "인프라: EKS ACTIVE"
  tag_audit "$p"
  finops_audit "$p"

  local secs=$(( KB_SECS + ${SC_SECS%.*} ))
  record check_time "$p" AUTOMATED "$([ -n "$KB_PASS" ] && [ "$secs" -lt 600 ] && echo AUTOMATED || echo SLOW)" "점검 소요시간(진단 A+B)" \
    "자동 ${secs}s (수동 가정: 12항목×10분 ≈ 2시간)"
  if [ "$p" = after ]; then
    python3 "$CHECKS/kube_bench.py" compare "$RUN_DIR" >/dev/null && ok "전후 비교표: ${RUN_DIR#$SCEN_DIR/}/COMPLIANCE.md"
    sed -n '1,40p' "$RUN_DIR/COMPLIANCE.md" | grep -E '^\| (Before|After)' | sed 's/^/      /'
  fi
  timeline "$p" "$p 진단·테스트 완료" "자체점검 $SC_PASS/$SC_TOTAL, kube-bench PASS $KB_PASS/FAIL $KB_FAIL, $(( $(date +%s) - t0 ))s"
}

# ----------------------------------------------------------------------------- AFTER (단계별 개선)
step_audit_log() {
  printf '%s┃  📄 cfn/stack.yaml (Cluster.Logging)%s\n' "$C_C" "$C_0"
  grep -n -A2 "Logging:" "$SCEN_DIR/cfn/stack.yaml" | sed "s/^/${C_DIM}┃     /;s/\$/${C_0}/"
  stack_set_params EnableAuditLog=true
  info "즉시 확인 → 활성화된 로그: $(aws eks describe-cluster --name "$CLUSTER" --query 'cluster.logging.clusterLogging[?enabled].types[]' --output text)"
}
step_rbac() {
  cmdline "kubectl delete clusterrolebinding hannctl-legacy-developers-admin hannctl-legacy-app-sa-admin"
  k delete -f "$K8S/before/legacy-rbac.yaml" --ignore-not-found >/dev/null
  show_manifest "$K8S/after/20-developer-rbac.yaml"
  cmdline "kubectl apply -f k8s/after/20-developer-rbac.yaml"
  k apply -f "$K8S/after/20-developer-rbac.yaml" >/dev/null
  info "즉시 확인 → 개발자: Pod 조회=$(cani $DEV_CTX list pods -n audit-app), Secret 조회=$(cani $DEV_CTX get secrets -n audit-app), 앱 SA 전체 Secret=$(cani $CLUSTER list secrets -A --as=system:serviceaccount:audit-app:default)"
}
step_pod_security() {
  cmdline "kubectl label ns audit-app other-team pod-security.kubernetes.io/enforce=restricted hannctl.io/protected=true"
  for ns in audit-app other-team; do
    k label ns "$ns" pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=latest hannctl.io/protected=true --overwrite >/dev/null
  done
  MANIFEST_LINES=14 show_manifest "$K8S/policies/kyverno-baseline.yaml"
  cmdline "kubectl apply -f k8s/policies/kyverno-baseline.yaml"
  k apply -f "$K8S/policies/kyverno-baseline.yaml" >/dev/null
  wait_policies
  info "즉시 확인 → privileged Pod: $(admission_try audit-app < "$K8S/attack/privileged-pod.yaml"), 기존 Pod 상태: $(k -n audit-app get pods --no-headers | awk '{print $3}' | sort | uniq -c | tr -s ' ' | tr '\n' ' ')"
}
step_network() {
  MANIFEST_LINES=12 show_manifest "$K8S/after/40-network.yaml"
  cmdline "kubectl apply -f k8s/after/40-network.yaml"
  k apply -f "$K8S/after/40-network.yaml" >/dev/null
  MANIFEST_LINES=6 show_manifest "$K8S/after/45-app-serviceaccounts.yaml"
  cmdline "kubectl apply -f k8s/after/45-app-serviceaccounts.yaml && kubectl set serviceaccount deploy/web web ..."
  k apply -f "$K8S/after/45-app-serviceaccounts.yaml" >/dev/null
  k -n audit-app set serviceaccount deploy/web web >/dev/null; k -n audit-app set serviceaccount deploy/api api >/dev/null
  k -n other-team set serviceaccount deploy/client client >/dev/null
  cmdline "for ns in (모든 Namespace); kubectl patch sa default -n \$ns -p '{\"automountServiceAccountToken\": false}'"
  for ns in $(k get ns -o jsonpath='{.items[*].metadata.name}'); do
    k -n "$ns" patch sa default --type merge -p '{"automountServiceAccountToken":false}' >/dev/null
  done
  for d in web api; do k -n audit-app rollout status "deploy/$d" --timeout=180s >/dev/null; done
  k -n other-team rollout status deploy/client --timeout=180s >/dev/null
  local i; for i in $(seq 1 24); do                       # 이전 Pod(default SA)가 완전히 사라질 때까지
    [ "$(k get pods -A -o jsonpath='{range .items[*]}{.spec.serviceAccountName}{"\n"}{end}' | grep -cx default)" = 0 ] && break; sleep 5
  done
  info "즉시 확인 → 다른 팀→api: $(http_from_pod other-team client http://api.audit-app.svc.cluster.local/health 3), web→api: $(http_from_pod audit-app web http://api.audit-app.svc.cluster.local/health 3), web SA: $(k -n audit-app get deploy web -o jsonpath='{.spec.template.spec.serviceAccountName}'), default SA 사용 Pod: $(k get pods -A -o jsonpath='{range .items[*]}{.spec.serviceAccountName}{"\n"}{end}' | grep -cx default)개"
}
step_cronjob() {
  MANIFEST_LINES=12 show_manifest "$K8S/after/50-kube-bench-cronjob.yaml"
  cmdline "kubectl apply -f k8s/after/50-kube-bench-cronjob.yaml"
  k apply -f "$K8S/after/50-kube-bench-cronjob.yaml" >/dev/null
  info "즉시 확인 → $(k -n hannctl-audit get cronjob --no-headers | awk '{print $1" schedule="$2" "$3" "$4" "$5" "$6}')"
}
scenario_after() {
  improve 1 5 "감사 로그 활성화" "CloudFormation EnableAuditLog=false→true (EKS audit/authenticator → CloudWatch)" "누가 무엇을 했는지 기록이 남음(사고 조사·감사 증적)" step_audit_log \
    "EKS 감사 로그는 기본으로 꺼져 있다. 켜기 전의 행동은 나중에 증명할 방법이 없다"
  improve 2 5 "과다 권한 제거(RBAC)" "개발자·앱 SA 의 cluster-admin 삭제 → 개발자 view(audit-app 한정)" "탈취·실수 시 피해 범위 최소화" step_rbac \
    "IAM 은 '로그인 가능 여부', RBAC 은 '로그인 후 할 수 있는 일'. 업무에 필요한 조회는 남기고 Secret·삭제·권한상승만 뺀다"
  improve 3 5 "Pod 보안 기준 강제" "PSA restricted 라벨 + Kyverno ValidatingPolicy(Deny) 3종" "privileged/hostPath/root Pod 사전 차단" step_pod_security \
    "정책은 '새로 만드는 Pod' 를 검사한다. 기존 정상 Pod 가 기준을 지키게 만들어 두었기 때문에 서비스는 멈추지 않는다"
  improve 4 5 "네트워크·토큰 최소화" "default-deny + web→api 만 허용, 앱 전용 SA + 모든 default SA 토큰 자동마운트 OFF" "측면 이동·토큰 탈취 경로 축소 (CIS 4.1.5)" step_network \
    "API 를 쓰지 않는 앱에는 토큰을 주지 않는다. 쓰지 않는 권한·통로는 공격자의 통로가 된다"
  improve 5 5 "정기 점검 자동화" "kube-bench CronJob(매일 09:00 KST) 등록" "점검이 사람 기억에 의존하지 않음(재발 방지)" step_cronjob \
    "한 번 고친 설정도 시간이 지나면 다시 틀어진다. 감사는 '한 번의 점검'이 아니라 '반복되는 점검의 기록'을 요구한다"
  info "다음: 동일 조건으로 재진단(kube-bench + 자체 점검) → 전후 비교표 COMPLIANCE.md"
}

scenario_status() {
  section "감사·하드닝 현황"
  aws eks describe-cluster --name "$CLUSTER" --query '{버전:cluster.version,감사로그:cluster.logging.clusterLogging[?enabled].types[]}' --output table
  k get ns audit-app other-team hannctl-audit -L pod-security.kubernetes.io/enforce,hannctl.io/protected 2>/dev/null
  k get clusterrolebinding -l hannctl.io/scenario=s4 2>/dev/null; k get rolebinding -n audit-app 2>/dev/null
  k get networkpolicy -n audit-app 2>/dev/null; k get validatingpolicy 2>/dev/null; k get cronjob,job -n hannctl-audit 2>/dev/null
  k get pods -n audit-app -o wide 2>/dev/null | cut -c1-120
}

# ----------------------------------------------------------------------------- (선택) 업그레이드 절차
cmd_upgrade() {
  preflight; ensure_up; run_latest
  local cur target; cur=$(aws eks describe-cluster --name "$CLUSTER" --query cluster.version --output text)
  target=${1:-$(python3 -c 'import sys;a,b=sys.argv[1].split(".");print(f"{a}.{int(b)+1}")' "$cur")}
  banner "UPGRADE — EKS $cur → $target (Control Plane → 노드 그룹 → 애드온)"
  info "약 25분 소요(비용 약 \$$(python3 -c "print(round(float('$HOURLY_USD')*0.45,2))")). 유지 시간이 넉넉한지 확인(필요 시): ./run.sh lifetime 8"
  section "1) 사전 점검"
  ev after upgrade-01-insights -- aws eks list-insights --cluster-name "$CLUSTER" --filter categories=UPGRADE_READINESS \
    --query 'insights[].[name,insightStatus.status]' --output table
  ev after upgrade-02-nodes-before -- kubectl --context "$CLUSTER" get nodes -o wide
  [ "$(http_from_pod audit-app web http://api.audit-app.svc.cluster.local/health)" = 200 ] && ok "앱 정상(업그레이드 전)" || warn "앱 상태 확인 필요"
  timeline after "업그레이드 시작" "$cur → $target"
  section "2) Control Plane 업그레이드 (약 8~12분, 1 minor 씩만 가능)"
  stack_set_params KubernetesVersion="$target"
  section "3) 노드 그룹 롤링 업그레이드 (노드를 1대씩 교체, 약 10분)"
  stack_set_params NodeKubernetesVersion="$target"
  section "4) 애드온을 새 버전 기본값으로 업데이트"
  local a v
  for a in vpc-cni kube-proxy coredns metrics-server eks-pod-identity-agent; do
    aws eks describe-addon --cluster-name "$CLUSTER" --addon-name "$a" >/dev/null 2>&1 || continue
    v=$(aws eks describe-addon-versions --kubernetes-version "$target" --addon-name "$a" \
        --query 'addons[0].addonVersions[?compatibilities[?defaultVersion==`true`]].addonVersion | [0]' --output text)
    info "$a → $v"
    aws eks update-addon --cluster-name "$CLUSTER" --addon-name "$a" --addon-version "$v" --resolve-conflicts PRESERVE >/dev/null 2>&1 || warn "$a 업데이트 건너뜀"
  done
  for a in vpc-cni kube-proxy coredns metrics-server; do aws eks wait addon-active --cluster-name "$CLUSTER" --addon-name "$a" 2>/dev/null; done
  section "5) 사후 점검"
  ev after upgrade-03-nodes-after -- kubectl --context "$CLUSTER" get nodes -o wide
  record upgrade_version after "$target" "$(aws eks describe-cluster --name "$CLUSTER" --query cluster.version --output text)" "업그레이드: Control Plane 버전"
  record upgrade_app after 200 "$(http_from_pod audit-app web http://api.audit-app.svc.cluster.local/health)" "업그레이드 후 앱 정상"
  timeline after "업그레이드 완료" "$cur → $target"
  ok "업그레이드 완료. 재진단: ./run.sh test after"
}

case "${1:-}" in
  upgrade) shift; cmd_upgrade "$@" ;;
  *) dispatch "$@" ;;
esac
