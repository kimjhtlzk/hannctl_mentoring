"""ReleaseSafe 고객용 API (표준 라이브러리만 사용).

서버 모드 (기본, 8080):
  GET /version  → 이 이미지가 어떤 버전·커밋·CI 빌드에서 왔는지 (배포 추적성)
  GET /health   → 헬스체크
테스트 모드:
  python3 app.py probe URL [TIMEOUT]  → HTTP 상태코드 또는 BLOCKED
  python3 app.py get URL              → 응답 본문 출력
"""
import json
import os
import socket
import sys
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

INFO = {
    "service": "release-api",
    "version": os.environ.get("APP_VERSION", "dev"),
    "variant": os.environ.get("APP_VARIANT", "secure"),
    "commit": os.environ.get("GIT_COMMIT", "unknown"),
    "build_id": os.environ.get("BUILD_ID", "local"),
}


class Handler(BaseHTTPRequestHandler):
    def reply(self, code, body):
        data = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.startswith("/health"):
            return self.reply(200, {"status": "ok"})
        if self.path.startswith("/version"):
            return self.reply(200, dict(INFO, pod=socket.gethostname()))
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


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "probe":
        print(probe(sys.argv[2], float(sys.argv[3]) if len(sys.argv) > 3 else 4))
    elif len(sys.argv) > 2 and sys.argv[1] == "get":
        with urllib.request.urlopen(sys.argv[2], timeout=5) as r:
            print(r.read().decode())
    else:
        ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
