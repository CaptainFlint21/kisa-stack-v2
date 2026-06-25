#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "..", "..");
const skillsSource = path.join(repoRoot, "skills");
const profilesDir = path.join(repoRoot, "profiles");
const hookSource = path.join(scriptDir, "hooks", "wiki-hook.mjs");
const wikiTemplate = path.join(scriptDir, "wiki-template");

function fail(message) {
  console.error(`ERROR: ${message}`);
  process.exit(1);
}

function parseArguments(argv) {
  const result = {
    action: argv[0] || "",
    profile: "",
    home: process.env.HOME || process.env.USERPROFILE || os.homedir(),
    codexHome: process.env.CODEX_HOME || "",
    vault: process.env.KISA_WIKI_VAULT || "",
    dryRun: false,
    snapshot: "",
  };

  for (let index = 1; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === "--dry-run") {
      result.dryRun = true;
      continue;
    }
    const next = argv[index + 1];
    if (!next) fail(`Missing value after ${value}`);
    if (value === "--profile") result.profile = next;
    else if (value === "--home") result.home = next;
    else if (value === "--codex-home") result.codexHome = next;
    else if (value === "--vault") result.vault = next;
    else if (value === "--snapshot") result.snapshot = next;
    else fail(`Unknown option: ${value}`);
    index += 1;
  }

  if (!["install", "sync", "doctor", "rollback"].includes(result.action)) {
    fail("Usage: node kisa.mjs <install|sync|doctor|rollback> --profile <name> [--dry-run]");
  }
  if (result.action !== "rollback" && !result.profile) fail("--profile is required");

  result.home = path.resolve(result.home);
  result.codexHome = path.resolve(result.codexHome || path.join(result.home, ".codex"));
  result.vault = path.resolve(result.vault || path.join(repoRoot, "LLM Wiki"));
  return result;
}

const options = parseArguments(process.argv.slice(2));
const skillTargetRoot = path.join(options.home, ".agents", "skills");
const hookTarget = path.join(options.codexHome, "hooks", "kisa-wiki-hook.mjs");
const hooksTarget = path.join(options.codexHome, "hooks.json");
const agentsTarget = path.join(options.codexHome, "AGENTS.md");
const backupRoot = path.join(options.codexHome, "kisa-backups");
const stateTarget = path.join(options.codexHome, "kisa-desktop-state.json");

function normalizeForComparison(value) {
  const resolved = path.resolve(value);
  return process.platform === "win32" ? resolved.toLowerCase() : resolved;
}

function isWithin(parent, child) {
  const normalizedParent = `${normalizeForComparison(parent)}${path.sep}`;
  const normalizedChild = normalizeForComparison(child);
  return normalizedChild === normalizeForComparison(parent) || normalizedChild.startsWith(normalizedParent);
}

function assertSafeTarget(target) {
  if (![options.home, options.vault].some((root) => isWithin(root, target))) {
    fail(`Refusing to modify path outside approved roots: ${target}`);
  }
}

async function exists(target) {
  try {
    await fs.lstat(target);
    return true;
  } catch {
    return false;
  }
}

async function hashFile(target) {
  return crypto.createHash("sha256").update(await fs.readFile(target)).digest("hex");
}

function ignoredRelative(relative) {
  const parts = relative.split(path.sep);
  return parts.includes("node_modules") || parts.includes("__pycache__") || path.basename(relative) === ".env";
}

async function treeManifest(root) {
  const manifest = new Map();
  if (!(await exists(root))) return manifest;

  async function visit(current, relative = "") {
    const entries = await fs.readdir(current, { withFileTypes: true });
    entries.sort((left, right) => left.name.localeCompare(right.name));
    for (const entry of entries) {
      const childRelative = path.join(relative, entry.name);
      if (ignoredRelative(childRelative)) continue;
      const child = path.join(current, entry.name);
      if (entry.isDirectory()) await visit(child, childRelative);
      else if (entry.isFile()) manifest.set(childRelative, await hashFile(child));
      else manifest.set(childRelative, `special:${entry.isSymbolicLink() ? "symlink" : "other"}`);
    }
  }

  await visit(root);
  return manifest;
}

async function sameTree(source, target) {
  const left = await treeManifest(source);
  const right = await treeManifest(target);
  if (left.size !== right.size) return false;
  for (const [name, hash] of left) {
    if (right.get(name) !== hash) return false;
  }
  return true;
}

async function sameFile(source, target) {
  if (!(await exists(target))) return false;
  return (await hashFile(source)) === (await hashFile(target));
}

async function copyTree(source, target) {
  await fs.cp(source, target, {
    recursive: true,
    force: true,
    filter: (item) => path.basename(item) !== ".env",
  });
}

let snapshotDirectory = "";
const snapshotEntries = [];

function timestamp() {
  return `${new Date().toISOString().replaceAll("-", "").replaceAll(":", "").replace(".", "-").replace("Z", "")}-${process.pid}`;
}

