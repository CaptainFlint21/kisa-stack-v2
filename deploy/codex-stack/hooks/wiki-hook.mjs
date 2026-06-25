#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";

function argument(name, fallback = "") {
  const index = process.argv.indexOf(name);
  return index >= 0 && process.argv[index + 1] ? process.argv[index + 1] : fallback;
}

async function readInput() {
  let input = "";
  for await (const chunk of process.stdin) {
    input += chunk;
  }
  if (!input.trim()) return {};
  try {
    return JSON.parse(input);
  } catch {
    return {};
  }
}

function wikiContext(vault) {
  const pages = path.join(vault, "codex", "pages");
  return [
    "## KISA LLM Wiki — required analysis anchor",
    `- Canonical vault: ${vault}`,
    `- Start with: ${path.join(pages, "overview.md")} and ${path.join(pages, "components.md")}.`,
    "- Read workflows.md, architecture.md, or goals-and-roadmap.md when relevant.",
    "- Verify repository and live-system facts directly; Wiki is durable context, not a substitute for inspection.",
    "- Do not write durable notes unless the user explicitly asks.",
    "- Reply in Russian unless the user requests another language.",
  ].join("\n");
}

async function shouldEmitReminder(input) {
  const sessionId = String(input.session_id || input.sessionId || "unknown");
  const key = crypto.createHash("sha256").update(sessionId).digest("hex");
  const stateDir = path.join(os.tmpdir(), "kisa-codex-hooks");
  const stateFile = path.join(stateDir, `${key}.txt`);
  await fs.mkdir(stateDir, { recursive: true });

  let count = 0;
  try {
    count = Number.parseInt(await fs.readFile(stateFile, "utf8"), 10) || 0;
  } catch {
    count = 0;
  }
  count += 1;
  await fs.writeFile(stateFile, `${count}\n`, { mode: 0o600 });
  return count % 3 === 0;
}

const event = argument("--event");
const vault = path.resolve(argument("--vault", process.env.KISA_WIKI_VAULT || path.join(os.homedir(), "LLM Wiki")));
const input = await readInput();

if (event === "UserPromptSubmit" && !(await shouldEmitReminder(input))) {
  process.exit(0);
}

if (!["SessionStart", "UserPromptSubmit"].includes(event)) {
  console.error(`Unsupported hook event: ${event || "<empty>"}`);
  process.exit(2);
}

process.stdout.write(
  `${JSON.stringify({
    hookSpecificOutput: {
      hookEventName: event,
      additionalContext: wikiContext(vault),
    },
  })}\n`,
);
