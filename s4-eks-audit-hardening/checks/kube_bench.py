#!/usr/bin/env python3
"""kube-bench 결과(JSON) 집계 + 전후 비교 보고서.

usage:
  kube_bench.py summarize RAW_LOG OUT_DIR   → OUT_DIR/kube-bench.json, kube-bench.md
                                              stdout: "<pass> <fail> <warn> <info> <4.1.1 상태>"
  kube_bench.py compare RUN_DIR             → RUN_DIR/COMPLIANCE.md (kube-bench 표 / 자체 점검 표 를 분리)
"""
import json
import os
import sys


def extract(raw_path):
    """Job 로그에서 JSON 부분만 추출 (경고 문구 등이 섞여 있을 수 있음)."""
    text = open(raw_path).read()
    start, end = text.find("{"), text.rfind("}")
    return json.loads(text[start:end + 1])


def flatten(report):
    rows = []
    for c in report.get("Controls", []):
        for t in c.get("tests", []):
            for r in t.get("results", []):
                rows.append({"section": c.get("text", ""), "id": r.get("test_number"), "desc": r.get("test_desc", ""),
                             "status": r.get("status"), "scored": r.get("scored")})
    return rows


def summarize(raw, out):
    rep = extract(raw)
    rows = flatten(rep)
    tot = {k: sum(r["status"] == k for r in rows) for k in ("PASS", "FAIL", "WARN", "INFO")}
    json.dump({"totals": tot, "results": rows}, open(os.path.join(out, "kube-bench.json"), "w"), ensure_ascii=False, indent=1)
    md = [f"# kube-bench (CIS Amazon EKS Benchmark v1.8.0) — PASS {tot['PASS']} / FAIL {tot['FAIL']} / WARN {tot['WARN']}\n",
          "| 항목 | 내용 | 결과 |", "|---|---|---|"]
    md += [f'| {r["id"]} | {r["desc"]} | {r["status"]} |' for r in rows]
    open(os.path.join(out, "kube-bench.md"), "w").write("\n".join(md) + "\n")
    s415 = next((r["status"] for r in rows if r["id"] == "4.1.5"), "NA")
    print(tot["PASS"], tot["FAIL"], tot["WARN"], tot["INFO"], s415)


# After 에도 남는 FAIL 의 원인 — 고객이 고칠 수 없거나(관리형/시스템) 고치면 클러스터가 깨지는 항목
WHY = {
    "4.1.1": "EKS 가 자동 생성하는 eks:addon-cluster-admin(User eks:addon-manager) 바인딩 — AWS 관리형, 제거 대상 아님",
    "4.1.2": "Kubernetes/EKS 기본 Role 중 Secret 조회 권한을 가진 시스템 역할이 존재",
    "4.1.3": "기본 ClusterRole(cluster-admin 등)이 와일드카드(*)를 사용 — Kubernetes 기본 구성",
    "4.1.4": "기본 ClusterRole(admin, edit 등)이 Pod 생성 권한 보유 — Kubernetes 기본 구성",
    "4.1.6": "시스템 Pod(aws-node, kube-proxy, coredns 등)는 API 접근이 필요해 토큰을 마운트",
    "4.2.1": "aws-node·kube-proxy 등 노드 네트워크를 구성하는 시스템 DaemonSet 은 privileged 필요",
    "4.2.2": "점검 도구 kube-bench Pod 자체가 hostPID 사용 (점검 중에만 존재, 종료 후 삭제)",
    "4.2.4": "aws-node·kube-proxy 등 시스템 DaemonSet 은 hostNetwork 필요",
    "4.3.2": "kube-system 등 시스템 Namespace 에는 NetworkPolicy 미적용 (잘못 적용하면 클러스터 장애)",
    "4.5.2": "default Namespace 에 Kubernetes 가 자동 생성한 serviceaccount/default 를 사용자 리소스로 판정",
}


def load(path):
    return json.load(open(path)) if os.path.exists(path) else None


