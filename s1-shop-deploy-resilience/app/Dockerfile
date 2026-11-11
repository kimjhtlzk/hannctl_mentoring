# ShopNow 상품 API 이미지 (CodeBuild 에서 빌드 → Trivy 검사 → ECR)
FROM public.ecr.aws/docker/library/python:3.13-alpine

# VARIANT=vuln: 오래된 취약 라이브러리를 일부러 포함 (Trivy 차단 시연용, 앱에서는 사용 안 함)
# 그 다음, 실행에 필요 없는 설치 도구(pip 등)를 지워 공격 표면과 취약점을 줄인다
#  (공식 베이스 이미지도 pip 내부 라이브러리에 HIGH 취약점이 있을 수 있음 → 그대로 두면 게이트에서 차단됨)
ARG VARIANT=secure
RUN if [ "$VARIANT" = "vuln" ]; then pip install --no-cache-dir Django==2.2; fi; \
    pip uninstall -y pip setuptools wheel >/dev/null 2>&1; rm -rf /usr/local/lib/python3*/ensurepip

# 버전/장애 모드는 빌드 시 고정 → 이미지 태그만 봐도 무엇이 배포됐는지 알 수 있음
ARG APP_VERSION=v1
ARG FAIL_MODE=0
ENV APP_VERSION=$APP_VERSION FAIL_MODE=$FAIL_MODE PYTHONDONTWRITEBYTECODE=1

WORKDIR /app
COPY app.py /app/app.py

# root 가 아닌 사용자로 실행 (PSA restricted 기준 충족)
USER 10001
EXPOSE 8080
CMD ["python3", "/app/app.py"]
