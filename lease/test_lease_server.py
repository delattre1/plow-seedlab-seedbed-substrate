"""lease-server.py against the real lease.sh, on a throwaway bank: python3 lease/test_lease_server.py"""
import importlib.util
import json
import os
import tempfile
import time
from pathlib import Path

tmp = Path(tempfile.mkdtemp())
(tmp / "bank").mkdir()
(tmp / "volumes.txt").write_text("claude-auth-bank-01\nclaude-auth-bank-02\n")
live = {"claudeAiOauth": {"refreshToken": "r1", "refreshTokenExpiresAt": (time.time() + 86400) * 1000}}
dead = {"claudeAiOauth": {"refreshToken": "", "refreshTokenExpiresAt": 0}}
for vol, creds in (("claude-auth-bank-01", dead), ("claude-auth-bank-02", live)):
    (tmp / "bank" / vol).mkdir()
    (tmp / "bank" / vol / ".credentials.json").write_text(json.dumps(creds))
os.environ.update(BANK_ROOT=str(tmp / "bank"), LEASE_DIR=str(tmp / "leases"),
                  BANK_FILE=str(tmp / "volumes.txt"), ALLOWED_OWNER_UID="me", VOL_UID=str(os.getuid()))
spec = importlib.util.spec_from_file_location("ls", Path(__file__).with_name("lease-server.py"))
ls = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ls)
ls.LEASES.mkdir()

code, out = ls.checkout("vm:a")
assert code == 200 and out["volume"] == "claude-auth-bank-02", out      # dead 01 skipped
assert "NEEDS-LOGIN" in (ls.LEASES / "claude-auth-bank-01" / "holder").read_text()
assert ls.checkout("vm:b")[0] == 409                                     # one holder per login
assert ls.checkout("vm:a")[1]["lease_id"] == out["lease_id"]             # restart gets it back

rotated = {"claudeAiOauth": dict(live["claudeAiOauth"], refreshToken="r2")}
ls.store("claude-auth-bank-02", rotated)
ls.store("claude-auth-bank-02", dead)                                    # never overwrite with dead
assert "r2" in ls.creds_path("claude-auth-bank-02").read_text()

m = ls.read_meta("claude-auth-bank-02")
m["expires"] = time.time() - 1
ls.meta_path("claude-auth-bank-02").write_text(json.dumps(m))
code, out = ls.checkout("vm:b")                                          # expired holder reaped
assert code == 200 and out["credentials"]["claudeAiOauth"]["refreshToken"] == "r2", out
print("lease-server self-check OK")
