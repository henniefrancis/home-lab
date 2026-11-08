"""End-to-end check of the Authentik forward-auth chain (driven by scripts/test-authentik-config.sh, never run on the Pi).

Runs inside the pinned Authentik image (its Python has `requests`) on the test Docker network, where every lab host name
resolves to the test Traefik. All values are dummies passed in through the environment; the TLS certificate is a
throw-away self-signed wildcard, so verification is off here (and only here).

Prints one `PASS name` or `FAIL name (detail)` line per check and exits 1 if any check failed.
"""

import base64
import hashlib
import hmac
import os
import struct
import sys
import time
from urllib.parse import parse_qs, urljoin, urlparse

import requests
import urllib3

urllib3.disable_warnings()

DOMAIN = os.environ["DOMAIN"]
ADMIN_PW = os.environ["ADMIN_PW"]
OUTSIDER_PW = os.environ["OUTSIDER_PW"]
OUTSIDER_TOTP_HEX = os.environ["OUTSIDER_TOTP_HEX"]
AUTH = f"auth.{DOMAIN}"
TRAEFIK = f"traefik.{DOMAIN}"
DASH = f"dashboard.{DOMAIN}"
FLOW = f"https://{AUTH}/api/v3/flows/executor/default-authentication-flow/"

failures = 0


def check(name, ok, detail=""):
    global failures
    if ok:
        print(f"PASS  {name}")
    else:
        failures += 1
        print(f"FAIL  {name} ({detail})")


