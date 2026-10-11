# Security and privacy

Side A never copies a login. It writes logins in two cases: a renewal, when a Claude login's
short-lived access token has expired, and a trade, when Autopilot moves running sessions off an
account near its limit.

- **How a trade stays safe.** Two Claude logins swap Keychain items: the full account's login
  goes to the item of an account no session is using, and that account's login goes to the item
  your sessions read, which they pick up within about 30 seconds. Both logins' Claude Code refresh
  locks are held, both owners are verified first, and if the second write fails the first is put
  back. Each refresh token stays in exactly one item, so none is ever spent twice. MCP logins stay
  with their item.

- **How renewal stays safe.** It takes Claude Code's own refresh lock for that login, re-reads
  the stored login inside the lock (if a session renewed it first, that one is used), sends the
  same request to the same endpoint with Claude Code's client id, and saves the result the way
  Claude Code does. Only the Claude login is replaced; MCP logins in the same item are kept. A
  refresh token is never spent twice.
- **Live limits.** Side A wraps the Claude Code statusline command. The wrapper saves the
  statusline input (limits, model, working folder) to `~/Library/Application Support/SideA/runtime/live`,
  readable only by you, then runs your own command with the same input. No login passes through it.

- **Logins stay in their CLI's Keychain items.** Claude logins live in Claude Code's default
  item and Side A's profile items; a trade can move one to another of these items. Codex logins stay in
  `~/.codex` or the account's profile.
- **What it reads:** each account's access token, to call the usage and profile endpoints
  the CLIs use, and the Codex id_token, to name the account. Every read checks that the
  token belongs to that account and refuses one it cannot verify.
- **What it writes:** its own folder in `~/Library/Application Support/SideA`; one marked
  line in `~/.zshrc` if you turn on Switch in Terminal; one Claude Code hook in
  `~/.claude/settings.json` if you turn on instant switching. Both can be turned off in
  Settings and are removed cleanly.
- **Tokens are never logged, printed, uploaded or put on a command line.** The identity
  cache stores a hash prefix of each token, never the token.
- **Starting a 5-hour window** runs the CLI with one short Haiku message; the CLI refreshes
  its own login if it needs to.
- **Analytics** are off unless you opt in, and never include account data.
- **Updates** are Ed25519-signed (Sparkle), and installers are Developer ID signed and
  Apple notarized.

Report a vulnerability privately through GitHub's security advisories on
[arnenoori/side-a-source](https://github.com/arnenoori/side-a-source/security/advisories/new).
