"""BizDesk 샘플 업무 앱 (표준 라이브러리만 사용 — 별도 이미지 빌드 불필요).

서버 모드 (기본):
  GET /health            → 헬스체크
  GET /tenant            → 이 테넌트의 내부 데이터(가상)
  GET /call?target=URL   → (web 역할) 다른 서비스 호출 결과를 그대로 보여줌
테스트 모드:
  python3 app.py probe URL [TIMEOUT]   → HTTP 상태코드 또는 BLOCKED 출력
  python3 app.py resolve HOST          → RESOLVED / FAILED
"""
import json
import os
import socket
import sys
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TENANT = os.environ.get("TENANT", "unknown")
ROLE = os.environ.get("ROLE", "api")


def probe(url, timeout):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return str(r.status)
    except urllib.error.HTTPError as e:
        return str(e.code)
    except Exception as e:  # 타임아웃/연결거부 = 네트워크 차단
        return "BLOCKED"


class Handler(BaseHTTPRequestHandler):
    def reply(self, code, body):
        data = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        if u.path == "/health":
            return self.reply(200, {"status": "ok", "tenant": TENANT, "role": ROLE})
        if u.path == "/tenant":
            return self.reply(200, {"tenant": TENANT, "pod": socket.gethostname(),
                                    "data": f"{TENANT} 고객사 내부 주문 데이터(가상)"})
        if u.path == "/call":
            target = urllib.parse.parse_qs(u.query).get("target", [""])[0]
            return self.reply(200, {"from": TENANT, "target": target, "result": probe(target, 3)})
        return self.reply(404, {"error": "not found"})

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "probe":
        print(probe(sys.argv[2], float(sys.argv[3]) if len(sys.argv) > 3 else 4))
    elif len(sys.argv) > 1 and sys.argv[1] == "resolve":
        try:
            socket.gethostbyname(sys.argv[2])
            print("RESOLVED")
        except Exception:
            print("FAILED")
    else:
        ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
