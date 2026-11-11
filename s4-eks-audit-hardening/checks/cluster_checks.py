#!/usr/bin/env python3
"""AuditReady 자체 보안 점검 (DEMO-01 ~ DEMO-12) — kube-bench 와 별개로 '우리 회사 기준'을 점검한다.

usage: cluster_checks.py --context CTX --cluster NAME --out DIR
출력 : DIR/selfcheck.json, selfcheck.csv, selfcheck.md   /  stdout: "<통과수> <전체수> <소요초>"
의존 : python3 표준 라이브러리 + kubectl + aws CLI (macOS/Linux/CloudShell 공통)
"""
import argparse
import csv
import json
import os
import subprocess
import time

HERE = os.path.dirname(os.path.abspath(__file__))
APP_NS = "audit-app"


def sh(cmd, check=False):
    p = subprocess.run(cmd, capture_output=True, text=True)
    if check and p.returncode != 0:
        raise RuntimeError(p.stderr.strip())
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def kjson(ctx, *args):
    rc, out, err = sh(["kubectl", "--context", ctx, *args, "-o", "json"])
    return json.loads(out) if rc == 0 and out else {}


# --------------------------------------------------------------------------- 점검 항목
# 각 함수는 (PASS|FAIL, 상세) 를 돌려준다.
def c01_psa(ctx, cluster):
    labels = kjson(ctx, "get", "ns", APP_NS).get("metadata", {}).get("labels", {})
    v = labels.get("pod-security.kubernetes.io/enforce", "없음")
    return ("PASS" if v == "restricted" else "FAIL"), f"enforce={v}"


def c02_cluster_admin(ctx, cluster):
    found = []
    for b in kjson(ctx, "get", "clusterrolebindings").get("items", []):
        if b["roleRef"]["name"] != "cluster-admin":
            continue
        for s in b.get("subjects") or []:
            n = s.get("name", "")
            if s.get("kind") == "Group" and n in ("system:masters", "system:nodes"):
                continue
            if n.startswith("system:") or n.startswith("eks:"):
                continue
            found.append(f'{b["metadata"]["name"]}→{s.get("kind")}/{n}')
    return ("PASS" if not found else "FAIL"), (", ".join(found) or "비시스템 주체 없음")


def c03_audit_log(ctx, cluster):
    rc, out, _ = sh(["aws", "eks", "describe-cluster", "--name", cluster, "--query",
                     "cluster.logging.clusterLogging[?enabled].types[]", "--output", "json"])
    types = json.loads(out) if rc == 0 and out else []
    return ("PASS" if "audit" in types else "FAIL"), f"enabled={types or '없음'}"


def c04_default_deny(ctx, cluster):
    for p in kjson(ctx, "get", "networkpolicy", "-n", APP_NS).get("items", []):
        sp = p["spec"]
        if sp.get("podSelector") in ({}, None) and set(sp.get("policyTypes", [])) >= {"Ingress", "Egress"} \
                and not sp.get("ingress") and not sp.get("egress"):
            return "PASS", p["metadata"]["name"]
    return "FAIL", "default-deny 정책 없음"


def c05_kyverno(ctx, cluster):
    # Kyverno ValidatingPolicy(CEL): validationActions 에 Deny 가 있고 READY 인 정책만 '강제 중'으로 인정
    want = {"hannctl-disallow-privileged", "hannctl-disallow-host-path", "hannctl-require-run-as-non-root"}
    have = set()
    for p in kjson(ctx, "get", "validatingpolicy").get("items", []):
        deny = "Deny" in p["spec"].get("validationActions", [])
        ready = p.get("status", {}).get("conditionStatus", {}).get("ready") is True
        if p["metadata"]["name"] in want and deny and ready:
            have.add(p["metadata"]["name"])
    return ("PASS" if have == want else "FAIL"), f"Deny+Ready 정책 {len(have)}/{len(want)}"


def c06_sa_token(ctx, cluster):
    sa = kjson(ctx, "get", "sa", "default", "-n", APP_NS)
    v = sa.get("automountServiceAccountToken")
    return ("PASS" if v is False else "FAIL"), f"automountServiceAccountToken={v}"


def c07_dev_secrets(ctx, cluster):
    _, out, _ = sh(["kubectl", "--context", ctx, "auth", "can-i", "get", "secrets", "-n", APP_NS,
                    "--as", "developer", "--as-group", "hannctl:developers"])
    return ("PASS" if out == "no" else "FAIL"), f"개발자 Secret 조회={out or 'no'}"


def c08_privileged(ctx, cluster):
    rc, _, err = sh(["kubectl", "--context", ctx, "apply", "-n", APP_NS, "--dry-run=server",
                     "-f", os.path.join(HERE, "..", "k8s", "attack", "privileged-pod.yaml")])
    return ("PASS" if rc != 0 else "FAIL"), ("거부됨" if rc != 0 else "생성 허용됨")


def c09_app(ctx, cluster):
    _, out, _ = sh(["kubectl", "--context", ctx, "-n", APP_NS, "exec", "deploy/web", "--", "python3", "/app/app.py",
                    "probe", f"http://api.{APP_NS}.svc.cluster.local/health", "4"])
    code = out.splitlines()[-1] if out else "ERR"
    return ("PASS" if code == "200" else "FAIL"), f"web→api HTTP {code}"


