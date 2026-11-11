# 평가표 — 시나리오 3 · 취약 이미지 배포 차단 DevSecOps

- 만점 **100점**, 목표 **88점 이상**
- `./run.sh demo`(또는 `after`) 가 끝나면 **자동 채점**된다. 수동 재채점: `./run.sh score`
- 각 항목은 하나 이상의 자동 테스트(check)로 판정한다. 항목 점수 = 배점 × (통과 테스트 수 / 테스트 수)
- `before:` 테스트는 "통제 전 위험이 실제로 재현되었는가", `after:` 테스트는 "통제 후 기대 결과가 나왔는가"를 본다.

| ID | 영역 | 평가 항목 | 배점 | 판정 근거(자동 테스트) | 합격 기준 |
|---|---|---|---:|---|---|
| S3-01 | AWS 인프라 | EKS ACTIVE + ECR(신뢰 레지스트리) + CodeBuild CI 준비 | 8 | `after:cluster_ready`<br>`after:ecr_ci_ready` | 모든 테스트가 기대값과 일치 |
| S3-02 | FinOps·식별자 | 모든 AWS 리소스 hannctl 식별 + 유지시간 자동삭제·월 상한 보호 | 7 | `after:tag_compliance`<br>`after:finops_guard` | 모든 테스트가 기대값과 일치 |
| S3-03 | 문제 재현(Before) | 게이트 없이 취약 이미지가 Push·배포되고, 외부 이미지·특권 Pod 도 허용됨을 재현 | 10 | `before:ci_vuln_build`<br>`before:vuln_deployed`<br>`before:untrusted_registry`<br>`before:privileged` | 모든 테스트가 기대값과 일치 |
| S3-04 | CI 보안 게이트 | Trivy HIGH/CRITICAL 위반 이미지는 CI 실패 → ECR 에 Push 되지 않음 | 20 | `after:ci_vuln_build`<br>`after:gate_reason`<br>`after:vuln_in_ecr` | 모든 테스트가 기대값과 일치 |
| S3-05 | 정상 배포 유지 | 검증된 이미지는 CI 통과 → ECR → EKS 배포, /version 변경, 서비스 정상 | 15 | `after:ci_secure_build`<br>`after:version_changed`<br>`after:service_health` | 모든 테스트가 기대값과 일치 |
| S3-06 | 배포 추적성 | 커밋↔CI 빌드↔이미지 digest↔Deployment 연결, 취약 이미지 운영 제거 | 8 | `after:traceability`<br>`after:vuln_deployed` | 모든 테스트가 기대값과 일치 |
| S3-07 | 신뢰 레지스트리 | 외부 레지스트리 이미지 거부, 승인 ECR 이미지는 허용 (Kyverno) | 12 | `after:untrusted_registry`<br>`after:trusted_registry` | 모든 테스트가 기대값과 일치 |
| S3-08 | Pod 보안 | privileged / hostPath / root Pod 생성 거부 (PSA + Kyverno) | 12 | `after:privileged`<br>`after:hostpath`<br>`after:root` | 모든 테스트가 기대값과 일치 |
| S3-09 | 감사 증적 | Trivy 결과·게이트 차단 로그가 증적으로 보관됨 | 8 | `after:ci_evidence` | 모든 테스트가 기대값과 일치 |

## 발표 평가(사람이 채점, 참고용 — 자동 점수와 별도)

| 관점 | 확인 질문 |
|---|---|
| 문제 정의 | 어떤 기업의 어떤 사고/운영 문제를 해결했는지 1분 안에 설명하는가? |
| 설계 이유 | 왜 이 통제(기술)를 이 위치에 배치했는지 계층(IAM/RBAC/Admission/Network/Audit)으로 설명하는가? |
| 증거 | Before/After 를 같은 테스트로 비교하고 실측값만 사용했는가? |
| 정상 유지 | 차단만이 아니라 정상 서비스가 유지됨을 함께 보였는가? |
| 한계 | 구현하지 않은 것·과장하면 안 되는 것을 구분해 말하는가? |
