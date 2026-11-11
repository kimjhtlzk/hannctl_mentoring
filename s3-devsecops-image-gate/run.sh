#!/usr/bin/env bash
# =============================================================================
# 시나리오 3 — 취약 컨테이너 이미지의 운영 배포를 막는 DevSecOps (ReleaseSafe)
#   ./run.sh demo   : 인프라 생성 → Before(게이트 없음) 재현 → (N초 후) 단계별 개선 → After 테스트 → 채점/보고서
#   ./run.sh down   : 전부 삭제
# =============================================================================
SCENARIO_ID="s3"
SCENARIO_TITLE="시나리오 3 · 취약 이미지 배포 차단 DevSecOps (ReleaseSafe)"
STACK="hannctl-s3-release"
CLUSTER="hannctl-s3-release"
# 시간당 예상 비용(서울, 온디맨드 기준): EKS 0.10 + 노드(t4g.medium) 0.042 + NAT 0.059 + 공인IP 0.005 + CodeBuild 사용분 ≈ 0.22
#  → 스택 태그 hannctl:est-usd-per-hour 로 기록, janitor 가 월 누적 예상치 계산에 사용
HOURLY_USD="0.22"
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
K8S="$SCEN_DIR/k8s"
NS="release"
CI_PROJECT="hannctl-s3-ci"
REPO_NAME="hannctl-s3-release-api"

stack_params() {
  # 사양 파라미터는 항상 명시 (aws cloudformation deploy 는 기존 스택의 이전 값을 재사용하기 때문)
  echo "ClusterName=$CLUSTER DeployerPrincipalArn=$(deployer_arn) EndpointAllowedCidr=$(my_ip_cidr)" \
       "NodeCapacityType=${HANNCTL_CAPACITY:-ON_DEMAND} NodeDesired=1" \
       "NodeInstanceTypes=${HANNCTL_INSTANCE_TYPES:-t4g.medium,t4g.large,m6g.large,m7g.large,c6g.large,c7g.large}"
}

registry() { echo "$(account_id).dkr.ecr.$HANNCTL_REGION.amazonaws.com"; }
repo_uri() { stack_output "$STACK" RepoUri; }
src_commit() { # git 커밋(있으면) 또는 소스 해시 → 이미지와 소스를 연결하는 값
  git -C "$SCEN_DIR" rev-parse --short HEAD 2>/dev/null ||
    python3 -c 'import hashlib,sys;h=hashlib.sha256();[h.update(open(f,"rb").read()) for f in sys.argv[1:]];print("src-"+h.hexdigest()[:10])' \
      "$SCEN_DIR/app/app.py" "$SCEN_DIR/app/Dockerfile"
}

# ----------------------------------------------------------------------------- CI (CodeBuild)
upload_source() { # app/ 을 zip 으로 묶어 소스 버킷에 업로드 (zip 명령 없이 python 으로 → OS 무관)
  mkdir -p "$SCEN_DIR/.build"
  ( cd "$SCEN_DIR/app" && python3 -m zipfile -c "$SCEN_DIR/.build/source.zip" Dockerfile app.py trivy_summary.py )
  aws s3 cp "$SCEN_DIR/.build/source.zip" "s3://$(stack_output "$STACK" SourceBucket)/source.zip" --only-show-errors
}

ecr_tag_state() { # PRESENT / ABSENT
  aws ecr describe-images --repository-name "$REPO_NAME" --image-ids "imageTag=$1" >/dev/null 2>&1 && echo PRESENT || echo ABSENT
}

