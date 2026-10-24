/* Relay owns project configuration; process restarts remain in the desktop host. */
(() => {
  let draft = null, busy = false, projectFiles = [], workspace = null, sharedImport = null;
  const ids = ['relayId','relayMode','relayNode','relayUrl','relayListener','relayPath','relayToken','relayAutostart','relayReconnect','relayMax','relayBuffer','relayPipeline','relayDirection','relayEgress','relayRoute'];
  const option = (value, label) => '<option value="' + esc(value) + '">' + esc(label || value) + '</option>';
  function stage(message) { $('relayStage').textContent = message; }
  function buttons() {
    $('relayPublish').disabled = busy || !draft?.validated || draft.published;
    $('relayValidate').disabled = busy || !draft || draft.published;
    $('relayLoad').disabled = busy;
    $('relaySource').disabled = busy;
    for (const id of [...ids, 'relaySelect']) $(id).disabled = busy || !!draft?.published;
    if (!busy && !draft?.published) {
      $('relayId').readOnly = $('relaySelect').value !== '';
      const agent = $('relayMode').value === 'agent';
      $('relayUrl').disabled = !agent;
      $('relayAutostart').disabled = !agent;
      $('relayListener').disabled = agent;
      $('relayPath').disabled = agent;
      const binding = !!$('relayPipeline').value;
      $('relayEgress').disabled = !binding || $('relayDirection').value !== 'incoming';
      $('relayRoute').disabled = !binding || $('relayDirection').value !== 'outgoing';
    }
  }
  function invalidate() {
    if (!draft || busy || draft.published) return;
    draft.validated = false;
    $('relayToml').textContent = ''; $('relayChangePaths').textContent = '';
    $('relayBindingLabel').textContent = '磁盘中的项目绑定（当前修改尚未校验）';
    renderBindings();
    stage('有未校验的修改；尚未发布。');
    buttons();
  }
  function populate(id, supplied = null) {
    const r = supplied || draft.model.relays.find(r => r.id === id) || {
      id: 'edge', mode: 'agent', node_id: 'agent-local', url: '', listener: '', path: '/vhttpd/relay',
      token: '${env.VHTTPD_RELAY_TOKEN:-}', autostart: true, reconnect_delay_ms: 1000, max_channels: 1024, channel_buffer: 64
    };
    if (!['agent','hub','client','server'].includes(r.mode) || (r.carrier && r.carrier !== 'websocket')) throw new Error('此 Relay 类型请使用源码编辑器。');
    const values = {relayId:r.id, relayMode: r.mode === 'client' ? 'agent' : r.mode === 'server' ? 'hub' : r.mode,
      relayNode:r.node_id, relayUrl:r.url, relayListener:r.listener, relayPath:r.path, relayToken:r.token,
      relayAutostart:String(r.autostart), relayReconnect:r.reconnect_delay_ms, relayMax:r.max_channels, relayBuffer:r.channel_buffer};
    for (const [key, value] of Object.entries(values)) $(key).value = value ?? '';
    $('relayPipeline').value = '';
    invalidate();
  }
  function pathLabel(path) {
    const file = projectFiles.find(f => f.path === path);
    return file?.role === 'main' ? '主配置 · ' + path.split(/[\\/]/).pop() : file?.include_path || path || '—';
  }
  function renderBindings(model = workspace) {
    const rows = [];
    const relayOwner = id => projectFiles.find(f => asArray(f.relay_ids).includes(id))?.path || (model !== workspace && id === $('relayId').value.trim() ? draft.path : '');
    for (const p of model.pipelines) {
      const adapter = model.adapters.find(a => 'adapter:' + a.id === p.egress);
      const add = (relayId, direction, route) => rows.push([esc(p.id), esc(pathLabel(p.source_path)), esc(direction), esc(relayId), esc(pathLabel(relayOwner(relayId))),
        esc(p.egress) + '<br><small>' + esc(pathLabel(adapter?.source_path)) + '</small>', esc(route || '—')]);
      if (p.ingress.startsWith('relay:')) add(p.ingress.slice(6), 'Relay → Pipeline', '');
      if (adapter?.kind === 'relay-delivery' && (adapter.target || '').startsWith('relay:')) add(adapter.target.slice(6), 'Pipeline → Relay', adapter.route);
    }
    $('relayBindings').innerHTML = table(['Pipeline','Pipeline 来源','方向','Relay','Relay 来源','Adapter / 来源','远端 Pipeline'], rows);
  }
  function pipelineSource() {
    const p = workspace?.pipelines.find(p => p.id === $('relayPipeline').value);
    const adapter = workspace?.adapters.find(a => 'adapter:' + a.id === p?.egress);
    $('relayPipelineSource').textContent = p ? 'Pipeline 来源：' + p.source_path +
      (adapter ? '\n当前 Adapter 来源：' + adapter.source_path : '') : '';
  }
  function choosePipeline() {
    const p = workspace?.pipelines.find(p => p.id === $('relayPipeline').value);
    const adapter = workspace?.adapters.find(a => 'adapter:' + a.id === p?.egress);
    if (p) {
      $('relayEgress').value = p.egress;
      $('relayDirection').value = adapter?.kind === 'relay-delivery' ? 'outgoing' : 'incoming';
      $('relayRoute').value = adapter?.route || '';
    }
    invalidate(); pipelineSource();
  }
  async function load(sourcePath) {
    const next = await apiRequest('/admin/config/workspace');
    const files = asArray(next.files).map(f => f.source);
    const main = files.find(f => f.role === 'main');
    if (!main) throw new Error('找不到项目主配置。');
    const selected = files.find(f => f.path === sourcePath) || files.find(f => f.path === draft?.path) || files.find(f => asArray(f.relay_ids).length) || main;
    const text = next.files.find(f => f.source.path === selected.path).value;
    const fragment = selected.role !== 'main';
    const model = RelayConfig.inspect(text, {fragment});
    workspace = next; projectFiles = files;
    draft = {path:selected.path, projectPath:main.path, original:text, model, fragment,
      id:'relay-ui-' + crypto.randomUUID(), validated:false, published:false};
    $('relaySource').innerHTML = files.map(f => option(f.path,
      (f.role === 'main' ? '主配置 · ' : 'Include · ') + (f.include_path || f.path) +
      (asArray(f.relay_ids).length ? ' · Relay: ' + f.relay_ids.join(', ') : ''))).join('');
    $('relaySource').value = selected.path;
    $('relayConfigPath').textContent = 'Relay 编辑来源：' + selected.path +
      (selected.parent_path ? '\n被包含于：' + selected.parent_path : '') + '\n整项目入口：' + main.path;
    $('relaySelect').innerHTML = option('', '＋ 新建 Relay') + model.relays.map(r => option(r.id)).join('');
    const listeners = new Set(files.flatMap(f => asArray(f.websocket_listeners).map(id => 'listener:' + id)));
    $('relayListener').innerHTML = option('', '选择项目的 WebSocket listener') + [...listeners].map(l => option(l)).join('');
    $('relayEgress').innerHTML = option('', '选择项目的出口 Adapter') + next.adapters.map(a => option('adapter:' + a.id, 'adapter:' + a.id + ' · ' + pathLabel(a.source_path))).join('');
    $('relayPipeline').innerHTML = option('', '仅修改 Relay，不改绑定') + next.pipelines.map(p => option(p.id, p.id + ' · ' + pathLabel(p.source_path))).join('');
    $('relaySelect').value = model.relays[0]?.id || '';
    $('relayForm').classList.remove('hidden');
    populate($('relaySelect').value); renderBindings(); pipelineSource();
    stage('项目配置已载入；可选择其他来源文件中的 Pipeline 一起修改。');
    if (sharedImport) {
      $('relaySelect').value = '';
      populate('', sharedImport);
      stage('共享连接已复制为独立草稿；可选择配置来源和 Pipeline。尚未发布，自动连接默认关闭。');
    }
    $('relayBindingLabel').textContent = '整个项目的 Relay / Pipeline 绑定与来源';
    $('relayResult').textContent = ''; $('relayToml').textContent = ''; $('relayChangePaths').textContent = '';
  }
  function candidate() {
    const r = {id:$('relayId').value.trim(), mode:$('relayMode').value, carrier:'websocket', node_id:$('relayNode').value.trim(),
      url:$('relayUrl').value.trim(), listener:$('relayListener').value, path:$('relayPath').value.trim(), token:$('relayToken').value,
      autostart:$('relayAutostart').value === 'true', reconnect_delay_ms:Number($('relayReconnect').value),
      max_channels:Number($('relayMax').value), channel_buffer:Number($('relayBuffer').value)};
    if ($('relaySelect').value === '' && projectFiles.some(f => asArray(f.relay_ids).includes(r.id))) throw new Error('Relay ID 已存在，请选择已有 Relay 编辑。');
    return RelayConfig.projectEdit(workspace, draft.path, r, {pipeline:$('relayPipeline').value, direction:$('relayDirection').value, egress:$('relayEgress').value, route:$('relayRoute').value.trim()});
  }
  function changesetUrl(action) { return '/admin/config/changesets/' + encodeURIComponent(draft.id) + '/' + action; }
  async function validate() {
    const edit = candidate();
    if (!edit.changes.length) throw new Error('没有要发布的修改；可直接检查生效状态。');
    $('relayToml').textContent = edit.changes.map(f => '# ' + pathLabel(f.path) + '\n' + f.value).join('\n\n');
    $('relayChangePaths').textContent = '本次草稿涉及 ' + edit.changes.length + ' 个文件：\n' + edit.changes.map(f => f.path).join('\n');
    await apiRequest('/admin/config/changesets?id=' + encodeURIComponent(draft.id), {method:'POST', headers:{'content-type':'application/json'}, body:JSON.stringify({config_path:draft.projectPath, files:edit.changes})});
    const result = await apiRequest(changesetUrl('validate'), {method:'POST'});
    $('relayResult').textContent = JSON.stringify(result, null, 2);
    if (!result.ok) throw new Error(result.error || '配置校验失败。');
    const diff = await apiRequest(changesetUrl('diff'));
    draft.edit = edit; draft.validated = true;
    $('relayBindingLabel').textContent = '整个项目的草稿绑定（尚未运行生效）';
    renderBindings(edit);
    $('relayResult').textContent = JSON.stringify({validation:result, diff}, null, 2);
    stage('整个项目校验通过；' + edit.changes.length + ' 个文件作为一份草稿，尚未发布。' + (diff.allowed ? '此变更支持运行计划应用。' : '生效需要工作台重启：' + diff.strategy));
  }
  async function publish() {
    if (!draft.validated || draft.published) throw new Error('请先校验当前草稿。');
    const result = await apiRequest(changesetUrl('publish'), {method:'POST'});
    if (!result.ok) throw new Error(result.error || '发布失败。');
    draft.published = true;
    sharedImport = null;
    $('relayBindingLabel').textContent = '整个项目的已发布绑定（生效状态由宿主工作台检查）';
    stage('整组文件已发布。请返回宿主工作台查看生效状态；点击重启后会自动检查。');
    await refresh();
  }
  async function run(action) {
    if (busy) return;
    busy = true; buttons(); $('relayEditError').textContent = '';
    try { await action(); }
    catch (e) { $('relayEditError').textContent = e.message || String(e); }
    finally { busy = false; if (draft) $('relaySource').value = draft.path; buttons(); }
  }
  for (const id of ids) $(id).addEventListener('input', invalidate);
  $('relayPipeline').addEventListener('change', choosePipeline);
  $('relaySelect').addEventListener('change', () => { sharedImport = null; try { populate($('relaySelect').value); renderBindings(); pipelineSource(); } catch(e) { $('relayEditError').textContent=e.message; } });
  $('relaySource').addEventListener('change', () => run(() => load($('relaySource').value)));
  $('relayLoad').addEventListener('click', () => run(() => load()));
  $('relayValidate').addEventListener('click', () => run(validate));
  $('relayPublish').addEventListener('click', () => run(publish));
  let openedSourceLink = '', openingSourceLink = false;
  async function openSourceLink() {
    if (openingSourceLink || state.authRequired || !state.data.configFiles || openedSourceLink === location.hash) return;
    let link;
    try { link = ConfigSourceLink.parse(location.hash); }
    catch (e) { selectView('relay'); $('relayEditError').textContent = e.message; return; }
    if (!link) return;
    openingSourceLink = true;
    const hash = location.hash;
    try {
      const source = ConfigSourceLink.resolve(link, asArray(state.data.configFiles));
      if (asArray(source.relay_ids).length) {
        selectView('relay');
        await run(() => load(source.path));
      } else {
        if (!window.CommonConfigUI || !await CommonConfigUI.openSource(source.path)) await openConfigFileDraft(source.path);
      }
      openedSourceLink = hash;
    } catch (e) {
      openedSourceLink = hash;
      selectView('relay'); $('relayEditError').textContent = e.message || String(e);
    } finally { openingSourceLink = false; }
  }
  window.addEventListener('vhttpd:refreshed', openSourceLink);
  window.addEventListener('hashchange', openSourceLink);
  openSourceLink();
  let sharedDraftOpened = '', sharedDraftOpening = false;
  async function openSharedDraft() {
    if (!location.hash.startsWith('#relay-draft?') || state.authRequired || !state.data.configFiles || sharedDraftOpening || sharedDraftOpened === location.hash) return;
    sharedDraftOpening = true;
    const hash = location.hash;
    selectView('relay');
    await run(async () => {
      const id = new URLSearchParams(hash.split('?')[1]).get('id');
      if (!/^shared-relay-[a-f0-9]{24}$/.test(id || '')) throw new Error('共享连接草稿编号无效。');
      const bundle = await apiRequest('/admin/config/changesets/' + encodeURIComponent(id));
      if (bundle.files?.length !== 1) throw new Error('共享连接草稿格式无效。');
      const file = bundle.files[0];
      sharedImport = null;
      await load(file.path);
      const original = workspace.files.find(f => f.source.path === file.path);
      if (bundle.config_path !== workspace.config_path || !original || original.value !== file.original) throw new Error('项目配置已变化，请从工作台重新选择共享连接。');
      const added = RelayConfig.inspect(file.value, {fragment: draft.fragment}).relays.filter(r => !projectFiles.some(f => asArray(f.relay_ids).includes(r.id)));
      if (added.length !== 1) throw new Error('共享连接草稿无法识别，请从工作台重新选择。');
      sharedImport = added[0];
      draft.id = id;
      $('relaySelect').value = '';
      populate('', sharedImport);
      stage('共享连接已复制为独立草稿；可选择配置来源和 Pipeline。尚未发布，自动连接默认关闭。');
    });
    sharedDraftOpened = hash;
    sharedDraftOpening = false;
  }
  window.addEventListener('vhttpd:refreshed', openSharedDraft);
  window.addEventListener('hashchange', openSharedDraft);
  openSharedDraft();
})();
