#!/usr/bin/env bash
# Тонкая обёртка над judge.py. Ключ только через MOBILE_QA_JUDGE_KEY в
# окружении — никогда не передавай его как аргумент (попадёт в историю
# шелла и в список процессов).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="${PYTHON:-python3}"
"$PYTHON" "$SCRIPT_DIR/judge.py" "$@"