ci_build() { # ci_build PHASE NAME VARIANT GATE APP_VERSION → CI_STATUS CI_GATE CI_SUMMARY CI_DIGEST CI_TAG CI_SECONDS
  local phase=$1 name=$2 variant=$3 gate=$4 ver=$5
  CI_TAG="${ver}-${variant}-$(date +%H%M%S)"
  local commit; commit=$(src_commit)
  cmdline "aws codebuild start-build --project-name $CI_PROJECT (VARIANT=$variant GATE=$gate TAG=$CI_TAG)"
  local id; id=$(aws codebuild start-build --project-name "$CI_PROJECT" --query build.id --output text \
    --environment-variables-override "name=VARIANT,value=$variant" "name=GATE,value=$gate" \
      "name=IMAGE_TAG,value=$CI_TAG" "name=APP_VERSION,value=$ver" "name=GIT_COMMIT,value=$commit") || die "CI 시작 실패"
  CI_BUILD_ID=$id
  local t0 st cur
  t0=$(date +%s)
  while :; do
    read -r st cur <<<"$(aws codebuild batch-get-builds --ids "$id" --query 'builds[0].[buildStatus,currentPhase]' --output text)"
    printf '\r%s  ⏳ CI 진행: %-14s (%3ds) %s' "$C_Y" "$cur" "$(( $(date +%s) - t0 ))" "$C_0"
    [ "$st" != "IN_PROGRESS" ] && break
    sleep 5
  done
  printf '\n'
  CI_STATUS=$st
  CI_SECONDS=$(( $(date +%s) - t0 ))   # 대기 포함 CI 소요 시간(사람이 체감하는 검사 시간)
  # CI 로그 수집 (CloudWatch 반영 지연 대비 재시도)
  local grp strm log="$RUN_DIR/$phase/ci-$name.log" i
  read -r grp strm <<<"$(aws codebuild batch-get-builds --ids "$id" --query 'builds[0].logs.[groupName,streamName]' --output text)"
  for i in 1 2 3 4 5 6; do
    aws logs filter-log-events --log-group-name "$grp" --log-stream-names "$strm" --query 'events[].message' --output text 2>/dev/null |
      tr '\t' '\n' > "$log"
    grep -q "Phase complete: BUILD\|GATE_RESULT" "$log" && break
    sleep 5
  done
  # 실제 출력만 매칭(로그에 함께 찍히는 명령문 'GATE_RESULT=$R' 은 대문자로 시작하지 않아 제외됨)
  CI_GATE=$(grep -o 'GATE_RESULT=[A-Z][A-Z]*' "$log" | tail -1 | cut -d= -f2); CI_GATE=${CI_GATE:-NONE}
  CI_SUMMARY=$(grep -o 'TRIVY_SUMMARY.*' "$log" | tail -1 | sed 's/TRIVY_SUMMARY //')
  CI_DIGEST=$(grep -o 'IMAGE_DIGEST=sha256:[0-9a-f]*' "$log" | tail -1 | cut -d= -f2)
  info "빌드 $CI_STATUS (${CI_SECONDS}s) · Trivy HIGH/CRITICAL: ${CI_SUMMARY:-없음} · 게이트: $CI_GATE${CI_DIGEST:+ · digest ${CI_DIGEST:0:19}…}"
  grep '^VULN ' "$log" | head -5 | sed 's/^/      /'
  timeline "$phase" "CI 빌드 $name ($variant, gate=$gate)" "$CI_STATUS · $CI_GATE · ${CI_SUMMARY:-} · ${CI_SECONDS}s"
}

deploy_image() { # deploy_image IMAGE_REF — Deployment 생성/갱신 후 롤아웃 대기
  sed "s#__IMAGE__#$1#" "$K8S/base/release-api.yaml" | k apply -f - >/dev/null
  k -n "$NS" set image deploy/release-api "app=$1" >/dev/null
  k -n "$NS" rollout status deploy/release-api --timeout=180s >/dev/null || warn "롤아웃 지연"
}

# ----------------------------------------------------------------------------- 기본 구성
scenario_up() {
  install_kyverno
  # 없을 때만 생성 (apply 로 덮어쓰면 After 단계에서 붙인 보안 라벨이 지워진다 → up 을 다시 실행해도 상태 유지)
  k get ns "$NS" >/dev/null 2>&1 || k create namespace "$NS" >/dev/null
  k label ns "$NS" hannctl.io/scenario=s3 --overwrite >/dev/null
  ok "ECR($REPO_NAME), CodeBuild($CI_PROJECT), Kyverno 준비"
}

