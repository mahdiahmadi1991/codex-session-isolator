import * as vscode from "vscode";
import * as path from "path";
import * as os from "os";
import * as fs from "fs/promises";
import { existsSync, Dirent } from "fs";
import { spawn, ChildProcessWithoutNullStreams } from "child_process";
import {
  createWizardPromptParserState,
  consumeWizardOutputChunk,
  WizardPromptAnswers,
  WizardPromptId
} from "./wizardPromptMatcher";
import {
  detectPowerShellCommand as detectPowerShellCommandWithProbe
} from "./powerShellDetection";
import {
  getRemoteWslDefaultDecision
} from "./wizardContext";

type WizardDefaults = {
  useRemoteWsl?: boolean;
  codexRunInWsl?: boolean;
  ignoreSessions?: boolean;
  windowsShortcutEnabled?: boolean;
  windowsShortcutLocation?: "projectRoot" | "desktop" | "startMenu" | "custom";
  windowsShortcutCustomPath?: string;
};

type ProcessResult = {
  code: number;
  stdout: string;
  stderr: string;
};

type WizardRunFailureKind = "timeout" | "unknownPrompt" | "processError";

type WizardRunResult = {
  exitCode: number;
  failureKind?: WizardRunFailureKind;
  message?: string;
};

type InitializeFlowOptions = {
  reopenAfterInitialize: boolean;
  showPostInitializeActions: boolean;
};

type WizardPromptContext = {
  effectivePlatform: NodeJS.Platform;
  effectiveTargetPath: string;
};

const EXTENSION_NAMESPACE = "codexSessionIsolator";
const LEGACY_NAMESPACE = "codexProjectIsolator";

const CMD_INITIALIZE = `${EXTENSION_NAMESPACE}.initialize`;
const CMD_SETUP = `${EXTENSION_NAMESPACE}.setup`;
const CMD_REOPEN = `${EXTENSION_NAMESPACE}.reopenWithLauncher`;
const CMD_OPEN_LOGS = `${EXTENSION_NAMESPACE}.openLogs`;
const CMD_OPEN_CONFIG = `${EXTENSION_NAMESPACE}.openConfig`;
const LEGACY_CMD_INITIALIZE = `${LEGACY_NAMESPACE}.initialize`;
const LEGACY_CMD_SETUP = `${LEGACY_NAMESPACE}.setup`;
const LEGACY_CMD_REOPEN = `${LEGACY_NAMESPACE}.reopenWithLauncher`;
const LEGACY_CMD_OPEN_LOGS = `${LEGACY_NAMESPACE}.openLogs`;
const LEGACY_CMD_OPEN_CONFIG = `${LEGACY_NAMESPACE}.openConfig`;
const WIZARD_TIMEOUT_MS = 120_000;

function formatTimestamp(): string {
  return new Date().toISOString();
}

function appendOutputLine(output: vscode.OutputChannel, message: string): void {
  output.appendLine(`${formatTimestamp()} ${message}`);
}

function isWslEnvironmentRuntime(): boolean {
  return Boolean(process.env.WSL_DISTRO_NAME && process.env.WSL_INTEROP);
}

function isWindowsPowerShellExecutable(command: string): boolean {
  return /(?:^|[\\/])(pwsh|powershell)(?:\.exe)?$/i.test(command) && /\.exe$/i.test(command);
}

function getBooleanSetting(key: string, fallback: boolean): boolean {
  const value = vscode.workspace.getConfiguration(EXTENSION_NAMESPACE).get<boolean>(key);
  if (typeof value === "boolean") {
    return value;
  }

  const legacy = vscode.workspace.getConfiguration(LEGACY_NAMESPACE).get<boolean>(key);
  if (typeof legacy === "boolean") {
    return legacy;
  }

  return fallback;
}

export function activate(context: vscode.ExtensionContext): void {
  const output = vscode.window.createOutputChannel("Codex Session Isolator");
  context.subscriptions.push(output);

  const initializeHandler = async () => {
    await initializeLauncherCommand(context, output);
  };
  const setupHandler = async () => {
    await setupLauncherCommand(context, output);
  };
  const reopenHandler = async () => {
    const root = await pickTargetRoot();
    if (!root) {
      return;
    }
    await reopenWithLauncher(context, output, root, true);
  };
  const openLogsHandler = async () => {
    const root = await pickTargetRoot();
    if (!root) {
      return;
    }
    await openLogsFolder(root);
  };
  const openConfigHandler = async () => {
    const root = await pickTargetRoot();
    if (!root) {
      return;
    }
    await openConfigFile(root);
  };

  context.subscriptions.push(vscode.commands.registerCommand(CMD_INITIALIZE, initializeHandler));
  context.subscriptions.push(vscode.commands.registerCommand(CMD_SETUP, setupHandler));
  context.subscriptions.push(vscode.commands.registerCommand(CMD_REOPEN, reopenHandler));
  context.subscriptions.push(vscode.commands.registerCommand(CMD_OPEN_LOGS, openLogsHandler));
  context.subscriptions.push(vscode.commands.registerCommand(CMD_OPEN_CONFIG, openConfigHandler));

  // Keep legacy command IDs active so older keybindings/tasks still work after renaming.
  context.subscriptions.push(vscode.commands.registerCommand(LEGACY_CMD_INITIALIZE, initializeHandler));
  context.subscriptions.push(vscode.commands.registerCommand(LEGACY_CMD_SETUP, setupHandler));
  context.subscriptions.push(vscode.commands.registerCommand(LEGACY_CMD_REOPEN, reopenHandler));
  context.subscriptions.push(vscode.commands.registerCommand(LEGACY_CMD_OPEN_LOGS, openLogsHandler));
  context.subscriptions.push(vscode.commands.registerCommand(LEGACY_CMD_OPEN_CONFIG, openConfigHandler));
}

