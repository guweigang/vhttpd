const {createClient} = require('../../utils/vhttpd');
const config = require('../../config');

Page({
  data: {
    baseURL: config.baseURL, local: true, loggedIn: false, busy: false,
    status: '未登录', expiresAt: '', error: '', userJSON: '', requestId: '', events: [],
  },
  onLoad() {
    this._disposed = false;
    this.update({local: /^http:\/\/127\.0\.0\.1:\d+$/.test(this.data.baseURL)});
  },
  onUnload() { this._disposed = true; },
  update(patch) { if (!this._disposed) this.setData(patch); },
  log(event) { this.update({events: this.data.events.concat(event).slice(-12)}); },
  onBaseURLInput(event) {
    if (this.data.busy) return;
    const baseURL = event.detail.value.trim().replace(/\/$/, '');
    this._vhttpd = undefined;
    this.update({baseURL, local: /^http:\/\/127\.0\.0\.1:\d+$/.test(baseURL),
      loggedIn: false, status: '地址已更改，请重新登录', expiresAt: '',
      userJSON: '', requestId: '', error: '', events: []});
  },
  client() {
    // Pass wx explicitly: no reliance on globalThis.wx in a Mini Program.
    if (!this._vhttpd) this._vhttpd = createClient({baseURL: this.data.baseURL, wxApi: wx});
    return this._vhttpd;
  },
  failure(error) {
    if (error.status === 401 || error.message === 'LOGIN_REQUIRED') {
      this.update({loggedIn: false, expiresAt: ''});
    }
    this.update({error: error.errMsg || error.message || '请求失败', status: '请求失败', userJSON: '', requestId: ''});
  },
  async onLogin() {
    if (this.data.busy) return;
    this.update({busy: true, error: '', loggedIn: false, userJSON: '', requestId: '', events: [], status: '登录中…'});
    try {
      const vhttpd = this.client();
      const session = await vhttpd.login();
      // Do not render or log the login code / bearer token.
      this.update({loggedIn: true, status: '登录成功', expiresAt: new Date(session.expiresAt).toLocaleString()});
      this.log('vhttpd.login → 成功');
    } catch (error) { this.failure(error); }
    finally { this.update({busy: false}); }
  },
  showResult(response) {
    this.update({userJSON: JSON.stringify(response.result, null, 2), requestId: response.requestId || '', status: '查询成功'});
  },
  async onPromiseQuery() {
    if (this.data.busy) return;
    this.update({busy: true, error: '', events: [], userJSON: '', requestId: '', status: 'Promise 查询中…'});
    try {
      const vhttpd = this.client();
      const response = await vhttpd.callFunction({name: 'getUser', data: {}});
      this.showResult(response);
      this.log('Promise → resolved');
    } catch (error) { this.failure(error); this.log('Promise → rejected'); }
    finally { this.update({busy: false}); }
  },
  onCallbackQuery() {
    if (this.data.busy) return;
    this.update({busy: true, error: '', events: [], userJSON: '', requestId: '', status: '回调查询中…'});
    try {
      const vhttpd = this.client();
      // Intentionally no await/catch: this demonstrates callback-only migration.
      vhttpd.callFunction({
        name: 'getUser', data: {},
        success: response => { this.showResult(response); this.log('success'); },
        fail: error => { this.failure(error); this.log('fail'); },
        complete: () => { this.log('complete'); this.update({busy: false}); },
      });
    } catch (error) { this.failure(error); this.update({busy: false}); }
  },
  onClearSession() {
    if (this.data.busy) return;
    try {
      this.client().clearSession();
      this.update({loggedIn: false, status: '本地会话已清除', expiresAt: '', userJSON: '', requestId: '', error: '', events: []});
    } catch (error) { this.failure(error); }
  },
});
