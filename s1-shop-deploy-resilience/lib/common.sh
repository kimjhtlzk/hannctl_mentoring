#!/usr/bin/env bash
# =============================================================================
# hannctl 공통 라이브러리 — 모든 시나리오의 run.sh 가 source 한다.
#  - AWS 에 생성되는 모든 리소스: 이름 hannctl- 접두사 + 태그 Project=hannctl
#  - 자격 증명: 콘솔 로그인(aws login) 또는 CloudShell → 작업용 역할 hannctl-operator-role 의 임시 자격 증명 (Access Key 없음)
#  - 시나리오 스택은 hannctl-cfn-exec-role 로 생성 → hannctl-janitor 가 유지 시간(생성 시각 기준) 만료 시 자동 삭제
#  - macOS 기본 bash 3.2 호환 (연관 배열/mapfile 미사용)
# =============================================================================
set -o pipefail

: "${HANNCTL_PROFILE:=hannctl}"          # 작업용 프로필 (hannctl-operator-role 로 자동 전환, 자동 생성)
: "${HANNCTL_SOURCE_PROFILE:=}"          # (선택) 로그인 대신 쓸 기존 프로필 — 비우면 aws login / CloudShell 사용
LOGIN_PROFILE="hannctl-login"            # aws login 이 임시 자격 증명을 보관하는 프로필 (자동 생성)
IDENTITY_STACK="hannctl-identity"        # 작업용 역할(+root 대신 쓸 콘솔 사용자) 스택
OPERATOR_ROLE="hannctl-operator-role"
: "${HANNCTL_REGION:=ap-northeast-2}"    # 서울 리전
: "${HANNCTL_LIFETIME_HOURS:=}"          # 실습 환경 유지 시간(스택 생성 시각 기준, 비우면 시작 시 물어봄 / 기본 6)
DEFAULT_LIFETIME_HOURS=6
: "${HANNCTL_ALERT_EMAIL:=}"             # 예산/자동정리 알림 메일(선택)
: "${HANNCTL_BUDGET_USD:=20}"            # 월 상한(USD, 약 3만원 이내) — 넘으면 janitor 가 전부 삭제, 새 배포 거부
: "${BEFORE_WAIT_SECONDS:=60}"           # demo: Before 관찰 후 After 로 넘어가기까지 대기(초)
: "${STEP_PAUSE_SECONDS:=5}"             # demo: 개선 단계 사이 대기(초)
# 환경 변수 Access Key 는 프로필보다 우선하므로 쓰지 않는다 (장기 키 대신 임시 자격 증명만 사용)
case "${AWS_EXECUTION_ENV:-}" in CloudShell*) ;; *) unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN ;; esac
export AWS_PROFILE="$HANNCTL_PROFILE" AWS_REGION="$HANNCTL_REGION" AWS_DEFAULT_REGION="$HANNCTL_REGION" AWS_PAGER=""

# 시나리오 폴더 단독 배포 구조: <시나리오>/lib/common.sh, <시나리오>/cfn/*.yaml
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCEN_DIR="$(cd "$LIB_DIR/.." && pwd)"
GUARD_STACK="hannctl-finops-guard"
: "${HOURLY_USD:=0.25}"                  # 시나리오 시간당 예상 비용(run.sh 에서 지정) → 스택 태그로 기록
GUARD_TEMPLATE="$SCEN_DIR/cfn/hannctl-finops-guard.yaml"
IDENTITY_TEMPLATE="$SCEN_DIR/cfn/hannctl-identity.yaml"
export PATH="$SCEN_DIR/.tools/bin:$PATH"   # tools/install-tools.sh 가 설치한 kubectl/helm
KYVERNO_CHART_VERSION="3.9.2"            # Kyverno v1.19.2

