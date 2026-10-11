# Changelog

## 0.5.19 — 2026-10-08

Running sessions switch: when an account with running sessions nears its limit, Autopilot trades its login with an account no session is using, and the sessions continue as that account within about 30 seconds, nothing to restart. Logins are never copied; both refresh locks are held and a failed write is undone. The move point is a setting (default 95%, was a fixed 97%). Autopilot reacts between replies instead of once a minute, and stale statusline temp files are cleaned up.

## 0.5.18 — 2026-10-07

Live limits: Side A wraps the Claude Code statusline so every reply saves that account's 5-hour and weekly numbers (from the response itself), then runs your own statusline with the same input. The usage endpoint is only read every 15 minutes while sessions report, for Fable, paid usage and use elsewhere, which ends its rate limits. On by default; Settings > Autopilot turns it off and restores your statusline exactly.

## 0.5.17 — 2026-10-07

Always-current readings: Side A renews expired Claude logins the way Claude Code does (its endpoint, client id, refresh lock and Keychain format), so idle accounts stay readable around the clock at no cost. Warns three days before a sign-in ends. A rate limit keeps the last reading instead of showing Couldn't connect, and the account in use is read every three minutes. Fixes 0.5.16 holding the Mac login's refresh lock while waking it.

## 0.5.16 — 2026-10-07

A new sign-in or a refresh is read at once instead of after a back-off; readings older than 15 minutes say when they are from. Side A takes Claude Code's own refresh lock while it runs claude for an account, so it never refreshes a login at the same moment as an open session.

## 0.5.15 — 2026-10-07

Countdowns move while the menu is open, and a limit estimate from stale readings is dropped. A login whose owner can't be checked yet no longer reads as Couldn't connect. Switch notifications explain that running sessions keep their account. Sign in again is in each account's menu.

## 0.5.14 — 2026-10-07

Usage lists Claude and Codex models in separate sections, so Codex is not crowded out. Codex turns count the way ccusage counts them, so a session total that restarts after compaction is no longer missed.

## 0.5.13 — 2026-10-07

Usage rows list every limit with its reset (5-hour, weekly, Fable); Accounts shows Fable bars and each reset under its bar; Today compares with what you usually use by this hour.

## 0.5.12 — 2026-10-07

Paid usage warnings: Side A reads each Claude account's usage-credit spend, warns before the account in use starts billing credits with nowhere to move, notifies when spend grows, and shows spend in Usage.

## 0.5.11 — 2026-10-07

Run accounts side by side: sidea use <name> or Open Terminal on an account keeps one terminal on it while Autopilot moves the rest. Weekly forecasts follow your usual rhythm, with a week-ahead summary. The Terminal prompt leaves the menu; Use and turning on Autopilot set it up.

## 0.5.10 — 2026-10-07

Accounts no longer sit on Reading forever: revoked Codex logins ask for sign-in instead of backing off as a rate limit, idle Claude logins can be woken (automatically during work hours, or with Wake), and failed reads say why with a retry time. Clearer Terminal setup prompt.

## 0.5.9 — 2026-10-07

Sync across Macs through iCloud Drive: combined usage, per-Mac totals, shared working hours and accounts from other Macs to sign in to. Follow Fable: while Claude Code runs Fable, Autopilot ranks accounts by Fable headroom and skips plans that bill Fable as extra usage.

## 0.5.8 — 2026-10-07

Redesigned Autopilot tab: live ranking with the scoring rule, a 24-hour day strip and rule chips. Pace verdicts predict when a limit runs out. Codex sessions count in Usage; GPT model names read cleanly; placeholder rows filtered. More site Easter eggs.

## 0.5.7 — 2026-10-07

Accounts tab grouped by provider with an In use label and live limits; Usage tab with weekly pace per account, period comparisons, per-model daily chart and an hourly activity strip.

## 0.5.6 — 2026-10-07

Reads per-model weekly caps from the usage endpoint's scoped limits and shows them once used. The 3D player is opt-in. Easter eggs on the site and in notifications.

## 0.5.5 — 2026-10-07

The disc is visible with the lid open: the lid seam was a solid cylinder that covered it.

## 0.5.4 — 2026-10-06

Open source under MIT; each release's source is published to arnenoori/side-a-source. Optional manual update installs.

## 0.5.3 — 2026-10-06

Menu bar pivot: the 5-hour and weekly limits for every account, shown as a percentage in the menu bar. Autopilot picks the Claude account with the quota closest to expiring and warms idle 5-hour windows during your usual hours. Selection is read-only: Side A never writes or refreshes a login; an opt-in zsh function points new `claude` commands at the chosen account, and an optional hook rechecks on a rate limit. Codex accounts are tracked and warmed, not switched. Usage by day, project and model. Removed per-project Terminal sessions and the PTY supervisor.

## 0.4.1 — 2026-09-07

Simplified tool readiness, automatic verification on return from sign-in, and physical OPEN/PLAY guidance. Transient verification failures preserve account readiness; reconnecting keeps Auto flip preferences. Added a private local diagnostic summary and consent-aware completed-setup metrics.

## 0.4.0 — 2026-09-07

Added signed Sparkle updates, local release automation, tool checks, and optional anonymous app metrics.

## 0.3.0 — 2026-09-06

Added Codex subscription profiles, native CLI sessions, verified identity, and
same-thread account switching through the app-server protocol. Auto flip waits for
completed work and a structured usage limit. Accounts stay grouped by provider for
handoffs; the LCD and menu bar show the selected or playing agent. Existing Claude
profiles migrate without changing sign-in metadata or Auto flip consent.

Accounts now opens in a separate utility window beside the 3D player. Removed the
sheet backdrop and the overlapping disclosure arrow from account menus. Onboarding
adds only a compact Claude/Codex selector.

Added provider migration, protocol, privacy, and real PTY switching tests. Codex
remains experimental until two real subscription accounts pass live acceptance.

## 0.2.1 — 2026-09-06

Reduced onboarding to a compact form. Removed the slogan panel, branded footer,
repeated headings, and numbered explanations. Shortened sign-in, account, and
settings copy while retaining field labels and the Auto flip access note.

## 0.2.0 — 2026-09-06

The standalone app is now just the 3D device. Removed the entire surrounding layout
and window chrome; added a transparent window, housing drag, LCD account/session
status and project selection, and accessibility actions directly on the model.
OPEN reveals onboarding after the lid animation. The menu bar companion remains.

## 0.1.0 — 2026-09-06

Initial Claude Code preview: native 3D account player, menu bar companion, isolated
login onboarding, verified account selection, managed Terminal sessions, and
opt-in rate-limit handoffs. Includes Blender source, reproducible app packaging,
security documentation, and native/PTY tests. Live multi-account acceptance remains
pending account sign-in; Codex and Claude Desktop integrations are not included.