async function ensureSnapshot() {
  if (snapshotDirectory) return snapshotDirectory;
  snapshotDirectory = path.join(backupRoot, timestamp());
  if (!options.dryRun) await fs.mkdir(path.join(snapshotDirectory, "files"), { recursive: true });
  return snapshotDirectory;
}

async function backupTarget(target) {
  assertSafeTarget(target);
  const snapshot = await ensureSnapshot();
  const entry = { target, existed: await exists(target), backup: "" };
  if (entry.existed) {
    entry.backup = path.join("files", String(snapshotEntries.length));
    if (!options.dryRun) {
      await fs.cp(target, path.join(snapshot, entry.backup), {
        recursive: true,
        force: true,
      });
    }
  }
  snapshotEntries.push(entry);
}

async function finishSnapshot() {
  if (!snapshotDirectory || options.dryRun) return;
  await fs.writeFile(
    path.join(snapshotDirectory, "snapshot.json"),
    `${JSON.stringify({ createdAt: new Date().toISOString(), entries: snapshotEntries }, null, 2)}\n`,
    "utf8",
  );
}

function logOperation(message) {
  console.log(`${options.dryRun ? "[dry-run] " : ""}${message}`);
}

async function replaceDirectory(source, target) {
  await backupTarget(target);
  logOperation(`sync directory: ${target}`);
  if (options.dryRun) return;

  let localEnv = null;
  const localEnvPath = path.join(target, ".env");
  if (await exists(localEnvPath)) localEnv = await fs.readFile(localEnvPath);
  await fs.rm(target, { recursive: true, force: true });
  await fs.mkdir(path.dirname(target), { recursive: true });
  await copyTree(source, target);
  if (localEnv !== null) await fs.writeFile(path.join(target, ".env"), localEnv, { mode: 0o600 });
}

async function replaceFile(source, target) {
  await backupTarget(target);
  logOperation(`sync file: ${target}`);
  if (options.dryRun) return;
  await fs.mkdir(path.dirname(target), { recursive: true });
  await fs.copyFile(source, target);
}

async function writeText(target, content) {
  await backupTarget(target);
  logOperation(`write file: ${target}`);
  if (options.dryRun) return;
  await fs.mkdir(path.dirname(target), { recursive: true });
  await fs.writeFile(target, content, "utf8");
}

