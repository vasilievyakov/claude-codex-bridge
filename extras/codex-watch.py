#!/usr/bin/env python3
"""codex-watch: live terminal monitor for OpenAI Codex CLI (macOS and Linux).

Shows, top-style, what Codex is doing right now: running `codex exec`
reviewers/workers and plugin app-servers, worker state files, and the most
recent finished results. Meant to run in its own terminal window.

Usage:
  codex-watch.py [--interval 2.0] [--once] [--cache-dir ~/.cache]

Sections:
  RUNNING          one row per Codex process found in
                   `ps -A -ww -o pid=,etime=,command=` whose argv[0] has the
                   basename `codex` (any directory prefix or none: the npm
                   vendor binary `.../vendor/<triple>/bin/codex`, the Homebrew
                   binary `/opt/homebrew/Cellar/codex/<ver>/bin/codex`, a
                   downloaded binary, or plain `codex` from PATH) followed by
                   `exec` or `app-server`. Wrapper processes of the same run
                   (`node .../bin/codex.js exec`, `timeout 900 codex exec`,
                   the skill's own bash script) are not counted; the real
                   codex child is a separate process and is matched on its
                   own. EVENTS is the line count of <output>.events.jsonl,
                   LAST the last describable event read from the tail of that
                   file (at most 64 KB). The prompt argument is never printed.
  WORKERS (state)  <cache>/codex-worker/workers/<repo-key>/<label>.json;
                   the section is skipped when there are no state files.
  RECENT RESULTS   8 newest result files among <cache>/second-opinion/**/*.json
                   and <cache>/codex-worker/*.json (not workers/, not
                   *.events.jsonl, not files still written by a RUNNING
                   process). Reviews show `verdict (findings)`, workers show
                   `status (n files)`, unparsable JSON shows `unreadable`.

Flags:
  --interval <sec>   refresh period, default 2.0
  --once             print one snapshot (no screen clear) and exit
  --cache-dir <dir>  cache root, default ~/.cache (for tests)

Environment:
  CODEX_WATCH_FAKE_PS=<path>  Read ps-like lines ("<pid> <etime> <command>")
                              from this text file instead of running ps, so
                              the RUNNING table can be exercised without a
                              live Codex. Combine with --cache-dir pointing
                              at a fixture tree.

Python 3 standard library only. Ctrl-C exits cleanly.
"""

import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime

HOME = os.path.expanduser("~")
TAIL_BYTES = 64 * 1024
RECENT_LIMIT = 8
PS_LINE_RE = re.compile(r"^\s*(\d+)\s+(\S+)\s+(.*?)\s*$")
# argv[0] must have the basename `codex` (with or without a directory prefix)
# and the next word must be `exec` or `app-server`. Wrappers whose argv[0] is
# something else (`node .../codex.js exec`, `timeout 900 codex exec`,
# `bash .../second-opinion.sh`) and shells or editors whose command line merely
# mentions the pattern are not counted.
CODEX_RE = re.compile(r"^(?:\S*/)?codex\s+(exec|app-server)(?:\s|$)")
STAMP_RE = re.compile(r"^\d{8}-\d{6}-")
RESULT_EXTS = (".events.jsonl", ".json", ".md")


# ---------------------------------------------------------------------------
# Event wording for `codex exec --json` events
# ---------------------------------------------------------------------------

def one_line(text, limit):
    text = re.sub(r"\s+", " ", str(text)).strip()
    if len(text) > limit:
        return text[: limit - 1] + "…"
    return text


def clean_command(cmd):
    cmd = str(cmd)
    m = re.match(r"^/bin/(?:ba|z)?sh\s+-lc\s+(.*)$", cmd, re.S)
    if m:
        cmd = m.group(1).strip()
        if len(cmd) >= 2 and cmd[0] == cmd[-1] and cmd[0] in "\"'":
            cmd = cmd[1:-1]
    return one_line(cmd, 110)


