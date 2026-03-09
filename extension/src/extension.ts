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
  trackSessionHistory?: boolean;
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
  autoReopenAfterInitialize: boolean;
  promptToReopenAfterInitialize: boolean;
};

type RollbackDeleteBehavior = "Stop" | "DeletePermanently";

type RollbackRunResult = {
  exitCode: number;
  stdout: string;
  stderr: string;
};

type RollbackExecutionPlatform = "windows" | "mac" | "linux";

type RollbackExecutionDetails = {
  powerShellCommand: string;
  scriptPathForCommand: string;
  targetRootForCommand: string;
  executionPlatform: RollbackExecutionPlatform;
};

type RollbackManifestRecord = {
  kind?: string | null;
  pathScope?: string | null;
  existedBeforeSetup?: boolean;
  existsAfterSetup?: boolean;
  hadBackup?: boolean;
  backupRelativePath?: string | null;
  projectRelativePath?: string | null;
  absolutePath?: string | null;
};

type RollbackManifest = {
  schemaVersion?: number;
  latestBackupSessionId?: string | null;
  latestBackupProjectRelativePath?: string | null;
  launchMode?: string | null;
  workspaceRelativePath?: string | null;
  generatedWorkspace?: {
    createdByWizard?: boolean;
    projectRelativePath?: string | null;
  } | null;
  managedFiles?: {
    wizardDefaults?: RollbackManifestRecord | null;
    rollbackManifest?: RollbackManifestRecord | null;
    launcher?: RollbackManifestRecord | null;
    launcherConfig?: RollbackManifestRecord | null;
    launcherRunner?: RollbackManifestRecord | null;
    windowsShortcut?: (RollbackManifestRecord & {
      enabled?: boolean;
      locationKey?: string | null;
      livesInProjectRoot?: boolean;
    }) | null;
    vscodeSettings?: RollbackManifestRecord | null;
    workspaceSettings?: RollbackManifestRecord | null;
    gitignore?: RollbackManifestRecord | null;
    metadataDirectory?: RollbackManifestRecord | null;
  } | null;
  removedDuringSetup?: RollbackManifestRecord[] | null;
};

type RollbackRemovalCandidate = {
  displayPath: string;
  executionPath: string;
};

type RollbackPreflightPlan = {
  unsupportedRemovalCandidates: string[];
  requiresPermanentDeleteFallback: boolean;
};

type LogLevel = "INFO" | "WARN" | "ERROR";

type WizardPromptContext = {
  effectivePlatform: NodeJS.Platform;
  effectiveTargetPath: string;
};

const EXTENSION_NAMESPACE = "codexSessionIsolator";
const CMD_SETUP = `${EXTENSION_NAMESPACE}.setup`;
const CMD_REOPEN = `${EXTENSION_NAMESPACE}.reopenWithLauncher`;
const CMD_ROLLBACK = `${EXTENSION_NAMESPACE}.rollback`;
const CMD_OPEN_LOGS = `${EXTENSION_NAMESPACE}.openLogs`;
const CMD_OPEN_CONFIG = `${EXTENSION_NAMESPACE}.openConfig`;
const WIZARD_TIMEOUT_MS = 120_000;
const REOPEN_CLOSE_HANDOFF_DELAY_MS = 1500;
const PROJECT_EXTENSION_LOG_PREFIX = "extension";

function formatTimestamp(): string {
  return new Date().toISOString();
}

function normalizeLogMessage(message: string): { scope: string; body: string } {
  const scopes: string[] = [];
  let remaining = message.trim();
  let match = remaining.match(/^\[([^\]]+)\]\s*/);
  while (match) {
    scopes.push(match[1].trim());
    remaining = remaining.slice(match[0].length);
    match = remaining.match(/^\[([^\]]+)\]\s*/);
  }

  return {
    scope: scopes.length > 0 ? scopes.join(".") : "extension",
    body: remaining
  };
}

function appendOutputLine(
  output: vscode.OutputChannel,
  message: string,
  level: LogLevel = "INFO"
): void {
  const normalized = normalizeLogMessage(message);
  output.appendLine(`${formatTimestamp()} [${level}] [${normalized.scope}] ${normalized.body}`);
}

function getProjectExtensionLogPath(targetRoot: string): string {
  const stamp = new Date().toISOString().slice(0, 10).replace(/-/g, "");
  return path.join(targetRoot, ".vsc_launcher", "logs", `${PROJECT_EXTENSION_LOG_PREFIX}-${stamp}.log`);
}

async function appendProjectLogLine(
  targetRoot: string,
  scope: string,
  payload: Record<string, unknown>,
  level: LogLevel = "INFO"
): Promise<void> {
  const logPath = getProjectExtensionLogPath(targetRoot);
  const logDir = path.dirname(logPath);
  if (!existsSync(logDir)) {
    return;
  }

  const body = JSON.stringify(payload);
  const line = `${formatTimestamp()} [${level}] [extension.${scope}] ${body}\n`;
  try {
    await fs.appendFile(logPath, line, "utf8");
  } catch {
    // Extension-local project logging is best-effort and must never block the main flow.
  }
}

