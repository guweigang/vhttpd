import { feishuText, feishuUpdateText, feishuStreamAppendText, feishuStreamFinish, codexRpcCall, codexTurnStart, codexTurnInterrupt, codexSessionClear, feishuSessionClear, providerInstanceUpsert, providerInstanceEnsure } from "./commands.mts";
import { isUseCommandText } from "./command-text-rules.mjs";
import { createFeishuInboundDeduper } from "../feishu/dedupe.mts";
import { createFeishuCommandRouter } from "./command-router.mjs";
import { createCodexNotificationRouter } from "./notification-router.mjs";
import { createCodexQueryCommandHandler } from "./codex-query-command.mjs";
import { createCodexRpcHelpers } from "./codex-rpc-helpers.mjs";
import { createCodexStatusHelpers } from "./codex-status-helpers.mjs";
import { buildThreadStartParams, buildTurnStartParams } from "./codex-start-params.mjs";
import { createBotTextHelpers } from "./bot-text-helpers.mjs";
import { createFeishuSessionHelpers } from "./feishu-session-helpers.mjs";
import { normalizeMainInstanceAlias } from "./instance-alias.mjs";
import { buildCodexPreflightCommands, ensureStreamCodexInstance, resolveCodexInstance } from "./codex-instance-policy.mjs";
import { createItemRenderCoordinator } from "./item-render-coordinator.mjs";
import { createProjectAdminCommandHandlers } from "./project-admin-commands.mjs";
import { createProjectPathHelpers } from "./project-paths.mjs";
import { createProviderRuntimeHelpers } from "./provider-runtime.mjs";
import { createCodexRpcResponseRouter } from "./rpc-router.mjs";
import { createParentStreamOutput, isPlainPromptStream } from "./parent-stream-output.mjs";
import { createSelectionCommandHandlers } from "./selection-commands.mjs";
import { createSessionCommandHandlers } from "./session-commands.mjs";
import { createThreadTaskCommandHandlers } from "./thread-task-commands.mjs";
import { renderCodexAssistantText } from "./assistant-text-renderer.mjs";
import { createThreadSessionCoordinator } from "./thread-session-coordinator.mjs";
import {
  formatCodexErrorCodeLabel,
  isCodexThreadIdleStatus,
  normalizeCodexRuntimeStatus,
} from "../codex/protocol.mts";
import { isBusyStream, isStaleBusyStream, positiveIntegerEnv } from "./busy-guard.mts";
import {
  isItemLifecycleNotification,
  isThreadScopedSession,
  notificationItemKey,
  shouldRenderAssistantContentInItemStream,
  threadRootIdFromSessionKey,
} from "../feishu/card-policy.mts";
import { mdBullet, mdInline, mdSection, mdText } from "./ui-text.mts";
import { botDefaults } from "../config/config.mts";
import providerConfig from "../config/provider-config.mts";
import {
  appendStreamDraft,
  bindProjectToChat,
  clearSelectionScope,
  bindThreadToStream,
  createStreamState,
  createDerivedStreamState,
  ensureChatState,
  ensureProjectRecord,
  finalizeStreamState,
  getProjectRecord,
  getItemRenderState,
  getSettingValue,
  getSelectionScope,
  getLatestProjectThread,
  getStreamState,
  listRecentThreadStreams,
  listInstanceSpecs,
  listBoundChatProjects,
  listChatProjects,
  listRecentProjectThreads,
  listSettings,
  rememberInboundEvent,
  rememberSelectionScope,
  resetChatThread,
  runtimeSnapshot,
  unbindProjectFromChat,
  upsertItemRenderState,
  upsertInstanceSpec,
  upsertSetting,
  updateProjectDefaultCodexInstance,
  updateProjectRecordPath,
  updateStreamState,
  updateChatState,
} from "./state.mjs";

const CODEXBOT_TS_BUILD = "codexbot-ts-2026-04-01-idle-session-fix";
const ENABLE_ITEM_RENDER_STREAMS = true;
const FEISHU_INBOUND_DEDUPE_WINDOW_MS = 2 * 60 * 1000;
const FEISHU_INBOUND_DEDUPE_LIMIT = 1024;
const ACTIVE_STREAM_STALE_MS = positiveIntegerEnv("CODEXBOT_TS_ACTIVE_STREAM_STALE_MS", 3 * 60 * 1000);
const feishuInboundDeduper = createFeishuInboundDeduper({
  dedupeWindowMs: FEISHU_INBOUND_DEDUPE_WINDOW_MS,
  dedupeLimit: FEISHU_INBOUND_DEDUPE_LIMIT,
  rememberInboundEvent,
});

