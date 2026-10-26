#!/usr/bin/env bash
# Полная диагностика окружения mobile-qa на свежей машине: проверяет ВСЁ
# сразу (не останавливается на первой проблеме, как ensure-env.sh), чтобы
# агент видел целиком, чего не хватает, а не играл в "выбей крота" —
# почини одно, запусти заново, упади на следующем.
#
# Ничего не устанавливает и не меняет — только читает и печатает рецепт.
# Рецепты ниже проверены вручную в этой же сессии (включая реальный
# инцидент: `brew install maestro` без --formula подхватил чужой каск
# "AI agent command center" с тем же именем — рецепт это учитывает).
#
# Запуск: .claude/skills/mobile-qa/scripts/doctor.sh
# Код возврата: 0 — всё готово, 1 — есть хотя бы одна проблема.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
MAESTRO_DIR="$PROJECT_ROOT/.maestro"
PROBLEMS=0

ok() { echo "  ✅ $1"; }
# $2 (опционально): "agent" — агент может предложить и выполнить сам после
# согласия человека; "manual" (по умолчанию) — GUI/лицензия/человеческий
# ввод, агент физически не пройдёт, даже с согласием
bad() {
  local tag="${2:-manual}"
  if [ "$tag" = "agent" ]; then
    echo "  ❌ [агент может починить с согласия] $1"
  else
    echo "  ❌ [только вручную] $1"
  fi
  PROBLEMS=$((PROBLEMS + 1))
}

echo "=== mobile-qa doctor: $PROJECT_ROOT ==="
echo

echo "--- Инструменты ---"
if command -v brew >/dev/null 2>&1; then
  ok "Homebrew установлен"
else
  bad "Homebrew не установлен. Рецепт: https://brew.sh (официальный однострочник) — это первое, что нужно вообще для чего-либо ниже на macOS." manual
fi

if xcode-select -p >/dev/null 2>&1; then
  ok "Xcode Command Line Tools установлены ($(xcode-select -p))"
else
  bad "Xcode Command Line Tools не установлены. Рецепт: 'xcode-select --install' — спросит подтверждение в системном GUI-диалоге, агент физически не кликнет по нему, даже с согласия." manual
fi

if command -v maestro >/dev/null 2>&1; then
  ok "Maestro CLI установлен ($(maestro --version 2>&1 | tail -1))"
else
  bad "Maestro CLI не установлен. Рецепт (проверено на практике сегодня):
       brew tap mobile-dev-inc/tap
       brew trust mobile-dev-inc/tap   # Homebrew откажется ставить из недоверенного тапа без этого
       brew install --formula mobile-dev-inc/tap/maestro
     ВАЖНО: 'brew install maestro' БЕЗ --formula подхватывает ЧУЖОЙ каск с тем же
     именем ('AI agent command center' от runmaestro.ai, вообще не то) — обязательно
     --formula mobile-dev-inc/tap/maestro, не короткое имя." agent
fi

echo
echo "--- iOS-симулятор ---"
AVAILABLE="$(xcrun simctl list devices available 2>/dev/null)"
if [[ "$AVAILABLE" == *"iPhone"* ]]; then
  FIRST_IPHONE="$(echo "$AVAILABLE" | grep -E '^[[:space:]]+iPhone' | head -1 | sed -E 's/^[[:space:]]+//; s/[[:space:]]+\(.*//')"
  ok "Хотя бы один iPhone-симулятор доступен ($FIRST_IPHONE)"
else
  bad "Ни одного iPhone-симулятора не найдено. Рецепт: открой Xcode → Settings → Platforms → добавь рантайм iOS (несколько GB, долгая загрузка, лицензионное согласие в самом Xcode) — агент не может ни скачать, ни согласиться с лицензией за человека." manual
fi

echo
echo "--- Node-зависимости проекта ---"
if command -v node >/dev/null 2>&1; then
  ok "node установлен ($(node --version))"
else
  bad "node не установлен. Рецепт: brew install node, либо nvm/volta — на усмотрение команды, скил не навязывает менеджер версий." agent
fi
if [ -d "$PROJECT_ROOT/node_modules" ]; then
  ok "node_modules есть (зависимости проекта установлены)"
else
  bad "node_modules нет. Рецепт: 'pnpm install' из корня проекта (см. package.json/pnpm-workspace.yaml) — без этого 'expo start' не запустится вовсе." agent
fi

echo
echo "--- Конфиг проекта для mobile-qa ---"
if [ -f "$MAESTRO_DIR/config.json" ]; then
  ok ".maestro/config.json есть"
else
  bad ".maestro/config.json нет. Не секрет, заводится один раз и коммитится: {\"appId\": \"<bundle id>\", \"devClientScheme\": \"<expo-scheme>\", \"metroPort\": 8081}. Агент может сам прочитать bundle id/scheme из app.config.ts или app.json проекта и предложить готовый файл." agent
fi
if [ -f "$MAESTRO_DIR/.env" ]; then
  ok ".maestro/.env есть (тестовый OTP/учётка для флоу логина)"
else
  echo "  ⚠️  .maestro/.env нет — не блокер сам по себе (не каждый флоу требует логин), но любой флоу с OTP-обходом работать не будет. Не секрет для коммита, но и не обязателен — заводится только если у бэкенда есть dev-обход логина."
fi

echo
if [ "$PROBLEMS" -eq 0 ]; then
  echo "Всё готово — можно звать scripts/ensure-env.sh."
  exit 0
else
  echo "Проблем: $PROBLEMS. По одной, сверху вниз (некоторые зависят от предыдущих): [агент может починить с согласия] — предложи рецепт человеку, выполни сам после «да»; [только вручную] — человек делает это сам, агент не пройдёт GUI/лицензию. После каждой починки перезапусти doctor.sh, не чини следующий пункт вслепую."
  exit 1
fi
