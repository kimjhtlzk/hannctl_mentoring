# 처음 시작하기 — s4-eks-audit-hardening

이 폴더 하나만 있으면 시나리오 전체(AWS 인프라 생성 → 문제 재현 → 자동 개선 → 검증 → 채점 → 삭제)를 실행할 수 있다.
아래 순서대로 한 번만 준비하면, 이후에는 `./run.sh demo` 명령 하나로 끝난다.

---

## 1단계. 이 시나리오 폴더만 내려받기

**방법 A — git (권장, 이 폴더만 받기)**

```bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/kimjhtlzk/hannctl_mentoring.git
cd hannctl_mentoring
git sparse-checkout set s4-eks-audit-hardening
cd s4-eks-audit-hardening
```

**방법 B — git 없이 압축 파일로 받기**

```bash
curl -L https://github.com/kimjhtlzk/hannctl_mentoring/archive/refs/heads/main.tar.gz | tar xz --strip-components=1 hannctl_mentoring-main/s4-eks-audit-hardening
cd s4-eks-audit-hardening
```

> 강사에게 zip 파일로 받았다면 압축을 풀고 폴더 안으로 들어가면 된다.

---

## 2단계. 필요한 도구 준비 (한 번만)

| 도구 | 용도 | 설치 |
|---|---|---|
| **AWS CLI v2** | AWS에 명령을 보내는 도구 | 아래 OS별 안내 (Linux는 자동 설치 가능) |
| **python3** | 테스트·채점 스크립트 | 대부분 기본 설치되어 있음 |
| **kubectl, helm** | Kubernetes 조작 | **자동 설치됨** (`tools/install-tools.sh`, 폴더 안 `.tools/`에 설치, sudo 불필요) |
| Docker | **필요 없음** | 이미지 빌드는 AWS CodeBuild에서 수행 |

| 환경 | 준비 명령 |
|---|---|
| **AWS CloudShell** (가장 쉬움) | 준비할 것 없음. AWS 콘솔 우측 상단 `>_` 아이콘 → 1단계부터 진행 |
| **macOS** | `brew install awscli python3` |
| **Ubuntu / Debian** | `sudo apt update && sudo apt install -y python3 curl unzip git` → AWS CLI는 `./tools/install-tools.sh`가 자동 설치 |
| **CentOS / Rocky / Amazon Linux** | `sudo yum install -y python3 curl unzip git` → AWS CLI는 `./tools/install-tools.sh`가 자동 설치 |

```bash
./tools/install-tools.sh      # kubectl/helm(+Linux 에서 AWS CLI) 설치. 이미 있으면 건너뜀
```

---

## 3단계. AWS 자격 증명 설정 (한 번만)

강사에게 받은 Access Key 또는 SSO로 설정한다. **CloudShell은 이미 로그인되어 있으므로 건너뛴다.**

```bash
aws configure                 # Access Key ID / Secret / region: ap-northeast-2 / output: json
aws sts get-caller-identity   # 내 계정이 맞는지 확인
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
./run.sh demo                       # 전부 자동 (첫 실행 약 25~35분: 인프라 생성 15분 포함)
./run.sh demo --before-wait 180     # Before 상태를 3분 동안 관찰한 뒤 자동으로 개선 단계로 넘어감
```

- 진행 중에는 **다른 터미널에서 `./run.sh watch`** 를 켜 두면 변화를 실시간으로 볼 수 있다.
- 끝나면 `evidence/latest/REPORT.html`(점수, 전후 비교, 타임라인)이 열린다. 자동으로 열리지 않으면 파일을 브라우저로 직접 연다.
- 무엇이 왜 일어나는지는 [`README.md`](README.md)의 **"4. 자동 진행 순서"** 를 보면서 따라간다.

| 자주 쓰는 명령 | 설명 |
|---|---|
| `./run.sh status` | 지금 AWS·EKS에 무엇이 있는지 |
| `./run.sh before` / `./run.sh after` | Before 또는 After만 따로 실행 |
| `./run.sh test after` | 테스트만 다시 실행 |
| `./run.sh score` | 최근 결과 다시 채점 |
| `eval "$(./run.sh kubeconfig)"` | 직접 `kubectl` 을 쓰고 싶을 때 (이 시나리오 전용 설정) |
| `./run.sh extend 2` | 자동 삭제 시간을 지금부터 2시간 뒤로 연장 |

---

## 6단계. 끝나면 반드시 삭제

```bash
./run.sh down          # 이 시나리오가 만든 AWS 리소스 전부 삭제 (10~15분)
```

> 💸 잊어버려도 **3시간 뒤 자동 삭제**된다(최대 12시간 안전망). 그래도 실습이 끝나면 직접 지우는 습관을 들이자.
> 비용은 시나리오 1개 실행 시 약 $0.3~0.4/시간이다.

---

## 문제가 생기면

| 증상 | 해결 |
|---|---|
| `AWS 자격 증명 확인 실패` | `aws configure` 다시 설정, `aws sts get-caller-identity` 확인 |
| kubectl이 `Unauthorized`/타임아웃 | 내 공인 IP가 바뀌었을 수 있다 → `./run.sh up`(EKS API 허용 IP 갱신) |
| `VPC 한도` 오류 | 같은 계정에 VPC가 5개다. 다른 실습을 `down` 하거나 강사에게 문의 |
| 스택 배포 실패 | 화면의 `✘` 줄(실패 리소스와 이유)을 확인 → `./run.sh down` 후 다시 `./run.sh demo` |
| 점수가 88점 미만 | `evidence/latest/REPORT.html`에서 ❌ 항목 확인 → `./run.sh after`로 재시도 |
