#!/usr/bin/env python3
"""The Auth Bank's login pool: the owner's Claude accounts, each lent to at most one container.

An account is a `claude setup-token` login (one browser approval, about a year, no refresh), so
lending one never races a refresh the way a shared ~/.claude login does. The lease server lends them
(POST /checkout, /heartbeat, /return, after the Plow owner check); the owner runs this file:

    docker exec -i claude-bank-lease python3 /app/pool.py add NAME   < token     # token on stdin, never argv
    docker exec claude-bank-lease python3 /app/pool.py disable NAME --reason leak
    docker exec claude-bank-lease python3 /app/pool.py enable NAME
    docker exec claude-bank-lease python3 /app/pool.py list | usage

Usage is what the containers REPORT from their own Claude session logs: Claude has no per-account
usage API, so this is "tokens seen and limits hit", never "allowance left". A container that hits a
usage limit is lent a DIFFERENT account on its next heartbeat and keeps its old one until its Claude
is back on the same session (then it returns the old). Disabling an account (a leak) stops it being
lent and moves its holder off it the same way; revoking it is manual, in Claude's settings.
"""
import fcntl
import json
import os
import re
import sys
import time
import uuid
from contextlib import contextmanager
from pathlib import Path

POOL = Path(os.environ.get("POOL_DIR", "/pool"))
LIMIT_COOLDOWN = int(os.environ.get("POOL_LIMIT_COOLDOWN", str(5 * 3600)))  # Claude's window is ~5 h
NAME = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
USAGE_KEYS = ("input", "output", "cache_read", "cache_write")


def _token_path(name):
    return POOL / "accounts" / (name + ".token")


