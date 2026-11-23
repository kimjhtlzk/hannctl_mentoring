#!/usr/bin/env bash
# =============================================================================
# 시나리오 2 — B2B SaaS 고객사별 보안 격리 (BizDesk)
#   ./run.sh demo            : 인프라 생성 → Before 재현/테스트 → (N초 후) 단계별 개선 → After 테스트 → 채점/보고서
#   ./run.sh down            : 전부 삭제
# =============================================================================
SCENARIO_ID="s2"
SCENARIO_TITLE="시나리오 2 · B2B SaaS 고객사별 보안 격리 (BizDesk)"
STACK="hannctl-s2-saas"
CLUSTER="hannctl-s2-saas"
# 시간당 예상 비용(보수적, 서울 온디맨드 기준): EKS 0.10 + 노드 1대 0.042 + NAT 0.059 + 공인IP 0.005 + 디스크·로그 ~0.004
HOURLY_USD="0.21"
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
K8S="$SCEN_DIR/k8s"

stack_params() {
  # 사양 파라미터는 항상 명시 (aws cloudformation deploy 는 기존 스택의 이전 값을 재사용하기 때문)
  echo "ClusterName=$CLUSTER DeployerPrincipalArn=$(deployer_arn) EndpointAllowedCidr=$(my_ip_cidr)" \
       "NodeCapacityType=${HANNCTL_CAPACITY:-ON_DEMAND} NodeDesired=1"
}

role_contexts() { # 테넌트 운영자 IAM Role 로 접속하는 kubeconfig 컨텍스트
  add_role_context hannctl-s2-tenant-a "$(stack_output "$STACK" TenantAOperatorRoleArn)"
  add_role_context hannctl-s2-tenant-b "$(stack_output "$STACK" TenantBOperatorRoleArn)"
}

scenario_up() {
  install_kyverno
  role_contexts
  section "고객사 A/B 워크로드 배포 (web → api)"
  for t in a b; do
    k get namespace "tenant-$t" >/dev/null 2>&1 || k create namespace "tenant-$t" --save-config >/dev/null   # 없을 때만 생성 (After 보안 라벨 보존)
    k -n "tenant-$t" create configmap bizdesk-app --from-file="$SCEN_DIR/app/app.py" --dry-run=client -o yaml | k apply -f - >/dev/null
  done
  k apply -f "$K8S/base/" >/dev/null
  for t in a b; do for d in web api; do k -n "tenant-$t" rollout status "deploy/$d" --timeout=180s >/dev/null; done; done
  ok "tenant-a, tenant-b 각각 web/api 실행 중"
}

# ----------------------------------------------------------------------------- BEFORE
scenario_before() {
  role_contexts
  section "Before 상태로 되돌리기 (NetworkPolicy 없음 · PSA 없음 · 과다 RBAC)"
  k delete networkpolicy --all -n tenant-a >/dev/null 2>&1
  k delete networkpolicy --all -n tenant-b >/dev/null 2>&1
  k delete -f "$K8S/after/30-tenant-rbac.yaml" --ignore-not-found >/dev/null 2>&1
  k delete -f "$K8S/policies/kyverno-baseline.yaml" --ignore-not-found >/dev/null 2>&1
  for t in a b; do
    k label ns "tenant-$t" pod-security.kubernetes.io/enforce- pod-security.kubernetes.io/enforce-version- hannctl.io/protected- >/dev/null 2>&1
  done
  k apply -f "$K8S/before/legacy-rbac.yaml" >/dev/null
  ok "Before 적용: 같은 클러스터 안의 모든 Pod 끼리 통신 가능, 두 운영자 모두 클러스터 전체 edit 권한"
  ev before 00-rbac-legacy -- kubectl --context "$CLUSTER" get clusterrolebinding hannctl-legacy-tenant-operators-edit -o wide
  sleep 5
}

# ----------------------------------------------------------------------------- 테스트 (Before/After 동일)
API_A="http://api.tenant-a.svc.cluster.local/tenant"
API_B="http://api.tenant-b.svc.cluster.local/tenant"

