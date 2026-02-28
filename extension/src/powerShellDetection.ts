export type CommandProbeResult = {
  code: number;
  stdout: string;
  stderr: string;
};

export type CommandProbe = (command: string, args: string[]) => Promise<CommandProbeResult>;

export type PowerShellDetectionAttempt = {
  command: string;
  code: number;
  stderr: string;
};

export type PowerShellDetectionResult = {
  command?: string;
  attempts: PowerShellDetectionAttempt[];
};

const PROBE_ARGS = ["-NoLogo", "-NoProfile", "-Command", "exit 0"];

function isWslEnvironment(env: NodeJS.ProcessEnv | undefined): boolean {
  if (!env) {
    return false;
  }

  return Boolean(env.WSL_DISTRO_NAME && env.WSL_INTEROP);
}

export function getPowerShellCandidates(
  platform: NodeJS.Platform,
  env?: NodeJS.ProcessEnv
): string[] {
  if (platform === "win32") {
    return ["pwsh", "powershell.exe"];
  }

  if (isWslEnvironment(env)) {
    return ["pwsh", "powershell", "pwsh.exe", "powershell.exe"];
  }

  return ["pwsh", "powershell"];
}

export function getPowerShellProbeArgs(): string[] {
  return [...PROBE_ARGS];
}

export async function detectPowerShellCommand(
  platform: NodeJS.Platform,
  probe: CommandProbe,
  env?: NodeJS.ProcessEnv
): Promise<PowerShellDetectionResult> {
  const attempts: PowerShellDetectionAttempt[] = [];
  const probeArgs = getPowerShellProbeArgs();

  for (const candidate of getPowerShellCandidates(platform, env)) {
    const result = await probe(candidate, probeArgs);
    attempts.push({
      command: candidate,
      code: result.code,
      stderr: result.stderr
    });

    if (result.code === 0) {
      return {
        command: candidate,
        attempts
      };
    }
  }

  return { attempts };
}