def describe(ev):
    t = ev.get("type", "")
    item = ev.get("item") if isinstance(ev.get("item"), dict) else {}
    it = item.get("type", "")
    if t == "thread.started":
        return "thread %s" % ev.get("thread_id", "")
    if t == "turn.started":
        return "turn started"
    if t == "turn.completed":
        u = ev.get("usage") or {}
        return "turn completed: in %s (cached %s), out %s" % (
            u.get("input_tokens", "?"),
            u.get("cached_input_tokens", "?"),
            u.get("output_tokens", "?"),
        )
    if t == "turn.failed" or t == "error":
        return "error: %s" % one_line(
            ev.get("message") or ev.get("error") or json.dumps(ev, ensure_ascii=False),
            140,
        )
    if it == "command_execution":
        if t == "item.started":
            return "run: %s" % clean_command(item.get("command", ""))
        code = item.get("exit_code")
        status = item.get("status", "")
        out = one_line(item.get("aggregated_output", ""), 70)
        if code in (0, None) and status != "failed":
            return "ok%s" % ((": " + out) if out else "")
        return "exit %s%s" % (code, (": " + out) if out else "")
    if it == "file_change":
        changes = item.get("changes") or []
        names = ", ".join(
            "%s (%s)" % (os.path.basename(c.get("path", "")), c.get("kind", ""))
            for c in changes[:6]
        )
        if len(changes) > 6:
            names += ", +%d" % (len(changes) - 6)
        return ("edit: %s" if t == "item.started" else "edited: %s") % (names or "?")
    if it == "web_search":
        q = item.get("query", "")
        if t == "item.started" and not q:
            return "search started"
        return "search: %s" % one_line(q, 110)
    if it == "agent_message":
        if t == "item.completed":
            return "message: %s" % one_line(item.get("text", ""), 120)
        return None
    if it == "reasoning":
        if t == "item.completed":
            txt = item.get("text") or item.get("summary") or ""
            return ("thinking: %s" % one_line(txt, 100)) if txt else None
        return None
    if it == "error":
        return "codex: %s" % one_line(item.get("message", ""), 140)
    if t.startswith("item."):
        return "%s %s" % (t.split(".", 1)[1], it or "item")
    return t or None


# ---------------------------------------------------------------------------
# Paths and labels
# ---------------------------------------------------------------------------

def short_home(path):
    if not path:
        return "-"
    if path == HOME or path.startswith(HOME + os.sep):
        return "~" + path[len(HOME):]
    return path


def strip_result_ext(name):
    for ext in RESULT_EXTS:
        if name.endswith(ext):
            return name[: -len(ext)]
    return name


def label_from_output(path):
    if not path:
        return "-"
    base = strip_result_ext(os.path.basename(path))
    return STAMP_RE.sub("", base) or "-"


def kind_from_path(path, default="exec"):
    if not path:
        return default
    if "/second-opinion/" in path:
        return "review"
    if "/codex-worker/" in path:
        return "worker"
    return default


def events_path_for(output):
    if not output:
        return ""
    return strip_result_ext(output) + ".events.jsonl"


# ---------------------------------------------------------------------------
# Processes
# ---------------------------------------------------------------------------