# ----------------------------------------------------------------------------- BEFORE
scenario_before() {
  section "Before 상태로 되돌리기 (CI 게이트 꺼짐 · 레지스트리/Pod 정책 없음)"
  k delete validatingpolicy hannctl-trusted-registry-only --ignore-not-found >/dev/null 2>&1
  k delete -f "$K8S/policies/kyverno-baseline.yaml" --ignore-not-found >/dev/null 2>&1
  k get ns "$NS" >/dev/null 2>&1 || k create namespace "$NS" >/dev/null
  k label ns "$NS" pod-security.kubernetes.io/enforce- pod-security.kubernetes.io/enforce-version- hannctl.io/protected- >/dev/null 2>&1

  section "Before CI: 검사는 하지만 게이트가 꺼져 있어 취약 이미지도 그대로 Push"
  lesson "Trivy 가 취약점을 '발견'해도, 결과를 보고 멈추는 장치(게이트)가 없으면 이미지는 그대로 저장소에 들어간다"
  upload_source
  ci_build before vuln vuln off v1.0.0
  record ci_vuln_build before SUCCEEDED "$CI_STATUS" "CI: 취약 이미지 빌드 결과" "${CI_SUMMARY:-} ${CI_SECONDS}s"
  record vuln_in_ecr before PRESENT "$(ecr_tag_state "$CI_TAG")" "ECR: 취약 이미지 저장 여부" "$CI_TAG"
  echo "$CI_TAG" > "$RUN_DIR/vuln_tag"

  section "취약 이미지를 운영 Namespace 에 배포 (태그로 배포, 추적 정보 없음)"
  lesson "태그(:v1.0.0-…)만으로 배포하면 '지금 운영에 정확히 어떤 내용의 이미지가 떠 있나'를 증명하기 어렵다"
  cmdline "kubectl -n $NS set image deploy/release-api app=…/$REPO_NAME:$CI_TAG"
  deploy_image "$(repo_uri):$CI_TAG"
  k -n "$NS" annotate deploy/release-api hannctl.io/git-commit- hannctl.io/image-digest- hannctl.io/ci-build-id- kubernetes.io/change-cause- >/dev/null 2>&1
  ok "Before 적용: 취약 이미지가 운영에서 실행 중"
}

# ----------------------------------------------------------------------------- 테스트 (Before/After 동일)
vuln_state() { # 이미지 참조에 -vuln- 태그가 남아 있으면 취약 이미지가 아직 실행 중 (bash 3.2: $( ) 안 case 회피용 함수)
  case "$1" in *-vuln-*) echo RUNNING ;; *) echo REPLACED ;; esac
}
running_image() { k -n "$NS" get deploy release-api -o jsonpath='{.spec.template.spec.containers[0].image}'; }
api_version() { k -n "$NS" exec deploy/release-api -- python3 /app/app.py get http://release-api.$NS.svc.cluster.local/version 2>/dev/null | tail -1; }

workload_tests() {
  local p=$1 img ver
  img=$(running_image)
  ver=$(api_version)
  echo "$ver" > "$RUN_DIR/$p/version.json"
  info "실행 중 이미지: ${img##*/}"
  info "/version 응답: $ver"
  record service_health "$p" 200 "$(k -n "$NS" exec deploy/release-api -- python3 /app/app.py probe http://release-api.$NS.svc.cluster.local/health 2>/dev/null | tail -1)" "정상: 서비스 응답(/health)"
  if [ "$p" = before ]; then
    record vuln_deployed "$p" RUNNING "$(vuln_state "$img")" "운영: 취약 이미지 실행 여부"
  else
    record vuln_deployed "$p" REPLACED "$(vuln_state "$img")" "운영: 취약 이미지 실행 여부"
    record version_changed "$p" "v1.1.0/secure" "$(python3 -c 'import json,sys;d=json.loads(sys.argv[1]);print(d["version"]+"/"+d["variant"])' "$ver" 2>/dev/null || echo ERROR)" "배포: /version 이 검증된 새 버전"
  fi
  # 추적성: 커밋·digest·CI 빌드 ID 가 Deployment 에 기록되고, 실제 이미지가 그 digest 로 고정되었나
  local dg cm bid trace=MISSING
  dg=$(k -n "$NS" get deploy release-api -o jsonpath='{.metadata.annotations.hannctl\.io/image-digest}')
  cm=$(k -n "$NS" get deploy release-api -o jsonpath='{.metadata.annotations.hannctl\.io/git-commit}')
  bid=$(k -n "$NS" get deploy release-api -o jsonpath='{.metadata.annotations.hannctl\.io/ci-build-id}')
  [ -n "$dg" ] && [ -n "$cm" ] && [ -n "$bid" ] && case "$img" in *"@$dg") trace=LINKED ;; esac
  record traceability "$p" "$([ "$p" = before ] && echo MISSING || echo LINKED)" "$trace" "추적: 커밋↔CI빌드↔digest↔배포" "${cm:+commit=$cm}"
  EV_LINES=8 ev "$p" rollout-history -- kubectl --context "$CLUSTER" -n "$NS" rollout history deploy/release-api
}

