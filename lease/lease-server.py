#!/usr/bin/env python3
"""The auth bank's lease, over HTTPS -- for containers that cannot mount a bank volume.

spin.sh mounts a leased claude-auth-bank-NN volume at ~/.claude. A Plow cloud VM runs on
another machine and cannot, so the same lease moves the LOGIN instead of the mount:

  POST /checkout  {holder}               -> {lease_id, volume, credentials}
  POST /heartbeat {lease_id, credentials} -> keeps the lease; stores the refreshed login
  POST /return    {lease_id, credentials} -> stores the login back, frees the volume
  GET  /status                            -> lease.sh status (names and holders only)
  POST /token                             -> {token}: the owner's long-lived login (claude setup-token)
  POST /beacon                            -> logs one boot-step line from a VM (no auth, no secrets)

/token is the simpler source: a setup-token login lasts about a year and has no refresh token, so
every one of the owner's VMs can use the same one at once without logging each other out, and it
cannot die from sitting idle the way a bank volume's login does. It lives in TOKEN_FILE on this
server only -- never in an image -- and goes only to the owner's own agents (same check as below).

The one-holder rule is lease.sh's own: every checkout is `lease.sh acquire`, every free is
`lease.sh release`. While a VM holds a volume, the bank never touches that login except to
store what the VM hands back, so exactly one process ever refreshes it -- which is the whole
reason the bank exists (two refreshers of one login log each other out).

Who may check out: a caller proves it is one of the owner's Plow agents with a Plow index
assertion (minted in the VM through its PLOW_API_BASE proxy, 5 minutes, single purpose),
which this server resolves at Plow and compares to ALLOWED_OWNER_UID. No secret lives in
any image.

A volume whose login is dead (no refresh token) is left leased to NEEDS-LOGIN, so acquire
skips it until it is authed again.
"""
import json
import os
import subprocess
import threading
import time
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
LEASE_SH = str(HERE / "lease.sh")
BANK_ROOT = Path(os.environ.get("BANK_ROOT", "/bank"))      # each volume mounted at /bank/<name>
LEASES = Path(os.environ.get("LEASE_DIR", "/leases"))
PORT = int(os.environ.get("PORT", "8797"))
PREFIX = os.environ.get("PATH_PREFIX", "/claude-bank")      # the funnel mount path, if kept
PLOW = os.environ.get("PLOW_API", "https://api.plow.co")
ALLOWED_OWNER = os.environ["ALLOWED_OWNER_UID"]
# ponytail: a VM that stops heartbeating (destroyed: Plow gives no notice) frees its volume
# after LEASE_TTL with the last login it stored. Ceiling: a VM cut off longer than that and
# then back would share the login with the next holder; upgrade path is fencing the VM by
# lease_id on every heartbeat reply (it already stops if told its lease is gone).
LEASE_TTL = int(os.environ.get("LEASE_TTL", "1800"))
VOL_UID = int(os.environ.get("VOL_UID", "1001"))            # bank volumes are owned by tester
TOKEN_FILE = Path(os.environ.get("TOKEN_FILE", "/secret/claude-setup-token"))
LOCK = threading.Lock()
os.environ["LEASE_DIR"] = str(LEASES)


def log(msg):
    print(time.strftime("%Y-%m-%dT%H:%M:%SZ ", time.gmtime()) + msg, flush=True)


def lease(*args):
    r = subprocess.run([LEASE_SH, *args], capture_output=True, text=True)
    return r.returncode, r.stdout.strip()


def meta_path(vol):
    return LEASES / vol / "lease.json"      # beside lease.sh's own `holder` file


def read_meta(vol):
    try:
        return json.loads(meta_path(vol).read_text())
    except (OSError, ValueError):
        return {}


def creds_path(vol):
    return BANK_ROOT / vol / ".credentials.json"


def login_alive(creds):
    o = (creds or {}).get("claudeAiOauth") or {}
    exp = o.get("refreshTokenExpiresAt") or 0
    return bool(o.get("refreshToken")) and (not exp or exp / 1000 > time.time())