net_tests() { # net_tests PHASE  (After 기대값: 같은 테넌트=200, 교차=BLOCKED)
  local p=$1 crossExp=BLOCKED; [ "$p" = before ] && crossExp=200
  record a_to_a "$p" 200 "$(http_from_pod tenant-a web "$API_A")" "정상: A web → A api"
  record b_to_b "$p" 200 "$(http_from_pod tenant-b web "$API_B")" "정상: B web → B api"
  record a_to_b "$p" "$crossExp" "$(http_from_pod tenant-a web "$API_B")" "차단: A web → B api"
  record b_to_a "$p" "$crossExp" "$(http_from_pod tenant-b web "$API_A")" "차단: B web → A api"
  record a_api_to_b "$p" "$crossExp" "$(http_from_pod tenant-a api "$API_B")" "차단: A api → B api (측면 이동)"
  record dns "$p" RESOLVED "$(k -n tenant-a exec deploy/web -- python3 /app/app.py resolve api.tenant-a.svc.cluster.local 2>/dev/null | tail -1)" "정상: DNS 조회 유지"
}

cani() { # cani CONTEXT VERB RESOURCE NAMESPACE → yes/no
  local r; r=$(kubectl --context "$1" auth can-i "$2" "$3" -n "$4" 2>/dev/null); echo "${r:-no}"
}
rbac_tests() {
  local p=$1 crossExp=no; [ "$p" = before ] && crossExp=yes
  local A=hannctl-s2-tenant-a B=hannctl-s2-tenant-b
  record rbac_a_list_pods_a  "$p" yes "$(cani $A list pods tenant-a)" "정상: A 운영자 → A Pod 조회"
  record rbac_a_patch_deploy_a "$p" yes "$(cani $A patch deployments tenant-a)" "정상: A 운영자 → A 배포 재시작"
  record rbac_a_list_pods_b  "$p" "$crossExp" "$(cani $A list pods tenant-b)" "차단: A 운영자 → B Pod 조회"
  record rbac_a_patch_deploy_b "$p" "$crossExp" "$(cani $A patch deployments tenant-b)" "차단: A 운영자 → B 배포 변경"
  record rbac_b_list_pods_a  "$p" "$crossExp" "$(cani $B list pods tenant-a)" "차단: B 운영자 → A Pod 조회"
  record rbac_a_get_secrets_a "$p" "$crossExp" "$(cani $A get secrets tenant-a)" "차단: A 운영자 → Secret 조회(최소권한)"
  EV_LINES=6 ev "$p" rbac-a-operator-get-pods-tenant-b -- kubectl --context $A get pods -n tenant-b
}

pod_tests() {
  local p=$1 exp=DENIED; [ "$p" = before ] && exp=ALLOWED
  local r
  r=$(admission_try tenant-a "$RUN_DIR/$p/admission-privileged.txt" < "$K8S/attack/privileged-pod.yaml")
  record privileged "$p" "$exp" "$r" "차단: privileged Pod 생성"
  r=$(admission_try tenant-a "$RUN_DIR/$p/admission-hostpath.txt" < "$K8S/attack/hostpath-pod.yaml")
  record hostpath "$p" "$exp" "$r" "차단: hostPath(/) 마운트 Pod 생성"
  r=$(admission_try tenant-a "$RUN_DIR/$p/admission-root.txt" < "$K8S/attack/root-pod.yaml")
  record root "$p" "$exp" "$r" "차단: root 실행 Pod 생성"
  if [ "$p" = after ]; then info "거부 메시지 (누가·왜 막았는지) — 먼저 PSA 가 막는다:"; fold -w 150 "$RUN_DIR/$p/admission-privileged.txt" | head -3 | sed 's/^/      /'; fi
  # 이중 방어 확인: PSA 라벨이 없는 Namespace(실수로 라벨을 빠뜨린 상황)에서도 Kyverno 가 막는가?
  k create namespace hannctl-policy-check --dry-run=client -o yaml | k apply -f - >/dev/null
  k label ns hannctl-policy-check hannctl.io/scenario=s2 hannctl.io/protected=true --overwrite >/dev/null
  r=$(admission_try hannctl-policy-check "$RUN_DIR/$p/admission-kyverno-only.txt" < "$K8S/attack/privileged-pod.yaml")
  record kyverno_layer "$p" "$exp" "$r" "이중방어: PSA 없는 Namespace 에서 Kyverno 차단"
  if [ "$p" = after ]; then info "PSA 가 없어도 Kyverno 가 막는다:"; grep -o 'Policy hannctl-[a-z-]* failed: [^;]*' "$RUN_DIR/$p/admission-kyverno-only.txt" | head -2 | sed 's/^/      /'; fi
}

