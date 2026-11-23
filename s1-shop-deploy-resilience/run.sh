#!/usr/bin/env bash
# =============================================================================
# 시나리오 1 — 온라인 쇼핑몰의 안전한 배포 및 장애 대응 (ShopNow)
#   ./run.sh demo     : 인프라 생성 → Before 재현/테스트 → (N초 후) 단계별 개선 → After 테스트 → 채점/보고서
#   ./run.sh grafana  : Grafana 접속 (port-forward, 로그인 정보 출력)
#   ./run.sh down     : 전부 삭제
# =============================================================================
SCENARIO_ID="s1"
SCENARIO_TITLE="시나리오 1 · 쇼핑몰 안전한 배포·장애 대응 (ShopNow)"
STACK="hannctl-s1-shop"
CLUSTER="hannctl-s1-shop"
HOURLY_USD="0.25"            # 예상 시간당 비용(온디맨드 기준): EKS 0.10 + NAT 0.059 + 공인IP 0.005 + t4g.large 0.083 + CodeBuild 사용분
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
K8S="$SCEN_DIR/k8s"
SVC="http://shop-api.shop.svc.cluster.local"
CI_PROJECT="hannctl-s1-ci"
ECR_REPO="hannctl-s1-shop-api"
: "${LOAD_SECONDS:=150}"     # 부하 테스트 시간(초)
: "${LOAD_CONC:=16}"         # 동시 요청 수

stack_params() {
  # 사양 파라미터는 항상 명시 (aws cloudformation deploy 는 기존 스택의 이전 값을 재사용하기 때문)
  echo "ClusterName=$CLUSTER DeployerPrincipalArn=$(deployer_arn) EndpointAllowedCidr=$(my_ip_cidr)" \
       "NodeCapacityType=${HANNCTL_CAPACITY:-ON_DEMAND} NodeDesired=1"
}
repo_uri() { stack_output "$STACK" EcrRepoUri; }
node_count() { k get nodes --no-headers 2>/dev/null | grep -c " Ready"; }
ready_pods() { local r; r=$(k -n shop get deploy shop-api -o jsonpath='{.status.readyReplicas}' 2>/dev/null); echo "${r:-0}"; }
loadgen() { k -n shop-loadtest exec deploy/loadgen -- python3 /app/app.py "$@" 2>/dev/null; }
json_field() { python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1]))[sys.argv[2]])
except Exception: print("")' "$1" "$2"; }

# ----------------------------------------------------------------------------- CI (CodeBuild)
ci_upload() { # app/ 폴더를 zip 으로 만들어 S3 소스 버킷에 업로드
  mkdir -p "$SCEN_DIR/.build"
  python3 - "$SCEN_DIR/app" "$SCEN_DIR/.build/source.zip" <<'PY'
import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for f in os.listdir(src):
        z.write(os.path.join(src, f), f)
PY
  aws s3 cp "$SCEN_DIR/.build/source.zip" "s3://$(stack_output "$STACK" SourceBucket)/source.zip" >/dev/null
}
ci_start() { # ci_start TAG VARIANT FAIL_MODE → build id
  aws codebuild start-build --project-name "$CI_PROJECT" --query build.id --output text \
    --environment-variables-override "name=IMAGE_TAG,value=$1,type=PLAINTEXT" \
      "name=VARIANT,value=$2,type=PLAINTEXT" "name=FAIL_MODE,value=$3,type=PLAINTEXT"
}
ci_wait() { # ci_wait BUILD_ID → SUCCEEDED / FAILED ...
  local st
  while :; do
    st=$(aws codebuild batch-get-builds --ids "$1" --query 'builds[0].buildStatus' --output text)
    [ "$st" != "IN_PROGRESS" ] && break
    sleep 10
  done
  echo "$st"
}
ci_seconds() {
  aws codebuild batch-get-builds --ids "$1" --query 'builds[0].[startTime,endTime]' --output text |
    python3 -c 'import sys,datetime as d;a,b=sys.stdin.read().split();f=d.datetime.fromisoformat;print(int((f(b)-f(a)).total_seconds()))' 2>/dev/null
}
ci_log() { # ci_log BUILD_ID FILE — 빌드 로그(Trivy 결과 포함) 저장
  local g s
  g=$(aws codebuild batch-get-builds --ids "$1" --query 'builds[0].logs.groupName' --output text)
  s=$(aws codebuild batch-get-builds --ids "$1" --query 'builds[0].logs.streamName' --output text)
  aws logs get-log-events --log-group-name "$g" --log-stream-name "$s" --query 'events[].message' --output text 2>/dev/null | tr '\t' '\n' > "$2"
}
ecr_has() { aws ecr describe-images --repository-name "$ECR_REPO" --image-ids "imageTag=$1" >/dev/null 2>&1 && echo yes || echo no; }
ecr_untag() { aws ecr batch-delete-image --repository-name "$ECR_REPO" --image-ids "imageTag=$1" >/dev/null 2>&1 || true; }

