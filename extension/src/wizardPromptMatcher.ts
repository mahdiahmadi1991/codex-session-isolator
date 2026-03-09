export type WizardPromptId =
  | "workspaceSelection"
  | "remoteWsl"
  | "wslDistroSelection"
  | "codexRunInWsl"
  | "createWindowsShortcut"
  | "windowsShortcutLocationSelection"
  | "windowsShortcutCustomPath"
  | "trackSessionHistory";

export type WizardPromptAnswers = Partial<Record<WizardPromptId, string>>;

export type WizardPromptAction =
  | {
      kind: "answer";
      promptId: WizardPromptId;
      promptText: string;
      answer: string;
    }
  | {
      kind: "unknown";
      promptText: string;
      reason: string;
    };

export type WizardPromptParserState = {
  pendingFragment: string;
  recentLines: string[];
  answeredPromptIds: Set<WizardPromptId>;
  suppressedPromptLine?: string;
};

const YES_NO_PATTERN = /\[\s*[yn]\s*\/\s*[yn]\s*\]\s*:?\s*$/i;
const SELECT_DEFAULT_PATTERN = /^select\s*\[default:\s*\d+\]\s*:?\s*$/i;
const MAX_RECENT_LINES = 24;

export function createWizardPromptParserState(): WizardPromptParserState {
  return {
    pendingFragment: "",
    recentLines: [],
    answeredPromptIds: new Set<WizardPromptId>()
  };
}

export function consumeWizardOutputChunk(
  state: WizardPromptParserState,
  chunk: string,
  answers: WizardPromptAnswers
): WizardPromptAction[] {
  const actions: WizardPromptAction[] = [];
  const normalizedChunk = chunk.replace(/\r/g, "");
  const combined = state.pendingFragment + normalizedChunk;
  const lines = combined.split("\n");
  state.pendingFragment = lines.pop() ?? "";

  for (const line of lines) {
    const action = consumeLine(state, line, answers, false);
    if (action) {
      actions.push(action);
    }
  }

  const pendingAction = consumeLine(state, state.pendingFragment, answers, true);
  if (pendingAction) {
    actions.push(pendingAction);
    state.pendingFragment = "";
  }

  return actions;
}

function consumeLine(
  state: WizardPromptParserState,
  rawLine: string,
  answers: WizardPromptAnswers,
  fromPendingFragment: boolean
): WizardPromptAction | undefined {
  const line = rawLine.replace(/\r/g, "");
  const trimmed = line.trim();
  if (trimmed.length === 0) {
    return undefined;
  }

  const normalized = normalize(trimmed);
  if (state.suppressedPromptLine && normalized === state.suppressedPromptLine) {
    state.suppressedPromptLine = undefined;
    if (!fromPendingFragment) {
      rememberRecentLine(state, trimmed);
    }
    return undefined;
  }

  if (!fromPendingFragment && state.suppressedPromptLine) {
    state.suppressedPromptLine = undefined;
  }

  const promptDetection = detectPrompt(trimmed, state.recentLines);
  if (!fromPendingFragment) {
    rememberRecentLine(state, trimmed);
  }

  if (!promptDetection) {
    return undefined;
  }

  if (promptDetection.kind === "unknown") {
    if (fromPendingFragment) {
      state.suppressedPromptLine = normalized;
    }
    return {
      kind: "unknown",
      promptText: trimmed,
      reason: promptDetection.reason
    };
  }

  const promptId = promptDetection.promptId;
  if (state.answeredPromptIds.has(promptId)) {
    if (fromPendingFragment) {
      state.suppressedPromptLine = normalized;
    }
    return {
      kind: "unknown",
      promptText: trimmed,
      reason: `Prompt '${promptId}' appeared more than once.`
    };
  }

  const answer = answers[promptId];
  if (typeof answer !== "string" || answer.trim().length === 0) {
    if (fromPendingFragment) {
      state.suppressedPromptLine = normalized;
    }
    return {
      kind: "unknown",
      promptText: trimmed,
      reason: `No prepared answer found for prompt '${promptId}'.`
    };
  }

  state.answeredPromptIds.add(promptId);
  if (fromPendingFragment) {
    state.suppressedPromptLine = normalized;
  }

  return {
    kind: "answer",
    promptId,
    promptText: trimmed,
    answer
  };
}