admission_tests() {
  local p=$1 exp=DENIED r img; [ "$p" = before ] && exp=ALLOWED
  local d="$RUN_DIR/$p"
  r=$(admission_try "$NS" "$d/admission-untrusted-registry.txt" < "$K8S/attack/untrusted-registry-pod.yaml")
  record untrusted_registry "$p" "$exp" "$r" "차단: 외부(미승인) 레지스트리 이미지"
  img=$(running_image)
  sed "s#__IMAGE__#$img#" "$K8S/base/trusted-image-pod.yaml" > "$d/trusted-image-pod.yaml"
  r=$(admission_try "$NS" "$d/admission-trusted-ecr.txt" < "$d/trusted-image-pod.yaml")
  record trusted_registry "$p" ALLOWED "$r" "정상: 승인된 ECR 이미지는 허용"
  r=$(admission_try "$NS" "$d/admission-privileged.txt" < "$K8S/attack/privileged-pod.yaml")
  record privileged "$p" "$exp" "$r" "차단: privileged Pod"
  r=$(admission_try "$NS" "$d/admission-hostpath.txt" < "$K8S/attack/hostpath-pod.yaml")
  record hostpath "$p" "$exp" "$r" "차단: hostPath(/) 마운트 Pod"
  r=$(admission_try "$NS" "$d/admission-root.txt" < "$K8S/attack/root-pod.yaml")
  record root "$p" "$exp" "$r" "차단: root 실행 Pod"
  if [ "$p" = after ]; then
    info "거부 메시지 예시 (외부 이미지 → Kyverno, privileged → PSA):"
    grep -o '\[hannctl/Kyverno\][^"'"'"']*' "$d/admission-untrusted-registry.txt" | head -1 | sed 's/^/      /'
    grep -o 'violates PodSecurity[^:]*:[^,]*' "$d/admission-privileged.txt" | head -1 | sed 's/^/      /'
  fi
}

infra_tests() {
  local p=$1 ready=MISSING
  record cluster_ready "$p" ACTIVE "$(aws eks describe-cluster --name "$CLUSTER" --query cluster.status --output text)" "인프라: EKS 클러스터 ACTIVE"
  aws ecr describe-repositories --repository-names "$REPO_NAME" >/dev/null 2>&1 &&
    [ "$(aws codebuild batch-get-projects --names "$CI_PROJECT" --query 'length(projects)' --output text)" = 1 ] && ready=READY
  record ecr_ci_ready "$p" READY "$ready" "인프라: ECR + CodeBuild CI 준비"
  tag_audit "$p"
  finops_audit "$p"
}

