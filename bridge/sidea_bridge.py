#!/usr/bin/env python3
"""Side A's stdlib-only account bridge.

Every login lives in exactly one place. The account this Mac is signed in to keeps the
CLI's default Keychain item; every other account keeps its own profile slot. Side A never
copies a login between places: refresh tokens rotate, and two holders of one token
eventually invalidate each other. "Using" an account records which slot new `claude`
commands should read (CLAUDE_SECURESTORAGE_CONFIG_DIR, set by a small shell function).
Tokens are never logged or printed.
"""
from __future__ import annotations
import argparse
import contextlib
import datetime
import fcntl
import functools
import hashlib
import json
import os
import re
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata
import urllib.error
import urllib.request
import uuid

GLOBAL_SERVICE = "Claude Code-credentials"
# Endpoints Claude Code itself calls with the same login (CLI 2.1.292).
USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
PROFILE_URL = "https://api.anthropic.com/api/oauth/profile"
WINDOW_LABELS = {"five_hour": "5-hour", "seven_day": "Weekly", "seven_day_opus": "Weekly Opus",
                 "seven_day_sonnet": "Weekly Sonnet"}


def atomic_json(path: Path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temp = tempfile.mkstemp(dir=path.parent, prefix=".write-")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, separators=(",", ":"))
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def read_json(path: Path, default=None):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return default


def read_json_quiet(path: Path, default=None):
    """For files other programs write (session records): a half-written one is skipped, not fatal."""
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def account_by_id(config, identifier):
    # Require canonical UUIDs before using any profile identifier as a path.
    if str(uuid.UUID(identifier)).lower() != identifier.lower():
        raise ValueError("Invalid account identifier")
    return next(a for a in config["accounts"] if a["id"] == identifier)


def provider_of(account):
    provider = account.get("provider", "claude")
    if provider not in {"claude", "codex"}: raise ValueError("Unsupported agent. Update Side A.")
    return provider


def profile_dir(root, identifier):
    uuid.UUID(identifier)
    return root / "profiles" / identifier


def prepare_profile(root, identifier):
    profile = profile_dir(root, identifier)
    profile.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(profile, 0o700)
    shared = root / "conversations"
    shared.mkdir(parents=True, exist_ok=True, mode=0o700)
    projects = profile / "projects"
    if projects.is_symlink():
        if projects.resolve() != shared.resolve():
            raise ValueError("Unexpected conversation directory. Profile left untouched.")
    elif projects.exists():
        raise ValueError("An independent conversation directory already exists. Profile left untouched.")
    else:
        projects.symlink_to(shared, target_is_directory=True)
    return profile


def clean_environment(profile):
    # Avoid inherited API keys, OAuth overrides, nested-session markers, or cloud
    # provider settings silently authenticating a different account.
    env = {k: os.environ[k] for k in (
        "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "TERM",
        "COLORTERM", "SSH_AUTH_SOCK", "TERM_PROGRAM", "TERM_PROGRAM_VERSION"
    ) if k in os.environ}
    env["PATH"] = os.pathsep.join([
        str(Path.home() / ".local/bin"), str(Path.home() / ".npm-global/bin"), "/opt/homebrew/bin", "/usr/local/bin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin"
    ])
    env["CLAUDE_CONFIG_DIR"] = str(profile)
    return env


def claude_binary():
    for path in [Path.home()/".local/bin/claude", Path("/opt/homebrew/bin/claude"), Path("/usr/local/bin/claude")]:
        if path.is_file() and os.access(path, os.X_OK):
            return str(path)
    raise ValueError("Install Claude Code first: https://code.claude.com/docs/en/setup")


def auth_status(root, account, binary=None):
    if provider_of(account) == "codex":
        from codex_bridge import account_status
        return account_status(root, account, binary)
    profile = prepare_profile(root, account["id"])
    env = clean_environment(profile)
    env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = selector_for(root, account)
    result = subprocess.run([binary or claude_binary(), "auth", "status", "--json"],
        env=env, capture_output=True, timeout=25, text=True)
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        raise ValueError("Claude did not return a valid account status. Update Claude Code and retry.") from None
    if not isinstance(data, dict):
        raise ValueError("Claude returned an unsupported account-status shape.")
    logged_in = result.returncode == 0 and data.get("loggedIn") is True
    # Only subscription OAuth identities belong here. The token, not the config file, names the owner.
    method = data.get("authMethod", "")
    email = token_email(root, read_secret(home_service(root, account))) or data.get("email") or ""
    return {"loggedIn": logged_in and method == "claude.ai" and bool(email),
            "email": email, "authMethod": method}


def profile_service(root, identifier):
    # Mirrors the CLI: suffix = sha256 of the NFC config-dir path, first 8 hex chars.
    path = str(profile_dir(root, identifier))
    return f"{GLOBAL_SERVICE}-{hashlib.sha256(unicodedata.normalize('NFC', path).encode()).hexdigest()[:8]}"


def keychain_user():
    return os.environ.get("USER") or "claude-code-user"


@functools.lru_cache(maxsize=None)
def read_secret(service):
    # Logins are only written by renew(), under Claude Code's refresh lock.
    result = subprocess.run(["security", "find-generic-password", "-a", keychain_user(), "-s", service, "-w"],
                            capture_output=True, text=True, timeout=15)
    if result.returncode != 0:
        return None
    raw = result.stdout.strip()
    if not raw.startswith("{"):
        raw = bytes.fromhex(raw).decode()
    return json.loads(raw)


@contextlib.contextmanager
def selection_lock(root, name="selection.lock"):
    runtime = root / "runtime"
    runtime.mkdir(parents=True, exist_ok=True, mode=0o700)
    with open(runtime / name, "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def expired(blob):
    return ((blob or {}).get("claudeAiOauth") or {}).get("expiresAt", 0) / 1000 < time.time() + 60


_identities = {}


def token_email(root, blob):
    """Who a stored login belongs to, from the profile endpoint. Cached on disk per token;
    a failed lookup is retried after ten minutes, never on every poll."""
    token = ((blob or {}).get("claudeAiOauth") or {}).get("accessToken")
    if not token:
        return ""
    key = hashlib.sha256(token.encode()).hexdigest()[:24]
    if key in _identities:
        return _identities[key]
    path = root / "runtime" / "identity-cache.json"
    cache = read_json(path, {}) or {}
    entry = cache.get(key)
    if isinstance(entry, str) or (isinstance(entry, dict) and entry.get("retry", 0) > time.time()) or expired(blob):
        _identities[key] = entry if isinstance(entry, str) else ""
        return _identities[key]
    try:
        data = post_json(PROFILE_URL, None, {"Authorization": f"Bearer {token}", "anthropic-beta": "oauth-2025-04-20"}, method="GET")
        email = ((data.get("account") or {}).get("email") or "").casefold()
    except (urllib.error.URLError, ValueError, OSError):
        email = ""
    # Bridges run in parallel; re-read under a lock so one lookup never drops another's result.
    with selection_lock(root, "identity.lock"):
        cache = read_json(path, {}) or {}
        cache = dict(list(cache.items())[-50:])
        cache[key] = email or {"retry": time.time() + 600}
        atomic_json(path, cache)
    _identities[key] = email
    return email


def mac_email(root):
    """The account the Mac's default login belongs to."""
    return token_email(root, read_secret(GLOBAL_SERVICE))


def account_for_email(config, email, provider="claude"):
    return next((a for a in config.get("accounts", []) if provider_of(a) == provider
                 and email and a.get("email", "").casefold() == email), None)


def homes_path(root):
    return root / "runtime" / "homes.json"


def home_slot(root, account):
    """Where the account's login lives: "mac" for the Mac login, else a profile id. A swap moves
    logins between slots, so an account's slot can be another account's profile."""
    email = account.get("email", "").casefold()
    if email and mac_email(root) == email:
        return "mac"
    homes = read_json(homes_path(root), {}) or {}
    slot = homes.get(account["id"])
    if slot and slot != "mac":
        profile_dir(root, slot)  # validates the id
        return slot
    # Its own profile may hold a login another account moved in (say its login was in the Mac
    # item, which was then signed in to someone else); it then takes the slot that account left.
    slot, seen = account["id"], set()
    while slot not in seen:
        seen.add(slot)
        mover = next((other for other, held in homes.items() if held == slot and other != account["id"]), None)
        if not mover:
            return slot
        slot = mover
    raise ValueError(f"Sign in to {account['name']} again.")


def slot_service(root, slot):
    return GLOBAL_SERVICE if slot == "mac" else profile_service(root, slot)


def slot_selector(root, slot):
    return "" if slot == "mac" else str(profile_dir(root, slot))


def home_service(root, account):
    """The one Keychain item that holds this account's login."""
    return slot_service(root, home_slot(root, account))


def owned_login(root, account, idle_ok=False):
    """The account's login, refusing a slot that holds someone else's or one not yet verified.
    An expired login is only returned unverified when the caller treats it as idle."""
    blob = read_secret(home_service(root, account))
    if not blob or "claudeAiOauth" not in blob:
        raise ValueError(f"Sign in to {account['name']} again.")
    owner = token_email(root, blob)
    if owner == account.get("email", "").casefold() and owner:
        return blob
    if not owner and expired(blob) and idle_ok:
        return blob
    if not owner:
        raise ValueError("Can't confirm whose login this is yet; retrying later.")
    raise ValueError(f"Sign in to {account['name']} again; its saved login belongs to another account.")


def selection_path(root):
    return root / "runtime" / "claude-selector"


def selector_for(root, account):
    """CLAUDE_SECURESTORAGE_CONFIG_DIR for an account: empty selects the Mac login."""
    return slot_selector(root, home_slot(root, account))


def write_selector(root, value):
    path = selection_path(root)
    fd, temp = tempfile.mkstemp(dir=path.parent, prefix=".selector-")
    with os.fdopen(fd, "w") as stream:
        stream.write(value + "\n")
    os.replace(temp, path)


def global_account(config, root):
    """The account new `claude` commands use. One file is the source of truth: the selected
    profile path, or empty for the Mac login. A selection whose login no longer belongs
    to its account is ignored, so the answer always matches what the shell launches."""
    mac = account_for_email(config, mac_email(root))
    path = selection_path(root)
    chosen = path.read_text().strip() if path.exists() else ""
    if not chosen:
        return mac
    account = next((a for a in config.get("accounts", []) if provider_of(a) == "claude" and selector_for(root, a) == chosen), None)
    if account and token_email(root, read_secret(home_service(root, account))) in ("", account["email"].casefold()):
        # An unknown owner (lookup failing) keeps the choice; reads still refuse it until verified.
        return account
    return mac


def repair_selection(root, config):
    """Points the selector at what global_account reports, e.g. after the Mac login changed."""
    with selection_lock(root):
        # Fresh reads: a trade may have just moved logins.
        read_secret.cache_clear()
        write_pins(root, config)
        account = global_account(config, root)
        wanted = selector_for(root, account) if account else ""
        path = selection_path(root)
        if (path.read_text().strip() if path.exists() else "") != wanted:
            write_selector(root, wanted)
    return account


def post_json(url, body, headers=None, method="POST"):
    request = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(),
        method=method, headers={"Content-Type": "application/json", "User-Agent": "claude-cli (side-a)", **(headers or {})})
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response)


