# mobile-qa — Maestro E2E для Claude Code

Claude Code skill: пишет, запускает и честно читает Maestro E2E-флоу для
мобильных Expo/React Native проектов (iOS Simulator). Не пакет для `pip`/
`brew` — набор bash-скриптов и `SKILL.md`, который кладётся прямо в
`.claude/skills/` целевого проекта.

Родился при работе над одним Expo-проектом, выделен в отдельный репозиторий,
чтобы ставиться на любой другой — без переноса файлов вручную.

## Установка

**Требует macOS** (Homebrew, Xcode, `xcrun simctl`) — это скил под iOS
Simulator, не Android/Linux/Windows.

### Через npm/pnpm (рекомендую — большинство Expo/RN проектов уже на нём)

```bash
npm install --save-dev git+https://github.com/MirMohsun/mobile-qa.git
# или: pnpm add -D git+https://github.com/MirMohsun/mobile-qa.git
```

`postinstall` сам копирует `SKILL.md`/`rules/`/`scripts/`/`examples/` в
`.claude/skills/mobile-qa/` проекта и выставляет `+x` на скрипты — npm/pnpm
не знают про `.claude/skills/`, одной установки пакета недостаточно без
этого шага. Повторная установка перезаписывает папку целиком (как
`git pull`, не слияние).

**pnpm может заблокировать `postinstall`** сторонних пакетов по умолчанию
(hardening). Если установка прошла, а `.claude/skills/mobile-qa/` не
появилась — `pnpm approve-builds mobile-qa`, затем `pnpm install` заново.

### Через git submodule (если нужна явная версионированная git-ссылка)

```bash
git submodule add https://github.com/MirMohsun/mobile-qa.git .claude/skills/mobile-qa
git submodule update --init --recursive   # нужно после каждого клонирования родительского репо
```

**Не делай `git clone` прямо в `.claude/skills/mobile-qa` внутри уже
существующего git-репозитория.** Git создаст "embedded repository" —
отдельную ссылку вместо реальных файлов; `git add` на родительском репо
закоммитит нерабочую ссылку, а не содержимое скила, и об этом даже не будет
предупреждения при `git status`, только при первом `git add` (сам git
предупредит "adding embedded git repository" — это и есть сигнал, что
что-то пошло не так, не игнорируй его). Для разовой непривязанной копии
без мусора в `.git/` — склонируй во временную папку и скопируй файлы
руками, не клонируй прямо в целевой путь.

## Первым делом — доктор, не самопроверка

```bash
.claude/skills/mobile-qa/scripts/doctor.sh
```

Читает всё окружение разом (Homebrew, Xcode Command Line Tools, Maestro,
доступный iOS-симулятор, node, `node_modules`, `.maestro/config.json`,
`.maestro/.env`) и печатает рецепт на каждую проблему. Ничего не
устанавливает сам — только показывает, что́ сделать, и кто это должен
сделать:

- `[агент может починить с согласия]` — Maestro, node, `pnpm install`,
  `.maestro/config.json`. Чисто CLI, без `sudo` и GUI — агент может
  предложить рецепт и выполнить после явного «да» человека.
- `[только вручную]` — Homebrew, Xcode CLT, рантайм iOS-симулятора.
  Системные GUI-диалоги, пароли, лицензионные соглашения — агент
  физически не пройдёт их, даже с согласия.

## Настройка под конкретный проект

Скил не хардкодит `appId` — заведи `.maestro/config.json` в целевом
проекте (не секрет, коммитится):

```bash
cp examples/config.json.example <путь-к-проекту>/.maestro/config.json
# и отредактируй appId/devClientScheme под реальный bundle id и Expo-схему
```

Если у бэкенда есть dev-обход логина (тестовый номер + фиксированный
OTP), заведи ещё `.maestro/.env` (gitignored, это уже секрет):

```bash
TEST_PHONE_NATIONAL=...
TEST_OTP=...
```

## Порядок работы

```bash
.claude/skills/mobile-qa/scripts/ensure-env.sh         # поднимает симулятор + Metro
.claude/skills/mobile-qa/scripts/selftest.sh           # канонический набор .maestro/*.yaml
.claude/skills/mobile-qa/scripts/run.sh <flow.yaml>    # один целевой флоу
.claude/skills/mobile-qa/scripts/report.sh <junit.xml> # находки → .maestro/reports/*.md
.claude/skills/mobile-qa/scripts/judge.sh "<находка>"  # узкий судья без доступа к коду (см. ниже)
```

Полная дисциплина — в [SKILL.md](SKILL.md): самопроверка перед прогоном,
коды возврата 0–3, три тега (`destructive`/`needs-fixture`/`subflow`),
автоматические отчёты по падениям, два судьи (агент с доступом к коду —
основной; `judge.py` без кода — узкий fallback для прогонов без живого
агента, например в CI).

`judge.py`/`judge.sh` берут три переменные окружения, не аргументы команды
(ключ в истории шелла — риск): `MOBILE_QA_JUDGE_URL` (обязателен, адрес
OpenAI-совместимого API), `MOBILE_QA_JUDGE_KEY` (обязателен), опционально
`MOBILE_QA_JUDGE_MODEL`. Задан только `KEY` без `URL` — судья молча
пропускается с причиной "не заданы", не ошибкой; проверь оба, если
результат неожиданно без разбора.

## Что переносится на другой проект, а что нет

Зафиксировано в [`rules/skill.json`](rules/skill.json#L10) (`portability`):
скрипты и дисциплина не знают про конкретный проект, но dev-client-
оверлеи, поведение Keychain/`clearState` и "локаль на аккаунте, а не на
симуляторе" — это факты про Expo + iOS Simulator, проверенные на одном
реальном проекте. Для другого стека (bare RN, Android-first, Flutter,
нативный iOS без Expo) их нужно переоткрыть заново, не копировать вслепую.

## Чего скил не умеет

- `design-audit` (сверка экрана с Figma-макетом) — не реализован, нет
  доступа к Figma MCP и эталонной пары экранов.
- Не заводит задачи в трекер по находкам — осознанно отложено.
- Не билдит и не ставит приложение на симулятор — это отдельная дорогая
  операция, `ensure-env.sh` ожидает уже собранный dev-клиент.
- Не проверяет содержимое WebView вглубь, не умеет нативные пикеры/
  share-sheet/внешние deep links — см. `limits` в `rules/skill.json`.
