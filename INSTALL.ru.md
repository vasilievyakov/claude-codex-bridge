# Установка: текст для твоего агента

Этот файл написан для агента, а не для shell. Открой Claude Code (или Codex) на машине, которую нужно настроить, и вставь все, что ниже черты. Агент прочитает окружение, подстроит шаги, проверит каждый и отчитается. Человек может пройти те же шаги руками: каждый шаг это команда, ни одного клика.

---

Ты устанавливаешь **claude-codex-bridge**: два скилла (`second-opinion`, `codex-worker`), которые дают Claude Code использовать OpenAI Codex CLI как вторую модель, плюс необязательные инструменты наблюдаемости. Иди по шагам по порядку. Пути подстраивай под эту машину. Перед правкой любого существующего конфига скопируй его в `<файл>.bak-<ГГГГММДД>`. Никогда не удаляй и не перезаписывай файлы пользователя. Если шаг требует решения (например, у пользователя уже есть статус-строка), спроси. В конце выведи сводку: что изменил и что проверил.

## 1. Предусловия

Проверь и сообщи версии:

```
claude --version
codex --version        # нужен codex-cli 0.153 или новее; 0.150+ должен работать
git --version
python3 --version
```

Если `codex` нет: `npm i -g @openai/codex` (Node 18+) или `brew install codex`. Затем `codex login`, если `codex login status` говорит, что вход не выполнен. Если нет `timeout` (чистый macOS), предложи `brew install coreutils`; скрипты работают и без него, но тогда без лимита времени.

## 2. Получи репозиторий

```
git clone https://github.com/vasilievyakov/claude-codex-bridge ~/claude-codex-bridge
```

Если репозиторий уже на диске, используй этот путь и пропусти clone. Ниже этот путь называется `$BRIDGE`.

## 3. Поставь скиллы для Claude Code

Уровень пользователя (все проекты):

```
mkdir -p ~/.claude/skills
ln -s "$BRIDGE/skills/second-opinion" ~/.claude/skills/second-opinion
ln -s "$BRIDGE/skills/codex-worker" ~/.claude/skills/codex-worker
```

Симлинки обновляются вместе с `git pull`. Если пользователь хочет копии, используй `cp -R`. Для одного проекта клади в `<проект>/.claude/skills/` вместо `~/.claude/skills/`. Если папка с таким именем уже есть, остановись и спроси.

Альтернатива, если доступен CLI `skills`: `npx skills add vasilievyakov/claude-codex-bridge` ставит оба скилла во все агенты, которые найдет.

## 4. Поставь скиллы для Codex

Codex сканирует `~/.agents/skills` (актуальное место) и `~/.codex/skills` (устаревшее). Используй одно из них, не оба: при дублях Codex укорачивает описания всех скиллов, чтобы уложиться в бюджет контекста.

```
mkdir -p ~/.agents/skills
ln -s "$BRIDGE/skills/second-opinion" ~/.agents/skills/second-opinion
ln -s "$BRIDGE/skills/codex-worker" ~/.agents/skills/codex-worker
```

## 5. Общие инструкции для обоих агентов

Claude Code читает `~/.claude/CLAUDE.md` и разворачивает строки `@import`. Codex читает `~/.codex/AGENTS.md` и импорты не разворачивает. Один общий файл плюс симлинк покрывают обоих:

```
mkdir -p ~/.agents ~/.codex
[ -e ~/.agents/AGENTS.md ] || cp "$BRIDGE/extras/AGENTS.template.md" ~/.agents/AGENTS.md
[ -e ~/.codex/AGENTS.md ] || ln -s ~/.agents/AGENTS.md ~/.codex/AGENTS.md
```

Если `~/.codex/AGENTS.md` уже существует как обычный файл, не заменяй его; скажи пользователю и предложи слить. Затем подключи общий файл к Claude Code: если в `~/.claude/CLAUDE.md` нет строки `@~/.agents/AGENTS.md`, добавь ее первой строкой (создай файл, если его нет; существующее содержимое сохрани).

Разреши Codex читать `CLAUDE.md` проекта, когда в проекте нет `AGENTS.md`: в `~/.codex/config.toml` должна быть строка верхнего уровня

```
project_doc_fallback_filenames = ["CLAUDE.md"]
```

Допиши ее, если нет; остальное не трогай. Codex ограничивает проектные документы 32 КиБ.

## 6. Необязательно: официальный плагин Codex для Claude Code

Нативное ревью и интерактивное делегирование дает плагин OpenAI. Перед запуском сверь имена команд с его README:

```
claude plugin marketplace add openai/codex-plugin-cc
claude plugin install codex@openai-codex
```

Плагин не зависит от двух скиллов; скиллы работают без него.

## 7. Необязательно: видеть, как работает Codex

- Живая таблица запущенных процессов Codex и последних результатов: `python3 "$BRIDGE/extras/codex-watch.py"` в отдельном окне терминала. Предложи алиас.
- Индикатор `codex:N` в статус-строке: если у пользователя есть скрипт статус-строки (см. `statusLine.command` в `~/.claude/settings.json`), добавь в него сегмент из `$BRIDGE/extras/statusline-segment.sh`. Если статус-строки нет, поставь `$BRIDGE/extras/statusline-minimal.sh` и пропиши `"statusLine": {"type": "command", "command": "bash $BRIDGE/extras/statusline-minimal.sh"}` в `~/.claude/settings.json` (сначала бэкап). Подробности в `extras/README.md`.

## 8. Проверь

```
bash "$BRIDGE/skills/second-opinion/tests/run.sh"
bash "$BRIDGE/skills/codex-worker/tests/run.sh"
cd <любой git-репозиторий> && bash "$BRIDGE/skills/second-opinion/scripts/second-opinion.sh" --dry-run
```

Тесты используют фальшивый `codex` на PATH и ничего не стоят. `--dry-run` печатает точную команду `codex exec` и путь к промпту, не запуская Codex. Затем открой новую сессию Claude Code и убедись, что скиллы видны (`/second-opinion`, `/codex-worker`). Настоящая сквозная проверка: `bash "$BRIDGE/demo.sh"` (одна-две минуты, два запроса к Codex).

## 9. Отчитайся

Перечисли: найденные версии, куда прилинкованы скиллы, какие конфиги созданы или изменены (с путями бэкапов), что пропущено и почему, результаты тестов. Не пересказывай этот файл пользователю.
