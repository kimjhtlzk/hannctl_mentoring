#!/usr/bin/env bash
# =============================================================================
# 시나리오 5 — 기업 내부 API 의 인증정보 보호와 최소 권한 (OfficeLink)
#   ./run.sh demo   : 인프라 생성 → Before 재현/테스트 → (N초 후) 단계별 개선 → After 테스트 → 채점/보고서
#   ./run.sh down   : 전부 삭제
# =============================================================================
SCENARIO_ID="s5"
SCENARIO_TITLE="시나리오 5 · 내부 API 인증정보 보호와 최소 권한 (OfficeLink)"
STACK="hannctl-s5-office"
CLUSTER="hannctl-s5-office"
# 시간당 예상 비용(서울 온디맨드 기준 보수적): EKS 0.10 + Spot 노드 1대 ~0.042 + NAT 0.059 + 공인IP 0.005 + Secret 2개 비례 ~0.001
#  → 스택 태그 hannctl:est-usd-per-hour 로 기록, janitor 가 월 누적 예상치가 상한에 닿으면 hannctl 스택 정리
HOURLY_USD="0.21"
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
K8S="$SCEN_DIR/k8s"
NS=office
LEGACY_USER="hannctl-s5-legacy-app"
SECRET_OK="hannctl/s5/allowed"
SECRET_NO="hannctl/s5/restricted"
ID_LEGACY="user/$LEGACY_USER"
ID_READER="role/$CLUSTER-app-reader"
ID_NOSECRET="role/$CLUSTER-no-secret"
: "${CLOUDTRAIL_WAIT_SECONDS:=600}"   # CloudTrail 이벤트 기록 지연(보통 5분 내외, 최대 ~15분)

stack_params() {
  # 사양 파라미터는 항상 명시 (aws cloudformation deploy 는 기존 스택의 이전 값을 재사용하기 때문)
  echo "ClusterName=$CLUSTER DeployerPrincipalArn=$(deployer_arn) EndpointAllowedCidr=$(my_ip_cidr)" \
       "NodeCapacityType=${HANNCTL_CAPACITY:-ON_DEMAND} NodeDesired=1"
}

role_contexts() { # 개발자/운영자 IAM Role 로 접속하는 kubeconfig 컨텍스트
  add_role_context hannctl-s5-developer "$(stack_output "$STACK" DeveloperRoleArn)"
  add_role_context hannctl-s5-operator "$(stack_output "$STACK" OperatorRoleArn)"
}

# 파일에서 "핵심 줄"만 골라 보여준다 (show_manifest 의 축약판): show_keylines FILE 'REGEX'
show_keylines() {
  printf '%s┃  📄 %s (핵심 줄)%s\n' "$C_C" "${1#$SCEN_DIR/}" "$C_0"
  grep -n -E "$2" "$1" | sed "s/^/${C_DIM}┃     /;s/\$/${C_0}/"
}

mask() { python3 -c 'import sys;s=sys.argv[1];print(s[:4]+"****" if len(s)>4 else "****")' "$1"; }

scenario_up() {
  install_kyverno
  role_contexts
  section "OfficeLink 기본 구성 (Namespace, ServiceAccount, 사내 포털 web)"
  k create namespace "$NS" --dry-run=client -o yaml | k apply -f - >/dev/null
  k -n "$NS" create configmap officelink-app --from-file="$SCEN_DIR/app/app.py" --dry-run=client -o yaml | k apply -f - >/dev/null
  # 리전/비밀값 이름은 ConfigMap 으로 주입 (코드·YAML 에 하드코딩하지 않음)
  k -n "$NS" create configmap officelink-config --from-literal=AWS_REGION="$HANNCTL_REGION" \
    --from-literal=AWS_DEFAULT_REGION="$HANNCTL_REGION" --from-literal=ALLOWED_SECRET="$SECRET_OK" \
    --from-literal=RESTRICTED_SECRET="$SECRET_NO" --dry-run=client -o yaml | k apply -f - >/dev/null
  k apply -f "$K8S/base/" >/dev/null
  k -n "$NS" rollout status deploy/office-web --timeout=300s >/dev/null || die "office-web 기동 실패"
  ok "office Namespace 준비 (SA app-reader/no-access ↔ Pod Identity 연결은 CloudFormation 이 생성)"
}