def store(vol, creds):
    if not login_alive(creds):
        return  # never overwrite a bank login with a dead one
    p = creds_path(vol)
    tmp = p.with_suffix(".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(creds, f)
    os.chown(tmp, VOL_UID, -1)
    os.replace(tmp, p)


def owner_of(assertion):
    req = urllib.request.Request(PLOW + "/v1/auth/index-identity/assertion",
                                 headers={"X-Plow-Index-Assertion": assertion})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.load(r).get("owner_uid")
    except Exception:
        return None


def by_lease_id(lease_id):
    for d in LEASES.glob("*/lease.json"):
        m = read_meta(d.parent.name)
        if m.get("lease_id") == lease_id:
            return d.parent.name, m
    return None, None


def reap():
    """Free the volumes of holders that stopped heartbeating."""
    for d in LEASES.glob("*/lease.json"):
        vol, m = d.parent.name, read_meta(d.parent.name)
        if m.get("expires", 0) < time.time():
            lease("release", vol)
            log(f"expired {vol} held by {m.get('holder')}")


def checkout(holder):
    reap()
    for d in LEASES.glob("*/lease.json"):   # a restarted VM gets its own volume back
        m = read_meta(d.parent.name)
        if m.get("holder") == holder:
            vol = d.parent.name
            m["expires"] = time.time() + LEASE_TTL
            meta_path(vol).write_text(json.dumps(m))
            return 200, {"lease_id": m["lease_id"], "volume": vol,
                         "credentials": json.loads(creds_path(vol).read_text())}
    while True:
        rc, vol = lease("acquire", holder)
        if rc != 0:
            return 409, {"error": "no free login in the bank"}
        try:
            creds = json.loads(creds_path(vol).read_text())
        except (OSError, ValueError):
            creds = None
        if login_alive(creds):
            break
        # Dead login: keep it locked, relabelled, so acquire stops handing it out; next one.
        (LEASES / vol / "holder").write_text("NEEDS-LOGIN\t%s\n" % time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
        log(f"{vol} has no live login, parked as NEEDS-LOGIN")
    m = {"holder": holder, "lease_id": uuid.uuid4().hex, "expires": time.time() + LEASE_TTL}
    meta_path(vol).write_text(json.dumps(m))
    log(f"checkout {vol} -> {holder}")
    return 200, {"lease_id": m["lease_id"], "volume": vol, "credentials": creds}


class H(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _path(self):
        p = self.path.split("?", 1)[0]
        return p[len(PREFIX):] or "/" if PREFIX and p.startswith(PREFIX) else p

    def do_GET(self):
        if self._path() == "/status":
            with LOCK:
                reap()
                return self._send(200, {"status": lease("status")[1].splitlines()})
        self._send(404, {"error": "not found"})

    def do_POST(self):
        if self._path() == "/beacon":
            # A VM saying how far its boot got: the one view into a machine we cannot log into.
            # Unauthenticated, so it carries step names only and is logged short and printable.
            raw = self.rfile.read(min(int(self.headers.get("Content-Length") or 0), 300))
            line = "".join(c if c.isprintable() else " " for c in raw.decode("utf-8", "replace"))[:240]
            log("beacon %s" % line)
            return self._send(200, {"ok": True})
        if owner_of(self.headers.get("X-Plow-Index-Assertion", "")) != ALLOWED_OWNER:
            return self._send(401, {"error": "not the bank owner's agent"})
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        except ValueError:
            return self._send(400, {"error": "bad json"})
        p = self._path()
        if p == "/token":
            try:
                token = TOKEN_FILE.read_text().strip()
            except OSError:
                token = ""
            if not token:
                return self._send(503, {"error": "no login stored on the bank yet"})
            log("token handed to %s" % str(body.get("holder") or "?")[:120])
            return self._send(200, {"token": token})
        with LOCK:
            if p == "/checkout":
                holder = str(body.get("holder") or "")[:120]
                if not holder:
                    return self._send(400, {"error": "holder required"})
                return self._send(*checkout("vm:" + holder))
            vol, m = by_lease_id(str(body.get("lease_id") or ""))
            if not vol:
                # The VM must stop using the login: someone else may hold it now.
                return self._send(410, {"error": "lease gone"})
            if body.get("credentials"):
                store(vol, body["credentials"])
            if p == "/heartbeat":
                m["expires"] = time.time() + LEASE_TTL
                meta_path(vol).write_text(json.dumps(m))
                return self._send(200, {"ok": True, "volume": vol})
            if p == "/return":
                lease("release", vol)
                log(f"returned {vol} from {m.get('holder')}")
                return self._send(200, {"ok": True})
        self._send(404, {"error": "not found"})

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    LEASES.mkdir(parents=True, exist_ok=True)
    log(f"auth bank lease server on 127.0.0.1:{PORT}, owner {ALLOWED_OWNER}")
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
