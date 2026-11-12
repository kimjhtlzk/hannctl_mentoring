# 처음 시작하기 — s1-shop-deploy-resilience

아래 순서대로 한 번만 준비하면, 이후에는 `./run.sh demo` 명령 하나로 AWS 인프라 생성 → 문제 재현 → 자동 개선 → 검증 → 채점까지 진행되고, `./run.sh down` 으로 삭제된다.

---

## 1단계. 시나리오 내려받기

**방법 A — git (이 시나리오만 받기)**

```bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/kimjhtlzk/hannctl_mentoring.git
cd hannctl_mentoring
git sparse-checkout set s1-shop-deploy-resilience
cd s1-shop-deploy-resilience
```

**방법 B — git 없이 압축 파일로 받기** (curl, tar 만 있으면 된다)

```bash
curl -L https://github.com/kimjhtlzk/hannctl_mentoring/archive/refs/heads/main.tar.gz | tar xz --strip-components=1 hannctl_mentoring-main/s1-shop-deploy-resilience
cd s1-shop-deploy-resilience
```

> git 이 없다면 방법 B 를 쓰거나 먼저 설치한다: macOS `xcode-select --install` · Ubuntu `sudo apt install -y git` · CentOS/Rocky/Amazon Linux `sudo yum install -y git`
> 멘토에게 zip 파일로 받았다면 압축을 풀고 폴더 안으로 들어가면 된다.

---

## 2단계. 필요한 도구 자동 설치 (한 번만)

```bash
./tools/install-tools.sh
```

필요한 도구를 하나씩 확인해서 **없는 것만 설치하고, 이미 있으면 건너뛴다.** 다시 실행해도 안전하다.
(`./run.sh` 도 실행할 때마다 도구를 확인하고, 빠진 것이 있으면 이 스크립트를 자동으로 부른다.)

| 도구 | 용도 | 없을 때 설치 방법 |
|---|---|---|
| curl · tar · gzip · unzip | 내려받기·압축 해제 | OS 패키지 관리자 (apt / dnf / yum / zypper / brew) |
| **python3** (3.8 이상) | 테스트·채점·비용 계산 | OS 패키지 관리자 → 안 되면(sudo 없음 등) **이 폴더의 `.tools/python` 에 독립 실행형 Python 설치** |
| **AWS CLI v2** | AWS 에 명령 보내기 | 이 폴더의 `.tools/aws-cli` 에 설치 (macOS 도 관리자 암호 불필요) |
| **kubectl · helm** | Kubernetes 조작 | 이 폴더의 `.tools/bin` 에 설치 |
| Docker | **필요 없음** | 이미지 빌드는 AWS CodeBuild 에서 수행 |

```text
🔧 필요한 도구 확인 (linux/amd64) — 이미 있는 것은 건너뜁니다      ← 실행 예시 (Ubuntu, 처음)
  curl         ✔ 있음
  unzip        … 설치 중
  unzip        ✔ 설치됨
  python3      ✔ 있음 (Python 3.12.3)
  AWS CLI      … v2 설치 중 (.tools/aws-cli)
  AWS CLI      ✔ 설치됨 (aws-cli/2.x)
  kubectl      ✔ 설치됨 (v1.35.0)
  helm         ✔ 설치됨 (v3.19.0)
```

| 환경 | 참고 |
|---|---|
| **AWS CloudShell** (가장 쉬움) | AWS 콘솔 우측 상단 `>_` 아이콘 → 1단계부터. 대부분 이미 있어서 kubectl·helm 정도만 설치된다 |
| **macOS** | 관리자 암호 없이 설치된다 (Homebrew 가 있으면 python 은 brew 로 설치) |
| **Ubuntu / Debian · CentOS / Rocky / Amazon Linux** | curl·unzip·python3 이 없으면 `sudo` 암호를 물을 수 있다. sudo 를 못 쓰면 python3 은 폴더 안에 설치되고, curl 이 없으면 관리자에게 설치를 요청한다 |

> 폴더 안(`.tools/`)에 설치된 도구를 터미널에서 직접 쓰려면: `eval "$(./run.sh kubeconfig)"` (PATH 와 KUBECONFIG 를 함께 설정한다. `run.sh` 는 자동으로 사용한다.)