gate_state() { aws cloudformation describe-stacks --stack-name "$STACK" --query "Stacks[0].Parameters[?ParameterKey=='CiSecurityGate'].ParameterValue" --output text; }
set_gate() { # set_gate on|off — CloudFormation 파라미터만 바꿔 CodeBuild 의 GATE 값을 전환 (IaC 로 파이프라인 변경)
  [ "$(gate_state)" = "$1" ] && { info "CI 보안 게이트 이미 $1"; return 0; }
  stack_set_params "CiSecurityGate=$1"
  ok "CI 보안 게이트 → $1"
}

# ----------------------------------------------------------------------------- 설치 (up)
install_monitoring() {
  section "Prometheus + Grafana (kube-prometheus-stack) 설치"
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update prometheus-community >/dev/null 2>&1 || true
  helm upgrade --install kps prometheus-community/kube-prometheus-stack --kube-context "$CLUSTER" -n monitoring --create-namespace \
    --version 93.2.0 -f "$K8S/monitoring-values.yaml" --set fullnameOverride=kps --wait --timeout 15m >/dev/null || die "모니터링 설치 실패"
  ok "Prometheus/Grafana 준비 (./run.sh grafana 로 접속)"
}
apply_deploy() { # apply_deploy FILE TAG
  sed "s#__IMAGE__#$(repo_uri):$2#" "$1" | k apply -f - >/dev/null
}
scenario_up() {
  section "CI: 이미지 빌드 (v1 정상, v2-bad 버그 버전) — CodeBuild 에서 병렬 실행"
  ci_upload
  local b1 b2; b1=$(ci_start v1 secure 0); b2=$(ci_start v2-bad secure 1)
  info "빌드 시작: $b1 / $b2"
  install_kyverno
  install_monitoring
  section "ShopNow 기본 리소스"
  k apply -f "$K8S/base/shop.yaml" >/dev/null
  k -n shop-loadtest create configmap shop-app --from-file="$SCEN_DIR/app/app.py" --dry-run=client -o yaml | k apply -f - >/dev/null
  info "이미지 빌드 대기…"
  [ "$(ci_wait "$b1")" = SUCCEEDED ] && [ "$(ci_wait "$b2")" = SUCCEEDED ] || die "초기 이미지 빌드 실패 (CodeBuild 콘솔 hannctl-s1-ci 확인)"
  ok "ECR 이미지: v1, v2-bad"
  if k -n shop get deploy shop-api >/dev/null 2>&1; then   # README 6장처럼 직접 구성한 환경: 이미 배포한 설정을 덮어쓰지 않는다
    info "shop-api 가 이미 배포되어 있어 현재 설정을 그대로 둡니다"
  else
    apply_deploy "$K8S/before/shop-api.yaml" v1
  fi
  k -n shop rollout status deploy/shop-api --timeout=300s >/dev/null || die "shop-api 배포 실패"
  k -n shop-loadtest rollout status deploy/loadgen --timeout=180s >/dev/null
  ok "shop-api v1 실행 중"
}