# ----------------------------------------------------------------------------- UI
if [ -t 1 ]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[34m'; C_M=$'\033[35m'; C_C=$'\033[36m'
  C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_0=$'\033[0m'
else
  C_R=; C_G=; C_Y=; C_B=; C_M=; C_C=; C_DIM=; C_BOLD=; C_0=
fi
banner()  { printf '\n%s%s══════════════════════════════════════════════════════════════════════%s\n%s  %s%s\n%s══════════════════════════════════════════════════════════════════════%s\n' "$C_BOLD" "$C_B" "$C_0" "$C_BOLD" "$*" "$C_0" "$C_B" "$C_0"; }
guide_step() { # GUIDE.md 의 단계 번호를 화면에 표시 — 멘티가 문서의 어느 단계인지 바로 맞춰 볼 수 있게
  printf '\n%s📍 [가이드 %s/10단계] %s%s\n' "$C_BOLD$C_M" "$1" "$2" "$C_0"
}
section() { printf '\n%s── %s %s\n' "$C_C$C_BOLD" "$*" "$C_0"; }
info()    { printf '%s  • %s%s\n' "$C_DIM" "$*" "$C_0"; }
ok()      { printf '%s  ✔ %s%s\n' "$C_G" "$*" "$C_0"; }
warn()    { printf '%s  ! %s%s\n' "$C_Y" "$*" "$C_0" >&2; }
err()     { printf '%s  ✘ %s%s\n' "$C_R" "$*" "$C_0" >&2; }
die()     { err "$*"; exit 1; }
cmdline() { printf '%s  $ %s%s\n' "$C_M" "$*" "$C_0"; }

countdown() { # countdown SECONDS MESSAGE
  local s=$1 msg=$2
  while [ "$s" -gt 0 ]; do
    printf '\r%s  ⏳ %s — %4ds 남음 %s' "$C_Y" "$msg" "$s" "$C_0"
    sleep 1; s=$((s - 1))
  done
  printf '\r%s  ⏩ %s — 전환!                              %s\n' "$C_Y" "$msg" "$C_0"
}

need() { for b in "$@"; do command -v "$b" >/dev/null 2>&1 || die "필요한 도구가 없습니다: $b"; done; }
pyjson() { python3 -c "$1" "${@:2}"; }   # 작은 JSON 처리 헬퍼(jq 없이도 동작)

# ----------------------------------------------------------------------------- AWS 기본
account_id() { aws sts get-caller-identity --query Account --output text; }
deployer_arn() {
  # assumed-role 세션 ARN 이면 IAM Role ARN 으로 변환 (EKS Access Entry/Trust 용)
  local arn; arn=$(aws sts get-caller-identity --query Arn --output text)
  case "$arn" in
    arn:aws:sts::*:assumed-role/*)
      local acct role; acct=$(echo "$arn" | cut -d: -f5); role=$(echo "$arn" | cut -d/ -f2)
      echo "arn:aws:iam::$acct:role/$role" ;;
    *) echo "$arn" ;;
  esac
}
my_ip_cidr() { echo "$(curl -s --max-time 5 https://checkip.amazonaws.com | tr -d '[:space:]')/32"; }
stack_status() { aws cloudformation describe-stacks --stack-name "$1" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NONE"; }
stack_output() { aws cloudformation describe-stacks --stack-name "$1" --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text; }
iso_from_epoch() { python3 -c 'import datetime,sys;print(datetime.datetime.fromtimestamp(float(sys.argv[1]),datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }
stack_created_epoch() { # 스택 생성 시각(epoch), 없으면 지금
  local c; c=$(aws cloudformation describe-stacks --stack-name "$1" --query 'Stacks[0].CreationTime' --output text 2>/dev/null)
  if [ -n "$c" ] && [ "$c" != None ]; then python3 -c 'import datetime,sys;print(int(datetime.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00")).timestamp()))' "$c"; else date +%s; fi
}
stack_tag() { aws cloudformation describe-stacks --stack-name "$1" --query "Stacks[0].Tags[?Key=='$2'].Value | [0]" --output text 2>/dev/null; }

choose_lifetime() { # 처음 시작할 때 유지 시간을 정한다 (이미 있는 스택이면 그 값을 그대로 사용)
  [ -n "${LIFETIME_CHOSEN:-}" ] && return 0; LIFETIME_CHOSEN=1
  local cur; cur=$(stack_tag "$STACK" hannctl:lifetime-hours)
  if [ -n "$cur" ] && [ "$cur" != None ]; then HANNCTL_LIFETIME_HOURS=$cur; return 0; fi
  if [ -z "$HANNCTL_LIFETIME_HOURS" ]; then
    if [ -t 0 ]; then
      printf '\n%s⏰ 이 실습 환경을 몇 시간 유지할까요? (만든 시각부터, 지나면 자동 삭제)%s\n' "$C_BOLD$C_Y" "$C_0"
      printf '   1~24 시간, 시간당 약 $%s — 그냥 Enter 면 %s시간: ' "$HOURLY_USD" "$DEFAULT_LIFETIME_HOURS"
      read -r HANNCTL_LIFETIME_HOURS
    fi
    HANNCTL_LIFETIME_HOURS=${HANNCTL_LIFETIME_HOURS:-$DEFAULT_LIFETIME_HOURS}
  fi
  case "$HANNCTL_LIFETIME_HOURS" in ''|*[!0-9]*) die "유지 시간은 0~24 사이 정수여야 합니다: $HANNCTL_LIFETIME_HOURS" ;; esac
  [ "$HANNCTL_LIFETIME_HOURS" -le 24 ] || die "유지 시간은 0~24 시간입니다 (0 = 무제한)"
  if [ "$HANNCTL_LIFETIME_HOURS" -eq 0 ]; then
    warn "유지 시간 무제한 — 자동 삭제되지 않습니다. 끝나면 반드시 ./run.sh down (하루 방치 시 약 \$$(python3 -c "print(round($HOURLY_USD*24,2))"))"
  else
    info "유지 시간 ${HANNCTL_LIFETIME_HOURS}시간 (최대 예상 비용 약 \$$(python3 -c "print(round($HOURLY_USD*$HANNCTL_LIFETIME_HOURS,2))"))"
  fi
}

iso_after_hours() { python3 -c 'import datetime,sys;print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=float(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }

awscli_ok() { # AWS CLI 2.32 이상 (aws login 지원 버전)
  local v; v=$(AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null aws --version 2>&1 | sed -n 's#^aws-cli/\([0-9]*\)\.\([0-9]*\)\..*#\1 \2#p')
  # shellcheck disable=SC2086
  set -- $v; [ "${1:-0}" -eq 2 ] && [ "${2:-0}" -ge 32 ]
}
tools_ready() { # python3(3.8+), AWS CLI 2.32+, kubectl, helm, curl 이 모두 있는가
  command -v curl >/dev/null 2>&1 && command -v kubectl >/dev/null 2>&1 && command -v helm >/dev/null 2>&1 &&
  command -v python3 >/dev/null 2>&1 && python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' 2>/dev/null &&
  awscli_ok
}

ensure_tools() { # 없는 도구만 자동 설치 (있으면 아무것도 하지 않음)
  tools_ready && return 0
  warn "필요한 도구가 없어 자동 설치합니다 (tools/install-tools.sh — 이미 있는 것은 건너뜀)"
  bash "$SCEN_DIR/tools/install-tools.sh" || die "도구 설치 실패 — START_HERE.md 2단계 참고"
  hash -r
}

preflight() {
  ensure_tools
  need aws kubectl helm python3 curl
  ensure_identity
  info "AWS 계정 $(account_id) / 신원 $OPERATOR_ROLE (프로필 $HANNCTL_PROFILE) / 리전 $HANNCTL_REGION"
}

# ----------------------------------------------------------------------------- 자격 증명 (멘티 환경에서 자동 생성)
#  1) 로그인 : CloudShell 이면 그대로, 아니면 aws login(브라우저 콘솔 로그인) → 프로필 hannctl-login 에 임시 자격 증명
#  2) 신원   : hannctl-identity 스택이 IAM Role hannctl-operator-role 을 만든다
#  3) 전환   : 프로필 hannctl = "로그인 자격 증명으로 hannctl-operator-role 전환" → run.sh 의 모든 작업이 이 역할로 실행
#  root 로 로그인했다면 역할 전환이 불가능하므로 콘솔 사용자 hannctl-admin 을 만들어 다시 로그인하게 안내한다
in_cloudshell() { case "${AWS_EXECUTION_ENV:-}" in CloudShell*) return 0 ;; esac; return 1; }
login_source() { # 로그인 자격 증명이 들어 있는 프로필 (CloudShell 은 빈 값 = 컨테이너 자격 증명)
  if [ -n "$HANNCTL_SOURCE_PROFILE" ]; then echo "$HANNCTL_SOURCE_PROFILE"; elif in_cloudshell; then echo ""; else echo "$LOGIN_PROFILE"; fi
}
boot_aws() { # 역할 전환 "전"의 로그인 자격 증명으로 aws 실행 (신원 스택 배포·삭제용)
  local src; src=$(login_source)
  if [ -n "$src" ]; then AWS_PROFILE="$src" aws "$@"; else env -u AWS_PROFILE aws "$@"; fi
}
browser_here() { # 이 터미널에서 브라우저를 열 수 있는가 (아니면 aws login --remote: 주소를 다른 기기에서 열고 코드 붙여넣기)
  [ -n "${SSH_CONNECTION:-}" ] && return 1
  [ "$(uname -s)" = Darwin ] || [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]
}
aws_login() { # 브라우저 콘솔 로그인 → 임시 자격 증명 (Access Key 를 만들거나 저장하지 않음)
  [ -t 0 ] || die "AWS 로그인이 필요합니다. 터미널에서 ./run.sh login 을 한 번 실행하세요"
  section "AWS 로그인 — 브라우저에서 내 AWS 계정으로 로그인하면 CLI 가 임시 자격 증명을 받습니다"
  info "Access Key 를 만들지 않습니다. 자격 증명은 자동 갱신되며 최대 12시간 유지됩니다 (프로필 $LOGIN_PROFILE)"
  aws configure set region "$HANNCTL_REGION" --profile "$LOGIN_PROFILE"
  if browser_here; then aws login --profile "$LOGIN_PROFILE" || die "로그인 실패 — 다시 ./run.sh login"
  else
    info "이 터미널에서는 브라우저를 열 수 없습니다 → 아래 주소를 PC/휴대폰 브라우저에서 열고, 로그인 후 표시되는 코드를 붙여 넣으세요"
    aws login --profile "$LOGIN_PROFILE" --remote || die "로그인 실패 — 다시 ./run.sh login"
  fi
}
ensure_login() { # 로그인 자격 증명이 유효한지 확인하고, 없으면 자동으로 로그인
  boot_aws sts get-caller-identity >/dev/null 2>&1 && return 0
  in_cloudshell && die "CloudShell 자격 증명을 확인할 수 없습니다 — 브라우저에서 CloudShell 탭을 새로 고침하세요"
  [ -n "$HANNCTL_SOURCE_PROFILE" ] && die "프로필 $HANNCTL_SOURCE_PROFILE 의 자격 증명이 유효하지 않습니다 (HANNCTL_SOURCE_PROFILE 을 비우면 aws login 사용)"
  aws_login
  boot_aws sts get-caller-identity >/dev/null 2>&1 || die "로그인 후에도 자격 증명을 확인할 수 없습니다"
}
clear_role_cache() { # AWS CLI 가 저장해 둔 작업용 역할의 임시 자격 증명만 지운다 (역할을 지웠다 다시 만들면 옛 자격 증명이 무효가 되므로)
  local d="${AWS_CLI_CACHE_DIR:-$HOME/.aws/cli/cache}" f
  [ -d "$d" ] || return 0
  for f in "$d"/*.json; do
    [ -f "$f" ] && grep -q "assumed-role/$OPERATOR_ROLE/" "$f" 2>/dev/null && rm -f "$f"
  done
  return 0
}
identity_deploy() { # identity_deploy [Key=Value ...] — 신원 스택 생성/갱신 (로그인 자격 증명으로)
  local sha; sha=$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest()[:12])' "$IDENTITY_TEMPLATE")
  info "작업용 IAM 역할 $OPERATOR_ROLE 준비 중 (스택 $IDENTITY_STACK, 처음 한 번 약 1분)"
  boot_aws cloudformation deploy --stack-name "$IDENTITY_STACK" --template-file "$IDENTITY_TEMPLATE" \
    --capabilities CAPABILITY_NAMED_IAM --no-fail-on-empty-changeset ${1:+--parameter-overrides "$@"} \
    --tags Project=hannctl hannctl:role=identity hannctl:est-usd-per-hour=0 "hannctl:template-sha=$sha" hannctl:managed-by=hannctl-cli \
    >/dev/null || die "신원 스택 배포 실패 — 로그인한 사용자에게 관리자 권한(IAM 포함)이 필요합니다"
  clear_role_cache
}
identity_current() { # 신원 스택이 있고 템플릿이 최신인가
  local sha cur
  sha=$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest()[:12])' "$IDENTITY_TEMPLATE")
  cur=$(boot_aws cloudformation describe-stacks --stack-name "$IDENTITY_STACK" \
    --query "Stacks[?StackStatus=='CREATE_COMPLETE' || StackStatus=='UPDATE_COMPLETE'] | [0].Tags[?Key=='hannctl:template-sha'] | [0].Value" --output text 2>/dev/null)
  [ "$cur" = "$sha" ]
}
root_bootstrap() { # root 로 로그인한 경우: 콘솔 사용자 hannctl-admin 을 만들고 다시 로그인하게 한다
  local acct=$1 pw
  warn "root 사용자로 로그인되어 있습니다 — root 는 IAM 역할로 전환할 수 없고, 일상 작업에 쓰면 위험합니다"
  info "콘솔 로그인 전용 IAM 사용자 hannctl-admin 을 자동으로 만듭니다 (Access Key 없음, 할 수 있는 일은 $OPERATOR_ROLE 전환뿐)"
  pw=$(python3 -c 'import secrets,string as s;a=s.ascii_letters+s.digits;print(secrets.choice(s.ascii_uppercase)+secrets.choice(s.digits)+"".join(secrets.choice(a) for _ in range(14))+"#a")')
  identity_deploy CreateConsoleUser=true "ConsoleUserPassword=$pw"
  printf '\n%s┌─ hannctl-admin 로그인 정보 (지금 한 번만 표시) ─────────────────────────┐%s\n' "$C_BOLD$C_Y" "$C_0"
  printf '   로그인 주소 : https://%s.signin.aws.amazon.com/console\n   사용자 이름 : hannctl-admin\n   임시 비밀번호: %s  (첫 로그인 때 새 비밀번호로 변경)\n' "$acct" "$pw"
  printf '%s└──────────────────────────────────────────────────────────────────────┘%s\n' "$C_BOLD$C_Y" "$C_0"
  in_cloudshell && die "콘솔 오른쪽 위에서 로그아웃 → 위 주소로 hannctl-admin 로그인 → CloudShell 을 다시 열고 같은 명령을 실행하세요"
  printf '브라우저에서 root 를 로그아웃한 뒤 Enter 를 누르세요 (다음 로그인은 hannctl-admin 으로) '; read -r _
  aws logout --profile "$LOGIN_PROFILE" >/dev/null 2>&1 || true
  aws_login
  case "$(boot_aws sts get-caller-identity --query Arn --output text 2>/dev/null)" in
    *:root|'') die "아직 root 로 로그인되어 있습니다 — 브라우저에서 로그아웃 후 ./run.sh login" ;;
  esac
}
profile_set() { # profile_set KEY VALUE — 프로필 hannctl 의 값이 다를 때만 쓴다 (demo 와 watch 를 동시에 시작해도 설정 파일이 깨지지 않게 잠금)
  [ "$(aws configure get "$1" --profile "$HANNCTL_PROFILE" 2>/dev/null)" = "$2" ] && return 0
  local lock="${TMPDIR:-/tmp}/hannctl-aws-config.lock" i
  for i in $(seq 1 50); do mkdir "$lock" 2>/dev/null && break; sleep 0.2; done
  [ "$(aws configure get "$1" --profile "$HANNCTL_PROFILE" 2>/dev/null)" = "$2" ] || aws configure set "$1" "$2" --profile "$HANNCTL_PROFILE"
  rmdir "$lock" 2>/dev/null || true
}
ensure_identity() { # 로그인 확인 → 작업용 역할 준비 → 프로필 hannctl 로 전환 (프로세스당 한 번)
  [ -n "${IDENTITY_READY:-}" ] && return 0
  ensure_login
  local arn acct src i
  arn=$(boot_aws sts get-caller-identity --query Arn --output text); acct=$(echo "$arn" | cut -d: -f5)
  case "$arn" in
    *:root) root_bootstrap "$acct"; identity_current || identity_deploy ;;
    *":user/hannctl-admin") ;;   # root 가 만들어 준 콘솔 사용자: 역할 전환 권한만 있다 (신원 스택은 root 로그인 때 이미 만들어짐)
    *) identity_current || identity_deploy ;;
  esac
  # 작업용 프로필 hannctl: 로그인 자격 증명으로 hannctl-operator-role 전환 (CLI 가 만료 전에 자동 갱신)
  src=$(login_source)
  profile_set role_arn "arn:aws:iam::$acct:role/$OPERATOR_ROLE"
  if [ -n "$src" ]; then profile_set source_profile "$src"; else profile_set credential_source EcsContainer; fi
  profile_set role_session_name hannctl-cli
  profile_set region "$HANNCTL_REGION"
  export AWS_PROFILE="$HANNCTL_PROFILE"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do   # 새 역할은 전파에 몇 초 걸린다
    case "$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)" in
      *":assumed-role/$OPERATOR_ROLE/"*) IDENTITY_READY=1; return 0 ;;
    esac
    clear_role_cache   # 무효가 된 옛 자격 증명이 남아 있으면 다음 시도에서 새로 받는다
    sleep 5
  done
  die "$OPERATOR_ROLE 로 전환하지 못했습니다 — ./run.sh doctor 로 확인"
}
cmd_login() { # 수동 (재)로그인
  if in_cloudshell; then ok "CloudShell 은 이미 로그인되어 있습니다"; else aws_login; fi
  ensure_identity
  ok "준비 완료: $(aws sts get-caller-identity --query Arn --output text)"
}
cmd_logout() { # 이 PC 의 로그인 자격 증명 삭제 (AWS 리소스는 그대로)
  in_cloudshell && { info "CloudShell 은 콘솔 로그아웃으로 끝납니다"; return 0; }
  aws logout --profile "$LOGIN_PROFILE" >/dev/null 2>&1 && ok "로그아웃 완료 (프로필 $LOGIN_PROFILE 의 임시 자격 증명 삭제)" || info "로그인된 세션이 없습니다"
}
cmd_identity_delete() { # 신원 스택 삭제 (역할·콘솔 사용자) — 로그인 자격 증명으로 실행
  ensure_login
  local arn; arn=$(boot_aws sts get-caller-identity --query Arn --output text)
  case "$arn" in *":user/hannctl-admin") die "hannctl-admin 은 자기 자신을 지울 수 없습니다 → root 로 로그인한 CloudShell 에서: aws cloudformation delete-stack --stack-name $IDENTITY_STACK" ;; esac
  info "신원 스택 삭제: $IDENTITY_STACK ($OPERATOR_ROLE, hannctl-admin)"
  boot_aws cloudformation delete-stack --stack-name "$IDENTITY_STACK" &&
    boot_aws cloudformation wait stack-delete-complete --stack-name "$IDENTITY_STACK" && clear_role_cache && ok "신원 스택 삭제 완료"
}

# ----------------------------------------------------------------------------- FinOps Guard
ensure_guard() {
  local st; st=$(stack_status "$GUARD_STACK")
  case "$st" in
    CREATE_COMPLETE|UPDATE_COMPLETE|UPDATE_ROLLBACK_COMPLETE) ;;
    NONE)
      section "FinOps Guard 스택 생성 ($GUARD_STACK) — 최초 1회"
      aws cloudformation deploy --stack-name "$GUARD_STACK" --template-file "$GUARD_TEMPLATE" \
        --capabilities CAPABILITY_NAMED_IAM --no-fail-on-empty-changeset \
        --parameter-overrides "MonthlyBudgetUsd=$HANNCTL_BUDGET_USD" "AlertEmail=$HANNCTL_ALERT_EMAIL" \
        --tags Project=hannctl hannctl:role=guard hannctl:managed-by=hannctl-cli >/dev/null || die "guard 스택 생성 실패"
      # 비용 할당 태그 활성화(Budgets 태그 필터용, best-effort)
      aws ce update-cost-allocation-tags-status --cost-allocation-tags-status TagKey=Project,Status=Active >/dev/null 2>&1 || true
      ok "FinOps Guard 준비 완료 (janitor 10분 주기, 예산 \$$HANNCTL_BUDGET_USD/월)" ;;
    *) die "guard 스택 상태 이상: $st — CloudFormation 콘솔에서 $GUARD_STACK 이벤트 확인" ;;
  esac
  EXEC_ROLE_ARN=$(stack_output "$GUARD_STACK" CfnExecRoleArn)
}

# ----------------------------------------------------------------------------- 비용 (FinOps)
guard_cap() { # 현재 적용 중인 월 상한(가드 스택 파라미터), 가드가 없으면 기본값
  local v; v=$(aws cloudformation describe-stacks --stack-name "$GUARD_STACK" --query "Stacks[0].Parameters[?ParameterKey=='MonthlyBudgetUsd'].ParameterValue | [0]" --output text 2>/dev/null)
  case "$v" in ''|None) echo "$HANNCTL_BUDGET_USD" ;; *) echo "$v" ;; esac
}
cost_guard() { # 이번 달 누적 예상 비용 표시 + 상한 초과 시 새 배포 거부
  HANNCTL_BUDGET_USD=$(guard_cap)
  [ "$HANNCTL_BUDGET_USD" = 0 ] && { info "💸 월 상한 꺼짐 (./run.sh cap 20 으로 다시 켜기)"; return 0; }
  local j mtd; j=$(python3 "$LIB_DIR/cost.py" --json 2>/dev/null) || { warn "비용 추정 실패(무시)"; return 0; }
  mtd=$(echo "$j" | python3 -c 'import json,sys;print(json.load(sys.stdin)["mtd_usd"])')
  info "💸 이번 달 hannctl 누적 예상 비용 \$$mtd / 상한 \$$HANNCTL_BUDGET_USD (이 시나리오 약 \$$HOURLY_USD/시간)"
  if python3 -c 'import sys;sys.exit(0 if float(sys.argv[1])>=float(sys.argv[2]) else 1)' "$mtd" "$HANNCTL_BUDGET_USD"; then
    die "월 상한(\$$HANNCTL_BUDGET_USD) 도달 — 새 배포를 거부합니다. (./run.sh cost 로 확인, ./run.sh cap <USD> 로 조정)"
  fi
}
write_run_cost() { # 이번 실행의 예상 비용을 증적으로 저장 (REPORT 에 표시)
  local created; created=$(aws cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].CreationTime' --output text 2>/dev/null)
  python3 - "$created" "$HOURLY_USD" "$RUN_DIR/cost.json" "$LIB_DIR/cost.py" "$HANNCTL_BUDGET_USD" "${RUN_T0:-0}" <<'PY'
import datetime, json, subprocess, sys
created, rate, out, costpy, cap, t0 = sys.argv[1], float(sys.argv[2]), sys.argv[3], sys.argv[4], float(sys.argv[5]), int(sys.argv[6])
now = datetime.datetime.now(datetime.timezone.utc)
stack_h = (now - datetime.datetime.fromisoformat(created.replace("Z", "+00:00"))).total_seconds() / 3600 if created and created != "None" else 0
run_h = (now.timestamp() - t0) / 3600 if t0 else 0
try:
    mtd = json.loads(subprocess.check_output(["python3", costpy, "--json"]))["mtd_usd"]
except Exception:
    mtd = None
json.dump({"rate_usd_per_hour": rate, "stack_age_hours": round(stack_h, 2), "stack_cost_usd": round(stack_h * rate, 3),
           "run_hours": round(run_h, 2), "run_cost_usd": round(run_h * rate, 3), "month_to_date_usd": mtd, "cap_usd": cap},
          open(out, "w"))
PY
}
cmd_cap() { # 월 상한 변경 (0 = 끄기) — 가드 스택 파라미터만 바꾼다
  local usd=${1:-}
  case "$usd" in ''|*[!0-9]*) die "사용법: ./run.sh cap <USD 정수> (0 = 월 상한 끄기, 기본 20)" ;; esac
  preflight; ensure_guard
  [ "$usd" = 0 ] && warn "월 비용 상한을 끕니다 — 비용 폭주 시 자동 삭제되지 않습니다 (시나리오별 유지 시간 제한은 그대로)"
  aws cloudformation deploy --stack-name "$GUARD_STACK" --template-file "$GUARD_TEMPLATE" --capabilities CAPABILITY_NAMED_IAM \
    --no-fail-on-empty-changeset --parameter-overrides "MonthlyBudgetUsd=$usd" \
    --tags Project=hannctl hannctl:role=guard hannctl:managed-by=hannctl-cli >/dev/null && ok "월 상한 = \$$usd (0 은 꺼짐)"
}
cmd_cost() {
  preflight >/dev/null
  section "hannctl 비용 (실시간 추정 — 가동시간 × 단가 태그)"
  python3 "$LIB_DIR/cost.py"
  info "상한 \$$(guard_cap)/월 (0 = 꺼짐, 도달 시 janitor 가 hannctl 스택 전부 삭제). 이 시나리오 단가 약 \$$HOURLY_USD/시간"
  info "실제 청구액: 결제 콘솔 → Cost Explorer → 태그 Project=hannctl (반영까지 최대 24시간)"
}

# ----------------------------------------------------------------------------- 스택 배포/삭제
deploy_stack() { # deploy_stack STACK TEMPLATE [Key=Value ...]
  local stack=$1 tpl=$2; shift 2
  ensure_guard
  [ -n "$HANNCTL_LIFETIME_HOURS" ] || choose_lifetime
  local expires=never
  [ "$HANNCTL_LIFETIME_HOURS" -gt 0 ] && expires=$(iso_from_epoch $(( $(stack_created_epoch "$stack") + HANNCTL_LIFETIME_HOURS * 3600 )))
  section "CloudFormation 배포: $stack (유지 ${HANNCTL_LIFETIME_HOURS}h → $expires UTC 자동 삭제)"
  cmdline "aws cloudformation deploy --stack-name $stack --template-file ${tpl#$SCEN_DIR/} --role-arn hannctl-cfn-exec-role ..."
  local t0 total log rc; t0=$(date +%s); log=$(mktemp)
  total=$(aws cloudformation get-template-summary --template-body "file://$tpl" --query 'length(ResourceTypes)' --output text 2>/dev/null || echo "?")
  aws cloudformation deploy --stack-name "$stack" --template-file "$tpl" \
    --role-arn "$EXEC_ROLE_ARN" --capabilities CAPABILITY_NAMED_IAM --no-fail-on-empty-changeset \
    --parameter-overrides "$@" \
    --tags Project=hannctl "hannctl:scenario=$SCENARIO_ID" "hannctl:lifetime-hours=$HANNCTL_LIFETIME_HOURS" "hannctl:expires-at=$expires" "hannctl:est-usd-per-hour=$HOURLY_USD" \
           "hannctl:owner=$(deployer_arn | awk -F/ '{print $NF}')" hannctl:managed-by=hannctl-cli >"$log" 2>&1 &
  local pid=$!
  watch_stack_events "$stack" "$t0" "$pid" "$total"
  wait "$pid"; rc=$?
  grep -q "No changes to deploy" "$log" && info "변경 사항 없음 (이미 최신 상태)"
  rm -f "$log"
  [ $rc -eq 0 ] || { stack_events_tail "$stack"; die "스택 배포 실패: $stack"; }
  ok "스택 $stack 준비 ($(( $(date +%s) - t0 ))s)"
}

# 리소스 종류 → 학습용 한글 설명
res_label() {
  case "$1" in
    AWS::EC2::VPC) echo "VPC (격리된 가상 네트워크)" ;;
    AWS::EC2::Subnet) echo "서브넷 (AZ별 네트워크 구역)" ;;
    AWS::EC2::InternetGateway) echo "인터넷 게이트웨이" ;;
    AWS::EC2::NatGateway) echo "NAT 게이트웨이 (프라이빗 노드의 외부 통신)" ;;
    AWS::EC2::EIP) echo "고정 공인 IP (NAT 용)" ;;
    AWS::EC2::RouteTable|AWS::EC2::Route|AWS::EC2::SubnetRouteTableAssociation|AWS::EC2::VPCGatewayAttachment) echo "라우팅" ;;
    AWS::EC2::LaunchTemplate) echo "노드 시작 템플릿 (IMDSv2, 암호화 디스크)" ;;
    AWS::EC2::SecurityGroup) echo "보안 그룹" ;;
    AWS::IAM::Role) echo "IAM Role (권한)" ;;
    AWS::IAM::User) echo "IAM User" ;;
    AWS::IAM::Policy|AWS::IAM::ManagedPolicy) echo "IAM Policy" ;;
    AWS::EKS::Cluster) echo "EKS Control Plane (약 8~10분 소요)" ;;
    AWS::EKS::Nodegroup) echo "EKS 관리형 노드 그룹 (EC2 워커 노드, 약 2~4분)" ;;
    AWS::EKS::Addon) echo "EKS 애드온" ;;
    AWS::EKS::AccessEntry) echo "EKS Access Entry (IAM → Kubernetes 권한 연결)" ;;
    AWS::EKS::PodIdentityAssociation) echo "Pod Identity 연결 (ServiceAccount → IAM Role)" ;;
    AWS::Logs::LogGroup) echo "CloudWatch 로그 그룹" ;;
    AWS::ECR::Repository) echo "ECR 이미지 저장소" ;;
    AWS::CodeBuild::Project) echo "CodeBuild CI 프로젝트" ;;
    AWS::S3::Bucket) echo "S3 버킷" ;;
    AWS::SecretsManager::Secret) echo "Secrets Manager 비밀값" ;;
    *) echo "${1#AWS::}" ;;
  esac
}

# 배포/삭제가 진행되는 동안 리소스가 하나씩 생성·삭제되는 모습을 출력
watch_stack_events() { # watch_stack_events STACK SINCE_EPOCH PID [TOTAL]
  local stack=$1 since=$2 pid=$3 total=${4:-?} seen="" done_n=0 spin=0
  local since_iso; since_iso=$(python3 -c 'import datetime,sys;print(datetime.datetime.fromtimestamp(int(sys.argv[1]),datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S"))' "$since")
  while kill -0 "$pid" 2>/dev/null; do
    aws cloudformation describe-stack-events --stack-name "$stack" --max-items 60 \
      --query "reverse(StackEvents[?LogicalResourceId!='$stack'].[Timestamp,EventId,LogicalResourceId,ResourceType,ResourceStatus])" \
      --output text 2>/dev/null |
    while read -r ts eid lid typ st; do
      [ "$ts" \< "$since_iso" ] && continue
      case "$seen" in *"$eid"*) continue ;; esac
      echo "$eid" >> "${TMPDIR:-/tmp}/.hannctl-seen-$$"
      local el=$(( $(date +%s) - since ))
      case "$st" in
        CREATE_IN_PROGRESS|UPDATE_IN_PROGRESS|DELETE_IN_PROGRESS)
          grep -q "IP:$lid" "${TMPDIR:-/tmp}/.hannctl-seen-$$" 2>/dev/null && continue
          echo "IP:$lid" >> "${TMPDIR:-/tmp}/.hannctl-seen-$$"
          printf '%s  [%3dm%02ds] … %-28s %s%s\n' "$C_DIM" $((el/60)) $((el%60)) "$lid" "$(res_label "$typ")" "$C_0" ;;
        DELETE_COMPLETE)
          printf '%s  [%3dm%02ds] 🗑  %-27s %s 삭제됨%s\n' "$C_DIM" $((el/60)) $((el%60)) "$lid" "$(res_label "$typ")" "$C_0" ;;
        *_COMPLETE)
          printf '%s  [%3dm%02ds] ✔ %-28s %s%s\n' "$C_G" $((el/60)) $((el%60)) "$lid" "$(res_label "$typ")" "$C_0" ;;
        *FAILED*)
          printf '%s  [%3dm%02ds] ✘ %-28s %s%s\n' "$C_R" $((el/60)) $((el%60)) "$lid" "$st" "$C_0" ;;
      esac
    done
    seen=$(cat "${TMPDIR:-/tmp}/.hannctl-seen-$$" 2>/dev/null)
    sleep 10
  done
  rm -f "${TMPDIR:-/tmp}/.hannctl-seen-$$"
}

stack_events_tail() {
  aws cloudformation describe-stack-events --stack-name "$1" --max-items 15 \
    --query 'StackEvents[?contains(ResourceStatus,`FAILED`)].[LogicalResourceId,ResourceStatusReason]' --output text 2>/dev/null | head -10 >&2
}

pre_clean_stack() { # CFN 이 지울 수 없는 내용물(버킷 객체, 수동 Access Key)만 정리 — hannctl- 리소스 한정
  local stack=$1
  aws cloudformation list-stack-resources --stack-name "$stack" \
    --query 'StackResourceSummaries[].[ResourceType,PhysicalResourceId]' --output text 2>/dev/null |
  while read -r typ pid; do
    case "$pid" in hannctl-*) ;; *) continue ;; esac
    if [ "$typ" = "AWS::S3::Bucket" ]; then
      info "버킷 비우기: $pid"; aws s3 rm "s3://$pid" --recursive >/dev/null 2>&1 || true
    elif [ "$typ" = "AWS::IAM::User" ]; then
      for k in $(aws iam list-access-keys --user-name "$pid" --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null); do
        info "정적 Access Key 삭제: $pid/$k"; aws iam delete-access-key --user-name "$pid" --access-key-id "$k"
      done
    fi
  done
}

eks_orphan_clean() { # 노드가 줄어들 때 VPC CNI 가 드물게 남기는 분리된 ENI(+클러스터 삭제 뒤 남은 EKS 보안 그룹) 정리 — 남아 있으면 서브넷·VPC 삭제가 실패한다
  local cl=${1:-${CLUSTER:-}} e
  case "$cl" in hannctl-*) ;; *) return 0 ;; esac
  for e in $(aws ec2 describe-network-interfaces --filters "Name=tag:cluster.k8s.amazonaws.com/name,Values=$cl" Name=status,Values=available \
               --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null); do
    info "노드 축소 때 남은 네트워크 인터페이스 삭제: $e"
    aws ec2 delete-network-interface --network-interface-id "$e" 2>/dev/null || true
  done
  if ! aws eks describe-cluster --name "$cl" >/dev/null 2>&1; then
    for e in $(aws ec2 describe-security-groups --filters "Name=tag:aws:eks:cluster-name,Values=$cl" \
                 --query 'SecurityGroups[].GroupId' --output text 2>/dev/null); do
      info "클러스터 삭제 후 남은 보안 그룹 삭제: $e"
      aws ec2 delete-security-group --group-id "$e" >/dev/null 2>&1 || true
    done
  fi
  return 0
}
destroy_stack() { # destroy_stack STACK
  local stack=$1 st; st=$(stack_status "$stack")
  [ "$st" = "NONE" ] && { ok "$stack 없음 (이미 삭제됨)"; return 0; }
  case "$stack" in hannctl-*) ;; *) die "hannctl- 스택만 삭제할 수 있습니다: $stack" ;; esac
  section "스택 삭제: $stack (현재 $st)"
  pre_clean_stack "$stack"
  local t0; t0=$(date +%s)
  aws cloudformation delete-stack --stack-name "$stack"
  info "삭제 진행 (EKS 포함 시 10~15분) — 리소스가 하나씩 사라지는 과정:"
  aws cloudformation wait stack-delete-complete --stack-name "$stack" >/dev/null 2>&1 &
  local wpid=$!
  watch_stack_events "$stack" "$t0" "$wpid"
  if ! wait "$wpid"; then
    warn "1차 삭제 실패 → 원인 확인 후 재시도"; stack_events_tail "$stack"
    pre_clean_stack "$stack"; eks_orphan_clean; aws cloudformation delete-stack --stack-name "$stack"
    aws cloudformation wait stack-delete-complete --stack-name "$stack" || die "삭제 실패: 콘솔에서 $stack 이벤트 확인"
  fi
  ok "$stack 삭제 완료"
  local left; left=$(aws resourcegroupstaggingapi get-resources --tag-filters "Key=aws:cloudformation:stack-name,Values=$stack" \
    --query 'length(ResourceTagMappingList)' --output text 2>/dev/null || echo 0)
  [ "$left" = "0" ] && ok "잔여 태그 리소스 0건" || info "태그 검색 결과에 $left 건이 보이지만 삭제 직후의 캐시입니다(수 분 뒤 사라짐). 실제 존재 여부: ./run.sh status"
}

set_lifetime() { # set_lifetime STACK HOURS — 유지 시간을 "생성 시각부터 HOURS 시간"으로 변경 (태그만 갱신)
  local stack=$1 hours=$2 created now expires left
  case "$hours" in ''|*[!0-9]*) die "사용법: ./run.sh lifetime <0~24 시간> (0 = 무제한)" ;; esac
  [ "$hours" -le 24 ] || die "유지 시간은 0~24 시간입니다 (0 = 무제한)"
  [ "$(stack_status "$stack")" = NONE ] && die "스택이 없습니다. 먼저 ./run.sh demo 또는 up"
  ensure_guard
  created=$(stack_created_epoch "$stack"); now=$(date +%s)
  if [ "$hours" -eq 0 ]; then
    expires=never; warn "시간 제한을 끕니다 — 자동 삭제되지 않으니 끝나면 반드시 ./run.sh down"
  else
    expires=$(iso_from_epoch $((created + hours * 3600))); left=$(( (created + hours * 3600 - now) / 60 ))
    if [ "$left" -le 0 ]; then warn "생성 후 이미 ${hours}시간이 지났습니다 → 10분 안에 자동 삭제됩니다"; left=0; fi
    info "생성 $(iso_from_epoch "$created") + ${hours}h = $expires UTC (지금부터 약 $((left / 60))시간 $((left % 60))분 남음)"
  fi
  local params; params=$(aws cloudformation describe-stacks --stack-name "$stack" \
    --query 'Stacks[0].Parameters[].ParameterKey' --output text | tr '\t' '\n' | sed 's/.*/ParameterKey=&,UsePreviousValue=true/' | tr '\n' ' ')
  # shellcheck disable=SC2086
  aws cloudformation update-stack --stack-name "$stack" --use-previous-template --role-arn "$EXEC_ROLE_ARN" \
    --capabilities CAPABILITY_NAMED_IAM --parameters $params \
    --tags Key=Project,Value=hannctl "Key=hannctl:scenario,Value=$SCENARIO_ID" "Key=hannctl:lifetime-hours,Value=$hours" \
           "Key=hannctl:expires-at,Value=$expires" "Key=hannctl:est-usd-per-hour,Value=$HOURLY_USD" \
           "Key=hannctl:owner,Value=$(deployer_arn | awk -F/ '{print $NF}')" Key=hannctl:managed-by,Value=hannctl-cli >/dev/null \
    && info "태그 갱신 중(1~3분)…" && aws cloudformation wait stack-update-complete --stack-name "$stack" && ok "유지 시간 ${hours}시간으로 변경 완료"
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

# ----------------------------------------------------------------------------- Kubernetes
kube_init() { # kube_init CLUSTER — 시나리오 폴더 전용 kubeconfig (사용자 ~/.kube/config 를 건드리지 않음)
  export KUBECONFIG="$SCEN_DIR/.kube/config"
  mkdir -p "$SCEN_DIR/.kube"
  aws eks update-kubeconfig --name "$1" --kubeconfig "$KUBECONFIG" --alias "$1" >/dev/null || die "kubeconfig 생성 실패"
  kubectl config use-context "$1" >/dev/null
}
k() { kubectl --context "$CLUSTER" "$@"; }
add_role_context() { # add_role_context ALIAS ROLE_ARN — IAM Role 을 assume 해서 접속하는 컨텍스트
  aws eks update-kubeconfig --name "$CLUSTER" --kubeconfig "$KUBECONFIG" --role-arn "$2" --alias "$1" --user-alias "$1" >/dev/null
  kubectl config use-context "$CLUSTER" >/dev/null
}
wait_nodes() { # Ready 노드가 1대 이상이면 진행 (노드 그룹 교체 중 사라지는 옛 노드는 기다리지 않음)
  info "노드 Ready 대기…"
  local i ready=0
  for i in $(seq 1 60); do
    ready=$(k get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')
    [ "$ready" -ge 1 ] && break
    sleep 10
  done
  [ "$ready" -ge 1 ] || die "노드 Ready 실패 (10분) — ./run.sh status 로 노드 그룹 상태 확인"
  ok "노드 ${ready}대 Ready"
}
install_kyverno() {
  section "Kyverno $KYVERNO_CHART_VERSION 설치 (Admission 정책 엔진)"
  helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
  helm repo update kyverno >/dev/null 2>&1 || true
  helm upgrade --install kyverno kyverno/kyverno --kube-context "$CLUSTER" -n kyverno --create-namespace \
    --version "$KYVERNO_CHART_VERSION" \
    --set admissionController.replicas=1 --set backgroundController.replicas=1 \
    --set cleanupController.enabled=false --set reportsController.replicas=1 \
    --set features.policyExceptions.enabled=false \
    --wait --timeout 10m >/dev/null || die "Kyverno 설치 실패"
  ok "Kyverno 준비"
}

# 서버측 dry-run 으로 Admission 결과 확인 → ALLOWED / DENIED
admission_try() { # admission_try NAMESPACE [메시지 저장 파일]  (stdin: manifest) → ALLOWED / DENIED / ERROR
  # $(...) 안에서 호출되므로 메시지는 변수가 아니라 파일로 남긴다 (서브셸 변수는 사라짐)
  local out=${2:-${RUN_DIR:-${TMPDIR:-/tmp}}/.admission-last.txt} msg rc
  msg=$(k apply -n "$1" --dry-run=server -f - 2>&1); rc=$?
  printf '%s\n' "$msg" > "$out"
  if [ $rc -eq 0 ]; then echo ALLOWED
  elif echo "$msg" | grep -qiE 'denied|violates|forbidden|blocked|not allowed|validation error'; then echo DENIED
  else echo ERROR; fi   # Namespace 없음 등 정책과 무관한 실패는 "차단"으로 세지 않는다
}
wait_policies() { # Kyverno ValidatingPolicy 가 READY 될 때까지 (최대 60초)
  local i; for i in $(seq 1 12); do
    k get validatingpolicy -o jsonpath='{range .items[*]}{.status.conditionStatus.ready}{"\n"}{end}' 2>/dev/null | grep -qv true || return 0
    sleep 5
  done
}

# Pod 안에서 HTTP 호출 → HTTP 상태코드 / BLOCKED
http_from_pod() { # http_from_pod NS DEPLOY URL [TIMEOUT]
  local r; r=$(k -n "$1" exec "deploy/$2" -- python3 /app/app.py probe "$3" "${4:-4}" 2>/dev/null | tail -1)
  if [ -z "$r" ]; then   # exec 자체 실패(노드 교체로 Pod 재시작 중 등) → Pod 준비를 기다려 한 번 더
    k -n "$1" rollout status "deploy/$2" --timeout=120s >/dev/null 2>&1
    r=$(k -n "$1" exec "deploy/$2" -- python3 /app/app.py probe "$3" "${4:-4}" 2>/dev/null | tail -1)
  fi
  echo "${r:-ERROR}"
}

# ----------------------------------------------------------------------------- 증적/결과
run_new() { # 새 실행 디렉터리
  RUN_ID="run-$(date +%Y%m%d-%H%M%S)"
  RUN_DIR="$SCEN_DIR/evidence/$RUN_ID"
  mkdir -p "$RUN_DIR/before" "$RUN_DIR/after"
  ln -sfn "$RUN_ID" "$SCEN_DIR/evidence/latest"
  info "증적 디렉터리: ${RUN_DIR#$SCEN_DIR/}"
}
run_latest() {
  [ -L "$SCEN_DIR/evidence/latest" ] || run_new
  RUN_ID=$(readlink "$SCEN_DIR/evidence/latest"); RUN_DIR="$SCEN_DIR/evidence/$RUN_ID"
}
ev() { # ev PHASE NAME -- command... : 명령 출력을 증적 파일로 저장(+화면 출력)
  local phase=$1 name=$2; shift 3
  cmdline "$*"
  { echo "# $(date '+%F %T') \$ $*"; "$@" 2>&1; } | tee "$RUN_DIR/$phase/$name.txt" | sed 's/^/    /' | head -${EV_LINES:-25}
}
timeline() { # timeline PHASE TITLE DETAIL
  pyjson 'import json,sys,time;print(json.dumps({"ts":time.strftime("%H:%M:%S"),"phase":sys.argv[1],"title":sys.argv[2],"detail":sys.argv[3]},ensure_ascii=False))' \
    "$1" "$2" "${3:-}" >> "$RUN_DIR/timeline.jsonl"
}
record() { # record KEY PHASE EXPECTED OBSERVED "TITLE" ["METRIC"]
  local key=$1 phase=$2 expected=$3 observed=$4 title=$5 metric=${6:-}
  pyjson 'import json,sys,time;k,p,e,o,t,m=sys.argv[1:7];print(json.dumps({"key":k,"phase":p,"expected":e,"observed":o,"ok":e==o,"title":t,"metric":m,"ts":time.strftime("%H:%M:%S")},ensure_ascii=False))' \
    "$key" "$phase" "$expected" "$observed" "$title" "$metric" >> "$RUN_DIR/results.jsonl"
  local mark color
  if [ "$expected" = "$observed" ]; then mark="✔"; color=$C_G; else mark="✘"; color=$C_R; fi
  # Before 에서 '차단' 대상 경로가 열려 있는 것 = 위험이 재현된 것 → ⚠ 노란색
  if [ "$phase" = "before" ] && [ "$expected" = "$observed" ]; then
    case "$title" in
      정상*|인프라*|모든*|유지시간*|증적*|자체*|kube-bench\ 자동*|점검\ 소요*) ;;   # 정상 동작·측정 항목
      *) case "$observed" in BLOCKED|DENIED|ACCESS_DENIED|no) ;; *) mark="⚠"; color=$C_Y ;; esac ;;   # 이미 막혀 있으면 위험 아님
    esac
  fi
  printf '  %s%s [%-6s] %-44s 기대=%-9s 관찰=%-9s %s%s\n' "$color" "$mark" "$phase" "$title" "$expected" "$observed" "${metric:+($metric)}" "$C_0"
}

improve() { # improve N TOTAL "제목" "무엇이 바뀌나" "기대 효과" FUNC ["배움 포인트"]
  local n=$1 total=$2 title=$3 what=$4 effect=$5 fn=$6 lesson=${7:-}
  printf '\n%s┏━ [개선 %s/%s] %s%s\n' "$C_BOLD$C_G" "$n" "$total" "$title" "$C_0"
  printf '%s┃  변경: %s%s\n┃  효과: %s\n' "$C_G" "$what" "$C_0" "$effect"
  timeline after "[$n/$total] $title" "$what → $effect"
  "$fn"
  [ -n "$lesson" ] && printf '%s┃  💡 배움 포인트: %s%s\n' "$C_BOLD$C_C" "$lesson" "$C_0"
  printf '%s┗━ 완료%s\n' "$C_G" "$C_0"
  [ "$n" -lt "$total" ] && countdown "$STEP_PAUSE_SECONDS" "다음 개선 단계로"
  return 0
}

# 적용할 설정 파일의 "핵심 줄"을 보여준다 (주석 포함, 메타데이터 잡음 제외) — "이 설정이 → 이 결과" 학습용
show_manifest() { # show_manifest FILE [최대줄수]
  local f=$1 max=${2:-${MANIFEST_LINES:-18}}
  printf '%s┃  📄 %s%s\n' "$C_C" "${f#$SCEN_DIR/}" "$C_0"
  grep -v -E '^[[:space:]]*$|^---$|^[[:space:]]*(labels|annotations):|^apiVersion:' "$f" | head -"$max" | sed "s/^/${C_DIM}┃     /;s/\$/${C_0}/"
  local n; n=$(grep -c . "$f"); [ "$n" -gt "$max" ] && printf '%s┃     … (전체: %s)%s\n' "$C_DIM" "${f#$SCEN_DIR/}" "$C_0"
  return 0
}
lesson() { printf '%s  💡 %s%s\n' "$C_C" "$*" "$C_0"; }   # Before 테스트 등에서 짧은 해설

tag_audit() { # tag_audit PHASE — 스택의 모든 리소스가 hannctl 이름 또는 Project=hannctl 태그를 갖는지
  aws cloudformation list-stack-resources --stack-name "$STACK" --output json > "$RUN_DIR/$1/stack-resources.json"
  # 스택 태그가 전파되지 않는 리소스(Launch Template 등)도 잡도록 "스택 태그 ∪ Project=hannctl" 합집합으로 조회
  { aws resourcegroupstaggingapi get-resources --tag-filters "Key=aws:cloudformation:stack-name,Values=$STACK" --output json
    aws resourcegroupstaggingapi get-resources --tag-filters "Key=Project,Values=hannctl" --output json
    aws resourcegroupstaggingapi get-resources --tag-filters "Key=Name" --resource-type-filters ec2:launch-template --output json; } |
    python3 -c 'import json,sys
d=json.JSONDecoder(); s=sys.stdin.read().strip(); out=[]
while s:
    o,i=d.raw_decode(s); out+=o["ResourceTagMappingList"]; s=s[i:].strip()
print(json.dumps({"ResourceTagMappingList":out}))' \
    > "$RUN_DIR/$1/tagged-resources.json"
  local res; res=$(python3 "$LIB_DIR/tagcheck.py" "$RUN_DIR/$1/stack-resources.json" "$RUN_DIR/$1/tagged-resources.json" "$RUN_DIR/$1/tag-audit.txt")
  record tag_compliance "$1" COMPLIANT "$res" "모든 AWS 리소스 hannctl 식별자"
}
finops_audit() { # 유지시간 태그 + guard + janitor 존재
  local ttl janitor
  ttl=$(stack_tag "$STACK" hannctl:lifetime-hours)   # 유지 시간 태그(0 = 무제한이어도 월 상한은 동작)
  janitor=$(aws lambda get-function --function-name hannctl-janitor --query 'Configuration.State' --output text 2>/dev/null || echo NONE)
  if [ -n "$ttl" ] && [ "$ttl" != "None" ] && [ "$janitor" = "Active" ]; then
    record finops_guard "$1" PROTECTED PROTECTED "유지시간 자동삭제 + janitor + 월상한" "lifetime=${ttl}h"
  else
    record finops_guard "$1" PROTECTED MISSING "유지시간 자동삭제 + janitor + 월상한"
  fi
}

score_run() {
  section "자동 평가 (rubric.json)"
  python3 "$LIB_DIR/score.py" --rubric "$SCEN_DIR/rubric.json" --run "$RUN_DIR" --title "$SCENARIO_TITLE"
}

# ----------------------------------------------------------------------------- 공통 명령 디스패처
# 시나리오 run.sh 가 구현하는 함수:
#   scenario_up      : (스택 배포 이후) 클러스터 내부 기본 구성
#   scenario_before  : Before(통제 전) 상태 적용
#   scenario_tests   : scenario_tests PHASE — 동일 테스트 세트
#   scenario_after   : improve 단계들을 순서대로 호출
#   stack_params     : CFN 파라미터 출력(줄 단위)
usage() {
  cat <<EOF
${C_BOLD}$SCENARIO_TITLE${C_0}
사용법: ./run.sh <명령> [옵션]

  doctor             처음 실행 전 환경 점검 (도구·로그인·작업용 역할·한도) — 필요하면 자동 설치/로그인
  login | logout     AWS 콘솔 로그인으로 임시 자격 증명 받기 / 이 PC 의 로그인 지우기 (보통은 자동)
  up                 AWS 인프라(CloudFormation) + 클러스터 기본 구성
  demo [--before-wait N] [--step-pause N]
                     Before 적용 → 테스트 → N초 후 자동으로 개선 단계별 적용 → After 테스트 → 채점/보고서
  before             Before(통제 전) 상태 적용 + 테스트
  after              개선 단계 적용 + After 테스트 + 채점
  test before|after  현재 상태로 테스트만 실행 (before 는 새 결과 폴더, after 는 최근 결과 폴더에 기록 — 클러스터 구성은 바꾸지 않음)
  score              최근 실행 결과 채점 + REPORT.md 생성
  status             AWS/EKS 리소스 한눈에 보기
  watch              (다른 터미널에서) 클러스터 상태 + 진행 단계 실시간 관찰
  cost               이번 달 hannctl 누적 예상 비용 / 상한
  cap <USD>          월 비용 상한 변경 (기본 20, 0 = 끄기)
  kubeconfig         KUBECONFIG·PATH 설정문 출력 → eval "\$(./run.sh kubeconfig)" (직접 kubectl/aws 사용 시)
  lifetime <HOURS>   유지 시간 변경 — "생성 시각부터 HOURS 시간" (예: 6시간 중 4시간 지난 뒤 9 → 남은 5시간, 0 = 무제한)
  down               이 시나리오의 모든 AWS 리소스 삭제(스택 + 내용물) 및 잔여 확인
  down-all           down + 공통 FinOps Guard(janitor/예산)까지 삭제(다른 hannctl 스택이 없을 때)
  down-all --identity  위 + 작업용 역할(hannctl-identity 스택)까지 삭제

옵션/환경 변수: --hours N 또는 HANNCTL_LIFETIME_HOURS(처음 유지 시간, 기본 6) BEFORE_WAIT_SECONDS(기본 60)
          STEP_PAUSE_SECONDS(기본 5) HANNCTL_BUDGET_USD(월 상한, 기본 20)
          HANNCTL_REGION(기본 ap-northeast-2) HANNCTL_SOURCE_PROFILE(로그인 대신 쓸 기존 프로필, 선택)
EOF
}

cmd_up() {
  preflight
  cost_guard
  choose_lifetime
  guide_step 3 "인프라 생성 — CloudFormation 이 AWS 리소스를 만든다 (약 12~14분)"
  local params; params=$(stack_params)
  # shellcheck disable=SC2086
  deploy_stack "$STACK" "$SCEN_DIR/cfn/stack.yaml" $params
  guide_step 4 "클러스터 기본 구성 — 노드 준비 + 실습 앱·도구 설치"
  console_view_access
  kube_init "$CLUSTER"
  wait_nodes
  scenario_up
  mark_setup_done
  if [ -n "${RUN_T0:-}" ]; then ok "인프라 준비 완료 → 이어서 Before 단계로 넘어갑니다"
  else ok "인프라 준비 완료 → ./run.sh demo  또는 ./run.sh status"; fi
}
ensure_up() { # 스택 + 클러스터 내부 구성이 모두 끝났는지 확인하고, 빠진 부분만 이어서 수행
  local st; st=$(stack_status "$STACK")
  case "$st" in
    CREATE_COMPLETE|UPDATE_COMPLETE|UPDATE_ROLLBACK_COMPLETE)
      kube_init "$CLUSTER"
      if ! k -n kube-system get configmap hannctl-setup >/dev/null 2>&1; then
        guide_step 4 "클러스터 기본 구성 — 노드 준비 + 실습 앱·도구 설치"
        warn "클러스터 내부 구성이 완료되지 않았습니다 → 이어서 구성합니다"
        wait_nodes; scenario_up; mark_setup_done
      fi ;;
    *) cmd_up ;;
  esac
}
ensure_cluster() { # 테스트 전용: 스택·클러스터가 있는지만 확인 (내부 구성은 건드리지 않는다 — 직접 구성한 상태 그대로 테스트)
  case "$(stack_status "$STACK")" in
    CREATE_COMPLETE|UPDATE_COMPLETE|UPDATE_ROLLBACK_COMPLETE) kube_init "$CLUSTER" ;;
    *) die "스택 $STACK 이 없습니다 — 먼저 ./run.sh up (또는 README 6절의 인프라 생성)을 진행하세요" ;;
  esac
}
console_view_access() { # 로그인한 콘솔 사용자도 EKS 콘솔에서 노드·Pod 를 볼 수 있게 읽기 전용(AmazonEKSAdminViewPolicy) 권한을 준다
  local arn role
  arn=$(boot_aws sts get-caller-identity --query Arn --output text 2>/dev/null) || return 0
  case "$arn" in
    *":assumed-role/"*) role=$(echo "$arn" | cut -d/ -f2)   # SSO 역할처럼 경로가 있는 역할도 정확한 ARN 으로
       arn=$(boot_aws iam get-role --role-name "$role" --query Role.Arn --output text 2>/dev/null) || return 0 ;;
  esac
  case "$arn" in *":role/$OPERATOR_ROLE") return 0 ;; esac   # 작업용 역할은 이미 관리자
  aws eks describe-access-entry --cluster-name "$CLUSTER" --principal-arn "$arn" >/dev/null 2>&1 && return 0
  aws eks create-access-entry --cluster-name "$CLUSTER" --principal-arn "$arn" >/dev/null 2>&1 &&
  aws eks associate-access-policy --cluster-name "$CLUSTER" --principal-arn "$arn" \
    --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminViewPolicy --access-scope type=cluster >/dev/null 2>&1 &&
  info "AWS 콘솔에서도 노드·Pod 를 볼 수 있도록 로그인한 사용자에게 EKS 읽기 전용 권한을 주었습니다: ${arn##*:}"
  return 0
}
mark_setup_done() { # scenario_up 완료 표식 (중단 후 재실행 시 이어하기용)
  k -n kube-system create configmap hannctl-setup --from-literal=scenario="$SCENARIO_ID" \
    --from-literal=at="$(date -u +%FT%TZ)" --dry-run=client -o yaml | k apply -f - >/dev/null
}
cmd_before() {
  ensure_up; run_new
  guide_step 5 "Before — 보호 장치가 없는 상태에서 위험을 재현한다"
  banner "BEFORE — 통제 전 상태 재현 ($SCENARIO_TITLE)"
  timeline before "Before 상태 적용" "보호 장치가 부족한 실습 상태"
  scenario_before
  section "Before 테스트"
  info "읽는 법: ⚠ 노란 줄 = 개선 후 막혀야 할 위험이 지금은 그대로 열려 있음(위험 재현 성공), ✔ 초록 줄 = 정상 동작"
  scenario_tests before
}
cmd_after() {
  ensure_up; run_latest
  guide_step 7 "개선 단계 — 보호 장치를 하나씩 적용하고 바로 효과를 확인한다"
  banner "AFTER — 개선 단계 자동 적용"
  scenario_after
  guide_step 8 "After 테스트·채점 — Before 와 같은 테스트를 다시 실행한다"
  section "After 테스트 (Before 와 동일한 테스트)"
  scenario_tests after
  write_run_cost
  score_run
}
cmd_demo() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --hours) HANNCTL_LIFETIME_HOURS=$2; shift 2 ;;
      --before-wait) BEFORE_WAIT_SECONDS=$2; shift 2 ;;
      --step-pause)  STEP_PAUSE_SECONDS=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  guide_step 2 "실행 시작 — 유지 시간을 정하고 demo 를 시작한다"
  preflight; choose_lifetime   # 가장 먼저 유지 시간을 정한다
  local t0; t0=$(date +%s); RUN_T0=$t0
  printf '\n%s👀 팁: 다른 터미널에서 "./run.sh watch" 를 실행하면 클러스터가 바뀌는 모습을 실시간으로 볼 수 있습니다.%s\n' "$C_BOLD$C_Y" "$C_0"
  printf '%s   GUIDE.md 의 단계 번호(📍)가 이 화면의 📍 표시와 같습니다. 화면과 문서를 맞춰 보며 따라가세요.%s\n' "$C_Y" "$C_0"
  cmd_before
  guide_step 6 "Before 관찰 — 위험한 상태를 직접 살펴보는 시간"
  section "Before 관찰 시간 (${BEFORE_WAIT_SECONDS}s) — 다른 터미널에서 ./run.sh status 또는 README 의 조회 명령을 실행해 보세요"
  countdown "$BEFORE_WAIT_SECONDS" "Before 상태 유지 중, 이후 자동으로 After 로 전환"
  cmd_after
  guide_step 9 "결과 확인 — 점수와 보고서(REPORT.html)"
  ok "데모 총 소요 $(( ($(date +%s) - t0) / 60 ))분 — 보고서: ${RUN_DIR#$SCEN_DIR/}/REPORT.md (.html)"
  open_report
}
open_report() { # HANNCTL_OPEN_REPORT=0 이면 자동으로 열지 않음
  [ "${HANNCTL_OPEN_REPORT:-1}" = 1 ] || return 0
  local f="$RUN_DIR/REPORT.html"
  if command -v open >/dev/null 2>&1 && [ "$(uname -s)" = Darwin ]; then open "$f" >/dev/null 2>&1
  elif command -v xdg-open >/dev/null 2>&1 && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then xdg-open "$f" >/dev/null 2>&1 &
  fi
  return 0
}
cmd_watch() { # 다른 터미널에서 실시간 관찰용 (Ctrl+C 로 종료)
  preflight >/dev/null
  local st
  while st=$(aws eks describe-cluster --name "$CLUSTER" --query cluster.status --output text 2>/dev/null); [ "$st" != ACTIVE ]; do
    clear
    printf '%s%s — 실시간 관찰 (%s)%s\n' "$C_BOLD" "$SCENARIO_TITLE" "$(date '+%H:%M:%S')" "$C_0"
    printf '  ⏳ EKS 클러스터 %s 준비 대기 중 (현재: %s) — 인프라 생성에 10~15분 걸립니다. 준비되면 자동으로 화면이 바뀝니다.\n' "$CLUSTER" "${st:-아직 없음}"
    sleep 15
  done
  kube_init "$CLUSTER"
  local stack_t0   # 이번 스택이 만들어지기 전의 실행 기록(지난 실습)은 "최근 진행 단계"에 보여주지 않는다
  stack_t0=$(aws cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].CreationTime' --output text 2>/dev/null |
    python3 -c 'import sys,datetime;t=sys.stdin.read().strip();print(int(datetime.datetime.fromisoformat(t.replace("Z","+00:00")).timestamp()) if t and t!="None" else 0)' 2>/dev/null || echo 0)
  while true; do
    clear
    printf '%s%s — 실시간 관찰 (%s, 5초마다 갱신, Ctrl+C 종료)%s\n' "$C_BOLD" "$SCENARIO_TITLE" "$(date '+%H:%M:%S')" "$C_0"
    scenario_watch 2>/dev/null || scenario_status 2>/dev/null
    if [ -L "$SCEN_DIR/evidence/latest" ] && [ -f "$SCEN_DIR/evidence/latest/timeline.jsonl" ] &&
       [ "$(python3 -c 'import os,sys;print(int(os.path.getmtime(sys.argv[1])))' "$SCEN_DIR/evidence/latest/timeline.jsonl")" -ge "${stack_t0:-0}" ]; then
      printf '\n%s최근 진행 단계%s (%s)\n' "$C_BOLD" "$C_0" "$(basename "$(readlink "$SCEN_DIR/evidence/latest")")"
      tail -4 "$SCEN_DIR/evidence/latest/timeline.jsonl" | python3 -c 'import sys,json;[print("  ",d["ts"],d["title"]) for d in map(json.loads,sys.stdin)]'
    fi
    sleep 5
  done
}
cmd_status() {
  preflight
  banner "STATUS — $SCENARIO_TITLE"
  section "AWS (CloudFormation 스택: $STACK)"
  aws cloudformation describe-stacks --stack-name "$STACK" \
    --query 'Stacks[0].{"상태":StackStatus,"생성":CreationTime,"유지시간":Tags[?Key==`hannctl:lifetime-hours`]|[0].Value,"자동삭제UTC":Tags[?Key==`hannctl:expires-at`]|[0].Value}' --output table 2>/dev/null || { warn "스택 없음"; return 0; }
  aws cloudformation list-stack-resources --stack-name "$STACK" \
    --query 'StackResourceSummaries[].[ResourceType,PhysicalResourceId,ResourceStatus]' --output text | awk '{printf "    %-40s %-55s %s\n",$1,substr($2,1,55),$3}'
  section "EKS"
  aws eks describe-cluster --name "$CLUSTER" --query 'cluster.{"버전":version,"상태":status,"엔드포인트접근":resourcesVpcConfig.publicAccessCidrs,"로그":logging.clusterLogging[?enabled].types|[0]}' --output table
  kube_init "$CLUSTER"
  section "Kubernetes 노드 / 워크로드"
  k get nodes -o wide | cut -c1-140
  k get deploy,svc,hpa,networkpolicy -A -l hannctl.io/scenario="$SCENARIO_ID" 2>/dev/null
  k get validatingpolicy 2>/dev/null
  scenario_status 2>/dev/null || true
}
cmd_down() {
  preflight; ensure_guard
  guide_step 10 "삭제 — 이 시나리오가 만든 AWS 리소스를 모두 지운다"
  banner "DOWN — $SCENARIO_TITLE 리소스 전체 삭제"
  scenario_down 2>/dev/null || true
  eks_orphan_clean
  destroy_stack "$STACK"
  rm -rf "$SCEN_DIR/.kube"
  ok "완료. (공통 FinOps Guard 는 유지됨 — 함께 지우려면: ./run.sh down-all)"
}
cmd_down_all() { # 이 시나리오 + (다른 hannctl 시나리오 스택이 없을 때만) FinOps Guard 까지 삭제
  cmd_down
  local others; others=$(aws cloudformation describe-stacks \
    --query "Stacks[?starts_with(StackName,'hannctl-') && StackName!='$GUARD_STACK' && StackName!='$IDENTITY_STACK' && StackStatus!='DELETE_COMPLETE'].StackName" --output text)
  if [ -n "$others" ]; then
    warn "다른 hannctl 시나리오 스택이 아직 있어 FinOps Guard${1:+ 와 작업용 신원} 은 유지합니다: $others"
  else
    destroy_stack "$GUARD_STACK"
    aws budgets delete-budget --account-id "$(account_id)" --budget-name hannctl-monthly-budget >/dev/null 2>&1 || true
    ok "hannctl 리소스 전체 정리 완료"
    if [ "${1:-}" = --identity ]; then cmd_identity_delete
    else info "작업용 신원($IDENTITY_STACK: $OPERATOR_ROLE, 비용 0원)은 다음 실습을 위해 남깁니다. 지우려면: ./run.sh down-all --identity"; fi
  fi
}