async function logOperationEvent(
  output: vscode.OutputChannel,
  targetRoot: string,
  scope: string,
  payload: Record<string, unknown>,
  level: LogLevel = "INFO"
): Promise<void> {
  appendOutputLine(output, `[extension][${scope}] ${JSON.stringify(payload)}`, level);
  await appendProjectLogLine(targetRoot, scope, payload, level);
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

function quoteForPosixSingleQuotes(value: string): string {
  return `'${value.replace(/'/g, `'\"'\"'`)}'`;
}

function quoteForPowerShellSingleQuotes(value: string): string {
  return `'${value.replace(/'/g, "''")}'`;
}

function getWindowsShortcutFileName(targetRoot: string): string {
  const leaf = path.basename(targetRoot) || "Project";
  const safeLeaf = leaf
    .replace(/[<>:"/\\|?*]/g, " ")
    .replace(/\s+/g, " ")
    .trim() || "Project";
  return `Open ${safeLeaf}.lnk`;
}

function joinWindowsPath(basePath: string, leaf: string): string {
  const trimmedBase = basePath.replace(/[\\/]+$/, "");
  return `${trimmedBase}\\${leaf}`;
}

function isWslEnvironmentRuntime(): boolean {
  return Boolean(process.env.WSL_DISTRO_NAME && process.env.WSL_INTEROP);
}

function isWindowsPowerShellExecutable(command: string): boolean {
  return /(?:^|[\\/])(pwsh|powershell)(?:\.exe)?$/i.test(command) && /\.exe$/i.test(command);
}

function inferWslDistroFromTargetPath(targetPath: string, platform: NodeJS.Platform): string | undefined {
  if (!targetPath) {
    return undefined;
  }

  const uncMatch = targetPath.match(/^\\\\(?:wsl\.localhost|wsl\$)\\([^\\]+)\\/i);
  if (uncMatch?.[1]) {
    return uncMatch[1].trim();
  }

  if (platform !== "win32" && targetPath.startsWith("/") && process.env.WSL_DISTRO_NAME) {
    return process.env.WSL_DISTRO_NAME.trim();
  }

  return undefined;
}

function getRuntimeLauncherPath(targetRoot: string): string {
  return process.platform === "win32"
    ? path.join(targetRoot, "vsc_launcher.bat")
    : path.join(targetRoot, "vsc_launcher.sh");
}

function getAlternateLauncherPath(targetRoot: string): string {
  return process.platform === "win32"
    ? path.join(targetRoot, "vsc_launcher.sh")
    : path.join(targetRoot, "vsc_launcher.bat");
}

function getAnyExistingLauncherPath(targetRoot: string): string | undefined {
  const runtimeLauncherPath = getRuntimeLauncherPath(targetRoot);
  if (existsSync(runtimeLauncherPath)) {
    return runtimeLauncherPath;
  }

  const alternateLauncherPath = getAlternateLauncherPath(targetRoot);
  if (existsSync(alternateLauncherPath)) {
    return alternateLauncherPath;
  }

  return undefined;
}

function getBooleanSetting(key: string, fallback: boolean): boolean {
  const value = vscode.workspace.getConfiguration(EXTENSION_NAMESPACE).get<boolean>(key);
  if (typeof value === "boolean") {
    return value;
  }

  return fallback;
}

export function activate(context: vscode.ExtensionContext): void {
  const output = vscode.window.createOutputChannel("Codex Session Isolator");
  context.subscriptions.push(output);

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
  const rollbackHandler = async () => {
    await rollbackLauncherCommand(context, output);
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

  context.subscriptions.push(vscode.commands.registerCommand(CMD_SETUP, setupHandler));
  context.subscriptions.push(vscode.commands.registerCommand(CMD_REOPEN, reopenHandler));
  context.subscriptions.push(vscode.commands.registerCommand(CMD_ROLLBACK, rollbackHandler));
  context.subscriptions.push(vscode.commands.registerCommand(CMD_OPEN_LOGS, openLogsHandler));
  context.subscriptions.push(vscode.commands.registerCommand(CMD_OPEN_CONFIG, openConfigHandler));
}

export function deactivate(): void {}

async function setupLauncherCommand(
  context: vscode.ExtensionContext,
  output: vscode.OutputChannel,
  targetRoot?: string,
  autoReopenAfterInitialize = false
): Promise<void> {
  const targetSelection = targetRoot
    ? { targetRoot, scope: "current" as const }
    : await pickOperationTarget();
  if (!targetSelection) {
    return;
  }

  await logOperationEvent(output, targetSelection.targetRoot, "setup", {
    phase: "selected-target",
    scope: targetSelection.scope,
    targetRoot: targetSelection.targetRoot,
    autoReopenAfterSetup: autoReopenAfterInitialize
  });

  const shouldReopen = targetSelection.scope === "current";
  const initialized = await initializeLauncherForTarget(
    context,
    output,
    targetSelection.targetRoot,
    {
      autoReopenAfterInitialize,
      promptToReopenAfterInitialize: shouldReopen && !autoReopenAfterInitialize
    }
  );

  if (initialized && targetSelection.scope === "other") {
    await showExternalTargetCompletionReport(targetSelection.targetRoot);
  }
}

async function rollbackLauncherCommand(
  context: vscode.ExtensionContext,
  output: vscode.OutputChannel
): Promise<void> {
  const targetSelection = await pickOperationTarget("Apply rollback to current project or another project?");
  if (!targetSelection) {
    return;
  }

  await logOperationEvent(output, targetSelection.targetRoot, "rollback", {
    phase: "selected-target",
    scope: targetSelection.scope,
    targetRoot: targetSelection.targetRoot
  });

  if (!(await ensureWorkspaceTrusted())) {
    await logOperationEvent(output, targetSelection.targetRoot, "rollback", {
      phase: "blocked",
      reason: "workspace-untrusted"
    }, "WARN");
    return;
  }

  const removeCodexRuntimeData = await promptRollbackCodexRuntimeDataChoice(targetSelection.targetRoot);
  if (typeof removeCodexRuntimeData !== "boolean") {
    await logOperationEvent(output, targetSelection.targetRoot, "rollback", {
      phase: "canceled",
      reason: "codex-runtime-choice-dismissed"
    }, "WARN");
    return;
  }

  await logOperationEvent(output, targetSelection.targetRoot, "rollback", {
    phase: "codex-runtime-choice",
    removeCodexRuntimeData
  });

  const executionDetails = await resolveRollbackExecutionDetails(context, output, targetSelection.targetRoot, "rollback");
  if (!executionDetails) {
    return;
  }

  const preflightPlan = await buildRollbackPreflightPlan(
    targetSelection.targetRoot,
    executionDetails,
    removeCodexRuntimeData
  );
  if (!preflightPlan) {
    await logOperationEvent(output, targetSelection.targetRoot, "rollback", {
      phase: "canceled",
      reason: "preflight-unavailable"
    }, "WARN");
    return;
  }

  let deleteBehavior: RollbackDeleteBehavior = "Stop";
  if (preflightPlan.requiresPermanentDeleteFallback) {
    const deleteChoice = await promptRollbackDeleteBehaviorChoice(
      targetSelection.targetRoot,
      preflightPlan.unsupportedRemovalCandidates.length
    );

    if (deleteChoice !== "DeletePermanently") {
      await logOperationEvent(output, targetSelection.targetRoot, "rollback", {
        phase: "canceled",
        reason: "permanent-delete-declined"
      }, "WARN");
      return;
    }

    deleteBehavior = "DeletePermanently";
    await logOperationEvent(output, targetSelection.targetRoot, "rollback", {
      phase: "fallback-approved",
      deleteBehavior,
      removeCodexRuntimeData
    }, "WARN");
  }

  const initialRun = await runRollbackForTarget(
    context,
    output,
    targetSelection.targetRoot,
    deleteBehavior,
    removeCodexRuntimeData,
    executionDetails
  );
  let successfulRun = initialRun;
  if (initialRun.exitCode !== 0 && deleteBehavior === "Stop" && rollbackNeedsPermanentDeleteDecision(initialRun)) {
    const deleteChoice = await promptRollbackDeleteBehaviorChoice(
      targetSelection.targetRoot,
      preflightPlan.unsupportedRemovalCandidates.length
    );

    if (deleteChoice !== "DeletePermanently") {
      await logOperationEvent(output, targetSelection.targetRoot, "rollback", {
        phase: "canceled",
        reason: "permanent-delete-declined"
      }, "WARN");
      return;
    }

    await logOperationEvent(output, targetSelection.targetRoot, "rollback", {
      phase: "fallback-approved",
      deleteBehavior: "DeletePermanently",
      removeCodexRuntimeData
    }, "WARN");

    const rerun = await runRollbackForTarget(
      context,
      output,
      targetSelection.targetRoot,
      "DeletePermanently",
      removeCodexRuntimeData,
      executionDetails
    );
    successfulRun = rerun;
    if (rerun.exitCode !== 0) {
      await logOperationEvent(output, targetSelection.targetRoot, "rollback", {
        phase: "failed",
        reason: "rerun-nonzero-exit",
        exitCode: rerun.exitCode
      }, "ERROR");
      void vscode.window.showErrorMessage("Rollback failed.");
      return;
    }
  } else if (initialRun.exitCode !== 0) {
    await logOperationEvent(output, targetSelection.targetRoot, "rollback", {
      phase: "failed",
      reason: "nonzero-exit",
      exitCode: initialRun.exitCode
    }, "ERROR");
    void vscode.window.showErrorMessage("Rollback failed.");
    return;
  }

  const rollbackSummary = parseRollbackSummary(successfulRun);
  await logOperationEvent(output, targetSelection.targetRoot, "rollback", {
    phase: "completed",
    scope: targetSelection.scope,
    removeCodexRuntimeData,
    restored: rollbackSummary.restored ?? 0,
    trashed: rollbackSummary.trashed ?? 0,
    permanentlyDeleted: rollbackSummary.permanentlyDeleted ?? 0,
    edited: rollbackSummary.edited ?? 0
  });

  if (targetSelection.scope === "other") {
    await showRollbackCompletionReport(targetSelection.targetRoot, true, successfulRun);
    return;
  }

  await showRollbackCompletionReport(targetSelection.targetRoot, false, successfulRun);
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

  const scriptPath = context.asAbsolutePath(path.join("scripts", "vsc-launcher-wizard.ps1"));
  if (!existsSync(scriptPath)) {
    void vscode.window.showErrorMessage(`Bundled wizard script not found: ${scriptPath}`);
    await logOperationEvent(output, targetRoot, "setup", {
      phase: "failed",
      reason: "missing-bundled-wizard",
      scriptPath
    }, "ERROR");
    return false;
  }

  const psDetection = await detectPowerShellCommandRuntime(output);
  if (!psDetection.command) {
    void vscode.window.showErrorMessage(
      "No PowerShell runtime found. Install PowerShell 7 (`pwsh`) or Windows PowerShell (`powershell.exe`), then retry. See 'Codex Session Isolator' output logs."
    );
    await logOperationEvent(output, targetRoot, "setup", {
      phase: "failed",
      reason: "powershell-not-found"
    }, "ERROR");
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
      await logOperationEvent(output, targetRoot, "setup", {
        phase: "failed",
        reason: "wsl-path-conversion-failed"
      }, "ERROR");
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
    await logOperationEvent(output, targetRoot, "setup", {
      phase: "canceled",
      reason: "prompt-canceled"
    }, "WARN");
    return false;
  }

  const args = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", scriptPathForCommand, "-TargetPath", targetRootForCommand];
  if (debugMode) {
    args.push("-DebugMode");
  }

  output.show(true);
  await logOperationEvent(output, targetRoot, "setup", {
    phase: "starting-wizard",
    targetRoot,
    effectiveTargetRoot: targetRootForCommand,
    powerShellCommand: psCommand,
    debugMode
  });
  const shouldPreFeedAnswers = isWslEnvironmentRuntime() && isWindowsPowerShellExecutable(psCommand);
  if (shouldPreFeedAnswers) {
    await logOperationEvent(output, targetRoot, "setup", {
      phase: "prefeed-enabled",
      reason: "windows-powershell-in-wsl"
    });
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
    void vscode.window.showErrorMessage("Launcher wizard timed out after 120 seconds.");
    await logOperationEvent(output, targetRoot, "setup", {
      phase: "failed",
      reason: "timeout"
    }, "ERROR");
    return false;
  }

  if (runResult.failureKind === "unknownPrompt") {
    void vscode.window.showErrorMessage("Launcher wizard stopped on an unknown prompt to avoid hanging.");
    await logOperationEvent(output, targetRoot, "setup", {
      phase: "failed",
      reason: "unknown-prompt"
    }, "ERROR");
    return false;
  }

  if (runResult.exitCode !== 0) {
    void vscode.window.showErrorMessage("Launcher wizard failed.");
    await logOperationEvent(output, targetRoot, "setup", {
      phase: "failed",
      reason: "wizard-exit-nonzero",
      exitCode: runResult.exitCode
    }, "ERROR");
    return false;
  }

  if (options.autoReopenAfterInitialize) {
    void vscode.window.showInformationMessage("Launcher setup complete. Reopening with launcher...");
    await logOperationEvent(output, targetRoot, "setup", {
      phase: "completed",
      reopenDecision: "auto"
    });
    const reopened = await reopenWithLauncher(context, output, targetRoot, false, true);
    if (!reopened) {
      return false;
    }
    return true;
  }

  if (options.promptToReopenAfterInitialize) {
    await logOperationEvent(output, targetRoot, "setup", {
      phase: "completed",
      reopenDecision: "prompt"
    });
    const action = await vscode.window.showInformationMessage(
      "Launcher generated successfully. Reopen this project with the launcher now?",
      { modal: true },
      "Reopen With Launcher",
      "Not now"
    );

    if (action === "Reopen With Launcher") {
      await logOperationEvent(output, targetRoot, "setup", {
        phase: "reopen-confirmed"
      });
      const reopened = await reopenWithLauncher(context, output, targetRoot, false, true);
      if (!reopened) {
        return false;
      }
    }
  }

  if (!options.autoReopenAfterInitialize && !options.promptToReopenAfterInitialize) {
    await logOperationEvent(output, targetRoot, "setup", {
      phase: "completed",
      reopenDecision: "none"
    });
  }

  return true;
}

async function runRollbackForTarget(
  context: vscode.ExtensionContext,
  output: vscode.OutputChannel,
  targetRoot: string,
  deleteBehavior: RollbackDeleteBehavior,
  removeCodexRuntimeData: boolean,
  executionDetails?: RollbackExecutionDetails
): Promise<RollbackRunResult> {
  const resolvedExecution = executionDetails
    ?? await resolveRollbackExecutionDetails(context, output, targetRoot, "rollback");
  if (!resolvedExecution) {
    return { exitCode: 1, stdout: "", stderr: "Rollback execution details could not be resolved." };
  }

  const psCommand = resolvedExecution.powerShellCommand;
  const debugMode = getBooleanSetting("debugWizardByDefault", false);
  const scriptPathForCommand = resolvedExecution.scriptPathForCommand;
  const targetRootForCommand = resolvedExecution.targetRootForCommand;

  const args = [
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    scriptPathForCommand,
    "-TargetPath",
    targetRootForCommand,
    "-Rollback",
    "-RollbackDeleteBehavior",
    deleteBehavior
  ];
  if (removeCodexRuntimeData) {
    args.push("-RollbackRemoveCodexRuntimeData");
  }
  if (debugMode) {
    args.push("-DebugMode");
  }

  output.show(true);
  await logOperationEvent(output, targetRoot, "rollback", {
    phase: "starting",
    targetRoot,
    effectiveTargetRoot: targetRootForCommand,
    powerShellCommand: psCommand,
    deleteBehavior,
    removeCodexRuntimeData,
    debugMode
  });
  return vscode.window.withProgress(
    {
      location: vscode.ProgressLocation.Notification,
      title: "Codex Session Isolator: Rolling back launcher changes",
      cancellable: false
    },
    async (progress) => {
      progress.report({ message: "Running rollback..." });
      return runNonInteractiveProcess(psCommand, args, targetRoot, output);
    }
  );
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
      appendOutputLine(output, `[extension] ${message}`, "ERROR");
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

async function runNonInteractiveProcess(
  command: string,
  args: string[],
  cwd: string,
  output: vscode.OutputChannel
): Promise<RollbackRunResult> {
  return new Promise<RollbackRunResult>((resolve) => {
    const child = spawn(command, args, { cwd, env: process.env });
    let stdout = "";
    let stderr = "";
    let settled = false;

    const finalize = (result: RollbackRunResult) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timeoutHandle);
      resolve(result);
    };

    child.stdout.on("data", (chunk: Buffer) => {
      const text = chunk.toString();
      stdout += text;
      output.append(text);
    });

    child.stderr.on("data", (chunk: Buffer) => {
      const text = chunk.toString();
      stderr += text;
      output.append(text);
    });

    child.on("error", (error: Error) => {
      finalize({
        exitCode: 1,
        stdout,
        stderr: `${stderr}\n${error.message}`.trim()
      });
    });

    child.on("close", (code: number | null) => {
      finalize({ exitCode: code ?? 1, stdout, stderr });
    });

    const timeoutHandle = setTimeout(() => {
      terminateProcess(child as ChildProcessWithoutNullStreams, output);
      finalize({
        exitCode: 1,
        stdout,
        stderr: `${stderr}\nRollback process timed out after ${Math.floor(WIZARD_TIMEOUT_MS / 1000)} seconds.`.trim()
      });
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
    "trackSessionHistory"
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
    appendOutputLine(output, `[extension] Failed to close wizard stdin: ${message}`, "WARN");
  }

  try {
    if (!child.killed) {
      child.kill();
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    appendOutputLine(output, `[extension] Failed to terminate wizard process: ${message}`, "WARN");
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
      const inferredDistro = inferWslDistroFromTargetPath(effectiveTargetPath, effectivePlatform);
      const inferredDistroIndex = inferredDistro
        ? distros.findIndex((name) => name.toLowerCase() === inferredDistro.toLowerCase())
        : -1;

      if (distros.length > 1 && inferredDistroIndex < 0) {
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

  const trackSessionHistory = await promptBoolean(
    "Track Codex session history in git? (config.toml stays trackable)",
    defaults.trackSessionHistory ?? false
  );
  if (trackSessionHistory === undefined) {
    return undefined;
  }
  responses.trackSessionHistory = trackSessionHistory ? "y" : "n";

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
    if (typeof parsed.trackSessionHistory !== "boolean" && typeof parsed.ignoreSessions === "boolean") {
      parsed.trackSessionHistory = !parsed.ignoreSessions;
    }
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
    appendOutputLine(output, `[extension] PowerShell detected: ${detection.command}`, "INFO");
    return { command: detection.command };
  }

  appendOutputLine(output, "[extension] PowerShell detection failed. Attempt summary:", "WARN");
  for (const attempt of detection.attempts) {
    const reason = attempt.stderr.trim().replace(/\s+/g, " ").slice(0, 200);
    appendOutputLine(
      output,
      `[extension] - ${attempt.command}: exit=${attempt.code}${reason ? `, stderr=${reason}` : ""}`,
      "WARN"
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

async function pickOperationTarget(
  placeHolder = "Apply launcher setup to current project or another project?"
): Promise<{ targetRoot: string; scope: "current" | "other" } | undefined> {
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
      placeHolder,
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

function getRollbackManifestPath(targetRoot: string): string {
  return path.join(targetRoot, ".vsc_launcher", "rollback.manifest.json");
}

async function readRollbackManifest(targetRoot: string): Promise<RollbackManifest | undefined> {
  const manifestPath = getRollbackManifestPath(targetRoot);
  if (!existsSync(manifestPath)) {
    return undefined;
  }

  const raw = await fs.readFile(manifestPath, "utf8");
  return JSON.parse(raw) as RollbackManifest;
}

function getRollbackRecordDisplayPath(targetRoot: string, record: RollbackManifestRecord | undefined | null): string | undefined {
  if (!record) {
    return undefined;
  }

  if (typeof record.projectRelativePath === "string" && record.projectRelativePath.trim().length > 0) {
    return record.projectRelativePath.replace(/\//g, path.sep);
  }

  if (typeof record.absolutePath === "string" && record.absolutePath.trim().length > 0) {
    const resolvedRoot = path.resolve(targetRoot);
    const resolvedAbsolute = path.resolve(record.absolutePath);
    if (resolvedAbsolute === resolvedRoot || resolvedAbsolute.startsWith(`${resolvedRoot}${path.sep}`)) {
      return path.relative(resolvedRoot, resolvedAbsolute) || path.basename(resolvedAbsolute);
    }
    return record.absolutePath;
  }

  return undefined;
}

function parseRollbackSummary(runResult: RollbackRunResult): { restored?: number; trashed?: number; permanentlyDeleted?: number; edited?: number } {
  const combined = `${runResult.stdout}\n${runResult.stderr}`;
  const extractCount = (label: string): number | undefined => {
    const match = combined.match(new RegExp(`-\\s+${label}:\\s+(\\d+)`, "i"));
    return match ? Number(match[1]) : undefined;
  };

  return {
    restored: extractCount("Restored"),
    trashed: extractCount("Trashed"),
    permanentlyDeleted: extractCount("PermanentlyDeleted"),
    edited: extractCount("Edited")
  };
}

function rollbackNeedsPermanentDeleteDecision(runResult: RollbackRunResult): boolean {
  const combined = `${runResult.stdout}\n${runResult.stderr}`;
  return (
    combined.includes("Native Trash/Recycle Bin is not available")
    || combined.includes("native Trash/Recycle Bin is unavailable")
  );
}

async function hasRemovableCodexRuntimeData(targetRoot: string): Promise<boolean> {
  const codexRoot = path.join(targetRoot, ".codex");
  try {
    const entries = await fs.readdir(codexRoot, { withFileTypes: true });
    return entries.some((entry) => !(entry.isFile() && entry.name.toLowerCase() === "config.toml"));
  } catch {
    return false;
  }
}

async function promptRollbackCodexRuntimeDataChoice(targetRoot: string): Promise<boolean | undefined> {
  if (!(await hasRemovableCodexRuntimeData(targetRoot))) {
    return false;
  }

  const selection = await vscode.window.showQuickPick(
    [
      {
        label: "Keep project Codex runtime data (recommended)",
        description: "Preserve .codex content",
        removeCodexRuntimeData: false
      },
      {
        label: "Remove project Codex runtime data",
        description: "Delete everything in .codex except config.toml",
        removeCodexRuntimeData: true
      }
    ],
    {
      placeHolder: `Choose how rollback should handle .codex data for ${targetRoot}`,
      canPickMany: false
    }
  );

  return selection?.removeCodexRuntimeData;
}

async function promptRollbackDeleteBehaviorChoice(
  targetRoot: string,
  unsupportedPathCount: number
): Promise<RollbackDeleteBehavior | undefined> {
  const selection = await vscode.window.showQuickPick(
    [
      {
        label: "Stop rollback (recommended)",
        description: "Do not continue if permanent deletion would be required",
        deleteBehavior: "Stop" as RollbackDeleteBehavior
      },
      {
        label: "Delete permanently",
        description: `Continue for ${unsupportedPathCount} unsupported rollback path(s) without Trash/Recycle Bin`,
        deleteBehavior: "DeletePermanently" as RollbackDeleteBehavior
      }
    ],
    {
      placeHolder: `Trash/Recycle Bin is unavailable for ${targetRoot}. Choose how rollback should continue.`,
      canPickMany: false
    }
  );

  return selection?.deleteBehavior;
}

async function resolveRollbackExecutionDetails(
  context: vscode.ExtensionContext,
  output: vscode.OutputChannel,
  targetRoot: string,
  operation: "rollback" | "setup"
): Promise<RollbackExecutionDetails | undefined> {
  const scriptPath = context.asAbsolutePath(path.join("scripts", "vsc-launcher-wizard.ps1"));
  if (!existsSync(scriptPath)) {
    void vscode.window.showErrorMessage(`Bundled wizard script not found: ${scriptPath}`);
    await logOperationEvent(output, targetRoot, operation, {
      phase: "failed",
      reason: "missing-bundled-wizard",
      scriptPath
    }, "ERROR");
    return undefined;
  }

  const psDetection = await detectPowerShellCommandRuntime(output);
  if (!psDetection.command) {
    void vscode.window.showErrorMessage(
      "No PowerShell runtime found. Install PowerShell 7 (`pwsh`) or Windows PowerShell (`powershell.exe`), then retry. See 'Codex Session Isolator' output logs."
    );
    await logOperationEvent(output, targetRoot, operation, {
      phase: "failed",
      reason: "powershell-not-found"
    }, "ERROR");
    return undefined;
  }

  const psCommand = psDetection.command;
  let scriptPathForCommand = scriptPath;
  let targetRootForCommand = targetRoot;
  let executionPlatform: RollbackExecutionPlatform =
    process.platform === "darwin" ? "mac" : process.platform === "win32" ? "windows" : "linux";

  if (isWslEnvironmentRuntime() && isWindowsPowerShellExecutable(psCommand)) {
    const convertedScriptPath = await convertWslPathToWindows(scriptPath);
    const convertedTargetRoot = await convertWslPathToWindows(targetRoot);
    if (!convertedScriptPath || !convertedTargetRoot) {
      void vscode.window.showErrorMessage(
        "Failed to convert WSL paths for Windows PowerShell execution. Ensure 'wslpath' is available, then retry."
      );
      await logOperationEvent(output, targetRoot, operation, {
        phase: "failed",
        reason: "wsl-path-conversion-failed"
      }, "ERROR");
      return undefined;
    }

    scriptPathForCommand = convertedScriptPath;
    targetRootForCommand = convertedTargetRoot;
    executionPlatform = "windows";
    appendOutputLine(output, `[extension] Using Windows PowerShell path translation for ${operation} target: ${targetRootForCommand}`);
  } else if (isWindowsPowerShellExecutable(psCommand)) {
    executionPlatform = "windows";
  }

  return {
    powerShellCommand: psCommand,
    scriptPathForCommand,
    targetRootForCommand,
    executionPlatform
  };
}

function joinExecutionRelativePath(basePath: string, portableRelativePath: string, executionPlatform: RollbackExecutionPlatform): string {
  const sanitizedRelative = portableRelativePath.replace(/^\/+/, "");
  if (executionPlatform === "windows") {
    return path.win32.join(basePath, sanitizedRelative.replace(/\//g, "\\"));
  }

  return path.posix.join(basePath, sanitizedRelative.replace(/\\/g, "/"));
}

function canUseNativeTrashForExecutionPath(targetPath: string, executionPlatform: RollbackExecutionPlatform): boolean {
  if (!targetPath.trim()) {
    return false;
  }

  if (executionPlatform === "windows") {
    return !/^\\\\/i.test(targetPath);
  }

  const homeDir = (process.env.HOME ?? os.homedir() ?? "").trim();
  return homeDir.length > 0;
}

async function buildRollbackPreflightPlan(
  targetRoot: string,
  executionDetails: RollbackExecutionDetails,
  removeCodexRuntimeData: boolean
): Promise<RollbackPreflightPlan | undefined> {
  let manifest: RollbackManifest | undefined;
  try {
    manifest = await readRollbackManifest(targetRoot);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    void vscode.window.showErrorMessage(`Rollback manifest could not be read safely: ${message}`);
    return undefined;
  }

  if (!manifest) {
    void vscode.window.showWarningMessage(
      "No rollback manifest was found for this project. Automatic rollback is not available for this target."
    );
    return undefined;
  }

  if (manifest.schemaVersion !== 1) {
    void vscode.window.showWarningMessage(
      `Rollback manifest schema version '${String(manifest.schemaVersion ?? "unknown")}' is not supported by this extension build.`
    );
    return undefined;
  }

  const managedFiles = manifest.managedFiles ?? {};
  const deletionCandidates: RollbackRemovalCandidate[] = [];
  const addRemovalCandidate = (record: RollbackManifestRecord | undefined | null) => {
    const displayPath = getRollbackRecordDisplayPath(targetRoot, record);
    if (!displayPath) {
      return;
    }

    const localProjectPath = path.resolve(targetRoot, displayPath);
    const existsNow = existsSync(localProjectPath)
      || (record?.pathScope === "external" && !!record.absolutePath && existsSync(record.absolutePath));
    if (!existsNow) {
      return;
    }

    const executionPath = record?.pathScope === "external" && record.absolutePath
      ? record.absolutePath
      : joinExecutionRelativePath(
        executionDetails.targetRootForCommand,
        displayPath.replace(/\\/g, "/"),
        executionDetails.executionPlatform
      );

    deletionCandidates.push({ displayPath, executionPath });
  };

  addRemovalCandidate(managedFiles.launcher);
  addRemovalCandidate(managedFiles.launcherConfig);
  addRemovalCandidate(managedFiles.launcherRunner);
  addRemovalCandidate(managedFiles.windowsShortcut);
  addRemovalCandidate(managedFiles.wizardDefaults);
  if (manifest.generatedWorkspace?.createdByWizard) {
    addRemovalCandidate(manifest.generatedWorkspace);
  }

  if (managedFiles.vscodeSettings && existsSync(path.join(targetRoot, ".vscode", "settings.json"))) {
    if (managedFiles.vscodeSettings.existedBeforeSetup === false) {
      deletionCandidates.push({
        displayPath: ".vscode/settings.json",
        executionPath: joinExecutionRelativePath(
          executionDetails.targetRootForCommand,
          ".vscode/settings.json",
          executionDetails.executionPlatform
        )
      });
    }
  }

  const preserveMetadataDir = Boolean(managedFiles.metadataDirectory?.existedBeforeSetup)
    || Boolean(managedFiles.wizardDefaults?.hadBackup)
    || Boolean(managedFiles.launcherConfig?.hadBackup)
    || Boolean(managedFiles.launcherRunner?.hadBackup);

  const latestBackupProjectRelativePath = typeof manifest.latestBackupProjectRelativePath === "string"
    && manifest.latestBackupProjectRelativePath.trim().length > 0
      ? manifest.latestBackupProjectRelativePath
      : undefined;

  if (preserveMetadataDir) {
    if (latestBackupProjectRelativePath) {
      const backupDisplayPath = latestBackupProjectRelativePath.replace(/\//g, path.sep);
      if (existsSync(path.join(targetRoot, backupDisplayPath))) {
        deletionCandidates.push({
          displayPath: backupDisplayPath,
          executionPath: joinExecutionRelativePath(
            executionDetails.targetRootForCommand,
            latestBackupProjectRelativePath,
            executionDetails.executionPlatform
          )
        });
      }
    }

    const manifestDisplayPath = path.join(".vsc_launcher", "rollback.manifest.json");
    if (existsSync(path.join(targetRoot, manifestDisplayPath))) {
      deletionCandidates.push({
        displayPath: manifestDisplayPath,
        executionPath: joinExecutionRelativePath(
          executionDetails.targetRootForCommand,
          ".vsc_launcher/rollback.manifest.json",
          executionDetails.executionPlatform
        )
      });
    }
  } else if (existsSync(path.join(targetRoot, ".vsc_launcher"))) {
    deletionCandidates.push({
      displayPath: ".vsc_launcher",
      executionPath: joinExecutionRelativePath(
        executionDetails.targetRootForCommand,
        ".vsc_launcher",
        executionDetails.executionPlatform
      )
    });
  }

  if (removeCodexRuntimeData) {
    const codexRoot = path.join(targetRoot, ".codex");
    try {
      const codexEntries = await fs.readdir(codexRoot, { withFileTypes: true });
      let preserveConfig = false;
      for (const entry of codexEntries) {
        if (entry.isFile() && entry.name.toLowerCase() === "config.toml") {
          preserveConfig = true;
          continue;
        }

        const displayPath = path.join(".codex", entry.name);
        deletionCandidates.push({
          displayPath,
          executionPath: joinExecutionRelativePath(
            executionDetails.targetRootForCommand,
            `.codex/${entry.name}`,
            executionDetails.executionPlatform
          )
        });
      }

      if (codexEntries.some((entry) => !(entry.isFile() && entry.name.toLowerCase() === "config.toml")) && !preserveConfig) {
        deletionCandidates.push({
          displayPath: ".codex",
          executionPath: joinExecutionRelativePath(
            executionDetails.targetRootForCommand,
            ".codex",
            executionDetails.executionPlatform
          )
        });
      }
    } catch {
      // Ignore .codex inspection errors here; the dedicated prompt already suppresses missing-path cases.
    }
  }

  const unsupportedRemovalCandidates = deletionCandidates
    .filter((candidate) => !canUseNativeTrashForExecutionPath(candidate.executionPath, executionDetails.executionPlatform))
    .map((candidate) => candidate.displayPath);

  return {
    unsupportedRemovalCandidates,
    requiresPermanentDeleteFallback: unsupportedRemovalCandidates.length > 0
  };
}

async function showRollbackCompletionReport(
  targetRoot: string,
  isExternal: boolean,
  runResult: RollbackRunResult
): Promise<void> {
  const summary = parseRollbackSummary(runResult);
  const detailLines = [
    `Target: ${targetRoot}`,
    `Restored: ${summary.restored ?? 0}`,
    `Trashed: ${summary.trashed ?? 0}`,
    `Permanently deleted: ${summary.permanentlyDeleted ?? 0}`,
    `Edited: ${summary.edited ?? 0}`
  ];

  if (isExternal) {
    detailLines.push("", "Current VS Code window was not changed because rollback targeted another project.");
  }

  await vscode.window.showInformationMessage(
    isExternal
      ? "Rollback completed for another project."
      : "Rollback completed for the current project.",
    { modal: true, detail: detailLines.join("\n") }
  );
}

async function showExternalTargetCompletionReport(targetRoot: string): Promise<void> {
  const launcherPath = getAnyExistingLauncherPath(targetRoot) ?? getRuntimeLauncherPath(targetRoot);
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
    void vscode.window.showWarningMessage("Launcher logs folder not found. Run Setup Launcher first.");
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
    void vscode.window.showWarningMessage("Launcher config not found. Run Setup Launcher first.");
    return;
  }

  const doc = await vscode.workspace.openTextDocument(vscode.Uri.file(configPath));
  await vscode.window.showTextDocument(doc, { preview: false });
}

async function reopenWithLauncher(
  context: vscode.ExtensionContext,
  output: vscode.OutputChannel,
  targetRoot: string,
  allowSetupWhenMissing: boolean,
  forceCloseCurrentWindow = false
): Promise<boolean> {
  if (!(await ensureWorkspaceTrusted())) {
    return false;
  }

  const launcherPath = getRuntimeLauncherPath(targetRoot);
  const alternateLauncherPath = getAlternateLauncherPath(targetRoot);
  const missingLauncherMessage = existsSync(alternateLauncherPath)
    ? `Launcher file for this environment was not found in target root. Found ${path.basename(alternateLauncherPath)} instead. Reinitialize launcher to regenerate the correct launcher file.`
    : "Launcher file not found in target root.";

  if (!existsSync(launcherPath)) {
    if (!allowSetupWhenMissing) {
      void vscode.window.showWarningMessage(missingLauncherMessage);
      await logOperationEvent(output, targetRoot, "reopen", {
        phase: "failed",
        reason: "launcher-missing"
      }, "WARN");
      return false;
    }

    const action = await vscode.window.showWarningMessage(
      missingLauncherMessage,
      "Setup only",
      "Setup & Reopen",
      "Cancel"
    );

    if (action === "Setup only") {
      await logOperationEvent(output, targetRoot, "reopen", {
        phase: "launcher-missing",
        resolution: "setup-only"
      }, "WARN");
      await initializeLauncherForTarget(
        context,
        output,
        targetRoot,
        { autoReopenAfterInitialize: false, promptToReopenAfterInitialize: true }
      );
      return false;
    }

    if (action === "Setup & Reopen") {
      await logOperationEvent(output, targetRoot, "reopen", {
        phase: "launcher-missing",
        resolution: "setup-and-reopen"
      }, "WARN");
      await setupLauncherCommand(context, output, targetRoot, true);
      return false;
    }

    await logOperationEvent(output, targetRoot, "reopen", {
      phase: "canceled",
      reason: "launcher-missing-cancel"
    }, "WARN");
    return false;
  }

  const appendReopenLog = (message: string) => {
    if (output) {
      appendOutputLine(output, `[extension][reopen] ${message}`);
    }
    void appendProjectLogLine(targetRoot, "reopen", { message });
  };

  await logOperationEvent(output, targetRoot, "reopen", {
    phase: "starting",
    targetRoot,
    launcherPath
  });

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

      const shortcutLaunch = await tryLaunchWindowsShortcutForTarget(targetRoot);
      if (shortcutLaunch.ok) {
        appendReopenLog(`Windows shortcut launched successfully (${shortcutLaunch.reason}).`);
        return true;
      }

      appendReopenLog(`Windows shortcut launch skipped or failed (${shortcutLaunch.reason})`);

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

      const wrappedLaunch = await trySpawnDetachedUnixLauncher(launcherPath, targetRoot);
      if (wrappedLaunch.ok) {
        appendReopenLog(`Launcher dispatched through detached shell wrapper (${wrappedLaunch.reason}).`);
        return true;
      }

      appendReopenLog(`Detached shell wrapper failed (${wrappedLaunch.reason})`);

      const directLaunch = await trySpawnDetached(launcherPath, [], targetRoot);
      if (directLaunch.ok) {
        appendReopenLog("Launcher started directly as an executable file.");
        return true;
      }

      appendReopenLog(`Direct launcher execution failed (${directLaunch.reason})`);

      const shellCandidates = ["bash", "zsh"];
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
      : "Failed to reopen with launcher. Direct execution and bash/zsh fallbacks did not start successfully. Check 'Codex Session Isolator' output logs.";
    void vscode.window.showErrorMessage(message);
    await logOperationEvent(output, targetRoot, "reopen", {
      phase: "failed",
      reason: "launcher-dispatch-failed"
    }, "ERROR");
    return false;
  }

  const shouldClose = forceCloseCurrentWindow || getBooleanSetting("closeWindowAfterReopen", false);
  if (shouldClose) {
    appendReopenLog(`Waiting ${REOPEN_CLOSE_HANDOFF_DELAY_MS}ms before closing current window to allow launcher handoff.`);
    await delay(REOPEN_CLOSE_HANDOFF_DELAY_MS);
    await vscode.commands.executeCommand("workbench.action.closeWindow");
  } else {
    void vscode.window.showInformationMessage(
      "Launcher started successfully. You can close this window after the new launcher window opens."
    );
  }

  await logOperationEvent(output, targetRoot, "reopen", {
    phase: "completed",
    closeCurrentWindow: shouldClose
  });

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

async function trySpawnDetachedUnixLauncher(
  launcherPath: string,
  cwd: string
): Promise<{ ok: boolean; reason: string }> {
  const quotedLauncherPath = quoteForPosixSingleQuotes(launcherPath);
  const dispatchCommand =
    `if command -v setsid >/dev/null 2>&1; then ` +
    `setsid -f ${quotedLauncherPath} >/dev/null 2>&1; ` +
    `elif command -v nohup >/dev/null 2>&1; then ` +
    `nohup ${quotedLauncherPath} >/dev/null 2>&1 & ` +
    `else ${quotedLauncherPath} >/dev/null 2>&1 & fi`;

  const shellCandidates = ["bash", "zsh"];
  for (const shellName of shellCandidates) {
    const launch = await trySpawnDetached(shellName, ["-lc", dispatchCommand], cwd);
    if (launch.ok) {
      return { ok: true, reason: shellName };
    }
  }

  return { ok: false, reason: "no detached shell wrapper started successfully" };
}

async function getWindowsSpecialFolderPath(folderName: "Desktop" | "StartMenu"): Promise<string | undefined> {
  const result = await runCommand(
    "powershell.exe",
    [
      "-NoProfile",
      "-Command",
      `[Environment]::GetFolderPath(${quoteForPowerShellSingleQuotes(folderName)})`
    ]
  );
  if (result.code !== 0) {
    return undefined;
  }

  const resolved = result.stdout.trim();
  return resolved.length > 0 ? resolved : undefined;
}

async function testWindowsPathExists(windowsPath: string): Promise<boolean> {
  const result = await runCommand(
    "powershell.exe",
    [
      "-NoProfile",
      "-Command",
      `if (Test-Path -LiteralPath ${quoteForPowerShellSingleQuotes(windowsPath)}) { exit 0 } else { exit 1 }`
    ]
  );
  return result.code === 0;
}

async function tryLaunchWindowsShortcutForTarget(
  targetRoot: string
): Promise<{ ok: boolean; reason: string }> {
  if (!(isWslEnvironmentRuntime())) {
    return { ok: false, reason: "not running in WSL" };
  }

  const defaults = await readWizardDefaults(targetRoot);
  if (!defaults.windowsShortcutEnabled) {
    return { ok: false, reason: "windows shortcut is disabled for this target" };
  }

  const shortcutFileName = getWindowsShortcutFileName(targetRoot);
  let shortcutWindowsPath: string | undefined;

  switch (defaults.windowsShortcutLocation) {
    case "projectRoot": {
      const shortcutWslPath = path.join(targetRoot, shortcutFileName);
      if (!existsSync(shortcutWslPath)) {
        return { ok: false, reason: "project-root shortcut file was not found" };
      }
      shortcutWindowsPath = await convertWslPathToWindows(shortcutWslPath);
      if (!shortcutWindowsPath) {
        return { ok: false, reason: "failed to convert project-root shortcut path to Windows format" };
      }
      break;
    }
    case "desktop": {
      const desktopPath = await getWindowsSpecialFolderPath("Desktop");
      if (!desktopPath) {
        return { ok: false, reason: "failed to resolve Windows Desktop path" };
      }
      shortcutWindowsPath = joinWindowsPath(desktopPath, shortcutFileName);
      break;
    }
    case "startMenu": {
      const startMenuPath = await getWindowsSpecialFolderPath("StartMenu");
      if (!startMenuPath) {
        return { ok: false, reason: "failed to resolve Windows Start Menu path" };
      }
      shortcutWindowsPath = joinWindowsPath(startMenuPath, shortcutFileName);
      break;
    }
    case "custom": {
      if (!defaults.windowsShortcutCustomPath) {
        return { ok: false, reason: "custom shortcut path is not configured" };
      }
      shortcutWindowsPath = joinWindowsPath(defaults.windowsShortcutCustomPath, shortcutFileName);
      break;
    }
    default:
      return { ok: false, reason: "shortcut location is not configured" };
  }

  if (!(await testWindowsPathExists(shortcutWindowsPath))) {
    return { ok: false, reason: `shortcut file was not found at ${shortcutWindowsPath}` };
  }

  const launch = await runCommand(
    "powershell.exe",
    [
      "-NoProfile",
      "-Command",
      `Start-Process -FilePath ${quoteForPowerShellSingleQuotes(shortcutWindowsPath)}`
    ]
  );
  if (launch.code !== 0) {
    const stderr = launch.stderr.trim().replace(/\s+/g, " ");
    return { ok: false, reason: stderr || "Start-Process failed" };
  }

  return { ok: true, reason: shortcutWindowsPath };
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
