# ReleaseSafe release-api 이미지
#  VARIANT=secure : 최신 베이스 + OS 패치 → Trivy HIGH/CRITICAL 0건 목표
#  VARIANT=vuln   : 일부러 오래된 라이브러리(Django 2.2) 포함 → Trivy 가 HIGH/CRITICAL 탐지 (실습용, 실제로 import 하지 않음)
FROM public.ecr.aws/docker/library/python:3.13-alpine

ARG VARIANT=secure
ARG APP_VERSION=dev
ARG GIT_COMMIT=unknown
ARG BUILD_ID=local

# OS 패키지 최신화 → (vuln 이면) 취약 라이브러리 설치 → 실행에 불필요한 pip 제거(공격 표면 축소)
RUN apk upgrade --no-cache \
 && if [ "$VARIANT" = "vuln" ]; then pip install --no-cache-dir Django==2.2; fi \
 && pip uninstall -y pip

# 이미지 안에 "어디서 왔는지" 기록 → /version 으로 확인 (배포 추적성)
ENV APP_VERSION=$APP_VERSION APP_VARIANT=$VARIANT GIT_COMMIT=$GIT_COMMIT BUILD_ID=$BUILD_ID PYTHONDONTWRITEBYTECODE=1

COPY app.py /app/app.py
USER 10001
EXPOSE 8080
CMD ["python3", "/app/app.py"]