@contextmanager
def state():
    """pool.json under an exclusive lock: every read-modify-write of the pool goes through here."""
    POOL.mkdir(parents=True, exist_ok=True)
    with open(POOL / ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            st = json.loads((POOL / "pool.json").read_text())
        except (OSError, ValueError):
            st = {}
        st.setdefault("accounts", {})
        st.setdefault("leases", {})
        yield st
        tmp = POOL / "pool.json.tmp"
        tmp.write_text(json.dumps(st, indent=1))
        os.replace(tmp, POOL / "pool.json")


def _reap(st, now):
    for lid, l in list(st["leases"].items()):
        if l["expires"] < now:
            del st["leases"][lid]
    for l in st["leases"].values():          # a replacement whose reservation lapsed is no longer pending
        if l.get("replacement") not in st["leases"]:
            l.pop("replacement", None)


def _free(st, now, exclude=()):
    """Enabled accounts nobody holds and not inside a limit cooldown, least used today first."""
    held = {l["account"] for l in st["leases"].values()}
    today = time.strftime("%Y-%m-%d", time.gmtime(now))
    out = [n for n, a in st["accounts"].items()
           if not a.get("disabled") and n not in held and n not in exclude
           and a.get("limited_until", 0) <= now and _token_path(n).exists()]
    return sorted(out, key=lambda n: (st["accounts"][n].get("usage", {}).get("days", {}).get(today, 0), n))


def _lend(st, account, holder, ttl, now, **extra):
    lid = uuid.uuid4().hex
    st["leases"][lid] = dict(account=account, holder=holder, expires=now + ttl, started=now, **extra)
    return {"lease_id": lid, "account": account, "token": _token_path(account).read_text().strip()}


def checkout(holder, ttl, now=None):
    """One unheld login for `holder` (a restarted holder gets its own back), or None: no capacity."""
    now = now or time.time()
    with state() as st:
        _reap(st, now)
        for lid, l in st["leases"].items():
            if l["holder"] == holder and not l.get("pending_for"):
                l["expires"] = now + ttl
                return {"lease_id": lid, "account": l["account"], "token": _token_path(l["account"]).read_text().strip()}
        free = _free(st, now)
        return _lend(st, free[0], holder, ttl, now) if free else None


def _record(acct, delta, now):
    u = acct.setdefault("usage", {})
    u["total"] = u.get("total", 0) + delta
    day, hour = time.strftime("%Y-%m-%d", time.gmtime(now)), time.strftime("%Y-%m-%dT%H", time.gmtime(now))
    days, hours = u.setdefault("days", {}), u.setdefault("hours", {})
    days[day] = days.get(day, 0) + delta
    hours[hour] = hours.get(hour, 0) + delta
    for h in sorted(hours)[:-48]:            # keep two days of hours, enough for "last 5 h"
        del hours[h]
    for d in sorted(days)[:-35]:
        del days[d]


def heartbeat(lease_id, ttl, usage=None, limit_hit=False, bad_login=False, now=None):
    """Keep the lease; record the usage the holder saw. Returns None if the lease is gone, else
    {"ok": True} plus, when the holder must move (limit hit, or its account was disabled), either
    "rotate": {lease_id, account, token} (a different account, reserved; the old lease stays held)
    or "no_capacity": True. `bad_login`: the holder found the login does not work (expired, or
    revoked by hand), so the account is disabled for everyone."""
    now = now or time.time()
    with state() as st:
        _reap(st, now)
        l = st["leases"].get(lease_id)
        if not l:
            return None
        l["expires"] = now + ttl
        acct = st["accounts"].get(l["account"], {})
        seen = {k: int((usage or {}).get(k) or 0) for k in USAGE_KEYS}   # cumulative since the lease began
        prev = l.get("reported", {})
        delta = sum(max(0, seen[k] - prev.get(k, 0)) for k in USAGE_KEYS)
        if delta:
            _record(acct, delta, now)
        l["reported"] = {k: max(seen[k], prev.get(k, 0)) for k in USAGE_KEYS}
        if bad_login and not acct.get("disabled"):
            acct.update(disabled=True, disabled_reason="login stopped working", disabled_at=now)
        if limit_hit and not l.get("limit_seen"):
            l["limit_seen"] = True
            acct.setdefault("limit_hits", []).append(now)
            acct["limit_hits"] = acct["limit_hits"][-20:]
            acct["limited_until"] = now + LIMIT_COOLDOWN
        if not (l.get("limit_seen") or acct.get("disabled")):
            return {"ok": True}
        rep = st["leases"].get(l.get("replacement") or "")
        if rep:                                 # already reserved: hand the same one again
            rep["expires"] = now + ttl
            return {"ok": True, "rotate": {"lease_id": l["replacement"], "account": rep["account"],
                                           "token": _token_path(rep["account"]).read_text().strip()}}
        free = _free(st, now, exclude=(l["account"],))
        if not free:
            return {"ok": True, "no_capacity": True}
        r = _lend(st, free[0], l["holder"], ttl, now, pending_for=lease_id)
        l["replacement"] = r["lease_id"]
        return {"ok": True, "rotate": r}


def give_back(lease_id):
    """Free a lease. Returning the old one after a rotation makes its replacement the holder's own;
    returning a replacement (the restart failed) leaves the holder on its old one."""
    with state() as st:
        l = st["leases"].pop(lease_id, None)
        if not l:
            return False
        rep = st["leases"].get(l.get("replacement") or "")
        if rep:
            rep.pop("pending_for", None)
        for other in st["leases"].values():
            if other.get("replacement") == lease_id:
                other.pop("replacement", None)
        return True


def add(name, token):
    if not NAME.match(name):
        raise SystemExit("name: lowercase letters, digits and '-', at most 40")
    token = token.strip()
    if not token.startswith("sk-ant-") or len(token) < 40:
        raise SystemExit("that does not look like a Claude setup-token (it starts with sk-ant-)")
    p = _token_path(name)
    p.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(p.with_suffix(".tmp"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(token)
    os.replace(p.with_suffix(".tmp"), p)
    with state() as st:
        a = st["accounts"].setdefault(name, {})
        a.update(added=a.get("added") or time.time(), disabled=False)
        a.pop("disabled_reason", None)


def disable(name, reason="", enable=False):
    with state() as st:
        a = st["accounts"].get(name)
        if a is None:
            raise SystemExit("no account %r" % name)
        if enable:
            a["disabled"] = False
            a.pop("disabled_reason", None)
        else:
            a.update(disabled=True, disabled_reason=reason or "disabled", disabled_at=time.time())
        held = [l["holder"] for l in st["leases"].values() if l["account"] == name]
    return held


def report(now=None):
    """One row per account: state, holder, tokens reported today / last 5 h / total, last limit."""
    now = now or time.time()
    with state() as st:
        _reap(st, now)
        rows = []
        for n, a in sorted(st["accounts"].items()):
            u = a.get("usage", {})
            last5 = sum(v for h, v in u.get("hours", {}).items()
                        if h >= time.strftime("%Y-%m-%dT%H", time.gmtime(now - 5 * 3600)))
            holders = [l["holder"] + (" (reserved)" if l.get("pending_for") else "")
                       for l in st["leases"].values() if l["account"] == n]
            state_ = ("DISABLED: " + a.get("disabled_reason", "")) if a.get("disabled") else \
                ("limited until " + time.strftime("%H:%MZ", time.gmtime(a["limited_until"]))
                 if a.get("limited_until", 0) > now else "ok")
            hits = a.get("limit_hits", [])
            rows.append(dict(account=n, state=state_, holder=", ".join(holders) or "-",
                             today=u.get("days", {}).get(time.strftime("%Y-%m-%d", time.gmtime(now)), 0),
                             last_5h=last5, total=u.get("total", 0),
                             last_limit=time.strftime("%Y-%m-%d %H:%MZ", time.gmtime(hits[-1])) if hits else "-"))
        return rows


def main(argv):
    cmd = argv[0] if argv else "list"
    if cmd == "add" and len(argv) == 2:
        add(argv[1], sys.stdin.read())
        print("added %s (token not shown)" % argv[1])
    elif cmd in ("disable", "enable") and len(argv) >= 2:
        reason = " ".join(argv[argv.index("--reason") + 1:]) if "--reason" in argv else ""
        held = disable(argv[1], reason, enable=(cmd == "enable"))
        print("%sd %s" % (cmd, argv[1]))
        if cmd == "disable":
            if held:
                print("its holder moves to another account at its next heartbeat: " + ", ".join(held))
            print("Claude cannot revoke a login remotely: if it leaked, revoke it by hand in Claude's settings.")
    elif cmd in ("list", "usage"):
        rows = report()
        if not rows:
            print("pool is empty: add one with  python3 pool.py add NAME < token")
        for r in rows:
            print("{account:16} {state:28} holder={holder:40} today={today:>11,} last5h={last_5h:>11,} "
                  "total={total:>13,} last_limit={last_limit}".format(**r))
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
