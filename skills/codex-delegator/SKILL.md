---
name: codex-delegator
description: "Delegate repository coding work from Hermes to Codex CLI through the official Codex MCP server. Use for implementation, refactoring, debugging, tests, code review, and migrations that need a coding agent inside a concrete workspace. Hermes keeps Git orchestration. Do not use for ordinary conversation, emotional support, simple research, or tasks without a repository."
metadata:
  hermes:
    tags: [codex, coding, delegation, mcp, git]
    related_skills: [researcher]
---

# Codex Delegator

Delegate codebase changes to the official Codex MCP server exposed by:

```bash
codex mcp-server
```

The server provides two tools:

- `codex` — starts a Codex thread and returns a `threadId`;
- `codex-reply` — continues the same thread using that `threadId`.

Tool names may be namespaced by the MCP client. Use the discovered tools whose
underlying names are `codex` and `codex-reply`.

## Use this skill when

- the user asks to implement or refactor code;
- a repository bug must be diagnosed and fixed;
- tests, lint, build, migrations, or code review are required.

Do not delegate ordinary conversation, summarization, emotional support, or
research that does not require changing or deeply inspecting a repository.

## Production compatibility contract

Hermes 0.16.0 does not support MCP elicitation. Any Codex MCP call that can ask
for approval may block until the normal tool timeout and fail with
`JsonRpcError: Elicitation not supported`.

For production compatibility, the initial `codex` call must use:

```text
sandbox: workspace-write
approval-policy: never
```

The Codex MCP schema accepts those fields only on the initial `codex` call.
`codex-reply` accepts `threadId` and `prompt`; it continues the existing thread
and inherits the initial thread's sandbox and approval policy.

Never select `danger-full-access` and never use the old on-request approval
mode.
If a call fails with an elicitation-not-supported or approval-related error,
report a compatibility blocker immediately. Do not retry that error and do not
wait the normal timeout. Ordinary incomplete work is not an approval failure:
continue it with `codex-reply` and the same `threadId`.

## Required first-call contract

Before the first tool call:

1. Resolve the real repository directory.
2. Convert it to an absolute path.
3. Confirm that the requested task is scoped to that workspace.
4. Prepare a feature branch in Hermes if the user requested a full Git workflow.
5. Build a self-contained prompt with the goal, constraints, acceptance checks,
   and relevant user decisions.

Call `codex` with:

```text
prompt: <self-contained coding task>
cwd: <absolute repository path>
sandbox: workspace-write
approval-policy: never
```

Never put a sudo password, API key, bot token, or other secret in the prompt.
Do not pass `sandbox` or `approval-policy` to `codex-reply`; it must reuse the
same `threadId` and inherits those settings from the initial `codex` call.

## Delegated scope

Codex's delegated authority is limited to:

- editing files inside the absolute `cwd`;
- reading repository context needed for the task;
- running local verification commands that do not require network, sudo, or
  writes outside `cwd`.

Codex must not:

- create, switch, or delete branches;
- commit;
- push;
- open pull requests;
- use network;
- use sudo or request elevated privileges;
- write outside the absolute `cwd`.

Tasks that require sudo, network, or outside-workspace writes must stop as
blockers. Do not bypass those blockers by changing sandbox, asking for approval,
or using a different tool path.

## Thread lifecycle

1. Save the returned `threadId` in the active Hermes conversation state.
2. Read the first Codex response and decide whether the requested outcome is
   complete and verified.
3. If work remains, call `codex-reply` with the same `threadId` and a precise
   `prompt`. Do not include `sandbox` or `approval-policy` fields on
   `codex-reply`.
4. Continue one call at a time until Codex reports the implementation and
   verification result.
5. Do not run parallel calls against the same `threadId`.
6. Start a new `codex` thread for a different repository or unrelated task.

Do not persist thread IDs in the repository. Conversation/session state is the
correct owner of ephemeral delegation IDs.

## Prompt requirements

A delegated coding prompt must state:

- exact requested outcome;
- absolute workspace path;
- applicable `AGENTS.md` and repository conventions;
- files or subsystems known to be in scope;
- required tests/build/lint checks;
- Git boundaries: Hermes owns branch creation, commit, push, and draft PR;
- explicit delegated scope: file edits inside `cwd` and local verification only;
- explicit blockers: sudo, network, and outside-workspace writes stop the task;
- explicit prohibitions: no branch creation or switching, no commit, no push,
  no PR creation, no force-push, no history rewrite, no direct push to `main`,
  no autonomous sudo, no secrets.

Tell Codex to inspect before editing, preserve unrelated user changes, fix root
causes, and report anything it could not verify.

## Git policy for the Kate profile

Hermes owns Git orchestration. When the user requested a full Git workflow,
Hermes must:

- prepare a feature branch before delegation;
- after Codex returns, inspect the diff and verification output;
- commit intentional changes only after user authorization;
- push the feature branch only after user authorization;
- open a draft pull request only after user authorization.

Codex must not perform Git orchestration through MCP. It may inspect local Git
state and diffs when that is useful for implementation or reporting.

Always forbidden:

- force-push;
- destructive history rewrites;
- direct push to `main`;
- committing secrets or local credential files.

## Failure handling

- Missing workspace: ask for or discover the absolute repository path before
  calling Codex.
- MCP server unavailable: report the failed connection and recommend
  `hermes mcp test codex`; do not silently replace the requested workflow.
- Approval required, elicitation unsupported, or approval-related error: report
  a compatibility blocker immediately. Do not retry and do not wait the normal
  timeout.
- Required sudo, network, or outside-workspace write: report a blocker. Do not
  bypass the sandbox or change approval policy.
- Codex returns an incomplete result: continue through `codex-reply` with the
  specific missing verification or implementation step.
- Context is no longer relevant: start a fresh thread instead of reusing a stale
  `threadId`.

## Final response

Summarize:

- what Codex changed;
- repository and branch;
- checks that passed;
- Git follow-up completed by Hermes, including commit, push, and draft PR URL
  when user-authorized;
- blockers or unverified items.
