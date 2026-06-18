---
name: codex-delegator
description: "Delegate repository coding work from Hermes to Codex CLI through the official Codex MCP server. Use for implementation, refactoring, debugging, tests, code review, migrations, and Git workflows that need a coding agent inside a concrete workspace. Do not use for ordinary conversation, emotional support, simple research, or tasks without a repository."
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
- tests, lint, build, migrations, or code review are required;
- a branch, commit, push, or draft pull request is explicitly part of the task.

Do not delegate ordinary conversation, summarization, emotional support, or
research that does not require changing or deeply inspecting a repository.

## Required first-call contract

Before the first tool call:

1. Resolve the real repository directory.
2. Convert it to an absolute path.
3. Confirm that the requested task is scoped to that workspace.
4. Build a self-contained prompt with the goal, constraints, acceptance checks,
   and relevant user decisions.

Call `codex` with:

```text
prompt: <self-contained coding task>
cwd: <absolute repository path>
sandbox: workspace-write
approval-policy: on-request
```

Never select `danger-full-access`. Never put a sudo password, API key, bot token,
or other secret in the prompt.

## Thread lifecycle

1. Save the returned `threadId` in the active Hermes conversation state.
2. Read the first Codex response and decide whether the requested outcome is
   complete and verified.
3. If work remains, call `codex-reply` with the same `threadId` and a precise
   follow-up.
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
- Git authorization, if any;
- explicit prohibitions: no force-push, no history rewrite, no direct push to
  `main`, no autonomous sudo.

Tell Codex to inspect before editing, preserve unrelated user changes, fix root
causes, and report anything it could not verify.

## Git policy for the Kate profile

Allowed only when the user requested a full Git workflow:

- create a feature branch;
- commit intentional changes;
- push that feature branch;
- open a draft pull request.

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
- Approval required: let the `on-request` approval path handle it. Do not bypass
  the sandbox.
- Codex returns an incomplete result: continue through `codex-reply` with the
  specific missing verification or implementation step.
- Context is no longer relevant: start a fresh thread instead of reusing a stale
  `threadId`.

## Final response

Summarize:

- what Codex changed;
- repository and branch;
- checks that passed;
- draft PR URL when created;
- blockers or unverified items.
