#!/usr/bin/env python3
"""hannctl 이번 달 누적 예상 비용 (실시간 추정, AWS 청구서 지연과 무관).

계산: 이번 달에 존재했던 hannctl-* 시나리오 스택마다
      가동 시간(생성~삭제 또는 지금) × 스택 태그 hannctl:est-usd-per-hour
usage: cost.py [--json]   (AWS CLI 자격 증명 사용, boto3 불필요)
"""
import datetime
import json
import subprocess
import sys

GUARD = "hannctl-finops-guard"
DEFAULT_RATE = 0.25  # 태그가 없을 때 보수적 단가(USD/h)


def aws(*args):
    out = subprocess.check_output(["aws", *args, "--output", "json"], stderr=subprocess.DEVNULL)
    return json.loads(out or b"{}")


def ts(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))


def estimate():
    now = datetime.datetime.now(datetime.timezone.utc)
    month_start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    rows, total = [], 0.0
    for s in aws("cloudformation", "list-stacks").get("StackSummaries", []):
        name = s["StackName"]
        if not name.startswith("hannctl-") or name == GUARD:
            continue
        created = ts(s["CreationTime"])
        deleted = ts(s["DeletionTime"]) if s.get("DeletionTime") else None
        if deleted and deleted < month_start:
            continue
        try:
            st = aws("cloudformation", "describe-stacks", "--stack-name", s["StackId"])["Stacks"][0]
        except Exception:
            continue
        tags = {t["Key"]: t["Value"] for t in st.get("Tags", [])}
        if tags.get("Project") != "hannctl":
            continue
        rate = float(tags.get("hannctl:est-usd-per-hour", DEFAULT_RATE))
        hours = max(0.0, ((deleted or now) - max(created, month_start)).total_seconds() / 3600)
        cost = hours * rate
        total += cost
        rows.append({"stack": name, "hours": round(hours, 2), "rate": rate, "usd": round(cost, 3),
                     "live": deleted is None})
    return {"month": now.strftime("%Y-%m"), "mtd_usd": round(total, 2), "stacks": rows}


if __name__ == "__main__":
    r = estimate()
    if "--json" in sys.argv:
        print(json.dumps(r, ensure_ascii=False))
    else:
        for x in r["stacks"]:
            print(f'  {x["stack"]:28} {x["hours"]:6.2f}h × ${x["rate"]:.2f}/h = ${x["usd"]:.2f}{"  (실행 중)" if x["live"] else ""}')
        print(f'  이번 달({r["month"]}) hannctl 누적 예상: ${r["mtd_usd"]:.2f}')