def totp(key: bytes, at=None) -> str:
    counter = int((at or time.time()) // 30)
    digest = hmac.new(key, struct.pack(">Q", counter), hashlib.sha1).digest()
    offset = digest[-1] & 0x0F
    code = (struct.unpack(">I", digest[offset : offset + 4])[0] & 0x7FFFFFFF) % 10**6
    return f"{code:06d}"


def new_session():
    s = requests.Session()
    s.verify = False
    return s


def post_flow(s, body):
    headers = {"X-authentik-CSRF": s.cookies.get("authentik_csrf", ""), "Content-Type": "application/json"}
    r = s.post(FLOW, json=body, headers=headers)
    r.raise_for_status()
    return r.json()


def login(s, user, password, totp_hex=None):
    """Walk the stock authentication flow. Returns (final component, info about the MFA step)."""
    info = {"mfa_seen": False, "mfa_no_device": None, "mfa_choices": []}
    r = s.get(FLOW)
    r.raise_for_status()
    challenge = r.json()
    for _ in range(12):
        comp = challenge.get("component")
        if comp == "ak-stage-identification":
            challenge = post_flow(s, {"component": comp, "uid_field": user})
        elif comp == "ak-stage-password":
            challenge = post_flow(s, {"component": comp, "password": password})
        elif comp == "ak-stage-authenticator-validate":
            info["mfa_seen"] = True
            devices = challenge.get("device_challenges") or []
            if devices:
                info["mfa_no_device"] = False
                challenge = post_flow(s, {"component": comp, "code": totp(bytes.fromhex(totp_hex))})
            else:
                info["mfa_no_device"] = True
                info["mfa_choices"] = [c["meta_model_name"] for c in challenge.get("configuration_stages", [])]
                return "needs-enrolment", info, challenge
        else:
            return comp, info, challenge
    return "too-many-steps", info, challenge


def enrol_totp(s, challenge):
    """Pick the TOTP configuration stage offered by the enforced MFA step, enrol with the secret it shows, finish login."""
    stage = next(c for c in challenge["configuration_stages"] if "authenticator_totp" in c["meta_model_name"])
    c = post_flow(s, {"component": "ak-stage-authenticator-validate", "selected_stage": stage["pk"]})
    for _ in range(6):
        if c.get("component") == "ak-stage-authenticator-totp":
            secret = parse_qs(urlparse(c["config_url"]).query)["secret"][0]
            key = base64.b32decode(secret + "=" * (-len(secret) % 8))
            c = post_flow(s, {"component": "ak-stage-authenticator-totp", "code": totp(key)})
        else:
            return c.get("component"), c
    return "too-many-steps", c


def visit(s, host, path="/", headers=None, limit=12):
    """GET following redirects by hand (every host name resolves to the test Traefik)."""
    url = f"https://{host}{path}"
    r = None
    for _ in range(limit):
        r = s.get(url, allow_redirects=False, headers=headers)
        if r.status_code in (301, 302, 303, 307, 308):
            url = urljoin(url, r.headers["Location"])
            continue
        break
    return r, url


def proxy_cookies(s, host):
    return [c for c in s.cookies if c.name.startswith("authentik_proxy_") and c.domain == host]


# --- 1. unauthenticated request ------------------------------------------------------------------------------------
anon = new_session()
r = anon.get(f"https://{TRAEFIK}/", allow_redirects=False)
check("unauthenticated dashboard request is redirected to the Authentik authorize endpoint",
      r.status_code == 302 and r.headers.get("Location", "").startswith(f"https://{AUTH}/application/o/authorize/"),
      f"{r.status_code} {r.headers.get('Location', '')[:80]}")
redirect_uri = parse_qs(urlparse(r.headers.get("Location", "")).query).get("redirect_uri", [""])[0]
check("the login callback returns to the APP host (per-app login), not to a shared domain",
      redirect_uri.startswith(f"https://{TRAEFIK}/outpost.goauthentik.io/callback"), redirect_uri)
raw = r.raw.headers.getlist("Set-Cookie") if hasattr(r.raw.headers, "getlist") else []
sc = next((c for c in raw if c.startswith("authentik_proxy_")), "")
check("outpost cookie is host-only (no Domain attribute), HttpOnly, Secure, SameSite=Lax",
      sc != "" and "domain=" not in sc.lower() and "httponly" in sc.lower() and "secure" in sc.lower() and "samesite=lax" in sc.lower(), sc[:60])
check("security headers are on the redirect (HSTS)", "max-age=" in r.headers.get("Strict-Transport-Security", ""))
body = anon.get(f"https://{TRAEFIK}/dashboard/", allow_redirects=False)
check("dashboard path without a session is also redirected (no content)", body.status_code == 302 and b"<title>Traefik" not in body.content)
body = anon.get(f"https://{TRAEFIK}/api/rawdata", allow_redirects=False)
check("dashboard API without a session is redirected (no data)", body.status_code == 302 and b"routers" not in body.content)

# --- 2. MFA enforced for akadmin (bootstrap password) --------------------------------------------------------------
admin = new_session()
comp, info, ch = login(admin, "akadmin", ADMIN_PW)
check("bootstrap password logs akadmin in as far as the MFA step", comp == "needs-enrolment", comp)
check("MFA is enforced: a user without a device is sent to configure one, not let through",
      info["mfa_seen"] and info["mfa_no_device"] is True, str(info))
check("TOTP and WebAuthn are the offered methods",
      any("authenticator_totp" in m for m in info["mfa_choices"]) and any("authenticator_webauthn" in m for m in info["mfa_choices"]), str(info["mfa_choices"]))
# (a second session: following an application authorize URL replaces the pending login plan of the session that does it)
probe = new_session()
login(probe, "akadmin", ADMIN_PW)
r, final = visit(probe, TRAEFIK)
check("password alone does not open the dashboard (session is not established before MFA)",
      b"<title>Traefik" not in r.content and urlparse(final).hostname == AUTH and "/if/flow/" in final, f"{r.status_code} {final[:80]}")
me = probe.get(f"https://{AUTH}/api/v3/core/users/me/", allow_redirects=False)
check("password alone gives no API session", me.status_code in (401, 403), str(me.status_code))

comp, c = enrol_totp(admin, ch)
check("enrolling TOTP inside the login flow completes the login", comp == "xak-flow-redirect", f"{comp}")
me = admin.get(f"https://{AUTH}/api/v3/core/users/me/", allow_redirects=False)
check("after MFA the session is established (akadmin)", me.status_code == 200 and me.json()["user"]["username"] == "akadmin", str(me.status_code))

# --- 3. SSO into the dashboard, per-app cookies ------------------------------------------------------------------
r, final = visit(admin, TRAEFIK)
check("SSO then serves the Traefik dashboard", r.status_code == 200 and b"<title>Traefik" in r.content, f"{r.status_code} {final[:80]}")
r = admin.get(f"https://{TRAEFIK}/api/rawdata", allow_redirects=False)
check("the dashboard API answers with a session", r.status_code == 200 and "routers" in r.json(), str(r.status_code))
check("one proxy cookie exists, for the traefik host only", len(proxy_cookies(admin, TRAEFIK)) == 1 and not proxy_cookies(admin, DASH))
check("no cookie is domain-wide (none has a leading-dot domain, none targets the parent domain)",
      all(not c.domain.startswith(".") and c.domain != DOMAIN for c in admin.cookies), str([(c.name, c.domain) for c in admin.cookies]))
r = admin.get(f"https://{DASH}/", allow_redirects=False)
check("the second app does not accept the first app's cookie (per-app login)", r.status_code == 302 and r.headers["Location"].startswith(f"https://{AUTH}/"), f"{r.status_code}")

# --- 4. headers: the backend sees the real identity; forged identity headers are replaced -----------------------
forged = {"X-authentik-username": "mallory", "X-authentik-groups": "evil", "X-authentik-uid": "0"}
r, final = visit(admin, DASH, "/", headers=forged)
text = r.text if r is not None else ""
low = {ln.split(": ", 1)[0].lower(): ln.split(": ", 1)[1] for ln in text.splitlines() if ": " in ln}
check("backend (whoami) receives the authenticated user, not the forged one",
      r.status_code == 200 and low.get("x-authentik-username") == "akadmin" and "mallory" not in text, f"{r.status_code} {low.get('x-authentik-username')}")
check("backend receives the group claim homelab-admins and not the forged group",
      "homelab-admins" in low.get("x-authentik-groups", "") and "evil" not in text, low.get("x-authentik-groups", ""))
check("two apps, two different cookies", len(proxy_cookies(admin, DASH)) == 1 and proxy_cookies(admin, DASH)[0].value != proxy_cookies(admin, TRAEFIK)[0].value)

# --- 5. a valid user outside homelab-admins is denied ---------------------------------------------------------------
out = new_session()
comp, info, ch = login(out, "outsider", OUTSIDER_PW, OUTSIDER_TOTP_HEX)
check("outsider (password + TOTP) logs in to Authentik itself", comp == "xak-flow-redirect", comp)
r, final = visit(out, TRAEFIK)
check("outsider is denied the dashboard (not a member of homelab-admins; fail-closed binding)",
      b"<title>Traefik" not in r.content and urlparse(final).hostname == AUTH and "Permission denied" in r.text, f"{r.status_code} {final[:80]}")
r = out.get(f"https://{TRAEFIK}/api/rawdata", allow_redirects=False)
check("outsider gets no dashboard data", r.status_code != 200 and "routers" not in r.text[:2000], str(r.status_code))

print(f"\n{failures} check(s) failed" if failures else "\nAll end-to-end checks passed")
sys.exit(1 if failures else 0)