const codexRpcHelpers = createCodexRpcHelpers({
  mdBullet,
  mdInline,
  mdSection,
});

const {
  codeQueryMethods: CODEX_QUERY_METHODS,
  codexRpcDebugText,
  codexRpcIndicatesMissingThread,
  defaultCodexParams,
  extractAnswerFromThreadReadResult,
  extractExactAnswerFromThreadReadResult,
  extractAssistantItemsFromReadResult,
  extractThreadNameFromResult,
  formatCodexRpcResult,
  normalizeCodexAlias,
  parseCodexCommand,
  prettyJson,
  readFinalAnswerFromSessionPath,
  truncateText,
} = codexRpcHelpers;

async function detachStaleActiveStream(session, stream) {
  if (!stream || !isStaleBusyStream(stream, ACTIVE_STREAM_STALE_MS)) {
    return stream;
  }
  const resultText = stream.resultText || stream.draft || botTextHelpers.staleDetachedText(stream);
  await finalizeStreamState(stream.streamId, {
    status: "cancelled",
    resultText,
    completedAt: Date.now(),
    lastEvent: "stale.auto_detach",
  });
  await resetChatThread(session.sessionKey, session.chatId);
  return (await getStreamState(stream.streamId)) || {
    ...stream,
    status: "cancelled",
    resultText,
    completedAt: Date.now(),
    lastEvent: "stale.auto_detach",
  };
}

const projectPathHelpers = createProjectPathHelpers({
  botDefaults,
});

const {
  normalizeImportPath,
  pathExistsAsDirectory,
  resolveProjectCwd,
} = projectPathHelpers;

const codexStatusHelpers = createCodexStatusHelpers({
  mdSection,
});

const {
  codexFinalizingText,
  isTerminalIdleStatus,
  isTerminalStreamStatus,
} = codexStatusHelpers;

const providerRuntimeHelpers = createProviderRuntimeHelpers({
  botDefaults,
  buildTag: CODEXBOT_TS_BUILD,
  normalizeMainInstanceAlias,
  providerConfig,
  providerInstanceEnsure,
  providerInstanceUpsert,
  upsertInstanceSpec,
});

const {
  buildAppStartupCommands,
  buildCodexInstanceSpec,
  buildProviderInstanceCommands,
  configuredCodexInstance,
  configuredCodexInstanceNames,
  fallbackCodexInstance,
  runLaneStartup,
} = providerRuntimeHelpers;

const threadSessionCoordinatorDeps = {
  bindThreadToStream,
  botDefaults,
  buildTurnStartParams,
  codexTurnStart,
  ensureChatState,
  fallbackCodexInstance,
  feishuUpdateText,
  finalizeStreamState,
  getStreamState,
  threadBoundText: (threadId) => threadId,
};

const threadSessionCoordinator = createThreadSessionCoordinator(threadSessionCoordinatorDeps);

const {
  consumePendingThreadRename,
  continueQueuedTurnStart,
  deleteThreadName,
  lookupThreadName,
  rememberPendingThreadRename,
  rememberThreadName,
} = threadSessionCoordinator;

const botTextHelpers = createBotTextHelpers({
  botDefaults,
  formatCodexErrorCodeLabel,
  isThreadScopedSession,
  lookupThreadName,
  mdBullet,
  mdInline,
  mdSection,
});

threadSessionCoordinatorDeps.threadBoundText = botTextHelpers.threadBoundText;

const feishuSessionHelpers = createFeishuSessionHelpers({
  feishuText,
  helpText: botTextHelpers.helpText,
});

const {
  feishuReplyText,
  handleHelp,
} = feishuSessionHelpers;

const itemRenderCoordinator = createItemRenderCoordinator({
  appendStreamDraft,
  createDerivedStreamState,
  enableItemRenderStreams: ENABLE_ITEM_RENDER_STREAMS,
  feishuStreamAppendText,
  feishuStreamFinish,
  feishuText,
  finalizeStreamState,
  getItemRenderState,
  getStreamState,
  isPlainPromptStream,
  isItemLifecycleNotification,
  notificationItemKey,
  shouldRenderAssistantContentInItemStream,
  threadRootIdFromSessionKey,
  upsertItemRenderState,
});