cmd_doctor() { # 처음 실행 전 환경 점검 — 무엇이 부족한지 ✔/✘ 로 알려준다
  guide_step 1 "사전 점검 — 도구·로그인·권한·한도를 확인한다"
  banner "DOCTOR — 실행 환경 점검 ($SCENARIO_TITLE)"
  local bad=0
  tools_ready || { warn "없는 도구를 먼저 설치합니다"; bash "$SCEN_DIR/tools/install-tools.sh"; hash -r; }
  chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else err "$1 → $3"; bad=$((bad + 1)); fi; }
  chk "bash / OS: $(uname -s) $(uname -m)" "true" ""
  chk "python3 ($(python3 --version 2>&1))" "python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)'" "./tools/install-tools.sh 실행 (START_HERE.md 2단계)"
  chk "curl" "command -v curl" "curl 설치"
  chk "AWS CLI 2.32+ ($(AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null aws --version 2>&1 | cut -d' ' -f1))" "awscli_ok" "./tools/install-tools.sh 실행 (START_HERE.md 2단계)"
  chk "kubectl ($(kubectl version --client 2>/dev/null | head -1))" "command -v kubectl" "./tools/install-tools.sh 실행"
  chk "helm ($(helm version --short 2>/dev/null))" "command -v helm" "./tools/install-tools.sh 실행"
  ( ensure_identity ) || true                               # 로그인이 안 되어 있으면 여기서 자동 로그인 + 작업용 역할 준비
  chk "로그인 ($(in_cloudshell && echo CloudShell || { [ -n "$HANNCTL_SOURCE_PROFILE" ] && echo "기존 프로필 $HANNCTL_SOURCE_PROFILE" || echo "aws login → 프로필 $LOGIN_PROFILE"; }))" \
      "boot_aws sts get-caller-identity" "./run.sh login (START_HERE.md 3단계)"
  if ! boot_aws sts get-caller-identity >/dev/null 2>&1; then   # 로그인이 없으면 나머지 AWS 점검은 의미가 없다
    info "AWS 권한·한도 점검은 로그인한 뒤 다시 ./run.sh doctor 로 확인합니다"
    err "$bad 개 항목을 해결한 뒤 다시 ./run.sh doctor"; return 1
  fi
  export AWS_PROFILE="$HANNCTL_PROFILE"
  chk "작업용 신원 $OPERATOR_ROLE (임시 자격 증명, 프로필 $HANNCTL_PROFILE)" \
      "aws sts get-caller-identity --query Arn --output text | grep -q ':assumed-role/$OPERATOR_ROLE/'" "로그인한 사용자에게 관리자 권한이 필요 (IAM 역할 생성)"
  chk "리전 $HANNCTL_REGION 에서 EKS 사용 가능" "aws eks list-clusters" "권한 또는 리전 확인"
  chk "CloudFormation/IAM 권한" "aws cloudformation list-stacks --max-items 1 && aws iam list-roles --max-items 1" "hannctl-identity 스택(역할 권한) 확인"
  local vpcs eips; vpcs=$(aws ec2 describe-vpcs --query 'length(Vpcs)' --output text 2>/dev/null || echo 9)
  eips=$(aws ec2 describe-addresses --query 'length(Addresses)' --output text 2>/dev/null || echo 9)
  if [ "$(stack_status "$STACK")" != NONE ]; then ok "VPC: 이 시나리오 스택이 이미 있음 (현재 ${vpcs}/5)"
  else chk "VPC 여유 (현재 ${vpcs}/5, 시나리오당 1개 필요)" "[ $vpcs -lt 5 ]" "다른 실습을 down 하거나 VPC 한도 증가 요청"; fi
  chk "탄력적 IP 여유 (현재 ${eips}/5)" "[ $eips -lt 5 ]" "사용하지 않는 EIP 정리 또는 한도 증가 요청"
  chk "EKS API 허용용 공인 IP 확인 ($(my_ip_cidr))" "[ -n \"\$(curl -s --max-time 5 https://checkip.amazonaws.com)\" ]" "인터넷 연결 확인"
  python3 "$LIB_DIR/cost.py" 2>/dev/null | tail -1 | sed 's/^ */  • /'
  [ $bad -eq 0 ] && ok "모든 점검 통과 → ./run.sh demo" || err "$bad 개 항목을 해결한 뒤 다시 ./run.sh doctor"
  [ $bad -eq 0 ]
}

