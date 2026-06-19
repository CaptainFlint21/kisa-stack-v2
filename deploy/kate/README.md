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
- installs the personalized KISA `~/.codex/AGENTS.md`;
- initializes RTK for Codex and Hermes;
- installs Codex and Hermes Wiki hooks;
- creates the initial `~/LLM Wiki/{codex,hermes}/pages/` structure;
- renders a mode-0600 Hermes configuration with the local Telegram credentials;
- configures the `codex` MCP server as `codex mcp-server` with a 900-second tool
  timeout and no parallel calls to one server.

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

Repository-only verification without live Hermes/provider calls:

```bash
bash deploy/kate/verify.sh --offline
```

The workflow covers shell syntax, optional ShellCheck, installer dry-run,
idempotent re-run, backup-on-drift, core metadata, the VTT fixture, installed
skill drift, RTK, Hermes doctor, hook doctor, and the Codex MCP connection.

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
