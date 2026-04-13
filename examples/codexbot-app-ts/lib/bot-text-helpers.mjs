export function createBotTextHelpers(deps) {
  function helpText() {
    return [
      deps.mdSection("Project", [
        "- `help` / `/help`",
        "- `/create [project_key]`",
        "- `/bind [project_key] [path]`",
        "- `/unbind [project_key]`",
        "- `/projects`",
        "- `/project` / `/project [project_key]`",
        "- `/project-instance [project_key] [instance]`",
      ]),
      deps.mdSection("Instance", [
        "- `/instances`",
        "- `/instance` / `/instance [name]`",
      ]),
      deps.mdSection("Model", [
        "- `/models` / `/model [model_id]`",
      ]),
      deps.mdSection("Thread", [
        "- `/threads`",
        "- `/thread` / `/thread [thread_id]`",
        "- `/thread rename [title]`",
        "- `/use [project_key|model_id|thread_id|instance]`",
        "- `/use latest`",
        "- `/new [model_id]`",
        "- `/cancel`",
      ]),
      deps.mdSection("Runtime", [
        "- `/settings` / `/setting [name] [value]`",
        "- `/codex models|threads|thread|config|skills|apps`",
      ]),
      deps.mdSection("Notes", [
        "- `/create` only works for a brand-new project key and a brand-new directory.",
        "- `/bind` registers or completes a project path and binds it to this chat without switching the current session.",
        "- `/unbind` only works for non-current projects.",
        "- `/project [project_key]` only switches to a project already bound to this chat.",
        "- `/use` keeps the last selection scope until the next non-`/use` command.",
        "- After `/instances`, `/use [instance]` switches the session instance.",
        "- In thread scope, `/use` also reads the latest assistant reply from the selected thread.",
        "- `/import` has been merged into `/bind`.",
        "- Plain text messages start a Codex task in the current project context.",
        "- In Feishu threads, session state is scoped to the current thread.",
      ]),
    ].join("\n\n");
  }

  function sessionScopeText(sessionKey) {
    return deps.isThreadScopedSession(sessionKey) ? "current Feishu thread" : "whole chat";
  }

  function taskQueuedText(stream) {
    return deps.mdSection("Queued", [
      deps.mdBullet("Project", stream.projectKey, { code: true }),
      deps.mdBullet("Model", stream.model, { code: true }),
      deps.mdBullet("Mode", stream.threadId ? "reuse" : "new", { code: true }),
      deps.mdBullet("Thread", stream.threadId || "new thread", { code: true }),
      deps.mdBullet("Stream", stream.streamId, { code: true }),
    ]);
  }

  function threadBoundText(threadId) {
    return deps.mdSection("Thread Ready", [
      deps.mdInline(threadId),
    ]);
  }

  function taskRunningText(stream) {
    return deps.mdSection("Running", [
      deps.mdBullet("Project", stream.projectKey, { code: true }),
      deps.mdBullet("Model", stream.model, { code: true }),
      deps.mdBullet("Mode", stream.threadId ? "reuse" : "new", { code: true }),
      deps.mdBullet("Thread", stream.threadId || "starting", { code: true }),
    ]);
  }

  function currentProjectText(state) {
    return deps.mdSection("Current Project", [
      deps.mdBullet("Project", state.projectKey, { code: true }),
      deps.mdBullet("CWD", state.cwd, { code: true }),
      deps.mdBullet("Codex Instance", state.codexInstance || deps.botDefaults().defaultCodexInstance || "main", { code: true }),
    ]);
  }

  function projectSelectedText(state) {
    return deps.mdSection("Project Updated", [
      deps.mdBullet("Project", state.projectKey, { code: true }),
      deps.mdBullet("CWD", state.cwd, { code: true }),
      deps.mdBullet("Codex Instance", state.codexInstance || deps.botDefaults().defaultCodexInstance || "main", { code: true }),
    ]);
  }

  function projectCreatedText(project, state) {
    return deps.mdSection("Project Created", [
      deps.mdBullet("Project", project.projectKey, { code: true }),
      deps.mdBullet("Path", project.repoPath, { code: true }),
      deps.mdBullet("Current Project", state.projectKey, { code: true }),
      deps.mdBullet("Model", state.model, { code: true }),
      deps.mdBullet("Codex Instance", state.codexInstance || deps.botDefaults().defaultCodexInstance || "main", { code: true }),
    ]);
  }

  function currentInstanceText(state, project = undefined) {
    return deps.mdSection("Current Instance", [
      deps.mdBullet("Session", state.codexInstance || deps.botDefaults().defaultCodexInstance || "main", { code: true }),
      deps.mdBullet("Project", state.projectKey, { code: true }),
      deps.mdBullet("Project Default", project?.defaultCodexInstance || deps.botDefaults().defaultCodexInstance || "main", { code: true }),
    ]);
  }

  function instanceSelectedText(state, previousInstance, project = undefined) {
    const nextInstance = state.codexInstance || deps.botDefaults().defaultCodexInstance || "main";
    return deps.mdSection("Instance Updated", [
      deps.mdBullet("Previous", previousInstance || "main", { code: true }),
      deps.mdBullet("Session", nextInstance, { code: true }),
      deps.mdBullet("Project", state.projectKey, { code: true }),
      deps.mdBullet("Project Default", project?.defaultCodexInstance || deps.botDefaults().defaultCodexInstance || "main", { code: true }),
      "- Current thread binding cleared.",
    ]);
  }

  function instanceUseSelectedText(state, previousInstance, project = undefined, threadId = "", willReadThread = false) {
    const nextInstance = state.codexInstance || deps.botDefaults().defaultCodexInstance || "main";
    const lines = [
      deps.mdBullet("Previous", previousInstance || "main", { code: true }),
      deps.mdBullet("Session", nextInstance, { code: true }),
      deps.mdBullet("Project", state.projectKey, { code: true }),
      deps.mdBullet("Project Default", project?.defaultCodexInstance || deps.botDefaults().defaultCodexInstance || "main", { code: true }),
    ];
    if (threadId) {
      lines.push(deps.mdBullet("Thread", threadId, { code: true }));
      lines.push(willReadThread
        ? "- Reading the latest assistant reply from the current thread on this instance."
        : "- Current thread binding kept.");
    } else {
      lines.push("- No thread is currently bound.");
    }
    return deps.mdSection("Instance Updated", lines);
  }

  function projectInstanceUpdatedText(project, currentProjectKey = "", currentSessionInstance = "") {
    const lines = [
      deps.mdBullet("Project", project.projectKey, { code: true }),
      deps.mdBullet("Project Default", project.defaultCodexInstance || "main", { code: true }),
    ];
    if (project.projectKey === currentProjectKey) {
      lines.push(deps.mdBullet("Current Session", currentSessionInstance || project.defaultCodexInstance || "main", { code: true }));
      lines.push("- Current thread binding cleared.");
    } else {
      lines.push("- Current session project is unchanged.");
    }
    return deps.mdSection("Project Instance Updated", lines);
  }

  function settingsEmptyText() {
    return deps.mdSection("Settings", [
      "- No settings configured yet.",
      "- Use `/setting project_root_dir [path]` first.",
    ]);
  }

  function settingsListText(settings) {
    const lines = [];
    for (const setting of settings) {
      lines.push(`- ${deps.mdInline(setting.name)} = ${deps.mdInline(setting.value)}`);
    }
    return deps.mdSection("Current Settings", lines);
  }

  function settingUpdatedText(name, value) {
    return deps.mdSection("Setting Updated", [
      `- ${deps.mdInline(name)} = ${deps.mdInline(value)}`,
    ]);
  }

  function projectRootMissingText() {
    return deps.mdSection("Project Root Missing", [
      "- Use `/setting project_root_dir [path]` first.",
    ]);
  }

  function usageText(command, syntax) {
    return deps.mdSection("Usage", [
      `- ${deps.mdInline(command)} ${syntax}`.trim(),
    ]);
  }

  function useCommandSyntax(scope) {
    switch (scope) {
      case "project":
        return "[project_key]";
      case "model":
        return "[model_id]";
      case "instance":
        return "[instance]";
      case "thread":
        return "latest | [thread_id]";
      default:
        return "[project_key|model_id|thread_id|instance] | latest";
    }
  }

  function importPathInvalidText(repoPath) {
    return deps.mdSection("Import Path Invalid", [
      deps.mdBullet("Path", repoPath, { code: true }),
      "- The path must point to an existing directory.",
    ]);
  }

  function codexCommandHelpText(state) {
    return [
      deps.mdSection("Codex RPC Query", [
        "- `/codex models`",
        "- `/codex threads`",
        "- `/codex thread`",
        "- `/codex config`",
        "- `/codex skills`",
        "- `/codex apps`",
        "- `/codex thread/read {\"threadId\":\"...\",\"includeTurns\":true}`",
      ]),
      deps.mdSection("Current Context", [
        deps.mdBullet("CWD", state.cwd, { code: true }),
        deps.mdBullet("Thread", state.threadId || "not bound", { code: true }),
      ]),
    ].join("\n\n");
  }

  function codexRpcQueuedText(method) {
    return deps.mdSection("Codex RPC Query", [
      deps.mdBullet("Method", method, { code: true }),
      "- Query sent to Codex.",
    ]);
  }

  function threadReadQueuedText() {
    return "Reading the latest assistant reply from this thread.";
  }

  function threadRenameQueuedText(threadId, title) {
    return deps.mdSection("Thread Rename", [
      deps.mdBullet("Thread", threadId || "unknown", { code: true }),
      deps.mdBullet("New Title", title),
      "- Rename request sent to Codex.",
    ]);
  }

  function threadRenamedText(threadId, previousTitle, nextTitle) {
    const lines = [deps.mdBullet("Thread", threadId || "unknown", { code: true })];
    if (previousTitle) {
      lines.push(deps.mdBullet("Previous", previousTitle));
    }
    lines.push(deps.mdBullet("Current", nextTitle || previousTitle || "renamed"));
    return deps.mdSection("Thread Renamed", lines);
  }

  function codexRpcErrorText(method, message) {
    return deps.mdSection("Codex RPC Error", [
      deps.mdBullet("Method", method, { code: true }),
      message || "",
    ]);
  }

  function unsupportedCodexMethodText(method) {
    return deps.mdSection("Unsupported Codex Method", [
      deps.mdBullet("Method", method, { code: true }),
      "- Only query-style RPC methods are allowed.",
    ]);
  }

  function codexThreadRequiredText() {
    return deps.mdSection("Thread Required", [
      "- Use `/thread` first, or send `/codex thread/read {\"threadId\":\"...\",\"includeTurns\":true}`.",
    ]);
  }

  function threadReadEmptyText(threadId) {
    return deps.mdSection("Thread Read", [
      deps.mdBullet("Thread", threadId || "unknown", { code: true }),
      "- No assistant reply was found in this thread yet.",
    ]);
  }

  function codexErrorText(method) {
    return deps.mdSection("Codex Error", [
      deps.mdBullet("Method", method, { code: true }),
    ]);
  }

  function threadExpiredRestartingText(threadId) {
    return deps.mdSection("Thread Restarting", [
      deps.mdBullet("Previous Thread", threadId || "unknown", { code: true }),
      "- The saved Codex thread is no longer available. Starting a new thread automatically.",
    ]);
  }

  function projectRegisteredText(project, state) {
    return deps.mdSection("Project Registered", [
      deps.mdBullet("Project", project.projectKey, { code: true }),
      deps.mdBullet("Path", project.repoPath, { code: true }),
      deps.mdBullet("Current Project", state.projectKey, { code: true }),
      deps.mdBullet("Model", state.model, { code: true }),
    ]);
  }

  function projectBoundText(projectKey, repoPath = "") {
    const lines = [
      deps.mdBullet("Project", projectKey, { code: true }),
      "- Current session project is unchanged.",
    ];
    if (repoPath) {
      lines.splice(1, 0, deps.mdBullet("Path", repoPath, { code: true }));
    }
    return deps.mdSection("Project Bound", lines);
  }

  function projectPathFilledText(project, state) {
    return deps.mdSection("Project Path Updated", [
      deps.mdBullet("Project", project.projectKey, { code: true }),
      deps.mdBullet("Path", project.repoPath, { code: true }),
      deps.mdBullet("Current Project", state.projectKey, { code: true }),
      deps.mdBullet("Model", state.model, { code: true }),
    ]);
  }

  function projectExistsText(projectKey, repoPath) {
    return deps.mdSection("Project Exists", [
      deps.mdBullet("Project", projectKey, { code: true }),
      deps.mdBullet("Path", repoPath, { code: true }),
    ]);
  }

  function projectDirectoryExistsText(projectKey, repoPath) {
    return deps.mdSection("Project Directory Exists", [
      deps.mdBullet("Project", projectKey, { code: true }),
      deps.mdBullet("Path", repoPath, { code: true }),
      "- `/create` only works when the target directory does not exist yet.",
    ]);
  }

  function projectMissingText(projectKey) {
    return deps.mdSection("Unknown Project", [
      deps.mdInline(projectKey),
    ]);
  }

  function projectPathAlreadyBoundText(projectKey, repoPath) {
    return deps.mdSection("Project Path Already Bound", [
      deps.mdBullet("Project", projectKey, { code: true }),
      deps.mdBullet("Existing Path", repoPath, { code: true }),
      "- Use `/project [project_key]` to switch, or choose a new project key.",
    ]);
  }

  function bindMergedText() {
    return deps.mdSection("Command Updated", [
      "- `/import` has been merged into `/bind`.",
      "- Use `/bind [project_key] [path]`.",
    ]);
  }

  function projectUnboundText(projectKey) {
    return deps.mdSection("Project Unbound", [
      deps.mdBullet("Project", projectKey, { code: true }),
      "- Chat binding removed.",
    ]);
  }

  function projectNotBoundText(projectKey) {
    return deps.mdSection("Project Not Bound", [
      deps.mdBullet("Project", projectKey, { code: true }),
      "- No explicit chat binding exists for this project.",
      "- Use `/bind [project_key] [path]` first.",
    ]);
  }

  function codexInstanceUnknownText(instance, knownInstances) {
    const lines = [deps.mdBullet("Instance", instance, { code: true })];
    if (knownInstances.length) {
      lines.push(deps.mdBullet("Known", knownInstances.join(", "), { code: true }));
    }
    lines.push("- Use `/instances` to inspect configured Codex instances.");
    return deps.mdSection("Unknown Codex Instance", lines);
  }

  function codexInstancesEmptyText() {
    return deps.mdSection("Codex Instances", [
      "- No Codex instances are configured.",
    ]);
  }

  function formatCodexInstanceEntry(entry, index, currentInstance, projectDefaultInstance) {
    const badges = [];
    if (entry.name === currentInstance) {
      badges.push("session");
    }
    if (entry.name === projectDefaultInstance) {
      badges.push("project");
    }
    const suffix = badges.length ? ` ${badges.join(",")}` : "";
    const lines = [
      `**${index}. ${deps.mdInline(entry.name)}${suffix}**`,
      deps.mdBullet("URL", entry.url, { code: true }),
      deps.mdBullet("CWD", entry.cwd, { code: true }),
      deps.mdBullet("Startup", entry.startup, { code: true }),
    ];
    if (entry.desiredState) {
      lines.push(deps.mdBullet("Desired", entry.desiredState, { code: true }));
    }
    if (entry.source) {
      lines.push(deps.mdBullet("Source", entry.source, { code: true }));
    }
    return lines.join("\n");
  }

  function codexInstancesListText(state, project, entries) {
    const lines = [
      deps.mdBullet("Session", state.codexInstance || deps.botDefaults().defaultCodexInstance || "main", { code: true }),
      deps.mdBullet("Project", state.projectKey, { code: true }),
      deps.mdBullet("Project Default", project?.defaultCodexInstance || deps.botDefaults().defaultCodexInstance || "main", { code: true }),
    ];
    if (!entries.length) {
      lines.push("- No Codex instances are configured.");
      return deps.mdSection("Codex Instances", lines);
    }
    lines.push("");
    for (let i = 0; i < entries.length; i += 1) {
      lines.push(formatCodexInstanceEntry(
        entries[i],
        i + 1,
        state.codexInstance || deps.botDefaults().defaultCodexInstance || "main",
        project?.defaultCodexInstance || deps.botDefaults().defaultCodexInstance || "main",
      ));
      if (i < entries.length - 1) {
        lines.push("");
      }
    }
    return deps.mdSection("Codex Instances", lines);
  }

  function projectUnbindCurrentBlockedText(projectKey) {
    return deps.mdSection("Cannot Unbind Current Project", [
      deps.mdBullet("Project", projectKey, { code: true }),
      "- Switch to another project first, then run `/unbind` again.",
    ]);
  }

  function currentModelText(state) {
    return deps.mdSection("Current Model", [
      deps.mdInline(state.model),
    ]);
  }

  function modelSelectedText(state) {
    return deps.mdSection("Model Updated", [
      deps.mdInline(state.model),
    ]);
  }

  function currentThreadText(state) {
    return state.threadId ? `Current thread: ${deps.mdInline(state.threadId)}` : "No thread is currently bound.";
  }

  function summarizeInteractionText(text, maxLength = 140) {
    const raw = typeof text === "string" ? text.replace(/\s+/g, " ").trim() : "";
    if (!raw) {
      return "";
    }
    if (raw.length <= maxLength) {
      return raw;
    }
    return `${raw.slice(0, maxLength - 3)}...`;
  }

  function formatThreadInteractionEntry(stream, index) {
    const lines = [`**${index}. ${deps.mdInline(stream.streamId)}**`, deps.mdBullet("Status", stream.status || "queued", { code: true })];
    if (stream.prompt) {
      lines.push(deps.mdBullet("Prompt", summarizeInteractionText(stream.prompt)));
    }
    const answer = stream.resultText || stream.draft || "";
    if (answer) {
      lines.push(deps.mdBullet("Reply", summarizeInteractionText(answer)));
    }
    return lines.join("\n");
  }

  function appendThreadInteractionSummary(lines, streams = []) {
    if (!Array.isArray(streams) || streams.length === 0) {
      return lines;
    }
    lines.push("");
    lines.push("Recent Interactions:");
    for (let i = 0; i < streams.length; i += 1) {
      lines.push(formatThreadInteractionEntry(streams[i], i + 1));
      if (i < streams.length - 1) {
        lines.push("");
      }
    }
    return lines;
  }

  function streamMatchesThreadContext(stream, state) {
    if (!stream || !state) {
      return false;
    }
    if (stream.sessionKey !== state.sessionKey) {
      return false;
    }
    return stream.projectKey === state.projectKey;
  }

  function currentThreadSummaryText(state, stream, interactions = []) {
    const lines = [
      deps.mdBullet("Session Scope", sessionScopeText(state.sessionKey)),
      currentThreadText(state),
      deps.mdBullet("Next Prompt", state.threadId ? "reuse current thread" : "start new thread"),
    ];
    const threadName = deps.lookupThreadName(state.threadId || "");
    if (threadName) {
      lines.push(deps.mdBullet("Name", threadName));
    }
    if (stream) {
      lines.push(deps.mdBullet("Last Stream", stream.streamId, { code: true }));
      lines.push(deps.mdBullet("Last Status", stream.status || "queued", { code: true }));
      if (stream.prompt) {
        lines.push(deps.mdBullet("Last Prompt", stream.prompt));
      }
    }
    appendThreadInteractionSummary(lines, interactions);
    return deps.mdSection("Current Thread", lines);
  }

  function formatThreadEntry(stream, index, currentThreadId = "") {
    const lines = [
      `**${index}. ${deps.mdInline(stream.threadId)}${stream.threadId === currentThreadId ? " current" : ""}**`,
      deps.mdBullet("Status", stream.status || "queued", { code: true }),
    ];
    const threadName = deps.lookupThreadName(stream.threadId || "");
    if (threadName) {
      lines.push(deps.mdBullet("Name", threadName));
    }
    if (stream.prompt) {
      lines.push(deps.mdBullet("Prompt", stream.prompt));
    }
    return lines.join("\n");
  }

  function formatProjectEntry(project, currentProjectKey, index) {
    const badge = project.projectKey === currentProjectKey ? " current" : "";
    const lines = [
      `**${index}. ${deps.mdInline(project.projectKey)}${badge}**`,
      deps.mdBullet("Model", project.model, { code: true }),
      deps.mdBullet("Path", project.cwd, { code: true }),
      deps.mdBullet("Codex", project.codexInstance || deps.botDefaults().defaultCodexInstance || "main", { code: true }),
    ];
    lines.push(deps.mdBullet("Thread", project.threadId || "not bound", { code: true }));
    return lines.join("\n");
  }

  function projectsListText(state, projects) {
    const lines = [deps.mdBullet("Chat", state.chatId, { code: true })];
    if (!projects.length) {
      lines.push("- No bound projects yet.");
      lines.push("- Use `/bind [project_key] [path]` first.");
      return deps.mdSection("Projects", lines);
    }
    lines.push("");
    for (let i = 0; i < projects.length; i += 1) {
      lines.push(formatProjectEntry(projects[i], state.projectKey, i + 1));
      if (i < projects.length - 1) {
        lines.push("");
      }
    }
    lines.push("");
    lines.push("- Use `/project [project_key]` or `/use [project_key]` to switch.");
    return deps.mdSection("Projects", lines);
  }

  function modelsListText(state, models) {
    const lines = [deps.mdBullet("Current", state.model, { code: true })];
    if (!models.length) {
      lines.push("- No models configured.");
      return deps.mdSection("Configured Models", lines);
    }
    lines.push("");
    for (let i = 0; i < models.length; i += 1) {
      const model = models[i];
      lines.push(`**${i + 1}. ${deps.mdInline(model)}${model === state.model ? " current" : ""}**`);
    }
    lines.push("");
    lines.push("- Use `/model [model_id]` or `/use [model_id]` to switch.");
    return deps.mdSection("Configured Models", lines);
  }

  function threadsListText(state, streams) {
    const lines = [
      deps.mdBullet("Project", state.projectKey, { code: true }),
      deps.mdBullet("Current", state.threadId || "not bound", { code: true }),
      deps.mdBullet("Next Prompt", state.threadId ? "reuse current thread" : "start new thread"),
    ];
    if (!streams.length) {
      lines.push("- No known threads yet.");
      lines.push("- Send a prompt first, or use `/new` to start a fresh thread next.");
      return deps.mdSection("Recent Threads", lines);
    }
    lines.push("");
    for (let i = 0; i < streams.length; i += 1) {
      lines.push(formatThreadEntry(streams[i], i + 1, state.threadId || ""));
      if (i < streams.length - 1) {
        lines.push("");
      }
    }
    return deps.mdSection("Recent Threads", lines);
  }

  function threadSelectedText(state, threadId, sourceStream, interactions = []) {
    const lines = [deps.mdBullet("Thread", threadId, { code: true }), deps.mdBullet("Session Scope", sessionScopeText(state.sessionKey))];
    const threadName = deps.lookupThreadName(threadId);
    if (threadName) {
      lines.push(deps.mdBullet("Name", threadName));
    }
    if (sourceStream?.prompt) {
      lines.push(deps.mdBullet("Latest Prompt", sourceStream.prompt));
    }
    if (sourceStream?.status) {
      lines.push(deps.mdBullet("Latest Status", sourceStream.status, { code: true }));
    }
    lines.push(deps.mdBullet("Next Prompt", "reuse current thread"));
    lines.push("- Next prompt will continue on this thread.");
    appendThreadInteractionSummary(lines, interactions);
    return deps.mdSection("Thread Selected", lines);
  }

  function latestThreadMissingText(state) {
    return deps.mdSection("Recent Threads", [
      `- No recent threads found for project ${deps.mdInline(state.projectKey)}.`,
    ]);
  }

  function newConversationText(state, previousThreadId, previousModel) {
    const lines = ["- Thread binding cleared.", deps.mdBullet("Session Scope", sessionScopeText(state.sessionKey))];
    if (previousThreadId) {
      lines.push(deps.mdBullet("Previous Thread", previousThreadId, { code: true }));
    }
    if (previousModel && previousModel !== state.model) {
      lines.push(`- Model switched: ${deps.mdInline(previousModel)} -> ${deps.mdInline(state.model)}`);
    }
    lines.push(deps.mdBullet("Next Prompt", "start new thread"));
    lines.push("- Next prompt will start a new thread.");
    return deps.mdSection("New Conversation", lines);
  }

  function busyText(stream) {
    const lines = [
      deps.isThreadScopedSession(stream.sessionKey)
        ? "Still working on the previous request in this thread."
        : "Still working on the previous request.",
      deps.mdBullet("Last Stream", stream.streamId, { code: true }),
      deps.mdBullet("Status", stream.status || "queued", { code: true }),
    ];
    if (stream.prompt) {
      lines.push(deps.mdBullet("Prompt", stream.prompt));
    }
    lines.push("- Use `/cancel` to detach this run, or wait for Codex to finish.");
    return deps.mdSection("Busy", lines);
  }

  function staleDetachedText(stream) {
    const lines = [
      deps.isThreadScopedSession(stream.sessionKey)
        ? "Detached a stale run from this thread session."
        : "Detached a stale run from this chat session.",
      deps.mdBullet("Stream", stream.streamId, { code: true }),
      deps.mdBullet("Previous Status", stream.status || "queued", { code: true }),
    ];
    if (stream.threadId) {
      lines.push(deps.mdBullet("Thread", stream.threadId, { code: true }));
    }
    if (stream.prompt) {
      lines.push(deps.mdBullet("Prompt", stream.prompt));
    }
    lines.push("- The previous run stopped sending updates, so it no longer blocks new prompts.");
    return deps.mdSection("Stale Run Detached", lines);
  }

  function cancelIdleText(sessionKey) {
    return deps.isThreadScopedSession(sessionKey)
      ? deps.mdSection("Cancel", ["- No active Codex run to cancel in this thread."])
      : deps.mdSection("Cancel", ["- No active Codex run to cancel."]);
  }

  function cancelDetachedText(stream) {
    const lines = [
      deps.isThreadScopedSession(stream.sessionKey)
        ? "Detached the active run from this thread session."
        : "Detached the active run from this chat session.",
      deps.mdBullet("Stream", stream.streamId, { code: true }),
      deps.mdBullet("Status", stream.status || "queued", { code: true }),
    ];
    if (stream.threadId) {
      lines.push(deps.mdBullet("Thread", stream.threadId, { code: true }));
    }
    lines.push("- A best-effort Codex session clear was sent.");
    return deps.mdSection("Cancelled", lines);
  }

  function cancelInterruptingText(stream) {
    const lines = [
      deps.mdBullet("Stream", stream.streamId, { code: true }),
      deps.mdBullet("Thread", stream.threadId || "unknown", { code: true }),
      deps.mdBullet("Turn", stream.turnId || "unknown", { code: true }),
      "- Interrupt request sent to Codex.",
      "- The session will detach immediately so the next prompt is not blocked.",
    ];
    return deps.mdSection("Cancelling", lines);
  }

  function codexStatusText(status, detail) {
    const label = typeof status === "string" && status.trim() !== "" ? status.trim() : "running";
    return detail && detail.trim() !== ""
      ? deps.mdSection("Codex Status", [deps.mdBullet("Status", label, { code: true }), detail])
      : deps.mdSection("Codex Status", [deps.mdBullet("Status", label, { code: true })]);
  }

  function codexActiveStatusText(flags = []) {
    const lines = [deps.mdBullet("Status", "active", { code: true })];
    const normalizedFlags = Array.isArray(flags)
      ? flags.filter((flag) => typeof flag === "string" && flag.trim() !== "")
      : [];
    if (normalizedFlags.length) {
      lines.push(deps.mdBullet("Flags", normalizedFlags.join(", "), { code: true }));
    }
    return deps.mdSection("Codex Thread", lines);
  }

  function codexSystemErrorText(notification) {
    const lines = [
      deps.mdBullet("Status", "systemError", { code: true }),
      "- Codex reported a thread-level system error, but did not include structured error details in this status event.",
    ];
    if (notification?.threadId) {
      lines.push(deps.mdBullet("Thread", notification.threadId, { code: true }));
    }
    return deps.mdSection("Codex Error", lines);
  }

  function codexStructuredErrorText(notification) {
    const lines = [];
    const primaryMessage = typeof notification?.turnError?.message === "string" && notification.turnError.message.trim() !== ""
      ? notification.turnError.message.trim()
      : typeof notification?.errorMessage === "string"
        ? notification.errorMessage.trim()
        : "";
    if (primaryMessage) {
      lines.push(primaryMessage);
    }
    const code = deps.formatCodexErrorCodeLabel(notification?.turnError?.codexErrorCode || "");
    if (code) {
      lines.push(deps.mdBullet("Code", code, { code: true }));
    }
    const httpStatus = Number(notification?.turnError?.codexErrorHttpStatus);
    if (Number.isFinite(httpStatus) && httpStatus > 0) {
      lines.push(deps.mdBullet("HTTP Status", String(httpStatus), { code: true }));
    }
    const additionalDetails = typeof notification?.turnError?.additionalDetails === "string"
      ? notification.turnError.additionalDetails.trim()
      : "";
    if (additionalDetails) {
      lines.push(additionalDetails);
    }
    if (notification?.threadId) {
      lines.push(deps.mdBullet("Thread", notification.threadId, { code: true }));
    }
    if (notification?.turnId) {
      lines.push(deps.mdBullet("Turn", notification.turnId, { code: true }));
    }
    if (!lines.length) {
      lines.push("- Codex returned an unspecified error.");
    }
    return deps.mdSection("Codex Error", lines);
  }

  return {
    bindMergedText,
    busyText,
    cancelDetachedText,
    cancelIdleText,
    cancelInterruptingText,
    codexActiveStatusText,
    codexCommandHelpText,
    codexErrorText,
    codexInstanceUnknownText,
    codexInstancesEmptyText,
    codexInstancesListText,
    codexRpcErrorText,
    codexRpcQueuedText,
    codexStatusText,
    codexStructuredErrorText,
    codexSystemErrorText,
    codexThreadRequiredText,
    currentInstanceText,
    currentModelText,
    currentProjectText,
    currentThreadSummaryText,
    helpText,
    importPathInvalidText,
    instanceSelectedText,
    instanceUseSelectedText,
    latestThreadMissingText,
    modelSelectedText,
    modelsListText,
    newConversationText,
    projectBoundText,
    projectCreatedText,
    projectDirectoryExistsText,
    projectExistsText,
    projectInstanceUpdatedText,
    projectMissingText,
    projectNotBoundText,
    projectPathAlreadyBoundText,
    projectPathFilledText,
    projectRegisteredText,
    projectRootMissingText,
    projectSelectedText,
    projectUnbindCurrentBlockedText,
    projectUnboundText,
    projectsListText,
    settingUpdatedText,
    settingsEmptyText,
    settingsListText,
    staleDetachedText,
    streamMatchesThreadContext,
    taskQueuedText,
    taskRunningText,
    threadBoundText,
    threadExpiredRestartingText,
    threadReadEmptyText,
    threadReadQueuedText,
    threadRenameQueuedText,
    threadRenamedText,
    threadSelectedText,
    threadsListText,
    unsupportedCodexMethodText,
    usageText,
    useCommandSyntax,
  };
}
