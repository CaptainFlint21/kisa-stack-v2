#!/usr/bin/env node

import assert from "node:assert/strict";
import fs from "node:fs";
import fsp from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const manager = path.join(repoRoot, "deploy", "codex-stack", "kisa.mjs");
const testRoot = await fsp.mkdtemp(path.join(os.tmpdir(), "kisa-codex-stack-"));
const home = path.join(testRoot, "home");
const codexHome = path.join(home, ".codex");
const vault = path.join(testRoot, "vault");
const customAgents = "# Existing user instructions\n\nKeep this file.\n";
const originalStopHook = {
  hooks: {
    Stop: [
      {
        hooks: [
          {
            type: "command",
            command: "echo existing-hook",
          },
        ],
      },
    ],
  },
};

function run(action, extra = [], expectedStatus = 0) {
  const result = spawnSync(
    process.execPath,
    [
      manager,
      action,
      "--profile",
      "codex-desktop",
      "--home",
      home,
      "--codex-home",
      codexHome,
      "--vault",
      vault,
      ...extra,
    ],
    { encoding: "utf8" },
  );
  assert.equal(
    result.status,
    expectedStatus,
    `${action} failed\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`,
  );
  return result;
}

function backupCount() {
  const root = path.join(codexHome, "kisa-backups");
  return fs.existsSync(root)
    ? fs.readdirSync(root, { withFileTypes: true }).filter((entry) => entry.isDirectory()).length
    : 0;
}

try {
  await fsp.mkdir(codexHome, { recursive: true });
  await fsp.writeFile(path.join(codexHome, "AGENTS.md"), customAgents, "utf8");
  await fsp.writeFile(path.join(codexHome, "hooks.json"), `${JSON.stringify(originalStopHook, null, 2)}\n`, "utf8");

  run("install", ["--dry-run"]);
  assert.equal(fs.existsSync(path.join(home, ".agents")), false, "dry-run created skill root");

  run("install");
  assert.equal(await fsp.readFile(path.join(codexHome, "AGENTS.md"), "utf8"), customAgents);

  const hooks = JSON.parse(await fsp.readFile(path.join(codexHome, "hooks.json"), "utf8"));
  assert.equal(hooks.hooks.Stop[0].hooks[0].command, "echo existing-hook");
  assert.equal(hooks.hooks.SessionStart.length, 1);
  assert.equal(hooks.hooks.UserPromptSubmit.length, 1);

  run("doctor");
  const backupsAfterInstall = backupCount();
  run("sync");
  assert.equal(backupCount(), backupsAfterInstall, "idempotent sync created a backup");

  const installedSkill = path.join(home, ".agents", "skills", "researcher", "SKILL.md");
  const driftMarker = "\nLOCAL_DRIFT_FOR_ROLLBACK\n";
  await fsp.appendFile(installedSkill, driftMarker, "utf8");
  await fsp.writeFile(path.join(path.dirname(installedSkill), ".env"), "LOCAL_SECRET=preserve\n", "utf8");

  run("sync");
  assert.equal(backupCount(), backupsAfterInstall + 1, "drift sync did not create one backup");
  assert.equal((await fsp.readFile(installedSkill, "utf8")).includes("LOCAL_DRIFT_FOR_ROLLBACK"), false);
  assert.equal(
    await fsp.readFile(path.join(path.dirname(installedSkill), ".env"), "utf8"),
    "LOCAL_SECRET=preserve\n",
  );
  run("doctor");

  const snapshots = (await fsp.readdir(path.join(codexHome, "kisa-backups")))
    .sort()
    .reverse();
  run("rollback", ["--snapshot", path.join(codexHome, "kisa-backups", snapshots[0])]);
  assert.equal((await fsp.readFile(installedSkill, "utf8")).includes("LOCAL_DRIFT_FOR_ROLLBACK"), true);
  assert.notEqual(run("doctor", [], 1).stderr.includes("Doctor found"), false);

  console.log("KISA Codex stack regression tests passed.");
} finally {
  await fsp.rm(testRoot, { recursive: true, force: true });
}
