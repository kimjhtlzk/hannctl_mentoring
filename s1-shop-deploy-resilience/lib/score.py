#!/usr/bin/env python3
"""rubric.json + results.jsonl → 자동 채점(SCORECARD) + Before/After 보고서(REPORT.md).

채점 규칙
- 각 평가 항목(items[])은 하나 이상의 check(key, phase)를 가진다.
- check 는 해당 phase 의 가장 최근 record 가 ok(기대값==관찰값)일 때 통과.
- 항목 점수 = 배점 × (통과 check 수 / 전체 check 수)  → 부분 점수 허용.
- 총점 ≥ target(기본 88) 이면 PASS.
"""
import argparse
import html
import json
import os
import sys


KRW_PER_USD = 1400  # 비용 표시용 대략 환율


def krw(usd):
    return f"{int(round(usd * KRW_PER_USD, -1)):,}원"


def load_cost(run):
    p = os.path.join(run, "cost.json")
    return json.load(open(p)) if os.path.exists(p) else None


def load_jsonl(path):
    rows = []
    if os.path.exists(path):
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line:
                    rows.append(json.loads(line))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rubric", required=True)
    ap.add_argument("--run")
    ap.add_argument("--title", default="")
    ap.add_argument("--rubric-md", help="평가표 Markdown(RUBRIC.md) 생성 경로")
    a = ap.parse_args()

    rubric = json.load(open(a.rubric))
    if a.rubric_md:
        return write_rubric_md(rubric, a.rubric_md)
    results = load_jsonl(os.path.join(a.run, "results.jsonl"))
    timeline = load_jsonl(os.path.join(a.run, "timeline.jsonl"))
    latest = {}
    for r in results:  # 같은 key/phase 는 마지막 값 사용(재실행 반영)
        latest[(r["key"], r["phase"])] = r

    target = rubric.get("target", 88)
    total, max_total, rows = 0.0, 0, []
    for it in rubric["items"]:
        checks = it["checks"]
        passed = sum(1 for c in checks if latest.get((c["key"], c["phase"]), {}).get("ok"))
        got = round(it["points"] * passed / len(checks) * 2) / 2
        total += got
        max_total += it["points"]
        missing = [f'{c["phase"]}:{c["key"]}' for c in checks if (c["key"], c["phase"]) not in latest]
        rows.append((it, got, passed, len(checks), missing))

    verdict = "PASS" if total >= target else "FAIL"
    out = []
    out.append(f"# 실행 보고서 — {a.title or rubric.get('title', '')}\n")
    out.append(f"- 실행 ID: `{os.path.basename(os.path.normpath(a.run))}`")
    out.append(f"- **총점: {total:g} / {max_total}  (목표 {target}점 이상 → {verdict})**\n")

    out.append("## 1. 평가표 채점 결과\n")
    out.append("| ID | 영역 | 평가 항목 | 배점 | 획득 | 근거(check) |")
    out.append("|---|---|---|---:|---:|---|")
    for it, got, passed, n, missing in rows:
        mark = "✅" if passed == n else ("🟡" if passed else "❌")
        ev = ", ".join(f'{c["phase"]}:{c["key"]}' for c in it["checks"])
        out.append(f'| {it["id"]} | {it["category"]} | {mark} {it["title"]} | {it["points"]} | {got:g} | {ev} |')

    out.append("\n## 2. Before / After 비교 (동일 테스트)\n")
    out.append("| 테스트 | Before 관찰 | After 관찰 | After 기대 | 판정 | 지표 |")
    out.append("|---|---|---|---|---|---|")
    keys = []
    for r in results:
        if r["key"] not in keys:
            keys.append(r["key"])
    for k in keys:
        b, af = latest.get((k, "before")), latest.get((k, "after"))
        if not af:
            continue
        if b and b["observed"] != af["observed"] and af["ok"]:
            judge = "🔁 개선"
        elif af["ok"]:
            judge = "✅ 유지/정상"
        else:
            judge = "❌ 미달"
        metric = " / ".join(x for x in [b and b.get("metric") and f'B: {b["metric"]}', af.get("metric") and f'A: {af["metric"]}'] if x)
        out.append(f'| {af["title"]} | {b["observed"] if b else "-"} | {af["observed"]} | {af["expected"]} | {judge} | {metric} |')

    out.append("\n## 3. 전환 타임라인 (Before → After)\n")
    out.append("| 시각 | 단계 | 내용 |")
    out.append("|---|---|---|")
    for t in timeline:
        out.append(f'| {t["ts"]} | {t["title"]} | {t["detail"]} |')

    cost = load_cost(a.run)
    if cost:
        out.append("\n## 4. 비용 (실시간 추정)\n")
        out.append("| 항목 | 값 |\n|---|---|")
        out.append(f'| 시나리오 단가(추정) | ${cost["rate_usd_per_hour"]:.2f}/시간 (≈ {krw(cost["rate_usd_per_hour"])}) |')
        if cost["run_hours"] > 0:   # demo 로 실행했을 때만 (before/after 를 따로 실행하면 생략)
            out.append(f'| 이번 demo 실행 | {cost["run_hours"]:.2f}시간 → ${cost["run_cost_usd"]:.2f} (≈ {krw(cost["run_cost_usd"])}) |')
        out.append(f'| 스택 생성 후 누적 | {cost["stack_age_hours"]:.2f}시간 → ${cost["stack_cost_usd"]:.2f} (≈ {krw(cost["stack_cost_usd"])}) |')
        if cost.get("month_to_date_usd") is not None:
            out.append(f'| 이번 달 hannctl 전체 누적 | ${cost["month_to_date_usd"]:.2f} / 상한 ${cost["cap_usd"]:.0f} (≈ {krw(cost["month_to_date_usd"])} / {krw(cost["cap_usd"])}) |')
        out.append("\n> 가동시간 × 서울 리전 온디맨드 단가 기준의 보수적 추정. 실제 청구액은 Cost Explorer(태그 Project=hannctl)에서 확인.")

    out.append("\n## 5. 증적 파일\n")
    for phase in ("before", "after"):
        d = os.path.join(a.run, phase)
        if os.path.isdir(d):
            files = sorted(os.listdir(d))
            out.append(f"- `{phase}/`: " + ", ".join(f"`{f}`" for f in files))
    out.append("\n> 수치는 이번 실행의 실측값이다. 목표치를 실제 성과처럼 표기하지 않는다.\n")

    report = "\n".join(out)
    with open(os.path.join(a.run, "REPORT.md"), "w") as f:
        f.write(report)
    json.dump({"score": total, "max": max_total, "target": target, "verdict": verdict},
              open(os.path.join(a.run, "score.json"), "w"))

    write_html(a, rubric, rows, results, latest, keys, timeline, total, max_total, target, verdict)

    # 터미널 요약
    tty = sys.stdout.isatty()
    G, R, Y, B, Z = ("\033[32m", "\033[31m", "\033[33m", "\033[1m", "\033[0m") if tty else ("",) * 5
    for it, got, passed, n, missing in rows:
        c = G if passed == n else (Y if passed else R)
        print(f'  {c}{it["id"]:6} {got:>4g}/{it["points"]:<3} {it["title"]}{Z}' + (f"  (미실행: {', '.join(missing)})" if missing else ""))
    c = G if verdict == "PASS" else R
    print(f"\n  {B}{c}총점 {total:g}/{max_total} — 목표 {target}점 → {verdict}{Z}")
    print(f"  보고서: {os.path.join(a.run, 'REPORT.md')}")
    print(f"  시각화: {os.path.join(a.run, 'REPORT.html')}  (브라우저로 열기)")