# ----------------------------------------------------------------------------- 정적 키
issue_static_key() { # 레거시 공용 IAM User 의 Access Key 발급 → K8s Secret (화면/파일에 원문을 남기지 않음)
  for kid in $(aws iam list-access-keys --user-name "$LEGACY_USER" --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
    aws iam delete-access-key --user-name "$LEGACY_USER" --access-key-id "$kid"
  done
  cmdline "aws iam create-access-key --user-name $LEGACY_USER | kubectl create secret generic legacy-aws-credentials ..."
  aws iam create-access-key --user-name "$LEGACY_USER" --output json \
    | python3 -c 'import json,sys;k=json.load(sys.stdin)["AccessKey"];print("AWS_ACCESS_KEY_ID="+k["AccessKeyId"]);print("AWS_SECRET_ACCESS_KEY="+k["SecretAccessKey"])' \
    | k -n "$NS" create secret generic legacy-aws-credentials --from-env-file=/dev/stdin --dry-run=client -o yaml \
    | k apply -f - >/dev/null || die "정적 키 Secret 생성 실패"
  k -n "$NS" label secret legacy-aws-credentials hannctl.io/scenario=s5 --overwrite >/dev/null
  local kid; kid=$(aws iam list-access-keys --user-name "$LEGACY_USER" --query 'AccessKeyMetadata[0].AccessKeyId' --output text)
  warn "정적 Access Key 발급됨: $(mask "$kid") (Before 재현용 — After 에서 폐기)"
}
static_cred_state() { # → STATIC_STATE(PRESENT|NONE), STATIC_METRIC 설정 (서브셸 없이 호출)
  local keys sec refs
  keys=$(aws iam list-access-keys --user-name "$LEGACY_USER" --query 'length(AccessKeyMetadata)' --output text 2>/dev/null || echo 0)
  sec=$(k -n "$NS" get secret legacy-aws-credentials --no-headers 2>/dev/null | wc -l | tr -d ' ')
  refs=$(k -n "$NS" get deploy -o json | python3 -c 'import json,sys;d=json.load(sys.stdin);print(sum(1 for x in d["items"] if "legacy-aws-credentials" in json.dumps(x["spec"]["template"]["spec"])))')
  STATIC_METRIC="IAM 정적키 ${keys}개 · K8s Secret ${sec}개 · 참조 Deployment ${refs}개"
  if [ "$keys" = 0 ] && [ "$sec" = 0 ] && [ "$refs" = 0 ]; then STATIC_STATE=NONE; else STATIC_STATE=PRESENT; fi
}

# ----------------------------------------------------------------------------- BEFORE
scenario_before() {
  role_contexts
  section "Before 상태로 되돌리기 (공용 정적 키 · 과다 RBAC · 정책 없음)"
  k -n "$NS" delete networkpolicy --all >/dev/null 2>&1
  k delete -f "$K8S/after/30-rbac.yaml" --ignore-not-found >/dev/null 2>&1
  k delete -f "$K8S/policies/kyverno-baseline.yaml" --ignore-not-found >/dev/null 2>&1
  k label ns "$NS" pod-security.kubernetes.io/enforce- pod-security.kubernetes.io/enforce-version- hannctl.io/protected- >/dev/null 2>&1
  issue_static_key
  k apply -f "$K8S/before/" >/dev/null
  for d in office-api intruder; do k -n "$NS" rollout status "deploy/$d" --timeout=300s >/dev/null || die "$d 기동 실패"; done
  date +%s > "$RUN_DIR/start_epoch"
  info "새 Access Key 전파 대기 (IAM 은 최종 일관성 — 약 10초)"; sleep 12
  ok "Before 적용: office-api 와 intruder 가 같은 공용 키 사용, 개발자/운영자 cluster-admin"
  EV_LINES=8 ev before 00-deploy-env-sources -- kubectl --context "$CLUSTER" -n "$NS" get deploy -o custom-columns=NAME:.metadata.name,SA:.spec.template.spec.serviceAccountName,ENV_FROM:.spec.template.spec.containers[0].envFrom[*]
}

# ----------------------------------------------------------------------------- 테스트 (Before/After 동일)
# Pod 안에서 앱 CLI 실행. 빈 응답이면(Spot 노드 교체 등으로 Pod 재시작 중) 준비될 때까지 기다렸다가 1회 재시도
in_pod() {
  local out; out=$(k -n "$NS" exec "deploy/$1" -- python3 /app/app.py "${@:2}" 2>/dev/null | tail -1)
  if [ -z "$out" ]; then
    k -n "$NS" rollout status "deploy/$1" --timeout=300s >/dev/null 2>&1
    k -n "$NS" wait --for=condition=Ready pod -l "app=$1" --timeout=120s >/dev/null 2>&1
    out=$(k -n "$NS" exec "deploy/$1" -- python3 /app/app.py "${@:2}" 2>/dev/null | tail -1)
  fi
  echo "${out:-ERROR}"
}
cani() { local r; r=$(kubectl --context "$1" auth can-i "$2" "$3" -n "${4:-$NS}" 2>/dev/null); echo "${r:-no}"; }

cred_tests() {
  local p=$1
  [ "$p" = before ] && lesson "공용 정적 키 하나를 모든 Pod 가 공유 → 하나만 뚫려도 키가 새고, AWS 기록에는 모두 같은 user 로 찍혀 누가 썼는지 모른다"
  static_cred_state
  record static_creds "$p" "$([ "$p" = before ] && echo PRESENT || echo NONE)" "$STATIC_STATE" "정적 Access Key 존재 여부" "$STATIC_METRIC"
  record api_identity "$p" "$([ "$p" = before ] && echo "$ID_LEGACY" || echo "$ID_READER")" "$(in_pod office-api whoami)" "업무 API 의 AWS 신원"
  record intruder_identity "$p" "$([ "$p" = before ] && echo "$ID_LEGACY" || echo "$ID_NOSECRET")" "$(in_pod intruder whoami)" "비인가 Pod 의 AWS 신원"
}
secret_tests() {
  local p=$1 deny=ACCESS_DENIED; [ "$p" = before ] && deny=OK
  [ "$p" = before ] && lesson "권한이 '사람(IAM User)' 기준이라 Pod 를 구분하지 못한다 → 업무와 무관한 Pod 도 모든 Secret 을 읽는다"
  record api_allowed "$p" OK "$(in_pod office-api check "$SECRET_OK")" "정상: 업무 API → allowed Secret"
  record api_restricted "$p" "$deny" "$(in_pod office-api check "$SECRET_NO")" "차단: 업무 API → restricted Secret"
  record intruder_allowed "$p" "$deny" "$(in_pod intruder check "$SECRET_OK")" "차단: 비인가 Pod → allowed Secret"
  record intruder_restricted "$p" "$deny" "$(in_pod intruder check "$SECRET_NO")" "차단: 비인가 Pod → restricted Secret"
  record imds_bypass "$p" BLOCKED "$(in_pod intruder imds)" "차단: Pod → 노드 IMDS(노드 역할 우회)"
  local blocked=0 scope=0 r sec
  for sec in "$SECRET_OK" "$SECRET_NO"; do
    r=$(in_pod intruder check "$sec"); [ "$r" != OK ] && blocked=$((blocked+1))
    r=$(in_pod office-api check "$sec"); [ "$r" = OK ] && scope=$((scope+1))
  done
  info "비인가 Secret 접근 차단률: $blocked/2 · 업무 API 가 읽을 수 있는 Secret: $scope/2"
}
rbac_tests() {
  local p=$1 deny=no; [ "$p" = before ] && deny=yes
  [ "$p" = before ] && lesson "cluster-admin 은 K8s Secret(=정적 키)까지 읽는다. 사람 권한이 넓으면 IAM 을 아무리 좁혀도 우회된다"
  local DEV=hannctl-s5-developer OPS=hannctl-s5-operator
  record dev_get_pods "$p" yes "$(cani $DEV list pods)" "정상: 개발자 → Pod 조회"
  record dev_delete_deploy "$p" "$deny" "$(cani $DEV delete deployments)" "차단: 개발자 → Deployment 삭제"
  record dev_get_secrets "$p" "$deny" "$(cani $DEV get secrets)" "차단: 개발자 → K8s Secret 조회"
  record dev_cluster_admin "$p" "$deny" "$(cani $DEV create clusterrolebindings)" "차단: 개발자 → 권한 상승(CRB 생성)"
  record ops_patch_deploy "$p" yes "$(cani $OPS patch deployments)" "정상: 운영자 → 배포 재시작"
  record ops_get_secrets "$p" "$deny" "$(cani $OPS get secrets)" "차단: 운영자 → K8s Secret 조회"
  record ops_other_ns "$p" "$deny" "$(cani $OPS list pods kube-system)" "차단: 운영자 → 다른 Namespace"
  # 실제 요청(서버측 dry-run) — 감사 로그에 403 이 남는다
  EV_LINES=4 ev "$p" rbac-developer-delete-deploy -- kubectl --context $DEV -n "$NS" delete deploy office-api --dry-run=server
  EV_LINES=4 ev "$p" rbac-developer-get-secrets -- kubectl --context $DEV -n "$NS" get secrets
}
net_tests() {
  local p=$1 deny=BLOCKED; [ "$p" = before ] && deny=200
  local URL="http://office-api.$NS.svc.cluster.local/health"
  record web_to_api "$p" 200 "$(in_pod office-web probe "$URL" 4)" "정상: 사내 포털 → 업무 API"
  record intruder_to_api "$p" "$deny" "$(in_pod intruder probe "$URL" 4)" "차단: 비인가 Pod → 업무 API"
}
pod_tests() {
  local p=$1 exp=DENIED; [ "$p" = before ] && exp=ALLOWED
  local r f
  for f in privileged hostpath root; do
    r=$(admission_try "$NS" "$RUN_DIR/$p/admission-$f.txt" < "$K8S/attack/$f-pod.yaml")
    record "$f" "$p" "$exp" "$r" "차단: $f Pod 생성"
  done
  [ "$p" = after ] && { info "거부 메시지 예시:"; head -2 "$RUN_DIR/$p/admission-privileged.txt" | cut -c1-200 | sed 's/^/      /'; }
}
infra_tests() {
  local p=$1
  record cluster_ready "$p" ACTIVE "$(aws eks describe-cluster --name "$CLUSTER" --query cluster.status --output text)" "인프라: EKS 클러스터 ACTIVE"
  record pod_identity_agent "$p" ACTIVE "$(aws eks describe-addon --cluster-name "$CLUSTER" --addon-name eks-pod-identity-agent --query addon.status --output text)" "인프라: Pod Identity Agent"
  record pod_identity_assoc "$p" 2 "$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER" --namespace "$NS" --query 'length(associations)' --output text)" "인프라: SA↔IAM Role 연결 2개"
  tag_audit "$p"
  finops_audit "$p"
}

