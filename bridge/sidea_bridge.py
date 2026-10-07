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
import shlex
import subprocess
import sys
import tempfile
import time
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
    import unicodedata
    return f"{GLOBAL_SERVICE}-{hashlib.sha256(unicodedata.normalize('NFC', path).encode()).hexdigest()[:8]}"


def keychain_user():
    return os.environ.get("USER") or "claude-code-user"


@functools.lru_cache(maxsize=None)
def read_secret(service):
    # One read per item per bridge run; the bridge never writes a login.
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


def home_service(root, account):
    """The one Keychain item that holds this account's login."""
    mac = mac_email(root)
    if mac and mac == account.get("email", "").casefold():
        return GLOBAL_SERVICE
    return profile_service(root, account["id"])


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
    return "" if home_service(root, account) == GLOBAL_SERVICE else str(profile_dir(root, account["id"]))


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
    account = next((a for a in config.get("accounts", []) if a["id"] == Path(chosen).name and provider_of(a) == "claude"), None)
    if account and selector_for(root, account) == chosen and token_email(root, read_secret(profile_service(root, account["id"]))) in ("", account["email"].casefold()):
        # An unknown owner (lookup failing) keeps the choice; reads still refuse it until verified.
        return account
    return mac


def repair_selection(root, config):
    """Points the selector at what global_account reports, e.g. after the Mac login changed."""
    with selection_lock(root):
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
    windows += model_windows(data, {window["label"] for window in windows})
    return {"windows": windows, "stale": False, "capacity": plan_capacity(oauth)}


def model_windows(data, seen):
    """Weekly limits scoped to one model (e.g. Fable), which the usage endpoint reports only
    in its `limits` list. Each stops that model on its own, before the overall weekly limit."""
    windows = []
    for limit in data.get("limits") or []:
        if not isinstance(limit, dict) or limit.get("kind") != "weekly_scoped":
            continue
        model = ((limit.get("scope") or {}).get("model") or {})
        name = str(model.get("display_name") or model.get("id") or "").strip()
        label = f"Weekly {name}"
        if not name or label in seen:
            continue
        seen.add(label)
        windows.append({"id": "seven_day_model:" + name.casefold(), "label": label,
                        "percent": float(limit.get("percent") or 0), "resetsAt": epoch(limit.get("resets_at"))})
    return windows


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
    """Point new `claude` commands at `account`'s own login. Nothing is copied or written."""
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


def shell_snippet(root):
    selector = shlex.quote(str(root / "runtime" / "claude-selector"))
    fable = shlex.quote(str(fable_model_path(root)))
    # A preexec hook, not a `claude` function: an alias to a path (claude=~/.claude/local/claude)
    # would skip a function, but every command runs after preexec. One line, so removal stays simple.
    # The fable alias is remapped only while Side A asks for it, and only unset if Side A set it.
    return (f"{SHELL_MARK}\n"
            f"_side_a_select() {{ local d m; d=\"$(cat {selector} 2>/dev/null)\"; "
            f"[ -f {selector} ] && export CLAUDE_SECURESTORAGE_CONFIG_DIR=\"$d\" || unset CLAUDE_SECURESTORAGE_CONFIG_DIR; "
            f"m=\"$(cat {fable} 2>/dev/null)\"; "
            f"if [ -n \"$m\" ]; then export ANTHROPIC_DEFAULT_FABLE_MODEL=\"$m\" _SIDE_A_FABLE=1; "
            f"elif [ -n \"$_SIDE_A_FABLE\" ]; then unset ANTHROPIC_DEFAULT_FABLE_MODEL _SIDE_A_FABLE; fi; }}; "
            f"autoload -Uz add-zsh-hook && add-zsh-hook preexec _side_a_select\n")


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


def prime(root, config, account):
    """Send one tiny message so the account's 5-hour window starts now instead of at first real use."""
    if provider_of(account) == "codex":
        from codex_bridge import prime as codex_prime
        return codex_prime(root, account)
    owned_login(root, account)
    env = clean_environment(prepare_profile(root, account["id"]))
    # The profile's clean settings keep the user's hooks and CLAUDE.md out; the selector
    # picks the account's own login, which the CLI refreshes itself if needed.
    env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = selector_for(root, account)
    result = subprocess.run([claude_binary(), "-p", "Reply with OK.", "--model", "haiku", "--max-turns", "1"],
                            env=env, cwd=root, capture_output=True, timeout=120, stdin=subprocess.DEVNULL)
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


def report(root, days=30):
    """Per-day and per-project token use from local Claude Code transcripts."""
    cutoff = time.time() - days * 86400
    cache_path = root / "runtime" / "report-cache.json"
    cache = read_json(cache_path, {}) or {}
    fresh, merged, hours = {}, {}, {}
    folders = [Path.home() / ".claude" / "projects", root / "conversations"]
    for folder in folders:
        for path in folder.glob("*/**/*.jsonl") if folder.is_dir() else []:
            try:
                stat = path.stat()
            except OSError:
                continue
            if stat.st_mtime < cutoff:
                continue
            signature = f"{stat.st_size}:{int(stat.st_mtime)}"
            entry = cache.get(str(path))
            if not entry or entry["signature"] != signature or "offset" not in entry:
                entry = {"signature": signature, **scan_transcript(path, entry if entry and "offset" in entry else None)}
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
    by_day, by_project, by_model = {}, {}, {}
    for key, (inp, out, write, read) in merged.items():
        day, project, model = key.split("\t")
        if day < since:
            continue
        for table, name in ((by_day, day), (by_project, project), (by_model, model)):
            row = table.setdefault(name, {"input": 0, "output": 0, "cacheWrite": 0, "cacheRead": 0})
            row["input"] += inp; row["output"] += out; row["cacheWrite"] += write; row["cacheRead"] += read
    rows = lambda table, label: sorted(({label: name, **value} for name, value in table.items() if name),
                                       key=lambda row: -(row["input"] + row["output"] + row["cacheWrite"] + row["cacheRead"]))
    return {"days": sorted(rows(by_day, "date"), key=lambda row: row["date"]),
            "projects": rows(by_project, "project"), "models": rows(by_model, "model"),
            "activity": [{"date": day, "hours": counts} for day, counts in sorted(hours.items()) if day >= since]}