const {
  isCompletedItemNotification,
  renderAssistantContentToItemStream,
} = itemRenderCoordinator;

const parentStreamOutput = createParentStreamOutput({
  feishuText,
  threadRootIdFromSessionKey,
});

const {
  openParentStreamCard,
  sendStreamText,
} = parentStreamOutput;

const codexInstancePolicyDeps = {
  botDefaults,
  buildCodexInstanceSpec,
  buildProviderInstanceCommands,
  configuredCodexInstance,
  fallbackCodexInstance,
  getProjectRecord,
  updateStreamState,
};

const handleCodexNotification = createCodexNotificationRouter({
  appendStreamDraft,
  bindThreadToStream,
  botDefaults,
  buildCodexInstanceSpec,
  buildTag: CODEXBOT_TS_BUILD,
  codexActiveStatusText: botTextHelpers.codexActiveStatusText,
  codexFinalizingText,
  codexRpcCall,
  codexStatusText: botTextHelpers.codexStatusText,
  codexStructuredErrorText: botTextHelpers.codexStructuredErrorText,
  codexSystemErrorText: botTextHelpers.codexSystemErrorText,
  continueQueuedTurnStart,
  fallbackCodexInstance,
  feishuStreamAppendText,
  feishuStreamFinish,
  feishuUpdateText,
  finalizeStreamState,
  getStreamState,
  isPlainPromptStream,
  isCompletedItemNotification,
  isTerminalIdleStatus,
  isTerminalStreamStatus,
  openParentStreamCard,
  readFinalAnswerFromSessionPath,
  renderAssistantContentToItemStream,
  renderCodexAssistantText,
  sendStreamText,
  updateStreamState,
});

const handleCodexRpcResponse = createCodexRpcResponseRouter({
  botDefaults,
  buildTag: CODEXBOT_TS_BUILD,
  buildThreadStartParams,
  codexRpcCall,
  codexRpcDebugText,
  codexRpcErrorText: botTextHelpers.codexRpcErrorText,
  codexRpcIndicatesMissingThread,
  consumePendingThreadRename,
  continueQueuedTurnStart,
  deleteThreadName,
  extractAnswerFromThreadReadResult,
  extractExactAnswerFromThreadReadResult,
  extractAssistantItemsFromReadResult,
  extractThreadNameFromResult,
  fallbackCodexInstance,
  feishuUpdateText,
  feishuStreamAppendText,
  feishuStreamFinish,
  finalizeStreamState,
  formatCodexRpcResult,
  getStreamState,
  isPlainPromptStream,
  openParentStreamCard,
  prettyJson,
  renderAssistantContentToItemStream,
  rememberThreadName,
  renderCodexAssistantText,
  resetChatThread,
  sendStreamText,
  taskRunningText: botTextHelpers.taskRunningText,
  threadExpiredRestartingText: botTextHelpers.threadExpiredRestartingText,
  threadReadEmptyText: botTextHelpers.threadReadEmptyText,
  threadRenamedText: botTextHelpers.threadRenamedText,
  truncateText,
  updateStreamState,
});