def epoch(value):
    if value in (None, ""):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def claude_usage(root, config, account):
    blob = owned_login(root, account, idle_ok=True)
    if expired(blob):
        # Nobody has used this login since it expired, so its last reading still holds.
        raise ValueError("Login idle; its last reading still applies.")
    oauth = blob["claudeAiOauth"]
    token = oauth["accessToken"]
    try:
        data = post_json(USAGE_URL, None, {"Authorization": f"Bearer {token}",
                                           "anthropic-beta": "oauth-2025-04-20"}, method="GET")
    except urllib.error.HTTPError as error:
        if error.code == 401:
            raise ValueError(f"Sign in to {account['name']} again; the login was rejected.") from None
        raise ValueError(f"Usage is unavailable right now (HTTP {error.code}).") from None
    windows = [{"id": key, "label": label, "percent": float(data[key].get("utilization") or 0),
                "resetsAt": epoch(data[key].get("resets_at"))}
               for key, label in WINDOW_LABELS.items() if isinstance(data.get(key), dict)]
    # Per-model weekly caps now arrive as scoped entries in `limits`, e.g. {"model": {"display_name": "Fable"}}.
    for limit in data.get("limits") or []:
        model = ((limit.get("scope") or {}).get("model") or {}).get("display_name") if isinstance(limit, dict) else None
        if limit.get("kind") == "weekly_scoped" and model:
            windows.append({"id": "model:" + model.casefold(), "label": "Weekly " + model,
                            "percent": float(limit.get("percent") or 0), "resetsAt": epoch(limit.get("resets_at"))})
    return {"windows": windows, "stale": False, "capacity": plan_capacity(oauth), "extra": extra_usage(data)}


def extra_usage(data):
    """Paid usage past the plan limits: whether it is on and what this month has cost, in dollars."""
    spend = data.get("spend") if isinstance(data.get("spend"), dict) else {}
    money = lambda value: (value.get("amount_minor") or 0) / 10 ** (value.get("exponent") or 0) if isinstance(value, dict) else None
    legacy = data.get("extra_usage") if isinstance(data.get("extra_usage"), dict) else {}
    enabled = bool(spend.get("enabled", legacy.get("is_enabled")))
    used = money(spend.get("used"))
    if used is None:
        used = float(legacy.get("used_credits") or 0) / 100
    limit = money(spend.get("limit"))
    if limit is None and legacy.get("monthly_limit") is not None:
        limit = float(legacy["monthly_limit"]) / 100
    return {"enabled": enabled, "used": used, "limit": limit,
            "currency": (spend.get("used") or {}).get("currency") or legacy.get("currency") or "USD"}


def plan_capacity(oauth):
    # Relative quota size, so 1% of a Max 20x account outweighs 1% of a Pro account.
    tier = f"{oauth.get('rateLimitTier') or ''} {oauth.get('subscriptionType') or ''}".lower()
    return 20.0 if "20x" in tier else 5.0 if "5x" in tier or "max" in tier else 1.0


def usage(root, config, account):
    if provider_of(account) == "codex":
        import codex_bridge
        return codex_bridge.usage(root, account)
    return claude_usage(root, config, account)


def activate(root, config, account):
    """Point new `claude` commands at `account`'s own login. No login is copied or written."""
    if provider_of(account) == "codex":
        raise ValueError("Codex accounts are tracked here; switch Codex with `codex login`.")
    blob = owned_login(root, account)
    if token_email(root, blob) != account.get("email", "").casefold():
        raise ValueError(f"Use {account['name']} once so Side A can confirm its login, then try again.")
    with selection_lock(root):
        write_selector(root, selector_for(root, account))


def adopt(root, account):
    """Record the Mac's own login as an account. Its login stays where it is."""
    if provider_of(account) == "codex":
        import codex_bridge
        return codex_bridge.adopt(root, account)
    email = mac_email(root)
    if not email:
        raise ValueError("No Claude login was found on this Mac.")
    profile = prepare_profile(root, account["id"])
    data = read_json(Path.home() / ".claude.json", {}) or {}
    if (data.get("oauthAccount") or {}).get("emailAddress", "").casefold() == email:
        atomic_json(profile / ".claude.json", {"oauthAccount": data["oauthAccount"], "hasCompletedOnboarding": True})
    return {"email": email}


SHELL_MARK = "# side-a shell integration"


def login_stamps(root, config):
    """When each Claude account's stored login expires. A new value means a sign-in or refresh
    happened, so the app re-reads that account at once instead of waiting out a back-off."""
    stamps = {}
    for account in config.get("accounts", []):
        if provider_of(account) == "claude" and account.get("ready"):
            stamps[account["id"]] = ((read_secret(home_service(root, account)) or {}).get("claudeAiOauth") or {}).get("expiresAt") or 0
    return stamps


def login_ends(root, config):
    """When each Claude sign-in stops renewing (ms). Refreshes do not move it, so a new sign-in
    is needed about monthly; the app warns ahead of it."""
    ends = {}
    for account in config.get("accounts", []):
        if provider_of(account) == "claude" and account.get("ready"):
            end = ((read_secret(home_service(root, account)) or {}).get("claudeAiOauth") or {}).get("refreshTokenExpiresAt")
            if end:
                ends[account["id"]] = end
    return ends


def pins_path(root):
    return root / "runtime" / "accounts"


def pin_name(name):
    """What `sidea use <name>` accepts for an account: its name, lowercased, dashes for the rest."""
    # ponytail: two accounts whose names slug alike share one pin; rename one if that ever matters.
    return re.sub(r"[^a-z0-9]+", "-", name.casefold()).strip("-") or "account"


def write_pins(root, config):
    """One file per Claude account holding its selector, so a terminal can stay on one account
    with `sidea use <name>` while Autopilot moves the rest. A slot holding another account's
    login gets no pin."""
    folder = pins_path(root)
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    wanted = {}
    for account in config.get("accounts", []):
        if provider_of(account) != "claude" or not account.get("ready"):
            continue
        if token_email(root, read_secret(home_service(root, account))) in ("", account.get("email", "").casefold()):
            wanted[pin_name(account["name"])] = selector_for(root, account)
    for path in folder.iterdir():
        if path.name not in wanted:
            path.unlink(missing_ok=True)
    for name, value in wanted.items():
        path = folder / name
        if not path.exists() or path.read_text().strip() != value:
            path.write_text(value + "\n")


def shell_snippet(root):
    selector = shlex.quote(str(root / "runtime" / "claude-selector"))
    fable = shlex.quote(str(fable_model_path(root)))
    pins = shlex.quote(str(pins_path(root)))
    # A preexec hook, not a `claude` function: an alias to a path (claude=~/.claude/local/claude)
    # would skip a function, but every command runs after preexec. One line, so removal stays simple.
    # SIDE_A_PIN, set by `sidea use`, keeps one terminal on one account.
    # The fable alias is remapped only while Side A asks for it, and only unset if Side A set it.
    # It also runs once when sourced: preexec for `source ~/.zshrc && claude` fired before the hook existed.
    return (f"{SHELL_MARK}\n"
            f"_side_a_select() {{ local f={selector} m=; [ -n \"${{SIDE_A_PIN-}}\" ] && [ -f {pins}/\"$SIDE_A_PIN\" ] && f={pins}/\"$SIDE_A_PIN\"; "
            f"if [ -f \"$f\" ]; then export CLAUDE_SECURESTORAGE_CONFIG_DIR=\"$(<\"$f\")\"; else unset CLAUDE_SECURESTORAGE_CONFIG_DIR; fi; "
            f"[ -f {fable} ] && m=\"$(<{fable})\"; "
            f"if [ -n \"$m\" ]; then export ANTHROPIC_DEFAULT_FABLE_MODEL=\"$m\" _SIDE_A_FABLE=1; "
            f"elif [ -n \"${{_SIDE_A_FABLE-}}\" ]; then unset ANTHROPIC_DEFAULT_FABLE_MODEL _SIDE_A_FABLE; fi; }}; "
            f"sidea() {{ local p=\"${{${{2:l}}// /-}}\"; if [ \"$1\" = use ] && [ -f {pins}/\"$p\" ]; then export SIDE_A_PIN=\"$p\"; echo \"This terminal now uses $p.\"; "
            f"elif [ \"$1\" = auto ]; then unset SIDE_A_PIN; echo \"This terminal follows Side A again.\"; "
            f"else echo \"sidea use <account> keeps this terminal on one account; sidea auto follows Side A. Accounts: $(ls {pins} 2>/dev/null | tr '\\n' ' ')\"; fi; }}; "
            f"autoload -Uz add-zsh-hook && add-zsh-hook preexec _side_a_select && _side_a_select\n")


# While every account's Fable limit is spent, new `claude` commands resolve the fable alias to this.
FABLE_FALLBACK_MODEL = "claude-opus-5-5"


def fable_model_path(root):
    return root / "runtime" / "claude-fable-model"


def set_fable_fallback(root, enabled):
    path = fable_model_path(root)
    if not enabled:
        path.unlink(missing_ok=True)
        return
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temp = path.with_name(path.name + ".tmp")
    temp.write_text(FABLE_FALLBACK_MODEL)
    os.replace(temp, path)