scenario_tests() {
  local p=$1
  section "[$p] 1) 운영 중인 워크로드: 어떤 이미지가 실행되고 있나"
  workload_tests "$p"
  section "[$p] 2) 클러스터 입구(Admission): 이미지 출처 + 위험 Pod (서버측 dry-run)"
  [ "$p" = before ] && lesson "클러스터에 정책이 없으면 CI 를 거치지 않은 외부 이미지·특권 Pod 도 kubectl 한 줄로 실행된다"
  admission_tests "$p"
  section "[$p] 3) 인프라 · 식별자 · FinOps"
  infra_tests "$p"
  if [ "$p" = after ]; then
    local f="$RUN_DIR/after/ci-vuln-gated.log" saved=MISSING
    [ -f "$f" ] && grep -q 'TRIVY_SUMMARY critical=' "$f" && grep -q 'GATE_RESULT=BLOCKED' "$f" && saved=SAVED
    record ci_evidence after SAVED "$saved" "증적: Trivy 결과·차단 로그 보관" "after/ci-vuln-gated.log"
  fi
  # 참고(채점 외): ECR 기본 스캔은 OS 패키지 중심 → 언어 라이브러리(Django) 취약점은 CI 의 Trivy 가 잡는다
  local vt; vt=$(cat "$RUN_DIR/vuln_tag" 2>/dev/null)
  [ -n "$vt" ] && aws ecr describe-image-scan-findings --repository-name "$REPO_NAME" --image-id "imageTag=$vt" \
    --query 'imageScanFindings.findingSeverityCounts' --output json > "$RUN_DIR/$p/ecr-basic-scan.json" 2>/dev/null
  timeline "$p" "$p 테스트 완료" "$(grep -c "\"phase\": \"$p\"" "$RUN_DIR/results.jsonl") 개 항목"
}

