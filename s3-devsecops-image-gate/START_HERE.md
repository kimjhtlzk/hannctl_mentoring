# 처음 시작하기 — s3-devsecops-image-gate

아래 순서대로 한 번만 준비하면, 이후에는 `./run.sh demo` 명령 하나로 AWS 인프라 생성 → 문제 재현 → 자동 개선 → 검증 → 채점까지 진행되고, `./run.sh down` 으로 삭제된다.

---

## 1단계. 시나리오 내려받기

**방법 A — git (이 시나리오만 받기)**

```bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/kimjhtlzk/hannctl_mentoring.git
cd hannctl_mentoring
git sparse-checkout set s3-devsecops-image-gate
cd s3-devsecops-image-gate
```

**방법 B — git 없이 압축 파일로 받기** (curl, tar 만 있으면 된다)

```bash
curl -L https://github.com/kimjhtlzk/hannctl_mentoring/archive/refs/heads/main.tar.gz | tar xz --strip-components=1 hannctl_mentoring-main/s3-devsecops-image-gate
cd s3-devsecops-image-gate
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
| **AWS CLI v2** (2.32 이상) | AWS 에 명령 보내기, 브라우저 로그인(`aws login`) | 없거나 2.32 보다 오래됐으면 이 폴더의 `.tools/aws-cli` 에 설치 (기존 것은 그대로, macOS 도 관리자 암호 불필요) |
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

> 폴더 안(`.tools/`)에 설치된 도구를 터미널에서 직접 쓰려면: `eval "$(./run.sh kubeconfig)"` (PATH·KUBECONFIG·AWS 프로필을 함께 설정한다. `run.sh` 는 자동으로 사용한다.)

---

## 3단계. AWS 로그인 (자동 — 따로 할 일 없음)

**내 AWS 계정**에 관리자 권한으로 콘솔 로그인만 할 수 있으면 된다. Access Key 를 만들거나 `aws configure` 를 할 필요가 없다.
처음 `./run.sh doctor`(또는 `demo`)를 실행하면 아래 과정이 자동으로 진행된다.

```text
① 로그인       CloudShell → 이미 로그인됨, 그대로 사용
               내 PC     → 브라우저가 열리고 AWS 콘솔에 로그인 → CLI 가 임시 자격 증명을 받음 (aws login)
② 작업용 역할   hannctl-identity 스택이 IAM 역할 hannctl-operator-role 을 만듦 (처음 한 번, 약 1분, 비용 0원)
③ 역할 전환     이후 run.sh 의 모든 작업은 hannctl-operator-role 의 임시 자격 증명으로 실행
```

| 처음 실행할 때 보이는 것 | 할 일 |
|---|---|
| 브라우저가 열리고 AWS 로그인 화면이 나온다 | 내 AWS 계정으로 로그인 → "허용" → 터미널로 돌아오면 자동으로 이어진다 |
| (서버·SSH 처럼 브라우저가 없는 곳) 주소가 출력되고 코드를 묻는다 | 주소를 PC/휴대폰 브라우저에서 열어 로그인 → 화면의 코드를 터미널에 붙여 넣기 |
| `root 사용자로 로그인되어 있습니다` + hannctl-admin 로그인 정보 | 아래 "root 로 로그인했다면" 참고 |

자동으로 만들어지는 것 (모두 이름에 **hannctl** 이 붙는다):

| 이름 | 종류 | 역할 |
|---|---|---|
| `hannctl-login` | 내 PC 의 AWS CLI 프로필 | 콘솔 로그인으로 받은 임시 자격 증명 (자동 갱신, 최대 12시간) |
| `hannctl` | 내 PC 의 AWS CLI 프로필 | `hannctl-login` → `hannctl-operator-role` 로 전환하는 설정 (run.sh 가 사용) |
| `hannctl-operator-role` | IAM 역할 (`hannctl-identity` 스택) | 실제 작업 권한. IAM 은 이름이 `hannctl-` 인 것만 다룰 수 있고, 자기 권한은 스스로 늘릴 수 없다 |
| `hannctl-admin` | IAM 사용자 (root 로 로그인한 경우에만) | 콘솔 로그인 전용. Access Key 없음. `hannctl-operator-role` 로 전환하는 것만 가능 |

> **root 로 로그인했다면:** root 는 IAM 역할로 전환할 수 없고 일상 작업에 쓰면 위험하다. 그래서 키트가 콘솔 사용자 `hannctl-admin` 을 만들고 로그인 주소·임시 비밀번호를 **한 번만** 보여 준다.
> 브라우저에서 root 를 로그아웃하고 `hannctl-admin` 으로 다시 로그인하면 이어서 진행된다(첫 로그인 때 새 비밀번호를 정한다). CloudShell 이라면 `hannctl-admin` 으로 콘솔에 다시 로그인한 뒤 CloudShell 을 열고 같은 명령을 다시 실행한다.

> 🔒 이 키트는 Access Key(장기 키)를 만들거나 파일에 저장하지 않는다. 다시 로그인하려면 `./run.sh login`, 이 PC 의 로그인을 지우려면 `./run.sh logout`.
> 이미 쓰고 있는 AWS CLI 프로필로 로그인을 대신하려면 `HANNCTL_SOURCE_PROFILE=프로필명 ./run.sh demo` (그 프로필에서도 `hannctl-operator-role` 로 전환해서 작업한다).

---

## 4단계. 사전 점검

```bash
./run.sh doctor
```

도구, 로그인, 작업용 역할, 리전, VPC 한도를 점검하고 ✔/✘로 보여준다. 도구가 없으면 설치하고, 로그인이 안 되어 있으면 로그인부터 진행한다. ✘가 있으면 안내에 따라 해결한다.

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
> 작업용 역할(`hannctl-identity` 스택, 비용 0원)까지 지우려면 `./run.sh down-all --identity`. (hannctl-admin 으로 로그인한 경우에는 root 로 CloudShell 에서 `aws cloudformation delete-stack --stack-name hannctl-identity`)

---

## 문제가 생기면

| 증상 | 해결 |
|---|---|
| `AWS 로그인이 필요합니다` / 로그인 실패 | `./run.sh login` 으로 다시 로그인 (임시 자격 증명은 최대 12시간) |
| `신원 스택 배포 실패` | 로그인한 사용자에게 관리자 권한(IAM 역할 생성)이 있어야 한다. 계정 소유자(root)로 로그인하면 키트가 `hannctl-admin` 을 만들어 준다 |
| 실습 도중 환경이 사라졌다 | 유지 시간이 지나 자동 삭제된 것이다 → `./run.sh demo` 로 다시 만들고, 다음에는 `--hours` 를 넉넉히 준다 |
| kubectl이 `Unauthorized`/타임아웃 | 내 공인 IP가 바뀌었을 수 있다 → `./run.sh up`(EKS API 허용 IP 갱신) |
| `VPC 한도` 오류 | 같은 계정에 VPC가 5개다. 다른 실습을 `down` 하거나 Service Quotas 에서 VPC 한도 증가 요청 |
| 스택 배포 실패 | 화면의 `✘` 줄(실패 리소스와 이유)을 확인 → `./run.sh down` 후 다시 `./run.sh demo` |
| 점수가 88점 미만 | `evidence/latest/REPORT.html`에서 ❌ 항목 확인 → `./run.sh after`로 재시도 |
