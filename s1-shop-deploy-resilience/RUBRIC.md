# 평가표 — 시나리오 1 · 쇼핑몰 안전한 배포·장애 대응 (ShopNow)

- 만점 **100점**, 목표 **88점 이상**
- `./run.sh demo`(또는 `after`) 가 끝나면 **자동 채점**된다. 수동 재채점: `./run.sh score`
- 각 항목은 하나 이상의 자동 테스트(check)로 판정한다. 항목 점수 = 배점 × (통과 테스트 수 / 테스트 수)
- `before:` 테스트는 "통제 전 위험이 실제로 재현되었는가", `after:` 테스트는 "통제 후 기대 결과가 나왔는가"를 본다.

| ID | 영역 | 평가 항목 | 배점 | 판정 근거(자동 테스트) | 합격 기준 |
|---|---|---|---:|---|---|
| S1-01 | AWS 인프라 | EKS 클러스터 ACTIVE (VPC·노드·ECR·CodeBuild 포함 스택 정상) | 5 | `after:cluster_ready` | 모든 테스트가 기대값과 일치 |
| S1-02 | FinOps·식별자 | 모든 AWS 리소스 hannctl 식별 + 유지 시간 자동삭제/월 상한 보호 | 7 | `after:tag_compliance`<br>`after:finops_guard` | 모든 테스트가 기대값과 일치 |
| S1-03 | 문제 재현(Before) | 고정 Pod·버그 배포 장애·취약 이미지 유입·위험 Pod 허용이 실제로 재현됨 | 10 | `before:pod_scaling`<br>`before:bad_deploy`<br>`before:ci_vuln_image`<br>`before:privileged` | 모든 테스트가 기대값과 일치 |
| S1-04 | 운영: 자동 확장 | 부하 증가 시 HPA 가 Pod 를 2개 초과로 확장 | 12 | `after:pod_scaling` | 모든 테스트가 기대값과 일치 |
| S1-05 | 운영: 노드 확장 | Pending Pod 발생 시 Cluster Autoscaler 가 노드 추가 | 8 | `after:node_scaling` | 모든 테스트가 기대값과 일치 |
| S1-06 | 정상 서비스 유지 | 부하 중에도 요청 성공률 99% 이상 | 8 | `after:load_success` | 모든 테스트가 기대값과 일치 |
| S1-07 | 장애 대응: 안전한 배포 | 버그 버전 배포 중에도 성공률 95% 이상 (Readiness + maxUnavailable 0) | 12 | `after:bad_deploy` | 모든 테스트가 기대값과 일치 |
| S1-08 | 장애 대응: 복구 | 롤백으로 정상 버전(v1) 복구 + 복구 시간 측정 | 8 | `after:rollback` | 모든 테스트가 기대값과 일치 |
| S1-09 | 공급망 보안 | Trivy 게이트: 취약 이미지 ECR 유입 차단, 정상 이미지는 통과 | 15 | `after:ci_vuln_image`<br>`after:ci_secure_image` | 모든 테스트가 기대값과 일치 |
| S1-10 | Pod 보안 | privileged / hostPath / root Pod 생성 거부 (PSA + Kyverno) | 10 | `after:privileged`<br>`after:hostpath`<br>`after:root` | 모든 테스트가 기대값과 일치 |
| S1-11 | 관측 | Prometheus 가 HPA/Pod 지표를 실제 수집 (Grafana 로 시각화) | 5 | `after:monitoring` | 모든 테스트가 기대값과 일치 |

## 발표 평가(사람이 채점, 참고용 — 자동 점수와 별도)

| 관점 | 확인 질문 |
|---|---|
| 문제 정의 | 어떤 기업의 어떤 사고/운영 문제를 해결했는지 1분 안에 설명하는가? |
| 설계 이유 | 왜 이 통제(기술)를 이 위치에 배치했는지 계층(IAM/RBAC/Admission/Network/Audit)으로 설명하는가? |
| 증거 | Before/After 를 같은 테스트로 비교하고 실측값만 사용했는가? |
| 정상 유지 | 차단만이 아니라 정상 서비스가 유지됨을 함께 보였는가? |
| 한계 | 구현하지 않은 것·과장하면 안 되는 것을 구분해 말하는가? |
