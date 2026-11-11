# 평가표 — 시나리오 4 · EKS 보안 진단·하드닝·감사 증적 자동화

- 만점 **100점**, 목표 **88점 이상**
- `./run.sh demo`(또는 `after`) 가 끝나면 **자동 채점**된다. 수동 재채점: `./run.sh score`
- 각 항목은 하나 이상의 자동 테스트(check)로 판정한다. 항목 점수 = 배점 × (통과 테스트 수 / 테스트 수)
- `before:` 테스트는 "통제 전 위험이 실제로 재현되었는가", `after:` 테스트는 "통제 후 기대 결과가 나왔는가"를 본다.

| ID | 영역 | 평가 항목 | 배점 | 판정 근거(자동 테스트) | 합격 기준 |
|---|---|---|---:|---|---|
| S4-01 | AWS 인프라·FinOps | EKS ACTIVE + 모든 리소스 hannctl 식별 + 유지시간 자동삭제/월 상한 보호 | 8 | `after:cluster_ready`<br>`after:tag_compliance`<br>`after:finops_guard` | 모든 테스트가 기대값과 일치 |
| S4-02 | 초기 진단(Before) | 통제 전 문제를 진단·재현 (자체점검 지적, 감사 흔적 없음, 과다 권한, 위험 Pod 허용) | 10 | `before:selfcheck`<br>`before:audit_events`<br>`before:dev_get_secrets`<br>`before:privileged` | 모든 테스트가 기대값과 일치 |
| S4-03 | CIS 점검(kube-bench) | kube-bench 자동 점검을 전후 동일 조건으로 실행 | 7 | `before:kb_run`<br>`after:kb_run` | 모든 테스트가 기대값과 일치 |
| S4-04 | CIS 점검(kube-bench) | 개선 가능한 CIS 항목(4.1.5 default ServiceAccount 미사용)이 FAIL→PASS | 5 | `before:kb_4_1_5`<br>`after:kb_4_1_5` | 모든 테스트가 기대값과 일치 |
| S4-05 | 자체 점검 | 자체 점검 DEMO-01~12 전 항목 통과 | 15 | `after:selfcheck` | 모든 테스트가 기대값과 일치 |
| S4-06 | 감사 증적 | EKS 감사 로그 활성화 + 거부 이벤트를 CloudWatch 에서 조회 | 15 | `after:audit_log_enabled`<br>`after:audit_events` | 모든 테스트가 기대값과 일치 |
| S4-07 | RBAC 최소 권한 | 개발자 Secret 조회·배포 삭제·권한 상승, 앱 SA 전체 Secret 조회 거부 + 조회 권한 유지 | 15 | `after:dev_get_secrets`<br>`after:dev_delete_deploy`<br>`after:dev_create_crb`<br>`after:app_sa_secrets`<br>`after:dev_list_pods` | 모든 테스트가 기대값과 일치 |
| S4-08 | Pod 보안 | privileged / hostPath / root Pod 생성 거부 (PSA + Kyverno) | 10 | `after:privileged`<br>`after:hostpath`<br>`after:root` | 모든 테스트가 기대값과 일치 |
| S4-09 | 네트워크·가용성 | 다른 팀 → 앱 접근 차단 + 정상 서비스(web→api) 유지 | 7 | `after:cross_ns`<br>`after:app_health` | 모든 테스트가 기대값과 일치 |
| S4-10 | 점검 자동화 | 정기 점검 CronJob 등록 + 진단 A·B 자동 수행(10분 이내) | 8 | `after:cronjob`<br>`after:check_time` | 모든 테스트가 기대값과 일치 |

## 발표 평가(사람이 채점, 참고용 — 자동 점수와 별도)

| 관점 | 확인 질문 |
|---|---|
| 문제 정의 | 어떤 기업의 어떤 사고/운영 문제를 해결했는지 1분 안에 설명하는가? |
| 설계 이유 | 왜 이 통제(기술)를 이 위치에 배치했는지 계층(IAM/RBAC/Admission/Network/Audit)으로 설명하는가? |
| 증거 | Before/After 를 같은 테스트로 비교하고 실측값만 사용했는가? |
| 정상 유지 | 차단만이 아니라 정상 서비스가 유지됨을 함께 보였는가? |
| 한계 | 구현하지 않은 것·과장하면 안 되는 것을 구분해 말하는가? |
