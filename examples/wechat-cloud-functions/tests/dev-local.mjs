// Readiness probe executed by vjsx. Native process ownership/traps live in dev-local.sh.
if (process.release?.name !== 'vjsx') throw Error('Run this probe with vjsx');
const base = process.env.WCF_BASE_URL;
if (!/^http:\/\/127\.0\.0\.1:\d+$/.test(base || '')) throw Error('loopback WCF_BASE_URL required');
const budget = 2 * Number(process.env.VHTTPD_VJSX_BOOTSTRAP_TIMEOUT_MS || 120000) + 15000;
const end = Date.now() + budget;
let ready = false, last = '';
while (Date.now() < end) {
  try {
    const login = await fetch(base + '/auth/login', {method: 'POST',
      headers: {'content-type': 'application/json'}, body: JSON.stringify({code: 'local-readiness-probe'}),
      signal: AbortSignal.timeout(5000)});
    if (login.status !== 200) throw Error('login HTTP ' + login.status);
    const session = await login.json();
    const response = await fetch(base + '/functions/getUser', {method: 'POST', body: '{}',
      headers: {'content-type': 'application/json', authorization: 'Bearer ' + session.token},
      signal: AbortSignal.timeout(5000)});
    if (response.status !== 200 || (await response.json()).result?.openid !== 'local-demo-user') throw Error('SDK query failed');
    ready = true; break;
  } catch (error) { last = error.message; await new Promise(resolve => setTimeout(resolve, 500)); }
}
if (!ready) throw Error('vhttpd readiness timed out: ' + last);
console.log('LOCAL DEMO READY: ' + base);
console.log('FAKE IDENTITY ONLY: local-demo-user (not a verified WeChat user)');
