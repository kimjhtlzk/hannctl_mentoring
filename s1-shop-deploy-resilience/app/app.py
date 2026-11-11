"""ShopNow 상품 조회 API (표준 라이브러리만 사용).

서버 모드 (기본, 포트 8080):
  GET /products  → 상품 목록 (요청마다 약간의 CPU 연산 → HPA 확장 시연용)
  GET /health    → 헬스체크 (Readiness/Liveness Probe 대상)
  GET /version   → 현재 이미지 버전
  FAIL_MODE=1 이면 /products, /health 가 500 → "잘못된 배포(v2-bad)" 재현
테스트 모드:
  python3 app.py probe URL [TIMEOUT]                  → HTTP 상태코드 또는 BLOCKED
  python3 app.py get URL                              → 응답 본문 출력
  python3 app.py load URL SECONDS CONCURRENCY         → 부하 발생 후 성공률/p95 JSON 출력
"""
import hashlib
import json
import os
import socket
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = os.environ.get("APP_VERSION", "unknown")
FAIL = os.environ.get("FAIL_MODE", "0") == "1"
PRODUCTS = [{"id": i, "name": f"할인상품-{i}", "price": 1000 * i} for i in range(1, 21)]


def burn_cpu(n=10000):
    # 상품 조회 시 계산 작업 흉내 (CPU 사용률을 올려 HPA 동작을 보이게 함)
    h = b"shopnow"
    for _ in range(n):
        h = hashlib.sha256(h).digest()


class Handler(BaseHTTPRequestHandler):
    def reply(self, code, body):
        data = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.startswith("/version"):
            return self.reply(200, {"version": VERSION, "pod": socket.gethostname()})
        if FAIL:  # 버그가 있는 버전
            return self.reply(500, {"error": "internal error", "version": VERSION})
        if self.path.startswith("/health"):
            return self.reply(200, {"status": "ok"})
        if self.path.startswith("/products"):
            burn_cpu()
            return self.reply(200, {"version": VERSION, "pod": socket.gethostname(), "items": PRODUCTS})
        return self.reply(404, {"error": "not found"})

    def log_message(self, *args):
        pass


def probe(url, timeout):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return str(r.status)
    except urllib.error.HTTPError as e:
        return str(e.code)
    except Exception:
        return "BLOCKED"


def load(url, seconds, conc):
    # 간단한 부하 발생기: 일정 시간 동안 동시 요청 → 성공률/지연시간 측정
    lat, ok, fail = [], [0], [0]
    lock = threading.Lock()
    end = time.time() + seconds

    def worker():
        while time.time() < end:
            t = time.time()
            try:
                with urllib.request.urlopen(url, timeout=5) as r:
                    r.read()
                    good = r.status == 200
            except Exception:
                good = False
            with lock:
                lat.append((time.time() - t) * 1000)
                (ok if good else fail)[0] += 1

    ts = [threading.Thread(target=worker) for _ in range(conc)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    lat.sort()
    total = ok[0] + fail[0]
    print(json.dumps({
        "requests": total,
        "success_rate": round(ok[0] * 100 / total, 1) if total else 0,
        "p95_ms": round(lat[int(len(lat) * 0.95) - 1]) if lat else 0,
    }))


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "probe":
        print(probe(sys.argv[2], float(sys.argv[3]) if len(sys.argv) > 3 else 4))
    elif len(sys.argv) > 1 and sys.argv[1] == "get":
        try:
            print(urllib.request.urlopen(sys.argv[2], timeout=4).read().decode())
        except Exception as e:
            print(json.dumps({"error": str(e)}))
    elif len(sys.argv) > 1 and sys.argv[1] == "load":
        load(sys.argv[2], float(sys.argv[3]), int(sys.argv[4]))
    else:
        ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