export function deactivate(): void {}

async function initializeLauncherCommand(
  context: vscode.ExtensionContext,
  output: vscode.OutputChannel
): Promise<void> {
  const targetSelection = await pickOperationTarget();
  if (!targetSelection) {
    return;
  }

  const initialized = await initializeLauncherForTarget(
    context,
    output,
    targetSelection.targetRoot,
    {
      reopenAfterInitialize: false,
      showPostInitializeActions: targetSelection.scope === "current"
    }
  );

  if (initialized && targetSelection.scope === "other") {
    await showExternalTargetCompletionReport(targetSelection.targetRoot);
  }
}

async function setupLauncherCommand(
  context: vscode.ExtensionContext,
  output: vscode.OutputChannel,
  targetRoot?: string
): Promise<void> {
  const targetSelection = targetRoot
    ? { targetRoot, scope: "current" as const }
    : await pickOperationTarget();
  if (!targetSelection) {
    return;
  }

  const shouldReopen = targetSelection.scope === "current";
  const initialized = await initializeLauncherForTarget(
    context,
    output,
    targetSelection.targetRoot,
    { reopenAfterInitialize: shouldReopen, showPostInitializeActions: false }
  );

  if (initialized && targetSelection.scope === "other") {
    await showExternalTargetCompletionReport(targetSelection.targetRoot);
  }
}

async function initializeLauncherForTarget(
  context: vscode.ExtensionContext,
  output: vscode.OutputChannel,
  targetRoot: string,
  options: InitializeFlowOptions
): Promise<boolean> {
  if (!(await ensureWorkspaceTrusted())) {
    return false;
  }

  if (!(await confirmLauncherChanges(targetRoot))) {
    return false;
  }

  const scriptPath = context.asAbsolutePath(path.join("scripts", "vsc-launcher-wizard.ps1"));
  if (!existsSync(scriptPath)) {
    void vscode.window.showErrorMessage(`Bundled wizard script not found: ${scriptPath}`);
    return false;
  }

  const psDetection = await detectPowerShellCommandRuntime(output);
  if (!psDetection.command) {
    void vscode.window.showErrorMessage(
      "No PowerShell runtime found. Install PowerShell 7 (`pwsh`) or Windows PowerShell (`powershell.exe`), then retry. See 'Codex Session Isolator' output logs."
    );
    return false;
  }
  const psCommand = psDetection.command;

  const debugMode = getBooleanSetting("debugWizardByDefault", false);
  let scriptPathForCommand = scriptPath;
  let targetRootForCommand = targetRoot;
  if (isWslEnvironmentRuntime() && isWindowsPowerShellExecutable(psCommand)) {
    const convertedScriptPath = await convertWslPathToWindows(scriptPath);
    const convertedTargetRoot = await convertWslPathToWindows(targetRoot);
    if (!convertedScriptPath || !convertedTargetRoot) {
      void vscode.window.showErrorMessage(
        "Failed to convert WSL paths for Windows PowerShell execution. Ensure 'wslpath' is available, then retry."
      );
      return false;
    }

    scriptPathForCommand = convertedScriptPath;
    targetRootForCommand = convertedTargetRoot;
    appendOutputLine(output, `[extension] Using Windows PowerShell path translation for WSL target: ${targetRootForCommand}`);
  }

  const responseContext: WizardPromptContext = {
    effectivePlatform: isWslEnvironmentRuntime() && isWindowsPowerShellExecutable(psCommand) ? "win32" : process.platform,
    effectiveTargetPath: targetRootForCommand
  };
  const responses = await buildWizardResponses(targetRoot, responseContext);
  if (!responses) {
    return false;
  }

  const args = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", scriptPathForCommand, "-TargetPath", targetRootForCommand];
  if (debugMode) {
    args.push("-DebugMode");
  }

  output.show(true);
  appendOutputLine(output, `[extension] Running wizard for: ${targetRoot}`);
  const shouldPreFeedAnswers = isWslEnvironmentRuntime() && isWindowsPowerShellExecutable(psCommand);
  if (shouldPreFeedAnswers) {
    appendOutputLine(output, "[extension] Prefeeding wizard answers because Windows PowerShell in WSL does not reliably emit Read-Host prompts over pipes.");
  }

  const runResult = await vscode.window.withProgress(
    {
      location: vscode.ProgressLocation.Notification,
      title: "Codex Session Isolator: Initializing launcher",
      cancellable: false
    },
    async (progress) => {
      progress.report({ message: "Running launcher wizard..." });
      return runWizardProcess(psCommand, args, responses, targetRoot, output, shouldPreFeedAnswers);
    }
  );
  if (runResult.failureKind === "timeout") {
    void vscode.window.showErrorMessage(
      "Launcher wizard timed out after 120 seconds. Check 'Codex Session Isolator' output logs for details."
    );
    return false;
  }

  if (runResult.failureKind === "unknownPrompt") {
    void vscode.window.showErrorMessage(
      "Launcher wizard stopped on an unknown prompt to avoid hanging. Check 'Codex Session Isolator' output logs."
    );
    return false;
  }

  if (runResult.exitCode !== 0) {
    void vscode.window.showErrorMessage(
      "Launcher wizard failed. See 'Codex Session Isolator' output channel for details."
    );
    return false;
  }

  if (options.reopenAfterInitialize) {
    void vscode.window.showInformationMessage("Launcher setup complete. Reopening with launcher...");
    const reopened = await reopenWithLauncher(context, output, targetRoot, false);
    if (!reopened) {
      return false;
    }
    return true;
  }

  if (options.showPostInitializeActions) {
    const action = await vscode.window.showInformationMessage(
      "Launcher generated successfully.",
      "Reopen With Launcher",
      "Open Logs",
      "Open Config"
    );

    if (action === "Reopen With Launcher") {
      await reopenWithLauncher(context, output, targetRoot, false);
    } else if (action === "Open Logs") {
      await openLogsFolder(targetRoot);
    } else if (action === "Open Config") {
      await openConfigFile(targetRoot);
    }
  }

  return true;
}

