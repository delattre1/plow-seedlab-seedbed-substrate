#!/usr/bin/env python3
"""queue-client-v2-shim — make a baked/installed queue-client.py speak the V2 queue.

WHY THIS EXISTS (fleet-wide bug, root-caused on card ca09a42c386febed):
  The central queue-server is V2 (mypeople-queue-v2). Its `GET /task/poll` returns
  a **LIST** of claimed tasks and names the verb field **"type"**. The pre-V2
  queue-client baked into the golden image expects a single **DICT** and reads
  **"action"**. So the instant a real spawn/send/kill task arrives, the node's
  client crashes (`AttributeError: 'list' object has no attribute 'get'`) and goes
  REGISTERED-BUT-DEAF: it still heartbeats "alive" (a separate tkmx path) but can
  no longer receive ANY spawn/send/kill. => JOIN-mode spawns silently fail on every
  golden node. This shim is the durable fix, applied ONCE at the source of truth.

WHAT IT DOES — the proven 2-field compat shim (validated on demo node hud-join-1):
  Replaces the client's `task_loop()` with the V2-compatible loop (identical to the
  central queue-client): normalize a LIST-or-DICT poll response to a list, and read
  the verb from "type" OR "action". Handlers, register, heartbeat are untouched
  (they already match V2 field-for-field).

IDEMPOTENT + SAFE: re-running is a no-op once patched; if the file is already
V2-aware (or the anchors are missing) it exits 0 without changing anything, and it
refuses to write a file that does not parse.

USAGE:  python3 queue-client-v2-shim.py /home/tester/mypeople/bin/queue-client.py
"""
import ast
import sys

MARKER = "# [v2-compat-shim]"

# The V2-compatible dispatch — byte-for-byte the central queue-client's known-good
# implementation, so a golden node's client never drifts from the server it joins.
V2_BLOCK = '''def _handle_one(task):  # [v2-compat-shim]
    """Run one task through its handler and report the result. The verb is carried
    as `type` (V2 queue-server schema) with `action` accepted as a legacy alias.
    Errors are reported INSIDE `result` ({error:...}) so a queue-routed `mp` on the
    submitting host can surface them (the server stores `result`, not a top error)."""
    tid = task.get("task_id")
    action = task.get("type") or task.get("action") or ""
    handler = HANDLERS.get(action)
    if not handler:
        try:
            post_json("/task/result", {"task_id": tid, "ok": False,
                                       "result": {"error": f"unknown action {action!r}"}})
        except urllib.error.URLError:
            pass
        return
    try:
        ok, payload = handler(task)
    except Exception as e:
        ok, payload = False, f"handler raised: {e}"
    try:
        if ok:
            post_json("/task/result", {"task_id": tid, "ok": True, "result": payload})
        else:
            post_json("/task/result", {"task_id": tid, "ok": False, "result": {"error": str(payload)}})
    except urllib.error.URLError as e:
        print(f"{time.strftime('%H:%M:%S')} result POST FAIL: {e}", file=sys.stderr, flush=True)
    print(f"{time.strftime('%H:%M:%S')} task {str(tid)[:8]} {action} \\u2192 ok={ok}", flush=True)


def task_loop():  # [v2-compat-shim]
    while True:
        try:
            tasks = get_json(f"/task/poll?hostname={urllib.parse.quote(HOSTNAME)}")
        except urllib.error.URLError as e:
            print(f"{time.strftime('%H:%M:%S')} poll FAIL: {e}", file=sys.stderr, flush=True)
            time.sleep(POLL_INTERVAL)
            continue
        # V2 queue-server returns a LIST of claimed tasks; the legacy server returned
        # a single task dict. Normalize to a list so both protocols work.
        if isinstance(tasks, dict):
            tasks = [tasks] if tasks.get("task_id") else []
        if not tasks:
            time.sleep(POLL_INTERVAL)
            continue
        for task in tasks:
            _handle_one(task)
'''


def patch(path):
    src = open(path, encoding="utf-8").read()

    if MARKER in src:
        print(f"queue-client-v2-shim: already applied ({path}) — no-op")
        return 0

    anchor = "\ndef task_loop():"
    end = "\ndef main("
    if anchor not in src or end not in src.split(anchor, 1)[1]:
        # Nothing to patch (unexpected shape). Do NOT guess — fail loud but non-fatal
        # so a from-seed hydrate that ships an already-V2 client is not blocked.
        print(f"queue-client-v2-shim: anchors not found in {path} — SKIPPED "
              "(client may already be V2 or restructured); verify manually", file=sys.stderr)
        return 0

    head, rest = src.split(anchor, 1)          # head ends just before "\ndef task_loop():"
    _, after_main = rest.split(end, 1)         # after_main = "():\n    if not SECRET ..."
    new = head + "\n" + V2_BLOCK + "\ndef main(" + after_main

    # Never write a file that does not parse.
    ast.parse(new)

    open(path, "w", encoding="utf-8").write(new)
    print(f"queue-client-v2-shim: applied V2 poll/dispatch shim to {path}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: queue-client-v2-shim.py <path/to/queue-client.py>", file=sys.stderr)
        sys.exit(2)
    sys.exit(patch(sys.argv[1]))