function detectPrompt(
  line: string,
  recentLines: string[]
): { kind: "known"; promptId: WizardPromptId } | { kind: "unknown"; reason: string } | undefined {
  const normalized = normalize(line);

  if (isKnownContextLine(normalized) || normalized.startsWith("[wizard]")) {
    return undefined;
  }

  if (isKnownPrompt(normalized, "launch vs code in remote wsl mode?")) {
    return { kind: "known", promptId: "remoteWsl" };
  }

  if (isKnownPrompt(normalized, "set codex to run in wsl for this project?")) {
    return { kind: "known", promptId: "codexRunInWsl" };
  }

  if (isKnownPrompt(normalized, "create windows shortcut for double-click launch?")) {
    return { kind: "known", promptId: "createWindowsShortcut" };
  }

  if (isKnownTextPrompt(normalized, "enter windows shortcut directory path")) {
    return { kind: "known", promptId: "windowsShortcutCustomPath" };
  }

  if (
    isKnownPrompt(normalized, "track codex session history in git?") ||
    isKnownPrompt(normalized, "ignore codex chat sessions in gitignore?")
  ) {
    return { kind: "known", promptId: "trackSessionHistory" };
  }

  if (SELECT_DEFAULT_PATTERN.test(line)) {
    const selectionPrompt = detectSelectionPromptFromContext(recentLines);
    if (!selectionPrompt) {
      return {
        kind: "unknown",
        reason: "Selection prompt found but context is unknown."
      };
    }
    return { kind: "known", promptId: selectionPrompt };
  }

  if (YES_NO_PATTERN.test(line)) {
    return {
      kind: "unknown",
      reason: "Unknown yes/no prompt."
    };
  }

  if (line.trimEnd().endsWith(":")) {
    return {
      kind: "unknown",
      reason: "Unknown prompt ending with ':'."
    };
  }

  return undefined;
}

function detectSelectionPromptFromContext(recentLines: string[]): WizardPromptId | undefined {
  for (let i = recentLines.length - 1; i >= 0; i -= 1) {
    const normalized = normalize(recentLines[i]);
    if (normalized.includes("select wsl distro:")) {
      return "wslDistroSelection";
    }
    if (normalized.includes("select windows shortcut location:")) {
      return "windowsShortcutLocationSelection";
    }
    if (normalized.includes("multiple workspace files found. select one:")) {
      return "workspaceSelection";
    }
  }

  return undefined;
}

function isKnownPrompt(normalizedLine: string, promptPrefix: string): boolean {
  return normalizedLine.startsWith(promptPrefix) && YES_NO_PATTERN.test(normalizedLine);
}

function isKnownTextPrompt(normalizedLine: string, promptPrefix: string): boolean {
  return normalizedLine.startsWith(promptPrefix) && normalizedLine.endsWith(":");
}

function isKnownContextLine(normalizedLine: string): boolean {
  if (normalizedLine.includes("multiple workspace files found. select one:")) {
    return true;
  }
  if (normalizedLine.includes("select wsl distro:")) {
    return true;
  }
  if (normalizedLine.includes("select windows shortcut location:")) {
    return true;
  }
  if (/^\d+\.\s+/.test(normalizedLine)) {
    return true;
  }
  return false;
}

function rememberRecentLine(state: WizardPromptParserState, line: string): void {
  state.recentLines.push(line);
  if (state.recentLines.length > MAX_RECENT_LINES) {
    state.recentLines = state.recentLines.slice(state.recentLines.length - MAX_RECENT_LINES);
  }
}

function normalize(value: string): string {
  return value.toLowerCase().replace(/\s+/g, " ").trim();
}
