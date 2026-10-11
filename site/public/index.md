# Side A

See every Claude Code and Codex account's 5-hour and weekly limits from your Mac's menu bar. Side A switches your Mac to whichever account has quota about to go unused. Made by [Arne Noori](https://arne.ai).

## Why it helps

Quota you don't use before a window resets is gone. With more than one account, one runs dry while another expires. Side A spends the one about to expire first.

## What it does

- **Every limit.** 5-hour and weekly usage for each account, with reset times.
- **Switching.** Running sessions move to a fresh account near a limit, with nothing to restart, and new `claude` commands follow.
- **Autopilot.** Switches before you hit a limit, not after.
- **Two accounts at once.** `sidea use <name>` keeps one terminal on an account for a long task while Autopilot moves the rest.
- **Fable aware.** While you use Fable, ranks accounts by the Fable share they have left.
- **Across your Macs.** Optional iCloud Drive sync combines usage; logins never sync.
- **Early windows.** Starts idle 5-hour windows before your usual start, so they reset sooner.
- **Usage by project.** Tokens per project and per day, from your local transcripts.
- **Instant on limits.** An optional hook rechecks the moment a rate limit hits, so Autopilot moves right away.

## How it decides

It reads the same numbers as `/usage` (and Codex's rate-limit call), then ranks accounts by weekly percent left divided by hours until the weekly reset, times plan size.

- **Plan size:** Max 20x is 20, Max 5x is 5, Pro is 1.
- **Tie-break:** the 5-hour window that resets soonest.
- **Thresholds:** leaves an account at 97%; only switches to one under 90%.
- **Stability:** stays put unless another account is 1.5 times more urgent.
- **Forecasts:** weekly pace follows when you usually work, learned from your activity over the last four weeks.

Example: 60% left, resets in a day: 2.5 per hour. 90% left, resets in six days: 0.6 per hour. The first one goes first.

## What it touches

Reads each account's own login where its CLI keeps it, and transcripts in `~/.claude/projects`. Writes one marked line in `~/.zshrc` if you turn on switching, wraps the Claude Code statusline (your own command still runs, with the same input) to save each reply's limits, and its own folder in `~/Library/Application Support/SideA`. Never copies, logs or uploads a login; moving running sessions trades two logins' Keychain items, so each still lives in one place. When a Claude login's short-lived token expires, renews it the way Claude Code does, under Claude Code's own lock, so readings stay current.

Never logs or uploads a token, moves your MCP server logins, runs your Claude hooks when it starts a window, or sends analytics unless you opt in.

Relies on endpoints the CLIs use but don't document. Doesn't raise any limit. Starting a window costs a few tokens. Codex is tracked, not switched; that part is experimental.

## Download

The signed and Apple-notarized public preview is available from [official releases](https://github.com/arnenoori/side-a-releases/releases). Only published stable releases containing a universal macOS DMG and SHA256SUMS.txt appear as downloads on the website. The interactive player on this website uses demo accounts.

## Setup

1. Download the signed DMG. Drag Side A to Applications and open it. It lives in the menu bar.
2. Add the login this Mac already uses, then your other accounts. Each opens the provider's sign-in in your browser and verifies on its own.
3. Turn on switching in Terminal, and leave Autopilot on or choose **Use** on an account.

## Requirements

- macOS 14 or later, Apple Silicon or Intel.
- [Python 3.9 or later](https://www.python.org/downloads/macos/).
- [Claude Code](https://code.claude.com/docs/en/setup) or [Codex CLI](https://developers.openai.com/codex/cli).
- A Claude or ChatGPT subscription with Claude Code or Codex access.

## Troubleshooting

If an account shows "Usage unavailable", sign in to it again from Settings. Settings and Help offer a local diagnostic summary with app and tool versions. No accounts, paths, conversations, or credentials are included, and nothing is uploaded.

## Privacy

Your accounts and usage stay on your Mac. If you turn on sync, token totals, working hours, project paths and account names and emails go to a Side A folder in your own iCloud Drive so your other Macs can combine them; logins never do. Claude and Codex handle sign-in and requests under their own policies. Anonymous app statistics are off by default: opt in during setup or in Settings to share setup and switch counts. App statistics use a new anonymous ID each launch and include no accounts, emails, code, or project paths. The website sends anonymous page views, download clicks, and demo interactions to PostHog in the US, with no cookies, recordings, or persistent visitor IDs. Turn website statistics off in Privacy; Do Not Track and Global Privacy Control are also respected. The page checks GitHub for public downloads. Side A is an independent app, not affiliated with Anthropic, OpenAI, or Sony.

## Machine-readable resources

- [Product information](https://getsidea.com/product.json)
- [API description](https://getsidea.com/openapi.json)
- [Setup skill index](https://getsidea.com/.well-known/agent-skills/index.json)
- [Resource catalog](https://getsidea.com/.well-known/ard.json)

The public website and product information do not require authentication. No public account-management, OAuth, MCP server, or payment endpoint is provided. Browsers that support WebMCP can read product information and check official download availability.
