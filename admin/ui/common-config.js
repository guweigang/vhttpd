/* Lossless common-field editing. The backend still compiles the whole project. */
(function(root) {
  const same = (a,b) => JSON.stringify(a) === JSON.stringify(b);
  const R = root.RelayConfig;
  function array(raw) {
    // Accept ordinary TOML string arrays, including literal strings and trailing commas.
    const values = []; let i = 0;
    const space = () => { while (i < raw.length && /\s/.test(raw[i])) i++; };
    space(); if (raw[i++] !== '[') throw Error('路由条件需要使用字符串数组；复杂表达式请使用 TOML 编辑。');
    while (true) {
      space(); if (raw[i] === ']') { i++; break; }
      const quote = raw[i], start = i++;
      if (!['"', "'"].includes(quote) || raw.slice(start,start+3) === quote.repeat(3)) throw Error('复杂路由条件请使用 TOML 编辑。');
      while (i < raw.length && raw[i] !== quote) { if (quote === '"' && raw[i] === '\\') i++; i++; }
      if (i >= raw.length) throw Error('路由字符串未闭合。');
      i++;
      values.push(quote === '"' ? JSON.parse(raw.slice(start,i)) : raw.slice(start+1,i-1));
      space(); if (raw[i] === ',') { i++; continue; } if (raw[i] !== ']') throw Error('路由条件需要逗号分隔。');
    }
    space(); if (i !== raw.length) throw Error('无法识别路由条件。');
    return values;
  }
  function read(section,key,fallback) {
    const e = section.entries.filter(e => same(e.key,key.split('.')));
    if (e.length > 1) throw Error('重复字段，请先使用 TOML 编辑修复。');
    const value = e.length && Array.isArray(fallback) ? array(e[0].raw) : R.read(section,key,fallback);
    if (typeof value !== typeof fallback || Array.isArray(value) !== Array.isArray(fallback)) throw Error('此字段格式需要使用 TOML 编辑。');
    return value;
  }
  const domains={listener:'listeners',route:'pipelines',engine:'engines',adapter:'adapters'};
  const adapterFields={
    'http-handler':{engine:''},
    'static':{root:''},
    'fixed-response':{'options.status':'','options.body':''},
    'relay-delivery':{'options.target':'','options.route':''}
  };
  function inspect(workspace) {
    const parsed = workspace.files.map(f => ({...f, sections:R.parse(f.value)}));
    let control = '';
    for (const file of parsed) for (const s of file.sections) if (same(s.path,['control'])) control = R.read(s,'listener',control);
    const dynamicControl = control && !/^listener:[^${}]+$/.test(control);
    const items = [];
    for (const file of parsed) for (const s of file.sections) {
      let type, id;
      if (s.path.length === 2 && s.path[0] === 'listeners' && !s.array && 'listener:'+s.path[1] !== control && R.read(s,'protocol') === 'http' && R.read(s,'transport','tcp') === 'tcp') { type='listener'; id=s.path[1]; }
      if (s.path.length === 2 && s.path[0] === 'engines' && !s.array && R.read(s,'kind') === 'vjsx') { type='engine'; id=s.path[1]; }
      if (s.path.length === 2 && s.path[0] === 'adapters' && !s.array) { type='adapter'; id=s.path[1]; }
      if (same(s.path,['pipelines']) && s.array) { type='route'; id=R.read(s,'id'); }
      if (!type) continue;
      const item = {type,id,path:file.source.path,section:s.path,values:{},error:''};
      if(type==='adapter') item.kind=R.read(s,'kind');
      try {
        if(type==='adapter') item.values=Object.fromEntries(Object.entries(adapterFields[item.kind] || {}).map(([key,fallback])=>[key,read(s,key,fallback)]));
        if (type === 'listener' && dynamicControl) throw Error('管理监听使用动态引用，请使用高级 TOML 编辑此监听。');
        if (type === 'listener') item.values = {host:read(s,'host',''),port:read(s,'port',0)};
        if (type === 'engine') item.values = {entry:read(s,'entry',''),module_root:read(s,'module_root','')};
        if (type === 'route') {
          const binding = workspace.pipelines.find(p => p.id === id && p.source_path === item.path);
          if (dynamicControl) continue;
          if (!binding || !binding.ingress.startsWith('listener:') || binding.ingress === control) continue;
          const listenerId = binding.ingress.slice(9);
          if (!parsed.some(f => f.sections.some(l => same(l.path,['listeners',listenerId]) && R.read(l,'protocol') === 'http'))) continue;
          if (file.sections.some(x => x.path[0] === 'pipelines' && x.path.length > 1)) throw Error('嵌套路由表请使用 TOML 编辑，避免改写其他路由。');
          item.values = {ingress:read(s,'ingress',''),egress:read(s,'egress',''),'match.paths':read(s,'match.paths',[]),'match.methods':read(s,'match.methods',[])};
        }
        // Verify that each editable target has one unambiguous source range.
        R.patch(file.value,s.path,type === 'route' ? id : null,item.values);
      } catch(e) { item.error=e.message; }
      try { R.patch(file.value,s.path,type==='route'?id:null,{}); item.canDelete=type!=='route' || !item.error; } catch(_) { item.canDelete=false; }
      items.push(item);
    }
    const order={listener:0,route:1,engine:2,adapter:3};
    items.sort((a,b)=>order[a.type]-order[b.type]);
    return {items,adapters:workspace.adapters || []};
  }
  function componentIds(workspace,type) {
    const ids=new Set();
    for (const file of workspace.files) for (const section of R.parse(file.value)) {
      if (type!=='route') {
        if (section.path[0]===domains[type] && section.path.length>1) ids.add(section.path[1]);
        for (const entry of section.entries) { const full=[...section.path,...entry.key]; if(full[0]===domains[type] && full.length>1) ids.add(full[1]); }
      } else if (same(section.path,['pipelines']) && section.array) ids.add(R.read(section,'id'));
    }
    if(type==='route') for(const pipeline of workspace.pipelines) ids.add(pipeline.id);
    return ids;
  }
  function create(workspace,model,type,path) {
    if (!Object.hasOwn(domains,type) || !workspace.files.some(f=>f.source.path===path)) throw Error('请选择项目内的配置来源文件。');
    const used=componentIds(workspace,type);
    for(const item of model.items) if(item.type===type) used.add(item.id);
    let n=1; const prefix={listener:'http',route:'route',engine:'vjsx',adapter:'out'}[type]; while(used.has(prefix+n)) n++;
    const listener=[...model.items].reverse().find(i=>i.type==='listener' && i.added && !i.deleted && !i.error) || model.items.find(i=>i.type==='listener' && !i.deleted && !i.error);
    const before=workspace.pipelines.find(p=>p.source_path===path)?.id || '';
    const ports=new Set(model.items.filter(i=>i.type==='listener' && !i.deleted).map(i=>i.values.port));
    for(const file of workspace.files) for(const section of R.parse(file.value)) if(section.path[0]==='listeners') { try { ports.add(R.read(section,'port',0)); } catch(_) {} }
    let port=8080;while(ports.has(port) && port<65535) port++;if(ports.has(port)) throw Error('请在高级配置中选择可用端口。');
    const adapter=[...model.items].reverse().find(i=>i.type==='adapter' && !i.deleted) || workspace.adapters.find(a=>!model.items.some(i=>i.type==='adapter' && i.id===a.id && i.deleted));
    const engine=[...model.items].reverse().find(i=>i.type==='engine' && !i.deleted && !i.error);
    const values={listener:{host:'127.0.0.1',port},route:{ingress:listener?'listener:'+listener.id:'',egress:adapter?'adapter:'+adapter.id:'','match.paths':['/'+prefix+n],'match.methods':[]},engine:{entry:engine?.values.entry || 'main.mjs',module_root:''},adapter:{engine:engine?'engine:'+engine.id:''}}[type];
    return {type,id:prefix+n,path,added:true,deleted:false,before,error:'',kind:type==='adapter'?'http-handler':undefined,section:type==='route'?['pipelines']:[domains[type],prefix+n],values};
  }
  function setAdapterKind(item,kind) {
    if(item.type!=='adapter' || !item.added || !Object.hasOwn(adapterFields,kind)) throw Error('此出口类型请使用高级 TOML 编辑。');
    item.kind=kind;item.values={...adapterFields[kind],...(kind==='static'?{root:'.'}:kind==='fixed-response'?{'options.status':'200','options.body':'OK'}:{})};
  }

  function valuesFor(item,input,all=false) {
    const values={};
    for(const [key,value] of Object.entries(input)) {
      if (!Object.hasOwn(item.values,key)) throw Error('不支持的表单字段。');
      if (!all && same(value,item.values[key])) continue;
      if (item.type==='listener' && key==='port' && (!Number.isInteger(value) || value<1 || value>65535)) throw Error('HTTP 端口应为 1–65535 的整数。');
      if (typeof value!==typeof item.values[key] || Array.isArray(value)!==Array.isArray(item.values[key])) throw Error('字段类型不正确。');
      if (Array.isArray(value) && value.some(v=>typeof v!=='string' || !v.trim())) throw Error('路由条件不能包含空值。');
      if (key==='match.methods' && value.some(v=>!/^[A-Z!#$%&'*+.^_`|~0-9-]+$/.test(v))) throw Error('HTTP 方法应使用大写名称，如 GET、POST。');
      if (typeof value==='string' && (/[\u0000-\u001f]/.test(value) || (!value.trim() && !['module_root','host','options.body','options.route'].includes(key)))) throw Error('请填写有效的配置值。');
      if(key==='options.status' && !/^[1-5][0-9]{2}$/.test(value)) throw Error('HTTP 状态码应为 100–599。');
      values[key]=(['module_root','host','options.route'].includes(key) && !value.trim()) || (key==='match.methods' && !value.length)?undefined:value;
    }
    return values;
  }
  function deletionImpact(workspace,model,index,edits={}) {
    const target=model.items[index];
    if(!target || !Object.hasOwn(domains,target.type) || (target.error && !target.canDelete)) throw Error('此配置请使用高级 TOML 编辑。');
    const ref=(target.type==='route'?'pipeline:':target.type+':')+target.id, references=[], graph=[];
    const actual=(item,i)=>({...item.values,...edits[i]});
    const ownerFor=(path,section,id)=>model.items.findIndex(item=>item.path===path && !item.added &&
      (item.type==='route'?same(section,['pipelines']) && item.id===id:item.section.length<=section.length && same(item.section,section.slice(0,item.section.length))));
    function record(path,section,id,key,values,owner) {
      if(target.type==='engine' && key.at(-1)==='engine' && values.some(v=>typeof v==='string' && v.includes('${env.'))) values=[...values,ref];
      const component=model.items[owner];
      const domain={adapters:'adapter',engines:'engine',transforms:'transform',policies:'policy',relays:'relay',listeners:'listener'}[section[0]];
      const source=component?(component.type==='route'?'pipeline':component.type)+':'+component.id:id?'pipeline:'+id:domain && section[1]?domain+':'+section[1]:'';
      if(source) graph.push({source,values});
      if(!values.includes(ref)) return;
      if(owner===index) return;
      const route=model.items[owner];
      references.push({path,component:route?route.type+':'+route.id:(id || section.join('.')),field:key.join('.'),index:owner,
        scheduledRemoval:!!route?.deleted,canCascade:route?.type==='route' && !route.error && ((target.type==='listener' && key.join('.')==='ingress') || (target.type==='adapter' && key.join('.')==='egress'))});
    }
    for(const file of workspace.files) for(const section of R.parse(file.value)) {
      const id=section.array && same(section.path,['pipelines'])?R.read(section,'id'):'';
      const owner=ownerFor(file.source.path,section.path,id);
      for(const entry of section.entries) {
        const key=entry.key.join('.');
        const override=edits[owner];
        if(override && Object.hasOwn(override,key)) continue;
        let strings=(entry.raw.match(/"(?:\\.|[^"\\])*"|'[^']*'/g)||[]).map(token=>{try{return token[0]==='"'?JSON.parse(token):token.slice(1,-1);}catch(_){return '';}});
        // Workspace bindings include environment-resolved ingress/egress references.
        if(strings.some(v=>typeof v==='string' && v.includes('${env.')) && id && ['ingress','egress'].includes(key)) {
          const pipeline=workspace.pipelines.find(p=>p.source_path===file.source.path && p.id===id);
          if(pipeline) strings.push(pipeline[key]);
        }
        const full=[...section.path,...entry.key];
        const dottedOwner=owner<0 && full.length>2?model.items.findIndex(item=>!item.added && item.type!=='route' && item.section[0]===full[0] && item.id===full[1]):-1;
        // Dynamic engine references cannot be resolved by the lossless source editor.
        if(target.type==='engine' && full.at(-1)==='engine' && strings.some(v=>typeof v==='string' && v.includes('${env.'))) strings.push(ref);
        record(file.source.path,section.path,id,entry.key,strings,dottedOwner>=0?dottedOwner:owner);
      }
    }
    for(const [i,item] of model.items.entries()) for(const [key,value] of Object.entries(item.added?actual(item,i):(edits[i] || {}))) record(item.path,item.section,item.id,key.split('.'),Array.isArray(value)?value:[value],i);
    const affected=new Set([ref]);
    let grew=true;while(grew) { grew=false;for(const edge of graph) if(!affected.has(edge.source) && edge.values.some(v=>affected.has(v))) { affected.add(edge.source);grew=true; } }
    const bindings=[];
    if(target.type==='route') {
      const value=actual(target,index), adapter=workspace.adapters.find(a=>'adapter:'+a.id===value.egress);
      bindings.push({id:target.id,path:target.path,ingress:value.ingress,egress:value.egress,relay:adapter?.kind==='relay-delivery'?adapter.target:''});
    } else {
      const adapterRefs=new Set(target.type==='adapter'?[ref]:[]);
      if(target.type==='engine') for(const r of references) { const owner=model.items[r.index]; if(owner?.type==='adapter') adapterRefs.add('adapter:'+owner.id); }
      const matches=(value,id)=>affected.has('pipeline:'+id) || (target.type==='listener'?value.ingress===ref:adapterRefs.has(value.egress));
      for(const [i,item] of model.items.entries()) if(item.type==='route') {
        const value=actual(item,i);
        if(matches(value,item.id)) bindings.push({id:item.id,path:item.path,ingress:value.ingress,egress:value.egress,scheduledRemoval:!!item.deleted});
      }
      for(const pipeline of workspace.pipelines) if(matches(pipeline,pipeline.id) && !model.items.some(i=>i.type==='route' && i.id===pipeline.id && i.path===pipeline.source_path)) bindings.push({id:pipeline.id,path:pipeline.source_path,ingress:pipeline.ingress,egress:pipeline.egress});
    }
    return {references,bindings,cascadeIndices:[...new Set(references.filter(r=>!r.scheduledRemoval && r.canCascade).map(r=>r.index))],blockers:references.filter(r=>!r.scheduledRemoval && !r.canCascade)};
  }
  function remove(text,item) {
    const sections=R.parse(text);
    const targets=sections.filter(s=>item.type!=='route'?s.path[0]===domains[item.type] && s.path[1]===item.id:same(s.path,['pipelines']) && s.array && R.read(s,'id')===item.id);
    if(item.type==='route' && sections.some(s=>s.path[0]==='pipelines' && s.path.length>1)) throw Error('嵌套路由表请使用高级 TOML 编辑。');
    const ranges=targets.map(s=>({start:s.start,end:s.entries.at(-1)?.end || s.body}));
    // Also handle dotted declarations that extend a listener in another include.
    if(item.type!=='route') for(const s of sections) if(!targets.includes(s)) for(const e of s.entries) if(same([...s.path,...e.key].slice(0,2),[domains[item.type],item.id])) ranges.push({start:e.start,end:e.end});
    ranges.sort((a,b)=>b.start-a.start);
    for(const range of ranges) text=text.slice(0,range.start)+text.slice(range.end);
    return text;
  }
  function edit(workspace,model,edits) {
    const texts=new Map(workspace.files.map(f=>[f.source.path,f.value]));
    for(const [index,item] of model.items.entries()) if(item.deleted) {
      const impact=deletionImpact(workspace,model,index,edits);
      if(impact.references.some(r=>!r.scheduledRemoval)) throw Error('删除 '+item.id+' 前，请先处理受影响的绑定或一并删除已确认的 HTTP 路由。');
    }
    for(const [index,input] of Object.entries(edits)) {
      const item=model.items[Number(index)];
      if(!item) throw Error('此配置请使用 TOML 编辑。');
      if(item.deleted || item.added) continue;
      if(item.error) throw Error('此配置请使用 TOML 编辑。');
      const values=valuesFor(item,input);
      if(Object.keys(values).length) texts.set(item.path,R.patch(texts.get(item.path),item.section,item.type==='route'?item.id:null,values));
    }
    const used=Object.fromEntries(Object.keys(domains).map(type=>[type,componentIds(workspace,type)]));
    for(const [index,item] of model.items.entries()) if(item.added && !item.deleted) {
      if(!texts.has(item.path)) throw Error('请选择项目内的配置来源文件。');
      if(!/^[A-Za-z0-9_][A-Za-z0-9_.\/-]{0,127}$/.test(item.id)) throw Error('ID 使用字母、数字、_、-、. 或 /，长度不超过 128。');
      if(used[item.type].has(item.id)) throw Error('ID 已在项目中使用：'+item.id);
      used[item.type].add(item.id);
      const values=valuesFor(item,{...item.values,...edits[index]},true);
      let text=texts.get(item.path);
      if(item.type==='listener') text=R.patch(text,['listeners',item.id],null,{protocol:'http',transport:'tcp',...values});
      else if(item.type==='engine') text=R.patch(text,['engines',item.id],null,{kind:'vjsx',runtime_profile:'script',...values});
      else if(item.type==='adapter') {
        if(!Object.hasOwn(adapterFields,item.kind)) throw Error('此出口类型请使用高级 TOML 编辑。');
        text=R.patch(text,['adapters',item.id],null,{kind:item.kind,...values});
      } else {
        const block='\n[[pipelines]]\nid = '+JSON.stringify(item.id)+'\n'+Object.entries(values).filter(([,v])=>v!==undefined).map(([k,v])=>k+' = '+JSON.stringify(v)+'\n').join('');
        const before=item.before?R.parse(text).find(s=>same(s.path,['pipelines']) && s.array && R.read(s,'id')===item.before):null;
        if(item.before && !before) throw Error('插入位置已不存在，请重新选择。');
        text=before?text.slice(0,before.start)+block+'\n'+text.slice(before.start):text.trimEnd()+'\n'+block;
      }
      texts.set(item.path,text);
    }
    for(const item of model.items) if(item.deleted && !item.added) for(const [path,text] of texts) texts.set(path,remove(text,item));
    return [...texts].filter(([path,value])=>value!==workspace.files.find(f=>f.source.path===path).value).map(([path,value])=>({path,original:workspace.files.find(f=>f.source.path===path).value,value}));
  }
  root.CommonConfig = {inspect,edit,create,deletionImpact,setAdapterKind};
})(globalThis);
