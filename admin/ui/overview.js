/* Read-only view model: configuration, runtime evidence and transport availability
 * are separate states. Never infer live health from graph node status. */
(function (root) {
  const array = value => Array.isArray(value) ? value : [];
  function number(object, path) {
    const value = path.split('.').reduce((item, key) => item == null ? undefined : item[key], object);
    return typeof value === 'number' && Number.isFinite(value) ? value : null;
  }
  function eventRows(events) {
    const names = {'admin.config_changeset.published':'已发布项目配置','admin.draft.saved':'已保存草稿','admin.draft.published':'已发布草稿','admin.runtime.plan.replacement.applied':'已应用运行计划'};
    return array(events).slice().reverse().map(event => ({
      time:event.at_unix ? new Date(event.at_unix * 1000).toLocaleString() : event.ts || event.time || event.created_at || '—',
      type:names[event.type] || event.type || event.action || '操作',
      target:event.fields?.draft_id || event.key || event.target || event.draft_id || event.fields?.config_path || '—'
    }));
  }
  const emptyMetrics = () => ({requests_total:0,errors_total:0,client_errors_total:0,server_errors_total:0,timeouts_total:0,duration_sum_ms:0,duration_count:0,duration_max_ms:0,duration_buckets:Array(9).fill(0)});
  function latency(metrics) {
    if (!metrics || !metrics.duration_count) return {average:'—',p95:'—',max:'—'};
    const bounds=[1,5,10,50,100,500,1000,5000];
    const rank=Math.ceil(metrics.duration_count*0.95);
    const index=array(metrics.duration_buckets).findIndex(count=>count>=rank);
    return {average:(metrics.duration_sum_ms/metrics.duration_count).toFixed(1)+' ms',p95:index<0?'—':index<8?'≤ '+bounds[index]+' ms':'> 5000 ms',max:metrics.duration_max_ms+' ms'};
  }
  function traffic(data, errors={}, authRequired=false) {
    const usable=!!data.runtime && !errors.runtime && !authRequired;
    const seen=new Set();
    const registered=usable ? array(data.runtime.listeners).filter(listener=> {
      if(listener.is_control===true || (listener.is_control!==false && listener.listener_id===data.runtime.pipelines?.listener_id) || seen.has(listener.listener_id)) return false;
      seen.add(listener.listener_id);return true;
    }) : [];
    const sources=array(data.configFiles);
    const listeners=registered.map(listener=>{
      const metrics=listener.http_metrics && typeof listener.http_metrics.requests_total==='number' ? listener.http_metrics : null;
      const actual=new Map(array(listener.route_metrics).map(route=>[route.pipeline_id,route.metrics]));
      const projected=new Map(array(listener.pipelines?.routes).map(route=>[route.pipeline_id,route]));
      const ids=[...new Set([...projected.keys(),...actual.keys()])];
      const routes=ids.map(id=> {
        const route=projected.get(id), value=actual.get(id) || (metrics?emptyMetrics():null);
        const source=sources.find(file=>array(file.pipeline_ids).includes(id));
        return {id,listener:listener.listener_id,label:id==='@overflow'?'其余历史路由':id || '默认处理 / 协议入口',match:route?[array(route.methods).join(', ') || '*',array(route.paths).join(', ') || '*'].join(' '):'',active:!!route,metrics:value,latency:latency(value),source:source?.path || '',issue:!!value && value.errors_total>0};
      });
      return {id:listener.listener_id,address:listener.host+':'+listener.port,metrics,latency:latency(metrics),routes,failures:array(listener.recent_errors).map(error=>({...error,listener:listener.listener_id}))};
    });
    const available=usable && listeners.length>0 && listeners.every(listener=>listener.metrics);
    const total=emptyMetrics();
    if(available) for(const listener of listeners) {
      const m=listener.metrics;
      for(const key of ['requests_total','errors_total','client_errors_total','server_errors_total','timeouts_total','duration_sum_ms','duration_count'])total[key]+=m[key] || 0;
      total.duration_max_ms=Math.max(total.duration_max_ms,m.duration_max_ms || 0);
      for(let i=0;i<9;i++)total.duration_buckets[i]+=m.duration_buckets?.[i] || 0;
    }
    return {available,listeners,total:available?total:null,latency:latency(available?total:null),routes:listeners.flatMap(listener=>listener.routes),failures:listeners.flatMap(listener=>listener.failures).sort((a,b)=>b.at_unix-a.at_unix)};
  }
  function build(data = {}, errors = {}, authRequired = false) {
    const runtime = data.runtime;
    const business = traffic(data, errors, authRequired);
    const connected = !!runtime && !errors.runtime && !authRequired;
    const graphAvailable = !!data.graph && !errors.graph && !authRequired;
    const nodes = graphAvailable ? array(data.graph.nodes) : [];
    const edges = graphAvailable ? array(data.graph.edges) : [];
    const byRef = new Map(nodes.map(node => [node.ref, node]));
    const files = errors.configFiles || authRequired ? [] : array(data.configFiles);
    const main = files.find(file => file.role === 'main');
    const path = main?.path || '';
    const project = path ? (path.split('/').slice(-2, -1)[0] || '当前项目') : '当前项目';
    const stats = connected && !errors.stats ? (data.stats || runtime.stats) : null;
    const plan = connected && !errors.plan && data.plan?.config_path === path ? data.plan : null;
    // A missing/invalid plan never clears pending status or claims effectiveness.
    const knownPlan = !!plan && typeof plan.allowed === 'boolean' && Array.isArray(plan.actions) && !!plan.strategy;
    const pending = knownPlan && (!plan.allowed || plan.actions.length > 0);
    const registered = connected ? array(runtime.listeners) : [];
    const listeners = nodes.filter(node => node.domain === 'listener' && node.id !== runtime?.pipelines?.listener_id);
    const routeNodes = nodes.filter(node => node.domain === 'pipeline');
    const observed = listeners.filter(node => registered.some(item => item.listener_id === node.id));
    const notices = [];
    if (!connected) notices.push({tone:'danger', title:authRequired ? '需要重新登录' : '运行状态无法确认', detail:authRequired ? '回到工作台，点击“打开浏览器”重新登录。' : '检查工作台中的实例与启动日志，再刷新此页。', view:null});
    if (connected && !knownPlan) notices.push({tone:'warning',title:'配置生效状态未确认',detail:'整项目检查未完成或配置校验失败。查看项目配置；管理接口可连接不表示新配置已生效。',view:'apps',action:'检查配置'});
    if (pending) {
      const changed = [['restart_listeners','监听'],['changed_pipelines','路由'],['drain_engines','执行器'],['reload_relays','Relay']].map(([key,label]) => array(plan[key]).length ? label+' '+array(plan[key]).length+' 项' : '').filter(Boolean).join('、');
      notices.push({tone:'warning',title:'待重启生效',detail:(changed ? '影响'+changed+'。' : '')+'新配置尚未生效。回到工作台点击“重启并生效”，完成后自动检查整个项目。',view:'apps',action:'继续编辑'});
    }
    const agents = connected ? array(runtime.relay?.agents) : [];
    const failedAgents = agents.filter(agent => ['backoff','closed','disconnected'].includes(agent.state));
    if (failedAgents.length) notices.push({tone:'warning',title:failedAgents.length+' 个 Relay Agent 未连接',detail:failedAgents.map(agent => agent.node_id || agent.relay_id).join('、')+'；查看连接状态与重试记录。',view:'relay',action:'查看 Relay'});
    const recent=data.traffic;
    const fresh=connected && recent && !errors.traffic && Date.now()/1000-recent.at_unix<=15 && recent.at_unix<=Date.now()/1000+5;
    const failingRoutes=fresh?recent.listeners.flatMap(listener=>listener.routes).filter(route=>route.metrics.errors_total>0):[];
    if(failingRoutes.length) notices.push({tone:'warning',title:failingRoutes.length+' 条路由在近期窗口出现错误',detail:'所选最近 '+recent.window_seconds/60+' 分钟；按监听和路由定位。历史累计错误不作为近期故障。',view:'traffic',action:'定位近期异常'});
    const requests = number(stats, 'http.requests_total');
    const errorCount = number(stats, 'http.errors_total');
    const timeoutCount = number(stats, 'http.timeouts_total');
    if (!authRequired && Object.keys(errors).some(key => key !== 'runtime' && key !== 'plan')) notices.push({tone:'warning',title:'部分信息暂不可用',detail:'无法读取：'+Object.keys(errors).filter(key => !['runtime','plan'].includes(key)).join('、')+'。未知值以 — 显示，稍后自动重试。'});
    const states = [
      {label:'管理连接',title:connected?'已连接':'未确认',tone:connected?'good':'danger',detail:connected?'已获取当前实例的运行快照':'无法读取实时状态'},
      {label:'业务监听',title:connected && graphAvailable ? (listeners.length ? observed.length+' / '+listeners.length+' 已登记' : '未配置业务监听') : '未确认',tone:connected && graphAvailable && observed.length===listeners.length?'neutral':'warning',detail:'运行时登记 / 计划监听；不等于 HTTP 请求成功'},
      {label:'项目配置',title:pending?'待重启生效':knownPlan?'运行计划一致':'未确认',tone:pending?'warning':knownPlan?'good':'warning',detail:knownPlan?'按主配置及全部 include 比较；业务行为需实际请求验证':'等待整项目检查，不能判断是否已生效'}
    ];
    const chains = routeNodes.map(node => {
      const incoming = edges.filter(edge => edge.to===node.ref && edge.kind==='ingress');
      const outgoing = edges.filter(edge => edge.from===node.ref && edge.kind==='egress');
      const transforms = edges.filter(edge => edge.from===node.ref && edge.kind.includes('transform'));
      const refs = [...incoming.map(edge=>edge.from),node.ref,...transforms.map(edge=>edge.to),...outgoing.map(edge=>edge.to)];
      for (const edge of outgoing) for (const link of edges.filter(link=>link.from===edge.to && ['adapter_uses_engine','adapter_uses_relay'].includes(link.kind))) refs.push(link.to);
      const steps = [...new Set(refs)].map(ref => {
        const item=byRef.get(ref) || {ref,id:ref};
        const meta=item.metadata || {};
        const detail=item.domain==='listener' ? [item.kind,meta.host && meta.host+':'+meta.port].filter(Boolean).join(' · ') : item.kind || '引用未解析';
        return {ref,label:({listener:'输入监听',relay:'Relay',pipeline:'路由 / Pipeline',adapter:'出口 Adapter',engine:'执行器',transform:'转换'})[item.domain] || '组件', name:item.label || item.id,detail};
      });
      return {label:node.label || node.id,match:[node.metadata?.methods,node.metadata?.paths].filter(Boolean).join(' · ') || '全部匹配',steps};
    });
    return {project,path,graphAvailable,states,notices,chains,business,
      metrics:[{label:'项目累计已完成请求',value:business.total?.requests_total ?? '—',detail:'本次进程累计 · 不含管理接口和 WebSocket'},
        {label:'累计错误 · 4xx / 5xx',value:business.total?business.total.client_errors_total+' / '+business.total.server_errors_total:'—',detail:'超时 '+(business.total?.timeouts_total ?? '—')+' 次；累计值不代表当前故障'},
        {label:'累计平均 / P95 处理耗时',value:business.latency.average,detail:'P95 '+business.latency.p95+' · 分桶估计'},
        {label:'运行时长',value:connected && typeof runtime.uptime_seconds==='number'?Math.floor(runtime.uptime_seconds/60)+'分 '+runtime.uptime_seconds%60+'秒':'—',detail:'当前进程；重启后重新计时'}],
      events:errors.events || authRequired ? [] : eventRows(data.events).slice(0,5),
      sources:files.map(file=>({role:file.role,path:file.path,label:file.include_path || file.path}))};
  }
  root.AdminOverview={build,eventRows,traffic,latency};
  if(typeof module==='object' && module.exports) module.exports=root.AdminOverview;
})(globalThis);
