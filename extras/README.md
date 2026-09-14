# extras

Optional tools around the Claude Code + Codex bridge: two ways to see what Codex is doing, and a template for one instructions file shared by both agents. Nothing here is required by the skills; each file stands alone. macOS and Linux, any Codex install (npm, Homebrew, downloaded binary). No dependencies beyond bash, python3 and `ps`/`pgrep`.

Every user's status line and instruction files are different, so wiring these in is a job for your agent, not for an installer. Copy the "Give this to your agent" block into Claude Code and let it make the edit.

## codex-watch.py

Live, top-style monitor for its own terminal window: running `codex exec` reviewers and workers and plugin app-servers (PID, elapsed, kind, label, last event from the `.events.jsonl` file), worker state files, and the newest results under `~/.cache/second-opinion` and `~/.cache/codex-worker`. Python 3 standard library only; the prompt argument is never printed.

Try it:

    python3 extras/codex-watch.py --once

Give this to your agent:

> Install `extras/codex-watch.py` from this repo as a command I can run from any terminal: copy it to `~/.local/bin/codex-watch`, make it executable, and make sure `~/.local/bin` is on my PATH in my shell rc (add it only if it is missing). Then run `codex-watch --once` and show me the output. Do not delete or overwrite anything without asking.

## statusline-segment.sh

A sourceable bash function `codex_statusline_segment` that prints `codex:N` (N running `codex exec` processes), `codex:N+srv` when a plugin `codex app-server` is alive as well, or nothing when Codex is idle. Detection via `pgrep -f`; the npm `codex.js` wrapper and `timeout` wrappers are not double-counted. The usage comment in the file shows the four lines to add to an existing status line.

Try it:

    bash extras/statusline-segment.sh

Give this to your agent:

> Read `extras/statusline-segment.sh` from this repo and its usage comment. Find my current Claude Code status line script: the `statusLine.command` in `~/.claude/settings.json`. Copy the segment file next to that script, source it from the script, and append ` | <segment>` to the final output only when `codex_statusline_segment` prints something. Change nothing else in my status line. Test by piping a sample status line JSON into the script and show me the before and after output.

## statusline-minimal.sh

A complete minimal status line for users who have none: `model | dir | 123.4K (61.7%) | codex:1`. Reads the Claude Code JSON on stdin, parses it with python3 (no jq), sources `statusline-segment.sh` from the same directory. Renders in about 60 ms. The `settings.json` snippet is in the file header.

Try it:

    echo '{"model":{"display_name":"Test"},"workspace":{"current_dir":"'"$PWD"'"},"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":1000,"cache_read_input_tokens":50000,"output_tokens":200}}}' | bash extras/statusline-minimal.sh

Give this to your agent:

> I have no Claude Code status line yet. Copy `extras/statusline-minimal.sh` and `extras/statusline-segment.sh` from this repo into `~/.claude/statusline/`, then add `"statusLine": {"type": "command", "command": "bash ~/.claude/statusline/statusline-minimal.sh"}` to `~/.claude/settings.json` without touching other settings (if a `statusLine` entry already exists, stop and show it to me instead). Test by piping a sample status line JSON into the script.

## AGENTS.template.md

Template for one instructions file read by both agents: Claude Code through `@~/.agents/AGENTS.md` in `~/.claude/CLAUDE.md`, Codex through the symlink `~/.codex/AGENTS.md` -> `~/.agents/AGENTS.md`. Sections: Language, Style, Safety, Git, Environment, Codex (config, skills directories), Claude Code (routing to `second-opinion`, `codex-worker` and the plugin commands). Placeholders in angle brackets; write the file in the language you want the agents to answer in.

Try it:

    cat extras/AGENTS.template.md

Give this to your agent:

> Set up shared agent instructions from `extras/AGENTS.template.md` in this repo. Create `~/.agents/AGENTS.md` from the template, asking me for every placeholder. Move the rules from my `~/.claude/CLAUDE.md` that apply to both agents into it and leave an `@~/.agents/AGENTS.md` import line in `~/.claude/CLAUDE.md`. Make `~/.codex/AGENTS.md` a symlink to `~/.agents/AGENTS.md`; if a real `~/.codex/AGENTS.md` already exists, merge its content into the shared file first and show me the diff before replacing it. Keep the result under 32 KiB. Do not delete anything without asking.

## По-русски

Необязательные инструменты вокруг связки Claude Code + Codex: два способа видеть, что делает Codex, и шаблон одного файла инструкций, который читают оба агента. Скиллам ничего из этого не нужно, каждый файл самостоятелен. macOS и Linux, любой способ установки Codex (npm, Homebrew, скачанный бинарник). Зависимости: bash, python3 и `ps`/`pgrep`.