audit_test() { # EKS 감사 로그(CloudWatch) — 개발자의 거부(403) 요청
  local p=$1 found=NOT_FOUND start; start=$(( ($(date +%s) - 900) * 1000 ))
  info "CloudWatch(EKS audit)에서 office-developer 의 403 이벤트 조회 (수집 지연 최대 ~3분)"
  for _ in 1 2 3 4 5 6 7 8 9; do
    aws logs filter-log-events --log-group-name "/aws/eks/$CLUSTER/cluster" --log-stream-name-prefix kube-apiserver-audit \
      --start-time "$start" --filter-pattern '{ $.user.username = "office-developer" && $.responseStatus.code = 403 }' \
      --max-items 5 --output json 2>/dev/null > "$RUN_DIR/$p/.audit-raw.json"
    local n; n=$(python3 - "$RUN_DIR/$p/.audit-raw.json" "$RUN_DIR/$p/eks-audit-403.txt" <<'PY'
import json, sys
try:
    ev = json.load(open(sys.argv[1])).get("events", [])
except Exception:
    ev = []
with open(sys.argv[2], "w") as f:   # 계정 정보 없이 요약만 저장
    for e in ev:
        m = json.loads(e["message"])
        f.write(f'{m.get("stageTimestamp")} user={m["user"]["username"]} verb={m.get("verb")} resource={m.get("objectRef",{}).get("resource")} ns={m.get("objectRef",{}).get("namespace")} code={m["responseStatus"]["code"]}\n')
print(len(ev))
PY
)
    rm -f "$RUN_DIR/$p/.audit-raw.json"
    [ "$n" != 0 ] && { found=FOUND; break; }
    sleep 20
  done
  record audit_forbidden "$p" FOUND "$found" "감사: K8s 거부 요청 → EKS audit(CloudWatch)"
}

