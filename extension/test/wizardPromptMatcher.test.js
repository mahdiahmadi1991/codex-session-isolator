const test = require("node:test");
const assert = require("node:assert/strict");
const {
  createWizardPromptParserState,
  consumeWizardOutputChunk
} = require("../out/wizardPromptMatcher.js");

test("normal flow resolves known prompts with prepared answers", () => {
  const state = createWizardPromptParserState();
  const answers = {
    workspaceSelection: "2",
    remoteWsl: "y",
    wslDistroSelection: "1",
    codexRunInWsl: "n",
    createWindowsShortcut: "y",
    windowsShortcutLocationSelection: "4",
    windowsShortcutCustomPath: "C:\\Users\\Me\\Desktop",
    ignoreSessions: "y"
  };

  const actions1 = consumeWizardOutputChunk(
    state,
    "Multiple workspace files found. Select one:\n1. app.code-workspace\n2. api.code-workspace\nSelect [default: 1]:",
    answers
  );
  assert.equal(actions1.length, 1);
  assert.deepEqual(actions1[0], {
    kind: "answer",
    promptId: "workspaceSelection",
    promptText: "Select [default: 1]:",
    answer: "2"
  });

  const actions2 = consumeWizardOutputChunk(
    state,
    "\nLaunch VS Code in Remote WSL mode? [Y/n]:",
    answers
  );
  assert.equal(actions2.length, 1);
  assert.equal(actions2[0].kind, "answer");
  assert.equal(actions2[0].promptId, "remoteWsl");
  assert.equal(actions2[0].answer, "y");

  const actions3 = consumeWizardOutputChunk(
    state,
    "\nSelect WSL distro:\n1. Ubuntu\n2. Debian\nSelect [default: 1]:",
    answers
  );
  assert.equal(actions3.length, 1);
  assert.equal(actions3[0].kind, "answer");
  assert.equal(actions3[0].promptId, "wslDistroSelection");
  assert.equal(actions3[0].answer, "1");

  const actions4 = consumeWizardOutputChunk(
    state,
    "\nSet Codex to run in WSL for this project? [Y/n]:\nCreate Windows shortcut for double-click launch? [y/N]:\nSelect Windows shortcut location:\n1. Project root\n2. Desktop\n3. Start Menu\n4. Custom path\nSelect [default: 1]:\nEnter Windows shortcut directory path [C:\\Users\\Me\\Desktop]:\nIgnore Codex chat sessions in gitignore? [y/N]:",
    answers
  );
  assert.equal(actions4.length, 5);
  assert.equal(actions4[0].kind, "answer");
  assert.equal(actions4[0].promptId, "codexRunInWsl");
  assert.equal(actions4[0].answer, "n");
  assert.equal(actions4[1].kind, "answer");
  assert.equal(actions4[1].promptId, "createWindowsShortcut");
  assert.equal(actions4[1].answer, "y");
  assert.equal(actions4[2].kind, "answer");
  assert.equal(actions4[2].promptId, "windowsShortcutLocationSelection");
  assert.equal(actions4[2].answer, "4");
  assert.equal(actions4[3].kind, "answer");
  assert.equal(actions4[3].promptId, "windowsShortcutCustomPath");
  assert.equal(actions4[3].answer, "C:\\Users\\Me\\Desktop");
  assert.equal(actions4[4].kind, "answer");
  assert.equal(actions4[4].promptId, "ignoreSessions");
  assert.equal(actions4[4].answer, "y");
});

test("unknown extra prompt fails fast", () => {
  const state = createWizardPromptParserState();
  const actions = consumeWizardOutputChunk(
    state,
    "Enable telemetry uploads? [y/N]:",
    { ignoreSessions: "y" }
  );

  assert.equal(actions.length, 1);
  assert.equal(actions[0].kind, "unknown");
  assert.match(actions[0].reason, /unknown/i);
});

test("prompt order change is handled by prompt text", () => {
  const state = createWizardPromptParserState();
  const answers = {
    remoteWsl: "n",
    codexRunInWsl: "n",
    ignoreSessions: "y"
  };

  const actions1 = consumeWizardOutputChunk(
    state,
    "Ignore Codex chat sessions in gitignore? [y/N]:",
    answers
  );
  assert.equal(actions1.length, 1);
  assert.equal(actions1[0].kind, "answer");
  assert.equal(actions1[0].promptId, "ignoreSessions");
  assert.equal(actions1[0].answer, "y");

  const actions2 = consumeWizardOutputChunk(
    state,
    "\nLaunch VS Code in Remote WSL mode? [Y/n]:",
    answers
  );
  assert.equal(actions2.length, 1);
  assert.equal(actions2[0].kind, "answer");
  assert.equal(actions2[0].promptId, "remoteWsl");
  assert.equal(actions2[0].answer, "n");

  const actions3 = consumeWizardOutputChunk(
    state,
    "\nSet Codex to run in WSL for this project? [Y/n]:",
    answers
  );
  assert.equal(actions3.length, 1);
  assert.equal(actions3[0].kind, "answer");
  assert.equal(actions3[0].promptId, "codexRunInWsl");
  assert.equal(actions3[0].answer, "n");
});

test("partial prompt split across chunks is matched once", () => {
  const state = createWizardPromptParserState();
  const answers = { ignoreSessions: "n" };

  const first = consumeWizardOutputChunk(state, "Ignore Codex chat ses", answers);
  assert.equal(first.length, 0);

  const second = consumeWizardOutputChunk(state, "sions in gitignore? [y/N]:", answers);
  assert.equal(second.length, 1);
  assert.equal(second[0].kind, "answer");
  assert.equal(second[0].promptId, "ignoreSessions");
  assert.equal(second[0].answer, "n");

  const third = consumeWizardOutputChunk(state, "\n", answers);
  assert.equal(third.length, 0);
});