Строка состояния и файлы инструкций у каждого свои, поэтому встраивание делает агент, а не установщик. Скопируй блок «Отдай агенту» в Claude Code и пусть он внесет правку.

### codex-watch.py

Живой монитор в стиле top для отдельного окна терминала: работающие `codex exec` (ревьюеры и воркеры) и app-server плагина (PID, время, тип, метка, последнее событие из `.events.jsonl`), файлы состояния воркеров и свежие результаты в `~/.cache/second-opinion` и `~/.cache/codex-worker`. Только стандартная библиотека Python 3; текст промпта никогда не печатается.

Попробовать:

    python3 extras/codex-watch.py --once

Отдай агенту:

> Установи `extras/codex-watch.py` из этого репозитория как команду, доступную из любого терминала: скопируй в `~/.local/bin/codex-watch`, сделай исполняемым и проверь, что `~/.local/bin` есть в PATH в моем rc-файле (добавь, только если нет). Затем запусти `codex-watch --once` и покажи вывод. Ничего не удаляй и не перезаписывай без вопроса.

### statusline-segment.sh

Подключаемая через `source` функция `codex_statusline_segment`: печатает `codex:N` (N работающих процессов `codex exec`), `codex:N+srv`, если жив еще и `codex app-server` плагина, и ничего, когда Codex простаивает. Детекция через `pgrep -f`; npm-обертка `codex.js` и обертка `timeout` не считаются дважды. В комментарии к файлу показаны четыре строки для добавления в существующую строку состояния.

Попробовать:

    bash extras/statusline-segment.sh

Отдай агенту:

> Прочитай `extras/statusline-segment.sh` из этого репозитория и комментарий по использованию. Найди мой текущий скрипт строки состояния Claude Code: `statusLine.command` в `~/.claude/settings.json`. Скопируй файл сегмента рядом с этим скриптом, подключи его через `source` и добавляй ` | <сегмент>` к итоговому выводу только когда `codex_statusline_segment` что-то печатает. Больше ничего в строке состояния не меняй. Проверь, подав в скрипт образец JSON строки состояния, и покажи вывод до и после.

### statusline-minimal.sh

Полная минимальная строка состояния для тех, у кого ее нет: `model | dir | 123.4K (61.7%) | codex:1`. Читает JSON Claude Code со stdin, разбирает его python3 (без jq), подключает `statusline-segment.sh` из той же папки. Отрисовка около 60 мс. Фрагмент для `settings.json` в шапке файла.

Попробовать:

    echo '{"model":{"display_name":"Test"},"workspace":{"current_dir":"'"$PWD"'"},"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":1000,"cache_read_input_tokens":50000,"output_tokens":200}}}' | bash extras/statusline-minimal.sh

Отдай агенту:

> У меня еще нет строки состояния Claude Code. Скопируй `extras/statusline-minimal.sh` и `extras/statusline-segment.sh` из этого репозитория в `~/.claude/statusline/`, затем добавь `"statusLine": {"type": "command", "command": "bash ~/.claude/statusline/statusline-minimal.sh"}` в `~/.claude/settings.json`, не трогая остальные настройки (если запись `statusLine` уже есть, остановись и покажи ее мне). Проверь, подав в скрипт образец JSON строки состояния.

### AGENTS.template.md

Шаблон одного файла инструкций, который читают оба агента: Claude Code через `@~/.agents/AGENTS.md` в `~/.claude/CLAUDE.md`, Codex через симлинк `~/.codex/AGENTS.md` -> `~/.agents/AGENTS.md`. Разделы: Language, Style, Safety, Git, Environment, Codex (конфиг, папки скиллов), Claude Code (маршрутизация на `second-opinion`, `codex-worker` и команды плагина). Заполнители в угловых скобках; пиши файл на том языке, на котором агенты должны отвечать.

Попробовать:

    cat extras/AGENTS.template.md

Отдай агенту:

> Настрой общие инструкции агентов по `extras/AGENTS.template.md` из этого репозитория. Создай `~/.agents/AGENTS.md` из шаблона, спросив меня про каждый заполнитель. Перенеси в него правила из моего `~/.claude/CLAUDE.md`, которые относятся к обоим агентам, и оставь в `~/.claude/CLAUDE.md` строку импорта `@~/.agents/AGENTS.md`. Сделай `~/.codex/AGENTS.md` симлинком на `~/.agents/AGENTS.md`; если настоящий файл `~/.codex/AGENTS.md` уже есть, сначала слей его содержимое в общий файл и покажи мне diff перед заменой. Держи результат в пределах 32 КиБ. Ничего не удаляй без вопроса.