HOOK_MARK = "side-a-limit"


def limit_marker(root):
    return root / "runtime" / "limit-hit"


def hook_command(root):
    # `touch` only: StopFailure output is ignored, and nothing is added to the conversation.
    return f"touch {shlex.quote(str(limit_marker(root)))} # {HOOK_MARK}"


def set_limit_hook(root, enabled):
    """Opt-in StopFailure hook (matcher rate_limit) in ~/.claude/settings.json for instant switching."""
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
    write_settings(path, settings)


def write_settings(path, settings):
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
    write_settings(path, settings)


def opus_fallback_installed():
    settings = read_json(Path.home() / ".claude" / "settings.json", {}) or {}
    return bool(settings.get("fallbackModel"))


PROFILE_IN_ENV = re.compile(r"CLAUDE_SECURESTORAGE_CONFIG_DIR=(\S.*?/profiles/([0-9a-f-]{36}))")


def session_model(session_id):
    """The model of the session's latest reply, from the tail of its transcript."""
    for path in (Path.home() / ".claude" / "projects").glob(f"*/{session_id}.jsonl"):
        with open(path, "rb") as stream:
            stream.seek(0, os.SEEK_END)
            stream.seek(max(0, stream.tell() - 262144))
            lines = stream.read().splitlines()
        for line in reversed(lines):
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            model = (entry.get("message") or {}).get("model") if entry.get("type") == "assistant" else None
            if model and not model.startswith("<"):
                return model
    return None


def live_sessions(root, config):
    """Running Claude Code sessions, the model each last replied with, and the account it runs on:
    the profile in its environment, or the Mac login when it has none."""
    ids = {account["id"] for account in config.get("accounts", [])}
    mac = None
    sessions = []
    for path in (Path.home() / ".claude" / "sessions").glob("*.json"):
        data = read_json(path, None)
        pid = data.get("pid") if isinstance(data, dict) else None
        if not isinstance(pid, int) or not isinstance(data.get("sessionId"), str) or data.get("cwd") == str(root):
            continue
        result = subprocess.run(["ps", "-E", "-o", "command=", "-p", str(pid)], capture_output=True, text=True)
        if result.returncode != 0:
            continue  # not running any more
        match = PROFILE_IN_ENV.search(result.stdout)
        if match:
            account = match.group(2) if match.group(2) in ids else None
        else:
            if mac is None:
                try:
                    mac = (account_for_email(config, mac_email(root)) or {}).get("id") or ""
                except (ValueError, OSError):
                    mac = ""
            account = mac or None
        sessions.append({"pid": pid, "name": data.get("name"), "status": data.get("status"),
                         "model": session_model(data["sessionId"]), "accountID": account})
    return sorted(sessions, key=lambda item: item["pid"])


def limit_hook_installed():
    settings = read_json(Path.home() / ".claude" / "settings.json", {}) or {}
    return any(HOOK_MARK in h.get("command", "") for g in (settings.get("hooks") or {}).get("StopFailure", []) for h in g.get("hooks", []))


def main():
    # Own process group, so the app's watchdog can stop any claude or codex child with us.
    try:
        os.setpgid(0, 0)
    except OSError:
        pass
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ["login", "status", "logout", "usage", "activate", "adopt", "prime"]:
        commands.add_parser(name).add_argument("account")
    commands.add_parser("active")
    commands.add_parser("report")
    commands.add_parser("hook").add_argument("state", choices=["on", "off", "status"])
    commands.add_parser("shell").add_argument("state", choices=["on", "off", "status"])
    commands.add_parser("fable").add_argument("state", choices=["on", "off", "status"])
    commands.add_parser("fallback").add_argument("state", choices=["on", "off", "status"])
    commands.add_parser("sessions")
    args = parser.parse_args()
    root = args.root.expanduser().resolve()
    os.umask(0o077)
    if args.command == "report":
        print(json.dumps(report(root)))
        return
    if args.command == "hook":
        if args.state != "status":
            set_limit_hook(root, args.state == "on")
        print(json.dumps({"installed": limit_hook_installed()}))
        return
    if args.command == "shell":
        if args.state != "status":
            set_shell(root, args.state == "on")
        print(json.dumps({"installed": shell_installed(root)}))
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
    if args.command == "sessions":
        print(json.dumps(live_sessions(root, config)))
        return
    if args.command == "active":
        import codex_bridge
        mac = mac_email(root)
        print(json.dumps({"accountID": (repair_selection(root, config) or {}).get("id"),
                          "email": "" if account_for_email(config, mac) else mac,
                          "codexAccountID": (codex_bridge.global_account(config) or {}).get("id"),
                          "codexEmail": codex_bridge.global_email()}))
        return
    account = account_by_id(config, args.account)
    if args.command == "usage":
        print(json.dumps(usage(root, config, account)))
    elif args.command == "activate":
        activate(root, config, account)
    elif args.command == "adopt":
        print(json.dumps(adopt(root, account)))
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
        sys.exit(subprocess.call(command, env=clean_environment(prepare_profile(root, account["id"])),
                                 cwd=root, stdin=subprocess.DEVNULL))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, StopIteration, OSError, subprocess.TimeoutExpired) as error:
        print(f"Side A: {error}", file=sys.stderr)
        sys.exit(1)