cloudtrail_test() { # AWS API 감사(CloudTrail) — 누가 어떤 신원으로 Secret 을 읽었나
  local p=$1 start found=NOT_FOUND waited=0 res
  start=$(cat "$RUN_DIR/start_epoch" 2>/dev/null || echo $(( $(date +%s) - 3600 )))
  info "CloudTrail Event history 에서 GetSecretValue 조회 (기록 지연 최대 ~15분, 최대 ${CLOUDTRAIL_WAIT_SECONDS}s 대기)"
  while :; do
    # 원본(JSON)에는 계정 ID·키 ID 가 있으므로 임시 파일로만 쓰고 요약만 남긴 뒤 지운다
    aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=GetSecretValue \
      --start-time "$start" --max-items 500 --output json > "$RUN_DIR/$p/.ct-raw.json" 2>/dev/null
    res=$(python3 - "$RUN_DIR/$p/.ct-raw.json" "$RUN_DIR/$p/cloudtrail-getsecretvalue.txt" "$CLUSTER" "$LEGACY_USER" <<'PY'
import json, sys
raw, out, cluster, legacy = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    events = json.load(open(raw)).get("Events", [])
except Exception:
    events = []
rows, cnt = [], {"legacy": 0, "reader": 0, "denied": 0}
for e in events:
    d = json.loads(e["CloudTrailEvent"])
    arn = d.get("userIdentity", {}).get("arn", "")
    sid = str((d.get("requestParameters") or {}).get("secretId", ""))
    if "hannctl/s5/" not in sid:
        continue
    who = arn.split(":")[-1]                       # 계정 ID 제거: user/... 또는 assumed-role/<role>/<session>
    who = "/".join(who.split("/")[:2])
    secret = "hannctl/s5/" + sid.split("hannctl/s5/")[1].split("-")[0]
    err = d.get("errorCode", "") or "OK"
    if legacy in who: cnt["legacy"] += 1
    if f"{cluster}-app-reader" in who and err == "OK": cnt["reader"] += 1
    if err != "OK": cnt["denied"] += 1
    rows.append(f'{d["eventTime"]}  {who:45} {secret:24} {err}')
open(out, "w").write("\n".join(sorted(rows)) + "\n")
print(("FOUND" if cnt["reader"] and cnt["legacy"] else "NOT_FOUND") + f'|공용키 조회 {cnt["legacy"]}건 · app-reader 조회 {cnt["reader"]}건 · 거부 {cnt["denied"]}건')
PY
)
    rm -f "$RUN_DIR/$p/.ct-raw.json"
    found=${res%%|*}
    [ "$found" = FOUND ] && break
    [ "$waited" -ge "$CLOUDTRAIL_WAIT_SECONDS" ] && break
    printf '\r      … 아직 기록 전 (%ss 경과) %s' "$waited" "${res#*|}"; sleep 30; waited=$((waited + 30))
  done
  echo
  record cloudtrail_secret_access "$p" FOUND "$found" "감사: Secret 접근 → CloudTrail(신원별)" "${res#*|}"
  head -8 "$RUN_DIR/$p/cloudtrail-getsecretvalue.txt" | sed 's/^/      /'
}