# ----------------------------------------------------------------------------- BEFORE
scenario_before() {
  section "Before 상태로 되돌리기 (게이트 OFF · 정책 없음 · Probe/HPA/노드확장 없음)"
  set_gate off
  k -n shop delete hpa shop-api --ignore-not-found >/dev/null
  helm uninstall cluster-autoscaler -n kube-system --kube-context "$CLUSTER" >/dev/null 2>&1 || true
  k delete -f "$K8S/policies/kyverno-baseline.yaml" --ignore-not-found >/dev/null 2>&1
  k label ns shop pod-security.kubernetes.io/enforce- pod-security.kubernetes.io/enforce-version- hannctl.io/protected- >/dev/null 2>&1
  apply_deploy "$K8S/before/shop-api.yaml" v1
  k -n shop scale deploy/shop-api --replicas=2 >/dev/null
  k -n shop rollout status deploy/shop-api --timeout=300s >/dev/null
  # 이전 실행에서 늘어난 노드가 있으면 1대로 복귀 (축소가 끝날 때까지 기다려야 테스트 중 Pod 가 쫓겨나지 않음)
  if [ "$(k get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')" -gt 1 ]; then
    local ng i; ng=$(aws eks list-nodegroups --cluster-name "$CLUSTER" --query 'nodegroups[0]' --output text)
    info "이전 실행에서 늘어난 노드를 1대로 축소 (최대 5분 대기)"
    aws eks update-nodegroup-config --cluster-name "$CLUSTER" --nodegroup-name "$ng" --scaling-config minSize=1,maxSize=3,desiredSize=1 >/dev/null 2>&1 || true
    for i in $(seq 1 60); do [ "$(k get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')" -le 1 ] && break; sleep 5; done
  fi
  k -n shop rollout status deploy/shop-api --timeout=300s >/dev/null
  k -n shop-loadtest rollout status deploy/loadgen --timeout=300s >/dev/null
  ok "Before 적용: Pod 2개 고정, Probe 없음, 보안 정책 없음, CI 게이트 OFF"
  ev before 00-deployment -- kubectl --context "$CLUSTER" -n shop get deploy,pods,hpa -o wide
}

# ----------------------------------------------------------------------------- 테스트
CI_VULN_ID=""; CI_SECURE_ID=""
ci_tests_start() { # 빌드는 오래 걸리므로 먼저 시작해 두고 다른 테스트와 병렬 진행
  local p=$1
  info "CI 빌드 시작 (게이트=$(gate_state)): 취약 이미지(vuln)$([ "$p" = after ] && echo ' + 정상 이미지(v1) 재빌드')"
  ci_upload
  ecr_untag vuln
  CI_VULN_ID=$(ci_start vuln vuln 0)
  [ "$p" = after ] && CI_SECURE_ID=$(ci_start v1 secure 0)
  return 0
}
ci_tests_finish() {
  local p=$1 st exp=BLOCKED; [ "$p" = before ] && exp=PUSHED
  info "CI 결과 대기…"
  st=$(ci_wait "$CI_VULN_ID"); ci_log "$CI_VULN_ID" "$RUN_DIR/$p/ci-vuln-build.log"
  local pushed; pushed=$([ "$(ecr_has vuln)" = yes ] && echo PUSHED || echo BLOCKED)
  local found; found=$(grep -E "^Total: " "$RUN_DIR/$p/ci-vuln-build.log" | head -2 | tr '\n' ' ' | sed 's/ *$//')
  record ci_vuln_image "$p" "$exp" "$pushed" "공급망: 취약 이미지 ECR 유입" "빌드 $st, $(ci_seconds "$CI_VULN_ID")s${found:+ / $found}"
  if [ "$p" = before ]; then
    aws ecr wait image-scan-complete --repository-name "$ECR_REPO" --image-id imageTag=vuln 2>/dev/null
    aws ecr describe-image-scan-findings --repository-name "$ECR_REPO" --image-id imageTag=vuln \
      --query 'imageScanFindings.findingSeverityCounts' --output json > "$RUN_DIR/$p/ecr-scan-vuln.json" 2>/dev/null
    info "ECR 기본 스캔 결과(참고, 게이트 아님): $(tr -d '\n ' < "$RUN_DIR/$p/ecr-scan-vuln.json")"
  else
    st=$(ci_wait "$CI_SECURE_ID"); ci_log "$CI_SECURE_ID" "$RUN_DIR/$p/ci-secure-build.log"
    record ci_secure_image "$p" PUSHED "$([ "$st" = SUCCEEDED ] && [ "$(ecr_has v1)" = yes ] && echo PUSHED || echo "$st")" \
      "공급망: 정상 이미지는 검사 통과 후 배포" "빌드 $st, $(ci_seconds "$CI_SECURE_ID")s"
  fi
  # 빌드 로그 중 실제 출력만 (CodeBuild 가 찍는 buildspec 명령 원문은 제외) — 게이트 상태, Trivy 합계, CRITICAL 예시 2줄, push 여부
  grep -E '^\[hannctl\]|^Total: |│ CRITICAL │' "$RUN_DIR/$p/ci-vuln-build.log" | awk '/│/{if(++c>2)next}1' | head -8 | sed 's/^/      /'
}