const threadTaskCommandHandlers = createThreadTaskCommandHandlers({
  activeStreamStaleMs: ACTIVE_STREAM_STALE_MS,
  botDefaults,
  buildCodexPreflightCommands,
  buildThreadStartParams,
  buildTurnStartParams,
  busyText: botTextHelpers.busyText,
  cancelDetachedText: botTextHelpers.cancelDetachedText,
  cancelIdleText: botTextHelpers.cancelIdleText,
  cancelInterruptingText: botTextHelpers.cancelInterruptingText,
  codexInstancePolicyDeps,
  codexRpcCall,
  codexTurnStart,
  codexSessionClear,
  codexThreadRequiredText: botTextHelpers.codexThreadRequiredText,
  codexTurnInterrupt,
  configuredCodexInstanceNames,
  createStreamState,
  currentThreadSummaryText: botTextHelpers.currentThreadSummaryText,
  detachStaleActiveStream,
  ensureChatState,
  ensureStreamCodexInstance,
  fallbackCodexInstance,
  feishuSessionClear,
  feishuUpdateText,
  finalizeStreamState,
  getLatestProjectThread,
  getProjectRecord,
  getSelectionScope,
  getStreamState,
  instanceUseSelectedText: botTextHelpers.instanceUseSelectedText,
  isBusyStream,
  isStaleBusyStream,
  latestThreadMissingText: botTextHelpers.latestThreadMissingText,
  listBoundChatProjects,
  listInstanceSpecs,
  listRecentProjectThreads,
  listRecentThreadStreams,
  lookupThreadName,
  modelSelectedText: botTextHelpers.modelSelectedText,
  projectNotBoundText: botTextHelpers.projectNotBoundText,
  projectSelectedText: botTextHelpers.projectSelectedText,
  rememberPendingThreadRename,
  rememberThreadName,
  replyText: feishuReplyText,
  resetChatThread,
  resolveCodexInstance,
  resolveProjectCwd,
  streamMatchesThreadContext: botTextHelpers.streamMatchesThreadContext,
  taskQueuedText: botTextHelpers.taskQueuedText,
  threadReadQueuedText: botTextHelpers.threadReadQueuedText,
  threadRenameQueuedText: botTextHelpers.threadRenameQueuedText,
  threadSelectedText: botTextHelpers.threadSelectedText,
  updateChatState,
  updateStreamState,
  usageText: botTextHelpers.usageText,
  useCommandSyntax: botTextHelpers.useCommandSyntax,
});

const {
  handleCancelCommand,
  handleRegularTask,
  handleThreadCommand,
  handleUseCommand,
} = threadTaskCommandHandlers;

const selectionCommandHandlers = createSelectionCommandHandlers({
  botDefaults,
  codexInstanceUnknownText: botTextHelpers.codexInstanceUnknownText,
  codexInstancesListText: botTextHelpers.codexInstancesListText,
  configuredCodexInstance,
  configuredCodexInstanceNames,
  currentInstanceText: botTextHelpers.currentInstanceText,
  currentModelText: botTextHelpers.currentModelText,
  currentProjectText: botTextHelpers.currentProjectText,
  ensureChatState,
  fallbackCodexInstance,
  getProjectRecord,
  instanceSelectedText: botTextHelpers.instanceSelectedText,
  listBoundChatProjects,
  listInstanceSpecs,
  modelSelectedText: botTextHelpers.modelSelectedText,
  modelsListText: botTextHelpers.modelsListText,
  projectInstanceUpdatedText: botTextHelpers.projectInstanceUpdatedText,
  projectMissingText: botTextHelpers.projectMissingText,
  projectNotBoundText: botTextHelpers.projectNotBoundText,
  projectSelectedText: botTextHelpers.projectSelectedText,
  projectsListText: botTextHelpers.projectsListText,
  providerConfig,
  rememberSelectionScope,
  replyText: feishuReplyText,
  resolveProjectCwd,
  updateChatState,
  updateProjectDefaultCodexInstance,
  usageText: botTextHelpers.usageText,
});

const {
  handleInstanceCommand,
  handleInstancesCommand,
  handleModelCommand,
  handleModelsCommand,
  handleProjectCommand,
  handleProjectInstanceCommand,
  handleProjectsCommand,
} = selectionCommandHandlers;

const projectAdminCommandHandlers = createProjectAdminCommandHandlers({
  bindMergedText: botTextHelpers.bindMergedText,
  bindProjectToChat,
  botDefaults,
  ensureChatState,
  ensureProjectRecord,
  fallbackCodexInstance,
  getProjectRecord,
  getSettingValue,
  importPathInvalidText: botTextHelpers.importPathInvalidText,
  normalizeImportPath,
  pathExistsAsDirectory,
  projectCreatedText: botTextHelpers.projectCreatedText,
  projectDirectoryExistsText: botTextHelpers.projectDirectoryExistsText,
  projectExistsText: botTextHelpers.projectExistsText,
  projectNotBoundText: botTextHelpers.projectNotBoundText,
  projectPathAlreadyBoundText: botTextHelpers.projectPathAlreadyBoundText,
  projectPathFilledText: botTextHelpers.projectPathFilledText,
  projectRegisteredText: botTextHelpers.projectRegisteredText,
  projectRootMissingText: botTextHelpers.projectRootMissingText,
  projectUnbindCurrentBlockedText: botTextHelpers.projectUnbindCurrentBlockedText,
  projectUnboundText: botTextHelpers.projectUnboundText,
  replyText: feishuReplyText,
  unbindProjectFromChat,
  updateChatState,
  updateProjectRecordPath,
  usageText: botTextHelpers.usageText,
  listBoundChatProjects,
});