def set_shell(root, enabled):
    """Adds or removes the ~/.zshrc line that points each command at Side A's choice."""
    if not enabled:
        # Shells already open keep the hook; with no selector it leaves their commands alone.
        with selection_lock(root):
            selection_path(root).unlink(missing_ok=True)
    path = Path.home() / ".zshrc"
    text = path.read_text() if path.exists() else ""
    lines = text.splitlines(keepends=True)
    kept, skip = [], False
    for line in lines:
        if line.startswith(SHELL_MARK):
            skip = True
            continue
        if skip:
            skip = False
            continue
        kept.append(line)
    text = "".join(kept)
    if len(kept) < len(lines):
        # Drop the blank separator line that was added with the function.
        text = text.rstrip("\n") + "\n" if text.strip() else ""
    if enabled:
        text = text.rstrip("\n") + ("\n\n" if text.strip() else "") + shell_snippet(root)
    path = path.resolve()  # a symlinked dotfile stays a symlink
    temp = path.with_name(".zshrc.side-a")
    temp.write_text(text)
    if path.exists():
        os.chmod(temp, path.stat().st_mode & 0o777)
    os.replace(temp, path)


def shell_installed(root):
    """Whether switching is on; an older snippet is upgraded in place."""
    path = Path.home() / ".zshrc"
    text = path.read_text() if path.exists() else ""
    if SHELL_MARK in text and shell_snippet(root) not in text:
        set_shell(root, True)
    return SHELL_MARK in text


@contextlib.contextmanager
def claude_refresh_lock(folder, timeout=30):
    """Holds Claude Code's own refresh lock for one login while Side A renews it. Claude Code keeps
    it in the login's storage folder (CLAUDE_SECURESTORAGE_CONFIG_DIR, or ~/.claude for the Mac
    login), so every session on that login waits for it, and the server never sees a refresh token
    used twice. Same format as Claude Code's lock library: a directory, stale after 60 s idle."""
    path = Path(folder) / ".oauth_refresh.lock"
    deadline = time.time() + timeout
    while True:
        try:
            path.mkdir()
            break
        except FileExistsError:
            try:
                if time.time() - path.stat().st_mtime > 60:
                    path.rmdir()
                    continue
            except OSError:
                pass
            if time.time() > deadline:
                raise ValueError("Claude Code is refreshing a login right now; Side A will try again shortly.")
            time.sleep(0.5)
        except FileNotFoundError:
            path.parent.mkdir(parents=True, exist_ok=True)
    stop = threading.Event()
    def keep_fresh():
        while not stop.wait(5):
            with contextlib.suppress(OSError):
                os.utime(path)
    threading.Thread(target=keep_fresh, daemon=True).start()
    try:
        yield
    finally:
        stop.set()
        with contextlib.suppress(OSError):
            path.rmdir()


def run_as(root, account, args, timeout):
    """Runs claude as the account's own login with clean settings. The child takes the login's
    refresh lock itself, so Side A must not hold it here."""
    env = clean_environment(prepare_profile(root, account["id"]))
    # The profile's clean settings keep the user's hooks and CLAUDE.md out; the selector
    # picks the account's own login, which the CLI refreshes itself if needed.
    env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = selector_for(root, account)
    return subprocess.run([claude_binary(), *args], env=env, cwd=root, capture_output=True,
                          text=True, timeout=timeout, stdin=subprocess.DEVNULL)


# Claude Code's own OAuth client and token endpoint: renewing here is the same request Claude Code makes.
TOKEN_URL = "https://platform.claude.com/v1/oauth/token"
CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"


SWAP_JOURNAL = "Side A swap journal"


def swapped_path(root):
    return root / "runtime" / "swapped.json"


def trade(login, item):
    """`login` placed in `item`: MCP logins belong to the item's sessions, so they stay."""
    moved = {k: v for k, v in login.items() if k != "mcpOAuth"}
    if item and "mcpOAuth" in item:
        moved["mcpOAuth"] = item["mcpOAuth"]
    return moved


def same_login(root, blob, login):
    """`blob` is `login`'s account: the same tokens, or, once a session renewed it, the same owner."""
    mine, theirs = (blob or {}).get("claudeAiOauth") or {}, (login or {}).get("claudeAiOauth") or {}
    if not mine or not theirs:
        return False
    if mine.get("refreshToken") and mine.get("refreshToken") == theirs.get("refreshToken"):
        return True
    owner = token_email(root, blob)
    return bool(owner) and owner == token_email(root, login)


def swap_locks(root, slots):
    stack = contextlib.ExitStack()
    for slot in slots:
        stack.enter_context(claude_refresh_lock(slot_selector(root, slot) or str(Path.home() / ".claude")))
    return stack


def slot_owner(root, config, slot):
    """The library account whose verified login is in `slot`, if any."""
    return account_for_email(config, token_email(root, read_secret(slot_service(root, slot))))


def swap(root, config, slot, other, share=False):
    """Moves every session reading `slot` to `other`'s login: the login in `slot` and `other`'s
    trade Keychain items. Running sessions re-read their item within about 30 s. Nothing is
    copied: a journal is saved first, and finish_swap() completes the trade from it, now or
    after a crash. `share` lets `other`'s own sessions continue on the login from `slot`; the app
    asks for it only when that login still has room for every one of them."""
    if provider_of(other) != "claude":
        raise ValueError("Only Claude accounts trade logins.")
    if slot != "mac":
        profile_dir(root, slot)  # validates the id
    with selection_lock(root), selection_lock(root, "renew.lock"):
        read_secret.cache_clear()
        finish_swap(root)
        # Resolved under the locks, so a trade that just finished is seen.
        account = slot_owner(root, config, slot)
        target = home_slot(root, other)
        if not account or account["id"] == other["id"] or target == slot:
            raise ValueError("These two logins can't trade places.")
        slots = [slot, target]
        if any(signing_in(root, s) for s in slots):
            raise ValueError("An account is signing in; trading later.")
        with swap_locks(root, slots):
            # Checked last, right before the writes, not from the app's last look: a session started
            # meanwhile must not get the full login.
            busy = busy_slots(root, config)
            if busy is None or (target in busy and not share):
                raise ValueError("A session is using that account now.")
            read_secret.cache_clear()
            logins = [read_secret(slot_service(root, slot)), owned_login(root, other)]
            if token_email(root, logins[0]) != account.get("email", "").casefold():
                raise ValueError("Can't confirm whose login this is yet; retrying later.")
            # Where each account's own login ends up. A second sign-in of the same account
            # (not its home) is moved without becoming its home.
            moves = {other["id"]: slot}
            if home_slot(root, account) == slot:
                moves[account["id"]] = target
            write_secret(SWAP_JOURNAL, {"slots": slots, "moves": moves,
                                        "logins": [trade(login, None) for login in logins]})
            # Finished while the refresh locks still hold, so no session refreshes a login that is
            # briefly in both items; a failure that outlasts this is finished by the next bridge run.
            for attempt in range(3):
                try:
                    finish_swap(root, locked=True)
                    break
                except (ValueError, OSError, subprocess.TimeoutExpired):
                    if attempt == 2:
                        raise
                    time.sleep(1)


def finish_swap(root, locked=False):
    """Completes a trade from its journal. Always forward, never back, using the newest copy of each
    login (a session may have renewed one), so each login ends in exactly one item. Callers hold
    selection.lock and renew.lock; the refresh locks are taken here unless `locked`."""
    read_secret.cache_clear()  # a journal read before the locks may already be finished
    journal = read_secret(SWAP_JOURNAL)
    if not journal:
        return
    slots, moves, logins = journal["slots"], journal["moves"], journal["logins"]
    with contextlib.ExitStack() as stack:
        if not locked:
            stack.enter_context(swap_locks(root, slots))
        services = [slot_service(root, slot) for slot in slots]
        read_secret.cache_clear()
        items = [read_secret(service) for service in services]
        # Only the two journaled logins are in these slots. What the trade wrote carries the journal's
        # tokens, so an item matching neither was never written: it is that slot's original login,
        # renewed by a session (its owner may not be looked up yet).
        def which(index, item):
            if same_login(root, item, logins[0]):
                return 0
            if same_login(root, item, logins[1]):
                return 1
            return index if item and item.get("claudeAiOauth") else None
        firsts = [item for i, item in enumerate(items) if which(i, item) == 0]
        seconds = [item for i, item in enumerate(items) if which(i, item) == 1]
        newest = lambda copies: max(copies, key=lambda blob: blob["claudeAiOauth"].get("expiresAt") or 0)
        wanted = [trade(newest([logins[1]] + seconds), items[0]), trade(newest([logins[0]] + firsts), items[1])]
        for service, item, blob in zip(services, items, wanted):
            if item != blob:
                write_secret(service, blob)
        homes = read_json(homes_path(root), {}) or {}
        homes.update(moves)
        # The Mac login is found by its owner, so only moves into other profiles are recorded.
        atomic_json(homes_path(root), {k: v for k, v in homes.items() if v not in (k, "mac")})
        # A statusline that was mid-write keeps its old file time, so readings from before are dropped.
        swapped = read_json(swapped_path(root), {}) or {}
        atomic_json(swapped_path(root), {**swapped, **{slot: time.time() for slot in slots}})
        for slot in slots:
            (live_dir(root) / f"{slot}.json").unlink(missing_ok=True)
        deleted = subprocess.run(["security", "delete-generic-password", "-a", keychain_user(), "-s", SWAP_JOURNAL],
                                 capture_output=True, timeout=15)
        read_secret.cache_clear()
        if deleted.returncode != 0 and read_secret(SWAP_JOURNAL):
            raise ValueError("The trade finished but its journal could not be removed; retrying.")


def process_environment(pid):
    """A process's argv[0] and environment, exactly as the kernel holds them (what ps -E prints,
    without the ambiguity of argv text that looks like an environment variable)."""
    import ctypes
    libc = ctypes.CDLL(None, use_errno=True)
    mib = (ctypes.c_int * 3)(1, 49, pid)  # CTL_KERN, KERN_PROCARGS2
    size = ctypes.c_size_t(0)
    if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0:
        return None
    buffer = ctypes.create_string_buffer(size.value)
    if libc.sysctl(mib, 3, buffer, ctypes.byref(size), None, 0) != 0:
        return None
    raw = buffer.raw[:size.value]
    argc = int.from_bytes(raw[:4], "little")
    parts = [part for part in raw[4:].split(b"\0") if part]
    # parts: executable path, argv[0..argc-1], then environment entries.
    if len(parts) < argc + 1:
        return None
    env = dict(entry.decode(errors="replace").split("=", 1) for entry in parts[argc + 1:] if b"=" in entry)
    return parts[1].decode(errors="replace") if argc else parts[0].decode(errors="replace"), env


