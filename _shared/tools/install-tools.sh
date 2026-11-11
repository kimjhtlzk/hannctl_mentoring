#!/usr/bin/env bash
# kubectl / helm (+ Linux 에서 AWS CLI v2 가 없으면 함께) 를 시나리오 폴더의 .tools/bin 에 설치한다.
# 지원: macOS(arm64/x86_64), Linux(Ubuntu/CentOS/Amazon Linux/AWS CloudShell, x86_64/aarch64)
# 관리자 권한(sudo) 불필요. 시스템 경로를 건드리지 않는다.
set -euo pipefail
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.35.0}"
HELM_VERSION="${HELM_VERSION:-v3.19.0}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.tools"
BIN="$DIR/bin"; mkdir -p "$BIN"

case "$(uname -s)" in Darwin) OS=darwin ;; Linux) OS=linux ;; *) echo "지원하지 않는 OS"; exit 1 ;; esac
case "$(uname -m)" in x86_64|amd64) ARCH=amd64 ;; arm64|aarch64) ARCH=arm64 ;; *) echo "지원하지 않는 CPU"; exit 1 ;; esac
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

if ! command -v kubectl >/dev/null 2>&1; then
  echo "• kubectl $KUBECTL_VERSION ($OS/$ARCH) 설치"
  curl -fsSL -o "$BIN/kubectl" "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/$OS/$ARCH/kubectl"
  chmod +x "$BIN/kubectl"
fi
if ! command -v helm >/dev/null 2>&1; then
  echo "• helm $HELM_VERSION ($OS/$ARCH) 설치"
  curl -fsSL -o "$TMP/helm.tgz" "https://get.helm.sh/helm-$HELM_VERSION-$OS-$ARCH.tar.gz"
  tar -xzf "$TMP/helm.tgz" -C "$TMP"; mv "$TMP/$OS-$ARCH/helm" "$BIN/helm"; chmod +x "$BIN/helm"
fi
if ! command -v aws >/dev/null 2>&1; then
  if [ "$OS" = linux ]; then
    echo "• AWS CLI v2 설치"
    command -v unzip >/dev/null || { echo "unzip 이 필요합니다 (apt install unzip / yum install unzip)"; exit 1; }
    A=$([ "$ARCH" = amd64 ] && echo x86_64 || echo aarch64)
    curl -fsSL -o "$TMP/awscli.zip" "https://awscli.amazonaws.com/awscli-exe-linux-$A.zip"
    unzip -q "$TMP/awscli.zip" -d "$TMP"; "$TMP/aws/install" -i "$DIR/aws-cli" -b "$BIN" >/dev/null
  else
    echo "AWS CLI v2 를 설치하세요: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"; exit 1
  fi
fi
command -v python3 >/dev/null || { echo "python3 이 필요합니다 (apt install python3 / yum install python3)"; exit 1; }
echo "✔ 도구 준비 완료: $BIN"
