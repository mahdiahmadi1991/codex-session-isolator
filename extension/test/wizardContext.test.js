const test = require("node:test");
const assert = require("node:assert/strict");
const {
  detectWizardWorkspaceContext,
  getRemoteWslDefaultDecision
} = require("../out/wizardContext.js");

test("local Windows path defaults Remote WSL to No", () => {
  const context = detectWizardWorkspaceContext("C:\\dev\\my-app", "win32", undefined);
  assert.equal(context, "windows_local");

  const decision = getRemoteWslDefaultDecision({
    targetPath: "C:\\dev\\my-app",
    platform: "win32"
  });
  assert.equal(decision.defaultValue, false);
  assert.match(decision.reason, /local Windows path/i);
});

test("WSL UNC path defaults Remote WSL to Yes", () => {
  const context = detectWizardWorkspaceContext("\\\\wsl$\\Ubuntu-24.04\\home\\user\\app", "win32", undefined);
  assert.equal(context, "wsl_unc");

  const decision = getRemoteWslDefaultDecision({
    targetPath: "\\\\wsl$\\Ubuntu-24.04\\home\\user\\app",
    platform: "win32"
  });
  assert.equal(decision.defaultValue, true);
  assert.match(decision.reason, /UNC path/i);
});

test("remote WSL workspace defaults Remote WSL to Yes", () => {
  const context = detectWizardWorkspaceContext("/home/user/app", "linux", "wsl");
  assert.equal(context, "remote_wsl");

  const decision = getRemoteWslDefaultDecision({
    targetPath: "/home/user/app",
    platform: "linux",
    remoteName: "wsl"
  });
  assert.equal(decision.defaultValue, true);
  assert.match(decision.reason, /Remote WSL workspace/i);
});

test("saved default overrides detected context", () => {
  const decision = getRemoteWslDefaultDecision({
    targetPath: "C:\\dev\\my-app",
    platform: "win32",
    storedDefault: true
  });

  assert.equal(decision.context, "stored_default");
  assert.equal(decision.defaultValue, true);
  assert.match(decision.reason, /saved default/i);
});
