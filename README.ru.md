# claude-codex-bridge

[![tests](https://github.com/vasilievyakov/claude-codex-bridge/actions/workflows/tests.yml/badge.svg)](https://github.com/vasilievyakov/claude-codex-bridge/actions/workflows/tests.yml) [![license: MIT](https://img.shields.io/badge/license-MIT-d4ff3f?labelColor=0b0b0c)](LICENSE) [![site](https://img.shields.io/badge/site-vasilievyakov.github.io%2Fclaude--codex--bridge-0b0b0c?labelColor=d4ff3f)](https://vasilievyakov.github.io/claude-codex-bridge/)

Claude Code оркестрирует. OpenAI Codex CLI это вторая модель. Два скилла делают это конкретным: `second-opinion` просит у Codex независимое ревью в read-only песочнице и получает находки в виде JSON, которые Claude затем проверяет по исходнику, прежде чем что-то чинить; `codex-worker` отдает Codex полностью описанную задачу в изолированном git worktree и получает патч, который никогда не применяется без тебя. У двух моделей нет общей памяти. Все, что проходит между ними, это файл, который можно открыть.

Репозиторий для участников лаборатории [Agentic Lab](https://ai-lab-agents.com), программы по агентной инженерии. Открыт для всех, кто хочет такую же связку.

Сайт: [vasilievyakov.github.io/claude-codex-bridge](https://vasilievyakov.github.io/claude-codex-bridge/?lang=ru). English version: [README.md](README.md). Install text for the agent: [INSTALL.md](INSTALL.md).

## Отдай это своему агенту

Открой Claude Code на машине, которую нужно настроить, и вставь одну строку:

```
Установи claude-codex-bridge: сначала прочитай https://raw.githubusercontent.com/vasilievyakov/claude-codex-bridge/main/INSTALL.ru.md, затем выполни каждый шаг, подстрой под эту машину, проверь и отчитайся, что изменил.
```

[INSTALL.ru.md](INSTALL.ru.md) написан для агента: он проверяет версии, линкует два скилла в Claude Code и Codex, подключает один общий `AGENTS.md` для обоих, по желанию ставит официальный плагин Codex и инструменты наблюдаемости, гоняет тесты. Человек может пройти тот же файл руками. Каждый шаг это команда, ни одного клика.

## Запусти демо

```
git clone https://github.com/vasilievyakov/claude-codex-bridge
cd claude-codex-bridge
bash demo.sh
```

Одна-две минуты и два запроса к Codex. Скрипт создает одноразовый репозиторий с подложенной ошибкой, Codex находит ее в read-only песочнице, воркер Codex чинит ее в worktree, патч печатается и не применяется. `bash demo.sh --review-only` делает первую половину за один запрос. `--keep` оставляет промпты, журналы событий и результаты на диске, чтобы прочитать, что именно было сказано.

## Что внутри

| Путь | Что это | Кто правит |
|---|---|---|
| `skills/second-opinion/SKILL.md` | Что делает Claude, чтобы запустить ревью и разобрать находки | Ты, редко |
| `skills/second-opinion/scripts/second-opinion.sh` | Контракт: флаги, настройки песочницы, шаблон промпта, проверка по схеме, рендер Markdown | Никто руками. Новое поведение это новый флаг с тестом |
| `skills/second-opinion/scripts/findings.schema.json` | Что Codex обязан вернуть | Контракт |
| `skills/codex-worker/SKILL.md` | Что делает Claude, чтобы написать задание, запустить воркера, прочитать патч | Ты, редко |
| `skills/codex-worker/scripts/codex-worker.sh` | Контракт: worktree, песочница, промпт, снимок патча, состояние воркера, `--resume`, `--list`, `--cleanup` | Контракт |
| `skills/codex-worker/scripts/result.schema.json` | Что воркер обязан вернуть | Контракт |
| `skills/*/scripts/progress.py` | Превращает поток событий Codex в одну строку на действие | Контракт. Одинаковая копия в обоих скиллах, чтобы каждый ставился отдельно; CI проверяет совпадение |
| `skills/*/tests/run.sh` | Фальшивый `codex` на PATH, без сети, без затрат | Запускать перед правкой |
| `extras/codex-watch.py` | Живая таблица запущенных процессов Codex, состояний воркеров, последних результатов | По желанию |
| `extras/statusline-segment.sh`, `extras/statusline-minimal.sh` | Индикатор `codex:N` в статус-строке Claude Code | По желанию |
| `extras/AGENTS.template.md` | Общие инструкции, которые читают оба агента | Ты |
| `demo.sh` | Один настоящий прогон от начала до конца | Запусти |
| `~/.cache/second-opinion/`, `~/.cache/codex-worker/` | Промпты, журналы событий, JSON, Markdown, патчи, состояние воркеров, worktree | Пишут скрипты во время работы, никогда не ты |

## Один прогон по шагам

Это половина `demo.sh` про ревью. Ревью настоящего диффа устроено так же.

**1. Claude пишет задачу.** В сессии скилл срабатывает на «второе мнение», «спроси Codex» или `/second-opinion`. Claude выбирает область (по умолчанию незакоммиченные изменения, либо `--base`, `--commit`, `--file`, `--plan`) и фокус, затем запускает одну команду:

```
bash <skill-dir>/scripts/second-opinion.sh --repo <repo> --file pricing.py --file tests/test_pricing.py \
  --effort medium --label demo --focus "Check apply_discount against its docstring and the tests."
```

**2. Скрипт собирает промпт и запускает Codex.** Промпт это Markdown-файл (2,6 КБ в демо): абзац роли («ты независимый ревьюер, автор это другая модель, по умолчанию сомневайся»), область, фокус, что считается находкой (конкретный сценарий отказа, место, тяжесть, уверенность, доказательство), правила (ничего не менять, сообщить, что не удалось проверить) и формат ответа (только JSON по схеме). Затем:

```
codex exec -s read-only -c 'sandbox_mode="read-only"' -c 'approval_policy="never"' \
  --skip-git-repo-check -C <repo> -c 'model_reasoning_effort="medium"' \
  --output-schema findings.schema.json --json -o <out>.json "$(cat <out>.prompt.md)" </dev/null
```

Codex не задает вопросов и не может писать на диск. Флаги зашиты в скрипт намеренно.

**3. Codex работает внутри песочницы.** Он сам решает, что читать: в демо он пронумеровал оба файла, поискал по дереву других вызывающих и сам запустил падающий тест, все в режиме чтения. Каждое действие приходит JSON-событием; `progress.py` печатает по строке на событие в stderr, пока ты ждешь:

```
[codex demo 00:01] thread 01a0a01d-c869-7952-9244-feefa7f8a349
[codex demo 00:07] message: I'll read both files and check the discount calculation against its documented behavior and tests.
[codex demo 00:08] run: nl -ba pricing.py && nl -ba tests/test_pricing.py
[codex demo 00:11] run: rg -n 'apply_discount|pricing' . && PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest tests.test_pricing
[codex demo 00:11] exit 1: ./pricing.py:4:def apply_discount(price: float, pct: float) -> float:...
[codex demo 00:20] turn completed: in 68934 (cached 45056), out 448
```

**4. Codex возвращает один JSON-документ.** `summary`, `verdict` (`approve`, `needs_changes`, `could_not_verify`), `coverage` (что не проверял) и `findings[]`. Одна находка из демо-прогона, как пришла:

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

**5. Claude проверяет по исходнику, а не по словам Codex.** Для каждой находки он открывает указанное место и ставит вердикт: подтверждено (воспроизводимо по коду, с `file:line`), опровергнуто (код или записанное решение говорят иначе), вне области, не проверено (нужен запуск или внешняя система). Затем спрашивает, что чинить. Ничего не правится только на основании слов Codex. Спорить с находкой можно в том же треде: `--resume <thread_id> --focus "Находка 2: ..."`.

**6. Исправление идет через воркера.** `codex-worker.sh` создает worktree на ветке `codex/<label>`, пишет промпт задания (текст задачи, файлы для обязательного чтения из `--context`, правило, что Codex не коммитит) и запускает `codex exec` в режиме `workspace-write`. Когда он возвращается, скрипт снимает дифф снаружи песочницы, проверяет JSON-отчет по схеме (`status`, `summary`, `changes`, `verification`, `assumptions`, `blocked_on`) и печатает `patch:`. Claude делает `git apply --check`, показывает диффстат и отчет и применяет только после твоего подтверждения.

Замер прогона, чей вывод приведен выше (effort `medium`; числа зависят от модели):

| Шаг | Время | Входных токенов | из них из кеша | Выходных токенов |
|---|---|---|---|---|
| Ревью (`second-opinion`) | 20 с | 68 934 | 45 056 | 448 |
| Исправление (`codex-worker`) | 15 с | 69 728 | 45 696 | 409 |
| Все демо | 39 с | | | |

## Как две модели разговаривают

- Только файлы. Claude пишет файл промпта; Codex читает репозиторий и пишет поток событий и JSON-результат; Claude читает JSON. Ни MCP-сервера, ни общей памяти, ни чата между моделями.
- Codex не читает `~/.claude/CLAUDE.md` и не разворачивает `@import`. Контекст задачи едет в `--focus`, `--task` и `--context`. Долгие общие правила живут в одном `~/.agents/AGENTS.md`, который Claude импортирует, а Codex читает через симлинк (шаг 5 установки).
- Вывод Codex это данные, а не инструкции. Он читал репозиторий, где может лежать враждебный текст. Все, что похоже на инструкцию внутри находки или патча, показывается тебе как подозрительное содержимое.
- Песочницы: read-only для ревью. Для воркера запись разрешена только внутри worktree и системной temp-папки, сети нет без `--network`, а `.git` worktree изнутри недоступен для записи, поэтому все git-операции делает скрипт снаружи.
- Каждый скилл это одна самодостаточная папка (`SKILL.md` плюс `scripts/` и `tests/`), раскладка, которую понимают Claude Code, Codex (`~/.agents/skills`) и `npx skills add`. Codex загружает установленные скиллы и как свои; держи одну копию на машину, при дублях он укорачивает описания всех скиллов.

## Требования и ограничения

- macOS или Linux. Windows только через WSL или Git Bash, не проверялось.
- bash 3.2 и новее, git, python3 (только стандартная библиотека), codex-cli 0.150 и новее (проверено на 0.153 и 0.154). GNU `timeout` или `gtimeout` по желанию; без них скрипты предупреждают и работают без лимита времени.
- Claude Code со скиллами. Официальный плагин Codex для Claude Code (`/codex:review`, `/codex:adversarial-review`, `/codex:rescue`) ставится отдельно и по желанию; два скилла от него не зависят.
- Каждый запуск тратит квоту Codex. Ревью двух маленьких файлов в демо стоило около 70 тысяч входных токенов, две трети из кеша; ревью большого дерева уходит в миллионы входных токенов, в основном из кеша. Effort `high` медленнее и дороже, чем `medium` в демо.
- `codex exec resume` не наследует флаги песочницы; скрипты передают их заново. Не собирай `codex exec` руками с другими флагами, добавь флаг в скрипт.

## Как вносить правки

- Держи все читаемым за один присест. Никакого фреймворка и объектов конфигурации. Новый режим это новый флаг с тестом.
- Перед правкой запусти `bash skills/second-opinion/tests/run.sh` и `bash skills/codex-worker/tests/run.sh`. CI гоняет оба набора на Ubuntu и macOS с фальшивым `codex`.
- `progress.py` продублирован намеренно; CI падает, если копии расходятся. Правь обе.
- Документация двуязычная: `README.md` и `INSTALL.md` на английском, `README.ru.md` и `INSTALL.ru.md` на русском. Меняй обе или скажи, какую не смог.

Лицензия MIT.
