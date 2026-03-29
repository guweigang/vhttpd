import { botDefaults } from "./config.mts";

const defaults = botDefaults();
const codexInstances = {};
const feishuInstances = {};
const providers = {};
const providerConfig = {};

codexInstances.main = {};
codexInstances.main.startup = true;

codexInstances.local4501 = {};
codexInstances.local4501.url = "ws://127.0.0.1:4501";
codexInstances.local4501.cwd = "../../codex/";
codexInstances.local4501.startup = false;

feishuInstances.main = {};
feishuInstances.main.startup = true;
feishuInstances.main.app_id = defaults.feishuAppId;
feishuInstances.main.app_secret = defaults.feishuAppSecret;
feishuInstances.main.verification_token = defaults.feishuVerificationToken;
feishuInstances.main.encrypt_key = defaults.feishuEncryptKey;

providers.codex = {};
providers.codex.instances = codexInstances;

providers.feishu = {};
providers.feishu.instances = feishuInstances;

providerConfig.providers = providers;

export default providerConfig;