def ps_lines():
    fake = os.environ.get("CODEX_WATCH_FAKE_PS")
    if fake:
        try:
            with open(fake, encoding="utf-8", errors="replace") as f:
                return f.read().splitlines()
        except OSError:
            return []
    try:
        out = subprocess.run(
            ["ps", "-A", "-ww", "-o", "pid=,etime=,command="],
            capture_output=True, text=True, timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return []
    return out.stdout.splitlines()


def _option_value(args, names):
    """First value of any of `names` in an argv list; supports --name=value."""
    for k, tok in enumerate(args):
        if tok in names:
            return args[k + 1] if k + 1 < len(args) else ""
        for name in names:
            if name.startswith("--") and tok.startswith(name + "="):
                return tok[len(name) + 1:]
    return ""


def parse_process(line):
    m = PS_LINE_RE.match(line)
    if not m:
        return None
    pid, etime, cmd = m.groups()
    vm = CODEX_RE.match(cmd)
    if not vm:
        return None
    args = cmd.split()[1:]
    proc = {
        "pid": pid, "etime": etime, "sub": vm.group(1),
        "kind": "exec", "label": "-", "mode": "-", "cwd": "",
        "output": "", "events": "",
    }
    if proc["sub"] == "app-server":
        proc["kind"] = "plugin"
        return proc
    proc["mode"] = "fresh"
    if "exec" in args:
        e = args.index("exec")
        if e + 1 < len(args) and args[e + 1] == "resume":
            proc["mode"] = "resume"
    output = _option_value(args, ("-o", "--output-last-message"))
    if output:
        output = os.path.abspath(os.path.expanduser(output))
    cwd = _option_value(args, ("-C", "--cd"))
    if cwd:
        cwd = os.path.abspath(os.path.expanduser(cwd))
    proc["output"] = output
    proc["events"] = events_path_for(output)
    proc["cwd"] = cwd
    proc["kind"] = kind_from_path(output)
    proc["label"] = label_from_output(output)
    return proc


def running_processes():
    procs = []
    for line in ps_lines():
        p = parse_process(line)
        if p:
            procs.append(p)
    procs.sort(key=lambda p: int(p["pid"]))
    return procs


# ---------------------------------------------------------------------------
# Events files
# ---------------------------------------------------------------------------

def count_lines(path):
    n = 0
    last = b"\n"
    try:
        with open(path, "rb") as f:
            while True:
                chunk = f.read(1 << 20)
                if not chunk:
                    break
                n += chunk.count(b"\n")
                last = chunk[-1:]
    except OSError:
        return None
    if last != b"\n":
        n += 1
    return n


def last_event(path):
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            start = max(0, size - TAIL_BYTES)
            f.seek(start)
            data = f.read()
    except OSError:
        return None
    lines = data.decode("utf-8", errors="replace").split("\n")
    if start > 0:
        lines = lines[1:]  # drop the partial first line
    for line in reversed(lines):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if not isinstance(ev, dict):
            continue
        text = describe(ev)
        if text:
            return text
    return None


# ---------------------------------------------------------------------------
# Worker state and results
# ---------------------------------------------------------------------------

def load_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def worker_state_rows(cache):
    pattern = os.path.join(cache, "codex-worker", "workers", "*", "*.json")
    rows = []
    for path in sorted(glob.glob(pattern)):
        name = strip_result_ext(os.path.basename(path))
        d = load_json(path)
        if d is None:
            rows.append([name, "unreadable", "-", "-", "-"])
            continue
        rows.append([
            str(d.get("label") or name),
            str(d.get("status") or "-"),
            str(d.get("branch") or "-"),
            str(d.get("last_run") or "-"),
            str(d.get("thread_id") or "-")[:8],
        ])
    return rows


def result_status(path, kind):
    d = load_json(path)
    if d is None:
        return "unreadable"
    if kind == "review":
        findings = d.get("findings")
        n = len(findings) if isinstance(findings, list) else 0
        return "%s (%d)" % (d.get("verdict") or "?", n)
    changes = d.get("changes")
    n = len(changes) if isinstance(changes, list) else 0
    return "%s (%d %s)" % (d.get("status") or "?", n, "file" if n == 1 else "files")


def recent_result_rows(cache, running_outputs, limit=RECENT_LIMIT):
    paths = set(glob.glob(os.path.join(cache, "second-opinion", "**", "*.json"), recursive=True))
    paths.update(glob.glob(os.path.join(cache, "codex-worker", "*.json")))
    items = []
    for p in paths:
        ap = os.path.abspath(p)
        if ap.endswith(".events.jsonl") or "/codex-worker/workers/" in ap:
            continue
        if ap in running_outputs:
            continue
        try:
            mtime = os.path.getmtime(ap)
        except OSError:
            continue
        items.append((mtime, ap))
    items.sort(reverse=True)
    rows = []
    for mtime, ap in items[:limit]:
        kind = kind_from_path(ap)
        rows.append([
            datetime.fromtimestamp(mtime).strftime("%H:%M"),
            kind,
            label_from_output(ap),
            result_status(ap, kind),
        ])
    return rows


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

def fit(text, width):
    text = one_line(text, 1 << 20)
    if width <= 0:
        return ""
    if len(text) > width:
        return text[:width] if width == 1 else text[: width - 1] + "…"
    return text


def render_table(headers, rows, width, caps=None, flex=None):
    """Fixed-width table lines. caps: {col: max width}; flex: column that
    takes whatever width is left (and shrinks first)."""
    n = len(headers)
    sep = 2
    cells = [[str(h) for h in headers]] + [[str(c) for c in r] for r in rows]
    widths = [max(len(one_line(row[i], 1 << 20)) for row in cells) for i in range(n)]
    for i, cap in (caps or {}).items():
        widths[i] = min(widths[i], cap)
    min_flex = 4 if flex is not None else 0

    def others_total():
        return sum(w for i, w in enumerate(widths) if i != flex) + sep * (n - 1)

    # Too narrow: shave the widest fixed column, one char at a time, down to 6.
    while others_total() + min_flex > width:
        cands = [i for i in range(n) if i != flex and widths[i] > 6]
        if not cands:
            break
        widths[max(cands, key=lambda k: widths[k])] -= 1
    if flex is not None:
        widths[flex] = max(min_flex, min(widths[flex], width - others_total()))
    lines = []
    for row in cells:
        parts = [fit(c, widths[i]).ljust(widths[i]) for i, c in enumerate(row)]
        lines.append((" " * sep).join(parts)[:width].rstrip())
    return lines


def indent(lines, pad="  "):
    return [pad + ln for ln in lines]


def render(a, width):
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    if a.once:
        head = "codex-watch  %s  snapshot" % now
    else:
        head = "codex-watch  %s  refresh %.1fs  Ctrl-C quits" % (now, a.interval)
    out = [head[:width], ""]

    procs = running_processes()
    out.append("RUNNING (%d)" % len(procs))
    if not procs:
        out.append("  none running")
    else:
        rows = []
        for p in procs:
            ev_count, last = "-", "-"
            if p["events"]:
                n = count_lines(p["events"])
                if n is not None:
                    ev_count = str(n)
                    last = last_event(p["events"]) or "-"
            rows.append([
                p["pid"], p["etime"], p["kind"], p["label"], p["mode"],
                short_home(p["cwd"]), ev_count, last,
            ])
        out += indent(render_table(
            ["PID", "ELAPSED", "KIND", "LABEL", "MODE", "CWD", "EVENTS", "LAST"],
            rows, width - 2, caps={3: 28, 5: 32}, flex=7,
        ))

    workers = worker_state_rows(a.cache_dir)
    if workers:
        out.append("")
        out.append("WORKERS (state)")
        out += indent(render_table(
            ["LABEL", "STATUS", "BRANCH", "LAST_RUN", "THREAD"],
            workers, width - 2, caps={0: 28, 2: 32}, flex=3,
        ))

    running_outputs = {p["output"] for p in procs if p["output"]}
    results = recent_result_rows(a.cache_dir, running_outputs)
    out.append("")
    out.append("RECENT RESULTS")
    if not results:
        out.append("  none")
    else:
        out += indent(render_table(
            ["TIME", "KIND", "LABEL", "STATUS"],
            results, width - 2, caps={2: 40}, flex=3,
        ))
    return out


def main():
    ap = argparse.ArgumentParser(
        description="Live monitor of OpenAI Codex CLI activity (codex exec, app-server)."
    )
    ap.add_argument("--interval", type=float, default=2.0, help="refresh period in seconds (default 2.0)")
    ap.add_argument("--once", action="store_true", help="print one snapshot and exit")
    ap.add_argument("--cache-dir", default=os.path.join(HOME, ".cache"), help="cache root (default ~/.cache)")
    a = ap.parse_args()
    if a.interval <= 0:
        ap.error("--interval must be positive")
    a.cache_dir = os.path.abspath(os.path.expanduser(a.cache_dir))

    while True:
        width = max(20, shutil.get_terminal_size((100, 30)).columns)
        body = "\n".join(render(a, width)) + "\n"
        if a.once:
            sys.stdout.write(body)
            sys.stdout.flush()
            return 0
        sys.stdout.write("\033[2J\033[H" + body)
        sys.stdout.flush()
        time.sleep(a.interval)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.stdout.write("\n")
        sys.exit(0)
    except BrokenPipeError:
        try:
            sys.stdout.close()
        finally:
            sys.exit(0)
