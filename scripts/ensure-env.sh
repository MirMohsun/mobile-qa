#!/usr/bin/env bash
# Поднимает окружение для Maestro-прогона: симулятор + Metro. Идемпотентно —
# повторный вызов не плодит процессы и не перевыбирает симулятор заново.
#
# Выбор симулятора: первый раз — первый доступный iOS Simulator (НЕ реальное
# устройство: xcrun simctl в принципе не видит физические девайсы, так что
# отдельно исключать их не нужно). UDID фиксируется в .maestro/.device и
# переиспользуется во всех следующих вызовах — не "первый доступный" каждый
# раз заново, а конкретно тот же симулятор.
#
# Коды: 0 — окружение готово, выводит UDID в stdout последней строкой.
#       3 — не удалось поднять (нет Maestro, нет ни одного симулятора,
#       приложение не установлено, Metro не поднялся).
#
# ПРАВИЛО ДЛЯ ВСЕГО ФАЙЛА: никогда `producer | grep -q ...` или
# `producer | head -N ...` напрямую под set -o pipefail. Любой консьюмер,
# который выходит раньше, чем producer дописал вывод (grep -q на первом
# совпадении, head -N на N-й строке), шлёт producer'у SIGPIPE; pipefail
# подхватывает ненулевой код producer'а и считает весь пайплайн упавшим,
# даже если сам консьюмер нашёл то, что искал. Поймано на практике на
# первом же прогоне этого скрипта (`xcrun simctl listapps | grep -q`
# падало через раз на реальном выводе в 500+ строк). Правило: сначала
# `VAR="$(producer)"`, потом парсить `$VAR` — producer успевает завершиться
# до того, как что-то решит прочитать не весь его вывод.
set -euo pipefail

FORCED_UDID=""
if [ "${1:-}" = "--udid" ]; then
  FORCED_UDID="$2"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
MAESTRO_DIR="$PROJECT_ROOT/.maestro"
DEVICE_FILE="$MAESTRO_DIR/.device"
METRO_PID_FILE="$MAESTRO_DIR/.metro.pid"
METRO_LOG_FILE="$MAESTRO_DIR/.metro.log"
CONFIG_FILE="$MAESTRO_DIR/config.json"
PYTHON="${PYTHON:-python3}"

mkdir -p "$MAESTRO_DIR"

fail() {
  echo "$1" >&2
  exit 3
}

# Проект-специфичные значения (appId, deep-link схема) живут в
# .maestro/config.json целевого проекта, не в самом скиле — иначе скил
# переносится на другой проект с чужим appId, зашитым в код
[ -f "$CONFIG_FILE" ] || fail ".maestro/config.json не найден. Это не секрет (в отличие от .maestro/.env) — заведи его сам с полями appId и devClientScheme для этого проекта, скил не угадывает их."
APP_ID="$("$PYTHON" -c "import json,sys; print(json.load(open(sys.argv[1]))['appId'])" "$CONFIG_FILE")"
# devClientScheme не читается здесь: ensure-env.sh не делает deep-link
# reconnect сам, это шаг каждого .yaml-флоу — схема нужна их авторам,
# не этому скрипту. Не держим неиспользуемую переменную.
METRO_PORT="$("$PYTHON" -c "import json,sys; print(json.load(open(sys.argv[1])).get('metroPort',8081))" "$CONFIG_FILE")"
[ -n "$APP_ID" ] || fail ".maestro/config.json не содержит appId — без него ensure-env.sh не знает, какое приложение проверять."

metro_up() {
  local status
  status="$(curl -s --max-time 2 "http://localhost:$METRO_PORT/status" 2>/dev/null || true)"
  [[ "$status" == *"packager-status:running"* ]]
}

echo "--- Maestro ---"
command -v maestro >/dev/null 2>&1 || fail "Maestro не установлен (команда maestro не найдена). Ставится через 'brew install --formula mobile-dev-inc/tap/maestro', не автоматически."
echo "ок: $(maestro --version 2>&1 | tail -1)"

echo "--- Симулятор ---"
UDID=""
if [ -n "$FORCED_UDID" ]; then
  UDID="$FORCED_UDID"
  echo "UDID задан явно: $UDID"
