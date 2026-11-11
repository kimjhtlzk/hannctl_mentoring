#!/usr/bin/env bash
# =============================================================================
# 실행에 필요한 도구를 확인하고 "없는 것만" 설치한다. 이미 있으면 건너뛴다.
#   기본 도구 : curl, tar, gzip, unzip  → OS 패키지 관리자 (apt / dnf / yum / zypper / apk / brew)
#   python3   : 패키지 관리자 → 안 되면 이 폴더의 .tools/python 에 독립 실행형 설치 (sudo 불필요)
#   AWS CLI v2, kubectl, helm : 이 폴더의 .tools/ 에 설치 (sudo 불필요, 시스템 경로를 건드리지 않음)
# 지원: macOS(Apple Silicon/Intel), Ubuntu/Debian, CentOS/Rocky/RHEL/Amazon Linux, openSUSE, AWS CloudShell
# =============================================================================
set -uo pipefail
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.35.0}"
HELM_VERSION="${HELM_VERSION:-v3.19.0}"
PY_MIN_MINOR=8                                   # python 3.8 이상
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.tools"
BIN="$DIR/bin"; mkdir -p "$BIN"
export PATH="$BIN:$PATH"

case "$(uname -s)" in Darwin) OS=darwin ;; Linux) OS=linux ;; *) echo "지원하지 않는 OS: $(uname -s)"; exit 1 ;; esac
case "$(uname -m)" in x86_64|amd64) ARCH=amd64 ;; arm64|aarch64) ARCH=arm64 ;; *) echo "지원하지 않는 CPU: $(uname -m)"; exit 1 ;; esac
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

have() { command -v "$1" >/dev/null 2>&1; }
line() { printf '  %-12s %s\n' "$1" "$2"; }
SUDO=""; [ "$(id -u)" -ne 0 ] && have sudo && SUDO="sudo"

pm_install() { # OS 패키지 관리자로 설치 (Linux 는 root 또는 sudo 필요, macOS 는 Homebrew 가 있을 때만)
  if [ "$OS" = darwin ]; then have brew && brew install "$@" >/dev/null 2>&1; return; fi
  [ "$(id -u)" -ne 0 ] && [ -z "$SUDO" ] && return 1
  if have apt-get; then $SUDO apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq "$@" >/dev/null 2>&1
  elif have dnf; then $SUDO dnf install -y -q "$@" >/dev/null 2>&1
  elif have yum; then $SUDO yum install -y -q "$@" >/dev/null 2>&1
  elif have zypper; then $SUDO zypper -n -q install "$@" >/dev/null 2>&1
  elif have apk; then $SUDO apk add -q "$@" >/dev/null 2>&1
  else return 1; fi
}

echo "🔧 필요한 도구 확인 ($OS/$ARCH) — 이미 있는 것은 건너뜁니다"

# ---------------------------------------------------------------- 1) 기본 도구
for t in curl tar gzip unzip; do
  if have "$t"; then line "$t" "✔ 있음"; continue; fi
  line "$t" "… 설치 중"
  pkg=$t; [ "$t" = curl ] && pkg="curl ca-certificates"
  # shellcheck disable=SC2086
  pm_install $pkg && have "$t" && line "$t" "✔ 설치됨" || { line "$t" "✘ 설치 실패 — 관리자 권한(sudo)으로 직접 설치하세요"; [ "$t" = unzip ] || exit 1; }
done

# ---------------------------------------------------------------- 2) python3 (3.8 이상)
py_ok() { have python3 && python3 -c "import sys; sys.exit(0 if sys.version_info >= (3, $PY_MIN_MINOR) else 1)" 2>/dev/null; }
standalone_python() { # github.com/astral-sh/python-build-standalone 의 독립 실행형 Python 을 .tools/python 에 설치
  local triple url
  case "$OS-$ARCH" in
    darwin-arm64) triple=aarch64-apple-darwin ;;  darwin-amd64) triple=x86_64-apple-darwin ;;
    linux-arm64)  triple=aarch64-unknown-linux-gnu ;; linux-amd64) triple=x86_64-unknown-linux-gnu ;;
  esac
  url=$(curl -fsSL https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest |
        grep -oE "https://[^\"]*cpython-3\.12\.[0-9]+(%2B|\+)[0-9]+-${triple}-install_only\.tar\.gz" | head -1)
  [ -n "$url" ] || return 1
  rm -rf "$DIR/python" && curl -fsSL "$url" | tar xz -C "$DIR" && ln -sf "$DIR/python/bin/python3" "$BIN/python3"
}
if py_ok; then
  line python3 "✔ 있음 ($(python3 --version 2>&1))"
