#!/usr/bin/env python3
"""One sitting: the owner approves N Claude logins, back to back, straight into the Auth Bank pool.

    python3 lease/approve-logins.py 10        (or double-click ~/Downloads/Add Claude logins.command)

For each one, `claude setup-token` opens Claude's authorize page in the browser. The owner signs in
(or switches account) and approves there, and pastes the code if Claude asks for one. That is the only
part a person does. This script never types a password or a code.

Each token is caught as it comes out, hidden on screen ("[saved to the pool]"), checked with one tiny
Claude request, and piped over ssh straight into the pool (`pool.py add`). It never goes in argv, a
file on this Mac, or a log.
"""
import os
import pty
import re
import subprocess
import sys
import select
import struct
import termios
import tty
import fcntl

TOKEN = re.compile(rb"sk-ant-[A-Za-z0-9_\-]{20,}")
SETUP = os.environ.get("SETUP_CMD", "claude setup-token").split()
POOL_ADD = os.environ.get("POOL_ADD", "ssh delattre-server docker exec -i claude-bank-lease python3 /app/pool.py add").split()
POOL_LIST = os.environ.get("POOL_LIST", "ssh delattre-server docker exec claude-bank-lease python3 /app/pool.py list").split()
NAME = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")


def capture_token():
    """Run setup-token in a very wide pty (so the token is never wrapped), show the owner everything
    except the token, and return the token (bytes) or None."""
    found, held = [], [b""]

    def scrub(data, final=False):
        buf = held[0] + data
        cut = len(buf)
        if not final:                         # hold back an unfinished token, or a tail that may start one
            m = re.search(rb"sk-ant-[A-Za-z0-9_\-]*$", buf)
            if m:
                cut = m.start()
            else:
                for k in range(6, 0, -1):
                    if buf.endswith(b"sk-ant"[:k]):
                        cut = len(buf) - k
                        break
        emit, held[0] = buf[:cut], buf[cut:]
        found.extend(m.group(0) for m in TOKEN.finditer(emit))
        return TOKEN.sub(b"[saved to the pool]", emit)

    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(SETUP[0], SETUP)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 1000, 0, 0))
    old = termios.tcgetattr(0) if os.isatty(0) else None
    try:
        if old:
            tty.setraw(0)
        while True:
            r, _, _ = select.select([fd, 0] if old else [fd], [], [])
            if fd in r:
                try:
                    data = os.read(fd, 4096)
                except OSError:
                    data = b""
                if not data:
                    os.write(1, scrub(b"", final=True))
                    break
                os.write(1, scrub(data))
            if old and 0 in r:
                os.write(fd, os.read(0, 1024))
    finally:
        if old:
            termios.tcsetattr(0, termios.TCSADRAIN, old)
        os.waitpid(pid, 0)
    return found[0] if found else None


def works(token):
    env = dict(os.environ, CLAUDE_CODE_OAUTH_TOKEN=token.decode())
    env.pop("AGENT_ID", None)                 # a nested claude would fire this fleet's Stop hook as us
    check = os.environ.get("CHECK_CMD", "claude -p 'reply with OK' --model claude-haiku-4-5")
    r = subprocess.run(check, shell=True, env=env, capture_output=True, timeout=120)
    return r.returncode == 0


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 10
    print(f"\nAdding {n} Claude logins to your Auth Bank pool. For each one:")
    print("  1. a Claude page opens in your browser: sign in (or switch account) and approve")
    print("  2. if Claude shows a code, paste it here and press Enter")
    print("  3. type a short name for that account (or just Enter)\n")
    added = []
    for i in range(1, n + 1):
        print(f"\n===== login {i} of {n} =====\n")
        tok = capture_token()
        if not tok:
            print("\nNo login came back from that one (cancelled?). Skipping it.")
            continue
        print("\nChecking it works...", end=" ", flush=True)
        if not works(tok):
            print("it did NOT work, so it was not added. Skipping it.")
            continue
        print("works.")
        while True:
            name = input(f"Short name for this account [daniel-{i + 1}]: ").strip().lower() or f"daniel-{i + 1}"
            if NAME.match(name):
                break
            print("  letters, digits and '-' only")
        r = subprocess.run(POOL_ADD + [name], input=tok + b"\n", capture_output=True)
        print(("  added to the pool as " + name) if r.returncode == 0 else
              "  could not add it: " + r.stderr.decode(errors="replace")[-200:])
        if r.returncode == 0:
            added.append(name)
        tok = None
    print(f"\nDone: {len(added)} added ({', '.join(added) or 'none'}). The pool now:\n")
    subprocess.run(POOL_LIST)


if __name__ == "__main__":
    main()
