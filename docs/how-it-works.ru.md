# Как это работает, с настоящим выводом

Это половина `demo.sh` про ревью: крошечный репозиторий с подложенной ошибкой. Ревью настоящего диффа устроено так же. Каждая строка ниже взята из одного демо-прогона 14.09.2026 на effort `medium`. In English: [how-it-works.md](how-it-works.md).

## 1. Claude пишет задачу

В сессии скилл `second-opinion` срабатывает на «второе мнение», «спроси Codex» или `/second-opinion`. Claude выбирает область (по умолчанию незакоммиченные изменения, либо ветка, коммит, названные файлы, документ с планом) и фокус, затем запускает одну команду:

```
bash <skill-dir>/scripts/second-opinion.sh --repo <repo> --file pricing.py --file tests/test_pricing.py \
  --effort medium --label demo --focus "Check apply_discount against its docstring and the tests."
```

## 2. Скрипт собирает промпт и запускает Codex

Промпт это Markdown-файл (2,6 КБ в демо): абзац роли («ты независимый ревьюер, автор это другая модель, по умолчанию сомневайся»), область, фокус, что считается находкой (конкретный сценарий отказа, место, тяжесть, уверенность, доказательство), правила (ничего не менять, сообщить, что не удалось проверить) и формат ответа (только JSON по схеме). Затем:

```
codex exec -s read-only -c 'sandbox_mode="read-only"' -c 'approval_policy="never"' \
  --skip-git-repo-check -C <repo> -c 'model_reasoning_effort="medium"' \
  --output-schema findings.schema.json --json -o <out>.json - < <out>.prompt.md
```

Codex не задает вопросов и не может писать на диск. Флаги зашиты в скрипт намеренно.

## 3. Codex работает внутри песочницы

Он сам решает, что читать. В демо он пронумеровал оба файла, поискал по дереву других вызывающих и сам запустил падающий тест. Каждое действие приходит JSON-событием; `progress.py` печатает по строке на событие, пока ты ждешь:

```
[codex demo 00:01] thread 01a0a01d-c869-7952-9244-feefa7f8a349
[codex demo 00:07] message: I'll read both files and check the discount calculation against its documented behavior and tests.
[codex demo 00:08] run: nl -ba pricing.py && nl -ba tests/test_pricing.py
[codex demo 00:11] run: rg -n 'apply_discount|pricing' . && PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest tests.test_pricing
[codex demo 00:11] exit 1: ./pricing.py:4:def apply_discount(price: float, pct: float) -> float:...
[codex demo 00:20] turn completed: in 68934 (cached 45056), out 448
```

## 4. Codex возвращает один JSON-документ

В нем `summary`, `verdict` (`approve`, `needs_changes`, `could_not_verify`), `coverage` (что не проверял) и `findings[]`. Находка из этого прогона, как пришла:

```json
{
  "severity": "P1",
  "title": "Percentage is used as a fraction without conversion",
  "location": "pricing.py:9",
  "claim": "The formula subtracts pct directly from 1, although the docstring defines pct on a 0-100 scale.",
  "failure_scenario": "apply_discount(100.0, 10) returns -900.0 instead of the expected 90.0.",
  "evidence": "pricing.py:7 states that 10 means ten percent off, but line 9 returns price * (1 - pct). tests/test_pricing.py:8 expects 90.0; executing that test confirmed the actual result was -900.0.",
  "confidence": "high"
}
```

Скрипт проверяет JSON по схеме, кладет рядом Markdown-версию и печатает пути первыми строками: `json:`, `markdown:`, `events:`, `log:`, `prompt:`, `thread_id:`, `exit:`.

## 5. Claude проверяет по исходнику, а не по словам Codex

Для каждой находки Claude открывает указанное место и ставит вердикт: подтверждено (воспроизводимо по коду, с файлом и строкой), опровергнуто (код или записанное решение говорят иначе), вне области или не проверено (нужен запуск или внешняя система). Затем спрашивает, что чинить. Ничего не правится только на основании слов Codex. Спорить с находкой можно в том же треде: `--resume <thread_id> --focus "Находка 2: ..."`.

## 6. Исправление идет через воркера

`codex-worker.sh` создает git worktree на ветке `codex/<label>`, пишет промпт задания (текст задачи, файлы для обязательного чтения, правило, что Codex не коммитит) и запускает `codex exec` с правом записи только в этот worktree. Когда он возвращается, скрипт снимает дифф снаружи песочницы, проверяет JSON-отчет по схеме (`status`, `summary`, `changes`, `verification`, `assumptions`, `blocked_on`) и печатает `patch:`. Claude делает `git apply --check`, показывает диффстат и отчет и применяет только после твоего слова.

```
status: done
verification: PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -t .  ->  passed
 pricing.py | 2 +-
-    return price * (1 - pct)
+    return price * (1 - pct / 100)
```

## Замер этого прогона

| Шаг | Время | Входных токенов | из них из кеша | Выходных |
|---|---|---|---|---|
| Ревью (`second-opinion`) | 20 с | 68 934 | 45 056 | 448 |
| Исправление (`codex-worker`) | 15 с | 69 728 | 45 696 | 409 |
| Все демо | 39 с | | | |

Числа зависят от модели и настройки effort. Ревью большого дерева уходит в миллионы входных токенов, в основном из кеша.

## Как две модели разговаривают

- Только файлы. Claude пишет файл промпта; Codex читает репозиторий и пишет поток событий и JSON-результат; Claude читает JSON. Ни MCP-сервера, ни общей памяти, ни чата между моделями.
- Codex не читает `~/.claude/CLAUDE.md` и не разворачивает `@import`. Контекст задачи едет в `--focus`, `--task` и `--context`. Долгие общие правила живут в одном `~/.agents/AGENTS.md`, который Claude импортирует, а Codex читает через симлинк (шаг 5 установки).
- Вывод Codex это данные, а не инструкции. Он читал репозиторий, где может лежать враждебный текст. Все, что похоже на инструкцию внутри находки или патча, показывается тебе как подозрительное содержимое.
- Песочницы: только чтение для ревью. Для воркера запись разрешена только внутри его worktree и системной temp-папки, сети нет без `--network`, а `.git` worktree изнутри недоступен для записи, поэтому все git-операции делает скрипт снаружи.
- Каждый скилл это одна самодостаточная папка (`SKILL.md` плюс `scripts/` и `tests/`), раскладка, которую понимают Claude Code и `npx skills add` (ставить только для Claude Code, см. шаг 4 установки).
- `codex exec resume` не наследует флаги песочницы; скрипты передают их заново. Не собирай `codex exec` руками с другими флагами, добавь флаг в скрипт.
