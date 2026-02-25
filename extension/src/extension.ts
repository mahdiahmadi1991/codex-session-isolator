import * as vscode from "vscode";
import * as path from "path";
import * as fs from "fs/promises";
import { existsSync, Dirent } from "fs";
import { spawn } from "child_process";

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

const EXTENSION_NAMESPACE = "codexProjectIsolator";
const CMD_INITIALIZE = `${EXTENSION_NAMESPACE}.initialize`;
const CMD_REOPEN = `${EXTENSION_NAMESPACE}.reopenWithLauncher`;
const CMD_OPEN_LOGS = `${EXTENSION_NAMESPACE}.openLogs`;
const CMD_OPEN_CONFIG = `${EXTENSION_NAMESPACE}.openConfig`;
const LEGACY_NAMESPACE = "codexSessionIsolator";

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

  context.subscriptions.push(
    vscode.commands.registerCommand(CMD_INITIALIZE, async () => {
      await initializeLauncher(context, output);
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand(CMD_REOPEN, async () => {
      const root = await pickTargetRoot();
      if (!root) {
        return;
      }
      await reopenWithLauncher(root);
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand(CMD_OPEN_LOGS, async () => {
      const root = await pickTargetRoot();
      if (!root) {
        return;
      }
      await openLogsFolder(root);
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand(CMD_OPEN_CONFIG, async () => {
      const root = await pickTargetRoot();
      if (!root) {
        return;
      }
      await openConfigFile(root);
    })
  );
}

export function deactivate(): void {}

async function initializeLauncher(
  context: vscode.ExtensionContext,
  output: vscode.OutputChannel
): Promise<void> {
  if (!(await ensureWorkspaceTrusted())) {
    return;
  }

  const targetRoot = await pickTargetRoot();
  if (!targetRoot) {
    return;
  }

  if (!(await confirmLauncherChanges(targetRoot))) {
    return;
  }

  const scriptPath = context.asAbsolutePath(path.join("scripts", "vsc-launcher-wizard.ps1"));
  if (!existsSync(scriptPath)) {
    void vscode.window.showErrorMessage(`Bundled wizard script not found: ${scriptPath}`);
    return;
  }

  const responses = await buildWizardResponses(targetRoot);
  if (!responses) {
    return;
  }

  const psCommand = await detectPowerShellCommand();
  if (!psCommand) {
    void vscode.window.showErrorMessage(
      "PowerShell was not found. Install powershell/pwsh to run the launcher wizard."
    );
    return;
  }

  const debugMode = getBooleanSetting("debugWizardByDefault", false);

  const args = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", scriptPath, "-TargetPath", targetRoot];
  if (debugMode) {
    args.push("-DebugMode");
  }

  output.show(true);
  output.appendLine(`[extension] Running wizard for: ${targetRoot}`);

  const exitCode = await runWizardProcess(psCommand, args, responses, targetRoot, output);
  if (exitCode !== 0) {
    void vscode.window.showErrorMessage(
      "Launcher wizard failed. See 'Codex Session Isolator' output channel for details."
    );
    return;
  }

  const action = await vscode.window.showInformationMessage(
    "Launcher generated successfully.",
    "Reopen With Launcher",
    "Open Logs",
    "Open Config"
  );

  if (action === "Reopen With Launcher") {
    await reopenWithLauncher(targetRoot);
  } else if (action === "Open Logs") {
    await openLogsFolder(targetRoot);
  } else if (action === "Open Config") {
    await openConfigFile(targetRoot);
  }
}

async function runWizardProcess(
  command: string,
  args: string[],
  responses: string[],
  cwd: string,
  output: vscode.OutputChannel
): Promise<number> {
  return new Promise<number>((resolve) => {
    const child = spawn(command, args, { cwd, env: process.env });

    child.stdout.on("data", (chunk: Buffer) => {
      output.append(chunk.toString());
    });

    child.stderr.on("data", (chunk: Buffer) => {
      output.append(chunk.toString());
    });

    child.on("error", (error: Error) => {
      output.appendLine(`[extension] Failed to start wizard process: ${error.message}`);
      resolve(1);
    });

    child.on("close", (code: number | null) => {
      resolve(code ?? 1);
    });

    if (child.stdin.writable) {
      const payload = responses.join("\n") + "\n";
      child.stdin.write(payload);
      child.stdin.end();
    }
  });
}

async function buildWizardResponses(targetRoot: string): Promise<string[] | undefined> {
  const defaults = await readWizardDefaults(targetRoot);
  const responses: string[] = [];

  const workspaceFiles = await findWorkspaceFiles(targetRoot, 3);
  if (workspaceFiles.length > 1) {
    const selected = await promptWorkspaceSelection(targetRoot, workspaceFiles);
    if (selected === undefined) {
      return undefined;
    }
    responses.push(String(selected + 1));
  }

  const wslAvailable = process.platform === "win32" && (await isWslAvailable());
  if (wslAvailable) {
    const useRemoteWsl = await promptBoolean(
      "Launch VS Code in Remote WSL mode?",
      defaults.useRemoteWsl ?? false
    );
    if (useRemoteWsl === undefined) {
      return undefined;
    }
    responses.push(useRemoteWsl ? "y" : "n");

    if (useRemoteWsl) {
      const distros = await getWslDistros();
      if (distros.length > 1) {
        const distroIndex = await promptWslDistroSelection(distros);
        if (distroIndex === undefined) {
          return undefined;
        }
        responses.push(String(distroIndex + 1));
      }
    }

    const codexRunInWsl = await promptBoolean(
      "Set Codex to run in WSL for this project?",
      defaults.codexRunInWsl ?? useRemoteWsl
    );
    if (codexRunInWsl === undefined) {
      return undefined;
    }
    responses.push(codexRunInWsl ? "y" : "n");
  }

  const ignoreSessions = await promptBoolean(
    "Ignore Codex chat sessions in gitignore?",
    defaults.ignoreSessions ?? true
  );
  if (ignoreSessions === undefined) {
    return undefined;
  }
  responses.push(ignoreSessions ? "y" : "n");

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

async function promptWslDistroSelection(distros: string[]): Promise<number | undefined> {
  const picks = distros.map((name, index) => ({ label: name, index }));
  const selected = await vscode.window.showQuickPick(picks, {
    placeHolder: "Select WSL distro for Remote WSL launch",
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

async function reopenWithLauncher(targetRoot: string): Promise<void> {
  if (!(await ensureWorkspaceTrusted())) {
    return;
  }

  const launcherPath = process.platform === "win32"
    ? path.join(targetRoot, "vsc_launcher.bat")
    : path.join(targetRoot, "vsc_launcher.sh");

  if (!existsSync(launcherPath)) {
    const action = await vscode.window.showWarningMessage(
      "Launcher file not found in target root.",
      "Initialize Launcher"
    );
    if (action === "Initialize Launcher") {
      await vscode.commands.executeCommand(CMD_INITIALIZE);
    }
    return;
  }

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

  const shouldClose = getBooleanSetting("closeWindowAfterReopen", true);
  if (shouldClose) {
    await vscode.commands.executeCommand("workbench.action.closeWindow");
  }
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

  const action = await vscode.window.showWarningMessage(
    "Initialize launcher for this project?",
    {
      modal: true,
      detail:
        `Target: ${targetRoot}\n\n` +
        "This runs a bundled PowerShell wizard and may update project files:\n" +
        "- .vscode/settings.json\n" +
        "- workspace settings in *.code-workspace\n" +
        "- .gitignore managed block\n" +
        "- vsc_launcher.* and .vsc_launcher/*"
    },
    "Initialize"
  );

  return action === "Initialize";
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
