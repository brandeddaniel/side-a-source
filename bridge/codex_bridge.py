"""Codex adapter: CLI-owned credentials, read through the app-server protocol.

Rate limits come from official RPCs. The only token Side A reads is the Mac login's
id_token, to name its account; no login is ever copied or written.
"""
from __future__ import annotations
import base64
import json
import os
from pathlib import Path
import select
import subprocess
import time

MAX_MESSAGE = 32 * 1024 * 1024


class RPC:
    """Short-lived stdio client used only for identity and saved-thread checks."""
    def __init__(self, command, env, cwd):
        self.process = subprocess.Popen(command, env=env, cwd=cwd, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.buffer = b""
        self.sequence = 0
        self.deadline = time.monotonic() + 25
        try:
            self.call("initialize", {"clientInfo": {"name": "side_a", "version": "0.3.0"}})
            self.send({"method": "initialized"})
        except BaseException:
            self.close()
            raise

    def send(self, value):
        self.process.stdin.write(json.dumps(value).encode() + b"\n")
        self.process.stdin.flush()

    def call(self, method, params=None):
        self.sequence += 1
        identifier = self.sequence
        self.send({"id": identifier, "method": method, "params": params or {}})
        while time.monotonic() < self.deadline:
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                response = json.loads(line)
                if response.get("id") == identifier and "method" not in response:
                    if "error" in response:
                        message = str((response.get("error") or {}).get("message") or "")
                        # Keep only what the app acts on: revoked logins need sign-in, rate limits back off.
                        # Revocation first: its message also says "failed to fetch codex rate limits".
                        if "401" in message or "token_revoked" in message:
                            raise ValueError("Sign in again: Codex rejected this login.")
                        if "429" in message or "too many requests" in message.lower():
                            raise ValueError("Codex usage is rate-limited (429).")
                        raise ValueError("Codex could not complete the account check. Update Codex and retry.")
                    return response["result"]
            if select.select([self.process.stdout], [], [], .1)[0]:
                data = os.read(self.process.stdout.fileno(), 65536)
                if not data:
                    break
                self.buffer += data
                if len(self.buffer) > MAX_MESSAGE:
                    break
        raise ValueError("Codex did not respond to the account or conversation check.")

    def close(self):
        if self.process.stdin:
            self.process.stdin.close()
        try:
            # EOF lets app-server flush conversation state before termination.
            try: self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                self.process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            raise ValueError("Codex did not shut down gracefully.") from None
        finally:
            if self.process.stdout:
                self.process.stdout.close()

    def __enter__(self): return self
    def __exit__(self, *_): self.close()



def codex_binary():
    for path in [Path.home()/".local/bin/codex", Path.home()/".npm-global/bin/codex", Path("/opt/homebrew/bin/codex"), Path("/usr/local/bin/codex")]:
        if path.is_file() and os.access(path, os.X_OK): return str(path)
    raise ValueError("Install Codex CLI first: https://developers.openai.com/codex/cli")


def prepare_profile(root, identifier):
    import sidea_bridge as common
    profile = common.profile_dir(root, identifier)
    profile.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(profile, 0o700)
    shared = root / "codex-conversations"
    shared.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Current Codex keeps its history index in sqlite_home, rollout bodies in
    # sessions, and writer coordination in thread-writer-locks. Auth stays private.
    for name in ("sessions", "archived_sessions", "thread-writer-locks"):
        target, link = shared / name, profile / name
        target.mkdir(parents=True, exist_ok=True, mode=0o700)
        if link.is_symlink():
            if link.resolve() != target.resolve():
                raise ValueError("Unexpected Codex conversation directory. Profile left untouched.")
        elif link.exists():
            raise ValueError("An independent Codex conversation directory exists. Profile left untouched.")
        else:
            link.symlink_to(target, target_is_directory=True)
    return profile


def command(root, binary=None):
    return [binary or codex_binary(), "-c", 'cli_auth_credentials_store="file"',
            "-c", 'forced_login_method="chatgpt"', "-c", 'model_provider="openai"',
            "-c", "sqlite_home=" + json.dumps(str(root / "codex-conversations"))]


def environment(root, account):
    import sidea_bridge as common
    env = common.clean_environment(prepare_profile(root, account["id"]))
    env["CODEX_HOME"] = env.pop("CLAUDE_CONFIG_DIR")
    return env


def is_mac_login(account):
    return bool(account.get("email")) and global_email() == account["email"].casefold()


def invocation(root, account, binary=None):
    """Command and environment for the account's one home: ~/.codex for the Mac's own
    Codex login (run as the user normally would), its profile otherwise."""
    env = environment(root, account)
    if is_mac_login(account):
        env["CODEX_HOME"] = str(global_home())
        return [binary or codex_binary()], env
    return command(root, binary), env


def owned(root, account):
    """Refuses a profile holding another account's login, e.g. a copy left by Side A 0.4."""
    if is_mac_login(account):
        return
    email = login_email(read_auth(prepare_profile(root, account["id"])))
    if email != account.get("email", "").casefold():
        raise ValueError(f"Sign in to {account['name']} again; its saved login belongs to another account."
                         if email else f"Sign in to {account['name']} again.")


def account_status(root, account, binary=None):
    base, env = invocation(root, account, binary)
    with RPC(base + ["app-server"], env, root) as rpc:
        data = rpc.call("account/read", {"refreshToken": False})
    identity = data.get("account") or {}
    email = identity.get("email")
    method = identity.get("type", "")
    return {"loggedIn": method == "chatgpt" and isinstance(email, str) and bool(email.strip()),
            "email": email if isinstance(email, str) else "", "authMethod": method}


def global_home():
    return Path.home() / ".codex"


def login_email(auth):
    # The email claim of the id_token payload; the signature is irrelevant for matching.
    token = ((auth or {}).get("tokens") or {}).get("id_token") or ""
    try:
        payload = token.split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    except (IndexError, ValueError):
        return ""
    return (claims.get("email") or "").casefold()


def global_email():
    return login_email(read_auth(global_home()))


def read_auth(home):
    try:
        return json.loads((home / "auth.json").read_text())
    except (FileNotFoundError, ValueError):
        return None



def global_account(config):
    email = global_email()
    return next((a for a in config.get("accounts", []) if a.get("provider") == "codex"
                 and email and a.get("email", "").casefold() == email), None)


def adopt(root, account):
    """Record the Mac's own Codex login as an account. Its login stays in ~/.codex."""
    email = global_email()
    if not email:
        raise ValueError("No Codex login was found on this Mac.")
    prepare_profile(root, account["id"])
    return {"email": email}


def usage(root, account):
    owned(root, account)
    base, env = invocation(root, account)
    with RPC(base + ["app-server"], env, root) as rpc:
        data = rpc.call("account/rateLimits/read")
    limits = data.get("rateLimits") or {}
    windows = []
    for key in ("primary", "secondary"):
        window = limits.get(key)
        if not window:
            continue
        minutes = window.get("windowDurationMins") or 0
        label = "5-hour" if minutes == 300 else "Weekly" if minutes == 10080 else f"{minutes // 60}-hour"
        windows.append({"id": "five_hour" if minutes == 300 else "seven_day" if minutes == 10080 else key,
                        "label": label, "percent": float(window.get("usedPercent") or 0),
                        "resetsAt": window.get("resetsAt")})
    return {"windows": windows, "stale": False}


def prime(root, account):
    owned(root, account)
    base, env = invocation(root, account)
    result = subprocess.run(base + ["exec", "--skip-git-repo-check", "-s", "read-only", "Reply with OK."],
        env=env, cwd=root, capture_output=True, timeout=180, stdin=subprocess.DEVNULL)
    if result.returncode != 0:
        raise ValueError(f"{account['name']} could not start its 5-hour window.")