---

## 3단계. AWS 자격 증명 설정 (한 번만)

멘토에게 받은 Access Key 또는 SSO로 설정한다. **CloudShell은 이미 로그인되어 있으므로 건너뛴다.**

```bash
eval "$(./run.sh kubeconfig)"   # (AWS CLI 가 2단계에서 폴더 안에 설치됐다면) aws 명령을 바로 쓰도록 PATH 설정
aws configure                   # Access Key ID / Secret / region: ap-northeast-2 / output: json
aws sts get-caller-identity     # 내 계정이 맞는지 확인
```

> 🔒 Access Key는 **절대 Git에 올리거나 파일에 저장하지 않는다.** 이 키트도 키를 파일에 저장하지 않는다.
> 다른 프로필을 쓰려면 `HANNCTL_PROFILE=프로필명 ./run.sh demo`

---

## 4단계. 사전 점검

```bash
./run.sh doctor
```

도구, 자격 증명, 리전, 권한, VPC 한도를 점검하고 ✔/✘로 보여준다. ✘가 있으면 안내에 따라 해결한다.

---

## 5단계. 실행

```bash
./run.sh demo                       # 전부 자동 (인프라 생성 포함 약 20~45분)
./run.sh demo --before-wait 180     # Before 상태를 3분 동안 관찰한 뒤 자동으로 개선 단계로 넘어감
```

**처음 실행하면 유지 시간을 먼저 묻는다.**

```text
⏰ 이 실습 환경을 몇 시간 유지할까요? (만든 시각부터, 지나면 자동 삭제)
   1~24 시간, 시간당 약 $0.2x — 그냥 Enter 면 6시간:
```

- 그냥 Enter 를 누르면 **6시간**이다. 묻지 않고 바로 정하려면 `./run.sh demo --hours 8` 처럼 쓴다.
- 유지 시간은 **AWS 인프라를 처음 만든 시각부터** 센다. 시간이 지나면 FinOps 자동 정리(janitor)가 10분 안에 전부 삭제한다.
- 실습 중에 바꾸려면 `./run.sh lifetime N` 을 쓴다. 이때도 **처음 만든 시각부터 N시간**이 된다.

| 예시 (처음 6시간으로 시작) | 명령 | 결과 |
|---|---|---|
| 4시간 지났는데 더 쓰고 싶다 | `./run.sh lifetime 9` | 생성 후 9시간까지 → **지금부터 5시간** 남음 |
| 일찍 끝내고 싶다 | `./run.sh lifetime 5` | 생성 후 5시간까지 → 지금부터 1시간 남음 |
| 이미 지난 시간으로 줄였다 | `./run.sh lifetime 3` (4시간 지난 상태) | 10분 안에 자동 삭제 |

- 진행 중에는 **다른 터미널에서 `./run.sh watch`** 를 켜 두면 변화를 실시간으로 볼 수 있다.
- 끝나면 `evidence/latest/REPORT.html`(점수, 전후 비교, 타임라인, 비용)이 열린다. 자동으로 열리지 않으면 파일을 브라우저로 직접 연다.
- 무엇이 왜 일어나는지는 [`README.md`](README.md)의 **"4. 자동 진행 순서"** 를 보면서 따라간다.

| 자주 쓰는 명령 | 설명 |
|---|---|
| `./run.sh status` | 지금 AWS·EKS에 무엇이 있는지, 자동 삭제 시각 |
| `./run.sh before` / `./run.sh after` | Before 또는 After만 따로 실행 |
| `./run.sh test after` | 테스트만 다시 실행 |
| `./run.sh score` | 최근 결과 다시 채점 |
| `./run.sh cost` | 이번 달 hannctl 누적 예상 비용 |
| `eval "$(./run.sh kubeconfig)"` | 직접 `kubectl` 을 쓰고 싶을 때 (이 시나리오 전용 설정) |
| `./run.sh lifetime 9` | 유지 시간을 "생성 후 9시간"으로 변경 (`extend` 도 같은 명령) |

---

## 6단계. 끝나면 반드시 삭제

