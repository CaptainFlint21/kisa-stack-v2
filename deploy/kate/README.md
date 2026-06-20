# Kate: Telegram → Hermes → Codex CLI

This profile deploys KISA Stack on a Linux host named Kate. Hermes owns the
Telegram gateway, memory, schedules, and orchestration. Repository coding work
is delegated to Codex CLI through the official `codex mcp-server` interface.

## Security baseline

- Everything runs as the ordinary Kate Unix user.
- No sudo password is stored in Hermes.
- Root/sudo remains an interactive user approval.
- Hermes can access files allowed by the Kate user's normal Unix permissions.
- The initial Codex MCP `codex` call uses `workspace-write` with
  `approval-policy: never`; `codex-reply` inherits that thread contract.
- Codex MCP delegation is limited to file edits inside the absolute `cwd` and
  local verification; sudo, network, and outside-workspace writes are blockers.
- Telegram DMs are allowlisted to one owner user ID.
- The bot responds in one approved private group; membership in that group is
  the group authorization boundary.
- Every group command requires a mention or reply.
- Force-push, history rewrites, and direct pushes to `main` are forbidden.
- OAuth state, Telegram tokens, and IDs stay under `~/.hermes` with mode `0600`.
- Ordinary Codex CLI uses `~/.local/bin/codex` and the common Codex proxy source
  `~/.hermes/codex-proxy.env`.
- Hermes MCP uses the separate absolute launcher
  `~/.local/bin/codex-hermes-proxy`, which loads only
  `~/.hermes/hermes-proxy.env`.
- Generated caches, shell startup loaders, doctors, and launchers must not print
  proxy values.

## 1. Checkout

```bash
mkdir -p ~/src
cd ~/src
git clone https://github.com/CaptainFlint21/kisa-stack-v2.git
cd kisa-stack-v2
git switch codex/kate-hermes-integration
```

After the integration PR is merged, use `main` instead of the feature branch.

## 2. Preview and bootstrap

```bash
bash deploy/kate/bootstrap.sh --dry-run
bash deploy/kate/bootstrap.sh
```

The bootstrap:

- installs Hermes and RTK from their official installers when missing;
- snapshots every affected path under `~/.kisa-backups/<timestamp>/`;
- installs the `core` profile into `~/.agents/skills` and `~/.hermes/skills`;
- installs the personalized KISA `~/.codex/AGENTS.md` and
  `~/.codex/hooks.json`, with managed-file backups before overwrite;
- repairs the user `~/.local/bin/codex` proxy wrapper as a regular mode-0700
  file that survives npm launcher rewrites;
- installs or repairs the Hermes MCP launcher
  `~/.local/bin/codex-hermes-proxy` as a regular mode-0700 file;
- installs the Kate Codex user-proxy flow from `~/.hermes/codex-proxy.env` to
  a mode-0600 systemd user environment cache at
  `~/.config/environment.d/90-codex-proxy.conf`;
- initializes RTK for Codex and Hermes;
- installs Codex and Hermes Wiki hooks;
- creates the initial `~/LLM Wiki/{codex,hermes}/pages/` structure;
- renders a mode-0600 Hermes configuration with the local Telegram credentials;
- configures the `codex` MCP server as
  `~/.local/bin/codex-hermes-proxy mcp-server` with a 900-second tool timeout
  and no parallel calls to one server.

The bootstrap does not authenticate OAuth or start the gateway. Those remain
interactive so credentials are not accidentally shared or logged.

## 3. Separate Hermes Codex OAuth

Do not copy `~/.codex/auth.json` into Hermes. Create a separate Hermes OAuth
session over SSH:

```bash
hermes auth add openai-codex --type oauth --no-browser --manual-paste
hermes auth status openai-codex
hermes model
```

Select provider `openai-codex`. Keep Codex CLI's existing login independent.
This prevents the two runtimes from racing on one refresh token.

## 4. Approve hooks and test MCP

Review the installed scripts first:

```bash
sed -n '1,240p' ~/.hermes/hooks/hermes-pre-llm.sh
sed -n '1,240p' ~/.codex/hooks/codex-session-start.sh
sed -n '1,240p' ~/.codex/hooks/codex-user-prompt.sh
```

