"""OfficeLink 사내 업무 API (boto3 포함 공개 이미지 + ConfigMap 주입 → 이미지 빌드 불필요).

AWS 자격증명은 코드에 없다. boto3 '표준 자격증명 체인'이 알아서 찾는다:
  ① 환경변수 AWS_ACCESS_KEY_ID (Before: 정적 키)  ② Pod Identity (After: 임시 자격증명)  ③ …

서버 모드 (기본, :8080)
  GET /health                 헬스체크
  GET /whoami                 지금 어떤 AWS 신원으로 동작하나
  GET /check-secret?name=…    Secrets Manager 조회 결과 (값은 앞 4자리만 표시)
  GET /call?target=URL        (web 역할) 다른 서비스 호출
CLI 모드 (테스트용)
  python3 app.py check NAME   → OK / ACCESS_DENIED / NO_CREDENTIALS / INVALID_KEY / BLOCKED / ERROR
  python3 app.py whoami       → user/<이름> | role/<이름> | NO_CREDENTIALS
  python3 app.py imds         → 노드 IMDS(인스턴스 역할) 우회 가능 여부: EXPOSED / BLOCKED
  python3 app.py probe URL [T]→ HTTP 상태코드 / BLOCKED
"""
import json
import os
import socket
import sys
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError, EndpointConnectionError, NoCredentialsError, ConnectTimeoutError

REGION = os.environ.get("AWS_REGION", "ap-northeast-2")
CFG = Config(connect_timeout=3, read_timeout=5, retries={"max_attempts": 1})


def check_secret(name):
    """비밀값 조회 결과를 (판정, 마스킹된 값) 으로 반환."""
    try:
        v = boto3.client("secretsmanager", region_name=REGION, config=CFG).get_secret_value(SecretId=name)["SecretString"]
        return "OK", v[:4] + "****"                     # 원문은 절대 출력하지 않는다
    except NoCredentialsError:
        return "NO_CREDENTIALS", None
    except ClientError as e:
        code = e.response["Error"]["Code"]
        if code in ("AccessDeniedException", "AccessDenied"):
            return "ACCESS_DENIED", None
        if code in ("UnrecognizedClientException", "InvalidClientTokenId", "InvalidSignatureException"):
            return "INVALID_KEY", None                   # 폐기된 정적 키
        return "ERROR:" + code, None
    except (EndpointConnectionError, ConnectTimeoutError):
        return "BLOCKED", None
    except Exception as e:
        return "ERROR:" + type(e).__name__, None


def whoami():
    try:
        arn = boto3.client("sts", region_name=REGION, config=CFG).get_caller_identity()["Arn"]
    except NoCredentialsError:
        return "NO_CREDENTIALS"
    except Exception as e:
        return "ERROR:" + type(e).__name__
    # 계정 ID 는 숨기고 신원 종류/이름만 표시
    if ":user/" in arn:
        return "user/" + arn.split(":user/")[1]
    if ":assumed-role/" in arn:
        return "role/" + arn.split(":assumed-role/")[1].split("/")[0]
    return "other"


def imds():
    """노드의 IMDSv2 토큰 발급 시도. hop limit 1 이면 Pod 에서는 응답이 돌아오지 않는다."""
    req = urllib.request.Request("http://169.254.169.254/latest/api/token", method="PUT",
                                 headers={"X-aws-ec2-metadata-token-ttl-seconds": "60"})
    try:
        urllib.request.urlopen(req, timeout=2).read()
        return "EXPOSED"
    except Exception:
        return "BLOCKED"


def probe(url, timeout):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return str(r.status)
    except urllib.error.HTTPError as e:
        return str(e.code)
    except Exception:
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
        q = urllib.parse.parse_qs(u.query)
        if u.path == "/health":
            return self.reply(200, {"status": "ok", "role": os.environ.get("ROLE", "api")})
        if u.path == "/whoami":
            return self.reply(200, {"pod": socket.gethostname(), "identity": whoami()})
        if u.path == "/check-secret":
            result, masked = check_secret(q.get("name", [""])[0])
            return self.reply(200 if result == "OK" else 403, {"result": result, "value": masked})
        if u.path == "/call":
            return self.reply(200, {"target": q.get("target", [""])[0], "result": probe(q.get("target", [""])[0], 3)})
        return self.reply(404, {"error": "not found"})

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "serve"
    if cmd == "check":
        print(check_secret(sys.argv[2])[0])
    elif cmd == "whoami":
        print(whoami())
    elif cmd == "imds":
        print(imds())
    elif cmd == "probe":
        print(probe(sys.argv[2], float(sys.argv[3]) if len(sys.argv) > 3 else 4))
    else:
        ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