```bash
./run.sh down          # 이 시나리오가 만든 AWS 리소스 전부 삭제 (약 10분)
```

> 💸 잊어버려도 **정한 유지 시간(기본 6시간)이 지나면 자동 삭제**된다. 그래도 실습이 끝나면 직접 지우는 습관을 들이자.
> 비용은 시나리오 1개 실행 시 약 $0.2~0.25/시간(≈300~350원)이다. 각 시나리오 README 의 "비용" 항목에 실측값이 있다.

---

## 7단계(선택). 자동 삭제·비용 상한을 끄고 싶다면

이 키트에는 비용 폭주를 막는 장치가 두 가지 있다. 처음 `./run.sh demo` 를 실행하면 계정에 **FinOps Guard 스택(`hannctl-finops-guard`)** 이 자동으로 만들어지고, 여기에 들어 있는 janitor(Lambda)가 10분마다 점검한다.

| 장치 | 동작 | 끄는 방법 | 다시 켜기 |
|---|---|---|---|
| **유지 시간** (시나리오별) | 생성 후 N시간이 지나면 그 시나리오 스택 삭제 | `./run.sh lifetime 0` (0 = 무제한) | `./run.sh lifetime 6` |
| **월 비용 상한** (계정 전체 hannctl) | 이번 달 hannctl 누적 예상 비용이 $20(≈3만원)에 닿으면 hannctl 스택 전부 삭제 | `./run.sh cap 0` (0 = 끄기) | `./run.sh cap 20` |
| **janitor 전체** | 위 두 가지 점검을 모두 수행 | `aws events disable-rule --name hannctl-janitor-schedule` | `aws events enable-rule --name hannctl-janitor-schedule` |

어떤 리소스가 무엇을 하는지:

| 리소스 (모두 `hannctl-finops-guard` 스택 안) | 역할 |
|---|---|
| Lambda `hannctl-janitor` + EventBridge 규칙 `hannctl-janitor-schedule` | 10분마다 유지 시간·월 상한을 점검하고 초과한 hannctl 스택을 삭제 |
| AWS Budgets `hannctl-monthly-budget` + SNS `hannctl-finops-alerts` | 실제 청구액 기준 알림 (삭제는 하지 않음) |
| IAM 역할 `hannctl-cfn-exec-role` | CloudFormation 이 시나리오 리소스를 만들고 지울 때 쓰는 역할 |

> ⚠️ 끄면 **자동으로 지워 주지 않는다.** 끝나면 반드시 `./run.sh down` 을 실행한다. (24시간 방치 시 시나리오 1개당 약 $5~6)
> ⚠️ 시나리오 스택이 남아 있는 동안에는 `hannctl-finops-guard` 스택이나 `hannctl-cfn-exec-role` 역할을 **콘솔에서 직접 지우지 않는다.** 실행 역할이 없으면 시나리오 스택을 삭제할 수 없게 된다.
> 모든 실습을 마치고 Guard 까지 정리하려면 `./run.sh down-all` 을 실행한다. 이 명령은 다른 hannctl 시나리오 스택이 남아 있으면 Guard 를 지우지 않는다.

---

## 문제가 생기면

| 증상 | 해결 |
|---|---|
| `AWS 자격 증명 확인 실패` | `aws configure` 다시 설정, `aws sts get-caller-identity` 확인 |
| 실습 도중 환경이 사라졌다 | 유지 시간이 지나 자동 삭제된 것이다 → `./run.sh demo` 로 다시 만들고, 다음에는 `--hours` 를 넉넉히 준다 |
| kubectl이 `Unauthorized`/타임아웃 | 내 공인 IP가 바뀌었을 수 있다 → `./run.sh up`(EKS API 허용 IP 갱신) |
| `VPC 한도` 오류 | 같은 계정에 VPC가 5개다. 다른 실습을 `down` 하거나 멘토에게 문의 |
| 스택 배포 실패 | 화면의 `✘` 줄(실패 리소스와 이유)을 확인 → `./run.sh down` 후 다시 `./run.sh demo` |
| 점수가 88점 미만 | `evidence/latest/REPORT.html`에서 ❌ 항목 확인 → `./run.sh after`로 재시도 |