def pct(p, f):
    return f"{p * 100 // (p + f)}%" if p + f else "-"


def compare(run):
    kb_b, kb_a = load(f"{run}/before/kube-bench.json"), load(f"{run}/after/kube-bench.json")
    sc_b, sc_a = load(f"{run}/before/selfcheck.json"), load(f"{run}/after/selfcheck.json")
    o = ["# 컴플라이언스 전후 비교 (진단 → 개선 → 재진단)\n",
         "> kube-bench(CIS 공식 기준)와 자체 점검(회사 기준)은 **검사 영역이 다르므로 합산하지 않는다.**\n"]
    if kb_b and kb_a:
        tb, ta = kb_b["totals"], kb_a["totals"]
        o += ["## 표 1. kube-bench — CIS Amazon EKS Benchmark v1.8.0 (node · policies · controlplane · managedservices)\n",
              "| 구분 | PASS | FAIL | WARN(수동 확인) | 자동판정 준수율 PASS/(PASS+FAIL) |", "|---|---:|---:|---:|---:|",
              f'| Before | {tb["PASS"]} | {tb["FAIL"]} | {tb["WARN"]} | {pct(tb["PASS"], tb["FAIL"])} |',
              f'| After  | {ta["PASS"]} | {ta["FAIL"]} | {ta["WARN"]} | {pct(ta["PASS"], ta["FAIL"])} |', ""]
        before = {r["id"]: r for r in kb_b["results"]}
        changed = [(r, before.get(r["id"], {}).get("status")) for r in kb_a["results"]
                   if before.get(r["id"], {}).get("status") != r["status"]]
        o.append("**상태가 바뀐 항목**\n")
        if changed:
            o += ["| 항목 | 내용 | Before | After |", "|---|---|---|---|"]
            o += [f'| {r["id"]} | {r["desc"]} | {b} | {r["status"]} |' for r, b in changed]
        else:
            o.append("- 없음")
        still = [r for r in kb_a["results"] if r["status"] == "FAIL"]
        if still:
            o += ["", "**After 에도 FAIL 로 남은 항목과 원인** (숨기지 않고 보고 — 대부분 AWS 관리형·시스템 구성요소)\n",
                  "| 항목 | 내용 | 남은 이유 |", "|---|---|---|"]
            o += [f'| {r["id"]} | {r["desc"]} | {WHY.get(r["id"], "추가 분석 필요")} |' for r in still]
        o.append("\n> controlplane·managedservices 섹션은 AWS 관리형 영역이라 대부분 WARN(수동 확인)이다. 분모에서 임의로 빼지 않고 그대로 보고한다.\n")
    if sc_b and sc_a:
        o += ["## 표 2. 자체 점검 — AuditReady 내부 기준 (DEMO-01 ~ 12)\n",
              "| 구분 | 통과 | 전체 | 통과율 | 점검 소요(자동) |", "|---|---:|---:|---:|---:|",
              f'| Before | {sc_b["passed"]} | {sc_b["total"]} | {sc_b["passed"] * 100 // sc_b["total"]}% | {sc_b["seconds"]}s |',
              f'| After  | {sc_a["passed"]} | {sc_a["total"]} | {sc_a["passed"] * 100 // sc_a["total"]}% | {sc_a["seconds"]}s |', "",
              "| ID | 점검 항목 | Before | After |", "|---|---|---|---|"]
        b = {r["id"]: r for r in sc_b["checks"]}
        o += [f'| {r["id"]} | {r["title"]} | {b[r["id"]]["status"]} | {r["status"]} |' for r in sc_a["checks"]]
    open(os.path.join(run, "COMPLIANCE.md"), "w").write("\n".join(o) + "\n")
    print(os.path.join(run, "COMPLIANCE.md"))


if __name__ == "__main__":
    if sys.argv[1] == "summarize":
        summarize(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == "compare":
        compare(sys.argv[2])