async function runWizardProcess(
  command: string,
  args: string[],
  responses: WizardPromptAnswers,
  cwd: string,
  output: vscode.OutputChannel,
  preFeedAnswers: boolean
): Promise<WizardRunResult> {
  return new Promise<WizardRunResult>((resolve) => {
    const child = spawn(command, args, { cwd, env: process.env });
    const parserState = createWizardPromptParserState();
    let settled = false;

    const finalize = (result: WizardRunResult): void => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timeoutHandle);
      resolve(result);
    };

    const fail = (failureKind: WizardRunFailureKind, message: string): void => {
      appendOutputLine(output, `[extension] ${message}`);
      terminateProcess(child, output);
      finalize({ exitCode: 1, failureKind, message });
    };

    const handleChunk = (stream: "stdout" | "stderr", chunk: Buffer): void => {
      if (settled) {
        return;
      }

      const text = chunk.toString();
      output.append(text);

      if (preFeedAnswers) {
        return;
      }

      const actions = consumeWizardOutputChunk(parserState, text, responses);
      for (const action of actions) {
        if (action.kind === "unknown") {
          fail(
            "unknownPrompt",
            `Unexpected wizard prompt: ${action.promptText} (${action.reason})`
          );
          return;
        }

        const answer = `${action.answer}\n`;
        if (!child.stdin.writable) {
          fail(
            "processError",
            `Wizard stdin is not writable when answering prompt '${action.promptId}'.`
          );
          return;
        }

        appendOutputLine(
          output,
          `[extension][wizard-answer] ${JSON.stringify({
            stream,
            promptId: action.promptId,
            prompt: action.promptText,
            answer: formatPromptAnswerForLog(action.promptId, action.answer)
          })}`
        );

        child.stdin.write(answer);
      }
    };

    child.stdout.on("data", (chunk: Buffer) => {
      handleChunk("stdout", chunk);
    });

    child.stderr.on("data", (chunk: Buffer) => {
      handleChunk("stderr", chunk);
    });

    child.on("error", (error: Error) => {
      finalize({
        exitCode: 1,
        failureKind: "processError",
        message: `Failed to start wizard process: ${error.message}`
      });
    });

    if (preFeedAnswers) {
      const serializedAnswers = serializeWizardAnswersForPrefeed(responses);
      if (serializedAnswers.length > 0) {
        child.stdin.write(serializedAnswers);
      }
    }

    child.on("close", (code: number | null) => {
      finalize({ exitCode: code ?? 1 });
    });

    const timeoutHandle = setTimeout(() => {
      fail(
        "timeout",
        `Wizard process timed out after ${Math.floor(WIZARD_TIMEOUT_MS / 1000)} seconds.`
      );
    }, WIZARD_TIMEOUT_MS);
  });
}

function serializeWizardAnswersForPrefeed(responses: WizardPromptAnswers): string {
  const orderedPromptIds: WizardPromptId[] = [
    "workspaceSelection",
    "remoteWsl",
    "wslDistroSelection",
    "codexRunInWsl",
    "createWindowsShortcut",
    "windowsShortcutLocationSelection",
    "windowsShortcutCustomPath",
    "ignoreSessions"
  ];
  const orderedAnswers: string[] = [];
  for (const promptId of orderedPromptIds) {
    const value = responses[promptId];
    if (typeof value === "string" && value.length > 0) {
      orderedAnswers.push(value);
    }
  }

  if (orderedAnswers.length === 0) {
    return "";
  }

  return `${orderedAnswers.join("\n")}\n`;
}

