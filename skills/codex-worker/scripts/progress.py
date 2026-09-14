#!/usr/bin/env python3
"""Follow a `codex exec --json` events file and print one human-readable line
per event to stderr, so a person watching the terminal (or the Background panel
in Claude Code) can see what Codex is doing while it runs.

Usage:
  progress.py --file <events.jsonl> --label <label> [--start <epoch>] [--pid <codex pid>]

With --pid the follower exits on its own shortly after that process is gone
(after draining the file). Without --pid it runs until killed.
Identical copies of this file live in the second-opinion and codex-worker skills.
"""

import argparse
import json
import os
import re
import sys
import time


def alive(pid):
    if pid is None:
        return True
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", required=True)
    ap.add_argument("--label", required=True)
    ap.add_argument("--start", type=float, default=None)
    ap.add_argument("--pid", type=int, default=None)
    ap.add_argument("--interval", type=float, default=0.3)
    a = ap.parse_args()
    start = a.start if a.start is not None else time.time()

    def emit(text):
        el = int(time.time() - start)
        sys.stderr.write(
            "[codex %s %02d:%02d] %s\n" % (a.label, el // 60, el % 60, text)
        )
        sys.stderr.flush()

    buf = ""
    pos = 0
    gone_since = None
    while True:
        try:
            with open(a.file, "rb") as f:
                f.seek(pos)
                chunk = f.read()
                pos = f.tell()
        except FileNotFoundError:
            chunk = b""
        if chunk:
            buf += chunk.decode("utf-8", errors="replace")
            while "\n" in buf:
                line, buf = buf.split("\n", 1)
                line = line.strip()
                if not line.startswith("{"):
                    continue
                try:
                    ev = json.loads(line)
                except Exception:
                    continue
                if not isinstance(ev, dict):
                    continue
                text = describe(ev)
                if text:
                    emit(text)
        if not alive(a.pid):
            if gone_since is None:
                gone_since = time.time()
            elif time.time() - gone_since > 0.8 and not chunk:
                break
        time.sleep(a.interval)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    except BrokenPipeError:
        pass
