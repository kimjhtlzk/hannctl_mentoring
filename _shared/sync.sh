#!/usr/bin/env bash
# [관리자용] _shared 의 공통 파일을 모든 시나리오 폴더에 복사한다.
# 각 시나리오 폴더는 이 복사본으로 독립 실행된다 (조별로 폴더 단위 전달 가능).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for d in "$ROOT"/s[0-9]-*/; do
  mkdir -p "$d/lib" "$d/cfn" "$d/tools"
  cp "$ROOT/_shared/lib/common.sh" "$ROOT/_shared/lib/score.py" "$ROOT/_shared/lib/tagcheck.py" "$ROOT/_shared/lib/cost.py" "$d/lib/"
  cp "$ROOT/_shared/cfn/hannctl-finops-guard.yaml" "$d/cfn/"
  cp "$ROOT/_shared/tools/install-tools.sh" "$d/tools/"
  mkdir -p "$d/k8s/policies" && cp "$ROOT/_shared/k8s/kyverno-baseline.yaml" "$d/k8s/policies/"
  [ -f "$d/rubric.json" ] && python3 "$d/lib/score.py" --rubric "$d/rubric.json" --rubric-md "$d/RUBRIC.md" >/dev/null
  n=$(basename "$d")
  sed -e "s#__SCENARIO_DIR__#$n#g" -e "s#__GITHUB_REPO__#${GITHUB_REPO:-kimjhtlzk/hannctl_mentoring}#g" -e "s#__REPO_NAME__#${GITHUB_REPO_NAME:-hannctl_mentoring}#g" \
    "$ROOT/_shared/docs/START_HERE.md" > "$d/START_HERE.md"
  chmod +x "$d/tools/install-tools.sh" "$d/run.sh" 2>/dev/null || true
  echo "synced → ${d#$ROOT/}"
done