audit_test() { # EKS 감사 로그(CloudWatch)에 A 운영자의 403(거부) 이벤트가 남는지
  local p=$1 found=NOT_FOUND i start
  start=$(( ($(date +%s) - 900) * 1000 ))
  info "CloudWatch 감사 로그에서 tenant-a-operator 의 거부(403) 이벤트 조회 (수집 지연 최대 ~3분)"
  for i in 1 2 3 4 5 6 7 8 9; do
    if aws logs filter-log-events --log-group-name "/aws/eks/$CLUSTER/cluster" --log-stream-name-prefix kube-apiserver-audit \
        --start-time "$start" --filter-pattern '{ $.user.username = "tenant-a-operator" && $.responseStatus.code = 403 }' \
        --max-items 3 --output json > "$RUN_DIR/$p/audit-403-events.json" 2>/dev/null \
       && [ "$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1])).get("events",[])))' "$RUN_DIR/$p/audit-403-events.json")" != "0" ]; then
      found=FOUND; break
    fi
    sleep 20
  done
  record audit_forbidden "$p" FOUND "$found" "감사: 거부 이벤트 CloudWatch 기록"
}

infra_tests() {
  local p=$1
  record cluster_ready "$p" ACTIVE "$(aws eks describe-cluster --name "$CLUSTER" --query cluster.status --output text)" "인프라: EKS 클러스터 ACTIVE"
  local np; np=$(aws eks describe-addon --cluster-name "$CLUSTER" --addon-name vpc-cni --query addon.configurationValues --output text | grep -c '"enableNetworkPolicy":"true"')
  record netpol_engine "$p" ENABLED "$([ "$np" -ge 1 ] && echo ENABLED || echo DISABLED)" "인프라: VPC CNI NetworkPolicy 엔진"
  tag_audit "$p"
  finops_audit "$p"
}

scenario_tests() {
  local p=$1
  section "[$p] 1) 네트워크: 고객사 간 Pod 통신"
  [ "$p" = before ] && lesson "Kubernetes 기본값은 '모든 Pod 끼리 통신 허용'. Namespace 를 나눠도 네트워크는 나뉘지 않는다"
  net_tests "$p"
  section "[$p] 2) 권한: 테넌트 운영자 IAM Role → Kubernetes RBAC"
  [ "$p" = before ] && lesson "실제 IAM Role 로 EKS 에 접속해 확인한다. 편의상 준 클러스터 전체 edit 권한이면 다른 고객사와 Secret 까지 보인다"
  rbac_tests "$p"
  section "[$p] 3) Pod 보안: 위험 Pod 생성 시도 (서버측 dry-run)"
  [ "$p" = before ] && lesson "privileged·hostPath·root Pod 는 노드를 장악해 같은 노드의 다른 고객사 Pod 까지 침해할 수 있다 (실제 생성 없이 dry-run 으로만 시도)"
  pod_tests "$p"
  section "[$p] 4) 인프라 · 식별자 · FinOps"
  infra_tests "$p"
  if [ "$p" = after ]; then section "[$p] 5) 감사 증적"; audit_test "$p"; fi
  ev "$p" networkpolicies -- kubectl --context "$CLUSTER" get networkpolicy -A -l hannctl.io/scenario=s2
  timeline "$p" "$p 테스트 완료" "$(grep -c "\"phase\": \"$p\"" "$RUN_DIR/results.jsonl") 개 항목"
}