dispatch() {
  local cmd=${1:-help}; shift || true
  case "$cmd" in help|-h|--help|kubeconfig) ;; *) ensure_tools ;; esac   # 모든 명령 전에 도구 확인
  case "$cmd" in
    up) [ "${1:-}" = --hours ] && HANNCTL_LIFETIME_HOURS=${2:-}; cmd_up ;;
    demo) cmd_demo "$@" ;;
    before) cmd_before ;;
    after) cmd_after ;;
    test) ensure_cluster   # before → 새 증적 폴더, after → 최근 증적 폴더에 이어 기록
          if [ "${1:-after}" = before ]; then run_new; else run_latest; fi
          scenario_tests "${1:-after}"
          [ "${1:-after}" = after ] && write_run_cost ;;
    score) run_latest; score_run ;;
    status) cmd_status ;;
    watch) cmd_watch ;;
    cost) cmd_cost ;;
    cap) cmd_cap "$@" ;;
    doctor) cmd_doctor ;;
    kubeconfig) echo "export KUBECONFIG=$SCEN_DIR/.kube/config; export PATH=$SCEN_DIR/.tools/bin:\$PATH; export AWS_PROFILE=$HANNCTL_PROFILE AWS_REGION=$HANNCTL_REGION AWS_PAGER=\"\"" ;;
    login) cmd_login ;;
    logout) cmd_logout ;;
    lifetime|extend) preflight; set_lifetime "$STACK" "${1:-}" ;;
    down) cmd_down ;;
    down-all) cmd_down_all "${1:-}" ;;
    *) usage ;;
  esac
}
