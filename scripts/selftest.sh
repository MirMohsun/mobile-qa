#!/usr/bin/env bash
# Самопроверка окружения: прогоняет стандартный набор .maestro/ (как
# зафиксировано в .maestro/TEST_PLAN.md — exclude-tags destructive,
# needs-fixture,subflow). Падение значит "окружению нельзя верить" (код 2),
# а не "в приложении баг" — это разные вещи, и коды у них разные.
#
# Перед этим сам поднимает окружение (симулятор + Metro) через ensure-env.sh:
# если оно не поднимается вовсе, это код 3, а не 2.
#
# При любом падении автоматически пишет находки через report.sh —
# .maestro/reports/<дата>-<флоу>.md со скриншотом и (если есть) судьёй.
#
# Запуск: .claude/skills/mobile-qa/scripts/selftest.sh [--udid <id>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
MAESTRO_DIR="$PROJECT_ROOT/.maestro"

FORCED_UDID_ARGS=()
if [ "${1:-}" = "--udid" ]; then
  FORCED_UDID_ARGS=(--udid "$2")
fi

echo "--- Шаг 0: поднимаем окружение ---"
ENV_OUTPUT="$("$SCRIPT_DIR/ensure-env.sh" "${FORCED_UDID_ARGS[@]+"${FORCED_UDID_ARGS[@]}"}")" || {
  echo "$ENV_OUTPUT" >&2
  echo "Окружение не поднялось вовсе — это код 3, не 2. Самопроверка приложения тут ни при чём." >&2
  exit 3
}
echo "$ENV_OUTPUT"
UDID="$(echo "$ENV_OUTPUT" | tail -1)"
echo

if [ ! -d "$MAESTRO_DIR" ] || [ -z "$(find "$MAESTRO_DIR" -maxdepth 1 -name '*.yaml' -print -quit 2>/dev/null)" ]; then
  echo "В .maestro/ нет ни одного .yaml флоу — самопроверять нечего." >&2
  exit 3
fi

if [ -f "$MAESTRO_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$MAESTRO_DIR/.env"
  set +a
fi

ENV_ARGS=()
[ -n "${TEST_PHONE_NATIONAL:-}" ] && ENV_ARGS+=(-e "TEST_PHONE_NATIONAL=$TEST_PHONE_NATIONAL")
[ -n "${TEST_OTP:-}" ] && ENV_ARGS+=(-e "TEST_OTP=$TEST_OTP")

JUNIT_OUT="$(mktemp -t mobile-qa-junit).xml"

set +e
# Каноническая команда зафиксирована в .maestro/TEST_PLAN.md — не
# переизобретаем набор тегов тут, он должен совпадать с тем, что реально
# пишут флоу-авторы в заголовки .yaml
maestro --udid "$UDID" test "$MAESTRO_DIR" \
  --exclude-tags destructive,needs-fixture,subflow \
  --format JUNIT --output "$JUNIT_OUT" \
  "${ENV_ARGS[@]}"
MAESTRO_EXIT=$?
set -e

if [ "$MAESTRO_EXIT" -ne 0 ]; then
  echo
  echo "--- Пишу отчёты по упавшим флоу ---"
  "$SCRIPT_DIR/report.sh" "$JUNIT_OUT" || echo "report.sh сам не смог записать отчёты (см. вывод выше) — падения всё равно см. в JUnit: $JUNIT_OUT" >&2
  echo
  echo "Самопроверка провалена. Окружение было готово (ensure-env.sh это подтвердил) — значит дело в самих флоу/приложении, не в окружении. Отчёты — в .maestro/reports/."
  exit 2
fi

echo
echo "Самопроверка пройдена."
exit 0