async function profileSkills(profile) {
  const profilePath = path.join(profilesDir, `${profile}.txt`);
  if (!(await exists(profilePath))) fail(`Profile not found: ${profile}`);
  const lines = (await fs.readFile(profilePath, "utf8")).split(/\r?\n/);
  const names = lines.map((line) => line.replace(/#.*/, "").trim()).filter(Boolean);
  if (!names.length) fail(`Profile is empty: ${profile}`);
  for (const name of names) {
    if (!(await exists(path.join(skillsSource, name, "SKILL.md")))) fail(`Skill not found: ${name}`);
    if (!(await exists(path.join(skillsSource, name, "agents", "openai.yaml")))) {
      fail(`Codex metadata missing: ${name}/agents/openai.yaml`);
    }
  }
  return names;
}

function shellQuote(value) {
  return `'${value.replaceAll("'", `'\\''`)}'`;
}

function windowsQuote(value) {
  return `"${value.replaceAll('"', '\\"')}"`;
}

function hookHandler(event) {
  const unixCommand = `${shellQuote(process.execPath)} ${shellQuote(hookTarget)} --event ${event} --vault ${shellQuote(options.vault)}`;
  const windowsCommand = `${windowsQuote(process.execPath)} ${windowsQuote(hookTarget)} --event ${event} --vault ${windowsQuote(options.vault)}`;
  return {
    type: "command",
    command: unixCommand,
    commandWindows: windowsCommand,
    timeout: 10,
    statusMessage: event === "SessionStart" ? "Loading KISA Wiki context" : "Refreshing KISA Wiki context",
  };
}

function isManagedHookGroup(group) {
  return Array.isArray(group?.hooks) && group.hooks.some((hook) => String(hook?.command || "").includes("kisa-wiki-hook.mjs"));
}

async function desiredHooksDocument() {
  let document = {};
  if (await exists(hooksTarget)) {
    try {
      document = JSON.parse(await fs.readFile(hooksTarget, "utf8"));
    } catch {
      fail(`Invalid JSON: ${hooksTarget}`);
    }
  }
  if (!document.hooks || typeof document.hooks !== "object") document.hooks = {};

  for (const event of ["SessionStart", "UserPromptSubmit"]) {
    const current = Array.isArray(document.hooks[event]) ? document.hooks[event] : [];
    const managed = {
      ...(event === "SessionStart" ? { matcher: "startup|resume|clear|compact" } : {}),
      hooks: [hookHandler(event)],
    };
    document.hooks[event] = [...current.filter((group) => !isManagedHookGroup(group)), managed];
  }
  return `${JSON.stringify(document, null, 2)}\n`;
}

async function renderedAgentsTemplate() {
  const source = await fs.readFile(path.join(repoRoot, "global-config", "AGENTS.md"), "utf8");
  return source
    .replaceAll("<ПУТЬ_К_VAULT>", path.dirname(options.vault))
    .replaceAll("<ПУТЬ_К_КЛОНУ>", path.dirname(repoRoot));
}

async function syncInstallation() {
  const names = await profileSkills(options.profile);

  for (const name of names) {
    const source = path.join(skillsSource, name);
    const target = path.join(skillTargetRoot, name);
    if (await sameTree(source, target)) console.log(`unchanged skill: ${name}`);
    else await replaceDirectory(source, target);
  }

  if (await sameFile(hookSource, hookTarget)) console.log("unchanged Wiki hook");
  else await replaceFile(hookSource, hookTarget);

  const desiredHooks = await desiredHooksDocument();
  const currentHooks = (await exists(hooksTarget)) ? await fs.readFile(hooksTarget, "utf8") : "";
  if (currentHooks === desiredHooks) console.log("unchanged hooks.json");
  else await writeText(hooksTarget, desiredHooks);

  if (!(await exists(agentsTarget))) await writeText(agentsTarget, await renderedAgentsTemplate());
  else console.log(`preserved existing AGENTS.md: ${agentsTarget}`);

  const templateFiles = await treeManifest(wikiTemplate);
  for (const relative of templateFiles.keys()) {
    const source = path.join(wikiTemplate, relative);
    const target = path.join(options.vault, relative);
    if (await exists(target)) console.log(`preserved Wiki page: ${target}`);
    else await replaceFile(source, target);
  }

  const state = {
    profile: options.profile,
    repoRoot,
    skills: names,
    codexHome: options.codexHome,
    vault: options.vault,
  };
  const currentState = (await exists(stateTarget)) ? await fs.readFile(stateTarget, "utf8") : "";
  const desiredState = `${JSON.stringify(state, null, 2)}\n`;
  if (currentState !== desiredState) await writeText(stateTarget, desiredState);

  await finishSnapshot();
  console.log(options.dryRun ? "Dry-run completed." : "KISA Codex stack synchronized.");
}

async function doctor() {
  const failures = [];
  const names = await profileSkills(options.profile);

  for (const name of names) {
    const source = path.join(skillsSource, name);
    const target = path.join(skillTargetRoot, name);
    if (!(await sameTree(source, target))) failures.push(`skill drift or missing: ${target}`);
  }
  if (!(await sameFile(hookSource, hookTarget))) failures.push(`Wiki hook drift or missing: ${hookTarget}`);

  const desiredHooks = await desiredHooksDocument();
  const currentHooks = (await exists(hooksTarget)) ? await fs.readFile(hooksTarget, "utf8") : "";
  if (currentHooks !== desiredHooks) failures.push(`hooks.json drift or missing: ${hooksTarget}`);
  if (!(await exists(agentsTarget))) failures.push(`AGENTS.md missing: ${agentsTarget}`);

  const templateFiles = await treeManifest(wikiTemplate);
  for (const relative of templateFiles.keys()) {
    const target = path.join(options.vault, relative);
    if (!(await exists(target))) failures.push(`Wiki page missing: ${target}`);
  }

  if (failures.length) {
    failures.forEach((failure) => console.error(`FAIL ${failure}`));
    fail(`Doctor found ${failures.length} problem(s)`);
  }
  console.log("OK KISA Codex stack");
}

async function latestSnapshot() {
  if (options.snapshot) return path.resolve(options.snapshot);
  if (!(await exists(backupRoot))) fail("No rollback snapshots found");
  const candidates = (await fs.readdir(backupRoot, { withFileTypes: true }))
    .filter((entry) => entry.isDirectory())
    .map((entry) => path.join(backupRoot, entry.name))
    .sort()
    .reverse();
  if (!candidates.length) fail("No rollback snapshots found");
  return candidates[0];
}

async function rollback() {
  const snapshot = await latestSnapshot();
  const manifestPath = path.join(snapshot, "snapshot.json");
  if (!(await exists(manifestPath))) fail(`Snapshot manifest missing: ${manifestPath}`);
  const manifest = JSON.parse(await fs.readFile(manifestPath, "utf8"));

  for (const entry of [...manifest.entries].reverse()) {
    assertSafeTarget(entry.target);
    logOperation(`restore: ${entry.target}`);
    if (options.dryRun) continue;
    await fs.rm(entry.target, { recursive: true, force: true });
    if (entry.existed) {
      await fs.mkdir(path.dirname(entry.target), { recursive: true });
      await fs.cp(path.join(snapshot, entry.backup), entry.target, { recursive: true, force: true });
    }
  }
  console.log(options.dryRun ? "Rollback dry-run completed." : `Rollback completed: ${snapshot}`);
}

if (options.action === "doctor") await doctor();
else if (options.action === "rollback") await rollback();
else await syncInstallation();
