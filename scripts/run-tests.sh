#!/bin/bash
# MacAwake 单元测试（纯解析函数，CLT 环境无需 XCTest）
# 用法: ./scripts/run-tests.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> swift build -c release --product MacAwakeTests"
swift build -c release --product MacAwakeTests

exec "$ROOT/.build/release/MacAwakeTests"
