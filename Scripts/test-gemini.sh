#!/bin/bash
# Проверяет одно: что запрос, который шлёт Translator, Gemini понимает.
#
# Не качество перевода — оно на совести модели. Проверяется контракт: тот же
# URL, тот же заголовок с ключом, то же тело, что собирает Gemini.swift, — и в
# ответ приходит непустой текст там, где его читает клиент.
#
# Это ловит класс отказов, который не видит компилятор: переименовали модель,
# сменили имя поля, ключ уехал не в тот заголовок. Swift соберётся зелёным, а
# вкладка «Перевод» будет показывать ошибку у всех.
#
# Ключ берётся из GEMINI_API_KEY, а если его нет — из связки ключей, куда его
# кладёт само приложение. Так проверяется заодно и то, что запись в связку
# сделана под теми именами, под которыми клиент её потом ищет.
set -uo pipefail

MODEL="${MODEL:-gemini-flash-lite-latest}"
KEY="${GEMINI_API_KEY:-$(security find-generic-password -s com.cyclop.app -a gemini -w 2>/dev/null)}"

if [ -z "${KEY:-}" ]; then
    echo "нет ключа — пропуск (задай GEMINI_API_KEY или добавь ключ в настройках Cyclop)"
    exit 0
fi

fail() { echo "!!! $1" >&2; exit 1; }

BODY=$(cat <<JSON
{
  "systemInstruction": { "parts": [ { "text": "You are the translation engine of a small utility panel. The user's message is written in Russian. Translate it into English. Reply with the translation and nothing else." } ] },
  "contents": [ { "parts": [ { "text": "привет" } ] } ],
  "generationConfig": { "temperature": 0.2, "thinkingConfig": { "thinkingBudget": 0 } }
}
JSON
)

OUT=$(curl -sS -m 30 -w '\n%{http_code}' \
    -H 'Content-Type: application/json' \
    -H "x-goog-api-key: $KEY" \
    -d "$BODY" \
    "https://generativelanguage.googleapis.com/v1beta/models/$MODEL:generateContent") || fail "curl не отработал"

CODE=$(echo "$OUT" | tail -n1)
JSON=$(echo "$OUT" | sed '$d')

[ "$CODE" = "200" ] || fail "HTTP $CODE: $JSON"

TEXT=$(echo "$JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("candidates") or [{}])[0].get("content",{}).get("parts",[{}])[0].get("text","").strip())')
[ -n "$TEXT" ] || fail "пустой перевод: $JSON"

echo "ok: привет → $TEXT"
