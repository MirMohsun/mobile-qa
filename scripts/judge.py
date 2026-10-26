# -*- coding: utf-8 -*-
"""Судья находки Maestro-прогона: решает, что падение шага значит и что с
ним делать. Перенесено из qa-audit (qa_audit/judge.py) почти без изменений —
разделение работ то же: прогон находит факт (какой шаг упал, на чём),
судья выносит суждение. Смешивать нельзя: как только прогон начинает
рассуждать сам, он начинает выдумывать причины.

Свод правил — rules/judge-rules.md, печатается тут же для контекста модели.

Судья необязателен. Нет ключа (MOBILE_QA_JUDGE_KEY), нет сети, не ответил —
результат всё равно отдаётся, просто без разбора. Условием выдачи он не
становится никогда.
"""

import base64
import json
import os
import re
import sys
import urllib.request

PROMPT = """Ты судья находки Maestro E2E-прогона мобильного приложения. Прогон нашёл факт:
какой шаг упал (tapOn/assertVisible/inputText/...), на каком селекторе, что видно на
скриншоте. Твоя работа: решить, что это значит и что делать. Правила:
1. Флейк окружения — не баг приложения: служебный диалог dev-client (онбординг,
   push-permission), гонка анимации, таймаут сети при первой загрузке — это «мало данных»
   или «ложная», если видно по скриншоту, что приложение само по себе в порядке.
2. Смотри на скриншот, а не только на текст ошибки: "assertVisible failed" на экране,
   где элемент просто не успел отрисоваться — другое дело, чем элемент, которого там
   вообще никогда не будет.
3. Проверка, приложенная не туда (устаревший testID, экран сменил вёрстку) — «ложная»,
   и скажи, что проверке нужно обновление, а не что в приложении баг.
4. Не придумывай того, чего не видишь. Нет скриншота и мало описания — «мало данных»,
   это честный ответ, а не слабость.
5. Поломка важнее флейка: пустой экран, исключение в логе, кнопка без реакции на
   повторных попытках — «подтверждаю». Разовый сетевой таймбаут — скорее «мало данных».
Кода не правь, тесты не переписывай, команд не давай.

Ответь ровно тремя строками, без заголовков и списков:
РЕШЕНИЕ: ровно одно слово из трёх — подтверждаю, ложная, мало данных. Других слов нет
ПОЧЕМУ: одна строка — довод, а не пересказ находки
СДЕЛАТЬ: конкретное действие (обновить селектор, добавить ожидание, завести баг-репорт)"""


def one_body(finding):
    """Что уходит судье по одной находке: шаг, селектор, контекст."""
    lines = [f"Находка: {finding}"]
    return "\n".join(lines)


def parse(text):
    """Разбор ответа. Что не разобралось — не выдумываем: пустое так и остаётся."""
    t = str(text or "")

    def pick(key):
        m = re.search(key + r"\s*:?\s*(.+)", t)
        return m.group(1).strip().strip('«»"\'')[:300] if m else ""

    raw = pick("РЕШЕНИЕ").lower()
    verdict = (
        "подтверждаю" if "подтвержд" in raw
        else "ложная" if "ложн" in raw
        else "мало данных" if "мало" in raw
        else ""
    )
    return {"verdict": verdict, "why": pick("ПОЧЕМУ"), "fix": pick("СДЕЛАТЬ")}


def ask(url, model, key, body, image=None, timeout=120):
    content = body
    if image:
        content = [
            {"type": "text", "text": body},
            {
                "type": "image_url",
                "image_url": {"url": "data:image/png;base64," + base64.b64encode(image).decode()},
            },
        ]
    payload = {
        "model": model or "gpt-4o-mini",
        "temperature": 0.2,
        "messages": [{"role": "system", "content": PROMPT}, {"role": "user", "content": content}],
    }
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "content-type": "application/json",
            **({"authorization": f"Bearer {key}"} if key else {}),
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            d = json.loads(r.read())
        text = (((d.get("choices") or [{}])[0].get("message") or {}).get("content") or "").strip()
        return {"text": text} if text else {"error": "судья ответил пусто"}
    except Exception as e:
        return {"error": f"судья недоступен: {type(e).__name__}"}


RETRY = (
    "Ответь одной строкой: РЕШЕНИЕ: подтверждаю, либо РЕШЕНИЕ: ложная, "
    "либо РЕШЕНИЕ: мало данных. Больше ничего не пиши."
)


def judge_finding(finding, image_path=None):
    """Разобрать одну находку. Возвращает решение или сообщение об ошибке."""
    url = os.environ.get("MOBILE_QA_JUDGE_URL", "")
    key = os.environ.get("MOBILE_QA_JUDGE_KEY", "")
    model = os.environ.get("MOBILE_QA_JUDGE_MODEL", "")

    if not url or not key:
        return {"skipped": True, "reason": "MOBILE_QA_JUDGE_URL/MOBILE_QA_JUDGE_KEY не заданы — разбор пропущен"}

    image = None
    if image_path and os.path.isfile(image_path):
        with open(image_path, "rb") as f:
            image = f.read()

    body = one_body(finding)
    r = ask(url, model, key, body, image=image)
    if "error" in r:
        return {"skipped": True, "reason": r["error"]}

    got = parse(r.get("text", ""))
    if not got["verdict"]:
        again = ask(url, model, key, body + "\n\n" + RETRY, timeout=60)
        second = parse(again.get("text", ""))
        if second["verdict"]:
            got["verdict"] = second["verdict"]
    return got


if __name__ == "__main__":
    finding_arg = sys.argv[1] if len(sys.argv) > 1 else ""
    image_arg = sys.argv[2] if len(sys.argv) > 2 else None
    if not finding_arg:
        print("Использование: judge.py \"<находка>\" [путь-к-скриншоту]", file=sys.stderr)
        sys.exit(3)
    result = judge_finding(finding_arg, image_arg)
    print(json.dumps(result, ensure_ascii=False, indent=2))
