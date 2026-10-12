"""lease-server.py + pool.py over real HTTP on a throwaway pool: python3 lease/test_lease_server.py"""
import importlib.util
import json
import os
import tempfile
import threading
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

tmp = Path(tempfile.mkdtemp())
os.environ.update(POOL_DIR=str(tmp / "pool"), ALLOWED_OWNER_UID="me", LEASE_TTL="600")
spec = importlib.util.spec_from_file_location("ls", Path(__file__).with_name("lease-server.py"))
ls = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ls)
pool = ls.pool
ls.owner_of = lambda assertion: {"mine": "me", "theirs": "someone-else"}.get(assertion)
srv = ThreadingHTTPServer(("127.0.0.1", 0), ls.H)
threading.Thread(target=srv.serve_forever, daemon=True).start()


def call(path, body=None, who="mine"):
    req = urllib.request.Request("http://127.0.0.1:%d/claude-bank%s" % (srv.server_port, path),
                                 data=json.dumps(body or {}).encode(),
                                 headers={"X-Plow-Index-Assertion": who, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if r.headers.get_content_type() == "application/json" else raw)
    except urllib.error.HTTPError as e:
        return e.code, json.load(e)


TOK = {n: "sk-ant-oat01-" + n * 40 for n in ("aa", "bb", "cc")}

# No login yet: no capacity, and a stranger never gets past the owner check.
assert call("/checkout", {"holder": "vm1"})[0] == 409
assert call("/checkout", {"holder": "vm1"}, who="theirs")[0] == 401
assert call("/checkout", {"holder": "vm1"}, who="")[0] == 401
for n in ("aa", "bb"):
    pool.add(n, TOK[n] + "\n")
assert oct((tmp / "pool/accounts/aa.token").stat().st_mode & 0o777) == "0o600"

# One holder per login; a restarted holder gets its own back; nobody else gets a held one.
c1, a = call("/checkout", {"holder": "vm1"})
assert c1 == 200 and a["token"] == TOK[a["account"]]
assert call("/checkout", {"holder": "vm1"})[1]["lease_id"] == a["lease_id"]
c2, b = call("/checkout", {"holder": "vm2"})
assert c2 == 200 and b["account"] != a["account"]
assert call("/checkout", {"holder": "vm3"})[0] == 409            # both held: no-capacity

# Usage the holder reports (cumulative) lands on its account once, not twice.
assert call("/heartbeat", {"lease_id": a["lease_id"], "usage": {"input": 100, "output": 50}})[1] == {"ok": True}
call("/heartbeat", {"lease_id": a["lease_id"], "usage": {"input": 100, "output": 50}})
row = {r["account"]: r for r in pool.report()}[a["account"]]
assert row["total"] == 150 and row["today"] == 150, row

# A limit hit with no free login: told so, keeps its own.
assert call("/heartbeat", {"lease_id": a["lease_id"], "limit_hit": True})[1].get("no_capacity")
pool.add("cc", TOK["cc"])
# Now a free one exists: a DIFFERENT login is reserved for it, the old lease stays held.
_, hb = call("/heartbeat", {"lease_id": a["lease_id"]})
rot = hb["rotate"]
assert rot["account"] == "cc" and rot["token"] == TOK["cc"]
assert call("/heartbeat", {"lease_id": a["lease_id"]})[1]["rotate"]["lease_id"] == rot["lease_id"]  # same reservation
assert call("/checkout", {"holder": "vm3"})[0] == 409            # cc reserved, a's still held
# Rotation done: the old lease goes back; the limited account is not lent again inside its cooldown.
assert call("/return", {"lease_id": a["lease_id"]})[0] == 200
assert call("/heartbeat", {"lease_id": rot["lease_id"]})[1] == {"ok": True}
assert call("/checkout", {"holder": "vm3"})[0] == 409            # 'aa' limited, 'bb' and 'cc' held
assert "limited until" in {r["account"]: r for r in pool.report()}[a["account"]]["state"]

# A leaked account: its holder is moved off; a failed restart gives the RESERVED one back.
pool.disable("bb", "leak")
_, hb = call("/heartbeat", {"lease_id": b["lease_id"]})
assert hb.get("no_capacity")                                      # nothing free to move to yet
with pool.state() as st:
    st["accounts"][a["account"]]["limited_until"] = 0
_, hb = call("/heartbeat", {"lease_id": b["lease_id"]})
assert hb["rotate"]["account"] == a["account"]
assert call("/return", {"lease_id": hb["rotate"]["lease_id"]})[0] == 200   # restart failed: give back the new one
_, hb = call("/heartbeat", {"lease_id": b["lease_id"]})                  # still on its old lease...
assert hb["rotate"]["account"] == a["account"]                    # ...and still asked to move off the leak
# Giving the leaked one back makes the reservation its own.
call("/return", {"lease_id": b["lease_id"]})
assert {r["account"]: r["holder"] for r in pool.report()}[a["account"]] == "vm:vm2"
# The leaked account is never lent, even with everything else free.
with pool.state() as st:
    st["leases"].clear()
got = [call("/checkout", {"holder": "n%d" % i}) for i in range(3)]
assert [g[0] for g in got] == [200, 200, 409] and "bb" not in [g[1].get("account") for g in got], got

# A holder that stops heartbeating frees its login after the lease timeout.
with pool.state() as st:
    for l in st["leases"].values():
        l["expires"] = 0
assert call("/heartbeat", {"lease_id": rot["lease_id"]})[0] == 410
assert call("/checkout", {"holder": "vm6"})[0] == 200

# A holder whose login stopped working disables it for everyone and is moved off it.
with pool.state() as st:
    st["leases"].clear()
    for acc in st["accounts"].values():
        acc.update(disabled=False, limited_until=0)
_, x = call("/checkout", {"holder": "vm7"})
_, hb = call("/heartbeat", {"lease_id": x["lease_id"], "bad_login": True})
assert hb["rotate"]["account"] != x["account"]
assert "login stopped working" in {r["account"]: r for r in pool.report()}[x["account"]]["state"]

# remove: refused while held, then the token file and record are gone.
held_name = x["account"]
try:
    pool.remove(held_name)
    raise AssertionError("removed a held account")
except SystemExit:
    pass
call("/return", {"lease_id": x["lease_id"]}); call("/return", {"lease_id": hb["rotate"]["lease_id"]})
pool.remove(held_name)
assert not (tmp / "pool/accounts" / (held_name + ".token")).exists()
assert held_name not in [r["account"] for r in pool.report()]
pool.add(held_name, TOK[held_name])

# /status is unauthenticated: counts only, no names, holders or tokens.
st = json.load(urllib.request.urlopen("http://127.0.0.1:%d/claude-bank/status" % srv.server_port))
assert set(st) == {"accounts", "held", "usable"} and st["accounts"] == 3, st

# /token (older releases) and /skills keep their owner check.
ls.TOKEN_FILE, ls.SKILLS_FILE = tmp / "token", tmp / "skills.tar.gz"
assert call("/token")[0] == 503
ls.TOKEN_FILE.write_text("sk-ant-oat01-test\n")
assert call("/token") == (200, {"token": "sk-ant-oat01-test"})
assert call("/token", who="theirs")[0] == 401
ls.SKILLS_FILE.write_bytes(b"\x1f\x8bpretend")
assert call("/skills") == (200, b"\x1f\x8bpretend") and call("/skills", who="theirs")[0] == 401
# Bad input never becomes an account.
for bad in (("BAD NAME", TOK["aa"]), ("ok", "not-a-token")):
    try:
        pool.add(*bad)
        raise AssertionError("accepted %r" % (bad,))
    except SystemExit:
        pass
srv.shutdown()
print("lease-server self-check OK")
