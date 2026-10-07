# Side A

**Your coding accounts, a track apart.**

A native macOS account player with a real-time 3D, Discman-inspired interface,
a menu bar companion, and isolated Claude Code and Codex sign-ins. Built with SwiftUI,
SceneKit, and an original Blender model.

<p align="center"><img src="design/discman.png" width="540" alt="Side A’s silver 3D account player, modeled in Blender"></p>

## What works in v0.5

- **Menu bar first.** Every account shows its 5-hour and weekly limits (plus weekly
  Opus/Sonnet when reported) with reset times. The menu bar shows a gauge with the
  active account's tightest limit. The 3D player is optional.
- **Switching without moving logins.** New `claude` commands in any terminal use the
  chosen account; each login stays where its CLI keeps it (see below).
- **Autopilot.** Side A reads the active account's usage every two minutes (others every
  ten) and keeps the Mac on the account
  with the most quota at risk: weekly percent left divided by hours until the
  weekly reset. Among near-ties it burns the 5-hour window that resets soonest.
  It switches away before a limit is hit and avoids flapping between accounts.
- **Window priming.** A 5-hour window starts only at an account's first message.
  Autopilot sends one tiny Haiku message to idle opted-in accounts so their window
  starts early and resets early, instead of starting when you first need it.
- **Background sign-in.** Adding an account opens the official browser sign-in and
  verifies by itself. The login this Mac already uses is detected and added with one click.
- Codex accounts show their limits through the Codex app-server
  `account/rateLimits/read` call and can be primed. Switching is Claude-only.

## Updates and privacy (local fork)

This fork has **no auto-updater and no analytics**. Sparkle and PostHog are removed, so the app
never contacts getsidea.com, an appcast, or any telemetry service. The only network calls are the ones
the app needs to work: Anthropic's OAuth usage/profile endpoints (to read Claude limits) and the
local `claude`/`codex` CLIs, which talk to their own providers.

To pull upstream changes when you choose:

```sh
git fetch upstream
git merge upstream/main   # resolve conflicts in Package.swift, Info.plist, Settings/Menu views if any
./scripts/build-app.sh
```

Before merging, check that no new updater, analytics, or remote endpoint came in: `git diff HEAD upstream/main -- Package.swift scripts/Info.plist Sources bridge | grep -iE 'http|sparkle|posthog|URLSession'`.

A local diagnostic summary is available from Settings or Help. It contains only app/tool versions and coarse session state; nothing is uploaded. See [recovery](docs/recovery.md).

## Run

Requires macOS 14+, Python 3.9+, and either
[Claude Code](https://code.claude.com/docs/en/setup) or
[Codex CLI](https://developers.openai.com/codex/cli) (tested: 0.148.0; requires remote TUI/app-server support).
Setup checks Python and the selected CLI automatically, and links to their official installers when needed. It recognizes Homebrew, local-bin, and installed Apple developer-tool Python paths. Python uses only its standard library.

Build with Xcode 16+ / Swift 6:

```sh
./scripts/build-app.sh
open "dist/Side A.app"
```

The build is locally ad-hoc signed, **not notarized for public distribution**.
The app may be moved to Applications. It needs access to its own
Application Support directory and your Keychain; it is not App Sandbox
compatible because it runs the coding CLIs and manages their Keychain logins.

For an isolated interface preview with fictional accounts:

```sh
open -n "dist/Side A.app" --args --demo
```

Preview mode does not authenticate or launch coding sessions.

## Connect

1. Open the menu bar item and add the login this Mac already uses.
2. **Accounts… > Add account**, choose Claude or Codex, then **Sign in**. Finish in the
   browser; Side A verifies the identity when the CLI returns.
3. Turn on switching in Terminal, then leave **Autopilot** on or press **Use**.
   On the player, PLAY uses the on-deck account.

## How switching works

Every login lives in exactly one place: the account this Mac is signed in to keeps
Claude Code's default Keychain item, and every other account keeps its own profile
slot. Side A never copies a login. Refresh tokens rotate, so two copies of one login
eventually invalidate each other (Codex revokes the login outright).

Choosing an account writes its profile path (empty for the Mac login) to
`runtime/claude-selector`. With switching turned on,
one marked line in `~/.zshrc` reads that choice before each command (so aliases work) and sets
`CLAUDE_SECURESTORAGE_CONFIG_DIR`, so the command uses that account's own Keychain item
while settings, history and hooks stay in `~/.claude`. Sessions already running keep
their account. Apps that start `claude` outside your shell use the Mac login.

Side A identifies every login by its token (profile endpoint, cached per token) and
refuses a slot that holds another account's login or one it cannot verify yet. It never
refreshes a login: an expired one is idle and its last reading still applies. Starting a
5-hour window runs the CLI, which refreshes that account's login itself.
Codex accounts are tracked and primed; switch Codex itself with `codex login`.

## Development

```sh
python3 -m unittest discover -s bridge/tests -v
swift test
./scripts/build-app.sh release
```

The build script copies the canonical bridge into app resources before compiling.
Do not edit the generated resource copy. There are no package dependencies; the bridge needs no third-party Python packages. CI runs both suites and builds verified app artifacts on native
Apple Silicon and Intel Macs. The [distribution guide](docs/distribution.md)
describes the gated signing, notarization, and public-release pipeline.
The `site/` directory contains the minimal Three.js download page. Public releases
include a custom DMG, a ZIP alternative, and checksums. Signing credentials are
required before the first public release can be published.

Rebuild the model (Blender 5.2 was used):

```sh
/Applications/Blender.app/Contents/MacOS/Blender --background --python design/build_discman.py
```

`design/SideA.blend` is the editable source. The script exports evaluated mesh data
into the native app and renders the reference image. This is original artwork
inspired by portable CD players, not a Sony product or an exact model replica.

See [architecture](docs/architecture.md), [security](SECURITY.md),
[design decisions](docs/design.md), and [validation](docs/validation.md).

MIT License. Copyright © 2026 Arne Noori. See [LICENSE](LICENSE).
