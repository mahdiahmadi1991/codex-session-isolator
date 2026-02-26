const test = require("node:test");
const assert = require("node:assert/strict");
const {
  detectPowerShellCommand,
  getPowerShellProbeArgs
} = require("../out/powerShellDetection.js");

test("prefers pwsh on Windows when available", async () => {
  const calls = [];
  const probe = async (command, args) => {
    calls.push({ command, args });
    if (command === "pwsh") {
      return { code: 0, stdout: "", stderr: "" };
    }
    return { code: 1, stdout: "", stderr: "not reached" };
  };

  const result = await detectPowerShellCommand("win32", probe);
  assert.equal(result.command, "pwsh");
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0].args, getPowerShellProbeArgs());
});

test("falls back to powershell.exe on Windows if pwsh is missing", async () => {
  const calls = [];
  const probe = async (command, args) => {
    calls.push({ command, args });
    if (command === "pwsh") {
      return { code: 1, stdout: "", stderr: "ENOENT" };
    }
    if (command === "powershell.exe") {
      return { code: 0, stdout: "", stderr: "" };
    }
    return { code: 1, stdout: "", stderr: "unexpected" };
  };

  const result = await detectPowerShellCommand("win32", probe);
  assert.equal(result.command, "powershell.exe");
  assert.deepEqual(calls.map((entry) => entry.command), ["pwsh", "powershell.exe"]);
  assert.deepEqual(calls[0].args, getPowerShellProbeArgs());
  assert.deepEqual(calls[1].args, getPowerShellProbeArgs());
});

test("returns no command when neither PowerShell runtime exists", async () => {
  const probe = async (command) => ({
    code: 1,
    stdout: "",
    stderr: `${command} not found`
  });

  const result = await detectPowerShellCommand("win32", probe);
  assert.equal(result.command, undefined);
  assert.equal(result.attempts.length, 2);
  assert.deepEqual(result.attempts.map((attempt) => attempt.command), ["pwsh", "powershell.exe"]);
});

test("non-Windows checks pwsh before powershell", async () => {
  const calls = [];
  const probe = async (command) => {
    calls.push(command);
    if (command === "pwsh") {
      return { code: 1, stdout: "", stderr: "missing" };
    }
    return { code: 0, stdout: "", stderr: "" };
  };

  const result = await detectPowerShellCommand("linux", probe);
  assert.equal(result.command, "powershell");
  assert.deepEqual(calls, ["pwsh", "powershell"]);
});