elif [ -f "$DEVICE_FILE" ]; then
  SAVED_UDID="$(cat "$DEVICE_FILE" 2>/dev/null | tr -d '[:space:]')"
  ALL_DEVICES="$(xcrun simctl list devices)"
  if [ -n "$SAVED_UDID" ] && [[ "$ALL_DEVICES" == *"$SAVED_UDID"* ]]; then
    UDID="$SAVED_UDID"
    echo "используем ранее выбранный симулятор: $UDID"
  else
    echo "сохранённый UDID ($SAVED_UDID) больше не существует — выбираю заново"
  fi
fi

if [ -z "$UDID" ]; then
  # Первый запуск (или сохранённый девайс исчез): первый доступный iPhone-
  # симулятор, в порядке, в котором его выдаёт simctl. Реальные устройства
  # сюда не попадают в принципе — simctl работает только с симуляторами.
  AVAILABLE_DEVICES="$(xcrun simctl list devices available 2>/dev/null)"
  FIRST_IPHONE_LINE="$(echo "$AVAILABLE_DEVICES" | grep -E '^\s+iPhone' | head -1 || true)"
  UDID="$(echo "$FIRST_IPHONE_LINE" | sed -E 's/.*\(([0-9A-F-]+)\).*/\1/')"
  [ -n "$UDID" ] || fail "Ни одного доступного iPhone-симулятора не найдено (xcrun simctl list devices available). Поставь рантайм iOS в Xcode — автоматически скил этого не делает."
  echo "$UDID" > "$DEVICE_FILE"
  echo "выбран новый симулятор: $UDID (зафиксирован в .maestro/.device)"
fi

ALL_DEVICES="$(xcrun simctl list devices)"
DEVICE_LINE="$(echo "$ALL_DEVICES" | grep "$UDID" || true)"
if [[ "$DEVICE_LINE" == *"(Booted)"* ]]; then
  BOOT_STATE="Booted"
else
  BOOT_STATE="Shutdown"
fi
if [ "$BOOT_STATE" != "Booted" ]; then
  echo "бучу симулятор..."
  xcrun simctl boot "$UDID" 2>&1 | grep -v "Unable to boot device in current state: Booted" || true
  sleep 2
fi
echo "ок: симулятор забучен ($UDID)"

echo "--- Приложение ---"
APP_LIST="$(xcrun simctl listapps "$UDID" 2>/dev/null)"
if [[ "$APP_LIST" != *"\"$APP_ID\""* ]]; then
  fail "Приложение $APP_ID не установлено на $UDID. Собери и поставь dev-билд (напр. через Xcode или 'npx expo run:ios') — скил билдить сам не умеет, это отдельная дорогая операция."
fi
echo "ок: $APP_ID установлено"

echo "--- Metro ---"
METRO_WAS_UP=0
metro_up && METRO_WAS_UP=1

if [ "$METRO_WAS_UP" -eq 0 ] && [ -f "$METRO_PID_FILE" ]; then
  OLD_PID="$(cat "$METRO_PID_FILE" 2>/dev/null | tr -d '[:space:]')"
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    # Процесс жив, но /status ещё не ответил — даём секунду и проверяем снова
    # вместо того, чтобы сразу считать его мёртвым и плодить дубликат
    sleep 1
    metro_up && METRO_WAS_UP=1
  fi
fi

if [ "$METRO_WAS_UP" -eq 0 ]; then
  echo "Metro не поднят — запускаю в фоне (expo start --dev-client)..."
  (cd "$PROJECT_ROOT" && nohup npx expo start --dev-client > "$METRO_LOG_FILE" 2>&1 & echo $! > "$METRO_PID_FILE")
  for _ in $(seq 1 30); do
    sleep 1
    if metro_up; then
      METRO_WAS_UP=1
      break
    fi
  done
fi

if [ "$METRO_WAS_UP" -eq 0 ]; then
  echo "--- хвост $METRO_LOG_FILE ---" >&2
  tail -20 "$METRO_LOG_FILE" >&2 2>/dev/null || true
  fail "Metro не поднялся за 30 секунд — смотри $METRO_LOG_FILE"
fi
echo "ок: Metro отвечает на localhost:$METRO_PORT (PID $(cat "$METRO_PID_FILE" 2>/dev/null || echo '?'), детачен — следующий вызов его не тронет)"

echo
echo "Окружение готово."
echo "$UDID"