load_test() { # 같은 부하(LOAD_SECONDS 동안 LOAD_CONC 동시 요청)를 주고 Pod/노드 변화 관측
  local p=$1 out="$RUN_DIR/$p/load.json" csv="$RUN_DIR/$p/load-timeline.csv"
  local n0 maxr=0 maxn r n t=0 i
  if [ "$p" = after ] && [ "$(node_count)" -gt 1 ]; then
    # 직전 부하로 늘어난 노드가 남아 있으면 Pending 이 생기지 않아 노드 확장을 관찰할 수 없다 → 같은 조건(노드 1대)이 될 때까지 대기
    info "이전 부하로 늘어난 노드 $(node_count)대 → Cluster Autoscaler 가 한가한 노드를 줄여 1대가 될 때까지 대기 (보통 3~8분, 최대 12분)"
    for i in $(seq 1 72); do [ "$(node_count)" -le 1 ] && break; sleep 10; done
    if [ "$(node_count)" -le 1 ]; then ok "노드 1대로 축소됨 → Before 와 같은 조건에서 부하 시작"
    else warn "노드가 아직 $(node_count)대 — 노드 확장 결과가 FIXED 로 나올 수 있습니다 (몇 분 뒤 ./run.sh test after 로 재시도)"; fi
  fi
  n0=$(node_count); maxn=$n0
  info "부하 시작: ${LOAD_SECONDS}s 동안 동시 ${LOAD_CONC}개 요청 → GET /products"
  echo "seconds,ready_pods,hpa_desired,nodes" > "$csv"
  loadgen load "$SVC/products" "$LOAD_SECONDS" "$LOAD_CONC" > "$out" &
  local pid=$!
  while kill -0 "$pid" 2>/dev/null || { [ "$p" = after ] && [ "$t" -lt 330 ] && [ "$maxn" -le "$n0" ]; }; do
    r=$(ready_pods); n=$(node_count)
    local d; d=$(k -n shop get hpa shop-api -o jsonpath='{.status.desiredReplicas}' 2>/dev/null)
    [ "$r" -gt "$maxr" ] && maxr=$r; [ "$n" -gt "$maxn" ] && maxn=$n
    printf '      t=%3ss  Ready Pod=%-2s HPA 목표=%-2s 노드=%s %s\n' "$t" "$r" "${d:--}" "$n" "$(kill -0 $pid 2>/dev/null && echo '(부하 중)' || echo '(부하 종료, 노드 확장 관측 중)')"
    echo "$t,$r,${d:-},$n" >> "$csv"
    sleep 10; t=$((t + 10))
  done
  wait "$pid"
  local sr p95 req; sr=$(json_field "$out" success_rate); p95=$(json_field "$out" p95_ms); req=$(json_field "$out" requests)
  local m="처리 ${req:-0}건($(( ${req:-0} / LOAD_SECONDS ))rps), 성공률 ${sr}%, p95 ${p95}ms, 최대 Pod ${maxr}, 노드 ${n0}→${maxn}"
  if [ "$p" = before ]; then
    record pod_scaling "$p" FIXED "$([ "$maxr" -le 2 ] && echo FIXED || echo SCALED)" "운영: 부하 시 Pod 수 변화" "$m"
  else
    record pod_scaling "$p" SCALED "$([ "$maxr" -gt 2 ] && echo SCALED || echo FIXED)" "운영: 부하 시 Pod 수 변화" "$m"
    record node_scaling "$p" SCALED "$([ "$maxn" -gt "$n0" ] && echo SCALED || echo FIXED)" "운영: Pending 시 노드 자동 확장" "노드 ${n0}→${maxn}"
  fi
  record load_success "$p" OK "$(python3 -c "import sys;print('OK' if float(sys.argv[1] or 0)>=99 else 'DEGRADED')" "$sr")" "정상: 부하 중 요청 성공률 ≥99%" "$m"
}

