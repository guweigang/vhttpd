(function(root){
  function build(snapshot,files=[],now=Date.now()/1000){
    const fresh=!!snapshot && Array.isArray(snapshot.instances) && Number.isFinite(snapshot.at_unix) && now-snapshot.at_unix<=15 && snapshot.at_unix<=now+5;
    if(!fresh)return {available:false,instances:[]};
    const sources=(type,id)=>files.filter(file=>Array.isArray(file[type+'_ids']) && file[type+'_ids'].includes(id)).map(file=>file.path);
    const instances=snapshot.instances.map(item=>{
      const load=item.load || {},known=load.available===true,concurrency=known && load.concurrency_observed!==false;
      let status=!known?'负载未采集':load.stopping?'停止接收':load.waiting>0?'正在排队':load.embedded && load.usable===0?'无可接收的执行槽':!concurrency?'并发占用未确认':load.capacity>0 && load.occupied>=load.capacity?'执行槽已占满':'采样时空闲';
      if(concurrency && load.occupied>0 && load.occupied<load.capacity && !load.waiting && !load.stopping)status='部分执行槽占用';
      const recentTimeout=known && load.last_queue_timeout_unix>0 && snapshot.at_unix-load.last_queue_timeout_unix>=0 && snapshot.at_unix-load.last_queue_timeout_unix<=60;
      return {...item,load,known,concurrency,status,recentTimeout,engineSources:(item.engine_ids || []).flatMap(id=>sources('engine',id).map(path=>({id,path}))),routes:(item.routes || []).map(route=>({...route,sources:sources('pipeline',route.pipeline_id),adapterSources:sources('adapter',route.adapter_id)}))};
    });
    return {available:true,at:snapshot.at_unix,instances};
  }
  function forRoute(model,listener,pipeline){return model.instances.filter(item=>item.listener_id===listener && (item.routes.some(route=>route.pipeline_id===pipeline) || (pipeline==='' && item.primary)));}
  root.ExecutorOverview={build,forRoute};
  if(typeof module==='object' && module.exports)module.exports=root.ExecutorOverview;
})(globalThis);
