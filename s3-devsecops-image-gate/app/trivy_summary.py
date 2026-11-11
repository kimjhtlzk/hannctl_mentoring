"""Trivy JSON 결과 → 사람이 읽기 쉬운 요약 (CI 로그에 출력, run.sh 가 수집해 증적으로 저장)."""
import json
import sys

data = json.load(open(sys.argv[1]))
vulns = [v for r in data.get("Results") or [] for v in r.get("Vulnerabilities") or []]
crit = sum(1 for v in vulns if v["Severity"] == "CRITICAL")
high = sum(1 for v in vulns if v["Severity"] == "HIGH")
print(f"TRIVY_SUMMARY critical={crit} high={high}")
for v in sorted(vulns, key=lambda v: v["Severity"])[:10]:
    print(f'VULN {v["Severity"]:8} {v["VulnerabilityID"]:18} {v["PkgName"]} {v["InstalledVersion"]} -> fixed {v.get("FixedVersion", "-")}')
print(f"TRIVY_TOTAL={crit + high}")
