// Explicit live probe. Configuration is read from the application's JSON file,
// never from provider environment variables. Defaults perform no chat sends.
import fs from "node:fs";
import path from "node:path";
const args = process.argv.slice(2);
const option = (name) => args[args.indexOf(name) + 1];
if (!args.includes("--config")) throw Error("Usage: node probe.mjs --config /path/to/bot.local.json --provider codex|feishu [--instance name] [--turn]");
const configPath = path.resolve(option("--config"));
let config;
try { config = JSON.parse(fs.readFileSync(configPath,"utf8")); } catch (_) { throw Error("invalid_application_configuration"); }
const provider = option("--provider");
const section = config[provider];
if (!section) throw Error("Provider absent from application configuration");
const instance = args.includes("--instance") ? option("--instance") : section.default_instance || "main";
const cfg = {...section,...section.instances?.[instance]};
if (cfg.cwd) {
  if (typeof cfg.cwd !== "string") throw Error("invalid_application_cwd");
  cfg.cwd = path.resolve(path.dirname(configPath), cfg.cwd);
}
const report = [];
try {
  if (provider === "feishu") {
    if (!cfg.app_id || !cfg.app_secret) throw Error("missing_application_credentials");
    const request = async (endpoint, body) => {
      const response = await fetch(`https://open.feishu.cn${endpoint}`, {method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify(body),signal:AbortSignal.timeout(15000)});
      if (!response.ok) throw Error(`feishu_http_${response.status}`);
      const result = await response.json();
      if (result.code !== 0) throw Error(`feishu_api_${Number(result.code)}`);
      return result;
    };
    const token = await request("/open-apis/auth/v3/tenant_access_token/internal", {app_id:cfg.app_id,app_secret:cfg.app_secret});
    if (typeof token.tenant_access_token !== "string" || !token.tenant_access_token) throw Error("invalid_token_response");
    report.push("tenant_authentication");
    const endpoint = await request("/callback/ws/endpoint", {AppID:cfg.app_id,AppSecret:cfg.app_secret});
    const url = endpoint.data?.URL;
    if (typeof url !== "string" || !url.startsWith("wss://")) throw Error("invalid_websocket_endpoint");
    report.push("websocket_endpoint_contract");
  } else if (provider === "codex") {
    const socket = new WebSocket(cfg.url);
    let sequence = 0;
    const pending = new Map();
    let completion;
    const notifications = new Set();
    const rpc = (method, params) => new Promise((resolve,reject) => {
      const id = ++sequence;
      const timer = setTimeout(() => { pending.delete(id); reject(Error("rpc_timeout")); },30000);
      pending.set(id, {resolve:(value) => {clearTimeout(timer);resolve(value);}, reject:(error) => {clearTimeout(timer);reject(error);}});
      socket.send(JSON.stringify({id,method,params}));
    });
    socket.addEventListener("message", (event) => {
      let message;
      try { message = JSON.parse(String(event.data)); } catch (_) { completion?.reject(Error("invalid_json"));return; }
      if (pending.has(message.id)) {
        const waiter = pending.get(message.id);pending.delete(message.id);
        if (message.error) waiter.reject(Error(`codex_rpc_${Number(message.error.code)}`));else waiter.resolve(message.result);
      } else if (typeof message.method === "string") {
        notifications.add(message.method);
        if (message.method === "turn/completed") completion?.resolve(message.params);
      }
    });
    try {
      await new Promise((resolve,reject) => {
        const timer = setTimeout(() => reject(Error("connect_timeout")),10000);
        socket.addEventListener("open", () => {clearTimeout(timer);resolve();},{once:true});
        socket.addEventListener("error", () => {clearTimeout(timer);reject(Error("connect_failed"));},{once:true});
      });
      const initialized = await rpc("initialize", {clientInfo:{name:"vhttpd_protocol_probe",version:"1"},capabilities:{}});
      if (typeof initialized?.userAgent !== "string") throw Error("invalid_initialize_result");
      socket.send(JSON.stringify({method:"initialized",params:{}}));
      report.push("correlated_initialization");
      const models = await rpc("model/list", {});
      if (!Array.isArray(models?.data)) throw Error("invalid_model_list");
      report.push("model_list_contract");
      if (args.includes("--turn")) {
        const thread = await rpc("thread/start", {model:cfg.model,cwd:cfg.cwd,ephemeral:true,sandbox:"read-only",approvalPolicy:"never"});
        if (typeof thread?.thread?.id !== "string") throw Error("invalid_thread_start_result");
        let timer;
        const finished = new Promise((resolve,reject) => {
          timer = setTimeout(() => reject(Error("turn_timeout")),60000);
          completion = {resolve,reject};
        });
        // Attach a rejection handler before awaiting turn/start to avoid unhandled timeouts.
        finished.catch(() => {});
        try {
          await rpc("turn/start", {threadId:thread.thread.id,input:[{type:"text",text:"Reply exactly VHTTPD_PROTOCOL_OK. Do not use tools."}]});
          const result = await finished;
          if (result?.turn?.status !== "completed") throw Error("turn_did_not_complete");
          if (!notifications.has("item/agentMessage/delta")) throw Error("missing_stream_delta");
          report.push("ephemeral_streaming_turn");
        } finally {clearTimeout(timer);completion = undefined;}
      }
    } finally {
      for (const waiter of pending.values()) waiter.reject(Error("probe_closed"));
      pending.clear();socket.close();
    }
  } else { throw Error("unsupported_provider"); }
  console.log(JSON.stringify({ok:true,provider,checks:report}));
} catch (error) {
  // Never echo upstream messages, URL parameters, credentials or file contents.
  console.error(JSON.stringify({ok:false,provider,checks:report,error:/^[a-z0-9_]+$/.test(error.message) ? error.message : "probe_failed"}));
  process.exitCode = 1;
}