function terminateProcess(child: ChildProcessWithoutNullStreams, output: vscode.OutputChannel): void {
  try {
    if (child.stdin.writable) {
      child.stdin.end();
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    appendOutputLine(output, `[extension] Failed to close wizard stdin: ${message}`);
  }

  try {
    if (!child.killed) {
      child.kill();
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    appendOutputLine(output, `[extension] Failed to terminate wizard process: ${message}`);
  }
}

function formatPromptAnswerForLog(promptId: WizardPromptId, answer: string): string {
  if (promptId === "workspaceSelection" || promptId === "wslDistroSelection" || promptId === "windowsShortcutLocationSelection") {
    return `option_${answer}`;
  }

  const normalized = answer.trim().toLowerCase();
  if (normalized === "y" || normalized === "yes") {
    return "yes";
  }
  if (normalized === "n" || normalized === "no") {
    return "no";
  }

  return "value";
}

async function buildWizardResponses(
  targetRoot: string,
  promptContext?: WizardPromptContext
): Promise<WizardPromptAnswers | undefined> {
  const defaults = await readWizardDefaults(targetRoot);
  const responses: WizardPromptAnswers = {};
  const effectivePlatform = promptContext?.effectivePlatform ?? process.platform;
  const effectiveTargetPath = promptContext?.effectiveTargetPath ?? targetRoot;

  const workspaceFiles = await findWorkspaceFiles(targetRoot);
  if (workspaceFiles.length > 1) {
    const selected = await promptWorkspaceSelection(targetRoot, workspaceFiles);
    if (selected === undefined) {
      return undefined;
    }
    responses.workspaceSelection = String(selected + 1);
  }

  const wslAvailable = effectivePlatform === "win32" && (await isWslAvailable());
  if (wslAvailable) {
    const remoteDefaultDecision = getRemoteWslDefaultDecision({
      targetPath: effectiveTargetPath,
      platform: effectivePlatform,
      remoteName: vscode.env.remoteName,
      storedDefault: defaults.useRemoteWsl
    });
    const useRemoteWsl = await promptBoolean(
      "Launch VS Code in Remote WSL mode?",
      remoteDefaultDecision.defaultValue
    );
    if (useRemoteWsl === undefined) {
      return undefined;
    }
    responses.remoteWsl = useRemoteWsl ? "y" : "n";

    if (useRemoteWsl) {
      const distros = await getWslDistros();
      if (distros.length > 1) {
        const defaultDistro = await getDefaultWslDistro();
        let defaultIndex = distros.findIndex((name) =>
          !!defaultDistro && name.toLowerCase() === defaultDistro.toLowerCase()
        );
        if (defaultIndex < 0) {
          defaultIndex = 0;
        }

        const distroIndex = await promptWslDistroSelection(distros, defaultIndex);
        if (distroIndex === undefined) {
          return undefined;
        }
        responses.wslDistroSelection = String(distroIndex + 1);
      }
    }

    if (useRemoteWsl) {
      const codexRunInWsl = await promptBoolean(
        "Set Codex to run in WSL for this project?",
        defaults.codexRunInWsl ?? true
      );
      if (codexRunInWsl === undefined) {
        return undefined;
      }
      responses.codexRunInWsl = codexRunInWsl ? "y" : "n";
    }
  }

  if (isWslShortcutTarget(effectiveTargetPath, effectivePlatform)) {
    const createShortcut = await promptBoolean(
      "Create Windows shortcut for double-click launch?",
      defaults.windowsShortcutEnabled ?? false
    );
    if (createShortcut === undefined) {
      return undefined;
    }
    responses.createWindowsShortcut = createShortcut ? "y" : "n";

    if (createShortcut) {
      const selectedLocation = await promptWindowsShortcutLocation(defaults.windowsShortcutLocation ?? "projectRoot");
      if (!selectedLocation) {
        return undefined;
      }
      responses.windowsShortcutLocationSelection = String(selectedLocation.index + 1);

      if (selectedLocation.key === "custom") {
        const customPath = await promptWindowsShortcutCustomPath(defaults.windowsShortcutCustomPath ?? "");
        if (customPath === undefined) {
          return undefined;
        }
        responses.windowsShortcutCustomPath = customPath;
      }
    }
  }

  const ignoreSessions = await promptBoolean(
    "Ignore Codex chat sessions in gitignore?",
    defaults.ignoreSessions ?? false
  );
  if (ignoreSessions === undefined) {
    return undefined;
  }
  responses.ignoreSessions = ignoreSessions ? "y" : "n";

  return responses;
}

function isWslShortcutTarget(targetPath: string, platform: NodeJS.Platform): boolean {
  if (!targetPath) {
    return false;
  }

  if (platform === "win32") {
    return /^\\\\(?:wsl\.localhost|wsl\$)\\/i.test(targetPath);
  }

  const inWsl = !!process.env.WSL_DISTRO_NAME && !!process.env.WSL_INTEROP;
  return inWsl && targetPath.startsWith("/");
}

async function promptWorkspaceSelection(root: string, workspaceFiles: string[]): Promise<number | undefined> {
  const picks = workspaceFiles.map((filePath, index) => ({
    label: path.relative(root, filePath).replace(/\\/g, "/"),
    description: filePath,
    index
  }));

  const selected = await vscode.window.showQuickPick(picks, {
    placeHolder: "Multiple workspace files found. Select launch target.",
    canPickMany: false
  });

  return selected?.index;
}

async function promptWslDistroSelection(
  distros: string[],
  defaultIndex: number
): Promise<number | undefined> {
  const picks = distros.map((name, index) => ({
    label: name,
    description: index === defaultIndex ? "Windows default distro" : undefined,
    index
  }));
  const selected = await vscode.window.showQuickPick(picks, {
    placeHolder: `Select WSL distro for Remote WSL launch (default: ${distros[defaultIndex]})`,
    canPickMany: false
  });

  return selected?.index;
}

async function promptWindowsShortcutLocation(
  defaultLocation: "projectRoot" | "desktop" | "startMenu" | "custom"
): Promise<{ key: "projectRoot" | "desktop" | "startMenu" | "custom"; index: number } | undefined> {
  const ordered: Array<{ key: "projectRoot" | "desktop" | "startMenu" | "custom"; label: string }> = [
    { key: "projectRoot", label: "Project root" },
    { key: "desktop", label: "Desktop" },
    { key: "startMenu", label: "Start Menu" },
    { key: "custom", label: "Custom path" }
  ];

  let defaultIndex = ordered.findIndex((item) => item.key === defaultLocation);
  if (defaultIndex < 0) {
    defaultIndex = 0;
  }

  const picks = ordered.map((item, index) => ({
    label: item.label,
    description: index === defaultIndex ? "Default" : undefined,
    key: item.key,
    index
  }));

  const selected = await vscode.window.showQuickPick(picks, {
    placeHolder: "Select Windows shortcut location",
    canPickMany: false
  });

  if (!selected) {
    return undefined;
  }

  return { key: selected.key, index: selected.index };
}

async function promptWindowsShortcutCustomPath(defaultPath: string): Promise<string | undefined> {
  const value = await vscode.window.showInputBox({
    prompt: "Enter Windows shortcut directory path",
    value: defaultPath.trim(),
    ignoreFocusOut: true
  });

  if (value === undefined) {
    return undefined;
  }

  const trimmed = value.trim();
  if (trimmed.length === 0) {
    return undefined;
  }

  return trimmed;
}

async function promptBoolean(prompt: string, defaultValue: boolean): Promise<boolean | undefined> {
  const picks: Array<{ label: string; value: boolean }> = defaultValue
    ? [
        { label: "Yes (default)", value: true },
        { label: "No", value: false }
      ]
    : [
        { label: "No (default)", value: false },
        { label: "Yes", value: true }
      ];

  const selected = await vscode.window.showQuickPick(picks, {
    placeHolder: prompt,
    canPickMany: false
  });

  return selected?.value;
}

async function readWizardDefaults(targetRoot: string): Promise<WizardDefaults> {
  try {
    const defaultsPath = path.join(targetRoot, ".vsc_launcher", "wizard.defaults.json");
    if (!existsSync(defaultsPath)) {
      return {};
    }

    const raw = await fs.readFile(defaultsPath, "utf8");
    const parsed = JSON.parse(raw) as WizardDefaults;
    return parsed ?? {};
  } catch {
    return {};
  }
}

async function detectPowerShellCommandRuntime(
  output: vscode.OutputChannel
): Promise<{ command?: string }> {
  const detection = await detectPowerShellCommandWithProbe(process.platform, runCommand, process.env);
  if (detection.command) {
    appendOutputLine(output, `[extension] PowerShell detected: ${detection.command}`);
    return { command: detection.command };
  }

  appendOutputLine(output, "[extension] PowerShell detection failed. Attempt summary:");
  for (const attempt of detection.attempts) {
    const reason = attempt.stderr.trim().replace(/\s+/g, " ").slice(0, 200);
    appendOutputLine(
      output,
      `[extension] - ${attempt.command}: exit=${attempt.code}${reason ? `, stderr=${reason}` : ""}`
    );
  }

  return {};
}

async function isWslAvailable(): Promise<boolean> {
  const status = await runCommand("wsl.exe", ["--status"]);
  return status.code === 0;
}

async function getWslDistros(): Promise<string[]> {
  const result = await runCommand("wsl.exe", ["-l", "-q"]);
  if (result.code !== 0) {
    return [];
  }

  return result.stdout
    .split(/\r?\n/)
    .map((line) => line.replace(/\u0000/g, "").trim())
    .filter((line) => line.length > 0 && !/^docker-desktop(-data)?$/i.test(line));
}

async function getDefaultWslDistro(): Promise<string | undefined> {
  const result = await runCommand("wsl.exe", ["--status"]);
  if (result.code !== 0) {
    return undefined;
  }

  const normalized = result.stdout.replace(/\u0000/g, "");
  const match = normalized.match(/Default\s*Distribution:\s*([^\r\n]+)/i);
  return match?.[1]?.trim();
}

async function runCommand(command: string, args: string[]): Promise<ProcessResult> {
  return new Promise<ProcessResult>((resolve) => {
    const child = spawn(command, args, { env: process.env });
    let stdout = "";
    let stderr = "";

    child.stdout.on("data", (chunk: Buffer) => {
      stdout += chunk.toString();
    });

    child.stderr.on("data", (chunk: Buffer) => {
      stderr += chunk.toString();
    });

    child.on("error", (error: Error) => {
      resolve({ code: 1, stdout, stderr: `${stderr}\n${error.message}`.trim() });
    });

    child.on("close", (code: number | null) => {
      resolve({ code: code ?? 1, stdout, stderr });
    });
  });
}

async function convertWslPathToWindows(inputPath: string): Promise<string | undefined> {
  const result = await runCommand("wslpath", ["-w", inputPath]);
  if (result.code !== 0) {
    return undefined;
  }

  const converted = result.stdout.trim();
  return converted.length > 0 ? converted : undefined;
}

async function pickTargetRoot(): Promise<string | undefined> {
  const folders = vscode.workspace.workspaceFolders ?? [];

  if (folders.length === 1) {
    return folders[0].uri.fsPath;
  }

  if (folders.length > 1) {
    const picks = folders.map((folder) => ({
      label: folder.name,
      description: folder.uri.fsPath,
      path: folder.uri.fsPath
    }));
    const selected = await vscode.window.showQuickPick(picks, {
      placeHolder: "Select workspace root",
      canPickMany: false
    });
    if (selected) {
      return selected.path;
    }
  }

  const defaultPickerUri = getProjectPickerDefaultUri();
  const chosen = await vscode.window.showOpenDialog({
    canSelectFiles: false,
    canSelectFolders: true,
    canSelectMany: false,
    title: "Select project root for Codex Session Isolator",
    defaultUri: defaultPickerUri
  });

  return chosen?.[0]?.fsPath;
}

async function pickCurrentWorkspaceRootOnly(): Promise<string | undefined> {
  const folders = vscode.workspace.workspaceFolders ?? [];
  if (folders.length === 1) {
    return folders[0].uri.fsPath;
  }

  if (folders.length > 1) {
    const picks = folders.map((folder) => ({
      label: folder.name,
      description: folder.uri.fsPath,
      path: folder.uri.fsPath
    }));
    const selected = await vscode.window.showQuickPick(picks, {
      placeHolder: "Select current workspace root",
      canPickMany: false
    });
    return selected?.path;
  }

  return undefined;
}

async function pickTargetRootFromDialog(): Promise<string | undefined> {
  const defaultPickerUri = getProjectPickerDefaultUri();
  const chosen = await vscode.window.showOpenDialog({
    canSelectFiles: false,
    canSelectFolders: true,
    canSelectMany: false,
    title: "Select target project root for Codex Session Isolator",
    defaultUri: defaultPickerUri
  });
  return chosen?.[0]?.fsPath;
}

function getProjectPickerDefaultUri(): vscode.Uri {
  const remoteName = (vscode.env.remoteName ?? "").toLowerCase();
  const envHome = (process.env.HOME ?? "").trim();
  const osHome = (os.homedir() ?? "").trim();
  let username = "";
  try {
    username = (os.userInfo().username ?? "").trim();
  } catch {
    username = "";
  }

  // In Remote WSL, prefer canonical Linux home (/home/<user>) even when HOME/os.homedir is overridden.
  if (remoteName === "wsl" || !!process.env.WSL_DISTRO_NAME) {
    if (username) {
      const canonicalWslHome = path.posix.join("/home", username);
      if (existsSync(canonicalWslHome)) {
        return vscode.Uri.file(canonicalWslHome);
      }
      return vscode.Uri.file(canonicalWslHome);
    }

    if (envHome && envHome.startsWith("/home/")) {
      return vscode.Uri.file(envHome);
    }
    if (osHome && osHome.startsWith("/home/")) {
      return vscode.Uri.file(osHome);
    }
    return vscode.Uri.file("/home");
  }

  if (envHome) {
    return vscode.Uri.file(envHome);
  }
  if (osHome) {
    return vscode.Uri.file(osHome);
  }
  return vscode.Uri.file(path.parse(process.cwd()).root || "/");
}

async function pickOperationTarget(): Promise<{ targetRoot: string; scope: "current" | "other" } | undefined> {
  const currentRoot = await pickCurrentWorkspaceRootOnly();
  if (!currentRoot) {
    const fallback = await pickTargetRoot();
    return fallback ? { targetRoot: fallback, scope: "other" } : undefined;
  }

  const selection = await vscode.window.showQuickPick(
    [
      {
        label: "Current project (recommended)",
        description: currentRoot,
        scope: "current" as const
      },
      {
        label: "Another project",
        description: "Select a different folder",
        scope: "other" as const
      }
    ],
    {
      placeHolder: "Apply launcher setup to current project or another project?",
      canPickMany: false
    }
  );

  if (!selection) {
    return undefined;
  }

  if (selection.scope === "current") {
    return { targetRoot: currentRoot, scope: "current" };
  }

  const otherRoot = await pickTargetRootFromDialog();
  if (!otherRoot) {
    return undefined;
  }

  return { targetRoot: otherRoot, scope: "other" };
}

async function showExternalTargetCompletionReport(targetRoot: string): Promise<void> {
  const launcherPath = process.platform === "win32"
    ? path.join(targetRoot, "vsc_launcher.bat")
    : path.join(targetRoot, "vsc_launcher.sh");
  const logsPath = path.join(targetRoot, ".vsc_launcher", "logs");
  const details =
    `Target: ${targetRoot}\n` +
    `Launcher: ${launcherPath}\n` +
    `Logs: ${logsPath}\n\n` +
    "Current VS Code window was not reopened because a different project was selected.";

  const action = await vscode.window.showInformationMessage(
    "Launcher setup completed for another project.",
    { modal: true, detail: details },
    "Open Logs",
    "Open Config"
  );

  if (action === "Open Logs") {
    await openLogsFolder(targetRoot);
  } else if (action === "Open Config") {
    await openConfigFile(targetRoot);
  }
}

async function openLogsFolder(targetRoot: string): Promise<void> {
  const logsPath = path.join(targetRoot, ".vsc_launcher", "logs");
  if (!existsSync(logsPath)) {
    void vscode.window.showWarningMessage("Launcher logs folder not found. Initialize launcher first.");
    return;
  }

  let entries: Dirent[] = [];
  try {
    entries = await fs.readdir(logsPath, { withFileTypes: true });
  } catch {
    entries = [];
  }

  const logCandidates = entries
    .filter((entry) => entry.isFile() && entry.name.toLowerCase().endsWith(".log"))
    .map((entry) => path.join(logsPath, entry.name));

  if (logCandidates.length === 0) {
    void vscode.window.showInformationMessage(`Launcher logs folder is empty: ${logsPath}`);
    return;
  }

  let latestLogPath = logCandidates[0];
  for (const candidate of logCandidates.slice(1)) {
    try {
      const [currentStat, candidateStat] = await Promise.all([
        fs.stat(latestLogPath),
        fs.stat(candidate)
      ]);
      if (candidateStat.mtimeMs > currentStat.mtimeMs) {
        latestLogPath = candidate;
      }
    } catch {
      // Keep current best candidate.
    }
  }

  const doc = await vscode.workspace.openTextDocument(vscode.Uri.file(latestLogPath));
  await vscode.window.showTextDocument(doc, { preview: false });
}

async function openConfigFile(targetRoot: string): Promise<void> {
  const configCandidates = [
    path.join(targetRoot, ".vsc_launcher", "config.json"),
    path.join(targetRoot, ".vsc_launcher", "config.env")
  ];
  const configPath = configCandidates.find((candidate) => existsSync(candidate));
  if (!configPath) {
    void vscode.window.showWarningMessage("Launcher config not found. Initialize launcher first.");
    return;
  }

  const doc = await vscode.workspace.openTextDocument(vscode.Uri.file(configPath));
  await vscode.window.showTextDocument(doc, { preview: false });
}

async function reopenWithLauncher(
  context: vscode.ExtensionContext,
  output: vscode.OutputChannel,
  targetRoot: string,
  allowSetupWhenMissing: boolean
): Promise<boolean> {
  if (!(await ensureWorkspaceTrusted())) {
    return false;
  }

  const launcherPath = process.platform === "win32"
    ? path.join(targetRoot, "vsc_launcher.bat")
    : path.join(targetRoot, "vsc_launcher.sh");

  if (!existsSync(launcherPath)) {
    if (!allowSetupWhenMissing) {
      void vscode.window.showWarningMessage("Launcher file not found in target root.");
      return false;
    }

    const action = await vscode.window.showWarningMessage(
      "Launcher file not found in target root.",
      "Initialize only",
      "Initialize & Reopen",
      "Cancel"
    );

    if (action === "Initialize only") {
      await initializeLauncherForTarget(
        context,
        output,
        targetRoot,
        { reopenAfterInitialize: false, showPostInitializeActions: true }
      );
      return false;
    }

    if (action === "Initialize & Reopen") {
      await setupLauncherCommand(context, output, targetRoot);
      return false;
    }

    return false;
  }

  const appendReopenLog = (message: string) => {
    if (output) {
      appendOutputLine(output, `[extension][reopen] ${message}`);
    }
  };

  const launched = await vscode.window.withProgress(
    {
      location: vscode.ProgressLocation.Notification,
      title: "Codex Session Isolator: Reopen With Launcher",
      cancellable: false
    },
    async (progress) => {
      progress.report({ message: "Starting launcher..." });
      if (process.platform === "win32") {
        const launch = await trySpawnDetachedWindowsLauncher(launcherPath, targetRoot);
        if (!launch.ok) {
          appendReopenLog(`Windows launcher start failed (${launch.reason})`);
          return false;
        }

        appendReopenLog("Launcher started using cmd.exe.");
        return true;
      }

      const isExecutableBefore = await isFileExecutable(launcherPath);
      if (!isExecutableBefore) {
        const chmodResult = await runCommand("chmod", ["+x", launcherPath]);
        if (chmodResult.code !== 0) {
          appendReopenLog(
            `Warning: chmod +x failed for launcher (exit=${chmodResult.code}). Trying to run via shell fallback anyway.`
          );
        } else {
          appendReopenLog("Launcher executable bit set with chmod +x.");
        }
      } else {
        appendReopenLog("Launcher is already executable; skipping chmod.");
      }

      const shellCandidates = ["bash", "zsh", "sh"];
      for (const shellName of shellCandidates) {
        const launch = await trySpawnDetached(shellName, [launcherPath], targetRoot);
        if (launch.ok) {
          appendReopenLog(`Launcher started using shell: ${shellName}`);
          return true;
        }

        appendReopenLog(`Shell launch failed: ${shellName} (${launch.reason})`);
      }

      return false;
    }
  );

  if (!launched) {
    const message = process.platform === "win32"
      ? "Failed to start launcher via cmd.exe. Check 'Codex Session Isolator' output logs."
      : "Failed to reopen with launcher using bash/zsh/sh. Ensure at least one shell is installed and check 'Codex Session Isolator' output logs.";
    void vscode.window.showErrorMessage(message);
    return false;
  }

  const shouldClose = getBooleanSetting("closeWindowAfterReopen", false);
  if (shouldClose) {
    await vscode.commands.executeCommand("workbench.action.closeWindow");
  } else {
    void vscode.window.showInformationMessage(
      "Launcher started successfully. You can close this window after the new launcher window opens."
    );
  }

  return true;
}

async function isFileExecutable(filePath: string): Promise<boolean> {
  try {
    const stat = await fs.stat(filePath);
    return (stat.mode & 0o111) !== 0;
  } catch {
    return false;
  }
}

async function trySpawnDetached(
  command: string,
  args: string[],
  cwd: string
): Promise<{ ok: boolean; reason: string }> {
  return new Promise<{ ok: boolean; reason: string }>((resolve) => {
    const child = spawn(command, args, {
      cwd,
      detached: true,
      stdio: "ignore"
    });

    child.once("error", (error: Error) => {
      const message = error.message || "unknown spawn error";
      resolve({ ok: false, reason: message });
    });

    child.once("spawn", () => {
      child.unref();
      resolve({ ok: true, reason: "" });
    });
  });
}

async function trySpawnDetachedWindowsLauncher(
  launcherPath: string,
  cwd: string
): Promise<{ ok: boolean; reason: string }> {
  return new Promise<{ ok: boolean; reason: string }>((resolve) => {
    const command = `"${launcherPath.replace(/"/g, "\"\"")}"`;
    const child = spawn("cmd.exe", ["/d", "/s", "/c", command], {
      cwd,
      detached: true,
      stdio: "ignore",
      windowsHide: true
    });

    child.once("error", (error: Error) => {
      const message = error.message || "unknown spawn error";
      resolve({ ok: false, reason: message });
    });

    child.once("spawn", () => {
      child.unref();
      resolve({ ok: true, reason: "" });
    });
  });
}

async function ensureWorkspaceTrusted(): Promise<boolean> {
  if (vscode.workspace.isTrusted) {
    return true;
  }

  const action = await vscode.window.showWarningMessage(
    "Codex Session Isolator requires a trusted workspace to run project launchers and scripts.",
    "Manage Workspace Trust"
  );

  if (action === "Manage Workspace Trust") {
    await vscode.commands.executeCommand("workbench.trust.manage");
  }

  return false;
}

async function confirmLauncherChanges(targetRoot: string): Promise<boolean> {
  const requireConfirmation = getBooleanSetting("requireConfirmation", true);
  if (!requireConfirmation) {
    return true;
  }

  const action = await vscode.window.showInformationMessage(
    "Initialize project launcher for this workspace?",
    {
      modal: true,
      detail:
        `Target: ${targetRoot}\n\n` +
        "This runs the bundled setup wizard and updates project-local files:\n" +
        "- .vscode/settings.json\n" +
        "- workspace settings in *.code-workspace\n" +
        "- .gitignore managed block (if .gitignore already exists)\n" +
        "- vsc_launcher.* and .vsc_launcher/*"
    },
    "Continue"
  );

  return action === "Continue";
}

async function findWorkspaceFiles(root: string): Promise<string[]> {
  let entries: Dirent[] = [];
  try {
    entries = await fs.readdir(root, { withFileTypes: true });
  } catch {
    return [];
  }

  return entries
    .filter((entry) => entry.isFile() && entry.name.toLowerCase().endsWith(".code-workspace"))
    .map((entry) => path.join(root, entry.name))
    .sort();
}