bad_deploy_test() { # 버그 버전(v2-bad) 배포 중 서비스 영향 측정 → 롤백 → 복구 시간
  local p=$1 out="$RUN_DIR/$p/bad-deploy-load.json" exp=PROTECTED; [ "$p" = before ] && exp=DEGRADED
  info "버그 버전 v2-bad 배포 + 동시에 45초 부하"
  loadgen load "$SVC/products" 45 4 > "$out" &
  local pid=$!
  sleep 5
  cmdline "kubectl -n shop set image deploy/shop-api app=…:v2-bad"
  k -n shop set image deploy/shop-api "app=$(repo_uri):v2-bad" >/dev/null
  wait "$pid"
  local sr; sr=$(json_field "$out" success_rate)
  # HPA 로 Pod 가 8개까지 늘어난 상태에서도 v2-bad Pod(0/1 NotReady)가 화면에 보이도록 충분한 줄 수로 출력
  EV_LINES=14 ev "$p" bad-deploy-pods -- kubectl --context "$CLUSTER" -n shop get pods -o wide
  record bad_deploy "$p" "$exp" "$(python3 -c "import sys;print('PROTECTED' if float(sys.argv[1] or 0)>=95 else 'DEGRADED')" "$sr")" "장애: 버그 버전 배포 중 서비스 영향" "배포 중 성공률 ${sr}%"
  info "롤백: kubectl rollout undo"
  local t0 sec ver; t0=$(date +%s)
  cmdline "kubectl -n shop rollout undo deploy/shop-api"
  k -n shop rollout undo deploy/shop-api >/dev/null
  k -n shop rollout status deploy/shop-api --timeout=300s >/dev/null
  sec=$(( $(date +%s) - t0 ))
  ver=$(loadgen get "$SVC/version" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("version",""))' 2>/dev/null)
  record rollback "$p" v1 "${ver:-none}" "복구: 롤백 후 정상 버전(/version)" "복구 ${sec}s"
  k -n shop rollout history deploy/shop-api > "$RUN_DIR/$p/rollout-history.txt" 2>&1
}

pod_tests() {
  local p=$1 exp=DENIED r f; [ "$p" = before ] && exp=ALLOWED
  for f in privileged hostpath root; do
    r=$(admission_try shop "$RUN_DIR/$p/admission-$f.txt" < "$K8S/attack/$f-pod.yaml")
    case $f in privileged) t="정책: privileged Pod 생성" ;; hostpath) t="정책: hostPath(/) 마운트 Pod 생성" ;; root) t="정책: root 실행 Pod 생성" ;; esac
    record "$f" "$p" "$exp" "$r" "$t"
  done
  [ "$p" = after ] && { info "거부 메시지 예시:"; head -2 "$RUN_DIR/$p/admission-privileged.txt" | cut -c1-200 | sed 's/^/      /'; }
  return 0
}

monitoring_test() { # Prometheus 가 실제로 HPA/Pod 지표를 수집 중인지 (API 서버 서비스 프록시로 질의)
  local p=$1 q res
  q='kube_horizontalpodautoscaler_status_current_replicas%7Bnamespace%3D%22shop%22%7D'
  res=$(k get --raw "/api/v1/namespaces/monitoring/services/http:kps-prometheus:9090/proxy/api/v1/query?query=$q" 2>/dev/null)
  echo "$res" > "$RUN_DIR/$p/prometheus-query.json"
  local v; v=$(echo "$res" | python3 -c 'import sys,json;r=json.load(sys.stdin)["data"]["result"];print(r[0]["value"][1] if r else "")' 2>/dev/null)
  record monitoring "$p" COLLECTING "$([ -n "$v" ] && echo COLLECTING || echo NO_DATA)" "관측: Prometheus 가 HPA 지표 수집" "현재 replicas=${v:-?}"
}

infra_tests() {
  local p=$1
  record cluster_ready "$p" ACTIVE "$(aws eks describe-cluster --name "$CLUSTER" --query cluster.status --output text)" "인프라: EKS 클러스터 ACTIVE"
  tag_audit "$p"
  finops_audit "$p"
}

