#!/usr/bin/env python3
"""The Auth Bank over HTTPS: the owner's Claude logins for the owner's own cloud agents.

  POST /checkout  {holder}                      -> {lease_id, account, token}: one pool login, held by
                                                   this caller alone (409: no free login)
  POST /heartbeat {lease_id, usage, limit_hit}  -> keeps it; records the usage the caller saw; on a usage
                                                   limit (or a disabled account) adds "rotate": a
                                                   DIFFERENT login, reserved (the old one stays held)
  POST /return    {lease_id}                    -> frees it (after a rotation: the OLD one, once the
                                                   caller's Claude is back on the new one)
  POST /token                                   -> {token}: the single long-lived login, for releases
                                                   older than the pool client (transition only)
  POST /skills                                  -> the owner's personal Claude skills, a .tar.gz
  POST /beacon                                  -> logs one boot-step line from a VM (no auth, no secrets)
  GET  /status                                  -> pool counts only (it is unauthenticated)

The pool is pool.py (accounts are `claude setup-token` logins the owner adds over ssh; see there).
A setup-token has no refresh token, so lending one never races a refresh the way a shared ~/.claude
login does -- which is what killed the volume bank (every volume NEEDS-LOGIN since 09-27). The
volumes and lease.sh stay for spin.sh on this host; nothing here touches them any more.

Who may call: a caller proves it is one of the owner's Plow agents with a Plow index assertion
(minted in the VM through its PLOW_API_BASE proxy, 5 minutes, single purpose), which this server
resolves at Plow and compares to ALLOWED_OWNER_UID. No secret lives in any image.

/skills is the owner's skills (lease/sync-skills.py packs them on the owner's Mac): no credentials,
but the owner's hostnames, contacts and accounts, so never in the public image either.
"""
import json
import os
import sys
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORT = int(os.environ.get("PORT", "8797"))
PREFIX = os.environ.get("PATH_PREFIX", "/claude-bank")      # the funnel mount path, if kept
PLOW = os.environ.get("PLOW_API", "https://api.plow.co")
ALLOWED_OWNER = os.environ["ALLOWED_OWNER_UID"]
# A holder that stops heartbeating (destroyed: Plow gives no notice) frees its login after this.
LEASE_TTL = int(os.environ.get("LEASE_TTL", "600"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import pool  # noqa: E402
TOKEN_FILE = Path(os.environ.get("TOKEN_FILE", "/secret/claude-setup-token"))
SKILLS_FILE = Path(os.environ.get("SKILLS_FILE", "/secret/skills.tar.gz"))


def log(msg):
    print(time.strftime("%Y-%m-%dT%H:%M:%SZ ", time.gmtime()) + msg, flush=True)


def owner_of(assertion):
    req = urllib.request.Request(PLOW + "/v1/auth/index-identity/assertion",
                                 headers={"X-Plow-Index-Assertion": assertion})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.load(r).get("owner_uid")
    except Exception:
        return None


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
            rows = pool.report()
            return self._send(200, {"accounts": len(rows), "held": sum(r["holder"] != "-" for r in rows),
                                    "usable": sum(r["state"] == "ok" for r in rows)})
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
        if p == "/skills":
            try:
                data = SKILLS_FILE.read_bytes()
            except OSError:
                return self._send(503, {"error": "no skills stored on the bank yet"})
            log("skills handed to %s" % str(body.get("holder") or "?")[:120])
            self.send_response(200)
            self.send_header("Content-Type", "application/gzip")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            return self.wfile.write(data)
        if p == "/checkout":
            holder = str(body.get("holder") or "")[:120]
            if not holder:
                return self._send(400, {"error": "holder required"})
            got = pool.checkout("vm:" + holder, LEASE_TTL)
            if not got:
                log("no free login for %s" % holder)
                return self._send(409, {"error": "no-capacity: every login in the pool is held, limited or disabled"})
            log("checkout %s -> %s" % (got["account"], holder))
            return self._send(200, got)
        if p == "/heartbeat":
            out = pool.heartbeat(str(body.get("lease_id") or ""), LEASE_TTL,
                                 usage=body.get("usage") if isinstance(body.get("usage"), dict) else None,
                                 limit_hit=bool(body.get("limit_hit")), bad_login=bool(body.get("bad_login")))
            if out is None:
                return self._send(410, {"error": "lease gone"})   # stop using that login: it may be lent again
            if out.get("rotate"):
                log("rotate: reserved %s for %s" % (out["rotate"]["account"], str(body.get("holder") or "?")[:120]))
            elif out.get("no_capacity"):
                log("rotate wanted, no free login (%s)" % str(body.get("holder") or "?")[:120])
            return self._send(200, out)
        if p == "/return":
            ok = pool.give_back(str(body.get("lease_id") or ""))
            log("returned a lease (%s)" % ("ok" if ok else "already gone"))
            return self._send(200 if ok else 410, {"ok": ok})
        self._send(404, {"error": "not found"})

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    log(f"auth bank lease server on 127.0.0.1:{PORT}, owner {ALLOWED_OWNER}")
    ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