def c10_endpoint(ctx, cluster):
    rc, out, _ = sh(["aws", "eks", "describe-cluster", "--name", cluster, "--query",
                     "cluster.resourcesVpcConfig.publicAccessCidrs", "--output", "json"])
    cidrs = json.loads(out) if rc == 0 and out else []
    return ("PASS" if cidrs and "0.0.0.0/0" not in cidrs else "FAIL"), f"허용 CIDR {len(cidrs)}개(전체 공개 아님)" \
        if "0.0.0.0/0" not in cidrs else "0.0.0.0/0 공개"


def c11_imds(ctx, cluster):
    rc, out, _ = sh(["aws", "ec2", "describe-instances", "--filters", f"Name=tag:eks:cluster-name,Values={cluster}",
                     "Name=instance-state-name,Values=running", "--query",
                     "Reservations[].Instances[].MetadataOptions.[HttpTokens,HttpPutResponseHopLimit]", "--output", "json"])
    rows = json.loads(out) if rc == 0 and out else []
    ok = rows and all(r[0] == "required" and r[1] == 1 for r in rows)
    return ("PASS" if ok else "FAIL"), f"노드 {len(rows)}대 IMDSv2 필수·hop=1"


def c12_cron(ctx, cluster):
    cj = kjson(ctx, "get", "cronjob", "-n", "hannctl-audit")
    names = [i["metadata"]["name"] for i in cj.get("items", [])]
    return ("PASS" if names else "FAIL"), (", ".join(names) or "정기 점검 없음")


CHECKS = [
    ("DEMO-01", "Pod 보안", "업무 Namespace 에 PSA restricted 강제", "kubectl label ns audit-app pod-security.kubernetes.io/enforce=restricted", c01_psa),
    ("DEMO-02", "RBAC", "cluster-admin 이 비시스템 주체에 바인딩되지 않음", "과다 ClusterRoleBinding 삭제 후 Namespace Role 로 대체", c02_cluster_admin),
    ("DEMO-03", "감사 로그", "EKS API 감사 로그(audit) CloudWatch 수집", "CFN EnableAuditLog=true (EKS logging 설정)", c03_audit_log),
    ("DEMO-04", "네트워크", "업무 Namespace 에 default-deny NetworkPolicy", "default-deny + 필요한 경로만 허용", c04_default_deny),
    ("DEMO-05", "정책 엔진", "Kyverno 거부(Deny) 정책(privileged/hostPath/root)", "kubectl apply -f k8s/policies/kyverno-baseline.yaml", c05_kyverno),
    ("DEMO-06", "서비스 계정", "default SA 토큰 자동 마운트 비활성화", "automountServiceAccountToken: false", c06_sa_token),
    ("DEMO-07", "RBAC", "개발자 그룹이 Secret 을 조회할 수 없음", "개발자 → view(RoleBinding)", c07_dev_secrets),
    ("DEMO-08", "Pod 보안", "privileged Pod 생성 요청이 거부됨", "PSA restricted + Kyverno", c08_privileged),
    ("DEMO-09", "가용성", "업무 서비스 정상 응답(web→api 200)", "정책 변경 후 회귀 테스트", c09_app),
    ("DEMO-10", "AWS 설정", "EKS API 엔드포인트가 전체 공개(0.0.0.0/0)가 아님", "publicAccessCidrs 제한", c10_endpoint),
    ("DEMO-11", "AWS 설정", "노드 IMDSv2 필수 + hop limit 1", "Launch Template MetadataOptions", c11_imds),
    ("DEMO-12", "점검 자동화", "kube-bench 정기 점검 CronJob 등록", "kubectl apply -f k8s/after/50-kube-bench-cronjob.yaml", c12_cron),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--context", required=True)
    ap.add_argument("--cluster", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    t0 = time.time()
    rows = []
    for cid, cat, title, fix, fn in CHECKS:
        try:
            status, detail = fn(a.context, a.cluster)
        except Exception as e:  # 점검 실패도 결과로 남긴다
            status, detail = "ERROR", str(e)[:120]
        rows.append({"id": cid, "category": cat, "title": title, "status": status, "detail": detail, "fix": fix})
    secs = round(time.time() - t0, 1)
    passed = sum(r["status"] == "PASS" for r in rows)

    json.dump({"passed": passed, "total": len(rows), "seconds": secs, "checks": rows},
              open(os.path.join(a.out, "selfcheck.json"), "w"), ensure_ascii=False, indent=2)
    with open(os.path.join(a.out, "selfcheck.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["id", "category", "title", "status", "detail", "fix"])
        w.writeheader()
        w.writerows(rows)
    md = [f"# 자체 보안 점검 결과 — {passed}/{len(rows)} 통과 ({passed * 100 // len(rows)}%), 소요 {secs}s\n",
          "| ID | 영역 | 점검 항목 | 결과 | 상세 | 조치 방법 |", "|---|---|---|---|---|---|"]
    md += [f'| {r["id"]} | {r["category"]} | {r["title"]} | {"✅" if r["status"] == "PASS" else "❌"} {r["status"]} | {r["detail"]} | {r["fix"]} |' for r in rows]
    open(os.path.join(a.out, "selfcheck.md"), "w").write("\n".join(md) + "\n")
    print(passed, len(rows), secs)


if __name__ == "__main__":
    main()