# ----------------------------------------------------------------------------- AFTER (단계별 개선)
show_gate_snippet() { # CloudFormation 안 buildspec 의 "게이트" 핵심 줄만 보여준다
  printf '%s┃  📄 cfn/stack.yaml → CodeBuild buildspec (스캔 → 게이트)%s\n' "$C_C" "$C_0"
  sed -n '/STAGE=scan/,/ECR Push 중단/p' "$SCEN_DIR/cfn/stack.yaml" | sed 's/^ *//' | head -12 | sed "s/^/${C_DIM}┃     /;s/\$/${C_0}/"
}
step_gate_on() {
  show_gate_snippet
  upload_source
  ci_build after vuln-gated vuln on v1.0.1
  record ci_vuln_build after FAILED "$CI_STATUS" "CI: 취약 이미지 빌드 결과" "${CI_SUMMARY:-} ${CI_SECONDS}s"
  record gate_reason after BLOCKED "$CI_GATE" "CI: 실패 원인이 Trivy 게이트인가"
  record vuln_in_ecr after ABSENT "$(ecr_tag_state "$CI_TAG")" "ECR: 취약 이미지 저장 여부" "$CI_TAG"
}
step_secure_release() {
  ci_build after secure secure on v1.1.0
  record ci_secure_build after SUCCEEDED "$CI_STATUS" "CI: 정상 이미지 빌드 결과" "${CI_SUMMARY:-} ${CI_SECONDS}s"
  [ -n "$CI_DIGEST" ] || { warn "digest 없음 — 배포 생략"; return 0; }
  show_manifest "$SCEN_DIR/app/Dockerfile" 14
  local ref; ref="$(repo_uri)@$CI_DIGEST"
  cmdline "kubectl -n $NS set image deploy/release-api app=…/$REPO_NAME@${CI_DIGEST:0:19}…  (태그 대신 digest 로 고정)"
  deploy_image "$ref"
  k -n "$NS" annotate deploy/release-api --overwrite >/dev/null \
    "hannctl.io/git-commit=$(src_commit)" "hannctl.io/image-digest=$CI_DIGEST" "hannctl.io/ci-build-id=${CI_BUILD_ID##*:}" \
    "kubernetes.io/change-cause=CI ${CI_BUILD_ID##*:} · $CI_TAG · gate PASSED"
  info "즉시 확인 → /version: $(api_version)"
}
step_admission_policies() {
  show_manifest "$K8S/policies/trusted-registry.yaml" 22
  cmdline "kubectl label ns $NS pod-security.kubernetes.io/enforce=restricted hannctl.io/protected=true"
  k label ns "$NS" pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=latest hannctl.io/protected=true --overwrite >/dev/null
  cmdline "kubectl apply -f k8s/policies/kyverno-baseline.yaml -f k8s/policies/trusted-registry.yaml(레지스트리 주소 치환)"
  local out
  out=$(k apply -f "$K8S/policies/kyverno-baseline.yaml" 2>&1) || { echo "$out"; die "정책 적용 실패"; }
  out=$(sed "s#__REGISTRY__#$(registry)#g" "$K8S/policies/trusted-registry.yaml" | k apply -f - 2>&1) || { echo "$out"; die "정책 적용 실패"; }
  wait_policies
  info "즉시 확인 → 외부 이미지: $(admission_try "$NS" "$RUN_DIR/after/admission-untrusted-registry-step.txt" < "$K8S/attack/untrusted-registry-pod.yaml"), 기존 정상 Pod: $(k -n "$NS" get pods --no-headers | awk '{print $3}' | sort | uniq -c | tr -s ' ' | tr '\n' ' ')"
}
scenario_after() {
  improve 1 3 "CI 보안 게이트 켜기 (Trivy HIGH/CRITICAL)" "GATE=on 으로 같은 취약 소스를 다시 빌드" "취약 이미지는 빌드 실패 → ECR Push·배포 자체가 일어나지 않음" step_gate_on \
    "스캔은 '발견'일 뿐이다. 실패 시 push 를 멈추는 게이트가 있어야 '차단'이 되고, 그래서 저장소에 취약 이미지가 '없다'까지 증명할 수 있다"
  improve 2 3 "검증된 이미지만 배포 (digest 고정 + 추적성)" "보안 패치된 소스 빌드 → 게이트 통과 → digest 로 배포, 커밋/빌드ID 기록" "운영 이미지 교체, '무엇이 언제 어디서 왔는지' 추적 가능" step_secure_release \
    "게이트는 '막기'만이 아니라 '통과한 것만 내보내기'다. digest(sha256)로 배포하면 운영 이미지가 검사한 바로 그 이미지임이 보장된다"
  improve 3 3 "클러스터 입구 정책 (신뢰 레지스트리 + PSA + Kyverno)" "승인 ECR 외 이미지 거부 + privileged/hostPath/root 거부" "CI 를 우회한 kubectl 직접 배포도 차단(2단계 방어)" step_admission_policies \
    "CI 게이트는 'CI 를 거친 것'만 지킨다. 클러스터 입구(Admission) 정책이 있어야 우회 경로까지 막힌다 — 그래서 2단계 방어"
}

scenario_status() {
  section "공급망 현황"
  k -n "$NS" get deploy release-api -o wide 2>/dev/null | cut -c1-160
  k -n "$NS" rollout history deploy/release-api 2>/dev/null | tail -4
  aws ecr describe-images --repository-name "$REPO_NAME" --query 'sort_by(imageDetails,&imagePushedAt)[-5:].[imageTags[0],imagePushedAt]' --output table 2>/dev/null
  aws codebuild list-builds-for-project --project-name "$CI_PROJECT" --max-items 5 --query ids --output text 2>/dev/null | tr '\t' '\n' | head -5 |
    while read -r b; do [ -n "$b" ] && [ "$b" != None ] && aws codebuild batch-get-builds --ids "$b" --query 'builds[0].[id,buildStatus]' --output text; done
  k get validatingpolicy 2>/dev/null
}

dispatch "$@"
