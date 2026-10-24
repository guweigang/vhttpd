// Copy into a Mini Program and bind createClient(...) to `vhttpd`.
// wx.request connects directly to your remote vhttpd + vjsx HTTPS service.
// No wx.cloud SDK or Tencent cloud function forwarding is involved.
// callFunction supports {name, data, success, fail, complete}, not the full SDK.
exports.createClient = function({baseURL, wxApi = globalThis.wx}) {
  const base = String(baseURL).replace(/\/$/, "");
  if (!/^https:\/\//.test(base) && !/^http:\/\/127\.0\.0\.1:\d+$/.test(base)) {
    throw Error("Use HTTPS; localhost HTTP is only for developer-tool testing");
  }
  const key = "wcf-session:" + base;
  let loggingIn;
  const send = (path, data, token) => new Promise((resolve, reject) => wxApi.request({
    url: base + path, method: "POST", data,
    header: {"content-type": "application/json", ...(token ? {authorization: "Bearer " + token} : {})},
    success(response) {
      if (response.statusCode === 200) return resolve(response.data);
      if (response.statusCode === 401) wxApi.removeStorageSync(key);
      const error = Error(response.data?.error?.code || "REQUEST_FAILED");
      error.status = response.statusCode;
      reject(error);
    },
    fail: reject,
  }));
  return {
    login() {
      if (loggingIn) return loggingIn;
      loggingIn = (async () => {
        const code = await new Promise((resolve, reject) => wxApi.login({
          success: result => result.code ? resolve(result.code) : reject(Error("WECHAT_LOGIN_FAILED")), fail: reject,
        }));
        const session = await send("/auth/login", {code});
        wxApi.setStorageSync(key, session);
        return session;
      })();
      loggingIn.then(() => { loggingIn = undefined; }, () => { loggingIn = undefined; });
      return loggingIn;
    },
    callFunction(options = {}) {
      const success = options?.success, fail = options?.fail, complete = options?.complete;
      const notify = (callback, value) => {
        // Even a throwing success/fail callback must not skip complete.
        let callbackError;
        try { if (typeof callback === "function") callback(value); }
        catch (error) { callbackError = {error}; }
        try { if (typeof complete === "function") complete(value); }
        catch (error) { if (!callbackError) callbackError = {error}; }
        if (callbackError) throw callbackError.error;
      };
      const operation = (async () => {
        const {name, data = {}} = options;
        if (!/^[A-Za-z][A-Za-z0-9_-]{0,63}$/.test(name)) throw Error("INVALID_FUNCTION_NAME");
        const session = wxApi.getStorageSync(key);
        if (!session || session.expiresAt <= Date.now()) throw Error("LOGIN_REQUIRED");
        // Never automatically retry a business call: it might already have written.
        return send("/functions/" + name, data, session.token);
      })();
      const promise = operation.then(value => {
        const result = {...value, errMsg: "callFunction:ok"};
        notify(success, result);
        return result;
      }, reason => {
        // Preserve HTTP status / transport details, adding the SDK-style errMsg.
        const message = reason?.message || reason?.errMsg || "REQUEST_FAILED";
        const error = Object.assign(new Error(message), reason);
        error.errMsg = "callFunction:fail " + message;
        notify(fail, error);
        throw error;
      });
      // Callback-only callers may ignore the return value. Mark that rejection
      // handled without changing the Promise seen by callers that also await it.
      if ([success, fail, complete].some(callback => typeof callback === "function")) {
        promise.catch(() => {});
      }
      return promise;
    },
    clearSession() { wxApi.removeStorageSync(key); }, // local only; does not revoke the server token
  };
};
