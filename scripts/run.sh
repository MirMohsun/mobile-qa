#!/usr/bin/env bash
# Прогоняет один Maestro-флоу после самопроверки окружения.
# Коды: 0 чисто, 1 флоу упал на реальном шаге, 2 самопроверка провалена
# (окружение было готово, но что-то из стандартного набора не прошло), 3 не
# удалось запустить вовсе (окружение не поднялось).
#
# При падении целевого флоу автоматически пишет отчёт через report.sh.
#
# Запуск: .claude/skills/mobile-qa/scripts/run.sh <flow.yaml> [--include-destructive] [--udid <id>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

if [ $# -lt 1 ]; then
  echo "Использование: run.sh <flow.yaml> [--include-destructive] [--udid <id>]" >&2
  exit 3
fi

FLOW="$1"
shift

INCLUDE_DESTRUCTIVE=0
FORCED_UDID_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --include-destructive) INCLUDE_DESTRUCTIVE=1; shift ;;
    --udid) FORCED_UDID_ARGS=(--udid "$2"); shift 2 ;;
    *) echo "Неизвестный флаг: $1" >&2; exit 3 ;;
  esac
done

if [ ! -f "$FLOW" ]; then
  echo "Флоу не найден: $FLOW" >&2
  exit 3
fi

FLOW_CONTENT="$(cat "$FLOW")"
if [[ "$FLOW_CONTENT" == *"- destructive"* ]] && [ "$INCLUDE_DESTRUCTIVE" -ne 1 ]; then
  echo "Флоу помечен tags: [destructive] (меняет реальные данные на проде — стейджинга нет)." >&2
  echo "Запусти с --include-destructive, если это осознанный выбор, а не случайность." >&2
  exit 3
fi
if [[ "$FLOW_CONTENT" == *"- needs-fixture"* ]]; then
  echo "Предупреждение: флоу помечен needs-fixture — без нужного состояния аккаунта не считается зелёным по дизайну (см. .maestro/TEST_PLAN.md)." >&2
fi

echo "--- Шаг 0: поднимаем окружение ---"
ENV_OUTPUT="$("$SCRIPT_DIR/ensure-env.sh" "${FORCED_UDID_ARGS[@]+"${FORCED_UDID_ARGS[@]}"}")" || {
  echo "$ENV_OUTPUT" >&2
  echo "Окружение не поднялось вовсе — код 3. До самопроверки/флоу дело не дошло." >&2
  exit 3
}
echo "$ENV_OUTPUT"
UDID="$(echo "$ENV_OUTPUT" | tail -1)"
echo

echo "--- Шаг 1: самопроверка стандартного набора ---"
if ! "$SCRIPT_DIR/selftest.sh" --udid "$UDID" >/tmp/mobile-qa-selftest.log 2>&1; then
  cat /tmp/mobile-qa-selftest.log
  echo "Самопроверка провалена — результатам по $FLOW верить нельзя. Окружение было готово, дело в флоу/приложении." >&2
  exit 2
fi
echo "Самопроверка пройдена."

echo "--- Шаг 2: прогон $FLOW ---"
if [ -f "$PROJECT_ROOT/.maestro/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$PROJECT_ROOT/.maestro/.env"
  set +a
fi

ENV_ARGS=()
[ -n "${TEST_PHONE_NATIONAL:-}" ] && ENV_ARGS+=(-e "TEST_PHONE_NATIONAL=$TEST_PHONE_NATIONAL")
[ -n "${TEST_OTP:-}" ] && ENV_ARGS+=(-e "TEST_OTP=$TEST_OTP")

JUNIT_OUT="$(mktemp -t mobile-qa-junit).xml"

set +e
maestro --udid "$UDID" test "$FLOW" --format JUNIT --output "$JUNIT_OUT" "${ENV_ARGS[@]}"
MAESTRO_EXIT=$?
set -e

if [ "$MAESTRO_EXIT" -eq 0 ]; then
  echo "Флоу прошёл чисто."
  exit 0
else
  echo "--- Пишу отчёт по падению ---"
  "$SCRIPT_DIR/report.sh" "$JUNIT_OUT" || true
  echo "Флоу упал на реальном шаге — см. отчёт в .maestro/reports/ и вывод Maestro выше." >&2
  exit 1
fi