def busy_slots(root, config):
    """The slots running claude processes read their login from, from each process's environment
    (Claude Code's own rule: CLAUDE_SECURESTORAGE_CONFIG_DIR, else CLAUDE_CONFIG_DIR, empty is the
    Mac login). None when processes can't be listed, so nothing is traded blind."""
    try:
        listing = subprocess.run(["ps", "-o", "pid=,comm=", "-U", keychain_user()], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if listing.returncode != 0:
        return None
    # Every profile on disk, not only listed accounts: a removed account's profile may hold a moved login.
    profiles = [p.name for p in (root / "profiles").glob("*") if p.is_dir()]
    services = {profile_service(root, slot): slot for slot in profiles + [a["id"] for a in config.get("accounts", [])]
                if is_uuid(slot)}
    services[GLOBAL_SERVICE] = "mac"
    busy = set()
    for line in listing.stdout.splitlines():
        pid, _, command = line.strip().partition(" ")
        program = Path(command.strip())
        if program.name != "claude" and program.parent.name != "versions":
            continue
        found = process_environment(int(pid))
        if found is None:
            try:
                os.kill(int(pid), 0)
            except OSError:
                continue  # exited meanwhile
            return None  # running but unreadable: unknown, so nothing is traded
        env = found[1]
        store = env.get("CLAUDE_SECURESTORAGE_CONFIG_DIR")
        if store is None:
            store = env.get("CLAUDE_CONFIG_DIR") or ""
        service = GLOBAL_SERVICE if not store else \
            f"{GLOBAL_SERVICE}-{hashlib.sha256(unicodedata.normalize('NFC', store).encode()).hexdigest()[:8]}"
        if service in services:
            busy.add(services[service])
    return busy


def is_uuid(value):
    try:
        uuid.UUID(value)
        return True
    except (ValueError, TypeError):
        return False


def signing_in_path(root, slot):
    return root / "runtime" / f"signing-in-{slot}"


def signing_in(root, slot):
    """A sign-in child is writing this slot; its pid is in the marker."""
    try:
        os.kill(int(signing_in_path(root, slot).read_text()), 0)
        return True
    except (OSError, ValueError):
        return False


def busy_logins(root, config):
    """Each slot a running claude reads, with the library account whose login is in it."""
    slots = busy_slots(root, config)
    if slots is None:
        return None
    return [{"slot": slot, "account": (slot_owner(root, config, slot) or {}).get("id")} for slot in sorted(slots)]


def verify_idle_owner(root, account, blob):
    """An expired login can't be looked up until it is renewed; until then the CLI's own
    record of who signed in must name this account."""
    if not token_email(root, blob) and (not account.get("email") or
            auth_status(root, account).get("email", "").casefold() != account["email"].casefold()):
        raise ValueError(f"Sign in to {account['name']} again.")


# security -i reads commands in chunks; Claude Code writes through stdin up to this length, argv beyond.
STDIN_LIMIT = 4032


def write_secret(service, blob):
    """Replaces a stored login exactly as Claude Code writes it: hex through stdin when it fits,
    so the token stays out of process lists, else as an argument like Claude Code does."""
    hexed = json.dumps(blob, separators=(",", ":")).encode().hex()
    command = f'add-generic-password -U -a "{keychain_user()}" -s "{service}" -X "{hexed}" '
    for _ in range(3):
        if len(command) <= STDIN_LIMIT:
            result = subprocess.run(["security", "-i"], input=command + "\n", capture_output=True, text=True, timeout=15)
        else:
            result = subprocess.run(["security", "add-generic-password", "-U", "-a", keychain_user(), "-s", service, "-X", hexed],
                                    capture_output=True, text=True, timeout=15)
        read_secret.cache_clear()
        if result.returncode == 0 and "error" not in result.stderr.lower() and read_secret(service) == blob:
            return
        time.sleep(0.5)
    raise ValueError("The renewed login could not be saved. Sign in to this account again.")


def renew(root, config, account):
    """Renews an expired login exactly as Claude Code does, so its limits stay readable around the
    clock at no cost. Under Claude Code's refresh lock, and re-read inside it: if a session renewed
    the login first, that one is used, so a refresh token is never spent twice."""
    service = home_service(root, account)
    if not expired(read_secret(service)):
        return
    verify_idle_owner(root, account, owned_login(root, account, idle_ok=True))
    # One Side A renewal or trade at a time; a trade in between moves the login, so re-resolve.
    with selection_lock(root, "renew.lock"):
        read_secret.cache_clear()
        if home_service(root, account) != service:
            return
        folder = selector_for(root, account) or str(Path.home() / ".claude")
        with claude_refresh_lock(folder):
            _renew(root, account, service)


def _renew(root, account, service):
    # Fresh from the Keychain, not this run's cache: a session may have renewed it meanwhile.
    read_secret.cache_clear()
    blob = read_secret(service)
    if not expired(blob):
        return
    oauth = (blob or {}).get("claudeAiOauth") or {}
    if not oauth.get("refreshToken"):
        raise ValueError(f"Sign in to {account['name']} again; its login ended.")
    body = {"grant_type": "refresh_token", "refresh_token": oauth["refreshToken"], "client_id": CLIENT_ID}
    if oauth.get("scopes"):
        body["scope"] = " ".join(oauth["scopes"])
    try:
        data = post_json(TOKEN_URL, body)
    except urllib.error.HTTPError as error:
        if error.code in (400, 401, 403):
            raise ValueError(f"Sign in to {account['name']} again; its login ended.") from None
        raise ValueError(f"Renewing the login failed (HTTP {error.code}); retrying later.") from None
    if not data.get("access_token") or not data.get("expires_in"):
        raise ValueError("Renewing the login returned an unexpected answer; retrying later.")
    oauth.update(accessToken=data["access_token"], refreshToken=data.get("refresh_token") or oauth["refreshToken"],
                 expiresAt=int((time.time() + float(data["expires_in"])) * 1000))
    if data.get("refresh_token_expires_in"):
        oauth["refreshTokenExpiresAt"] = int((time.time() + float(data["refresh_token_expires_in"])) * 1000)
    # Only the Claude login is replaced: MCP logins a session saved meanwhile are kept.
    read_secret.cache_clear()
    write_secret(service, {**(read_secret(service) or blob), "claudeAiOauth": oauth})


def prime(root, config, account):
    """Send one tiny message so the account's 5-hour window starts now instead of at first real use."""
    if provider_of(account) == "codex":
        from codex_bridge import prime as codex_prime
        return codex_prime(root, account)
    verify_idle_owner(root, account, owned_login(root, account, idle_ok=True))
    result = run_as(root, account, ["-p", "Reply with OK.", "--model", "haiku", "--max-turns", "1"], 120)
    if result.returncode != 0:
        raise ValueError(f"{account['name']} could not start its 5-hour window.")


def scan_transcript(path, previous=None):
    """Token totals per (local day, project, model) for one transcript, plus responses per
    local hour of each day. Transcripts are append-only, so a grown file is read from where
    the previous scan stopped; only complete lines are counted."""
    previous = previous if previous and previous.get("offset", 0) <= path.stat().st_size else None
    totals = {key: list(values) for key, values in (previous or {}).get("totals", {}).items()}
    hours = {day: list(counts) for day, counts in (previous or {}).get("hours", {}).items()}
    # Duplicates of one response are adjacent, so the last few keys cover the seam.
    seen = {tuple(key) for key in (previous or {}).get("tail", [])}
    recent = list((previous or {}).get("tail", []))
    offset = (previous or {}).get("offset", 0)
    with open(path, "rb") as stream:
        stream.seek(offset)
        for line in stream:
            if not line.endswith(b"\n"):
                break
            offset += len(line)
            if b'"usage"' not in line:
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            message = entry.get("message") or {}
            usage = message.get("usage") if isinstance(message, dict) else None
            if not isinstance(usage, dict) or not entry.get("timestamp"):
                continue
            # Streaming writes one line per content block; count each API response once.
            key = (message.get("id"), entry.get("requestId"))
            if key != (None, None):
                if key in seen:
                    continue
                seen.add(key)
                recent = (recent + [list(key)])[-20:]
            moment = datetime.datetime.fromisoformat(entry["timestamp"].replace("Z", "+00:00")).astimezone()
            day = moment.date().isoformat()
            hours.setdefault(day, [0] * 24)[moment.hour] += 1
            bucket = totals.setdefault(f"{day}\t{entry.get('cwd') or ''}\t{message.get('model') or ''}", [0, 0, 0, 0])
            for index, field in enumerate(("input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")):
                bucket[index] += int(usage.get(field) or 0)
    return {"totals": totals, "hours": hours, "offset": offset, "tail": recent}


def scan_codex(path, previous=None):
    """Token totals for one Codex session log, in the same shape as scan_transcript.
    Each token_count event carries the session's running total; counting the change
    between events keeps a repeated event from being counted twice."""
    previous = previous if previous and previous.get("offset", 0) <= path.stat().st_size else None
    totals = {key: list(values) for key, values in (previous or {}).get("totals", {}).items()}
    hours = {day: list(counts) for day, counts in (previous or {}).get("hours", {}).items()}
    state = dict((previous or {}).get("codex") or {"model": "", "cwd": "", "last": [0, 0, 0, 0]})
    offset = (previous or {}).get("offset", 0)
    with open(path, "rb") as stream:
        stream.seek(offset)
        for line in stream:
            if not line.endswith(b"\n"):
                break
            offset += len(line)
            if b'"turn_context"' not in line and b'"session_meta"' not in line and b'"token_count"' not in line:
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            payload = entry.get("payload") or {}
            if entry.get("type") in ("turn_context", "session_meta"):
                state["model"] = payload.get("model") or state["model"]
                state["cwd"] = payload.get("cwd") or state["cwd"]
                continue
            info = (payload.get("info") or {}) if payload.get("type") == "token_count" else {}
            total, last = info.get("total_token_usage") or {}, info.get("last_token_usage") or {}
            if not (total or last) or not entry.get("timestamp"):
                continue
            # Input includes cached input; split it so cached reads count as cache reads.
            vector = lambda usage: [int(usage.get("input_tokens") or 0) - int(usage.get("cached_input_tokens") or 0),
                                    int(usage.get("output_tokens") or 0), int(usage.get("cache_write_input_tokens") or 0),
                                    int(usage.get("cached_input_tokens") or 0)]
            now = vector(total) if total else None
            # Like ccusage: the turn's own usage when the running total moved (it can restart after
            # compaction), else the growth of the total. A repeated event moves nothing.
            if last and (now is None or now != state["last"]):
                delta = vector(last)
            else:
                delta = [max(a - b, 0) for a, b in zip(now or state["last"], state["last"])]
            if now is not None:
                state["last"] = now
            if not any(delta):
                continue
            moment = datetime.datetime.fromisoformat(entry["timestamp"].replace("Z", "+00:00")).astimezone()
            day = moment.date().isoformat()
            hours.setdefault(day, [0] * 24)[moment.hour] += 1
            bucket = totals.setdefault(f"{day}\t{state['cwd']}\t{state['model']}", [0, 0, 0, 0])
            for index, value in enumerate(delta):
                bucket[index] += value
    return {"totals": totals, "hours": hours, "offset": offset, "codex": state}


def recent_model(within=1800):
    """Model of the newest Claude Code response in the last half hour, so Autopilot can plan
    around a model-specific cap. Only the newest session counts."""
    # ponytail: newest session wins; per-terminal models would need the shell hook to report them.
    cutoff, newest = time.time() - within, None
    folder = Path.home() / ".claude" / "projects"
    for path in folder.glob("*/*.jsonl") if folder.is_dir() else []:
        try:
            stat = path.stat()
        except OSError:
            continue
        if stat.st_mtime > cutoff and (newest is None or stat.st_mtime > newest[0]):
            newest = (stat.st_mtime, path, stat.st_size)
    if not newest:
        return None
    # Read backwards in chunks: a large tool result can follow the last response.
    end, carry = newest[2], b""
    with open(newest[1], "rb") as stream:
        while end > 0 and newest[2] - end < 8 * 262144:
            start = max(end - 262144, 0)
            stream.seek(start)
            lines = (stream.read(end - start) + carry).split(b"\n")
            carry, end = (lines.pop(0) if start else b""), start
            for line in reversed(lines):
                if b'"assistant"' not in line:
                    continue
                try:
                    entry = json.loads(line)
                    model = (entry.get("message") or {}).get("model")
                    moment = epoch(entry.get("timestamp"))
                except (ValueError, AttributeError, TypeError):
                    continue
                if model and not model.startswith("<"):
                    return model if moment and moment > cutoff else None
    return None


def machine_identity(root):
    """A stable id per Mac, so reinstalling never leaves an old copy of this Mac's totals counted twice."""
    try:
        hardware = subprocess.run(["ioreg", "-rd1", "-c", "IOPlatformExpertDevice"], capture_output=True, text=True, timeout=5).stdout
        hardware = next(line.split('"')[-2] for line in hardware.splitlines() if "IOPlatformUUID" in line)
    except (OSError, subprocess.TimeoutExpired, StopIteration, IndexError):
        hardware = ""
    path = root / "machine-id"
    if hardware:
        path.write_text(hashlib.sha256(("side-a:" + hardware).encode()).hexdigest()[:32])
    elif not path.exists():
        path.write_text(str(uuid.uuid4()))
    try:
        name = subprocess.run(["scutil", "--get", "ComputerName"], capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        name = ""
    return path.read_text().strip(), name or "This Mac"


def sync_machines(root, folder, merged, hours, since, days):
    """Shares this Mac's token totals and activity through a synced folder and adds every
    other Mac's. Only counts, project paths, account names and emails are written; logins never are."""
    folder = Path(folder) / "machines"
    own, name = machine_identity(root)
    config = read_json(root / "config.json", {}) or {}
    accounts = [{"name": a["name"], "email": a.get("email", ""), "provider": provider_of(a)} for a in config.get("accounts", [])]
    mine = {"name": name, "totals": merged, "hours": hours, "accounts": accounts}
    previous = read_json(folder / f"{own}.json", None) if (folder / f"{own}.json").exists() else None
    # Unchanged totals are not rewritten, so iCloud uploads only real changes plus a daily heartbeat.
    if not isinstance(previous, dict) or time.time() - float(previous.get("updated") or 0) > 86400 \
            or {k: v for k, v in previous.items() if k != "updated"} != mine:
        atomic_json(folder / f"{own}.json", {**mine, "updated": time.time()})
    week = (datetime.date.today() - datetime.timedelta(days=6)).isoformat()
    tokens = lambda totals: sum(sum(v) for k, v in totals.items() if k.split("\t", 1)[0] >= week)
    machines = [{"name": name, "tokens": tokens(merged), "updated": time.time(), "current": True}]
    known = {(a["provider"], a["email"].casefold()) for a in accounts if a["email"]}
    elsewhere = {}
    merged = {key: list(values) for key, values in merged.items()}
    hours = {day: list(counts) for day, counts in hours.items()}
    for path in sorted(folder.glob("*.json")):
        if path.stem == own:
            continue
        # ponytail: an iCloud file evicted to a placeholder is skipped until macOS downloads it again.
        # Shared files are untrusted: a malformed one is skipped and every count is bounded.
        try:
            data = read_json(path, None)
            if not isinstance(data, dict) or time.time() - float(data.get("updated") or 0) > days * 86400:
                continue
            bound = lambda value, top: min(max(int(value), 0), top)
            totals = {str(k): [bound(v, 10**13) for v in values[:4]] + [0] * (4 - len(values[:4]))
                      for k, values in dict(data.get("totals") or {}).items() if str(k).count("\t") == 2 and str(k)[:10] >= since}
            counts = {str(day): [bound(c, 10**6) for c in list(values)[:24]] for day, values in dict(data.get("hours") or {}).items() if str(day) >= since}
            remote = [a for a in list(data.get("accounts") or []) if isinstance(a, dict)]
            updated = float(data["updated"])
        except (ValueError, TypeError, AttributeError, KeyError, OSError):
            continue
        for key, values in totals.items():
            bucket = merged.setdefault(key, [0, 0, 0, 0])
            for index, value in enumerate(values):
                bucket[index] += value
        for day, values in counts.items():
            total = hours.setdefault(day, [0] * 24)
            for hour, count in enumerate(values):
                total[hour] += count
        machines.append({"name": str(data.get("name") or "Another Mac")[:60], "tokens": tokens(totals), "updated": updated, "current": False})
        for account in remote:
            key = (account.get("provider"), str(account.get("email", "")).casefold())
            if key[1] and key[0] in ("claude", "codex") and key not in known:
                elsewhere.setdefault(key, {"name": str(account.get("name") or key[1]), "email": account["email"],
                                           "provider": key[0], "machine": machines[-1]["name"]})
    return merged, hours, machines, list(elsewhere.values())


def report(root, days=30, sync=None):
    """Per-day and per-project token use from local Claude Code and Codex logs, plus other Macs'
    totals when a sync folder is set."""
    cutoff = time.time() - days * 86400
    cache_path = root / "runtime" / "report-cache.json"
    cache = read_json(cache_path, {}) or {}
    fresh, merged, hours = {}, {}, {}
    folders = [(Path.home() / ".claude" / "projects", "*/**/*.jsonl", scan_transcript), (root / "conversations", "*/**/*.jsonl", scan_transcript),
               (Path.home() / ".codex" / "sessions", "**/*.jsonl", scan_codex)]
    for folder, pattern, scan in folders:
        for path in folder.glob(pattern) if folder.is_dir() else []:
            try:
                stat = path.stat()
            except OSError:
                continue
            if stat.st_mtime < cutoff:
                continue
            signature = f"{stat.st_size}:{int(stat.st_mtime)}"
            entry = cache.get(str(path))
            if not entry or entry["signature"] != signature or "offset" not in entry:
                entry = {"signature": signature, **scan(path, entry if entry and "offset" in entry else None)}
            fresh[str(path)] = entry
            for day, counts in entry["hours"].items():
                total = hours.setdefault(day, [0] * 24)
                for hour, count in enumerate(counts):
                    total[hour] += count
            for key, values in entry["totals"].items():
                bucket = merged.setdefault(key, [0, 0, 0, 0])
                for index, value in enumerate(values):
                    bucket[index] += value
    atomic_json(cache_path, fresh)
    since = (datetime.date.today() - datetime.timedelta(days=days - 1)).isoformat()
    merged = {key: values for key, values in merged.items() if key.split("\t", 1)[0] >= since}
    hours = {day: counts for day, counts in hours.items() if day >= since}
    machines, elsewhere = [], []
    if sync:
        merged, hours, machines, elsewhere = sync_machines(root, sync, merged, hours, since, days)
    by_day, by_project, by_model, by_day_model = {}, {}, {}, {}
    for key, (inp, out, write, read) in merged.items():
        day, project, model = key.split("\t")
        if day < since or model.startswith("<"):
            continue
        for table, name in ((by_day, day), (by_project, project), (by_model, model), (by_day_model, (day, model))):
            row = table.setdefault(name, {"input": 0, "output": 0, "cacheWrite": 0, "cacheRead": 0})
            row["input"] += inp; row["output"] += out; row["cacheWrite"] += write; row["cacheRead"] += read
    rows = lambda table, label: sorted(({label: name, **value} for name, value in table.items() if name),
                                       key=lambda row: -(row["input"] + row["output"] + row["cacheWrite"] + row["cacheRead"]))
    return {"days": sorted(rows(by_day, "date"), key=lambda row: row["date"]),
            "projects": rows(by_project, "project"), "models": rows(by_model, "model"),
            # Each day split by model, for the stacked daily chart.
            "dayModels": sorted(({"date": day, "model": model, **value} for (day, model), value in by_day_model.items() if model),
                                key=lambda row: (row["date"], row["model"])),
            "activity": [{"date": day, "hours": counts} for day, counts in sorted(hours.items()) if day >= since],
            "machines": machines, "elsewhere": elsewhere}


HOOK_MARK = "side-a-limit"


def limit_marker(root):
    return root / "runtime" / "limit-hit"


def hook_command(root):
    # `touch` only: StopFailure output is ignored, and nothing is added to the conversation.
    return f"touch {shlex.quote(str(limit_marker(root)))} # {HOOK_MARK}"


def set_limit_hook(root, enabled):
    """Opt-in StopFailure hook (matcher rate_limit) in ~/.claude/settings.json for instant switching."""
    with selection_lock(root, "settings.lock"):
        _set_limit_hook(root, enabled)


def _set_limit_hook(root, enabled):
    path = Path.home() / ".claude" / "settings.json"
    settings = read_json(path, {}) or {}
    hooks = settings.setdefault("hooks", {})
    groups = [g for g in hooks.get("StopFailure", []) if not any(HOOK_MARK in h.get("command", "") for h in g.get("hooks", []))]
    if enabled:
        limit_marker(root).parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        groups.append({"matcher": "rate_limit", "hooks": [{"type": "command", "command": hook_command(root), "timeout": 5}]})
    if groups:
        hooks["StopFailure"] = groups
    else:
        hooks.pop("StopFailure", None)
    if not hooks:
        settings.pop("hooks")
    write_settings(settings)


def write_settings(settings):
    path = Path.home() / ".claude" / "settings.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path = path.resolve()  # a symlinked settings file stays a symlink
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False, prefix=".side-a-") as stream:
        json.dump(settings, stream, indent=2)
        stream.write("\n")
    if path.exists():
        os.chmod(stream.name, path.stat().st_mode & 0o777)
    os.replace(stream.name, path)


OPUS_FALLBACK = ["opus"]


def set_opus_fallback(enabled):
    """Opt-in `fallbackModel` in ~/.claude/settings.json; only removes the value Side A wrote."""
    path = Path.home() / ".claude" / "settings.json"
    settings = read_json(path, {}) or {}
    if enabled:
        if settings.get("fallbackModel"):
            return
        settings["fallbackModel"] = OPUS_FALLBACK
    elif settings.get("fallbackModel") == OPUS_FALLBACK:
        settings.pop("fallbackModel")
    else:
        return
    write_settings(settings)


def opus_fallback_installed():
    settings = read_json(Path.home() / ".claude" / "settings.json", {}) or {}
    return bool(settings.get("fallbackModel"))


PROFILE_IN_ENV = re.compile(r"CLAUDE_SECURESTORAGE_CONFIG_DIR=(\S.*?/profiles/([0-9a-f-]{36}))")


def transcript_tail(session_id, size=262144):
    for path in (Path.home() / ".claude" / "projects").glob(f"*/{session_id}.jsonl"):
        with open(path, "rb") as stream:
            stream.seek(0, os.SEEK_END)
            stream.seek(max(0, stream.tell() - size))
            return stream.read().splitlines()
    return []


def session_titles(session):
    """Names a session's terminal title may show: its registry name and its latest custom or AI title."""
    titles = {session.get("name")}
    found = set()
    for line in reversed(transcript_tail(session["sessionId"])):
        for kind, key in (("custom-title", "customTitle"), ("ai-title", "aiTitle")):
            if kind not in found and f'"{kind}"'.encode() in line:
                try:
                    titles.add(json.loads(line).get(key))
                    found.add(kind)
                except ValueError:
                    pass
        if len(found) == 2:
            break
    return {title for title in titles if title}


def session_state(session_id):
    """Model and effort of the session's latest main-thread reply, from the tail of its transcript.
    Long tool results can fill the usual tail, so a wider one is read only when needed."""
    for size in (262144, 8 << 20):
        for line in reversed(transcript_tail(session_id, size)):
            if b'"assistant"' not in line:
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if entry.get("type") != "assistant" or entry.get("isSidechain"):
                continue
            model = (entry.get("message") or {}).get("model")
            if model and not model.startswith("<"):
                return model, entry.get("effort")
    return None, None


def session_model(session_id):
    return session_state(session_id)[0]


def session_activity(session_id):
    """When the transcript last changed, and whether its last main-thread entry ends a turn.
    Claude Code marks a session "busy" while background tasks run, so status alone can't tell
    a stuck turn from one that finished and is waiting."""
    last, ended = None, False
    for line in reversed(transcript_tail(session_id)):
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if entry.get("isSidechain") or not entry.get("timestamp"):
            continue
        if last is None:
            last = epoch(entry["timestamp"])
        if entry.get("type") in ("assistant", "user", "system"):
            ended = entry.get("type") == "system" and entry.get("subtype") == "turn_duration"
            break
    return last, ended


def running_jobs(pid):
    """Shell commands the session started that are still running (Claude Code runs each through
    `zsh -c source .../shell-snapshots/...`). Exiting or restarting the session would kill them."""
    result = subprocess.run(["ps", "-axo", "pid=,ppid=,args="], capture_output=True, text=True)
    jobs = 0
    for line in result.stdout.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[1] == str(pid) and "shell-snapshots" in parts[2]:
            jobs += 1
    return jobs


LIMIT_KINDS = (("fable", "fable limit"), ("weekly", "weekly limit"), ("session", "session limit"))


def session_limit(session_id):
    """The limit the session's latest main-thread reply says it hit, and when: Claude Code writes a
    rate_limit API error reply ("You've reached your Fable limit", "You've hit your session limit",
    "... weekly limit"). Direct evidence, for when the usage endpoint can't be read."""
    for line in reversed(transcript_tail(session_id)):
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if entry.get("type") != "assistant" or entry.get("isSidechain"):
            continue
        if not (entry.get("isApiErrorMessage") and entry.get("error") == "rate_limit"):
            return None, None
        content = (entry.get("message") or {}).get("content")
        text = (content if isinstance(content, str) else " ".join(
            part.get("text", "") for part in content or [] if isinstance(part, dict))).lower()
        kind = next((kind for kind, phrase in LIMIT_KINDS if phrase in text), None)
        return kind, epoch(entry.get("timestamp"))
    return None, None


def live_sessions(root, config):
    """Running Claude Code sessions, the model each last replied with, and the account it runs on:
    the profile in its environment, or the Mac login when it has none."""
    ids = {account["id"] for account in config.get("accounts", [])}
    mac = None
    owners = {}
    sessions = []
    for path in (Path.home() / ".claude" / "sessions").glob("*.json"):
        data = read_json_quiet(path, None)
        pid = data.get("pid") if isinstance(data, dict) else None
        if not isinstance(pid, int) or not isinstance(data.get("sessionId"), str) or data.get("cwd") == str(root):
            continue
        result = subprocess.run(["ps", "-E", "-o", "command=", "-p", str(pid)], capture_output=True, text=True)
        if result.returncode != 0:
            continue  # not running any more
        match = PROFILE_IN_ENV.search(result.stdout)
        if match:
            # The slot's login decides the account: `/login` inside a session replaces the login in
            # the slot it started on, so the slot's own account can be the wrong answer.
            slot = match.group(2)
            if slot not in owners:
                try:
                    email = token_email(root, read_secret(profile_service(root, slot)))
                except (ValueError, OSError):
                    email = ""
                owned = (account_for_email(config, email) or {}).get("id") if email else None
                owners[slot] = owned or (slot if slot in ids and not email else None)
            account = owners[slot]
        else:
            if mac is None:
                try:
                    mac = (account_for_email(config, mac_email(root)) or {}).get("id") or ""
                except (ValueError, OSError):
                    mac = ""
            account = mac or None
        since = data.get("statusUpdatedAt")
        limit, limit_at = session_limit(data["sessionId"])
        activity, ended = session_activity(data["sessionId"])
        sessions.append({"limitHit": limit, "limitAt": limit_at, "lastActivity": activity, "turnEnded": ended,
                         "runningJobs": running_jobs(pid),"pid": pid, "name": data.get("name"), "status": data.get("status"), "entrypoint": data.get("entrypoint"),
                         "statusSince": since / 1000 if isinstance(since, (int, float)) else None,
                         "model": session_model(data["sessionId"]), "accountID": account})
    return sorted(sessions, key=lambda item: item["pid"])


# One Apple event for all terminals: Ghostty can be slow to answer, and three per terminal adds up.
GHOSTTY_LIST = """on run argv
    if application "Ghostty" is not running then return ""
    tell application "Ghostty" to set {ids, dirs, names} to {id, working directory, name} of every terminal
    set sep to character id 9
    set out to ""
    repeat with i from 1 to count of ids
        set out to out & (item i of ids) & sep & (item i of dirs) & sep & (item i of names) & linefeed
    end repeat
    return out
end run"""

GHOSTTY_FOCUS = """on run argv
    tell application "Ghostty"
        activate
        focus (first terminal whose id is (item 1 of argv))
    end tell
end run"""

GHOSTTY_ESCAPE = """on run argv
    tell application "Ghostty" to send key "escape" to (first terminal whose id is (item 1 of argv))
end run"""

GHOSTTY_KEY = """on run argv
    tell application "Ghostty" to send key (item 2 of argv) to (first terminal whose id is (item 1 of argv))
end run"""

# Ctrl+U first clears anything half-typed in the prompt, so the text is never joined onto a draft.
GHOSTTY_TYPE = """on run argv
    tell application "Ghostty"
        set t to first terminal whose id is (item 1 of argv)
        send key "u" modifiers "control" to t
        input text (item 2 of argv) to t
        send key "enter" to t
    end tell
end run"""

# Whether this terminal is the one in front while Ghostty is the active app: the user may be typing.
GHOSTTY_IN_USE = """on run argv
    tell application "Ghostty"
        if not frontmost then return "no"
        if id of focused terminal of selected tab of front window is (item 1 of argv) then return "yes"
    end tell
    return "no"
end run"""


def osascript(script, *args):
    try:
        result = subprocess.run(["osascript", "-", *args], input=script, capture_output=True, text=True, timeout=45)
    except subprocess.TimeoutExpired:
        raise ValueError("Ghostty is not responding right now; Side A will try again.") from None
    if result.returncode != 0:
        if "-1743" in result.stderr:
            raise ValueError("Allow Side A to control Ghostty in System Settings > Privacy & Security > Automation.")
        raise ValueError("Ghostty did not respond.")
    return result.stdout


def ghostty_terminals():
    terminals = []
    for line in osascript(GHOSTTY_LIST).splitlines():
        parts = line.split("\t", 2)
        if len(parts) == 3:
            # Claude Code prefixes its title with a status glyph (e.g. "✳ name").
            terminals.append({"id": parts[0], "cwd": parts[1], "title": re.sub(r"^\W+\s", "", parts[2]).strip(), "raw": parts[2]})
    return terminals


def session_record(pid):
    data = read_json_quiet(Path.home() / ".claude" / "sessions" / f"{pid}.json", None)
    if not isinstance(data, dict) or data.get("pid") != pid or not isinstance(data.get("sessionId"), str):
        raise ValueError("That session is no longer running.")
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        raise ValueError("That session is no longer running.") from None
    except PermissionError:
        pass
    return data


def session_terminal(session, records, terminals):
    """The Ghostty terminal running a session: its title is the session name and its folder matches,
    or failing that, the terminal showing the session's tty."""
    same_folder = [t for t in terminals if t["cwd"] == session.get("cwd")]
    titles = session_titles(session)
    named = [t for t in same_folder if t["title"] in titles]
    if len(named) == 1:
        return named[0]
    # Otherwise only the exact tty decides: a lone tab in the same folder may be a plain shell
    # while the session runs in another terminal app.
    marked = terminal_by_tty(session.get("pid"))
    if marked:
        return marked
    raise ValueError("Couldn't find this session's Ghostty tab.")


def terminal_by_tty(pid):
    """The Ghostty terminal showing this process's tty, when titles can't tell: a unique title is
    written to the tty, the terminal showing it is found, and its previous title is put back."""
    if not isinstance(pid, int):
        return None
    tty = subprocess.run(["ps", "-o", "tty=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    if not re.fullmatch(r"ttys\d+", tty):
        return None
    before = {t["id"]: t for t in ghostty_terminals()}
    mark = f"side-a-{uuid.uuid4().hex[:12]}"
    try:
        with open(f"/dev/{tty}", "w") as stream:
            stream.write(f"\033]2;{mark}\007")
    except OSError:
        return None
    time.sleep(0.3)
    found = next((t for t in ghostty_terminals() if t["title"] == mark), None)
    if found and found["id"] in before:
        raw = before[found["id"]]["raw"]
        with contextlib.suppress(OSError), open(f"/dev/{tty}", "w") as stream:
            stream.write(f"\033]2;{raw}\007")
        return before[found["id"]]
    return found


def proc_argv(pid):
    """A process's exact argv (KERN_PROCARGS2), so arguments containing spaces stay whole."""
    import ctypes, struct
    libc = ctypes.CDLL(None, use_errno=True)
    mib = (ctypes.c_int * 3)(1, 49, pid)  # CTL_KERN, KERN_PROCARGS2
    size = ctypes.c_size_t(0)
    if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0:
        return []
    buffer = ctypes.create_string_buffer(size.value)
    if libc.sysctl(mib, 3, buffer, ctypes.byref(size), None, 0) != 0:
        return []
    raw = buffer.raw[:size.value]
    argc = struct.unpack("i", raw[:4])[0]
    rest = raw[4:]
    rest = rest[rest.index(b"\0"):].lstrip(b"\0")  # skip the executable path and its padding
    return [part.decode(errors="replace") for part in rest.split(b"\0")[:argc]]


# Flags kept on a resume. The prompt and anything unknown are dropped: a positional prompt would be
# sent again, and an unknown flag's value can't be told apart from a prompt.
RESUME_BOOLEAN = {"--dangerously-skip-permissions", "--allow-dangerously-skip-permissions", "--verbose",
                  "--debug", "--chrome", "--no-chrome", "--ide", "--strict-mcp-config", "--brief"}
RESUME_VALUE = {"--permission-mode", "--append-system-prompt", "--system-prompt", "--settings", "--agent",
                "--fallback-model", "--setting-sources"}
RESUME_VARIADIC = {"--add-dir", "--allowedTools", "--allowed-tools", "--disallowedTools", "--disallowed-tools",
                   "--mcp-config", "--plugin-dir", "--betas"}
EFFORTS = {"low", "medium", "high", "xhigh", "max"}
MODEL_FAMILIES = ("fable", "opus", "sonnet", "haiku")


def model_family(model):
    return next((family for family in MODEL_FAMILIES if family in (model or "").lower()), None)


def resume_command(pid, session_id, model, effort=None, argv=None):
    """claude --resume for the same conversation, the session's own flags, and the same model and
    effort. The original --model value is kept when it is the same model, so a [1m] context survives."""
    args = (proc_argv(pid) if argv is None else argv)[1:]
    kept, original_model, index = [], None, 0
    while index < len(args):
        arg = args[index]
        name, _, inline = arg.partition("=")
        if name == "--model":
            original_model = inline or (args[index + 1] if index + 1 < len(args) else None)
            index += 1 if inline else 2
        elif name in RESUME_BOOLEAN:
            kept.append(arg); index += 1
        elif name in RESUME_VALUE:
            if inline:
                kept.append(arg); index += 1
            elif index + 1 < len(args):
                kept += [arg, args[index + 1]]; index += 2
            else:
                index += 1
        elif name in RESUME_VARIADIC:
            kept.append(arg); index += 1
            if not inline:
                while index < len(args) and not args[index].startswith("-"):
                    kept.append(args[index]); index += 1
        else:
            index += 1  # prompt, --resume/--continue and their values, unknown flags
    if original_model and model_family(original_model) == model_family(model):
        model = original_model
    elif model and "fable" in model:
        model = "fable"  # the alias, so a spent-everywhere remap still applies
    return ["claude", "--resume", session_id, *kept, *(["--model", model] if model else []),
            *(["--effort", effort] if effort in EFFORTS else [])]


def live_session_for(session_id, other_than):
    """A running session record for this conversation, other than the given pid."""
    for path in (Path.home() / ".claude" / "sessions").glob("*.json"):
        data = read_json_quiet(path, None)
        if isinstance(data, dict) and data.get("sessionId") == session_id and data.get("pid") != other_than:
            try:
                os.kill(data["pid"], 0)
                return data
            except (ProcessLookupError, TypeError):
                continue
            except PermissionError:
                return data
    return None


def resuming(session_id):
    """Whether a claude process resuming this conversation is running."""
    result = subprocess.run(["ps", "-axww", "-o", "args="], capture_output=True, text=True)
    return any("--resume" in line and session_id in line for line in result.stdout.splitlines())


def wait_for(check, seconds, step=0.5):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = check()
        if value:
            return value
        time.sleep(step)
    return None


def session_action(root, pid, action, automatic=False):
    """Switches a running session to Opus (`/model opus`), or moves it to the account new commands
    use now: `/exit`, then resume the same conversation in the same tab. `rescue` first presses Esc
    to end a turn stuck on a spent limit, and afterwards types `continue` so the work carries on.
    Automatic actions skip the tab in front, where the user may be typing."""
    session = session_record(pid)
    records = [r for r in (read_json_quiet(p, None) for p in (Path.home() / ".claude" / "sessions").glob("*.json")) if isinstance(r, dict)]
    terminal = session_terminal(session, records, ghostty_terminals())
    if action == "focus":
        osascript(GHOSTTY_FOCUS, terminal["id"])
        return
    if automatic:
        try:
            in_use = osascript(GHOSTTY_IN_USE, terminal["id"]).strip() == "yes"
        except ValueError:
            in_use = True  # can't tell: leave the tab alone rather than risk typing over the user
        if in_use:
            raise ValueError("Skipped: that tab is in front, and you may be typing in it.")
    if action in ("opus", "opus-continue"):
        osascript(GHOSTTY_TYPE, terminal["id"], "/model opus")
        if action == "opus-continue":
            time.sleep(2)
            osascript(GHOSTTY_TYPE, terminal["id"], "continue")
        return
    record = lambda number: read_json_quiet(Path.home() / ".claude" / "sessions" / f"{number}.json", {}) or {}
    if action == "rescue":
        osascript(GHOSTTY_ESCAPE, terminal["id"])
        if not wait_for(lambda: record(pid).get("status") == "idle", 30):
            raise ValueError("Esc did not end the stuck turn; nothing else was typed.")
        session = session_record(pid)
    elif session.get("status") not in ("idle", "shell"):
        raise ValueError("Wait for the session to finish its turn, then move it.")
    if running_jobs(pid):
        raise ValueError("It has commands still running (they would be killed by a restart). Use /login in its tab to switch its account without restarting.")
    model, effort = session_state(session["sessionId"])
    command = resume_command(pid, session["sessionId"], model, effort)
    selector = selection_path(root)
    prefix = f"CLAUDE_SECURESTORAGE_CONFIG_DIR={shlex.quote(selector.read_text().strip())} " if selector.exists() else ""
    resume = prefix + " ".join(shlex.quote(part) for part in command)
    osascript(GHOSTTY_TYPE, terminal["id"], "/exit")
    if not wait_for(lambda: not process_alive(pid), 20, 0.3):
        # Claude Code asks to confirm /exit while background work runs (agents, monitors): decline it,
        # so no prompt is left open in the user's tab, and leave the session as it was.
        with contextlib.suppress(ValueError):
            osascript(GHOSTTY_ESCAPE, terminal["id"])
        raise ValueError("It has background work running (Claude Code asked to confirm /exit, which Side A declined); "
                         "use /login in its tab to switch its account without restarting.")
    # From here the session has exited: every failure says how to bring it back.
    name = session.get("name") or "The session"
    try:
        osascript(GHOSTTY_TYPE, terminal["id"], resume)
        # A long conversation first asks whether to resume from a summary or in full; the user's
        # choice is the full session (second option). Only answered while a claude process resuming
        # this conversation is running and still has not started after 20 seconds.
        if not wait_for(lambda: live_session_for(session["sessionId"], pid), 20) and resuming(session["sessionId"]):
            osascript(GHOSTTY_KEY, terminal["id"], "arrowDown")  # Ghostty's key name for the down arrow
            time.sleep(0.3)
            osascript(GHOSTTY_KEY, terminal["id"], "enter")
        resumed = wait_for(lambda: live_session_for(session["sessionId"], pid), 45)
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        raise ValueError(f"{name} exited but did not restart ({error}). In its tab, run: {resume}") from None
    if not resumed:
        raise ValueError(f"{name} did not restart; it may be asking a question in its tab. To restart it yourself: {resume}")
    if action == "rescue" and wait_for(lambda: record(resumed["pid"]).get("status") == "idle", 60):
        osascript(GHOSTTY_TYPE, terminal["id"], "continue")


def process_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True




LIVE_MARK = "side-a-live"
# Every Claude Code reply hands the statusline the account's limits from the response
# headers, so saving them gives a live reading without calling the rate-limited usage endpoint.
# $(cat; echo x) keeps the input byte for byte, so the user's own statusline sees it unchanged.
LIVE_SCRIPT = """#!/bin/sh
# side-a-live: saves each session's limits for Side A, then runs the original statusline.
umask 077
input=$(cat; echo x); input=${input%x}
case $input in *'"rate_limits"'*)
  name=${CLAUDE_SECURESTORAGE_CONFIG_DIR%/}; name=${name##*/}; name=${name:-mac}
  dir=LIVE_DIR
  printf '%s' "$input" > "$dir/.$name.$$" && mv -f "$dir/.$name.$$" "$dir/$name.json" ;;
esac
[ -n "$1" ] || exit 0
printf '%s' "$input" | /bin/sh -c "$1"
"""


def live_dir(root):
    return root / "runtime" / "live"


def live_wrapped(command):
    """The user's command inside Side A's wrapper, or None when the command is not the wrapper."""
    if not (isinstance(command, str) and command.startswith("/bin/sh ") and command.endswith(f" # {LIVE_MARK}")):
        return None
    words = shlex.split(command, comments=True)
    if len(words) not in (2, 3) or not words[1].endswith("/runtime/statusline.sh"):
        return None
    return words[2] if len(words) == 3 else ""


def set_live(root, enabled):
    """Wraps the statusLine command; the user's own command is kept as the wrapper's argument."""
    with selection_lock(root, "settings.lock"):
        _set_live(root, enabled)


def _set_live(root, enabled):
    settings = read_json(Path.home() / ".claude" / "settings.json", {}) or {}
    line = settings.get("statusLine")
    # Only a command statusline (or none) is wrapped; anything else is left exactly as it is.
    if line is not None and not (isinstance(line, dict) and line.get("type", "command") == "command"):
        return
    line = line or {}
    inner = live_wrapped(line.get("command"))
    command = (line.get("command") or "") if inner is None else inner
    if not isinstance(command, str):
        return
    if enabled:
        live_dir(root).mkdir(parents=True, exist_ok=True, mode=0o700)
        script = root / "runtime" / "statusline.sh"
        script.write_text(LIVE_SCRIPT.replace("LIVE_DIR", shlex.quote(str(live_dir(root)))))
        wrapped = f"/bin/sh {shlex.quote(str(script))}" + (f" {shlex.quote(command)}" if command else "")
        settings["statusLine"] = {**line, "type": "command", "command": f"{wrapped} # {LIVE_MARK}"}
    elif inner is None:
        return
    elif command:
        settings["statusLine"] = {**line, "command": command}
    else:
        settings.pop("statusLine")
    write_settings(settings)


def live_installed():
    settings = read_json(Path.home() / ".claude" / "settings.json", {}) or {}
    line = settings.get("statusLine") if isinstance(settings.get("statusLine"), dict) else {}
    return live_wrapped(line.get("command")) is not None


def live_limits(root, config):
    """Each Claude account's limits as its newest session last saw them, by account id."""
    found = {}
    mac = mac_email(root)
    # A file from Mac-login sessions belongs to whoever held the Mac login then; a sign-in
    # as someone else drops it rather than credit their limits to the new account.
    seen = live_dir(root) / "mac.email"
    try:
        if mac and seen.read_text() != mac:
            (live_dir(root) / "mac.json").unlink(missing_ok=True)
    except FileNotFoundError:
        pass
    if mac and live_dir(root).is_dir():
        seen.write_text(mac)
    # A statusline Claude Code stopped mid-write leaves its temporary file behind.
    for path in live_dir(root).glob(".*.*"):
        with contextlib.suppress(OSError):
            if time.time() - path.stat().st_mtime > 60:
                path.unlink()
    swapped = read_json(swapped_path(root), {}) or {}
    for path in live_dir(root).glob("*.json"):
        try:
            name = path.stem
            account = next((a for a in config.get("accounts", []) if provider_of(a) == "claude" and home_slot(root, a) == name), None)
            with open(path) as stream:
                at = os.fstat(stream.fileno()).st_mtime
                limits = json.load(stream).get("rate_limits") or {}
            windows = [{"id": key, "label": label, "percent": float(limits[key]["used_percentage"]),
                        "resetsAt": epoch(limits[key].get("resets_at"))}
                       for key, label in WINDOW_LABELS.items() if isinstance(limits.get(key), dict)]
            # ponytail: a fixed 2-minute quiet period after a trade covers replies in flight and Claude
            # Code's 30 s login cache; a reply streaming longer than that can still report the old account.
            if account and windows and at > swapped.get(name, 0) + 120 and at > found.get(account["id"], {}).get("at", 0):
                found[account["id"]] = {"at": at, "windows": windows}
        except (OSError, ValueError, TypeError, KeyError, AttributeError):
            continue
    return found


def limit_hook_installed():
    settings = read_json(Path.home() / ".claude" / "settings.json", {}) or {}
    return any(HOOK_MARK in h.get("command", "") for g in (settings.get("hooks") or {}).get("StopFailure", []) for h in g.get("hooks", []))


def main():
    # The app's watchdog sends SIGTERM; exiting normally lets `finally` release Claude Code's refresh lock.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    # Own process group, so the app's watchdog can stop any claude or codex child with us.
    try:
        os.setpgid(0, 0)
    except OSError:
        pass
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ["login", "status", "logout", "usage", "activate", "adopt", "prime", "renew"]:
        commands.add_parser(name).add_argument("account")
    swap_command = commands.add_parser("swap")
    swap_command.add_argument("slot")
    swap_command.add_argument("account")
    swap_command.add_argument("--share", action="store_true")
    commands.add_parser("active")
    commands.add_parser("report").add_argument("--sync", type=Path)
    commands.add_parser("hook").add_argument("state", choices=["on", "off", "status"])
    commands.add_parser("shell").add_argument("state", choices=["on", "off", "status"])
    commands.add_parser("fable").add_argument("state", choices=["on", "off", "status"])
    commands.add_parser("fallback").add_argument("state", choices=["on", "off", "status"])
    commands.add_parser("sessions")
    action = commands.add_parser("session")
    action.add_argument("pid", type=int)
    action.add_argument("action", choices=["opus", "opus-continue", "move", "focus", "rescue"])
    action.add_argument("--auto", action="store_true")
    commands.add_parser("live").add_argument("state", choices=["on", "off", "status"])
    args = parser.parse_args()
    root = args.root.expanduser().resolve()
    os.umask(0o077)
    if args.command == "report":
        print(json.dumps(report(root, sync=args.sync)))
        return
    if args.command == "hook":
        if args.state != "status":
            set_limit_hook(root, args.state == "on")
        print(json.dumps({"installed": limit_hook_installed()}))
        return
    if args.command == "live":
        if args.state != "status":
            set_live(root, args.state == "on")
        print(json.dumps({"installed": live_installed()}))
        return
    if args.command == "shell":
        if args.state != "status":
            set_shell(root, args.state == "on")
        print(json.dumps({"installed": shell_installed(root)}))
        return
    if args.command == "session":
        session_action(root, args.pid, args.action, automatic=args.auto)
        return
    if args.command == "fable":
        if args.state != "status":
            set_fable_fallback(root, args.state == "on")
        print(json.dumps({"installed": fable_model_path(root).exists()}))
        return
    if args.command == "fallback":
        if args.state != "status":
            set_opus_fallback(args.state == "on")
        print(json.dumps({"installed": opus_fallback_installed()}))
        return
    config = read_json(root / "config.json")
    # A trade interrupted by a crash is completed before any login is read or written.
    if read_secret(SWAP_JOURNAL):
        read_secret.cache_clear()
        with selection_lock(root), selection_lock(root, "renew.lock"):
            finish_swap(root)
    if args.command == "sessions":
        print(json.dumps(live_sessions(root, config)))
        return
    if args.command == "active":
        import codex_bridge
        mac = mac_email(root)
        print(json.dumps({"accountID": (repair_selection(root, config) or {}).get("id"),
                          "email": "" if account_for_email(config, mac) else mac,
                          "codexAccountID": (codex_bridge.global_account(config) or {}).get("id"),
                          "codexEmail": codex_bridge.global_email(), "claudeModel": recent_model(),
                          "logins": login_stamps(root, config), "loginEnds": login_ends(root, config),
                          "live": live_limits(root, config), "busy": busy_logins(root, config)}))
        return
    if args.command == "swap":
        swap(root, config, args.slot, account_by_id(config, args.account), share=args.share)
        return
    account = account_by_id(config, args.account)
    if args.command == "usage":
        print(json.dumps(usage(root, config, account)))
    elif args.command == "activate":
        activate(root, config, account)
    elif args.command == "adopt":
        print(json.dumps(adopt(root, account)))
    elif args.command == "renew":
        renew(root, config, account)
    elif args.command == "prime":
        prime(root, config, account)
    elif provider_of(account) == "codex":
        import codex_bridge
        if args.command == "status":
            print(json.dumps(codex_bridge.account_status(root, account)))
        else:
            sys.exit(subprocess.call(codex_bridge.command(root) + [args.command],
                env=codex_bridge.environment(root, account), cwd=root, stdin=subprocess.DEVNULL))
    elif args.command == "status":
        print(json.dumps(auth_status(root, account)))
    else:
        command = [claude_binary(), "auth", args.command]
        if args.command == "login":
            command.append("--claudeai")
            if account.get("email"):
                command += ["--email", account["email"]]
        env = clean_environment(prepare_profile(root, account["id"]))
        # Into the account's own slot: its profile may hold another account's login after a swap.
        # The slot is marked under selection.lock, so no trade moves a login into it meanwhile.
        with selection_lock(root):
            read_secret.cache_clear()
            held = token_email(root, read_secret(home_service(root, account)))
            owner = account_for_email(config, held) if held and held != account.get("email", "").casefold() else None
            # Only the other account's own login blocks; a stray second copy of it (say from a
            # `/login` typed in a session here) is replaced, since that account's home is elsewhere.
            if owner and home_slot(root, owner) == home_slot(root, account):
                raise ValueError(f"{account['name']}'s slot holds another account's login; sign in again after Side A frees it.")
            slot = home_slot(root, account)
            env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = slot_selector(root, slot)
            signing_in_path(root, slot).write_text(str(os.getpid()))
        try:
            code = subprocess.call(command, env=env, cwd=root, stdin=subprocess.DEVNULL)
        finally:
            signing_in_path(root, slot).unlink(missing_ok=True)
        sys.exit(code)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, StopIteration, OSError, subprocess.TimeoutExpired) as error:
        print(f"Side A: {error}", file=sys.stderr)
        sys.exit(1)