Approve Hermes shell hooks once from an interactive terminal, then verify them:

```bash
hermes --accept-hooks -z "Reply with OK. Do not use tools."
hermes hooks list
hermes hooks doctor
hermes mcp test codex
```

The MCP test must discover the underlying `codex` and `codex-reply` tools.

## 5. Install the user gateway service

Use the user-level service. Do not pass `--system` and do not use sudo:

```bash
hermes gateway install
hermes gateway start
hermes gateway status --deep
```

The Telegram bot should be a member of only the approved private group. Bot
privacy mode should remain enabled in BotFather so ordinary group traffic is not
forwarded to the bot.

## 6. Verification

Full verification:

```bash
bash deploy/kate/verify.sh
```

Repository-only verification before live sync:

```bash
bash deploy/kate/verify.sh --offline
```

Offline verification covers shell syntax, optional ShellCheck, installer
dry-run, idempotent re-run, backup-on-drift, core metadata, the VTT fixture, and
temp-HOME regression tests. It intentionally skips live installed-skill,
launcher, global Codex config, Hermes config, CLI availability, and MCP drift
doctors so it can pass before the live sync stage.

Full verification additionally checks installed skill drift, the Codex proxy
wrapper doctor, the global Codex config doctor, RTK, Hermes doctor, hook doctor,
and the Codex MCP connection.

## 6.1. Repair Codex proxy wrapper after Codex CLI updates

Codex CLI updates installed through npm may replace `~/.local/bin/codex` with an
npm-managed launcher or symlink. Kate needs `~/.local/bin/codex` to be a regular
mode-0700 proxy wrapper so Hermes/Codex MCP traffic inherits
`~/.hermes/codex-proxy.env` without printing proxy values. The wrapper resolves
the current real Codex CLI under `~/.nvm/versions/node/*/bin/codex` at runtime,
so it keeps working after Node or Codex version changes.

Run the штатный repair and doctor after any Codex CLI/npm update:

```bash
cd ~/src/kisa-stack-v2
bash deploy/kate/codex-wrapper.sh repair
bash deploy/kate/codex-wrapper.sh doctor
codex --version
```

The regular KISA core sync also repairs the wrapper:

```bash
bash install.sh sync core --codex --hermes
```

`doctor` fails when the wrapper is missing, is a symlink, lacks the proxy-env
reference, has the wrong mode, or no real NVM Codex CLI can be found. It never
prints proxy environment values.

## 6.2. Kate Codex user proxy hardening

Kate keeps the ordinary Codex proxy secret source separate from Hermes:

- Codex source: `~/.hermes/codex-proxy.env`
- Hermes source: `~/.hermes/hermes-proxy.env`
- generated systemd cache: `~/.config/environment.d/90-codex-proxy.conf`
- shell loader: `~/.config/kate-proxy/load-codex-proxy.bash`
- sync command: `~/.config/kate-proxy/sync-codex-proxy-env.bash`

Install or repair the flow:

```bash
cd ~/src/kisa-stack-v2
bash deploy/kate/user-proxy.sh install
```

Refresh the generated cache after editing `~/.hermes/codex-proxy.env`:

```bash
bash deploy/kate/user-proxy.sh sync
```

Validate the local contract:

```bash
bash deploy/kate/user-proxy.sh doctor
```

The loader parses shell-style `KEY=value` lines without `eval`, supports quoted
values and CRLF line endings, and exports only proxy variables. The generated
cache is replaced atomically from a temp file in its destination directory. The
doctor checks file modes, startup block idempotency, source/cache equality by
hash, systemd user-manager environment when available, and Hermes isolation
without printing proxy values.

For read-only validation of older Kate installs, `doctor` accepts exactly one
compatible legacy startup block per shell startup file:

```bash
# Kate Codex proxy environment
if [ -n "${BASH_VERSION:-}" ] && [ -r "$HOME/.config/kate-proxy/load-codex-proxy.bash" ]; then
  . "$HOME/.config/kate-proxy/load-codex-proxy.bash"
fi
```

`install` normalizes legacy block(s) into the managed marker block and keeps
exactly one loader block in each startup file.

This workflow does not configure Git, npm, pnpm, sudoers, or passwordless sudo.
Those tools inherit proxy settings only through the user environment.

