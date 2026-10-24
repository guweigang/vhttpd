const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
function editor(validation = {ok:true}) {
  const elements = new Map();
  const element = id => {
    if (!elements.has(id)) elements.set(id, {value:'', textContent:'', disabled:false, classList:{toggle(){}}, parentElement:{classList:{toggle(){}}}});
    return elements.get(id);
  };
  const calls = [];
  const context = vm.createContext({document:{getElementById:element,querySelector:()=>element('label')},validation,calls});
  const source = fs.readFileSync('admin/ui/app.js','utf8');
  vm.runInContext(source.slice(0, source.indexOf('    localStorage.removeItem')), context);
  vm.runInContext(`refresh = async () => {};
    apiRequest = async (path, options) => { calls.push({path,options}); return path.endsWith('/validate') ? validation : {ok:true}; };
    state.activeDraftId = 'config.main'; state.configDraft = true;`,context);
  element('draftEditorInput').value = 'version = 2\n';
  element('draftPublishPath').value = '/project/vhttpd.toml';
  return {element,calls,run:code=>vm.runInContext(code,context)};
}
test('validate saves latest text first, then publish targets original configuration', async () => {
  const e = editor();
  await e.run('runDraftAction("validate")');
  assert.equal(e.calls[0].options.method, 'PUT');
  assert.equal(e.calls[0].options.body,'version = 2\n');
  assert.ok(e.calls[1].path.endsWith('/validate'));
  assert.equal(e.element('publishDraft').disabled,false);
  await e.run('runDraftAction("publish")');
  assert.ok(e.calls[2].path.endsWith('/publish?path=%2Fproject%2Fvhttpd.toml'));
  assert.equal(e.element('publishDraft').disabled,true);
  assert.match(e.element('draftStage').textContent,/重启并生效/);
});
test('invalid project cannot be published', async () => {
  const e = editor({ok:false,error:'invalid reference'});
  await e.run('runDraftAction("validate")');
  assert.equal(e.element('publishDraft').disabled,true);
  await assert.rejects(e.run('publishDraftEditor()'),/先保存并校验/);
  assert.equal(e.calls.length,2);
});
test('editing text or destination invalidates validation, even without an input event', async () => {
  for (const field of ['draftEditorInput','draftPublishPath']) {
    const e = editor();
    await e.run('runDraftAction("validate")');
    e.element(field).value += 'changed';
    await assert.rejects(e.run('publishDraftEditor()'),/先保存并校验/);
    assert.equal(e.calls.length,2);
  }
});
test('diff reflects latest unsaved text and opens the result without a page change', async () => {
  const e = editor();
  e.element('draftEditorInput').value += '# new edit';
  await e.run('runDraftAction("diff")');
  assert.equal(e.calls[0].options.body,'version = 2\n# new edit');
  assert.ok(e.calls[1].path.endsWith('/validate'));
  assert.ok(e.calls[2].path.endsWith('/diff'));
  assert.equal(e.element('draftTechnical').open,true);
});
test('observability does not turn missing telemetry into healthy zero, and resets samples after restart', () => {
  const e=editor();
  e.run('state.data = {}; state.errors = {stats:"offline"}; renderObservability(); recordTelemetrySample();');
  assert.equal(e.element('healthState').textContent,'统计未确认');
  assert.match(e.element('healthGrid').innerHTML,/—/);
  assert.equal(e.run('state.history.length'),0);
  e.run('state.errors = {}; state.data = {runtime:{started_at_unix:1}, stats:{http:{requests_total:8,errors_total:0}}}; recordTelemetrySample();');
  assert.equal(e.run('state.history.length'),1);
  e.run('state.data.runtime.started_at_unix=2; state.data.stats.http.requests_total=0; recordTelemetrySample();');
  assert.equal(e.run('state.history.length'),1);
  assert.equal(e.run('state.history[0].requests'),0);
});
