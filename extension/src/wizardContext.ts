export type WizardWorkspaceContext = "remote_wsl" | "wsl_unc" | "windows_local" | "other";

export type RemoteWslDefaultDecision = {
  context: WizardWorkspaceContext | "stored_default";
  defaultValue: boolean;
  reason: string;
};

type RemoteWslDecisionInput = {
  targetPath: string;
  platform: NodeJS.Platform;
  remoteName?: string;
  storedDefault?: boolean;
};

export function isWslUncPath(targetPath: string): boolean {
  if (!targetPath) {
    return false;
  }

  return /^\\\\(?:wsl\.localhost|wsl\$)\\/i.test(targetPath);
}

export function isWindowsDrivePath(targetPath: string): boolean {
  if (!targetPath) {
    return false;
  }

  return /^[a-zA-Z]:[\\/]/.test(targetPath);
}

export function detectWizardWorkspaceContext(
  targetPath: string,
  platform: NodeJS.Platform,
  remoteName?: string
): WizardWorkspaceContext {
  const normalizedRemote = (remoteName ?? "").toLowerCase();
  if (normalizedRemote === "wsl") {
    return "remote_wsl";
  }

  if (isWslUncPath(targetPath)) {
    return "wsl_unc";
  }

  if (platform === "win32" && isWindowsDrivePath(targetPath)) {
    return "windows_local";
  }

  return "other";
}

export function getRemoteWslDefaultDecision(input: RemoteWslDecisionInput): RemoteWslDefaultDecision {
  if (typeof input.storedDefault === "boolean") {
    return {
      context: "stored_default",
      defaultValue: input.storedDefault,
      reason: "saved default from previous run"
    };
  }

  const context = detectWizardWorkspaceContext(input.targetPath, input.platform, input.remoteName);
  switch (context) {
    case "remote_wsl":
      return {
        context,
        defaultValue: true,
        reason: "default Yes: Remote WSL workspace detected"
      };
    case "wsl_unc":
      return {
        context,
        defaultValue: true,
        reason: "default Yes: WSL UNC path detected"
      };
    case "windows_local":
      return {
        context,
        defaultValue: false,
        reason: "default No: local Windows path detected"
      };
    default:
      return {
        context,
        defaultValue: false,
        reason: "default No: no WSL context detected"
      };
  }
}
