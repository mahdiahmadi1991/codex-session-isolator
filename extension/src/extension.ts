import * as vscode from "vscode";
import * as path from "path";
import * as fs from "fs/promises";
import { existsSync, Dirent } from "fs";
import { spawn, ChildProcessWithoutNullStreams } from "child_process";
import {
  createWizardPromptParserState,
  consumeWizardOutputChunk,
  WizardPromptAnswers,
  WizardPromptId
} from "./wizardPromptMatcher";

type WizardDefaults = {
  useRemoteWsl?: boolean;
  codexRunInWsl?: boolean;
  ignoreSessions?: boolean;
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
  const targetRoot = await pickTargetRoot();
  if (!targetRoot) {
    return;
  }

  await initializeLauncherForTarget(
    context,
    output,
    targetRoot,
    { reopenAfterInitialize: false, showPostInitializeActions: true }
  );
}

async function setupLauncherCommand(
  context: vscode.ExtensionContext,
  output: vscode.OutputChannel,
  targetRoot?: string
): Promise<void> {
  const resolvedTargetRoot = targetRoot ?? await pickTargetRoot();
  if (!resolvedTargetRoot) {
    return;
  }

  await initializeLauncherForTarget(
    context,
    output,
    resolvedTargetRoot,
    { reopenAfterInitialize: true, showPostInitializeActions: false }
  );
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

  const responses = await buildWizardResponses(targetRoot);
  if (!responses) {
    return false;
  }

  const psCommand = await detectPowerShellCommand();
  if (!psCommand) {
    void vscode.window.showErrorMessage(
      "PowerShell was not found. Install powershell/pwsh to run the launcher wizard."
    );
    return false;
  }

  const debugMode = getBooleanSetting("debugWizardByDefault", false);

  const args = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", scriptPath, "-TargetPath", targetRoot];
  if (debugMode) {
    args.push("-DebugMode");
  }

  output.show(true);
  output.appendLine(`[extension] Running wizard for: ${targetRoot}`);

  const runResult = await vscode.window.withProgress(
    {
      location: vscode.ProgressLocation.Notification,
      title: "Codex Session Isolator: Initializing launcher",
      cancellable: false
    },
    async (progress) => {
      progress.report({ message: "Running launcher wizard..." });
      return runWizardProcess(psCommand, args, responses, targetRoot, output);
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
  output: vscode.OutputChannel
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
      output.appendLine(`[extension] ${message}`);
      terminateProcess(child, output);
      finalize({ exitCode: 1, failureKind, message });
    };

    const handleChunk = (stream: "stdout" | "stderr", chunk: Buffer): void => {
      if (settled) {
        return;
      }

      const text = chunk.toString();
      output.append(text);

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

        output.appendLine(
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

function terminateProcess(child: ChildProcessWithoutNullStreams, output: vscode.OutputChannel): void {
  try {
    if (child.stdin.writable) {
      child.stdin.end();
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    output.appendLine(`[extension] Failed to close wizard stdin: ${message}`);
  }

  try {
    if (!child.killed) {
      child.kill();
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    output.appendLine(`[extension] Failed to terminate wizard process: ${message}`);
  }
}

function formatPromptAnswerForLog(promptId: WizardPromptId, answer: string): string {
  if (promptId === "workspaceSelection" || promptId === "wslDistroSelection") {
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

async function buildWizardResponses(targetRoot: string): Promise<WizardPromptAnswers | undefined> {
  const defaults = await readWizardDefaults(targetRoot);
  const responses: WizardPromptAnswers = {};

  const workspaceFiles = await findWorkspaceFiles(targetRoot, 3);
  if (workspaceFiles.length > 1) {
    const selected = await promptWorkspaceSelection(targetRoot, workspaceFiles);
    if (selected === undefined) {
      return undefined;
    }
    responses.workspaceSelection = String(selected + 1);
  }

  const wslAvailable = process.platform === "win32" && (await isWslAvailable());
  if (wslAvailable) {
    const useRemoteWsl = await promptBoolean(
      "Launch VS Code in Remote WSL mode?",
      defaults.useRemoteWsl ?? true
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

    const codexRunInWsl = await promptBoolean(
      "Set Codex to run in WSL for this project?",
      defaults.codexRunInWsl ?? true
    );
    if (codexRunInWsl === undefined) {
      return undefined;
    }
    responses.codexRunInWsl = codexRunInWsl ? "y" : "n";
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

async function detectPowerShellCommand(): Promise<string | undefined> {
  if (process.platform === "win32") {
    return "powershell.exe";
  }

  for (const candidate of ["pwsh", "powershell"]) {
    const result = await runCommand(candidate, ["-NoProfile", "-Command", "$PSVersionTable.PSVersion.ToString()"]);
    if (result.code === 0) {
      return candidate;
    }
  }

  return undefined;
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

  const chosen = await vscode.window.showOpenDialog({
    canSelectFiles: false,
    canSelectFolders: true,
    canSelectMany: false,
    title: "Select project root for Codex Session Isolator"
  });

  return chosen?.[0]?.fsPath;
}

async function openLogsFolder(targetRoot: string): Promise<void> {
  const logsPath = path.join(targetRoot, ".vsc_launcher", "logs");
  if (!existsSync(logsPath)) {
    void vscode.window.showWarningMessage("Launcher logs folder not found. Initialize launcher first.");
    return;
  }

  await vscode.commands.executeCommand("revealFileInOS", vscode.Uri.file(logsPath));
}

async function openConfigFile(targetRoot: string): Promise<void> {
  const configPath = path.join(targetRoot, ".vsc_launcher", "config.json");
  if (!existsSync(configPath)) {
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

  await vscode.window.withProgress(
    {
      location: vscode.ProgressLocation.Notification,
      title: "Codex Session Isolator: Reopen With Launcher",
      cancellable: false
    },
    async (progress) => {
      progress.report({ message: "Starting launcher..." });
      if (process.platform === "win32") {
        const child = spawn("cmd.exe", ["/c", launcherPath], {
          cwd: targetRoot,
          detached: true,
          stdio: "ignore"
        });
        child.unref();
      } else {
        await runCommand("chmod", ["+x", launcherPath]);
        const child = spawn("bash", [launcherPath], {
          cwd: targetRoot,
          detached: true,
          stdio: "ignore"
        });
        child.unref();
      }
    }
  );

  const shouldClose = getBooleanSetting("closeWindowAfterReopen", true);
  if (shouldClose) {
    await vscode.commands.executeCommand("workbench.action.closeWindow");
  } else {
    void vscode.window.showInformationMessage("Launcher started successfully.");
  }

  return true;
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
        "- .gitignore managed block\n" +
        "- vsc_launcher.* and .vsc_launcher/*"
    },
    "Continue"
  );

  return action === "Continue";
}

async function findWorkspaceFiles(root: string, maxDepth: number): Promise<string[]> {
  const results: string[] = [];

  async function walk(dir: string, depth: number): Promise<void> {
    let entries: Dirent[] = [];
    try {
      entries = await fs.readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }

    for (const entry of entries) {
      const fullPath = path.join(dir, entry.name);
      if (entry.isFile() && entry.name.toLowerCase().endsWith(".code-workspace")) {
        results.push(fullPath);
      }

      if (entry.isDirectory() && depth < maxDepth) {
        await walk(fullPath, depth + 1);
      }
    }
  }

  await walk(root, 0);
  return results.sort();
}
