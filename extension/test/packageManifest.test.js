const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const manifestPath = path.resolve(__dirname, "..", "package.json");
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));

test("manifest exposes only the supported command surface", () => {
  const commands = manifest.contributes.commands.map((entry) => entry.command);

  assert.deepEqual(commands, [
    "codexSessionIsolator.setup",
    "codexSessionIsolator.reopenWithLauncher",
    "codexSessionIsolator.rollback",
    "codexSessionIsolator.openLogs",
    "codexSessionIsolator.openConfig"
  ]);
  assert.ok(!commands.includes("codexSessionIsolator.initialize"));
  assert.ok(commands.every((command) => !command.startsWith("codexProjectIsolator.")));
});

test("manifest activation events no longer include legacy commands", () => {
  assert.deepEqual(manifest.activationEvents, [
    "onCommand:codexSessionIsolator.setup",
    "onCommand:codexSessionIsolator.reopenWithLauncher",
    "onCommand:codexSessionIsolator.rollback",
    "onCommand:codexSessionIsolator.openLogs",
    "onCommand:codexSessionIsolator.openConfig"
  ]);
  assert.ok(
    manifest.activationEvents.every((event) => !event.includes("codexProjectIsolator."))
  );
});