const {
  handleBindCommand,
  handleCreateCommand,
  handleImportCommand,
  handleUnbindCommand,
} = projectAdminCommandHandlers;

const handleCodexCommand = createCodexQueryCommandHandler({
  buildCodexPreflightCommands,
  codeQueryMethods: CODEX_QUERY_METHODS,
  codexCommandHelpText: botTextHelpers.codexCommandHelpText,
  codexInstancePolicyDeps,
  codexRpcCall,
  codexRpcQueuedText: botTextHelpers.codexRpcQueuedText,
  codexThreadRequiredText: botTextHelpers.codexThreadRequiredText,
  createStreamState,
  defaultCodexParams,
  ensureChatState,
  ensureStreamCodexInstance,
  getProjectRecord,
  normalizeCodexAlias,
  parseCodexCommand,
  replyText: feishuReplyText,
  resolveCodexInstance,
  unsupportedCodexMethodText: botTextHelpers.unsupportedCodexMethodText,
  updateStreamState,
});

const sessionCommandHandlers = createSessionCommandHandlers({
  ensureChatState,
  listRecentProjectThreads,
  listSettings,
  newConversationText: botTextHelpers.newConversationText,
  rememberSelectionScope,
  replyText: feishuReplyText,
  settingUpdatedText: botTextHelpers.settingUpdatedText,
  settingsEmptyText: botTextHelpers.settingsEmptyText,
  settingsListText: botTextHelpers.settingsListText,
  threadsListText: botTextHelpers.threadsListText,
  updateChatState,
  upsertSetting,
});

const {
  handleNewCommand,
  handleSettingsCommand,
  handleThreadsCommand,
} = sessionCommandHandlers;

const routeFeishuCommand = createFeishuCommandRouter({
  buildTag: CODEXBOT_TS_BUILD,
  clearSelectionScope,
  handleBindCommand,
  handleCancelCommand,
  handleCodexCommand,
  handleCreateCommand,
  handleHelp,
  handleImportCommand,
  handleInstanceCommand,
  handleInstancesCommand,
  handleModelCommand,
  handleModelsCommand,
  handleNewCommand,
  handleProjectCommand,
  handleProjectInstanceCommand,
  handleProjectsCommand,
  handleRegularTask,
  handleSettingsCommand,
  handleThreadCommand,
  handleThreadsCommand,
  handleUnbindCommand,
  handleUseCommand,
  isUseCommandText,
  shouldIgnoreInbound: (inbound) => feishuInboundDeduper.shouldIgnore(inbound),
});

export function createBotApp() {
  return {
    async startup(runtime) {
      return {
        commands: await runLaneStartup(runtime),
      };
    },

    async app_startup(runtime) {
      return {
        commands: await buildAppStartupCommands(runtime),
      };
    },

    async http(ctx) {
      if (ctx.path === "/health") {
        return ctx.text("OK", 200);
      }
      if (ctx.path === "/admin/state") {
        return ctx.json(
          {
            ok: true,
            app: "codexbot-app-ts",
            dispatchKind: ctx.runtime.dispatchKind,
            snapshot: await runtimeSnapshot(),
          },
          200,
        );
      }
      return ctx.json(
        {
          ok: true,
          app: "codexbot-app-ts",
          dispatchKind: ctx.runtime.dispatchKind,
          path: ctx.path,
        },
        200,
      );
    },

    async websocket_upstream(frame) {
      frame.runtime.log("codexbot-app-ts upstream", CODEXBOT_TS_BUILD, frame.provider, frame.eventType, frame.target);
      if (frame.provider === "feishu" && frame.eventType === "im.message.receive_v1") {
        return routeFeishuCommand(frame);
      }
      if (frame.provider === "codex" && frame.eventType === "codex.rpc.response") {
        return handleCodexRpcResponse(frame);
      }
      if (frame.provider === "codex" && frame.eventType === "codex.notification") {
        return handleCodexNotification(frame);
      }
      return {
        handled: false,
        commands: [],
      };
    },
  };
}
