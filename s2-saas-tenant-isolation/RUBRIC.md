# 평가표 — 시나리오 2 · B2B SaaS 고객사별 보안 격리

- 만점 **100점**, 목표 **88점 이상**
- `./run.sh demo`(또는 `after`) 가 끝나면 **자동 채점**된다. 수동 재채점: `./run.sh score`
- 각 항목은 하나 이상의 자동 테스트(check)로 판정한다. 항목 점수 = 배점 × (통과 테스트 수 / 테스트 수)
- `before:` 테스트는 "통제 전 위험이 실제로 재현되었는가", `after:` 테스트는 "통제 후 기대 결과가 나왔는가"를 본다.

| ID | 영역 | 평가 항목 | 배점 | 판정 근거(자동 테스트) | 합격 기준 |
|---|---|---|---:|---|---|
| S2-01 | AWS 인프라 | EKS 클러스터 ACTIVE + VPC CNI NetworkPolicy 엔진 활성화 | 8 | `after:cluster_ready`<br>`after:netpol_engine` | 모든 테스트가 기대값과 일치 |
| S2-02 | FinOps·식별자 | 모든 AWS 리소스 hannctl 식별 + 유지시간 자동삭제/월 상한 보호 | 7 | `after:tag_compliance`<br>`after:finops_guard` | 모든 테스트가 기대값과 일치 |
| S2-03 | 문제 재현(Before) | 통제 전 교차 통신·과다 권한·위험 Pod 가 실제로 가능함을 재현 | 10 | `before:a_to_b`<br>`before:b_to_a`<br>`before:rbac_a_list_pods_b`<br>`before:privileged` | 모든 테스트가 기대값과 일치 |
| S2-04 | 네트워크 격리 | 고객사 간 Pod 통신 차단 (A↔B 양방향 + 측면 이동) | 20 | `after:a_to_b`<br>`after:b_to_a`<br>`after:a_api_to_b` | 모든 테스트가 기대값과 일치 |
| S2-05 | 정상 서비스 유지 | 같은 테넌트 통신 + DNS 는 정책 적용 후에도 정상 | 15 | `after:a_to_a`<br>`after:b_to_b`<br>`after:dns` | 모든 테스트가 기대값과 일치 |
| S2-06 | 권한 격리(RBAC) | 다른 테넌트 조회/변경 및 Secret 조회 거부 | 15 | `after:rbac_a_list_pods_b`<br>`after:rbac_a_patch_deploy_b`<br>`after:rbac_b_list_pods_a`<br>`after:rbac_a_get_secrets_a` | 모든 테스트가 기대값과 일치 |
| S2-07 | 권한 격리(RBAC) | 자기 테넌트 운영 권한(조회·재시작)은 유지 | 5 | `after:rbac_a_list_pods_a`<br>`after:rbac_a_patch_deploy_a` | 모든 테스트가 기대값과 일치 |
| S2-08 | Pod 보안 | privileged / hostPath / root Pod 생성 거부 + PSA 누락 시에도 Kyverno 가 차단(이중 방어) | 12 | `after:privileged`<br>`after:hostpath`<br>`after:root`<br>`after:kyverno_layer` | 모든 테스트가 기대값과 일치 |
| S2-09 | 감사 증적 | 거부된 접근이 EKS 감사 로그(CloudWatch)에 기록됨 | 8 | `after:audit_forbidden` | 모든 테스트가 기대값과 일치 |

## 발표 평가(사람이 채점, 참고용 — 자동 점수와 별도)

| 관점 | 확인 질문 |
|---|---|
| 문제 정의 | 어떤 기업의 어떤 사고/운영 문제를 해결했는지 1분 안에 설명하는가? |
| 설계 이유 | 왜 이 통제(기술)를 이 위치에 배치했는지 계층(IAM/RBAC/Admission/Network/Audit)으로 설명하는가? |
| 증거 | Before/After 를 같은 테스트로 비교하고 실측값만 사용했는가? |
| 정상 유지 | 차단만이 아니라 정상 서비스가 유지됨을 함께 보였는가? |
| 한계 | 구현하지 않은 것·과장하면 안 되는 것을 구분해 말하는가? |