else
  line python3 "… 설치 중"
  case "$OS" in
    darwin) pm_install python ;;                                  # Homebrew 가 있으면 사용
    linux)  pm_install python3 || true ;;
  esac
  hash -r
  if ! py_ok; then standalone_python || true; hash -r; fi        # sudo/패키지 관리자가 없으면 폴더 안에 설치
  py_ok && line python3 "✔ 설치됨 ($(python3 --version 2>&1))" || { line python3 "✘ 설치 실패 — START_HERE.md 2단계 참고"; exit 1; }
fi

# ---------------------------------------------------------------- 3) AWS CLI v2
if have aws && aws --version 2>&1 | grep -q 'aws-cli/2'; then
  line "AWS CLI" "✔ 있음 ($(aws --version 2>&1 | cut -d' ' -f1))"
else
  line "AWS CLI" "… v2 설치 중 (.tools/aws-cli)"
  if [ "$OS" = linux ]; then
    A=$([ "$ARCH" = amd64 ] && echo x86_64 || echo aarch64)
    curl -fsSL -o "$TMP/awscli.zip" "https://awscli.amazonaws.com/awscli-exe-linux-$A.zip" &&
      unzip -q "$TMP/awscli.zip" -d "$TMP" && "$TMP/aws/install" -i "$DIR/aws-cli" -b "$BIN" --update >/dev/null
  else
    # macOS: 공식 pkg 를 "현재 사용자 폴더"에 설치 (관리자 암호 불필요)
    curl -fsSL -o "$TMP/AWSCLIV2.pkg" https://awscli.amazonaws.com/AWSCLIV2.pkg
    cat > "$TMP/choices.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><array><dict>
  <key>choiceAttribute</key><string>customLocation</string>
  <key>attributeSetting</key><string>$DIR</string>
  <key>choiceIdentifier</key><string>default</string>
</dict></array></plist>
EOF
    installer -pkg "$TMP/AWSCLIV2.pkg" -target CurrentUserHomeDirectory -applyChoiceChangesXML "$TMP/choices.xml" >/dev/null &&
      ln -sf "$DIR/aws-cli/aws" "$BIN/aws"
  fi
  hash -r
  aws --version 2>&1 | grep -q 'aws-cli/2' && line "AWS CLI" "✔ 설치됨 ($(aws --version 2>&1 | cut -d' ' -f1))" || { line "AWS CLI" "✘ 설치 실패"; exit 1; }
fi

# ---------------------------------------------------------------- 4) kubectl
if have kubectl; then
  line kubectl "✔ 있음"
else
  curl -fsSL -o "$BIN/kubectl" "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/$OS/$ARCH/kubectl" && chmod +x "$BIN/kubectl" &&
    line kubectl "✔ 설치됨 ($KUBECTL_VERSION)" || { line kubectl "✘ 설치 실패"; exit 1; }
fi

# ---------------------------------------------------------------- 5) helm
if have helm; then
  line helm "✔ 있음"
else
  curl -fsSL -o "$TMP/helm.tgz" "https://get.helm.sh/helm-$HELM_VERSION-$OS-$ARCH.tar.gz" &&
    tar -xzf "$TMP/helm.tgz" -C "$TMP" && mv "$TMP/$OS-$ARCH/helm" "$BIN/helm" && chmod +x "$BIN/helm" &&
    line helm "✔ 설치됨 ($HELM_VERSION)" || { line helm "✘ 설치 실패"; exit 1; }
fi

echo "✔ 도구 준비 완료 (폴더 안 설치 위치: $BIN — run.sh 가 자동으로 사용)"