def write_rubric_md(rubric, path):
    o = [f"# 평가표 — {rubric['title']}\n",
         f"- 만점 **{sum(i['points'] for i in rubric['items'])}점**, 목표 **{rubric.get('target', 88)}점 이상**",
         "- `./run.sh demo`(또는 `after`) 가 끝나면 **자동 채점**된다. 수동 재채점: `./run.sh score`",
         "- 각 항목은 하나 이상의 자동 테스트(check)로 판정한다. 항목 점수 = 배점 × (통과 테스트 수 / 테스트 수)",
         "- `before:` 테스트는 \"통제 전 위험이 실제로 재현되었는가\", `after:` 테스트는 \"통제 후 기대 결과가 나왔는가\"를 본다.\n",
         "| ID | 영역 | 평가 항목 | 배점 | 판정 근거(자동 테스트) | 합격 기준 |", "|---|---|---|---:|---|---|"]
    for it in rubric["items"]:
        ev = "<br>".join(f'`{c["phase"]}:{c["key"]}`' for c in it["checks"])
        o.append(f'| {it["id"]} | {it["category"]} | {it["title"]} | {it["points"]} | {ev} | {it.get("criteria", "모든 테스트가 기대값과 일치")} |')
    o.append("\n## 발표 평가(사람이 채점, 참고용 — 자동 점수와 별도)\n")
    o.append("| 관점 | 확인 질문 |\n|---|---|")
    for q in rubric.get("presentation", [
        ("문제 정의", "어떤 기업의 어떤 사고/운영 문제를 해결했는지 1분 안에 설명하는가?"),
        ("설계 이유", "왜 이 통제(기술)를 이 위치에 배치했는지 계층(IAM/RBAC/Admission/Network/Audit)으로 설명하는가?"),
        ("증거", "Before/After 를 같은 테스트로 비교하고 실측값만 사용했는가?"),
        ("정상 유지", "차단만이 아니라 정상 서비스가 유지됨을 함께 보였는가?"),
        ("한계", "구현하지 않은 것·과장하면 안 되는 것을 구분해 말하는가?")]):
        o.append(f"| {q[0]} | {q[1]} |")
    open(path, "w").write("\n".join(o) + "\n")
    print(f"평가표 생성: {path}")


