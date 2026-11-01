// Copy into a Mini Program and bind createClient(...) to `vhttpd`.
// wx.request connects directly to your remote vhttpd + vjsx HTTPS service.
// No wx.cloud SDK or Tencent cloud function forwarding is involved.
// callFunction supports {name, data, success, fail, complete}, not the full SDK.
exports.createClient = function({baseURL, wxApi = globalThis.wx, maxUploadBytes = 10485760}) {
  const base = String(baseURL).replace(/\/$/, "");
  if (!/^https:\/\//.test(base) && !/^http:\/\/127\.0\.0\.1:\d+$/.test(base)) {
    throw Error("Use HTTPS; localhost HTTP is only for developer-tool testing");
  }
  if (!Number.isSafeInteger(maxUploadBytes) || maxUploadBytes < 1 || maxUploadBytes > 67108864) throw Error('Invalid upload limit');
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
  const authenticated = (path, data) => {
    const session = wxApi.getStorageSync(key);
    if (!session || session.expiresAt <= Date.now()) throw Error('LOGIN_REQUIRED');
    return send(path, data, session.token);
  };
  const storageCall = (method, options, work) => {
    const notify = (callback, value) => {
      let failure;
      try { if (typeof callback === 'function') callback(value); } catch (error) { failure = {error}; }
      try { if (typeof options?.complete === 'function') options.complete(value); } catch (error) { failure ||= {error}; }
      if (failure) throw failure.error;
    };
    const promise = Promise.resolve().then(work).then(value => {
      const result = {...value, errMsg: method + ':ok'}; notify(options?.success, result); return result;
    }, reason => {
      const error = Object.assign(new Error(reason?.message || reason?.errMsg || 'REQUEST_FAILED'), reason);
      error.errMsg = method + ':fail ' + error.message; notify(options?.fail, error); throw error;
    });
    if ([options?.success, options?.fail, options?.complete].some(value => typeof value === 'function')) promise.catch(() => {});
    return promise;
  };
  return {
    uploadFile(options = {}) {
      return storageCall('uploadFile', options, async () => {
        if (!options.filePath || !options.cloudPath) throw Error('INVALID_PARAM');
        const session = wxApi.getStorageSync(key);
        if (!session || session.expiresAt <= Date.now()) throw Error('LOGIN_REQUIRED');
        const manager = wxApi.getFileSystemManager();
        const stat = await new Promise((resolve, reject) => manager.stat({path: options.filePath, success: resolve, fail: reject}));
        if (!Number.isSafeInteger(stat.stats?.size) || stat.stats.size > maxUploadBytes) throw Error('FILE_TOO_LARGE');
        const file = await new Promise((resolve, reject) => manager.readFile({filePath: options.filePath, encoding: 'base64', success: resolve, fail: reject}));
        if (typeof file.data !== 'string' || file.data.length > Math.ceil(maxUploadBytes / 3) * 4) throw Error('FILE_TOO_LARGE');
        return authenticated('/storage/upload', {cloudPath: options.cloudPath, base64: file.data});
      });
    },
    getTempFileURL(options = {}) {
      return storageCall('getTempFileURL', options, () => authenticated('/storage/temp-url', {fileList: options.fileList}));
    },
    deleteFile(options = {}) {
      return storageCall('deleteFile', options, () => authenticated('/storage/delete', {fileList: options.fileList}));
    },
    downloadFile(options = {}) {
      return storageCall('downloadFile', options, async () => {
        const response = await authenticated('/storage/temp-url', {fileList: [options.fileID]});
        const file = response.fileList?.[0];
        if (file?.status !== 0 || !file.tempFileURL) throw Error(file?.errMsg || 'FILE_NOT_FOUND');
        const result = await new Promise((resolve, reject) => wxApi.downloadFile({url: file.tempFileURL, success: resolve, fail: reject}));
        if (result.statusCode !== 200) throw Error('DOWNLOAD_FAILED');
        return {tempFilePath: result.tempFilePath, statusCode: result.statusCode};
      });
    },
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