scenario_tests() {
  local p=$1
  section "[$p] 0) CI 빌드 시작 (병렬)"
  ci_tests_start "$p"
  section "[$p] 1) 트래픽 급증: 부하 테스트"
  [ "$p" = before ] && lesson "Pod 수가 고정되어 있으면 트래픽이 늘어도 처리 능력은 그대로 → 응답이 느려진다(p95 증가)"
  load_test "$p"
  section "[$p] 2) 잘못된 배포 → 롤백"
  [ "$p" = before ] && lesson "Probe 가 없으면 '실행 중' = '정상'으로 간주 → 500 을 내는 새 버전이 기존 Pod 를 밀어내고 트래픽을 받는다"
  bad_deploy_test "$p"
  section "[$p] 3) 위험 Pod 생성 시도 (서버측 dry-run)"
  [ "$p" = before ] && lesson "정책이 없으면 privileged·hostPath·root Pod 도 그대로 생성 → 노드 전체 장악 가능"
  pod_tests "$p"
  section "[$p] 4) CI 보안 게이트 결과"
  [ "$p" = before ] && lesson "검사 없이 push 하면 CRITICAL 취약점이 있는 이미지도 레지스트리에 들어가 언제든 배포될 수 있다"
  ci_tests_finish "$p"
  section "[$p] 5) 관측 · 인프라 · 식별자 · FinOps"
  [ "$p" = after ] && monitoring_test "$p"
  infra_tests "$p"
  ev "$p" final-state -- kubectl --context "$CLUSTER" -n shop get deploy,hpa,pods -o wide
  timeline "$p" "$p 테스트 완료" "$(grep -c "\"phase\": \"$p\"" "$RUN_DIR/results.jsonl") 개 항목"
}

# ----------------------------------------------------------------------------- AFTER (단계별 개선)
step_ci_gate() {
  printf '%s┃  📄 cfn/stack.yaml (CodeBuild buildspec 중 게이트 부분)%s\n' "$C_C" "$C_0"
  grep -E 'CiSecurityGate|GATE" = "on"|trivy image|CODEBUILD_BUILD_SUCCEEDING' "$SCEN_DIR/cfn/stack.yaml" | head -6 | sed "s/^ */${C_DIM}┃     /;s/\$/${C_0}/"
  set_gate on
  info "이제 CodeBuild 는 이미지 빌드 후 Trivy 로 HIGH/CRITICAL(수정 가능) 취약점을 검사하고, 발견 시 빌드를 실패시켜 ECR 로 push 하지 않는다"
  info "실제 차단 여부는 After 테스트에서 취약 이미지를 다시 빌드해 확인"
}
step_pod_security() {
  MANIFEST_LINES=14 show_manifest "$K8S/policies/kyverno-baseline.yaml"
  cmdline "kubectl label ns shop pod-security.kubernetes.io/enforce=restricted hannctl.io/protected=true"
  k label ns shop pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=latest hannctl.io/protected=true --overwrite >/dev/null
  cmdline "kubectl apply -f k8s/policies/kyverno-baseline.yaml"
  k apply -f "$K8S/policies/kyverno-baseline.yaml" >/dev/null
  wait_policies
  info "즉시 확인 → privileged Pod: $(admission_try shop < "$K8S/attack/privileged-pod.yaml")"
}
step_probes() {
  MANIFEST_LINES=24 show_manifest "$K8S/after/30-shop-api.yaml"
  cmdline "kubectl apply -f k8s/after/30-shop-api.yaml   # Probe + maxUnavailable 0 + securityContext"
  apply_deploy "$K8S/after/30-shop-api.yaml" v1
  k -n shop rollout status deploy/shop-api --timeout=300s >/dev/null
  info "즉시 확인 → $(k -n shop get deploy shop-api -o jsonpath='Ready {.status.readyReplicas}/{.spec.replicas}, 전략 maxUnavailable={.spec.strategy.rollingUpdate.maxUnavailable}')"
}
step_autoscaling() {
  MANIFEST_LINES=8 show_manifest "$K8S/after/40-cluster-autoscaler-values.yaml"
  cmdline "helm install cluster-autoscaler autoscaler/cluster-autoscaler -f k8s/after/40-cluster-autoscaler-values.yaml"
  helm repo add autoscaler https://kubernetes.github.io/autoscaler >/dev/null 2>&1 || true
  helm repo update autoscaler >/dev/null 2>&1 || true
  helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler --kube-context "$CLUSTER" -n kube-system \
    --version 9.59.0 -f "$K8S/after/40-cluster-autoscaler-values.yaml" \
    --set autoDiscovery.clusterName="$CLUSTER" --set awsRegion="$HANNCTL_REGION" --wait --timeout 5m >/dev/null || warn "Cluster Autoscaler 설치 경고"
  show_manifest "$K8S/after/40-hpa.yaml"
  cmdline "kubectl apply -f k8s/after/40-hpa.yaml"
  k apply -f "$K8S/after/40-hpa.yaml" >/dev/null
  sleep 20
  info "즉시 확인 → HPA: $(k -n shop get hpa shop-api -o jsonpath='CPU 목표 {.spec.metrics[0].resource.target.averageUtilization}%, 현재 Pod {.status.currentReplicas}개 (min {.spec.minReplicas} / max {.spec.maxReplicas})' 2>/dev/null)"
  info "Cluster Autoscaler: $(k -n kube-system get deploy cluster-autoscaler -o jsonpath='{.status.readyReplicas}' 2>/dev/null)/1 Ready (Pod Identity 로 AWS 권한 획득)"
}
step_observe() {
  info "Grafana 접속: ./run.sh grafana  → http://localhost:3000 (대시보드: Kubernetes / Compute Resources / Namespace (Pods) → namespace=shop)"
  info "Prometheus 질의 예: kube_horizontalpodautoscaler_status_current_replicas{namespace=\"shop\"}"
}
scenario_after() {
  improve 1 5 "CI 보안 게이트 ON (Trivy)" "CFN 파라미터 CiSecurityGate=on → CodeBuild 가 Trivy HIGH/CRITICAL 검사" "취약 이미지는 ECR 에 들어가지 못함(배포 경로 차단)" step_ci_gate \
    "스캔 결과를 '보는 것'과 '막는 것'은 다르다 → exit-code 1 로 빌드를 실패시켜야 취약 이미지가 배포 경로에 들어가지 못한다"
  improve 2 5 "Pod 보안 정책 (PSA restricted + Kyverno)" "shop Namespace 에 PSA restricted 라벨 + Kyverno 3개 정책" "privileged/hostPath/root Pod 생성 거부" step_pod_security \
    "Admission 단계에서 거부하면 위험한 Pod 는 '만들어지기 전에' 막힌다 (실행 후 탐지보다 앞선 예방 통제)"
  improve 3 5 "안전한 배포 설정 (Probe + 롤링 전략)" "readiness/liveness Probe, maxUnavailable 0, securityContext" "고장 난 새 버전은 트래픽을 받지 못하고 기존 버전이 계속 서비스" step_probes \
    "Readiness Probe 가 실패하는 Pod 는 Service 엔드포인트에서 빠진다 + maxUnavailable 0 → 잘못된 버전이 기존 Pod 를 밀어내지 못한다"
  improve 4 5 "자동 확장 (HPA + Cluster Autoscaler)" "CPU 50% 기준 Pod 2→8, Pending Pod 발생 시 노드 1→3" "트래픽 급증 시 Pod 와 노드가 자동으로 늘어남" step_autoscaling \
    "HPA 는 Pod 만 늘린다. 노드 자리가 없으면 Pod 는 Pending → 노드 확장(Cluster Autoscaler)은 별도로 필요하다"
  improve 5 5 "관측 (Prometheus/Grafana)" "이미 설치된 모니터링으로 Pod 수·CPU 추이 확인" "확장/장애/복구를 그래프로 증명" step_observe \
    "\"늘어났다/복구됐다\"는 말보다 시간축 그래프와 수치가 증거가 된다"
}

