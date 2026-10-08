#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 0 ]]; then
  echo "用法：./scripts/run_macos.sh（仅支持本机 macOS Debug，不接受额外参数）" >&2
  exit 2
fi
if [[ "$(uname -s)" != Darwin ]]; then
  echo "此启动入口仅支持 macOS。" >&2
  exit 1
fi
if ! command -v flutter >/dev/null 2>&1; then
  echo "找不到 Flutter，请先将 Flutter SDK 的 bin 目录加入 PATH。" >&2
  exit 1
fi

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
if ! signing_python="$(xcrun --find python3)"; then
  echo "找不到 Xcode Python 3，请检查 Xcode 安装、所选开发者目录及首次启动设置。" >&2
  exit 1
fi
"$signing_python" -B "$project_root/scripts/macos_signing.py"

# Replace this process so Flutter owns the terminal, hot reload and Ctrl-C.
exec flutter run -d macos --debug --no-pub
