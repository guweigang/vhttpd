/* Common configuration forms share the project changeset API with Relay. */
(() => {
  let workspace, model, draft, baseline, pending={}, deleting=null, busy=false, published=false;
  const area=$('commonFields');
  const option=(value,label)=>'<option value="'+esc(value)+'">'+esc(label || value)+'</option>';
  const stage=(message,tone='info')=>{ $('commonStage').textContent=message; $('commonStage').dataset.tone=tone; };
  function controls() {
    for (const input of area.querySelectorAll('input,select,textarea')) input.disabled=busy || published || deleting!==null;
    for (const button of area.querySelectorAll('button')) button.disabled=busy || deleting!==null || (published && !button.hasAttribute('data-common-source'));
    for(const id of ['commonAddListener','commonAddRoute','commonAddEngine','commonAddAdapter','commonNewSource']) $(id).disabled=busy || published || !workspace || deleting!==null;
    $('commonLoad').disabled=busy || deleting!==null;
    $('commonValidate').disabled=busy || !workspace || published || deleting!==null;
    $('commonPublish').disabled=busy || !draft || published || deleting!==null;
    $('configureProject').disabled=busy || deleting!==null;
  }
  function edits() {
    const result={};
    for (const input of area.querySelectorAll('[data-common-field]')) {
      const index=input.dataset.commonItem, key=input.dataset.commonField;
      (result[index] ||= {})[key] = key === 'port' ? Number(input.value) :
        key === 'match.paths' ? input.value.split('\n').map(v=>v.trim()).filter(Boolean) :
        key === 'match.methods' ? input.value.split(',').map(v=>v.trim()).filter(Boolean) : input.value;
    }
    return result;
  }
  function capture() { for(const [index,values] of Object.entries(edits())) pending[index]=values; }
  function changes() { return CommonConfig.edit(workspace,model,edits()); }
  function fingerprint() { return JSON.stringify({edits:edits(),metadata:[...area.querySelectorAll('[data-common-meta]')].map(i=>[i.dataset.commonItem,i.dataset.commonMeta,i.value]),operations:model?.items.map(i=>({id:i.id,path:i.path,added:!!i.added,deleted:!!i.deleted,before:i.before,kind:i.kind}))}); }
  function invalidate() { draft=null; stage('有未发布修改，请保存并校验整个项目。'); controls(); }
  function render() {
    const order={listener:0,route:1,engine:2,adapter:3};
    area.innerHTML=model.items.map((item,index)=>({item,index})).sort((a,b)=>order[a.item.type]-order[b.item.type]).map(({item,index})=>{
      const value=pending[index] || item.values;
      if(item.deleted) return '<fieldset class="common-component common-deleted" data-common-card="'+index+'"><legend>'+esc(item.id)+' · 待删除</legend><p>来源：'+esc(item.path)+'。尚未发布。</p><button class="button" data-common-undo="'+index+'">撤销删除</button></fieldset>';
      const title={listener:'HTTP 监听',route:'HTTP 路由',engine:'vjsx 执行器',adapter:'出口 Adapter'}[item.type];
      let fields='';
      const sources=workspace.files.map(f=>option(f.source.path,(f.source.role==='main'?'主配置 · ':'Include · ')+(f.source.include_path || f.source.path))).join('');
      const meta=item.added?'<div class="form-grid"><div class="form-field"><label for="common-id-'+index+'">'+({listener:'监听 ID',route:'路由 ID',engine:'执行器 ID',adapter:'Adapter ID'}[item.type])+'</label><input id="common-id-'+index+'" data-common-meta="id" data-common-item="'+index+'" value="'+esc(item.id)+'"></div><div class="form-field"><label for="common-source-'+index+'">配置来源文件</label><select id="common-source-'+index+'" data-common-meta="path" data-common-item="'+index+'">'+sources+'</select></div></div>':'';
      const field=(key,label,body)=>'<div class="form-field"><label for="common-'+index+'-'+key+'">'+label+'</label>'+body+'</div>';
      const attrs=key=>' id="common-'+index+'-'+key+'" data-common-item="'+index+'" data-common-field="'+key+'"';
      const input=(key,label,type='text')=>field(key,label,'<input'+attrs(key)+' type="'+type+'" value="'+esc(value[key])+'"'+(type==='number'?' min="1" max="65535" step="1"':'')+'>');
      const select=(key,label,options)=>field(key,label,'<select'+attrs(key)+'>'+options.map(([v,l])=>option(v,l)).join('')+'</select>');
      if (!item.error) {
        if (item.type==='listener') fields=input('host','监听地址（留空沿用运行时默认地址）')+input('port','端口','number');
        if (item.type==='engine') fields=input('entry','JS / TS 入口路径')+input('module_root','模块目录（可选）')+'<p>入口文件须已存在；删除执行器只删除配置，保留源码。新增执行器默认使用 script 运行模式。</p>';
        if(item.type==='adapter') {
          if(item.kind==='http-handler') {
            const engines=model.items.filter(i=>i.type==='engine' && !i.deleted).map(i=>['engine:'+i.id,i.id+' · '+i.path]);
            if(!engines.some(([v])=>v===value.engine)) engines.push([value.engine,value.engine || '请选择执行器']);
            fields=select('engine','绑定执行器',engines);
          }
          if(item.kind==='static') fields=input('root','静态文件根目录');
          if(item.kind==='fixed-response') fields=input('options.status','HTTP 状态码')+input('options.body','响应内容');
          if(item.kind==='relay-delivery') fields=input('options.target','Relay 目标节点')+input('options.route','Relay 路由（可选）');
          if(!fields) fields='<p>此类型的参数保留高级 TOML 编辑；删除前会检查整个项目的引用。</p>';
        }
        if (item.type==='route') {
          const listeners=[['','请选择 HTTP 监听'],...model.items.filter(i=>i.type==='listener' && !i.deleted && !i.error).map(i=>['listener:'+i.id,i.id+' · '+i.path])];
          if (!listeners.some(([v])=>v===value.ingress)) listeners.push([value.ingress,value.ingress]);
          const adapters=[['','请选择出口 Adapter'],...model.items.filter(i=>i.type==='adapter' && !i.deleted).map(a=>['adapter:'+a.id,a.id+' · '+a.path]),...model.adapters.filter(a=>!model.items.some(i=>i.type==='adapter' && i.id===a.id)).map(a=>['adapter:'+a.id,a.id+' · '+a.source_path])];
          if (!adapters.some(([v])=>v===value.egress)) adapters.push([value.egress,value.egress]);
          fields=select('ingress','输入 HTTP 监听',listeners)+select('egress','出口 Adapter',adapters)+
            field('match.paths','路由路径（每行一条，* 表示全部路径）','<textarea'+attrs('match.paths')+' rows="3">'+esc(value['match.paths'].join('\n'))+'</textarea>')+
            field('match.methods','HTTP 方法（逗号分隔；留空表示全部）','<input'+attrs('match.methods')+' value="'+esc(value['match.methods'].join(', '))+'" placeholder="GET, POST">');
        }
      }
      const kind=item.type==='adapter'?(item.added?'<div class="form-field"><label for="common-kind-'+index+'">出口类型</label><select id="common-kind-'+index+'" data-common-meta="kind" data-common-item="'+index+'">'+[['http-handler','vjsx / 执行器处理'],['static','静态文件'],['fixed-response','固定响应'],['relay-delivery','Relay 转发']].map(([k,l])=>option(k,l)).join('')+'</select></div>':'<p>类型：'+esc(item.kind)+'</p>'):'';
      const positions=item.added && item.type==='route'?'<div class="form-field"><label for="common-before-'+index+'">插入位置</label><select id="common-before-'+index+'" data-common-meta="before" data-common-item="'+index+'">'+workspace.pipelines.filter(p=>p.source_path===item.path).map(p=>option(p.id,'在 '+p.id+' 之前')).join('')+option('','文件末尾')+'</select><small>现有路由顺序保持不变；跨 include 的顺序沿用项目合并规则。</small></div>':'';
      return '<fieldset class="common-component" data-common-card="'+index+'"><legend>'+title+' · '+esc(item.id)+(item.added?' · 待新增':'')+'</legend><p class="value-text">来源：'+esc(item.path)+'</p>'+
        meta+kind+(item.error?'<p>'+esc(item.error)+'</p>':'<div class="form-grid">'+fields+'</div>')+
        positions+(item.added?'':'<button class="button" data-common-source="'+index+'">高级：编辑此来源 TOML</button>')+((!item.error || item.canDelete)?' <button class="button danger" data-common-delete="'+index+'">'+(item.added?'取消新增':'删除'+({listener:'监听',route:'路由',engine:'执行器',adapter:'出口'}[item.type]))+'</button>':'')+'</fieldset>';
    }).join('') || '<p>当前项目没有可表单编辑的 HTTP / vjsx 配置，请使用下方配置文件的 TOML 编辑入口。</p>';
    for (const input of area.querySelectorAll('select[data-common-field]')) input.value=(pending[input.dataset.commonItem] || model.items[Number(input.dataset.commonItem)].values)[input.dataset.commonField];
    for(const input of area.querySelectorAll('select[data-common-meta]')) input.value=model.items[Number(input.dataset.commonItem)][input.dataset.commonMeta];
  }
  async function load() {
    if (workspace && !published && fingerprint() !== baseline && !window.confirm('重新读取会丢弃表单中的未发布修改，是否继续？')) return;
    const next=await apiRequest('/admin/config/workspace');
    const nextModel=CommonConfig.inspect(next);
    workspace=next; model=nextModel; draft=null; pending={}; deleting=null; published=false;
    $('commonDeletePanel').classList.add('hidden');
    $('commonNewSource').innerHTML=workspace.files.map(f=>option(f.source.path,(f.source.role==='main'?'主配置 · ':'Include · ')+(f.source.include_path || f.source.path))).join('');
    $('commonNewSource').value=workspace.config_path;
    render(); baseline=fingerprint(); stage('修改常用字段后，保存并校验整个项目，再发布。管理监听不在表单中修改。');
    $('commonProject').textContent='整项目入口：'+workspace.config_path;
    $('commonResult').textContent='';
  }
  async function run(action) {
    if (busy) return;
    busy=true; controls();
    try { await action(); }
    catch(e) {
      const message=e.message || String(e);
      if (message.includes('config_changeset_source_changed')) { draft=null; stage('来源文件已被其他编辑修改，请重新读取项目配置后再校验、发布。','danger'); }
      else stage('操作失败：'+message,'danger');
    }
    finally { busy=false; controls(); }
  }
  async function open(scroll=true) {
    selectView('apps');
    $('configEditorSlot').classList.add('hidden');
    if (!workspace) await run(load);
    if (scroll) $('commonConfigPanel').scrollIntoView({block:'start'});
  }
  async function validate() {
    draft=null;
    const files=changes();
    if (!files.length) { stage('没有配置变化，无需发布。'); return; }
    const snapshot=fingerprint(), id='common-ui-'+crypto.randomUUID();
    stage('正在保存草稿并校验整个项目…');
    await apiRequest('/admin/config/changesets?id='+encodeURIComponent(id),{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({config_path:workspace.config_path,files})});
    const result=await apiRequest('/admin/config/changesets/'+id+'/validate',{method:'POST'});
    if (!result.ok) throw Error(result.error || '整项目校验失败。');
    const diff=await apiRequest('/admin/config/changesets/'+id+'/diff');
    draft={id,snapshot};
    $('commonResult').textContent=JSON.stringify({validation:result,diff},null,2);
    stage('整个项目校验通过，'+files.length+' 个来源文件待发布；尚未写入文件。','good');
  }
  async function publish() {
    if (!draft || draft.snapshot!==fingerprint()) { draft=null; throw Error('请先校验当前表单。'); }
    const result=await apiRequest('/admin/config/changesets/'+draft.id+'/publish',{method:'POST'});
    if (!result.ok) throw Error(result.error || '发布失败。');
    published=true; draft=null;
    stage('配置已发布，待重启生效。回到 Mac 工作台点击“重启并生效”，完成后自动检查整个项目并重新登录 Admin UI。继续修改请点“重新读取”。','warning');
    await refresh();
  }
  function changed(event) {
    if(busy || published) return;
    const input=event.target;
    capture();
    if(input.dataset.commonMeta) {
      if(event.type==='input') { invalidate();return; }
      const item=model.items[Number(input.dataset.commonItem)], key=input.dataset.commonMeta, old=item[key];
      if(key==='kind') { CommonConfig.setAdapterKind(item,input.value);pending[input.dataset.commonItem]={...item.values}; }
      else item[key]=input.value;
      if(key==='path') item.before=workspace.pipelines.find(p=>p.source_path===item.path)?.id || '';
      if(key==='id') for(const values of Object.values(pending)) for(const field of ['ingress','egress','engine']) if(values[field]===item.type+':'+old) values[field]=item.type+':'+item.id;
      if(event.type==='change') render();
    }
    invalidate();
  }
  area.addEventListener('input',changed);
  area.addEventListener('change',changed);
  function add(type) {
    if(busy || published || !workspace || deleting!==null) return;
    capture();
    const item=CommonConfig.create(workspace,{...model,items:model.items.map((item,index)=>({...item,values:{...item.values,...pending[index]}}))},type,$('commonNewSource').value);
    model.items.push(item); pending[model.items.length-1]={...item.values};
    render(); invalidate();
    area.querySelector('[data-common-card="'+(model.items.length-1)+'"]').scrollIntoView({block:'center'});
  }
  function previewDelete(index) {
    capture();
    const item=model.items[index],impact=CommonConfig.deletionImpact(workspace,model,index,pending);
    deleting={index,impact};
    $('commonDeleteTitle').textContent='删除'+({listener:' HTTP 监听',route:' HTTP 路由',engine:' vjsx 执行器',adapter:'出口 Adapter'}[item.type])+' · '+item.id;
    $('commonDeleteImpact').innerHTML='<p>来源：'+esc(item.path)+'</p>'+
      (impact.bindings.length?'<p>受影响的绑定：</p><ul>'+impact.bindings.map(b=>'<li>'+esc(b.ingress+' → '+b.id+' → '+b.egress+(b.relay?' → '+b.relay:''))+'<br><small>'+esc(b.path)+(b.scheduledRemoval?' · 已待删除':'')+'</small></li>').join('')+'</ul>':'<p>没有关联的路由绑定。</p>')+
      (impact.references.length?'<p>项目内引用：</p><ul>'+impact.references.map(r=>'<li>'+esc(r.component+' · '+r.field)+(r.scheduledRemoval?' · 已待删除':'')+'<br><small>'+esc(r.path)+'</small></li>').join('')+'</ul>':'')+
      (impact.blockers.length?'<p>存在不能一并删除的引用，请先取消并改绑，或使用高级 TOML 编辑。</p>':'')+
      '<p>此操作先暂存删除；统一校验并发布后才会写入文件。未选择的组件与源码文件继续保留。</p>';
    $('commonDeleteCascade').checked=false;
    $('commonDeleteCascade').disabled=!impact.cascadeIndices.length || !!impact.blockers.length;
    $('commonDeleteCascadeLabel').classList.toggle('hidden',!impact.cascadeIndices.length);
    $('commonDeleteCascadeText').textContent='同时删除上述 '+impact.cascadeIndices.length+' 条 HTTP 路由（可在发布前撤销）';
    $('commonDeletePanel').classList.remove('hidden');
    deleteControls();controls();
    $('commonDeletePanel').scrollIntoView({block:'center'});
  }
  function deleteControls() {
    if(!deleting) return;
    $('commonDeleteConfirm').disabled=!!deleting.impact.blockers.length || (!!deleting.impact.cascadeIndices.length && !$('commonDeleteCascade').checked);
  }
  function closeDelete() { deleting=null; $('commonDeletePanel').classList.add('hidden');controls(); }
  $('commonAddListener').addEventListener('click',()=>add('listener'));
  $('commonAddRoute').addEventListener('click',()=>add('route'));
  $('commonAddEngine').addEventListener('click',()=>add('engine'));
  $('commonAddAdapter').addEventListener('click',()=>add('adapter'));
  $('commonDeleteCascade').addEventListener('change',deleteControls);
  $('commonDeleteCancel').addEventListener('click',closeDelete);
  $('commonDeleteConfirm').addEventListener('click',()=>{
    if(!deleting || $('commonDeleteConfirm').disabled) return;
    const indices=[deleting.index,...($('commonDeleteCascade').checked?deleting.impact.cascadeIndices:[])];
    for(const index of indices) model.items[index].deleted=true;
    closeDelete();render();invalidate();
  });
  area.addEventListener('click',event=>{
    if(busy || deleting!==null) return;
    const removeButton=event.target.closest('[data-common-delete]');
    if(removeButton && !published) { previewDelete(Number(removeButton.dataset.commonDelete));return; }
    const undo=event.target.closest('[data-common-undo]');
    if(undo && !published) { capture();model.items[Number(undo.dataset.commonUndo)].deleted=false;render();invalidate();return; }
    const button=event.target.closest('[data-common-source]');
    if (!button || busy) return;
    const item=model.items[Number(button.dataset.commonSource)];
    run(()=>openConfigFileDraft(item.path));
  });
  $('commonLoad').addEventListener('click',()=>run(load));
  $('commonValidate').addEventListener('click',()=>run(validate));
  $('commonPublish').addEventListener('click',()=>run(publish));
  document.querySelector('[data-view="apps"]').addEventListener('click',()=>open(false));
  async function openSource(path, pipelineId, componentType='route') {
    await open(false);
    const index=model?.items.findIndex(i=>i.path===path && !i.error && (!pipelineId || (i.type===componentType && i.id===pipelineId))) ?? -1;
    if (index < 0) return false;
    for(const previous of area.querySelectorAll('.common-located')) previous.classList.remove('common-located');
    const card=area.querySelector('[data-common-card="'+index+'"]');card.classList.add('common-located');card.scrollIntoView({block:'center'});
    return true;
  }
  window.CommonConfigUI={open,openSource};
  controls();
})();
