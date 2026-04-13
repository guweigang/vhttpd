import * as path from "path";

export function createProviderRuntimeHelpers(deps) {
  function runtimeConfigValue(runtime, path, fallbackValue) {
    if (!runtime || typeof runtime.getConfig !== "function") {
      return fallbackValue;
    }
    return runtime.getConfig(path, fallbackValue);
  }

  function resolveConfiguredRuntimePath(value) {
    const text = typeof value === "string" ? value.trim() : "";
    if (!text) {
      return "";
    }
    return path.isAbsolute(text) ? text : path.resolve(process.cwd(), text);
  }

  function configuredCodexInstance(instance) {
    const name = deps.normalizeMainInstanceAlias(instance);
    if (!name) {
      return undefined;
    }
    return deps.providerConfig.providers?.codex?.instances?.[name];
  }

  function configuredCodexStartupInstances() {
    const instances = deps.providerConfig.providers?.codex?.instances || {};
    return Object.keys(instances)
      .sort()
      .filter((name) => instances[name]?.startup !== false);
  }

  function configuredCodexInstanceNames() {
    return Object.keys(deps.providerConfig.providers?.codex?.instances || {}).sort();
  }

  function configuredFeishuInstance(instance) {
    const name = deps.normalizeMainInstanceAlias(instance);
    if (!name) {
      return undefined;
    }
    return deps.providerConfig.providers?.feishu?.instances?.[name];
  }

  function configuredFeishuStartupInstances() {
    const instances = deps.providerConfig.providers?.feishu?.instances || {};
    return Object.keys(instances)
      .sort()
      .filter((name) => instances[name]?.startup !== false);
  }

  function fallbackCodexInstance(value, defaults = deps.botDefaults()) {
    return deps.normalizeMainInstanceAlias(value, deps.normalizeMainInstanceAlias(defaults.defaultCodexInstance, "main"));
  }

  function fallbackFeishuInstance(value, defaults = deps.botDefaults()) {
    return deps.normalizeMainInstanceAlias(value, deps.normalizeMainInstanceAlias(defaults.defaultFeishuInstance, "main"));
  }

  function buildCodexInstanceSpec(state, stream = undefined, defaults = deps.botDefaults(), instance = "") {
    const source = stream || state || {};
    const configured = configuredCodexInstance(fallbackCodexInstance(instance, defaults)) || {};
    const configuredCwd = resolveConfiguredRuntimePath(configured.cwd || "");
    return {
      url: configured.url || defaults.codexUrl,
      model: source.model || state?.model || configured.model || defaults.model,
      effort: configured.effort || defaults.effort,
      cwd: source.cwd || state?.cwd || configuredCwd || defaults.cwd,
      approval_policy: configured.approval_policy || defaults.approvalPolicy,
      sandbox: configured.sandbox || defaults.sandbox,
      reconnect_delay_ms: Number(configured.reconnect_delay_ms) > 0 ? Number(configured.reconnect_delay_ms) : defaults.codexReconnectDelay,
      flush_interval_ms: Number(configured.flush_interval_ms) > 0 ? Number(configured.flush_interval_ms) : defaults.codexFlushInterval,
    };
  }

  function buildFeishuInstanceSpec(defaults = deps.botDefaults(), instance = "") {
    const configured = configuredFeishuInstance(fallbackFeishuInstance(instance, defaults)) || {};
    return {
      app_id: configured.app_id || "",
      app_secret: configured.app_secret || "",
      verification_token: configured.verification_token || "",
      encrypt_key: configured.encrypt_key || "",
    };
  }

  function hasFeishuConnectionCredentials(spec) {
    if (!spec || typeof spec !== "object") {
      return false;
    }
    const appId = typeof spec.app_id === "string" ? spec.app_id.trim() : "";
    const appSecret = typeof spec.app_secret === "string" ? spec.app_secret.trim() : "";
    return appId !== "" && appSecret !== "";
  }

  function hasConfiguredInstanceSpec(spec) {
    if (!spec || typeof spec !== "object") {
      return false;
    }
    return Object.values(spec).some((value) => typeof value === "string" && value.trim() !== "");
  }

  async function buildProviderInstanceCommands(provider, instance, spec, desiredState = "connected", options = {}) {
    const commands = [];
    if (hasConfiguredInstanceSpec(spec)) {
      await deps.upsertInstanceSpec(provider, instance, spec, desiredState);
      commands.push(deps.providerInstanceUpsert(provider, instance, spec, desiredState));
    } else if (!options.allowEnsureWithoutStoredSpec) {
      return [];
    }
    commands.push(deps.providerInstanceEnsure(provider, instance));
    return commands;
  }

  async function buildAppStartupCommands(runtime = undefined) {
    const defaults = deps.botDefaults();
    const commands = [];
    const runtimeFeishuEnabled = runtimeConfigValue(runtime, "feishu.enabled", true) !== false;
    const runtimeFeishuBridgeEnabled = runtimeConfigValue(runtime, "feishu.bridge.enabled", false) === true;
    const startedCodexInstances = new Set();
    for (const instance of configuredCodexStartupInstances()) {
      const resolvedInstance = fallbackCodexInstance(instance, defaults);
      const codexSpec = buildCodexInstanceSpec(undefined, undefined, defaults, resolvedInstance);
      commands.push(...await buildProviderInstanceCommands("codex", resolvedInstance, codexSpec, "connected"));
      startedCodexInstances.add(resolvedInstance);
    }
    const codexInstance = fallbackCodexInstance("", defaults);
    if (!startedCodexInstances.has(codexInstance)) {
      const codexSpec = buildCodexInstanceSpec(undefined, undefined, defaults, codexInstance);
      commands.push(...await buildProviderInstanceCommands("codex", codexInstance, codexSpec, "connected"));
    }

    if (!runtimeFeishuEnabled) {
      if (runtime && typeof runtime.log === "function") {
        runtime.log("codexbot-app-ts app_startup", deps.buildTag, "skip feishu startup: feishu.enabled=false");
      }
    } else if (runtimeFeishuBridgeEnabled) {
      if (runtime && typeof runtime.log === "function") {
        runtime.log("codexbot-app-ts app_startup", deps.buildTag, "skip feishu startup: feishu.bridge.enabled=true");
      }
    } else {
      for (const instance of configuredFeishuStartupInstances()) {
        const resolvedInstance = fallbackFeishuInstance(instance, defaults);
        const feishuSpec = buildFeishuInstanceSpec(defaults, resolvedInstance);
        if (hasFeishuConnectionCredentials(feishuSpec)) {
          commands.push(...await buildProviderInstanceCommands("feishu", resolvedInstance, feishuSpec, "connected"));
        } else if (runtime && typeof runtime.log === "function") {
          runtime.log("codexbot-app-ts app_startup", deps.buildTag, `skip feishu startup for ${resolvedInstance}: missing FEISHU_APP_ID or FEISHU_APP_SECRET`);
        }
      }
    }

    if (runtime && typeof runtime.log === "function") {
      runtime.log("codexbot-app-ts app_startup", deps.buildTag, `commands=${commands.length}`);
    }
    return commands;
  }

  async function runLaneStartup(runtime = undefined) {
    if (runtime && typeof runtime.log === "function") {
      runtime.log("codexbot-app-ts startup", deps.buildTag);
    }
    return [];
  }

  return {
    buildAppStartupCommands,
    buildCodexInstanceSpec,
    buildFeishuInstanceSpec,
    buildProviderInstanceCommands,
    configuredCodexInstance,
    configuredCodexInstanceNames,
    configuredCodexStartupInstances,
    configuredFeishuInstance,
    configuredFeishuStartupInstances,
    fallbackCodexInstance,
    fallbackFeishuInstance,
    runLaneStartup,
  };
}