# ----------------------------------------------------------------------------- 상태/관찰
scenario_status() {
  section "ShopNow 현황"
  k -n shop get deploy,hpa,pods -o wide 2>/dev/null | cut -c1-150
  k get nodes -L eks.amazonaws.com/nodegroup 2>/dev/null
  section "CI · ECR"
  info "CI 보안 게이트: $(gate_state)"
  aws ecr describe-images --repository-name "$ECR_REPO" --query 'imageDetails[?imageTags].[imageTags[0],imagePushedAt]' --output text 2>/dev/null | sed 's/^/    /'
}
scenario_watch() {
  k -n shop get hpa 2>/dev/null; echo
  k -n shop get pods -o wide 2>/dev/null | cut -c1-110; echo
  k get nodes 2>/dev/null; echo
  printf 'CI 게이트: %s\n' "$(gate_state)"
}
cmd_grafana() {
  preflight >/dev/null; kube_init "$CLUSTER"
  local pw; pw=$(k -n monitoring get secret kps-grafana -o jsonpath='{.data.admin-password}' | python3 -c 'import sys,base64;print(base64.b64decode(sys.stdin.read()).decode())')
  ok "Grafana → http://localhost:3000  (ID: admin / PW: $pw)  — Ctrl+C 로 종료"
  k -n monitoring port-forward svc/kps-grafana 3000:80
}

case "${1:-}" in
  grafana) cmd_grafana ;;
  *) dispatch "$@" ;;
esac
