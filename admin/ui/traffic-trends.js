/* Server windows, never differences between browser polls. */
(function(root){
  const counters=['requests_total','errors_total','client_errors_total','server_errors_total','timeouts_total','duration_sum_ms','duration_count'];
  function sum(values){const out={duration_max_ms:0,duration_buckets:Array(9).fill(0)};for(const key of counters)out[key]=0;for(const value of values){if(!value)continue;for(const key of counters)out[key]+=value[key] || 0;out.duration_max_ms=Math.max(out.duration_max_ms,value.duration_max_ms || 0);for(let i=0;i<9;i++)out.duration_buckets[i]+=value.duration_buckets?.[i] || 0;}return out;}
  function status(recent,historical,slowMs){
    if(!recent)return '近期未确认';
    if(!recent.requests_total)return historical?.errors_total?'近期无请求 · 有历史错误，未确认恢复':'近期无已完成请求';
    if(recent.errors_total)return '近期有错误 · '+recent.errors_total+' 次';
    if(recent.duration_max_ms>=slowMs)return '近期有慢请求';
    return historical?.errors_total?'近期无错误 · 保留历史记录':'近期无错误';
  }
  function build(snapshot,business,filter={},now=Date.now()/1000){
    const listener=filter.listener || '',pipeline=filter.pipeline ?? null,seconds=Number(filter.seconds || 60),slowMs=Math.max(1,Number(filter.slowMs || 500));
    const valid=business.available && snapshot && Number.isFinite(snapshot.at_unix) && snapshot.at_unix<=now+5 && now-snapshot.at_unix<=15 && snapshot.window_seconds===seconds && snapshot.listener===listener && snapshot.route_filtered===(pipeline!==null) && (pipeline===null || snapshot.pipeline===pipeline);
    const span=valid?Math.max(1,snapshot.at_unix-snapshot.start_unix):null;
    const recentListeners=new Map((valid?snapshot.listeners:[]).map(item=>[item.listener_id,item]));
    const rows=business.routes.filter(route=>(!listener || route.listener===listener) && (pipeline===null || route.id===pipeline)).map(route=>{
      const owner=recentListeners.get(route.listener),recent=owner ? owner.routes.find(item=>item.pipeline_id===route.id)?.metrics || sum([]) : null;
      return {...route,recent,status:status(recent,route.metrics,slowMs),recentIssue:!!recent?.errors_total,historicalIssue:!!recent && !!route.metrics?.errors_total && !recent.errors_total,slow:!!recent?.requests_total && recent.duration_max_ms>=slowMs};
    });
    const average=metrics=>metrics?.duration_count?metrics.duration_sum_ms/metrics.duration_count:null;
    const sorted=rows.filter(row=>filter.status==='recent'?row.recentIssue:filter.status==='history'?row.historicalIssue:filter.status==='slow'?row.slow:true).sort((a,b)=>filter.sort==='slow'?(b.recent?.duration_max_ms || 0)-(a.recent?.duration_max_ms || 0):filter.sort==='requests'?(b.recent?.requests_total || 0)-(a.recent?.requests_total || 0):Number(b.recentIssue)-Number(a.recentIssue) || (b.recent?.errors_total || 0)-(a.recent?.errors_total || 0));
    const selected=business.listeners.filter(item=>!listener || item.id===listener).map(item=>{
      const recent=recentListeners.get(item.id)?.metrics || null;
      const historical=pipeline===null?item.metrics:sum(item.routes.filter(route=>route.id===pipeline).map(route=>route.metrics));
      return {...item,recent,historical,status:status(recent,historical,slowMs)};
    });
    const metrics=valid?snapshot.metrics:null;
    const points=valid?snapshot.series.map(point=>({at:point.at_unix,span:point.span_seconds,requests:point.metrics.requests_total/Math.max(1,point.span_seconds),errorRate:point.metrics.requests_total?point.metrics.errors_total/point.metrics.requests_total*100:null,average:average(point.metrics),maximum:point.metrics.requests_total?point.metrics.duration_max_ms:null,count:point.metrics.requests_total})):[];
    return {available:!!valid,span,warmup:!!valid && span<seconds,metrics,rps:metrics?metrics.requests_total/span:null,errorRate:metrics?.requests_total?metrics.errors_total/metrics.requests_total*100:null,latency:root.AdminOverview.latency(metrics),points,rows:sorted,allRows:rows,listeners:selected,slowMs,at:valid?snapshot.at_unix:null,recentIssues:rows.filter(row=>row.recentIssue).length,historicalIssues:rows.filter(row=>row.historicalIssue).length,slowRoutes:rows.filter(row=>row.slow).length};
  }
  root.TrafficTrends={build,status,sum};
  if(typeof module==='object' && module.exports)module.exports=root.TrafficTrends;
})(globalThis);