# ----------------------------------------------------------------------------- AFTER (단계별 개선)
step_default_deny() {
  show_manifest "$K8S/after/10-default-deny.yaml" 8
  cmdline "kubectl apply -f k8s/after/10-default-deny.yaml"
  k apply -f "$K8S/after/10-default-deny.yaml" >/dev/null; sleep 8
  info "즉시 확인 → 기본 차단만 적용하면 '정상 통신과 DNS 까지' 끊긴다 (그래서 다음 단계가 필요)"
  printf '      A→A api: %s | A→B api: %s | DNS: %s\n' "$(http_from_pod tenant-a web "$API_A" 3)" "$(http_from_pod tenant-a web "$API_B" 3)" \
    "$(k -n tenant-a exec deploy/web -- python3 /app/app.py resolve api.tenant-a.svc.cluster.local 2>/dev/null | tail -1)"
}
step_allow_required() {
  show_manifest "$K8S/after/20-allow-required.yaml" 30
  cmdline "kubectl apply -f k8s/after/20-allow-required.yaml"
  k apply -f "$K8S/after/20-allow-required.yaml" >/dev/null; sleep 8
  info "즉시 확인 → 필요한 경로(DNS, 같은 테넌트 web→api)만 다시 열림"
  printf '      A→A api: %s | A→B api: %s | B→A api: %s\n' "$(http_from_pod tenant-a web "$API_A" 3)" "$(http_from_pod tenant-a web "$API_B" 3)" "$(http_from_pod tenant-b web "$API_A" 3)"
}
step_rbac() {
  show_manifest "$K8S/after/30-tenant-rbac.yaml" 18
  cmdline "kubectl delete clusterrolebinding hannctl-legacy-tenant-operators-edit && kubectl apply -f k8s/after/30-tenant-rbac.yaml"
  k delete -f "$K8S/before/legacy-rbac.yaml" --ignore-not-found >/dev/null
  k apply -f "$K8S/after/30-tenant-rbac.yaml" >/dev/null
  info "즉시 확인 → A 운영자: tenant-a Pod 조회=$(cani hannctl-s2-tenant-a list pods tenant-a), tenant-b Pod 조회=$(cani hannctl-s2-tenant-a list pods tenant-b), Secret 조회=$(cani hannctl-s2-tenant-a get secrets tenant-a)"
}
step_pod_security() {
  show_manifest "$K8S/policies/kyverno-baseline.yaml" 22
  cmdline "kubectl label ns tenant-a tenant-b pod-security.kubernetes.io/enforce=restricted hannctl.io/protected=true"
  for t in a b; do
    k label ns "tenant-$t" pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=latest hannctl.io/protected=true --overwrite >/dev/null
  done
  cmdline "kubectl apply -f k8s/policies/kyverno-baseline.yaml"
  k apply -f "$K8S/policies/kyverno-baseline.yaml" >/dev/null
  wait_policies
  info "즉시 확인 → privileged Pod: $(admission_try tenant-a < "$K8S/attack/privileged-pod.yaml"), 기존 정상 Pod: $(k -n tenant-a get pods --no-headers | awk '{print $3}' | sort | uniq -c | tr -s ' ' | tr '\n' ' ')"
}
scenario_after() {
  improve 1 4 "네트워크 기본 차단(default-deny)" "tenant-a/b 에 Ingress+Egress 전부 차단 NetworkPolicy" "명시하지 않은 모든 Pod 통신 차단(화이트리스트 방식의 출발점)" step_default_deny \
    "podSelector: {} 는 'Namespace 의 모든 Pod' 를 뜻한다. 허용 규칙 없이 차단만 걸면 정상 통신과 DNS 까지 끊긴다"
  improve 2 4 "필요한 통신만 허용(allow-list)" "DNS(53) + 같은 테넌트 web→api(8080) 만 허용" "정상 서비스 복구, 고객사 간 통신은 계속 차단" step_allow_required \
    "NetworkPolicy 는 '허용 규칙의 합집합'이다. 허용한 경로만 열리고, 다른 테넌트로 가는 경로는 규칙이 없으니 계속 막힌다"
  improve 3 4 "운영자 권한 최소화(RBAC)" "클러스터 전체 edit 바인딩 삭제 → 테넌트별 Role/RoleBinding" "A 운영자는 A 만, Secret 조회 불가" step_rbac \
    "ClusterRoleBinding = 클러스터 전체, RoleBinding = 그 Namespace 만. IAM Role → Access Entry(그룹) → RoleBinding 순서로 권한이 결정된다"
  improve 4 4 "위험 Pod 차단(PSA restricted + Kyverno)" "Namespace 에 PSA restricted 라벨 + Kyverno ValidatingPolicy 3개" "privileged/hostPath/root Pod 생성 요청 거부" step_pod_security \
    "Admission 은 '만들어지기 전에' 거부한다. 이미 실행 중인 정상 Pod 는 그대로 동작하고, 새로 만드는 위험한 Pod 만 막힌다"
}

scenario_watch() { # ./run.sh watch 화면: 격리 현황 + NetworkPolicy + Kyverno 정책 (Before → After 변화가 한눈에 보이도록)
  scenario_status
  section "NetworkPolicy (Before: 없음 → 개선 1: default-deny → 개선 2: allow-list 추가)"
  k get networkpolicy -A -l hannctl.io/scenario=s2 2>&1
  section "Kyverno ValidatingPolicy (개선 4 이후 3개 READY)"
  k get validatingpolicy 2>&1
}

scenario_status() {
  section "테넌트 격리 현황"
  k get ns -l hannctl.io/scenario=s2 -L pod-security.kubernetes.io/enforce,hannctl.io/protected
  k get pods -n tenant-a -o wide 2>/dev/null | cut -c1-120; k get pods -n tenant-b -o wide 2>/dev/null | cut -c1-120
  k get rolebinding,clusterrolebinding -A -l hannctl.io/scenario=s2 2>/dev/null
}

dispatch "$@"