def write_html(a, rubric, rows, results, latest, keys, timeline, total, max_total, target, verdict):
    """브라우저로 여는 단일 파일 보고서 (외부 리소스 없음 — 오프라인/사내망에서도 열림)."""
    esc = html.escape
    pct = int(total / max_total * 100) if max_total else 0
    color = "#1a7f37" if verdict == "PASS" else "#cf222e"
    item_rows = []
    for it, got, passed, n, _ in rows:
        state = "ok" if passed == n else ("part" if passed else "bad")
        item_rows.append(
            f'<tr class="{state}"><td>{esc(it["id"])}</td><td>{esc(it["category"])}</td><td>{esc(it["title"])}</td>'
            f'<td class="num">{got:g} / {it["points"]}</td>'
            f'<td><div class="bar"><span style="width:{int(got / it["points"] * 100)}%"></span></div></td></tr>')
    cmp_rows = []
    for k in keys:
        b, af = latest.get((k, "before")), latest.get((k, "after"))
        if not af:
            continue
        changed = b and b["observed"] != af["observed"]
        judge = ("개선" if changed else "정상 유지") if af["ok"] else "미달"
        cls = "ok" if af["ok"] else "bad"
        cmp_rows.append(
            f'<tr class="{cls}"><td>{esc(af["title"])}</td>'
            f'<td><span class="pill {"risk" if b and b["ok"] and changed else ""}">{esc(b["observed"]) if b else "-"}</span></td>'
            f'<td class="arrow">{"→" if changed else "="}</td>'
            f'<td><span class="pill {cls}">{esc(af["observed"])}</span></td><td>{esc(af["expected"])}</td><td>{judge}</td>'
            f'<td class="metric">{esc(af.get("metric") or "")}</td></tr>')
    tl_rows = "".join(f'<li><b>{esc(t["ts"])}</b> {esc(t["title"])}<br><small>{esc(t["detail"])}</small></li>' for t in timeline)
    cost = load_cost(a.run)
    cost_html = ""
    if cost:
        mtd = cost.get("month_to_date_usd")
        cost_html = (f'<h2>비용 (실시간 추정)</h2><table>'
                     f'<tr><td>시나리오 단가</td><td>${cost["rate_usd_per_hour"]:.2f}/시간 (≈ {krw(cost["rate_usd_per_hour"])})</td></tr>'
                     + (f'<tr><td>이번 demo 실행</td><td>{cost["run_hours"]:.2f}시간 → <b>${cost["run_cost_usd"]:.2f}</b> (≈ {krw(cost["run_cost_usd"])})</td></tr>' if cost["run_hours"] > 0 else "")
                     + f'<tr><td>스택 생성 후 누적</td><td>{cost["stack_age_hours"]:.2f}시간 → ${cost["stack_cost_usd"]:.2f}</td></tr>'
                     + (f'<tr><td>이번 달 hannctl 전체</td><td>${mtd:.2f} / 상한 ${cost["cap_usd"]:.0f}'
                        f'<div class="bar"><span style="width:{min(100, int(mtd / cost["cap_usd"] * 100))}%"></span></div></td></tr>' if mtd is not None else "")
                     + '</table><p><small>가동시간 × 서울 리전 단가 기준 보수적 추정. 실제 청구액은 Cost Explorer(태그 Project=hannctl).</small></p>')
    doc = f"""<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{esc(rubric.get('title', 'hannctl report'))}</title><style>
:root{{--bg:#fff;--fg:#1f2328;--mute:#656d76;--line:#d0d7de;--ok:#1a7f37;--okbg:#dafbe1;--bad:#cf222e;--badbg:#ffebe9;--part:#9a6700;--partbg:#fff8c5}}
@media (prefers-color-scheme:dark){{:root{{--bg:#0d1117;--fg:#e6edf3;--mute:#8d96a0;--line:#30363d;--okbg:#033a16;--badbg:#490202;--partbg:#3b2e00}}}}
body{{background:var(--bg);color:var(--fg);font:15px/1.55 -apple-system,"Apple SD Gothic Neo","Noto Sans KR",sans-serif;margin:0;padding:24px 16px;max-width:1100px;margin:auto}}
h1{{font-size:22px;margin:0 0 4px}} h2{{font-size:17px;margin:28px 0 10px;border-bottom:1px solid var(--line);padding-bottom:6px}}
.score{{display:flex;gap:20px;align-items:center;margin:16px 0}} .gauge{{width:120px;height:120px;border-radius:50%;
background:conic-gradient({color} {pct}%,var(--line) 0);display:grid;place-items:center}}
.gauge div{{width:92px;height:92px;border-radius:50%;background:var(--bg);display:grid;place-items:center;font-size:24px;font-weight:700}}
.verdict{{font-size:20px;font-weight:700;color:{color}}} table{{width:100%;border-collapse:collapse;font-size:14px}}
td,th{{border-bottom:1px solid var(--line);padding:7px 6px;text-align:left;vertical-align:top}} th{{color:var(--mute);font-weight:600}}
.num{{white-space:nowrap;text-align:right}} .bar{{background:var(--line);height:8px;border-radius:4px;min-width:80px}}
.bar span{{display:block;height:8px;border-radius:4px;background:var(--ok)}} tr.bad .bar span{{background:var(--bad)}} tr.part .bar span{{background:var(--part)}}
.pill{{padding:2px 8px;border-radius:10px;background:var(--line);font-family:ui-monospace,monospace;font-size:12px}}
.pill.ok{{background:var(--okbg);color:var(--ok)}} .pill.bad,.pill.risk{{background:var(--badbg);color:var(--bad)}}
.arrow{{color:var(--mute)}} .metric{{color:var(--mute);font-size:12px}} ul.tl{{list-style:none;padding:0;border-left:3px solid var(--line)}}
ul.tl li{{padding:4px 0 8px 14px}} small{{color:var(--mute)}} .wrap{{overflow-x:auto}}
</style></head><body>
<h1>{esc(rubric.get('title', ''))}</h1><div style="color:var(--mute)">실행 ID {esc(os.path.basename(os.path.normpath(a.run)))}</div>
<div class="score"><div class="gauge"><div>{total:g}</div></div><div><div class="verdict">{verdict}</div>
<div>총점 {total:g} / {max_total} · 목표 {target}점 이상</div></div></div>
<h2>Before → After 비교 (같은 테스트를 두 번 실행)</h2><div class="wrap"><table>
<tr><th>테스트</th><th>Before</th><th></th><th>After</th><th>After 기대</th><th>판정</th><th>지표</th></tr>{''.join(cmp_rows)}</table></div>
<p><small>빨간 Before 값 = 통제 전 위험이 실제로 재현된 것. After 에서 기대값과 일치하면 통제가 동작한 것.</small></p>
<h2>평가표 채점</h2><div class="wrap"><table><tr><th>ID</th><th>영역</th><th>평가 항목</th><th>점수</th><th></th></tr>{''.join(item_rows)}</table></div>
<h2>전환 타임라인</h2><ul class="tl">{tl_rows}</ul>{cost_html}
<p><small>모든 수치는 이번 실행의 실측값. 원본 증적은 같은 폴더의 before/, after/ 참조.</small></p>
</body></html>"""
    with open(os.path.join(a.run, "REPORT.html"), "w") as f:
        f.write(doc)


if __name__ == "__main__":
    main()
