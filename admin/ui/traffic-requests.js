(function(root){
  function stages(value){
    if(!value?.available)return {available:false,rows:[],bottleneck:'分阶段耗时未采集'};
    const definitions=[['queue','排队'],['vjsx','vjsx 执行'],['adapter','出口 Adapter'],['other','其他处理 / 未细分']];
    const rows=definitions.map(([key,label])=>({key,label,measured:key==='other' || value[key+'_observed']===true,ms:value[key+'_ms']}));
    if(rows.some(row=>row.measured && (!Number.isFinite(row.ms) || row.ms<0)))return {available:false,rows:[],bottleneck:'分阶段数据无效'};
    const known=rows.filter(row=>row.measured),sum=known.reduce((n,row)=>n+row.ms,0),largest=[...known].sort((a,b)=>b.ms-a.ms)[0];
    return {available:true,rows:rows.map(row=>({...row,share:row.measured && sum>0?row.ms/sum*100:0})),bottleneck:largest && largest.ms>=.01?'主要耗时：'+largest.label+'（'+largest.ms.toFixed(2)+' ms）':'阶段耗时接近 0 ms'};
  }
  function select(snapshot,focus,seconds,threshold,now=Date.now()/1000){
    const available=!!snapshot && !!focus && snapshot.listener===focus[0] && snapshot.pipeline===focus[1] && snapshot.window_seconds===seconds && snapshot.at_unix<=now+5 && now-snapshot.at_unix<=15 && Array.isArray(snapshot.requests);
    if(!available)return {available:false,requests:[],retained:0};
    const requests=snapshot.requests.filter(item=>item.request && item.request.duration_ms>=threshold && item.request.at_unix>=snapshot.at_unix-seconds && item.request.at_unix<=snapshot.at_unix).map(item=>({observation_id:item.request.observation_id,method:item.request.method,status:item.request.status,duration_ms:item.request.duration_ms,at_unix:item.request.at_unix,stages:stages(item.request.stages),log_line:item.log_line})).sort((a,b)=>b.at_unix-a.at_unix);
    return {available:true,requests,retained:snapshot.retained};
  }
  root.TrafficRequests={select,stages};
  if(typeof module==='object' && module.exports)module.exports=root.TrafficRequests;
})(globalThis);
