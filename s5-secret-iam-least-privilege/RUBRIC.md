# 평가표 — 시나리오 5 · 내부 API 인증정보 보호와 최소 권한

- 만점 **100점**, 목표 **88점 이상**
- `./run.sh demo`(또는 `after`) 가 끝나면 **자동 채점**된다. 수동 재채점: `./run.sh score`
- 각 항목은 하나 이상의 자동 테스트(check)로 판정한다. 항목 점수 = 배점 × (통과 테스트 수 / 테스트 수)
- `before:` 테스트는 "통제 전 위험이 실제로 재현되었는가", `after:` 테스트는 "통제 후 기대 결과가 나왔는가"를 본다.

| ID | 영역 | 평가 항목 | 배점 | 판정 근거(자동 테스트) | 합격 기준 |
|---|---|---|---:|---|---|
| S5-01 | AWS 인프라 | EKS ACTIVE + Pod Identity Agent + SA↔IAM Role 연결 2개 | 8 | `after:cluster_ready`<br>`after:pod_identity_agent`<br>`after:pod_identity_assoc` | 모든 테스트가 기대값과 일치 |
| S5-02 | FinOps·식별자 | 모든 AWS 리소스 hannctl 식별 + 유지시간 자동삭제/월 상한 보호 | 7 | `after:tag_compliance`<br>`after:finops_guard` | 모든 테스트가 기대값과 일치 |
| S5-03 | 문제 재현(Before) | 공용 정적 키로 비인가 Pod 까지 모든 Secret 조회, 개발자 과다 권한 재현 | 10 | `before:static_creds`<br>`before:intruder_restricted`<br>`before:api_restricted`<br>`before:dev_get_secrets` | 모든 테스트가 기대값과 일치 |
| S5-04 | 정적 자격증명 제거 | Access Key·K8s Secret·참조 0개, 업무 API 는 Pod Identity 임시 자격증명 사용 | 12 | `after:static_creds`<br>`after:api_identity` | 모든 테스트가 기대값과 일치 |
| S5-05 | Secret 최소 권한 | 업무 API 는 allowed 만 읽고 restricted 는 AccessDenied | 13 | `after:api_allowed`<br>`after:api_restricted` | 모든 테스트가 기대값과 일치 |
| S5-06 | 비인가 워크로드 차단 | 비인가 Pod 는 모든 Secret AccessDenied, 노드 IMDS 우회 불가 | 15 | `after:intruder_allowed`<br>`after:intruder_restricted`<br>`after:intruder_identity`<br>`after:imds_bypass` | 모든 테스트가 기대값과 일치 |
| S5-07 | 사람 권한(RBAC) | 개발자 읽기 전용·운영자 워크로드 관리, Secret 조회·권한 상승·타 NS 거부 | 12 | `after:dev_get_pods`<br>`after:dev_delete_deploy`<br>`after:dev_get_secrets`<br>`after:dev_cluster_admin`<br>`after:ops_patch_deploy`<br>`after:ops_get_secrets`<br>`after:ops_other_ns` | 모든 테스트가 기대값과 일치 |
| S5-08 | Pod 보안 | privileged / hostPath / root Pod 생성 거부 (PSA + Kyverno) | 8 | `after:privileged`<br>`after:hostpath`<br>`after:root` | 모든 테스트가 기대값과 일치 |
| S5-09 | 네트워크 | 포털→업무 API 정상, 비인가 Pod→업무 API 차단 | 7 | `after:web_to_api`<br>`after:intruder_to_api` | 모든 테스트가 기대값과 일치 |
| S5-10 | 감사 증적 | K8s 거부 요청(EKS audit)과 Secret 접근 신원(CloudTrail)을 각각 확인 | 8 | `after:audit_forbidden`<br>`after:cloudtrail_secret_access` | 모든 테스트가 기대값과 일치 |

## 발표 평가(사람이 채점, 참고용 — 자동 점수와 별도)

| 관점 | 확인 질문 |
|---|---|
| 문제 정의 | 어떤 기업의 어떤 사고/운영 문제를 해결했는지 1분 안에 설명하는가? |
| 설계 이유 | 왜 이 통제(기술)를 이 위치에 배치했는지 계층(IAM/RBAC/Admission/Network/Audit)으로 설명하는가? |
| 증거 | Before/After 를 같은 테스트로 비교하고 실측값만 사용했는가? |
| 정상 유지 | 차단만이 아니라 정상 서비스가 유지됨을 함께 보였는가? |
| 한계 | 구현하지 않은 것·과장하면 안 되는 것을 구분해 말하는가? |