## 6.3. Global Codex config and Hermes MCP launcher

Kate manages global Codex instructions and hooks from repository templates:

- `deploy/kate/templates/AGENTS.md` -> `~/.codex/AGENTS.md`
- `deploy/kate/templates/codex-hooks.json` -> `~/.codex/hooks.json`
- `deploy/kate/codex-global-config.sh` -> global install/sync/doctor workflow

Install or repair the managed files and the Hermes MCP launcher:

```bash
cd ~/src/kisa-stack-v2
bash deploy/kate/codex-global-config.sh install
```

Sync only files already marked as KISA-managed:

```bash
bash deploy/kate/codex-global-config.sh sync
```

Validate drift and the canonical Hermes MCP command:

```bash
bash deploy/kate/codex-global-config.sh doctor
```

`install` backs up existing targets before overwrite. `sync` refuses unmanaged
Codex instruction, hook, and launcher files, backs up drifted managed files, and
normalizes duplicate RTK includes in `AGENTS.md`. Both `install` and `sync` also
canonicalize only the known Hermes MCP command in an existing
`~/.hermes/config.yaml`, backing it up first and preserving unrelated config
content such as Telegram policy and credentials. They do not invent a missing
Hermes config; `doctor` reports that as drift. `doctor` is read-only and reports
drift without changing files.

The Hermes launcher is:

```text
~/.local/bin/codex-hermes-proxy
```

It is a regular mode-0700 file, loads only `~/.hermes/hermes-proxy.env`,
normalizes CRLF env files, clears inherited common Codex proxy variables before
loading Hermes values, resolves the real NVM Codex CLI at runtime, and then
execs `codex mcp-server`.

## 7. Telegram acceptance

Run these checks after the gateway is online:

1. Send a DM from the owner account. Hermes must answer.
2. Mention or reply to the bot from the owner account in the approved group.
   Hermes must answer in that group.
3. Mention or reply to the bot from another member of the approved group.
   Hermes must answer in that group.
4. Send an ordinary unmentioned group message. Hermes must ignore it.
5. Mention the bot from another group. Hermes must ignore it.
6. Confirm the bot is not present in any other group.

## 8. End-to-end Codex delegation

Use a disposable repository first. From Telegram, ask Hermes to:

1. inspect the repository;
2. create a feature branch;
3. make a small tested change;
4. continue the same Codex MCP thread until tests pass;
5. inspect the diff and test output;
6. after user authorization, commit, push the feature branch, and open a draft
   PR from Hermes.

Acceptance criteria:

- Hermes invokes `codex`, retains its `threadId`, then uses `codex-reply`;
- Codex receives an absolute `cwd`;
- the initial `codex` call uses sandbox `workspace-write` and approval policy
  `never`;
- `codex-reply` is called with the same `threadId` and a prompt, and inherits
  the initial thread's sandbox and approval policy;
- Codex edits only inside `cwd` and runs local checks;
- Codex does not create or switch branches, commit, push, open PRs, use network,
  use sudo, or write outside `cwd`;
- sudo, network, outside-workspace writes, elicitation-not-supported, and
  approval-related errors are reported as blockers without retrying the approval
  path;
- Hermes prepares the feature branch before delegation;
- Hermes inspects diff and tests after Codex returns;
- Hermes owns user-authorized commit, push, and draft PR creation;
- no direct push reaches `main`;
- the final Telegram response includes changed files, checks, branch, and PR URL.

## Updating

```bash
cd ~/src/kisa-stack-v2
git pull --ff-only
bash install.sh sync core --codex --hermes
bash deploy/kate/codex-wrapper.sh doctor
bash deploy/kate/verify.sh
hermes gateway restart
```

`sync` creates timestamped per-skill backups only when content changed. Local
skill `.env` files are preserved and never copied from the repository.

## Rollback

Restore the latest bootstrap snapshot:

```bash
bash deploy/kate/rollback.sh
```

Restore a specific snapshot:

```bash
bash deploy/kate/rollback.sh ~/.kisa-backups/YYYYMMDD-HHMMSS
```

Then restart Codex and Hermes. Rollback only touches the paths captured by the
bootstrap snapshot.
