#!/usr/bin/env python3
"""Pack the owner's personal Claude skills for their cloud MyPlow, and put the pack on the bank.

    python3 lease/sync-skills.py              # ~/.claude/skills -> delattre-server, served at POST /skills
    python3 lease/sync-skills.py --dry-run    # print what would go and what is left out, send nothing

These are the owner's own skills: no credentials by design, but their hostnames, contacts and
accounts, so they reach only their own agents through the bank (same owner check as the login) and
never the public image. Symlinks are followed (several skills live in other checkouts). Left out:
dependency trees and build output (gstack alone carries 1.1 GB of node_modules and macOS binaries
no Linux VM can run), any file over 1 MB, binaries, and any file holding something token-shaped,
so a secret pasted into a skill by mistake stays on the Mac.
"""
import io
import os
import re
import subprocess
import sys
import tarfile
from pathlib import Path

SRC = Path(os.environ.get("SKILLS_DIR", Path.home() / ".claude/skills"))
DEST = os.environ.get("SKILLS_DEST", "delattre-server:claude-bank-lease/secret/skills.tar.gz")
SKIP_DIRS = {"node_modules", "dist", "bin", ".git", "__pycache__", ".venv", "venv"}
MAX_BYTES = 1 << 20
SECRET = re.compile(rb"sk-ant-[a-z]{3}\d{2}-|gh[pousr]_[A-Za-z0-9]{36}|github_pat_\w{40,}|AKIA[0-9A-Z]{16}"
                    rb"|xox[abpr]-[0-9A-Za-z-]{10,}|ops_[A-Za-z0-9_-]{40,}|-----BEGIN [A-Z ]*PRIVATE KEY-----")
BINARY = (b"\x7fELF", b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"MZ")


def pack(src):
    kept, skipped, buf = [], [], io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for root, dirs, files in os.walk(src, followlinks=True):
            dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
            for name in sorted(files):
                path = Path(root, name)
                rel = path.relative_to(src)
                try:
                    data = path.read_bytes()
                except OSError:
                    continue
                why = ("over 1 MB" if len(data) > MAX_BYTES else "binary" if data.startswith(BINARY) or b"\0" in data[:4096]
                       else "token-shaped text" if SECRET.search(data) else None)
                if why:
                    skipped.append((str(rel), why))
                    continue
                info = tarfile.TarInfo(str(rel))
                info.size, info.mode, info.mtime = len(data), 0o755 if os.access(path, os.X_OK) else 0o644, 0
                tar.addfile(info, io.BytesIO(data))
                kept.append(str(rel))
    return buf.getvalue(), kept, skipped


if __name__ == "__main__":
    data, kept, skipped = pack(SRC)
    skills = sorted({k.split("/", 1)[0] for k in kept if k.endswith("SKILL.md")})
    print(f"{len(skills)} skills, {len(kept)} files, {len(data) // 1024} KB packed")
    for rel, why in skipped:
        if why != "binary":
            print(f"  left out ({why}): {rel}")
    print(f"  left out (binary): {sum(1 for _, w in skipped if w == 'binary')} files")
    if "--dry-run" in sys.argv:
        sys.exit(0)
    host, path = DEST.split(":", 1)
    subprocess.run(["ssh", host, f"umask 077; cat > {path}.tmp && mv {path}.tmp {path}"], input=data, check=True)
    print(f"sent to {DEST}")