scenario_tests() {
  local p=$1
  section "[$p] 1) 자격증명: 정적 키가 남아 있나, 각 Pod 는 어떤 AWS 신원인가"
  cred_tests "$p"
  section "[$p] 2) Secret 접근: 승인 Pod 는 필요한 것만, 비인가 Pod 는 AccessDenied"
  secret_tests "$p"
  section "[$p] 3) 사람 권한: 개발자/운영자 IAM Role → Kubernetes RBAC"
  rbac_tests "$p"
  section "[$p] 4) 네트워크: 업무 API 에 누가 접근하나"
  net_tests "$p"
  section "[$p] 5) Pod 보안: 위험 Pod 생성 시도 (서버측 dry-run)"
  pod_tests "$p"
  section "[$p] 6) 인프라 · 식별자 · FinOps"
  infra_tests "$p"
  if [ "$p" = after ]; then
    section "[$p] 7) 감사 증적 — EKS audit(쿠버네티스 API) vs CloudTrail(AWS API)"
    audit_test "$p"
    cloudtrail_test "$p"
  fi
  timeline "$p" "$p 테스트 완료" "$(grep -c "\"phase\": \"$p\"" "$RUN_DIR/results.jsonl") 개 항목"
}

# ----------------------------------------------------------------------------- AFTER (단계별 개선)
step_pod_identity() {
  show_keylines "$SCEN_DIR/cfn/stack.yaml" 'AppReaderAssociation:|NoSecretAssociation:|ServiceAccount: (app-reader|no-access)|RoleArn: !GetAtt (AppReader|NoSecret)|Service: pods.eks.amazonaws.com|Resource: !Ref AllowedSecret$'
  show_keylines "$K8S/after/10-workloads-pod-identity.yaml" 'name: (office-api|intruder)$|serviceAccountName|envFrom|configMapRef|secretRef'
  cmdline "kubectl apply -f k8s/after/10-workloads-pod-identity.yaml"
  k apply -f "$K8S/after/10-workloads-pod-identity.yaml" >/dev/null
  for d in office-api intruder; do k -n "$NS" rollout status "deploy/$d" --timeout=300s >/dev/null; done
  info "즉시 확인 → 업무 API 신원: $(in_pod office-api whoami) | allowed: $(in_pod office-api check "$SECRET_OK") | restricted: $(in_pod office-api check "$SECRET_NO")"
  info "             비인가 Pod 신원: $(in_pod intruder whoami) | allowed: $(in_pod intruder check "$SECRET_OK")"
  info "             EKS 가 Pod 에 주입한 자격증명 주소: $(k -n "$NS" exec deploy/office-api -- printenv AWS_CONTAINER_CREDENTIALS_FULL_URI 2>/dev/null)"
}
step_revoke_static_key() {
  local kid
  show_keylines "$SCEN_DIR/cfn/stack.yaml" 'UserName: hannctl-s5-legacy-app|Resource: \[!Ref AllowedSecret, !Ref RestrictedSecret\]'

  for kid in $(aws iam list-access-keys --user-name "$LEGACY_USER" --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
    cmdline "aws iam delete-access-key --user-name $LEGACY_USER --access-key-id $(mask "$kid")"
    aws iam delete-access-key --user-name "$LEGACY_USER" --access-key-id "$kid"
  done
  cmdline "kubectl -n office delete secret legacy-aws-credentials"
  k -n "$NS" delete secret legacy-aws-credentials --ignore-not-found >/dev/null
  static_cred_state
  info "즉시 확인 → 정적 자격증명 $STATIC_STATE ($STATIC_METRIC) | 업무 API 는 계속 정상: $(in_pod office-api check "$SECRET_OK")"
}
step_rbac() {
  show_keylines "$K8S/before/20-legacy-rbac.yaml" 'name: cluster-admin|name: "hannctl:office'
  show_manifest "$K8S/after/30-rbac.yaml" 22
  cmdline "kubectl delete clusterrolebinding hannctl-legacy-office-admins && kubectl apply -f k8s/after/30-rbac.yaml"
  k delete -f "$K8S/before/20-legacy-rbac.yaml" --ignore-not-found >/dev/null
  k apply -f "$K8S/after/30-rbac.yaml" >/dev/null
  info "즉시 확인 → 개발자: 조회=$(cani hannctl-s5-developer list pods) 삭제=$(cani hannctl-s5-developer delete deployments) Secret=$(cani hannctl-s5-developer get secrets) | 운영자: 재시작=$(cani hannctl-s5-operator patch deployments) Secret=$(cani hannctl-s5-operator get secrets)"
}
step_pod_security() {
  show_keylines "$K8S/policies/kyverno-baseline.yaml" '^kind:|name: hannctl-|validationActions|expression: "|message:'
  cmdline "kubectl label ns office pod-security.kubernetes.io/enforce=restricted hannctl.io/protected=true"
  k label ns "$NS" pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=latest hannctl.io/protected=true --overwrite >/dev/null
  cmdline "kubectl apply -f k8s/policies/kyverno-baseline.yaml"
  k apply -f "$K8S/policies/kyverno-baseline.yaml" >/dev/null
  wait_policies
  info "즉시 확인 → privileged Pod: $(admission_try "$NS" "$RUN_DIR/after/admission-step4.txt" < "$K8S/attack/privileged-pod.yaml") | 기존 Pod: $(k -n "$NS" get pods --no-headers | awk '{print $3}' | sort | uniq -c | tr -s ' ' | tr '\n' ' ')"
}
step_network() {
  show_keylines "$K8S/after/50-networkpolicy.yaml" '^# |name: (default-deny-all|allow-)|policyTypes|cidr:|port: (53|80|443|8080)|access: office-api'
  cmdline "kubectl apply -f k8s/after/50-networkpolicy.yaml"
  k apply -f "$K8S/after/50-networkpolicy.yaml" >/dev/null; sleep 10
  local URL="http://office-api.$NS.svc.cluster.local/health"
  info "즉시 확인 → 포털→API: $(in_pod office-web probe "$URL" 3) | 비인가→API: $(in_pod intruder probe "$URL" 3) | 업무 API→Secrets Manager: $(in_pod office-api check "$SECRET_OK")"
}
scenario_after() {
  improve 1 5 "Pod Identity 전환" "office-api → SA app-reader, intruder → SA no-access (키 참조 제거)" "Pod 마다 다른 IAM Role, 임시 자격증명 자동 교체" step_pod_identity \
    "Pod 는 키를 갖지 않는다. ServiceAccount 에 연결된 IAM Role 의 임시 자격증명을 EKS 가 주입할 뿐 — 코드는 그대로(표준 자격증명 체인)"
  improve 2 5 "정적 Access Key 폐기" "공용 IAM User 의 Access Key 삭제 + K8s Secret 삭제" "유출돼도 쓸 수 있는 장기 키가 0개" step_revoke_static_key \
    "전환 → 검증 → 폐기 순서. 옛 키를 먼저 지우면 서비스가 끊긴다(무중단 자격증명 교체 절차)"
  improve 3 5 "사람 권한 최소화(RBAC)" "cluster-admin 바인딩 삭제 → 개발자 view, 운영자 워크로드 관리" "개발자는 읽기만, 누구도 Secret 조회 불가" step_rbac \
    "IAM(=AWS 권한)과 RBAC(=K8s 권한)은 별개. EKS Access Entry 가 IAM Role 을 K8s 그룹으로 이어 주고, 권한은 RoleBinding 이 정한다"
  improve 4 5 "위험 Pod 차단(PSA + Kyverno)" "office 에 PSA restricted 라벨 + Kyverno 3개 정책" "privileged/hostPath/root Pod 거부" step_pod_security \
    "노드를 장악하면 그 노드의 모든 Pod 자격증명이 위험하다 → 위험 Pod 는 '만들어지기 전에' 거부"
  improve 5 5 "네트워크 최소화(NetworkPolicy)" "default-deny + DNS/AWS API(443)/Pod Identity Agent/포털→API 만 허용" "비인가 Pod 는 업무 API 호출 불가, IMDS 도 차단" step_network \
    "default-deny 후에는 '필요한 출구'를 직접 열어야 한다 — Pod Identity Agent(169.254.170.23)를 빼먹으면 자격증명을 못 받는다"
}

scenario_status() {
  section "OfficeLink 현황"
  k -n "$NS" get deploy -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,SERVICE_ACCOUNT:.spec.template.spec.serviceAccountName 2>/dev/null
  static_cred_state 2>/dev/null
  printf '  정적 키 상태: %s (%s)\n' "$STATIC_STATE" "$STATIC_METRIC"
  aws eks list-pod-identity-associations --cluster-name "$CLUSTER" --query 'associations[].[namespace,serviceAccount]' --output text 2>/dev/null | sed 's/^/  Pod Identity: /'
  k -n "$NS" get networkpolicy 2>/dev/null
  k get clusterrolebinding,rolebinding -A -l hannctl.io/scenario=s5 2>/dev/null
  k get validatingpolicy 2>/dev/null
}
scenario_watch() { scenario_status; }

dispatch "$@"
